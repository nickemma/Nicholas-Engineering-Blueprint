# 11. Shortest paths: Dijkstra

<!-- continue: ../10-union-find/README.md -->

BFS finds the fewest **edges**. When edges have **weights** (milliseconds, kilometres, cost), the fewest edges can be the slowest route. **Dijkstra's algorithm** finds the cheapest path from one source to every node, provided no weight is negative. It's BFS with a priority queue (guide 08) instead of a plain queue: always settle the closest unsettled node next.

**Recognise it when:**

- the graph has non-negative weights, and the problem asks for the minimum total;
- the question is "how long until everything is reached?" or "the cheapest way from A to B";
- a grid's moves cost different amounts.

If weights can be negative, use Bellman-Ford. If every weight is the same, plain BFS is simpler and faster.

**Real systems:**
- **Link-state routing.** OSPF and IS-IS routers each run Dijkstra over the network map to build their forwarding tables. That's the layer below the networking in [Phase 2](../../lessons/02-connected-services/TEACHING.md#step-7-look-at-the-wire) and [Phase 5](../../lessons/05-constrained-operations/TEACHING.md#step-4-services-dns-and-load-balancing).
- **Maps:** route planners start from it.

## Worked problem: Network Delay Time

[LeetCode 743](https://leetcode.com/problems/network-delay-time/). *n* nodes, labelled 1 to *n*, and directed edges `(u, v, w)`: a signal from *u* reaches *v* after *w* milliseconds. A signal starts at node *k*. How long until every node has it? Return −1 if some node never does.

| Edges | *n* | *k* | Output |
|---|---|---|---|
| `[[2, 1, 1], [2, 3, 1], [3, 4, 1]]` | 4 | 2 | 2 |
| `[[1, 2, 1]]` | 2 | 2 | −1 (nothing leaves node 2) |

**Think first.** The time a node gets the signal is its shortest-path distance from *k*. The answer is the **largest** of those distances. Dijkstra computes them all:

1. Put (0, *k*) on a min-heap of (distance, node).
2. Pop the closest. If it's already **settled**, skip it (an older, longer entry). Otherwise settle it: its distance is now final.
3. For each edge out of it, push (distance + weight, neighbour).
4. Repeat until the heap is empty.

Why is a popped node's distance final? Every other path to it would go through a node that's at least as far away, and weights can't be negative, so no path found later can be shorter. This is exactly where negative weights break the algorithm.

<!-- file: shortestpaths/delay.go -->
~~~go
// Package shortestpaths holds the weighted shortest-path problems.
package shortestpaths

import "container/heap"

type item struct{ dist, node int }

// byDist is a min-heap of items by distance, for container/heap.
type byDist []item

func (h byDist) Len() int           { return len(h) }
func (h byDist) Less(i, j int) bool { return h[i].dist < h[j].dist }
func (h byDist) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *byDist) Push(x any)        { *h = append(*h, x.(item)) }
func (h *byDist) Pop() any {
	old := *h
	x := old[len(old)-1]
	*h = old[:len(old)-1]
	return x
}

// NetworkDelay returns how long a signal from k takes to reach all n nodes
// (labelled 1..n) over directed edges {u, v, w}, or -1 if some never hears
// it. Dijkstra with a binary heap: O(e log e) time, O(n + e) space.
func NetworkDelay(edges [][3]int, n, k int) int {
	out := make([][]item, n+1) // u → its edges, as {weight, v}
	for _, e := range edges {
		out[e[0]] = append(out[e[0]], item{dist: e[2], node: e[1]})
	}
	settled := make([]bool, n+1)
	h := &byDist{{0, k}}
	latest, reached := 0, 0
	for h.Len() > 0 {
		cur := heap.Pop(h).(item)
		if settled[cur.node] {
			continue // a stale, longer entry: the node was settled earlier
		}
		settled[cur.node] = true
		reached++
		latest = cur.dist // pops come in increasing distance: this is the max so far
		for _, e := range out[cur.node] {
			if !settled[e.node] {
				heap.Push(h, item{dist: cur.dist + e.dist, node: e.node})
			}
		}
	}
	if reached < n {
		return -1
	}
	return latest
}
~~~

- Instead of updating an entry's priority inside the heap (which `container/heap` can't do without extra bookkeeping), this pushes a new entry and **skips stale ones** when popped. That's called lazy deletion, and it's the usual way to write Dijkstra.
- Nodes are popped in increasing distance, so the last settled node's distance is the answer.

<!-- file: shortestpaths/delay_test.go -->
~~~go
package shortestpaths

import "testing"

func TestNetworkDelay(t *testing.T) {
	cases := []struct {
		name  string
		edges [][3]int
		n, k  int
		want  int
	}{
		{"example", [][3]int{{2, 1, 1}, {2, 3, 1}, {3, 4, 1}}, 4, 2, 2},
		{"unreachable", [][3]int{{1, 2, 1}}, 2, 2, -1},
		{"only the source", nil, 1, 1, 0},
		// The direct edge costs 10; the way round costs 1 + 1 + 1 = 3.
		{"fewest edges isn't fastest", [][3]int{{1, 4, 10}, {1, 2, 1}, {2, 3, 1}, {3, 4, 1}}, 4, 1, 3},
		{"two ways in", [][3]int{{1, 2, 1}, {2, 3, 2}, {1, 3, 4}}, 3, 1, 3},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := NetworkDelay(c.edges, c.n, c.k); got != c.want {
				t.Errorf("NetworkDelay = %d, want %d", got, c.want)
			}
		})
	}
}
~~~

"Fewest edges isn't fastest" is the case plain BFS gets wrong: with a first-in, first-out queue instead of the heap, node 4 is settled through the direct edge, at 10 milliseconds, before the cheaper way round is found.

<!-- run: test -z "$(gofmt -l .)" && go vet ./shortestpaths/ && go test ./shortestpaths/ -->

<!-- file: shortestpaths/delay.py -->
~~~python
import heapq


def network_delay(edges: list[tuple[int, int, int]], n: int, k: int) -> int:
    """Time for a signal from k to reach all n nodes (1..n), or -1."""
    out: dict[int, list[tuple[int, int]]] = {}
    for u, v, w in edges:
        out.setdefault(u, []).append((w, v))
    settled: set[int] = set()
    h = [(0, k)]
    latest = 0
    while h:
        dist, node = heapq.heappop(h)
        if node in settled:
            continue
        settled.add(node)
        latest = dist
        for w, v in out.get(node, []):
            if v not in settled:
                heapq.heappush(h, (dist + w, v))
    return latest if len(settled) == n else -1
~~~

<!-- file: shortestpaths/test_delay.py -->
~~~python
import pytest

from shortestpaths.delay import network_delay


@pytest.mark.parametrize(
    ("edges", "n", "k", "want"),
    [
        ([(2, 1, 1), (2, 3, 1), (3, 4, 1)], 4, 2, 2),
        ([(1, 2, 1)], 2, 2, -1),
        ([], 1, 1, 0),
        ([(1, 4, 10), (1, 2, 1), (2, 3, 1), (3, 4, 1)], 4, 1, 3),
        ([(1, 2, 1), (2, 3, 2), (1, 3, 4)], 3, 1, 3),
    ],
)
def test_network_delay(edges, n, k, want):
    assert network_delay(edges, n, k) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q shortestpaths -->

**Complexity:** O(*e* log *e*) time with lazy deletion (each edge pushes at most once); O(*n* + *e*) space.

## Pitfalls

- **Negative weights** silently give wrong answers. Check the problem says weights are non-negative.
- **Settling on push instead of pop.** A node's distance is final only when it comes off the heap.
- **Forgetting stale entries.** Without the `settled` check, a node is expanded once per entry: still correct, but much slower.
- **Grids are graphs too.** Each cell is a node with up to four weighted edges; don't build the graph, compute neighbours on the fly.

## Practice

1. **[Path With Minimum Effort](https://leetcode.com/problems/path-with-minimum-effort/)** (medium). Minimise the largest height step along a path across a grid.
   <details><summary>Hint</summary>Dijkstra where a path's cost is the <b>maximum</b> step so far, not the sum. It still works, because extending a path never lowers its cost.</details>
2. **[Cheapest Flights Within K Stops](https://leetcode.com/problems/cheapest-flights-within-k-stops/)** (medium).
   <details><summary>Hint</summary>The stop limit breaks plain Dijkstra (a cheaper path with too many stops can block a dearer valid one). Bellman-Ford for <i>k</i> + 1 rounds, copying the distances each round, is simpler.</details>
3. **[Swim in Rising Water](https://leetcode.com/problems/swim-in-rising-water/)** (hard). The earliest time you can cross a grid whose cells flood at given times.
   <details><summary>Hint</summary>Practice 1 again: a path's cost is the highest cell on it. Or binary-search the time (guide 05) and flood-fill (guide 09).</details>

Next: [12. Intervals](../12-intervals/README.md).
