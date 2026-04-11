#include <stdio.h>
#include <string.h>
#include "wgslender.h"

int main(void) {
    /* Print library version. */
    uint32_t ver_len;
    const uint8_t *ver = wgslender_version_c(&ver_len);
    printf("wgslender %.*s\n\n", ver_len, ver);

    const char *source =
        "@group(0) @binding(0) var<uniform> tint: vec4f;\n"
        "\n"
        "@vertex\n"
        "fn vs_main(@builtin(vertex_index) idx: u32) -> @builtin(position) vec4f {\n"
        "    let x = f32(idx & 1u) * 4.0 - 1.0;\n"
        "    let y = f32((idx >> 1u) & 1u) * 4.0 - 1.0;\n"
        "    return vec4f(x, y, 0.0, 1.0);\n"
        "}\n"
        "\n"
        "@fragment\n"
        "fn fs_main() -> @location(0) vec4f {\n"
        "    return tint;\n"
        "}\n";

    printf("Original (%zu bytes):\n%s\n", strlen(source), source);

    /* Minify with default options. */
    WgslenderResult r = wgslender_minify_c(
        (const uint8_t *)source, (uint32_t)strlen(source),
        WGSLENDER_OPT_DEFAULT);

    if (r.error) {
        fprintf(stderr, "minification failed\n");
        return 1;
    }

    printf("Minified (%u bytes):\n%.*s\n", r.code_len, r.code_len, r.code_ptr);

    /* Free the result buffer (both pointer and length required). */
    wgslender_free_c((uint8_t *)r.code_ptr, r.code_len);
    return 0;
}
