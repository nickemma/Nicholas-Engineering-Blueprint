# 04 Decide what is committed

> Core 07 · About 8 hours · Builds on the preceding lesson

## The problem

A leader has the same earlier-term entry on three of five peers. A later election can still choose a peer with a newer last log term that replaces it. Applying that earlier command now could expose a value another peer will never apply.

## The mental model

Sort each peer's highest matched index, counting the leader's last index as its own match. A strict majority covers the index at zero-based position `(members-1)/2`. With five matches `[1, 1, 2, 2, 3]` that index is 2. Read its term before advancing commit.

## The pattern

A leader counts matched copies for an entry from its own term. When the majority covers such an entry, commit the prefix through it, including earlier terms. On election, append an empty current-term entry so the boundary can advance even with no clients. A follower applies only the part of the leader's committed prefix covered by its current Append request. Apply in order before reporting client success.

The directed Figure 8 test starts at its decision point with a term-2 entry at index 2, a term-4 leader, and two follower replies matching index 2. It tries again after those peers acknowledge the current-term entry at index 3. [Raft paper, §5.4 and Figure 8](https://raft.github.io/raft.pdf)

## Build it

### Step 1. Add an election no-op

Insert the empty entry after initializing progress. Give the driver a list of newly committed entries.

<details>
<summary>Hint 1</summary>

The leader needs an entry in its new term.

</details>

<details>
<summary>Hint 2</summary>

Create one locally and include it in replication.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- edit: internal/raft/node.go -->
~~~go
)

type Message struct {
	Kind        Kind
	From, To    int
	Term        uint64
	OK          bool
	Prev, Match int
	PrevTerm    uint64
	Entries     []Entry
}

type Ready struct {
	Messages []Message
}

type Node struct {
~~~

~~~go
)

type Message struct {
	Kind                Kind
	From, To            int
	Term                uint64
	OK                  bool
	Prev, Match, Commit int
	PrevTerm            uint64
	Entries             []Entry
}

type Ready struct {
	Messages []Message
	Applied  []Applied
}

type Node struct {
~~~

<!-- edit: internal/raft/node.go -->
~~~go
	ready    Ready
	log      []Entry
	progress []progress
}

func New(id, members int, seed int64) *Node {
~~~

~~~go
	ready    Ready
	log      []Entry
	progress []progress
	commit   int
}

func New(id, members int, seed int64) *Node {
~~~

<!-- edit: internal/raft/node.go -->
~~~go
	}
	n.role, n.leader, n.elapsed = Leader, n.id, 0
	n.startReplication()
	n.broadcast()
	return true
}
~~~

~~~go
	}
	n.role, n.leader, n.elapsed = Leader, n.id, 0
	n.startReplication()
	n.appendLocal(Command{}) // Commit prior entries with a new-term no-op.
	n.tryCommit()
	n.broadcast()
	return true
}
~~~

</details>

### Step 2. Propagate the commit index

Attach the commit index to each Append. Fill in `min(leaderCommit, /* TODO */)` for the follower.

<details>
<summary>Hint 1</summary>

Which part of the log did this request check or copy?

</details>

<details>
<summary>Hint 2</summary>

Use the last index covered by the request, including the previous index for an empty Append.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- edit: internal/raft/replication.go -->
~~~go
	if n.role != Leader {
		return 0, 0, false
	}
	n.log = append(n.log, Entry{Term: n.term, Command: command})
	n.broadcast()
	return len(n.log) - 1, n.term, true
}
~~~

~~~go
	if n.role != Leader {
		return 0, 0, false
	}
	n.appendLocal(command)
	n.tryCommit()
	n.broadcast()
	return len(n.log) - 1, n.term, true
}
~~~

<!-- edit: internal/raft/replication.go -->
~~~go
	end := min(next+16, len(n.log))
	n.send(peer, Message{
		Kind: Append, Prev: next - 1, PrevTerm: n.log[next-1].Term,
		Entries: slices.Clone(n.log[next:end]),
	})
}
~~~

~~~go
	end := min(next+16, len(n.log))
	n.send(peer, Message{
		Kind: Append, Prev: next - 1, PrevTerm: n.log[next-1].Term,
		Entries: slices.Clone(n.log[next:end]), Commit: n.commit,
	})
}
~~~

<!-- edit: internal/raft/replication.go -->
~~~go
		}
	}
	last := m.Prev + len(m.Entries)
	n.send(m.From, Message{Kind: AppendReply, OK: true, Prev: m.Prev, Match: last})
}
~~~

~~~go
		}
	}
	last := m.Prev + len(m.Entries)
	n.commitThrough(min(m.Commit, last))
	n.send(m.From, Message{Kind: AppendReply, OK: true, Prev: m.Prev, Match: last})
}
~~~

<!-- edit: internal/raft/replication.go -->
~~~go
		return
	}
	p.match, p.next = m.Match, m.Match+1
	if p.next < len(n.log) {
		n.replicate(m.From)
	}
~~~

~~~go
		return
	}
	p.match, p.next = m.Match, m.Match+1
	if n.tryCommit() {
		n.broadcast()
		return
	}
	if p.next < len(n.log) {
		n.replicate(m.From)
	}
~~~

</details>

### Step 3. Find the current-term majority

Fill in the two early-return conditions in `tryCommit`. Emit the newly committed entries in order.

<details>
<summary>Hint 1</summary>

Heartbeats can repeat the same commit boundary.

</details>

<details>
<summary>Hint 2</summary>

Skip positions already committed and candidates whose entry term differs from the leader's term.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/raft/commit.go -->
~~~go
package raft

import "slices"

type Applied struct {
	Index int
	Entry
}

func (n *Node) appendLocal(command Command) {
	n.log = append(n.log, Entry{Term: n.term, Command: command})
}

// tryCommit runs only on the leader. The median-like order statistic
// is the largest index held by a strict majority, including the leader.
func (n *Node) tryCommit() bool {
	matches := make([]int, n.members)
	for peer := 1; peer <= n.members; peer++ {
		matches[peer-1] = n.progress[peer].match
	}
	matches[n.id-1] = len(n.log) - 1
	slices.Sort(matches)
	index := matches[(len(matches)-1)/2]
	if index <= n.commit || n.log[index].Term != n.term {
		return false
	}
	n.commitThrough(index)
	return true
}

func (n *Node) commitThrough(index int) {
	for n.commit < index {
		n.commit++
		n.ready.Applied = append(n.ready.Applied, Applied{Index: n.commit, Entry: n.log[n.commit]})
	}
}
~~~

</details>

### Step 4. Check application history

Key the history by index. Compare peers that apply the same position. Partition a leader and verify that local admission leaves its applied index fixed.

<details>
<summary>Hint 1</summary>

Inspect effects from Take as well as the local proposal result.

</details>

<details>
<summary>Hint 2</summary>

Compare entries at equal indexes throughout the history.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- edit: internal/cluster/cluster.go -->
~~~go
)

type Cluster struct {
	Net     *simnet.Network[raft.Message]
	Nodes   []*raft.Node // slot zero is unused
	Leaders map[uint64]int
}

func New(count int, seed int64) *Cluster {
	c := &Cluster{
		Net:     simnet.New[raft.Message](seed),
		Nodes:   make([]*raft.Node, count+1),
		Leaders: make(map[uint64]int),
	}
	for id := 1; id <= count; id++ {
		c.Nodes[id] = raft.New(id, count, seed*31+int64(id))
~~~

~~~go
)

type Cluster struct {
	Net       *simnet.Network[raft.Message]
	Nodes     []*raft.Node // slot zero is unused
	Leaders   map[uint64]int
	Committed map[int]raft.Entry
	Applied   []int
}

func New(count int, seed int64) *Cluster {
	c := &Cluster{
		Net:       simnet.New[raft.Message](seed),
		Nodes:     make([]*raft.Node, count+1),
		Leaders:   make(map[uint64]int),
		Committed: make(map[int]raft.Entry),
		Applied:   make([]int, count+1),
	}
	for id := 1; id <= count; id++ {
		c.Nodes[id] = raft.New(id, count, seed*31+int64(id))
~~~

<!-- edit: internal/cluster/cluster.go -->
~~~go
		}
		c.Leaders[term] = id
	}
	for _, m := range node.Take().Messages {
		c.Net.Send(m.From, m.To, m)
	}
}
~~~

~~~go
		}
		c.Leaders[term] = id
	}
	ready := node.Take()
	for _, applied := range ready.Applied {
		if entry, exists := c.Committed[applied.Index]; exists && entry != applied.Entry {
			panic(fmt.Sprintf("different commands applied at index %d", applied.Index))
		}
		c.Committed[applied.Index] = applied.Entry
		c.Applied[id] = applied.Index
	}
	for _, m := range ready.Messages {
		c.Net.Send(m.From, m.To, m)
	}
}
~~~

<!-- edit: internal/cluster/replication_test.go -->
~~~go
	}
	t.Logf("peer %d replaced peer %d's uncommitted suffix in term %d; shared prefix retained", leader, old, term)
}
~~~

~~~go
	}
	t.Logf("peer %d replaced peer %d's uncommitted suffix in term %d; shared prefix retained", leader, old, term)
}

func TestMinorityCannotCommit(t *testing.T) {
	c := New(3, 7)
	c.Run(60)
	_, old := c.LatestLeader()
	before := c.Applied[old]
	c.Isolate(old, true)
	if !c.Propose(old, raft.Command{Op: "put", Key: "route", Value: "isolated"}) {
		t.Fatal("expected the old leader to accept a local proposal")
	}
	c.Run(100)
	if c.Applied[old] != before {
		t.Fatal("minority leader applied an entry")
	}
	for _, entry := range c.Committed {
		if entry.Command.Value == "isolated" {
			t.Fatal("isolated value was committed")
		}
	}
	t.Logf("isolated peer %d kept its applied index at %d", old, before)
}
~~~

</details>

### Step 5. Make the rule fail on purpose

Write the Figure 8 test. In a disposable copy, remove the term comparison in `tryCommit` and run `go test -run '^TestFigureEight$' -v ./internal/raft`.

<details>
<summary>Hint 1</summary>

The leader's own copy counts as the third match.

</details>

<details>
<summary>Hint 2</summary>

Expect no application after the first two replies, then application of indexes 2 and 3 after the next pair.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/raft/commit_test.go -->
~~~go
package raft

import "testing"

func TestFigureEight(t *testing.T) {
	// The Figure 8(c) leader holds the old term-2 entry on three out
	// of five peers. Three matches at index 2 are insufficient.
	n := New(1, 5, 7)
	n.term, n.role, n.commit = 4, Leader, 1
	n.log = []Entry{
		{}, {Term: 1}, {Term: 2, Command: Command{Op: "put", Key: "route", Value: "old"}},
	}
	n.startReplication()
	n.appendLocal(Command{}) // Index 3 is in term 4.
	reply := func(from, match int) {
		n.Step(Message{Kind: AppendReply, From: from, To: 1, Term: 4, OK: true, Match: match})
	}
	reply(2, 2)
	reply(3, 2)
	if ready := n.Take(); len(ready.Applied) != 0 {
		t.Fatalf("old term-2 entry applied before a current-term majority: %+v", ready.Applied)
	}
	t.Log("three copies of index 2 from term 2 leave commit at index 1")
	reply(2, 3)
	reply(3, 3)
	ready := n.Take()
	if len(ready.Applied) != 2 || ready.Applied[0].Index != 2 || ready.Applied[1].Index != 3 {
		t.Fatalf("missing ordered prefix: %+v", ready.Applied)
	}
	t.Log("three copies of index 3 from term 4 commit indexes 2 and 3 in order")
}

func TestVoteChecksLastTermBeforeLength(t *testing.T) {
	n := New(1, 3, 7)
	n.term = 4
	n.log = []Entry{{}, {Term: 3}}
	n.Step(Message{Kind: RequestVote, From: 2, To: 1, Term: 4, Prev: 8, PrevTerm: 2})
	if ready := n.Take(); len(ready.Messages) != 1 || ready.Messages[0].OK {
		t.Fatalf("granted a vote to a longer but older log: %+v", ready)
	}
}

func TestStaleRejectionKeepsFollowerProgress(t *testing.T) {
	n := New(1, 3, 7)
	n.term, n.role = 2, Leader
	n.log = []Entry{{}, {Term: 1}, {Term: 2}}
	n.startReplication()
	n.Step(Message{Kind: AppendReply, From: 2, To: 1, Term: 2, OK: true, Match: 2})
	n.Step(Message{Kind: AppendReply, From: 2, To: 1, Term: 2, Prev: 2})
	if p := n.progress[2]; p.match != 2 || p.next != 3 {
		t.Fatalf("stale rejection regressed progress: %+v", p)
	}
}
~~~

</details>

## Check it

~~~bash
test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 -v ./...
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 -v ./... -->

~~~text
commit_test.go:23: three copies of index 2 from term 2 leave commit at index 1
commit_test.go:30: three copies of index 3 from term 4 commit indexes 2 and 3 in order
replication_test.go:70: isolated peer 2 kept its applied index at 1
~~~

The deliberately broken run stops at “old term-2 entry applied before a current-term majority”. Restore the comparison before continuing.

Full captures are in [04-commit.txt](../evidence/lessons/04-commit.txt), [04-broken.txt](../evidence/lessons/04-broken.txt).

## If it goes wrong

| Symptom | What to inspect |
|---|---|
| An older-term entry applies early | Check the term of the majority's highest index. |
| A follower applies a divergent entry | Cap the received commit index at the range verified by the current Append. |

## Explain it

1. Why can a no-op make earlier entries usable?
2. What can the isolated leader do while it waits?
