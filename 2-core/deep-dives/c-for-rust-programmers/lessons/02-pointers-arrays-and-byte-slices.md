# 02 Pointers, arrays, and byte slices

## The problem

A pointer at the first byte cannot tell you how many other bytes belong to the allocation. A subrange needs the caller's length and an explicit check.

## The pattern

In `byte_view`, the pointer is borrowed and `len` counts initialized bytes. The caller keeps the allocation alive. Check `start <= len`, then compare `count` with `len - start`. This avoids an overflowing `start + count`. An empty view at the end of a live array may point one past the last byte. Handle a null empty view before offset arithmetic.

## Build it

### Step 1. Trace the bounds

For [11, 0, 33], predict the resulting pointer and count for start 1 and count 2, and for start 3 and count 0.

<details>
<summary>Hint</summary>

The result borrows the same allocation, and the first selected byte can equal zero.

</details>

### Step 2. Test the contract

Include empty input, a zero byte, an out-of-range start, and a count too large to add safely.

<details>
<summary>Hint</summary>

Use SIZE_MAX as a bad count and make the function reject it before adjusting the pointer.

</details>

<details>
<summary>Type-along answer</summary>

Create `tests/view_test.c`.

<!-- file: tests/view_test.c -->
~~~c
#include "byte_view.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    const uint8_t bytes[] = {11, 0, 33};
    byte_view out;
    assert(view_subrange((byte_view){bytes, sizeof bytes}, 1, 2, &out));
    assert(out.data == &bytes[1] && out.len == 2 && out.data[0] == 0);
    assert(view_subrange((byte_view){NULL, 0}, 0, 0, &out));
    assert(out.data == NULL && out.len == 0);
    assert(view_subrange((byte_view){bytes, sizeof bytes}, sizeof bytes, 0, &out));
    assert(out.data == bytes + sizeof bytes && out.len == 0);
    assert(!view_subrange((byte_view){bytes, sizeof bytes}, sizeof bytes + 1, 0, &out));
    assert(!view_subrange((byte_view){bytes, sizeof bytes}, 1, SIZE_MAX, &out));
    assert(!view_subrange((byte_view){NULL, 1}, 0, 0, &out));
    puts("view bounds: empty, embedded zero, and rejected range checked");
    return 0;
}
~~~

</details>

## Check it

~~~bash
make --no-print-directory -s check
~~~

<!-- run: make --no-print-directory -s check -->

~~~text
view bounds: empty, embedded zero, and rejected range checked
~~~

If the end case fails, distinguish a valid one-past pointer for an empty view from a dereference.

[Reference capture](../evidence/02-view.txt)

## Explain it

Where does the original allocation live, and how long may the subrange be used?
