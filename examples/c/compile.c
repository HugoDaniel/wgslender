/*
 * Compile WGSL to a binary shader via the C API.
 *
 * Build:
 *   zig build lib
 *   cc examples/c/compile.c -Iinclude zig-out/lib/libwgslender.a -o compile
 *   ./compile
 */

#include <stdio.h>
#include <string.h>
#include "wgslender.h"

int main(void) {
    const char *source =
        "@compute @workgroup_size(1) fn main() {\n"
        "    let x = 1.0 + 2.0;\n"
        "}\n";

    WgslenderCompileResult r = wgslender_compile_c(
        (const uint8_t *)source, (uint32_t)strlen(source),
        (const uint8_t *)"{}", 2);

    printf("compile: original=%u bytes, wasm=%u bytes\n",
        r.original_size, r.wasm_len);

    if (r.wasm_ptr && r.wasm_len >= 4) {
        printf("magic: %02x %02x %02x %02x\n",
            r.wasm_ptr[0], r.wasm_ptr[1], r.wasm_ptr[2], r.wasm_ptr[3]);
        wgslender_free_c((uint8_t *)r.wasm_ptr, r.wasm_len);
    }
    if (r.errors_json_ptr) {
        printf("errors: %.*s\n", r.errors_json_len, r.errors_json_ptr);
        wgslender_free_c((uint8_t *)r.errors_json_ptr, r.errors_json_len);
    }
    return 0;
}
