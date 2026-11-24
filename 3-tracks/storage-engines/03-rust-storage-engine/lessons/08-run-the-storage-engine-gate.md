# 08 Run the recovery and read-cost gate

> A Rust storage engine · Week 4 · Builds on lesson 07

## The problem

A good result on one hand-written sequence might miss an interaction between flush, compaction, and a pinned range. A seeded workload can repeat those combinations and compare them with an independent model.

## The mental model

The reference map represents the latest full state. Copy it when a snapshot is pinned. Drive both engines with the same key, mutation, and bounds, then compare their point and range results at matching times.

## The pattern

Use deterministic operation sequences and count work at stable boundaries. The block counters are logical data-frame requests. The compaction counters measure SSTable bytes. A deliberately broken compactor serves as a control for the pinned-view check.

## Build it

### Step 1 — Write the model

Store only current values in a simple ordered map and clone that map at each pin. Test an empty key and a high byte key.

<details>
<summary>Hint</summary>

The model can represent a deletion by removing a key. It needs neither tombstones nor a compaction algorithm.

</details>

<details>
<summary>Implementation</summary>

Create `tests/model.rs`.

<!-- file: tests/model.rs -->
~~~rust
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::Path;

use lsm::{Row, Store};

type Reference = BTreeMap<Vec<u8>, Vec<u8>>;

fn random(state: &mut u64) -> u64 {
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    *state
}

fn compare(db: &Store, reference: &Reference, snapshot: Option<&lsm::Snapshot>) -> io::Result<()> {
    for key in (0_u8..24).map(|n| vec![n]).chain([vec![], vec![0xff, 0]]) {
        let actual = match snapshot {
            Some(snapshot) => db.get_at(&key, snapshot)?,
            None => db.get(&key)?,
        };
        assert_eq!(actual.as_ref(), reference.get(&key), "key {key:?}");
    }
    for (start, end) in [
        (vec![], vec![0xff, 1]),
        (vec![5], vec![15]),
        (vec![8], vec![8]),
    ] {
        let expected: Vec<Row> = reference
            .range(start.clone()..end.clone())
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        let actual = match snapshot {
            Some(snapshot) => db.scan_at(&start, &end, snapshot)?,
            None => db.scan(&start, &end)?,
        };
        assert_eq!(actual, expected, "range {start:?}..{end:?}");
    }
    Ok(())
}

fn exercise(path: &Path, seed: u64) -> io::Result<()> {
    let mut rng = seed;
    let mut reference = Reference::new();
    let mut pins = Vec::new();
    let mut db = Store::open(path)?;
    for step in 1..=120 {
        let number = random(&mut rng);
        let key = match number % 26 {
            24 => vec![],
            25 => vec![0xff, 0],
            id => vec![id as u8],
        };
        let sequence = if number & 3 == 0 {
            reference.remove(&key);
            db.delete(&key)?
        } else {
            let bytes = (number as u16).to_be_bytes();
            let value = if number.is_multiple_of(7) {
                &[][..]
            } else {
                &bytes
            };
            reference.insert(key.clone(), value.to_vec());
            db.put(&key, value)?
        };
        assert_eq!(sequence, step);
        if step % 10 == 0 {
            db.flush()?;
        }
        if step % 15 == 0 {
            pins.push((db.snapshot(), reference.clone()));
        }
        if step % 20 == 0 {
            db.compact()?;
            compare(&db, &reference, None)?;
            for (snapshot, model) in &pins {
                compare(&db, model, Some(snapshot))?;
            }
            if pins.len() > 2 {
                pins.remove(0);
            }
        }
    }

    drop(pins);
    db.compact()?;
    compare(&db, &reference, None)?;
    drop(db);
    let db = Store::open(path)?;
    assert_eq!(db.sequence(), 120);
    compare(&db, &reference, None)?;
    Ok(())
}

#[test]
fn seeded_workloads_match_an_independent_ordered_map() -> io::Result<()> {
    let path = std::env::temp_dir().join(format!("lsm-model-{}", std::process::id()));
    fs::create_dir(&path)?;
    let seeds = [7, 19, 83, 211];
    let result = (|| {
        for seed in seeds {
            exercise(&path.join(seed.to_string()), seed)?;
        }
        println!("4 seeds, 480 mutations: point reads and scans matched current and pinned models");
        Ok(())
    })();
    fs::remove_dir_all(path)?;
    result
}

#[test]
fn no_live_values_still_preserves_the_replay_watermark() -> io::Result<()> {
    let path = std::env::temp_dir().join(format!("lsm-empty-{}", std::process::id()));
    fs::create_dir(&path)?;
    let result = (|| {
        let mut db = Store::open(&path)?;
        db.put(b"a", b"old")?;
        db.delete(b"a")?;
        db.flush()?;
        assert_eq!(db.compact()?.retained_versions, 0);
        assert!(db.state().runs.is_empty());
        drop(db);
        let mut db = Store::open(&path)?;
        assert_eq!(db.state().covered, 2);
        assert_eq!(db.get(b"a")?, None);
        assert_eq!(db.put(b"a", b"new")?, 3);
        drop(db);
        let db = Store::open(&path)?;
        assert_eq!(db.get(b"a")?, Some(b"new".to_vec()));
        println!("zero-run compaction preserved watermark 2; reinsert replayed at sequence 3");
        Ok(())
    })();
    fs::remove_dir_all(path)?;
    result
}
~~~

</details>

### Step 2 — Run four seeds

Interleave puts, deletes, flushes, compactions, and pinned reads. Compare current and older states and reopen after the last compaction.

<details>
<summary>Hint</summary>

Read a few fixed ranges at each checkpoint. Include an empty range and verify byte sort order.

</details>

### Step 3 — Predict the zero-run case

Delete the only key, flush, and compact. Predict what stays in the manifest after every version is elided.

<details>
<summary>Hint</summary>

The published watermark survives even when no SSTables do.

</details>

### Step 4 — Use the compaction control

The gate creates a scratch copy and replaces the oldest-pinned horizon with the current sequence. Explain which assertion should fail and what data that view loses.

<details>
<summary>Hint</summary>

A pinned read must fail for the expected mismatch. A compile error would leave the control untested.

</details>

## Check it

~~~bash
bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/03-rust-storage-engine/gate/run.sh" "$PWD"
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/03-rust-storage-engine/gate/run.sh" "$PWD" -->

The reference compared 480 mutations over four seeds. Bloom results matched with filtering on and off. All ten interruption schedules finished and the newest-only compaction control changed a pinned read. [Evidence](../evidence/README.md)

## If it goes wrong

If the model disagrees, keep the seed, operation number, and snapshot sequence before shrinking the fixture. If the breakage control passes, inspect whether its first snapshot actually differs from the latest state.
