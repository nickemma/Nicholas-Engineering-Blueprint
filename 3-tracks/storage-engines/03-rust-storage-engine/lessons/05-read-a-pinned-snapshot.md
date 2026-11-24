# 05 Read a pinned snapshot across several runs

> A Rust storage engine · Week 3 · Builds on lesson 04

## The problem

A client reads a range and later repeats the same read. In between, another operation can overwrite or delete some keys and flush them to another run. The client needs the original view.

## The mental model

Pin sequence S. For each key, find its greatest version with sequence at most S. In a range scan, merge the heads of all sources by key, then by descending sequence for that key. A visible tombstone resolves the key as absent.

## The pattern

Multiversion concurrency control (MVCC) keeps several versions for a key and selects one using a read sequence. A snapshot handle pins that sequence until it is dropped. The handle is owned by the same open store for its lifetime.

## Build it

### Step 1 — Pin and release sequence numbers

Track how many handles exist at each sequence. Give a reopened store its own identity.

<details>
<summary>Hint</summary>

Two handles can pin the same sequence. Dropping either one must leave the other registered.

</details>

<details>
<summary>Implementation</summary>

Create `src/snapshot.rs`.

<!-- file: src/snapshot.rs -->
~~~rust
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

#[derive(Default)]
pub struct Pins(Arc<Mutex<BTreeMap<u64, usize>>>);

pub struct Snapshot {
    owner: Arc<Mutex<BTreeMap<u64, usize>>>,
    sequence: u64,
}

impl Snapshot {
    pub fn sequence(&self) -> u64 {
        self.sequence
    }
}

impl Pins {
    pub fn pin(&self, sequence: u64) -> Snapshot {
        *self.0.lock().unwrap().entry(sequence).or_default() += 1;
        Snapshot {
            owner: self.0.clone(),
            sequence,
        }
    }

    pub fn owns(&self, snapshot: &Snapshot) -> bool {
        Arc::ptr_eq(&self.0, &snapshot.owner)
    }
}

impl Drop for Snapshot {
    fn drop(&mut self) {
        let mut pins = self.owner.lock().unwrap();
        let count = pins.get_mut(&self.sequence).unwrap();
        *count -= 1;
        if *count == 0 {
            pins.remove(&self.sequence);
        }
    }
}
~~~

</details>

### Step 2 — Read sorted blocks as an iterator

Keep one block from each table in flight and skip keys outside the scan bounds.

<details>
<summary>Hint</summary>

Seek the starting block by its upper key and stop as soon as a block starts beyond the range.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `src/table.rs` in order.

<!-- edit: src/table.rs -->
~~~rust
        Ok(matches)
    }

    pub fn range(&self, start: &[u8], end: &[u8]) -> io::Result<Vec<Entry>> {
        let index = self
            .blocks
            .partition_point(|block| block.last.as_slice() < start);
        let mut entries = Vec::new();
        for block in &self.blocks[index..] {
            if block.first.as_slice() >= end {
                break;
            }
            entries.extend(self.read(block)?.into_iter().filter(|entry| {
                let key = entry.key.as_slice();
                start <= key && key < end
            }));
        }
        Ok(entries)
    }
}
~~~

Replace the selected lines with this block.

~~~rust
        Ok(matches)
    }

    pub fn range<'a>(
        &'a self,
        start: &'a [u8],
        end: &'a [u8],
    ) -> impl Iterator<Item = io::Result<Entry>> + 'a {
        let index = self
            .blocks
            .partition_point(|block| block.last.as_slice() < start);
        TableScan::new(self, index, Some((start, end)))
    }
}

struct TableScan<'a> {
    table: &'a Table,
    blocks: std::slice::Iter<'a, Block>,
    entries: std::vec::IntoIter<Entry>,
    bounds: Option<(&'a [u8], &'a [u8])>,
}

impl<'a> TableScan<'a> {
    fn new(table: &'a Table, from: usize, bounds: Option<(&'a [u8], &'a [u8])>) -> Self {
        Self {
            table,
            blocks: table.blocks[from..].iter(),
            entries: Vec::new().into_iter(),
            bounds,
        }
    }
}

impl Iterator for TableScan<'_> {
    type Item = io::Result<Entry>;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            for entry in self.entries.by_ref() {
                if self.bounds.is_none_or(|(start, end)| {
                    start <= entry.key.as_slice() && entry.key.as_slice() < end
                }) {
                    return Some(Ok(entry));
                }
            }
            let block = self.blocks.next()?;
            if self
                .bounds
                .is_some_and(|(_, end)| block.first.as_slice() >= end)
            {
                self.blocks = [].iter();
                return None;
            }
            match self.table.read(block) {
                Ok(entries) => self.entries = entries.into_iter(),
                Err(error) => {
                    self.blocks = [].iter();
                    return Some(Err(error));
                }
            }
        }
    }
}
~~~

</details>

### Step 3 — Merge source heads

Use a heap containing one current entry per ordered source. Advance the source that produced the result.

<details>
<summary>Hint</summary>

Rust’s heap is a max-heap. Reverse the key comparison while keeping newest sequence first for matching keys.

</details>

<details>
<summary>Implementation</summary>

Create `src/merge.rs`.

<!-- file: src/merge.rs -->
~~~rust
use std::cmp::Ordering;
use std::collections::BinaryHeap;
use std::io;

use crate::entry::Entry;

pub type Source<'a> = Box<dyn Iterator<Item = io::Result<Entry>> + 'a>;

struct Head {
    entry: Entry,
    source: usize,
}

impl Ord for Head {
    fn cmp(&self, other: &Self) -> Ordering {
        // Smallest key first. For a shared key, greatest sequence first.
        other
            .entry
            .key
            .cmp(&self.entry.key)
            .then(self.entry.version.seq.cmp(&other.entry.version.seq))
            .then(self.source.cmp(&other.source))
    }
}

impl PartialOrd for Head {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl PartialEq for Head {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other).is_eq()
    }
}

impl Eq for Head {}

pub struct Merge<'a> {
    sources: Vec<Source<'a>>,
    heads: BinaryHeap<Head>,
    error: Option<io::Error>,
}

impl<'a> Merge<'a> {
    pub fn new(sources: Vec<Source<'a>>) -> io::Result<Self> {
        let mut merge = Self {
            sources,
            heads: BinaryHeap::new(),
            error: None,
        };
        for source in 0..merge.sources.len() {
            merge.advance(source)?;
        }
        Ok(merge)
    }

    fn advance(&mut self, source: usize) -> io::Result<()> {
        if let Some(entry) = self.sources[source].next() {
            self.heads.push(Head {
                entry: entry?,
                source,
            });
        }
        Ok(())
    }
}

impl Iterator for Merge<'_> {
    type Item = io::Result<Entry>;

    fn next(&mut self) -> Option<Self::Item> {
        if let Some(error) = self.error.take() {
            self.heads.clear();
            return Some(Err(error));
        }
        let Head { entry, source } = self.heads.pop()?;
        self.error = self.advance(source).err();
        Some(Ok(entry))
    }
}
~~~

</details>

### Step 4 — Resolve a visible version

Use the latest admissible sequence for point reads and let a visible tombstone finish that key in a scan.

<details>
<summary>Hint</summary>

Ignore too-new records without marking their key as decided.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `src/lib.rs` in order.

<!-- edit: src/lib.rs -->
~~~rust
mod disk;
mod entry;
mod manifest;
mod table;

use std::collections::BTreeMap;
~~~

Replace the selected lines with this block.

~~~rust
mod disk;
mod entry;
mod manifest;
mod merge;
mod snapshot;
mod table;

use std::collections::BTreeMap;
~~~

<!-- edit: src/lib.rs -->
~~~rust
use disk::sync_dir;
use entry::{Entry, Version};
use manifest::{Manifest, create_wal, table_path, wal_path};
use table::Table;

#[derive(Debug, Default, Eq, PartialEq)]
pub struct ProbeStats {
~~~

Replace the selected lines with this block.

~~~rust
use disk::sync_dir;
use entry::{Entry, Version};
use manifest::{Manifest, create_wal, table_path, wal_path};
use merge::{Merge, Source};
use snapshot::Pins;
use table::Table;

pub use snapshot::Snapshot;

#[derive(Debug, Default, Eq, PartialEq)]
pub struct ProbeStats {
~~~

<!-- edit: src/lib.rs -->
~~~rust
    manifest: Manifest,
    tables: Vec<Table>,
    failed: bool,
    _lock: File,
}
~~~

Replace the selected lines with this block.

~~~rust
    manifest: Manifest,
    tables: Vec<Table>,
    failed: bool,
    pins: Pins,
    _lock: File,
}
~~~

<!-- edit: src/lib.rs -->
~~~rust
        Ok(Self {
            dir: dir.to_path_buf(),
            _lock: lock,
            seq,
            mem,
            wal,
~~~

Replace the selected lines with this block.

~~~rust
        Ok(Self {
            dir: dir.to_path_buf(),
            _lock: lock,
            pins: Pins::default(),
            seq,
            mem,
            wal,
~~~

<!-- edit: src/lib.rs -->
~~~rust
        Ok(())
    }

    pub fn get(&self, key: &[u8]) -> io::Result<Option<Vec<u8>>> {
        self.get_with_stats(key, true).map(|(value, _)| value)
    }

    pub fn get_with_stats(
~~~

Replace the selected lines with this block.

~~~rust
        Ok(())
    }

    pub fn snapshot(&self) -> Snapshot {
        self.pins.pin(self.seq)
    }

    fn pinned(&self, snapshot: &Snapshot) -> io::Result<u64> {
        if !self.pins.owns(snapshot) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "snapshot belongs to another open store",
            ));
        }
        Ok(snapshot.sequence())
    }

    pub fn get(&self, key: &[u8]) -> io::Result<Option<Vec<u8>>> {
        self.get_with_stats(key, true).map(|(value, _)| value)
    }

    pub fn get_at(&self, key: &[u8], snapshot: &Snapshot) -> io::Result<Option<Vec<u8>>> {
        self.get_visible(key, self.pinned(snapshot)?, true)
            .map(|(value, _)| value)
    }

    pub fn get_with_stats(
~~~

<!-- edit: src/lib.rs -->
~~~rust
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
                {
                    best = Some(entry.version);
                }
~~~

Replace the selected lines with this block.

~~~rust
        key: &[u8],
        use_filter: bool,
    ) -> io::Result<(Option<Vec<u8>>, ProbeStats)> {
        self.get_visible(key, self.seq, use_filter)
    }

    fn get_visible(
        &self,
        key: &[u8],
        at: u64,
        use_filter: bool,
    ) -> io::Result<(Option<Vec<u8>>, ProbeStats)> {
        self.ensure_live()?;
        let mut stats = ProbeStats::default();
        let mut best = self
            .mem
            .get(key)
            .and_then(|versions| visible(versions, at))
            .cloned();
        for table in &self.tables {
            for entry in table.point(key, use_filter, &mut stats)? {
                if entry.version.seq <= at
                    && best
                        .as_ref()
                        .is_none_or(|version| version.seq < entry.version.seq)
                {
                    best = Some(entry.version);
                }
~~~

<!-- edit: src/lib.rs -->
~~~rust
    }

    pub fn scan(&self, start: &[u8], end: &[u8]) -> io::Result<Vec<Row>> {
        self.ensure_live()?;
        if start >= end {
            return Ok(Vec::new());
        }
        let mut ordered: BTreeMap<Vec<u8>, Version> = self
            .mem
            .range::<[u8], _>((
                std::ops::Bound::Included(start),
                std::ops::Bound::Excluded(end),
            ))
            .filter_map(|(key, versions)| Some((key.clone(), versions.last()?.clone())))
            .collect();
        for table in &self.tables {
            for entry in table.range(start, end)? {
                let best = ordered
                    .entry(entry.key)
                    .or_insert_with(|| entry.version.clone());
                if best.seq < entry.version.seq {
                    *best = entry.version;
                }
            }
        }
        Ok(ordered
            .into_iter()
            .filter_map(|(key, version)| Some((key, version.value?)))
            .collect())
    }
}
~~~

Replace the selected lines with this block.

~~~rust
    }

    pub fn scan(&self, start: &[u8], end: &[u8]) -> io::Result<Vec<Row>> {
        self.scan_visible(start, end, self.seq)
    }

    pub fn scan_at(&self, start: &[u8], end: &[u8], snapshot: &Snapshot) -> io::Result<Vec<Row>> {
        self.scan_visible(start, end, self.pinned(snapshot)?)
    }

    fn scan_visible(&self, start: &[u8], end: &[u8], at: u64) -> io::Result<Vec<Row>> {
        self.ensure_live()?;
        if start >= end {
            return Ok(Vec::new());
        }
        let mem = self
            .mem
            .range::<[u8], _>((
                std::ops::Bound::Included(start),
                std::ops::Bound::Excluded(end),
            ))
            .filter_map(|(key, versions)| {
                Some(Ok(Entry {
                    key: key.clone(),
                    version: visible(versions, at)?.clone(),
                }))
            });
        let mut sources: Vec<Source<'_>> = vec![Box::new(mem)];
        for table in &self.tables {
            sources.push(Box::new(table.range(start, end)));
        }
        let mut rows = Vec::new();
        let mut decided = None;
        for entry in Merge::new(sources)? {
            let entry = entry?;
            if entry.version.seq <= at && decided.as_ref() != Some(&entry.key) {
                // Even if this version is a tombstone, older entries must stay hidden.
                decided = Some(entry.key.clone());
                if let Some(value) = entry.version.value {
                    rows.push((entry.key, value));
                }
            }
        }
        Ok(rows)
    }
}

fn visible(versions: &[Version], at: u64) -> Option<&Version> {
    let past = versions.partition_point(|version| version.seq <= at);
    versions[..past].last()
}
~~~

</details>

### Step 5 — Check old and new views

Keep handles from before and after a delete, then reinsert the key. Exercise a second key with more versions than fit in a block.

<details>
<summary>Hint</summary>

Check the visible values and scan membership at each pin. A handle from before reopening should be refused.

</details>

<details>
<summary>Implementation</summary>

Create `tests/mvcc.rs`.

<!-- file: tests/mvcc.rs -->
~~~rust
use std::{fs, io};

use lsm::Store;

#[test]
fn pinned_reads_cross_flushes_and_tombstones() -> io::Result<()> {
    let dir = std::env::temp_dir().join(format!("lsm-mvcc-{}", std::process::id()));
    fs::create_dir(&dir)?;
    let result = (|| {
        let mut db = Store::open(&dir)?;
        db.put(b"a", b"old")?;
        db.put(b"b", b"")?;
        let first = db.snapshot();
        db.flush()?;
        db.delete(b"a")?;
        db.flush()?;
        let deleted = db.snapshot();
        db.put(b"a", b"new")?;
        db.put(b"c", b"third")?;
        // Enough versions of the same key to span several indexed blocks.
        for number in 0..36 {
            db.put(b"z", &[number])?;
        }
        db.flush()?;
        let z = db.snapshot();
        db.delete(b"z")?;
        assert_eq!(db.get_at(b"z", &z)?, Some(vec![35]));
        assert_eq!(db.get(b"z")?, None);
        assert_eq!(db.get(b"a")?, Some(b"new".to_vec()));
        assert_eq!(db.get_at(b"a", &deleted)?, None);
        assert_eq!(db.get_at(b"a", &first)?, Some(b"old".to_vec()));
        assert_eq!(
            db.scan_at(b"a", b"c", &first)?,
            vec![(b"a".to_vec(), b"old".to_vec()), (b"b".to_vec(), vec![])]
        );
        assert_eq!(
            db.scan_at(b"a", b"c", &deleted)?,
            vec![(b"b".to_vec(), vec![])]
        );
        drop(db);
        let db = Store::open(&dir)?;
        assert!(db.get_at(b"a", &first).is_err());
        println!("pinned scan retained a=old before deletion and hid a at the deletion sequence");
        Ok(())
    })();
    fs::remove_dir_all(dir)?;
    result
}
~~~

</details>

## Check it

~~~bash
cargo test --offline --locked --quiet --test mvcc -- --nocapture
~~~

<!-- run: cargo fmt --check && cargo clippy --offline --locked --quiet --all-targets -- -D warnings && cargo test --offline --locked --quiet --test mvcc -- --nocapture -->

The pinned scan held `a=old` before the deletion and hid `a` at the deletion sequence.

## If it goes wrong

If later writes leak into a scan, check the sequence comparison. If an older version appears after a delete, check that the scan records the key even when its chosen version has no value.
