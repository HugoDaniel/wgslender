# wgslender

WGSL minifier, validator, and reflection tool for WebGPU shaders - WebAssembly build.

This package provides a WASM build of [wgslender](https://github.com/HugoDaniel/wgslender) that runs in browsers and Node.js. Features >99% test coverage and validation against the Dawn Tint test suite.

## Installation

```bash
npm install wgslender
```

## Browser Usage

```html
<script src="node_modules/wgslender/wasm_exec.js"></script>
<script src="node_modules/wgslender/lib/browser.js"></script>
<script>
  (async () => {
    await wgslender.initialize({
      wasmURL: "node_modules/wgslender/wgslender.wasm",
    });

    const result = wgslender.minify(`
      @vertex fn main() -> @builtin(position) vec4f {
        return vec4f(0.0);
      }
    `);

    console.log(result.code);
    // "@vertex fn main()->@builtin(position) vec4f{return vec4f(0.0);}"
  })();
</script>
```

### ESM Usage

```javascript
import { initialize, minify } from "wgslender";

await initialize({ wasmURL: "/path/to/wgslender.wasm" });

const result = minify(source, {
  minifyWhitespace: true,
  minifyIdentifiers: true,
  minifySyntax: true,
});
```

## Node.js Usage

```javascript
const { initialize, minify } = require("wgslender");

await initialize(); // Automatically finds wgslender.wasm

const result = minify(source);
console.log(result.code);
```

## API

### `initialize(options)`

Initialize the WASM module. Must be called before `minify()`, `reflect()`,
`minifyAndReflect()`, or `validate()`.

```typescript
interface InitializeOptions {
  wasmURL?: string | URL; // Path or URL to wgslender.wasm
  wasmModule?: WebAssembly.Module; // Pre-compiled module
}
```

### `minify(source, options?)`

Minify WGSL source code.

```typescript
interface MinifyOptions {
  minifyWhitespace?: boolean; // Remove whitespace (default: true)
  minifyIdentifiers?: boolean; // Rename identifiers (default: true)
  minifySyntax?: boolean; // Optimize syntax (default: true)
  mangleExternalBindings?: boolean; // Mangle uniform/storage names (default: false)
  treeShaking?: boolean; // Remove unused declarations (default: true)
  preserveUniformStructTypes?: boolean; // Keep struct types used in uniforms (default: false)
  keepNames?: string[]; // Names to preserve from renaming
  sourceMap?: boolean; // Generate source map (default: false)
  sourceMapSources?: boolean; // Include source in sourcesContent (default: false)
}

interface MinifyResult {
  code: string; // Minified code
  errors: MinifyError[]; // Parse/minification errors
  originalSize: number; // Input size in bytes
  minifiedSize: number; // Output size in bytes
  sourceMap?: string; // Source map JSON (if sourceMap: true)
}
```

### `reflect(source)`

Extract binding information, struct layouts, and entry points from WGSL source.

```typescript
interface ReflectResult {
  bindings: BindingInfo[];
  structs: Record<string, StructLayout>;
  entryPoints: EntryPointInfo[];
  errors: string[];
}

interface BindingInfo {
  group: number;
  binding: number;
  name: string;
  addressSpace: string; // "uniform", "storage", "handle"
  accessMode?: string; // "read", "write", "read_write" (for storage)
  type: string;
  layout: StructLayout | null; // null for textures/samplers
}

interface StructLayout {
  size: number;
  alignment: number;
  fields: FieldInfo[];
}

interface FieldInfo {
  name: string;
  type: string;
  offset: number;
  size: number;
  alignment: number;
  layout?: StructLayout; // for nested structs
}

interface EntryPointInfo {
  name: string;
  stage: string; // "vertex", "fragment", "compute"
  workgroupSize: number[] | null; // [x, y, z] for compute, null otherwise
}
```

**Example:**

```javascript
const result = reflect(`
  struct Uniforms { time: f32, resolution: vec2<u32> }
  @group(0) @binding(0) var<uniform> u: Uniforms;
  @compute @workgroup_size(8, 8) fn main() {}
`);

console.log(result.bindings[0]);
// {
//   group: 0, binding: 0, name: "u",
//   addressSpace: "uniform", type: "Uniforms",
//   layout: {
//     size: 16, alignment: 8,
//     fields: [
//       { name: "time", type: "f32", offset: 0, size: 4, alignment: 4 },
//       { name: "resolution", type: "vec2<u32>", offset: 8, size: 8, alignment: 8 }
//     ]
//   }
// }

console.log(result.entryPoints[0]);
// { name: "main", stage: "compute", workgroupSize: [8, 8, 1] }
```

Memory layouts follow the WGSL specification:

- `vec3` has alignment=16 but size=12
- Struct members are aligned to their natural alignment
- Struct size is rounded up to struct alignment

### `minifyAndReflect(source, options?)`

Minify and reflect in a single WASM call. Equivalent to calling `minify()`
followed by `reflect(result.code)`, except the two passes share one parsed
module and renamer instead of reparsing the minified output — so `reflect`'s
names are guaranteed to match `minify`'s renaming, and you save a second
parse.

```typescript
interface MinifyAndReflectResult {
  minify: MinifyResult;
  reflect: ReflectResult;
}

function minifyAndReflect(source: string, options?: MinifyOptions): MinifyAndReflectResult;
```

`options` accepts the same `MinifyOptions` as `minify()`.

**Example:**

```javascript
const { minify: minified, reflect: info } = minifyAndReflect(`
  struct Uniforms { time: f32, resolution: vec2<u32> }
  @group(0) @binding(0) var<uniform> uniforms: Uniforms;
  @compute @workgroup_size(8, 8) fn main() { let t = uniforms.time; }
`, { minifyIdentifiers: true });

console.log(minified.code);
// struct a{time:f32,resolution:vec2<u32>}@group(0) @binding(0) var<uniform> uniforms:a;@compute @workgroup_size(8,8) fn main(){let t=uniforms.time;}

console.log(info.bindings[0].name, info.bindings[0].typeMapped);
// "uniforms" "a"  — external bindings keep their name by default; the type is renamed
```

### `validate(source, options?)`

Validate WGSL source for semantic errors, type mismatches, and uniformity
violations.

```typescript
interface ValidateOptions {
  strictMode?: boolean; // Treat warnings as errors
  diagnosticFilters?: Record<string, "error" | "warning" | "info" | "off">;
}

interface ValidateResult {
  valid: boolean; // true if no errors
  diagnostics: DiagnosticInfo[];
  errorCount: number;
  warningCount: number;
}

interface DiagnosticInfo {
  severity: "error" | "warning" | "info" | "note";
  code?: string; // e.g., "E0200"
  message: string;
  line: number; // 1-based
  column: number; // 1-based
  endLine?: number;
  endColumn?: number;
  specRef?: string; // WGSL spec reference
}
```

**Example:**

```javascript
const result = validate(`
  fn foo() -> f32 {
    var x: i32 = 1;
    return x;  // Error: returning i32 from f32 function
  }
`);

console.log(result.valid); // false
console.log(result.errorCount); // 1
console.log(result.diagnostics[0]);
// {
//   severity: "error",
//   code: "E0200",
//   message: "cannot return 'i32' from function returning 'f32'",
//   line: 4,
//   column: 5
// }
```

**With options:**

```javascript
const result = validate(source, {
  strictMode: true, // Treat warnings as errors
  diagnosticFilters: {
    derivative_uniformity: "off", // Disable uniformity warnings
  },
});
```

**Validation checks:**

- Type mismatches (assignments, returns, function calls)
- Undefined symbols (variables, functions, types)
- Invalid operations (operators, indexing, member access)
- Entry point requirements
- Uniformity analysis (textureSample, derivatives)
- WGSL spec compliance

### `isInitialized()`

Returns `true` if the WASM module is initialized.

### `version`

The version of the minifier.

## Options

### `minifyWhitespace`

Remove unnecessary whitespace and newlines.

### `minifyIdentifiers`

Rename local variables, function parameters, and helper functions to shorter
names. Entry points and API-facing declarations are preserved.

### `minifySyntax`

Apply syntax-level optimizations like numeric literal shortening.

### `mangleExternalBindings`

Control how `var<uniform>` and `var<storage>` names are handled:

- `false` (default): Original names are preserved in declarations, short aliases
  are used internally. This maintains compatibility with WebGPU's binding
  reflection APIs.
- `true`: Names are mangled directly for smaller output, but breaks binding
  reflection.

```javascript
// Input
const shader = `
@group(0) @binding(0) var<uniform> uniforms: f32;
fn getValue() -> f32 { return uniforms * 2.0; }
`;

// With mangleExternalBindings: false (default)
// Output: "@group(0) @binding(0) var<uniform> uniforms:f32;let a=uniforms;fn b()->f32{return a*2.0;}"

// With mangleExternalBindings: true
// Output: "@group(0) @binding(0) var<uniform> a:f32;fn b()->f32{return a*2.0;}"
```

### `treeShaking`

Enable dead code elimination to remove unused declarations (default: `true`):

```javascript
minify(source, {
  treeShaking: true, // Remove unreachable code
});
```

### `preserveUniformStructTypes`

Automatically preserve struct type names that are used in `var<uniform>` or
`var<storage>` declarations (default: `false`):

```javascript
// Input
const shader = `
struct MyUniforms { time: f32 }
@group(0) @binding(0) var<uniform> u: MyUniforms;
@fragment fn main() -> @location(0) vec4f { return vec4f(u.time); }
`;

// With preserveUniformStructTypes: false (default)
// struct MyUniforms -> struct a

// With preserveUniformStructTypes: true
// struct MyUniforms preserved
minify(source, {
  preserveUniformStructTypes: true,
});
```

This is particularly useful for frameworks like PNGine that detect builtin
uniforms by struct type name.

### `keepNames`

Array of identifier names that should not be renamed:

```javascript
minify(source, {
  minifyIdentifiers: true,
  keepNames: ["myHelper", "computeValue"],
});
```

### `sourceMap`

Generate a source map to debug minified shaders by mapping back to original
source:

```javascript
const result = minify(source, {
  minifyIdentifiers: true,
  sourceMap: true,
});

console.log(result.code);
// "const a=42;fn b()->i32{return a;}"

console.log(result.sourceMap);
// '{"version":3,"sources":[],"names":["longVariable","myFunction"],"mappings":"MAAAA,..."}'
```

The source map follows the
[Source Map v3 specification](https://sourcemaps.info/spec.html) and includes:

- `version`: Always 3
- `names`: Original names of renamed identifiers
- `mappings`: VLQ-encoded position mappings

### `sourceMapSources`

Include the original source code in the source map's `sourcesContent` field for
self-contained debugging:

```javascript
const result = minify(source, {
  sourceMap: true,
  sourceMapSources: true, // Embed original source
});

const map = JSON.parse(result.sourceMap);
console.log(map.sourcesContent);
// ["const longVariable = 42;\nfn myFunction() -> i32 { return longVariable; }"]
```

### Source Map Example: Complete Workflow

```javascript
import { initialize, minify } from "wgslender";

await initialize({ wasmURL: "/wgslender.wasm" });

const source = `
const longVariableName = 42;

fn helperFunction(value: i32) -> i32 {
    return value * 2;
}

@compute @workgroup_size(1)
fn main() {
    let result = helperFunction(longVariableName);
}
`;

const result = minify(source, {
  minifyWhitespace: true,
  minifyIdentifiers: true,
  sourceMap: true,
  sourceMapSources: true,
});

console.log("Minified code:");
console.log(result.code);
// "const a=42;fn b(c:i32)->i32{return c*2;}@compute @workgroup_size(1) fn main(){let d=b(a);}"

console.log("\nSource map:");
const map = JSON.parse(result.sourceMap);
console.log("Names:", map.names);
// Names: ["longVariableName", "helperFunction", "value", "result"]

// To use the source map inline:
const codeWithSourceMap = result.code +
  "\n//# sourceMappingURL=data:application/json;base64," +
  btoa(result.sourceMap);
```

## Using with Bundlers

### Vite

```javascript
import { initialize, minify } from "wgslender";
import wasmURL from "wgslender/wgslender.wasm?url";

await initialize({ wasmURL });
```

### Webpack

```javascript
import { initialize, minify } from "wgslender";

// Configure webpack to handle .wasm files
await initialize({ wasmURL: new URL("wgslender/wgslender.wasm", import.meta.url) });
```

## Pre-compiling WASM

For better performance when creating multiple instances:

```javascript
const wasmModule = await WebAssembly.compileStreaming(
  fetch("/wgslender.wasm"),
);

// Share module across workers
await initialize({ wasmModule });
```

## Refactoring API

The analyzer that powers the WGSL language server is exposed as pure
functions, so any editor or build tool can drive find-references, rename,
and structural edits without spawning a full LSP session. All offsets are
**UTF-8 byte offsets** into the source.

Every function returns a result object with an optional `error` string —
no exceptions are thrown for user input. `*Apply` variants always return
a usable `source` field (the original text on failure) so you can use
the return value as a drop-in replacement either way.

### Cursor-based operations

```typescript
findReferences(source, offset, includeDeclaration?): FindReferencesResult
rename(source, offset, newName): RenameResult
renameApply(source, offset, newName): RenameApplyResult
```

```javascript
import { findReferences, renameApply } from "wgslender";

const { references } = findReferences(source, cursorByteOffset);
// [{ start: 12, end: 15, isWrite: true }, { start: 42, end: 45, isWrite: false }, ...]

const { ok, source: next, edits } = renameApply(source, cursorByteOffset, "newName");
```

### Stable identifiers

Stable IDs are deterministic strings like `v1:fn:main/block#0/let:x` that
identify a symbol independently of its text position. They survive
reparses and edits that don't move the declaration across a block scope,
so you can cache them across keystrokes.

```typescript
stableIdAtOffset(source, offset): { stableId: string | null, error?: string }
locateStableId(source, stableId): { start: number | null, end: number | null, error?: string }
locateDeclaration(source, stableId): { start, end }   // full decl (attributes + trailing `;`/`}`)
locateType(source, stableId): { start, end }          // just the `: T` annotation
```

```typescript
renameByStableId(source, stableId, newName): RenameResult
removeDeclarationByStableId(source, stableId): RenameResult
removeDeclarationApplyByStableId(source, stableId): RenameApplyResult
changeTypeByStableId(source, stableId, newType): RenameResult
changeTypeApplyByStableId(source, stableId, newType): RenameApplyResult
```

```javascript
import { stableIdAtOffset, changeTypeApplyByStableId } from "wgslender";

const { stableId } = stableIdAtOffset(source, cursorByteOffset);
const { source: next } = changeTypeApplyByStableId(source, stableId, "vec3<f32>");
```

`locateType` works on struct members, function parameters, function return
types (pass the function's stable ID), and `var`/`const`/`let`/`override`
declarations with an explicit `: T` annotation.

### Error strings

| Code | Meaning |
|------|---------|
| `"parse error"` | Source didn't parse — the edit couldn't be computed |
| `"symbol not found"` | Offset is not over a renameable symbol, or the stable ID doesn't resolve |
| `"invalid identifier"` | `newName` is empty, a keyword, reserved, starts with `__`, or contains bad chars |

## Performance

- WASM binary: ~3.6MB
- Initialization: ~100ms (first load)
- Transform: <1ms for typical shaders

## License

CC0 - Public Domain
