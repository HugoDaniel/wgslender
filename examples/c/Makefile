CC       ?= cc
CFLAGS   ?= -Wall -Wextra -std=c11
LIB_DIR  ?= ../../zig-out/lib
INC_DIR  ?= ../../include

EXAMPLES = minify validate reflect rename lint lint_fix compile minify_and_reflect remove_declaration_apply_by_id change_type_apply_by_id

all: $(EXAMPLES)

%: %.c
	$(CC) $(CFLAGS) -I$(INC_DIR) -o $@ $< $(LIB_DIR)/libwgslender.a

clean:
	rm -f $(EXAMPLES)

.PHONY: all clean
