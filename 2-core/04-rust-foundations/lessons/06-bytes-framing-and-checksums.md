# 06 Bytes, framing, and checksums

> About 6 hours · Work in the same `klog` package throughout the module.

## The problem

A file is a sequence of bytes. To recover one record at a time you need its exact length, an upper bound, and a way to tell when bytes have changed.

## The mental model

Each record has a 12-byte header followed by its payload. The first four bytes encode a little-endian length. Four bytes then hold the payload CRC-32C. The last four hold the CRC-32C of the preceding eight header bytes.

## The pattern

Verify the complete header before trusting the length or allocating a buffer. Verify the payload after all declared bytes arrive. Return a borrowed slice when data is already in memory.

## Build it

### Step 1. Write CRC-32C

The table holds the result for eight applications of the bit recurrence. A compile-time function builds the table. Test the implementation with the standard check value for the nine bytes `123456789`.

Create `src/crc.rs`.

<!-- file: src/crc.rs -->
~~~rust
//! CRC-32C (Castagnoli), the checksum used by many storage systems to
//! detect damaged bytes. A checksum can't repair damage or stop someone
//! who rewrites both the data and its checksum; it only detects accidents.

/// The Castagnoli polynomial, bit-reversed, as the table algorithm needs.
const POLYNOMIAL: u32 = 0x82F6_3B78;

/// A table of 256 precomputed values, built once at compile time, so the
/// checksum processes a whole byte per step instead of one bit.
const TABLE: [u32; 256] = build_table();

const fn build_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut crc = i as u32;
        let mut bit = 0;
        while bit < 8 {
            crc = if crc & 1 == 1 {
                (crc >> 1) ^ POLYNOMIAL
            } else {
                crc >> 1
            };
            bit += 1;
        }
        table[i] = crc;
        i += 1;
    }
    table
}

/// Returns the CRC-32C of data.
pub fn crc32c(data: &[u8]) -> u32 {
    let mut crc = !0u32;
    for &byte in data {
        crc = TABLE[((crc ^ byte as u32) & 0xFF) as usize] ^ (crc >> 8);
    }
    !crc
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_check_value() {
        // Every CRC-32C implementation must give this for "123456789".
        assert_eq!(crc32c(b"123456789"), 0xE306_9283);
    }

    #[test]
    fn empty_input() {
        assert_eq!(crc32c(b""), 0);
    }

    #[test]
    fn one_changed_bit_changes_the_checksum() {
        let mut data = b"job 7 completed".to_vec();
        let before = crc32c(&data);
        data[4] ^= 0b0000_0001;
        assert_ne!(crc32c(&data), before);
    }
}
~~~

Add this to `src/lib.rs`.

<!-- append: src/lib.rs -->
~~~rust
pub mod crc;
~~~

### Step 2. Define the frame and check its length before slicing

The size cap limits memory when reading untrusted bytes. The header CRC also protects the stored payload checksum. When a length field is damaged, the reader can refuse the header even if that length would appear to extend past EOF. The conversions use `unwrap` only on slices whose length is already fixed by the array type or checked by `get`.

Create `src/record.rs`.

<!-- file: src/record.rs -->
~~~rust
use std::fmt;

use crate::crc::crc32c;

pub const HEADER_LEN: usize = 12;
pub const MAX_PAYLOAD: usize = 1024 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum RecordError {
    Incomplete,
    TooLarge(usize),
    HeaderChecksum,
    PayloadChecksum,
}

impl fmt::Display for RecordError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Incomplete => write!(f, "incomplete frame"),
            Self::TooLarge(n) => write!(f, "payload length {n} exceeds {MAX_PAYLOAD}"),
            Self::HeaderChecksum => write!(f, "header checksum mismatch"),
            Self::PayloadChecksum => write!(f, "payload checksum mismatch"),
        }
    }
}

impl std::error::Error for RecordError {}

// The header is written separately from its payload so the writer
// can accept a borrowed payload without assembling a second copy.
pub fn encode_header(payload: &[u8]) -> Result<[u8; HEADER_LEN], RecordError> {
    if payload.len() > MAX_PAYLOAD {
        return Err(RecordError::TooLarge(payload.len()));
    }
    let mut bytes = [0; HEADER_LEN];
    bytes[..4].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    bytes[4..8].copy_from_slice(&crc32c(payload).to_le_bytes());
    let guard = crc32c(&bytes[..8]);
    bytes[8..].copy_from_slice(&guard.to_le_bytes());
    Ok(bytes)
}

pub(crate) struct Header {
    pub len: usize,
    checksum: u32,
}

pub(crate) fn parse_header(bytes: &[u8; HEADER_LEN]) -> Result<Header, RecordError> {
    let guard = u32::from_le_bytes(bytes[8..].try_into().unwrap());
    if crc32c(&bytes[..8]) != guard {
        return Err(RecordError::HeaderChecksum);
    }
    let len = u32::from_le_bytes(bytes[..4].try_into().unwrap()) as usize;
    if len > MAX_PAYLOAD {
        return Err(RecordError::TooLarge(len));
    }
    let checksum = u32::from_le_bytes(bytes[4..8].try_into().unwrap());
    Ok(Header { len, checksum })
}

pub(crate) fn verify(header: &Header, payload: &[u8]) -> Result<(), RecordError> {
    if crc32c(payload) != header.checksum {
        return Err(RecordError::PayloadChecksum);
    }
    Ok(())
}

pub fn decode(input: &[u8]) -> Result<(&[u8], usize), RecordError> {
    let bytes = input.get(..HEADER_LEN).ok_or(RecordError::Incomplete)?;
    let header = parse_header(bytes.try_into().unwrap())?;
    let end = HEADER_LEN + header.len;
    let payload = input.get(HEADER_LEN..end).ok_or(RecordError::Incomplete)?;
    verify(&header, payload)?;
    Ok((payload, end))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame(payload: &[u8]) -> Vec<u8> {
        let mut out = encode_header(payload).unwrap().to_vec();
        out.extend_from_slice(payload);
        out
    }

    #[test]
    fn a_view_borrows_only_one_payload() {
        let mut bytes = frame(b"hello");
        bytes.extend_from_slice(&frame(b"world"));
        let (payload, next) = decode(&bytes).unwrap();
        assert_eq!(payload, b"hello");
        assert_eq!(payload.as_ptr(), bytes[HEADER_LEN..].as_ptr());
        assert_eq!(decode(&bytes[next..]).unwrap().0, b"world");
    }

    #[test]
    fn every_incomplete_cut_is_detected() {
        let bytes = frame(b"hello");
        for cut in 0..bytes.len() {
            assert_eq!(decode(&bytes[..cut]), Err(RecordError::Incomplete));
        }
    }

    #[test]
    fn damage_in_header_and_payload_is_detected() {
        let mut bytes = frame(b"hello");
        bytes[0] ^= 1;
        assert_eq!(decode(&bytes), Err(RecordError::HeaderChecksum));
        bytes[0] ^= 1;
        bytes[HEADER_LEN] ^= 1;
        assert_eq!(decode(&bytes), Err(RecordError::PayloadChecksum));
    }

    #[test]
    fn payload_cap_and_empty_records() {
        assert_eq!(decode(&frame(b"")).unwrap().0, b"");
        let oversized = vec![0; MAX_PAYLOAD + 1];
        assert_eq!(
            encode_header(&oversized),
            Err(RecordError::TooLarge(oversized.len()))
        );

        let mut header = [0; HEADER_LEN];
        header[..4].copy_from_slice(&((MAX_PAYLOAD + 1) as u32).to_le_bytes());
        let guard = crc32c(&header[..8]);
        header[8..].copy_from_slice(&guard.to_le_bytes());
        assert_eq!(decode(&header), Err(RecordError::TooLarge(oversized.len())));
    }
}
~~~

Add this to `src/lib.rs`.

<!-- append: src/lib.rs -->
~~~rust
pub mod record;
~~~

### Step 3. Inspect a complete frame

Create `src/bin/frame-demo.rs`.

<!-- file: src/bin/frame-demo.rs -->
~~~rust
fn main() {
    let payload = b"job";
    let header = klog::record::encode_header(payload).expect("a small record fits");
    println!("header: {header:02x?}");
    println!("payload: {payload:02x?}");
}
~~~

~~~bash
cargo run --quiet --bin frame-demo
~~~

<!-- run: cargo run --quiet --bin frame-demo -->

~~~text
header: [03, 00, 00, 00, 11, 78, 63, d6, 38, 9d, 96, 4c]
payload: [6a, 6f, 62]
~~~

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Read the first four bytes of the captured frame and identify the byte order. Predict which check fails when you flip a bit in the length, the stored checksum, or the payload.

## If it goes wrong

Check the known CRC-32C value first if all checksum tests fail. The algorithm uses a reflected polynomial, an all-ones starting value, and a final complement.
