# 03 Replicate and repair a log

> Core 07 · About 7 hours · Builds on the preceding lesson

## The problem

A leader prepares changes while cut off from the majority. When it returns, another leader has used those indexes for different changes. Each peer needs the exact prefix of the leader's log before appending the new suffix.

## The mental model

~~~text
index             1           2
old peer       shared(t1)  isolated(t1)
new leader     shared(t1)  majority(t2)
                              ^
                        replace from here
~~~

Entries begin at index 1. A sentinel occupies 0 with term 0. An Append request gives the previous index and term, then carries some of the following entries. A follower finds the first conflict and replaces the suffix there. An empty or shorter Append can validate a prefix and leave a follower's extra tail alone.

## The pattern

Track `next` and `match` per follower. Probe at `next-1`. A refusal backs the probe up if it still corresponds to the probe being tracked. Success moves the match forward. Discard delayed replies that would rewind known progress. A candidate carries its last index and term so voters can check freshness. Compare last term first and use length as the tie breaker.

## Build it

### Step 1. Carry the prefix coordinates

Extend the message with the previous index and term and the entries after that point. Sketch an Append to an empty follower and one to a follower believed to match through index 5.

<details>
<summary>Hint 1</summary>

The sentinel is a real array slot.

</details>

<details>
<summary>Hint 2</summary>

Use previous index 0 for an empty log. Use 5 to start the next batch at 6.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- edit: internal/raft/node.go -->
~~~go
)

type Message struct {
	Kind     Kind
	From, To int
	Term     uint64
	OK       bool
}

type Ready struct {
~~~

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
~~~

<!-- edit: internal/raft/node.go -->
~~~go
	deadline int
	rng      *rand.Rand
	ready    Ready
}

func New(id, members int, seed int64) *Node {
	n := &Node{id: id, members: members, role: Follower, rng: rand.New(rand.NewSource(seed))}
	n.resetTimer()
	return n
}
~~~

~~~go
	deadline int
	rng      *rand.Rand
	ready    Ready
	log      []Entry
	progress []progress
}

func New(id, members int, seed int64) *Node {
	n := &Node{id: id, members: members, role: Follower, rng: rand.New(rand.NewSource(seed))}
	n.log = []Entry{{}} // Index zero is the sentinel.
	n.resetTimer()
	return n
}
~~~

<!-- edit: internal/raft/node.go -->
~~~go
	}
	for peer := 1; peer <= n.members; peer++ {
		if peer != n.id {
			n.send(peer, Message{Kind: RequestVote})
		}
	}
}
~~~

~~~go
	}
	for peer := 1; peer <= n.members; peer++ {
		if peer != n.id {
			n.send(peer, Message{Kind: RequestVote, Prev: len(n.log) - 1, PrevTerm: n.log[len(n.log)-1].Term})
		}
	}
}
~~~

<!-- edit: internal/raft/node.go -->
~~~go
		return false
	}
	n.role, n.leader, n.elapsed = Leader, n.id, 0
	n.broadcast()
	return true
}
~~~

~~~go
		return false
	}
	n.role, n.leader, n.elapsed = Leader, n.id, 0
	n.startReplication()
	n.broadcast()
	return true
}
~~~

<!-- edit: internal/raft/node.go -->
~~~go
	}
	switch m.Kind {
	case RequestVote:
		grant := (n.vote == 0 || n.vote == m.From)
		if grant {
			n.vote = m.From
			n.resetTimer()
~~~

~~~go
	}
	switch m.Kind {
	case RequestVote:
		grant := (n.vote == 0 || n.vote == m.From) && n.upToDate(m)
		if grant {
			n.vote = m.From
			n.resetTimer()
~~~

</details>

### Step 2. Replace the conflicting suffix

Fill in `if index is missing || /* TODO */` in the Append handler. Reply with the highest index this request actually covers.

<details>
<summary>Hint 1</summary>

A follower can have a longer unrelated suffix.

</details>

<details>
<summary>Hint 2</summary>

Compare terms at the same index. Acknowledge the previous index plus the entries in the request.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- edit: internal/raft/replication.go -->
~~~go
package raft

func (n *Node) broadcast() {
	for peer := 1; peer <= n.members; peer++ {
		if peer != n.id {
			n.send(peer, Message{Kind: Append})
		}
	}
}

func (n *Node) acceptAppend(m Message) {
	n.send(m.From, Message{Kind: AppendReply, OK: true})
}

func (n *Node) rejectAppend(m Message) {
	n.send(m.From, Message{Kind: AppendReply})
}

func (n *Node) appendReply(Message) {}
~~~

~~~go
package raft

import "slices"

type Command struct {
	Op, Key, Value string
}

type Entry struct {
	Term    uint64
	Command Command
}

type progress struct {
	next, match int
}

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

func (n *Node) Propose(command Command) (index int, term uint64, ok bool) {
	if n.role != Leader {
		return 0, 0, false
	}
	n.log = append(n.log, Entry{Term: n.term, Command: command})
	n.broadcast()
	return len(n.log) - 1, n.term, true
}

func (n *Node) broadcast() {
	for peer := 1; peer <= n.members; peer++ {
		if peer != n.id {
			n.replicate(peer)
		}
	}
}

func (n *Node) replicate(peer int) {
	next := n.progress[peer].next
	end := min(next+16, len(n.log))
	n.send(peer, Message{
		Kind: Append, Prev: next - 1, PrevTerm: n.log[next-1].Term,
		Entries: slices.Clone(n.log[next:end]),
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
			n.log = append(n.log[:index], m.Entries[i:]...)
			break
		}
	}
	last := m.Prev + len(m.Entries)
	n.send(m.From, Message{Kind: AppendReply, OK: true, Prev: m.Prev, Match: last})
}

func (n *Node) rejectAppend(m Message) {
	n.send(m.From, Message{Kind: AppendReply, Prev: m.Prev})
}

func (n *Node) appendReply(m Message) {
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
	if p.next < len(n.log) {
		n.replicate(m.From)
	}
}
~~~

</details>

### Step 3. Submit a proposal

Let the simulator call a specific node and flush the effects. Return whether it locally admits the command.

<details>
<summary>Hint 1</summary>

Use the same flush path as ticks and deliveries.

</details>

<details>
<summary>Hint 2</summary>

Use the bool returned by Propose. The next lesson introduces a separate application event.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- edit: internal/cluster/cluster.go -->
~~~go
	}
	return latest, c.Leaders[latest]
}
~~~

~~~go
	}
	return latest, c.Leaders[latest]
}

func (c *Cluster) Propose(id int, command raft.Command) bool {
	_, _, accepted := c.Nodes[id].Propose(command)
	c.flush(id)
	return accepted
}
~~~

</details>

### Step 4. Heal a divergent follower

Arrange a common prefix. Let both sides of a partition propose a write to one key, then heal and compare every log.

<details>
<summary>Hint 1</summary>

Inspect the suffix before reconnecting the old leader.

</details>

<details>
<summary>Hint 2</summary>

Keep the common entry and require the new leader's entry at the disputed position.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/cluster/replication_test.go -->
~~~go
package cluster

import (
	"slices"
	"testing"

	"switchyard/metad/internal/raft"
)

func TestConflictingSuffix(t *testing.T) {
	c := New(3, 7)
	c.Run(60)
	_, old := c.LatestLeader()
	write := func(id int, value string) {
		if !c.Propose(id, raft.Command{Op: "put", Key: "route", Value: value}) {
			t.Fatalf("peer %d refused %s", id, value)
		}
		c.Run(40)
	}
	write(old, "shared")
	c.Isolate(old, true)
	write(old, "isolated")
	term, leader := c.LatestLeader()
	if leader == old {
		t.Fatal("majority did not elect a leader")
	}
	write(leader, "majority")
	diverged := c.Nodes[old].Entries()
	if diverged[len(diverged)-1].Command.Value != "isolated" {
		t.Fatal("expected divergent suffix")
	}
	c.Isolate(old, false)
	c.Run(80)
	log := c.Nodes[leader].Entries()
	for _, peer := range c.Nodes[1:] {
		if !slices.Equal(peer.Entries(), log) {
			t.Fatalf("logs did not converge: %+v", peer.Entries())
		}
	}
	var values []string
	for _, entry := range log {
		if entry.Command.Op == "put" {
			values = append(values, entry.Command.Value)
		}
	}
	if !slices.Equal(values, []string{"shared", "majority"}) {
		t.Fatalf("unexpected final log: %+v", log)
	}
	t.Logf("peer %d replaced peer %d's uncommitted suffix in term %d; shared prefix retained", leader, old, term)
}
~~~

</details>

## Check it

~~~bash
test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 -v ./...
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 -v ./... -->

~~~text
replication_test.go:49: peer 1 replaced peer 2's uncommitted suffix in term 2; shared prefix retained
~~~

The schedule exercises suffix repair. The transition that allows a client to use a replicated value arrives in the next lesson.

Full captures are in [03-repair.txt](../evidence/lessons/03-repair.txt).

## If it goes wrong

| Symptom | What to inspect |
|---|---|
| A conflict loops at the same index | Check the previous term, the rejected probe index, and the lower bound match + 1. |
| An empty Append removes data | Only truncate when an incoming entry conflicts. |

## Explain it

1. Why can a longer log be less up to date?
2. What keeps an out-of-order refusal from undoing a successful probe?
