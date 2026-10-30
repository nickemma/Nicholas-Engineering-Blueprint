# 19. Design problems

<!-- continue: ../18-bit-manipulation/README.md -->

"Implement a data structure with these operations, at these costs." Design problems combine the earlier patterns:
- LRU Cache (guide 06) is a map plus a linked list;
- Min Stack (guide 04) is a stack with a shadow;
- Time-Based Key-Value Store (guide 05) is a map of sorted lists searched by binary search.

The skill is **choosing the structures from the required costs**. If an operation must be O(1), what lookup does it need? If one must return the minimum, what keeps it ready?

**Recognise it when** the problem is a class with methods, and each method has a target complexity.

**Real systems:** both worked problems here are pieces of Runway, rebuilt from scratch at interview size:
- the **token bucket** behind [Phase 6's rate limiter](../../lessons/06-safe-shared-queries/TEACHING.md#step-5-rate-limiting);
- the **consistent-hash ring** behind [Phase 4's sharded cache](../../lessons/04-replicated-state/TEACHING.md#step-11-consistent-hashing-and-a-cache-spread-over-several-servers).

They're also classic interview questions, at this exact size.

## The interview approach

1. **List the operations and their required costs.** Ask if they aren't given.
2. **Pick structures that meet each cost.** Say which operation each structure serves.
3. **Name the invariants**, the facts that must stay true after every operation, and check each method keeps them.
4. **Make time an input.** Anything that depends on the clock takes `now` as a parameter, so tests are exact and repeatable.

## Worked problem 1: a token bucket (our own)

A rate limiter that allows bursts. The bucket holds up to `burst` tokens and refills at `rate` tokens a second. Each request takes one token; with no token, it's refused.

~~~text
rate 1/s, burst 2, starting full at t = 0
t = 0      allow, allow, deny     (2 tokens, then empty)
t = 0.5    deny                   (half a token)
t = 1      allow                  (one whole token)
t = 10     allow, allow, deny     (refilled, but capped at 2)
~~~

**Think first.**
- Don't run a timer that adds tokens. Instead, store the token count and **when it was last updated**. On each request, add `elapsed × rate` tokens, capped at `burst`, then try to take one.
- That's O(1) time and O(1) memory per client, which is why rate limiters use it rather than storing timestamps (guide 03's "busiest window").
- **Invariant:** 0 ≤ tokens ≤ burst.
- A clock that goes **backwards** (an NTP correction) must not add tokens, or crash.

<!-- file: design/bucket.go -->
~~~go
// Package design holds the data-structure design problems.
package design

import "time"

// Bucket is a token bucket: up to burst tokens, refilled at rate per second.
// Each allowed request takes one token. It isn't safe for concurrent use;
// guard it with a mutex.
type Bucket struct {
	rate, burst float64
	tokens      float64
	last        time.Time
}

// NewBucket returns a full bucket, as of now.
func NewBucket(rate, burst float64, now time.Time) *Bucket {
	return &Bucket{rate: rate, burst: burst, tokens: burst, last: now}
}

// Allow reports whether a request at now may proceed, and takes a token if
// so. O(1).
func (b *Bucket) Allow(now time.Time) bool {
	if elapsed := now.Sub(b.last).Seconds(); elapsed > 0 {
		b.tokens = min(b.burst, b.tokens+elapsed*b.rate)
		b.last = now
	} // a clock that went backwards adds nothing
	if b.tokens >= 1 {
		b.tokens--
		return true
	}
	return false
}
~~~

<!-- file: design/bucket_test.go -->
~~~go
package design

import (
	"testing"
	"time"
)

func TestBucket(t *testing.T) {
	t0 := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	at := func(sec float64) time.Time { return t0.Add(time.Duration(sec * float64(time.Second))) }
	b := NewBucket(1, 2, t0)
	steps := []struct {
		sec  float64
		want bool
	}{
		{0, true}, {0, true}, {0, false}, // a burst of 2
		{0.5, false},          // half a token isn't enough
		{1, true}, {1, false}, // one whole token
		{10, true}, {10, true}, {10, false}, // refilled, capped at 2
		{5, false}, // the clock went back: nothing added
	}
	for i, s := range steps {
		if got := b.Allow(at(s.sec)); got != s.want {
			t.Errorf("step %d at t=%v: Allow = %v, want %v", i, s.sec, got, s.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./design/ && go test ./design/ -->

<!-- file: design/bucket.py -->
~~~python
class Bucket:
    """Token bucket: up to `burst` tokens, refilled at `rate` per second."""

    def __init__(self, rate: float, burst: float, now: float) -> None:
        self.rate, self.burst = rate, burst
        self.tokens = burst
        self.last = now

    def allow(self, now: float) -> bool:
        elapsed = now - self.last
        if elapsed > 0:
            self.tokens = min(self.burst, self.tokens + elapsed * self.rate)
            self.last = now
        if self.tokens >= 1:
            self.tokens -= 1
            return True
        return False
~~~

<!-- file: design/test_bucket.py -->
~~~python
from design.bucket import Bucket


def test_bucket():
    b = Bucket(rate=1, burst=2, now=0)
    steps = [
        (0, True), (0, True), (0, False),
        (0.5, False),
        (1, True), (1, False),
        (10, True), (10, True), (10, False),
        (5, False),
    ]  # fmt: skip
    for now, want in steps:
        assert b.allow(now) == want, f"at t={now}"
~~~

`# fmt: skip` keeps the steps grouped by moment, the way they're read.

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q design -->

**Complexity:** O(1) time and space per bucket.

## Worked problem 2: a consistent-hash ring (our own)

Spread keys over *n* servers so that adding or removing a server moves as few keys as possible.

`hash(key) % n` moves almost **every** key when *n* changes. A ring moves only about 1/*n* of them:
- Hash each server to several points on a circle of 2⁶⁴ positions (**virtual nodes**, which even out the load).
- A key belongs to the first server point at or after the key's own hash, wrapping round at the end.
- A new server only takes keys from the arc just before each of its points.

**Think first.**
- The ring is a **sorted** array of points, so a lookup is a binary search (guide 05): the first point with hash ≥ the key's hash, or index 0 if there's none.
- Adding a server inserts its points; removing one filters them out.
- The hash must be the same in every process, and on every machine. Python's built-in `hash()` of a string is randomised per process (Phase 7 met this exact trap), so both versions use SHA-256.

<!-- file: design/ring.go -->
~~~go
package design

import (
	"cmp"
	"crypto/sha256"
	"encoding/binary"
	"slices"
	"strconv"
)

// Ring assigns keys to nodes by consistent hashing, with replicas virtual
// points per node. It isn't safe for concurrent use.
type Ring struct {
	replicas int
	points   []point // sorted by hash
}

type point struct {
	hash uint64
	node string
}

// NewRing returns an empty ring.
func NewRing(replicas int) *Ring { return &Ring{replicas: replicas} }

// hash64 is the first 8 bytes of SHA-256: stable across processes and
// languages, and well spread.
func hash64(s string) uint64 {
	sum := sha256.Sum256([]byte(s))
	return binary.BigEndian.Uint64(sum[:8])
}

// Add places node at replicas points. O(r log(r·n)) for the sort.
func (r *Ring) Add(node string) {
	for i := range r.replicas {
		r.points = append(r.points, point{hash64(node + "#" + strconv.Itoa(i)), node})
	}
	slices.SortFunc(r.points, func(a, b point) int { return cmp.Compare(a.hash, b.hash) })
}

// Remove takes node's points off the ring.
func (r *Ring) Remove(node string) {
	r.points = slices.DeleteFunc(r.points, func(p point) bool { return p.node == node })
}

// Get returns the node that owns key, or "" if the ring is empty.
// O(log(r·n)): a binary search.
func (r *Ring) Get(key string) string {
	if len(r.points) == 0 {
		return ""
	}
	h := hash64(key)
	i, _ := slices.BinarySearchFunc(r.points, h, func(p point, h uint64) int { return cmp.Compare(p.hash, h) })
	if i == len(r.points) {
		i = 0 // past the last point: wrap round to the first
	}
	return r.points[i].node
}
~~~

`slices.BinarySearchFunc` returns where `h` would be inserted, which is exactly the first point with hash ≥ `h`: guide 05's template, from the standard library.

The tests check the **properties** that make it consistent hashing, not particular assignments:

<!-- file: design/ring_test.go -->
~~~go
package design

import (
	"fmt"
	"testing"
)

func keys(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("job-%d", i)
	}
	return out
}

func owners(r *Ring, ks []string) map[string]string {
	m := make(map[string]string, len(ks))
	for _, k := range ks {
		m[k] = r.Get(k)
	}
	return m
}

func TestEmptyRing(t *testing.T) {
	if got := NewRing(10).Get("x"); got != "" {
		t.Errorf("Get on an empty ring = %q, want \"\"", got)
	}
}

func TestLoadIsSpread(t *testing.T) {
	r := NewRing(100)
	for _, n := range []string{"a", "b", "c", "d"} {
		r.Add(n)
	}
	count := map[string]int{}
	for _, k := range keys(10000) {
		count[r.Get(k)]++
	}
	for n, c := range count {
		if c < 1500 || c > 3500 { // a fair share is 2,500
			t.Errorf("node %s owns %d of 10000 keys", n, c)
		}
	}
}

func TestAddingANodeMovesKeysOnlyToIt(t *testing.T) {
	r := NewRing(100)
	for _, n := range []string{"a", "b", "c"} {
		r.Add(n)
	}
	ks := keys(10000)
	before := owners(r, ks)
	r.Add("d")
	moved := 0
	for _, k := range ks {
		if now := r.Get(k); now != before[k] {
			moved++
			if now != "d" {
				t.Fatalf("%s moved from %s to %s, not to the new node", k, before[k], now)
			}
		}
	}
	if moved < 1500 || moved > 3500 { // about a quarter should move
		t.Errorf("%d of 10000 keys moved, want about 2500", moved)
	}
}

func TestRemovingANodeMovesOnlyItsKeys(t *testing.T) {
	r := NewRing(100)
	for _, n := range []string{"a", "b", "c", "d"} {
		r.Add(n)
	}
	ks := keys(10000)
	before := owners(r, ks)
	r.Remove("b")
	for _, k := range ks {
		if now := r.Get(k); before[k] != "b" && now != before[k] {
			t.Fatalf("%s moved from %s to %s, though %s wasn't removed", k, before[k], now, before[k])
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./design/ && go test ./design/ -->

<!-- file: design/ring.py -->
~~~python
import bisect
import hashlib


def hash64(s: str) -> int:
    """First 8 bytes of SHA-256: stable across processes, unlike hash()."""
    return int.from_bytes(hashlib.sha256(s.encode()).digest()[:8], "big")


class Ring:
    """Consistent hashing with `replicas` virtual points per node."""

    def __init__(self, replicas: int) -> None:
        self.replicas = replicas
        self.points: list[tuple[int, str]] = []  # (hash, node), sorted

    def add(self, node: str) -> None:
        self.points.extend((hash64(f"{node}#{i}"), node) for i in range(self.replicas))
        self.points.sort()

    def remove(self, node: str) -> None:
        self.points = [p for p in self.points if p[1] != node]

    def get(self, key: str) -> str | None:
        if not self.points:
            return None
        i = bisect.bisect_left(self.points, (hash64(key), ""))
        return self.points[i % len(self.points)][1]
~~~

- `bisect_left` with the tuple `(hash, "")` finds the first point whose hash is ≥ the key's: `""` sorts before any node name.
- `i % len(self.points)` wraps round past the last point.
- Both versions use the same hash and the same point names, so for the same nodes they assign every key to the same node.

<!-- file: design/test_ring.py -->
~~~python
from collections import Counter

from design.ring import Ring

KEYS = [f"job-{i}" for i in range(10000)]


def ring_of(*nodes):
    r = Ring(100)
    for n in nodes:
        r.add(n)
    return r


def test_empty_ring():
    assert Ring(10).get("x") is None


def test_load_is_spread():
    counts = Counter(ring_of("a", "b", "c", "d").get(k) for k in KEYS)
    assert all(1500 <= c <= 3500 for c in counts.values()), counts


def test_adding_a_node_moves_keys_only_to_it():
    r = ring_of("a", "b", "c")
    before = {k: r.get(k) for k in KEYS}
    r.add("d")
    moved = [k for k in KEYS if r.get(k) != before[k]]
    assert all(r.get(k) == "d" for k in moved)
    assert 1500 <= len(moved) <= 3500


def test_removing_a_node_moves_only_its_keys():
    r = ring_of("a", "b", "c", "d")
    before = {k: r.get(k) for k in KEYS}
    r.remove("b")
    assert all(r.get(k) == before[k] for k in KEYS if before[k] != "b")
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q design -->

**Complexity:** `Get` is O(log(*r*·*n*)) for *r* points per node and *n* nodes; `Add` and `Remove` are O(*r*·*n* log(*r*·*n*)) here, fine because membership changes rarely. Space is O(*r*·*n*).

## Pitfalls

- **Reading the real clock inside the structure.** Pass `now` in; tests become exact, and so do replays.
- **Unstable hashes.** Python's `hash()` and Go's `maphash` change between processes. Anything shared across machines needs a fixed hash.
- **Forgetting concurrency.** Interview answers are single-threaded, but say where the mutex would go.
- **Not stating the invariants.** "Tokens stay between 0 and burst" is what tells you a clock jump is a bug to handle.

## Practice

1. **[Insert Delete GetRandom O(1)](https://leetcode.com/problems/insert-delete-getrandom-o1/)** (medium). A set with O(1) insert, remove and uniform random choice.
   <details><summary>Hint</summary>An array for random choice, and a map from value to index. To remove, move the last element into the hole.</details>
2. **[LFU Cache](https://leetcode.com/problems/lfu-cache/)** (hard). Evict the least **frequently** used key, breaking ties by least recent.
   <details><summary>Hint</summary>A map from key to node, and a map from frequency to an LRU list (guide 06), plus the current minimum frequency.</details>
3. **[Design Twitter](https://leetcode.com/problems/design-twitter/)** (medium). Post, follow, unfollow, and the 10 most recent tweets from people you follow.
   <details><summary>Hint</summary>Each user's tweets in time order; the feed is "merge <i>k</i> sorted lists", stopping at 10 (guide 08). This is the news-feed system-design question, at interview size.</details>

Also revisit the design problems from earlier guides: Min Stack (04), Time-Based Key-Value Store (05) and LRU Cache (06).

You've finished the patterns. Keep the [spaced review](../README.md#spaced-review) going, and do a [timed mock](../README.md#practising-like-the-real-thing) every two weeks.
