# 02 Compact a log and install a snapshot

> Consensus in depth · Week 1 · Builds on lesson 01

## The problem

A follower has been offline through many updates. After the leader drops old entries from memory, ordinary AppendEntries cannot send the entries that follower needs.

## The mental model

If the snapshot ends at index 8 in term 2, slot 0 in the retained slice is a marker for index 8. Slot 1 is index 9. Network messages and the commit index continue to use absolute indexes.

## The pattern

A snapshot carries the applied state and its last included log index and term. When a peer receives one, it can keep later entries only if it agrees with the snapshot at that boundary. The Raft core treats the state bytes as opaque.

## Build it

### Step 1 — Represent the base and suffix

Work out the conversion for a first entry, the boundary itself, and the end of the retained log. Turn those equations into helpers.

<details>
<summary>Hint 1</summary>

Use the snapshot index as the slice offset.

</details>

<details>
<summary>Hint 2</summary>

Use the boundary term in both vote freshness and the AppendEntries prefix check.

</details>

<details>
<summary>Implementation</summary>

Create `internal/raft/snapshot.go`.

<!-- file: internal/raft/snapshot.go -->
~~~go
package raft

import (
	"fmt"
	"slices"
)

// A snapshot represents the state after applying Index. Data is an opaque
// immutable string so sending a snapshot cannot share a mutable buffer.
type Snapshot struct {
	Index int
	Term  uint64
	Data  string
}

// Leave room for JSON escaping and envelope fields in the peer transport.
const MaxSnapshotBytes = 128 << 10

func (s Snapshot) valid(currentTerm uint64) bool {
	return s.Index > 0 && s.Term > 0 && s.Term <= currentTerm &&
		len(s.Data) > 0 && len(s.Data) <= MaxSnapshotBytes
}

func (n *Node) Snapshot() Snapshot { return n.snapshot }
func (n *Node) Vote() int          { return n.vote }

func (n *Node) lastIndex() int     { return n.snapshot.Index + len(n.log) - 1 }
func (n *Node) at(index int) Entry { return n.log[index-n.snapshot.Index] }

func (n *Node) matches(index int, term uint64) bool {
	return index >= n.snapshot.Index && index <= n.lastIndex() && n.at(index).Term == term
}

func (n *Node) Compact(index int, data string) error {
	if index <= n.snapshot.Index || index > n.commit {
		return fmt.Errorf("cannot compact through index %d", index)
	}
	snapshot := Snapshot{Index: index, Term: n.at(index).Term, Data: data}
	if !snapshot.valid(n.term) {
		return fmt.Errorf("invalid snapshot at index %d", index)
	}
	n.install(snapshot)
	return nil
}

func (n *Node) install(snapshot Snapshot) {
	var suffix []Entry
	if n.matches(snapshot.Index, snapshot.Term) {
		suffix = slices.Clone(n.log[snapshot.Index-n.snapshot.Index+1:])
	}
	n.log = append([]Entry{{Term: snapshot.Term}}, suffix...)
	n.snapshot = snapshot
	n.commit = max(n.commit, snapshot.Index)
	n.ready.Save.Snapshot = &snapshot
}

func (n *Node) acceptSnapshot(m Message) {
	if m.Snapshot == nil || !m.Snapshot.valid(m.Term) {
		return
	}
	snapshot := *m.Snapshot
	if snapshot.Index > n.commit {
		n.install(snapshot)
	}
	n.send(m.From, Message{Kind: AppendReply, OK: true, Match: snapshot.Index})
}
~~~

Replace `internal/raft/commit.go` with the version below.

<!-- file: internal/raft/commit.go -->
~~~go
package raft

import "slices"

type Applied struct {
	Index int
	Entry
}

func (n *Node) appendLocal(command Command) {
	n.replaceSuffix(n.lastIndex()+1, []Entry{{Term: n.term, Command: command}})
}

// tryCommit runs only on the leader. The median-like order statistic
// is the largest index held by a strict majority, including the leader.
func (n *Node) tryCommit() bool {
	matches := make([]int, n.members)
	for peer := 1; peer <= n.members; peer++ {
		matches[peer-1] = n.progress[peer].match
	}
	matches[n.id-1] = n.lastIndex()
	slices.Sort(matches)
	index := matches[(len(matches)-1)/2]
	if index <= n.commit || n.at(index).Term != n.term {
		return false
	}
	n.commitThrough(index)
	return true
}

func (n *Node) commitThrough(index int) {
	for n.commit < index {
		n.commit++
		n.ready.Applied = append(n.ready.Applied, Applied{Index: n.commit, Entry: n.at(n.commit)})
	}
}
~~~

</details>

### Step 2 — Send the snapshot to a lagging peer

For each follower, choose AppendEntries or InstallSnapshot from its next index. Save the follower’s new snapshot before its acknowledgment leaves the driver.

<details>
<summary>Hint 1</summary>

A next index at or below the base needs a snapshot.

</details>

<details>
<summary>Hint 2</summary>

A follower already ahead can return its boundary as a hint. The leader can use the hint after checking its own term at that index.

</details>

<details>
<summary>Implementation</summary>

Find these blocks in `internal/raft/node.go` in order.

<!-- edit: internal/raft/node.go -->
~~~go
	VoteReply   Kind = "vote_reply"
	Append      Kind = "append"
	AppendReply Kind = "append_reply"
)

type Message struct {
~~~

Replace it with this version.

~~~go
	VoteReply   Kind = "vote_reply"
	Append      Kind = "append"
	AppendReply Kind = "append_reply"
	Install     Kind = "install_snapshot"
)

type Message struct {
~~~

<!-- edit: internal/raft/node.go -->
~~~go
	Prev, Match, Commit int
	PrevTerm            uint64
	Entries             []Entry
}

type Ready struct {
~~~

Replace it with this version.

~~~go
	Prev, Match, Commit int
	PrevTerm            uint64
	Entries             []Entry
	Snapshot            *Snapshot `json:",omitempty"`
}

type Ready struct {
~~~

<!-- edit: internal/raft/node.go -->
~~~go
	log      []Entry
	progress []progress
	commit   int
}

func New(id, members int, seed int64) *Node {
~~~

Replace it with this version.

~~~go
	log      []Entry
	progress []progress
	commit   int
	snapshot Snapshot
}

func New(id, members int, seed int64) *Node {
~~~

<!-- edit: internal/raft/node.go -->
~~~go
	}
	for peer := 1; peer <= n.members; peer++ {
		if peer != n.id {
			n.send(peer, Message{Kind: RequestVote, Prev: len(n.log) - 1, PrevTerm: n.log[len(n.log)-1].Term})
		}
	}
}
~~~

Replace it with this version.

~~~go
	}
	for peer := 1; peer <= n.members; peer++ {
		if peer != n.id {
			n.send(peer, Message{Kind: RequestVote, Prev: n.lastIndex(), PrevTerm: n.at(n.lastIndex()).Term})
		}
	}
}
~~~

<!-- edit: internal/raft/node.go -->
~~~go
			n.votes[m.From] = true
			n.win()
		}
	case Append:
		n.role, n.leader = Follower, m.From
		n.resetTimer()
		n.acceptAppend(m)
	case AppendReply:
		if n.role == Leader {
			n.appendReply(m)
~~~

Replace it with this version.

~~~go
			n.votes[m.From] = true
			n.win()
		}
	case Append, Install:
		n.role, n.leader = Follower, m.From
		n.resetTimer()
		if m.Kind == Install {
			n.acceptSnapshot(m)
		} else {
			n.acceptAppend(m)
		}
	case AppendReply:
		if n.role == Leader {
			n.appendReply(m)
~~~

Find these blocks in `internal/raft/replication.go` in order.

<!-- edit: internal/raft/replication.go -->
~~~go
func (n *Node) Entries() []Entry { return slices.Clone(n.log[1:]) }

func (n *Node) upToDate(m Message) bool {
	last := len(n.log) - 1
	term := n.log[last].Term
	return m.PrevTerm > term || (m.PrevTerm == term && m.Prev >= last)
}

func (n *Node) startReplication() {
	n.progress = make([]progress, n.members+1)
	for peer := 1; peer <= n.members; peer++ {
		n.progress[peer].next = len(n.log)
	}
}
~~~

Replace it with this version.

~~~go
func (n *Node) Entries() []Entry { return slices.Clone(n.log[1:]) }

func (n *Node) upToDate(m Message) bool {
	last := n.lastIndex()
	term := n.at(last).Term
	return m.PrevTerm > term || (m.PrevTerm == term && m.Prev >= last)
}

func (n *Node) startReplication() {
	n.progress = make([]progress, n.members+1)
	for peer := 1; peer <= n.members; peer++ {
		n.progress[peer].next = n.lastIndex() + 1
	}
}
~~~

<!-- edit: internal/raft/replication.go -->
~~~go
	n.appendLocal(command)
	n.tryCommit()
	n.broadcast()
	return len(n.log) - 1, n.term, true
}

func (n *Node) broadcast() {
~~~

Replace it with this version.

~~~go
	n.appendLocal(command)
	n.tryCommit()
	n.broadcast()
	return n.lastIndex(), n.term, true
}

func (n *Node) broadcast() {
~~~

<!-- edit: internal/raft/replication.go -->
~~~go

func (n *Node) replicate(peer int) {
	next := n.progress[peer].next
	end := min(next+16, len(n.log))
	n.send(peer, Message{
		Kind: Append, Prev: next - 1, PrevTerm: n.log[next-1].Term,
		Entries: slices.Clone(n.log[next:end]), Commit: n.commit,
	})
}

func (n *Node) acceptAppend(m Message) {
	if m.Prev < 0 || m.Prev >= len(n.log) || n.log[m.Prev].Term != m.PrevTerm {
		n.rejectAppend(m)
		return
	}
	for i, entry := range m.Entries {
		index := m.Prev + 1 + i
		if index >= len(n.log) || n.log[index].Term != entry.Term {
			n.replaceSuffix(index, m.Entries[i:])
			break
		}
~~~

Replace it with this version.

~~~go

func (n *Node) replicate(peer int) {
	next := n.progress[peer].next
	if next <= n.snapshot.Index {
		n.send(peer, Message{Kind: Install, Snapshot: &Snapshot{
			Index: n.snapshot.Index, Term: n.snapshot.Term, Data: n.snapshot.Data,
		}})
		return
	}
	end := min(next+16, n.lastIndex()+1)
	base := n.snapshot.Index
	n.send(peer, Message{
		Kind: Append, Prev: next - 1, PrevTerm: n.at(next - 1).Term,
		Entries: slices.Clone(n.log[next-base : end-base]), Commit: n.commit,
	})
}

func (n *Node) acceptAppend(m Message) {
	if m.Prev < n.snapshot.Index {
		n.send(m.From, Message{Kind: AppendReply, Prev: m.Prev, Match: n.snapshot.Index, PrevTerm: n.snapshot.Term})
		return
	}
	if !n.matches(m.Prev, m.PrevTerm) {
		n.rejectAppend(m)
		return
	}
	for i, entry := range m.Entries {
		index := m.Prev + 1 + i
		if !n.matches(index, entry.Term) {
			n.replaceSuffix(index, m.Entries[i:])
			break
		}
~~~

<!-- edit: internal/raft/replication.go -->
~~~go
	p := &n.progress[m.From]
	if !m.OK {
		// Ignore a rejection for a probe that has already been superseded.
		if m.Prev == p.next-1 && p.next > p.match+1 {
			p.next--
			n.replicate(m.From)
		}
		return
	}
	if m.Match <= p.match || m.Match >= len(n.log) {
		return
	}
	p.match, p.next = m.Match, m.Match+1
~~~

Replace it with this version.

~~~go
	p := &n.progress[m.From]
	if !m.OK {
		// Ignore a rejection for a probe that has already been superseded.
		if m.Prev != p.next-1 {
			return
		}
		if m.Match >= p.next && n.matches(m.Match, m.PrevTerm) {
			p.next = m.Match + 1
		} else if p.next > p.match+1 {
			p.next--
		} else {
			return
		}
		n.replicate(m.From)
		return
	}
	if m.Match <= p.match || m.Match > n.lastIndex() {
		return
	}
	p.match, p.next = m.Match, m.Match+1
~~~

<!-- edit: internal/raft/replication.go -->
~~~go
		n.broadcast()
		return
	}
	if p.next < len(n.log) {
		n.replicate(m.From)
	}
}
~~~

Replace it with this version.

~~~go
		n.broadcast()
		return
	}
	if p.next <= n.lastIndex() {
		n.replicate(m.From)
	}
}
~~~

</details>

### Step 3 — Replay a compacted prefix

Add the snapshot to the stable batch and stop the lagging follower in the seeded run. Rejoin it after the leader compacts.

<details>
<summary>Hint 1</summary>

Reuse the same boundary check during recovery.

</details>

<details>
<summary>Hint 2</summary>

The simulator should advance the installed follower’s applied index without replaying the entries inside the snapshot.

</details>

<details>
<summary>Implementation</summary>

Find these blocks in `internal/raft/stable.go` in order.

<!-- edit: internal/raft/stable.go -->
~~~go
// Batch is one atomic change. From is the 1-based start of a new suffix,
// or zero for a change that leaves the log alone.
type Batch struct {
	Hard    *HardState `json:",omitempty"`
	From    int        `json:",omitempty"`
	Entries []Entry    `json:",omitempty"`
}

func (b Batch) Empty() bool { return b.Hard == nil && b.From == 0 && len(b.Entries) == 0 }

type Stable struct {
	Hard    HardState
	Entries []Entry // Index 1 is stored at offset 0.
}

func (s *Stable) Apply(batch Batch, members int) error {
~~~

Replace it with this version.

~~~go
// Batch is one atomic change. From is the 1-based start of a new suffix,
// or zero for a change that leaves the log alone.
type Batch struct {
	Snapshot *Snapshot  `json:",omitempty"`
	Hard     *HardState `json:",omitempty"`
	From     int        `json:",omitempty"`
	Entries  []Entry    `json:",omitempty"`
}

func (b Batch) Empty() bool {
	return b.Snapshot == nil && b.Hard == nil && b.From == 0 && len(b.Entries) == 0
}

type Stable struct {
	Snapshot Snapshot
	Hard     HardState
	Entries  []Entry // Index Snapshot.Index + 1 is stored at offset 0.
}

func (s *Stable) Apply(batch Batch, members int) error {
~~~

<!-- edit: internal/raft/stable.go -->
~~~go
			return fmt.Errorf("invalid persisted term or vote: %+v", hard)
		}
	}
	if (batch.From == 0) != (len(batch.Entries) == 0) || batch.From < 0 || batch.From-1 > len(s.Entries) {
		return fmt.Errorf("invalid persisted suffix at index %d", batch.From)
	}
	if batch.From != 0 {
		var previous uint64
		if batch.From > 1 {
			previous = s.Entries[batch.From-2].Term
		}
		for _, entry := range batch.Entries {
			if entry.Term == 0 || entry.Term < previous || entry.Term > hard.Term {
~~~

Replace it with this version.

~~~go
			return fmt.Errorf("invalid persisted term or vote: %+v", hard)
		}
	}
	snap := s.Snapshot
	entries := s.Entries
	if incoming := batch.Snapshot; incoming != nil {
		if !incoming.valid(hard.Term) || incoming.Index <= snap.Index {
			return fmt.Errorf("invalid persisted snapshot at index %d", incoming.Index)
		}
		offset := incoming.Index - snap.Index
		if offset <= len(entries) && entries[offset-1].Term == incoming.Term {
			entries = slices.Clone(entries[offset:])
		} else {
			entries = nil
		}
		snap = *incoming
	}
	from := batch.From - snap.Index - 1
	if (batch.From == 0) != (len(batch.Entries) == 0) ||
		(batch.From != 0 && (from < 0 || from > len(entries))) {
		return fmt.Errorf("invalid persisted suffix at index %d", batch.From)
	}
	if batch.From != 0 {
		previous := snap.Term
		if from > 0 {
			previous = entries[from-1].Term
		}
		for _, entry := range batch.Entries {
			if entry.Term == 0 || entry.Term < previous || entry.Term > hard.Term {
~~~

<!-- edit: internal/raft/stable.go -->
~~~go
			}
			previous = entry.Term
		}
		s.Entries = append(s.Entries[:batch.From-1], batch.Entries...)
	}
	s.Hard = hard
	return nil
}

func Restore(id, members int, seed int64, stable Stable) *Node {
	n := New(id, members, seed)
	n.term, n.vote = stable.Hard.Term, stable.Hard.Vote
	n.log = append(n.log, stable.Entries...)
	return n
}
~~~

Replace it with this version.

~~~go
			}
			previous = entry.Term
		}
		entries = append(entries[:from], batch.Entries...)
	}
	s.Hard, s.Snapshot, s.Entries = hard, snap, entries
	return nil
}

func Restore(id, members int, seed int64, stable Stable) *Node {
	n := New(id, members, seed)
	n.term, n.vote = stable.Hard.Term, stable.Hard.Vote
	n.snapshot, n.commit = stable.Snapshot, stable.Snapshot.Index
	n.log[0].Term = stable.Snapshot.Term
	n.log = append(n.log, stable.Entries...)
	return n
}
~~~

<!-- edit: internal/raft/stable.go -->
~~~go
}

func (n *Node) replaceSuffix(index int, entries []Entry) {
	n.log = append(n.log[:index], entries...)
	n.ready.Save.From = index
	n.ready.Save.Entries = slices.Clone(entries)
}
~~~

Replace it with this version.

~~~go
}

func (n *Node) replaceSuffix(index int, entries []Entry) {
	n.log = append(n.log[:index-n.snapshot.Index], entries...)
	n.ready.Save.From = index
	n.ready.Save.Entries = slices.Clone(entries)
}
~~~

Find these blocks in `internal/cluster/cluster.go` in order.

<!-- edit: internal/cluster/cluster.go -->
~~~go
	}
	for _, m := range ready.Messages {
		c.Net.Send(m.From, m.To, m)
	}
	for _, applied := range ready.Applied {
		if entry, exists := c.Committed[applied.Index]; exists && entry != applied.Entry {
~~~

Replace it with this version.

~~~go
	}
	for _, m := range ready.Messages {
		c.Net.Send(m.From, m.To, m)
	}
	if snap := ready.Save.Snapshot; snap != nil {
		c.Applied[id] = max(c.Applied[id], snap.Index)
	}
	for _, applied := range ready.Applied {
		if entry, exists := c.Committed[applied.Index]; exists && entry != applied.Entry {
~~~

<!-- edit: internal/cluster/cluster.go -->
~~~go

func (c *Cluster) Restart(id int) {
	c.Nodes[id] = raft.Restore(id, len(c.Nodes)-1, int64(c.Net.Now*31+id), c.disks[id])
}
~~~

Replace it with this version.

~~~go

func (c *Cluster) Restart(id int) {
	c.Nodes[id] = raft.Restore(id, len(c.Nodes)-1, int64(c.Net.Now*31+id), c.disks[id])
	c.Applied[id] = c.disks[id].Snapshot.Index
}
~~~

Create `internal/cluster/snapshot_test.go`.

<!-- file: internal/cluster/snapshot_test.go -->
~~~go
package cluster

import (
	"fmt"
	"testing"

	"switchyard/metad/internal/raft"
)

func TestLaggingPeerInstallsSnapshot(t *testing.T) {
	c := New(3, 13)
	c.Run(100)
	_, leader := c.LatestLeader()
	lagging := leader%3 + 1
	c.Isolate(lagging, true)
	for i := range 8 {
		if !c.Propose(leader, raft.Command{Op: "put", Key: "job", Value: fmt.Sprint(i)}) {
			t.Fatal("lost leader while holding a majority")
		}
		c.Run(2)
	}
	index := c.Applied[leader]
	if index <= c.Applied[lagging] {
		t.Fatal("fixture needs a lagging follower")
	}
	if err := c.Nodes[leader].Compact(index, "job=7"); err != nil {
		t.Fatal(err)
	}
	c.flush(leader)
	// A stopped peer cannot increment its term while the link is blocked.
	c.Crash(lagging)
	c.Restart(lagging)
	c.Isolate(lagging, false)
	c.Run(100)
	got := c.Nodes[lagging].Snapshot()
	if got.Index != index || got.Data != "job=7" || c.Applied[lagging] < index {
		t.Fatalf("lagging peer did not install snapshot: %+v", got)
	}
	t.Logf("lagging peer %d installed snapshot at index %d", lagging, index)
}
~~~

</details>

## Check it

~~~bash
go test -race -count=1 -v ./internal/raft ./internal/cluster -run TestLaggingPeerInstallsSnapshot
~~~

<!-- run: go test -race -count=1 -v ./internal/raft ./internal/cluster -run TestLaggingPeerInstallsSnapshot -->

The seeded run reports `lagging peer 2 installed snapshot at index 9`. It uses the simulated disk. The next lesson connects the same transitions to the Rust writer.

## If it goes wrong

If the lagging peer retries forever, print its next index and the leader’s snapshot base. For a divergent suffix, inspect both the last included index and the last included term.
