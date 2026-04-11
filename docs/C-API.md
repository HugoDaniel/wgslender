# Wgslender C API

A C-callable static library for WGSL minification, reflection, and validation.

## Building

```bash
zig build lib
# Produces: zig-out/lib/libwgslender.a and zig-out/include/wgslender.h
```

## Linking

```bash
cc -std=c11 -o myapp myapp.c -Izig-out/include zig-out/lib/libwgslender.a
```

For Rust, add to `build.rs`:
```rust
println!("cargo:rustc-link-lib=static=wgslender");
println!("cargo:rustc-link-search=native=path/to/zig-out/lib");
```

## Option Flags

### Minification flags (`wgslender_minify_c`)

| Flag | Value | Description |
|------|-------|-------------|
| `WGSLENDER_OPT_MINIFY_WHITESPACE` | `1 << 0` | Remove unnecessary whitespace |
| `WGSLENDER_OPT_MINIFY_IDENTIFIERS` | `1 << 1` | Rename identifiers to shorter names |
| `WGSLENDER_OPT_MINIFY_SYNTAX` | `1 << 2` | Simplify WGSL syntax |
| `WGSLENDER_OPT_TREE_SHAKING` | `1 << 3` | Remove dead code |
| `WGSLENDER_OPT_MANGLE_EXTERNAL` | `1 << 4` | Rename `@group/@binding` variables |
| `WGSLENDER_OPT_PRESERVE_UNIFORM_STRUCTS` | `1 << 5` | Keep struct names used in uniform blocks |
| `WGSLENDER_OPT_DEFAULT` | `0x0f` | Whitespace + identifiers + syntax + tree shaking |

### Validation flags (`wgslender_validate_c`)

| Flag | Value | Description |
|------|-------|-------------|
| `WGSLENDER_OPT_STRICT` | `1 << 0` | Enable strict mode |

## Result Types

### `WgslenderResult`

Returned by `wgslender_minify_c` and `wgslender_minify_json_c`.

| Field | Type | Description |
|-------|------|-------------|
| `code_ptr` | `const uint8_t *` | Minified WGSL text, or `NULL` on error |
| `code_len` | `uint32_t` | Length in bytes |
| `error` | `bool` | `true` if minification failed |

### `WgslenderValidateResult`

Returned by `wgslender_validate_c`.

| Field | Type | Description |
|-------|------|-------------|
| `valid` | `bool` | `true` if the shader is valid |
| `json_ptr` | `const uint8_t *` | JSON diagnostics, or `NULL` on alloc failure |
| `json_len` | `uint32_t` | JSON length in bytes |
| `error_count` | `uint32_t` | Number of errors found |

### `WgslenderJsonResult`

Returned by `wgslender_reflect_c`.

| Field | Type | Description |
|-------|------|-------------|
| `json_ptr` | `const uint8_t *` | JSON data, or `NULL` on error |
| `json_len` | `uint32_t` | JSON length in bytes |
| `error` | `bool` | `true` if reflection failed |

## Functions

### `wgslender_minify_c`

Minify WGSL source using bitflag options.

```c
WgslenderResult wgslender_minify_c(
    const uint8_t *source_ptr, uint32_t source_len,
    uint32_t flags);
```

### `wgslender_minify_json_c`

Minify WGSL source with JSON-encoded options (same keys as `wgslender.json` config files). Supports all options including `keepNames`, `sortDeclarations`, `scopeLocalRename`, and `sourceMap`.

```c
WgslenderResult wgslender_minify_json_c(
    const uint8_t *source_ptr, uint32_t source_len,
    const uint8_t *opts_ptr, uint32_t opts_len);
```

**Options JSON:**
```json
{
    "minifyWhitespace": true,
    "minifyIdentifiers": true,
    "minifySyntax": true,
    "treeShaking": true,
    "mangleExternalBindings": false,
    "preserveUniformStructTypes": false,
    "keepNames": ["uniformName"],
    "sortDeclarations": false,
    "scopeLocalRename": false,
    "sourceMap": false
}
```

### `wgslender_validate_c`

Validate WGSL source for semantic errors. Returns validity status and JSON diagnostics.

```c
WgslenderValidateResult wgslender_validate_c(
    const uint8_t *source_ptr, uint32_t source_len,
    uint32_t flags);
```

**Diagnostics JSON:**
```json
{
    "valid": false,
    "diagnostics": [{
        "severity": "error",
        "code": "E0200",
        "message": "cannot resolve 'oops'",
        "line": 2,
        "column": 12
    }],
    "errorCount": 1,
    "warningCount": 0
}
```

### `wgslender_reflect_c`

Extract binding layout, struct definitions, and entry point information from WGSL source.

```c
WgslenderJsonResult wgslender_reflect_c(
    const uint8_t *source_ptr, uint32_t source_len);
```

### `wgslender_free_c`

Free memory returned by wgslender functions. **Both pointer and length are required.**

```c
void wgslender_free_c(uint8_t *ptr, uint32_t len);
```

### `wgslender_version_c`

Return the library version string. The returned pointer is static — do **not** free it.

```c
const uint8_t *wgslender_version_c(uint32_t *len);
```

## Memory Management

- All result pointers (`code_ptr`, `json_ptr`) must be freed with `wgslender_free_c(ptr, len)` — **both pointer and length are required**.
- The pointer from `wgslender_version_c` is static and must **not** be freed.
- Input pointers (`source_ptr`, `opts_ptr`) are read-only and not freed by wgslender.
- Check `result.error` (or `!result.valid`) before accessing result data. When error is `true`, the pointer is `NULL` and nothing needs to be freed.

## Thread Safety

All functions are thread-safe. Each function creates its own arena allocator internally — there is no shared mutable state.

## Example

```c
#include <stdio.h>
#include <string.h>
#include "wgslender.h"

int main(void) {
    const char *source =
        "@vertex fn main() -> @builtin(position) vec4f {\n"
        "    return vec4f(0.0, 0.0, 0.0, 1.0);\n"
        "}\n";

    WgslenderResult r = wgslender_minify_c(
        (const uint8_t *)source, (uint32_t)strlen(source),
        WGSLENDER_OPT_DEFAULT);

    if (r.error) {
        fprintf(stderr, "minification failed\n");
        return 1;
    }

    printf("Minified (%u bytes): %.*s\n", r.code_len, r.code_len, r.code_ptr);
    wgslender_free_c((uint8_t *)r.code_ptr, r.code_len);
    return 0;
}
```

See [`examples/c/`](../examples/c/) for full working examples (minify, validate, reflect).
