/*
 * wgslender.h — C API for the wgslender WGSL minifier.
 *
 * Build the static library with: zig build lib
 * Link with: cc myapp.c -Iinclude zig-out/lib/libwgslender.a
 */

#ifndef WGSLENDER_H
#define WGSLENDER_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Option flags for wgslender_minify_c ────────────────────────── */

#define WGSLENDER_OPT_MINIFY_WHITESPACE        (1u << 0)
#define WGSLENDER_OPT_MINIFY_IDENTIFIERS       (1u << 1)
#define WGSLENDER_OPT_MINIFY_SYNTAX            (1u << 2)
#define WGSLENDER_OPT_TREE_SHAKING             (1u << 3)
#define WGSLENDER_OPT_MANGLE_EXTERNAL          (1u << 4)
#define WGSLENDER_OPT_PRESERVE_UNIFORM_STRUCTS (1u << 5)

/* All standard minification options enabled. */
#define WGSLENDER_OPT_DEFAULT \
    (WGSLENDER_OPT_MINIFY_WHITESPACE | \
     WGSLENDER_OPT_MINIFY_IDENTIFIERS | \
     WGSLENDER_OPT_MINIFY_SYNTAX | \
     WGSLENDER_OPT_TREE_SHAKING)

/* ── Option flags for wgslender_validate_c ──────────────────────── */

#define WGSLENDER_OPT_STRICT (1u << 0)

/* ── Result types ───────────────────────────────────────────────── */

typedef struct {
    const uint8_t *code_ptr; /* Minified WGSL text (NULL on error). */
    uint32_t       code_len;
    bool           error;
} WgslenderResult;

typedef struct {
    bool           valid;
    const uint8_t *json_ptr; /* JSON diagnostics (NULL on alloc failure). */
    uint32_t       json_len;
    uint32_t       error_count;
} WgslenderValidateResult;

typedef struct {
    const uint8_t *json_ptr; /* JSON data (NULL on error). */
    uint32_t       json_len;
    bool           error;
} WgslenderJsonResult;

/* ── Functions ──────────────────────────────────────────────────── */

/**
 * Minify WGSL source using bitflag options.
 * Free result.code_ptr with wgslender_free_c(result.code_ptr, result.code_len).
 */
WgslenderResult wgslender_minify_c(
    const uint8_t *source_ptr, uint32_t source_len,
    uint32_t flags);

/**
 * Minify WGSL source with JSON options (same keys as wgslender.json config).
 * Free result.code_ptr with wgslender_free_c(result.code_ptr, result.code_len).
 */
WgslenderResult wgslender_minify_json_c(
    const uint8_t *source_ptr, uint32_t source_len,
    const uint8_t *opts_ptr, uint32_t opts_len);

/**
 * Validate WGSL source. Returns validity status and JSON diagnostics.
 * Free result.json_ptr with wgslender_free_c(result.json_ptr, result.json_len).
 */
WgslenderValidateResult wgslender_validate_c(
    const uint8_t *source_ptr, uint32_t source_len,
    uint32_t flags);

/**
 * Reflect WGSL source. Returns JSON with bindings, structs, and entry points.
 * Free result.json_ptr with wgslender_free_c(result.json_ptr, result.json_len).
 */
WgslenderJsonResult wgslender_reflect_c(
    const uint8_t *source_ptr, uint32_t source_len);

/**
 * Find all references to the symbol under `offset` in `source_ptr`.
 * `offset` is a UTF-8 byte offset. `include_declaration` is 0 or 1.
 * Returns JSON: {"references":[{"start":N,"end":N,"isWrite":bool},...]}
 * or {"references":[],"error":"..."} on parse failure, or
 *    {"references":[]} if no symbol is under the offset.
 * Free result.json_ptr with wgslender_free_c.
 */
WgslenderJsonResult wgslender_find_references_c(
    const uint8_t *source_ptr, uint32_t source_len,
    uint32_t offset,
    uint32_t include_declaration);

/**
 * Compute text edits that rename the symbol at `offset` to `new_name`.
 * Returns JSON: {"edits":[{"start":N,"end":N,"newText":"..."}, ...]}
 * or {"edits":[],"error":"..."} on failure. Possible errors:
 *   - "invalid identifier" — new_name is a keyword, reserved word,
 *     starts with __, contains bad chars, or is empty
 *   - "symbol not found" — offset is not over a symbol
 *   - "parse error"
 * Free result.json_ptr with wgslender_free_c.
 */
WgslenderJsonResult wgslender_rename_c(
    const uint8_t *source_ptr, uint32_t source_len,
    uint32_t offset,
    const uint8_t *new_name_ptr, uint32_t new_name_len);

/**
 * Rename-and-apply: returns the rewritten source plus the edit list.
 * Returns JSON:
 *   {"ok":true,"source":"<rewritten>","edits":[...]}
 * on success, or
 *   {"ok":false,"source":"<original>","edits":[],"error":"..."}
 * on failure. The `source` field is always present so callers can
 * use the response uniformly.
 * Free result.json_ptr with wgslender_free_c.
 */
WgslenderJsonResult wgslender_rename_apply_c(
    const uint8_t *source_ptr, uint32_t source_len,
    uint32_t offset,
    const uint8_t *new_name_ptr, uint32_t new_name_len);

/**
 * Free memory returned by wgslender functions.
 * Both ptr and len must come from a result struct.
 */
void wgslender_free_c(uint8_t *ptr, uint32_t len);

/**
 * Return the library version string. Do NOT free the returned pointer.
 * The string length is written to *len.
 */
const uint8_t *wgslender_version_c(uint32_t *len);

#ifdef __cplusplus
}
#endif

#endif /* WGSLENDER_H */
