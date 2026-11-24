# 06 Compact without losing a version

> A Rust storage engine · Week 3 · Builds on lesson 05

## The problem

A merge that keeps only the newest value seems to preserve current reads. It can still change the result for a reader pinned before an overwrite or delete.

## The mental model

The oldest pinned sequence is the compaction horizon. Keep all versions above it plus the newest visible value at or below it. In a full merge of published runs, a visible tombstone and the older covered versions can go together. The active WAL contains mutations newer than the published input.

## The pattern

Compaction rewrites immutable runs and publishes a replacement manifest while keeping the same WAL and replay watermark. This first compactor uses every published run. A compactor selecting part of the inventory would also have to account for overlapping runs outside its inputs.

## Build it

### Step 1 — Write the retention rule on paper

For a key with versions 8, 6, and 2, trace a pin at sequence 4 and then at 8. Try the same example with version 6 as a tombstone.

<details>
<summary>Hint</summary>

The pin at 4 needs version 2 and the engine must still serve newer snapshots.

</details>

### Step 2 — Find the horizon and gather the inputs

Use the least sequence with a live handle. Expose sorted iterators and count table bytes before starting the merge.

<details>
<summary>Hint</summary>

With no pin, the current sequence is the horizon. Full published coverage is what allows obsolete tombstones to go.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `src/snapshot.rs` in order.

<!-- edit: src/snapshot.rs -->
~~~rust
        }
    }

    pub fn owns(&self, snapshot: &Snapshot) -> bool {
        Arc::ptr_eq(&self.0, &snapshot.owner)
    }
~~~

Replace the selected lines with this block.

~~~rust
        }
    }

    pub fn oldest(&self) -> Option<u64> {
        self.0
            .lock()
            .unwrap()
            .first_key_value()
            .map(|(&sequence, _)| sequence)
    }

    pub fn owns(&self, snapshot: &Snapshot) -> bool {
        Arc::ptr_eq(&self.0, &snapshot.owner)
    }
~~~

Find these regions in `src/table.rs` in order.

<!-- edit: src/table.rs -->
~~~rust
        Ok(matches)
    }

    pub fn range<'a>(
        &'a self,
        start: &'a [u8],
~~~

Replace the selected lines with this block.

~~~rust
        Ok(matches)
    }

    pub fn bytes(&self) -> io::Result<u64> {
        Ok(self.file.metadata()?.len())
    }

    pub fn all(&self) -> impl Iterator<Item = io::Result<Entry>> + '_ {
        TableScan::new(self, 0, None)
    }

    pub fn range<'a>(
        &'a self,
        start: &'a [u8],
~~~

</details>

### Step 3 — Publish the surviving entries

Merge by key and sequence. Preserve the active WAL ID and its watermark while replacing the list of run IDs.

<details>
<summary>Hint</summary>

Dropping a version changes only the table inventory. It cannot rewind the sequence allocator.

</details>

<details>
<summary>Implementation</summary>

Create `src/compact.rs`.

<!-- file: src/compact.rs -->
~~~rust
use std::io;

use crate::Store;
use crate::disk::sync_dir;
use crate::manifest::table_path;
use crate::merge::{Merge, Source};
use crate::table::Table;

#[derive(Debug, Default, Eq, PartialEq)]
pub struct Compaction {
    pub input_runs: usize,
    pub input_versions: u64,
    pub input_bytes: u64,
    pub retained_versions: usize,
    pub output_bytes: u64,
}

impl Store {
    pub fn compact(&mut self) -> io::Result<Compaction> {
        self.ensure_live()?;
        if self.tables.is_empty() {
            return Ok(Compaction::default());
        }
        let horizon = self.pins.oldest().unwrap_or(self.seq);
        let id = self.manifest.next()?;
        let mut stats = Compaction {
            input_runs: self.tables.len(),
            ..Compaction::default()
        };
        let mut sources: Vec<Source<'_>> = Vec::new();
        for table in &self.tables {
            stats.input_bytes += table.bytes()?;
            sources.push(Box::new(table.all()));
        }

        let mut retained = Vec::new();
        let mut anchored = None;
        for entry in Merge::new(sources)? {
            let entry = entry?;
            stats.input_versions += 1;
            if entry.version.seq > horizon {
                retained.push(entry);
            } else if anchored.as_ref() != Some(&entry.key) {
                // Every published run is an input, and the active WAL is
                // newer. A tombstone at or below the horizon can go with
                // the older versions it hides.
                anchored = Some(entry.key.clone());
                if entry.version.value.is_some() {
                    retained.push(entry);
                }
            }
        }
        stats.retained_versions = retained.len();

        self.failed = true;
        let mut next = self.manifest.clone();
        next.generation = id;
        next.tables.clear();
        let mut tables = Vec::new();
        if !retained.is_empty() {
            let table = Table::create(&table_path(&self.dir, id), &retained)?;
            stats.output_bytes = table.bytes()?;
            tables.push(table);
            next.tables.push(id);
        }
        sync_dir(&self.dir)?;
        next.publish(&self.dir)?;
        self.tables = tables;
        self.manifest = next;
        self.manifest.cleanup(&self.dir)?;
        self.failed = false;
        Ok(stats)
    }
}
~~~

Find these regions in `src/lib.rs` in order.

<!-- edit: src/lib.rs -->
~~~rust
mod bloom;
mod codec;
mod disk;
mod entry;
mod manifest;
~~~

Replace the selected lines with this block.

~~~rust
mod bloom;
mod codec;
mod compact;
mod disk;
mod entry;
mod manifest;
~~~

<!-- edit: src/lib.rs -->
~~~rust
use snapshot::Pins;
use table::Table;

pub use snapshot::Snapshot;

#[derive(Debug, Default, Eq, PartialEq)]
~~~

Replace the selected lines with this block.

~~~rust
use snapshot::Pins;
use table::Table;

pub use compact::Compaction;
pub use snapshot::Snapshot;

#[derive(Debug, Default, Eq, PartialEq)]
~~~

</details>

### Step 4 — Release snapshots and compact again

Hold two handles for the oldest view and then release them one at a time. Verify what every remaining view sees through all rewrites.

<details>
<summary>Hint</summary>

Count versions and bytes, then reopen and check a deleted key still cannot reappear.

</details>

<details>
<summary>Implementation</summary>

Find these regions in `tests/mvcc.rs` in order.

<!-- edit: tests/mvcc.rs -->
~~~rust
    fs::remove_dir_all(dir)?;
    result
}
~~~

Replace the selected lines with this block.

~~~rust
    fs::remove_dir_all(dir)?;
    result
}

#[test]
fn compaction_keeps_every_pinned_view() -> io::Result<()> {
    let dir = std::env::temp_dir().join(format!("lsm-compact-{}", std::process::id()));
    fs::create_dir(&dir)?;
    let result = (|| {
        let mut db = Store::open(&dir)?;
        db.put(b"a", b"old")?;
        db.put(b"b", b"stable")?;
        db.put(b"d", b"obsolete")?;
        db.flush()?;
        let first = db.snapshot();
        let duplicate_pin = db.snapshot();

        db.delete(b"a")?;
        db.delete(b"d")?;
        db.flush()?;
        let deleted = db.snapshot();
        db.put(b"a", b"new")?;
        db.put(b"b", b"last")?;
        db.flush()?;

        let before = db.scan_at(b"a", b"z", &first)?;
        drop(first); // Another handle for the same sequence still pins it.
        let pinned = db.compact()?;
        assert_eq!(
            db.scan_at(b"a", b"z", &duplicate_pin)?,
            before,
            "pinned snapshot changed during compaction",
        );
        assert_eq!(db.get_at(b"a", &deleted)?, None);
        assert_eq!(db.get_at(b"b", &deleted)?, Some(b"stable".to_vec()));
        assert_eq!(pinned.retained_versions, 7);

        drop(duplicate_pin);
        let partial = db.compact()?;
        assert_eq!(partial.retained_versions, 3);
        assert_eq!(db.get_at(b"a", &deleted)?, None);
        drop(deleted);

        let latest = db.compact()?;
        assert_eq!(latest.retained_versions, 2);
        assert_eq!(
            db.scan(b"a", b"z")?,
            vec![
                (b"a".to_vec(), b"new".to_vec()),
                (b"b".to_vec(), b"last".to_vec())
            ]
        );
        assert_eq!(db.get(b"d")?, None);
        drop(db);
        let db = Store::open(&dir)?;
        assert_eq!(db.sequence(), 7);
        assert_eq!(db.get(b"d")?, None);
        println!(
            "versions 7 -> 3 -> 2; first compaction {} -> {} bytes; last {} -> {} bytes",
            pinned.input_bytes, pinned.output_bytes, latest.input_bytes, latest.output_bytes
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
cargo test --offline --locked --quiet --test mvcc -- --nocapture
~~~

<!-- run: cargo fmt --check && cargo clippy --offline --locked --quiet --all-targets -- -D warnings && cargo test --offline --locked --quiet --test mvcc -- --nocapture -->

The fixture retained 7, then 3, then 2 versions as pins were released. First compaction rewrote 437 input bytes into 242 output bytes. The last wrote 139 bytes from 162 input bytes.

## If it goes wrong

If pinned reads change during the first merge, inspect the horizon and the first admissible version for each key. If a tombstone is dropped and a value reappears, check which runs took part in the compaction.
