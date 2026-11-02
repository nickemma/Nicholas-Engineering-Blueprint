# 09. Graphs: BFS, DFS and topological sort

<!-- continue: ../08-heaps/README.md -->

A graph is nodes and edges, with no promise of a root or of no cycles. Trees were the special case; now you need a **visited** set, because a walk can come back to where it started. Three tools cover most problems:

- **DFS** explores as deep as possible: reachability, connected components, cycle detection.
- **BFS** explores in rings of distance: the **shortest path** when every edge costs the same.
- **Topological sort** orders a directed graph so every edge points forwards. It exists exactly when the graph has no cycle.

**Recognise it when** there are things and relationships between them:

- a grid of cells with neighbours;
- dependencies ("A must come before B");
- networks, maps, social links;
- states and moves between them ("the fewest steps to turn this into that").

**Real systems:**
- **Go's build orders packages topologically**, and rejects an import cycle with an error. That's Course Schedule below, run on every `go build` since [Phase 0](../../lessons/00-request-service/README.md).
- **Kubernetes deletes in graph order.** In [Phase 5](../../lessons/05-constrained-operations/README.md), it removes a Deployment's ReplicaSets and Pods by following their owner references.
- **Raft's partition tests** in [Phase 4](../../lessons/04-replicated-state/TEACHING.md#step-6-partial-partitions-prevote-and-checkquorum) are about which nodes can still reach which: graph connectivity.

## Worked problem 1: Number of Islands

[LeetCode 200](https://leetcode.com/problems/number-of-islands/). A grid of `'1'` (land) and `'0'` (water). Count the islands: groups of land cells joined up, down, left or right.

~~~text
1 1 0 0 0
1 1 0 0 0       3 islands
0 0 1 0 0
0 0 0 1 1
~~~

**Think first.**
- Each cell is a node, with edges to its four neighbours.
- Scan the grid. Each time you find land you haven't visited, you've found a new island: count it, then flood it, visiting every land cell reachable from it, so none of them is counted again.
- The flood can be DFS or BFS. BFS with an explicit queue can't overflow the call stack on a huge island.

<!-- file: graphs/islands.go -->
~~~go
// Package graphs holds the graph problems.
package graphs

// NumIslands counts groups of '1' cells joined horizontally or vertically.
// It doesn't change grid. O(rows·cols) time and space.
func NumIslands(grid [][]byte) int {
	rows := len(grid)
	if rows == 0 {
		return 0
	}
	cols := len(grid[0])
	seen := make([][]bool, rows)
	for r := range seen {
		seen[r] = make([]bool, cols)
	}
	dirs := [4][2]int{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

	islands := 0
	for r := range rows {
		for c := range cols {
			if grid[r][c] != '1' || seen[r][c] {
				continue
			}
			islands++
			seen[r][c] = true
			queue := [][2]int{{r, c}}
			for len(queue) > 0 {
				cell := queue[0]
				queue = queue[1:]
				for _, d := range dirs {
					nr, nc := cell[0]+d[0], cell[1]+d[1]
					if nr < 0 || nr >= rows || nc < 0 || nc >= cols {
						continue // off the grid
					}
					if grid[nr][nc] == '1' && !seen[nr][nc] {
						seen[nr][nc] = true // mark when queued, not when visited
						queue = append(queue, [2]int{nr, nc})
					}
				}
			}
		}
	}
	return islands
}
~~~

- **Mark a cell as seen when you queue it**, not when you take it off the queue. Otherwise the same cell can be queued several times by different neighbours.
- `for r := range rows` (Go 1.22+) counts from 0 to `rows`−1.

<!-- file: graphs/islands_test.go -->
~~~go
package graphs

import (
	"strings"
	"testing"
)

// grid turns rows like "11000" into the [][]byte the function takes.
func grid(rows ...string) [][]byte {
	g := make([][]byte, len(rows))
	for i, r := range rows {
		g[i] = []byte(strings.ReplaceAll(r, " ", ""))
	}
	return g
}

func TestNumIslands(t *testing.T) {
	cases := []struct {
		name string
		grid [][]byte
		want int
	}{
		{"three", grid("11000", "11000", "00100", "00011"), 3},
		{"one big", grid("11110", "11010", "11000", "00000"), 1},
		{"diagonal isn't joined", grid("10", "01"), 2},
		{"all water", grid("000"), 0},
		{"empty", nil, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := NumIslands(c.grid); got != c.want {
				t.Errorf("NumIslands = %d, want %d", got, c.want)
			}
		})
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./graphs/ && go test ./graphs/ -->

<!-- file: graphs/islands.py -->
~~~python
from collections import deque


def num_islands(grid: list[str]) -> int:
    """Count groups of '1' cells joined horizontally or vertically."""
    rows, cols = len(grid), len(grid[0]) if grid else 0
    seen: set[tuple[int, int]] = set()
    islands = 0
    for r in range(rows):
        for c in range(cols):
            if grid[r][c] != "1" or (r, c) in seen:
                continue
            islands += 1
            seen.add((r, c))
            queue = deque([(r, c)])
            while queue:
                cr, cc = queue.popleft()
                for nr, nc in ((cr + 1, cc), (cr - 1, cc), (cr, cc + 1), (cr, cc - 1)):
                    if 0 <= nr < rows and 0 <= nc < cols:
                        if grid[nr][nc] == "1" and (nr, nc) not in seen:
                            seen.add((nr, nc))
                            queue.append((nr, nc))
    return islands
~~~

<!-- file: graphs/test_islands.py -->
~~~python
import pytest

from graphs.islands import num_islands


@pytest.mark.parametrize(
    ("grid", "want"),
    [
        (["11000", "11000", "00100", "00011"], 3),
        (["11110", "11010", "11000", "00000"], 1),
        (["10", "01"], 2),
        (["000"], 0),
        ([], 0),
    ],
)
def test_num_islands(grid, want):
    assert num_islands(grid) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q graphs -->

**Complexity:** O(*R*·*C*) time and space.

## Worked problem 2: Course Schedule

[LeetCode 207](https://leetcode.com/problems/course-schedule/). There are *n* courses, numbered 0 to *n*−1, and prerequisite pairs `[a, b]` meaning "take *b* before *a*". Can you finish them all?

| *n* | Prerequisites | Output |
|---|---|---|
| 2 | `[[1, 0]]` | `true` (take 0, then 1) |
| 2 | `[[1, 0], [0, 1]]` | `false` (each needs the other: a cycle) |

**Think first.** You can finish everything exactly when the "before" graph has no cycle. **Kahn's algorithm** finds out by doing the schedule:
1. count each course's unmet prerequisites (its **in-degree**);
2. start with every course that has none;
3. taking a course removes one unmet prerequisite from each course that depends on it; any course that reaches zero becomes takeable.

If every course gets taken, there's no cycle. Courses on a cycle never reach zero.

<!-- file: graphs/courses.go -->
~~~go
package graphs

// CanFinish reports whether n courses can all be taken, given pairs
// {a, b} meaning "take b before a". Kahn's algorithm: O(n + e) time and
// space for e pairs.
func CanFinish(n int, prereqs [][2]int) bool {
	unlocks := make([][]int, n) // b → the courses that need b
	waiting := make([]int, n)   // a → how many prerequisites a still lacks
	for _, p := range prereqs {
		a, b := p[0], p[1]
		unlocks[b] = append(unlocks[b], a)
		waiting[a]++
	}
	var ready []int
	for c := range n {
		if waiting[c] == 0 {
			ready = append(ready, c)
		}
	}
	taken := 0
	for len(ready) > 0 {
		c := ready[len(ready)-1]
		ready = ready[:len(ready)-1]
		taken++
		for _, next := range unlocks[c] {
			waiting[next]--
			if waiting[next] == 0 {
				ready = append(ready, next)
			}
		}
	}
	return taken == n
}
~~~

The order in which `ready` courses are taken doesn't matter for this question, so a stack (take the last) is as good as a queue.

<!-- file: graphs/courses_test.go -->
~~~go
package graphs

import "testing"

func TestCanFinish(t *testing.T) {
	cases := []struct {
		name    string
		n       int
		prereqs [][2]int
		want    bool
	}{
		{"a chain", 2, [][2]int{{1, 0}}, true},
		{"two need each other", 2, [][2]int{{1, 0}, {0, 1}}, false},
		{"no prerequisites", 3, nil, true},
		{"a diamond", 4, [][2]int{{1, 0}, {2, 0}, {3, 1}, {3, 2}}, true},
		{"a cycle beside free courses", 4, [][2]int{{2, 1}, {3, 2}, {1, 3}}, false},
		{"a course needs itself", 1, [][2]int{{0, 0}}, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := CanFinish(c.n, c.prereqs); got != c.want {
				t.Errorf("CanFinish(%d, %v) = %v, want %v", c.n, c.prereqs, got, c.want)
			}
		})
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./graphs/ && go test ./graphs/ -->

<!-- file: graphs/courses.py -->
~~~python
def can_finish(n: int, prereqs: list[tuple[int, int]]) -> bool:
    """Can all n courses be taken, given (a, b) = "take b before a"?"""
    unlocks: list[list[int]] = [[] for _ in range(n)]
    waiting = [0] * n
    for a, b in prereqs:
        unlocks[b].append(a)
        waiting[a] += 1
    ready = [c for c in range(n) if waiting[c] == 0]
    taken = 0
    while ready:
        c = ready.pop()
        taken += 1
        for nxt in unlocks[c]:
            waiting[nxt] -= 1
            if waiting[nxt] == 0:
                ready.append(nxt)
    return taken == n
~~~

`[[] for _ in range(n)]` makes *n* separate lists. `[[]] * n` would make *n* references to **one** list, a classic Python bug.

<!-- file: graphs/test_courses.py -->
~~~python
import pytest

from graphs.courses import can_finish


@pytest.mark.parametrize(
    ("n", "prereqs", "want"),
    [
        (2, [(1, 0)], True),
        (2, [(1, 0), (0, 1)], False),
        (3, [], True),
        (4, [(1, 0), (2, 0), (3, 1), (3, 2)], True),
        (4, [(2, 1), (3, 2), (1, 3)], False),
        (1, [(0, 0)], False),
    ],
)
def test_can_finish(n, prereqs, want):
    assert can_finish(n, prereqs) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q graphs -->

**Complexity:** O(*n* + *e*) time and space.

## Pitfalls

- **No visited set** means infinite loops on any cycle.
- **Marking visited too late** (when dequeued) queues cells many times.
- **Directed or undirected?** For an undirected edge, add it both ways.
- **BFS finds shortest paths only when every edge costs the same.** With weights, use Dijkstra (guide 11).
- **Recursion depth.** A DFS over a 1,000 × 1,000 grid can recurse a million deep.

## Practice

1. **[Clone Graph](https://leetcode.com/problems/clone-graph/)** (medium). Deep-copy a connected undirected graph.
   <details><summary>Hint</summary>A map from original node to its copy doubles as the visited set.</details>
2. **[Max Area of Island](https://leetcode.com/problems/max-area-of-island/)** (medium). The biggest island's size.
   <details><summary>Hint</summary>Worked problem 1, counting cells during each flood.</details>
3. **[Rotting Oranges](https://leetcode.com/problems/rotting-oranges/)** (medium). Rot spreads one step a minute; when is every orange rotten?
   <details><summary>Hint</summary>Multi-source BFS: start the queue with every rotten orange at once, and count levels.</details>
4. **[Pacific Atlantic Water Flow](https://leetcode.com/problems/pacific-atlantic-water-flow/)** (medium). Which cells can drain to both oceans?
   <details><summary>Hint</summary>Search backwards, uphill, from each ocean's edge; answer the cells both searches reach.</details>
5. **[Course Schedule II](https://leetcode.com/problems/course-schedule-ii/)** (medium). Return an order, not just whether one exists.
   <details><summary>Hint</summary>Worked problem 2, recording each course as it's taken.</details>
6. **[Word Ladder](https://leetcode.com/problems/word-ladder/)** (hard). The fewest one-letter changes from one word to another, through a dictionary.
   <details><summary>Hint</summary>BFS over words. Find neighbours by pattern: "hot" matches "*ot", "h*t" and "ho*"; group the dictionary by these patterns first.</details>

Next: [10. Union-find](../10-union-find/README.md).
