# 01 Memory layout is an interface

> About 5 hours · Continue the `klog` package.

<!-- continue: ../../04-rust-foundations -->

## The problem

A Rust struct has a memory layout, while a received byte stream has a wire format. You need both when exchanging data with C and reading frames.

## The mental model

`size_of` includes padding. Alignment restricts usable addresses. `repr(C)` uses target C field layout rules. Wire bytes stay in the order the protocol specifies.

## The pattern

Read sizes and offsets from the target. Encode wire numbers explicitly and leave padding out of the protocol.

## Build it

### Step 1. Measure the layout

Keep your finished Core 04 checkout. The replay starts by rebuilding its `klog` package. Here the field widths match a possible C struct. `offset_of!` tells you where a field begins on the target you are running.

Create `src/bin/layout.rs`.

<!-- file: src/bin/layout.rs -->
~~~rust
use std::mem::{align_of, offset_of, size_of};

#[repr(C)]
struct Header {
    kind: u8,
    sequence: u64,
    length: u32,
}

fn main() {
    println!(
        "size={} align={}",
        size_of::<Header>(),
        align_of::<Header>()
    );
    println!(
        "kind={} sequence={} length={}",
        offset_of!(Header, kind),
        offset_of!(Header, sequence),
        offset_of!(Header, length)
    );
    let sequence = 0x0102_0304_0506_0708u64;
    println!("sequence on wire: {:02x?}", sequence.to_le_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn representation_respects_field_order_and_alignment() {
        assert_eq!(offset_of!(Header, kind), 0);
        assert_eq!(offset_of!(Header, sequence) % align_of::<u64>(), 0);
        assert!(offset_of!(Header, length) >= offset_of!(Header, sequence) + size_of::<u64>());
        assert_eq!(size_of::<Header>() % align_of::<Header>(), 0);
    }
}
~~~

~~~bash
cargo run --quiet --bin layout
~~~

<!-- run: cargo run --quiet --bin layout -->

~~~text
size=24 align=8
kind=0 sequence=8 length=16
sequence on wire: [08, 07, 06, 05, 04, 03, 02, 01]
~~~

### Step 2. Draw padding and choose a wire representation

Mark the gap after kind and any bytes after length. Keep the explicit little-endian record format from Core 04. A decoder can receive bytes at any address, regardless of the alignment a Rust reference to Header would require.

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Draw the measured layout. Explain why its struct size differs from the sum of field sizes and why reading a wire buffer as that struct would add alignment and validity obligations.

## If it goes wrong

If a different target prints different offsets, check the target alignment of its integer types. The tests check the relationships they rely on.
