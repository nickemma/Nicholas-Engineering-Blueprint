# 03 Recover across the snapshot and log boundary

> Consensus in depth · Week 2 · Builds on lesson 02

## The problem

After writing a snapshot, a peer may stop before it has removed the old log. After replacing the WAL, its next write still has to reach the correct file.

## The mental model

The existing WAL can end with a snapshot frame and still contain everything the snapshot covers. A separately written replacement contains hard state, the snapshot, and the suffix. Its writer already owns the new inode when the replacement becomes visible at the canonical path.

## The pattern

Persist and validate the snapshot before replacing the WAL. The Rust writer synchronizes each frame. Go holds a sidecar lock across the rename and synchronizes the directory. Recovery opens the canonical path, where either complete generation contains the snapshot and hard state.

## Build it

### Step 1 — Encode and restore applied state

List every part of the state machine that a follower needs after installing a snapshot. Encode and validate that state before reporting an install.

<details>
<summary>Hint 1</summary>

Lease tokens, logical time, and retry receipts all affect later results.

</details>

<details>
<summary>Hint 2</summary>

Copy the snapshot base into Applied before the remaining log is committed.

</details>

<details>
<summary>Implementation</summary>

Create `internal/metad/snapshot_state.go`.

<!-- file: internal/metad/snapshot_state.go -->
~~~go
package metad

import (
	"encoding/base64"
	"encoding/json"
	"errors"
)

const compactEvery = 8

type leaseRecord struct {
	Owner   string
	Token   int
	Expires int64
}

type snapshotState struct {
	Version int
	Values  map[string]string
	Retries map[string]map[string]receipt
	Leases  map[string]leaseRecord
	Now     int64
}

func (s *state) encode() (string, error) {
	snapshot := snapshotState{
		Version: 1, Values: s.values, Retries: s.retries, Now: s.now,
		Leases: make(map[string]leaseRecord, len(s.leases)),
	}
	for key, l := range s.leases {
		snapshot.Leases[key] = leaseRecord{Owner: l.owner, Token: l.token, Expires: l.expires}
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(data), nil
}

func decodeState(encoded string) (*state, error) {
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return nil, err
	}
	var snapshot snapshotState
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return nil, err
	}
	if snapshot.Version != 1 || snapshot.Values == nil || snapshot.Retries == nil || snapshot.Leases == nil {
		return nil, errors.New("invalid snapshot version or missing state")
	}
	s := newState()
	s.values, s.retries, s.now = snapshot.Values, snapshot.Retries, snapshot.Now
	for key, l := range snapshot.Leases {
		s.leases[key] = lease{owner: l.Owner, token: l.Token, expires: l.Expires}
	}
	return s, nil
}
~~~

Find these blocks in `internal/metad/runtime.go` in order.

<!-- edit: internal/metad/runtime.go -->
~~~go
)

type Status struct {
	ID, Leader, Applied int
	Term                uint64
	Role                raft.Role
}

type outcome struct {
~~~

Replace it with this version.

~~~go
)

type Status struct {
	ID, Leader, Applied, Snapshot, Vote int
	Term                                uint64
	Role                                raft.Role
}

type outcome struct {
~~~

<!-- edit: internal/metad/runtime.go -->
~~~go
	defer tick.Stop()
	pending := make(map[int]waiting)
	store := newState()
	status := Status{ID: r.id}

	for {
		select {
~~~

Replace it with this version.

~~~go
	defer tick.Stop()
	pending := make(map[int]waiting)
	store := newState()
	snapshot := r.node.Snapshot()
	if snapshot.Index != 0 {
		var err error
		store, err = decodeState(snapshot.Data)
		if err != nil {
			return fmt.Errorf("restore state at index %d: %w", snapshot.Index, err)
		}
	}
	status := Status{
		ID: r.id, Applied: snapshot.Index, Snapshot: snapshot.Index,
		Vote: r.node.Vote(), Term: r.node.Term(), Role: r.node.Role(),
	}
	nextSnapshot := snapshot.Index + compactEvery

	for {
		select {
~~~

<!-- edit: internal/metad/runtime.go -->
~~~go
		}

		ready := r.node.Take()
		if err := r.disk.Save(ready.Save); err != nil {
			return fmt.Errorf("persist before sending: %w", err)
		}
		role, term := r.node.Role(), r.node.Term()
		if role == raft.Leader && (role != status.Role || term != status.Term) {
			log.Printf("elected peer=%d term=%d", r.id, term)
		}
		status.Role, status.Term, status.Leader = role, term, r.node.Leader()
		for _, message := range ready.Messages {
			wire.send(message)
		}
~~~

Replace it with this version.

~~~go
		}

		ready := r.node.Take()
		var installed *state
		if incoming := ready.Save.Snapshot; incoming != nil {
			var err error
			installed, err = decodeState(incoming.Data)
			if err != nil {
				return fmt.Errorf("install state at index %d: %w", incoming.Index, err)
			}
		}
		if err := r.disk.Save(ready.Save); err != nil {
			return fmt.Errorf("persist before sending: %w", err)
		}
		if installed != nil {
			store = installed
			status.Applied = ready.Save.Snapshot.Index
			status.Snapshot = status.Applied
			nextSnapshot = status.Applied + compactEvery
			log.Printf("installed peer=%d index=%d", r.id, status.Applied)
		}
		role, term := r.node.Role(), r.node.Term()
		if role == raft.Leader && (role != status.Role || term != status.Term) {
			log.Printf("elected peer=%d term=%d", r.id, term)
		}
		status.Role, status.Term, status.Leader, status.Vote = role, term, r.node.Leader(), r.node.Vote()
		for _, message := range ready.Messages {
			wire.send(message)
		}
~~~

<!-- edit: internal/metad/runtime.go -->
~~~go
				delete(pending, entry.Index)
			}
		}
		for index, p := range pending {
			switch {
			case p.ctx.Err() != nil:
~~~

Replace it with this version.

~~~go
				delete(pending, entry.Index)
			}
		}
		if status.Applied >= nextSnapshot {
			nextSnapshot = status.Applied + compactEvery
			data, err := store.encode()
			if err != nil {
				return err
			}
			if len(data) <= raft.MaxSnapshotBytes {
				if err := r.node.Compact(status.Applied, data); err != nil {
					return err
				}
				if err := r.disk.Save(r.node.Take().Save); err != nil {
					return fmt.Errorf("persist local snapshot: %w", err)
				}
				status.Snapshot = status.Applied
				log.Printf("compacted peer=%d index=%d", r.id, status.Snapshot)
			}
		}
		for index, p := range pending {
			switch {
			case p.ctx.Err() != nil:
~~~

Find these blocks in `internal/metad/http.go` in order.

<!-- edit: internal/metad/http.go -->
~~~go
		return
	}
	switch message.Kind {
	case raft.RequestVote, raft.VoteReply, raft.Append, raft.AppendReply:
	default:
		http.Error(w, "unknown message", http.StatusBadRequest)
		return
~~~

Replace it with this version.

~~~go
		return
	}
	switch message.Kind {
	case raft.RequestVote, raft.VoteReply, raft.Append, raft.AppendReply, raft.Install:
	default:
		http.Error(w, "unknown message", http.StatusBadRequest)
		return
~~~

</details>

### Step 2 — Replace a complete WAL

Build the new generation beside the old one. Preserve hard state and write the retained suffix in batches. Run the handover after every second durable snapshot so the first boundary remains observable.

<details>
<summary>Hint 1</summary>

The canonical file name must refer to a complete WAL at every crash boundary.

</details>

<details>
<summary>Hint 2</summary>

An inode lock follows the file across a rename. The sidecar lock covers the file name through that transition.

</details>

<details>
<summary>Implementation</summary>

Find these blocks in `internal/wal/wal.go` in order.

<!-- edit: internal/wal/wal.go -->
~~~go
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
~~~

Replace it with this version.

~~~go
}

type Writer struct {
	child        *exec.Cmd
	binary, path string
	members      int
	lock         *os.File
	stable       raft.Stable
	snapshots    int
	failed       bool
	in           *os.File
	out          *os.File
}

func Open(binary, path string, members int) (*Writer, raft.Stable, uint64, error) {
	lock, err := lockWAL(path)
	if err != nil {
		return nil, raft.Stable{}, 0, err
	}
	// An interrupted replacement is disposable. Only path is authoritative.
	if err := os.Remove(path + ".next"); err != nil && !errors.Is(err, os.ErrNotExist) {
		lock.Close()
		return nil, raft.Stable{}, 0, err
	}
	w, stable, recovered, err := openWriter(binary, path, members)
	if err != nil {
		lock.Close()
		return nil, stable, 0, err
	}
	w.lock, w.stable = lock, stable
	return w, stable, recovered, nil
}

func openWriter(binary, path string, members int) (*Writer, raft.Stable, uint64, error) {
	childIn, in, err := os.Pipe()
	if err != nil {
		return nil, raft.Stable{}, 0, err
~~~

<!-- edit: internal/wal/wal.go -->
~~~go
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
~~~

Replace it with this version.

~~~go
		return nil, raft.Stable{}, 0, err
	}
	childOut.Close() // Let read observe EOF if the child exits during startup.
	w := &Writer{child: cmd, in: in, out: out, binary: binary, path: path, members: members}
	stable, recovered, err := w.replay(members)
	if err != nil {
		w.closeChild()
		return nil, raft.Stable{}, 0, fmt.Errorf("replay WAL %s: %w", path, err)
	}
	return w, stable, recovered, nil
~~~

<!-- edit: internal/wal/wal.go -->
~~~go
}

func (w *Writer) Save(batch raft.Batch) error {
	if batch.Empty() {
		return nil
	}
	raw, err := json.Marshal(record{Version: 1, Batch: batch})
	if err != nil {
		return err
~~~

Replace it with this version.

~~~go
}

func (w *Writer) Save(batch raft.Batch) error {
	if w.failed {
		return errors.New("WAL writer failed; reopen and replay")
	}
	if batch.Empty() {
		return nil
	}
	if err := w.stable.Apply(batch, w.members); err != nil {
		return err
	}
	if err := w.writeBatch(batch); err != nil {
		w.failed = true
		return err
	}
	if batch.Snapshot != nil {
		w.snapshots++
		if w.snapshots == 2 {
			if err := w.reclaim(); err != nil {
				w.failed = true
				return fmt.Errorf("replace WAL: %w", err)
			}
			w.snapshots = 0
		}
	}
	return nil
}

func (w *Writer) writeBatch(batch raft.Batch) error {
	raw, err := json.Marshal(record{Version: 1, Batch: batch})
	if err != nil {
		return err
~~~

<!-- edit: internal/wal/wal.go -->
~~~go
}

func (w *Writer) Close() {
	w.in.Close()
	w.out.Close()
	w.child.Process.Kill()
~~~

Replace it with this version.

~~~go
}

func (w *Writer) Close() {
	w.closeChild()
	w.lock.Close()
}

func (w *Writer) closeChild() {
	w.in.Close()
	w.out.Close()
	w.child.Process.Kill()
~~~

Create `internal/wal/reclaim.go`.

<!-- file: internal/wal/reclaim.go -->
~~~go
package wal

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"

	"switchyard/metad/internal/raft"
)

// Keep the name locked across replacement of the data inode.
func lockWAL(path string) (*os.File, error) {
	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, fmt.Errorf("lock WAL %s: %w", path, err)
	}
	return lock, nil
}

func (w *Writer) reclaim() error {
	parent := filepath.Dir(w.path)
	dir, err := os.Open(parent)
	if err != nil {
		return err
	}
	defer dir.Close()
	name := w.path + ".next"
	defer os.Remove(name)

	next, _, _, err := openWriter(w.binary, name, w.members)
	if err != nil {
		return err
	}
	defer func() {
		if next != nil {
			next.closeChild()
		}
	}()
	current := w.stable
	if err := next.writeBatch(raft.Batch{Hard: &current.Hard, Snapshot: &current.Snapshot}); err != nil {
		return err
	}
	for offset := 0; offset < len(current.Entries); offset += 16 {
		batch := raft.Batch{
			From:    current.Snapshot.Index + offset + 1,
			Entries: current.Entries[offset:min(offset+16, len(current.Entries))],
		}
		if err := next.writeBatch(batch); err != nil {
			return err
		}
	}
	if err := os.Rename(name, w.path); err != nil {
		return err
	}
	// The new writer already owns the replacement inode. Once renamed,
	// switch even if directory sync fails so the caller cannot use the old inode.
	w.closeChild()
	w.in, w.out, w.child = next.in, next.out, next.child
	next = nil
	return dir.Sync()
}
~~~

</details>

### Step 3 — Reopen before and after replacement

Check the two recovery shapes and append one more record after the rename. Validate the on-disk size with a repeated-value fixture.

<details>
<summary>Hint 1</summary>

A matching boundary keeps its suffix. A different term discards it.

</details>

<details>
<summary>Hint 2</summary>

A smaller file alone cannot show that the next append used the replacement or that the vote survived.

</details>

<details>
<summary>Implementation</summary>

Create `internal/raft/snapshot_test.go`.

<!-- file: internal/raft/snapshot_test.go -->
~~~go
package raft

import (
	"slices"
	"testing"
)

func TestReplayOldLogBesideNewSnapshot(t *testing.T) {
	hard := HardState{Term: 3, Vote: 2}
	a, b, c := Entry{Term: 1}, Entry{Term: 2}, Entry{Term: 3}
	original := Batch{Hard: &hard, From: 1, Entries: []Entry{a, b, c}}
	for _, test := range []struct {
		name string
		term uint64
		want []Entry
	}{
		{"matching boundary", 2, []Entry{c}},
		{"different boundary", 3, nil},
	} {
		t.Run(test.name, func(t *testing.T) {
			var disk Stable
			if err := disk.Apply(original, 3); err != nil {
				t.Fatal(err)
			}
			diskBeforePublish := Restore(1, 3, 1, disk)
			if diskBeforePublish.Snapshot().Index != 0 || len(diskBeforePublish.Entries()) != 3 {
				t.Fatal("original complete log did not survive")
			}
			marker := Snapshot{Index: 2, Term: test.term, Data: "job=queued"}
			if err := disk.Apply(Batch{Snapshot: &marker}, 3); err != nil {
				t.Fatal(err)
			}
			node := Restore(1, 3, 1, disk)
			if node.Snapshot() != marker || node.Vote() != 2 || node.Term() != 3 ||
				node.commit != 2 || !slices.Equal(node.Entries(), test.want) {
				t.Fatalf("restored the wrong boundary, hard state or suffix: %+v", disk)
			}
			t.Logf("snapshot index=%d term=%d; vote=%d; remaining entries=%d",
				marker.Index, marker.Term, node.Vote(), len(node.Entries()))
		})
	}
}
~~~

Create `internal/wal/reclaim_test.go`.

<!-- file: internal/wal/reclaim_test.go -->
~~~go
package wal

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"switchyard/metad/internal/raft"
)

func TestReplaceWALAfterDurableSnapshot(t *testing.T) {
	binary := os.Getenv("METAD_WAL_WRITER")
	if binary == "" {
		t.Skip("build the Rust writer and set METAD_WAL_WRITER")
	}
	path := filepath.Join(t.TempDir(), "peer.klog")
	open := func() (*Writer, raft.Stable) {
		t.Helper()
		w, stable, _, err := Open(binary, path, 3)
		if err != nil {
			t.Fatal(err)
		}
		return w, stable
	}
	w, _ := open()
	save := func(batch raft.Batch) {
		t.Helper()
		if err := w.Save(batch); err != nil {
			t.Fatal(err)
		}
	}
	hard := raft.HardState{Term: 3, Vote: 2}
	entry := raft.Entry{Term: 3, Command: raft.Command{Op: "put", Key: "job", Value: strings.Repeat("x", 512)}}
	for i := 1; i <= 20; i++ {
		save(raft.Batch{Hard: &hard, From: i, Entries: []raft.Entry{entry}})
	}
	snapshot := raft.Snapshot{Index: 16, Term: 3, Data: "state-at-16"}
	save(raft.Batch{Snapshot: &snapshot})
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	w.Close()
	w, restored := open()
	if restored.Snapshot != snapshot || restored.Hard != hard || len(restored.Entries) != 4 {
		t.Fatalf("snapshot with the old records present: %+v", restored)
	}
	snapshot = raft.Snapshot{Index: 17, Term: 3, Data: "state-at-17"}
	save(raft.Batch{Snapshot: &snapshot})
	snapshot = raft.Snapshot{Index: 18, Term: 3, Data: "state-at-18"}
	save(raft.Batch{Snapshot: &snapshot})
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if after.Size() >= info.Size() {
		t.Fatal("the replacement WAL did not reclaim obsolete records")
	}
	if other, _, _, err := Open(binary, path, 3); err == nil {
		other.Close()
		t.Fatal("a second writer opened the replacement generation")
	}
	// This append must reach the new inode.
	save(raft.Batch{From: 21, Entries: []raft.Entry{entry}})
	w.Close()
	w, restored = open()
	defer w.Close()
	if restored.Snapshot != snapshot || restored.Hard != hard || len(restored.Entries) != 3 ||
		restored.Entries[2] != entry {
		t.Fatalf("wrong state after reopening the replacement: %+v", restored)
	}
	t.Logf("WAL reduced from %d to %d bytes before next append; term=%d vote=%d suffix=%d",
		info.Size(), after.Size(), restored.Hard.Term, restored.Hard.Vote, len(restored.Entries))
}
~~~

</details>

## Check it

~~~bash
cargo build --quiet --locked --manifest-path klog/Cargo.toml --bin metad-wal
METAD_WAL_WRITER="$PWD/klog/target/debug/metad-wal" go test -race -count=1 -v ./internal/raft ./internal/wal -run "TestReplayOldLog|TestReplaceWAL"
~~~

<!-- run: cargo build --quiet --locked --manifest-path klog/Cargo.toml --bin metad-wal && METAD_WAL_WRITER="$PWD/klog/target/debug/metad-wal" go test -race -count=1 -v ./internal/raft ./internal/wal -run "TestReplayOldLog|TestReplaceWAL" -->

The fixture reported `WAL reduced from 13140 to 1311 bytes before next append; term=3 vote=2 suffix=3`. This is a single repeatedly written key. The snapshot has a 128 KiB encoded limit in this teaching runtime. Peers skip compaction when the state exceeds that limit.

## If it goes wrong

If recovery sees index 16 but loses the vote, inspect the replacement’s first batch. If a successful append vanishes, check the process swap after rename and reopen the canonical path.
