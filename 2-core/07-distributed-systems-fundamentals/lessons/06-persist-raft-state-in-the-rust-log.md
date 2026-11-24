# 06 Persist Raft state in the Rust log

> Core 07 · About 8 hours · Builds on the preceding lesson

## The problem

The simulated disk keeps a whole batch or discards it. A real writer can die halfway through writing a frame. Go needs a durable success signal from the same writer that synchronized the record.

## The mental model

~~~text
Go Ready.Save --> u32 length + JSON batch --> Rust log.append
Go resumes    <-- ACK byte 1              <-- file and name synced

startup: Rust verifies and repairs klog --> framed records --> Go validates Batch.Apply
         Rust sends length 0 and one u64 with recovered bytes when replay is complete
~~~

Pipe lengths and the recovered byte count are little-endian. Short reads are ordinary. EOF inside a packet is an error. The binary IPC envelope has its own one-MiB ceiling. The on-disk frame is still the Core 04 length and two CRCs. The local pipe uses the framing pattern from Core 06 without depending on its probe protocol.

## The pattern

One Rust child holds the exclusive writer lock from recovery through append. Use its existing scanner and write path. Raft replaces a conflicting suffix by appending a new logical replacement record. The file keeps earlier records until a later compaction design. Replay starts with empty application memory and checks the batch version, term, vote, and suffix before accepting it. A complete CRC failure stops startup. An incomplete trailing frame can be removed under the lock.

## Build it

### Step 1. Bring in Core 04

From your completed [Core 04 scratch project](../../04-rust-foundations/README.md), copy `Cargo.toml`, `Cargo.lock` and `src/` into a new `klog/` directory inside your Core 07 scratch project. If you need a fresh copy, run `python3 "$blueprint/scripts/replay_lessons.py" --keep "$blueprint/2-core/04-rust-foundations"`. Use the scratch directory that the replay prints as your Core 04 source.

<!-- continue: ../../04-rust-foundations into klog -->

<details>
<summary>Hint 1</summary>

Core 04's writer already owns the lock during repair.

</details>

<details>
<summary>Hint 2</summary>

Keep a dedicated `klog` crate next to `go.mod`. Both tools still build independently.

</details>

### Step 2. Stream verified records under the lock

Give `Log` a visitor that uses the file handle it already owns. Complete `seek(/* TODO */)` so replay starts at the first header.

<details>
<summary>Hint 1</summary>

Opening a second reader would compete for the lock.

</details>

<details>
<summary>Hint 2</summary>

Seek to byte zero and reuse the existing scanner on the locked file.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- edit: klog/src/log.rs -->
~~~rust
use std::fmt;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use crate::record::{self, HEADER_LEN, RecordError};
~~~

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

### Step 3. Serve the pipe protocol

Read the length before allocating. Use `read_exact` for the rest of a packet. Fill in the write order behind `append → /* TODO */ → flush`.

<details>
<summary>Hint 1</summary>

Go will use the first byte it receives as permission to release Raft's effects.

</details>

<details>
<summary>Hint 2</summary>

Emit ACK only after Log::append returns success. The zero-length packet belongs to startup replay.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: klog/src/bin/metad-wal.rs -->
~~~rust
use std::error::Error;
use std::io::{self, ErrorKind, Read, Write};
use std::path::Path;

use klog::log::Log;
use klog::record::MAX_PAYLOAD;

fn write_record(out: &mut impl Write, record: &[u8]) -> io::Result<()> {
    out.write_all(&(record.len() as u32).to_le_bytes())?;
    out.write_all(record)
}

fn read_record(input: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut length = [0; 4];
    match input.read_exact(&mut length[..1]) {
        Ok(()) => (),
        Err(error) if error.kind() == ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }
    input.read_exact(&mut length[1..])?;
    let size = u32::from_le_bytes(length) as usize;
    if size == 0 || size > MAX_PAYLOAD {
        return Err(io::Error::new(
            ErrorKind::InvalidData,
            "invalid WAL packet length",
        ));
    }
    let mut payload = vec![0; size];
    input.read_exact(&mut payload)?;
    Ok(Some(payload))
}

fn main() -> Result<(), Box<dyn Error>> {
    let args: Vec<_> = std::env::args_os().collect();
    let [_, path] = args.as_slice() else {
        return Err("usage: metad-wal WAL_FILE".into());
    };
    let mut log = Log::open(Path::new(path))?;
    let mut input = io::stdin().lock();
    let mut out = io::stdout().lock();
    log.visit(|record| {
        if record.is_empty() {
            return Err(io::Error::new(ErrorKind::InvalidData, "empty WAL record"));
        }
        write_record(&mut out, record)
    })?;
    write_record(&mut out, &[])?; // Zero marks the end of replay.
    out.write_all(&log.recovered_bytes().to_le_bytes())?;
    out.flush()?;

    while let Some(payload) = read_record(&mut input)? {
        log.append(&payload)?;
        out.write_all(&[1])?;
        out.flush()?;
    }
    Ok(())
}
~~~

</details>

### Step 4. Keep one Go writer handle

Start the child with its two pipe ends. Stream startup records through `Stable.Apply`. Bound pipe calls and close the process on failure so the peer cannot proceed on ambiguous storage state.

<details>
<summary>Hint 1</summary>

Close the parent's copy of the child's stdout writer after starting it.

</details>

<details>
<summary>Hint 2</summary>

A leaked writer descriptor can hide EOF when the child exits.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/wal/wal.go -->
~~~go
// Package wal uses the Rust klog process as a single, locked Raft writer.
package wal

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"time"

	"switchyard/metad/internal/raft"
)

const maxPayload = 1 << 20 // klog's one MiB payload ceiling

type record struct {
	Version int
	Batch   raft.Batch
}

type Writer struct {
	child *exec.Cmd
	in    *os.File
	out   *os.File
}

func Open(binary, path string, members int) (*Writer, raft.Stable, uint64, error) {
	childIn, in, err := os.Pipe()
	if err != nil {
		return nil, raft.Stable{}, 0, err
	}
	defer childIn.Close()
	out, childOut, err := os.Pipe()
	if err != nil {
		in.Close()
		return nil, raft.Stable{}, 0, err
	}
	defer childOut.Close()
	cmd := exec.Command(binary, path)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = childIn, childOut, os.Stderr
	if err := cmd.Start(); err != nil {
		in.Close()
		out.Close()
		return nil, raft.Stable{}, 0, err
	}
	childOut.Close() // Let read observe EOF if the child exits during startup.
	w := &Writer{child: cmd, in: in, out: out}
	stable, recovered, err := w.replay(members)
	if err != nil {
		w.Close()
		return nil, raft.Stable{}, 0, fmt.Errorf("replay WAL %s: %w", path, err)
	}
	return w, stable, recovered, nil
}

func (w *Writer) replay(members int) (raft.Stable, uint64, error) {
	var stable raft.Stable
	for {
		if err := w.out.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
			return stable, 0, err
		}
		var size uint32
		if err := binary.Read(w.out, binary.LittleEndian, &size); err != nil {
			return stable, 0, err
		}
		if size == 0 {
			var recovered uint64
			err := binary.Read(w.out, binary.LittleEndian, &recovered)
			return stable, recovered, err
		}
		if size > maxPayload {
			return stable, 0, fmt.Errorf("oversized WAL packet: %d", size)
		}
		raw := make([]byte, size)
		if _, err := io.ReadFull(w.out, raw); err != nil {
			return stable, 0, err
		}
		var r record
		if err := json.Unmarshal(raw, &r); err != nil {
			return stable, 0, err
		}
		if r.Version != 1 || r.Batch.Empty() {
			return stable, 0, errors.New("invalid WAL batch or version")
		}
		if err := stable.Apply(r.Batch, members); err != nil {
			return stable, 0, err
		}
	}
}

func (w *Writer) Save(batch raft.Batch) error {
	if batch.Empty() {
		return nil
	}
	raw, err := json.Marshal(record{Version: 1, Batch: batch})
	if err != nil {
		return err
	}
	if len(raw) > maxPayload {
		return fmt.Errorf("WAL batch exceeds %d bytes", maxPayload)
	}
	deadline := time.Now().Add(5 * time.Second)
	if err := w.in.SetWriteDeadline(deadline); err != nil {
		return err
	}
	if err := w.out.SetReadDeadline(deadline); err != nil {
		return err
	}
	if err := binary.Write(w.in, binary.LittleEndian, uint32(len(raw))); err != nil {
		return err
	}
	if _, err := w.in.Write(raw); err != nil {
		return err
	}
	var ack [1]byte
	if _, err := io.ReadFull(w.out, ack[:]); err != nil {
		return err
	}
	if ack[0] != 1 {
		return errors.New("invalid WAL acknowledgment")
	}
	return nil
}

func (w *Writer) Close() {
	w.in.Close()
	w.out.Close()
	w.child.Process.Kill()
	w.child.Wait()
}
~~~

</details>

### Step 5. Read the file through two restarts

Write a suffix replacement, reopen, and check it. Copy its prior file length to your notes. Cut into the newer frame, replay again, then flip a byte in a complete record.

<details>
<summary>Hint 1</summary>

A valid later frame and an incomplete later frame produce different replay states.

</details>

<details>
<summary>Hint 2</summary>

The cut restores the earlier suffix. The byte flip must stop startup and preserve the damaged file.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/wal/wal_test.go -->
~~~go
package wal

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"switchyard/metad/internal/raft"
)

func TestKlogRoundTrip(t *testing.T) {
	binary := os.Getenv("METAD_WAL_WRITER")
	if binary == "" {
		t.Skip("build the Rust writer and set METAD_WAL_WRITER")
	}
	path := filepath.Join(t.TempDir(), "peer.klog")
	w, _, _, err := Open(binary, path, 3)
	if err != nil {
		t.Fatal(err)
	}
	first := raft.Batch{Hard: &raft.HardState{Term: 3, Vote: 1}, From: 1,
		Entries: []raft.Entry{{Term: 1}, {Term: 3}}}
	err = w.Save(first)
	w.Close()
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	w, stable, recovered, err := Open(binary, path, 3)
	if err != nil {
		t.Fatal(err)
	}
	if recovered != 0 || stable.Hard != *first.Hard || len(stable.Entries) != 2 {
		w.Close()
		t.Fatalf("wrong replay: %+v, trimmed %d bytes", stable, recovered)
	}
	err = w.Save(raft.Batch{Hard: &raft.HardState{Term: 4}, From: 2,
		Entries: []raft.Entry{{Term: 4}}})
	w.Close()
	if err != nil {
		t.Fatal(err)
	}
	w, stable, _, err = Open(binary, path, 3)
	if err != nil {
		t.Fatal(err)
	}
	w.Close()
	if len(stable.Entries) != 2 || stable.Entries[1].Term != 4 {
		t.Fatal("new suffix was not replayed", stable)
	}
	if err := os.Truncate(path, info.Size()+15); err != nil {
		t.Fatal(err)
	}
	w, stable, recovered, err = Open(binary, path, 3)
	if err != nil {
		t.Fatal(err)
	}
	w.Close()
	if recovered != 15 || stable.Hard != *first.Hard || stable.Entries[1].Term != 3 {
		t.Fatalf("wrong repair: %+v, trimmed %d bytes", stable, recovered)
	}
	t.Logf("replayed a replacement, then trimmed %d torn bytes and recovered the previous suffix", recovered)

	broken, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	broken[12] ^= 1 // A complete frame with a changed payload.
	if err := os.WriteFile(path, broken, 0600); err != nil {
		t.Fatal(err)
	}
	if w, _, _, err := Open(binary, path, 3); err == nil {
		w.Close()
		t.Fatal("opened a corrupt log")
	}
	after, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(after, broken) {
		t.Fatal("startup changed the corrupt file", err)
	}
	t.Log("refused a complete damaged frame and preserved its bytes")
}
~~~

</details>

## Check it

~~~bash
cargo fmt --manifest-path klog/Cargo.toml --check && cargo clippy --quiet --manifest-path klog/Cargo.toml --all-targets -- -D warnings && cargo build --quiet --manifest-path klog/Cargo.toml --target-dir klog/target --bin metad-wal && test -z "$(gofmt -l .)" && go vet ./... && METAD_WAL_WRITER="$PWD/klog/target/debug/metad-wal" go test -race -count=1 -v ./...
~~~

<!-- run: cargo fmt --manifest-path klog/Cargo.toml --check && cargo clippy --quiet --manifest-path klog/Cargo.toml --all-targets -- -D warnings && cargo build --quiet --manifest-path klog/Cargo.toml --target-dir klog/target --bin metad-wal && test -z "$(gofmt -l .)" && go vet ./... && METAD_WAL_WRITER="$PWD/klog/target/debug/metad-wal" go test -race -count=1 -v ./... -->

~~~text
wal_test.go:66: replayed a replacement, then trimmed 15 torn bytes and recovered the previous suffix
wal_test.go:84: refused a complete damaged frame and preserved its bytes
~~~

The Go test starts the Rust child, reopens its files, and distinguishes an incomplete final frame from complete corrupt bytes.

Full captures are in [06-wal.txt](../evidence/lessons/06-wal.txt).

## If it goes wrong

| Symptom | What to inspect |
|---|---|
| Go reads EOF during startup | Read the Rust child's stderr. Check the log path and format before trying the peer again. |
| A second writer refuses the same file | Give each peer its own file and stop its current writer before reopening it. |

## Explain it

1. Why can a logical suffix change stay append-only on disk?
2. At what point is it safe for Go to release a Raft acknowledgment?
