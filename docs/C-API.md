# Wgslender C API

A C-callable static library for WGSL minification, reflection, and validation.

The reference usage is [`examples/c/`](../examples/c/) — ten programs covering
minify, validate, reflect, lint, rename, refactor and compile, kept honest by
`make -C examples/c test`. Prefer copying from there over copying from here:
those compile and run on every change.

## Building

```bash
zig build lib
# Produces: zig-out/lib/libwgslender.a and zig-out/include/wgslender.h
```

The archive is built as position-independent code, so it can be linked into a
shared library as well as an executable. The Rust package depends on that: its
proc-macro crate is a shared object with this archive inside. `zig build
lib-pic-check` proves the property by linking the archive into a shared object
for x86_64 and aarch64 Linux.

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

**Both minify entry points return plain text**, not a JSON envelope: no
`errors[]`, no original/minified size counters, no source map — measure the
sizes yourself. This differs from the WASM/npm surface, where `minify()` hands
back the envelope. In C the envelope exists only behind
`wgslender_minify_and_reflect_c` — declared in `wgslender.h`, demonstrated in
[`examples/c/minify_and_reflect.c`](../examples/c/minify_and_reflect.c), and
not yet written up below.

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

Minify WGSL source with JSON-encoded options (same keys as `wgslender.json` config files). Supports all options including `keepNames`, `sortDeclarations`, `scopeLocalRename`, and `sourceMap`. The bitflag word is frozen at the options it shipped with, so anything added since is reachable only this way.

**Malformed options JSON does not fail** — it falls back to the defaults
silently, so a typo'd key is a minification that quietly ignores you.

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

### Refactoring functions

The same analyzer that powers the WGSL language server is exposed as
stateless C functions. All offsets are **UTF-8 byte offsets** into the
source and every function returns `WgslenderJsonResult` — the `json_ptr`
is a JSON object that always includes the requested output field(s) and,
on failure, an `"error"` string. The buffer must be freed with
`wgslender_free_c(result.json_ptr, result.json_len)`.

#### `wgslender_find_references_c`

Find every use of the symbol under `offset`. `include_declaration` is
`0` or `1`.

```c
WgslenderJsonResult wgslender_find_references_c(
    const uint8_t *source_ptr, uint32_t source_len,
    uint32_t offset,
    uint32_t include_declaration);
```

Returns `{"references":[{"start":N,"end":N,"isWrite":bool}, ...]}`, or
`{"references":[]}` if no symbol is under the offset.

#### `wgslender_rename_c`

Compute the text edits that rename the symbol at `offset` to `new_name`.

```c
WgslenderJsonResult wgslender_rename_c(
    const uint8_t *source_ptr, uint32_t source_len,
    uint32_t offset,
    const uint8_t *new_name_ptr, uint32_t new_name_len);
```

Returns `{"edits":[{"start":N,"end":N,"newText":"..."}, ...]}` on success
or `{"edits":[],"error":"..."}` on failure. Possible error strings:
`"parse error"`, `"symbol not found"`, `"invalid identifier"` (keyword,
reserved, `__`-prefixed, empty, or containing bad characters).

#### `wgslender_rename_apply_c`

Same as `wgslender_rename_c` but also returns the rewritten source.

```c
WgslenderJsonResult wgslender_rename_apply_c(
    const uint8_t *source_ptr, uint32_t source_len,
    uint32_t offset,
    const uint8_t *new_name_ptr, uint32_t new_name_len);
```

Returns `{"ok":true,"source":"<rewritten>","edits":[...]}` on success or
`{"ok":false,"source":"<original>","edits":[],"error":"..."}` on failure.
The `source` field is always present so callers can use the response
uniformly.

#### Stable identifiers

Stable IDs are strings like `v1:fn:main/block#0/let:x` that identify a
symbol independently of its text position. They survive reparses and
edits that do not reorder or insert a `.block` scope at or above the
symbol's declaration, so callers can cache them across keystrokes.

```c
/* Resolve cursor offset → stable ID. */
WgslenderJsonResult wgslender_stable_id_at_offset_c(
    const uint8_t *source_ptr, uint32_t source_len,
    uint32_t offset);
/* → {"stableId":"v1:fn:main/block#0/let:x"}  or  {"stableId":null,"error":"..."} */

/* Resolve stable ID → declaration byte range. */
WgslenderJsonResult wgslender_locate_stable_id_c(
    const uint8_t *source_ptr, uint32_t source_len,
    const uint8_t *id_ptr, uint32_t id_len);
/* → {"start":N,"end":N}  or  {"start":null,"end":null,"error":"..."} */

/* Rename by stable ID — same JSON shape as wgslender_rename_c. */
WgslenderJsonResult wgslender_rename_by_id_c(
    const uint8_t *source_ptr, uint32_t source_len,
    const uint8_t *id_ptr, uint32_t id_len,
    const uint8_t *new_name_ptr, uint32_t new_name_len);
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
