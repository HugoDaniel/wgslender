CC       ?= cc
CFLAGS   ?= -Wall -Wextra -std=c11
LIB_DIR  ?= ../../zig-out/lib
INC_DIR  ?= ../../include

EXAMPLES = minify validate reflect

all: $(EXAMPLES)

%: %.c
	$(CC) $(CFLAGS) -I$(INC_DIR) -o $@ $< $(LIB_DIR)/libwgslender.a

clean:
	rm -f $(EXAMPLES)

.PHONY: all clean
