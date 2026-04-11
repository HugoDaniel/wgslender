#include <stdio.h>
#include <string.h>
#include "wgslender.h"

static void validate(const char *label, const char *source, uint32_t flags) {
    printf("--- %s ---\n", label);

    WgslenderValidateResult r = wgslender_validate_c(
        (const uint8_t *)source, (uint32_t)strlen(source), flags);

    printf("valid: %s, errors: %u\n", r.valid ? "true" : "false", r.error_count);

    if (r.json_ptr) {
        printf("diagnostics: %.*s\n", r.json_len, r.json_ptr);
        wgslender_free_c((uint8_t *)r.json_ptr, r.json_len);
    }
    printf("\n");
}

int main(void) {
    /* A valid shader. */
    validate("valid shader",
        "@vertex fn main() -> @builtin(position) vec4f {\n"
        "    return vec4f(0.0, 0.0, 0.0, 1.0);\n"
        "}\n",
        0);

    /* An invalid shader — references undeclared identifier. */
    validate("undeclared identifier",
        "@vertex fn main() -> @builtin(position) vec4f {\n"
        "    return oops;\n"
        "}\n",
        0);

    /* Strict mode validation. */
    validate("strict mode",
        "@vertex fn main() -> @builtin(position) vec4f {\n"
        "    return vec4f(0.0, 0.0, 0.0, 1.0);\n"
        "}\n",
        WGSLENDER_OPT_STRICT);

    return 0;
}
