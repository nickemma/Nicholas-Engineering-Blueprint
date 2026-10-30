# 15. Dynamic programming, 2D

<!-- continue: ../14-dp-1d/README.md -->

When a state needs **two** numbers to describe it, the table has two dimensions. Two shapes cover most problems:

- a **grid**, where `dp[r][c]` is the answer for reaching cell (*r*, *c*);
- **two sequences**, where `dp[i][j]` is the answer for the first *i* items of one and the first *j* of the other.

The four decisions from guide 14 still apply (state, recurrence, base cases, order). The order is usually row by row. Often only the previous row is needed, which brings the space down from O(*m*·*n*) to O(*n*).

**Recognise it when** the problem compares or aligns two strings or sequences (common parts, edits, interleavings), or counts or optimises paths through a grid that only move right and down.

**Real systems:**
- **`diff`.** `diff` and `git diff` find the longest common subsequence of two files' lines. Everything not in it is an insertion or a deletion. They use Myers' algorithm, a faster route to the same answer as worked problem 2's table.
- **Sequence alignment** in bioinformatics, and **spelling correction** (edit distance, practice 1).

## Worked problem 1: Unique Paths

[LeetCode 62](https://leetcode.com/problems/unique-paths/). A robot starts in the top-left of an *m* × *n* grid and moves only right or down. How many paths reach the bottom-right?

| *m* × *n* | Output |
|---|---|
| 3 × 7 | 28 |
| 3 × 2 | 3 |
| 1 × 1 | 1 |

**Think first.**
1. **State:** `paths[r][c]` = paths to cell (*r*, *c*).
2. **Recurrence:** you arrive from above or from the left: `paths[r][c] = paths[r-1][c] + paths[r][c-1]`.
3. **Base cases:** the whole first row and first column are 1 (only one way along an edge).
4. **Order:** row by row. Each row needs only the row above, so keep **one row** and update it in place. Before the update, `row[c]` still holds the value from above; `row[c-1]` already holds this row's value from the left.

<!-- file: dp2d/paths.go -->
~~~go
// Package dp2d holds the two-dimensional dynamic-programming problems.
package dp2d

// UniquePaths returns the number of right/down paths across an m×n grid.
// O(m·n) time, O(n) space: one row, updated in place.
func UniquePaths(m, n int) int {
	row := make([]int, n)
	for c := range row {
		row[c] = 1 // the first row
	}
	for range m - 1 {
		for c := 1; c < n; c++ {
			row[c] += row[c-1] // from above (old row[c]) + from the left
		}
	}
	return row[n-1]
}
~~~

<!-- file: dp2d/paths_test.go -->
~~~go
package dp2d

import "testing"

func TestUniquePaths(t *testing.T) {
	cases := []struct{ m, n, want int }{
		{3, 7, 28},
		{3, 2, 3},
		{1, 1, 1},
		{1, 5, 1},
		{10, 10, 48620},
	}
	for _, c := range cases {
		if got := UniquePaths(c.m, c.n); got != c.want {
			t.Errorf("UniquePaths(%d, %d) = %d, want %d", c.m, c.n, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./dp2d/ && go test ./dp2d/ -->

<!-- file: dp2d/paths.py -->
~~~python
def unique_paths(m: int, n: int) -> int:
    """Right/down paths across an m x n grid, with one row of memory."""
    row = [1] * n
    for _ in range(m - 1):
        for c in range(1, n):
            row[c] += row[c - 1]
    return row[-1]
~~~

<!-- file: dp2d/test_paths.py -->
~~~python
import pytest

from dp2d.paths import unique_paths


@pytest.mark.parametrize(
    ("m", "n", "want"), [(3, 7, 28), (3, 2, 3), (1, 1, 1), (1, 5, 1), (10, 10, 48620)]
)
def test_unique_paths(m, n, want):
    assert unique_paths(m, n) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q dp2d -->

**Complexity:** O(*m*·*n*) time, O(*n*) space. (There's also a formula, the binomial coefficient C(*m* + *n* − 2, *m* − 1), but the DP generalises to grids with obstacles; the formula doesn't.)

## Worked problem 2: Longest Common Subsequence

[LeetCode 1143](https://leetcode.com/problems/longest-common-subsequence/). The length of the longest sequence of characters that appears, in order, in both strings. The characters needn't be next to each other.

| Strings | Output | One such subsequence |
|---|---|---|
| `"abcde"`, `"ace"` | 3 | `"ace"` |
| `"abc"`, `"abc"` | 3 | `"abc"` |
| `"abc"`, `"def"` | 0 | |

**Think first.**
1. **State:** `lcs[i][j]` = the answer for the first *i* characters of `a` and the first *j* of `b`.
2. **Recurrence:**
   - If `a[i-1] == b[j-1]`, that character extends the best answer without it: `lcs[i-1][j-1] + 1`.
   - Otherwise, drop the last character of one string or the other: `max(lcs[i-1][j], lcs[i][j-1])`.
3. **Base cases:** with an empty string, 0. That's why the table has an extra row and column of zeros.
4. **Order:** row by row.

This one keeps the full table, which makes the recurrence easy to see. Each row needs only the one above; reducing it to two rows is a good exercise.

<!-- file: dp2d/lcs.go -->
~~~go
package dp2d

// LCS returns the length of the longest common subsequence of a and b
// (bytes). O(len(a)·len(b)) time and space.
func LCS(a, b string) int {
	lcs := make([][]int, len(a)+1) // row 0 and column 0: an empty prefix, all zeros
	for i := range lcs {
		lcs[i] = make([]int, len(b)+1)
	}
	for i := 1; i <= len(a); i++ {
		for j := 1; j <= len(b); j++ {
			if a[i-1] == b[j-1] {
				lcs[i][j] = lcs[i-1][j-1] + 1
			} else {
				lcs[i][j] = max(lcs[i-1][j], lcs[i][j-1])
			}
		}
	}
	return lcs[len(a)][len(b)]
}
~~~

<!-- file: dp2d/lcs_test.go -->
~~~go
package dp2d

import "testing"

func TestLCS(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"abcde", "ace", 3},
		{"abc", "abc", 3},
		{"abc", "def", 0},
		{"", "a", 0},
		{"bsbininm", "jmjkbkjkv", 1},
		{"abcba", "abcbcba", 5},
	}
	for _, c := range cases {
		if got := LCS(c.a, c.b); got != c.want {
			t.Errorf("LCS(%q, %q) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./dp2d/ && go test ./dp2d/ -->

<!-- file: dp2d/lcs.py -->
~~~python
def lcs(a: str, b: str) -> int:
    """Length of the longest common subsequence of a and b."""
    table = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(1, len(a) + 1):
        for j in range(1, len(b) + 1):
            if a[i - 1] == b[j - 1]:
                table[i][j] = table[i - 1][j - 1] + 1
            else:
                table[i][j] = max(table[i - 1][j], table[i][j - 1])
    return table[-1][-1]
~~~

<!-- file: dp2d/test_lcs.py -->
~~~python
import pytest

from dp2d.lcs import lcs


@pytest.mark.parametrize(
    ("a", "b", "want"),
    [
        ("abcde", "ace", 3),
        ("abc", "abc", 3),
        ("abc", "def", 0),
        ("", "a", 0),
        ("bsbininm", "jmjkbkjkv", 1),
        ("abcba", "abcbcba", 5),
    ],
)
def test_lcs(a, b, want):
    assert lcs(a, b) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q dp2d -->

**Complexity:** O(*m*·*n*) time and space.

## Pitfalls

- **The extra row and column.** Index the table by prefix length (0 to *n*), not by character position. Then empty prefixes are row and column 0, with no special cases.
- **`[[0] * n] * m` in Python** makes *m* references to one row. Use a comprehension.
- **Reducing space changes the order.** Updating one row in place works only when each cell needs the cell above (not yet overwritten) and the cell to the left (already updated). Check before shrinking.
- **Subsequence versus substring.** A subsequence may skip characters; a substring may not. They're different recurrences.

## Practice

1. **[Edit Distance](https://leetcode.com/problems/edit-distance/)** (medium). The fewest insertions, deletions and replacements turning one word into another. `"horse", "ros"` → `3`.
   <details><summary>Hint</summary>Like LCS: if the last characters match, <code>d[i-1][j-1]</code>; otherwise 1 + the minimum of the three neighbours (one per operation). The first row and column are 0, 1, 2, ...</details>
2. **[Coin Change II](https://leetcode.com/problems/coin-change-ii/)** (medium). The number of combinations making an amount.
   <details><summary>Hint</summary>Loop over coins in the outer loop and amounts in the inner one, so each combination is counted once, not once per ordering.</details>
3. **[Target Sum](https://leetcode.com/problems/target-sum/)** (medium). Put + or − before each number to reach a target; how many ways?
   <details><summary>Hint</summary>State: (index, running sum). A map from sum to count, carried from one index to the next.</details>
4. **[Interleaving String](https://leetcode.com/problems/interleaving-string/)** (medium). Is `s3` formed by interleaving `s1` and `s2`, keeping each one's order?
   <details><summary>Hint</summary><code>ok[i][j]</code> = the first <i>i</i> of s1 and first <i>j</i> of s2 form the first <i>i</i> + <i>j</i> of s3.</details>
5. **[Best Time to Buy and Sell Stock with Cooldown](https://leetcode.com/problems/best-time-to-buy-and-sell-stock-with-cooldown/)** (medium).
   <details><summary>Hint</summary>The second dimension is a state, not a sequence: holding, just sold (cooling down), or free to buy. A small state machine per day.</details>

Next: [16. Tries](../16-tries/README.md).
