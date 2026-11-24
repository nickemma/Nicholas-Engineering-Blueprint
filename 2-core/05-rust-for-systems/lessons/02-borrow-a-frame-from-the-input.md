# 02 Borrow a frame from the input

> About 6 hours · Continue the `klog` package.

## The problem

One read can contain several frames or only part of the next one. Returning a copied payload for every frame wastes work.

## The mental model

`input: &[header | payload | next header ...]` owns no bytes. A cursor advances its slice. Each returned payload borrows a range of the original buffer.

## The pattern

Advance only after validating a complete frame. Keep incompleteness and corruption distinct.

## Build it

### Step 1. Separate a complete frame from a partial feed

Reuse `klog::record::decode` from Core 04. Keep the current slice unchanged until decoding succeeds. Use an explicit lifetime for the input and output, so the borrowed payload remains usable after the cursor moves forward.

Create `src/frame_cursor.rs`.

<!-- file: src/frame_cursor.rs -->
~~~rust
use crate::record::{self, RecordError};

pub struct FrameCursor<'a> {
    remaining: &'a [u8],
}

impl<'a> FrameCursor<'a> {
    pub fn new(input: &'a [u8]) -> Self {
        Self { remaining: input }
    }

    pub fn next_frame(&mut self) -> Result<Option<&'a [u8]>, RecordError> {
        match record::decode(self.remaining) {
            Ok((payload, used)) => {
                self.remaining = &self.remaining[used..];
                Ok(Some(payload))
            }
            Err(RecordError::Incomplete) => Ok(None),
            Err(error) => Err(error),
        }
    }

    pub fn remaining(&self) -> &'a [u8] {
        self.remaining
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(payload: &[u8]) -> Vec<u8> {
        let mut bytes = record::encode_header(payload).unwrap().to_vec();
        bytes.extend_from_slice(payload);
        bytes
    }

    #[test]
    fn reads_multiple_frames_without_copying_the_payloads() {
        let mut bytes = frame(b"ready");
        bytes.extend(frame(b"done"));
        let mut cursor = FrameCursor::new(&bytes);
        let first = cursor.next_frame().unwrap().unwrap();
        let second = cursor.next_frame().unwrap().unwrap();
        assert_eq!((first, second), (b"ready".as_slice(), b"done".as_slice()));
        assert_eq!(first.as_ptr(), bytes[record::HEADER_LEN..].as_ptr());
        assert!(cursor.next_frame().unwrap().is_none());
    }

    #[test]
    fn preserves_incomplete_or_corrupt_input() {
        let mut bytes = frame(b"payload");
        for cut in 0..bytes.len() {
            let mut cursor = FrameCursor::new(&bytes[..cut]);
            assert_eq!(cursor.next_frame(), Ok(None));
            assert_eq!(cursor.remaining(), &bytes[..cut]);
        }
        bytes[0] ^= 1;
        let mut cursor = FrameCursor::new(&bytes);
        assert_eq!(cursor.next_frame(), Err(RecordError::HeaderChecksum));
        assert_eq!(cursor.remaining(), bytes);
    }
}
~~~

Register the module in `src/lib.rs`.

<!-- append: src/lib.rs -->
~~~rust
pub mod frame_cursor;
~~~

### Step 2. Prove the parser borrows the caller’s bytes

The test compares the payload pointer to the address inside the original buffer. `Ok(None)` leaves a suffix for the caller to retain and combine with the next read. In a network reader, bound that retained buffer.

~~~bash
cargo test --quiet frame_cursor::tests --lib
~~~

<!-- run: cargo test --quiet frame_cursor::tests --lib -->

~~~text

running 2 tests
..
test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 22 filtered out; finished in 0.00s
~~~

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Draw the original slice and the two returned payload slices. Explain why a caller cannot grow the input vector while either borrowed payload remains live.

## If it goes wrong

If the caller sees the same partial bytes repeatedly, have it read more bytes or report EOF. Handle a checksum error before attempting another decode of the same input.
