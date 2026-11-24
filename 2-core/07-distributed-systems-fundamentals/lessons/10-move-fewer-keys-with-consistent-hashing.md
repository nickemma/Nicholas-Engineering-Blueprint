# 10 Move fewer keys with consistent hashing

> Core 07 · About 7 hours · Builds on the preceding lesson

## The problem

A cache adds a server to handle more traffic. With placement by `hash(key) % N`, changing N also changes placement for most old keys. Their former cached copies are now useless and requests go back to the origin.

## The mental model

Put both keys and a server's **virtual nodes** on a ring of hash values. Each virtual node is a point assigned to one real server. A key belongs to the first point at or after its own hash, wrapping around to the first point if needed. Adding a point claims the arc immediately before that point. A key that moves on an addition should move to the new server.

## The pattern

A cache can recover a moved key from an origin. This lab gives each simulated server its own in-memory cache and uses an immutable origin. Moving durable source data would require a transfer protocol. Raft provides replicated agreement for Switchyard metadata. The ring places disposable copies of that metadata. Its balance metric counts distinct keys. A workload with a hot key can still concentrate requests on one server.

## Build it

### Step 1. Find the next point clockwise

Hash each server and replica number to a point. Sort those points. Fill in `if next == len(points) { next = /* TODO */ }` to handle wraparound.

<details>
<summary>Hint 1</summary>

The largest key hash can exceed the last server point.

</details>

<details>
<summary>Hint 2</summary>

Wrap to index zero. Sort input names first so collisions have a deterministic tie order.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/ring/ring.go -->
~~~go
// Package ring assigns cache keys to fixed points on a hash circle.
package ring

import (
	"crypto/sha256"
	"encoding/binary"
	"slices"
	"sort"
	"strconv"
)

type point struct {
	hash uint64
	node string
}

type Ring struct {
	points []point
}

func hash(key string) uint64 {
	sum := sha256.Sum256([]byte(key))
	return binary.BigEndian.Uint64(sum[:8])
}

func New(nodes []string, replicas int) Ring {
	var ring Ring
	nodes = slices.Clone(nodes)
	slices.Sort(nodes)
	for _, node := range slices.Compact(nodes) {
		for replica := range replicas {
			position := hash(node + "#" + strconv.Itoa(replica))
			ring.points = append(ring.points, point{hash: position, node: node})
		}
	}
	// Stable sorting gives colliding points an order independent of input order.
	sort.SliceStable(ring.points, func(i, j int) bool { return ring.points[i].hash < ring.points[j].hash })
	return ring
}

func (r Ring) Owner(key string) (string, bool) {
	if len(r.points) == 0 {
		return "", false
	}
	position := hash(key)
	next := sort.Search(len(r.points), func(i int) bool { return r.points[i].hash >= position })
	if next == len(r.points) {
		next = 0
	}
	return r.points[next].node, true
}

func Modulo(nodes []string, key string) (string, bool) {
	if len(nodes) == 0 {
		return "", false
	}
	return nodes[hash(key)%uint64(len(nodes))], true
}
~~~

</details>

### Step 2. Keep the surviving cache warm

Give each member a cache map. On membership change keep maps for surviving servers. Fetch a moved key from the origin the first time its new owner sees it.

<details>
<summary>Hint 1</summary>

An empty ring has no owner.

</details>

<details>
<summary>Hint 2</summary>

With no owner, fall back to the origin. Preserve each surviving shard's existing entries.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/ring/cache.go -->
~~~go
package ring

// Cache wraps an immutable origin in this lab. Each member has its own
// memory. Reassignment can be a miss because the origin still has the value.
type Cache struct {
	ring   Ring
	shards map[string]map[string]string
}

func (c *Cache) SetNodes(nodes []string) {
	next := make(map[string]map[string]string, len(nodes))
	for _, node := range nodes {
		next[node] = c.shards[node]
		if next[node] == nil {
			next[node] = make(map[string]string)
		}
	}
	c.shards = next
	c.ring = New(nodes, 128)
}

func (c *Cache) Get(key string, origin func(string) string) string {
	owner, present := c.ring.Owner(key)
	if !present {
		return origin(key)
	}
	shard := c.shards[owner]
	value, hit := shard[key]
	if !hit {
		value = origin(key)
		shard[key] = value
	}
	return value
}
~~~

</details>

### Step 3. Compare additions and removals

On the same key set, add D and then measure an independent removal of B. Check that keys owned by other servers stay put on removal and that cache misses match changed owners after an addition.

<details>
<summary>Hint 1</summary>

A remove test needs the old and new owner for every sampled key.

</details>

<details>
<summary>Hint 2</summary>

Only keys formerly at B should move when B goes away.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: internal/ring/ring_test.go -->
~~~go
package ring

import (
	"fmt"
	"testing"
)

func TestAddAndRemoveOnlyMoveAffectedKeys(t *testing.T) {
	first, expanded := New([]string{"A", "B", "C"}, 128), New([]string{"D", "C", "B", "A"}, 128)
	reordered := New([]string{"B", "C", "A"}, 128)
	moved := 0
	for i := range 10_000 {
		key := fmt.Sprintf("job/%d", i)
		old, _ := first.Owner(key)
		want, _ := reordered.Owner(key)
		got, _ := expanded.Owner(key)
		if old != want {
			t.Fatalf("input order changed %s", key)
		}
		if got != old {
			moved++
			if got != "D" {
				t.Fatalf("unaffected key %s went from %s to %s", key, old, got)
			}
		}
	}
	if moved < 1500 || moved > 3500 {
		t.Fatalf("D took an unexpected share: %d", moved)
	}
	t.Logf("add D or remove it again: %d of 10,000 keys move, all to or from D", moved)
}

func TestCacheUsesOriginOnlyForChangedOwners(t *testing.T) {
	before := []string{"A", "B", "C"}
	after := []string{"A", "B", "C", "D"}
	var cache Cache
	loads := 0
	origin := func(key string) string {
		loads++
		return "metadata for " + key
	}
	cache.SetNodes(before)
	for i := range 1000 {
		cache.Get(fmt.Sprint(i), origin)
	}
	cache.SetNodes(after)
	loads = 0
	changes := 0
	original := New(before, 128)
	for i := range 1000 {
		key := fmt.Sprint(i)
		was, _ := original.Owner(key)
		now, _ := cache.ring.Owner(key)
		if was != now {
			changes++
		}
		if value := cache.Get(key, origin); value != "metadata for "+key {
			t.Fatal("lost origin value", key, value)
		}
	}
	if changes == 0 || changes != loads {
		t.Fatalf("changed=%d cache misses=%d", changes, loads)
	}
	cache.SetNodes(nil)
	if got := cache.Get("42", origin); got != "metadata for 42" || loads != changes+1 {
		t.Fatal("failed to bypass an empty ring", got)
	}
	t.Logf("%d reassigned keys caused exactly %d cold misses", changes, changes)
}

func TestRemovingAMemberKeepsOtherKeysInPlace(t *testing.T) {
	before := New([]string{"A", "B", "C", "D"}, 128)
	after := New([]string{"A", "C", "D"}, 128)
	shifted := 0
	for i := range 1000 {
		key := fmt.Sprint(i)
		old, _ := before.Owner(key)
		now, found := after.Owner(key)
		if !found || (old != now) != (old == "B") {
			t.Fatalf("unexpected move for %s: %s to %s", key, old, now)
		}
		if old != now {
			shifted++
		}
	}
	if shifted == 0 {
		t.Fatal("no keys were owned by B")
	}
}
~~~

</details>

### Step 4. Run a skewed workload

Measure placement for 10,000 keys with modulo, one ring point per server, and 128 points per server. Repeat one of those keys 6,000 more times. Report the owner's request count.

<details>
<summary>Hint 1</summary>

A balanced number of keys can coexist with a large difference in request count.

</details>

<details>
<summary>Hint 2</summary>

Start with one request per key. Add repeated requests to the hot key's owner.

</details>

<details>
<summary>Type-along answer</summary>

For an existing file, the old fragment comes first and its replacement follows. New files are shown in full.

<!-- file: cmd/hashdemo/main.go -->
~~~go
package main

import (
	"fmt"

	"switchyard/metad/internal/ring"
)

func main() {
	before, after := []string{"A", "B", "C"}, []string{"A", "B", "C", "D"}
	old, next := ring.New(before, 128), ring.New(after, 128)
	single := ring.New(after, 1)
	onePoint, manyPoints := map[string]int{}, map[string]int{}
	modMoved, ringMoved := 0, 0
	for i := range 10_000 {
		key := fmt.Sprintf("job/%d", i)
		oldMod, _ := ring.Modulo(before, key)
		newMod, _ := ring.Modulo(after, key)
		if oldMod != newMod {
			modMoved++
		}
		previous, _ := old.Owner(key)
		current, _ := next.Owner(key)
		if previous != current {
			ringMoved++
		}
		one, _ := single.Owner(key)
		onePoint[one]++
		manyPoints[current]++
	}
	fmt.Printf("add D: modulo moves %d/10000; ring moves %d/10000\n", modMoved, ringMoved)
	for _, node := range after {
		fmt.Printf("node %s holds %d keys with 1 point; %d with 128 points\n", node, onePoint[node], manyPoints[node])
	}
	hot := "job/42"
	requests := map[string]int{}
	for node, count := range manyPoints {
		requests[node] = count // One request per distinct key.
	}
	for range 6_000 {
		owner, _ := next.Owner(hot)
		requests[owner]++
	}
	owner, _ := next.Owner(hot)
	fmt.Printf("node %s owns hot key %s and gets %d/16000 requests\n", owner, hot, requests[owner])
}
~~~

</details>

## Check it

~~~bash
test -z "$(gofmt -l .)" && go vet ./... && METAD_WAL_WRITER="$PWD/klog/target/debug/metad-wal" go test -race -count=1 -v ./... && go run -buildvcs=false ./cmd/hashdemo
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && METAD_WAL_WRITER="$PWD/klog/target/debug/metad-wal" go test -race -count=1 -v ./... && go run -buildvcs=false ./cmd/hashdemo -->

~~~text
add D: modulo moves 7551/10000; ring moves 2503/10000
node A holds 1283 keys with 1 point; 2546 with 128 points
node B holds 3475 keys with 1 point; 2797 with 128 points
node C holds 4474 keys with 1 point; 2154 with 128 points
node D holds 768 keys with 1 point; 2503 with 128 points
node D owns hot key job/42 and gets 8503/16000 requests
~~~

For this key set, adding D under modulo moved 7,551 keys. With the ring 2,503 moved, all to D. With skew, D handles more than half of requests.

Full captures are in [10-ring.txt](../evidence/lessons/10-ring.txt), [10-ring-tests.txt](../evidence/lessons/10-ring-tests.txt).

## If it goes wrong

| Symptom | What to inspect |
|---|---|
| An unrelated key moves on removal | Check that point identity depends on its server and replica number, independent of membership order. |
| One member still saturates with many virtual nodes | Measure requests by key and check for a hot key. |

## Explain it

1. What makes a cache miss acceptable after reassignment?
2. Why would rebuilding a sharded system of record require more than updating a ring?
