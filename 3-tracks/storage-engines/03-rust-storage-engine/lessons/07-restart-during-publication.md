# 07 Restart during flush and compaction

> A Rust storage engine · Week 4 · Builds on lesson 06

## The problem

An error code cannot tell you which artifact was durable when the process stopped. Place a barrier on each side of the manifest boundary and reopen the exact directory the process left behind.

## The mental model

Before manifest publication, the previous generation is authoritative and fully recoverable. After publication, the new generation is authoritative even while old files remain. Obsolete-file deletion follows the synced manifest.

## The pattern

Use process termination at named barriers. Capture the file inventory before opening the store because opening cleans up unreferenced artifacts. Fault hooks are compiled only into the test build; the ordinary CLI runs without them.

## Build it

### Step 1 — Line up the recovery states

Predict the generation, covered sequence, and active WAL for every interruption. Treat flush and compaction separately.

<details>
<summary>Hint</summary>

A flush rotates the WAL. Compaction leaves the same WAL available, including any unflushed mutations.

</details>

### Step 2 — Install fault barriers

Pause the learner-owned process before and after the relevant WAL and manifest operations.

<details>
<summary>Hint</summary>

Flush the barrier announcement so the parent can tell the difference between a pause and a process that has not reached it.

</details>

<details>
<summary>Implementation</summary>

Create `src/fault.rs`.

<!-- file: src/fault.rs -->
~~~rust
// The normal build never pauses storage calls.
#[cfg(not(feature = "fault-injection"))]
pub fn pause(_point: &str) {}

#[cfg(feature = "fault-injection")]
pub fn pause(point: &str) {
    use std::io::{self, Write};

    if std::env::var("LSM_PAUSE_AT").as_deref() == Ok(point) {
        println!("paused {point}");
        io::stdout().flush().expect("flush fault barrier");
        loop {
            std::thread::park();
        }
    }
}
~~~

Find these regions in `src/manifest.rs` in order.

<!-- edit: src/manifest.rs -->
~~~rust

use crate::codec::{Cursor, invalid, u32_to, u64_to};
use crate::disk::{read_frame, sync_dir, write_frame};

pub fn wal_path(dir: &Path, id: u64) -> PathBuf {
    dir.join(format!("wal-{id:020}"))
~~~

Replace the selected lines with this block.

~~~rust

use crate::codec::{Cursor, invalid, u32_to, u64_to};
use crate::disk::{read_frame, sync_dir, write_frame};
use crate::fault;

pub fn wal_path(dir: &Path, id: u64) -> PathBuf {
    dir.join(format!("wal-{id:020}"))
~~~

<!-- edit: src/manifest.rs -->
~~~rust
        let mut file = File::create_new(&pending)?;
        write_frame(&mut file, &data)?;
        file.sync_all()?;
        fs::rename(pending, dir.join("MANIFEST"))?;
        sync_dir(dir)
    }

    pub fn initialize(dir: &Path) -> io::Result<Self> {
~~~

Replace the selected lines with this block.

~~~rust
        let mut file = File::create_new(&pending)?;
        write_frame(&mut file, &data)?;
        file.sync_all()?;
        fault::pause("before-manifest");
        fs::rename(pending, dir.join("MANIFEST"))?;
        sync_dir(dir)?;
        fault::pause("manifest-published");
        Ok(())
    }

    pub fn initialize(dir: &Path) -> io::Result<Self> {
~~~

Find these regions in `src/compact.rs` in order.

<!-- edit: src/compact.rs -->
~~~rust

use crate::Store;
use crate::disk::sync_dir;
use crate::manifest::table_path;
use crate::merge::{Merge, Source};
use crate::table::Table;
~~~

Replace the selected lines with this block.

~~~rust

use crate::Store;
use crate::disk::sync_dir;
use crate::fault;
use crate::manifest::table_path;
use crate::merge::{Merge, Source};
use crate::table::Table;
~~~

<!-- edit: src/compact.rs -->
~~~rust
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
~~~

Replace the selected lines with this block.

~~~rust
            next.tables.push(id);
        }
        sync_dir(&self.dir)?;
        fault::pause("outputs-synced");
        next.publish(&self.dir)?;
        self.tables = tables;
        self.manifest = next;
        self.manifest.cleanup(&self.dir)?;
        fault::pause("after-cleanup");
        self.failed = false;
        Ok(stats)
    }
~~~

Find these regions in `src/lib.rs` in order.

<!-- edit: src/lib.rs -->
~~~rust
mod compact;
mod disk;
mod entry;
mod manifest;
mod merge;
mod snapshot;
~~~

Replace the selected lines with this block.

~~~rust
mod compact;
mod disk;
mod entry;
mod fault;
mod manifest;
mod merge;
mod snapshot;
~~~

<!-- edit: src/lib.rs -->
~~~rust
}

pub type Row = (Vec<u8>, Vec<u8>);

pub struct Store {
    dir: PathBuf,
~~~

Replace the selected lines with this block.

~~~rust
}

pub type Row = (Vec<u8>, Vec<u8>);

#[derive(Debug, Eq, PartialEq)]
pub struct State {
    pub sequence: u64,
    pub covered: u64,
    pub generation: u64,
    pub wal: u64,
    pub runs: Vec<u64>,
}

pub struct Store {
    dir: PathBuf,
~~~

<!-- edit: src/lib.rs -->
~~~rust
        self.seq
    }

    pub fn recovered_bytes(&self) -> u64 {
        self.wal.recovered_bytes()
    }
~~~

Replace the selected lines with this block.

~~~rust
        self.seq
    }

    pub fn state(&self) -> State {
        State {
            sequence: self.seq,
            covered: self.manifest.covered,
            generation: self.manifest.generation,
            wal: self.manifest.wal,
            runs: self.manifest.tables.clone(),
        }
    }

    pub fn recovered_bytes(&self) -> u64 {
        self.wal.recovered_bytes()
    }
~~~

<!-- edit: src/lib.rs -->
~~~rust
        let mut bytes = b"LSW1".to_vec();
        entry.encode(&mut bytes);
        self.failed = true;
        self.wal.append(&bytes).map_err(io::Error::other)?;
        self.seq = next;
        self.mem.entry(entry.key).or_default().push(entry.version);
        self.failed = false;
~~~

Replace the selected lines with this block.

~~~rust
        let mut bytes = b"LSW1".to_vec();
        entry.encode(&mut bytes);
        self.failed = true;
        fault::pause("before-wal");
        self.wal.append(&bytes).map_err(io::Error::other)?;
        fault::pause("after-wal-sync");
        self.seq = next;
        self.mem.entry(entry.key).or_default().push(entry.version);
        self.failed = false;
~~~

<!-- edit: src/lib.rs -->
~~~rust
        let next_wal = create_wal(&self.dir, id)?;
        let wal = Log::open_existing(&next_wal).map_err(io::Error::other)?;
        sync_dir(&self.dir)?;
        let mut next = self.manifest.clone();
        next.generation = id;
        next.covered = self.seq;
~~~

Replace the selected lines with this block.

~~~rust
        let next_wal = create_wal(&self.dir, id)?;
        let wal = Log::open_existing(&next_wal).map_err(io::Error::other)?;
        sync_dir(&self.dir)?;
        fault::pause("outputs-synced");
        let mut next = self.manifest.clone();
        next.generation = id;
        next.covered = self.seq;
~~~

<!-- edit: src/lib.rs -->
~~~rust
        self.mem.clear();
        self.manifest = next;
        self.manifest.cleanup(&self.dir)?;
        self.failed = false;
        Ok(())
    }
~~~

Replace the selected lines with this block.

~~~rust
        self.mem.clear();
        self.manifest = next;
        self.manifest.cleanup(&self.dir)?;
        fault::pause("after-cleanup");
        self.failed = false;
        Ok(())
    }
~~~

</details>

### Step 3 — Expose the local engine over a CLI

Encode keys and values as hex so tests can use arbitrary bytes, including an empty value. Print the authoritative generation and watermark.

<details>
<summary>Hint</summary>

A present zero-length value prints `value ` and an absent key prints `absent`.

</details>

<details>
<summary>Implementation</summary>

Create `src/main.rs`.

<!-- file: src/main.rs -->
~~~rust
use std::fmt::Write as _;
use std::io;
use std::path::Path;
use std::process::ExitCode;

use lsm::Store;

fn usage() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidInput,
        "usage: lsm DIR {put KEY VALUE|delete KEY|get KEY|scan START END|flush|compact|state}; keys and values are hex",
    )
}

fn hex(input: &str) -> io::Result<Vec<u8>> {
    let invalid = || {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "expected pairs of hexadecimal digits",
        )
    };
    if !input.len().is_multiple_of(2) || !input.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(invalid());
    }
    input
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let text = std::str::from_utf8(pair).map_err(|_| invalid())?;
            u8::from_str_radix(text, 16).map_err(|_| invalid())
        })
        .collect()
}

fn display(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(out, "{byte:02x}").unwrap();
    }
    out
}

fn run(dir: &Path, operation: &str, args: &[String]) -> io::Result<()> {
    let mut db = Store::open(dir)?;
    match (operation, args) {
        ("put", [key, value]) => println!("ok {}", db.put(&hex(key)?, &hex(value)?)?),
        ("delete", [key]) => println!("ok {}", db.delete(&hex(key)?)?),
        ("get", [key]) => match db.get(&hex(key)?)? {
            Some(value) => println!("value {}", display(&value)),
            None => println!("absent"),
        },
        ("scan", [start, end]) => {
            for (key, value) in db.scan(&hex(start)?, &hex(end)?)? {
                println!("{}={}", display(&key), display(&value));
            }
        }
        ("flush", []) => {
            db.flush()?;
            println!("flushed {}", db.state().covered);
        }
        ("compact", []) => {
            let stats = db.compact()?;
            println!(
                "compacted {} runs, {} -> {} versions, {} -> {} bytes",
                stats.input_runs,
                stats.input_versions,
                stats.retained_versions,
                stats.input_bytes,
                stats.output_bytes
            );
        }
        ("state", []) => {
            let state = db.state();
            let runs = state
                .runs
                .iter()
                .map(u64::to_string)
                .collect::<Vec<_>>()
                .join(",");
            println!(
                "sequence={} covered={} generation={} wal={} runs={} trimmed={}",
                state.sequence,
                state.covered,
                state.generation,
                state.wal,
                runs,
                db.recovered_bytes()
            );
        }
        _ => return Err(usage()),
    }
    Ok(())
}

fn main() -> ExitCode {
    let mut args = std::env::args_os().skip(1);
    let result = (|| {
        let dir = args.next().ok_or_else(usage)?;
        let op = args
            .next()
            .and_then(|arg| arg.into_string().ok())
            .ok_or_else(usage)?;
        let args = args
            .map(|arg| arg.into_string().map_err(|_| usage()))
            .collect::<io::Result<Vec<_>>>()?;
        run(Path::new(&dir), &op, &args)
    })();
    if let Err(error) = result {
        eprintln!("{error}");
        ExitCode::FAILURE
    } else {
        ExitCode::SUCCESS
    }
}
~~~

</details>

### Step 4 — Kill and reopen at each barrier

Run the learner binary against independent temporary directories. Kill it only after it prints the selected barrier. Check inventory, values, deletion, and the next sequence after recovery.

<details>
<summary>Hint</summary>

Inspect the files before asking the CLI to reopen them. Separate a lost acknowledgement before append from one after WAL sync.

</details>

<details>
<summary>Implementation</summary>

Create `lab/crash.py`.

<!-- file: lab/crash.py -->
~~~python
"""Kill only the learner binary and recover from the files it left."""

import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile


def run(binary, path, *args):
    return subprocess.run(
        [binary, path, *args], capture_output=True, text=True, check=True, timeout=10,
        env={k: v for k, v in os.environ.items() if k != "LSM_PAUSE_AT"},
    ).stdout.rstrip("\n")


def stop_at(binary, path, boundary, *args):
    with subprocess.Popen(
        [binary, path, *args], env={**os.environ, "LSM_PAUSE_AT": boundary},
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    ) as child:
        try:
            readable, _, _ = select.select([child.stdout], [], [], 8)
            assert readable, f"{boundary}: timed out waiting for child"
            line = child.stdout.readline().rstrip("\n")
            assert line == f"paused {boundary}", (boundary, line, child.poll())
        finally:
            if child.poll() is None:
                child.kill()
            stdout, stderr = child.communicate(timeout=8)
        assert child.returncode == -9 and not stdout and not stderr, (stdout, stderr)


def files(path, prefix):
    return sorted(int(file.name.removeprefix(prefix)) for file in path.glob(f"{prefix}*"))


def recover(binary, root, op, boundary):
    path = root / f"{op}-{boundary}"
    assert run(binary, path, "put", "61", "6f6c64") == "ok 1"  # a=old
    assert run(binary, path, "put", "64", "6f6c64") == "ok 2"  # d=old
    assert run(binary, path, "flush") == "flushed 2"
    assert run(binary, path, "put", "61", "6e6577") == "ok 3"  # a=new
    assert run(binary, path, "delete", "64") == "ok 4"
    assert run(binary, path, "put", "7a", "") == "ok 5"  # z=empty
    if op == "compact":
        assert run(binary, path, "flush") == "flushed 5"
        assert run(binary, path, "put", "6d", "78") == "ok 6"  # m=x outside the compaction

    stop_at(binary, path, boundary, op)
    # Inspect file inventory before recovery can remove unreferenced outputs.
    before = boundary in ("outputs-synced", "before-manifest")
    dirty = boundary != "after-cleanup"
    if op == "flush":
        assert files(path, "run-") == ([1, 2])
        assert files(path, "wal-") == ([1, 2] if dirty else [2])
        expected = (5, 2, 1, 1, [1]) if before else (5, 5, 2, 2, [1, 2])
    else:
        assert files(path, "run-") == ([1, 2, 3] if dirty else [3])
        assert files(path, "wal-") == [2]
        expected = (6, 5, 2, 2, [1, 2]) if before else (6, 5, 3, 2, [3])
    assert (path / "MANIFEST.next").exists() == (boundary == "before-manifest")

    sequence, covered, generation, wal, runs = expected
    formatted_runs = ",".join(map(str, runs))
    assert run(binary, path, "state") == (
        f"sequence={sequence} covered={covered} generation={generation} "
        f"wal={wal} runs={formatted_runs} trimmed=0"
    )
    assert files(path, "run-") == runs and files(path, "wal-") == [wal]
    assert not (path / "MANIFEST.next").exists()
    assert run(binary, path, "get", "64") == "absent"
    assert run(binary, path, "get", "7a") == "value "
    expected_scan = "61=6e6577\n6d=78\n7a=" if op == "compact" else "61=6e6577\n7a="
    assert run(binary, path, "scan", "00", "ff") == expected_scan
    assert run(binary, path, "put", "6e", "79") == f"ok {sequence + 1}"
    assert run(binary, path, "get", "6e") == "value 79"
    print(f"{op} {boundary}: generation={generation}, covered={covered}, recovered sequence={sequence}")


def uncertain(binary, root, boundary, survives):
    path = root / boundary
    assert run(binary, path, "put", "61", "78") == "ok 1"
    stop_at(binary, path, boundary, "put", "62", "79")
    assert run(binary, path, "get", "61") == "value 78"
    assert run(binary, path, "get", "62") == ("value 79" if survives else "absent")
    outcome = "present" if survives else "absent"
    print(f"{boundary}: no acknowledgement observed; in-flight value {outcome}")


def main(binary):
    with tempfile.TemporaryDirectory(prefix="lsm-crash-") as directory:
        root = Path(directory)
        for op in ("flush", "compact"):
            for phase in ("outputs-synced", "before-manifest", "manifest-published", "after-cleanup"):
                recover(binary, root, op, phase)
        uncertain(binary, root, "before-wal", False)
        uncertain(binary, root, "after-wal-sync", True)


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
~~~

</details>

## Check it

~~~bash
cargo build --offline --locked --quiet --features fault-injection
python3 -B lab/crash.py target/debug/lsm
~~~

<!-- run: cargo fmt --check && cargo clippy --offline --locked --quiet --all-targets -- -D warnings && cargo build --offline --locked --quiet --features fault-injection && target=$(cargo metadata --offline --locked --no-deps --format-version 1 | python3 -c 'import json, sys; print(json.load(sys.stdin)["target_directory"])') && python3 -B lab/crash.py "$target/debug/lsm" -->

The gate recovered sequence 5 after every interrupted flush and sequence 6 after every interrupted compaction. An in-flight write stopped before WAL append was absent. The one stopped after WAL sync was present. Neither interruption produced a client acknowledgment. [Gate transcript](../evidence/gate.txt)

## If it goes wrong

If the recovered generation is wrong, confirm which copy of the manifest was authoritative at the barrier. If a clean run pauses, rebuild the CLI without the fault feature. If you use a custom cargo target directory, pass its debug binary to the harness.
