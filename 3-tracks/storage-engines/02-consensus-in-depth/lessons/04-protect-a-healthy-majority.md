# 04 Keep an election from disrupting a healthy majority

> Consensus in depth · Week 2 · Builds on lesson 03

## The problem

Drop the link between the leader and one follower. The leader can still reach a majority through the other follower, yet the disconnected follower can send it a higher term indirectly by requesting a vote from that other peer.

## The mental model

With A leading, B can hear both A and C. C cannot hear A. C’s timeout can trigger a probe, and B can tell it that B is still hearing a leader.

## The pattern

PreVote asks about the next term before increasing the durable current term. A round ID prevents delayed probe replies from counting in later rounds. CheckQuorum uses current-term responses to count contacts during each window and makes a minority leader step down.

## Build it

### Step 1 — Use a trial election

Give the pre-candidate its own state and keep trial replies out of the normal term update.

<details>
<summary>Hint 1</summary>

A grant needs a fresh-enough log and a peer that has not recently heard a leader.

</details>

<details>
<summary>Hint 2</summary>

Only a majority in the active round starts the durable campaign.

</details>

<details>
<summary>Implementation</summary>

Create `internal/raft/election.go`.

<!-- file: internal/raft/election.go -->
~~~go
package raft

const quorumTicks = 12

func (n *Node) EnableElectionSafeguards() { n.safeguards = true }

func (n *Node) probe() {
	n.role, n.leader = PreCandidate, 0
	n.round = n.rng.Uint64()
	n.votes = map[int]bool{n.id: true}
	n.resetTimer()
	if n.members == 1 {
		n.campaign()
		return
	}
	last := n.lastIndex()
	for peer := 1; peer <= n.members; peer++ {
		if peer != n.id {
			n.send(peer, Message{
				Kind: PreVote, ProbeTerm: n.term + 1, Round: n.round,
				Prev: last, PrevTerm: n.at(last).Term,
			})
		}
	}
}

func (n *Node) stepProbe(m Message) {
	if m.Kind == PreVote {
		heardLeader := n.role == Leader || (n.leader != 0 && n.elapsed < n.deadline)
		grant := !heardLeader && m.ProbeTerm > n.term && n.upToDate(m)
		n.send(m.From, Message{Kind: PreVoteReply, ProbeTerm: m.ProbeTerm, Round: m.Round, OK: grant})
		return
	}
	if n.role == PreCandidate && m.OK && m.ProbeTerm == n.term+1 && m.Round == n.round {
		n.votes[m.From] = true
		if len(n.votes) > n.members/2 {
			n.campaign()
		}
	}
}

func (n *Node) checkQuorum() bool {
	n.quorumElapsed++
	if n.quorumElapsed < quorumTicks {
		return true
	}
	quorum := 1+len(n.contacts) > n.members/2 // The leader counts itself.
	n.quorumElapsed = 0
	clear(n.contacts)
	if !quorum {
		n.role, n.leader = Follower, 0
		n.resetTimer()
	}
	return quorum
}
~~~

Find these blocks in `internal/raft/node.go` in order.

<!-- edit: internal/raft/node.go -->
~~~go
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
	Install     Kind = "install_snapshot"
)

type Message struct {
~~~

Replace it with this version.

~~~go
type Role string

const (
	Follower     Role = "follower"
	Candidate    Role = "candidate"
	PreCandidate Role = "pre_candidate"
	Leader       Role = "leader"
)

type Kind string

const (
	RequestVote  Kind = "vote"
	VoteReply    Kind = "vote_reply"
	Append       Kind = "append"
	AppendReply  Kind = "append_reply"
	Install      Kind = "install_snapshot"
	PreVote      Kind = "pre_vote"
	PreVoteReply Kind = "pre_vote_reply"
)

type Message struct {
~~~

<!-- edit: internal/raft/node.go -->
~~~go
	PrevTerm            uint64
	Entries             []Entry
	Snapshot            *Snapshot `json:",omitempty"`
}

type Ready struct {
~~~

Replace it with this version.

~~~go
	PrevTerm            uint64
	Entries             []Entry
	Snapshot            *Snapshot `json:",omitempty"`
	ProbeTerm, Round    uint64
}

type Ready struct {
~~~

<!-- edit: internal/raft/node.go -->
~~~go
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
	log      []Entry
	progress []progress
	commit   int
	snapshot Snapshot
}

func New(id, members int, seed int64) *Node {
~~~

Replace it with this version.

~~~go
}

type Node struct {
	id            int
	members       int // IDs are contiguous, starting at 1.
	role          Role
	term          uint64
	vote          int
	leader        int
	votes         map[int]bool
	elapsed       int
	deadline      int
	rng           *rand.Rand
	ready         Ready
	log           []Entry
	progress      []progress
	commit        int
	snapshot      Snapshot
	safeguards    bool
	round         uint64
	contacts      map[int]bool
	quorumElapsed int
}

func New(id, members int, seed int64) *Node {
~~~

<!-- edit: internal/raft/node.go -->
~~~go

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
~~~

Replace it with this version.

~~~go

func (n *Node) resetTimer() {
	n.elapsed = 0
	n.deadline = quorumTicks + n.rng.Intn(quorumTicks)
}

func (n *Node) Tick() {
	n.elapsed++
	if n.role == Leader {
		if n.safeguards && !n.checkQuorum() {
			return
		}
		if n.elapsed >= 3 {
			n.elapsed = 0
			n.broadcast()
~~~

<!-- edit: internal/raft/node.go -->
~~~go
		return
	}
	if n.elapsed >= n.deadline {
		n.campaign()
	}
}
~~~

Replace it with this version.

~~~go
		return
	}
	if n.elapsed >= n.deadline {
		if n.safeguards {
			n.probe()
		} else {
			n.campaign()
		}
	}
}
~~~

<!-- edit: internal/raft/node.go -->
~~~go
		return false
	}
	n.role, n.leader, n.elapsed = Leader, n.id, 0
	n.startReplication()
	n.appendLocal(Command{}) // Commit prior entries with a new-term no-op.
	n.tryCommit()
~~~

Replace it with this version.

~~~go
		return false
	}
	n.role, n.leader, n.elapsed = Leader, n.id, 0
	n.contacts, n.quorumElapsed = make(map[int]bool), 0
	n.startReplication()
	n.appendLocal(Command{}) // Commit prior entries with a new-term no-op.
	n.tryCommit()
~~~

<!-- edit: internal/raft/node.go -->
~~~go
}

func (n *Node) Step(m Message) {
	if m.To != n.id || m.From < 1 || m.From > n.members || m.From == n.id || m.Term == 0 {
		return
	}
	if m.Term > n.term {
~~~

Replace it with this version.

~~~go
}

func (n *Node) Step(m Message) {
	if m.To != n.id || m.From < 1 || m.From > n.members || m.From == n.id {
		return
	}
	if m.Kind == PreVote || m.Kind == PreVoteReply {
		if n.safeguards {
			n.stepProbe(m)
		}
		return
	}
	if m.Term == 0 {
		return
	}
	if m.Term > n.term {
~~~

<!-- edit: internal/raft/node.go -->
~~~go
		}
	case AppendReply:
		if n.role == Leader {
			n.appendReply(m)
		}
	}
~~~

Replace it with this version.

~~~go
		}
	case AppendReply:
		if n.role == Leader {
			if n.safeguards {
				n.contacts[m.From] = true
			}
			n.appendReply(m)
		}
	}
~~~

</details>

### Step 2 — Enable the safeguards in the real peer

Accept the pre-vote wire kinds during bootstrap and enable the safeguards before the runtime starts.

<details>
<summary>Hint 1</summary>

A new peer can use term zero in a probe because the prospective term is carried separately.

</details>

<details>
<summary>Hint 2</summary>

Both peers need to understand the trial messages.

</details>

<details>
<summary>Implementation</summary>

Find these blocks in `internal/metad/http.go` in order.

<!-- edit: internal/metad/http.go -->
~~~go
	var message raft.Message
	if !decode(w, req, 256<<10, &message) || message.To != r.id ||
		message.From < 1 || message.From > r.members || message.From == r.id ||
		message.Term == 0 || len(message.Entries) > 16 {
		http.Error(w, "invalid peer message", http.StatusBadRequest)
		return
	}
	switch message.Kind {
	case raft.RequestVote, raft.VoteReply, raft.Append, raft.AppendReply, raft.Install:
	default:
		http.Error(w, "unknown message", http.StatusBadRequest)
		return
~~~

Replace it with this version.

~~~go
	var message raft.Message
	if !decode(w, req, 256<<10, &message) || message.To != r.id ||
		message.From < 1 || message.From > r.members || message.From == r.id ||
		(message.Term == 0 && message.Kind != raft.PreVote && message.Kind != raft.PreVoteReply) ||
		len(message.Entries) > 16 {
		http.Error(w, "invalid peer message", http.StatusBadRequest)
		return
	}
	switch message.Kind {
	case raft.RequestVote, raft.VoteReply, raft.Append, raft.AppendReply, raft.Install, raft.PreVote, raft.PreVoteReply:
	default:
		http.Error(w, "unknown message", http.StatusBadRequest)
		return
~~~

Find these blocks in `internal/metad/runtime.go` in order.

<!-- edit: internal/metad/runtime.go -->
~~~go
}

func New(id, members int, seed int64, stable raft.Stable, disk interface{ Save(raft.Batch) error }) *Runtime {
	return &Runtime{
		id: id, members: members, node: raft.Restore(id, members, seed, stable), disk: disk,
		messages: make(chan raft.Message, 128), propose: make(chan proposal, 128),
		status: make(chan chan Status),
	}
~~~

Replace it with this version.

~~~go
}

func New(id, members int, seed int64, stable raft.Stable, disk interface{ Save(raft.Batch) error }) *Runtime {
	node := raft.Restore(id, members, seed, stable)
	node.EnableElectionSafeguards()
	return &Runtime{
		id: id, members: members, node: node, disk: disk,
		messages: make(chan raft.Message, 128), propose: make(chan proposal, 128),
		status: make(chan chan Status),
	}
~~~

</details>

### Step 3 — Compare fixed schedules

Measure the term under the same partial partition in both configurations. Then isolate the leader from both followers.

<details>
<summary>Hint 1</summary>

The leader counts itself when measuring quorum contact.

</details>

<details>
<summary>Hint 2</summary>

A contact received before isolation may keep it leader through the first window.

</details>

<details>
<summary>Implementation</summary>

Create `internal/cluster/safeguards_test.go`.

<!-- file: internal/cluster/safeguards_test.go -->
~~~go
package cluster

import (
	"testing"

	"switchyard/metad/internal/raft"
)

func TestPartialPartitionKeepsHealthyLeader(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		c := New(3, 13)
		if enabled {
			for _, peer := range c.Nodes[1:] {
				peer.EnableElectionSafeguards()
			}
		}
		c.Run(100)
		term, leader := c.LatestLeader()
		lagging := leader%3 + 1
		c.Net.Block(leader, lagging, true)
		c.Net.Block(lagging, leader, true)
		c.Run(100)
		_, leaderNow := c.LatestLeader()
		if !enabled {
			if c.Nodes[leader].Term() <= term {
				t.Fatal("control did not disrupt the old leader")
			}
			t.Logf("without safeguards: original leader advanced from term %d to %d", term, c.Nodes[leader].Term())
			continue
		}
		if c.Nodes[leader].Term() != term || leaderNow != leader || c.Nodes[leader].Role() != raft.Leader {
			t.Fatalf("healthy majority lost its leader in term %d", term)
		}
		before := c.Applied[leader]
		if !c.Propose(leader, raft.Command{Op: "put", Key: "job", Value: "queued"}) {
			t.Fatal("healthy leader refused write")
		}
		c.Run(8)
		if c.Applied[leader] != before+1 {
			t.Fatal("majority did not complete the write")
		}
		t.Logf("with PreVote: majority committed in unchanged term %d", term)
	}
}

func TestLeaderStepsDownWithoutQuorum(t *testing.T) {
	c := New(3, 13)
	for _, peer := range c.Nodes[1:] {
		peer.EnableElectionSafeguards()
	}
	c.Run(100)
	term, leader := c.LatestLeader()
	c.Isolate(leader, true)
	// A contact from the previous window can permit one more window.
	c.Run(24)
	if c.Nodes[leader].Role() == raft.Leader || c.Nodes[leader].Term() != term {
		t.Fatal("isolated leader did not step down locally")
	}
	t.Log("CheckQuorum stepped down the minority leader within two windows")
}

func TestReturningFollowerDoesNotRaiseTerm(t *testing.T) {
	c := New(3, 13)
	for _, peer := range c.Nodes[1:] {
		peer.EnableElectionSafeguards()
	}
	c.Run(100)
	term, leader := c.LatestLeader()
	returning := leader%3 + 1
	c.Isolate(returning, true)
	c.Run(100)
	c.Isolate(returning, false)
	c.Run(60)
	if c.Nodes[leader].Role() != raft.Leader || c.Nodes[returning].Term() != term {
		t.Fatal("returning follower disrupted the leader")
	}
	t.Logf("returning peer recognized the leader in term %d", term)
}
~~~

</details>

## Check it

~~~bash
go test -race -count=1 -v ./internal/cluster -run "TestPartial|TestLeaderSteps|TestReturning"
~~~

<!-- run: go test -race -count=1 -v ./internal/cluster -run "TestPartial|TestLeaderSteps|TestReturning" -->

The control moved the original leader from term 1 to term 6. With PreVote, its majority committed in term 1. With CheckQuorum, an isolated leader stepped down within two windows. The fixtures cover these link shapes and seeds.

## If it goes wrong

If a healthy majority loses its leader, trace PreVote responses from the follower linking the two sides. If a minority leader stays in power, check that quorum contacts are cleared after each window.
