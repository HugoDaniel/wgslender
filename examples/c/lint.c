/*
 * Lint a WGSL source via the C API.
 *
 * Build:
 *   zig build lib
 *   cc examples/c/lint.c -Iinclude zig-out/lib/libwgslender.a -o lint
 *   ./lint
 */

#include <stdio.h>
#include <string.h>
#include "wgslender.h"

int main(void) {
    const char *source =
        "@compute @workgroup_size(1) fn main() {\n"
        "    let unused = 42;\n"
        "    _ = 3.14;\n"
        "}\n";

    const char *config = "{\"extends\":[\"@wgslender/recommended\"]}";

    WgslenderLintResult r = wgslender_lint_c(
        (const uint8_t *)source, (uint32_t)strlen(source),
        (const uint8_t *)config, (uint32_t)strlen(config));

    printf("lint: %u errors, %u warnings\n", r.error_count, r.warning_count);
    if (r.json_ptr) {
        printf("diagnostics: %.*s\n", r.json_len, r.json_ptr);
        wgslender_free_c((uint8_t *)r.json_ptr, r.json_len);
    }
    return 0;
}
