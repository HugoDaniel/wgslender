/*
 * Rename a WGSL symbol via the C API.
 *
 * Demonstrates the bidirectional loop: locate a symbol, compute edits,
 * apply them, print the rewritten source — with one call to
 * wgslender_rename_apply_c.
 *
 * Build:
 *   zig build lib
 *   cc examples/c/rename.c -I include -L zig-out/lib -lwgslender -o rename_demo
 *   ./rename_demo
 */

#include <stdio.h>
#include <string.h>
#include "wgslender.h"

int main(void) {
    const char *source =
        "fn helper(x: f32) -> f32 { return x * 2.0; }\n"
        "fn other(y: f32) -> f32 { return helper(y) + helper(1.0); }\n"
        "@compute @workgroup_size(1) fn main() { let z = helper(3.0); }\n";

    /* Locate the first `helper` in source — that's the declaration site. */
    const char *decl_site = strstr(source, "helper");
    if (!decl_site) {
        fprintf(stderr, "couldn't locate symbol in source\n");
        return 1;
    }
    uint32_t offset = (uint32_t)(decl_site - source);

    const char *new_name = "scale";

    WgslenderJsonResult r = wgslender_rename_apply_c(
        (const uint8_t *)source, (uint32_t)strlen(source),
        offset,
        (const uint8_t *)new_name, (uint32_t)strlen(new_name));

    if (r.error || !r.json_ptr) {
        fprintf(stderr, "rename_apply failed (allocation)\n");
        return 1;
    }

    /* The result is a JSON blob: parse it with your JSON lib of choice.
     * Here we just print it. A successful response looks like:
     *   {"ok":true,"source":"...rewritten...","edits":[...]}
     * A failing one:
     *   {"ok":false,"source":"<original>","edits":[],"error":"..."}
     */
    printf("rename_apply JSON (%u bytes):\n%.*s\n",
        r.json_len, r.json_len, r.json_ptr);

    wgslender_free_c((uint8_t *)r.json_ptr, r.json_len);
    return 0;
}
