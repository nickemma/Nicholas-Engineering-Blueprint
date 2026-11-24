# 07 Withdraw an anycast site in a route simulator

> Networking in depth · Week 3 · Builds on lesson 06

## The problem

Two sites offer the same service. A client gets a different path when its network prefers one neighbor or when one site withdraws.

## The mental model

Draw four autonomous systems. Advertise one service from two of them. Each round uses the previous round’s path announcements. Forbid an AS from selecting a path containing itself.

## The pattern

A path-vector model propagates paths and chooses among them locally. This model checks local preference, then path length and a deterministic final tie-break. Its rounds describe the model’s convergence. It sends no route advertisements.

## Build it

### Step 1 — Predict a first route

Choose the shorter path in the absence of a preference. Then change the local preference for the longer path.

<details>
<summary>Hint</summary>

A local routing preference can outweigh the path length.

</details>

### Step 2 — Run bounded rounds

Visit the nodes with a seeded iteration order, use the previous round’s state, and bound convergence. Record the observed path after each round.

<details>
<summary>Hint</summary>

The challenge is to model old paths disappearing after a withdrawal.

</details>

<details>
<summary>Implementation</summary>

Create `route/model.go`.

<!-- file: route/model.go -->
~~~go
// Package route models one service prefix over a fixed path-vector graph.
package route

import (
	"fmt"
	"math/rand"
	"slices"
)

type AS int
type link struct{ from, to AS }

type Model struct {
	peers      map[AS][]AS
	sites      map[AS]bool
	preference map[link]int
	best       map[AS][]AS
}

func New() *Model {
	return &Model{peers: map[AS][]AS{}, sites: map[AS]bool{}, preference: map[link]int{}, best: map[AS][]AS{}}
}

func (m *Model) Link(a, b AS) {
	m.peers[a] = append(m.peers[a], b)
	m.peers[b] = append(m.peers[b], a)
}

func (m *Model) Site(as AS, present bool) {
	m.sites[as] = present
	if _, known := m.peers[as]; !known {
		m.peers[as] = nil
	}
}

func (m *Model) Prefer(at, through AS, value int) {
	m.preference[link{at, through}] = value
}

func (m *Model) choose(at AS, a, b []AS) bool {
	if b == nil {
		return true
	}
	pa, pb := m.preference[link{at, a[1]}], m.preference[link{at, b[1]}]
	if pa != pb {
		return pa > pb
	}
	if len(a) != len(b) {
		return len(a) < len(b)
	}
	return a[1] < b[1]
}

func (m *Model) Settle(seed int64, observe AS) ([][]AS, error) {
	nodes := make([]AS, 0, len(m.peers))
	for as := range m.peers {
		nodes = append(nodes, as)
	}
	slices.Sort(nodes)
	rng := rand.New(rand.NewSource(seed))
	var trace [][]AS
	for range 64 {
		next := make(map[AS][]AS)
		changed := false
		for _, index := range rng.Perm(len(nodes)) {
			at := nodes[index]
			var choice []AS
			if m.sites[at] {
				choice = []AS{at}
			} else {
				for _, peer := range m.peers[at] {
					path := m.best[peer]
					if len(path) == 0 || slices.Contains(path, at) {
						continue
					}
					candidate := append([]AS{at}, path...)
					if m.choose(at, candidate, choice) {
						choice = candidate
					}
				}
			}
			next[at] = choice
			changed = changed || !slices.Equal(choice, m.best[at])
		}
		m.best = next
		trace = append(trace, slices.Clone(next[observe]))
		if !changed {
			return trace, nil
		}
	}
	return trace, fmt.Errorf("route decisions have not settled after 64 rounds")
}
~~~

</details>

### Step 3 — Check withdrawal and empty routing

Withdraw the preferred site, then withdraw the alternate. Verify the chosen route after both changes.

<details>
<summary>Hint</summary>

Keep the first route when it stabilizes and the final empty path when neither site remains.

</details>

<details>
<summary>Implementation</summary>

Create `route/model_test.go`.

<!-- file: route/model_test.go -->
~~~go
package route

import (
	"slices"
	"testing"
)

func TestWithdrawalMovesTheService(t *testing.T) {
	for _, seed := range []int64{7, 53} {
		m := New()
		m.Link(1, 2)
		m.Link(1, 3)
		m.Link(3, 4)
		m.Site(2, true)
		m.Site(4, true)
		check := func(want []AS) [][]AS {
			t.Helper()
			trace, err := m.Settle(seed, 1)
			if err != nil || !slices.Equal(trace[len(trace)-1], want) {
				t.Fatalf("trace %v; want %v: %v", trace, want, err)
			}
			return trace
		}
		check([]AS{1, 2})
		m.Prefer(1, 3, 10)
		check([]AS{1, 3, 4})
		m.Site(4, false)
		trace := check([]AS{1, 2})
		m.Site(2, false)
		check(nil)
		if seed == 7 {
			t.Logf("withdrawal selected [1 2] after %d rounds, including the confirming round; trace %v", len(trace), trace)
		}
	}
}
~~~

</details>

## Check it

~~~bash
go test -v ./route
~~~

<!-- run: go test -v ./route -->

In the reference graph the surviving route was `[1 2]`. The full model settled after six rounds including the confirming round.

## If it goes wrong

If the model oscillates, inspect the local preferences and keep the bounded trace. If a loop remains, verify that the candidate path is checked before selection.
