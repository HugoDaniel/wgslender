/*
 * Minify WGSL via the C API, both ways.
 *
 * Two entry points minify, and the difference is how you ask:
 *
 *   wgslender_minify_c       bitflags (WGSLENDER_OPT_*). Frozen: the flag word
 *                            has the options it was born with and no more.
 *   wgslender_minify_json_c  the same JSON keys as a wgslender.json config
 *                            (camelCase: keepNames, sortDeclarations, ...).
 *                            The only way to reach anything added since.
 *
 * Two facts about this surface, because both surprise people:
 *
 *   1. Both return *plain minified text*. No JSON envelope, no size counters,
 *      no error list — the sizes below are measured here, not reported. The
 *      envelope the WASM/npm path returns exists in C only behind
 *      wgslender_minify_and_reflect_c.
 *   2. Malformed options JSON does not fail. It falls back to defaults,
 *      silently (src/lib.zig: `Config.parseJson(...) catch Config{}`), so a
 *      typo'd key is a minification that quietly ignores you. Keep the
 *      literal valid.
 *
 * Build:
 *   zig build lib
 *   cc examples/c/minify.c -Iinclude zig-out/lib/libwgslender.a -o minify
 *   ./minify
 */

#include <stdio.h>
#include <string.h>
#include "wgslender.h"

/* Bounded substring search: the C ABI returns a pointer and a length, and
 * promises no terminator, so str* functions have no business here. */
static int contains(const uint8_t *hay, uint32_t hay_len, const char *needle) {
    size_t n = strlen(needle);
    if (n == 0 || hay_len < n) return 0;
    for (size_t i = 0; i + n <= hay_len; i++)
        if (memcmp(hay + i, needle, n) == 0) return 1;
    return 0;
}

int main(void) {
    /* Print library version. */
    uint32_t ver_len;
    const uint8_t *ver = wgslender_version_c(&ver_len);
    printf("wgslender %.*s\n\n", ver_len, ver);

    const char *source =
        "@group(0) @binding(0) var<uniform> tint: vec4f;\n"
        "\n"
        "fn corner(idx: u32) -> vec2f {\n"
        "    let x = f32(idx & 1u) * 4.0 - 1.0;\n"
        "    let y = f32((idx >> 1u) & 1u) * 4.0 - 1.0;\n"
        "    return vec2f(x, y);\n"
        "}\n"
        "\n"
        "@vertex\n"
        "fn vs_main(@builtin(vertex_index) idx: u32) -> @builtin(position) vec4f {\n"
        "    return vec4f(corner(idx), 0.0, 1.0);\n"
        "}\n"
        "\n"
        "@fragment\n"
        "fn fs_main() -> @location(0) vec4f {\n"
        "    return tint;\n"
        "}\n";

    printf("Original (%zu bytes):\n%s\n", strlen(source), source);

    /* Minify with default options, via the bitflag path. */
    WgslenderResult r = wgslender_minify_c(
        (const uint8_t *)source, (uint32_t)strlen(source),
        WGSLENDER_OPT_DEFAULT);

    if (r.error) {
        fprintf(stderr, "minification failed\n");
        return 1;
    }

    printf("Minified (%u bytes):\n%.*s\n", r.code_len, r.code_len, r.code_ptr);

    /* The same, asking in JSON so that keepNames can be said at all.
     *
     * `corner` is an internal helper: nothing outside the shader names it, so
     * the renamer shortens it like any other private symbol. The two entry
     * points keep their names either way — the host pipeline asks for them by
     * name — which is why keepNames exists for everything else. */
    const char *opts = "{\"keepNames\":[\"corner\"]}";

    WgslenderResult k = wgslender_minify_json_c(
        (const uint8_t *)source, (uint32_t)strlen(source),
        (const uint8_t *)opts, (uint32_t)strlen(opts));

    if (k.error) {
        fprintf(stderr, "minification with options failed\n");
        wgslender_free_c((uint8_t *)r.code_ptr, r.code_len);
        return 1;
    }

    printf("With keepNames (%u bytes):\n%.*s\n", k.code_len, k.code_len, k.code_ptr);

    /* Read out of the two outputs rather than asserting from memory: this line
     * is what the smoke suite checks, and it is only true if keepNames worked
     * *and* the default really would have renamed it. */
    printf("helper 'corner': default -> %s, keepNames -> %s\n",
        contains(r.code_ptr, r.code_len, "corner") ? "kept" : "renamed",
        contains(k.code_ptr, k.code_len, "corner") ? "kept" : "renamed");

    /* Free both result buffers (pointer and length required). */
    wgslender_free_c((uint8_t *)r.code_ptr, r.code_len);
    wgslender_free_c((uint8_t *)k.code_ptr, k.code_len);
    return 0;
}
