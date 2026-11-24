# 03 Call a C library through a checked boundary

> About 7 hours · Continue the `klog` package.

## The problem

Switchyard needs to call a function compiled by a C toolchain while keeping ordinary Rust call sites safe.

## The mental model

The C ABI governs argument passing. On this native Linux build, `size_t` maps to `usize`, and `uint64_t` maps to `u64`. The foreign function may run outside Rust’s checked memory rules.

## The pattern

Keep the raw declaration private. Derive the arguments from safe references and review the C body against the wrapper’s contract.

## Build it

### Step 1. Read the C signature

A C pointer has no length. The second argument tells the function how many bytes it may read. The loop never retains the pointer and has no accesses when length is zero. Unsigned addition in C wraps at the type width.

Create `native/sum_bytes.c`.

<!-- file: native/sum_bytes.c -->
~~~c
#include <stddef.h>
#include <stdint.h>

uint64_t sum_bytes(const uint8_t *bytes, size_t len) {
    uint64_t sum = 0;
    for (size_t i = 0; i < len; ++i) {
        sum += bytes[i];
    }
    return sum;
}
~~~

### Step 2. Build and link the archive

Cargo runs `build.rs` before compiling the library. Compile the C source with warnings treated as errors and archive the object with ar. Use the opt-in flag when the ASan gate compiles this C code.

Create `build.rs`.

<!-- file: build.rs -->
~~~rust
use std::env;
use std::path::PathBuf;
use std::process::Command;

fn check(command: &mut Command) {
    let result = command.status().expect("start native build command");
    assert!(result.success(), "native command failed: {command:?}");
}

fn main() {
    println!("cargo:rerun-if-changed=native/sum_bytes.c");
    for key in ["CC", "AR", "SWITCHYARD_C_ASAN"] {
        println!("cargo:rerun-if-env-changed={key}");
    }
    let out = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo output directory"));
    let object = out.join("sum_bytes.o");
    let archive = out.join("libswitchyard_native.a");
    let mut compiler = Command::new(env::var_os("CC").unwrap_or_else(|| "cc".into()));
    compiler.args(["-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC"]);
    if env::var("SWITCHYARD_C_ASAN").as_deref() == Ok("1") {
        compiler.args(["-fsanitize=address", "-fno-omit-frame-pointer"]);
    }
    check(
        compiler
            .args(["-c", "native/sum_bytes.c", "-o"])
            .arg(&object),
    );
    check(
        Command::new(env::var_os("AR").unwrap_or_else(|| "ar".into()))
            .arg("crs")
            .arg(&archive)
            .arg(&object),
    );
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=switchyard_native");
}
~~~

### Step 3. Wrap the unsafe call in a safe function

The wrapper derives the pointer and length from a live Rust slice and calls C before the borrow ends. The foreign declaration is a promise about the symbol and calling convention. Document the obligations where you discharge them.

Create `src/native.rs`.

<!-- file: src/native.rs -->
~~~rust
unsafe extern "C" {
    fn sum_bytes(bytes: *const u8, len: usize) -> u64;
}

pub fn sum(data: &[u8]) -> u64 {
    // SAFETY: the slice guarantees len readable bytes through this call.
    // C respects that bound, reads only, and does not retain the pointer.
    unsafe { sum_bytes(data.as_ptr(), data.len()) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn c_matches_the_rust_sum_at_the_slice_bounds() {
        let data = [255, 0, 12, 17, 254, 3];
        for lo in 0..=data.len() {
            for hi in lo..=data.len() {
                let input = &data[lo..hi];
                assert_eq!(sum(input), input.iter().map(|&n| u64::from(n)).sum());
            }
        }
    }
}
~~~

Register the module in `src/lib.rs`.

<!-- append: src/lib.rs -->
~~~rust
pub mod native;
~~~

~~~bash
cargo test --quiet native::tests --lib
~~~

<!-- run: cargo test --quiet native::tests --lib -->

~~~text

running 1 test
.
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 23 filtered out; finished in 0.00s
~~~

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Explain which property protects the empty input case, and what would change if C kept the pointer after returning.

## If it goes wrong

If linking fails, run the Cargo command with verbose output. Confirm the compiler and archive utility target the same architecture as Rust, and look for the expected archive in Cargo’s output directory.
