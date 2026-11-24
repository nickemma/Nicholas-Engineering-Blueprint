# 01 From source file to executable

## The problem

Two C files can compile on their own and still fail to link if a promised function has no definition. A changed header can also leave old code in a binary unless the build knows who includes it.

## The mental model

~~~text
header declarations ──┐
source with main ──────┼─ compiler ── view_main.o ─┐
library implementation ─ compiler ── byte_view.o ─┴─ linker ── view
~~~

The header describes shared types and declarations. Each compiler invocation sees one translation unit, which includes its headers. The linker resolves the call to the definition in the other object. In Make, declare dependencies separately from commands. Put a tab before each recipe line. GCC and Clang emit `.d` files with `-MMD -MP`. Make reads them on the next run.

## Build it

### Step 1. Declare a view and a checksum

Describe a borrowed span using a pointer and a count. Split its declarations and definition across the header and C source. The checksum uses unsigned 64-bit arithmetic.

<details>
<summary>Hint</summary>

Use the length as the loop bound. Zero is a byte and participates in the checksum.

</details>

<details>
<summary>Type-along answer</summary>

Create `include/byte_view.h`.

<!-- file: include/byte_view.h -->
~~~c
#ifndef BYTE_VIEW_H
#define BYTE_VIEW_H
#include <stddef.h>
#include <stdint.h>

typedef struct {
    const uint8_t *data;
    size_t len;
} byte_view;

/* Success writes a borrowed view. The original allocation must outlive it. */
int view_subrange(byte_view in, size_t start, size_t count, byte_view *out);
uint64_t view_checksum(byte_view in);
#endif
~~~

Create `c/byte_view.c`.

<!-- file: c/byte_view.c -->
~~~c
#include "byte_view.h"

int view_subrange(byte_view in, size_t start, size_t count, byte_view *out) {
    if (out == NULL || (in.data == NULL && in.len != 0) ||
        start > in.len || count > in.len - start) {
        return 0;
    }
    /* Avoid even adding zero to a null pointer. */
    out->data = start == 0 ? in.data : in.data + start;
    out->len = count;
    return 1;
}

uint64_t view_checksum(byte_view in) {
    uint64_t sum = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < in.len; ++i) {
        sum ^= in.data[i];
        sum *= UINT64_C(1099511628211);
    }
    return sum;
}
~~~

</details>
### Step 2. Give the program an entry point

Check the argument count. For a shell argument, use strlen once to build the view and print the count and checksum.

<details>
<summary>Hint</summary>

Shell arguments are C strings and terminate at a zero byte. Later you will read a binary file with its length.

</details>

<details>
<summary>Type-along answer</summary>

Create `c/view_main.c`.

<!-- file: c/view_main.c -->
~~~c
#include "byte_view.h"
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fputs("usage: view TEXT\n", stderr);
        return 2;
    }
    byte_view input = {(const uint8_t *)argv[1], strlen(argv[1])};
    printf("%zu bytes: %016" PRIx64 "\n", input.len, view_checksum(input));
    return 0;
}
~~~

</details>
### Step 3. Compile, link, and inspect the graph

Create a target for each object and another for the executable. With an existing build, try `make -n -W include/byte_view.h all` and identify the actions Make plans for the changed header.

<details>
<summary>Hint</summary>

The directory is an order-only prerequisite. Changes to directory metadata should not rebuild every object.

</details>

<details>
<summary>Type-along answer</summary>

Create `Makefile`.

<!-- file: Makefile -->
~~~make
CC ?= cc
CFLAGS ?= -O2
CPPFLAGS += -Iinclude
WARN = -std=c17 -Wall -Wextra -Wpedantic -Werror
BUILD ?= build

.PHONY: all check
all: $(BUILD)/view

$(BUILD):
	mkdir -p "$@"

$(BUILD)/%.o: c/%.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARN) -MMD -MP -c "$<" -o "$@"

$(BUILD)/%_test.o: tests/%_test.c | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(WARN) -MMD -MP -c "$<" -o "$@"

$(BUILD)/view: $(BUILD)/view_main.o $(BUILD)/byte_view.o
	$(CC) $(LDFLAGS) $^ $(LDLIBS) -o "$@"

$(BUILD)/view_test: $(BUILD)/view_test.o $(BUILD)/byte_view.o
	$(CC) $(LDFLAGS) $^ $(LDLIBS) -o "$@"

check: $(BUILD)/view_test
	"$(BUILD)/view_test"

-include $(wildcard $(BUILD)/*.d)
~~~

</details>

## Check it

~~~bash
make --no-print-directory -s all && build/view lab
~~~

<!-- run: make --no-print-directory -s all && build/view lab -->

~~~text
3 bytes: 126596191dc1ebb4
~~~

A missing definition shows up as an undefined reference at link time. Check whether its object appears on the link command.

[Reference capture](../evidence/01-build.txt)

## Explain it

Which phase checks the declaration and which phase resolves the symbol?
