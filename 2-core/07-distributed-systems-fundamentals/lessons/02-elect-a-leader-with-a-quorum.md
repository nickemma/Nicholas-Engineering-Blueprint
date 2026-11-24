# 02 Elect a leader with a quorum

> Core 07 · About 7 hours · Builds on the preceding lesson

## The problem

Every peer starts with an empty local view. To make a leadership claim usable, require a majority of peers to vote for one candidate in the same term.

## The mental model

~~~text
follower --timeout--> candidate --majority of votes--> leader
    ^                     |                               |
    +---------- higher term or valid heartbeat ----------+
~~~

A term is a number that increases when a peer campaigns. A higher number in a message moves its receiver into that term, clears the receiver's old vote, and makes it a follower. A stale request can receive a refusal carrying the newer term.

## The pattern

The majority threshold is `members/2 + 1`. Any two strict majorities intersect. For two candidates to win the same term, at least one peer would have to vote twice. Count each sender's positive reply once. A follower resets its timer when it grants a vote or receives a heartbeat from its leader. Seed separate timers so ties can break on a retry. The election tests keep peers alive. The disk lesson makes a vote survive reboot.

## Build it

### Step 1. Start an election

Fill in `campaign: bump term → /* TODO */ → send RequestVote`. Record the role, vote, and deadline so the driver can advance them using ticks.

<details>
<summary>Hint 1</summary>

A candidate counts as a voter.

</details>

<details>
<summary>Hint 2</summary>

Vote for yourself in the new term. Ask each other peer and count replies by ID.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/raft/node.go -->
~~~go
// Package raft holds a node's state transitions. Its driver supplies time and I/O.
package raft

import "math/rand"

type Role string

const (
	Follower  Role = "follower"
	Candidate Role = "candidate"
	Leader    Role = "leader"
)

type Kind string

const (
	RequestVote Kind = "vote"
	VoteReply   Kind = "vote_reply"
	Append      Kind = "append"
	AppendReply Kind = "append_reply"
)

type Message struct {
	Kind     Kind
	From, To int
	Term     uint64
	OK       bool
}

type Ready struct {
	Messages []Message
}

type Node struct {
	id       int
	members  int // IDs are contiguous, starting at 1.
	role     Role
	term     uint64
	vote     int
	leader   int
	votes    map[int]bool
	elapsed  int
	deadline int
	rng      *rand.Rand
	ready    Ready
}

func New(id, members int, seed int64) *Node {
	n := &Node{id: id, members: members, role: Follower, rng: rand.New(rand.NewSource(seed))}
	n.resetTimer()
	return n
}

func (n *Node) Role() Role   { return n.role }
func (n *Node) Term() uint64 { return n.term }
func (n *Node) Leader() int  { return n.leader }

func (n *Node) Take() Ready {
	ready := n.ready
	n.ready = Ready{}
	return ready
}

func (n *Node) send(to int, message Message) {
	message.From, message.To, message.Term = n.id, to, n.term
	n.ready.Messages = append(n.ready.Messages, message)
}

func (n *Node) resetTimer() {
	n.elapsed = 0
	n.deadline = 12 + n.rng.Intn(12)
}

func (n *Node) Tick() {
	n.elapsed++
	if n.role == Leader {
		if n.elapsed >= 3 {
			n.elapsed = 0
			n.broadcast()
		}
		return
	}
	if n.elapsed >= n.deadline {
		n.campaign()
	}
}

func (n *Node) campaign() {
	n.term++
	n.role, n.vote, n.leader = Candidate, n.id, 0
	n.votes = map[int]bool{n.id: true}
	n.resetTimer()
	if n.win() {
		return
	}
	for peer := 1; peer <= n.members; peer++ {
		if peer != n.id {
			n.send(peer, Message{Kind: RequestVote})
		}
	}
}

func (n *Node) win() bool {
	if len(n.votes) <= n.members/2 {
		return false
	}
	n.role, n.leader, n.elapsed = Leader, n.id, 0
	n.broadcast()
	return true
}

func (n *Node) Step(m Message) {
	if m.To != n.id || m.From < 1 || m.From > n.members || m.From == n.id || m.Term == 0 {
		return
	}
	if m.Term > n.term {
		n.term, n.vote, n.role, n.leader = m.Term, 0, Follower, 0
	}
	if m.Term < n.term {
		switch m.Kind {
		case RequestVote:
			n.send(m.From, Message{Kind: VoteReply})
		case Append:
			n.rejectAppend(m)
		}
		return
	}
	switch m.Kind {
	case RequestVote:
		grant := (n.vote == 0 || n.vote == m.From)
		if grant {
			n.vote = m.From
			n.resetTimer()
		}
		n.send(m.From, Message{Kind: VoteReply, OK: grant})
	case VoteReply:
		if n.role == Candidate && m.OK {
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
		}
	}
}
~~~

</details>

### Step 2. Send heartbeats

Use Append with an empty body to establish who sent a heartbeat. Put it in a separate file for the replication lesson to extend.

<details>
<summary>Hint 1</summary>

The leader runs a heartbeat timer. Followers run election timers.

</details>

<details>
<summary>Hint 2</summary>

Broadcast every three ticks. The follower's Step resets its own countdown.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/raft/replication.go -->
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

</details>

### Step 3. Drive the core

Wire ticks and deliveries to the same methods. Complete `leaderByTerm[term] = /* TODO */` and decide what to do when the map holds another ID.

<details>
<summary>Hint 1</summary>

The isolated old leader may still claim leadership in an older term.

</details>

<details>
<summary>Hint 2</summary>

Remember all winners. Compare claims within each term.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/cluster/cluster.go -->
~~~go
// Package cluster drives the Raft core without sockets or wall-clock time.
package cluster

import (
	"fmt"

	"switchyard/metad/internal/raft"
	"switchyard/metad/internal/simnet"
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
	}
	return c
}

func (c *Cluster) flush(id int) {
	node := c.Nodes[id]
	if node.Role() == raft.Leader {
		term := node.Term()
		if other := c.Leaders[term]; other != 0 && other != id {
			panic(fmt.Sprintf("term %d elected both %d and %d", term, other, id))
		}
		c.Leaders[term] = id
	}
	for _, m := range node.Take().Messages {
		c.Net.Send(m.From, m.To, m)
	}
}

func (c *Cluster) Run(ticks int) {
	for range ticks {
		for _, d := range c.Net.Advance() {
			if node := c.Nodes[d.To]; node != nil {
				node.Step(d.Value)
				c.flush(d.To)
			}
		}
		for id, node := range c.Nodes {
			if node != nil {
				node.Tick()
				c.flush(id)
			}
		}
	}
}

func (c *Cluster) Isolate(id int, blocked bool) {
	for peer := 1; peer < len(c.Nodes); peer++ {
		if peer != id {
			c.Net.Block(id, peer, blocked)
			c.Net.Block(peer, id, blocked)
		}
	}
}

func (c *Cluster) LatestLeader() (uint64, int) {
	var latest uint64
	for term := range c.Leaders {
		latest = max(term, latest)
	}
	return latest, c.Leaders[latest]
}
~~~

</details>

### Step 4. Force a split vote

Isolate peers while their timers expire. Heal the network, run a seeded retry, and check for progress. Add a run with variable loss and delay on five peers.

<details>
<summary>Hint 1</summary>

A candidate who hears only itself has one vote.

</details>

<details>
<summary>Hint 2</summary>

Check for no winner during isolation and a higher-term winner after reconnecting.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/cluster/election_test.go -->
~~~go
package cluster

import (
	"testing"

	"switchyard/metad/internal/raft"
)

func TestPartitionElectsHigherTerm(t *testing.T) {
	c := New(3, 7)
	c.Run(60)
	before, old := c.LatestLeader()
	if old == 0 {
		t.Fatal("no initial leader")
	}
	c.Isolate(old, true)
	c.Run(100)
	after, elected := c.LatestLeader()
	if after <= before || elected == old || c.Nodes[old].Role() != raft.Leader {
		t.Fatalf("before=%d/%d after=%d/%d", before, old, after, elected)
	}
	c.Isolate(old, false)
	c.Run(60)
	if c.Nodes[old].Role() != raft.Follower {
		t.Fatal("old leader failed to step down")
	}
	t.Logf("term %d elected peer %d; partition elected peer %d in term %d", before, old, elected, after)
}

func TestSplitVoteRetries(t *testing.T) {
	c := New(3, 7)
	c.Isolate(1, true)
	c.Isolate(2, true)
	c.Run(24) // Everybody runs an election, but nobody can gather two votes.
	for id := 1; id <= 3; id++ {
		if c.Nodes[id].Role() != raft.Candidate {
			t.Fatalf("peer %d was %s", id, c.Nodes[id].Role())
		}
	}
	if term, _ := c.LatestLeader(); term != 0 {
		t.Fatalf("elected a leader without a quorum")
	}
	c.Isolate(1, false)
	c.Isolate(2, false)
	c.Run(100)
	term, winner := c.LatestLeader()
	if term < 2 || winner == 0 {
		t.Fatalf("failed to retry: term=%d winner=%d", term, winner)
	}
	t.Logf("three self-votes in term 1; peer %d won term %d after healing", winner, term)
}

func TestElectionStorm(t *testing.T) {
	for seed := int64(1); seed <= 100; seed++ {
		c := New(5, seed)
		c.Net.Loss, c.Net.Delay = 20, 5
		c.Run(200)
		c.Isolate(1, true)
		c.Run(200)
		c.Isolate(1, false)
		c.Net.Loss, c.Net.Delay = 0, 1
		c.Run(100)
		if _, leader := c.LatestLeader(); leader == 0 {
			t.Fatalf("seed %d did not elect a leader", seed)
		}
	}
	t.Log("checked election safety across 100 seeds")
}
~~~

</details>

## Check it

~~~bash
test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 -v ./...
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 -v ./... -->

~~~text
election_test.go:27: term 1 elected peer 2; partition elected peer 3 in term 2
election_test.go:50: three self-votes in term 1; peer 2 won term 2 after healing
election_test.go:67: checked election safety across 100 seeds
~~~

Seed 7 gives both the split vote and a higher-term winner. Later lessons change the messages and can change the exact election timing.

Full captures are in [02-election.txt](../evidence/lessons/02-election.txt).

## If it goes wrong

| Symptom | What to inspect |
|---|---|
| Election never ends after healing | Compare per-node seeds, timer resets, and reply terms. |
| Two nodes claim leadership | Check the terms of the two claims and whether each can commit a request. |

## Explain it

1. Why is granting the same candidate's repeated request okay?
2. What changes when there are four voters?
