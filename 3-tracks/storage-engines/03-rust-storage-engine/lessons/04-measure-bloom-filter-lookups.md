# 04 Seek to a block and skip absent keys

> A Rust storage engine · Week 2 · Builds on lesson 03

## The problem

An absent key can still lie between the first and last keys of many blocks. The engine would otherwise read blocks just to discover the key is missing.

## The mental model

Each run stores a bit array. On build, a key sets several positions. On lookup, an unset position lets the engine skip the whole run for that key. An all-set result goes through the index and block lookup.

## The pattern

A Bloom filter is a probabilistic membership test. False positives cost work. A false negative can return an old value or hide a stored key, so build the filter from every represented key, including tombstones. Preserve the previous SSTable format as a readable run without a filter.

## Build it

### Step 1 — Build a stable bit mapping

Choose six reproducible probe positions and set them during table creation.

<details>
<summary>Hint</summary>

Use deterministic integer hashing so reopening computes the same bit positions.

</details>

<details>
<summary>Implementation</summary>

Create `src/bloom.rs`.

<!-- file: src/bloom.rs -->
~~~rust
// Six probes, generated from two stable 64-bit hashes of the byte key.
const PROBES: u64 = 6;
const MAX_BYTES: usize = 512 * 1024;

pub struct Bloom(Vec<u8>);

impl Bloom {
    pub fn new(entries: usize) -> Self {
        let bytes = entries.saturating_mul(10).div_ceil(8).clamp(8, MAX_BYTES);
        Self(vec![0; bytes])
    }

    pub fn decode(bytes: Vec<u8>) -> Option<Self> {
        (8..=MAX_BYTES)
            .contains(&bytes.len())
            .then_some(Self(bytes))
    }

    pub fn raw(&self) -> &[u8] {
        &self.0
    }

    pub fn insert(&mut self, key: &[u8]) {
        for bit in probes(key, self.0.len()) {
            self.0[bit / 8] |= 1 << (bit % 8);
        }
    }

    pub fn may_contain(&self, key: &[u8]) -> bool {
        probes(key, self.0.len()).all(|bit| self.0[bit / 8] & (1 << (bit % 8)) != 0)
    }
}

fn probes(key: &[u8], bytes: usize) -> impl Iterator<Item = usize> {
    let first = key.iter().fold(0xcbf29ce484222325_u64, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3)
    });
    let mix = (first ^ (first >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
    let second = ((mix ^ (mix >> 27)).wrapping_mul(0x94d049bb133111eb) ^ (mix >> 31)) | 1;
    (0..PROBES)
        .map(move |i| (first.wrapping_add(i.wrapping_mul(second)) % (bytes * 8) as u64) as usize)
}
~~~

</details>

### Step 2 — Persist the filter and keep the old reader path

Write the filter before the new table’s block index. Use the header version to open older files without a filter.

<details>
<summary>Hint</summary>

Check the filter frame’s checksum and length before using it.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `src/table.rs` in order.

<!-- edit: src/table.rs -->
~~~rust
use std::os::unix::fs::FileExt;
use std::path::Path;

use crate::codec::{Cursor, MAX_KEY, invalid, u32_to, u64_to};
use crate::disk::{read_frame, write_frame};
use crate::entry::Entry;

const MAGIC: &[u8] = b"LST1";
const BLOCK_ENTRIES: usize = 16;
const FOOTER_SIZE: u64 = (klog::record::HEADER_LEN + 8) as u64;
~~~

Replace the selected lines with this block.

~~~rust
use std::os::unix::fs::FileExt;
use std::path::Path;

use crate::ProbeStats;
use crate::bloom::Bloom;
use crate::codec::{Cursor, MAX_KEY, invalid, u32_to, u64_to};
use crate::disk::{read_frame, write_frame};
use crate::entry::Entry;

const MAGIC: &[u8] = b"LST2";
const BLOCK_ENTRIES: usize = 16;
const FOOTER_SIZE: u64 = (klog::record::HEADER_LEN + 8) as u64;
~~~

<!-- edit: src/table.rs -->
~~~rust
pub struct Table {
    file: File,
    blocks: Vec<Block>,
}

impl Table {
~~~

Replace the selected lines with this block.

~~~rust
pub struct Table {
    file: File,
    blocks: Vec<Block>,
    filter: Option<Bloom>,
}

impl Table {
~~~

<!-- edit: src/table.rs -->
~~~rust
            });
            at = end;
        }
        for block in blocks {
            write_frame(&mut file, &block.encode())?;
        }
~~~

Replace the selected lines with this block.

~~~rust
            });
            at = end;
        }
        let mut filter = Bloom::new(entries.len());
        for entry in entries {
            filter.insert(&entry.key);
        }
        write_frame(&mut file, filter.raw())?;
        for block in blocks {
            write_frame(&mut file, &block.encode())?;
        }
~~~

<!-- edit: src/table.rs -->
~~~rust
            .ok_or_else(|| invalid("missing table footer"))?;
        let mut magic = [0; 4];
        file.read_exact_at(&mut magic, 0)?;
        if magic != MAGIC {
            return Err(invalid("unknown table format"));
        }
        let (data, next) = read_frame(&file, footer, end)?;
~~~

Replace the selected lines with this block.

~~~rust
            .ok_or_else(|| invalid("missing table footer"))?;
        let mut magic = [0; 4];
        file.read_exact_at(&mut magic, 0)?;
        if magic != MAGIC && &magic != b"LST1" {
            return Err(invalid("unknown table format"));
        }
        let (data, next) = read_frame(&file, footer, end)?;
~~~

<!-- edit: src/table.rs -->
~~~rust
        if next != end || index <= MAGIC.len() as u64 || index >= footer {
            return Err(invalid("invalid table index offset"));
        }
        let mut at = index;
        let mut expected = MAGIC.len() as u64;
        let mut blocks: Vec<Block> = Vec::new();
        while at < footer {
~~~

Replace the selected lines with this block.

~~~rust
        if next != end || index <= MAGIC.len() as u64 || index >= footer {
            return Err(invalid("invalid table index offset"));
        }
        let (mut at, filter) = if magic == MAGIC {
            let (data, first) = read_frame(&file, index, footer)?;
            let filter =
                Bloom::decode(data).ok_or_else(|| invalid("invalid Bloom filter length"))?;
            (first, Some(filter))
        } else {
            (index, None)
        };
        let mut expected = MAGIC.len() as u64;
        let mut blocks: Vec<Block> = Vec::new();
        while at < footer {
~~~

<!-- edit: src/table.rs -->
~~~rust
        if blocks.is_empty() || expected != index {
            return Err(invalid("index does not cover table data"));
        }
        Ok(Self { file, blocks })
    }

    fn read(&self, block: &Block) -> io::Result<Vec<Entry>> {
~~~

Replace the selected lines with this block.

~~~rust
        if blocks.is_empty() || expected != index {
            return Err(invalid("index does not cover table data"));
        }
        Ok(Self {
            file,
            blocks,
            filter,
        })
    }

    fn read(&self, block: &Block) -> io::Result<Vec<Entry>> {
~~~

<!-- edit: src/table.rs -->
~~~rust
        Ok(entries)
    }

    pub fn point(&self, key: &[u8]) -> io::Result<Vec<Entry>> {
        let index = self
            .blocks
            .partition_point(|block| block.last.as_slice() < key);
~~~

Replace the selected lines with this block.

~~~rust
        Ok(entries)
    }

    pub fn point(
        &self,
        key: &[u8],
        use_filter: bool,
        stats: &mut ProbeStats,
    ) -> io::Result<Vec<Entry>> {
        let filter = self.filter.as_ref().filter(|_| use_filter);
        if filter.is_some_and(|filter| !filter.may_contain(key)) {
            stats.filter_negatives += 1;
            return Ok(Vec::new());
        }
        let index = self
            .blocks
            .partition_point(|block| block.last.as_slice() < key);
~~~

<!-- edit: src/table.rs -->
~~~rust
            if block.first.as_slice() > key {
                break;
            }
            matches.extend(
                self.read(block)?
                    .into_iter()
                    .filter(|entry| entry.key == key),
            );
        }
        Ok(matches)
    }
~~~

Replace the selected lines with this block.

~~~rust
            if block.first.as_slice() > key {
                break;
            }
            stats.block_reads += 1;
            matches.extend(
                self.read(block)?
                    .into_iter()
                    .filter(|entry| entry.key == key),
            );
        }
        if filter.is_some() && matches.is_empty() {
            stats.false_positives += 1;
        }
        Ok(matches)
    }
~~~

</details>

### Step 3 — Count the lookup work

Return checked data blocks, negative filter decisions, and positive filter decisions for keys absent from that run. Add a way to bypass filters for the same data.

<details>
<summary>Hint</summary>

Count blocks read at the point where the engine requests a data frame. An index miss can still follow a positive filter result.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `src/lib.rs` in order.

<!-- edit: src/lib.rs -->
~~~rust
mod codec;
mod disk;
mod entry;
~~~

Replace the selected lines with this block.

~~~rust
mod bloom;
mod codec;
mod disk;
mod entry;
~~~

<!-- edit: src/lib.rs -->
~~~rust
use entry::{Entry, Version};
use manifest::{Manifest, create_wal, table_path, wal_path};
use table::Table;

pub type Row = (Vec<u8>, Vec<u8>);
~~~

Replace the selected lines with this block.

~~~rust
use entry::{Entry, Version};
use manifest::{Manifest, create_wal, table_path, wal_path};
use table::Table;

#[derive(Debug, Default, Eq, PartialEq)]
pub struct ProbeStats {
    pub block_reads: u64,
    pub filter_negatives: u64,
    pub false_positives: u64,
}

pub type Row = (Vec<u8>, Vec<u8>);
~~~

<!-- edit: src/lib.rs -->
~~~rust
    }

    pub fn get(&self, key: &[u8]) -> io::Result<Option<Vec<u8>>> {
        self.ensure_live()?;
        let mut best = self
            .mem
            .get(key)
            .and_then(|versions| versions.last())
            .cloned();
        for table in &self.tables {
            for entry in table.point(key)? {
                if best
                    .as_ref()
                    .is_none_or(|version| version.seq < entry.version.seq)
~~~

Replace the selected lines with this block.

~~~rust
    }

    pub fn get(&self, key: &[u8]) -> io::Result<Option<Vec<u8>>> {
        self.get_with_stats(key, true).map(|(value, _)| value)
    }

    pub fn get_with_stats(
        &self,
        key: &[u8],
        use_filter: bool,
    ) -> io::Result<(Option<Vec<u8>>, ProbeStats)> {
        self.ensure_live()?;
        let mut stats = ProbeStats::default();
        let mut best = self
            .mem
            .get(key)
            .and_then(|versions| versions.last())
            .cloned();
        for table in &self.tables {
            for entry in table.point(key, use_filter, &mut stats)? {
                if best
                    .as_ref()
                    .is_none_or(|version| version.seq < entry.version.seq)
~~~

<!-- edit: src/lib.rs -->
~~~rust
                }
            }
        }
        Ok(best.and_then(|version| version.value))
    }

    pub fn scan(&self, start: &[u8], end: &[u8]) -> io::Result<Vec<Row>> {
~~~

Replace the selected lines with this block.

~~~rust
                }
            }
        }
        Ok((best.and_then(|version| version.value), stats))
    }

    pub fn scan(&self, start: &[u8], end: &[u8]) -> io::Result<Vec<Row>> {
~~~

</details>

### Step 4 — Compare results as well as cost

Test all keys in a two-run fixture where older values must stay hidden behind newer tombstones.

<details>
<summary>Hint</summary>

If the lookup of a deleted key returns an older value, compare its filter-on and filter-off results before changing the hash.

</details>

<details>
<summary>Implementation</summary>

Create `tests/bloom.rs`.

<!-- file: tests/bloom.rs -->
~~~rust
use std::{fs, io};

use lsm::Store;

#[test]
fn filters_reduce_absent_block_reads_without_hiding_tombstones() -> io::Result<()> {
    let dir = std::env::temp_dir().join(format!("lsm-bloom-{}", std::process::id()));
    fs::create_dir(&dir)?;
    let result = (|| {
        let mut db = Store::open(&dir)?;
        for number in (0_u16..1024).step_by(2) {
            db.put(&number.to_be_bytes(), b"value")?;
        }
        db.flush()?;
        for number in (0_u16..1024).step_by(8) {
            db.delete(&number.to_be_bytes())?;
        }
        db.flush()?;
        drop(db);
        let db = Store::open(&dir)?;
        let (mut filtered, mut plain, mut false_positives) = (0, 0, 0);
        for number in 0_u16..1024 {
            let key = number.to_be_bytes();
            let (without, scan) = db.get_with_stats(&key, false)?;
            let (with, bloom) = db.get_with_stats(&key, true)?;
            let expected = (number % 2 == 0 && number % 8 != 0).then(|| b"value".to_vec());
            assert_eq!(with, expected, "key {number}");
            assert_eq!(without, with, "key {number}");
            if number % 2 != 0 {
                plain += scan.block_reads;
                filtered += bloom.block_reads;
                false_positives += bloom.false_positives;
            }
        }
        assert!(filtered < plain, "{filtered} vs {plain}");
        println!(
            "512 absent keys: block reads {plain} -> {filtered}; {false_positives} false-positive table checks"
        );
        Ok(())
    })();
    fs::remove_dir_all(dir)?;
    result
}
~~~

</details>

## Check it

~~~bash
cargo test --offline --locked --quiet --test bloom -- --nocapture
~~~

<!-- run: cargo fmt --check && cargo clippy --offline --locked --quiet --all-targets -- -D warnings && cargo test --offline --locked --quiet --test bloom -- --nocapture -->

For 512 absent keys, block reads fell from 960 to 10. The filter made 11 false-positive table checks. The counters describe this fixture’s lookup work. A frame read can be served from the operating system’s cache.

## If it goes wrong

If result sets differ, verify both construction and lookup use the same probe mapping and that every version’s key enters the filter. If the counters show little change, check whether absent keys fall inside indexed block ranges.
