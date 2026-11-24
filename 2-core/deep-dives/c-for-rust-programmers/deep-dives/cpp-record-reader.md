# Call a C++ record reader safely from Rust

Use the existing [C/Rust deep dive](../README.md) to read a native compilation and link command. In this build, keep the parser in C++ and give Rust a safe owner that frees the C++ allocation exactly once. Build on Linux with Rust and Cargo, a GNU-compatible C++ compiler, and `ar`.

## 1. Name the ABI and the record format

Every record is a two-byte little-endian length followed by that many bytes. A caller sees clean EOF, a complete record, a truncated input, or an oversized length. A complete empty record differs from EOF.

The header declares an opaque handle and C linkage. The C++ layout stays inside the implementation. `reader_new` copies the input into a vector and translates exceptions to a null return. `reader_next` avoids allocation and checks the length before advancing.

Create `native/reader.h`.

<!-- file: native/reader.h -->
~~~~c
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct reader reader;

// Copy len bytes into an owned reader. NULL indicates invalid input or allocation failure.
reader *reader_new(const uint8_t *data, size_t len);
// Status 0 = record, 1 = EOF, 2 = truncated, 3 = too large.
// On status 0, the view belongs to r and remains valid until r is freed.
int reader_next(reader *r, const uint8_t **data, size_t *len);
void reader_free(reader *r);

#ifdef __cplusplus
}
#endif
~~~~

Create `native/reader.cpp`.

<!-- file: native/reader.cpp -->
~~~~cpp
#include "reader.h"

#include <memory>
#include <vector>

struct reader {
    std::vector<uint8_t> bytes;
    size_t offset = 0;
};

reader *reader_new(const uint8_t *data, size_t len) {
    if (data == nullptr && len != 0) {
        return nullptr;
    }
    try {
        auto handle = std::make_unique<reader>();
        if (len != 0) {
            handle->bytes.assign(data, data + len);
        }
        return handle.release();
    } catch (...) {
        return nullptr;
    }
}

int reader_next(reader *r, const uint8_t **data, size_t *len) {
    const auto left = r->bytes.size() - r->offset;
    if (left == 0) {
        return 1;
    }
    if (left < 2) {
        return 2;
    }
    const size_t length = size_t(r->bytes[r->offset]) |
                          (size_t(r->bytes[r->offset + 1]) << 8);
    if (length > 1024) {
        return 3;
    }
    if (length > left - 2) {
        return 2;
    }
    *data = r->bytes.data() + r->offset + 2;
    *len = length;
    r->offset += 2 + length;
    return 0;
}

void reader_free(reader *r) {
    delete r;
}
~~~~

## 2. Compile the native code with Cargo

The build script compiles one object, archives it, and tells Rust where to find that archive and the C++ runtime. The Rust code uses the platform C ABI for `int` and `size_t`. Cargo reruns the native build when either source file changes.

Create `Cargo.toml`.

<!-- file: Cargo.toml -->
~~~~toml
[package]
name = "native-records"
version = "0.1.0"
edition = "2024"
~~~~

Create `build.rs`.

<!-- file: build.rs -->
~~~~rust
use std::{env, path::PathBuf, process::Command};

fn main() {
    let out = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo sets OUT_DIR"));
    let object = out.join("reader.o");
    let archive = out.join("libreader.a");
    let compiler = env::var_os("CXX").unwrap_or_else(|| "c++".into());
    let status = Command::new(compiler)
        .args([
            "-std=c++17",
            "-O2",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-c",
            "native/reader.cpp",
            "-o",
        ])
        .arg(&object)
        .status()
        .expect("run C++ compiler");
    assert!(status.success(), "compile reader.cpp");
    let status = Command::new("ar")
        .arg("crs")
        .arg(&archive)
        .arg(&object)
        .status()
        .expect("run archiver");
    assert!(status.success(), "archive reader.o");
    println!("cargo:rerun-if-changed=native/reader.cpp");
    println!("cargo:rerun-if-changed=native/reader.h");
    println!("cargo:rerun-if-env-changed=CXX");
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=reader");
    println!("cargo:rustc-link-lib=dylib=stdc++");
}
~~~~

## 3. Put the ownership rules in the Rust API

`Reader` owns the native handle. Moving the Rust value transfers that ownership. `Drop` calls the allocator's matching release function. A record is borrowed from the reader, so Rust prevents the caller from freeing the owner while the view is in use. An empty record returns an ordinary empty slice. After reading, compare the C++ destructor and Rust `Drop` paths.

Create `src/lib.rs`.

<!-- file: src/lib.rs -->
~~~~rust
use std::{
    ffi::{c_int, c_void},
    ptr::{self, NonNull},
    slice,
};

unsafe extern "C" {
    fn reader_new(data: *const u8, len: usize) -> *mut c_void;
    fn reader_next(handle: *mut c_void, data: *mut *const u8, len: *mut usize) -> c_int;
    fn reader_free(handle: *mut c_void);
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    Allocation,
    Truncated,
    TooLarge,
    UnexpectedStatus,
}

pub struct Reader(NonNull<c_void>);

impl Reader {
    pub fn new(input: &[u8]) -> Result<Self, Error> {
        // The C++ constructor copies the live slice and catches exceptions.
        let handle = unsafe { reader_new(input.as_ptr(), input.len()) };
        NonNull::new(handle).map(Self).ok_or(Error::Allocation)
    }

    /// A record borrows the reader that owns its memory.
    ///
    /// ```compile_fail
    /// use native_records::Reader;
    /// let mut reader = Reader::new(&[1, 0, 42]).unwrap();
    /// let view = reader.read().unwrap().unwrap();
    /// drop(reader);
    /// assert_eq!(view, &[42]);
    /// ```
    pub fn read(&mut self) -> Result<Option<&[u8]>, Error> {
        let mut data = ptr::null();
        let mut length = 0;
        // Exclusive access protects the cursor. Both out-pointers are writable.
        let status = unsafe { reader_next(self.0.as_ptr(), &mut data, &mut length) };
        match status {
            0 if length == 0 => Ok(Some(&[])),
            // A successful C call returns a live non-null view of length bytes.
            0 => Ok(Some(unsafe { slice::from_raw_parts(data, length) })),
            1 => Ok(None),
            2 => Err(Error::Truncated),
            3 => Err(Error::TooLarge),
            _ => Err(Error::UnexpectedStatus),
        }
    }
}

impl Drop for Reader {
    fn drop(&mut self) {
        // This is the sole owner of the handle allocated by reader_new.
        unsafe { reader_free(self.0.as_ptr()) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let mut source = vec![0, 0, 3, 0, 9, 0, 7];
        let mut reader = Reader::new(&source).unwrap();
        source.fill(255);
        assert_eq!(reader.read().unwrap(), Some(&[][..]));
        assert_eq!(reader.read().unwrap(), Some(&[9, 0, 7][..]));
        assert_eq!(reader.read().unwrap(), None);
        println!("empty record, embedded zero, copied input, and EOF verified");
    }

    #[test]
    fn reject_each_incomplete_cut_and_the_first_oversize_length() {
        let valid = [3, 0, 9, 0, 7];
        for end in 1..valid.len() {
            let mut reader = Reader::new(&valid[..end]).unwrap();
            assert_eq!(reader.read(), Err(Error::Truncated));
        }
        assert_eq!(Reader::new(&[1, 4]).unwrap().read(), Err(Error::TooLarge));
    }
}
~~~~

## 4. Prove the handoff

The first test overwrites the caller's input after construction. The reader must still see the original bytes, including the embedded zero. The second test tries every incomplete cut of a record and the first size over the bound. The compile-fail check shows that the borrowed view cannot be used after `drop(reader)`.

<!-- run: cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test -- --nocapture -->
~~~~bash
cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test -- --nocapture
~~~~

The run printed `empty record, embedded zero, copied input, and EOF verified`. Both unit tests passed. The compile-fail test produced E0505 at `drop(reader)` and passed.
