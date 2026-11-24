# 06 Call a Rust library from C

## The problem

The C program now owns the bytes. It needs to call Rust without transferring ownership or depending on Rust's native slice layout.

## The pattern

Export one C ABI symbol with `extern "C"` and `unsafe(no_mangle)`. C passes a byte pointer, a count, and a pointer to a writable output. Keep the fixed return codes in the public declaration. Reject the null shapes and excessive lengths before constructing a slice, leaving the output unchanged on rejection. The caller is responsible for a readable live allocation and an aligned writable output. A null pointer check alone cannot establish those obligations.

Use a Rust `staticlib` for linking with the C toolchain. On Linux, `rustc` reports the system libraries required by the archive. Link in that order. This checksum uses unsigned wraparound as part of its definition.

## Build it

### Step 1. Write the matching declaration

Map size_t to usize, uint64_t to u64, and int to c_int. Document which pointers are valid when the function reads and writes.

<details>
<summary>Hint</summary>

Treat a null pointer with zero data length as the empty span. A writable output is still required.

</details>

<details>
<summary>Type-along answer</summary>

Create `include/rust_checksum.h`.

<!-- file: include/rust_checksum.h -->
~~~c
#ifndef RUST_CHECKSUM_H
#define RUST_CHECKSUM_H
#include <stddef.h>
#include <stdint.h>

/*
 * Return zero and write one uint64_t on success. A null data pointer
 * represents empty input only when len is zero. The caller owns all storage.
 * Input must be readable for the call. out must point to an aligned,
 * writable and nonoverlapping uint64_t.
 */
int rust_checksum(const uint8_t *data, size_t len, uint64_t *out);
#endif
~~~

Create `src/digest.rs`.

<!-- file: src/digest.rs -->
~~~rust
use std::{ffi::c_int, slice};

pub fn checksum(bytes: &[u8]) -> u64 {
    let mut sum = 14_695_981_039_346_656_037_u64;
    for &byte in bytes {
        sum ^= u64::from(byte);
        sum = sum.wrapping_mul(1_099_511_628_211);
    }
    sum
}

/// Write the checksum, returning 0 for success and 1 for invalid shape.
///
/// # Safety
/// Input used by the function must point to a readable allocation of len
/// bytes. A non-null output must be aligned, writable, and nonoverlapping.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rust_checksum(data: *const u8, len: usize, out: *mut u64) -> c_int {
    if out.is_null() || (data.is_null() && len != 0) || len > isize::MAX as usize {
        return 1;
    }
    let bytes = if len == 0 {
        &[]
    } else {
        // SAFETY: the caller supplies the readable range. Null and
        // excessive lengths were rejected above.
        unsafe { slice::from_raw_parts(data, len) }
    };
    let sum = checksum(bytes);
    // SAFETY: the caller supplies an aligned writable output.
    unsafe { out.write(sum) };
    0
}
~~~

</details>

Add the library crate types to `Cargo.toml` and expose the module.

<!-- append: Cargo.toml -->
~~~toml
[lib]
crate-type = ["rlib", "staticlib"]
~~~

<!-- append: src/lib.rs -->
~~~rust
pub mod digest;
~~~
### Step 2. Call the exported symbol

Read a file in binary mode into the owned C buffer. Call Rust while the buffer stays live. Test wrong argument shapes with the output initialized to an identifiable value.

<details>
<summary>Hint</summary>

Check the result of fread, fclose, and the checksum before printing a result. Free in C.

</details>

<details>
<summary>Type-along answer</summary>

Create `c/c_reads_rust.c`.

<!-- file: c/c_reads_rust.c -->
~~~c
#include "byte_buffer.h"
#include "rust_checksum.h"
#include <inttypes.h>
#include <stdio.h>

int main(int argc, char **argv) {
    uint64_t sum = 123;
    if (rust_checksum(NULL, 1, &sum) == 0 || sum != 123 ||
        rust_checksum(NULL, 0, NULL) == 0) {
        fputs("invalid argument check failed\n", stderr);
        return 1;
    }
    if (argc != 2) {
        fputs("usage: c_reads_rust FIXTURE\n", stderr);
        return 2;
    }
    byte_buffer *buffer = bb_new();
    if (buffer == NULL) {
        return 1;
    }
    FILE *file = fopen(argv[1], "rb");
    if (file == NULL) {
        perror(argv[1]);
        bb_free(buffer);
        return 1;
    }
    uint8_t chunk[256];
    size_t used;
    int okay = 1;
    while ((used = fread(chunk, 1, sizeof chunk, file)) != 0) {
        if (bb_append(buffer, chunk, used) != BB_OK) {
            okay = 0;
            break;
        }
    }
    if (ferror(file)) {
        okay = 0;
    }
    if (fclose(file) == EOF) {
        okay = 0;
    }
    if (okay) {
        byte_view view = bb_view(buffer);
        okay = rust_checksum(view.data, view.len, &sum) == 0;
    }
    bb_free(buffer);
    if (!okay) {
        fputs("failed to read or checksum fixture\n", stderr);
        return 1;
    }
    printf("%016" PRIx64 "\n", sum);
    return 0;
}
~~~

</details>

Add the archive link target to `Makefile`. If the host's Rust toolchain prints a different system library list, pass it as `RUST_LIBS` when linking.

<!-- append: Makefile -->
~~~make
RUST_BUILD ?= target
RUST_LIBS ?= -lgcc_s -lutil -lrt -lpthread -lm -ldl -lc

.PHONY: link-rust
link-rust: $(BUILD)/c_reads_rust.o
	cargo build --offline --target-dir "$(RUST_BUILD)"
	$(CC) $(LDFLAGS) "$<" "$(RUST_BUILD)/debug/libbyte_bridge.a" $(RUST_LIBS) -o "$(BUILD)/c_reads_rust"
~~~

## Check it

~~~bash
cargo rustc --offline --lib -- --print native-static-libs && make --no-print-directory -s link-rust && (fixture=$(mktemp) && trap 'rm -f -- "$fixture"' EXIT && printf 'A\000B' > "$fixture" && build/c_reads_rust "$fixture" && target/debug/rust_reads_c "$fixture")
~~~

<!-- run: cargo rustc --offline --lib -- --print native-static-libs && make --no-print-directory -s link-rust && (fixture=$(mktemp) && trap 'rm -f -- "$fixture"' EXIT && printf 'A\000B' > "$fixture" && build/c_reads_rust "$fixture" && target/debug/rust_reads_c "$fixture") -->

~~~text
note: native-static-libs: -lgcc_s -lutil -lrt -lpthread -lm -ldl -lc
fb029919a1274bf2
fb029919a1274bf2
~~~

The same three bytes cross both boundaries. The printed native library list is from the reference Linux toolchain.

[Reference capture](../evidence/06-link.txt)

## Explain it

What can the Rust function check before creating its slice, and what must the C caller establish?
