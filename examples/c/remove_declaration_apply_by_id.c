/*
 * Remove a declaration by stable id via the C API.
 *
 * Two-step flow: locate the symbol by source offset to get its
 * stable id, then apply the removal.
 *
 * Build:
 *   zig build lib
 *   cc examples/c/remove_declaration_apply_by_id.c -Iinclude zig-out/lib/libwgslender.a -o remove_declaration_apply_by_id
 *   ./remove_declaration_apply_by_id
 */

#include <stdio.h>
#include <string.h>
#include "wgslender.h"

/* Extract the value of a `"stableId":"..."` field from a JSON blob
 * (smoke-test helper, not a JSON parser). Returns bytes copied. */
static uint32_t extract_id(const uint8_t *json, uint32_t json_len, char *out, uint32_t cap) {
    const char *needle = "\"stableId\":\"";
    const char *start = strnstr((const char *)json, needle, json_len);
    if (!start) return 0;
    start += strlen(needle);
    const char *end = strchr(start, '"');
    if (!end) return 0;
    uint32_t n = (uint32_t)(end - start);
    if (n + 1 > cap) n = cap - 1;
    memcpy(out, start, n);
    out[n] = '\0';
    return n;
}

int main(void) {
    const char *source =
        "fn helper() -> i32 { return 1; }\n"
        "@compute @workgroup_size(1) fn main() {}\n";

    /* `helper` declaration starts at offset 3. */
    uint32_t offset = (uint32_t)((strstr(source, "helper") - source));

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

    WgslenderJsonResult rm_r = wgslender_remove_declaration_apply_by_id_c(
        (const uint8_t *)source, (uint32_t)strlen(source),
        (const uint8_t *)id, id_len);

    if (rm_r.error || !rm_r.json_ptr) {
        fprintf(stderr, "remove_declaration_apply_by_id failed\n");
        return 1;
    }

    printf("remove_declaration_apply_by_id (%u bytes):\n%.*s\n",
        rm_r.json_len, rm_r.json_len, rm_r.json_ptr);

    wgslender_free_c((uint8_t *)rm_r.json_ptr, rm_r.json_len);
    return 0;
}
