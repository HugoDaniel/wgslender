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

test: all
	./run_tests.sh

# Compile-only, against glibc headers, so that a BSD-ism nobody can see on
# macOS (strnstr, say) fails here rather than in a Linux user's terminal.
# zig doubles as a cross-compiler, so this needs no container and no CI.
lint-portability:
	for f in *.c; do \
	  zig cc -std=c11 -Wall -Wextra -Werror=implicit-function-declaration \
	    -target x86_64-linux-gnu -I$(INC_DIR) -c -o /dev/null $$f || exit 1; \
	done

.PHONY: all clean test lint-portability
