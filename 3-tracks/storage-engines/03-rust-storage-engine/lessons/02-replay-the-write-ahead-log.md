# 02 Make acknowledged writes recoverable

> A Rust storage engine · Week 1 · Builds on lesson 01

## The problem

A process can stop before its in-memory writes reach disk. After restart, a caller still expects every acknowledged mutation, including a deletion, to be reflected.

## The mental model

Encode the sequence, key, and optional value. Append one framed record and sync it. Apply the mutation in memory and return the sequence to the caller. Reopening rebuilds the memtable from complete records in sequence order.

## The pattern

A write-ahead log (WAL) is the durable record of a mutation before acknowledgment. This lesson reuses `klog` framing and its handling of incomplete tails and checksum errors. The engine adds its own version tag and validates consecutive sequence numbers.

## Build it

### Step 1 — Read under the writer lock

Add a visitor to the already open log so recovery can read the repaired file without releasing the lock.

<details>
<summary>Hint</summary>

Seek to byte zero, then call the same verified scanner. A separate read handle would contend for the lock.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `klog/src/log.rs` in order.

<!-- edit: klog/src/log.rs -->
~~~rust
use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use crate::record::{self, HEADER_LEN, RecordError};
~~~

Replace the selected lines with this block.

~~~rust
use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use crate::record::{self, HEADER_LEN, RecordError};
~~~

<!-- edit: klog/src/log.rs -->
~~~rust
        self.recovered_bytes
    }

    pub fn append(&mut self, payload: &[u8]) -> Result<u64, LogError> {
        if self.failed {
            return Err(LogError::WriterFailed);
~~~

Replace the selected lines with this block.

~~~rust
        self.recovered_bytes
    }

    /// Visit the verified records while keeping the exclusive writer lock.
    pub fn visit(&mut self, visit: impl FnMut(&[u8]) -> io::Result<()>) -> Result<(), LogError> {
        self.file.seek(SeekFrom::Start(0))?;
        let progress = scan(&mut self.file, visit)?;
        if progress.torn_bytes != 0 {
            return Err(LogError::Torn {
                offset: progress.offset,
                bytes: progress.torn_bytes,
            });
        }
        Ok(())
    }

    pub fn append(&mut self, payload: &[u8]) -> Result<u64, LogError> {
        if self.failed {
            return Err(LogError::WriterFailed);
~~~

</details>

### Step 2 — Encode the mutation

Write the fields in a fixed order. Give deletes a distinct length tag and cap sizes before copying.

<details>
<summary>Hint</summary>

Zero length is the valid encoding for an empty value. Use a different tag for a tombstone.

</details>

<details>
<summary>Implementation</summary>

Create `src/codec.rs`.

<!-- file: src/codec.rs -->
~~~rust
use std::io;

pub const MAX_KEY: usize = 1024;
pub const MAX_VALUE: usize = 32 * 1024;

pub fn invalid(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

pub fn u32_to(out: &mut Vec<u8>, number: u32) {
    out.extend(number.to_le_bytes());
}

pub fn u64_to(out: &mut Vec<u8>, number: u64) {
    out.extend(number.to_le_bytes());
}

pub struct Cursor<'a>(&'a [u8]);

impl<'a> Cursor<'a> {
    pub fn new(input: &'a [u8]) -> Self {
        Self(input)
    }

    pub fn take(&mut self, len: usize) -> io::Result<&'a [u8]> {
        let (value, rest) = self
            .0
            .split_at_checked(len)
            .ok_or_else(|| invalid("short payload"))?;
        self.0 = rest;
        Ok(value)
    }

    pub fn u32(&mut self) -> io::Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    pub fn u64(&mut self) -> io::Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    pub fn done(self) -> io::Result<()> {
        if self.0.is_empty() {
            Ok(())
        } else {
            Err(invalid("unexpected trailing bytes"))
        }
    }
}
~~~

Create `src/entry.rs`.

<!-- file: src/entry.rs -->
~~~rust
use std::io;

use crate::codec::{Cursor, MAX_KEY, MAX_VALUE, invalid, u32_to, u64_to};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Version {
    pub seq: u64,
    pub value: Option<Vec<u8>>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Entry {
    pub key: Vec<u8>,
    pub version: Version,
}

impl Entry {
    pub fn new(key: &[u8], seq: u64, value: Option<&[u8]>) -> io::Result<Self> {
        if key.len() > MAX_KEY || value.is_some_and(|value| value.len() > MAX_VALUE) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "key or value exceeds size limit",
            ));
        }
        Ok(Self {
            key: key.to_vec(),
            version: Version {
                seq,
                value: value.map(<[u8]>::to_vec),
            },
        })
    }

    pub fn encode(&self, out: &mut Vec<u8>) {
        u64_to(out, self.version.seq);
        u32_to(out, self.key.len() as u32);
        u32_to(
            out,
            self.version
                .value
                .as_ref()
                .map_or(u32::MAX, |v| v.len() as u32),
        );
        out.extend(&self.key);
        if let Some(value) = &self.version.value {
            out.extend(value);
        }
    }

    pub fn decode(cursor: &mut Cursor<'_>) -> io::Result<Self> {
        let seq = cursor.u64()?;
        let key_len = cursor.u32()? as usize;
        let value_len = cursor.u32()?;
        if seq == 0
            || key_len > MAX_KEY
            || (value_len != u32::MAX && value_len as usize > MAX_VALUE)
        {
            return Err(invalid("invalid entry sequence or size"));
        }
        let key = cursor.take(key_len)?.to_vec();
        let value = if value_len == u32::MAX {
            None
        } else {
            Some(cursor.take(value_len as usize)?.to_vec())
        };
        Ok(Self {
            key,
            version: Version { seq, value },
        })
    }
}
~~~

</details>

### Step 3 — Move the acknowledgment boundary

Write the record before updating the memtable, then replay the same format on open.

<details>
<summary>Hint</summary>

Compare the restored record sequence with the next expected sequence. Advance the live sequence only after append succeeds.

</details>

<details>
<summary>Implementation</summary>

Replace `src/lib.rs`.

<!-- file: src/lib.rs -->
~~~rust
mod codec;
mod entry;

use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::Path;

use klog::log::Log;

use codec::{Cursor, invalid};
use entry::{Entry, Version};

pub type Row = (Vec<u8>, Vec<u8>);

pub struct Store {
    seq: u64,
    mem: BTreeMap<Vec<u8>, Vec<Version>>,
    wal: Log,
}

impl Store {
    pub fn open(dir: &Path) -> io::Result<Self> {
        fs::create_dir_all(dir)?;
        let mut wal = Log::open(&dir.join("wal")).map_err(io::Error::other)?;
        let mut seq = 0_u64;
        let mut mem: BTreeMap<Vec<u8>, Vec<Version>> = BTreeMap::new();
        wal.visit(|record| {
            let mut cursor = Cursor::new(record);
            if cursor.take(4)? != b"LSW1" {
                return Err(invalid("unexpected WAL version"));
            }
            let entry = Entry::decode(&mut cursor)?;
            cursor.done()?;
            if Some(entry.version.seq) != seq.checked_add(1) {
                return Err(invalid("nonconsecutive WAL sequence"));
            }
            seq = entry.version.seq;
            mem.entry(entry.key).or_default().push(entry.version);
            Ok(())
        })
        .map_err(io::Error::other)?;
        Ok(Self { seq, mem, wal })
    }

    pub fn sequence(&self) -> u64 {
        self.seq
    }

    pub fn recovered_bytes(&self) -> u64 {
        self.wal.recovered_bytes()
    }

    pub fn put(&mut self, key: &[u8], value: &[u8]) -> io::Result<u64> {
        self.change(key, Some(value))
    }

    pub fn delete(&mut self, key: &[u8]) -> io::Result<u64> {
        self.change(key, None)
    }

    fn change(&mut self, key: &[u8], value: Option<&[u8]>) -> io::Result<u64> {
        let next = self
            .seq
            .checked_add(1)
            .ok_or_else(|| invalid("sequence exhausted"))?;
        let entry = Entry::new(key, next, value)?;
        let mut bytes = b"LSW1".to_vec();
        entry.encode(&mut bytes);
        self.wal.append(&bytes).map_err(io::Error::other)?;
        self.seq = next;
        self.mem.entry(entry.key).or_default().push(entry.version);
        Ok(next)
    }

    pub fn get(&self, key: &[u8]) -> Option<&[u8]> {
        self.mem.get(key)?.last()?.value.as_deref()
    }

    pub fn scan(&self, start: &[u8], end: &[u8]) -> Vec<Row> {
        if start >= end {
            return Vec::new();
        }
        self.mem
            .range::<[u8], _>((
                std::ops::Bound::Included(start),
                std::ops::Bound::Excluded(end),
            ))
            .filter_map(|(key, versions)| Some((key.clone(), versions.last()?.value.clone()?)))
            .collect()
    }
}
~~~

</details>

### Step 4 — Exercise the two damaged-file cases

Append three bytes to a good WAL, then separately flip a payload byte in a complete record. Read the file after both opens.

<details>
<summary>Hint</summary>

Tail repair should truncate bytes. Complete corruption should preserve the original damaged file and fail the open.

</details>

<details>
<summary>Implementation</summary>

Create `tests/wal.rs`.

<!-- file: tests/wal.rs -->
~~~rust
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

use lsm::Store;

struct Temp(PathBuf);

impl Temp {
    fn new() -> Self {
        static NEXT: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "lsm-wal-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed),
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn replay_torn_tail_and_refuse_corruption() {
    let dir = Temp::new();
    let mut db = Store::open(&dir.0).unwrap();
    assert_eq!(db.put(b"job", b"queued").unwrap(), 1);
    assert_eq!(db.put(b"empty", b"").unwrap(), 2);
    assert_eq!(db.delete(b"job").unwrap(), 3);
    drop(db);

    let path = dir.0.join("wal");
    let original = fs::read(&path).unwrap();
    fs::OpenOptions::new()
        .append(true)
        .open(&path)
        .unwrap()
        .write_all(&[0, 0, 0])
        .unwrap();
    let db = Store::open(&dir.0).unwrap();
    assert_eq!(db.recovered_bytes(), 3);
    assert_eq!(db.sequence(), 3);
    assert_eq!(db.get(b"empty"), Some(b"".as_slice()));
    assert_eq!(db.get(b"job"), None);
    assert_eq!(db.scan(b"", b"z"), vec![(b"empty".to_vec(), vec![])]);
    drop(db);
    assert_eq!(fs::read(&path).unwrap(), original);

    let mut broken = original;
    broken[klog::record::HEADER_LEN] ^= 1;
    fs::write(&path, &broken).unwrap();
    let error = Store::open(&dir.0).err().expect("corruption must fail");
    assert!(
        error.to_string().contains("payload checksum mismatch"),
        "{error}"
    );
    assert_eq!(fs::read(&path).unwrap(), broken);
    println!(
        "replayed through sequence 3, trimmed 3 bytes, and preserved the corrupt frame on refusal"
    );
}
~~~

</details>

## Check it

~~~bash
cargo test --offline --locked --quiet --test wal -- --nocapture
~~~

<!-- run: cargo fmt --check && cargo clippy --offline --locked --quiet --all-targets -- -D warnings && cargo test --offline --locked --quiet --test wal -- --nocapture -->

The check reached sequence 3, trimmed 3 tail bytes, and preserved the corrupt frame when it refused to open.

## If it goes wrong

If replay applies a deletion as an empty value, check the length sentinel. If recovery tries to acquire another reader lock, use the visitor on the existing writer.
