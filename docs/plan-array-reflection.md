# Plan: Add Array Type Information to Reflection Output

## Current State

**`workgroupSize` is already implemented** in `EntryPointInfo` (reflect.go:50-55):
```json
"entryPoints": [{ "name": "main", "stage": "compute", "workgroupSize": [8, 8, 1] }]
```

**Missing for array bindings** like `array<Particle, 10000>`:

| Field | Status | Notes |
|-------|--------|-------|
| `elementCount` | Missing | Computed internally (`evaluateConstExpr`) but not exposed |
| `elementStride` | Missing | Computed as `Stride` in `TypeLayout` but not exposed |
| `elementType` | Missing | Available in AST but not extracted |
| `depth` | Missing | Useful for parsing nested arrays without recursion |

---

## Proposed Changes

### 1. Add `ArrayInfo` struct to `reflect.go`

```go
// ArrayInfo describes array-specific information for array types.
// For nested arrays (e.g., array<array<f32, 4>, 10>), Array field contains nested info.
type ArrayInfo struct {
    Depth         int           `json:"depth"`                   // nesting depth (1 = simple array, 2+ = nested)
    ElementCount  *int          `json:"elementCount"`            // null for runtime-sized arrays
    ElementStride int           `json:"elementStride"`           // stride in bytes (size + alignment padding)
    TotalSize     *int          `json:"totalSize"`               // elementCount * elementStride, null for runtime-sized
    ElementType   string        `json:"elementType"`             // original name: "Particle", "vec4f", "array<f32, 4>"
    ElementTypeMapped string    `json:"elementTypeMapped"`       // minified name: "a", "vec4f", "array<f32, 4>"
    ElementLayout *StructLayout `json:"elementLayout,omitempty"` // layout if element is a struct
    Array         *ArrayInfo    `json:"array,omitempty"`         // nested array info (for array<array<...>>)
}
```

### 2. Extend `BindingInfo` struct

```go
type BindingInfo struct {
    Group        int           `json:"group"`
    Binding      int           `json:"binding"`
    Name         string        `json:"name"`              // original name
    NameMapped   string        `json:"nameMapped"`        // minified name
    AddressSpace string        `json:"addressSpace"`
    AccessMode   string        `json:"accessMode,omitempty"`
    Type         string        `json:"type"`              // original type string
    TypeMapped   string        `json:"typeMapped"`        // minified type string
    Layout       *StructLayout `json:"layout,omitempty"`  // only for non-array struct types
    Array        *ArrayInfo    `json:"array,omitempty"`   // only for array types
}
```

### 3. Add `extractArrayInfo()` function in `reflect.go`

Recursive function to handle nested arrays. Insert in the `LayoutComputer` methods section, after `extractBinding()`:

```go
// extractArrayInfo extracts array metadata including nested array information.
// The depth parameter tracks nesting level (1 for outermost array).
func (lc *LayoutComputer) extractArrayInfo(arrayType *ast.ArrayType, depth int) *ArrayInfo {
    arrayLayout := lc.computeArrayTypeLayout(arrayType)

    var elementCount *int
    var totalSize *int
    if arrayType.Size != nil {
        count, err := lc.evaluateConstExpr(arrayType.Size)
        if err == nil && count >= 0 {
            elementCount = &count
            total := count * arrayLayout.Stride
            totalSize = &total
        }
    }
    // null for runtime-sized arrays (arrayType.Size == nil)

    info := &ArrayInfo{
        Depth:             depth,
        ElementCount:      elementCount,
        ElementStride:     arrayLayout.Stride,
        TotalSize:         totalSize,
        ElementType:       lc.typeToString(arrayType.ElemType, false), // original
        ElementTypeMapped: lc.typeToString(arrayType.ElemType, true),  // minified
    }

    // Add struct layout if element is a struct type
    if identType, ok := arrayType.ElemType.(*ast.IdentType); ok {
        if structDecl := lc.lookupStruct(identType); structDecl != nil {
            info.ElementLayout = lc.computeStructLayout(structDecl)
        }
    }

    // Handle nested arrays recursively
    if nestedArray, ok := arrayType.ElemType.(*ast.ArrayType); ok {
        info.Array = lc.extractArrayInfo(nestedArray, depth+1)
    }

    return info
}
```

### 4. Extend `typeToString()` to support mapped names

Modify the existing `typeToString()` function signature:

```go
// typeToString converts an AST type to its string representation.
// If mapped is true, uses minified names for user-defined types.
func (lc *LayoutComputer) typeToString(typ ast.Type, mapped bool) string {
    switch t := typ.(type) {
    case *ast.IdentType:
        if mapped && t.Ref.IsValid() {
            return lc.getMappedName(t.Ref)
        }
        return t.Name
    case *ast.ArrayType:
        elemStr := lc.typeToString(t.ElemType, mapped)
        if t.Size != nil {
            count, _ := lc.evaluateConstExpr(t.Size)
            return fmt.Sprintf("array<%s, %d>", elemStr, count)
        }
        return fmt.Sprintf("array<%s>", elemStr)
    // ... other cases
    }
}
```

### 5. Modify `extractBinding()` in `reflect.go`

At the end of `extractBinding()`, before the return statement:

```go
// Set mapped names
info.NameMapped = lc.getMappedName(varDecl.Ref)
info.TypeMapped = lc.typeToString(varDecl.Type, true)

// Add array info for array types (move layout inside array info)
if arrayType, ok := varDecl.Type.(*ast.ArrayType); ok {
    info.Array = lc.extractArrayInfo(arrayType, 1)
    info.Layout = nil // layout is in array.elementLayout for array types
}
```

### 6. Update `pkg/api/api.go`

Mirror the new `ArrayInfo` type in the public API with identical fields.

### 7. Update tests

Add snapshot test cases for:
- Simple array bindings: `array<f32, 100>`
- Array of structs: `array<Particle, 10000>`
- Runtime-sized arrays: `array<f32>`
- Nested arrays: `array<array<f32, 4>, 10>`
- Deeply nested: `array<array<array<f32, 2>, 3>, 4>`

---

## Expected Output

### Simple array of structs
Input:
```wgsl
struct Particle { pos: vec3f, vel: f32 }
@group(0) @binding(0) var<storage, read_write> data: array<Particle, 10000>;
```

Output (with `minifyIdentifiers: true`):
```json
{
  "bindings": [{
    "group": 0,
    "binding": 0,
    "name": "data",
    "nameMapped": "a",
    "addressSpace": "storage",
    "accessMode": "read_write",
    "type": "array<Particle, 10000>",
    "typeMapped": "array<b, 10000>",
    "array": {
      "depth": 1,
      "elementCount": 10000,
      "elementStride": 16,
      "totalSize": 160000,
      "elementType": "Particle",
      "elementTypeMapped": "b",
      "elementLayout": {
        "size": 16,
        "alignment": 16,
        "fields": [
          { "name": "pos", "nameMapped": "pos", "offset": 0, "size": 12, "type": "vec3f" },
          { "name": "vel", "nameMapped": "vel", "offset": 12, "size": 4, "type": "f32" }
        ]
      }
    }
  }]
}
```

### Runtime-sized array
Input: `@group(0) @binding(0) var<storage> data: array<f32>;`

```json
{
  "bindings": [{
    "group": 0,
    "binding": 0,
    "name": "data",
    "nameMapped": "a",
    "addressSpace": "storage",
    "type": "array<f32>",
    "typeMapped": "array<f32>",
    "array": {
      "depth": 1,
      "elementCount": null,
      "elementStride": 4,
      "totalSize": null,
      "elementType": "f32",
      "elementTypeMapped": "f32"
    }
  }]
}
```

### Nested array
Input: `@group(0) @binding(0) var<storage> matrix: array<array<f32, 4>, 10>;`

```json
{
  "bindings": [{
    "group": 0,
    "binding": 0,
    "name": "matrix",
    "nameMapped": "a",
    "addressSpace": "storage",
    "type": "array<array<f32, 4>, 10>",
    "typeMapped": "array<array<f32, 4>, 10>",
    "array": {
      "depth": 1,
      "elementCount": 10,
      "elementStride": 16,
      "totalSize": 160,
      "elementType": "array<f32, 4>",
      "elementTypeMapped": "array<f32, 4>",
      "array": {
        "depth": 2,
        "elementCount": 4,
        "elementStride": 4,
        "totalSize": 16,
        "elementType": "f32",
        "elementTypeMapped": "f32"
      }
    }
  }]
}
```

---

## Files to Modify

| File | Change |
|------|--------|
| `internal/reflect/reflect.go` | Add `ArrayInfo`, extend `BindingInfo` with mapped names, add `extractArrayInfo()`, modify `typeToString()` |
| `pkg/api/api.go` | Mirror new `ArrayInfo` type and extended `BindingInfo` fields |
| `internal/reflect/reflect_test.go` | Add tests for array bindings with original/mapped name verification |

---

## Design Decisions

1. **Runtime-sized arrays**: `elementCount` and `totalSize` are `null` (not -1 or 0)

2. **Nested arrays**: Supported via recursive `Array` field; `depth` field allows iterative parsing without recursion

3. **`elementStride` naming**: Explicitly named "stride" (not "size") to indicate it includes alignment padding — this is the value needed for buffer offset calculations

4. **Original vs mapped names**: Both provided at every level:
   - `name`/`nameMapped` for binding names
   - `type`/`typeMapped` for full type strings
   - `elementType`/`elementTypeMapped` for array element types
   - Struct field names use `name`/`nameMapped` pattern

5. **`elementLayout` placement**: Struct layout for array elements is nested inside `ArrayInfo`, not at the binding level — this clarifies that the layout describes the element type, not the array itself

6. **`depth` field**: Starts at 1 for the outermost array, increments for each nesting level. Allows consumers to pre-allocate or iterate without recursive parsing:
   ```js
   // Easy iteration without recursion
   let info = binding.array;
   while (info) {
     console.log(`Depth ${info.depth}: ${info.elementType}`);
     info = info.array;
   }
   ```

7. **`totalSize` field**: Precomputed convenience field (`elementCount * elementStride`) to avoid client-side multiplication; `null` for runtime-sized arrays

---

## Error Handling

- `evaluateConstExpr()` returns `(int, error)` — on error, `elementCount` and `totalSize` are set to `null`
- Unknown struct types result in `elementLayout: null` (struct not found in symbol table)
- Built-in types (f32, vec4f, etc.) have `elementTypeMapped` identical to `elementType`
