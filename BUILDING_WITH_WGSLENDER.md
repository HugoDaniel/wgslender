# Building with wgslender - LLM Reference

Quick reference for AI agents integrating the wgslender WGSL minifier.

## Decision Tree: Which Options?

```
Need smallest output?
├─ Yes: Full minification (default)
│   └─ Breaking reflection APIs?
│       ├─ OK: --mangle-external-bindings (extra ~5% reduction)
│       └─ No: Keep default (mangleExternalBindings: false)
└─ No: --no-mangle (whitespace + syntax only)

Framework detects uniforms by struct TYPE name?
├─ Yes: --preserve-uniform-struct-types
└─ No: Skip (struct types will be renamed)

Have platform-specific bindings/helpers?
├─ Yes: Use --keep-names or config file
└─ No: Default is fine

Need to debug minified shaders?
├─ Yes: --source-map (external file) or --source-map-inline
│   └─ Want self-contained map?
│       ├─ Yes: Add --source-map-sources
│       └─ No: Skip (smaller map file)
└─ No: Skip source maps
```

## API Surfaces

### CLI
```bash
wgslender input.wgsl -o output.wgsl          # File to file
cat input.wgsl | wgslender > output.wgsl     # Pipe
wgslender --config myconfig.json input.wgsl  # With config
wgslender reflect input.wgsl                 # Reflect to JSON
wgslender reflect --compact input.wgsl       # Compact JSON
wgslender validate input.wgsl                # Validate shader
wgslender validate --json input.wgsl         # Validation JSON
```

### Node.js/Browser (WASM)
```javascript
import { initialize, minify, reflect, validate, minifyAndReflect } from 'wgslender';
await initialize();  // Required once, auto-finds WASM in Node

// Minification
const result = minify(source, options);
// result: { code, errors[], originalSize, minifiedSize, sourceMap? }

// Reflection (extract bindings, structs, entry points)
const info = reflect(source);
// info: { bindings[], structs{}, entryPoints[], errors[] }

// Semantic validation
const valid = validate(source, { strictMode: false });
// valid: { valid, diagnostics[], errorCount, warningCount }

// Combined minify + reflect (with minified names)
const combined = minifyAndReflect(source, options);
// combined: { code, reflect: { bindings[], structs{}, ... } }
```

### Go
```go
import "github.com/HugoDaniel/wgslender/pkg/api"
result := api.Minify(source)                    // Full minification
result := api.MinifyWhitespaceOnly(source)      // Safe mode
result := api.MinifyWithOptions(source, opts)   // Custom
info := api.Reflect(source)                     // Shader reflection
combined := api.MinifyAndReflect(source)        // Minify + reflect with mapped names
valid := api.Validate(source)                   // Semantic validation
valid := api.ValidateWithOptions(source, opts)  // Validation with options
```

### C Library (FFI)

Build: `make lib` → `build/libwgslender.a` + `build/libwgslender.h`

#### Function Signatures

```c
#include "libwgslender.h"

// Minify WGSL source code
// Returns: 0=success, 1=json_encode_failed, 2=null_input
int wgslender_minify(
    const char* source,      // WGSL source (not null-terminated required)
    int source_len,          // Length of source in bytes
    const char* options,     // JSON options (nullable)
    int options_len,         // Length of options (0 if null)
    char** out_code,         // Output: minified WGSL (caller must free)
    int* out_code_len,       // Output: length of minified code
    char** out_json,         // Output: result JSON (caller must free)
    int* out_json_len        // Output: length of JSON
);

// Reflect on WGSL source (extract bindings, structs, entry points)
// Returns: 0=success, 1=json_encode_failed, 2=null_input
int wgslender_reflect(
    const char* source,      // WGSL source
    int source_len,          // Length of source
    char** out_json,         // Output: reflection JSON (caller must free)
    int* out_json_len        // Output: length of JSON
);

// Minify and reflect in one call (includes mapped identifier names)
// Returns: 0=success, 1=json_encode_failed, 2=null_input
int wgslender_minify_and_reflect(
    const char* source,      // WGSL source
    int source_len,          // Length of source
    const char* options,     // JSON options (nullable)
    int options_len,         // Length of options (0 if null)
    char** out_code,         // Output: minified WGSL (caller must free)
    int* out_code_len,       // Output: length of minified code
    char** out_json,         // Output: reflection JSON (caller must free)
    int* out_json_len        // Output: length of JSON
);

// Semantic validation
// Returns: 0=success, 1=json_encode_failed, 2=null_input
int wgslender_validate(
    const char* source,      // WGSL source
    int source_len,          // Length of source
    const char* options,     // JSON options (nullable)
    int options_len,         // Length of options (0 if null)
    char** out_json,         // Output: validation JSON (caller must free)
    int* out_json_len        // Output: length of JSON
);

// Free memory allocated by wgslender functions
void wgslender_free(void* ptr);

// Get library version (static string, do NOT free)
const char* wgslender_version(void);
```

#### Memory Ownership

- All `out_*` parameters are allocated by wgslender (Go heap)
- Caller MUST call `wgslender_free()` on returned pointers
- Do NOT use `free()` - memory is managed by Go runtime
- Do NOT access memory after calling `wgslender_free()`

#### Reflection JSON Format

```json
{
  "bindings": [{
    "group": 0,
    "binding": 0,
    "name": "uniforms",
    "nameMapped": "a",           // Only with minify_and_reflect
    "addressSpace": "uniform",   // "uniform" or "storage"
    "type": "Uniforms",
    "typeMapped": "b",           // Only with minify_and_reflect
    "layout": {
      "size": 16,
      "alignment": 16,
      "fields": [{
        "name": "time",
        "type": "f32",
        "offset": 0,
        "size": 4,
        "alignment": 4
      }]
    },
    "array": {                   // Present for array types
      "elementType": "Particle",
      "elementTypeMapped": "c",  // Only with minify_and_reflect
      "elementStride": 32,
      "elementCount": 1000,      // null for runtime-sized
      "elementLayout": { ... }   // Layout of element struct
    }
  }],
  "structs": {
    "Uniforms": { "size": 16, "alignment": 16, "fields": [...] }
  },
  "entryPoints": [{
    "name": "main",
    "stage": "compute",          // "vertex", "fragment", or "compute"
    "workgroupSize": [64, 1, 1]  // Only for compute
  }],
  "errors": [{                   // Parse errors (if any)
    "message": "unexpected token",
    "line": 5,
    "column": 12
  }]
}
```

#### Basic Usage

```c
#include "libwgslender.h"
#include <stdio.h>
#include <string.h>

int main() {
    const char* source = "@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.); }";
    char *code = NULL, *json = NULL;
    int code_len = 0, json_len = 0;

    // Minify with default options
    int err = wgslender_minify(source, strlen(source), NULL, 0,
                             &code, &code_len, &json, &json_len);
    if (err == 0) {
        printf("Minified (%d bytes): %.*s\n", code_len, code_len, code);
        wgslender_free(code);
        wgslender_free(json);
    }

    // Reflection only
    err = wgslender_reflect(source, strlen(source), &json, &json_len);
    if (err == 0) {
        printf("Reflection: %.*s\n", json_len, json);
        wgslender_free(json);
    }

    return 0;
}
```

Link with: `gcc -o myapp myapp.c -L./build -lwgslender -lpthread -lm`

## Options Reference

| Option | Default | Effect | When to Change |
|--------|---------|--------|----------------|
| `minifyWhitespace` | true | Remove spaces/newlines | Rarely disable |
| `minifyIdentifiers` | true | Rename locals/helpers | Disable for debugging |
| `minifySyntax` | true | `vec3<f32>`→`vec3f`, `.5`→`0.5` | Rarely disable |
| `treeShaking` | true | Remove unused code | Disable if DCE breaks code |
| `mangleExternalBindings` | false | Rename uniform/storage vars | Enable for max compression |
| `preserveUniformStructTypes` | false | Keep struct types in uniforms | Enable for PNGine-like frameworks |
| `keepNames` | [] | Preserve specific identifiers | Platform bindings, debugging |
| `sourceMap` | false | Generate v3 source map | Debugging minified shaders |
| `sourceMapSources` | false | Embed original source in map | Self-contained debugging |

## What Gets Preserved (Always)

- Entry points: `@vertex fn main()`, `@fragment fn draw()`, `@compute fn calc()`
- Builtin names: `position`, `vertex_index`, `global_invocation_id`
- Override constants: `override size: u32 = 64`
- Struct field names: `.time`, `.position` (accessed via `.`, not renamed)
- Binding indices: `@group(0) @binding(1)` numbers unchanged

## What Gets Renamed

- Local variables: `let myValue` → `let a`
- Function parameters: `fn calc(inputVal: f32)` → `fn calc(a: f32)`
- Helper functions: `fn computeNormal()` → `fn a()`
- Struct type names: `struct MyData` → `struct a` (unless preserved)
- Type aliases: `alias Vec3 = vec3<f32>` → `alias a = vec3f`

## Config File Format

Config auto-discovered as `wgslender.json` or `.wgslenderrc` in cwd or parents.

```json
{
  "minifyWhitespace": true,
  "minifyIdentifiers": true,
  "minifySyntax": true,
  "mangleExternalBindings": false,
  "treeShaking": true,
  "preserveUniformStructTypes": false,
  "keepNames": ["customHelper", "MyStructType"]
}
```

## Platform Presets

### compute.toys
```bash
wgslender --config configs/compute.toys.json shader.wgsl
```
Preserves: `time`, `mouse`, `screen`, `pass_in/out`, `channel0/1`, samplers, type aliases, `main_image`

### PNGine
```bash
wgslender --config configs/pngine.json shader.wgsl
```
Preserves uniform struct types + `PngineInputs`, `TimeInputs`, `CanvasInputs`, etc.

## Common Patterns

### Pattern 1: Build Pipeline Integration
```bash
# In build script
for f in src/shaders/*.wgsl; do
  wgslender "$f" -o "dist/shaders/$(basename "$f" .wgsl).min.wgsl"
done
```

### Pattern 2: Runtime Minification (Browser)
```javascript
// Minify shader before compilation
const minified = minify(shaderSource, { minifyWhitespace: true });
if (minified.errors.length > 0) throw new Error(minified.errors[0].message);
const module = device.createShaderModule({ code: minified.code });
```

### Pattern 3: Preserve Reflection Compatibility
```javascript
// Default behavior - uniform names preserved for getPipelineLayout()
const result = minify(source); // mangleExternalBindings: false by default
// var<uniform> myUniforms stays as myUniforms in declaration
```

### Pattern 4: Maximum Compression
```javascript
const result = minify(source, {
  minifyWhitespace: true,
  minifyIdentifiers: true,
  minifySyntax: true,
  mangleExternalBindings: true,  // Breaks reflection
  treeShaking: true
});
```

### Pattern 5: Debug-Friendly Minification
```javascript
const result = minify(source, {
  minifyWhitespace: true,
  minifyIdentifiers: false,  // Keep readable names
  minifySyntax: true
});
```

### Pattern 6: Source Maps for Debugging
```bash
# CLI: Generate external .map file
wgslender -o shader.min.wgsl --source-map shader.wgsl

# CLI: Inline source map as data URI
wgslender --source-map-inline shader.wgsl > shader.min.wgsl

# CLI: Include original source in map
wgslender -o out.wgsl --source-map --source-map-sources shader.wgsl
```

```javascript
// JS/WASM: Generate source map
const result = minify(source, {
  sourceMap: true,
  sourceMapSources: true  // Optional: embed source
});
console.log(result.sourceMap);  // JSON string
// '{"version":3,"names":["originalName"],"mappings":"..."}'

// Inline source map for browser DevTools
const code = result.code + '\n//# sourceMappingURL=data:application/json;base64,' + btoa(result.sourceMap);
```

```go
// Go API: Generate source map
result := api.MinifyWithOptions(source, api.MinifyOptions{
    SourceMap: true,
    SourceMapOptions: api.SourceMapOptions{
        File: "out.min.wgsl",
        SourceName: "input.wgsl",
        IncludeSource: true,
    },
})
fmt.Println(result.SourceMap)     // JSON string
fmt.Println(result.SourceMapDataURI)  // data:application/json;base64,...
```

### Pattern 7: WebGPU Error Translation
WebGPU doesn't natively consume source maps, but you can translate `GPUCompilationMessage` positions back to original source:

```javascript
import { SourceMapConsumer } from 'source-map';

const result = minify(source, { sourceMap: true, sourceMapSources: true });
const module = device.createShaderModule({ code: result.code });
const info = await module.getCompilationInfo();

const consumer = await new SourceMapConsumer(JSON.parse(result.sourceMap));
for (const msg of info.messages) {
  if (msg.lineNum > 0) {
    const pos = consumer.originalPositionFor({
      line: msg.lineNum,
      column: msg.linePos - 1  // source-map uses 0-based columns
    });
    console.log(`${pos.source}:${pos.line}:${pos.column + 1} - ${msg.message}`);
  }
}
```

### Pattern 8: Shader Reflection for Buffer Layout
Use `reflect()` to get memory layouts for creating typed array views:

```javascript
const info = reflect(source);
const binding = info.bindings.find(b => b.name === 'uniforms');
if (binding?.layout) {
  const buffer = device.createBuffer({
    size: binding.layout.size,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
  });
  // Use field offsets to write data
  for (const field of binding.layout.fields) {
    console.log(`${field.name}: offset=${field.offset}, size=${field.size}`);
  }
}
```

### Pattern 9: Array Buffer Layout with Stride
For storage buffers with array types, use `array` metadata for proper stride calculation:

```javascript
const info = reflect(source);
const binding = info.bindings.find(b => b.name === 'particles');
if (binding?.array) {
  const { elementStride, elementCount, elementLayout } = binding.array;
  console.log(`Element stride: ${elementStride} bytes`);
  if (elementCount) {
    console.log(`Total size: ${elementCount * elementStride} bytes`);
  }
  // Access struct fields within each element
  if (elementLayout) {
    for (const field of elementLayout.fields) {
      console.log(`  ${field.name}: offset=${field.offset}`);
    }
  }
}
```

### Pattern 10: Minify with Reflection for Dynamic Binding
When you need both minified code and struct layout with minified names:

```javascript
const result = minifyAndReflect(source);

// Use minified code
const module = device.createShaderModule({ code: result.code });

// Get binding info with mapped names
for (const binding of result.reflect.bindings) {
  console.log(`${binding.name} -> ${binding.nameMapped}`);
  console.log(`${binding.type} -> ${binding.typeMapped}`);
  if (binding.array) {
    console.log(`Element: ${binding.array.elementType} -> ${binding.array.elementTypeMapped}`);
  }
}
```

### Pattern 11: Extract Entry Points and Workgroup Size
```javascript
const info = reflect(source);
for (const ep of info.entryPoints) {
  if (ep.stage === 'compute' && ep.workgroupSize) {
    console.log(`${ep.name}: workgroup_size(${ep.workgroupSize.join(', ')})`);
  }
}
```

### Pattern 12: Pre-Minification Validation
```javascript
// Validate before minifying to catch semantic errors
const validation = validate(source);
if (!validation.valid) {
  for (const d of validation.diagnostics) {
    console.error(`${d.line}:${d.column}: ${d.severity}: ${d.message}`);
  }
  throw new Error('Shader validation failed');
}

// Safe to minify
const result = minify(source);
```

### Pattern 13: Suppress Specific Warnings
```javascript
// Disable uniformity warnings for shaders that intentionally violate
const result = validate(source, {
  diagnosticFilters: {
    derivative_uniformity: 'off',  // Disable derivative uniformity checks
  }
});
```

### Pattern 14: Strict Validation Mode
```javascript
// Treat all warnings as errors
const result = validate(source, { strictMode: true });
if (!result.valid) {
  // Both errors AND warnings will cause valid=false
}
```

### Pattern 15: C/Zig FFI Integration
```c
// Build: make lib
// Link: gcc -o myapp myapp.c -L./build -lwgslender -lpthread -lm

#include "libwgslender.h"

const char* source = "@vertex fn main() -> @builtin(position) vec4f { return vec4f(0.); }";
char *code = NULL, *json = NULL;
int code_len = 0, json_len = 0;

// Use custom options via JSON
const char* opts = "{\"minifyWhitespace\":true,\"minifyIdentifiers\":true}";
int err = wgslender_minify(
    (char*)source, strlen(source),
    (char*)opts, strlen(opts),
    &code, &code_len,
    &json, &json_len
);

if (err == 0) {
    printf("Minified: %.*s\n", code_len, code);
    wgslender_free(code);
    wgslender_free(json);
}
```

```zig
// Zig FFI example (simplified from PNGine's wgslender_ffi.zig)
const c = @cImport({
    @cInclude("libwgslender.h");
});

/// Result wrapper for FFI calls. Holds C-allocated memory.
pub const FfiResult = struct {
    json: []const u8,

    pub fn deinit(self: *FfiResult) void {
        c.wgslender_free(@ptrCast(@constCast(self.json.ptr)));
        self.* = undefined;
    }
};

/// Reflect on WGSL source. Caller must call result.deinit().
pub fn reflectFfi(source: []const u8) !FfiResult {
    var out_json: [*c]u8 = undefined;
    var out_len: c_int = 0;

    const result = c.wgslender_reflect(
        @ptrCast(@constCast(source.ptr)),
        @intCast(source.len),
        &out_json,
        &out_len,
    );

    return switch (result) {
        0 => FfiResult{ .json = out_json[0..@intCast(out_len)] },
        1 => error.JsonEncodeFailed,
        2 => error.NullInput,
        else => error.UnknownError,
    };
}

// Usage:
// var result = try reflectFfi(wgsl_source);
// defer result.deinit();
// // Parse result.json...
```

**Zig Build Integration** (build.zig):
```zig
// Add wgslender library to your module
const wgslender_lib = b.option([]const u8, "wgslender-lib", "Path to libwgslender.a");
if (wgslender_lib) |lib_path| {
    module.addObjectFile(.{ .cwd_relative = lib_path });
    module.addIncludePath(.{ .cwd_relative = "path/to/wgslender/build" });
    module.link_libc = true;
    if (target.result.os.tag == .macos) {
        module.linkFramework("CoreFoundation", .{});
        module.linkFramework("Security", .{});
    }
    module.linkSystemLibrary("pthread", .{});
}
```

## Gotchas & Edge Cases

### 1. Struct Fields Are Never Renamed
```wgsl
// Input
struct Data { value: f32 }
fn get(d: Data) -> f32 { return d.value; }

// Output (note: .value preserved, but 'd' renamed)
struct a{value:f32}fn b(c:a)->f32{return c.value;}
```
**Why**: WGSL accesses fields via `.member` syntax which cannot be safely renamed without whole-program analysis across shader/host boundary.

### 2. External Binding Aliasing
```wgsl
// Input
@group(0) @binding(0) var<uniform> uniforms: Data;
fn main() { return uniforms.x + uniforms.y; }

// Output (default: mangleExternalBindings=false)
@group(0) @binding(0) var<uniform> uniforms:a;let b=uniforms;fn main(){return b.x+b.y;}

// Output (mangleExternalBindings=true)
@group(0) @binding(0) var<uniform> a:b;fn main(){return a.x+a.y;}
```
**Why**: WebGPU reflection APIs use variable names. Default preserves them via alias indirection.

### 3. Tree Shaking Removes Unused Code
```wgsl
// Input
fn unused() -> f32 { return 1.0; }
fn used() -> f32 { return 2.0; }
@fragment fn main() -> @location(0) vec4f { return vec4f(used()); }

// Output (unused() removed entirely)
fn a()->f32{return 2.;}@fragment fn main()->@location(0) vec4f{return vec4f(a());}
```
**Disable with**: `--no-tree-shaking` if code is dynamically referenced.

### 4. preserveUniformStructTypes Only Preserves Direct Types
```wgsl
// Input
struct Inner { x: f32 }
struct Outer { inner: Inner }
@group(0) @binding(0) var<uniform> u: Outer;

// Output (Inner renamed, Outer preserved)
struct a{x:f32}struct Outer{inner:a}...
```
Only the struct type directly in `var<uniform>` declaration is preserved, not nested types.

### 5. Entry Points Must Have Attributes
```wgsl
// This function WON'T be treated as entry point (no attribute)
fn main() -> vec4f { return vec4f(0.0); }  // Gets renamed!

// This WILL be preserved
@fragment fn main() -> @location(0) vec4f { return vec4f(0.0); }
```

### 6. Override Constants Are Never Renamed
```wgsl
override workgroupSize: u32 = 64;  // Name preserved (API-facing)
const localSize: u32 = 32;         // Gets renamed (internal)
```

### 7. Syntax Optimization Shortens Numbers
```wgsl
// Input
let x = vec3<f32>(0.5, 1.0, 1000000.0);

// Output
let a=vec3f(.5,1.,1e6);
```
`vec3<f32>` → `vec3f`, `0.5` → `.5`, `1.0` → `1.`, `1000000.0` → `1e6`

## Error Handling

```javascript
const result = minify(source);
if (result.errors.length > 0) {
  // Parse error - result.code contains original source
  console.error(result.errors[0].message);
  // Use original source as fallback
}
```

Minifier returns original source on parse errors, never partial/corrupted output.

## Size Reduction Expectations

| Mode | Typical Reduction |
|------|-------------------|
| Whitespace only | 25-35% |
| Full (default) | 55-65% |
| Full + mangle bindings | 60-70% |

## Build Outputs

```bash
make build        # Native binary: build/wgslender
make build-wasm   # WASM: build/wgslender.wasm (~3.6MB)
make lib          # C static library: build/libwgslender.a + libwgslender.h
make build-all    # All platforms + WASM
```

WASM requires `wasm_exec.js` from Go toolchain (included in npm package).

C library requires CGO. Link with: `-lwgslender -lpthread -lm`
