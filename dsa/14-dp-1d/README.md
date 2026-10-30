# 14. Dynamic programming, 1D

<!-- continue: ../13-backtracking/README.md -->

Dynamic programming (DP) is recursion that **remembers**. When the best answer for a problem is built from the best answers of smaller versions of it, and those smaller versions repeat, compute each one once and reuse it. The exponential recursion of guide 00's practice question 3 becomes linear.

Every DP solution is the same four decisions. Write them down before any code:

1. **State:** what does `dp[i]` mean, in one sentence?
2. **Recurrence:** how is `dp[i]` built from smaller states?
3. **Base cases:** the smallest states, answered directly.
4. **Order:** compute states so every one you need is ready. Often that's left to right, and then you only need the last one or two.

**Recognise it when** the problem asks for a **count** of ways, a **minimum** or **maximum**, or whether something is **possible**, and each choice affects what's possible later. If greedy (guide 17) has a counterexample, it's usually DP.

**Real systems:** [PostgreSQL's planner](../../lessons/03-durable-auditable-data/TEACHING.md#step-8-background-jobs), whose plans you read with `EXPLAIN` in Phase 3, chooses the order of a query's joins by dynamic programming: the best plan for joining a set of tables is built from the best plans for its subsets. (Above a dozen or so tables it switches to a genetic search, because the table of subsets grows too fast.) Speech recognition, sequence alignment and `diff` (guide 15) are DP too.

## Worked problem 1: Climbing Stairs

[LeetCode 70](https://leetcode.com/problems/climbing-stairs/). You climb *n* stairs, one or two at a time. In how many distinct ways can you reach the top?

| *n* | Output | The ways |
|---|---|---|
| 2 | 2 | 1+1, 2 |
| 3 | 3 | 1+1+1, 1+2, 2+1 |
| 5 | 8 | |

**Think first.** The four decisions:

1. **State:** `ways[i]` = the number of ways to reach step *i*.
2. **Recurrence:** the last move onto step *i* came from *i* − 1 or from *i* − 2, so `ways[i] = ways[i-1] + ways[i-2]`.
3. **Base cases:** `ways[0] = 1` (one way to be at the bottom: do nothing), `ways[1] = 1`.
4. **Order:** left to right, and only the last two values are needed. So two variables replace the whole table.

Written as plain recursion, `ways(n) = ways(n-1) + ways(n-2)` recomputes the same values exponentially often: `ways(45)` makes over a billion calls. Remembering each value makes it 45 additions.

<!-- file: dp1d/stairs.go -->
~~~go
// Package dp1d holds the one-dimensional dynamic-programming problems.
package dp1d

// ClimbStairs returns the number of ways to climb n stairs taking one or
// two at a time. O(n) time, O(1) space.
func ClimbStairs(n int) int {
	prev, cur := 1, 1 // ways[i-1], ways[i], starting at i = 1
	for range n - 1 {
		prev, cur = cur, prev+cur
	}
	return cur
}
~~~

<!-- file: dp1d/stairs_test.go -->
~~~go
package dp1d

import "testing"

func TestClimbStairs(t *testing.T) {
	for n, want := range map[int]int{1: 1, 2: 2, 3: 3, 5: 8, 45: 1836311903} {
		if got := ClimbStairs(n); got != want {
			t.Errorf("ClimbStairs(%d) = %d, want %d", n, got, want)
		}
	}
}
~~~

*n* = 45 is there on purpose: the plain recursive version takes seconds on it, and this one takes nanoseconds.

<!-- run: test -z "$(gofmt -l .)" && go vet ./dp1d/ && go test ./dp1d/ -->

<!-- file: dp1d/stairs.py -->
~~~python
def climb_stairs(n: int) -> int:
    """Ways to climb n stairs, one or two at a time."""
    prev, cur = 1, 1
    for _ in range(n - 1):
        prev, cur = cur, prev + cur
    return cur
~~~

<!-- file: dp1d/test_stairs.py -->
~~~python
import pytest

from dp1d.stairs import climb_stairs


@pytest.mark.parametrize(("n", "want"), [(1, 1), (2, 2), (3, 3), (5, 8), (45, 1836311903)])
def test_climb_stairs(n, want):
    assert climb_stairs(n) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q dp1d -->

**Complexity:** O(*n*) time, O(1) space.

## Worked problem 2: House Robber

[LeetCode 198](https://leetcode.com/problems/house-robber/). Houses in a row hold money. You can't take from two neighbouring houses. What's the most you can take?

| Input | Output | Take |
|---|---|---|
| `[1, 2, 3, 1]` | 4 | houses 0 and 2 |
| `[2, 7, 9, 3, 1]` | 12 | houses 0, 2 and 4 |
| `[2, 1, 1, 2]` | 4 | houses 0 and 3 |

**Think first.**
- **Greedy fails.** "Take every other house, starting with the bigger option" gets `[2, 1, 1, 2]` wrong: neither the even houses (3) nor the odd ones (3) give 4. The best choice at one house depends on later ones.
- **The four decisions:**
  1. **State:** `best[i]` = the most from houses 0..*i*.
  2. **Recurrence:** at house *i*, either skip it (`best[i-1]`) or take it (`nums[i] + best[i-2]`): `best[i] = max(best[i-1], nums[i] + best[i-2])`.
  3. **Base cases:** before any house, 0.
  4. **Order:** left to right; keep the last two values.

<!-- file: dp1d/robber.go -->
~~~go
package dp1d

// Rob returns the most money from houses in a row without taking two
// neighbours. O(n) time, O(1) space.
func Rob(nums []int) int {
	twoBack, oneBack := 0, 0 // best up to house i-2, and up to house i-1
	for _, n := range nums {
		twoBack, oneBack = oneBack, max(oneBack, twoBack+n)
	}
	return oneBack
}
~~~

<!-- file: dp1d/robber_test.go -->
~~~go
package dp1d

import "testing"

func TestRob(t *testing.T) {
	cases := []struct {
		nums []int
		want int
	}{
		{[]int{1, 2, 3, 1}, 4},
		{[]int{2, 7, 9, 3, 1}, 12},
		{[]int{2, 1, 1, 2}, 4}, // neither every-other pattern is best
		{[]int{5}, 5},
		{nil, 0},
	}
	for _, c := range cases {
		if got := Rob(c.nums); got != c.want {
			t.Errorf("Rob(%v) = %d, want %d", c.nums, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./dp1d/ && go test ./dp1d/ -->

<!-- file: dp1d/robber.py -->
~~~python
def rob(nums: list[int]) -> int:
    """Most money from houses in a row, never taking two neighbours."""
    two_back = one_back = 0
    for n in nums:
        two_back, one_back = one_back, max(one_back, two_back + n)
    return one_back
~~~

<!-- file: dp1d/test_robber.py -->
~~~python
import pytest

from dp1d.robber import rob


@pytest.mark.parametrize(
    ("nums", "want"),
    [([1, 2, 3, 1], 4), ([2, 7, 9, 3, 1], 12), ([2, 1, 1, 2], 4), ([5], 5), ([], 0)],
)
def test_rob(nums, want):
    assert rob(nums) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q dp1d -->

**Complexity:** O(*n*) time, O(1) space.

## Pitfalls

- **Coding before stating the state.** If you can't say what `dp[i]` means in one sentence, the recurrence will be wrong.
- **Base cases off by one.** Test *n* = 0 and *n* = 1 explicitly.
- **Simultaneous assignment.** `twoBack, oneBack = oneBack, ...` uses the **old** values on the right; two separate assignments wouldn't.
- **Top-down is fine too.** Recursion with a memo (a map, or Python's `functools.cache`) is often easier to write first; convert to a loop if the recursion gets too deep.

## Practice

1. **[Min Cost Climbing Stairs](https://leetcode.com/problems/min-cost-climbing-stairs/)** (easy). Each step has a cost; the cheapest way to the top.
   <details><summary>Hint</summary><code>cost_to_reach[i] = min(cost_to_reach[i-1] + cost[i-1], cost_to_reach[i-2] + cost[i-2])</code>.</details>
2. **[Coin Change](https://leetcode.com/problems/coin-change/)** (medium). The fewest coins making an amount. `[1, 2, 5], 11` → `3`.
   <details><summary>Hint</summary><code>fewest[a] = 1 + min(fewest[a − coin])</code> over coins ≤ a. Greedy (largest coin first) fails for coins like [1, 3, 4] and amount 6.</details>
3. **[Longest Increasing Subsequence](https://leetcode.com/problems/longest-increasing-subsequence/)** (medium). `[10, 9, 2, 5, 3, 7, 101, 18]` → `4`.
   <details><summary>Hint</summary>O(<i>n</i>²): <code>lis[i]</code> = longest ending at <i>i</i>. O(<i>n</i> log <i>n</i>): keep the smallest tail for each length and binary-search (guide 05) where each number goes.</details>
4. **[Word Break](https://leetcode.com/problems/word-break/)** (medium). Can a string be split into dictionary words?
   <details><summary>Hint</summary><code>ok[i]</code> = the first <i>i</i> characters can be split. <code>ok[i]</code> is true if some <code>ok[j]</code> is true and <code>s[j:i]</code> is a word.</details>
5. **[Decode Ways](https://leetcode.com/problems/decode-ways/)** (medium). Digits where 1–26 map to letters; how many decodings? `"226"` → `3`.
   <details><summary>Hint</summary>Climbing Stairs with conditions: a step of one digit if it isn't 0, a step of two if they form 10–26. Watch out for "06".</details>

Next: [15. Dynamic programming, 2D](../15-dp-2d/README.md).
