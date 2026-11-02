# 10. Union-find

<!-- continue: ../09-graphs/README.md -->

Union-find (also called a disjoint-set union) keeps track of groups that **merge** and never split. It answers two questions, each in nearly O(1):

- **`Find(x)`:** which group is *x* in? It returns the group's representative, its **root**.
- **`Union(x, y)`:** merge *x*'s group with *y*'s.

Each element points at a parent, and a root points at itself. Two tricks make the trees almost flat:
- **union by size:** hang the smaller tree under the larger;
- **path compression:** while finding a root, point nodes closer to it.

With both, a long run of operations costs O(α(*n*)) each. α is the inverse Ackermann function, which is less than 5 for any *n* you'll ever see.

**Recognise it when:**

- connections arrive one at a time, and you ask "are these two connected?" in between;
- you need the number of connected components as edges are added;
- you're looking for the edge that would create a cycle;
- you're grouping by equivalence ("these two accounts share an email").

**Real systems:**
- **Partition analysis.** During a network partition, which nodes can reach each other? Each live link unions two nodes, and every group with a majority could elect a leader. Those are the partitions [Phase 4](../../lessons/04-replicated-state/TEACHING.md#step-6-partial-partitions-prevote-and-checkquorum) injects, and the ones KESTREL studies.
- **Kruskal's minimum-spanning-tree algorithm,** and type inference in compilers.

## Worked problem: Redundant Connection

[LeetCode 684](https://leetcode.com/problems/redundant-connection/). A tree of *n* nodes (labelled 1 to *n*) had one extra edge added. Given the edges in order, return the edge whose removal leaves a tree. If several would, return the one that appears last.

| Edges | Output |
|---|---|
| `[[1, 2], [1, 3], [2, 3]]` | `[2, 3]` |
| `[[1, 2], [2, 3], [3, 4], [1, 4], [1, 5]]` | `[1, 4]` |

**Think first.**
- Add the edges one at a time.
- An edge whose two ends are **already connected** closes a cycle; it's redundant.
- "Already connected?" is `Find(a) == Find(b)`. Otherwise, `Union(a, b)`.
- The first edge that closes the cycle is also the last of the cycle's edges in the input, which is the one the problem asks for.

<!-- file: unionfind/dsu.go -->
~~~go
// Package unionfind holds a disjoint-set union and its problems.
package unionfind

// DSU is a disjoint-set union over the elements 0..n-1.
type DSU struct {
	parent, size []int
}

// New returns n elements, each in a group of its own.
func New(n int) *DSU {
	d := &DSU{parent: make([]int, n), size: make([]int, n)}
	for i := range n {
		d.parent[i], d.size[i] = i, 1
	}
	return d
}

// Find returns the root of x's group, pointing nodes on the way at their
// grandparent (path halving), which keeps the trees flat.
func (d *DSU) Find(x int) int {
	for d.parent[x] != x {
		d.parent[x] = d.parent[d.parent[x]]
		x = d.parent[x]
	}
	return x
}

// Union merges the groups of x and y. It returns false if they were
// already one group.
func (d *DSU) Union(x, y int) bool {
	rx, ry := d.Find(x), d.Find(y)
	if rx == ry {
		return false
	}
	if d.size[rx] < d.size[ry] {
		rx, ry = ry, rx // hang the smaller tree under the larger
	}
	d.parent[ry] = rx
	d.size[rx] += d.size[ry]
	return true
}

// RedundantEdge returns the edge that closes a cycle in a tree of nodes
// 1..n with one extra edge, or nil if none does.
func RedundantEdge(edges [][2]int) []int {
	d := New(len(edges) + 1) // nodes are numbered from 1
	for _, e := range edges {
		if !d.Union(e[0], e[1]) {
			return []int{e[0], e[1]}
		}
	}
	return nil
}
~~~

- **Path halving** (`parent[x] = parent[parent[x]]`) is a one-pass form of path compression: every node on the path skips a level.
- `Union` returning `false` for "already connected" is what makes `RedundantEdge` one line.

<!-- file: unionfind/dsu_test.go -->
~~~go
package unionfind

import (
	"slices"
	"testing"
)

func TestDSU(t *testing.T) {
	d := New(5)
	if d.Find(3) == d.Find(4) {
		t.Fatal("3 and 4 start apart")
	}
	d.Union(3, 4)
	d.Union(0, 1)
	d.Union(1, 4)
	if d.Find(0) != d.Find(3) {
		t.Error("0 and 3 should be joined through 1 and 4")
	}
	if d.Find(2) == d.Find(0) {
		t.Error("2 was never joined")
	}
	if d.Union(0, 4) {
		t.Error("Union of an already joined pair should return false")
	}
}

func TestRedundantEdge(t *testing.T) {
	cases := []struct {
		edges [][2]int
		want  []int
	}{
		{[][2]int{{1, 2}, {1, 3}, {2, 3}}, []int{2, 3}},
		{[][2]int{{1, 2}, {2, 3}, {3, 4}, {1, 4}, {1, 5}}, []int{1, 4}},
		{[][2]int{{1, 2}, {2, 1}}, []int{2, 1}},
	}
	for _, c := range cases {
		if got := RedundantEdge(c.edges); !slices.Equal(got, c.want) {
			t.Errorf("RedundantEdge(%v) = %v, want %v", c.edges, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./unionfind/ && go test ./unionfind/ -->

<!-- file: unionfind/dsu.py -->
~~~python
class DSU:
    """Disjoint-set union over 0..n-1, with union by size and path halving."""

    def __init__(self, n: int) -> None:
        self.parent = list(range(n))
        self.size = [1] * n

    def find(self, x: int) -> int:
        while self.parent[x] != x:
            self.parent[x] = self.parent[self.parent[x]]
            x = self.parent[x]
        return x

    def union(self, x: int, y: int) -> bool:
        rx, ry = self.find(x), self.find(y)
        if rx == ry:
            return False
        if self.size[rx] < self.size[ry]:
            rx, ry = ry, rx
        self.parent[ry] = rx
        self.size[rx] += self.size[ry]
        return True


def redundant_edge(edges: list[tuple[int, int]]) -> tuple[int, int] | None:
    """The edge that closes a cycle in a tree of nodes 1..n plus one edge."""
    d = DSU(len(edges) + 1)
    for a, b in edges:
        if not d.union(a, b):
            return (a, b)
    return None
~~~

<!-- file: unionfind/test_dsu.py -->
~~~python
import pytest

from unionfind.dsu import DSU, redundant_edge


def test_dsu():
    d = DSU(5)
    assert d.find(3) != d.find(4)
    d.union(3, 4)
    d.union(0, 1)
    d.union(1, 4)
    assert d.find(0) == d.find(3)
    assert d.find(2) != d.find(0)
    assert not d.union(0, 4)


@pytest.mark.parametrize(
    ("edges", "want"),
    [
        ([(1, 2), (1, 3), (2, 3)], (2, 3)),
        ([(1, 2), (2, 3), (3, 4), (1, 4), (1, 5)], (1, 4)),
        ([(1, 2), (2, 1)], (2, 1)),
    ],
)
def test_redundant_edge(edges, want):
    assert redundant_edge(edges) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q unionfind -->

**Complexity:** O(*e*·α(*n*)) time, effectively O(*e*); O(*n*) space.

## Pitfalls

- **Comparing parents instead of roots.** `parent[a] == parent[b]` isn't "same group"; `Find(a) == Find(b)` is.
- **Union without roots.** `parent[a] = b` links *a* alone, not its group. Always link `Find(a)` to `Find(b)`.
- **Off-by-one labels.** Problems often number nodes from 1; size the arrays for it.
- **It can't split.** If groups need to break apart, union-find is the wrong tool; rebuild, or use a graph search.

## Practice

1. **[Number of Provinces](https://leetcode.com/problems/number-of-provinces/)** (medium). Count the groups in an adjacency matrix.
   <details><summary>Hint</summary>Start with <i>n</i> groups; every successful Union reduces the count by one.</details>
2. **[Accounts Merge](https://leetcode.com/problems/accounts-merge/)** (medium). Accounts sharing any email belong to the same person.
   <details><summary>Hint</summary>Union each account's emails with its first email; then group emails by root.</details>
3. **[Satisfiability of Equality Equations](https://leetcode.com/problems/satisfiability-of-equality-equations/)** (medium). `["a==b", "b!=a"]` → `false`.
   <details><summary>Hint</summary>Process every <code>==</code> first (unions), then check that no <code>!=</code> joins two letters in the same group.</details>

Next: [11. Shortest paths](../11-shortest-paths/README.md).
