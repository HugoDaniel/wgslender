/*
 * Combined minify+reflect via the C API.
 *
 * Build:
 *   zig build lib
 *   cc examples/c/minify_and_reflect.c -Iinclude zig-out/lib/libwgslender.a -o minify_and_reflect
 *   ./minify_and_reflect
 */

#include <stdio.h>
#include <string.h>
#include "wgslender.h"

int main(void) {
    const char *source =
        "@group(0) @binding(0) var<uniform> u: vec4f;\n"
        "@compute @workgroup_size(1) fn main() {\n"
        "    let x = u.x;\n"
        "}\n";

    WgslenderMinifyAndReflectResult r = wgslender_minify_and_reflect_c(
        (const uint8_t *)source, (uint32_t)strlen(source),
        (const uint8_t *)"{}", 2);

    if (r.error || !r.json_ptr) {
        fprintf(stderr, "minify_and_reflect failed\n");
        return 1;
    }

    printf("minify_and_reflect (%u bytes):\n%.*s\n",
        r.json_len, r.json_len, r.json_ptr);

    wgslender_free_c((uint8_t *)r.json_ptr, r.json_len);
    return 0;
}
