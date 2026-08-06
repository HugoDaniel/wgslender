/*
 * Lint with autofix via the C API.
 *
 * Build:
 *   zig build lib
 *   cc examples/c/lint_fix.c -Iinclude zig-out/lib/libwgslender.a -o lint_fix
 *   ./lint_fix
 */

#include <stdio.h>
#include <string.h>
#include "wgslender.h"

int main(void) {
    const char *source =
        "@compute @workgroup_size(1) fn main() {\n"
        "    let x = f32(1.5);\n"
        "    _ = f32(x);\n"
        "}\n";

    const char *config = "{\"extends\":[\"@wgslender/recommended\"]}";

    WgslenderLintFixResult r = wgslender_lint_fix_c(
        (const uint8_t *)source, (uint32_t)strlen(source),
        (const uint8_t *)config, (uint32_t)strlen(config));

    printf("lint_fix: %u errors, %u warnings\n", r.error_count, r.warning_count);
    if (r.fixed_ptr) {
        printf("fixed source (%u bytes):\n%.*s\n", r.fixed_len, r.fixed_len, r.fixed_ptr);
        wgslender_free_c((uint8_t *)r.fixed_ptr, r.fixed_len);
    }
    if (r.json_ptr) {
        printf("diagnostics: %.*s\n", r.json_len, r.json_ptr);
        wgslender_free_c((uint8_t *)r.json_ptr, r.json_len);
    }
    return 0;
}
