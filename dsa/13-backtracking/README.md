# 13. Backtracking

<!-- continue: ../12-intervals/README.md -->

Backtracking builds a solution one choice at a time. After each choice, it recurses to make the next; after returning, it **undoes** the choice and tries the next option. It explores a tree of partial solutions, and **pruning** (giving up on a branch as soon as it can't work) is what makes it fast enough.

Every backtracking function has the same three parts:

1. **Record** the current partial solution, if it's a complete one.
2. **For each choice** that's still allowed: make it, recurse, undo it.
3. **Prune:** skip choices that can't lead anywhere.

**Recognise it when** the problem asks for **all** combinations, subsets, permutations, arrangements or paths, or for one that satisfies constraints (Sudoku, N-Queens), and *n* is small (around 20 or less): the answers themselves are exponential in number.

**Real systems:**
- **TLC,** the TLA+ model checker from [Phase 4](../../lessons/04-replicated-state/TEACHING.md#step-9-a-tla-model-of-elections), explores every reachable state of a model, skipping states it has already seen. That's a systematic search with pruning.
- **Phase 4's simulation tests** search the space of message orderings by sampling it randomly.
- **Elsewhere:** constraint solvers, package managers resolving versions, and regex engines all backtrack.

## Worked problem 1: Subsets

[LeetCode 78](https://leetcode.com/problems/subsets/). Every subset of a list of distinct integers.

| Input | Output |
|---|---|
| `[1, 2, 3]` | `[[], [1], [1, 2], [1, 2, 3], [1, 3], [2], [2, 3], [3]]` |

**Think first.**
- Each subset is a path in a tree: at each level, choose which element to add next, considering only elements **after** the last one chosen. That rule is what stops `[2, 1]` appearing as well as `[1, 2]`.
- Every node of the tree, not just the leaves, is a subset.
- There are 2ⁿ subsets, so nothing can do better than O(*n*·2ⁿ), the size of the output.

<!-- file: backtracking/subsets.go -->
~~~go
// Package backtracking holds the backtracking problems.
package backtracking

// Subsets returns every subset of nums (distinct values), in the order a
// depth-first walk finds them. O(n·2ⁿ) time and space: the output's size.
func Subsets(nums []int) [][]int {
	var out [][]int
	var path []int
	var walk func(start int)
	walk = func(start int) {
		out = append(out, append([]int{}, path...)) // every node is a subset: save a copy
		for i := start; i < len(nums); i++ {
			path = append(path, nums[i]) // choose
			walk(i + 1)                  // explore
			path = path[:len(path)-1]    // undo
		}
	}
	walk(0)
	return out
}
~~~

**The copy is essential.** `path` is one slice reused throughout. Appending it directly would store a reference to that same memory, and every later choice would overwrite subsets already "saved". `append([]int{}, path...)` copies it into a new slice. `slices.Clone(path)` would copy too, but it returns `nil` for an empty `path`, and the empty subset should be an empty list. Python has the same trap, with `path[:]` as the fix.

<!-- file: backtracking/subsets_test.go -->
~~~go
package backtracking

import (
	"reflect"
	"testing"
)

func TestSubsets(t *testing.T) {
	cases := []struct {
		nums []int
		want [][]int
	}{
		{[]int{1, 2, 3}, [][]int{{}, {1}, {1, 2}, {1, 2, 3}, {1, 3}, {2}, {2, 3}, {3}}},
		{[]int{0}, [][]int{{}, {0}}},
		{nil, [][]int{{}}},
	}
	for _, c := range cases {
		if got := Subsets(c.nums); !reflect.DeepEqual(got, c.want) {
			t.Errorf("Subsets(%v) = %v, want %v", c.nums, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./backtracking/ && go test ./backtracking/ -->

<!-- file: backtracking/subsets.py -->
~~~python
def subsets(nums: list[int]) -> list[list[int]]:
    """Every subset of nums (distinct values), in depth-first order."""
    out: list[list[int]] = []
    path: list[int] = []

    def walk(start: int) -> None:
        out.append(path[:])  # a copy: path keeps changing
        for i in range(start, len(nums)):
            path.append(nums[i])
            walk(i + 1)
            path.pop()

    walk(0)
    return out
~~~

<!-- file: backtracking/test_subsets.py -->
~~~python
from backtracking.subsets import subsets


def test_subsets():
    assert subsets([1, 2, 3]) == [[], [1], [1, 2], [1, 2, 3], [1, 3], [2], [2, 3], [3]]
    assert subsets([0]) == [[], [0]]
    assert subsets([]) == [[]]
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q backtracking -->

**Complexity:** O(*n*·2ⁿ) time and space.

## Worked problem 2: Combination Sum

[LeetCode 39](https://leetcode.com/problems/combination-sum/). Distinct positive candidates and a target. Find every combination that sums to the target, where each candidate may be used **any number of times**.

| Candidates | Target | Output |
|---|---|---|
| `[2, 3, 6, 7]` | 7 | `[[2, 2, 3], [7]]` |
| `[2, 3, 5]` | 8 | `[[2, 2, 2, 2], [2, 3, 3], [3, 5]]` |
| `[2]` | 1 | `[]` |

**Think first.** The same tree as Subsets, with two changes:
- **Reuse:** after choosing candidate *i*, recurse from *i* again, not *i* + 1, so it can be chosen again.
- **Prune:** sort the candidates first. Once one is bigger than what's left, every later one is too, so stop the loop. Without this, the search explores sums far past the target.

<!-- file: backtracking/combination_sum.go -->
~~~go
package backtracking

import "slices"

// CombinationSum returns every combination of candidates (distinct,
// positive, each usable many times) that sums to target. Each combination is
// ascending, and they're listed in depth-first order.
func CombinationSum(candidates []int, target int) [][]int {
	c := slices.Clone(candidates)
	slices.Sort(c)
	var out [][]int
	var path []int
	var walk func(start, left int)
	walk = func(start, left int) {
		if left == 0 {
			out = append(out, slices.Clone(path))
			return
		}
		for i := start; i < len(c) && c[i] <= left; i++ { // sorted: stop at the first too big
			path = append(path, c[i])
			walk(i, left-c[i]) // i, not i+1: c[i] may be used again
			path = path[:len(path)-1]
		}
	}
	walk(0, target)
	return out
}
~~~

<!-- file: backtracking/combination_sum_test.go -->
~~~go
package backtracking

import (
	"reflect"
	"testing"
)

func TestCombinationSum(t *testing.T) {
	cases := []struct {
		candidates []int
		target     int
		want       [][]int
	}{
		{[]int{2, 3, 6, 7}, 7, [][]int{{2, 2, 3}, {7}}},
		{[]int{2, 3, 5}, 8, [][]int{{2, 2, 2, 2}, {2, 3, 3}, {3, 5}}},
		{[]int{2}, 1, nil},
		{[]int{7, 3, 2}, 7, [][]int{{2, 2, 3}, {7}}}, // unsorted input
	}
	for _, c := range cases {
		if got := CombinationSum(c.candidates, c.target); !reflect.DeepEqual(got, c.want) {
			t.Errorf("CombinationSum(%v, %d) = %v, want %v", c.candidates, c.target, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./backtracking/ && go test ./backtracking/ -->

<!-- file: backtracking/combination_sum.py -->
~~~python
def combination_sum(candidates: list[int], target: int) -> list[list[int]]:
    """Combinations of candidates (reusable) summing to target, depth-first."""
    c = sorted(candidates)
    out: list[list[int]] = []
    path: list[int] = []

    def walk(start: int, left: int) -> None:
        if left == 0:
            out.append(path[:])
            return
        for i in range(start, len(c)):
            if c[i] > left:
                break
            path.append(c[i])
            walk(i, left - c[i])
            path.pop()

    walk(0, target)
    return out
~~~

<!-- file: backtracking/test_combination_sum.py -->
~~~python
import pytest

from backtracking.combination_sum import combination_sum


@pytest.mark.parametrize(
    ("candidates", "target", "want"),
    [
        ([2, 3, 6, 7], 7, [[2, 2, 3], [7]]),
        ([2, 3, 5], 8, [[2, 2, 2, 2], [2, 3, 3], [3, 5]]),
        ([2], 1, []),
        ([7, 3, 2], 7, [[2, 2, 3], [7]]),
    ],
)
def test_combination_sum(candidates, target, want):
    assert combination_sum(candidates, target) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q backtracking -->

**Complexity:** exponential in the target divided by the smallest candidate; the pruning and the output size dominate. Say "exponential, bounded by the number of combinations" and explain why.

## Pitfalls

- **Saving a reference instead of a copy** (`path` instead of `slices.Clone(path)` or `path[:]`).
- **Forgetting to undo.** Every append before the recursion needs a matching removal after it.
- **Duplicates in the answer** come from choosing an earlier element after a later one. Only consider elements from `start` on; with duplicate inputs, sort and skip equal neighbours at the same level (practice 2).
- **No pruning.** Ask, at every choice: can this branch still succeed? If not, return.

## Practice

1. **[Permutations](https://leetcode.com/problems/permutations/)** (medium). Every ordering of distinct integers.
   <details><summary>Hint</summary>Any unused element can come next: keep a <code>used</code> array instead of a <code>start</code> index.</details>
2. **[Subsets II](https://leetcode.com/problems/subsets-ii/)** (medium). Subsets, with duplicate values allowed in the input but not in the output.
   <details><summary>Hint</summary>Sort. In the loop, skip <code>nums[i]</code> if it equals <code>nums[i-1]</code> and <code>i > start</code>: the same value was already tried at this level.</details>
3. **[Word Search](https://leetcode.com/problems/word-search/)** (medium). Can a word be traced through adjacent grid cells, using each cell once?
   <details><summary>Hint</summary>From each cell matching the first letter, DFS with backtracking: mark the cell used, recurse to neighbours for the next letter, unmark.</details>
4. **[N-Queens](https://leetcode.com/problems/n-queens/)** (hard). Place *n* queens so none attack each other.
   <details><summary>Hint</summary>One queen per row. Keep sets of used columns and diagonals (row − col and row + col identify them); a clash prunes the branch at once.</details>

Next: [14. Dynamic programming, 1D](../14-dp-1d/README.md).
