# 05 Call the C library from Rust

## The problem

A Rust caller needs the C buffer's data and destructor. Passing the raw pointer through the whole program would require each caller to remember all of the C rules.

## The mental model

~~~text
Buffer owns handle ── C allocation
     |-- &self -> borrowed &[u8]
     |-- &mut self -> append may resize
     +-- Drop -> bb_free
~~~

The wrapper creates a safe API around a small unsafe boundary. The C declarations determine the ABI. The opaque Rust handle stands in for a C pointer. `repr(C)` gives the pointer-and-length view the layout the C function returns. Handle a zero-length view before constructing a Rust slice. The C buffer bounds every exposed nonempty slice by `PTRDIFF_MAX`, and its free function releases the allocation through the original allocator.

## Build it

### Step 1. Compile the C archive in Cargo

Use a build script to compile the two C files, put their objects in a static archive, and tell Cargo where to link it. Re-run when C sources, headers, or tool choices change.

<details>
<summary>Hint</summary>

Build into OUT_DIR. Use rustc-link-search for the archive directory and rustc-link-lib for its name.

</details>

<details>
<summary>Type-along answer</summary>

Create `Cargo.toml`.

<!-- file: Cargo.toml -->
~~~toml
[package]
name = "byte-bridge"
version = "0.1.0"
edition = "2024"
rust-version = "1.89"
~~~

Create `build.rs`.

<!-- file: build.rs -->
~~~rust
use std::{env, path::PathBuf, process::Command};

fn run(command: &mut Command) {
    let status = command.status().expect("start native build tool");
    assert!(status.success(), "failed native build: {command:?}");
}

fn main() {
    for path in [
        "c/byte_buffer.c",
        "c/byte_view.c",
        "include/byte_buffer.h",
        "include/byte_view.h",
    ] {
        println!("cargo:rerun-if-changed={path}");
    }
    println!("cargo:rerun-if-env-changed=CC");
    println!("cargo:rerun-if-env-changed=AR");
    let out = PathBuf::from(env::var_os("OUT_DIR").expect("Cargo build directory"));
    let cc = env::var_os("CC").unwrap_or_else(|| "cc".into());
    let ar = env::var_os("AR").unwrap_or_else(|| "ar".into());
    let mut objects = Vec::new();
    for name in ["byte_buffer", "byte_view"] {
        let object = out.join(format!("{name}.o"));
        run(Command::new(&cc)
            .args(["-std=c17", "-Wall", "-Wextra", "-Werror", "-Iinclude", "-c"])
            .arg(format!("c/{name}.c"))
            .arg("-o")
            .arg(&object));
        objects.push(object);
    }
    run(Command::new(ar)
        .arg("crs")
        .arg(out.join("libbyte_buffer.a"))
        .args(objects));
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=byte_buffer");
}
~~~

</details>
### Step 2. Bind the handle ownership

Construct the owner only after checking the raw handle for null. Implement a shared borrow, an exclusive append, and Drop. Write the safety reason at each call.

<details>
<summary>Hint</summary>

Tie the borrowed slice to &self by the method signature. The exclusive receiver then prevents growth while the view is still in use.

</details>

<details>
<summary>Type-along answer</summary>

Create `src/c_buffer.rs`.

<!-- file: src/c_buffer.rs -->
~~~rust
use std::{ffi::c_int, ptr::NonNull, slice};

#[repr(C)]
struct Handle {
    _private: [u8; 0],
}

#[repr(C)]
struct View {
    data: *const u8,
    len: usize,
}

unsafe extern "C" {
    fn bb_new() -> *mut Handle;
    fn bb_free(buffer: *mut Handle);
    fn bb_append(buffer: *mut Handle, data: *const u8, len: usize) -> c_int;
    fn bb_view(buffer: *const Handle) -> View;
    fn view_checksum(view: View) -> u64;
}

#[derive(Debug, PartialEq, Eq)]
pub struct BufferError(pub c_int);

pub struct Buffer {
    handle: NonNull<Handle>,
}

impl Buffer {
    pub fn new() -> Result<Self, BufferError> {
        // SAFETY: bb_new takes no inputs and returns an owned handle or null.
        let handle = NonNull::new(unsafe { bb_new() }).ok_or(BufferError(2))?;
        Ok(Self { handle })
    }

    pub fn append(&mut self, input: &[u8]) -> Result<(), BufferError> {
        // SAFETY: input is readable for the call. The exclusive borrow of
        // self prevents an overlapping slice taken from this buffer.
        match unsafe { bb_append(self.handle.as_ptr(), input.as_ptr(), input.len()) } {
            0 => Ok(()),
            status => Err(BufferError(status)),
        }
    }

    /// Borrow the initialized bytes. The borrow prevents buffer growth.
    ///
    /// ```,compile_fail
    /// use byte_bridge::c_buffer::Buffer;
    /// let mut buffer = Buffer::new().unwrap();
    /// let view = buffer.bytes();
    /// buffer.append(&[1]).unwrap();
    /// println!("{view:?}");
    /// ```
    pub fn bytes(&self) -> &[u8] {
        // SAFETY: the handle stays alive for the lifetime of this borrow.
        let view = unsafe { bb_view(self.handle.as_ptr()) };
        if view.len == 0 {
            return &[];
        }
        // SAFETY: C owns len initialized bytes bounded by PTRDIFF_MAX.
        // Mutation and destruction are excluded by the borrow.
        unsafe { slice::from_raw_parts(view.data, view.len) }
    }

    pub fn checksum(&self) -> u64 {
        let bytes = self.bytes();
        // SAFETY: C reads the live slice and retains no pointer.
        unsafe {
            view_checksum(View {
                data: bytes.as_ptr(),
                len: bytes.len(),
            })
        }
    }
}

impl Drop for Buffer {
    fn drop(&mut self) {
        // SAFETY: this value owns the handle and releases it once.
        unsafe { bb_free(self.handle.as_ptr()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn borrow_and_grow() {
        let mut buffer = Buffer::new().unwrap();
        assert!(buffer.bytes().is_empty());
        buffer.append(&[7, 0, 8]).unwrap();
        assert_eq!(buffer.bytes(), &[7, 0, 8]);
        buffer.append(&[1; 33]).unwrap();
        assert_eq!(&buffer.bytes()[..3], &[7, 0, 8]);
        assert_eq!(&buffer.bytes()[3..], &[1; 33]);
    }
}
~~~

</details>

Register the module in `src/lib.rs`.

<!-- file: src/lib.rs -->
~~~rust
pub mod c_buffer;
~~~
### Step 3. Read a binary fixture through the C library

Read the fixture, append it in chunks, and compare all returned bytes with the input before printing the C checksum.

<details>
<summary>Hint</summary>

Use file bytes and an explicit length, including zero bytes.

</details>

<details>
<summary>Type-along answer</summary>

Create `src/bin/rust_reads_c.rs`.

<!-- file: src/bin/rust_reads_c.rs -->
~~~rust
use byte_bridge::c_buffer::Buffer;
use std::fs;

fn main() -> Result<(), String> {
    let path = std::env::args_os()
        .nth(1)
        .ok_or("usage: rust_reads_c FIXTURE")?;
    let bytes = fs::read(path).map_err(|err| err.to_string())?;
    let mut buffer = Buffer::new().map_err(|err| format!("{err:?}"))?;
    for chunk in bytes.chunks(3) {
        buffer.append(chunk).map_err(|err| format!("{err:?}"))?;
    }
    if buffer.bytes() != bytes {
        return Err("buffer differs from fixture".into());
    }
    println!("{:016x}", buffer.checksum());
    Ok(())
}
~~~

</details>

## Check it

~~~bash
cargo fmt --check && cargo clippy --offline --all-targets -- -D warnings && cargo test --offline
~~~

<!-- run: cargo fmt --check && cargo clippy --offline --all-targets -- -D warnings && cargo test --offline -->

~~~text
test c_buffer::tests::borrow_and_grow ... ok
test src/c_buffer.rs - c_buffer::Buffer::bytes (line 47) - compile fail ... ok
~~~

The compile-fail doctest tries to grow the buffer while it still uses an earlier view. Its pass records that the compiler rejected the call.

[Reference capture](../evidence/05-rust.txt)

## Explain it

Which invariants make the wrapper's slice construction sound? Why must the destructor call C?
