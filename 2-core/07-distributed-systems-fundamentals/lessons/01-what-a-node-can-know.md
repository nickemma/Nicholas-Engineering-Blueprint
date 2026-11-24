# 01 What a node can know

> Core 07 · About 6 hours · Builds on the preceding lesson

## The problem

Node 1 stops sending heartbeats. Node 2 sees three empty ticks. Node 1 might be dead, paused, or sending into a failed link. A timeout gives node 2 a reason to suspect node 1. The cause is still unknown.

## The mental model

`Send(1, 2, heartbeat) → directed link → pending deliveries → Advance() → node 2`

A tick belongs to the simulator. It only moves when a test advances it. Give delayed messages a delivery tick and resolve ties in send order. Seed the random number generator once and visit events in a fixed order so a seed reproduces the sequence.

## The pattern

A **failure model** defines the permitted faults. Here a process can stop and reboot with its saved state. A message can be delayed or omitted. Retries can arrive more than once. Peers follow the protocol. A fault model where peers can lie arbitrarily is called Byzantine.

A **timing model** states the assumed bounds. Synchronous models bound message delays and processing steps. Asynchronous models permit arbitrary delays. Under eventual synchrony the bounds hold long enough for election and replication to progress. The safety rules still apply while delays are arbitrary.

Use local monotonic time for durations. A wall clock answers a calendar question and can move when adjusted. Comparing wall readings across machines leaves event causality uncertain. A Lamport clock propagates counters to order causally related events. Raft terms number election rounds.

FLP is a limit on guaranteed termination for deterministic consensus with arbitrary delays and a possible crash. CAP describes the choice during a partition between serving requests everywhere and maintaining the behavior of one up-to-date copy. Our protocol requires a quorum for progress. A client on the isolated side may time out. [Consensus primer](../../../system-design/fundamentals/consensus.md)

## Build it

### Step 1. Schedule a delivery

Model a directed link as two peer IDs. Fill in `at: n.Now + 1 + /* TODO */` for a delay between one and `Delay` ticks. Decide what blocking a route should do to queued traffic.

<details>
<summary>Hint 1</summary>

A packet scheduled for the current tick could be observed too early.

</details>

<details>
<summary>Hint 2</summary>

Sample from zero through Delay−1 and add one. Remove queued messages in the blocked direction.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/simnet/network.go -->
~~~go
// Package simnet delivers messages on a seeded, discrete clock.
package simnet

import (
	"math/rand"
	"slices"
)

type Link struct{ From, To int }

type Delivery[T any] struct {
	Link
	Value T
	at    int
}

type Network[T any] struct {
	Now     int
	Delay   int // maximum delay in ticks
	Loss    int // chance of loss, in percent
	rng     *rand.Rand
	blocked map[Link]bool
	pending []Delivery[T]
}

func New[T any](seed int64) *Network[T] {
	return &Network[T]{
		Delay:   1,
		rng:     rand.New(rand.NewSource(seed)),
		blocked: make(map[Link]bool),
	}
}

// Block changes a single directed link. Its in-flight messages are lost.
func (n *Network[T]) Block(from, to int, blocked bool) {
	link := Link{from, to}
	n.blocked[link] = blocked
	if blocked {
		n.pending = slices.DeleteFunc(n.pending, func(m Delivery[T]) bool {
			return m.Link == link
		})
	}
}

func (n *Network[T]) Send(from, to int, value T) {
	link := Link{from, to}
	if n.blocked[link] || n.rng.Intn(100) < n.Loss {
		return
	}
	n.pending = append(n.pending, Delivery[T]{
		Link: link, Value: value, at: n.Now + 1 + n.rng.Intn(n.Delay),
	})
}

// Advance visits simultaneous deliveries in send order.
func (n *Network[T]) Advance() []Delivery[T] {
	n.Now++
	var ready []Delivery[T]
	queued := n.pending[:0]
	for _, m := range n.pending {
		if m.at <= n.Now {
			ready = append(ready, m)
		} else {
			queued = append(queued, m)
		}
	}
	clear(n.pending[len(queued):])
	n.pending = queued
	return ready
}
~~~

</details>

### Step 2. Replay a seed

Set delay to four ticks and loss to 20 percent. Sketch a check that compares two runs with the same seed. Include a case where one direction is blocked and its reverse still works.

<details>
<summary>Hint 1</summary>

A map can answer membership questions without deciding delivery order.

</details>

<details>
<summary>Hint 2</summary>

Keep deliveries in a slice and compare the full arrival traces.

</details>

### Step 3. Compare silence

Send two heartbeats in both histories. Have the monitor suspect the sender after three ticks without a heartbeat. Let the paused peer resume at tick 7. Mark the first tick where the receiver can distinguish the histories.

<details>
<summary>Hint 1</summary>

Count from the last delivered heartbeat.

</details>

<details>
<summary>Hint 2</summary>

At tick 5 both histories are silent. At tick 7 the paused peer is heard from again.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/simnet/network_test.go -->
~~~go
package simnet

import (
	"reflect"
	"testing"
)

func TestOneWayLink(t *testing.T) {
	n := New[string](7)
	n.Send(1, 2, "already in flight")
	n.Block(1, 2, true)
	n.Send(1, 2, "dropped")
	n.Send(2, 1, "still delivered")
	got := n.Advance()
	if len(got) != 1 || got[0].Value != "still delivered" {
		t.Fatalf("deliveries: %+v", got)
	}
}

func TestSeedReplays(t *testing.T) {
	run := func() []Delivery[int] {
		n := New[int](42)
		n.Loss, n.Delay = 20, 4
		for i := range 30 {
			n.Send(1, 2, i)
		}
		var result []Delivery[int]
		for range 4 {
			result = append(result, n.Advance()...)
		}
		return result
	}
	first := run()
	if len(first) == 0 || len(first) == 30 || !reflect.DeepEqual(first, run()) {
		t.Fatalf("unexpected replay: %+v", first)
	}
}

func TestSilenceLooksTheSame(t *testing.T) {
	type observation struct {
		arrivals, suspected []int
	}
	trace := func(crashed bool) observation {
		n := New[bool](7)
		var seen observation
		last := 0
		for tick := 1; tick <= 9; tick++ {
			// A paused sender wakes on tick 7. A crashed sender stays gone.
			if tick <= 2 || (!crashed && tick >= 7) {
				n.Send(1, 2, true)
			}
			if len(n.Advance()) != 0 {
				last = n.Now
				seen.arrivals = append(seen.arrivals, n.Now)
			}
			if n.Now-last >= 3 {
				seen.suspected = append(seen.suspected, n.Now)
			}
		}
		return seen
	}
	pause, crash := trace(false), trace(true)
	if !reflect.DeepEqual(pause.arrivals, []int{1, 2, 7, 8, 9}) ||
		!reflect.DeepEqual(crash.arrivals, []int{1, 2}) ||
		!reflect.DeepEqual(pause.suspected, []int{5, 6}) ||
		!reflect.DeepEqual(crash.suspected, []int{5, 6, 7, 8, 9}) {
		t.Fatal("unexpected heartbeat traces", pause, crash)
	}
	t.Logf("arrivals when paused: %v; when crashed: %v", pause.arrivals, crash.arrivals)
	t.Logf("suspected when paused: %v; when crashed: %v", pause.suspected, crash.suspected)
}
~~~

</details>

## Check it

~~~bash
test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 -v ./...
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 -v ./... -->

~~~text
network_test.go:69: arrivals when paused: [1 2 7 8 9]; when crashed: [1 2]
network_test.go:70: suspected when paused: [5 6]; when crashed: [5 6 7 8 9]
~~~

The shared prefix makes a timeout an observation about recent messages. The test uses one fixed pause duration.

Full captures are in [01-network.txt](../evidence/lessons/01-network.txt).

## If it goes wrong

| Symptom | What to inspect |
|---|---|
| Timing changes between runs | Look for wall time or map iteration in the simulated event path. |
| Blocking the forward link kills return traffic | Key the partition by both sender and receiver in that order. |

## Explain it

1. What does the receiver know at tick 5?
2. How would you add a reproducible duplicate delivery?
