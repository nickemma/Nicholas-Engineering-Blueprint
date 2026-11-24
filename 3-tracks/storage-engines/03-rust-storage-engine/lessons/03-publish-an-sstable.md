# 03 Flush and publish an SSTable

> A Rust storage engine · Week 2 · Builds on lesson 02

## The problem

A memtable and one WAL eventually get large. A flush hands those versions to a sorted file. A restart must know which files represent them, even if it stops during the handoff.

## The mental model

The table starts with a magic value, then framed data blocks, framed block index entries, and a checksummed footer pointing to the index. A block index entry contains the first and last keys and its byte span. The manifest names the active files and the largest sequence covered by runs.

## The pattern

Publish a new table and empty WAL through one manifest replacement. Sync their files and directory before publishing the manifest, then sync the directory after rename. Recovery follows the authoritative manifest and replays the active WAL starting at its watermark plus one.

## Build it

### Step 1 — Draw the files for two generations

Write the inventory just before and just after publishing a flush. Leave the old WAL available until the manifest commits.

<details>
<summary>Hint</summary>

The earlier manifest needs the earlier WAL even if a newer table is already present.

</details>

### Step 2 — Frame and index blocks

Give each block a validated byte span and bounds. Search by the block’s last key and walk possible matches.

<details>
<summary>Hint</summary>

A single key may straddle a block boundary. Its first possible block may have a smaller first key.

</details>

<details>
<summary>Implementation</summary>

Create `src/disk.rs`.

<!-- file: src/disk.rs -->
~~~rust
use std::fs::File;
use std::io::{self, Write};
use std::os::unix::fs::FileExt;
use std::path::Path;

use klog::record::{HEADER_LEN, MAX_PAYLOAD, decode, encode_header};

use crate::codec::invalid;

pub fn sync_dir(dir: &Path) -> io::Result<()> {
    File::open(dir)?.sync_all()
}

pub fn write_frame(file: &mut File, data: &[u8]) -> io::Result<u64> {
    let header = encode_header(data).map_err(io::Error::other)?;
    file.write_all(&header)?;
    file.write_all(data)?;
    Ok((header.len() + data.len()) as u64)
}

pub fn read_frame(file: &File, at: u64, limit: u64) -> io::Result<(Vec<u8>, u64)> {
    let remaining = limit
        .checked_sub(at)
        .ok_or_else(|| invalid("invalid frame offset"))?;
    if remaining < HEADER_LEN as u64 {
        return Err(invalid("incomplete data frame"));
    }
    let mut header = [0; HEADER_LEN];
    file.read_exact_at(&mut header, at)?;
    let len = u32::from_le_bytes(header[..4].try_into().unwrap()) as usize;
    let size = HEADER_LEN + len;
    if len > MAX_PAYLOAD || size as u64 > remaining {
        return Err(invalid("invalid data frame length"));
    }
    let mut complete = header.to_vec();
    complete.resize(size, 0);
    file.read_exact_at(&mut complete[HEADER_LEN..], at + HEADER_LEN as u64)?;
    let (payload, used) = decode(&complete).map_err(io::Error::other)?;
    Ok((payload.to_vec(), at + used as u64))
}
~~~

Create `src/table.rs`.

<!-- file: src/table.rs -->
~~~rust
use std::fs::File;
use std::io::{self, Write};
use std::os::unix::fs::FileExt;
use std::path::Path;

use crate::codec::{Cursor, MAX_KEY, invalid, u32_to, u64_to};
use crate::disk::{read_frame, write_frame};
use crate::entry::Entry;

const MAGIC: &[u8] = b"LST1";
const BLOCK_ENTRIES: usize = 16;
const FOOTER_SIZE: u64 = (klog::record::HEADER_LEN + 8) as u64;

struct Block {
    first: Vec<u8>,
    last: Vec<u8>,
    start: u64,
    end: u64,
}

impl Block {
    fn encode(&self) -> Vec<u8> {
        let mut data = Vec::new();
        u64_to(&mut data, self.start);
        u64_to(&mut data, self.end);
        for key in [&self.first, &self.last] {
            u32_to(&mut data, key.len() as u32);
            data.extend(key);
        }
        data
    }

    fn decode(data: &[u8]) -> io::Result<Self> {
        let mut cursor = Cursor::new(data);
        let start = cursor.u64()?;
        let end = cursor.u64()?;
        let first = key(&mut cursor)?;
        let last = key(&mut cursor)?;
        cursor.done()?;
        if first > last || start >= end {
            return Err(invalid("invalid block bounds"));
        }
        Ok(Self {
            first,
            last,
            start,
            end,
        })
    }
}

fn key(cursor: &mut Cursor<'_>) -> io::Result<Vec<u8>> {
    let len = cursor.u32()? as usize;
    if len > MAX_KEY {
        return Err(invalid("oversized index key"));
    }
    Ok(cursor.take(len)?.to_vec())
}

pub struct Table {
    file: File,
    blocks: Vec<Block>,
}

impl Table {
    pub fn create(path: &Path, entries: &[Entry]) -> io::Result<Self> {
        if entries.is_empty() || !entries.windows(2).all(|pair| ordered(&pair[0], &pair[1])) {
            return Err(invalid("tables require sorted nonempty input"));
        }
        let mut file = File::create_new(path)?;
        file.write_all(MAGIC)?;
        let mut at = MAGIC.len() as u64;
        let mut blocks = Vec::new();
        for chunk in entries.chunks(BLOCK_ENTRIES) {
            let mut data = Vec::new();
            u32_to(&mut data, chunk.len() as u32);
            for entry in chunk {
                entry.encode(&mut data);
            }
            let end = at + write_frame(&mut file, &data)?;
            blocks.push(Block {
                first: chunk[0].key.clone(),
                last: chunk.last().unwrap().key.clone(),
                start: at,
                end,
            });
            at = end;
        }
        for block in blocks {
            write_frame(&mut file, &block.encode())?;
        }
        write_frame(&mut file, &at.to_le_bytes())?;
        file.sync_all()?;
        Self::open(path)
    }

    pub fn open(path: &Path) -> io::Result<Self> {
        let file = File::open(path)?;
        let end = file.metadata()?.len();
        let footer = end
            .checked_sub(FOOTER_SIZE)
            .ok_or_else(|| invalid("missing table footer"))?;
        let mut magic = [0; 4];
        file.read_exact_at(&mut magic, 0)?;
        if magic != MAGIC {
            return Err(invalid("unknown table format"));
        }
        let (data, next) = read_frame(&file, footer, end)?;
        let mut cursor = Cursor::new(&data);
        let index = cursor.u64()?;
        cursor.done()?;
        if next != end || index <= MAGIC.len() as u64 || index >= footer {
            return Err(invalid("invalid table index offset"));
        }
        let mut at = index;
        let mut expected = MAGIC.len() as u64;
        let mut blocks: Vec<Block> = Vec::new();
        while at < footer {
            let (data, next) = read_frame(&file, at, footer)?;
            let block = Block::decode(&data)?;
            if block.start != expected
                || block.end > index
                || blocks
                    .last()
                    .is_some_and(|previous| previous.last > block.first)
            {
                return Err(invalid("invalid table block layout"));
            }
            expected = block.end;
            blocks.push(block);
            at = next;
        }
        if blocks.is_empty() || expected != index {
            return Err(invalid("index does not cover table data"));
        }
        Ok(Self { file, blocks })
    }

    fn read(&self, block: &Block) -> io::Result<Vec<Entry>> {
        let (data, next) = read_frame(&self.file, block.start, block.end)?;
        let mut cursor = Cursor::new(&data);
        let count = cursor.u32()? as usize;
        if count == 0 || count > BLOCK_ENTRIES || block.end != next {
            return Err(invalid("invalid block entry count or length"));
        }
        let entries = (0..count)
            .map(|_| Entry::decode(&mut cursor))
            .collect::<io::Result<Vec<_>>>()?;
        cursor.done()?;
        if entries[0].key != block.first
            || entries[count - 1].key != block.last
            || !entries.windows(2).all(|pair| ordered(&pair[0], &pair[1]))
        {
            return Err(invalid("block entries disagree with index"));
        }
        Ok(entries)
    }

    pub fn point(&self, key: &[u8]) -> io::Result<Vec<Entry>> {
        let index = self
            .blocks
            .partition_point(|block| block.last.as_slice() < key);
        let mut matches = Vec::new();
        for block in &self.blocks[index..] {
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

fn ordered(a: &Entry, b: &Entry) -> bool {
    a.key < b.key || (a.key == b.key && a.version.seq > b.version.seq)
}
~~~

</details>

### Step 3 — Write the manifest transition

Record the generation, WAL ID, covered sequence, and live run IDs. Reject malformed inventory metadata.

<details>
<summary>Hint</summary>

Use one rename as the publication boundary and sync the directory before obsolete-file cleanup.

</details>

<details>
<summary>Implementation</summary>

Create `src/manifest.rs`.

<!-- file: src/manifest.rs -->
~~~rust
use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};

use crate::codec::{Cursor, invalid, u32_to, u64_to};
use crate::disk::{read_frame, sync_dir, write_frame};

pub fn wal_path(dir: &Path, id: u64) -> PathBuf {
    dir.join(format!("wal-{id:020}"))
}

pub fn table_path(dir: &Path, id: u64) -> PathBuf {
    dir.join(format!("run-{id:020}"))
}

#[derive(Clone, Default, Debug)]
pub struct Manifest {
    pub generation: u64,
    pub covered: u64,
    pub wal: u64,
    pub tables: Vec<u64>,
}

impl Manifest {
    pub fn load(dir: &Path) -> io::Result<Option<Self>> {
        let file = match File::open(dir.join("MANIFEST")) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error),
        };
        let end = file.metadata()?.len();
        let (data, next) = read_frame(&file, 0, end)?;
        let mut cursor = Cursor::new(&data);
        if next != end || cursor.take(4)? != b"LSM1" {
            return Err(invalid("invalid manifest format"));
        }
        let generation = cursor.u64()?;
        let covered = cursor.u64()?;
        let wal = cursor.u64()?;
        let count = cursor.u32()?;
        if count as usize > (data.len() - 32) / 8 {
            return Err(invalid("table count exceeds manifest length"));
        }
        let tables = (0..count)
            .map(|_| cursor.u64())
            .collect::<io::Result<Vec<_>>>()?;
        cursor.done()?;
        if wal > generation
            || tables.iter().any(|&id| id == 0 || id > generation)
            || tables.windows(2).any(|pair| pair[0] >= pair[1])
        {
            return Err(invalid("invalid manifest generation or table list"));
        }
        Ok(Some(Self {
            generation,
            covered,
            wal,
            tables,
        }))
    }

    pub fn publish(&self, dir: &Path) -> io::Result<()> {
        let mut data = b"LSM1".to_vec();
        for field in [self.generation, self.covered, self.wal] {
            u64_to(&mut data, field);
        }
        let count = u32::try_from(self.tables.len()).map_err(|_| invalid("too many tables"))?;
        u32_to(&mut data, count);
        for id in &self.tables {
            u64_to(&mut data, *id);
        }
        let pending = dir.join("MANIFEST.next");
        let mut file = File::create_new(&pending)?;
        write_frame(&mut file, &data)?;
        file.sync_all()?;
        fs::rename(pending, dir.join("MANIFEST"))?;
        sync_dir(dir)
    }

    pub fn initialize(dir: &Path) -> io::Result<Self> {
        let initial = wal_path(dir, 0);
        for file in fs::read_dir(dir)? {
            let path = file?.path();
            let name = path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("");
            if (path == initial && path.metadata()?.len() == 0) || name == "MANIFEST.next" {
                fs::remove_file(path)?;
            } else if name.starts_with("wal-") || name.starts_with("run-") {
                return Err(invalid(
                    "storage files exist without an authoritative manifest",
                ));
            }
        }
        create_wal(dir, 0)?;
        let manifest = Self::default();
        manifest.publish(dir)?;
        Ok(manifest)
    }

    pub fn cleanup(&self, dir: &Path) -> io::Result<()> {
        for file in fs::read_dir(dir)? {
            let file = file?;
            let name = file.file_name();
            let name = name.to_str().unwrap_or("");
            let obsolete = if let Some(id) = numeric_suffix(name, "wal-") {
                id != self.wal
            } else if let Some(id) = numeric_suffix(name, "run-") {
                self.tables.binary_search(&id).is_err()
            } else {
                name == "MANIFEST.next"
            };
            if obsolete {
                fs::remove_file(file.path())?;
            }
        }
        sync_dir(dir)
    }

    pub fn next(&self) -> io::Result<u64> {
        self.generation
            .checked_add(1)
            .ok_or_else(|| invalid("generation exhausted"))
    }
}

fn numeric_suffix(name: &str, prefix: &str) -> Option<u64> {
    let digits = name.strip_prefix(prefix)?;
    if digits.len() == 20 && digits.bytes().all(|byte| byte.is_ascii_digit()) {
        digits.parse().ok()
    } else {
        None
    }
}

pub fn create_wal(dir: &Path, id: u64) -> io::Result<PathBuf> {
    let path = wal_path(dir, id);
    File::create_new(&path)?.sync_all()?;
    sync_dir(dir)?;
    Ok(path)
}
~~~

</details>

### Step 4 — Connect flush and open

Hold an engine lock across generations. Move the memtable to a table and start a new WAL. On open, follow the listed files and rebuild any suffix.

<details>
<summary>Hint</summary>

An error partway through publication makes further writes unsafe until reopen reads the authoritative manifest.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `src/lib.rs` in order.

<!-- edit: src/lib.rs -->
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
~~~

Replace the selected lines with this block.

~~~rust
mod codec;
mod disk;
mod entry;
mod manifest;
mod table;

use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

use klog::log::Log;

use codec::{Cursor, invalid};
use disk::sync_dir;
use entry::{Entry, Version};
use manifest::{Manifest, create_wal, table_path, wal_path};
use table::Table;

pub type Row = (Vec<u8>, Vec<u8>);

pub struct Store {
    dir: PathBuf,
    seq: u64,
    mem: BTreeMap<Vec<u8>, Vec<Version>>,
    wal: Log,
    manifest: Manifest,
    tables: Vec<Table>,
    failed: bool,
    _lock: File,
}

impl Store {
    pub fn open(dir: &Path) -> io::Result<Self> {
        fs::create_dir_all(dir)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(dir.join("LOCK"))?;
        lock.try_lock().map_err(io::Error::from)?;
        let manifest = match Manifest::load(dir)? {
            Some(manifest) => manifest,
            None => Manifest::initialize(dir)?,
        };
        let tables = manifest
            .tables
            .iter()
            .map(|id| Table::open(&table_path(dir, *id)))
            .collect::<io::Result<Vec<_>>>()?;
        let mut wal = Log::open_existing(&wal_path(dir, manifest.wal)).map_err(io::Error::other)?;
        let mut seq = manifest.covered;
        let mut mem: BTreeMap<Vec<u8>, Vec<Version>> = BTreeMap::new();
        wal.visit(|record| {
            let mut cursor = Cursor::new(record);
~~~

<!-- edit: src/lib.rs -->
~~~rust
            Ok(())
        })
        .map_err(io::Error::other)?;
        Ok(Self { seq, mem, wal })
    }

    pub fn sequence(&self) -> u64 {
~~~

Replace the selected lines with this block.

~~~rust
            Ok(())
        })
        .map_err(io::Error::other)?;
        manifest.cleanup(dir)?;
        Ok(Self {
            dir: dir.to_path_buf(),
            _lock: lock,
            seq,
            mem,
            wal,
            manifest,
            tables,
            failed: false,
        })
    }

    pub fn sequence(&self) -> u64 {
~~~

<!-- edit: src/lib.rs -->
~~~rust
        self.change(key, None)
    }

    fn change(&mut self, key: &[u8], value: Option<&[u8]>) -> io::Result<u64> {
        let next = self
            .seq
            .checked_add(1)
~~~

Replace the selected lines with this block.

~~~rust
        self.change(key, None)
    }

    fn ensure_live(&self) -> io::Result<()> {
        if self.failed {
            return Err(io::Error::other("storage I/O failed; reopen the engine"));
        }
        Ok(())
    }

    fn change(&mut self, key: &[u8], value: Option<&[u8]>) -> io::Result<u64> {
        self.ensure_live()?;
        let next = self
            .seq
            .checked_add(1)
~~~

<!-- edit: src/lib.rs -->
~~~rust
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

Replace the selected lines with this block.

~~~rust
        let entry = Entry::new(key, next, value)?;
        let mut bytes = b"LSW1".to_vec();
        entry.encode(&mut bytes);
        self.failed = true;
        self.wal.append(&bytes).map_err(io::Error::other)?;
        self.seq = next;
        self.mem.entry(entry.key).or_default().push(entry.version);
        self.failed = false;
        Ok(next)
    }

    pub fn flush(&mut self) -> io::Result<()> {
        self.ensure_live()?;
        if self.mem.is_empty() {
            return Ok(());
        }
        let id = self.manifest.next()?;
        let entries: Vec<_> = self
            .mem
            .iter()
            .flat_map(|(key, versions)| {
                versions.iter().rev().map(|version| Entry {
                    key: key.clone(),
                    version: version.clone(),
                })
            })
            .collect();
        self.failed = true;
        let table = Table::create(&table_path(&self.dir, id), &entries)?;
        let next_wal = create_wal(&self.dir, id)?;
        let wal = Log::open_existing(&next_wal).map_err(io::Error::other)?;
        sync_dir(&self.dir)?;
        let mut next = self.manifest.clone();
        next.generation = id;
        next.covered = self.seq;
        next.wal = id;
        next.tables.push(id);
        next.publish(&self.dir)?;
        self.wal = wal;
        self.tables.push(table);
        self.mem.clear();
        self.manifest = next;
        self.manifest.cleanup(&self.dir)?;
        self.failed = false;
        Ok(())
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
                {
                    best = Some(entry.version);
                }
            }
        }
        Ok(best.and_then(|version| version.value))
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

</details>

### Step 5 — Recover across two blocks

Flush 32 keys, delete and overwrite across the block boundary, and reopen. Check both the scan and the physical WAL inventory.

<details>
<summary>Hint</summary>

The committed table holds the first 32 versions. The WAL supplies the two newer changes.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `tests/wal.rs` in order.

<!-- edit: tests/wal.rs -->
~~~rust
    assert_eq!(db.delete(b"job").unwrap(), 3);
    drop(db);

    let path = dir.0.join("wal");
    let original = fs::read(&path).unwrap();
    fs::OpenOptions::new()
        .append(true)
~~~

Replace the selected lines with this block.

~~~rust
    assert_eq!(db.delete(b"job").unwrap(), 3);
    drop(db);

    let path = dir.0.join("wal-00000000000000000000");
    let original = fs::read(&path).unwrap();
    fs::OpenOptions::new()
        .append(true)
~~~

<!-- edit: tests/wal.rs -->
~~~rust
    let db = Store::open(&dir.0).unwrap();
    assert_eq!(db.recovered_bytes(), 3);
    assert_eq!(db.sequence(), 3);
    assert_eq!(db.get(b"empty"), Some(b"".as_slice()));
    assert_eq!(db.get(b"job"), None);
    assert_eq!(db.scan(b"", b"z"), vec![(b"empty".to_vec(), vec![])]);
    drop(db);
    assert_eq!(fs::read(&path).unwrap(), original);
~~~

Replace the selected lines with this block.

~~~rust
    let db = Store::open(&dir.0).unwrap();
    assert_eq!(db.recovered_bytes(), 3);
    assert_eq!(db.sequence(), 3);
    assert_eq!(db.get(b"empty").unwrap(), Some(vec![]));
    assert_eq!(db.get(b"job").unwrap(), None);
    assert_eq!(
        db.scan(b"", b"z").unwrap(),
        vec![(b"empty".to_vec(), vec![])]
    );
    drop(db);
    assert_eq!(fs::read(&path).unwrap(), original);
~~~

Create `tests/flush.rs`.

<!-- file: tests/flush.rs -->
~~~rust
use std::{fs, io};

use lsm::Store;

#[test]
fn flush_publishes_a_run_and_replays_the_active_wal() -> io::Result<()> {
    let dir = std::env::temp_dir().join(format!("lsm-flush-{}", std::process::id()));
    fs::create_dir(&dir)?;
    let result = (|| {
        let mut db = Store::open(&dir)?;
        assert!(Store::open(&dir).is_err());
        for n in 0..32 {
            db.put(&[n], &[n + 1])?;
        }
        db.flush()?;
        db.delete(&[15])?;
        db.put(&[16], b"new")?;
        drop(db);

        let db = Store::open(&dir)?;
        assert_eq!(db.sequence(), 34);
        assert_eq!(db.get(&[0])?, Some(vec![1]));
        assert_eq!(db.get(&[15])?, None);
        assert_eq!(db.get(&[16])?, Some(b"new".to_vec()));
        assert_eq!(
            db.scan(&[14], &[18])?,
            vec![
                (vec![14], vec![15]),
                (vec![16], b"new".to_vec()),
                (vec![17], vec![18]),
            ]
        );
        assert!(!dir.join("wal-00000000000000000000").exists());
        println!("reopened two blocks through sequence 34; WAL deletion hid key 15");
        Ok(())
    })();
    fs::remove_dir_all(dir)?;
    result
}
~~~

</details>

## Check it

~~~bash
cargo test --offline --locked --quiet --test flush -- --nocapture
~~~

<!-- run: cargo fmt --check && cargo clippy --offline --locked --quiet --all-targets -- -D warnings && cargo test --offline --locked --quiet --test flush -- --nocapture -->

The reopen recovered through sequence 34 and the WAL deletion hid key 15. The two surviving storage inputs were the sorted run and the active WAL.

## If it goes wrong

If a flushed version is missing, check the manifest’s run list and covered sequence before checking the lookup. If a deletion resurfaces, check that a tombstone masks an older value across runs.
