# 17. Greedy

<!-- continue: ../16-tries/README.md -->

A greedy algorithm makes the choice that looks best **right now** and never reconsiders it. When that's provably safe, greedy is the simplest and fastest solution there is. When it isn't, greedy is confidently wrong. So the skill isn't writing greedy code (it's usually short); it's **knowing when the local choice is safe**, and being able to say why.

Two ways to convince yourself (and an interviewer):

- **Exchange argument:** take any optimal solution that differs from the greedy one at the first choice, and show you can swap in the greedy choice without making it worse.
- **Look for a counterexample first.** Try small inputs where the "obvious" choice fails. If you find one, it's dynamic programming (guide 14), not greedy. House Robber's `[2, 1, 1, 2]` was one.

**Recognise it when:**

- the problem asks for a maximum or minimum, and one choice at a time seems to build it;
- intervals sorted by end (guide 12's practice);
- "can you reach...", running best values, scheduling.

**Real systems:** the Kubernetes scheduler, which places every Pod in [Phase 5](../../lessons/05-constrained-operations/TEACHING.md#step-5-all-of-runway-on-kubernetes), is greedy. It filters the nodes that fit, scores them, and binds the Pod to the best one. It never moves Pods it has already placed, which is why a cluster can end up fragmented and why tools such as the descheduler exist. Capstone [brief 5](../../capstones/05-gpu-scheduler.md) is about exactly this limit, for GPUs. Huffman coding (compression) and Dijkstra (guide 11) are greedy too.

## Worked problem 1: Jump Game

[LeetCode 55](https://leetcode.com/problems/jump-game/). Each element is the maximum jump length from that position. Starting at the first position, can you reach the last?

| Input | Output |
|---|---|
| `[2, 3, 1, 1, 4]` | `true` |
| `[3, 2, 1, 0, 4]` | `false` (everything lands on the 0) |

**Think first.**
- You don't need to know **which** jumps to make, only how far you could possibly get.
- Walk left to right, keeping `farthest`, the furthest position reachable so far.
- If you ever stand on a position beyond `farthest`, you couldn't have got there: answer false.
- **Why greedy is safe:** if position *i* is reachable, every position before it is too (you could jump shorter), so the reachable positions are always a prefix, described by one number.

<!-- file: greedy/jump.go -->
~~~go
// Package greedy holds the greedy problems.
package greedy

// CanJump reports whether the last position can be reached, where nums[i]
// is the longest jump from i. O(n) time, O(1) space.
func CanJump(nums []int) bool {
	farthest := 0
	for i, n := range nums {
		if i > farthest {
			return false // no jump reaches i
		}
		farthest = max(farthest, i+n)
	}
	return true
}
~~~

<!-- file: greedy/jump_test.go -->
~~~go
package greedy

import "testing"

func TestCanJump(t *testing.T) {
	cases := []struct {
		nums []int
		want bool
	}{
		{[]int{2, 3, 1, 1, 4}, true},
		{[]int{3, 2, 1, 0, 4}, false},
		{[]int{0}, true}, // already at the end
		{[]int{0, 1}, false},
		{[]int{2, 0, 0}, true},
	}
	for _, c := range cases {
		if got := CanJump(c.nums); got != c.want {
			t.Errorf("CanJump(%v) = %v, want %v", c.nums, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./greedy/ && go test ./greedy/ -->

<!-- file: greedy/jump.py -->
~~~python
def can_jump(nums: list[int]) -> bool:
    """Can the last position be reached, where nums[i] is the longest jump?"""
    farthest = 0
    for i, n in enumerate(nums):
        if i > farthest:
            return False
        farthest = max(farthest, i + n)
    return True
~~~

<!-- file: greedy/test_jump.py -->
~~~python
import pytest

from greedy.jump import can_jump


@pytest.mark.parametrize(
    ("nums", "want"),
    [
        ([2, 3, 1, 1, 4], True),
        ([3, 2, 1, 0, 4], False),
        ([0], True),
        ([0, 1], False),
        ([2, 0, 0], True),
    ],
)
def test_can_jump(nums, want):
    assert can_jump(nums) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q greedy -->

**Complexity:** O(*n*) time, O(1) space.

## Worked problem 2: Maximum Subarray

[LeetCode 53](https://leetcode.com/problems/maximum-subarray/). The largest sum of any non-empty contiguous subarray.

| Input | Output | Subarray |
|---|---|---|
| `[-2, 1, -3, 4, -1, 2, 1, -5, 4]` | 6 | `[4, -1, 2, 1]` |
| `[5, 4, -1, 7, 8]` | 23 | the whole array |
| `[-3, -1, -2]` | −1 | `[-1]` (it must be non-empty) |

**Think first.** This is **Kadane's algorithm**.
- Walk left to right, keeping the best sum of a subarray that **ends here**.
- At each number, the choice is to extend the previous run or start fresh. If the run so far is negative, it can only drag the new number down, so drop it: `here = max(n, here + n)`.
- The answer is the best `here` seen.
- It's really DP with one value of state, and it's often filed under greedy because of that one-line choice.

<!-- file: greedy/subarray.go -->
~~~go
package greedy

// MaxSubarray returns the largest sum of a non-empty contiguous subarray of
// nums, which must be non-empty. Kadane's algorithm: O(n) time, O(1) space.
func MaxSubarray(nums []int) int {
	best, here := nums[0], nums[0]
	for _, n := range nums[1:] {
		here = max(n, here+n) // extend the run, or start again at n
		best = max(best, here)
	}
	return best
}
~~~

Starting from `nums[0]` instead of 0 is what handles an all-negative array: with 0, `[-3, -1, -2]` would wrongly answer 0, the sum of an empty subarray.

<!-- file: greedy/subarray_test.go -->
~~~go
package greedy

import "testing"

func TestMaxSubarray(t *testing.T) {
	cases := []struct {
		nums []int
		want int
	}{
		{[]int{-2, 1, -3, 4, -1, 2, 1, -5, 4}, 6},
		{[]int{5, 4, -1, 7, 8}, 23},
		{[]int{-3, -1, -2}, -1}, // all negative: the empty subarray isn't allowed
		{[]int{1}, 1},
	}
	for _, c := range cases {
		if got := MaxSubarray(c.nums); got != c.want {
			t.Errorf("MaxSubarray(%v) = %d, want %d", c.nums, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./greedy/ && go test ./greedy/ -->

<!-- file: greedy/subarray.py -->
~~~python
def max_subarray(nums: list[int]) -> int:
    """Largest sum of a non-empty contiguous subarray (Kadane)."""
    best = here = nums[0]
    for n in nums[1:]:
        here = max(n, here + n)
        best = max(best, here)
    return best
~~~

<!-- file: greedy/test_subarray.py -->
~~~python
import pytest

from greedy.subarray import max_subarray


@pytest.mark.parametrize(
    ("nums", "want"),
    [([-2, 1, -3, 4, -1, 2, 1, -5, 4], 6), ([5, 4, -1, 7, 8], 23), ([-3, -1, -2], -1), ([1], 1)],
)
def test_max_subarray(nums, want):
    assert max_subarray(nums) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q greedy -->

**Complexity:** O(*n*) time, O(1) space.

## Pitfalls

- **Greedy without a reason.** Before coding, say why the local choice can't hurt. If you can't, look for a counterexample.
- **Sorting by the wrong key.** Interval scheduling sorts by end, not start; the wrong key gives a plausible but wrong answer.
- **Empty versus non-empty.** Kadane initialised with 0 silently allows the empty subarray.
- **Coins.** "Largest coin first" works for euro and dollar coins, but not for coins like [1, 3, 4] (making 6). That's guide 14's practice 2.

## Practice

1. **[Jump Game II](https://leetcode.com/problems/jump-game-ii/)** (medium). The fewest jumps to the end.
   <details><summary>Hint</summary>BFS by levels, without a queue: the positions reachable with <i>j</i> jumps form a range; the next range ends at the farthest jump from inside it.</details>
2. **[Gas Station](https://leetcode.com/problems/gas-station/)** (medium). Which station can you start from to drive round a circle?
   <details><summary>Hint</summary>If total gas < total cost, none. Otherwise, whenever the tank goes negative, no station from the current start to here works: start again after here.</details>
3. **[Partition Labels](https://leetcode.com/problems/partition-labels/)** (medium). Split a string into as many parts as possible so each letter appears in only one part.
   <details><summary>Hint</summary>Record each letter's last position. Extend the current part to the furthest last position of the letters in it; cut when you reach it.</details>

Next: [18. Bit manipulation](../18-bit-manipulation/README.md).
