#include <stdio.h>
#include <string.h>
#include "wgslender.h"

int main(void) {
    const char *source =
        "struct Params {\n"
        "    width:  f32,\n"
        "    height: f32,\n"
        "    time:   f32,\n"
        "}\n"
        "\n"
        "@group(0) @binding(0) var<uniform> params: Params;\n"
        "@group(0) @binding(1) var<storage, read_write> output: array<f32>;\n"
        "\n"
        "@compute @workgroup_size(64)\n"
        "fn main(@builtin(global_invocation_id) id: vec3u) {\n"
        "    let i = id.x;\n"
        "    output[i] = params.time;\n"
        "}\n";

    WgslenderJsonResult r = wgslender_reflect_c(
        (const uint8_t *)source, (uint32_t)strlen(source));

    if (r.error) {
        fprintf(stderr, "reflection failed\n");
        return 1;
    }

    printf("Reflection JSON:\n%.*s\n", r.json_len, r.json_ptr);

    wgslender_free_c((uint8_t *)r.json_ptr, r.json_len);
    return 0;
}
