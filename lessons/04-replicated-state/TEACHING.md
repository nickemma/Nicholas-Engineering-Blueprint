# Phase 4 teaching: replicate and scale out

At the end of Phase 3, Runway's data is durable: it survives crashes, and a backup can bring it back. But it all lives on **one** PostgreSQL server. If that machine's disk dies, everything written since the last backup is gone. While the server restarts, Runway is down. And once the data or the traffic outgrows one machine, there's nowhere to go.

The answer is **more than one machine**, and it's where systems get genuinely hard. With copies on several machines, they must **agree** on what the data is, even though:
- messages between them are delayed, lost and reordered;
- machines crash and restart at any moment;
- the network can split them into groups that can't see each other, or worse, into *partial* partitions where A sees B, B sees C, but A can't see C;
- no machine can tell whether another one has crashed or is just slow.

This phase builds the standard answer, **consensus with Raft**, from nothing: your own implementation, tested in a simulator that makes every failure happen on purpose, reproducibly, thousands of times. It checks the result for **linearizability** with a real checker, models the core rule in **TLA+**, and runs it as a real three-node service that holds Runway's metadata. Then it does the other half of scaling: splitting data across machines with **consistent hashing**, coordinating with **leases and fencing tokens**, and changing data on several machines at once, with **two-phase commit** and **sagas**.

**The goal:** a Raft implementation that elects leaders, replicates a log, survives crashes, compacts with snapshots, and rides out partial partitions. It passes safety checks across thousands of simulated storms, a linearizability checker, a model checker, and a real cluster with real crashes. Around it you'll have a replicated metadata store with leased locks, a cache spread over several servers, and transactions across databases, each with its failure modes demonstrated.

**Time:** about 10 weeks. This is the hardest phase so far, on purpose. **Before you start:** finish Phase 3. Install Java 11 or newer (`java -version`) for TLA+ in step 9.

**A note on MIT 6.5840.** Its Raft labs are excellent extra practice, but do them in a **private** repository: MIT asks students not to publish solutions. The Raft in this guide is written independently, with a different design (a pure state machine driven by a simulator, in the style of etcd's raft), and its tests are its own.

## How this guide works

The same as before: type everything, file by file, and run the tests at the end of each step. Most of this phase runs in a **simulator**, so the tests need no servers at all, and each one replays exactly from its seed. Steps 11 and 12 use Redis and PostgreSQL again.

| Step | What you add |
|---|---|
| 1 | A simulated network, and a failure detector that can only ever *suspect* |
| 2 | Raft, part 1: terms, votes and leader election |
| 3 | Raft, part 2: log replication, commitment, and Figure 8 |
| 4 | Persistence: what must be saved before anything is sent, and a write-ahead log on disk |
| 5 | Snapshots and log compaction |
| 6 | Partial partitions, PreVote and CheckQuorum |
| 7 | A replicated key-value store with exactly-once sessions, checked for linearizability |
| 8 | Running it for real: a runtime, an HTTP transport, and a three-node `metad` |
| 9 | A TLA+ model of elections, checked by TLC |
| 10 | Locks with leases, and fencing tokens |
| 11 | Consistent hashing, hot keys, and a cache spread over several Redis servers |
| 12 | Transactions across shards: two-phase commit and sagas |

## Setup

Start from your finished Phase 3 code. From the repository root:

~~~bash
cd lessons/04-replicated-state
cp -r ../03-durable-auditable-data/practice practice
rm -rf practice/audit/target
cd practice
go test ./...
~~~

<!-- continue: ../03-durable-auditable-data/TEACHING.md -->

Keep the Phase 3 variables (`RUNWAY_DATABASE_URL` and the rest) exported. Steps 11 and 12 add two more Redis servers and one PostgreSQL setting.

---

## Step 1: A simulated network, and what a node can know

**The problem.** Distributed bugs hide in timing. Two messages cross in flight, a node pauses for half a second, a link drops one packet in ten thousand. Run the same test twice on real machines and you get two different interleavings: the bug shows up once a month, in production, and never when you're watching. You can't fix what you can't reproduce.

So before writing any distributed algorithm, build the world it will be tested in: a network you control completely, where time only moves when you say so and every random choice comes from a seed. Then a failing run is a seed, and a seed is a bug you can replay forever.

**New ideas.**

- A **failure model** says what can go wrong. This phase assumes:
  - **crash-recovery**: a node can stop at any instant, and may later restart with whatever it had saved to disk;
  - **omission**: messages can be lost, delayed by any amount, duplicated by retries, and reordered.

  It doesn't assume **Byzantine** failures, where a node lies or sends garbage on purpose. Tolerating those needs different, costlier algorithms (BFT), used in blockchains and some aerospace systems.
- A **timing model** says what you can assume about time:
  - *synchronous*: messages and steps have known upper bounds;
  - *asynchronous*: no bounds at all;
  - *partially synchronous*: bounds exist but you don't know them, or they only hold eventually.

  Real networks are best described as partially synchronous: usually fast, sometimes arbitrarily slow.
- **Clocks.**
  - A machine's clock drifts and gets corrected, and can even jump backwards. Go's `time.Now()` carries a separate *monotonic* reading for measuring durations, for exactly this reason.
  - Comparing timestamps from *different* machines tells you little about which event happened first. A **logical clock** orders events by causality instead: Lamport clocks count events and carry the count in messages. Raft's **terms**, in the next step, are a logical clock.
- A **failure detector** guesses which nodes have crashed, usually with heartbeats and a timeout. It can only **suspect**. A crashed node and a slow node look identical from outside: both are silent. Shorten the timeout and you detect crashes faster, but suspect more live nodes; lengthen it and you're wrong less often, and slower.
- **FLP**, stated precisely (Fischer, Lynch and Paterson, 1985): in an asynchronous system where even one process may crash, no deterministic algorithm can guarantee that consensus always *terminates*. Real systems such as Raft get around it by being always **safe** (they never decide two different things) and **live only when the network behaves** for long enough (partial synchrony).
- **CAP**, stated precisely (Gilbert and Lynch, 2002): when the network partitions, a system can't make *every* request both **linearizable** (as if there were one copy) and **answered**. Raft chooses consistency: the minority side of a partition stops answering. Nothing about CAP is relevant when there's no partition.
- **Deterministic simulation testing** runs the real code against a simulated network and clock, driven by one seed, and checks the system's safety rules after every step. FoundationDB and TigerBeetle are built this way; it finds bugs that years of production traffic wouldn't.
- **Asymmetric and partial partitions.** A link can fail in one direction only (A hears B, B doesn't hear A), or some links fail while others work. Real networks do this: a misconfigured firewall, a congested switch port. Step 6 shows they are harder for Raft than a clean split.

### The network

Create `internal/simnet/simnet.go`:

<!-- file: internal/simnet/simnet.go -->
~~~go
// Package simnet is a simulated network for testing distributed code.
//
// It is deterministic. Time is a counter of ticks, not the wall clock, and
// every random choice (how long a message takes, whether it's lost) comes
// from one seeded source. So a run that finds a bug can be replayed exactly,
// as many times as you like, from its seed.
package simnet

import (
	"math/rand/v2"
	"slices"
)

// Envelope is a message in flight.
type Envelope struct {
	From, To int
	Msg      any
	At       int // the tick it arrives
	seq      int // send order, to break ties deterministically
}

// Network delivers messages between numbered nodes, after a random delay,
// unless they're lost or a link is cut.
type Network struct {
	rng                *rand.Rand
	now                int
	minDelay, maxDelay int
	dropRate           float64
	cut                map[[2]int]bool // from→to links that deliver nothing
	inFlight           []Envelope
	seq                int

	Sent, Dropped, Delivered int
}

// New returns a network where every message takes exactly one tick.
func New(rng *rand.Rand) *Network {
	return &Network{rng: rng, minDelay: 1, maxDelay: 1, cut: map[[2]int]bool{}}
}

// SetDelay makes each message take between min and max ticks, chosen at
// random. Different delays let messages overtake each other.
func (n *Network) SetDelay(min, max int) { n.minDelay, n.maxDelay = min, max }

// SetDropRate loses each message with probability p.
func (n *Network) SetDropRate(p float64) { n.dropRate = p }

// Cut stops messages from one node reaching another. It is one-way: to cut
// both directions, call it twice.
func (n *Network) Cut(from, to int) { n.cut[[2]int{from, to}] = true }

// Partition splits the nodes into groups that can't reach each other.
// Nodes in the same group still can.
func (n *Network) Partition(groups ...[]int) {
	for i, a := range groups {
		for j, b := range groups {
			if i == j {
				continue
			}
			for _, from := range a {
				for _, to := range b {
					n.Cut(from, to)
				}
			}
		}
	}
}

// Heal restores every link.
func (n *Network) Heal() { clear(n.cut) }

// Now is the current tick.
func (n *Network) Now() int { return n.now }

// Send puts msg in flight from one node to another.
func (n *Network) Send(from, to int, msg any) {
	n.Sent++
	if n.cut[[2]int{from, to}] || n.rng.Float64() < n.dropRate {
		n.Dropped++
		return
	}
	delay := n.minDelay
	if n.maxDelay > n.minDelay {
		delay += n.rng.IntN(n.maxDelay - n.minDelay + 1)
	}
	n.seq++
	n.inFlight = append(n.inFlight, Envelope{From: from, To: to, Msg: msg, At: n.now + delay, seq: n.seq})
}

// Tick advances time by one tick and returns the messages that arrive now,
// in a fixed order. A message whose link was cut while it was in flight is
// lost.
func (n *Network) Tick() []Envelope {
	n.now++
	var due, later []Envelope
	for _, e := range n.inFlight {
		switch {
		case e.At > n.now:
			later = append(later, e)
		case n.cut[[2]int{e.From, e.To}]:
			n.Dropped++
		default:
			due = append(due, e)
		}
	}
	n.inFlight = later
	slices.SortFunc(due, func(a, b Envelope) int {
		if a.At != b.At {
			return a.At - b.At
		}
		return a.seq - b.seq
	})
	n.Delivered += len(due)
	return due
}
~~~

Nothing here is concurrent. There are no goroutines and no real time: `Tick` is the only way time passes. Messages that arrive in the same tick come out sorted by when they were sent, so even the order is deterministic. `Cut` is one-way on purpose, so you can build any shape of partial partition.

Create `internal/simnet/simnet_test.go`:

<!-- file: internal/simnet/simnet_test.go -->
~~~go
package simnet

import (
	"math/rand/v2"
	"testing"
)

func TestMessagesArriveAfterTheirDelay(t *testing.T) {
	n := New(rand.New(rand.NewPCG(1, 1)))
	n.SetDelay(3, 3)
	n.Send(1, 2, "hello")
	for tick := 1; tick <= 2; tick++ {
		if got := n.Tick(); len(got) != 0 {
			t.Fatalf("tick %d delivered %v early", tick, got)
		}
	}
	got := n.Tick()
	if len(got) != 1 || got[0].Msg != "hello" || got[0].From != 1 || got[0].To != 2 {
		t.Fatalf("tick 3 delivered %v", got)
	}
}

func TestACutLinkLosesMessagesInFlight(t *testing.T) {
	n := New(rand.New(rand.NewPCG(1, 1)))
	n.SetDelay(2, 2)
	n.Send(1, 2, "in flight")
	n.Cut(1, 2)
	n.Tick()
	if got := n.Tick(); len(got) != 0 {
		t.Fatalf("delivered %v across a cut link", got)
	}
	n.Send(2, 1, "the other way")
	n.Tick()
	if got := n.Tick(); len(got) != 1 {
		t.Fatalf("a one-way cut blocked the other direction: got %v", got)
	}
	if n.Dropped != 1 {
		t.Fatalf("Dropped = %d, want 1", n.Dropped)
	}
}

func TestPartitionSeparatesGroups(t *testing.T) {
	n := New(rand.New(rand.NewPCG(1, 1)))
	n.Partition([]int{1, 2}, []int{3})
	n.Send(1, 2, "same side")
	n.Send(1, 3, "across")
	n.Send(3, 2, "across")
	if got := n.Tick(); len(got) != 1 || got[0].Msg != "same side" {
		t.Fatalf("delivered %v, want only the same-side message", got)
	}
	n.Heal()
	n.Send(1, 3, "healed")
	if got := n.Tick(); len(got) != 1 {
		t.Fatalf("after Heal, delivered %v", got)
	}
}
~~~

### A failure detector, to see what a node can know

Create `internal/detector/detector.go`:

<!-- file: internal/detector/detector.go -->
~~~go
// Package detector is a heartbeat failure detector: each node tells every
// other node "I'm alive" at a fixed interval, and suspects any peer it
// hasn't heard from for a while.
//
// It can only ever *suspect*. A peer that has crashed and a peer whose
// heartbeats are delayed or lost look exactly the same from here.
package detector

import "slices"

// Heartbeat is the only message.
type Heartbeat struct{}

// Node is one member's detector.
type Node struct {
	id        int
	peers     []int
	interval  int
	timeout   int
	lastHeard map[int]int
}

// New returns a detector for node id that sends a heartbeat every interval
// ticks and suspects a peer after timeout ticks of silence.
func New(id int, peers []int, interval, timeout int) *Node {
	n := &Node{id: id, interval: interval, timeout: timeout, lastHeard: map[int]int{}}
	for _, p := range peers {
		if p != id {
			n.peers = append(n.peers, p)
			n.lastHeard[p] = 0
		}
	}
	return n
}

// Tick is called once per tick. It sends heartbeats when they're due.
func (n *Node) Tick(now int, send func(to int, msg any)) {
	if now%n.interval == 0 {
		for _, p := range n.peers {
			send(p, Heartbeat{})
		}
	}
}

// Receive records a message from a peer.
func (n *Node) Receive(now, from int, msg any) {
	if _, ok := msg.(Heartbeat); ok {
		n.lastHeard[from] = now
	}
}

// Suspects lists the peers not heard from for longer than the timeout.
func (n *Node) Suspects(now int) []int {
	var out []int
	for _, p := range n.peers {
		if now-n.lastHeard[p] > n.timeout {
			out = append(out, p)
		}
	}
	slices.Sort(out)
	return out
}
~~~

And a small world to run three of them in. Create `internal/detector/detector_test.go`:

<!-- file: internal/detector/detector_test.go -->
~~~go
package detector

import (
	"fmt"
	"math/rand/v2"
	"strings"
	"testing"

	"runway/internal/simnet"
)

// world runs three detectors on a simulated network.
type world struct {
	net     *simnet.Network
	nodes   map[int]*Node
	crashed map[int]bool
	log     []string // every change in who suspects whom, in order
	last    map[int]string
}

func newWorld(seed uint64) *world {
	w := &world{
		net:     simnet.New(rand.New(rand.NewPCG(seed, seed))),
		nodes:   map[int]*Node{},
		crashed: map[int]bool{},
		last:    map[int]string{},
	}
	for id := 1; id <= 3; id++ {
		w.nodes[id] = New(id, []int{1, 2, 3}, 2, 6)
		w.last[id] = "[]"
	}
	return w
}

func (w *world) run(ticks int) {
	for range ticks {
		for _, e := range w.net.Tick() {
			if !w.crashed[e.To] {
				w.nodes[e.To].Receive(w.net.Now(), e.From, e.Msg)
			}
		}
		for id := 1; id <= 3; id++ {
			if w.crashed[id] {
				continue
			}
			w.nodes[id].Tick(w.net.Now(), func(to int, msg any) { w.net.Send(id, to, msg) })
			if s := fmt.Sprint(w.nodes[id].Suspects(w.net.Now())); s != w.last[id] {
				w.last[id] = s
				w.log = append(w.log, fmt.Sprintf("t=%d node %d suspects %s", w.net.Now(), id, s))
			}
		}
	}
}

func TestACrashedNodeIsSuspected(t *testing.T) {
	w := newWorld(1)
	w.run(20)
	w.crashed[3] = true
	w.run(20)
	for _, id := range []int{1, 2} {
		if got := w.nodes[id].Suspects(w.net.Now()); fmt.Sprint(got) != "[3]" {
			t.Errorf("node %d suspects %v, want [3]", id, got)
		}
	}
}

// Slow messages look exactly like a crash: every node ends up suspecting
// peers that never stopped running.
func TestSlowMessagesLookLikeACrash(t *testing.T) {
	w := newWorld(1)
	w.net.SetDelay(1, 12) // sometimes slower than the 6-tick timeout
	w.run(200)
	var falsely []string
	for _, line := range w.log {
		if !strings.HasSuffix(line, "[]") {
			falsely = append(falsely, line)
		}
	}
	if len(falsely) == 0 {
		t.Fatal("no live node was ever suspected; the delays should cause false suspicion")
	}
	t.Logf("%d false suspicions in 200 ticks; the first: %s", len(falsely), falsely[0])
}

// Cutting one direction of one link makes the two ends disagree.
func TestAOneWayCutIsSeenByOneSideOnly(t *testing.T) {
	w := newWorld(1)
	w.run(10)
	w.net.Cut(1, 2) // 1's heartbeats no longer reach 2
	w.run(20)
	if got := w.nodes[2].Suspects(w.net.Now()); fmt.Sprint(got) != "[1]" {
		t.Errorf("node 2 suspects %v, want [1]", got)
	}
	if got := w.nodes[1].Suspects(w.net.Now()); len(got) != 0 {
		t.Errorf("node 1 suspects %v, want nobody: it still hears from 2", got)
	}
	if got := w.nodes[3].Suspects(w.net.Now()); len(got) != 0 {
		t.Errorf("node 3 suspects %v, want nobody", got)
	}
}

// The same seed gives the same run, event for event; another seed doesn't.
func TestTheSameSeedReplaysExactly(t *testing.T) {
	trace := func(seed uint64) string {
		w := newWorld(seed)
		w.net.SetDelay(1, 12)
		w.net.SetDropRate(0.1)
		w.run(300)
		return strings.Join(w.log, "\n")
	}
	if trace(7) != trace(7) {
		t.Fatal("two runs with seed 7 differ")
	}
	if trace(7) == trace(8) {
		t.Fatal("seeds 7 and 8 gave identical runs")
	}
}
~~~

`world.run` is the pattern every simulation in this phase follows:
1. deliver the messages that arrive this tick;
2. tick every running node, giving it a way to send;
3. record what changed.

The `log` of suspicions doubles as a **trace**: the last test runs the same seed twice and compares the traces character for character.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/simnet/... ./internal/detector/... && go test -race -count=1 ./internal/simnet/... ./internal/detector/... -->

~~~bash
go test -v ./internal/simnet/ ./internal/detector/
~~~

~~~text
--- PASS: TestMessagesArriveAfterTheirDelay (0.00s)
--- PASS: TestACutLinkLosesMessagesInFlight (0.00s)
--- PASS: TestPartitionSeparatesGroups (0.00s)
ok  	runway/internal/simnet	0.006s
--- PASS: TestACrashedNodeIsSuspected (0.00s)
    detector_test.go:82: 7 false suspicions in 200 ticks; the first: t=7 node 3 suspects [1]
--- PASS: TestSlowMessagesLookLikeACrash (0.00s)
--- PASS: TestAOneWayCutIsSeenByOneSideOnly (0.00s)
--- PASS: TestTheSameSeedReplaysExactly (0.01s)
ok  	runway/internal/detector	0.014s
~~~

Read the second test's log line. Nobody crashed. With delays of up to 12 ticks against a 6-tick timeout, node 3 suspected node 1 at tick 7, and there were seven false suspicions in 200 ticks. The one-way cut is the strangest: node 2 suspects node 1, while node 1 is sure everything is fine. Two nodes, two views of the same network, both "correct" from where they stand. Any algorithm built on such views must be safe even when they disagree.

**Break it: a cautious timeout.** In `detector_test.go`, change the timeout in `newWorld` from `6` to `20`, longer than the slowest message:

~~~text
--- FAIL: TestACrashedNodeIsSuspected (0.00s)
    detector_test.go:62: node 1 suspects [], want [3]
    detector_test.go:62: node 2 suspects [], want [3]
--- FAIL: TestSlowMessagesLookLikeACrash (0.00s)
    detector_test.go:80: no live node was ever suspected; the delays should cause false suspicion
--- FAIL: TestTheSameSeedReplaysExactly (0.01s)
~~~

No more false suspicions, but now node 3's real crash goes unnoticed for the whole 20 ticks the test waits. (The replay test fails for a dull reason: with no suspicions at all, two different seeds give the same empty trace.) There is no timeout that's both fast and never wrong. Every system picks a point on that curve; Raft picks a short one and makes sure a wrong guess can never break safety. Put `6` back.

**Explain it:** why can't a node tell a crashed peer from a slow one? State FLP and CAP precisely, and say what each does *not* say. What does a seeded simulator give you that running real processes doesn't?

**Read.** *Designing Data-Intensive Applications* (DDIA) Ch. 8, *The Trouble with Distributed Systems*, whole chapter. Then Lamport, *Time, Clocks, and the Ordering of Events in a Distributed System* (1978), sections 1–3. Carry this question in: which of the problems in Ch. 8 can a simulator reproduce, and which can't it?

---

## Step 2: Raft, part 1, electing a leader

**The problem.** Several machines must hold the same data, in the same order, with no single point of failure. The classic approach is **state machine replication**:
- every node runs the same deterministic state machine (a key-value store, say);
- every node applies the same commands in the same order;
- so every node ends up in the same state.

The hard part is agreeing on the order while nodes crash and messages go missing. That agreement is **consensus**.

Raft (Ongaro and Ousterhout, 2014) splits consensus into pieces you can understand one at a time. First, **elect a leader**. The leader decides the order, and everyone else copies it. This step builds the election. The next builds the copying.

**New ideas.**

- **Terms.** Time is divided into numbered terms, and each term has at most one leader. A term number is a logical clock: every message carries the sender's term, and a node that sees a higher term than its own adopts it at once and becomes a follower. A message from a lower term is from the past, and is answered with a refusal (so its sender learns it's out of date) or ignored.
- **Roles.**
  - A **follower** obeys a leader.
  - A **candidate** is asking to become leader.
  - A **leader** sends regular **heartbeats** to stop the others from starting elections.
- **The election.** A follower that hears nothing from a leader for its **election timeout** becomes a candidate:
  1. it starts a new term;
  2. it votes for itself;
  3. it asks everyone else for their vote (`RequestVote`).

  Each node grants **at most one vote per term**, to the first candidate that asks. A candidate with votes from a **majority** becomes leader. Two majorities of the same cluster always share at least one node, and that node voted only once, so **two leaders in one term are impossible**. This property is **election safety**.
- **Randomised timeouts.** If every follower timed out together, they would all stand at once, split the vote, and try again forever. Each node therefore picks a random timeout, here between 10 and 19 ticks, and usually one stands alone and wins.
- **Quorum.** A majority: 2 of 3, 3 of 5. A cluster of `2f+1` nodes tolerates `f` failures. That's why clusters have odd sizes: 4 nodes tolerate no more failures than 3, and need more votes.
- **A pure state machine.** The core never sleeps, opens a socket or touches a file. Time arrives as `Tick()`, messages arrive as `Step(msg)`, and everything the node wants done comes back from `Ready()`: state to save, and messages to send. A simulator in tests, or goroutines and sockets in production, carries those out. This is the design of etcd's raft library, and it's what makes every behaviour below reproducible.

### The core

Create `internal/raft/raft.go`:

<!-- file: internal/raft/raft.go -->
~~~go
// Package raft is the core of the Raft consensus algorithm (Ongaro and
// Ousterhout, "In Search of an Understandable Consensus Algorithm", 2014).
//
// The core is a pure state machine. It never sleeps, never touches the
// network or a disk, and never starts a goroutine. Time arrives as calls to
// Tick, messages as calls to Step, and everything the node wants done comes
// back from Ready: state to save, messages to send. The code around it (a
// simulator in tests, real goroutines, sockets and files in production)
// does the rest. That split is what makes every behaviour reproducible.
package raft

import (
	"math/rand/v2"
	"slices"
)

// ID names a member of the cluster. IDs start at 1; None is "nobody".
type ID int

const None ID = 0

// Role is what a node is doing in the current term.
type Role int

const (
	Follower Role = iota
	Candidate
	Leader
)

func (r Role) String() string {
	return [...]string{"follower", "candidate", "leader"}[r]
}

// MsgType says what a Message is.
type MsgType int

const (
	MsgVote     MsgType = iota + 1 // RequestVote: "elect me"
	MsgVoteResp                    // the answer
	MsgApp                         // AppendEntries, also the leader's heartbeat
	MsgAppResp                     // the answer
)

// Entry is one record in the replicated log.
type Entry struct {
	Term  uint64
	Index uint64
	Data  []byte
}

// Message is everything nodes say to each other. Which fields matter
// depends on Type.
type Message struct {
	Type     MsgType
	From, To ID
	Term     uint64 // the sender's current term
	// MsgVote: the candidate's last entry.
	LogIndex, LogTerm uint64
	Reject            bool // a refused vote or append
}

// HardState is what a node must save before it sends any message: if it
// forgot its term or its vote after a crash, it could vote twice.
type HardState struct {
	Term uint64
	Vote ID
}

// Config is a node's fixed settings.
type Config struct {
	ID    ID
	Peers []ID // every member, including this node
	// A follower that hears nothing from a leader for a random number of
	// ticks between ElectionTick and 2*ElectionTick-1 stands for election.
	ElectionTick int
	// A leader sends a heartbeat every HeartbeatTick ticks. It must be well
	// below ElectionTick, or followers stand for election needlessly.
	HeartbeatTick int
	// Rand chooses the election timeouts. A seeded source makes a node's
	// whole behaviour repeatable.
	Rand *rand.Rand
}

// Ready is what the node needs done after Tick, Step or Propose.
type Ready struct {
	HardState *HardState // non-nil when it changed: save it first
	Messages  []Message  // then send these
}

// Status is a snapshot of the node's view, for tests and monitoring.
type Status struct {
	ID     ID
	Role   Role
	Term   uint64
	Leader ID
}

// Node is one member's Raft state.
type Node struct {
	cfg   Config
	peers []ID // sorted, so every loop over them is in a fixed order

	role   Role
	term   uint64
	vote   ID
	leader ID

	electionElapsed  int
	electionTimeout  int
	heartbeatElapsed int
	votes            map[ID]bool

	msgs  []Message
	saved HardState
}

// New returns a follower in term 0.
func New(cfg Config) *Node {
	n := &Node{cfg: cfg, peers: slices.Sorted(slices.Values(cfg.Peers))}
	n.resetElectionTimer()
	return n
}

func (n *Node) quorum() int { return len(n.peers)/2 + 1 }

func (n *Node) resetElectionTimer() {
	n.electionElapsed = 0
	n.electionTimeout = n.cfg.ElectionTick + n.cfg.Rand.IntN(n.cfg.ElectionTick)
}

func (n *Node) send(m Message) {
	m.From, m.Term = n.cfg.ID, n.term
	n.msgs = append(n.msgs, m)
}

// Tick advances the node's clock by one tick.
func (n *Node) Tick() {
	if n.role == Leader {
		n.heartbeatElapsed++
		if n.heartbeatElapsed >= n.cfg.HeartbeatTick {
			n.heartbeatElapsed = 0
			n.broadcastHeartbeat()
		}
		return
	}
	n.electionElapsed++
	if n.electionElapsed >= n.electionTimeout {
		n.campaign()
	}
}

// campaign starts an election: a new term, a vote for itself, and a
// request for everyone else's vote.
func (n *Node) campaign() {
	n.role = Candidate
	n.term++
	n.vote = n.cfg.ID
	n.leader = None
	n.votes = map[ID]bool{n.cfg.ID: true}
	n.resetElectionTimer()
	if n.quorum() == 1 {
		n.becomeLeader()
		return
	}
	for _, p := range n.peers {
		if p != n.cfg.ID {
			n.send(Message{Type: MsgVote, To: p})
		}
	}
}

func (n *Node) becomeFollower(term uint64, leader ID) {
	n.role = Follower
	if term > n.term {
		n.term = term
		n.vote = None
	}
	n.leader = leader
	n.resetElectionTimer()
}

func (n *Node) becomeLeader() {
	n.role = Leader
	n.leader = n.cfg.ID
	n.heartbeatElapsed = 0
	n.broadcastHeartbeat()
}

func (n *Node) broadcastHeartbeat() {
	for _, p := range n.peers {
		if p != n.cfg.ID {
			n.send(Message{Type: MsgApp, To: p})
		}
	}
}

// Step processes one message from another node.
func (n *Node) Step(m Message) {
	switch {
	case m.Term > n.term:
		// Anyone with a newer term means this node is out of date. Only an
		// append comes from a known leader.
		leader := None
		if m.Type == MsgApp {
			leader = m.From
		}
		n.becomeFollower(m.Term, leader)
	case m.Term < n.term:
		// A message from an old term. Answer requests, so a stale leader or
		// candidate learns the new term and steps down; drop answers.
		switch m.Type {
		case MsgApp:
			n.send(Message{Type: MsgAppResp, To: m.From, Reject: true})
		case MsgVote:
			n.send(Message{Type: MsgVoteResp, To: m.From, Reject: true})
		}
		return
	}

	switch m.Type {
	case MsgVote:
		grant := n.vote == None || n.vote == m.From
		if grant {
			n.vote = m.From
			n.resetElectionTimer() // granting a vote defers our own candidacy
		}
		n.send(Message{Type: MsgVoteResp, To: m.From, Reject: !grant})
	case MsgVoteResp:
		if n.role != Candidate {
			return
		}
		n.votes[m.From] = !m.Reject
		granted := 0
		for _, ok := range n.votes {
			if ok {
				granted++
			}
		}
		if granted >= n.quorum() {
			n.becomeLeader()
		}
	case MsgApp:
		// A leader exists for this term: follow it.
		n.becomeFollower(m.Term, m.From)
		n.send(Message{Type: MsgAppResp, To: m.From})
	case MsgAppResp:
	}
}

// Ready returns what must be done now, and forgets it: the caller must save
// the HardState before sending the messages.
func (n *Node) Ready() Ready {
	var rd Ready
	if hs := (HardState{Term: n.term, Vote: n.vote}); hs != n.saved {
		n.saved = hs
		rd.HardState = &hs
	}
	rd.Messages, n.msgs = n.msgs, nil
	return rd
}

// Status reports the node's current view.
func (n *Node) Status() Status {
	return Status{ID: n.cfg.ID, Role: n.role, Term: n.term, Leader: n.leader}
}
~~~

Walk through one election, in the code:

1. **`Tick`.** A follower's `electionElapsed` reaches its `electionTimeout`, so it calls `campaign`.
2. **`campaign`.** It increases `term`, votes for itself, and queues a `MsgVote` to each peer. `send` stamps every message with the sender's ID and term.
3. **`Step`, receiving a vote request.** If the message's term is higher, the receiver first becomes a follower in that term, which clears its vote. Then it grants the vote only if it hasn't voted for anyone else in this term.
4. **`Step`, receiving a vote response.** The candidate counts its grants. On reaching a quorum it calls `becomeLeader`, which sends heartbeats (`MsgApp` with nothing in it yet).
5. **Heartbeats** reach followers, which call `becomeFollower` and reset their election timer, so no one else stands.

`HardState` is what a node will have to save before it sends anything: its term and its vote. Step 4 shows what happens when it doesn't.

### A simulated cluster that checks itself

Create `internal/raft/raftsim/raftsim.go`:

<!-- file: internal/raft/raftsim/raftsim.go -->
~~~go
// Package raftsim runs a Raft cluster on a simulated network, and checks
// Raft's safety properties after every step.
package raftsim

import (
	"fmt"
	"math/rand/v2"

	"runway/internal/raft"
	"runway/internal/simnet"
)

// Cluster is a simulated cluster of n nodes, IDs 1 to n.
type Cluster struct {
	Net   *simnet.Network
	rng   *rand.Rand
	nodes []*raft.Node // index 0 unused
	down  map[raft.ID]bool

	leaders map[uint64]raft.ID // who led each term: election safety
	err     error
}

// New builds a cluster whose every random choice comes from seed.
func New(n int, seed uint64) *Cluster {
	rng := rand.New(rand.NewPCG(seed, seed))
	c := &Cluster{
		Net:     simnet.New(rng),
		rng:     rng,
		nodes:   make([]*raft.Node, n+1),
		down:    map[raft.ID]bool{},
		leaders: map[uint64]raft.ID{},
	}
	for id := 1; id <= n; id++ {
		c.nodes[id] = raft.New(c.config(raft.ID(id)))
	}
	return c
}

func (c *Cluster) config(id raft.ID) raft.Config {
	var peers []raft.ID
	for p := 1; p < len(c.nodes); p++ {
		peers = append(peers, raft.ID(p))
	}
	return raft.Config{
		ID:            id,
		Peers:         peers,
		ElectionTick:  10,
		HeartbeatTick: 2,
		// Each node gets its own random source, drawn from the cluster's.
		Rand: rand.New(rand.NewPCG(c.rng.Uint64(), c.rng.Uint64())),
	}
}

// IDs lists the members.
func (c *Cluster) IDs() []raft.ID {
	var ids []raft.ID
	for id := 1; id < len(c.nodes); id++ {
		ids = append(ids, raft.ID(id))
	}
	return ids
}

// Node returns a member, for inspection.
func (c *Cluster) Node(id raft.ID) *raft.Node { return c.nodes[id] }

// Tick advances the whole cluster by one tick: deliver the messages that
// arrive now, tick every running node, and carry out each node's Ready.
func (c *Cluster) Tick() {
	for _, e := range c.Net.Tick() {
		to := raft.ID(e.To)
		if !c.down[to] {
			c.nodes[to].Step(e.Msg.(raft.Message))
			c.process(to)
		}
	}
	for _, id := range c.IDs() {
		if !c.down[id] {
			c.nodes[id].Tick()
			c.process(id)
		}
	}
}

// Run ticks n times, stopping early if a safety check fails.
func (c *Cluster) Run(ticks int) {
	for range ticks {
		if c.err != nil {
			return
		}
		c.Tick()
	}
}

// process carries out one node's Ready, then checks the invariants.
func (c *Cluster) process(id raft.ID) {
	rd := c.nodes[id].Ready()
	for _, m := range rd.Messages {
		c.Net.Send(int(m.From), int(m.To), m)
	}
	c.check(id)
}

func (c *Cluster) check(id raft.ID) {
	st := c.nodes[id].Status()
	if st.Role != raft.Leader {
		return
	}
	// Election safety: at most one leader in any term.
	if prev, ok := c.leaders[st.Term]; ok && prev != id {
		c.fail("election safety: nodes %d and %d both led term %d", prev, id, st.Term)
	}
	c.leaders[st.Term] = id
}

func (c *Cluster) fail(format string, args ...any) {
	if c.err == nil {
		c.err = fmt.Errorf("tick %d: %s", c.Net.Now(), fmt.Sprintf(format, args...))
	}
}

// Err is the first safety violation seen, or nil.
func (c *Cluster) Err() error { return c.err }

// Crash stops a node: it receives nothing and does nothing.
func (c *Cluster) Crash(id raft.ID) { c.down[id] = true }

// Leader returns the running node that believes it leads, in the highest
// term, or None.
func (c *Cluster) Leader() raft.ID {
	best, bestTerm := raft.None, uint64(0)
	for _, id := range c.IDs() {
		st := c.nodes[id].Status()
		if !c.down[id] && st.Role == raft.Leader && st.Term >= bestTerm {
			best, bestTerm = id, st.Term
		}
	}
	return best
}
~~~

After every node's `Ready`, `check` looks at that node: if it's a leader, it records which term it leads, and fails if any other node has ever led that same term. Checking after every single step, not just at the end, catches a violation at the moment it happens, with the tick in the message.

Create `internal/raft/raftsim/chaos.go`, the helpers for making trouble:

<!-- file: internal/raft/raftsim/chaos.go -->
~~~go
package raftsim

import "runway/internal/raft"

// Partition splits the cluster into groups that can't reach each other.
func (c *Cluster) Partition(groups ...[]raft.ID) {
	c.Net.Heal()
	var ints [][]int
	for _, g := range groups {
		var ids []int
		for _, id := range g {
			ids = append(ids, int(id))
		}
		ints = append(ints, ids)
	}
	c.Net.Partition(ints...)
}

// Heal restores every link.
func (c *Cluster) Heal() { c.Net.Heal() }

// randomPartition splits the cluster into two random groups.
func (c *Cluster) randomPartition() {
	var a, b []raft.ID
	for _, id := range c.IDs() {
		if c.rng.IntN(2) == 0 {
			a = append(a, id)
		} else {
			b = append(b, id)
		}
	}
	c.Partition(a, b)
}
~~~

### Tests

Create `internal/raft/raftsim/election_test.go`:

<!-- file: internal/raft/raftsim/election_test.go -->
~~~go
package raftsim

import (
	"testing"

	"runway/internal/raft"
)

func TestOneLeaderIsElected(t *testing.T) {
	c := New(3, 1)
	c.Run(100)
	leader := c.Leader()
	if leader == raft.None {
		t.Fatal("no leader after 100 ticks")
	}
	want := c.Node(leader).Status().Term
	for _, id := range c.IDs() {
		st := c.Node(id).Status()
		if st.Term != want || st.Leader != leader {
			t.Errorf("node %d: term %d, leader %d; want term %d, leader %d", id, st.Term, st.Leader, want, leader)
		}
	}
	if err := c.Err(); err != nil {
		t.Fatal(err)
	}
}

func TestANewLeaderReplacesACrashedOne(t *testing.T) {
	c := New(3, 2)
	c.Run(100)
	first := c.Leader()
	c.Crash(first)
	c.Run(100)
	second := c.Leader()
	if second == raft.None || second == first {
		t.Fatalf("after node %d crashed, the leader is %d", first, second)
	}
	if c.Node(second).Status().Term <= c.Node(first).Status().Term {
		t.Fatal("the new leader's term must be higher than the old one's")
	}
}

// Nodes cut off from the majority can't win: they never get enough votes.
func TestAMinorityCannotElectALeader(t *testing.T) {
	c := New(5, 3)
	c.Run(100)
	before := c.Node(c.Leader()).Status().Term
	c.Partition([]raft.ID{1, 2}, []raft.ID{3, 4, 5})
	c.Run(300)
	for term, id := range c.leaders {
		if term > before && id <= 2 {
			t.Fatalf("node %d won term %d from the minority side", id, term)
		}
	}
	if leader := c.Leader(); leader < 3 {
		t.Fatalf("the newest leader is %d, on the minority side", leader)
	}
}

// Many seeds, each a different storm of delays, losses and partitions.
// Whatever happens, no term may ever have two leaders.
func TestElectionSafetyUnderChaos(t *testing.T) {
	for seed := uint64(1); seed <= 200; seed++ {
		c := New(5, seed)
		c.Net.SetDelay(1, 8)
		c.Net.SetDropRate(0.1)
		for round := range 20 {
			if round%3 == 0 {
				c.Heal()
			} else {
				c.randomPartition()
			}
			c.Run(100)
		}
		if err := c.Err(); err != nil {
			t.Fatalf("seed %d: %v", seed, err)
		}
	}
}
~~~

The last test is the one that matters. It runs **200 storms**, each from its own seed. Each storm has 20 rounds of 100 ticks, with delays of up to 8 ticks, one message in ten lost, and the network split differently in most rounds. That's 400,000 simulated ticks, with the safety check after every node's every step.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/raft/... && go test -race -count=1 ./internal/raft/... -->

~~~bash
go test -v ./internal/raft/...
~~~

~~~text
--- PASS: TestOneLeaderIsElected (0.00s)
--- PASS: TestANewLeaderReplacesACrashedOne (0.00s)
--- PASS: TestAMinorityCannotElectALeader (0.00s)
--- PASS: TestElectionSafetyUnderChaos (1.06s)
ok  	runway/internal/raft/raftsim	1.068s
~~~

**Break it: vote for anyone.** In `Step`, change `grant := n.vote == None || n.vote == m.From` to `grant := true`:

~~~text
--- FAIL: TestElectionSafetyUnderChaos (0.00s)
    election_test.go:76: seed 1: tick 21: election safety: nodes 4 and 2 both led term 1
~~~

The very first storm finds it, 21 ticks in: two candidates in term 1, both granted by the same voters, both "won". Now the bug has a seed and a tick. To investigate, you'd run only seed 1 for 21 ticks and print what each node did; it would happen exactly the same way every time. Restore the line.

**Explain it:** why can't two candidates win the same term? Why are election timeouts random? Why does a 4-node cluster tolerate no more failures than a 3-node one?

**Read.** The Raft paper (extended version), §1–5.2. Carry this question in: what does Raft gain by having a strong leader, and what does it give up?

---

## Step 3: Raft, part 2, replicating the log

**The problem.** A leader on its own does nothing useful. Clients send it commands. It must put each one in its **log**, copy the log to the followers, and decide when an entry is safe: when no future leader can ever lose or change it. Only then may anyone apply it. Get any rule slightly wrong, and two nodes apply different commands at the same position, which is exactly what replication exists to prevent.

**New ideas.**

- **The log** is a numbered list of **entries**, each holding a command and the term in which a leader created it. An entry is identified by its *index and term* together: same index and same term means same entry.
- **AppendEntries.** The leader sends each follower the entries it's missing, together with the index and term of the entry just *before* them. The follower accepts only if its own log has that entry: the **consistency check**. If it hasn't, it refuses, and the leader backs up and tries an earlier position. This guarantees the **Log Matching** property: if two logs share an entry (same index and term), they are identical up to that point.
- **Conflicts are resolved by the leader.** A follower whose log disagrees with the leader's (entries from a leader that lost) deletes the conflicting entry and everything after it, and takes the leader's. Only entries that were never committed can be lost this way.
- **next and match.** For each follower, the leader keeps `next`, the next index to send, and `match`, the highest index known to be the same on both. Messages arrive late and out of order, so an old rejection can turn up after a newer success. Whatever a response says, `next` must never fall below `match + 1`. (My first version got this wrong. The simulator found it in step 5, when it turned a harmless resend into a follower stuck forever. That story is in step 5.)
- **Commitment.** An entry is **committed** once the leader that created it has stored it on a majority. Followers learn the commit index from the leader's messages, and every node applies committed entries in order, exactly once.
- **The up-to-date rule for votes.** A node votes only for a candidate whose log is *at least as up to date* as its own: its last entry has a higher term, or the same term and an index at least as high. Since a committed entry is on a majority, and a winner needs a majority's votes, the winner always has every committed entry: **Leader Completeness**.
- **Figure 8, and the current-term rule.** There's one trap left, shown in Figure 8 of the paper. A leader may find an entry from an *earlier* term on a majority, and yet a later leader can still overwrite it. So a leader counts replicas only for entries of its **current term**. Earlier entries become committed indirectly, together with the first current-term entry after them. That's also why a new leader appends an **empty entry** of its own term at once: it commits everything before it as soon as possible.
- **Safety vs liveness.** *Safety* is "nothing bad ever happens": no two nodes apply different entries at the same index. *Liveness* is "something good eventually happens": proposals do get committed. Raft guarantees safety always, and liveness only while a majority can talk to each other for long enough.

### Replication in the core

The changes to `internal/raft/raft.go`, in order:
1. **Messages** carry entries, the leader's commit index, and a `Match` in responses (the follower's last matching index, or a hint where to try next).
2. **`HardState`** gains `Commit`.
3. **`Ready`** gains `Entries` to save (which replace saved entries from their first index on) and `Committed` entries to apply.
4. **The node** gains its log (with a placeholder at index 0, so every real entry has one before it), commit and applied indexes, and per-follower `next` and `match`.
5. **Votes** carry the candidate's last index and term, and are granted only to up-to-date candidates.
6. **`becomeLeader`** initialises `next` and `match`, appends the empty entry, and sends appends. `Propose` lets the leader accept a command.
7. **`handleAppend`** (the follower) runs the consistency check and appends or truncates. **`handleAppendResp`** (the leader) moves `next` and `match`, and calls **`maybeCommit`**, which applies the majority and current-term rules.

There are many small changes, so they are listed here exactly, in file order.

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
import (
	"math/rand/v2"
	"slices"
)

// ID names a member of the cluster. IDs start at 1; None is "nobody".
~~~

to:

~~~go
import (
	"errors"
	"math/rand/v2"
	"slices"
)

// ErrNotLeader means only the leader accepts proposals.
var ErrNotLeader = errors.New("not the leader")

// maxBatch is the most entries one append message carries.
const maxBatch = 64

// ID names a member of the cluster. IDs start at 1; None is "nobody".
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	// MsgVote: the candidate's last entry.
~~~

to:

~~~go
	// MsgVote: the candidate's last entry. MsgApp: the entry just before
	// Entries, which the follower must already have.
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	Reject            bool // a refused vote or append
~~~

to:

~~~go
	Entries           []Entry // MsgApp: entries to append
	Commit            uint64  // MsgApp: the leader's commit index
	Reject            bool    // a refused vote or append
	// MsgAppResp: the follower's last matching index on success, or a hint
	// of where to try next on rejection.
	Match uint64
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	Term uint64
	Vote ID
~~~

to:

~~~go
	Term   uint64
	Vote   ID
	Commit uint64
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	Messages  []Message  // then send these
~~~

to:

~~~go
	// Entries to save, starting at Entries[0].Index. Any saved entries at
	// that index or later are replaced: a follower's log can be truncated.
	Entries   []Entry
	Messages  []Message // send these only after saving the above
	Committed []Entry   // apply these to the state machine, in order
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	ID     ID
	Role   Role
	Term   uint64
	Leader ID
~~~

to:

~~~go
	ID        ID
	Role      Role
	Term      uint64
	Leader    ID
	Commit    uint64
	LastIndex uint64
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go

	electionElapsed  int
~~~

to:

~~~go

	// log[0] is a placeholder at index 0, term 0, so that every real
	// entry has an entry before it.
	log     []Entry
	commit  uint64 // the highest index known to be committed
	applied uint64 // the highest index handed out to be applied

	// Leader only: for each follower, the next index to send it, and the
	// highest index known to match the leader's log.
	next, match map[ID]uint64

	electionElapsed  int
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	msgs  []Message
	saved HardState
~~~

to:

~~~go
	msgs        []Message
	saved       HardState
	unsavedFrom uint64 // the lowest log index changed since the last Ready; 0 if none
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
// New returns a follower in term 0.
~~~

to:

~~~go
// New returns a follower in term 0 with an empty log.
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	n := &Node{cfg: cfg, peers: slices.Sorted(slices.Values(cfg.Peers))}
~~~

to:

~~~go
	n := &Node{
		cfg:   cfg,
		peers: slices.Sorted(slices.Values(cfg.Peers)),
		log:   []Entry{{}},
	}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	return n
}
~~~

to:

~~~go
	return n
}

func (n *Node) lastIndex() uint64 { return n.log[len(n.log)-1].Index }
func (n *Node) lastTerm() uint64  { return n.log[len(n.log)-1].Term }

// termAt is the term of the entry at index i. It must exist.
func (n *Node) termAt(i uint64) uint64 { return n.log[i].Term }

// changed notes that the log changed from index i on and must be saved.
func (n *Node) changed(i uint64) {
	if n.unsavedFrom == 0 || i < n.unsavedFrom {
		n.unsavedFrom = i
	}
}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
			n.send(Message{Type: MsgVote, To: p})
~~~

to:

~~~go
			n.send(Message{Type: MsgVote, To: p, LogIndex: n.lastIndex(), LogTerm: n.lastTerm()})
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go

func (n *Node) becomeLeader() {
~~~

to:

~~~go

// becomeLeader starts a term as leader. It appends an empty entry of its
// own term at once: entries from earlier terms can only be committed
// together with one from the current term (§5.4.2 of the paper).
func (n *Node) becomeLeader() {
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	n.heartbeatElapsed = 0
	n.broadcastHeartbeat()
}
~~~

to:

~~~go
	n.heartbeatElapsed = 0
	n.next, n.match = map[ID]uint64{}, map[ID]uint64{}
	for _, p := range n.peers {
		n.next[p], n.match[p] = n.lastIndex()+1, 0
	}
	n.match[n.cfg.ID] = n.lastIndex() // the leader's own log matches itself
	n.appendEntry(nil)
	n.broadcastAppend()
}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
func (n *Node) broadcastHeartbeat() {
~~~

to:

~~~go
// appendEntry adds an entry of the current term to the leader's own log.
func (n *Node) appendEntry(data []byte) uint64 {
	index := n.lastIndex() + 1
	n.log = append(n.log, Entry{Term: n.term, Index: index, Data: data})
	n.changed(index)
	n.match[n.cfg.ID] = index
	n.maybeCommit() // a one-node cluster commits at once
	return index
}

// Propose asks the leader to add data to the log. It returns the entry's
// index. Being accepted is not being committed: a leader can lose its
// office before the entry reaches a majority, and then the entry is lost.
func (n *Node) Propose(data []byte) (uint64, error) {
	if n.role != Leader {
		return 0, ErrNotLeader
	}
	index := n.appendEntry(data)
	n.broadcastAppend()
	return index, nil
}

func (n *Node) broadcastHeartbeat() { n.broadcastAppend() }

// broadcastAppend sends every follower what it's missing. With nothing
// missing, the message is an empty heartbeat. Because heartbeats repeat,
// a lost message is simply sent again next time.
func (n *Node) broadcastAppend() {
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
			n.send(Message{Type: MsgApp, To: p})
		}
	}
}
~~~

to:

~~~go
			n.sendAppend(p)
		}
	}
}

func (n *Node) sendAppend(to ID) {
	prev := n.next[to] - 1
	last := min(n.lastIndex(), prev+maxBatch)
	n.send(Message{
		Type:     MsgApp,
		To:       to,
		LogIndex: prev,
		LogTerm:  n.termAt(prev),
		Entries:  slices.Clone(n.log[prev+1 : last+1]),
		Commit:   n.commit,
	})
}

// maybeCommit advances the commit index to the highest entry a majority
// has, but only if that entry is from the current term.
func (n *Node) maybeCommit() {
	var matches []uint64
	for _, p := range n.peers {
		matches = append(matches, n.match[p])
	}
	slices.Sort(matches)
	slices.Reverse(matches)
	candidate := matches[n.quorum()-1] // a majority has at least this much
	if candidate > n.commit && n.termAt(candidate) == n.term {
		n.commit = candidate
	}
}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
		grant := n.vote == None || n.vote == m.From
~~~

to:

~~~go
		// Vote for at most one candidate per term, and only for one whose
		// log is at least as up to date as ours: it must end in a later
		// term, or in the same term and be at least as long.
		upToDate := m.LogTerm > n.lastTerm() || (m.LogTerm == n.lastTerm() && m.LogIndex >= n.lastIndex())
		grant := (n.vote == None || n.vote == m.From) && upToDate
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
		n.send(Message{Type: MsgAppResp, To: m.From})
	case MsgAppResp:
	}
~~~

to:

~~~go
		n.handleAppend(m)
	case MsgAppResp:
		if n.role == Leader {
			n.handleAppendResp(m)
		}
	}
}

// handleAppend is the follower's side of log replication.
func (n *Node) handleAppend(m Message) {
	// The log matching check: we must already have the entry just before
	// the new ones, with the same term. If not, refuse, and hint at where
	// our log ends so the leader can back up.
	if m.LogIndex > n.lastIndex() || n.termAt(m.LogIndex) != m.LogTerm {
		n.send(Message{Type: MsgAppResp, To: m.From, Reject: true, Match: min(m.LogIndex-1, n.lastIndex())})
		return
	}
	for _, e := range m.Entries {
		if e.Index <= n.lastIndex() {
			if n.termAt(e.Index) == e.Term {
				continue // already have it
			}
			// A conflicting entry: it, and everything after it, came from a
			// leader that lost. Discard them.
			n.log = n.log[:e.Index]
		}
		n.log = append(n.log, e)
		n.changed(e.Index)
	}
	lastNew := m.LogIndex + uint64(len(m.Entries))
	if m.Commit > n.commit {
		n.commit = min(m.Commit, lastNew)
	}
	n.send(Message{Type: MsgAppResp, To: m.From, Match: lastNew})
}

// handleAppendResp is the leader's side.
//
// Responses can arrive late and out of order, so a rejection may answer an
// old message. Whatever it says, next never goes below match+1: the
// follower is known to have everything up to match.
func (n *Node) handleAppendResp(m Message) {
	if m.Reject {
		n.next[m.From] = max(n.match[m.From]+1, min(n.next[m.From]-1, m.Match+1))
		n.sendAppend(m.From)
		return
	}
	if m.Match > n.match[m.From] {
		n.match[m.From] = m.Match
		n.maybeCommit()
	}
	n.next[m.From] = max(n.next[m.From], m.Match+1)
	if n.next[m.From] <= n.lastIndex() {
		n.sendAppend(m.From)
	}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	if hs := (HardState{Term: n.term, Vote: n.vote}); hs != n.saved {
~~~

to:

~~~go
	if hs := (HardState{Term: n.term, Vote: n.vote, Commit: n.commit}); hs != n.saved {
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
		rd.HardState = &hs
	}
~~~

to:

~~~go
		rd.HardState = &hs
	}
	if n.unsavedFrom > 0 {
		rd.Entries = slices.Clone(n.log[n.unsavedFrom:])
		n.unsavedFrom = 0
	}
	if n.commit > n.applied {
		rd.Committed = slices.Clone(n.log[n.applied+1 : n.commit+1])
		n.applied = n.commit
	}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	return Status{ID: n.cfg.ID, Role: n.role, Term: n.term, Leader: n.leader}
~~~

to:

~~~go
	return Status{ID: n.cfg.ID, Role: n.role, Term: n.term, Leader: n.leader, Commit: n.commit, LastIndex: n.lastIndex()}
~~~


Two details worth slowing down for:
- `maybeCommit` sorts every node's `match` in descending order and takes the one at position `quorum-1`. With 5 nodes, the third-highest match is an index that at least 3 nodes have. That's the majority rule in two lines.
- `handleAppend` only moves `commit` up to `lastNew`, the last entry *this* message proved the follower shares with the leader. Entries further along the follower's log might still be about to be overwritten.

### The simulator checks state machine safety

In `internal/raft/raftsim/raftsim.go`, every applied entry now goes through a check: the first node to apply index *i* records the entry, and any node that later applies a *different* entry at *i* is a violation. Clients propose through `Propose`, and `RunUntilConverged` waits until every running node has applied the same entries.

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	"math/rand/v2"

~~~

to:

~~~go
	"math/rand/v2"
	"slices"

~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	leaders map[uint64]raft.ID // who led each term: election safety
	err     error
~~~

to:

~~~go
	leaders   map[uint64]raft.ID    // who led each term: election safety
	committed map[uint64]raft.Entry // the entry applied at each index: state machine safety
	applied   [][]string            // each node's applied data, in order (index 0 unused)
	err       error
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
		Net:     simnet.New(rng),
		rng:     rng,
		nodes:   make([]*raft.Node, n+1),
		down:    map[raft.ID]bool{},
		leaders: map[uint64]raft.ID{},
~~~

to:

~~~go
		Net:       simnet.New(rng),
		rng:       rng,
		nodes:     make([]*raft.Node, n+1),
		down:      map[raft.ID]bool{},
		leaders:   map[uint64]raft.ID{},
		committed: map[uint64]raft.Entry{},
		applied:   make([][]string, n+1),
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	}
	c.check(id)
}
~~~

to:

~~~go
	}
	for _, e := range rd.Committed {
		c.apply(id, e)
	}
	c.check(id)
}

// apply records that node id applied entry e, and checks state machine
// safety: every node applies the same entry at the same index.
func (c *Cluster) apply(id raft.ID, e raft.Entry) {
	if prev, ok := c.committed[e.Index]; ok {
		if prev.Term != e.Term || string(prev.Data) != string(e.Data) {
			c.fail("state machine safety: node %d applied {term %d %q} at index %d, another node applied {term %d %q}",
				id, e.Term, e.Data, e.Index, prev.Term, prev.Data)
		}
	} else {
		c.committed[e.Index] = e
	}
	if e.Data != nil { // skip the empty entries new leaders append
		c.applied[id] = append(c.applied[id], string(e.Data))
	}
}

// RunUntilConverged ticks until every running node has applied the same
// entries, and reports how many ticks that took, or -1 if it didn't
// happen within limit ticks.
func (c *Cluster) RunUntilConverged(limit int) int {
	for tick := range limit {
		if c.converged() {
			return tick
		}
		c.Tick()
	}
	return -1
}

func (c *Cluster) converged() bool {
	var first []string
	var seen bool
	for _, id := range c.IDs() {
		if c.down[id] {
			continue
		}
		if !seen {
			first, seen = c.applied[id], true
			continue
		}
		if !slices.Equal(c.applied[id], first) {
			return false
		}
	}
	return c.Leader() != raft.None
}

// Applied is the data node id has applied, in order.
func (c *Cluster) Applied(id raft.ID) []string { return c.applied[id] }

// Propose offers data to the current leader. It reports false if there is
// no leader or the leader refused; true only means "accepted", not
// "committed".
func (c *Cluster) Propose(data string) bool {
	leader := c.Leader()
	if leader == raft.None {
		return false
	}
	if _, err := c.nodes[leader].Propose([]byte(data)); err != nil {
		return false
	}
	c.process(leader)
	return true
}
~~~


Create `internal/raft/raftsim/replication_test.go`:

<!-- file: internal/raft/raftsim/replication_test.go -->
~~~go
package raftsim

import (
	"fmt"
	"slices"
	"testing"

	"runway/internal/raft"
)

func elect(t *testing.T, c *Cluster) raft.ID {
	t.Helper()
	c.Run(100)
	leader := c.Leader()
	if leader == raft.None {
		t.Fatal("no leader")
	}
	return leader
}

func TestCommittedEntriesReachEveryNode(t *testing.T) {
	c := New(3, 1)
	elect(t, c)
	for i := range 10 {
		if !c.Propose(fmt.Sprint("v", i)) {
			t.Fatal("the leader refused a proposal")
		}
	}
	c.Run(50)
	want := []string{"v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9"}
	for _, id := range c.IDs() {
		if got := c.Applied(id); !slices.Equal(got, want) {
			t.Errorf("node %d applied %v", id, got)
		}
	}
	if err := c.Err(); err != nil {
		t.Fatal(err)
	}
}

func TestAFollowerThatMissedEntriesCatchesUp(t *testing.T) {
	c := New(3, 2)
	leader := elect(t, c)
	behind := leader%3 + 1
	var rest []raft.ID
	for _, id := range c.IDs() {
		if id != behind {
			rest = append(rest, id)
		}
	}
	c.Partition([]raft.ID{behind}, rest)
	for i := range 100 {
		c.Propose(fmt.Sprint("v", i))
	}
	c.Run(50)
	if n := len(c.Applied(behind)); n != 0 {
		t.Fatalf("the cut-off node applied %d entries", n)
	}
	c.Heal()
	c.Run(200)
	if got, want := len(c.Applied(behind)), 100; got != want {
		t.Fatalf("after healing, the node applied %d entries, want %d", got, want)
	}
	if err := c.Err(); err != nil {
		t.Fatal(err)
	}
}

// A leader cut off from the majority still accepts proposals, but can't
// commit them. When it rejoins, they are thrown away.
func TestADeposedLeadersUncommittedEntriesAreDiscarded(t *testing.T) {
	c := New(5, 3)
	old := elect(t, c)
	var rest []raft.ID
	for _, id := range c.IDs() {
		if id != old {
			rest = append(rest, id)
		}
	}
	c.Partition([]raft.ID{old}, rest)
	if _, err := c.Node(old).Propose([]byte("lost")); err != nil {
		t.Fatal(err)
	}
	c.process(old)
	c.Run(200) // the majority elects a new leader
	if !c.Propose("kept") {
		t.Fatal("no leader on the majority side")
	}
	c.Run(50)
	c.Heal()
	c.Run(200)
	for _, id := range c.IDs() {
		if got := c.Applied(id); !slices.Equal(got, []string{"kept"}) {
			t.Errorf("node %d applied %v, want [kept]", id, got)
		}
	}
	if err := c.Err(); err != nil {
		t.Fatal(err)
	}
}

// Storms of delays, losses and partitions, with proposals throughout.
// Safety must hold at every step; once the storm ends, every node must
// catch up to the same log.
func TestStateMachineSafetyUnderChaos(t *testing.T) {
	for seed := uint64(1); seed <= 200; seed++ {
		c := New(5, seed)
		c.Net.SetDelay(1, 8)
		c.Net.SetDropRate(0.1)
		proposed := 0
		for round := range 20 {
			if round%3 == 0 {
				c.Heal()
			} else {
				c.randomPartition()
			}
			for range 5 {
				if c.Propose(fmt.Sprint("s", seed, "-", proposed)) {
					proposed++
				}
				c.Run(20)
			}
		}
		c.Heal()
		c.Net.SetDropRate(0)
		ticks := c.RunUntilConverged(5000)
		if err := c.Err(); err != nil {
			t.Fatalf("seed %d: %v", seed, err)
		}
		if ticks < 0 {
			t.Fatalf("seed %d: the nodes still disagree 5000 ticks after the storm ended", seed)
		}
		if len(c.Applied(1)) == 0 {
			t.Fatalf("seed %d: nothing was committed in 2000 ticks", seed)
		}
	}
}
~~~

The storm test now proposes throughout. At the end it **heals everything** and requires every node to converge on the same applied entries within 5,000 ticks. That's a liveness check, separate from the safety checks that ran at every step.

### Figure 8, step by step

Random storms are good at finding bugs, but some bugs need a specific sequence of events. For those, write the scenario by hand. This test drives five nodes directly, with a network that holds every message until the test delivers it. It's in package `raft`, not `raftsim`, so it can call unexported methods like `campaign`. Create `internal/raft/figure8_test.go`:

<!-- file: internal/raft/figure8_test.go -->
~~~go
package raft

import (
	"math/rand/v2"
	"slices"
	"testing"
)

// manual is a network the test controls completely: messages wait in a
// queue until the test delivers them, and a message to or from a node that
// isn't "up" is lost, as if that node had crashed.
type manual struct {
	t       *testing.T
	nodes   map[ID]*Node
	queue   []Message
	applied map[ID]map[uint64]Entry
}

func newManual(t *testing.T, size int) *manual {
	w := &manual{t: t, nodes: map[ID]*Node{}, applied: map[ID]map[uint64]Entry{}}
	var peers []ID
	for id := 1; id <= size; id++ {
		peers = append(peers, ID(id))
	}
	for _, id := range peers {
		w.nodes[id] = New(Config{ID: id, Peers: peers, ElectionTick: 10, HeartbeatTick: 2, Rand: rand.New(rand.NewPCG(1, uint64(id)))})
		w.applied[id] = map[uint64]Entry{}
	}
	return w
}

// collect takes a node's Ready: queue its messages, record what it applied.
func (w *manual) collect(id ID) {
	rd := w.nodes[id].Ready()
	w.queue = append(w.queue, rd.Messages...)
	for _, e := range rd.Committed {
		w.applied[id][e.Index] = e
	}
}

// deliver passes messages among the up nodes until none are left. Messages
// to or from any other node are lost.
func (w *manual) deliver(up ...ID) { w.deliverOnly(nil, up...) }

// deliverOnly is deliver, but passes only messages of the given types
// (all types if nil). Others stay queued.
func (w *manual) deliverOnly(types []MsgType, up ...ID) {
	var held []Message
	for len(w.queue) > 0 {
		m := w.queue[0]
		w.queue = w.queue[1:]
		switch {
		case types != nil && !slices.Contains(types, m.Type):
			held = append(held, m)
		case slices.Contains(up, m.From) && slices.Contains(up, m.To):
			w.nodes[m.To].Step(m)
			w.collect(m.To)
		}
	}
	w.queue = held
}

// elect makes id stand for election among the up nodes until it wins.
// Only the votes are delivered: the new leader's first appends stay
// queued, so the test decides whether they ever arrive.
func (w *manual) elect(id ID, up ...ID) {
	for range 5 {
		w.nodes[id].campaign()
		w.collect(id)
		w.deliverOnly([]MsgType{MsgVote, MsgVoteResp}, up...)
		if w.nodes[id].role == Leader {
			return
		}
	}
	w.t.Fatalf("node %d could not win an election among %v", id, up)
}

// heartbeat makes the leader send to everyone, and delivers among up.
func (w *manual) heartbeat(id ID, up ...ID) {
	w.nodes[id].broadcastAppend()
	w.collect(id)
	w.deliver(up...)
}

// The scenario of Figure 8 in the Raft paper, step by step. If a leader
// could commit an entry from an earlier term just by counting replicas, a
// later leader could overwrite it after it was applied.
func TestFigure8(t *testing.T) {
	w := newManual(t, 5)
	all := []ID{1, 2, 3, 4, 5}

	// (a) Node 1 leads term 1. Its entry "x" reaches only node 2.
	w.elect(1, all...)
	w.heartbeat(1, all...)
	if _, err := w.nodes[1].Propose([]byte("x")); err != nil {
		t.Fatal(err)
	}
	w.collect(1)
	w.deliver(1, 2)

	// (b) Node 1 crashes. Node 5 wins term 2 with votes from 3 and 4,
	// accepts an entry "y", and crashes before anything reaches anyone.
	w.elect(5, 3, 4, 5)
	if _, err := w.nodes[5].Propose([]byte("y")); err != nil {
		t.Fatal(err)
	}
	w.collect(5)
	w.queue = nil

	// (c) Node 1 is back and wins again, with votes from 2 and 3. It copies
	// "x" to node 3: now "x" is on a majority (1, 2, 3).
	w.elect(1, 1, 2, 3)
	w.heartbeat(1, 1, 2, 3)
	w.heartbeat(1, 1, 2, 3)

	// (d) Node 1 crashes again. Node 5 returns and stands for election. If
	// it can win, it overwrites what it disagrees with.
	w.queue = nil
	for range 5 {
		w.nodes[5].campaign()
		w.collect(5)
		w.deliverOnly([]MsgType{MsgVote, MsgVoteResp}, 2, 3, 4, 5)
		if w.nodes[5].role == Leader {
			w.heartbeat(5, 2, 3, 4, 5)
			w.heartbeat(5, 2, 3, 4, 5)
			break
		}
	}
	t.Logf("node 5 ended as %s of term %d", w.nodes[5].role, w.nodes[5].term)

	// Whatever happened, no two nodes may have applied different entries at
	// the same index.
	for index := uint64(1); index <= 4; index++ {
		var seen *Entry
		for _, id := range all {
			e, ok := w.applied[id][index]
			if !ok {
				continue
			}
			if seen != nil && (seen.Term != e.Term || string(seen.Data) != string(e.Data)) {
				t.Fatalf("index %d: node %d applied {term %d %q}, another node applied {term %d %q}",
					index, id, e.Term, e.Data, seen.Term, seen.Data)
			}
			seen = &e
		}
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/raft/... && go test -race -count=1 ./internal/raft/... -->

~~~bash
go test -v ./internal/raft/...
~~~

~~~text
    figure8_test.go:129: node 5 ended as candidate of term 7
--- PASS: TestFigure8 (0.00s)
ok  	runway/internal/raft	0.006s
--- PASS: TestOneLeaderIsElected (0.00s)
--- PASS: TestANewLeaderReplacesACrashedOne (0.00s)
--- PASS: TestAMinorityCannotElectALeader (0.00s)
--- PASS: TestElectionSafetyUnderChaos (1.38s)
--- PASS: TestCommittedEntriesReachEveryNode (0.00s)
--- PASS: TestAFollowerThatMissedEntriesCatchesUp (0.00s)
--- PASS: TestADeposedLeadersUncommittedEntriesAreDiscarded (0.00s)
--- PASS: TestStateMachineSafetyUnderChaos (1.49s)
ok  	runway/internal/raft/raftsim	2.881s
~~~

In Figure 8, node 5 tries five times and never wins: nodes 2 and 3 hold an entry from node 1's latest term, so node 5's log isn't up to date for them.

**Break it: vote for any log.** In the `MsgVote` case, change the `upToDate := ...` line to `upToDate := true`:

~~~text
--- FAIL: TestFigure8 (0.00s)
    figure8_test.go:129: node 5 ended as leader of term 4
    figure8_test.go:141: index 2: node 4 applied {term 2 ""}, another node applied {term 1 "x"}
~~~

Node 5, missing the committed entry `x`, won anyway, and overwrote it on nodes that had already applied it. The storm tests fail too. Restore the line.

**Break it: Figure 8 itself.** This one surprised me. Remove the current-term rule from `maybeCommit` (change `if candidate > n.commit && n.termAt(candidate) == n.term {` to `if candidate > n.commit {`) and run everything again. **All the tests still pass.** The rule is not the only protection: the empty entry a new leader appends is a second one. Every follower the leader counts in `match` has already received that current-term entry, so the earlier-term entry is never counted on its own. Now also delete the line `n.appendEntry(nil)` in `becomeLeader`:

~~~text
    figure8_test.go:129: node 5 ended as leader of term 4
    figure8_test.go:141: index 1: node 4 applied {term 2 "y"}, another node applied {term 1 "x"}
--- FAIL: TestFigure8 (0.00s)
~~~

With both protections gone, Figure 8 happens exactly as in the paper. Node 1 counted `x` on a majority in a later term and committed it. Then node 5, with `y` from term 2, won an election and overwrote it. The random storms never found this; the scripted scenario found it at once. Restore both lines. Keep both: a safety rule you rely on should never depend on one line of code being right.

**Explain it:** what does the consistency check guarantee, and how? Why may a follower delete entries, and why are they never committed ones? Draw Figure 8, and explain each of the two protections against it.

**Read.** The Raft paper, §5.3–5.4 (including Figure 8). Carry this question in: Leader Completeness is proved in §5.4.3. Which rule in your code does each step of the proof rely on?

---

## Step 4: Persistence, what must be saved first

**The problem.** So far a "crash" only stopped a node. Real crashes wipe memory: a restarted node knows only what it saved to disk. Which state must survive, and *when* must it be saved? Raft's answer is precise, and getting the *when* wrong breaks safety in ways that take months to show up in production.

**New ideas.**

- **What must be saved:** the current term, the vote in that term, and the log. Forget the term, and a node can vote in an old term again. Forget the vote, and it can vote twice in the same term. Forget a log entry it acknowledged, and an entry the leader counted as committed may vanish. The commit index can be saved too, as a hint, and everything else (roles, timers, `next` and `match`) is rebuilt on start.
- **Save before you speak.** A node must save its `Ready`'s state *before* sending its messages. A vote or an acknowledgement is a promise; once someone has heard it, the promise must survive a crash. The order is always: **save, send, apply.**
- **The state machine is rebuilt, not saved.** On restart, the node hands out committed entries again from the beginning (or, from step 5, from its last snapshot), and the state machine is rebuilt by applying them.
- **A write-ahead log (WAL)** saves state by appending records to a file, and replays them on start. Appending is fast, and one `fsync` per `Ready` makes a whole batch durable at once. You built the record format already: a length, a CRC-32C, and a payload, the same as the Rust Bridge's `klog`, with the same treatment of a torn last record.
- **Truncation without rewriting.** A follower sometimes replaces the tail of its log. The WAL never rewrites anything: an `Entry` record with index *i* simply replaces everything from *i* on when the file is replayed.

### The core restarts from saved state

In `internal/raft/raft.go`, `New` takes what was saved. Change:

<!-- edit: internal/raft/raft.go -->
~~~go
// New returns a follower in term 0 with an empty log.
func New(cfg Config) *Node {
	n := &Node{
		cfg:   cfg,
		peers: slices.Sorted(slices.Values(cfg.Peers)),
		log:   []Entry{{}},
	}
	n.resetElectionTimer()
	return n
}
~~~

to:

~~~go
// Persisted is what a node saved before it stopped: its HardState and its
// log. A new node starts with the zero value.
type Persisted struct {
	HardState HardState
	Entries   []Entry
}

// New returns a follower that carries on from saved: the same term, the
// same vote, the same log. Committed entries are handed out to be applied
// again from the start, because the state machine they built was in memory
// and is gone.
func New(cfg Config, saved Persisted) *Node {
	n := &Node{
		cfg:   cfg,
		peers: slices.Sorted(slices.Values(cfg.Peers)),
		log:   append([]Entry{{}}, saved.Entries...),
		term:  saved.HardState.Term,
		vote:  saved.HardState.Vote,
	}
	n.commit = min(saved.HardState.Commit, n.lastIndex())
	n.saved = HardState{Term: n.term, Vote: n.vote, Commit: n.commit}
	n.resetElectionTimer()
	return n
}
~~~

`n.saved` starts equal to what was loaded, so the first `Ready` doesn't save the same `HardState` again.

The Figure 8 test creates nodes too. In `internal/raft/figure8_test.go`, change:

<!-- edit: internal/raft/figure8_test.go -->
~~~go
		w.nodes[id] = New(Config{ID: id, Peers: peers, ElectionTick: 10, HeartbeatTick: 2, Rand: rand.New(rand.NewPCG(1, uint64(id)))})
~~~

to:

~~~go
		w.nodes[id] = New(Config{ID: id, Peers: peers, ElectionTick: 10, HeartbeatTick: 2, Rand: rand.New(rand.NewPCG(1, uint64(id)))}, Persisted{})
~~~

### A disk for every simulated node

The simulator gives each node a `Disk` that survives `Crash`, and saves each `Ready` to it **before** sending. `CrashChance` makes a node crash at random in the middle of carrying out a `Ready`: after saving, before sending. `Restart` builds a fresh node from what its disk holds.

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	nodes []*raft.Node // index 0 unused
	down  map[raft.ID]bool

~~~

to:

~~~go
	nodes []*raft.Node // index 0 unused
	disks []*Disk      // what each node has saved; survives crashes
	down  map[raft.ID]bool

	// CrashChance is the probability that a node crashes in the middle of
	// carrying out a Ready: after its first step, before its second.
	CrashChance float64

~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
		nodes:     make([]*raft.Node, n+1),
		down:      map[raft.ID]bool{},
~~~

to:

~~~go
		nodes:     make([]*raft.Node, n+1),
		disks:     make([]*Disk, n+1),
		down:      map[raft.ID]bool{},
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
		c.nodes[id] = raft.New(c.config(raft.ID(id)))
~~~

to:

~~~go
		c.disks[id] = &Disk{}
		c.nodes[id] = raft.New(c.config(raft.ID(id)), raft.Persisted{})
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
// process carries out one node's Ready, then checks the invariants.
~~~

to:

~~~go
// Disk is a node's saved state. The simulator treats every save as
// durable at once, as if each one ended with a successful fsync.
type Disk struct {
	state raft.Persisted
}

func (d *Disk) save(rd raft.Ready) {
	if rd.HardState != nil {
		d.state.HardState = *rd.HardState
	}
	if len(rd.Entries) > 0 {
		// Entries replace whatever was saved from their first index on.
		first := rd.Entries[0].Index
		d.state.Entries = append(d.state.Entries[:first-1], rd.Entries...)
	}
}

// process carries out one node's Ready, in Raft's required order: save,
// then send, then apply. Then it checks the invariants.
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	rd := c.nodes[id].Ready()
	for _, m := range rd.Messages {
~~~

to:

~~~go
	rd := c.nodes[id].Ready()
	c.disks[id].save(rd)
	if c.rng.Float64() < c.CrashChance {
		c.Crash(id) // saved, but the messages never left
		return
	}
	for _, m := range rd.Messages {
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
// Crash stops a node: it receives nothing and does nothing.
func (c *Cluster) Crash(id raft.ID) { c.down[id] = true }

~~~

to:

~~~go
// Crash stops a node: it receives nothing and does nothing. Everything not
// on its disk is gone.
func (c *Cluster) Crash(id raft.ID) { c.down[id] = true }

// Restart brings a crashed node back from what its disk holds. Its state
// machine starts empty and is rebuilt by applying the log again.
func (c *Cluster) Restart(id raft.ID) {
	c.nodes[id] = raft.New(c.config(id), c.disks[id].state)
	c.applied[id] = nil
	c.down[id] = false
}

// Down reports whether a node is crashed.
func (c *Cluster) Down(id raft.ID) bool { return c.down[id] }

~~~


Create `internal/raft/raftsim/persistence_test.go`:

<!-- file: internal/raft/raftsim/persistence_test.go -->
~~~go
package raftsim

import (
	"fmt"
	"slices"
	"testing"
)

// A whole cluster can crash and come back: everything committed is still
// there, and is applied again.
func TestAClusterRestartKeepsCommittedEntries(t *testing.T) {
	c := New(3, 4)
	elect(t, c)
	for i := range 5 {
		c.Propose(fmt.Sprint("v", i))
	}
	c.Run(50)
	for _, id := range c.IDs() {
		c.Crash(id)
	}
	for _, id := range c.IDs() {
		c.Restart(id)
	}
	c.Run(200)
	want := []string{"v0", "v1", "v2", "v3", "v4"}
	for _, id := range c.IDs() {
		if got := c.Applied(id); !slices.Equal(got, want) {
			t.Errorf("node %d applied %v after restarting, want %v", id, got, want)
		}
	}
	if err := c.Err(); err != nil {
		t.Fatal(err)
	}
}

// Nodes crash at random moments, even halfway through a Ready, and come
// back later. Safety must still hold.
func TestSafetyWithCrashesAndRestarts(t *testing.T) {
	for seed := uint64(1); seed <= 1000; seed++ {
		c := New(5, seed)
		c.Net.SetDelay(1, 8)
		c.Net.SetDropRate(0.05)
		c.CrashChance = 0.01
		proposed := 0
		for round := range 30 {
			for _, id := range c.IDs() {
				if c.Down(id) && c.rng.IntN(2) == 0 {
					c.Restart(id)
				}
			}
			if round%4 == 0 {
				c.randomPartition()
			} else {
				c.Heal()
			}
			for range 5 {
				if c.Propose(fmt.Sprint("s", seed, "-", proposed)) {
					proposed++
				}
				c.Run(20)
			}
		}
		if err := c.Err(); err != nil {
			t.Fatalf("seed %d: %v", seed, err)
		}
	}
}

// Without its disk a restarted node has forgotten its vote, and can vote
// twice in one term. This shows why HardState must be saved.
func TestAmnesiaBreaksElectionSafety(t *testing.T) {
	for seed := uint64(1); seed <= 200; seed++ {
		c := New(3, seed)
		c.Net.SetDelay(1, 8)
		c.CrashChance = 0.01
		for range 30 {
			for _, id := range c.IDs() {
				if c.Down(id) && c.rng.IntN(2) == 0 {
					c.disks[id] = &Disk{} // the disk is lost too
					c.Restart(id)
				}
			}
			c.Run(50)
		}
		if c.Err() != nil {
			t.Logf("seed %d: %v", seed, c.Err())
			return
		}
	}
	t.Fatal("200 seeds of nodes losing their disks never broke safety; the test should find a violation")
}
~~~

`TestSafetyWithCrashesAndRestarts` runs **1,000 storms**: nodes crash in the middle of their work and come back from disk, as well as all the delays and partitions. It needs that many because the dangerous moment (crashing between two particular operations) is rare. With 200 storms, the "Break it" below slipped through. `TestAmnesiaBreaksElectionSafety` is a test that *expects* a violation: nodes that lose their disk must, eventually, break safety. It shows the disk is doing its job.

### A write-ahead log on a real disk

The simulator's disk is perfect. A real one isn't: a write can be cut short by a crash, and nothing is durable until `fsync` returns. Create `internal/raft/raftwal/raftwal.go`:

<!-- file: internal/raft/raftwal/raftwal.go -->
~~~go
// Package raftwal saves a Raft node's state in a write-ahead log: one file
// that is only ever appended to, in the record format of the Rust Bridge's
// klog (a length, a CRC-32C checksum, then the payload).
//
// Two kinds of record are written. A HardState record replaces the one
// before it. An Entry record with index i replaces every saved entry at i
// or later, which is how a follower's truncated log is saved without ever
// rewriting the file. Replaying the file in order rebuilds the state.
package raftwal

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"

	"runway/internal/raft"
)

const (
	kindHardState = 1
	kindEntry     = 2
	headerSize    = 8 // 4-byte length, 4-byte CRC-32C
)

var castagnoli = crc32.MakeTable(crc32.Castagnoli)

// ErrCorrupt means a record before the end of the file is damaged. A
// damaged *last* record is a write torn by a crash, and is cut off instead.
var ErrCorrupt = errors.New("write-ahead log is corrupt")

// WAL is an open log file.
type WAL struct {
	f *os.File
	w *bufio.Writer
}

// Open opens or creates the log in dir and replays it.
func Open(dir string) (*WAL, raft.Persisted, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, raft.Persisted{}, err
	}
	f, err := os.OpenFile(filepath.Join(dir, "raft.wal"), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, raft.Persisted{}, err
	}
	state, valid, err := replay(f)
	if err != nil {
		f.Close()
		return nil, raft.Persisted{}, err
	}
	// Cut off a torn tail, and make the cut itself durable.
	if err := f.Truncate(valid); err != nil {
		f.Close()
		return nil, raft.Persisted{}, err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return nil, raft.Persisted{}, err
	}
	if _, err := f.Seek(valid, io.SeekStart); err != nil {
		f.Close()
		return nil, raft.Persisted{}, err
	}
	return &WAL{f: f, w: bufio.NewWriter(f)}, state, nil
}

// Save appends a Ready's HardState and entries, then waits until they are
// on disk. Only after Save returns may the node's messages be sent.
func (w *WAL) Save(hs *raft.HardState, entries []raft.Entry) error {
	if hs == nil && len(entries) == 0 {
		return nil
	}
	for _, e := range entries {
		if err := w.write(kindEntry, encodeEntry(e)); err != nil {
			return err
		}
	}
	if hs != nil {
		if err := w.write(kindHardState, encodeHardState(*hs)); err != nil {
			return err
		}
	}
	if err := w.w.Flush(); err != nil {
		return err
	}
	return w.f.Sync()
}

func (w *WAL) Close() error {
	if err := w.w.Flush(); err != nil {
		w.f.Close()
		return err
	}
	return w.f.Close()
}

func (w *WAL) write(kind byte, payload []byte) error {
	body := append([]byte{kind}, payload...)
	var header [headerSize]byte
	binary.LittleEndian.PutUint32(header[0:4], uint32(len(body)))
	binary.LittleEndian.PutUint32(header[4:8], crc32.Checksum(body, castagnoli))
	if _, err := w.w.Write(header[:]); err != nil {
		return err
	}
	_, err := w.w.Write(body)
	return err
}

// replay reads every record, and returns the state and the length of the
// valid part of the file.
func replay(f *os.File) (raft.Persisted, int64, error) {
	data, err := io.ReadAll(f)
	if err != nil {
		return raft.Persisted{}, 0, err
	}
	var state raft.Persisted
	offset := 0
	for offset < len(data) {
		body, n, ok := decode(data[offset:])
		if !ok {
			// A damaged record with whole records after it is real damage.
			// One at the very end is a write torn by a crash: stop here,
			// and Open cuts it off.
			if n > 0 && offset+n < len(data) {
				return raft.Persisted{}, 0, fmt.Errorf("%w at byte %d", ErrCorrupt, offset)
			}
			break
		}
		switch body[0] {
		case kindHardState:
			state.HardState = decodeHardState(body[1:])
		case kindEntry:
			e := decodeEntry(body[1:])
			if e.Index == 0 || e.Index > uint64(len(state.Entries))+1 {
				return raft.Persisted{}, 0, fmt.Errorf("%w: entry %d after %d entries", ErrCorrupt, e.Index, len(state.Entries))
			}
			state.Entries = append(state.Entries[:e.Index-1], e)
		default:
			return raft.Persisted{}, 0, fmt.Errorf("%w: unknown record kind %d", ErrCorrupt, body[0])
		}
		offset += n
	}
	return state, int64(offset), nil
}

// decode reads one record from the start of data. It returns its body, the
// record's total length, and whether it is whole and its checksum matches.
// For a record cut short, n is 0.
func decode(data []byte) (body []byte, n int, ok bool) {
	if len(data) < headerSize {
		return nil, 0, false
	}
	size := int(binary.LittleEndian.Uint32(data[0:4]))
	if size == 0 || len(data) < headerSize+size {
		return nil, 0, false
	}
	body = data[headerSize : headerSize+size]
	if crc32.Checksum(body, castagnoli) != binary.LittleEndian.Uint32(data[4:8]) {
		return nil, headerSize + size, false
	}
	return body, headerSize + size, true
}

func encodeHardState(hs raft.HardState) []byte {
	b := make([]byte, 24)
	binary.LittleEndian.PutUint64(b[0:], hs.Term)
	binary.LittleEndian.PutUint64(b[8:], uint64(hs.Vote))
	binary.LittleEndian.PutUint64(b[16:], hs.Commit)
	return b
}

func decodeHardState(b []byte) raft.HardState {
	return raft.HardState{
		Term:   binary.LittleEndian.Uint64(b[0:]),
		Vote:   raft.ID(binary.LittleEndian.Uint64(b[8:])),
		Commit: binary.LittleEndian.Uint64(b[16:]),
	}
}

func encodeEntry(e raft.Entry) []byte {
	b := make([]byte, 16, 16+len(e.Data))
	binary.LittleEndian.PutUint64(b[0:], e.Term)
	binary.LittleEndian.PutUint64(b[8:], e.Index)
	return append(b, e.Data...)
}

func decodeEntry(b []byte) raft.Entry {
	e := raft.Entry{Term: binary.LittleEndian.Uint64(b[0:]), Index: binary.LittleEndian.Uint64(b[8:])}
	if len(b) > 16 {
		e.Data = append([]byte(nil), b[16:]...)
	}
	return e
}
~~~

`Save` writes all of a `Ready`'s records through a buffer, then calls `Sync` (Go's `fsync`) **once**. A single `fsync` for the whole batch is why WALs are fast: the cost of reaching the disk is shared by everything in it. `replay` treats a damaged record at the end as a torn write and cuts it off, just as `klog` does. A damaged record with whole records after it is real corruption, and is refused.

Create `internal/raft/raftwal/raftwal_test.go`:

<!-- file: internal/raft/raftwal/raftwal_test.go -->
~~~go
package raftwal

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"runway/internal/raft"
)

func entries(term uint64, from, to uint64) []raft.Entry {
	var es []raft.Entry
	for i := from; i <= to; i++ {
		es = append(es, raft.Entry{Term: term, Index: i, Data: []byte{byte(i)}})
	}
	return es
}

func reopen(t *testing.T, dir string) raft.Persisted {
	t.Helper()
	w, state, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	w.Close()
	return state
}

func TestStateSurvivesReopening(t *testing.T) {
	dir := t.TempDir()
	w, state, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(state, raft.Persisted{}) {
		t.Fatalf("a new log holds %+v", state)
	}
	hs := raft.HardState{Term: 2, Vote: 3, Commit: 2}
	if err := w.Save(&hs, entries(1, 1, 3)); err != nil {
		t.Fatal(err)
	}
	w.Close()

	got := reopen(t, dir)
	want := raft.Persisted{HardState: hs, Entries: entries(1, 1, 3)}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("after reopening:\n got %+v\nwant %+v", got, want)
	}
}

// A later entry at index i replaces the saved entries from i on, just as a
// follower's log is truncated.
func TestALaterEntryReplacesTheTail(t *testing.T) {
	dir := t.TempDir()
	w, _, _ := Open(dir)
	_ = w.Save(nil, entries(1, 1, 5))
	_ = w.Save(&raft.HardState{Term: 2}, entries(2, 3, 3))
	w.Close()

	got := reopen(t, dir).Entries
	want := append(entries(1, 1, 2), entries(2, 3, 3)...)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("entries = %+v\nwant %+v", got, want)
	}
}

// A crash in the middle of a write leaves a partial last record. Opening
// the log cuts it off and keeps everything before it.
func TestATornLastRecordIsCutOff(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "raft.wal")
	w, _, _ := Open(dir)
	_ = w.Save(&raft.HardState{Term: 1, Vote: 1}, entries(1, 1, 2))
	w.Close()
	whole, _ := os.Stat(path)

	w, _, _ = Open(dir)
	_ = w.Save(nil, entries(1, 3, 3))
	w.Close()
	info, _ := os.Stat(path)
	if err := os.Truncate(path, info.Size()-3); err != nil { // tear the last record
		t.Fatal(err)
	}

	got := reopen(t, dir)
	if len(got.Entries) != 2 || got.HardState.Term != 1 {
		t.Fatalf("after a torn write: %+v", got)
	}
	if after, _ := os.Stat(path); after.Size() != whole.Size() {
		t.Fatalf("file is %d bytes, want the %d bytes before the torn record", after.Size(), whole.Size())
	}
}

// Damage with whole records after it isn't a torn write. It's refused.
func TestDamageInTheMiddleIsRefused(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "raft.wal")
	w, _, _ := Open(dir)
	_ = w.Save(nil, entries(1, 1, 3))
	w.Close()
	data, _ := os.ReadFile(path)
	data[headerSize+1] ^= 0xFF // flip bits inside the first record
	_ = os.WriteFile(path, data, 0o600)

	if _, _, err := Open(dir); !errors.Is(err, ErrCorrupt) {
		t.Fatalf("error = %v, want ErrCorrupt", err)
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/raft/... && go test -race -count=1 ./internal/raft/... -->

~~~bash
go test -v ./internal/raft/raftsim/ ./internal/raft/raftwal/
~~~

~~~text
--- PASS: TestAClusterRestartKeepsCommittedEntries (0.00s)
--- PASS: TestSafetyWithCrashesAndRestarts (2.55s)
    persistence_test.go:86: seed 1: tick 618: state machine safety: node 1 applied {term 23 ""} at index 1, another node applied {term 1 ""}
--- PASS: TestAmnesiaBreaksElectionSafety (0.00s)
...
--- PASS: TestStateSurvivesReopening (0.01s)
--- PASS: TestALaterEntryReplacesTheTail (0.02s)
--- PASS: TestATornLastRecordIsCutOff (0.02s)
--- PASS: TestDamageInTheMiddleIsRefused (0.01s)
ok  	runway/internal/raft/raftwal	0.078s
~~~

The amnesia test's log line is the violation it was looking for. A node lost its disk, so it forgot the entry at index 1 it had already applied, and accepted a different one.

**Break it: send before saving.** In `process` in `raftsim.go`, move the save after the sends, so a crash can strike between them. Change:

~~~go
	rd := c.nodes[id].Ready()
	c.disks[id].save(rd)
	if c.rng.Float64() < c.CrashChance {
		c.Crash(id) // saved, but the messages never left
		return
	}
	for _, m := range rd.Messages {
		c.Net.Send(int(m.From), int(m.To), m)
	}
~~~

to:

~~~go
	rd := c.nodes[id].Ready()
	for _, m := range rd.Messages {
		c.Net.Send(int(m.From), int(m.To), m)
	}
	if c.rng.Float64() < c.CrashChance {
		c.Crash(id) // sent, but never saved
		return
	}
	c.disks[id].save(rd)
~~~

~~~text
--- FAIL: TestSafetyWithCrashesAndRestarts (0.07s)
    persistence_test.go:64: seed 20: tick 1944: state machine safety: node 3 applied {term 49 ""} at index 5, another node applied {term 30 "s20-1"}
~~~

Seed 20. A follower acknowledged entries, crashed before they reached its disk, and restarted without them. The leader had counted that acknowledgement towards a majority and committed `s20-1`. With one copy fewer than the leader believed, a later leader didn't have it, and replaced it. Across 1,000 seeds this order fails 8 times; the correct order never does. Restore it.

This is the most important line in any Raft implementation, and a code review would read straight past it. Etcd, Consul and every other production Raft have the same rule written in a comment next to the code that enforces it.

**Explain it:** which three things must a Raft node save, and what goes wrong if it forgets each one? Why must saving come before sending? Why does one `fsync` per `Ready` make the log fast?

**Read.** The Raft paper, §5.6 (timing) and Figure 2's "Persistent state on all servers". Then the etcd raft package's README, the section on the `Ready` loop. Carry this question in: what does `Ready` force the code around the core to get right?

---

## Step 5: Snapshots and log compaction

**The problem.** The log grows forever. Every write Runway ever made is in it, so a restart replays the whole history, and a new or lagging follower must receive all of it. Most of that history is redundant: if a key was written a thousand times, only the last write matters now.

**New ideas.**

- A **snapshot** is the state machine's whole state as of one log index, plus that entry's term. Once it's saved, every entry up to that index can be thrown away: **log compaction**. The state machine produces the snapshot, because only it knows how to encode its state. Raft only stores and ships it.
- **InstallSnapshot.** When a follower needs entries the leader has already compacted away, the leader sends its snapshot instead. The follower replaces its state machine's state with it, and keeps any log entries *after* the snapshot only if its log contains the snapshot's last entry, same index and same term. If it doesn't, its later entries came from a different history and are dropped.
- **An offset log.** After compaction, the entry at index *i* is no longer at position *i* in memory. `log[0]` now stands for the snapshot's last entry, and every lookup subtracts its index.
- **Atomic file replacement.** A snapshot file must never be seen half written. Write it in full under a temporary name, `fsync` it, rename it over the old one, then `fsync` the **directory**, since the rename is a change to the directory. A crash at any instant then leaves either the old file or the new one.
- **Crash between two files.** Saving a snapshot and rewriting the log are two operations. A crash between them leaves a new snapshot next to an old log that still contains the entries it covers. Recovery must handle it, and the tests below make that happen on purpose.

### Snapshots in the core

The changes to `internal/raft/raft.go`:
1. A `Snapshot` type, a `MsgSnap` message that carries one, and a `Snapshot` in `Ready` for one received from the leader.
2. `Persisted` gains the snapshot, and `New` starts the log from it.
3. The log is offset by the snapshot's index: `firstIndex`, `termAt` and the new `entries` helper do the arithmetic, and every place that indexed `log` directly uses them.
4. `sendAppend` sends the snapshot when the follower needs compacted entries.
5. `handleAppend` accepts a message that starts inside its snapshot, `handleSnapshot` installs one, and `Compact` lets the application compact.
6. `Ready` hands out a received snapshot, and never asks to save entries that a snapshot already covers.

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	"errors"
	"math/rand/v2"
~~~

to:

~~~go
	"errors"
	"fmt"
	"math/rand/v2"
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	MsgAppResp                     // the answer
)
~~~

to:

~~~go
	MsgAppResp                     // the answer
	MsgSnap                        // InstallSnapshot: "start from this state"
)
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	Data  []byte
}
~~~

to:

~~~go
	Data  []byte
}

// Snapshot is the state machine's whole state as of an index, which
// replaces every log entry up to and including it.
type Snapshot struct {
	Index uint64 // the last entry the snapshot includes
	Term  uint64 // that entry's term
	Data  []byte // the state machine's encoded state
}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	Match uint64
~~~

to:

~~~go
	Match    uint64
	Snapshot *Snapshot // MsgSnap
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	HardState *HardState // non-nil when it changed: save it first
	// Entries to save, starting at Entries[0].Index. Any saved entries at
~~~

to:

~~~go
	HardState *HardState // non-nil when it changed: save it first
	// Snapshot, when non-nil, came from the leader: save it, and replace the
	// state machine's state with it. The log before it is gone.
	Snapshot *Snapshot
	// Entries to save, starting at Entries[0].Index. Any saved entries at
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	// log[0] is a placeholder at index 0, term 0, so that every real
	// entry has an entry before it.
	log     []Entry
	commit  uint64 // the highest index known to be committed
	applied uint64 // the highest index handed out to be applied
~~~

to:

~~~go
	// log[0] stands for the last entry covered by the snapshot (index 0,
	// term 0 before there is one), so every real entry has one before it.
	// The entry with index i is at log[i-log[0].Index].
	log      []Entry
	snapshot Snapshot
	commit   uint64 // the highest index known to be committed
	applied  uint64 // the highest index handed out to be applied
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	unsavedFrom uint64 // the lowest log index changed since the last Ready; 0 if none
~~~

to:

~~~go
	unsavedFrom uint64    // the lowest log index changed since the last Ready; 0 if none
	received    *Snapshot // a snapshot from the leader, not yet handed out
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
// Persisted is what a node saved before it stopped: its HardState and its
// log. A new node starts with the zero value.
~~~

to:

~~~go
// Persisted is what a node saved before it stopped: its HardState, its
// latest snapshot, and the log entries after it. A new node starts with the
// zero value.
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	HardState HardState
	Entries   []Entry
~~~

to:

~~~go
	HardState HardState
	Snapshot  Snapshot
	Entries   []Entry
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
// same vote, the same log. Committed entries are handed out to be applied
// again from the start, because the state machine they built was in memory
// and is gone.
func New(cfg Config, saved Persisted) *Node {
	n := &Node{
		cfg:   cfg,
		peers: slices.Sorted(slices.Values(cfg.Peers)),
		log:   append([]Entry{{}}, saved.Entries...),
		term:  saved.HardState.Term,
		vote:  saved.HardState.Vote,
~~~

to:

~~~go
// same vote, the same log. The caller restores the state machine from the
// snapshot; committed entries after it are handed out to be applied again,
// because the state they built was in memory and is gone.
func New(cfg Config, saved Persisted) *Node {
	snap := saved.Snapshot
	n := &Node{
		cfg:      cfg,
		peers:    slices.Sorted(slices.Values(cfg.Peers)),
		log:      append([]Entry{{Index: snap.Index, Term: snap.Term}}, saved.Entries...),
		snapshot: snap,
		term:     saved.HardState.Term,
		vote:     saved.HardState.Vote,
		applied:  snap.Index,
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	n.commit = min(saved.HardState.Commit, n.lastIndex())
~~~

to:

~~~go
	n.commit = max(snap.Index, min(saved.HardState.Commit, n.lastIndex()))
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
func (n *Node) lastIndex() uint64 { return n.log[len(n.log)-1].Index }
func (n *Node) lastTerm() uint64  { return n.log[len(n.log)-1].Term }
~~~

to:

~~~go
func (n *Node) firstIndex() uint64 { return n.log[0].Index } // the snapshot's index
func (n *Node) lastIndex() uint64  { return n.log[len(n.log)-1].Index }
func (n *Node) lastTerm() uint64   { return n.log[len(n.log)-1].Term }
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
// termAt is the term of the entry at index i. It must exist.
func (n *Node) termAt(i uint64) uint64 { return n.log[i].Term }
~~~

to:

~~~go
// termAt is the term of the entry at index i, which must be in the log or
// be the snapshot's last index.
func (n *Node) termAt(i uint64) uint64 { return n.log[i-n.firstIndex()].Term }

// entries returns the entries from index lo to hi inclusive.
func (n *Node) entries(lo, hi uint64) []Entry {
	return slices.Clone(n.log[lo-n.firstIndex() : hi-n.firstIndex()+1])
}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
func (n *Node) sendAppend(to ID) {
	prev := n.next[to] - 1
~~~

to:

~~~go
func (n *Node) sendAppend(to ID) {
	if n.next[to] <= n.firstIndex() {
		// The entries this follower needs were compacted away: send the
		// snapshot instead.
		snap := n.snapshot
		n.send(Message{Type: MsgSnap, To: to, Snapshot: &snap})
		return
	}
	prev := n.next[to] - 1
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
		Entries:  slices.Clone(n.log[prev+1 : last+1]),
~~~

to:

~~~go
		Entries:  n.entries(prev+1, last),
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
		n.handleAppend(m)
	case MsgAppResp:
~~~

to:

~~~go
		n.handleAppend(m)
	case MsgSnap:
		n.becomeFollower(m.Term, m.From)
		n.handleSnapshot(*m.Snapshot)
	case MsgAppResp:
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
func (n *Node) handleAppend(m Message) {
	// The log matching check: we must already have the entry just before
~~~

to:

~~~go
func (n *Node) handleAppend(m Message) {
	if m.LogIndex < n.firstIndex() {
		// The start of this message is inside our snapshot, so it's already
		// committed here. Tell the leader how far we are.
		n.send(Message{Type: MsgAppResp, To: m.From, Match: n.commit})
		return
	}
	// The log matching check: we must already have the entry just before
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
			n.log = n.log[:e.Index]
~~~

to:

~~~go
			n.log = n.log[:e.Index-n.firstIndex()]
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	n.send(Message{Type: MsgAppResp, To: m.From, Match: lastNew})
}
~~~

to:

~~~go
	n.send(Message{Type: MsgAppResp, To: m.From, Match: lastNew})
}

// handleSnapshot replaces the follower's state with the leader's snapshot.
func (n *Node) handleSnapshot(snap Snapshot) {
	if snap.Index <= n.commit {
		// Nothing new: we already have everything it covers.
		n.send(Message{Type: MsgAppResp, To: n.leader, Match: n.commit})
		return
	}
	if snap.Index <= n.lastIndex() && n.termAt(snap.Index) == snap.Term {
		// Our log already contains the snapshot's last entry: keep what
		// comes after it.
		n.log = n.log[snap.Index-n.firstIndex():]
	} else {
		n.log = []Entry{{Index: snap.Index, Term: snap.Term}}
	}
	n.log[0].Data = nil
	n.snapshot = snap
	n.commit, n.applied = snap.Index, snap.Index
	n.received = &snap
	n.send(Message{Type: MsgAppResp, To: n.leader, Match: snap.Index})
}

// Compact tells the node that the state machine's state as of index (which
// must already be applied) is data. Every log entry up to index is dropped.
// The caller must save the returned snapshot, and may then forget those
// entries on disk too.
func (n *Node) Compact(index uint64, data []byte) (Snapshot, error) {
	if index <= n.firstIndex() || index > n.applied {
		return Snapshot{}, fmt.Errorf("raft: cannot compact to %d: snapshot at %d, applied %d", index, n.firstIndex(), n.applied)
	}
	n.snapshot = Snapshot{Index: index, Term: n.termAt(index), Data: data}
	n.log = slices.Clone(n.log[index-n.firstIndex():])
	n.log[0].Data = nil
	return n.snapshot, nil
}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	}
	if n.unsavedFrom > 0 {
		rd.Entries = slices.Clone(n.log[n.unsavedFrom:])
~~~

to:

~~~go
	}
	rd.Snapshot, n.received = n.received, nil
	if n.unsavedFrom > 0 {
		// Changes inside the snapshot need no saving of their own.
		if from := max(n.unsavedFrom, n.firstIndex()+1); from <= n.lastIndex() {
			rd.Entries = n.entries(from, n.lastIndex())
		}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
		rd.Committed = slices.Clone(n.log[n.applied+1 : n.commit+1])
~~~

to:

~~~go
		rd.Committed = n.entries(n.applied+1, n.commit)
~~~


### The bug the simulator found

Here's how this step went the first time. With snapshots switched on in the storm tests, seed 38 stopped converging: four nodes reached index 70, and node 2 stayed at 68 forever, though the network had healed. Tracing the leader's view of node 2 showed `next = 66` but `match = 68`. A rejection from an *old* message had arrived after a newer success, and moved `next` back below what the follower was already known to have. From then on the leader kept deciding node 2 needed entries before its snapshot, sent the snapshot, got "already have it" back, and repeated, forever.

Without snapshots, the same bug had only made the leader resend entries the follower already had: wasteful, but nothing failed, so no test noticed. The rule in `handleAppendResp` that you typed in step 3 (`next` never below `match + 1`) is the fix. Bugs like this are why the storm tests run with every feature switched on together.

There's a second lesson. Later changes shifted the random choices, and today no seed reproduces that stuck state, even with the fix removed. A bug that a random search found once needs a **regression test** that sets up the exact scene on purpose, so it can never quietly come back. Create `internal/raft/progress_test.go`:

<!-- file: internal/raft/progress_test.go -->
~~~go
package raft

import "testing"

// A regression test for a bug the storm tests found once (step 5). A
// rejection from an old message arrived after a newer success, moved next
// below match, and left a follower stuck. Random seeds can't be relied on
// to find it again, so this test sets the scene directly.
func TestALateRejectionNeverMovesNextBelowMatch(t *testing.T) {
	w := newManual(t, 3)
	all := []ID{1, 2, 3}
	w.elect(1, all...)
	w.heartbeat(1, all...)
	for range 5 {
		if _, err := w.nodes[1].Propose([]byte("x")); err != nil {
			t.Fatal(err)
		}
		w.collect(1)
		w.deliver(all...)
	}
	leader := w.nodes[1]
	match := leader.match[2]
	if match < 5 {
		t.Fatalf("node 2's match is %d after five entries", match)
	}

	// A rejection of a message from long ago, in the current term, turns up
	// late: "I don't have the entry before index 1".
	leader.Step(Message{Type: MsgAppResp, From: 2, To: 1, Term: leader.term, Reject: true, Match: 0})
	if next := leader.next[2]; next < match+1 {
		t.Fatalf("next = %d after a late rejection, below match+1 = %d", next, match+1)
	}
}
~~~

### Snapshots in the simulator

The simulated state machine is the list of applied data, so its snapshot is that list encoded as JSON. Nodes compact every `SnapshotEvery` entries. The disk drops covered entries when it saves a snapshot, following the "same history" rule above.

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
import (
	"fmt"
~~~

to:

~~~go
import (
	"encoding/json"
	"fmt"
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	CrashChance float64

~~~

to:

~~~go
	CrashChance float64
	// SnapshotEvery makes a node compact its log once it has applied this
	// many entries since its last snapshot. Zero means never.
	SnapshotEvery int
	SnapshotsSent int // how many snapshots leaders have sent

~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	applied   [][]string            // each node's applied data, in order (index 0 unused)
	err       error
~~~

to:

~~~go
	applied   [][]string            // each node's applied data, in order (index 0 unused)
	lastApply []uint64              // the index each node last applied
	err       error
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
		applied:   make([][]string, n+1),
	}
~~~

to:

~~~go
		applied:   make([][]string, n+1),
		lastApply: make([]uint64, n+1),
	}
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	}
	if len(rd.Entries) > 0 {
~~~

to:

~~~go
	}
	if rd.Snapshot != nil {
		d.saveSnapshot(*rd.Snapshot)
	}
	if len(rd.Entries) > 0 {
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
		d.state.Entries = append(d.state.Entries[:first-1], rd.Entries...)
	}
}

~~~

to:

~~~go
		d.state.Entries = append(d.state.Entries[:first-d.state.Snapshot.Index-1], rd.Entries...)
	}
}

// saveSnapshot saves snap and drops the entries it covers. If the saved log
// doesn't contain snap's last entry, the entries after it belong to a
// different history, and go too.
func (d *Disk) saveSnapshot(snap raft.Snapshot) {
	var keep []raft.Entry
	for i, e := range d.state.Entries {
		if e.Index == snap.Index && e.Term == snap.Term {
			keep = d.state.Entries[i+1:]
		}
	}
	d.state.Snapshot = snap
	d.state.Entries = append([]raft.Entry(nil), keep...)
}

~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	for _, m := range rd.Messages {
		c.Net.Send(int(m.From), int(m.To), m)
	}
~~~

to:

~~~go
	for _, m := range rd.Messages {
		if m.Type == raft.MsgSnap {
			c.SnapshotsSent++
		}
		c.Net.Send(int(m.From), int(m.To), m)
	}
	if rd.Snapshot != nil {
		c.restore(id, *rd.Snapshot)
	}
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	}
	c.check(id)
}
~~~

to:

~~~go
	}
	c.maybeCompact(id)
	c.check(id)
}

// The simulated state machine is just the list of applied data, so a
// snapshot of it is that list, encoded.
func (c *Cluster) restore(id raft.ID, snap raft.Snapshot) {
	c.applied[id] = nil
	if snap.Data != nil {
		if err := json.Unmarshal(snap.Data, &c.applied[id]); err != nil {
			c.fail("node %d: bad snapshot: %v", id, err)
		}
	}
	c.lastApply[id] = snap.Index
}

func (c *Cluster) maybeCompact(id raft.ID) {
	first := c.disks[id].state.Snapshot.Index
	if c.SnapshotEvery == 0 || c.lastApply[id]-first < uint64(c.SnapshotEvery) {
		return
	}
	data, _ := json.Marshal(c.applied[id])
	snap, err := c.nodes[id].Compact(c.lastApply[id], data)
	if err != nil {
		c.fail("node %d: %v", id, err)
		return
	}
	c.disks[id].saveSnapshot(snap)
}
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
		c.applied[id] = append(c.applied[id], string(e.Data))
	}
}

~~~

to:

~~~go
		c.applied[id] = append(c.applied[id], string(e.Data))
	}
	c.lastApply[id] = e.Index
}

~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	c.nodes[id] = raft.New(c.config(id), c.disks[id].state)
	c.applied[id] = nil
~~~

to:

~~~go
	saved := c.disks[id].state
	saved.Entries = append([]raft.Entry(nil), saved.Entries...)
	c.nodes[id] = raft.New(c.config(id), saved)
	c.restore(id, saved.Snapshot)
~~~


Switch snapshots on in the storm tests. In `internal/raft/raftsim/persistence_test.go`:

Change:

<!-- edit: internal/raft/raftsim/persistence_test.go -->
~~~go
		c.CrashChance = 0.01
		proposed := 0
~~~

to:

~~~go
		c.CrashChance = 0.01
		c.SnapshotEvery = 5
		proposed := 0
~~~

Change:

<!-- edit: internal/raft/raftsim/persistence_test.go -->
~~~go
		c.CrashChance = 0.01
		for range 30 {
~~~

to:

~~~go
		c.CrashChance = 0.01
		c.SnapshotEvery = 5
		for range 30 {
~~~


and in `internal/raft/raftsim/replication_test.go`:

Change:

<!-- edit: internal/raft/raftsim/replication_test.go -->
~~~go
		c.Net.SetDropRate(0.1)
		proposed := 0
~~~

to:

~~~go
		c.Net.SetDropRate(0.1)
		c.SnapshotEvery = 5
		proposed := 0
~~~


Create `internal/raft/raftsim/snapshot_test.go`:

<!-- file: internal/raft/raftsim/snapshot_test.go -->
~~~go
package raftsim

import (
	"fmt"
	"slices"
	"testing"

	"runway/internal/raft"
)

// A follower that was away while the log was compacted can't be sent the
// entries it missed: they're gone. It gets the snapshot instead.
func TestALaggingFollowerIsSentASnapshot(t *testing.T) {
	c := New(3, 5)
	c.SnapshotEvery = 10
	leader := elect(t, c)
	behind := leader%3 + 1
	var rest []raft.ID
	for _, id := range c.IDs() {
		if id != behind {
			rest = append(rest, id)
		}
	}
	c.Partition([]raft.ID{behind}, rest)
	for i := range 50 {
		c.Propose(fmt.Sprint("v", i))
		c.Run(2)
	}
	c.Run(50)
	c.Heal()
	c.Run(100)

	if c.SnapshotsSent == 0 {
		t.Fatal("no snapshot was sent")
	}
	if got, want := c.Applied(behind), c.Applied(leader); len(want) != 50 || !slices.Equal(got, want) {
		t.Fatalf("the follower has %d entries, the leader %d", len(got), len(want))
	}
	if err := c.Err(); err != nil {
		t.Fatal(err)
	}
}

// A node restarts from its snapshot plus the entries saved after it.
func TestARestartBeginsFromTheSnapshot(t *testing.T) {
	c := New(3, 6)
	c.SnapshotEvery = 10
	elect(t, c)
	for i := range 25 {
		c.Propose(fmt.Sprint("v", i))
		c.Run(2)
	}
	c.Run(50)
	for _, id := range c.IDs() {
		if c.disks[id].state.Snapshot.Index == 0 {
			t.Fatalf("node %d never took a snapshot", id)
		}
		c.Crash(id)
		c.Restart(id)
	}
	c.Run(100)
	for _, id := range c.IDs() {
		if got := len(c.Applied(id)); got != 25 {
			t.Errorf("node %d has %d entries after restarting, want 25", id, got)
		}
	}
	if err := c.Err(); err != nil {
		t.Fatal(err)
	}
}
~~~

### Snapshots on disk

The write-ahead log now manages a directory holding two files, `raft.wal` and `snapshot`. `SaveSnapshot` replaces the snapshot atomically, then rewrites the log without the entries it covers, also atomically. `Open` reads the snapshot first, replays the log, and keeps only the entries that follow the snapshot. The changes reach almost every function, so replace `internal/raft/raftwal/raftwal.go` with:

<!-- file: internal/raft/raftwal/raftwal.go -->
~~~go
// Package raftwal saves a Raft node's state in a directory holding two
// files, in the record format of the Rust Bridge's klog (a length, a
// CRC-32C checksum, then the payload):
//
//	raft.wal   a write-ahead log, only ever appended to
//	snapshot   the latest snapshot, replaced atomically
//
// The log holds two kinds of record. A HardState record replaces the one
// before it. An Entry record with index i replaces every saved entry at i
// or later, which is how a follower's truncated log is saved without ever
// rewriting the file. Replaying the file in order rebuilds the state.
package raftwal

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"path/filepath"

	"runway/internal/raft"
)

const (
	kindHardState = 1
	kindEntry     = 2
	kindSnapshot  = 3
	headerSize    = 8 // 4-byte length, 4-byte CRC-32C
)

var castagnoli = crc32.MakeTable(crc32.Castagnoli)

// ErrCorrupt means a record before the end of the file is damaged. A
// damaged *last* record is a write torn by a crash, and is cut off instead.
var ErrCorrupt = errors.New("write-ahead log is corrupt")

// WAL is an open state directory.
type WAL struct {
	dir   string
	f     *os.File
	w     *bufio.Writer
	state raft.Persisted // everything saved so far, for rewriting the log
}

// Open opens or creates the state in dir and replays it.
func Open(dir string) (*WAL, raft.Persisted, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, raft.Persisted{}, err
	}
	snap, err := readSnapshot(filepath.Join(dir, "snapshot"))
	if err != nil {
		return nil, raft.Persisted{}, err
	}
	f, err := os.OpenFile(filepath.Join(dir, "raft.wal"), os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, raft.Persisted{}, err
	}
	hs, entries, valid, err := replay(f)
	if err != nil {
		f.Close()
		return nil, raft.Persisted{}, err
	}
	// Cut off a torn tail, and make the cut itself durable.
	if err := f.Truncate(valid); err != nil {
		f.Close()
		return nil, raft.Persisted{}, err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return nil, raft.Persisted{}, err
	}
	if _, err := f.Seek(valid, io.SeekStart); err != nil {
		f.Close()
		return nil, raft.Persisted{}, err
	}
	state := raft.Persisted{HardState: hs, Snapshot: snap, Entries: after(snap, entries)}
	return &WAL{dir: dir, f: f, w: bufio.NewWriter(f), state: state}, clone(state), nil
}

// after returns the entries that follow snap. If the log holds snap's last
// entry with a different term, everything after it came from a different
// history and is dropped. (A crash between saving a snapshot and rewriting
// the log can leave entries the snapshot already covers.)
func after(snap raft.Snapshot, entries []raft.Entry) []raft.Entry {
	for i, e := range entries {
		switch {
		case e.Index < snap.Index:
			continue
		case e.Index == snap.Index && e.Term == snap.Term:
			return entries[i+1:]
		case e.Index == snap.Index:
			return nil
		default: // the log starts after the snapshot
			return entries[i:]
		}
	}
	return nil
}

// Save writes a Ready's snapshot, entries and HardState, then waits until
// they are on disk. Only after Save returns may the node's messages be
// sent.
func (w *WAL) Save(hs *raft.HardState, snap *raft.Snapshot, entries []raft.Entry) error {
	if snap != nil {
		if err := w.SaveSnapshot(*snap); err != nil {
			return err
		}
	}
	if hs == nil && len(entries) == 0 {
		return nil
	}
	for _, e := range entries {
		if err := w.write(kindEntry, encodeEntry(e)); err != nil {
			return err
		}
	}
	if hs != nil {
		if err := w.write(kindHardState, encodeHardState(*hs)); err != nil {
			return err
		}
	}
	if err := w.w.Flush(); err != nil {
		return err
	}
	if err := w.f.Sync(); err != nil {
		return err
	}
	w.remember(hs, entries)
	return nil
}

func (w *WAL) remember(hs *raft.HardState, entries []raft.Entry) {
	if hs != nil {
		w.state.HardState = *hs
	}
	if len(entries) > 0 {
		first := entries[0].Index - w.state.Snapshot.Index - 1
		w.state.Entries = append(w.state.Entries[:first], entries...)
	}
}

// SaveSnapshot replaces the snapshot, then rewrites the log without the
// entries the snapshot covers. Each file is replaced atomically: written
// in full under a temporary name, synced, then renamed over the old one. A
// crash at any moment leaves either the old file or the new one, never a
// mixture.
func (w *WAL) SaveSnapshot(snap raft.Snapshot) error {
	if err := w.replace("snapshot", func(b *bufio.Writer) error {
		return writeRecord(b, kindSnapshot, encodeSnapshot(snap))
	}); err != nil {
		return err
	}
	w.state.Entries = after(snap, w.state.Entries)
	w.state.Snapshot = snap
	state := w.state
	if err := w.replace("raft.wal", func(b *bufio.Writer) error {
		for _, e := range state.Entries {
			if err := writeRecord(b, kindEntry, encodeEntry(e)); err != nil {
				return err
			}
		}
		return writeRecord(b, kindHardState, encodeHardState(state.HardState))
	}); err != nil {
		return err
	}
	// Carry on appending to the new log.
	if err := w.f.Close(); err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(w.dir, "raft.wal"), os.O_RDWR|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	w.f, w.w = f, bufio.NewWriter(f)
	return nil
}

// replace atomically replaces the file name in the directory with what
// fill writes.
func (w *WAL) replace(name string, fill func(*bufio.Writer) error) error {
	tmp := filepath.Join(w.dir, name+".tmp")
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	b := bufio.NewWriter(f)
	if err := fill(b); err != nil {
		f.Close()
		return err
	}
	if err := b.Flush(); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, filepath.Join(w.dir, name)); err != nil {
		return err
	}
	// The rename is a change to the directory: sync the directory too, or
	// a crash could forget it.
	d, err := os.Open(w.dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func (w *WAL) Close() error {
	if err := w.w.Flush(); err != nil {
		w.f.Close()
		return err
	}
	return w.f.Close()
}

func (w *WAL) write(kind byte, payload []byte) error { return writeRecord(w.w, kind, payload) }

func writeRecord(b *bufio.Writer, kind byte, payload []byte) error {
	body := append([]byte{kind}, payload...)
	var header [headerSize]byte
	binary.LittleEndian.PutUint32(header[0:4], uint32(len(body)))
	binary.LittleEndian.PutUint32(header[4:8], crc32.Checksum(body, castagnoli))
	if _, err := b.Write(header[:]); err != nil {
		return err
	}
	_, err := b.Write(body)
	return err
}

// replay reads every record of the log, and returns the HardState, the
// entries, and the length of the valid part of the file.
func replay(f *os.File) (raft.HardState, []raft.Entry, int64, error) {
	data, err := io.ReadAll(f)
	if err != nil {
		return raft.HardState{}, nil, 0, err
	}
	var hs raft.HardState
	var entries []raft.Entry
	offset := 0
	for offset < len(data) {
		body, n, ok := decode(data[offset:])
		if !ok {
			// A damaged record with whole records after it is real damage.
			// One at the very end is a write torn by a crash: stop here,
			// and Open cuts it off.
			if n > 0 && offset+n < len(data) {
				return raft.HardState{}, nil, 0, fmt.Errorf("%w at byte %d", ErrCorrupt, offset)
			}
			break
		}
		switch body[0] {
		case kindHardState:
			hs = decodeHardState(body[1:])
		case kindEntry:
			e := decodeEntry(body[1:])
			if len(entries) > 0 {
				first := entries[0].Index
				if e.Index < first || e.Index > first+uint64(len(entries)) {
					return raft.HardState{}, nil, 0, fmt.Errorf("%w: entry %d doesn't follow entries %d to %d",
						ErrCorrupt, e.Index, first, first+uint64(len(entries))-1)
				}
				entries = entries[:e.Index-first]
			}
			entries = append(entries, e)
		default:
			return raft.HardState{}, nil, 0, fmt.Errorf("%w: unknown record kind %d", ErrCorrupt, body[0])
		}
		offset += n
	}
	return hs, entries, int64(offset), nil
}

func readSnapshot(path string) (raft.Snapshot, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return raft.Snapshot{}, nil
	}
	if err != nil {
		return raft.Snapshot{}, err
	}
	body, _, ok := decode(data)
	if !ok || body[0] != kindSnapshot {
		// The file was written in full before it was renamed into place, so
		// any damage here is real.
		return raft.Snapshot{}, fmt.Errorf("%w: bad snapshot file", ErrCorrupt)
	}
	return decodeSnapshot(body[1:]), nil
}

// decode reads one record from the start of data. It returns its body, the
// record's total length, and whether it is whole and its checksum matches.
// For a record cut short, n is 0.
func decode(data []byte) (body []byte, n int, ok bool) {
	if len(data) < headerSize {
		return nil, 0, false
	}
	size := int(binary.LittleEndian.Uint32(data[0:4]))
	if size == 0 || len(data) < headerSize+size {
		return nil, 0, false
	}
	body = data[headerSize : headerSize+size]
	if crc32.Checksum(body, castagnoli) != binary.LittleEndian.Uint32(data[4:8]) {
		return nil, headerSize + size, false
	}
	return body, headerSize + size, true
}

func clone(s raft.Persisted) raft.Persisted {
	s.Entries = append([]raft.Entry(nil), s.Entries...)
	return s
}

func encodeHardState(hs raft.HardState) []byte {
	b := make([]byte, 24)
	binary.LittleEndian.PutUint64(b[0:], hs.Term)
	binary.LittleEndian.PutUint64(b[8:], uint64(hs.Vote))
	binary.LittleEndian.PutUint64(b[16:], hs.Commit)
	return b
}

func decodeHardState(b []byte) raft.HardState {
	return raft.HardState{
		Term:   binary.LittleEndian.Uint64(b[0:]),
		Vote:   raft.ID(binary.LittleEndian.Uint64(b[8:])),
		Commit: binary.LittleEndian.Uint64(b[16:]),
	}
}

func encodeEntry(e raft.Entry) []byte {
	b := make([]byte, 16, 16+len(e.Data))
	binary.LittleEndian.PutUint64(b[0:], e.Term)
	binary.LittleEndian.PutUint64(b[8:], e.Index)
	return append(b, e.Data...)
}

func decodeEntry(b []byte) raft.Entry {
	e := raft.Entry{Term: binary.LittleEndian.Uint64(b[0:]), Index: binary.LittleEndian.Uint64(b[8:])}
	if len(b) > 16 {
		e.Data = append([]byte(nil), b[16:]...)
	}
	return e
}

func encodeSnapshot(s raft.Snapshot) []byte {
	return encodeEntry(raft.Entry{Term: s.Term, Index: s.Index, Data: s.Data})
}

func decodeSnapshot(b []byte) raft.Snapshot {
	e := decodeEntry(b)
	return raft.Snapshot{Index: e.Index, Term: e.Term, Data: e.Data}
}
~~~

`replace` is the atomic-file pattern in full: temporary file, flush, `Sync`, `Close`, `Rename`, then `Sync` on the directory. `after` encodes the "same history" rule, and it's used both when installing a snapshot and when opening after a crash.

`Save` now takes a snapshot too. Update the tests, and add three for snapshots. In `internal/raft/raftwal/raftwal_test.go`:

Change:

<!-- edit: internal/raft/raftwal/raftwal_test.go -->
~~~go
import (
	"errors"
~~~

to:

~~~go
import (
	"bufio"
	"errors"
~~~

Change:

<!-- edit: internal/raft/raftwal/raftwal_test.go -->
~~~go
	if err := w.Save(&hs, entries(1, 1, 3)); err != nil {
~~~

to:

~~~go
	if err := w.Save(&hs, nil, entries(1, 1, 3)); err != nil {
~~~

Change:

<!-- edit: internal/raft/raftwal/raftwal_test.go -->
~~~go
	_ = w.Save(nil, entries(1, 1, 5))
	_ = w.Save(&raft.HardState{Term: 2}, entries(2, 3, 3))
~~~

to:

~~~go
	_ = w.Save(nil, nil, entries(1, 1, 5))
	_ = w.Save(&raft.HardState{Term: 2}, nil, entries(2, 3, 3))
~~~

Change:

<!-- edit: internal/raft/raftwal/raftwal_test.go -->
~~~go
	_ = w.Save(&raft.HardState{Term: 1, Vote: 1}, entries(1, 1, 2))
~~~

to:

~~~go
	_ = w.Save(&raft.HardState{Term: 1, Vote: 1}, nil, entries(1, 1, 2))
~~~

Change:

<!-- edit: internal/raft/raftwal/raftwal_test.go -->
~~~go
	_ = w.Save(nil, entries(1, 3, 3))
~~~

to:

~~~go
	_ = w.Save(nil, nil, entries(1, 3, 3))
~~~

Change:

<!-- edit: internal/raft/raftwal/raftwal_test.go -->
~~~go
	_ = w.Save(nil, entries(1, 1, 3))
~~~

to:

~~~go
	_ = w.Save(nil, nil, entries(1, 1, 3))
~~~

Add this at the end of the file:

<!-- append: internal/raft/raftwal/raftwal_test.go -->
~~~go
// A snapshot replaces the entries it covers, on disk too.
func TestASnapshotCompactsTheLog(t *testing.T) {
	dir := t.TempDir()
	w, _, _ := Open(dir)
	hs := raft.HardState{Term: 1, Commit: 10}
	_ = w.Save(&hs, nil, entries(1, 1, 10))
	before, _ := os.Stat(filepath.Join(dir, "raft.wal"))
	if err := w.SaveSnapshot(raft.Snapshot{Index: 8, Term: 1, Data: []byte("state at 8")}); err != nil {
		t.Fatal(err)
	}
	_ = w.Save(nil, nil, entries(1, 11, 11))
	w.Close()
	compacted, _ := os.Stat(filepath.Join(dir, "raft.wal"))
	if compacted.Size() >= before.Size() {
		t.Fatalf("the log grew from %d to %d bytes; the snapshot should have shrunk it", before.Size(), compacted.Size())
	}

	got := reopen(t, dir)
	want := raft.Persisted{
		HardState: hs,
		Snapshot:  raft.Snapshot{Index: 8, Term: 1, Data: []byte("state at 8")},
		Entries:   append(entries(1, 9, 10), entries(1, 11, 11)...),
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("after reopening:\n got %+v\nwant %+v", got, want)
	}
}

// A snapshot from the leader whose last entry isn't in our log replaces
// the log entirely: what we had after it was from a different history.
func TestASnapshotFromAnotherHistoryDropsTheLog(t *testing.T) {
	dir := t.TempDir()
	w, _, _ := Open(dir)
	_ = w.Save(&raft.HardState{Term: 3}, nil, entries(1, 1, 6))
	_ = w.Save(nil, &raft.Snapshot{Index: 5, Term: 2, Data: []byte("leader's state")}, nil)
	w.Close()
	if got := reopen(t, dir).Entries; len(got) != 0 {
		t.Fatalf("kept %d entries from the other history", len(got))
	}
}

// A crash after the new snapshot is in place but before the log was
// rewritten leaves the old log next to the new snapshot. Opening must
// still give the right state.
func TestACrashBetweenSnapshotAndLogRewrite(t *testing.T) {
	dir := t.TempDir()
	w, _, _ := Open(dir)
	_ = w.Save(&raft.HardState{Term: 1, Commit: 6}, nil, entries(1, 1, 6))
	w.Close()
	// Write only the snapshot, as if the process died straight after.
	w2 := &WAL{dir: dir}
	if err := w2.replace("snapshot", func(b *bufio.Writer) error {
		return writeRecord(b, kindSnapshot, encodeSnapshot(raft.Snapshot{Index: 4, Term: 1}))
	}); err != nil {
		t.Fatal(err)
	}

	got := reopen(t, dir)
	if got.Snapshot.Index != 4 || !reflect.DeepEqual(got.Entries, entries(1, 5, 6)) {
		t.Fatalf("snapshot %d, entries %+v; want snapshot 4 and entries 5 and 6", got.Snapshot.Index, got.Entries)
	}
}
~~~


The last test writes the new snapshot and then stops, exactly as a crash between the two steps would leave things. Then it checks that opening the directory still gives the right state.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/raft/... && go test -race -count=1 ./internal/raft/... -->

~~~bash
go test -v ./internal/raft/raftsim/ ./internal/raft/raftwal/
~~~

~~~text
...
--- PASS: TestStateMachineSafetyUnderChaos (1.42s)
--- PASS: TestALaggingFollowerIsSentASnapshot (0.00s)
--- PASS: TestARestartBeginsFromTheSnapshot (0.00s)
ok  	runway/internal/raft/raftsim	5.159s
...
--- PASS: TestASnapshotCompactsTheLog (0.03s)
--- PASS: TestASnapshotFromAnotherHistoryDropsTheLog (0.02s)
--- PASS: TestACrashBetweenSnapshotAndLogRewrite (0.02s)
ok  	runway/internal/raft/raftwal	0.135s
~~~

**Break it: the bug, again.** In `handleAppendResp`, change the rejection line back to the naive version, `n.next[m.From] = max(1, min(n.next[m.From]-1, m.Match+1))`:

~~~text
--- FAIL: TestALateRejectionNeverMovesNextBelowMatch (0.00s)
    progress_test.go:31: next = 1 after a late rejection, below match+1 = 7
~~~

The storm tests still pass with this line, as explained above; the regression test doesn't. Restore it.

**Explain it:** what does a snapshot replace, and who makes it? When does a follower keep its entries after installing a snapshot, and when must it drop them? Why does replacing a file atomically need a rename *and* an `fsync` of the directory? Explain the `next`/`match` bug in your own words.

**Read.** The Raft paper, §7 (log compaction). Then Pillai et al., *All File Systems Are Not Created Equal* (OSDI 2014), §1–3, on what applications get wrong about crash consistency. Carry this question in: which of the paper's mistakes does `replace` avoid, and how?

---

## Step 6: Partial partitions, PreVote and CheckQuorum

**The problem.** Raft as built so far is *safe* under any partition. Under some partitions, though, it's barely **available**. Two cases:

1. **The disruptive returner.** A node cut off from everyone keeps timing out and starting elections it can't win, raising its term each time: 23, say. When the network heals, its first message carries term 23. The working leader, still in term 1, sees a higher term and steps down. The whole cluster pays for a node that was simply away.
2. **The partial partition.** The link between the leader and one follower breaks, both ways, but the third node still reaches both. The cut-off follower stops hearing heartbeats, stands for election in a higher term, and the middle node carries that term to the leader, which steps down. Then the other side's link is the broken one, and it happens again. Leaders keep being deposed even though a majority could talk perfectly well.

Partial partitions aren't exotic. Research on real outages found network-partitioning failures throughout widely used systems, partial ones especially (Alquraan et al., *An Analysis of Network-Partitioning Failures in Cloud Systems*, OSDI 2018, from Samer Al-Kiswany's group at Waterloo).

**New ideas.**

- **PreVote** (Ongaro's thesis, §9.6). Before starting a real election, a node asks "*would* you vote for me in the next term?" without changing anyone's term, its own included. A peer says yes only if the asker's log is up to date **and the peer hasn't heard from a leader recently**. A node that's merely cut off gets refused by everyone who still hears the leader, so it never raises its term and can't disrupt anything.
- **CheckQuorum.** A leader that hasn't heard from a majority within an election timeout steps down. A leader cut off on the minority side stops believing it leads, so clients connected to it stop waiting for answers that can't come.
- **What they fix, and what they don't.** These two handle the cases above. Partial partitions in general remain an open problem: Alfatafta et al., *Toward a Generic Fault Tolerance Technique for Partial Network Partitioning* (OSDI 2020, also Al-Kiswany's group), show systems failing under shapes these mechanisms don't cover. The [KESTREL capstone](../../capstones/01-kestrel.md) starts from exactly here.

### PreVote and CheckQuorum in the core

The changes to `internal/raft/raft.go`:
1. A new role, `PreCandidate`, and two messages, `MsgPreVote` and `MsgPreVoteResp`.
2. Two settings, `PreVote` and `CheckQuorum`.
3. **`Tick`**: a follower whose election timer runs out starts a pre-campaign if `PreVote` is on. A leader counts its own election timer and, every election timeout, runs `checkQuorum`.
4. **`Step`**: pre-vote requests never change anyone's term (`handlePreVote` answers without touching state), and a *granted* pre-vote response carries the term the candidate *would* stand in, so it isn't a reason to change terms either. A leader records every peer it hears from in `active`.
5. Counting votes moves into `countVote`, shared by real and pre-votes. A pre-candidate that wins its pre-vote starts the real campaign.

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	Follower Role = iota
	Candidate
~~~

to:

~~~go
	Follower Role = iota
	PreCandidate
	Candidate
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	return [...]string{"follower", "candidate", "leader"}[r]
~~~

to:

~~~go
	return [...]string{"follower", "pre-candidate", "candidate", "leader"}[r]
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	MsgVote     MsgType = iota + 1 // RequestVote: "elect me"
	MsgVoteResp                    // the answer
	MsgApp                         // AppendEntries, also the leader's heartbeat
	MsgAppResp                     // the answer
	MsgSnap                        // InstallSnapshot: "start from this state"
~~~

to:

~~~go
	MsgVote        MsgType = iota + 1 // RequestVote: "elect me"
	MsgVoteResp                       // the answer
	MsgApp                            // AppendEntries, also the leader's heartbeat
	MsgAppResp                        // the answer
	MsgSnap                           // InstallSnapshot: "start from this state"
	MsgPreVote                        // "would you vote for me?", asked without changing terms
	MsgPreVoteResp                    // the answer
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	Rand *rand.Rand
}
~~~

to:

~~~go
	Rand *rand.Rand
	// PreVote makes a node ask whether it *could* win before it starts a
	// real election. Peers that still hear from a leader say no, so a node
	// that is merely cut off can't drive the term up and depose a working
	// leader (Ongaro's thesis, §9.6).
	PreVote bool
	// CheckQuorum makes a leader step down if it hasn't heard from a
	// majority within an election timeout, so a leader cut off from the
	// majority stops believing it leads.
	CheckQuorum bool
}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	votes            map[ID]bool

~~~

to:

~~~go
	votes            map[ID]bool
	active           map[ID]bool // leader only: peers heard from since the last quorum check

~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
			n.broadcastHeartbeat()
		}
		return
	}
~~~

to:

~~~go
			n.broadcastHeartbeat()
		}
		n.electionElapsed++
		if n.cfg.CheckQuorum && n.electionElapsed >= n.cfg.ElectionTick {
			n.electionElapsed = 0
			n.checkQuorum()
		}
		return
	}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	if n.electionElapsed >= n.electionTimeout {
		n.campaign()
	}
~~~

to:

~~~go
	if n.electionElapsed >= n.electionTimeout {
		if n.cfg.PreVote {
			n.preCampaign()
		} else {
			n.campaign()
		}
	}
}

// checkQuorum steps down a leader that hasn't heard from a majority since
// the last check.
func (n *Node) checkQuorum() {
	heard := 1 // itself
	for _, p := range n.peers {
		if p != n.cfg.ID && n.active[p] {
			heard++
		}
	}
	n.active = map[ID]bool{}
	if heard < n.quorum() {
		n.becomeFollower(n.term, None)
	}
}

// preCampaign asks the others whether they would vote for this node in the
// next term, without starting that term.
func (n *Node) preCampaign() {
	n.role = PreCandidate
	n.leader = None
	n.votes = map[ID]bool{n.cfg.ID: true}
	n.resetElectionTimer()
	if n.quorum() == 1 {
		n.campaign()
		return
	}
	for _, p := range n.peers {
		if p != n.cfg.ID {
			n.msgs = append(n.msgs, Message{Type: MsgPreVote, From: n.cfg.ID, To: p, Term: n.term + 1,
				LogIndex: n.lastIndex(), LogTerm: n.lastTerm()})
		}
	}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
	n.heartbeatElapsed = 0
	n.next, n.match = map[ID]uint64{}, map[ID]uint64{}
~~~

to:

~~~go
	n.heartbeatElapsed = 0
	n.electionElapsed = 0
	n.active = map[ID]bool{}
	n.next, n.match = map[ID]uint64{}, map[ID]uint64{}
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
func (n *Node) Step(m Message) {
	switch {
	case m.Term > n.term:
~~~

to:

~~~go
func (n *Node) Step(m Message) {
	if n.role == Leader {
		n.active[m.From] = true
	}
	switch {
	case m.Type == MsgPreVote:
		n.handlePreVote(m)
		return
	case m.Type == MsgPreVoteResp && !m.Reject && m.Term == n.term+1:
		// A granted pre-vote carries the term we'd stand in, not a term
		// anyone is in. It's not a reason to change terms.
	case m.Term > n.term:
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
		if n.role != Candidate {
			return
~~~

to:

~~~go
		if n.role == Candidate && n.countVote(m) {
			n.becomeLeader()
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
		n.votes[m.From] = !m.Reject
		granted := 0
		for _, ok := range n.votes {
			if ok {
				granted++
			}
		}
		if granted >= n.quorum() {
			n.becomeLeader()
~~~

to:

~~~go
	case MsgPreVoteResp:
		if n.role == PreCandidate && n.countVote(m) {
			n.campaign() // a majority would vote for us: now stand for real
~~~

Change:

<!-- edit: internal/raft/raft.go -->
~~~go
			n.handleAppendResp(m)
		}
	}
}

// handleAppend is the follower's side of log replication.
~~~

to:

~~~go
			n.handleAppendResp(m)
		}
	}
}

// countVote records a vote and reports whether a majority has granted.
func (n *Node) countVote(m Message) bool {
	n.votes[m.From] = !m.Reject
	granted := 0
	for _, ok := range n.votes {
		if ok {
			granted++
		}
	}
	return granted >= n.quorum()
}

// handlePreVote answers "would you vote for me in term m.Term?" It changes
// nothing here: not the term, not the vote. The answer is no if the term
// isn't newer, if the asker's log is behind, or if this node has heard from
// a leader within the election timeout: that leader is still working.
func (n *Node) handlePreVote(m Message) {
	upToDate := m.LogTerm > n.lastTerm() || (m.LogTerm == n.lastTerm() && m.LogIndex >= n.lastIndex())
	heardFromLeader := n.leader != None && n.electionElapsed < n.cfg.ElectionTick
	grant := m.Term > n.term && upToDate && !heardFromLeader
	resp := Message{Type: MsgPreVoteResp, From: n.cfg.ID, To: m.From, Term: n.term, Reject: !grant}
	if grant {
		resp.Term = m.Term
	}
	n.msgs = append(n.msgs, resp)
}

// handleAppend is the follower's side of log replication.
~~~


The key line is in `handlePreVote`: `heardFromLeader := n.leader != None && n.electionElapsed < n.cfg.ElectionTick`. A node that heard from a leader within the last election timeout has a working leader, and refuses to help anyone replace it.

### A switch in the simulator

The simulator gets options: `WithPreVote()` switches on both mechanisms. It also counts elections, which is how the tests below measure disruption.

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	disks []*Disk      // what each node has saved; survives crashes
	down  map[raft.ID]bool
~~~

to:

~~~go
	disks []*Disk      // what each node has saved; survives crashes
	opts  []Option
	down  map[raft.ID]bool
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	leaders   map[uint64]raft.ID    // who led each term: election safety
	committed map[uint64]raft.Entry // the entry applied at each index: state machine safety
~~~

to:

~~~go
	leaders   map[uint64]raft.ID    // who led each term: election safety
	elections int                   // how many times a node became leader
	committed map[uint64]raft.Entry // the entry applied at each index: state machine safety
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go

// New builds a cluster whose every random choice comes from seed.
func New(n int, seed uint64) *Cluster {
~~~

to:

~~~go

// Option changes every node's configuration.
type Option func(*raft.Config)

// WithPreVote turns on PreVote and CheckQuorum on every node.
func WithPreVote() Option {
	return func(cfg *raft.Config) { cfg.PreVote, cfg.CheckQuorum = true, true }
}

// New builds a cluster whose every random choice comes from seed.
func New(n int, seed uint64, opts ...Option) *Cluster {
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
		lastApply: make([]uint64, n+1),
	}
~~~

to:

~~~go
		lastApply: make([]uint64, n+1),
		opts:      opts,
	}
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	return raft.Config{
~~~

to:

~~~go
	cfg := raft.Config{
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
		Rand: rand.New(rand.NewPCG(c.rng.Uint64(), c.rng.Uint64())),
	}
}

~~~

to:

~~~go
		Rand: rand.New(rand.NewPCG(c.rng.Uint64(), c.rng.Uint64())),
	}
	for _, opt := range c.opts {
		opt(&cfg)
	}
	return cfg
}

~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	}
	c.leaders[st.Term] = id
~~~

to:

~~~go
	}
	if _, ok := c.leaders[st.Term]; !ok {
		c.elections++
	}
	c.leaders[st.Term] = id
~~~

Change:

<!-- edit: internal/raft/raftsim/raftsim.go -->
~~~go
	}
}

// Err is the first safety violation seen, or nil.
~~~

to:

~~~go
	}
}

// Elections is how many terms have had a leader so far.
func (c *Cluster) Elections() int { return c.elections }

// Err is the first safety violation seen, or nil.
~~~


Create `internal/raft/raftsim/partial_test.go`:

<!-- file: internal/raft/raftsim/partial_test.go -->
~~~go
package raftsim

import (
	"fmt"
	"testing"

	"runway/internal/raft"
)

// partial cuts the link between the leader and one follower, both ways.
// The third node still reaches both. It returns the middle node.
func partial(t *testing.T, c *Cluster) raft.ID {
	t.Helper()
	leader := elect(t, c)
	var others []raft.ID
	for _, id := range c.IDs() {
		if id != leader {
			others = append(others, id)
		}
	}
	c.Net.Cut(int(leader), int(others[1]))
	c.Net.Cut(int(others[1]), int(leader))
	return others[0]
}

// The cut-off follower stops hearing from the leader, stands for election
// in a higher term, and the middle node carries that term to the leader,
// which steps down. Then it happens the other way round.
func TestAPartialPartitionKeepsDeposingLeaders(t *testing.T) {
	c := New(3, 2)
	middle := partial(t, c)
	before := c.Elections()
	for i := range 100 {
		c.Propose(fmt.Sprint("v", i))
		c.Run(20)
	}
	elections := c.Elections() - before
	t.Logf("%d elections in 2000 ticks, term %d, %d of 100 proposals applied",
		elections, c.Node(middle).Status().Term, len(c.Applied(middle)))
	if elections == 0 {
		t.Fatal("the partial partition caused no elections; expected leaders to be deposed")
	}
}

// With PreVote, the cut-off follower asks first. The middle node still
// hears from the leader, so it says no, and nobody's term changes.
func TestPreVoteRidesOutAPartialPartition(t *testing.T) {
	c := New(3, 2, WithPreVote())
	middle := partial(t, c)
	before := c.Elections()
	for i := range 100 {
		c.Propose(fmt.Sprint("v", i))
		c.Run(20)
	}
	if elections := c.Elections() - before; elections != 0 {
		t.Fatalf("%d elections during the partial partition, want 0", elections)
	}
	if got := len(c.Applied(middle)); got != 100 {
		t.Fatalf("%d of 100 proposals applied, want all of them", got)
	}
	if err := c.Err(); err != nil {
		t.Fatal(err)
	}
}

// With no writes, the cut-off node's log is as up to date as anyone's, so
// only the "heard from a leader recently" check stops its pre-vote.
func TestAnIdleClusterRidesOutAPartialPartition(t *testing.T) {
	c := New(3, 2, WithPreVote())
	partial(t, c)
	before := c.Elections()
	c.Run(2000)
	if elections := c.Elections() - before; elections != 0 {
		t.Fatalf("%d elections while idle in a partial partition, want 0", elections)
	}
}

// A node cut off for a while comes back with a high term. Without PreVote,
// its first message deposes a leader that was working perfectly.
func TestARejoiningNodeDisruptsOnlyWithoutPreVote(t *testing.T) {
	for _, preVote := range []bool{false, true} {
		var opts []Option
		if preVote {
			opts = append(opts, WithPreVote())
		}
		c := New(5, 7, opts...)
		leader := elect(t, c)
		away := leader%5 + 1
		var rest []raft.ID
		for _, id := range c.IDs() {
			if id != away {
				rest = append(rest, id)
			}
		}
		c.Partition([]raft.ID{away}, rest)
		c.Run(300)
		before := c.Elections()
		c.Heal()
		c.Run(300)
		disrupted := c.Elections() > before
		t.Logf("PreVote %v: the returning node's term was %d; new elections after it returned: %d",
			preVote, c.Node(away).Status().Term, c.Elections()-before)
		if disrupted == preVote {
			t.Fatalf("PreVote %v: disrupted = %v", preVote, disrupted)
		}
	}
}

// With CheckQuorum, a leader cut off from the majority notices and steps
// down, instead of believing it leads forever.
func TestCheckQuorumDeposesAnIsolatedLeader(t *testing.T) {
	c := New(5, 8, WithPreVote())
	leader := elect(t, c)
	var rest []raft.ID
	for _, id := range c.IDs() {
		if id != leader {
			rest = append(rest, id)
		}
	}
	c.Partition([]raft.ID{leader}, rest)
	c.Run(25) // a little over two election timeouts
	if role := c.Node(leader).Status().Role; role == raft.Leader {
		t.Fatal("the isolated leader still believes it leads")
	}
}

// PreVote changes elections, so run the storms again with it on.
func TestSafetyUnderChaosWithPreVote(t *testing.T) {
	for seed := uint64(1); seed <= 300; seed++ {
		c := New(5, seed, WithPreVote())
		c.Net.SetDelay(1, 8)
		c.Net.SetDropRate(0.05)
		c.CrashChance = 0.005
		c.SnapshotEvery = 5
		for round := range 20 {
			for _, id := range c.IDs() {
				if c.Down(id) {
					c.Restart(id)
				}
			}
			if round%3 == 0 {
				c.Heal()
			} else {
				c.randomPartition()
			}
			for i := range 5 {
				c.Propose(fmt.Sprint(seed, "-", round, "-", i))
				c.Run(20)
			}
		}
		// The storm ends: no more crashes or losses, everyone back.
		c.CrashChance = 0
		for _, id := range c.IDs() {
			if c.Down(id) {
				c.Restart(id)
			}
		}
		c.Heal()
		c.Net.SetDropRate(0)
		ticks := c.RunUntilConverged(5000)
		if err := c.Err(); err != nil {
			t.Fatalf("seed %d: %v", seed, err)
		}
		if ticks < 0 {
			t.Fatalf("seed %d: the nodes still disagree 5000 ticks after the storm ended", seed)
		}
	}
}
~~~

The first test *documents* the problem: it passes when leaders keep getting deposed. The idle test matters for the "Break it" below. The last runs 300 storms with everything on (crashes, snapshots, PreVote) and requires both safety and recovery. Note that crashes stop once the storm ends; the first version of this test kept crashing nodes while waiting for them to agree, and of course they never did.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/raft/... && go test -race -count=1 ./internal/raft/... -->

~~~bash
go test -v -run 'Partial|PreVote|Rejoin|CheckQuorum' ./internal/raft/raftsim/
~~~

~~~text
    partial_test.go:38: 6 elections in 2000 ticks, term 14, 95 of 100 proposals applied
--- PASS: TestAPartialPartitionKeepsDeposingLeaders (0.01s)
--- PASS: TestPreVoteRidesOutAPartialPartition (0.01s)
--- PASS: TestAnIdleClusterRidesOutAPartialPartition (0.00s)
    partial_test.go:101: PreVote false: the returning node's term was 23; new elections after it returned: 1
    partial_test.go:101: PreVote true: the returning node's term was 1; new elections after it returned: 0
--- PASS: TestARejoiningNodeDisruptsOnlyWithoutPreVote (0.01s)
--- PASS: TestCheckQuorumDeposesAnIsolatedLeader (0.00s)
--- PASS: TestSafetyUnderChaosWithPreVote (2.09s)
ok  	runway/internal/raft/raftsim	2.125s
~~~

The numbers tell the story:

| | Without PreVote | With PreVote and CheckQuorum |
|---|---|---|
| Elections during 2,000 ticks of partial partition | 6 | 0 |
| Term at the end | 14 | 1 |
| Proposals applied | 95 of 100 | 100 of 100 |
| The isolated node's term when it returned | 23 | 1 |
| Elections caused by its return | 1 | 0 |

Five lost proposals is mild in a simulation with 100 proposals. In production, each lost leader means a few hundred milliseconds of refused writes, again and again for as long as the network stays half broken.

**Break it: pre-votes that don't check for a leader.** In `handlePreVote`, change the `heardFromLeader := ...` line to `heardFromLeader := false`, and run the partial-partition tests:

~~~text
--- FAIL: TestAnIdleClusterRidesOutAPartialPartition (0.00s)
    partial_test.go:74: 1 elections while idle in a partial partition, want 0
~~~

Only the idle test fails, and it's worth seeing why. In the other tests, writes keep arriving. The cut-off node misses them, its log falls behind, and the *up-to-date* check refuses its pre-vote anyway. With no writes, its log is as good as anyone's, so the leader check is the only thing standing in its way. Two checks guard the same door, and a test covers only one of them unless it builds the situation where the other one is alone. Restore the line.

**Explain it:** what does PreVote prevent, and why does it need the "heard from a leader recently" check? What does CheckQuorum add? Draw the partial partition from the first test, and trace one round of disruption without PreVote.

**Read.** Ongaro's PhD thesis, *Consensus: Bridging Theory and Practice*, §9.6 (*Preventing disruptions when a server rejoins the cluster*). Then Alquraan et al., OSDI 2018, §1–4. Carry this question in: which of the paper's failure patterns would your Raft survive now, and which wouldn't it?

---

## Step 7: A replicated key-value store, checked for linearizability

**The problem.** A replicated log is a means, not an end. Runway needs a **store**: put a value, get it back, compare-and-swap. And it needs the store to behave **as if there were one copy**, even though there are five, clients retry, and leaders change mid-request. "As if there were one copy" has a precise name, **linearizability**, and a precise test: record every client's requests and answers, then check whether *some* single order of them explains every answer.

Two traps lie in wait:
- **A retried command can run twice.** A client sends `append x`, the leader commits it, the answer is lost, and the client retries. Now the log holds `append x` twice.
- **Reads can be stale.** A leader cut off by a partition doesn't know it has been replaced. If it answers a read from its own copy, it can return a value that was overwritten seconds ago, on the other side of the partition.

**New ideas.**

- **A deterministic state machine.** The store applies commands from the log and nothing else. It never reads the clock, never picks random numbers, and never consults anything outside the command. So every node that applies the same log reaches the same state.
- **Client sessions** make retries safe. Each client names itself and numbers its requests 1, 2, 3, …, reusing a number when it retries. The store remembers each client's last number and answer. A command whose number isn't new gets the remembered answer and changes nothing. The sessions are part of the state, so they're in the snapshot too: a node restored from a snapshot must still recognise a retry.
- **Reads go through the log.** The simplest correct read is a command like any other: append `get`, wait for it to commit, answer from the state as of that point. It costs a round of replication per read. The faster alternatives are *ReadIndex* (confirm leadership with one round of heartbeats, then read locally) and *lease reads* (trust a time-based lease, which assumes bounded clock drift). Both are in the thesis, §6.4.
- **Linearizability, precisely.** Every operation appears to take effect at some instant between its call and its return, and the results match a single copy applying them in that order. It's about *real time*: if a write finished before a read began, the read must see it.
- **Porcupine** is a linearizability checker (Athalye, used in MIT 6.5840). You give it a **model** (what a single copy would do) and a **history** (each operation's input, output, call time and return time), and it searches for a valid order. Checking is NP-complete in general. Porcupine stays fast by checking each key separately (**partitioning**) and pruning hard.

### The store

Create `internal/metastore/store.go`:

<!-- file: internal/metastore/store.go -->
~~~go
// Package metastore is a small key-value store meant to be replicated:
// it's the state machine that a Raft log drives. Every node applies the
// same commands in the same order, so every node ends up with the same
// data. It holds Runway's metadata, which must survive any one machine.
package metastore

import (
	"encoding/json"
	"fmt"
)

// Command is one request, as it travels through the log.
type Command struct {
	// Client and Seq identify the request. A client numbers its requests
	// 1, 2, 3, ... and reuses the number when it retries, so a retry can
	// be recognised.
	Client string `json:"client"`
	Seq    uint64 `json:"seq"`
	Op     string `json:"op"` // get, put, append, cas or delete
	Key    string `json:"key"`
	Value  string `json:"value,omitempty"`
	Expect string `json:"expect,omitempty"` // cas: the value the key must have now
}

// Result is the answer to a Command.
type Result struct {
	Value string `json:"value"`
	Found bool   `json:"found"`
	OK    bool   `json:"ok"` // cas: whether it swapped; delete: whether the key existed
}

// Store is the state: the data, and the last answer given to each client.
type Store struct {
	Data     map[string]string  `json:"data"`
	Sessions map[string]Session `json:"sessions"`
}

// Session remembers a client's latest request and its answer.
type Session struct {
	Seq    uint64 `json:"seq"`
	Result Result `json:"result"`
}

func New() *Store {
	return &Store{Data: map[string]string{}, Sessions: map[string]Session{}}
}

// Apply runs one command and returns its answer. A command the client has
// already sent (its Seq isn't new) is a retry: it isn't run again, and
// gets the original answer. That is what makes a retried append or cas
// happen exactly once, even though the log may contain it twice.
func (s *Store) Apply(cmd Command) Result {
	if last, ok := s.Sessions[cmd.Client]; ok && cmd.Seq <= last.Seq {
		return last.Result
	}
	var r Result
	switch cmd.Op {
	case "get":
		r.Value, r.Found = s.Data[cmd.Key]
	case "put":
		s.Data[cmd.Key] = cmd.Value
		r.OK = true
	case "append":
		s.Data[cmd.Key] += cmd.Value
		r.Value, r.OK = s.Data[cmd.Key], true
	case "cas":
		current, found := s.Data[cmd.Key]
		if found && current == cmd.Expect {
			s.Data[cmd.Key] = cmd.Value
			r.OK = true
		}
		r.Value, r.Found = current, found
	case "delete":
		_, r.OK = s.Data[cmd.Key]
		delete(s.Data, cmd.Key)
	}
	s.Sessions[cmd.Client] = Session{Seq: cmd.Seq, Result: r}
	return r
}

// ApplyEntry decodes a log entry's data and applies it. The empty entries
// a new leader appends have no data, and do nothing.
func (s *Store) ApplyEntry(data []byte) (Result, error) {
	if data == nil {
		return Result{}, nil
	}
	var cmd Command
	if err := json.Unmarshal(data, &cmd); err != nil {
		return Result{}, fmt.Errorf("metastore: bad command: %w", err)
	}
	return s.Apply(cmd), nil
}

// Snapshot encodes the whole state, sessions included: a node restored
// from it must still recognise retries.
func (s *Store) Snapshot() ([]byte, error) { return json.Marshal(s) }

// Restore replaces the state with a snapshot's.
func (s *Store) Restore(data []byte) error {
	fresh := New()
	if len(data) > 0 {
		if err := json.Unmarshal(data, fresh); err != nil {
			return fmt.Errorf("metastore: bad snapshot: %w", err)
		}
	}
	*s = *fresh
	return nil
}
~~~

Create `internal/metastore/store_test.go`:

<!-- file: internal/metastore/store_test.go -->
~~~go
package metastore

import "testing"

func TestOperations(t *testing.T) {
	s := New()
	steps := []struct {
		cmd  Command
		want Result
	}{
		{Command{Client: "a", Seq: 1, Op: "get", Key: "k"}, Result{}},
		{Command{Client: "a", Seq: 2, Op: "put", Key: "k", Value: "x"}, Result{OK: true}},
		{Command{Client: "a", Seq: 3, Op: "append", Key: "k", Value: "y"}, Result{Value: "xy", OK: true}},
		{Command{Client: "a", Seq: 4, Op: "cas", Key: "k", Expect: "nope", Value: "z"}, Result{Value: "xy", Found: true}},
		{Command{Client: "a", Seq: 5, Op: "cas", Key: "k", Expect: "xy", Value: "z"}, Result{Value: "xy", Found: true, OK: true}},
		{Command{Client: "a", Seq: 6, Op: "get", Key: "k"}, Result{Value: "z", Found: true}},
		{Command{Client: "a", Seq: 7, Op: "delete", Key: "k"}, Result{OK: true}},
		{Command{Client: "a", Seq: 8, Op: "delete", Key: "k"}, Result{}},
	}
	for _, step := range steps {
		if got := s.Apply(step.cmd); got != step.want {
			t.Fatalf("%+v: got %+v, want %+v", step.cmd, got, step.want)
		}
	}
}

// The log can hold the same command twice, when a client retried. The
// second copy must change nothing and get the first copy's answer.
func TestARetryRunsOnce(t *testing.T) {
	s := New()
	cmd := Command{Client: "a", Seq: 1, Op: "append", Key: "k", Value: "x"}
	first, second := s.Apply(cmd), s.Apply(cmd)
	if s.Data["k"] != "x" || first != second {
		t.Fatalf("after a retry: value %q, answers %+v and %+v", s.Data["k"], first, second)
	}
	other := Command{Client: "b", Seq: 1, Op: "append", Key: "k", Value: "y"}
	if s.Apply(other); s.Data["k"] != "xy" {
		t.Fatalf("another client's Seq 1 was treated as a retry: %q", s.Data["k"])
	}
}

func TestSnapshotKeepsDataAndSessions(t *testing.T) {
	s := New()
	cmd := Command{Client: "a", Seq: 1, Op: "append", Key: "k", Value: "x"}
	s.Apply(cmd)
	snap, err := s.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	restored := New()
	if err := restored.Restore(snap); err != nil {
		t.Fatal(err)
	}
	restored.Apply(cmd) // a retry arriving after the restore
	if restored.Data["k"] != "x" {
		t.Fatalf("value %q: the restored store forgot the session and ran the retry", restored.Data["k"])
	}
}
~~~

### The simulator runs real state machines

The simulator so far applied entries to a list of strings. Now:
- it can drive any state machine (`WithStateMachine`), and snapshots hold both the list and the machine's own snapshot;
- it keeps each node's answers by log index (`Result`);
- a test can drive a node directly and then process its `Ready` (`Process`);
- options become functions on the cluster rather than on a node's configuration.

The changes overlap too much to list as separate edits, so replace `internal/raft/raftsim/raftsim.go` with:

<!-- file: internal/raft/raftsim/raftsim.go -->
~~~go
// Package raftsim runs a Raft cluster on a simulated network, and checks
// Raft's safety properties after every step.
package raftsim

import (
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"slices"

	"runway/internal/raft"
	"runway/internal/simnet"
)

// Cluster is a simulated cluster of n nodes, IDs 1 to n.
type Cluster struct {
	Net   *simnet.Network
	rng   *rand.Rand
	nodes []*raft.Node // index 0 unused
	disks []*Disk      // what each node has saved; survives crashes

	preVote    bool
	newMachine func() StateMachine
	machines   []StateMachine
	results    []map[uint64]result // each node's answers, by log index
	down       map[raft.ID]bool

	// CrashChance is the probability that a node crashes in the middle of
	// carrying out a Ready: after its first step, before its second.
	CrashChance float64
	// SnapshotEvery makes a node compact its log once it has applied this
	// many entries since its last snapshot. Zero means never.
	SnapshotEvery int
	SnapshotsSent int // how many snapshots leaders have sent

	leaders   map[uint64]raft.ID    // who led each term: election safety
	elections int                   // how many times a node became leader
	committed map[uint64]raft.Entry // the entry applied at each index: state machine safety
	applied   [][]string            // each node's applied data, in order (index 0 unused)
	lastApply []uint64              // the index each node last applied
	err       error
}

// Option changes how the cluster is built.
type Option func(*Cluster)

// WithPreVote turns on PreVote and CheckQuorum on every node.
func WithPreVote() Option {
	return func(c *Cluster) { c.preVote = true }
}

// StateMachine is what a node's log drives. Apply returns the answer to
// the entry's command.
type StateMachine interface {
	Apply(e raft.Entry) any
	Snapshot() []byte
	Restore(data []byte)
}

// WithStateMachine gives every node a state machine of its own, made by
// newMachine (and made again when a node restarts).
func WithStateMachine(newMachine func() StateMachine) Option {
	return func(c *Cluster) { c.newMachine = newMachine }
}

// result is a state machine's answer to one entry.
type result struct {
	term  uint64
	value any
}

// New builds a cluster whose every random choice comes from seed.
func New(n int, seed uint64, opts ...Option) *Cluster {
	rng := rand.New(rand.NewPCG(seed, seed))
	c := &Cluster{
		Net:       simnet.New(rng),
		rng:       rng,
		nodes:     make([]*raft.Node, n+1),
		disks:     make([]*Disk, n+1),
		down:      map[raft.ID]bool{},
		leaders:   map[uint64]raft.ID{},
		committed: map[uint64]raft.Entry{},
		applied:   make([][]string, n+1),
		lastApply: make([]uint64, n+1),
		machines:  make([]StateMachine, n+1),
		results:   make([]map[uint64]result, n+1),
	}
	for _, opt := range opts {
		opt(c)
	}
	for id := 1; id <= n; id++ {
		c.disks[id] = &Disk{}
		c.nodes[id] = raft.New(c.config(raft.ID(id)), raft.Persisted{})
		c.resetMachine(raft.ID(id))
	}
	return c
}

func (c *Cluster) config(id raft.ID) raft.Config {
	var peers []raft.ID
	for p := 1; p < len(c.nodes); p++ {
		peers = append(peers, raft.ID(p))
	}
	cfg := raft.Config{
		ID:            id,
		Peers:         peers,
		ElectionTick:  10,
		HeartbeatTick: 2,
		// Each node gets its own random source, drawn from the cluster's.
		Rand: rand.New(rand.NewPCG(c.rng.Uint64(), c.rng.Uint64())),
	}
	cfg.PreVote, cfg.CheckQuorum = c.preVote, c.preVote
	return cfg
}

func (c *Cluster) resetMachine(id raft.ID) {
	c.results[id] = map[uint64]result{}
	if c.newMachine != nil {
		c.machines[id] = c.newMachine()
	}
}

// IDs lists the members.
func (c *Cluster) IDs() []raft.ID {
	var ids []raft.ID
	for id := 1; id < len(c.nodes); id++ {
		ids = append(ids, raft.ID(id))
	}
	return ids
}

// Node returns a member, for inspection.
func (c *Cluster) Node(id raft.ID) *raft.Node { return c.nodes[id] }

// Tick advances the whole cluster by one tick: deliver the messages that
// arrive now, tick every running node, and carry out each node's Ready.
func (c *Cluster) Tick() {
	for _, e := range c.Net.Tick() {
		to := raft.ID(e.To)
		if !c.down[to] {
			c.nodes[to].Step(e.Msg.(raft.Message))
			c.process(to)
		}
	}
	for _, id := range c.IDs() {
		if !c.down[id] {
			c.nodes[id].Tick()
			c.process(id)
		}
	}
}

// Run ticks n times, stopping early if a safety check fails.
func (c *Cluster) Run(ticks int) {
	for range ticks {
		if c.err != nil {
			return
		}
		c.Tick()
	}
}

// Disk is a node's saved state. The simulator treats every save as
// durable at once, as if each one ended with a successful fsync.
type Disk struct {
	state raft.Persisted
}

func (d *Disk) save(rd raft.Ready) {
	if rd.HardState != nil {
		d.state.HardState = *rd.HardState
	}
	if rd.Snapshot != nil {
		d.saveSnapshot(*rd.Snapshot)
	}
	if len(rd.Entries) > 0 {
		// Entries replace whatever was saved from their first index on.
		first := rd.Entries[0].Index
		d.state.Entries = append(d.state.Entries[:first-d.state.Snapshot.Index-1], rd.Entries...)
	}
}

// saveSnapshot saves snap and drops the entries it covers. If the saved log
// doesn't contain snap's last entry, the entries after it belong to a
// different history, and go too.
func (d *Disk) saveSnapshot(snap raft.Snapshot) {
	var keep []raft.Entry
	for i, e := range d.state.Entries {
		if e.Index == snap.Index && e.Term == snap.Term {
			keep = d.state.Entries[i+1:]
		}
	}
	d.state.Snapshot = snap
	d.state.Entries = append([]raft.Entry(nil), keep...)
}

// process carries out one node's Ready, in Raft's required order: save,
// then send, then apply. Then it checks the invariants.
func (c *Cluster) process(id raft.ID) {
	rd := c.nodes[id].Ready()
	c.disks[id].save(rd)
	if c.rng.Float64() < c.CrashChance {
		c.Crash(id) // saved, but the messages never left
		return
	}
	for _, m := range rd.Messages {
		if m.Type == raft.MsgSnap {
			c.SnapshotsSent++
		}
		c.Net.Send(int(m.From), int(m.To), m)
	}
	if rd.Snapshot != nil {
		c.restore(id, *rd.Snapshot)
	}
	for _, e := range rd.Committed {
		c.apply(id, e)
	}
	c.maybeCompact(id)
	c.check(id)
}

// snapshotData is what a snapshot holds: the list of applied data the
// checks use, and the state machine's own snapshot, if there is one.
type snapshotData struct {
	Applied []string
	Machine []byte
}

func (c *Cluster) restore(id raft.ID, snap raft.Snapshot) {
	c.applied[id] = nil
	c.resetMachine(id)
	if snap.Data != nil {
		var d snapshotData
		if err := json.Unmarshal(snap.Data, &d); err != nil {
			c.fail("node %d: bad snapshot: %v", id, err)
		}
		c.applied[id] = d.Applied
		if c.machines[id] != nil {
			c.machines[id].Restore(d.Machine)
		}
	}
	c.lastApply[id] = snap.Index
}

func (c *Cluster) maybeCompact(id raft.ID) {
	first := c.disks[id].state.Snapshot.Index
	if c.SnapshotEvery == 0 || c.lastApply[id]-first < uint64(c.SnapshotEvery) {
		return
	}
	d := snapshotData{Applied: c.applied[id]}
	if c.machines[id] != nil {
		d.Machine = c.machines[id].Snapshot()
	}
	data, _ := json.Marshal(d)
	snap, err := c.nodes[id].Compact(c.lastApply[id], data)
	if err != nil {
		c.fail("node %d: %v", id, err)
		return
	}
	c.disks[id].saveSnapshot(snap)
}

// apply records that node id applied entry e, and checks state machine
// safety: every node applies the same entry at the same index.
func (c *Cluster) apply(id raft.ID, e raft.Entry) {
	if prev, ok := c.committed[e.Index]; ok {
		if prev.Term != e.Term || string(prev.Data) != string(e.Data) {
			c.fail("state machine safety: node %d applied {term %d %q} at index %d, another node applied {term %d %q}",
				id, e.Term, e.Data, e.Index, prev.Term, prev.Data)
		}
	} else {
		c.committed[e.Index] = e
	}
	if e.Data != nil { // skip the empty entries new leaders append
		c.applied[id] = append(c.applied[id], string(e.Data))
	}
	if c.machines[id] != nil {
		c.results[id][e.Index] = result{term: e.Term, value: c.machines[id].Apply(e)}
	}
	c.lastApply[id] = e.Index
}

// Result returns the answer node id's state machine gave to the entry at
// index, if it has applied that entry and it had the given term. A
// different term means the entry was replaced: the command it carried was
// lost, and must be sent again.
func (c *Cluster) Result(id raft.ID, index, term uint64) (any, bool) {
	r, ok := c.results[id][index]
	if !ok || r.term != term {
		return nil, false
	}
	return r.value, true
}

// Machine returns node id's state machine, for inspection.
func (c *Cluster) Machine(id raft.ID) StateMachine { return c.machines[id] }

// RunUntilConverged ticks until every running node has applied the same
// entries, and reports how many ticks that took, or -1 if it didn't
// happen within limit ticks.
func (c *Cluster) RunUntilConverged(limit int) int {
	for tick := range limit {
		if c.converged() {
			return tick
		}
		c.Tick()
	}
	return -1
}

func (c *Cluster) converged() bool {
	var first []string
	var seen bool
	for _, id := range c.IDs() {
		if c.down[id] {
			continue
		}
		if !seen {
			first, seen = c.applied[id], true
			continue
		}
		if !slices.Equal(c.applied[id], first) {
			return false
		}
	}
	return c.Leader() != raft.None
}

// Applied is the data node id has applied, in order.
func (c *Cluster) Applied(id raft.ID) []string { return c.applied[id] }

// Propose offers data to the current leader. It reports false if there is
// no leader or the leader refused; true only means "accepted", not
// "committed".
func (c *Cluster) Propose(data string) bool {
	leader := c.Leader()
	if leader == raft.None {
		return false
	}
	if _, err := c.nodes[leader].Propose([]byte(data)); err != nil {
		return false
	}
	c.process(leader)
	return true
}

// Process carries out a node's Ready now, after the caller has called one
// of its methods directly (such as Propose).
func (c *Cluster) Process(id raft.ID) { c.process(id) }

func (c *Cluster) check(id raft.ID) {
	st := c.nodes[id].Status()
	if st.Role != raft.Leader {
		return
	}
	// Election safety: at most one leader in any term.
	if prev, ok := c.leaders[st.Term]; ok && prev != id {
		c.fail("election safety: nodes %d and %d both led term %d", prev, id, st.Term)
	}
	if _, ok := c.leaders[st.Term]; !ok {
		c.elections++
	}
	c.leaders[st.Term] = id
}

func (c *Cluster) fail(format string, args ...any) {
	if c.err == nil {
		c.err = fmt.Errorf("tick %d: %s", c.Net.Now(), fmt.Sprintf(format, args...))
	}
}

// Elections is how many terms have had a leader so far.
func (c *Cluster) Elections() int { return c.elections }

// Err is the first safety violation seen, or nil.
func (c *Cluster) Err() error { return c.err }

// Crash stops a node: it receives nothing and does nothing. Everything not
// on its disk is gone.
func (c *Cluster) Crash(id raft.ID) { c.down[id] = true }

// Restart brings a crashed node back from what its disk holds. Its state
// machine starts empty and is rebuilt by applying the log again.
func (c *Cluster) Restart(id raft.ID) {
	saved := c.disks[id].state
	saved.Entries = append([]raft.Entry(nil), saved.Entries...)
	c.nodes[id] = raft.New(c.config(id), saved)
	c.restore(id, saved.Snapshot)
	c.down[id] = false
}

// Down reports whether a node is crashed.
func (c *Cluster) Down(id raft.ID) bool { return c.down[id] }

// Leader returns the running node that believes it leads, in the highest
// term, or None.
func (c *Cluster) Leader() raft.ID {
	best, bestTerm := raft.None, uint64(0)
	for _, id := range c.IDs() {
		st := c.nodes[id].Status()
		if !c.down[id] && st.Role == raft.Leader && st.Term >= bestTerm {
			best, bestTerm = id, st.Term
		}
	}
	return best
}
~~~

Tests in another package will cause partitions too, so `randomPartition` must be exported. Rename the method in `internal/raft/raftsim/chaos.go`. Change:

<!-- edit: internal/raft/raftsim/chaos.go -->
~~~go
// randomPartition splits the cluster into two random groups.
func (c *Cluster) randomPartition() {
~~~

to:

~~~go
// RandomPartition splits the cluster into two random groups.
func (c *Cluster) RandomPartition() {
~~~

and then every call to it. `gofmt -r` rewrites Go code by pattern: in a rule, a single lower-case letter (`x` here) matches any expression. It edits the syntax tree, not the text, so it can't touch a comment or a string by accident.

<!-- run: gofmt -r 'x.randomPartition() -> x.RandomPartition()' -w internal/raft/raftsim/ -->
~~~bash
gofmt -r 'x.randomPartition() -> x.RandomPartition()' -w internal/raft/raftsim/
~~~

### The linearizability test

Get Porcupine:

<!-- run: go get github.com/anishathalye/porcupine@v1.3.1 -->
~~~bash
go get github.com/anishathalye/porcupine@v1.3.1
~~~

Create `internal/metastore/linearizable_test.go`:

<!-- file: internal/metastore/linearizable_test.go -->
~~~go
package metastore_test

import (
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/anishathalye/porcupine"

	"runway/internal/metastore"
	"runway/internal/raft"
	"runway/internal/raft/raftsim"
)

// machine adapts the store to the simulator.
type machine struct{ store *metastore.Store }

func (m *machine) Apply(e raft.Entry) any {
	r, _ := m.store.ApplyEntry(e.Data)
	return r
}

func (m *machine) Snapshot() []byte {
	data, _ := m.store.Snapshot()
	return data
}

func (m *machine) Restore(data []byte) { _ = m.store.Restore(data) }

func newMachine() raftsim.StateMachine { return &machine{store: metastore.New()} }

// client sends one command at a time. Until it has an answer it keeps
// trying, with the same Seq. Like a real client, it doesn't know who leads:
// it sticks to the node it last used, and moves on when that node says
// it isn't the leader (following its hint, if it has one).
type client struct {
	id      int
	leader  raft.ID
	seq     uint64
	cmd     metastore.Command
	call    int64
	index   uint64
	term    uint64
	sentAt  int
	waiting bool
}

// kvModel is what linearizability means for this store: one key's
// operations, in some order consistent with real time, as if applied one
// at a time to a single copy.
var kvModel = porcupine.Model{
	Partition: func(history []porcupine.Operation) [][]porcupine.Operation {
		byKey := map[string][]porcupine.Operation{}
		var keys []string
		for _, op := range history {
			k := op.Input.(metastore.Command).Key
			if _, ok := byKey[k]; !ok {
				keys = append(keys, k)
			}
			byKey[k] = append(byKey[k], op)
		}
		var out [][]porcupine.Operation
		for _, k := range keys {
			out = append(out, byKey[k])
		}
		return out
	},
	Init: func() any { return "" },
	Step: func(state, input, output any) (bool, any) {
		v := state.(string)
		in, out := input.(metastore.Command), output.(metastore.Result)
		switch in.Op {
		case "get":
			return out.Value == v, v
		case "put":
			return true, in.Value
		case "append":
			return out.Value == v+in.Value, v + in.Value
		}
		return false, v
	},
	DescribeOperation: func(input, output any) string {
		in, out := input.(metastore.Command), output.(metastore.Result)
		return fmt.Sprintf("%s(%s, %q) -> %q", in.Op, in.Key, in.Value, out.Value)
	},
}

// workload runs clients against a simulated cluster for the given rounds
// of faults, and returns the history of completed operations.
func workload(t *testing.T, seed uint64, rounds int, readLocally bool, opts ...raftsim.Option) []porcupine.Operation {
	t.Helper()
	c := raftsim.New(5, seed, append(opts, raftsim.WithStateMachine(newMachine))...)
	c.Net.SetDelay(1, 6)
	c.Net.SetDropRate(0.05)
	c.SnapshotEvery = 20
	keys := []string{"a", "b"}
	clients := make([]*client, 6)
	for i := range clients {
		clients[i] = &client{id: i, leader: raft.ID(i%5 + 1)}
	}
	var history []porcupine.Operation

	step := func() {
		now := c.Net.Now()
		for _, cl := range clients {
			if !cl.waiting {
				cl.seq++
				cl.cmd = metastore.Command{Client: fmt.Sprint("c", cl.id), Seq: cl.seq, Key: keys[(cl.id+int(cl.seq))%2]}
				switch (cl.id + int(cl.seq)) % 3 {
				case 0:
					cl.cmd.Op = "get"
				case 1:
					cl.cmd.Op, cl.cmd.Value = "put", fmt.Sprint(cl.id, ".", cl.seq)
				default:
					cl.cmd.Op, cl.cmd.Value = "append", fmt.Sprint(cl.id, ".", cl.seq, ";")
				}
				cl.call, cl.waiting, cl.index = int64(now), true, 0
			}
			if cl.index != 0 {
				// Has any node applied our entry, with our term?
				for _, id := range c.IDs() {
					if v, ok := c.Result(id, cl.index, cl.term); ok {
						history = append(history, porcupine.Operation{ClientId: cl.id, Input: cl.cmd, Call: cl.call, Output: v, Return: int64(now)})
						cl.waiting = false
						break
					}
				}
				if !cl.waiting || now-cl.sentAt < 30 {
					continue
				}
			}
			// Send, or send again after 30 ticks without an answer.
			leader := cl.leader
			if c.Down(leader) || c.Node(leader).Status().Role != raft.Leader {
				// Not the leader (or not answering): try its hint, or the next node.
				if hint := c.Node(leader).Status().Leader; hint != raft.None && hint != leader && !c.Down(leader) {
					cl.leader = hint
				} else {
					cl.leader = leader%5 + 1
				}
				continue
			}
			if readLocally && cl.cmd.Op == "get" {
				// The mistake: answer a read from the leader's own copy,
				// without going through the log.
				v, found := c.Machine(leader).(*machine).store.Data[cl.cmd.Key]
				history = append(history, porcupine.Operation{ClientId: cl.id, Input: cl.cmd, Call: cl.call,
					Output: metastore.Result{Value: v, Found: found}, Return: int64(now)})
				cl.waiting = false
				continue
			}
			data, _ := json.Marshal(cl.cmd)
			index, err := c.Node(leader).Propose(data)
			if err != nil {
				continue
			}
			cl.index, cl.term, cl.sentAt = index, c.Node(leader).Status().Term, now
			c.Process(leader)
		}
		c.Tick()
	}

	for round := range rounds {
		if round%2 == 0 {
			c.Heal()
		} else {
			c.RandomPartition()
		}
		for range 100 {
			step()
		}
	}
	if err := c.Err(); err != nil {
		t.Fatalf("seed %d: %v", seed, err)
	}
	return history
}

func TestTheStoreIsLinearizable(t *testing.T) {
	for seed := uint64(1); seed <= 20; seed++ {
		history := workload(t, seed, 10, false, raftsim.WithPreVote())
		res := porcupine.CheckOperationsTimeout(kvModel, history, 10*time.Second)
		if res != porcupine.Ok {
			t.Fatalf("seed %d: %d operations are not linearizable (%s)", seed, len(history), res)
		}
		if seed == 1 {
			t.Logf("seed 1: %d operations checked", len(history))
		}
	}
}

// A leader cut off from the majority doesn't know it has been replaced, so
// a read served from its own copy can be stale. Without CheckQuorum, such
// a leader goes on believing it leads for as long as the partition lasts.
// Reads go through the log.
func TestLocalReadsAreNotLinearizable(t *testing.T) {
	for seed := uint64(1); seed <= 20; seed++ {
		history := workload(t, seed, 10, true)
		res, info := porcupine.CheckOperationsVerbose(kvModel, history, 10*time.Second)
		if res == porcupine.Illegal {
			t.Logf("seed %d: reading the leader's own copy gave a stale answer", seed)
			if path := os.Getenv("PORCUPINE_HTML"); path != "" {
				if err := porcupine.VisualizePath(kvModel, info, path); err != nil {
					t.Fatal(err)
				}
				t.Logf("wrote the history to %s", path)
			}
			return
		}
	}
	t.Fatal("20 seeds of local reads stayed linearizable; expected a stale read")
}
~~~

The simulated clients behave like real ones:
- each sends one command at a time and retries it, with the same `Seq`, if 30 ticks pass without an answer;
- each sticks to the node it last used, and moves on only when that node says it isn't the leader;
- an answer counts only from a node that applied the client's entry at the expected index **and term**; a different term at that index means the entry was replaced and the command lost.

The history records when each operation was called and when it returned, in simulated ticks. `kvModel` describes a single copy. `get`, `put` and `append` are enough to catch both traps.

`TestLocalReadsAreNotLinearizable` makes the second mistake on purpose: it answers reads from the leader's own copy. It runs without CheckQuorum, so a deposed leader goes on believing it leads for the whole partition, and it *expects* Porcupine to find a stale read. Set `PORCUPINE_HTML` to a file name and it writes Porcupine's visualisation of that history: open the file in a browser and step through the operations to see the read that couldn't have happened.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/... && go test -race -count=1 ./internal/raft/... ./internal/metastore/... -->

~~~bash
go test -v ./internal/metastore/
PORCUPINE_HTML=stale.html go test -run LocalReads ./internal/metastore/
~~~

~~~text
--- PASS: TestOperations (0.00s)
--- PASS: TestARetryRunsOnce (0.00s)
--- PASS: TestSnapshotKeepsDataAndSessions (0.00s)
    linearizable_test.go:189: seed 1: 1063 operations checked
--- PASS: TestTheStoreIsLinearizable (2.50s)
    linearizable_test.go:203: seed 9: reading the leader's own copy gave a stale answer
--- PASS: TestLocalReadsAreNotLinearizable (0.80s)
ok  	runway/internal/metastore	3.307s
~~~

Twenty seeds of partitions, losses and leader changes, around 1,000 operations each, and every history has a valid single-copy order. The local-read version broke at seed 9.

**Break it: forget the sessions.** In `Apply`, delete the three lines that return `last.Result` for a repeated `Seq`:

~~~text
--- FAIL: TestTheStoreIsLinearizable (0.64s)
    linearizable_test.go:189: seed 1: 1063 operations checked
    linearizable_test.go:186: seed 5: 996 operations are not linearizable (Illegal)
~~~

At seed 5, a retried `append` reached the log twice, and the value grew by the same piece two times. No single copy, applying each operation once, could produce that. Restore the lines.

**Explain it:** define linearizability, including the part about real time. Why must reads go through the log, or use ReadIndex or a lease? How do sessions make a retried `append` happen exactly once? Why do the sessions have to be in the snapshot?

**Read.** Herlihy and Wing, *Linearizability: A Correctness Condition for Concurrent Objects* (1990), §1–3. Then Ongaro's thesis, §6.3 (*Implementing linearizable semantics*) and §6.4 (*Processing read-only queries more efficiently*). And Kingsbury's *Strong consistency models* (jepsen.io), on how linearizability relates to serializability and the weaker models. Carry this question in: Runway's PostgreSQL data from Phase 3 was serializable at best per transaction. Is a single PostgreSQL server linearizable?

---

## Step 8: Running it for real

**The problem.** Everything so far ran inside a simulator, in one goroutine, with fake time. A real cluster has real clocks, real sockets, real disks and real processes that get `kill -9`'d. The core doesn't change at all; what it needs is the code around it: the **runtime**.

**New ideas.**

- **The runtime loop.** One goroutine owns the core, and only that goroutine ever calls it:
  1. wait for something to happen: a tick of a real `time.Ticker`, a message from a peer, or a proposal from a client;
  2. hand it to the core;
  3. carry out the core's `Ready`: **save** to the WAL with `fsync`, then **send**, then **apply**.

  Because a single goroutine owns the core, the core needs no locks. Everything else talks to that goroutine through channels.
- **Waiting for a proposal.** A client's request becomes a log entry at some index, in some term. The runtime parks the request until that index is applied. If the entry applied there has the *same term*, it's the client's entry, and the state machine's answer goes back to the client. If the term differs, the client's entry was replaced after a change of leader: the request failed, and the client should retry (with the same `Request-Seq`, so it can't happen twice).
- **A transport that never blocks.** Raft tolerates lost messages, but not a stalled loop. Each peer gets its own queue and sender goroutine, and a message that doesn't fit in the queue is dropped. A dead or slow peer then costs nothing but its own messages.
- **Redirects.** Only the leader answers. A follower replies **421 Misdirected Request** and names the leader, if it knows it, and the client goes there.
- **Real timing.** One tick is 100 ms, so a follower stands for election after 1–2 s without a leader. That's a trade-off: a shorter timeout fails over faster, but also suspects a merely slow leader more often (step 1's curve, again).

### The runtime

Create `internal/raft/raftnode/raftnode.go`:

<!-- file: internal/raft/raftnode/raftnode.go -->
~~~go
// Package raftnode runs the Raft core for real: a goroutine that turns
// clock ticks and network messages into calls on raft.Node, saves each
// Ready to the write-ahead log, sends its messages, and applies committed
// entries to the state machine.
//
// The core decides; this package only carries out its decisions, in the
// order Raft requires: save, then send, then apply.
package raftnode

import (
	"context"
	"errors"
	"log/slog"
	"math/rand/v2"
	"sync"
	"time"

	"runway/internal/raft"
	"runway/internal/raft/raftwal"
)

// ErrLost means the entry was accepted but then replaced, because the
// leader that accepted it lost office first. The caller should retry.
var ErrLost = errors.New("raftnode: the proposal was lost in a change of leader")

// ErrStopped means the node has stopped.
var ErrStopped = errors.New("raftnode: stopped")

// StateMachine is what the log drives.
type StateMachine interface {
	Apply(e raft.Entry) any
	Snapshot() ([]byte, error)
	Restore(data []byte) error
}

// Transport sends messages to peers. It must not block: a message it can't
// send at once may be dropped, and Raft will send it again.
type Transport interface {
	Send(msgs []raft.Message)
}

// Config is what Start needs.
type Config struct {
	ID            raft.ID
	Peers         []raft.ID
	Dir           string        // where the write-ahead log and snapshot live
	Tick          time.Duration // how long one tick is
	ElectionTick  int
	HeartbeatTick int
	SnapshotEvery uint64 // compact after this many applied entries
	Machine       StateMachine
	Transport     Transport
	Logger        *slog.Logger
}

type proposal struct {
	data  []byte
	reply chan answer
}

type answer struct {
	value any
	err   error
}

type waiter struct {
	term  uint64
	reply chan answer
}

// Node is a running member.
type Node struct {
	cfg      Config
	core     *raft.Node
	wal      *raftwal.WAL
	proposec chan proposal
	recvc    chan raft.Message
	stopc    chan struct{}
	done     chan struct{}

	mu     sync.Mutex
	status raft.Status

	waiters  map[uint64]waiter // proposals waiting to be applied, by index
	applied  uint64
	snapshot uint64
}

// Start opens the node's saved state, restores the state machine from its
// snapshot, and starts the loop.
func Start(cfg Config) (*Node, error) {
	wal, saved, err := raftwal.Open(cfg.Dir)
	if err != nil {
		return nil, err
	}
	if err := cfg.Machine.Restore(saved.Snapshot.Data); err != nil {
		wal.Close()
		return nil, err
	}
	core := raft.New(raft.Config{
		ID:            cfg.ID,
		Peers:         cfg.Peers,
		ElectionTick:  cfg.ElectionTick,
		HeartbeatTick: cfg.HeartbeatTick,
		Rand:          rand.New(rand.NewPCG(rand.Uint64(), rand.Uint64())),
		PreVote:       true,
		CheckQuorum:   true,
	}, saved)
	n := &Node{
		cfg:      cfg,
		core:     core,
		wal:      wal,
		proposec: make(chan proposal),
		recvc:    make(chan raft.Message, 1024),
		stopc:    make(chan struct{}),
		done:     make(chan struct{}),
		waiters:  map[uint64]waiter{},
		applied:  saved.Snapshot.Index,
		snapshot: saved.Snapshot.Index,
		status:   core.Status(),
	}
	go n.run()
	return n, nil
}

// Step hands the node a message from a peer. It doesn't block: if the node
// is overwhelmed, the message is dropped, as a network might.
func (n *Node) Step(m raft.Message) {
	select {
	case n.recvc <- m:
	default:
	}
}

// Propose adds data to the log and waits until it is applied, returning the
// state machine's answer. It fails with raft.ErrNotLeader on a follower,
// and with ErrLost if a change of leader replaced the entry.
func (n *Node) Propose(ctx context.Context, data []byte) (any, error) {
	p := proposal{data: data, reply: make(chan answer, 1)}
	select {
	case n.proposec <- p:
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-n.done:
		return nil, ErrStopped
	}
	select {
	case a := <-p.reply:
		return a.value, a.err
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-n.done:
		return nil, ErrStopped
	}
}

// Status is the node's latest view.
func (n *Node) Status() raft.Status {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.status
}

// Stop ends the loop and closes the log.
func (n *Node) Stop() error {
	close(n.stopc)
	<-n.done
	return n.wal.Close()
}

func (n *Node) run() {
	defer close(n.done)
	ticker := time.NewTicker(n.cfg.Tick)
	defer ticker.Stop()
	for {
		select {
		case <-n.stopc:
			n.failWaiters(ErrStopped)
			return
		case <-ticker.C:
			n.core.Tick()
		case m := <-n.recvc:
			n.core.Step(m)
		case p := <-n.proposec:
			index, err := n.core.Propose(p.data)
			if err != nil {
				p.reply <- answer{err: err}
				break
			}
			n.waiters[index] = waiter{term: n.core.Status().Term, reply: p.reply}
		}
		if err := n.handleReady(); err != nil {
			// The disk failed: carrying on could break Raft's promises.
			n.cfg.Logger.Error("raft: cannot save state; stopping", "error", err)
			n.failWaiters(err)
			return
		}
	}
}

// handleReady carries out the core's Ready in Raft's order: save, send,
// apply.
func (n *Node) handleReady() error {
	rd := n.core.Ready()
	if err := n.wal.Save(rd.HardState, rd.Snapshot, rd.Entries); err != nil {
		return err
	}
	n.cfg.Transport.Send(rd.Messages)
	if rd.Snapshot != nil {
		if err := n.cfg.Machine.Restore(rd.Snapshot.Data); err != nil {
			return err
		}
		n.applied, n.snapshot = rd.Snapshot.Index, rd.Snapshot.Index
	}
	for _, e := range rd.Committed {
		value := n.cfg.Machine.Apply(e)
		n.applied = e.Index
		if w, ok := n.waiters[e.Index]; ok {
			delete(n.waiters, e.Index)
			if w.term == e.Term {
				w.reply <- answer{value: value}
			} else {
				w.reply <- answer{err: ErrLost} // another entry took this index
			}
		}
	}
	if n.cfg.SnapshotEvery > 0 && n.applied-n.snapshot >= n.cfg.SnapshotEvery {
		if err := n.compact(); err != nil {
			return err
		}
	}
	n.mu.Lock()
	n.status = n.core.Status()
	n.mu.Unlock()
	return nil
}

func (n *Node) compact() error {
	data, err := n.cfg.Machine.Snapshot()
	if err != nil {
		return err
	}
	snap, err := n.core.Compact(n.applied, data)
	if err != nil {
		return err
	}
	if err := n.wal.SaveSnapshot(snap); err != nil {
		return err
	}
	n.snapshot = snap.Index
	return nil
}

func (n *Node) failWaiters(err error) {
	for index, w := range n.waiters {
		w.reply <- answer{err: err}
		delete(n.waiters, index)
	}
}
~~~

If saving fails, the loop **stops** instead of carrying on. A node that can't save what it promised must not promise anything else. Better to be down than to be wrong.

Create `internal/raft/raftnode/transport.go`:

<!-- file: internal/raft/raftnode/transport.go -->
~~~go
package raftnode

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"runway/internal/raft"
)

// HTTPTransport sends each message as JSON in a POST to the peer's
// /raft/message endpoint. Each peer has its own queue and sender goroutine,
// so one slow or dead peer never delays messages to the others.
type HTTPTransport struct {
	queues map[raft.ID]chan raft.Message
	logger *slog.Logger
}

// NewHTTPTransport starts a sender for every peer in urls (by ID).
func NewHTTPTransport(urls map[raft.ID]string, logger *slog.Logger) *HTTPTransport {
	t := &HTTPTransport{queues: map[raft.ID]chan raft.Message{}, logger: logger}
	client := &http.Client{Timeout: time.Second}
	for id, url := range urls {
		queue := make(chan raft.Message, 256)
		t.queues[id] = queue
		go func() {
			for m := range queue {
				body, _ := json.Marshal(m)
				resp, err := client.Post(url+"/raft/message", "application/json", bytes.NewReader(body))
				if err != nil {
					continue // lost: Raft sends again
				}
				resp.Body.Close()
			}
		}()
	}
	return t
}

// Send queues each message for its peer, dropping it if the queue is full.
func (t *HTTPTransport) Send(msgs []raft.Message) {
	for _, m := range msgs {
		select {
		case t.queues[m.To] <- m:
		default:
		}
	}
}

// Handler receives messages from peers and steps them into node.
func Handler(node *Node) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var m raft.Message
		if err := json.NewDecoder(r.Body).Decode(&m); err != nil {
			http.Error(w, "bad message", http.StatusBadRequest)
			return
		}
		node.Step(m)
		w.WriteHeader(http.StatusNoContent)
	})
}
~~~

### The store meets the runtime

The runtime's `StateMachine` hands over whole log entries. Add an adapter at the end of `internal/metastore/store.go`, and import `raft`:

Change:

<!-- edit: internal/metastore/store.go -->
~~~go
	"fmt"
)
~~~

to:

~~~go
	"fmt"

	"runway/internal/raft"
)
~~~

Add this at the end of the file:

<!-- append: internal/metastore/store.go -->
~~~go
// Machine adapts a Store to the Raft runtime, which hands it log entries.
type Machine struct{ Store *Store }

func NewMachine() *Machine { return &Machine{Store: New()} }

func (m *Machine) Apply(e raft.Entry) any {
	r, err := m.Store.ApplyEntry(e.Data)
	if err != nil {
		return err
	}
	return r
}

func (m *Machine) Snapshot() ([]byte, error) { return m.Store.Snapshot() }
func (m *Machine) Restore(data []byte) error { return m.Store.Restore(data) }
~~~


### The HTTP API

Create `internal/metad/metad.go`:

<!-- file: internal/metad/metad.go -->
~~~go
// Package metad is the HTTP face of one member of the metadata cluster:
// clients read and write keys, and peers deliver Raft messages.
//
// Only the leader can answer. A follower says so with 421 Misdirected
// Request and names the leader, if it knows it, so the client can go there.
package metad

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	"runway/internal/metastore"
	"runway/internal/raft"
	"runway/internal/raft/raftnode"
)

// Server serves one member.
type Server struct {
	node    *raftnode.Node
	peers   map[raft.ID]string // every member's base URL, by ID
	timeout time.Duration
}

func New(node *raftnode.Node, peers map[raft.ID]string, timeout time.Duration) *Server {
	return &Server{node: node, peers: peers, timeout: timeout}
}

// Handler returns the routes.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.Handle("POST /raft/message", raftnode.Handler(s.node))
	mux.HandleFunc("GET /status", s.status)
	mux.HandleFunc("GET /kv/{key}", s.op("get"))
	mux.HandleFunc("PUT /kv/{key}", s.op("put"))
	mux.HandleFunc("POST /kv/{key}/append", s.op("append"))
	mux.HandleFunc("POST /kv/{key}/cas", s.op("cas"))
	mux.HandleFunc("DELETE /kv/{key}", s.op("delete"))
	return mux
}

type statusResponse struct {
	ID     raft.ID `json:"id"`
	Role   string  `json:"role"`
	Term   uint64  `json:"term"`
	Leader raft.ID `json:"leader"`
	Commit uint64  `json:"commit"`
}

func (s *Server) status(w http.ResponseWriter, r *http.Request) {
	st := s.node.Status()
	writeJSON(w, http.StatusOK, statusResponse{ID: st.ID, Role: st.Role.String(), Term: st.Term, Leader: st.Leader, Commit: st.Commit})
}

// op handles one kind of command. Every command, reads included, goes
// through the log: that's what makes a read see every write that finished
// before it began.
func (s *Server) op(name string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cmd := metastore.Command{Op: name, Key: r.PathValue("key")}
		// A client that wants exactly-once retries names itself and numbers
		// its requests. Without that, each request is its own client.
		cmd.Client = r.Header.Get("Client-ID")
		cmd.Seq, _ = strconv.ParseUint(r.Header.Get("Request-Seq"), 10, 64)
		if cmd.Client == "" || cmd.Seq == 0 {
			cmd.Client, cmd.Seq = "anonymous-"+rand.Text(), 1
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<10))
		if err != nil {
			writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "body too large"})
			return
		}
		switch name {
		case "put", "append":
			cmd.Value = string(body)
		case "cas":
			var req struct{ Expect, Value string }
			if err := json.Unmarshal(body, &req); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": `cas needs {"expect":"...","value":"..."}`})
				return
			}
			cmd.Expect, cmd.Value = req.Expect, req.Value
		}

		data, _ := json.Marshal(cmd)
		ctx, cancel := context.WithTimeout(r.Context(), s.timeout)
		defer cancel()
		value, err := s.node.Propose(ctx, data)
		switch {
		case errors.Is(err, raft.ErrNotLeader):
			resp := map[string]any{"error": "not the leader"}
			if leader := s.node.Status().Leader; leader != raft.None {
				resp["leader"] = s.peers[leader]
			}
			writeJSON(w, http.StatusMisdirectedRequest, resp)
		case errors.Is(err, raftnode.ErrLost), errors.Is(err, context.DeadlineExceeded):
			w.Header().Set("Retry-After", "1")
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "not committed; retry with the same Request-Seq"})
		case err != nil:
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		default:
			writeJSON(w, http.StatusOK, value)
		}
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
~~~

Keys are a single path segment: `/kv/max_jobs` works, `/kv/runway/max_jobs` doesn't match any route and gets 404. (A `{key...}` pattern would allow slashes, but it must be the last part of a route, so `/kv/{key...}/append` isn't possible.)

### A real cluster in a test

This test runs three members in one process, but with everything real: real disks in temporary directories, real HTTP on random ports, real timers (10 ms ticks, so elections take about 100–200 ms). It stops and restarts members the way an operator would. Create `internal/metad/metad_test.go`:

<!-- file: internal/metad/metad_test.go -->
~~~go
package metad

import (
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"

	"runway/internal/metastore"
	"runway/internal/raft"
	"runway/internal/raft/raftnode"
)

// member is one running server of a test cluster.
type member struct {
	node   *raftnode.Node
	server *http.Server
}

type cluster struct {
	t       *testing.T
	urls    map[raft.ID]string
	dirs    map[raft.ID]string
	members map[raft.ID]*member
}

func newCluster(t *testing.T, size int) *cluster {
	c := &cluster{t: t, urls: map[raft.ID]string{}, dirs: map[raft.ID]string{}, members: map[raft.ID]*member{}}
	listeners := map[raft.ID]net.Listener{}
	for id := raft.ID(1); id <= raft.ID(size); id++ {
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		listeners[id] = l
		c.urls[id] = "http://" + l.Addr().String()
		c.dirs[id] = t.TempDir()
	}
	for id, l := range listeners {
		c.start(id, l)
	}
	t.Cleanup(func() {
		for id := range c.members {
			c.stop(id)
		}
	})
	return c
}

func (c *cluster) start(id raft.ID, l net.Listener) {
	var ids []raft.ID
	others := map[raft.ID]string{}
	for p, u := range c.urls {
		ids = append(ids, p)
		if p != id {
			others[p] = u
		}
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	node, err := raftnode.Start(raftnode.Config{
		ID: id, Peers: ids, Dir: c.dirs[id],
		Tick: 10 * time.Millisecond, ElectionTick: 10, HeartbeatTick: 1, SnapshotEvery: 50,
		Machine: metastore.NewMachine(), Transport: raftnode.NewHTTPTransport(others, logger), Logger: logger,
	})
	if err != nil {
		c.t.Fatal(err)
	}
	server := &http.Server{Handler: New(node, c.urls, 2*time.Second).Handler()}
	go func() { _ = server.Serve(l) }()
	c.members[id] = &member{node: node, server: server}
}

func (c *cluster) stop(id raft.ID) {
	m := c.members[id]
	_ = m.server.Close()
	_ = m.node.Stop()
	delete(c.members, id)
}

// restart brings a stopped member back on the same address and data.
func (c *cluster) restart(id raft.ID) {
	l, err := net.Listen("tcp", strings.TrimPrefix(c.urls[id], "http://"))
	if err != nil {
		c.t.Fatal(err)
	}
	c.start(id, l)
}

func (c *cluster) leader() raft.ID {
	c.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		for id, m := range c.members {
			if m.node.Status().Role == raft.Leader {
				return id
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	c.t.Fatal("no leader within 5 seconds")
	return raft.None
}

func do(t *testing.T, method, url, body string) (int, map[string]any) {
	t.Helper()
	req, _ := http.NewRequest(method, url, strings.NewReader(body))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func TestWritesSurviveTheLeaderStopping(t *testing.T) {
	c := newCluster(t, 3)
	leader := c.leader()
	for i := range 60 { // enough to take a snapshot (every 50 entries)
		if code, _ := do(t, http.MethodPut, c.urls[leader]+"/kv/k", fmt.Sprint("v", i)); code != http.StatusOK {
			t.Fatalf("PUT = %d", code)
		}
	}

	c.stop(leader)
	next := c.leader()
	code, got := do(t, http.MethodGet, c.urls[next]+"/kv/k", "")
	if code != http.StatusOK || got["value"] != "v59" {
		t.Fatalf("after the leader stopped: %d %v", code, got)
	}

	// The old leader comes back, catches up from its disk and the new leader.
	c.restart(leader)
	if code, _ := do(t, http.MethodPut, c.urls[next]+"/kv/k", "after"); code != http.StatusOK {
		t.Fatalf("PUT = %d", code)
	}
	deadline := time.Now().Add(5 * time.Second)
	for c.members[leader].node.Status().Commit < c.members[next].node.Status().Commit {
		if time.Now().After(deadline) {
			t.Fatal("the restarted member never caught up")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestAFollowerPointsToTheLeader(t *testing.T) {
	c := newCluster(t, 3)
	leader := c.leader()
	follower := leader%3 + 1
	deadline := time.Now().Add(5 * time.Second)
	for c.members[follower].node.Status().Leader != leader && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	code, got := do(t, http.MethodGet, c.urls[follower]+"/kv/k", "")
	if code != http.StatusMisdirectedRequest || got["leader"] != c.urls[leader] {
		t.Fatalf("follower answered %d %v; want 421 naming %s", code, got, c.urls[leader])
	}
}

// A retry with the same Client-ID and Request-Seq is applied once.
func TestARetriedAppendHappensOnce(t *testing.T) {
	c := newCluster(t, 3)
	url := c.urls[c.leader()] + "/kv/list/append"
	for range 2 {
		req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader("x;"))
		req.Header.Set("Client-ID", "jobsctl-1")
		req.Header.Set("Request-Seq", "7")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
	}
	if _, got := do(t, http.MethodGet, url[:strings.LastIndex(url, "/")], ""); got["value"] != "x;" {
		t.Fatalf("value %v after a retried append, want x;", got["value"])
	}
}
~~~

### The command

Create `cmd/metad/main.go`:

<!-- file: cmd/metad/main.go -->
~~~go
// Command metad runs one member of Runway's metadata cluster: a key-value
// store replicated with Raft.
//
//	METAD_ID     this member's ID, 1 to n
//	METAD_PEERS  every member, as 1=http://127.0.0.1:7001,2=...,3=...
//	METAD_DATA   the directory for this member's log and snapshot
//
// It listens on the address in its own METAD_PEERS entry.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"runway/internal/envconfig"
	"runway/internal/metad"
	"runway/internal/metastore"
	"runway/internal/raft"
	"runway/internal/raft/raftnode"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Getenv, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// parsePeers reads "1=http://host:port,2=...".
func parsePeers(s string) (map[raft.ID]string, error) {
	peers := map[raft.ID]string{}
	for _, part := range strings.Split(s, ",") {
		idText, u, ok := strings.Cut(part, "=")
		id, err := strconv.Atoi(idText)
		if !ok || err != nil || id < 1 {
			return nil, fmt.Errorf("METAD_PEERS: %q is not ID=URL", part)
		}
		if _, err := url.Parse(u); err != nil {
			return nil, fmt.Errorf("METAD_PEERS: %w", err)
		}
		peers[raft.ID(id)] = u
	}
	return peers, nil
}

func run(ctx context.Context, getenv envconfig.Getenv, stdout io.Writer) error {
	logger := slog.New(slog.NewJSONHandler(stdout, nil))
	id, err := strconv.Atoi(getenv("METAD_ID"))
	if err != nil || id < 1 {
		return errors.New("METAD_ID must be a member ID, 1 or more")
	}
	peers, err := parsePeers(getenv("METAD_PEERS"))
	if err != nil {
		return err
	}
	self, ok := peers[raft.ID(id)]
	if !ok {
		return fmt.Errorf("METAD_PEERS has no entry for member %d", id)
	}
	dir := getenv("METAD_DATA")
	if dir == "" {
		return errors.New("METAD_DATA must name a directory")
	}

	others := map[raft.ID]string{}
	var ids []raft.ID
	for p, u := range peers {
		ids = append(ids, p)
		if p != raft.ID(id) {
			others[p] = u
		}
	}
	slices.Sort(ids)
	node, err := raftnode.Start(raftnode.Config{
		ID:            raft.ID(id),
		Peers:         ids,
		Dir:           dir,
		Tick:          100 * time.Millisecond,
		ElectionTick:  10, // 1 to 2 seconds without a leader before standing
		HeartbeatTick: 1,
		SnapshotEvery: 1000,
		Machine:       metastore.NewMachine(),
		Transport:     raftnode.NewHTTPTransport(others, logger),
		Logger:        logger,
	})
	if err != nil {
		return err
	}
	defer node.Stop()

	u, _ := url.Parse(self)
	listener, err := net.Listen("tcp", u.Host)
	if err != nil {
		return err
	}
	server := &http.Server{Handler: metad.New(node, peers, 3*time.Second).Handler(), ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = server.Serve(listener) }()
	logger.Info("metad started", "id", id, "addr", u.Host, "members", len(ids), "data", dir)

	// Report changes of role, so the logs tell the story of each election.
	last := raft.Status{}
	watch := time.NewTicker(100 * time.Millisecond)
	defer watch.Stop()
	for {
		select {
		case <-ctx.Done():
			shutdown, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			return server.Shutdown(shutdown)
		case <-watch.C:
			if st := node.Status(); st.Role != last.Role || st.Term != last.Term {
				logger.Info("raft state", "role", st.Role.String(), "term", st.Term, "leader", st.Leader)
				last = st
			}
		}
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/raft/... ./internal/metastore/... ./internal/metad/... ./cmd/... -->

~~~bash
go test -v ./internal/metad/
~~~

~~~text
--- PASS: TestWritesSurviveTheLeaderStopping (1.16s)
--- PASS: TestAFollowerPointsToTheLeader (0.13s)
--- PASS: TestARetriedAppendHappensOnce (0.20s)
ok  	runway/internal/metad	1.497s
~~~

Run them ten times (`-count=10`) before trusting them. Tests with real timers can pass once by luck.

### Run it: three processes, then kill the leader

Build it, and start three members in the background. `$!` is the process ID of the last background command; saving each one lets you kill a particular member later.

~~~bash
go build -o metad ./cmd/metad
export METAD_PEERS=1=http://127.0.0.1:7001,2=http://127.0.0.1:7002,3=http://127.0.0.1:7003
for i in 1 2 3; do METAD_ID=$i METAD_DATA=data$i ./metad > metad$i.log 2>&1 & echo $! > metad$i.pid; done
sleep 3
for i in 1 2 3; do curl -s 127.0.0.1:700$i/status; done
~~~

~~~text
{"id":1,"role":"follower","term":1,"leader":2,"commit":1}
{"id":2,"role":"leader","term":1,"leader":2,"commit":1}
{"id":3,"role":"follower","term":1,"leader":2,"commit":1}
~~~

Your leader may be a different node. Below, the leader is node 2; use your own leader's port. Write through a follower, then through the leader:

~~~bash
curl -s -X PUT 127.0.0.1:7003/kv/max_jobs -d 100 -w ' %{http_code}\n'
curl -s -X PUT 127.0.0.1:7002/kv/max_jobs -d 100 -w ' %{http_code}\n'
curl -s 127.0.0.1:7002/kv/max_jobs
~~~

~~~text
{"error":"not the leader","leader":"http://127.0.0.1:7002"}
 421
{"value":"","found":false,"ok":true}
 200
{"value":"100","found":true,"ok":false}
~~~

(`ok` is about the operation: a `put` succeeded; a `get` has nothing to report there.) Now kill the leader the hard way, and ask the others after a few seconds:

~~~bash
kill -9 $(cat metad2.pid)
sleep 3
curl -s 127.0.0.1:7001/status; curl -s 127.0.0.1:7003/status
curl -s 127.0.0.1:7001/kv/max_jobs
~~~

~~~text
{"id":1,"role":"leader","term":2,"leader":1,"commit":4}
{"id":3,"role":"follower","term":2,"leader":1,"commit":4}
{"value":"100","found":true,"ok":false}
~~~

Node 1 won term 2 and the value is there. The cluster lost a third of its machines and lost nothing else. Restart node 2 with its old data directory and it rejoins as a follower:

~~~bash
METAD_ID=2 METAD_DATA=data2 ./metad >> metad2.log 2>&1 & echo $! > metad2.pid
sleep 3
curl -s 127.0.0.1:7002/status
grep '"raft state"' metad2.log
~~~

~~~text
{"id":2,"role":"follower","term":2,"leader":1,"commit":5}
{"msg":"raft state","role":"pre-candidate","term":0,"leader":0}
{"msg":"raft state","role":"leader","term":1,"leader":2}
{"msg":"raft state","role":"follower","term":2,"leader":1}
~~~

(Log lines trimmed.) The log tells node 2's whole life: it started, won term 1, was killed, and came back as a follower in term 2, with everything it had saved. Kill it again (and any other one member) as many times as you like: with two of three up, the cluster keeps answering. Kill two at once, and every request fails until one comes back. That's the majority rule, visible from a shell.

**Break it: every request a stranger.** In `metad.go`, change `if cmd.Client == "" || cmd.Seq == 0 {` to `if true {`, so the server ignores the client's identity:

~~~text
--- FAIL: TestARetriedAppendHappensOnce (0.21s)
    metad_test.go:181: value x;x; after a retried append, want x;
~~~

The client did everything right: it retried with the same `Client-ID` and `Request-Seq`. But the server treated each request as a new anonymous client, so the session couldn't recognise the retry. Exactly-once needs both ends. Restore the line.

**Explain it:** why does one goroutine own the core? What does the runtime do, in order, with each `Ready`, and why does it stop if saving fails? How does a waiting request learn that its entry was lost? What happened, tick by tick, when you killed the leader?

**Read.** The etcd raft package's documentation (`go.etcd.io/raft/v3`, the package overview, especially "Usage" and the `Ready` loop), and its `raftexample` directory. Carry this question in: what does etcd's runtime do that yours doesn't (pipelining, batching, membership changes), and what would each one buy?

---

## Step 9: A TLA+ model of elections

**The problem.** The storm tests ran millions of random interleavings, and still needed a hand-written scenario to find Figure 8. Random search can't promise it has looked everywhere. For the rule at the heart of Raft (one leader per term), you can do better: describe the algorithm abstractly and let a tool check **every** reachable state of a small cluster.

**New ideas.**

- **TLA+** (Lamport) is a language for describing systems as *state machines*: a set of variables, an initial state (`Init`), and the steps that may happen (`Next`). It's maths, not code: there's nothing to compile, and nothing about messages, threads or disks unless you write it in.
- **TLC** is TLA+'s model checker. Given small constants (3 servers, terms up to 3), it explores every state reachable from `Init` by any sequence of `Next` steps, and checks an **invariant** in each one. If the invariant fails, it prints the exact sequence of steps that broke it. It searches breadth-first, so that trace is the shortest one possible.
- **Abstraction.** The model leaves out the log, heartbeats and timers, and combines a vote request and its answer into one step. What's left is exactly what election safety depends on. A model that leaves out too much proves nothing, and one that includes everything is too big to check. Choosing what to keep *is* the skill.
- **A history variable.** `elected` records every `<<server, term>>` that ever won. Checking a property of the *whole history*, not just the current state, catches a second leader in an old term after the first has stepped down.
- **What it does and doesn't prove.** It proves that *this model*, at *this size*, never has two leaders in a term. It says nothing about your Go code matching the model, or about 7 servers. In practice, small models find almost every design bug (the "small scope hypothesis"). Industry uses TLA+ for exactly that: AWS has used it on DynamoDB, S3 and others since 2011.

### The model

Create `tla/RaftElection.tla`:

<!-- file: tla/RaftElection.tla -->
~~~tla
---------------------------- MODULE RaftElection ----------------------------
(* Raft's leader election, and nothing else: terms, votes, and becoming    *)
(* leader. Sending a vote request and getting the answer are modelled as  *)
(* one step, which hides message loss and delay but keeps every order in  *)
(* which servers can time out, vote and win.                              *)
EXTENDS Naturals, FiniteSets

CONSTANTS Servers, MaxTerm

VARIABLES
    term,      \* each server's current term
    role,      \* "follower", "candidate" or "leader"
    votedFor,  \* whom each server voted for in its current term, or Nil
    votes,     \* the votes each candidate has collected
    elected    \* history: every <<server, term>> that ever won

vars == <<term, role, votedFor, votes, elected>>

Nil == "nil"

\* A quorum is any set of more than half the servers.
IsQuorum(S) == Cardinality(S) * 2 > Cardinality(Servers)

Init ==
    /\ term     = [s \in Servers |-> 0]
    /\ role     = [s \in Servers |-> "follower"]
    /\ votedFor = [s \in Servers |-> Nil]
    /\ votes    = [s \in Servers |-> {}]
    /\ elected  = {}

\* Server s times out and stands for election in a new term, voting for
\* itself.
Timeout(s) ==
    /\ role[s] # "leader"
    /\ term[s] < MaxTerm
    /\ term'     = [term     EXCEPT ![s] = @ + 1]
    /\ role'     = [role     EXCEPT ![s] = "candidate"]
    /\ votedFor' = [votedFor EXCEPT ![s] = s]
    /\ votes'    = [votes    EXCEPT ![s] = {s}]
    /\ UNCHANGED elected

\* Server v votes for candidate c. A newer term resets v's vote, and v
\* becomes a follower; within one term, v votes at most once.
Vote(v, c) ==
    /\ v # c
    /\ role[c] = "candidate"
    /\ term[v] <= term[c]
    /\ term[v] < term[c] \/ votedFor[v] \in {Nil, c}
    /\ term'     = [term     EXCEPT ![v] = term[c]]
    /\ role'     = [role     EXCEPT ![v] = "follower"]
    /\ votedFor' = [votedFor EXCEPT ![v] = c]
    /\ votes'    = [votes    EXCEPT ![c] = @ \cup {v}]
    /\ UNCHANGED elected

\* A candidate with votes from a quorum becomes leader.
BecomeLeader(c) ==
    /\ role[c] = "candidate"
    /\ IsQuorum(votes[c])
    /\ role'    = [role EXCEPT ![c] = "leader"]
    /\ elected' = elected \cup {<<c, term[c]>>}
    /\ UNCHANGED <<term, votedFor, votes>>

Next ==
    \E s \in Servers :
        \/ Timeout(s)
        \/ BecomeLeader(s)
        \/ \E v \in Servers : Vote(v, s)

Spec == Init /\ [][Next]_vars

\* The property: no term ever has two leaders, at any time in the history.
ElectionSafety ==
    \A x, y \in elected : x[2] = y[2] => x[1] = y[1]

=============================================================================
~~~

Read it next to `raft.go`:

| TLA+ | Go |
|---|---|
| `Timeout(s)` | `campaign` |
| `Vote(v, c)`: the guard `term[v] < term[c] \/ votedFor[v] \in {Nil, c}` | `grant := (n.vote == None \|\| n.vote == m.From) && ...`, after `becomeFollower` on a higher term |
| `BecomeLeader(c)` | `countVote` reaching a quorum |
| `ElectionSafety` | the simulator's `check` |

`'` marks a variable's value in the *next* state. `EXCEPT ![s] = @ + 1` means "the same function, except at `s`, where it's the old value plus one". `UNCHANGED` lists variables a step leaves alone: every step must say what happens to every variable.

Create `tla/RaftElection.cfg`, which tells TLC what to check, and at what size:

<!-- file: tla/RaftElection.cfg -->
~~~text
SPECIFICATION Spec
CONSTANTS
    Servers = {s1, s2, s3}
    MaxTerm = 3
INVARIANT ElectionSafety
~~~

Keep the TLA+ tools and TLC's scratch files out of Git. `.gitignore` becomes:

<!-- file: .gitignore -->
~~~text
audit/target/
tla/tla2tools.jar
tla/states/
tla/*_TTrace_*.tla
~~~

### Check it

Download the TLA+ tools (one Java file) and run TLC. `-deadlock` turns off deadlock checking: when every server reaches `MaxTerm`, nothing more can happen, and that's expected.

<!-- run: cd tla && (test -f tla2tools.jar || curl -sSLo tla2tools.jar https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar) && java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC -deadlock -workers 1 -config RaftElection.cfg RaftElection.tla -->
~~~bash
cd tla
curl -sSLo tla2tools.jar https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar
java -cp tla2tools.jar tlc2.TLC -deadlock -workers 1 -config RaftElection.cfg RaftElection.tla
~~~

~~~text
Model checking completed. No error has been found.
14029 states generated, 4687 distinct states found, 0 states left on queue.
The depth of the complete state graph search is 13.
Finished in 01s
~~~

(Trimmed to the important lines.) TLC visited all 4,687 distinct states that three servers can reach with terms up to 3, and `ElectionSafety` held in every one. That's every interleaving: not a sample of them.

**Break it: vote twice.** In `Vote`, delete the line `/\ term[v] < term[c] \/ votedFor[v] \in {Nil, c}`, and run TLC again:

~~~text
Error: Invariant ElectionSafety is violated.
Error: The behavior up to this point is:
State 1: <Initial predicate>
State 2: <Timeout(s1) ...>
/\ term = (s1 :> 1 @@ s2 :> 0 @@ s3 :> 0)
State 3: <Vote(s2,s1) ...>
State 4: <BecomeLeader(s1) ...>
/\ elected = {<<s1, 1>>}
State 5: <Timeout(s3) ...>
/\ term = (s1 :> 1 @@ s2 :> 1 @@ s3 :> 1)
State 6: <Vote(s1,s3) ...>
/\ votedFor = (s1 :> s3 @@ s2 :> s1 @@ s3 :> s3)
State 7: <BecomeLeader(s3) ...>
/\ elected = {<<s1, 1>>, <<s3, 1>>}
830 distinct states found, 532 states left on queue.
~~~

(Each state lists every variable; only the ones that matter are kept here.) Read it as a story:
1. Server 1 times out, starts term 1, and server 2 votes for it.
2. Server 1 becomes leader of term 1.
3. Server 3 times out and starts term 1 as well: its own term was 0.
4. Server 1, the leader itself, votes for server 3, because nothing stops a second vote in the same term.
5. Server 3 becomes the second leader of term 1.

Seven states, the shortest counterexample there is, found after looking at only 830 states. Restore the line. (Delete the `states/` directory and `*_TTrace_*` files TLC leaves behind whenever you like; `.gitignore` already ignores them.)

**Explain it:** what does TLC check that the storm tests don't, and what do the storm tests check that TLC doesn't? Why does the model need the `elected` history variable? What did the model leave out, and why is that acceptable for election safety?

**Read.** Lamport, *Specifying Systems*, Part I (chapters 1–7), or the shorter *TLA+ Video Course* lectures 1–6. Then Newcombe et al., *How Amazon Web Services Uses Formal Methods* (CACM 2015). And Diego Ongaro's TLA+ specification of the whole of Raft (in the `raft.tla` repository linked from raft.github.io). Carry this question in: how would you add the log to this model, and what invariant would you check?

---

## Step 10: Locks with leases, and fencing tokens

**The problem.** In Phase 3, Runway's background tasks used a PostgreSQL advisory lock so that only one instance ran each task. That works while there's one database. With a replicated metadata store, Runway can take locks there instead. But a distributed lock has a trap that no amount of careful code in the lock service can fix:
1. Client A takes the lock.
2. A pauses (a long garbage collection, a stopped VM, a slow disk) for longer than the lock's lease.
3. The lease expires and B takes the lock.
4. A wakes up, still believing it holds the lock, and writes.

Both are now acting as "the" lock holder, and nothing told A it had lost.

**New ideas.**

- **A lease** is a lock with an expiry. If the holder dies, the lock frees itself when the lease ends; no one has to notice the death. The holder must **renew** before the lease runs out, to keep it.
- **Time in a replicated state machine.** The state machine can't read the clock: nodes apply the same command at different moments, and would disagree about what had expired. So the leader reads its clock **once**, when it proposes the command, and puts the time in the command. Every node then applies the same time. That moves the clock problem to the leader. If leadership changes and the new leader's clock is behind, a lease can last longer than intended. Systems that depend on lease timing assume a bound on clock drift, and leave a safety margin.
- **The pause can't be prevented, so it must be detected.** A process can't know it was paused. Checking "do I still hold the lock?" just before writing doesn't help either: the pause can strike between the check and the write.
- **Fencing tokens** (Kleppmann, *How to do distributed locking*). Every time the lock gets a *new holder*, it hands out a higher number, the token. Every write to the protected resource carries the writer's token, and the resource refuses any token lower than the highest it has seen. Once B has written with token 2, A's late write with token 1 is refused. The check happens where it can't be bypassed: at the resource.
- In a real system, the resource is often a database. Runway's version would be `UPDATE ... SET ..., fence = $token WHERE fence <= $token`, so the database itself refuses stale writers.

### Locks in the store

The changes to `internal/metastore/store.go`:
1. Commands gain an owner, a time-to-live, and the leader's clock (`At`).
2. Results gain the token, the expiry, and the current holder.
3. The store keeps its locks and the last token handed out.
4. `acquire` and `release` are two new commands.

Change:

<!-- edit: internal/metastore/store.go -->
~~~go
	Op     string `json:"op"` // get, put, append, cas or delete
~~~

to:

~~~go
	Op     string `json:"op"` // get, put, append, cas, delete, acquire or release
~~~

Change:

<!-- edit: internal/metastore/store.go -->
~~~go
	Expect string `json:"expect,omitempty"` // cas: the value the key must have now
}
~~~

to:

~~~go
	Expect string `json:"expect,omitempty"` // cas: the value the key must have now
	// Locks. Owner names who wants the lock; TTL is how long the lease
	// lasts. At is the leader's clock when it proposed the command: the
	// state machine can't read a clock itself, or nodes applying the same
	// command at different moments would disagree about what expired.
	Owner string `json:"owner,omitempty"`
	TTL   int64  `json:"ttl_ms,omitempty"`
	At    int64  `json:"at_ms,omitempty"`
}
~~~

Change:

<!-- edit: internal/metastore/store.go -->
~~~go
	OK    bool   `json:"ok"` // cas: whether it swapped; delete: whether the key existed
~~~

to:

~~~go
	OK    bool   `json:"ok"` // cas: whether it swapped; delete: whether the key existed; acquire: whether you hold the lock
	// acquire: the fencing token, and when the lease ends (leader's clock).
	Token   uint64 `json:"token,omitempty"`
	Expires int64  `json:"expires_ms,omitempty"`
	Holder  string `json:"holder,omitempty"` // acquire, when refused: who holds it
~~~

Change:

<!-- edit: internal/metastore/store.go -->
~~~go
	Sessions map[string]Session `json:"sessions"`
}
~~~

to:

~~~go
	Sessions map[string]Session `json:"sessions"`
	Locks    map[string]Lock    `json:"locks"`
	Tokens   uint64             `json:"tokens"` // the last fencing token handed out
}

// Lock is a lease on a name: Owner holds it until Expires, unless it
// renews. Token increases with every new holder, never with a renewal.
type Lock struct {
	Owner   string `json:"owner"`
	Token   uint64 `json:"token"`
	Expires int64  `json:"expires_ms"`
}
~~~

Change:

<!-- edit: internal/metastore/store.go -->
~~~go
	return &Store{Data: map[string]string{}, Sessions: map[string]Session{}}
~~~

to:

~~~go
	return &Store{Data: map[string]string{}, Sessions: map[string]Session{}, Locks: map[string]Lock{}}
~~~

Change:

<!-- edit: internal/metastore/store.go -->
~~~go
		delete(s.Data, cmd.Key)
	}
	s.Sessions[cmd.Client] = Session{Seq: cmd.Seq, Result: r}
	return r
}

~~~

to:

~~~go
		delete(s.Data, cmd.Key)
	case "acquire":
		r = s.acquire(cmd)
	case "release":
		if lock, ok := s.Locks[cmd.Key]; ok && lock.Owner == cmd.Owner {
			delete(s.Locks, cmd.Key)
			r.OK = true
		}
	}
	s.Sessions[cmd.Client] = Session{Seq: cmd.Seq, Result: r}
	return r
}

// acquire grants the lock if it's free, expired, or already held by the
// same owner (a renewal, which keeps the token). A new holder gets a new,
// higher token.
func (s *Store) acquire(cmd Command) Result {
	lock, held := s.Locks[cmd.Key]
	switch {
	case held && lock.Owner != cmd.Owner && cmd.At < lock.Expires:
		return Result{Holder: lock.Owner, Expires: lock.Expires}
	case !held || lock.Owner != cmd.Owner || cmd.At >= lock.Expires:
		s.Tokens++
		lock = Lock{Owner: cmd.Owner, Token: s.Tokens}
	}
	lock.Expires = cmd.At + cmd.TTL
	s.Locks[cmd.Key] = lock
	return Result{OK: true, Token: lock.Token, Expires: lock.Expires}
}

~~~


Read `acquire` closely:
- if someone else holds an unexpired lease, it's refused, and told who holds it and until when;
- if the lock is free, expired, or held by someone else whose lease has run out, it gets a **new, higher token**;
- if it's a renewal by the current holder, it keeps the **same** token, with a later expiry.

Add a test for the rules, at the end of `internal/metastore/store_test.go`:

Add this at the end of the file:

<!-- append: internal/metastore/store_test.go -->
~~~go
func TestLocksAreLeases(t *testing.T) {
	s := New()
	cmd := func(seq uint64, op, owner string, at int64) Result {
		return s.Apply(Command{Client: owner, Seq: seq, Op: op, Key: "l", Owner: owner, TTL: 1000, At: at})
	}
	if r := cmd(1, "acquire", "a", 0); !r.OK || r.Token != 1 || r.Expires != 1000 {
		t.Fatalf("first acquire: %+v", r)
	}
	if r := cmd(1, "acquire", "b", 500); r.OK || r.Holder != "a" {
		t.Fatalf("acquire while held: %+v", r)
	}
	if r := cmd(2, "acquire", "a", 800); !r.OK || r.Token != 1 || r.Expires != 1800 {
		t.Fatalf("renewal must keep the token and extend the lease: %+v", r)
	}
	if r := cmd(2, "acquire", "b", 2000); !r.OK || r.Token != 2 {
		t.Fatalf("acquire after expiry must give a new, higher token: %+v", r)
	}
	if r := cmd(3, "release", "a", 2100); r.OK {
		t.Fatal("a released a lock it no longer holds")
	}
	if r := cmd(3, "release", "b", 2100); !r.OK {
		t.Fatal("b couldn't release its lock")
	}
}
~~~


### A fenced resource, and the pause

Create `internal/fence/fence.go`:

<!-- file: internal/fence/fence.go -->
~~~go
// Package fence protects a resource with fencing tokens.
//
// A lease-based lock can't stop an old holder from acting after its lease
// has ended: the holder may simply not know, because it was paused (a long
// garbage collection, a stopped VM, a slow disk) or its clock ran slow. So
// the resource itself must check. Every write carries the writer's token,
// and the resource refuses any token lower than the highest it has seen.
// Tokens increase with every new lock holder, so an old holder's writes
// are refused from the moment a newer holder writes.
package fence

import (
	"errors"
	"fmt"
	"sync"
)

// ErrStale means a newer lock holder has already written.
var ErrStale = errors.New("fence: a newer lock holder has written")

// Resource is a value protected by fencing tokens.
type Resource struct {
	mu      sync.Mutex
	highest uint64
	value   string
	check   bool
}

// New returns a resource. With check false it accepts every write, which
// is what an unfenced resource does.
func New(check bool) *Resource { return &Resource{check: check} }

// Write sets the value if token isn't older than any token seen before.
func (r *Resource) Write(token uint64, value string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.check && token < r.highest {
		return fmt.Errorf("%w: token %d, but %d has been seen", ErrStale, token, r.highest)
	}
	r.highest = max(r.highest, token)
	r.value = value
	return nil
}

func (r *Resource) Value() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.value
}
~~~

Create `internal/fence/fence_test.go`, which acts out Kleppmann's story with exact times, using the store directly:

<!-- file: internal/fence/fence_test.go -->
~~~go
package fence

import (
	"errors"
	"testing"

	"runway/internal/metastore"
)

// The story from Kleppmann's "How to do distributed locking": client A takes
// the lock, pauses for longer than its lease, and wakes up still believing
// it holds the lock, after B has taken it and written.
func scenario(t *testing.T, r *Resource) (aErr error) {
	t.Helper()
	locks := metastore.New()
	acquire := func(owner string, seq uint64, at int64) metastore.Result {
		return locks.Apply(metastore.Command{Client: owner, Seq: seq, Op: "acquire", Key: "reaper", Owner: owner, TTL: 10_000, At: at})
	}

	a := acquire("a", 1, 0) // A holds the lock until t=10s, with token 1
	if !a.OK || a.Token != 1 {
		t.Fatalf("A's acquire: %+v", a)
	}
	// A pauses here for 15 seconds. Its lease runs out at t=10s.
	if early := acquire("b", 1, 5_000); early.OK {
		t.Fatal("B got the lock while A's lease was still running")
	}
	b := acquire("b", 2, 12_000) // the lease has expired: B gets token 2
	if !b.OK || b.Token != 2 {
		t.Fatalf("B's acquire: %+v", b)
	}
	if err := r.Write(b.Token, "B's update"); err != nil {
		t.Fatal(err)
	}
	// A wakes at t=15s. As far as it knows, it still holds the lock.
	return r.Write(a.Token, "A's update")
}

func TestWithoutFencingTheOldHolderOverwrites(t *testing.T) {
	r := New(false)
	if err := scenario(t, r); err != nil {
		t.Fatal(err)
	}
	if r.Value() != "A's update" {
		t.Fatalf("value %q", r.Value())
	}
	t.Log("B's update was silently overwritten by a client whose lease had expired")
}

func TestFencingRefusesTheOldHolder(t *testing.T) {
	r := New(true)
	err := scenario(t, r)
	if !errors.Is(err, ErrStale) {
		t.Fatalf("A's late write: %v, want ErrStale", err)
	}
	if r.Value() != "B's update" {
		t.Fatalf("value %q, want B's update", r.Value())
	}
	t.Logf("A's late write was refused: %v", err)
}
~~~

### Locks over HTTP

Add the routes in `internal/metad/metad.go`. The leader stamps the time:

Change:

<!-- edit: internal/metad/metad.go -->
~~~go
	mux.HandleFunc("DELETE /kv/{key}", s.op("delete"))
	return mux
~~~

to:

~~~go
	mux.HandleFunc("DELETE /kv/{key}", s.op("delete"))
	mux.HandleFunc("POST /locks/{key}/acquire", s.op("acquire"))
	mux.HandleFunc("POST /locks/{key}/release", s.op("release"))
	return mux
~~~

Change:

<!-- edit: internal/metad/metad.go -->
~~~go
			cmd.Expect, cmd.Value = req.Expect, req.Value
		}
~~~

to:

~~~go
			cmd.Expect, cmd.Value = req.Expect, req.Value
		case "acquire", "release":
			var req struct {
				Owner string `json:"owner"`
				TTL   int64  `json:"ttl_ms"`
			}
			if err := json.Unmarshal(body, &req); err != nil || req.Owner == "" || (name == "acquire" && req.TTL <= 0) {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": `locks need {"owner":"...","ttl_ms":N}`})
				return
			}
			cmd.Owner, cmd.TTL = req.Owner, req.TTL
			// The leader's clock, read once, here. Every node then applies
			// the same time.
			cmd.At = time.Now().UnixMilli()
		}
~~~


And a test that tokens increase when the holder changes, at the end of `internal/metad/metad_test.go`:

Add this at the end of the file:

<!-- append: internal/metad/metad_test.go -->
~~~go
func TestLockTokensIncrease(t *testing.T) {
	c := newCluster(t, 3)
	url := c.urls[c.leader()] + "/locks/reaper"
	code, a := do(t, http.MethodPost, url+"/acquire", `{"owner":"a","ttl_ms":200}`)
	if code != http.StatusOK || a["ok"] != true {
		t.Fatalf("a's acquire: %d %v", code, a)
	}
	if _, b := do(t, http.MethodPost, url+"/acquire", `{"owner":"b","ttl_ms":200}`); b["ok"] == true || b["holder"] != "a" {
		t.Fatalf("b got a held lock: %v", b)
	}
	time.Sleep(300 * time.Millisecond) // a's lease runs out
	_, b := do(t, http.MethodPost, url+"/acquire", `{"owner":"b","ttl_ms":200}`)
	if b["ok"] != true || b["token"].(float64) <= a["token"].(float64) {
		t.Fatalf("after the lease expired: a had %v, b got %v", a, b)
	}
}
~~~


<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/metastore/... ./internal/fence/... ./internal/metad/... -->

~~~bash
go test -v ./internal/fence/
~~~

~~~text
    fence_test.go:47: B's update was silently overwritten by a client whose lease had expired
--- PASS: TestWithoutFencingTheOldHolderOverwrites (0.00s)
    fence_test.go:59: A's late write was refused: fence: a newer lock holder has written: token 1, but 2 has been seen
--- PASS: TestFencingRefusesTheOldHolder (0.00s)
ok  	runway/internal/fence	0.007s
~~~

The lock service behaved perfectly in both tests: it never had two holders at once. The difference was entirely at the resource.

### Run it

Start the three members as in step 8, find the leader, and take the `reaper` lock from two API instances:

~~~bash
U=127.0.0.1:7002/locks/reaper   # use your leader's port
curl -s -X POST $U/acquire -d '{"owner":"api-1","ttl_ms":5000}'
curl -s -X POST $U/acquire -d '{"owner":"api-2","ttl_ms":5000}'
curl -s -X POST $U/acquire -d '{"owner":"api-1","ttl_ms":5000}'
sleep 6
curl -s -X POST $U/acquire -d '{"owner":"api-2","ttl_ms":5000}'
curl -s -X POST $U/release -d '{"owner":"api-1"}'
~~~

~~~text
{"value":"","found":false,"ok":true,"token":1,"expires_ms":1791270005888}
{"value":"","found":false,"ok":false,"expires_ms":1791270005888,"holder":"api-1"}
{"value":"","found":false,"ok":true,"token":1,"expires_ms":1791270005944}
{"value":"","found":false,"ok":true,"token":2,"expires_ms":1791270011974}
{"value":"","found":false,"ok":false}
~~~

In order:
1. `api-1` got token 1.
2. `api-2` was refused, and told who holds the lock and until when.
3. `api-1` renewed, keeping token 1 with a later expiry.
4. After the lease ran out, `api-2` got token 2.
5. `api-1`'s release was refused: it doesn't hold the lock any more, whatever it believes.

The expiry times are milliseconds since 1970 on the leader's clock.

**Break it: leases that never block.** In `acquire`, change `case held && lock.Owner != cmd.Owner && cmd.At < lock.Expires:` to `case held && lock.Owner != cmd.Owner && false:`:

~~~text
--- FAIL: TestLocksAreLeases (0.00s)
    store_test.go:69: acquire while held: {Value: Found:false OK:true Token:2 Expires:1500 Holder:}
~~~

`b` took the lock while `a` still held it. The fencing test fails too, at its first check. Fencing tokens protect against a holder that *doesn't know* it lost the lock; they're no substitute for a lock that works. Restore the line.

**Explain it:** what does a lease add to a lock, and what does it assume about clocks? Why can't the lock holder detect its own pause, even by checking just before it writes? How do fencing tokens make the *resource* safe? Why does a renewal keep the token, and a new holder get a new one?

**Read.** Martin Kleppmann, *How to do distributed locking* (2016). Then Burrows, *The Chubby lock service for loosely-coupled distributed systems* (OSDI 2006), §2.4 (sequencers, which are fencing tokens) and §2.8 (sessions and KeepAlives). Carry this question in: Chubby's sequencer and your token solve the same problem. What does Chubby do that your service doesn't?

---

## Step 11: Consistent hashing, and a cache spread over several servers

**The problem.** Replication makes data *safe*; it doesn't make it *bigger*. Every Raft node holds everything, and every write goes through one leader. When data or traffic outgrows a machine, you must **partition** (or **shard**) it: split the keys so each machine holds only some of them.

The obvious way to choose a key's machine is `hash(key) mod N`. Then you add a machine, `N` changes, and almost every key's machine changes with it. For a cache, that means nearly every cached copy is suddenly in the wrong place: a stampede of misses onto the database, at exactly the moment you were adding capacity because load was high.

**New ideas.**

- **Consistent hashing** (Karger et al., 1997). Hash both keys and nodes onto the same circle of numbers. A key belongs to the first node at or after its own position, going round. Adding a node takes over only the keys just before its position; every other key stays put. The share of keys that moves is about 1/N, the new node's fair share, and the moved keys go only to the new node.
- **Virtual nodes.** With one point per node, the gaps between points vary wildly, and so do the nodes' shares. Giving each node many points (100 here) averages the gaps out. It also means a node's keys, when it leaves, scatter across all the others instead of all landing on its neighbour.
- **Rendezvous hashing** (highest random weight) is the other common answer: score every node for each key, and pick the highest. It needs no ring, and moves the same 1/N, but costs O(N) per lookup. go-redis uses it by default; you'll replace it with your ring.
- **Hot keys.** Hashing spreads *keys*, not *traffic*. If half of all requests are for one key, the node that owns it carries half the load, however good the hashing is. The fixes: split the key into sub-keys (`job:hot#0`…`job:hot#31`) read at random, add replicas for reads, or cache it closer to the clients.
- **Rebalancing** is the expensive part in practice: moving data, not choosing where it goes. Caches can skip it (a moved key is just a miss), which is why this step shards the cache first. Databases must copy the data before switching ownership, and that's what tools like Vitess and CockroachDB spend most of their code on.

### The ring

Create `internal/ring/ring.go`:

<!-- file: internal/ring/ring.go -->
~~~go
// Package ring spreads keys over nodes with consistent hashing (Karger et
// al., 1997).
//
// Each node is placed at many points on a circle of hash values: its
// virtual nodes. A key belongs to the first point at or after the key's own
// hash, going round the circle. When a node joins, it takes over only the
// keys just before its new points; every other key stays where it was. With
// hash(key) mod N, by contrast, changing N moves almost every key.
package ring

import (
	"hash/fnv"
	"slices"
	"strconv"
)

type point struct {
	hash uint64
	node string
}

// Ring is a set of nodes on the circle. It isn't safe for concurrent
// changes; build a new one instead of changing a shared one.
type Ring struct {
	vnodes int
	points []point // sorted by hash
}

// New returns an empty ring that gives each node vnodes points.
func New(vnodes int, nodes ...string) *Ring {
	r := &Ring{vnodes: vnodes}
	for _, n := range nodes {
		r.Add(n)
	}
	return r
}

// Add puts a node's points on the circle.
func (r *Ring) Add(node string) {
	for i := range r.vnodes {
		r.points = append(r.points, point{hash: Hash(node + "#" + strconv.Itoa(i)), node: node})
	}
	slices.SortFunc(r.points, func(a, b point) int {
		switch {
		case a.hash < b.hash:
			return -1
		case a.hash > b.hash:
			return 1
		}
		return 0
	})
}

// Remove takes a node's points off the circle.
func (r *Ring) Remove(node string) {
	r.points = slices.DeleteFunc(r.points, func(p point) bool { return p.node == node })
}

// Get returns the node that owns key, or "" if the ring is empty.
func (r *Ring) Get(key string) string {
	if len(r.points) == 0 {
		return ""
	}
	h := Hash(key)
	i, _ := slices.BinarySearchFunc(r.points, h, func(p point, h uint64) int {
		switch {
		case p.hash < h:
			return -1
		case p.hash > h:
			return 1
		}
		return 0
	})
	if i == len(r.points) {
		i = 0 // past the last point: wrap round to the first
	}
	return r.points[i].node
}

// Hash is 64-bit FNV-1a, followed by a final mixing step (from
// SplitMix64). FNV alone gives similar strings, such as "node#1" and
// "node#2", similar hashes, which would bunch a node's points together.
func Hash(s string) uint64 {
	h := fnv.New64a()
	h.Write([]byte(s))
	x := h.Sum64()
	x ^= x >> 30
	x *= 0xbf58476d1ce4e5b9
	x ^= x >> 27
	x *= 0x94d049bb133111eb
	x ^= x >> 31
	return x
}

// ModN is the naive alternative: hash the key and take the remainder.
func ModN(key string, nodes []string) string {
	return nodes[Hash(key)%uint64(len(nodes))]
}
~~~

Create `internal/ring/ring_test.go`, three experiments as tests:

<!-- file: internal/ring/ring_test.go -->
~~~go
package ring

import (
	"fmt"
	"testing"
)

func keys(n int) []string {
	ks := make([]string, n)
	for i := range ks {
		ks[i] = fmt.Sprint("job:", i)
	}
	return ks
}

// Going from 4 nodes to 5, a fifth of the keys should move: the new node's
// fair share, and no more. With mod N, most keys move.
func TestAddingANodeMovesOnlyItsShare(t *testing.T) {
	four := []string{"a", "b", "c", "d"}
	five := append(four[:4:4], "e")
	r := New(100, four...)
	before := map[string]string{}
	for _, k := range keys(100_000) {
		before[k] = r.Get(k)
	}
	r.Add("e")

	ringMoved, modMoved := 0, 0
	for _, k := range keys(100_000) {
		if now := r.Get(k); now != before[k] {
			ringMoved++
			if now != "e" {
				t.Fatalf("key %s moved from %s to %s; keys may only move to the new node", k, before[k], now)
			}
		}
		if ModN(k, four) != ModN(k, five) {
			modMoved++
		}
	}
	t.Logf("adding a 5th node moved %.1f%% of keys on the ring, %.1f%% with mod N",
		float64(ringMoved)/1000, float64(modMoved)/1000)
	if ringMoved > 25_000 || modMoved < 70_000 {
		t.Fatalf("ring moved %d, mod N moved %d", ringMoved, modMoved)
	}
}

// imbalance is the busiest node's load divided by the average load.
func imbalance(r *Ring, ks []string, nodes int) float64 {
	load := map[string]int{}
	for _, k := range ks {
		load[r.Get(k)]++
	}
	busiest := 0
	for _, n := range load {
		busiest = max(busiest, n)
	}
	return float64(busiest) / (float64(len(ks)) / float64(nodes))
}

// With one point each, the gaps between points vary wildly, and so does
// each node's share. Many points per node average the gaps out.
func TestVirtualNodesEvenOutTheLoad(t *testing.T) {
	nodes := []string{"a", "b", "c", "d", "e"}
	ks := keys(100_000)
	for _, v := range []int{1, 10, 100, 1000} {
		t.Logf("%4d virtual nodes each: the busiest node has %.2fx the average load", v, imbalance(New(v, nodes...), ks, 5))
	}
	if one, many := imbalance(New(1, nodes...), ks, 5), imbalance(New(100, nodes...), ks, 5); one < 1.3 || many > 1.25 {
		t.Fatalf("imbalance %.2f with 1 vnode, %.2f with 100", one, many)
	}
}

// One hot key goes to one node, however good the hashing. Splitting it
// into sub-keys (key#0 ... key#7, read at random) spreads its traffic.
func TestAHotKeyNeedsSplitting(t *testing.T) {
	nodes := []string{"a", "b", "c", "d", "e"}
	r := New(100, nodes...)
	traffic := func(split int) float64 {
		load := map[string]int{}
		for i := range 100_000 {
			key := fmt.Sprint("job:", i)
			if i%2 == 0 { // half of all requests are for one job
				key = "job:hot"
				if split > 1 {
					key = fmt.Sprint("job:hot#", i%split)
				}
			}
			load[r.Get(key)]++
		}
		busiest := 0
		for _, n := range load {
			busiest = max(busiest, n)
		}
		return float64(busiest) / 20_000
	}
	whole := traffic(1)
	t.Logf("one hot key: the busiest node has %.2fx the average load", whole)
	for _, n := range []int{8, 32} {
		t.Logf("split %2d ways: %.2fx", n, traffic(n))
	}
	if whole < 2.5 || traffic(32) > whole*0.6 {
		t.Fatalf("hot key %.2f, split 32 ways %.2f", whole, traffic(32))
	}
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./internal/ring/... && go test -race -count=1 ./internal/ring/... -->

~~~bash
go test -v ./internal/ring/
~~~

~~~text
    ring_test.go:40: adding a 5th node moved 21.3% of keys on the ring, 80.0% with mod N
--- PASS: TestAddingANodeMovesOnlyItsShare (0.11s)
    ring_test.go:66:    1 virtual nodes each: the busiest node has 2.39x the average load
    ring_test.go:66:   10 virtual nodes each: the busiest node has 1.23x the average load
    ring_test.go:66:  100 virtual nodes each: the busiest node has 1.10x the average load
    ring_test.go:66: 1000 virtual nodes each: the busiest node has 1.03x the average load
--- PASS: TestVirtualNodesEvenOutTheLoad (0.08s)
    ring_test.go:97: one hot key: the busiest node has 3.00x the average load
    ring_test.go:99: split  8 ways: 1.78x
    ring_test.go:99: split 32 ways: 1.47x
--- PASS: TestAHotKeyNeedsSplitting (0.12s)
ok  	runway/internal/ring	0.312s
~~~

Three results to remember:
- Going from 4 to 5 nodes moved 21.3% of keys with the ring (the ideal is 20%) and 80% with mod N. Every moved key went to the new node.
- One point per node left the busiest node with 2.39 times its fair share; 100 points, 1.10.
- A hot key making up half the traffic put three times the average load on one node, and splitting it 32 ways cut that to 1.47. (Eight sub-keys can't spread evenly over five nodes; 32 come closer.)

### Runway's cache over several Redis servers

Two more Redis servers. In `compose.yaml`, change:

<!-- edit: compose.yaml -->
~~~yaml
volumes:
  pgdata:
~~~

to:

~~~yaml
  # Two more Redis servers, for the cache ring (Phase 4, step 11).
  redis-2:
    image: redis:8
    ports:
      - "6380:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 5s
      retries: 20

  redis-3:
    image: redis:8
    ports:
      - "6381:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      timeout: 5s
      retries: 20

volumes:
  pgdata:
~~~

~~~bash
docker compose up -d --wait redis-2 redis-3
export RUNWAY_REDIS_URLS=redis://localhost:6379/0,redis://localhost:6380/0,redis://localhost:6381/0
~~~

go-redis has a `Ring` client that sends each key to one of several servers, and lets you plug in the hashing. It also pings its servers and stops using one that fails, so that server's keys (and only those) move to the others. The cache needs to accept any client, not just a single server's. In `internal/cache/cache.go`, `REDIS_URL` may now list several servers, separated by commas:

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
	"strconv"
	"time"
~~~

to:

~~~go
	"strconv"
	"strings"
	"time"
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
	"runway/internal/jobs"
)
~~~

to:

~~~go
	"runway/internal/jobs"
	"runway/internal/ring"
)
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
	client  *redis.Client
~~~

to:

~~~go
	client  redis.UniversalClient
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
func New(next jobs.Repository, client *redis.Client, b *breaker.Breaker, opts Options) *Repository {
~~~

to:

~~~go
func New(next jobs.Repository, client redis.UniversalClient, b *breaker.Breaker, opts Options) *Repository {
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go
// Ping checks that Redis answers, for start-up.
func Ping(ctx context.Context, client *redis.Client) error {
~~~

to:

~~~go
// Ping checks that Redis answers, for start-up. For a ring, it checks every
// server.
func Ping(ctx context.Context, client redis.UniversalClient) error {
	if r, ok := client.(*redis.Ring); ok {
		return r.ForEachShard(ctx, func(ctx context.Context, shard *redis.Client) error {
			if err := shard.Ping(ctx).Err(); err != nil {
				return fmt.Errorf("connect to Redis at %s: %w", shard.Options().Addr, err)
			}
			return nil
		})
	}
~~~

Change:

<!-- edit: internal/cache/cache.go -->
~~~go

var _ jobs.Repository = (*Repository)(nil)
~~~

to:

~~~go

// Dial connects to one Redis server, or to several separated by commas.
// Several become a ring: each key lives on one server, chosen by
// consistent hashing, so adding a server moves only its share of the keys.
// The ring also watches its servers and stops using one that fails, which
// moves that server's keys (and only those) to the others.
func Dial(urls string) (redis.UniversalClient, error) {
	list := strings.Split(urls, ",")
	if len(list) == 1 {
		opts, err := redis.ParseURL(list[0])
		if err != nil {
			return nil, fmt.Errorf("parse REDIS_URL: %w", err)
		}
		return redis.NewClient(opts), nil
	}
	addrs := map[string]string{}
	for _, u := range list {
		opts, err := redis.ParseURL(u)
		if err != nil {
			return nil, fmt.Errorf("parse REDIS_URL: %w", err)
		}
		addrs[opts.Addr] = opts.Addr
	}
	return redis.NewRing(&redis.RingOptions{
		Addrs: addrs,
		NewConsistentHash: func(shards []string) redis.ConsistentHash {
			return ring.New(100, shards...)
		},
	}), nil
}

var _ jobs.Repository = (*Repository)(nil)
~~~


`Ping` asks every server in a ring, so a mistyped address fails at start-up, not on the first request that happens to hash to it.

In `cmd/api/main.go`, use `Dial`. The API no longer needs go-redis directly. Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc"
~~~

to:

~~~go
	"google.golang.org/grpc"
~~~

Then in `withCache`, change:

<!-- edit: cmd/api/main.go -->
~~~go
// withCache puts a Redis cache in front of repo when REDIS_URL is set. It
// returns a function that closes the Redis client.
func withCache(ctx context.Context, cfg config, repo jobs.Repository, metrics *httpapi.Metrics) (jobs.Repository, func(), error) {
	if cfg.RedisURL == "" {
		return repo, func() {}, nil
	}
	opts, err := redis.ParseURL(cfg.RedisURL)
	if err != nil {
		return nil, nil, fmt.Errorf("parse REDIS_URL: %w", err)
	}
	client := redis.NewClient(opts)
	if err := cache.Ping(ctx, client); err != nil {
~~~

to:

~~~go
// withCache puts a Redis cache in front of repo when REDIS_URL is set
// (one server, or several separated by commas). It returns a function that
// closes the Redis client.
func withCache(ctx context.Context, cfg config, repo jobs.Repository, metrics *httpapi.Metrics) (jobs.Repository, func(), error) {
	if cfg.RedisURL == "" {
		return repo, func() {}, nil
	}
	client, err := cache.Dial(cfg.RedisURL)
	if err != nil {
		return nil, nil, err
	}
	if err := cache.Ping(ctx, client); err != nil {
~~~

And test that a ring of three really shares the jobs. In `internal/cache/cache_test.go`:

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
func newCache(t *testing.T, c *redis.Client, next jobs.Repository) *Repository {
~~~

to:

~~~go
func newCache(t *testing.T, c redis.UniversalClient, next jobs.Repository) *Repository {
~~~

Add this at the end of the file:

<!-- append: internal/cache/cache_test.go -->
~~~go
// With several servers, each job's copy lives on one of them, and the jobs
// spread roughly evenly.
func TestARingSpreadsJobsAcrossServers(t *testing.T) {
	urls := os.Getenv("RUNWAY_REDIS_URLS")
	if !strings.Contains(urls, ",") {
		t.Skip("set RUNWAY_REDIS_URLS to two or more servers to run the ring test")
	}
	client, err := Dial(urls)
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	if err := Ping(context.Background(), client); err != nil {
		t.Fatal(err)
	}
	repo := newCache(t, client, memstore.New())
	for range 300 {
		job := create(t, repo)
		if _, err := repo.Get(context.Background(), job.ID); err != nil {
			t.Fatal(err)
		}
	}

	// ForEachShard calls the function for every server at once, so the map
	// needs a lock.
	var mu sync.Mutex
	counts := map[string]int{}
	err = client.(*redis.Ring).ForEachShard(context.Background(), func(ctx context.Context, shard *redis.Client) error {
		n := 0
		iter := shard.Scan(ctx, 0, repo.opts.Prefix+"*", 100).Iterator()
		for iter.Next(ctx) {
			n++
		}
		mu.Lock()
		counts[shard.Options().Addr] = n
		mu.Unlock()
		return iter.Err()
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("cached jobs per server: %v", counts)
	total := 0
	for addr, n := range counts {
		total += n
		if n < 50 {
			t.Errorf("%s holds only %d of 300 jobs", addr, n)
		}
	}
	if total != 300 {
		t.Fatalf("%d jobs cached in total, want 300", total)
	}
}
~~~


`ForEachShard` calls its function for all servers *at the same time*, so the test protects its map with a mutex. The first version didn't, and `-race` caught it.

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./internal/cache/... ./cmd/api/... -->

~~~bash
go test -v -run Ring ./internal/cache/
~~~

~~~text
    cache_test.go:190: cached jobs per server: map[localhost:6379:108 localhost:6380:92 localhost:6381:100]
--- PASS: TestARingSpreadsJobsAcrossServers (0.42s)
ok  	runway/internal/cache	0.424s
~~~

### Run it: lose a cache server

Run the API with all three servers, create 30 jobs (`sed` keeps just each new job's ID), read each one, and count where the copies went. Start from empty caches if you ran the test above: `docker compose exec redis redis-cli FLUSHALL`, and the same for `redis-2` and `redis-3`.

~~~bash
export DATABASE_URL=postgres://runway:runway@localhost:5432/runway
export REDIS_URL=redis://localhost:6379/0,redis://localhost:6380/0,redis://localhost:6381/0
go run ./cmd/api &
IDS=$(for i in $(seq 30); do curl -s -X POST localhost:8080/jobs -H 'Content-Type: application/json' -d '{"description":"ring","duration_ms":10}' | sed 's/{"id":\([0-9]*\).*/\1/'; done)
sleep 1
for id in $IDS; do curl -s -o /dev/null localhost:8080/jobs/$id; done
for s in redis redis-2 redis-3; do echo "$s: $(docker compose exec -T $s redis-cli --scan --pattern 'runway:job:v1:*' | wc -l)"; done
~~~

~~~text
redis: 11
redis-2: 9
redis-3: 10
~~~

Now stop one server, and read every job again:

~~~bash
docker compose stop redis-3
sleep 2
for id in $IDS; do curl -s -o /dev/null -w "%{http_code}\n" localhost:8080/jobs/$id; done | sort | uniq -c
curl -s localhost:8080/metrics | grep '^cache_'
for s in redis redis-2; do echo "$s: $(docker compose exec -T $s redis-cli --scan --pattern 'runway:job:v1:*' | wc -l)"; done
~~~

~~~text
     30 200
cache_breaker_state 0
cache_requests_total{result="hit"} 20
cache_requests_total{result="miss"} 100
redis: 14
redis-2: 16
~~~

All 30 reads succeeded. The ring noticed `redis-3` was gone (it pings every half second) and stopped using it. Its 10 jobs missed once, were read from PostgreSQL, and were cached on the other two (11+3 and 9+7). The 20 jobs on `redis` and `redis-2` never moved, and were hits. The cache breaker never opened, because the ring stepped round the failure before a request hit it. Start `redis-3` again (`docker compose start redis-3`), and the ring takes it back.

(Where the other misses came from: each job's own worker reads it twice while running it, 60 in all, plus the 30 first reads and the 10 moved jobs.)

**Break it: one point per server.** In `Dial`, change `ring.New(100, shards...)` to `ring.New(1, shards...)`, empty the three Redis servers (`docker compose exec redis redis-cli FLUSHALL`, and the same for `redis-2` and `redis-3`), and run the ring test:

~~~text
    cache_test.go:190: cached jobs per server: map[localhost:6379:188 localhost:6380:6 localhost:6381:106]
    cache_test.go:195: localhost:6380 holds only 6 of 300 jobs
--- FAIL: TestARingSpreadsJobsAcrossServers (0.43s)
~~~

One server got 188 jobs, another 6. Three random points cut a circle into very unequal arcs. Restore 100.

**Explain it:** why does adding a node to `hash mod N` move most keys, and a ring only about 1/N? What do virtual nodes fix? Why can't any hash function fix a hot key, and what can? When `redis-3` stopped, which keys moved, and why only those?

**Read.** DDIA Ch. 6, *Partitioning*, whole chapter. Then Karger et al., *Consistent Hashing and Random Trees* (STOC 1997), §1–2, and the DynamoDB paper (DeCandia et al., *Dynamo: Amazon's Highly Available Key-value Store*, SOSP 2007), §4.2 on partitioning. Carry this question in: Dynamo's first design gave each node random points, and later switched to fixed equal-sized ranges. Why?

---

## Step 12: Transactions across shards

**The problem.** Sharding splits data so that each machine holds part of it. Sooner or later, one change must touch two parts: move money from an account on shard A to an account on shard B, or move a job's record from one tenant's shard to another's. Each database can make its own part atomic, but nothing yet makes *both* parts atomic together. Crash in between, and the money has left A and never reached B.

**New ideas.**

- **Two-phase commit (2PC).** A **coordinator** runs the change in two phases:
  1. **Prepare.** Each participant does its part in a transaction, then *prepares* it. A prepared transaction is written to disk and will commit if told to, even after a crash. It may no longer refuse, and it keeps its locks.
  2. **Commit.** Once *every* participant has prepared, the coordinator records its decision (that record is the moment the change commits), then tells each one to commit.

  If anyone fails to prepare, the coordinator tells everyone to roll back.
- **2PC blocks.** If the coordinator dies after the participants prepare and before they hear the decision, they can't decide on their own. Committing might contradict a rollback the coordinator chose; rolling back might contradict a commit. So they **wait, holding their locks**, until the coordinator recovers. That's why people say 2PC "blocks", and why the coordinator's decision log must itself be highly available (often it's a Raft group, which is how Spanner and CockroachDB do it).
- **Presumed abort.** On recovery, a prepared transaction with no recorded decision is rolled back: if the decision had been "commit", it would have been recorded before anyone was told.
- **PostgreSQL's 2PC.** `PREPARE TRANSACTION 'name'` turns the current transaction into a prepared one, detached from the session: any session can later run `COMMIT PREPARED 'name'` or `ROLLBACK PREPARED 'name'`, and `pg_prepared_xacts` lists those waiting. It's off by default (`max_prepared_transactions = 0`): a forgotten prepared transaction holds its locks forever, so you switch it on only when you mean to use it.
- **Sagas** (Garcia-Molina and Salem, 1987) take the opposite trade. Each step commits locally at once, and each has a **compensating action** that undoes it in business terms, a refund rather than an "un-charge". If a step fails, the completed ones are compensated in reverse order. Nothing holds locks across services, so nothing blocks. The price is **isolation**: in the middle of a saga, others can see the change half done. Runway's Phase 2 `Create` was already a small saga: store the job, try to dispatch, and mark it failed (compensate) if dispatch failed.

| | Two-phase commit | Saga |
|---|---|---|
| Atomic? | Yes | Eventually: completed steps are compensated |
| Isolated? | Yes, while prepared | No: intermediate states are visible |
| Blocks on coordinator failure? | Yes, with locks held | No |
| Needs participants to support | Prepared transactions | Only local transactions, plus a compensation per step |
| Typical use | Inside one database system across its shards | Across services owned by different teams |

### Allow prepared transactions

In `compose.yaml`, start PostgreSQL with the setting. Change:

<!-- edit: compose.yaml -->
~~~yaml
  postgres:
    image: postgres:17
~~~

to:

~~~yaml
  postgres:
    image: postgres:17
    # Allow two-phase commit (Phase 4, step 12). The default is 0: off.
    command: ["postgres", "-c", "max_prepared_transactions=10"]
~~~

~~~bash
docker compose up -d --wait postgres
docker compose exec postgres psql -U runway -Atc 'SHOW max_prepared_transactions'
~~~

~~~text
10
~~~

### See it by hand first

Prepare a transaction in one `psql` session, then look at it from another:

~~~bash
docker compose exec postgres psql -U runway -c "CREATE TABLE demo_accounts (id INT PRIMARY KEY, balance INT NOT NULL)" -c "INSERT INTO demo_accounts VALUES (1, 100)"
printf "BEGIN;\nUPDATE demo_accounts SET balance = 70 WHERE id = 1;\nPREPARE TRANSACTION 'move-1';\n" | docker compose exec -T postgres psql -U runway
docker compose exec postgres psql -U runway -c "SELECT gid, owner, database FROM pg_prepared_xacts" -c "SELECT balance FROM demo_accounts"
docker compose exec postgres psql -U runway -c "SET lock_timeout = '1s'" -c "UPDATE demo_accounts SET balance = 0 WHERE id = 1"
~~~

~~~text
BEGIN
UPDATE 1
PREPARE TRANSACTION
  gid   | owner  | database 
--------+--------+----------
 move-1 | runway | runway
(1 row)

 balance 
---------
     100
(1 row)

SET
ERROR:  canceling statement due to lock timeout
CONTEXT:  while updating tuple (0,1) in relation "demo_accounts"
~~~

The session that prepared it has gone, and the transaction is still there. Its change isn't visible (the balance reads 100), and its lock is held: the second `UPDATE` waited a second and gave up. Now restart PostgreSQL entirely, and the prepared transaction is *still* there, waiting for a decision:

~~~bash
docker compose restart postgres
docker compose exec postgres psql -U runway -c "SELECT gid FROM pg_prepared_xacts" -c "COMMIT PREPARED 'move-1'" -c "SELECT balance FROM demo_accounts" -c "DROP TABLE demo_accounts"
~~~

~~~text
  gid   
--------
 move-1
(1 row)

COMMIT PREPARED
 balance 
---------
      70
(1 row)

DROP TABLE
~~~

### A coordinator

Create `internal/twopc/twopc.go`:

<!-- file: internal/twopc/twopc.go -->
~~~go
// Package twopc commits one change across several databases, all or
// nothing, with two-phase commit.
//
// Phase 1: each participant does its part in a transaction, then PREPAREs
// it. A prepared transaction is written to disk and will commit if told
// to, even after a crash, but nobody can see its changes yet, and it keeps
// its locks. Phase 2: once every participant has prepared, the coordinator
// records its decision, and tells each one to COMMIT PREPARED.
//
// The coordinator's decision record is the moment the change commits. If
// the coordinator dies before writing it, the prepared transactions wait,
// holding their locks, until Recover rolls them back. That waiting is
// two-phase commit's famous weakness: it blocks.
package twopc

import (
	"context"
	"errors"
	"fmt"
	"regexp"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Participant is one database taking part.
type Participant struct {
	Name string
	Pool *pgxpool.Pool
}

// Work is one participant's part of the change, done on conn inside the
// transaction Run has begun.
type Work func(ctx context.Context, conn *pgxpool.Conn) error

// errCrash simulates the coordinator dying at a chosen point.
var errCrash = errors.New("twopc: coordinator crashed (simulated)")

// Coordinator runs transactions and keeps their decisions in its own
// database.
type Coordinator struct {
	log *pgxpool.Pool
	// CrashAfter makes Run stop dead after "prepare" or "decide", leaving
	// everything exactly as a crashed process would. For tests.
	CrashAfter string
}

// NewCoordinator creates the decision table if needed.
func NewCoordinator(ctx context.Context, log *pgxpool.Pool) (*Coordinator, error) {
	_, err := log.Exec(ctx, `CREATE TABLE IF NOT EXISTS twopc_decisions (gid TEXT PRIMARY KEY, decided_at TIMESTAMPTZ NOT NULL DEFAULT now())`)
	return &Coordinator{log: log}, err
}

var validID = regexp.MustCompile(`^[a-z0-9-]{1,100}$`)

// gid names one participant's prepared transaction. PREPARE TRANSACTION
// takes a literal, not a parameter, so the ID is checked strictly.
func gid(id string, p Participant) string { return id + "-" + p.Name }

// Run does work on every participant, all or nothing.
func (c *Coordinator) Run(ctx context.Context, id string, parts []Participant, work []Work) error {
	if !validID.MatchString(id) {
		return fmt.Errorf("twopc: transaction ID %q must be lower-case letters, digits and dashes", id)
	}
	// Phase 1a: each participant does its part, on a connection of its
	// own, in a transaction begun by hand. (pgx's Tx type would expect a
	// COMMIT or ROLLBACK on the same connection; a prepared transaction
	// ends instead with COMMIT PREPARED, on any connection.)
	conns := make([]*pgxpool.Conn, len(parts))
	defer func() {
		for _, c := range conns {
			if c != nil {
				c.Release()
			}
		}
	}()
	abort := func(upTo int) {
		for _, c := range conns[:upTo] {
			_, _ = c.Exec(context.WithoutCancel(ctx), "ROLLBACK")
		}
	}
	for i, p := range parts {
		conn, err := p.Pool.Acquire(ctx)
		if err != nil {
			abort(i)
			return err
		}
		conns[i] = conn
		if _, err := conn.Exec(ctx, "BEGIN"); err != nil {
			abort(i)
			return err
		}
		if err := work[i](ctx, conn); err != nil {
			abort(i + 1)
			return fmt.Errorf("twopc: %s: %w", p.Name, err)
		}
	}
	// Phase 1b: each participant prepares. After this, it may no longer
	// refuse: it has promised to commit if told to. The connection is free
	// again: the prepared transaction now belongs to the database, not to
	// any session.
	for i, p := range parts {
		if _, err := conns[i].Exec(ctx, "PREPARE TRANSACTION '"+gid(id, p)+"'"); err != nil {
			for _, q := range parts[:i] {
				_, _ = q.Pool.Exec(context.WithoutCancel(ctx), "ROLLBACK PREPARED '"+gid(id, q)+"'")
			}
			abort(len(parts))
			return fmt.Errorf("twopc: %s could not prepare: %w", p.Name, err)
		}
	}
	if c.CrashAfter == "prepare" {
		return errCrash
	}
	// The decision. Once this row exists, the change has committed, whatever
	// happens next.
	if _, err := c.log.Exec(ctx, `INSERT INTO twopc_decisions (gid) VALUES ($1)`, id); err != nil {
		return err // no decision: Recover will roll back
	}
	if c.CrashAfter == "decide" {
		return errCrash
	}
	// Phase 2: tell everyone. A failure here isn't a failure of the
	// transaction: Recover will finish the job.
	return c.finish(ctx, id, parts, "COMMIT PREPARED")
}

func (c *Coordinator) finish(ctx context.Context, id string, parts []Participant, verb string) error {
	var errs []error
	for _, p := range parts {
		if _, err := p.Pool.Exec(ctx, verb+" '"+gid(id, p)+"'"); err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", p.Name, err))
		}
	}
	return errors.Join(errs...)
}

// Recover finishes every prepared transaction the participants still hold
// for this coordinator: commit if a decision was recorded, roll back if
// not. Run it at start-up, before anything else.
func (c *Coordinator) Recover(ctx context.Context, parts []Participant) (committed, rolledBack int, err error) {
	for _, p := range parts {
		rows, err := p.Pool.Query(ctx, `SELECT gid FROM pg_prepared_xacts WHERE database = current_database() AND gid LIKE $1`, "%-"+p.Name)
		if err != nil {
			return committed, rolledBack, err
		}
		gids, err := pgx.CollectRows(rows, pgx.RowTo[string])
		if err != nil {
			return committed, rolledBack, err
		}
		for _, g := range gids {
			id := g[:len(g)-len(p.Name)-1]
			var decided bool
			if err := c.log.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM twopc_decisions WHERE gid = $1)`, id).Scan(&decided); err != nil {
				return committed, rolledBack, err
			}
			verb := "ROLLBACK PREPARED"
			if decided {
				verb = "COMMIT PREPARED"
			}
			if _, err := p.Pool.Exec(ctx, verb+" '"+g+"'"); err != nil {
				return committed, rolledBack, err
			}
			if decided {
				committed++
			} else {
				rolledBack++
			}
		}
	}
	return committed, rolledBack, nil
}
~~~

Each participant works on a connection Run acquires and begins by hand, not through pgx's `Tx`. A `Tx` expects to end with `COMMIT` or `ROLLBACK` on the same connection, and keeps that connection until it does. A prepared transaction ends with `COMMIT PREPARED`, on any connection. The first version of this code used `Tx`. It never gave its connections back, so the pool, and the test, waited forever when it closed.

Create `internal/twopc/twopc_test.go`. Each "shard" is a schema of its own, standing in for a separate database:

<!-- file: internal/twopc/twopc_test.go -->
~~~go
package twopc

import (
	"context"
	"crypto/rand"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"runway/internal/pgstore/pgtest"
)

// bank gives each of two "shards" an account table, each in its own schema
// standing in for its own database.
type bank struct {
	coord *Coordinator
	parts []Participant
}

func newBank(t *testing.T) *bank {
	t.Helper()
	ctx := context.Background()
	accounts := func(ctx context.Context, pool *pgxpool.Pool) error {
		_, err := pool.Exec(ctx, `CREATE TABLE accounts (id INT PRIMARY KEY, balance INT NOT NULL CHECK (balance >= 0)); INSERT INTO accounts VALUES (1, 100)`)
		return err
	}
	suffix := strings.ToLower(rand.Text())[:8]
	b := &bank{parts: []Participant{
		{Name: "a" + suffix, Pool: pgtest.Pool(t, accounts)},
		{Name: "b" + suffix, Pool: pgtest.Pool(t, accounts)},
	}}
	var max string // SHOW always answers with text
	if err := b.parts[0].Pool.QueryRow(ctx, `SHOW max_prepared_transactions`).Scan(&max); err != nil {
		t.Fatal(err)
	}
	if max == "0" {
		t.Skip("PostgreSQL has max_prepared_transactions = 0; start it with -c max_prepared_transactions=10")
	}
	coord, err := NewCoordinator(ctx, pgtest.Pool(t, func(context.Context, *pgxpool.Pool) error { return nil }))
	if err != nil {
		t.Fatal(err)
	}
	b.coord = coord
	// A test that fails halfway must not leave prepared transactions
	// behind: they would hold locks, and block dropping the schemas.
	t.Cleanup(func() { _, _, _ = b.coord.Recover(context.Background(), b.parts) })
	return b
}

// move takes amount from shard a's account and gives it to shard b's.
func (b *bank) move(ctx context.Context, id string, amount int) error {
	return b.coord.Run(ctx, id, b.parts, []Work{
		func(ctx context.Context, conn *pgxpool.Conn) error {
			_, err := conn.Exec(ctx, `UPDATE accounts SET balance = balance - $1 WHERE id = 1`, amount)
			return err
		},
		func(ctx context.Context, conn *pgxpool.Conn) error {
			_, err := conn.Exec(ctx, `UPDATE accounts SET balance = balance + $1 WHERE id = 1`, amount)
			return err
		},
	})
}

func (b *bank) balances(t *testing.T) [2]int {
	t.Helper()
	var out [2]int
	for i, p := range b.parts {
		if err := p.Pool.QueryRow(context.Background(), `SELECT balance FROM accounts WHERE id = 1`).Scan(&out[i]); err != nil {
			t.Fatal(err)
		}
	}
	return out
}

func TestBothSidesCommit(t *testing.T) {
	b := newBank(t)
	if err := b.move(context.Background(), "move-1", 30); err != nil {
		t.Fatal(err)
	}
	if got := b.balances(t); got != [2]int{70, 130} {
		t.Fatalf("balances %v, want [70 130]", got)
	}
}

// If either side can't do its part, neither side changes.
func TestOneSideRefusingRollsBackBoth(t *testing.T) {
	b := newBank(t)
	err := b.move(context.Background(), "move-2", 500) // more than shard a has
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23514" {
		t.Fatalf("error = %v, want a CHECK violation (23514)", err)
	}
	if got := b.balances(t); got != [2]int{100, 100} {
		t.Fatalf("balances %v, want [100 100]: nothing may have changed", got)
	}
}

// The coordinator dies after both sides prepared, before deciding. Both
// prepared transactions hold their locks: anyone touching those rows
// waits. That is two-phase commit's blocking problem. Recovery finds no
// decision, so it rolls both back.
func TestACoordinatorCrashBeforeDecidingBlocksUntilRecovery(t *testing.T) {
	ctx := context.Background()
	b := newBank(t)
	b.coord.CrashAfter = "prepare"
	if err := b.move(ctx, "move-3", 30); !errors.Is(err, errCrash) {
		t.Fatalf("error = %v", err)
	}

	start := time.Now()
	_, err := b.parts[0].Pool.Exec(ctx, `SET lock_timeout = '200ms'; UPDATE accounts SET balance = 0 WHERE id = 1`)
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "55P03" {
		t.Fatalf("another write = %v after %v; want it to wait for the prepared transaction's lock, then time out (55P03)", err, time.Since(start))
	}
	t.Logf("a write to the locked row waited %v, then: %s", time.Since(start).Round(10*time.Millisecond), pgErr.Message)

	b.coord.CrashAfter = ""
	committed, rolledBack, err := b.coord.Recover(ctx, b.parts)
	if err != nil || committed != 0 || rolledBack != 2 {
		t.Fatalf("Recover = %d committed, %d rolled back, %v; want 0, 2", committed, rolledBack, err)
	}
	if got := b.balances(t); got != [2]int{100, 100} {
		t.Fatalf("balances %v, want [100 100]", got)
	}
}

// The coordinator dies after recording its decision, before telling the
// participants. The change has committed: recovery must finish it.
func TestACoordinatorCrashAfterDecidingIsFinishedByRecovery(t *testing.T) {
	ctx := context.Background()
	b := newBank(t)
	b.coord.CrashAfter = "decide"
	if err := b.move(ctx, "move-4", 30); !errors.Is(err, errCrash) {
		t.Fatalf("error = %v", err)
	}
	if got := b.balances(t); got != [2]int{100, 100} {
		t.Fatalf("balances %v before recovery; prepared changes must not be visible yet", got)
	}
	committed, rolledBack, err := b.coord.Recover(ctx, b.parts)
	if err != nil || committed != 2 || rolledBack != 0 {
		t.Fatalf("Recover = %d committed, %d rolled back, %v; want 2, 0", committed, rolledBack, err)
	}
	if got := b.balances(t); got != [2]int{70, 130} {
		t.Fatalf("balances %v, want [70 130]", got)
	}
}
~~~

### A saga

Create `internal/saga/saga.go`:

<!-- file: internal/saga/saga.go -->
~~~go
// Package saga runs a change across services as a sequence of steps, each
// committed on its own. If a step fails, the steps already done are undone
// in reverse order by their compensating actions.
//
// Unlike two-phase commit, nothing waits holding locks across services, so
// a crashed coordinator blocks nobody. The price is isolation: between
// steps, others can see the change half done. A compensation also isn't a
// rollback: it's a new, visible action (a refund, not an un-charge), and it
// can fail too, so it must be retried until it succeeds.
package saga

import (
	"context"
	"errors"
	"fmt"
)

// Step is one local transaction and the action that undoes it.
type Step struct {
	Name string
	Do   func(ctx context.Context) error
	Undo func(ctx context.Context) error
}

// Run does the steps in order. If one fails, it undoes the completed steps,
// newest first, and returns the failure. If an undo fails too, the saga is
// stuck half done, and the error says so: a person (or a retrying job) must
// finish it.
func Run(ctx context.Context, steps []Step) error {
	for i, step := range steps {
		err := step.Do(ctx)
		if err == nil {
			continue
		}
		failure := fmt.Errorf("saga: %s failed: %w", step.Name, err)
		for j := i - 1; j >= 0; j-- {
			if undoErr := steps[j].Undo(ctx); undoErr != nil {
				return errors.Join(failure, fmt.Errorf("saga: undoing %s failed, so the saga is half done: %w", steps[j].Name, undoErr))
			}
		}
		return failure
	}
	return nil
}
~~~

Create `internal/saga/saga_test.go`:

<!-- file: internal/saga/saga_test.go -->
~~~go
package saga

import (
	"context"
	"errors"
	"testing"
)

// Two "services", each with one account, each committing on its own.
type books struct{ a, b int }

func transfer(bk *books, amount int, creditFails bool, between func()) []Step {
	return []Step{
		{
			Name: "debit a",
			Do:   func(context.Context) error { bk.a -= amount; return nil },
			Undo: func(context.Context) error { bk.a += amount; return nil }, // a refund
		},
		{
			Name: "credit b",
			Do: func(context.Context) error {
				between() // someone looks while the saga is half done
				if creditFails {
					return errors.New("account b is closed")
				}
				bk.b += amount
				return nil
			},
			Undo: func(context.Context) error { bk.b -= amount; return nil },
		},
	}
}

func TestASuccessfulSagaDoesEveryStep(t *testing.T) {
	bk := &books{a: 100, b: 100}
	if err := Run(context.Background(), transfer(bk, 30, false, func() {})); err != nil {
		t.Fatal(err)
	}
	if *bk != (books{70, 130}) {
		t.Fatalf("books %+v", *bk)
	}
}

func TestAFailedStepIsCompensated(t *testing.T) {
	bk := &books{a: 100, b: 100}
	err := Run(context.Background(), transfer(bk, 30, true, func() {}))
	if err == nil {
		t.Fatal("the saga succeeded although the credit failed")
	}
	if *bk != (books{100, 100}) {
		t.Fatalf("books %+v after compensation, want {100 100}", *bk)
	}
	t.Log(err)
}

// The price of not holding locks: in the middle, the money is in neither
// account, and anyone adding up the books sees it missing.
func TestOthersSeeTheSagaHalfDone(t *testing.T) {
	bk := &books{a: 100, b: 100}
	var total int
	_ = Run(context.Background(), transfer(bk, 30, false, func() { total = bk.a + bk.b }))
	if total != 170 {
		t.Fatalf("total seen mid-saga = %d", total)
	}
	t.Logf("mid-saga, the books added up to %d, not 200", total)
}
~~~

<!-- run: go mod tidy && test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

<!-- run: env -u RUNWAY_AMQP_URL -u RUNWAY_DATABASE_URL -u RUNWAY_REDIS_URL -u RUNWAY_REDIS_URLS -u RUNWAY_KAFKA_BROKERS go test -count=1 ./... -->

~~~bash
go test -v ./internal/twopc/ ./internal/saga/
~~~

~~~text
--- PASS: TestBothSidesCommit (0.16s)
--- PASS: TestOneSideRefusingRollsBackBoth (0.12s)
    twopc_test.go:120: a write to the locked row waited 200ms, then: canceling statement due to lock timeout
--- PASS: TestACoordinatorCrashBeforeDecidingBlocksUntilRecovery (0.33s)
--- PASS: TestACoordinatorCrashAfterDecidingIsFinishedByRecovery (0.13s)
ok  	runway/internal/twopc	0.747s
--- PASS: TestASuccessfulSagaDoesEveryStep (0.00s)
    saga_test.go:53: saga: credit b failed: account b is closed
--- PASS: TestAFailedStepIsCompensated (0.00s)
    saga_test.go:65: mid-saga, the books added up to 170, not 200
--- PASS: TestOthersSeeTheSagaHalfDone (0.00s)
ok  	runway/internal/saga	0.004s
~~~

As in Phase 3, the whole suite must also pass, skipping what it can't run, with every server variable unset: `env -u RUNWAY_AMQP_URL -u RUNWAY_DATABASE_URL -u RUNWAY_REDIS_URL -u RUNWAY_REDIS_URLS -u RUNWAY_KAFKA_BROKERS go test ./...`.

The two log lines are the two weaknesses, measured. With 2PC, a crashed coordinator left a row locked, and an unrelated write waited until it timed out. With the saga, someone adding up the books mid-saga saw 170 instead of 200.

**Break it: recover by committing everything.** In `Recover`, change `verb := "ROLLBACK PREPARED"` to `verb := "COMMIT PREPARED"`:

~~~text
--- FAIL: TestACoordinatorCrashBeforeDecidingBlocksUntilRecovery (0.35s)
    twopc_test.go:120: a write to the locked row waited 200ms, then: canceling statement due to lock timeout
    twopc_test.go:128: balances [70 130], want [100 100]
~~~

The coordinator had never decided, so for all anyone knows, it might have been about to roll back (another participant could have failed to prepare). Recovery committed it anyway. Restore the line.

**Explain it:** walk through 2PC's two phases, and say what each participant may and may not do after preparing. Why does 2PC block when the coordinator dies, and what does "presumed abort" decide? When would you choose a saga instead, and what do you give up?

**Read.** DDIA Ch. 9, *Distributed Transactions and Consensus*, the sections on atomic commit and 2PC. Then Garcia-Molina and Salem, *Sagas* (SIGMOD 1987), §1–3, and the PostgreSQL manual's `PREPARE TRANSACTION` page. Carry this question in: Spanner runs 2PC between Paxos groups. Why does that make the blocking problem much smaller?

---

## Rebuild it yourself

Close the guide. In your own `runway` repository, rebuild Phase 4 from these contracts:
- the simulator's interface: `Tick`, `Send`, `Cut`, `Partition`, `Heal`, seeded randomness;
- Raft's messages and their rules, as in Figure 2 of the paper, plus PreVote and CheckQuorum;
- `Ready`'s order: save, send, apply;
- the safety checks after every step: election safety and state machine safety;
- the WAL's record format, and the atomic snapshot replacement;
- the store's commands, sessions and locks, and the linearizability model;
- `metad`'s HTTP API, and its 421 redirect;
- the ring's interface, and the cache's `Dial`;
- the 2PC coordinator's decision record and recovery rule.

Write the tests first, especially the storm tests and the Figure 8 scenario, and only then the code that passes them. Then repeat the experiments on *your* code:
1. break each safety rule and find the seed that catches it;
2. kill a `metad` leader with `kill -9`;
3. see TLC's counterexample;
4. lose a cache server;
5. crash a 2PC coordinator.

## Checkpoint

You're ready for Phase 5 when you can, without the guide:

1. State the failure and timing models this phase assumes, and FLP and CAP precisely.
2. Explain why a timeout can only suspect a failure, with numbers from the detector.
3. Explain terms, votes and randomised timeouts, and prove that a term can't have two leaders.
4. Explain the consistency check, Log Matching, the up-to-date rule and Leader Completeness.
5. Draw Figure 8, and name both protections against it in your code.
6. List what a node must save, and explain why saving comes before sending, using the seed that failed.
7. Explain snapshots, InstallSnapshot, and the "same history" rule, and the `next`/`match` bug.
8. Explain what PreVote and CheckQuorum fix, and why the idle test was needed.
9. Define linearizability, and explain how sessions and log reads achieve it, and how Porcupine checks it.
10. Explain the runtime loop and how a waiting request learns its entry was lost.
11. Read a TLC counterexample, and say what TLC proves and what it doesn't.
12. Explain leases, why a holder can't detect its own pause, and how fencing tokens protect the resource.
13. Compare `hash mod N` with a ring, explain virtual nodes, and say what can and can't fix a hot key.
14. Walk through 2PC, explain why it blocks, and compare it with a saga.

## If it goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| A storm test fails on one seed | A real bug: that's the test working | Run only that seed, print each node's `Status` every tick around the failing tick, and read what happened |
| A storm test fails, then passes on the next run | Something isn't deterministic: a map iterated while sending, a goroutine, `time.Now` | Every loop that sends must go over a sorted slice; the simulator must use only its seeded source |
| `the nodes still disagree 5000 ticks after the storm ended` | A liveness bug, or the test still injecting faults | Check crashes and drops are off after the storm; then compare `next`, `match` and commit on the leader and the lagging node |
| `go vet: field and method with the same name term` | A method named like a field | The guide's method is `termAt` |
| `metad` returns 404 for a key | The key contains `/` | Keys are a single path segment |
| `metad` returns 421 | That member isn't the leader | Send the request to the URL in the `leader` field |
| `metad` returns 503 `not committed` | No leader yet, or the leader changed mid-request | Retry, with the same `Client-ID` and `Request-Seq` |
| Every `metad` request times out | Fewer than two of three members are running | Start another member; a majority is needed |
| TLC: `Error: Missing input TLA+ module` | Run from the wrong directory | `cd tla` first |
| TLC: `java: command not found` | No Java | Install Java 11 or newer |
| The 2PC tests say `SKIP ... max_prepared_transactions = 0` | PostgreSQL started without the setting | Add the `command` line to `compose.yaml`, then `docker compose up -d --wait postgres` |
| A 2PC test hangs | Prepared transactions holding connections or locks | Check `SELECT gid FROM pg_prepared_xacts`; `ROLLBACK PREPARED` leftovers by hand |
| The ring test says `SKIP` | `RUNWAY_REDIS_URLS` isn't set | Set it to the three servers' URLs |

## Reading list for this phase

| When | Reading | Question to carry in |
|---|---|---|
| Step 1 | DDIA Ch. 8; Lamport, *Time, Clocks, and the Ordering of Events* | Which problems can a simulator reproduce? |
| Step 2 | Raft paper §1–5.2 | What does a strong leader cost? |
| Step 3 | Raft paper §5.3–5.4 | Which rule does each step of the proof rely on? |
| Step 4 | Raft paper §5.6, Figure 2; etcd raft README | What does `Ready` force the runtime to get right? |
| Step 5 | Raft paper §7; Pillai et al., OSDI 2014 | Which crash-consistency mistakes does `replace` avoid? |
| Step 6 | Ongaro's thesis §9.6; Alquraan et al., OSDI 2018 | Which partial-partition patterns would your Raft survive? |
| Step 7 | Herlihy and Wing; Ongaro's thesis §6.3–6.4; Kingsbury, *Strong consistency models* | Is one PostgreSQL server linearizable? |
| Step 8 | etcd raft documentation and `raftexample` | What would pipelining and batching buy? |
| Step 9 | *Specifying Systems* Part I; Newcombe et al., CACM 2015 | How would you model the log? |
| Step 10 | Kleppmann, *How to do distributed locking*; Chubby §2.4, §2.8 | What does Chubby do that your locks don't? |
| Step 11 | DDIA Ch. 6; Karger et al.; Dynamo §4.2 | Why did Dynamo switch to fixed ranges? |
| Step 12 | DDIA Ch. 9; *Sagas*; PostgreSQL `PREPARE TRANSACTION` | Why does running 2PC between Raft groups shrink the blocking problem? |
| After the phase | Corbett et al., *Spanner* (OSDI 2012); Lamport, *Paxos Made Simple*; Liskov and Cowling, *Viewstamped Replication Revisited* | How do Paxos and Viewstamped Replication differ from Raft, and what does Spanner add with TrueTime? |
