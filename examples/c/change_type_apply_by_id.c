/*
 * Change a declaration's type by stable id via the C API.
 *
 * Two-step flow: locate the symbol by source offset to get its
 * stable id, then apply the type change.
 *
 * Build:
 *   zig build lib
 *   cc examples/c/change_type_apply_by_id.c -Iinclude zig-out/lib/libwgslender.a -o change_type_apply_by_id
 *   ./change_type_apply_by_id
 */

#include <stdio.h>
#include <string.h>
#include "wgslender.h"

/* Bounded substring search. strnstr is BSD-only and absent from glibc. */
static const char *find_sub(const char *hay, size_t hay_len, const char *needle) {
    size_t n = strlen(needle);
    if (n == 0 || hay_len < n) return NULL;
    for (size_t i = 0; i + n <= hay_len; i++)
        if (memcmp(hay + i, needle, n) == 0) return hay + i;
    return NULL;
}

/* Every search here is bounded by json_len, because the C ABI hands back a
 * pointer and a length and promises no terminator: the buffer is allocated at
 * exactly its own size. A str* function would read past the end of it. */
static uint32_t extract_id(const uint8_t *json, uint32_t json_len, char *out, uint32_t cap) {
    const char *needle = "\"stableId\":\"";
    const char *text = (const char *)json;
    const char *start = find_sub(text, json_len, needle);
    if (!start) return 0;
    start += strlen(needle);
    const char *end = memchr(start, '"', (size_t)(text + json_len - start));
    if (!end) return 0;
    uint32_t n = (uint32_t)(end - start);
    if (n + 1 > cap) n = cap - 1;
    memcpy(out, start, n);
    out[n] = '\0';
    return n;
}

int main(void) {
    const char *source =
        "@group(0) @binding(0) var<uniform> u: f32;\n"
        "@compute @workgroup_size(1) fn main() {}\n";

    /* `u` is the variable declaration; locate its name in source. */
    uint32_t offset = (uint32_t)((strstr(source, "u:") - source));

    WgslenderJsonResult id_r = wgslender_stable_id_at_offset_c(
        (const uint8_t *)source, (uint32_t)strlen(source), offset);
    if (id_r.error || !id_r.json_ptr) {
        fprintf(stderr, "stable_id_at_offset failed\n");
        return 1;
    }

    char id[256];
    uint32_t id_len = extract_id(id_r.json_ptr, id_r.json_len, id, sizeof(id));
    wgslender_free_c((uint8_t *)id_r.json_ptr, id_r.json_len);
    if (id_len == 0) {
        fprintf(stderr, "no id in response\n");
        return 1;
    }
    printf("stable id: %s\n", id);

    const char *new_type = "vec4f";

    WgslenderJsonResult ct_r = wgslender_change_type_apply_by_id_c(
        (const uint8_t *)source, (uint32_t)strlen(source),
        (const uint8_t *)id, id_len,
        (const uint8_t *)new_type, (uint32_t)strlen(new_type));

    if (ct_r.error || !ct_r.json_ptr) {
        fprintf(stderr, "change_type_apply_by_id failed\n");
        return 1;
    }

    printf("change_type_apply_by_id (%u bytes):\n%.*s\n",
        ct_r.json_len, ct_r.json_len, ct_r.json_ptr);

    wgslender_free_c((uint8_t *)ct_r.json_ptr, ct_r.json_len);
    return 0;
}
