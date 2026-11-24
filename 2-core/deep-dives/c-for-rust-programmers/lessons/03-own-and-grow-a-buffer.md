# 03 Own and grow a buffer

## The problem

The C caller needs a buffer whose length can grow even if the allocation moves. The handle should still own the old bytes after a failed allocation.

## The pattern

An opaque handle has a public type name and a private representation. Publish operations and their ownership rules in the header. A live handle keeps an initialized prefix and a capacity. Before growing, check the length against the capacity bound. Ask the allocator for space and wait for success before replacing the saved pointer. Keep the old pointer in the handle if growth fails. Only advance the logical length after copying the new bytes. The release function must match the allocator used for storage.

## Build it

### Step 1. Declare ownership up front

Write the constructor, append, view, and release declarations. Decide who owns the handle and what invalidates a borrowed view.

<details>
<summary>Hint</summary>

Keep allocator state private. Allow a custom realloc-like allocator so a test can fail exactly one step.

</details>

<details>
<summary>Type-along answer</summary>

Create `include/byte_buffer.h`.

<!-- file: include/byte_buffer.h -->
~~~c
#ifndef BYTE_BUFFER_H
#define BYTE_BUFFER_H
#include "byte_view.h"

typedef struct byte_buffer byte_buffer;

enum { BB_OK = 0, BB_INVALID = 1, BB_NOMEM = 2, BB_TOO_LARGE = 3 };

/*
 * resize behaves like realloc for positive sizes. On failure it returns
 * NULL and leaves the original allocation valid. release frees pointers
 * returned by resize. The context must outlive the buffer.
 */
typedef struct {
    void *ctx;
    void *(*resize)(void *ctx, void *data, size_t size);
    void (*release)(void *ctx, void *data);
} bb_allocator;

byte_buffer *bb_new(void);
byte_buffer *bb_new_with_allocator(bb_allocator allocator);
void bb_free(byte_buffer *b);

/*
 * With a live handle, a valid nonempty input must be readable for len
 * bytes and must not overlap the buffer's storage. Lengths that exceed
 * the maximum capacity are rejected before reading the input.
 */
int bb_append(byte_buffer *b, const uint8_t *data, size_t len);
/* b is live. The returned bytes are borrowed until the next append or free. */
byte_view bb_view(const byte_buffer *b);
#endif
~~~

</details>
### Step 2. Preserve state on failed growth

Fill in the sequence behind `checked count → proposed capacity → /* TODO */ → copy → publish length`. Address the case where the growth multiplication itself would exceed the limit.

<details>
<summary>Hint</summary>

Store a successful result in a temporary variable before publishing the pointer or capacity.

</details>

<details>
<summary>Type-along answer</summary>

Create `c/byte_buffer.c`.

<!-- file: c/byte_buffer.c -->
~~~c
#include "byte_buffer.h"
#include <stdlib.h>
#include <string.h>

struct byte_buffer {
    uint8_t *data;
    size_t len;
    size_t capacity;
    bb_allocator allocator;
};

static void *resize_default(void *ctx, void *data, size_t size) {
    (void)ctx;
    return realloc(data, size);
}

static void release_default(void *ctx, void *data) {
    (void)ctx;
    free(data);
}

byte_buffer *bb_new_with_allocator(bb_allocator allocator) {
    if (allocator.resize == NULL || allocator.release == NULL) {
        return NULL;
    }
    byte_buffer *b = malloc(sizeof *b);
    if (b != NULL) {
        *b = (byte_buffer){.allocator = allocator};
    }
    return b;
}

byte_buffer *bb_new(void) {
    return bb_new_with_allocator((bb_allocator){NULL, resize_default, release_default});
}

void bb_free(byte_buffer *b) {
    if (b != NULL) {
        if (b->data != NULL) {
            b->allocator.release(b->allocator.ctx, b->data);
        }
        free(b);
    }
}

int bb_append(byte_buffer *b, const uint8_t *data, size_t len) {
    if (b == NULL || (data == NULL && len != 0)) {
        return BB_INVALID;
    }
    if (len == 0) {
        return BB_OK;
    }
    /* Rust's slice constructor also requires a range bounded by PTRDIFF_MAX. */
    if (len > (size_t)PTRDIFF_MAX - b->len) {
        return BB_TOO_LARGE;
    }
    const size_t needed = b->len + len;
    if (needed > b->capacity) {
        size_t capacity = b->capacity == 0 ? 16 : b->capacity;
        while (capacity < needed) {
            capacity = capacity > (size_t)PTRDIFF_MAX / 2 ? needed : capacity * 2;
        }
        void *next = b->allocator.resize(b->allocator.ctx, b->data, capacity);
        if (next == NULL) {
            return BB_NOMEM;
        }
        b->data = next;
        b->capacity = capacity;
    }
    memcpy(b->data + b->len, data, len);
    b->len = needed;
    return BB_OK;
}

byte_view bb_view(const byte_buffer *b) {
    return (byte_view){b->data, b->len};
}
~~~

</details>
### Step 3. Fail the allocation deterministically

Append a prefix with a zero byte. Make the next resize fail, then allow it and retry. Count frees and verify the old pointer and bytes after failure.

<details>
<summary>Hint</summary>

The first append fits in 16 bytes. Appending a further 20 exercises growth.

</details>

<details>
<summary>Type-along answer</summary>

Create `tests/buffer_test.c`.

<!-- file: tests/buffer_test.c -->
~~~c
#include "byte_buffer.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { int fail; int frees; } inject;

static void *resize(void *ctx, void *data, size_t size) {
    inject *state = ctx;
    return state->fail ? NULL : realloc(data, size);
}

static void release(void *ctx, void *data) {
    inject *state = ctx;
    ++state->frees;
    free(data);
}

int main(void) {
    inject state = {0};
    byte_buffer *buffer = bb_new_with_allocator((bb_allocator){&state, resize, release});
    assert(buffer != NULL && bb_view(buffer).len == 0);
    assert(bb_append(buffer, NULL, 0) == BB_OK);
    assert(bb_append(buffer, NULL, 1) == BB_INVALID);
    const uint8_t prefix[] = {7, 0, 8};
    const uint8_t more[20] = {9};
    assert(bb_append(buffer, prefix, sizeof prefix) == BB_OK);
    assert(bb_append(buffer, prefix, SIZE_MAX) == BB_TOO_LARGE);

    byte_view original = bb_view(buffer);
    state.fail = 1;
    assert(bb_append(buffer, more, sizeof more) == BB_NOMEM);
    byte_view old = bb_view(buffer);
    assert(old.data == original.data);
    assert(old.len == sizeof prefix && memcmp(old.data, prefix, old.len) == 0);
    assert(state.frees == 0);
    state.fail = 0;
    assert(bb_append(buffer, more, sizeof more) == BB_OK);
    byte_view grown = bb_view(buffer);
    assert(grown.len == sizeof prefix + sizeof more);
    assert(memcmp(grown.data, prefix, sizeof prefix) == 0);
    assert(memcmp(grown.data + sizeof prefix, more, sizeof more) == 0);
    bb_free(buffer);
    assert(state.frees == 1);
    bb_free(NULL);
    puts("failed growth kept the original bytes and ownership; retry succeeded");
    return 0;
}
~~~

</details>

Replace the existing Makefile with this version to add both tests to `check`.

<!-- edit: Makefile -->
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

-include $(wildcard $(BUILD)/*.d)

$(BUILD)/buffer_test: $(BUILD)/buffer_test.o $(BUILD)/byte_buffer.o
	$(CC) $(LDFLAGS) $^ $(LDLIBS) -o "$@"

check: $(BUILD)/view_test $(BUILD)/buffer_test
	"$(BUILD)/view_test"
	"$(BUILD)/buffer_test"
~~~

## Check it

~~~bash
make --no-print-directory -s check
~~~

<!-- run: make --no-print-directory -s check -->

~~~text
view bounds: empty, embedded zero, and rejected range checked
failed growth kept the original bytes and ownership; retry succeeded
~~~

The retry checks that a failed resize leaves a usable buffer. The allocator test also checks that exactly one release follows successful growth.

[Reference capture](../evidence/03-buffer.txt)

## Explain it

Why does assigning a resize result directly into the owned pointer lose information on failure?
