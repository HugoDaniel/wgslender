CC       ?= cc
CFLAGS   ?= -Wall -Wextra -std=c11
LIB_DIR  ?= ../../zig-out/lib
INC_DIR  ?= ../../include
PORT_DIR := .portability

EXAMPLES = minify validate reflect rename lint lint_fix compile minify_and_reflect remove_declaration_apply_by_id change_type_apply_by_id

all: $(EXAMPLES)

%: %.c
	$(CC) $(CFLAGS) -I$(INC_DIR) -o $@ $< $(LIB_DIR)/libwgslender.a

clean:
	rm -f $(EXAMPLES)
	rm -rf $(PORT_DIR)

test: all
	./run_tests.sh

# Compile-only, against glibc headers, so that a BSD-ism nobody can see on
# macOS (strnstr, say) fails here rather than in a Linux user's terminal.
# zig doubles as a cross-compiler, so this needs no container and no CI.
#
# The objects go to a scratch directory and are deleted. `-o /dev/null` looks
# like the obvious way to throw them away and is not: zig cc cannot write there
# and silently writes <name>.o beside the source instead.
lint-portability:
	@mkdir -p $(PORT_DIR)
	@for f in *.c; do \
	  zig cc -std=c11 -Wall -Wextra -Werror=implicit-function-declaration \
	    -target x86_64-linux-gnu -I$(INC_DIR) -c -o $(PORT_DIR)/$${f%.c}.o $$f \
	    || { rm -rf $(PORT_DIR); exit 1; }; \
	done
	@rm -rf $(PORT_DIR)

.PHONY: all clean test lint-portability
