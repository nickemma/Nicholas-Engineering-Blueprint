# 08. Heaps and priority queues

<!-- continue: ../07-trees/README.md -->

A heap keeps the smallest (or largest) element at the top. Reading the top is O(1). Adding an element or removing the top is O(log *n*). That's all it does, and it's exactly what "top *k*", "next smallest" and "what happens next?" need. A heap is a binary tree stored in an array: element *i*'s children are at 2*i* + 1 and 2*i* + 2, so it needs no pointers.

**Recognise it when** the problem asks for:

- the *k* largest, smallest, closest or most frequent;
- the next item by priority, again and again, while new items arrive;
- merging *k* sorted sequences;
- a running median.

**Real systems:**
- Go's runtime keeps every timer in a heap, so the next to fire is always on top. That includes each `context.WithTimeout` deadline from [Phase 1](../../lessons/01-reliable-service/TEACHING.md#step-6-deadlines-and-cancellation).
- [Phase 7's short-job lanes](../../lessons/07-utility-evaluation/TEACHING.md#step-9-using-the-predictions) order work by predicted size: a priority queue.
- Schedulers, Dijkstra's algorithm (guide 11) and the merge step of LSM compaction are all heaps.

## Worked problem 1: Kth Largest Element in an Array

[LeetCode 215](https://leetcode.com/problems/kth-largest-element-in-an-array/). The *k*-th largest value (not the *k*-th distinct).

| Input | *k* | Output |
|---|---|---|
| `[3, 2, 1, 5, 6, 4]` | 2 | 5 |
| `[3, 2, 3, 1, 2, 4, 5, 5, 6]` | 4 | 4 |

**Think first.**
- Sorting is O(*n* log *n*).
- Better: keep a **min-heap of the *k* largest seen so far**. Its top is the smallest of them, which is the *k*-th largest overall.
- Each new number either beats the top (replace it) or doesn't (ignore it). That's O(*n* log *k*), which is much better when *k* is small, and it works on a stream you can't hold in memory.

Go's `container/heap` works on any type that implements five methods: `Len`, `Less`, `Swap` (from `sort.Interface`) plus `Push` and `Pop`. You write the storage; the package does the sifting.

<!-- file: heaps/kth_largest.go -->
~~~go
// Package heaps holds the heap and priority-queue problems.
package heaps

import "container/heap"

// minHeap is a min-heap of ints for container/heap.
type minHeap []int

func (h minHeap) Len() int           { return len(h) }
func (h minHeap) Less(i, j int) bool { return h[i] < h[j] }
func (h minHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *minHeap) Push(x any)        { *h = append(*h, x.(int)) }
func (h *minHeap) Pop() any {
	old := *h
	x := old[len(old)-1]
	*h = old[:len(old)-1]
	return x
}

// KthLargest returns the k-th largest value in nums, 1 <= k <= len(nums).
// O(n log k) time, O(k) space.
func KthLargest(nums []int, k int) int {
	h := make(minHeap, 0, k)
	for _, n := range nums {
		if h.Len() < k {
			heap.Push(&h, n)
		} else if n > h[0] {
			h[0] = n        // replace the smallest of the k largest...
			heap.Fix(&h, 0) // ...and restore the heap order
		}
	}
	return h[0]
}
~~~

- `Push` and `Pop` take pointer receivers because they change the slice's length.
- Call `heap.Push(&h, x)`, **not** `h.Push(x)`: the package function appends and then sifts the new element into place. The method alone only appends.
- `heap.Fix` restores order after you change one element in place, which is cheaper than a pop and a push.

<!-- file: heaps/kth_largest_test.go -->
~~~go
package heaps

import "testing"

func TestKthLargest(t *testing.T) {
	cases := []struct {
		nums    []int
		k, want int
	}{
		{[]int{3, 2, 1, 5, 6, 4}, 2, 5},
		{[]int{3, 2, 3, 1, 2, 4, 5, 5, 6}, 4, 4},
		{[]int{1}, 1, 1},
		{[]int{2, 1}, 2, 1},
		{[]int{-1, -1}, 1, -1},
	}
	for _, c := range cases {
		if got := KthLargest(c.nums, c.k); got != c.want {
			t.Errorf("KthLargest(%v, %d) = %d, want %d", c.nums, c.k, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./heaps/ && go test ./heaps/ -->

Python's `heapq` works on a plain list and is a **min**-heap:

<!-- file: heaps/kth_largest.py -->
~~~python
import heapq


def kth_largest(nums: list[int], k: int) -> int:
    """The k-th largest value; O(n log k) with a min-heap of size k."""
    h: list[int] = []
    for n in nums:
        if len(h) < k:
            heapq.heappush(h, n)
        elif n > h[0]:
            heapq.heapreplace(h, n)  # pop the smallest and push n, in one step
    return h[0]
~~~

<!-- file: heaps/test_kth_largest.py -->
~~~python
import pytest

from heaps.kth_largest import kth_largest


@pytest.mark.parametrize(
    ("nums", "k", "want"),
    [
        ([3, 2, 1, 5, 6, 4], 2, 5),
        ([3, 2, 3, 1, 2, 4, 5, 5, 6], 4, 4),
        ([1], 1, 1),
        ([2, 1], 2, 1),
        ([-1, -1], 1, -1),
    ],
)
def test_kth_largest(nums, k, want):
    assert kth_largest(nums, k) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q heaps -->

**Complexity:** O(*n* log *k*) time, O(*k*) space. (Quickselect averages O(*n*), but its worst case is O(*n*²); say both in an interview.)

## Worked problem 2: K Closest Points to Origin

[LeetCode 973](https://leetcode.com/problems/k-closest-points-to-origin/). The *k* points nearest to (0, 0).

| Points | *k* | Output |
|---|---|---|
| `[[1, 3], [-2, 2]]` | 1 | `[[-2, 2]]` |
| `[[3, 3], [5, -1], [-2, 4]]` | 2 | `[[3, 3], [-2, 4]]` |

**Think first.**
- This is the mirror of problem 1: keep the *k* **closest**, so the top must be the **farthest** of them, ready to be replaced. That's a **max**-heap of size *k*.
- Compare squared distances, x² + y². Square roots aren't needed to compare, and they bring floating-point error.
- The problem allows any order. The function sorts its answer anyway, so tests (and callers) get the same result every time.

<!-- file: heaps/closest.go -->
~~~go
package heaps

import (
	"cmp"
	"container/heap"
	"slices"
)

// farthestFirst is a max-heap of points by squared distance from the origin.
type farthestFirst [][2]int

func dist2(p [2]int) int { return p[0]*p[0] + p[1]*p[1] }

func (h farthestFirst) Len() int           { return len(h) }
func (h farthestFirst) Less(i, j int) bool { return dist2(h[i]) > dist2(h[j]) }
func (h farthestFirst) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *farthestFirst) Push(x any)        { *h = append(*h, x.([2]int)) }
func (h *farthestFirst) Pop() any {
	old := *h
	x := old[len(old)-1]
	*h = old[:len(old)-1]
	return x
}

// KClosest returns the k points nearest the origin, nearest first (ties by
// x, then y). O(n log k) time, O(k) space.
func KClosest(points [][2]int, k int) [][2]int {
	h := make(farthestFirst, 0, k)
	for _, p := range points {
		if h.Len() < k {
			heap.Push(&h, p)
		} else if dist2(p) < dist2(h[0]) {
			h[0] = p
			heap.Fix(&h, 0)
		}
	}
	out := [][2]int(h)
	slices.SortFunc(out, func(a, b [2]int) int {
		return cmp.Or(cmp.Compare(dist2(a), dist2(b)), cmp.Compare(a[0], b[0]), cmp.Compare(a[1], b[1]))
	})
	return out
}
~~~

`cmp.Or` returns its first non-zero argument: compare by distance, and only on a tie by x, then by y.

<!-- file: heaps/closest_test.go -->
~~~go
package heaps

import (
	"reflect"
	"testing"
)

func TestKClosest(t *testing.T) {
	cases := []struct {
		points [][2]int
		k      int
		want   [][2]int
	}{
		{[][2]int{{1, 3}, {-2, 2}}, 1, [][2]int{{-2, 2}}},
		{[][2]int{{3, 3}, {5, -1}, {-2, 4}}, 2, [][2]int{{3, 3}, {-2, 4}}},
		{[][2]int{{0, 1}, {1, 0}, {2, 2}}, 2, [][2]int{{0, 1}, {1, 0}}},
		{[][2]int{{5, 5}}, 1, [][2]int{{5, 5}}},
	}
	for _, c := range cases {
		if got := KClosest(c.points, c.k); !reflect.DeepEqual(got, c.want) {
			t.Errorf("KClosest(%v, %d) = %v, want %v", c.points, c.k, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./heaps/ && go test ./heaps/ -->

Python has no max-heap, so push **negated** distances: the largest distance becomes the smallest key.

<!-- file: heaps/closest.py -->
~~~python
import heapq


def k_closest(points: list[tuple[int, int]], k: int) -> list[tuple[int, int]]:
    """The k points nearest the origin, nearest first (ties by x, then y)."""
    h: list[tuple[int, int, int]] = []  # (-distance², x, y): a max-heap by distance
    for x, y in points:
        d = x * x + y * y
        if len(h) < k:
            heapq.heappush(h, (-d, x, y))
        elif d < -h[0][0]:
            heapq.heapreplace(h, (-d, x, y))
    return [(x, y) for _, x, y in sorted(h, key=lambda e: (-e[0], e[1], e[2]))]
~~~

<!-- file: heaps/test_closest.py -->
~~~python
import pytest

from heaps.closest import k_closest


@pytest.mark.parametrize(
    ("points", "k", "want"),
    [
        ([(1, 3), (-2, 2)], 1, [(-2, 2)]),
        ([(3, 3), (5, -1), (-2, 4)], 2, [(3, 3), (-2, 4)]),
        ([(0, 1), (1, 0), (2, 2)], 2, [(0, 1), (1, 0)]),
        ([(5, 5)], 1, [(5, 5)]),
    ],
)
def test_k_closest(points, k, want):
    assert k_closest(points, k) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q heaps -->

**Complexity:** O(*n* log *k*) time, O(*k*) space.

## Pitfalls

- **Min or max?** To keep the *k* largest, use a **min**-heap (so you can throw out the smallest of them), and the other way round.
- **`h.Push` versus `heap.Push`** in Go: only the package function keeps the heap ordered.
- **A heap isn't sorted.** Only the top is guaranteed; iterating the array doesn't give sorted order.
- **Ties in Python tuples.** `heapq` compares whole tuples; if the second element isn't comparable (a dict, a custom object), add a counter as a tie-breaker.

## Practice

1. **[Last Stone Weight](https://leetcode.com/problems/last-stone-weight/)** (easy). Smash the two heaviest stones repeatedly; what's left?
   <details><summary>Hint</summary>A max-heap: pop two, push the difference if it's non-zero.</details>
2. **[Kth Largest Element in a Stream](https://leetcode.com/problems/kth-largest-element-in-a-stream/)** (easy). Worked problem 1, as a class that receives numbers one at a time.
   <details><summary>Hint</summary>Keep the size-<i>k</i> min-heap between calls.</details>
3. **[Task Scheduler](https://leetcode.com/problems/task-scheduler/)** (medium). Tasks with a cooldown *n* between equal tasks; the fewest time slots.
   <details><summary>Hint</summary>Always run the most frequent remaining task (a max-heap by count); park tasks in a cooldown queue until they're allowed again.</details>
4. **[Merge k Sorted Lists](https://leetcode.com/problems/merge-k-sorted-lists/)** (hard).
   <details><summary>Hint</summary>A min-heap holding the head of each list; pop the smallest, push its successor. O(<i>N</i> log <i>k</i>).</details>
5. **[Find Median from Data Stream](https://leetcode.com/problems/find-median-from-data-stream/)** (hard). Add numbers; return the median at any time.
   <details><summary>Hint</summary>Two heaps: a max-heap of the smaller half and a min-heap of the larger half, kept within one element of each other in size.</details>

Next: [09. Graphs](../09-graphs/README.md).
