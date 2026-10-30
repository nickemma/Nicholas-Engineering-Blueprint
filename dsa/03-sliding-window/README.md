# 03. Sliding window

<!-- continue: ../02-two-pointers/README.md -->

A window is a contiguous range `[left, right]` of the input. Move `right` forwards to grow it; move `left` forwards to shrink it when it breaks a rule. Each element enters once and leaves once, so the whole scan is O(*n*), however many windows you consider.

**Recognise it when** the problem asks for the **longest**, **shortest** or **best** **contiguous** range (a substring, a subarray, a time span) that satisfies a rule, or for something about **every** window of a fixed size.

**Real systems:**
- [Phase 6's rate limiter](../../lessons/06-safe-shared-queries/TEACHING.md#step-5-rate-limiting) answers "how many requests in the last second?";
- [Phase 5's burn-rate alerts](../../lessons/05-constrained-operations/TEACHING.md#step-10-prometheus-slos-and-burn-rate-alerts) answer "what fraction of requests failed in the last hour?".

Both are windows over time. Worked problem 2 is the first of these.

## Worked problem 1: Longest Substring Without Repeating Characters

[LeetCode 3](https://leetcode.com/problems/longest-substring-without-repeating-characters/). The length of the longest substring in which no character repeats.

| Input | Output | Why |
|---|---|---|
| `"abcabcbb"` | 3 | `"abc"` |
| `"bbbbb"` | 1 | `"b"` |
| `"pwwkew"` | 3 | `"wke"` (a substring must be contiguous; `"pwke"` isn't one) |

**Think first.**
- **Brute force:** check every substring, O(*n*²) of them, each O(*n*) to check: O(*n*³).
- **The window:** grow `right` one character at a time. When the new character is already inside the window, the window must start just after that earlier copy.
- Remember each character's **last position**, and the jump is one lookup.
- The trap: a character's last position may be **before** the window's start, and then it doesn't matter. `"abba"` catches it. When the second `a` arrives, the window is `"b"`, and the first `a`'s position is outside it.

<!-- file: slidingwindow/longest_substring.go -->
~~~go
// Package slidingwindow holds the sliding-window problems.
package slidingwindow

// LongestUniqueSubstring returns the length of the longest substring of s
// (bytes) with no repeated byte. O(n) time, O(alphabet) space.
func LongestUniqueSubstring(s string) int {
	last := make(map[byte]int) // byte → where it was last seen
	best, start := 0, 0
	for i := 0; i < len(s); i++ {
		if j, ok := last[s[i]]; ok && j >= start {
			start = j + 1 // the repeat is inside the window: start after it
		}
		last[s[i]] = i
		best = max(best, i-start+1)
	}
	return best
}
~~~

<!-- file: slidingwindow/longest_substring_test.go -->
~~~go
package slidingwindow

import "testing"

func TestLongestUniqueSubstring(t *testing.T) {
	cases := []struct {
		s    string
		want int
	}{
		{"abcabcbb", 3},
		{"bbbbb", 1},
		{"pwwkew", 3},
		{"", 0},
		{"abba", 2}, // the first a is outside the window when the second arrives
		{"dvdf", 3},
	}
	for _, c := range cases {
		if got := LongestUniqueSubstring(c.s); got != c.want {
			t.Errorf("LongestUniqueSubstring(%q) = %d, want %d", c.s, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./slidingwindow/ && go test ./slidingwindow/ -->

<!-- file: slidingwindow/longest_substring.py -->
~~~python
def longest_unique_substring(s: str) -> int:
    """Length of the longest substring with no repeated character."""
    last: dict[str, int] = {}
    best = start = 0
    for i, ch in enumerate(s):
        if last.get(ch, -1) >= start:
            start = last[ch] + 1
        last[ch] = i
        best = max(best, i - start + 1)
    return best
~~~

<!-- file: slidingwindow/test_longest_substring.py -->
~~~python
import pytest

from slidingwindow.longest_substring import longest_unique_substring


@pytest.mark.parametrize(
    ("s", "want"),
    [("abcabcbb", 3), ("bbbbb", 1), ("pwwkew", 3), ("", 0), ("abba", 2), ("dvdf", 3)],
)
def test_longest_unique_substring(s, want):
    assert longest_unique_substring(s) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q slidingwindow -->

**Complexity:** O(*n*) time; O(*k*) space for *k* distinct characters.

## Worked problem 2: the busiest window (our own)

This one isn't from LeetCode; it's the question a rate limiter or an alert asks. Given request timestamps in seconds, **sorted**, and a window length `w`, what's the most requests that fall in any window `[t, t + w)`?

| Timestamps | `w` | Output | Why |
|---|---|---|---|
| `[1, 2, 3, 10, 11]` | 3 | 3 | `[1, 4)` holds 1, 2 and 3 |
| `[0, 10, 20]` | 10 | 1 | the window is half-open: `[0, 10)` doesn't include 10 |
| `[5, 5, 5]` | 1 | 3 | three requests in the same second |

**Think first.** The busiest window can always start at some request (slide any window right until its left edge meets one; it loses nothing). So for each request as the window's **right** end, drop requests from the left while they're `w` or more seconds older, and count what's left.

<!-- file: slidingwindow/busiest.go -->
~~~go
package slidingwindow

// Busiest returns the most timestamps that fall in any half-open window
// [t, t+w). times must be sorted ascending. O(n) time, O(1) space.
func Busiest(times []int64, w int64) int {
	best, left := 0, 0
	for right, t := range times {
		for times[left] <= t-w {
			left++ // too old to share a window with t
		}
		best = max(best, right-left+1)
	}
	return best
}
~~~

<!-- file: slidingwindow/busiest_test.go -->
~~~go
package slidingwindow

import "testing"

func TestBusiest(t *testing.T) {
	cases := []struct {
		name  string
		times []int64
		w     int64
		want  int
	}{
		{"a burst", []int64{1, 2, 3, 10, 11}, 3, 3},
		{"half-open", []int64{0, 10, 20}, 10, 1},
		{"just wide enough", []int64{0, 10, 20}, 11, 2},
		{"same second", []int64{5, 5, 5}, 1, 3},
		{"none", nil, 5, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Busiest(c.times, c.w); got != c.want {
				t.Errorf("Busiest(%v, %d) = %d, want %d", c.times, c.w, got, c.want)
			}
		})
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./slidingwindow/ && go test ./slidingwindow/ -->

<!-- file: slidingwindow/busiest.py -->
~~~python
def busiest(times: list[int], w: int) -> int:
    """Most sorted timestamps in any half-open window [t, t + w)."""
    best = left = 0
    for right, t in enumerate(times):
        while times[left] <= t - w:
            left += 1
        best = max(best, right - left + 1)
    return best
~~~

<!-- file: slidingwindow/test_busiest.py -->
~~~python
import pytest

from slidingwindow.busiest import busiest


@pytest.mark.parametrize(
    ("times", "w", "want"),
    [
        ([1, 2, 3, 10, 11], 3, 3),
        ([0, 10, 20], 10, 1),
        ([0, 10, 20], 11, 2),
        ([5, 5, 5], 1, 3),
        ([], 5, 0),
    ],
)
def test_busiest(times, w, want):
    assert busiest(times, w) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q slidingwindow -->

**Complexity:** O(*n*) time, O(1) space. A real rate limiter can't keep every timestamp, which is why Phase 6 uses a token bucket: O(1) memory per client, at the cost of approximating the window.

## Pitfalls

- **Off by one at the edges.** Decide whether the window is `[t, t + w)` or `[t, t + w]`, write it down, and test the boundary (the `[0, 10, 20]` case).
- **Stale positions.** A remembered position from before the window's start must be ignored (`"abba"`).
- **Shrinking with `if` instead of `while`.** One new element can push several old ones out.
- **Windows need contiguity.** If the problem allows skipping elements ("subsequence"), it's not a window problem; it's usually dynamic programming.

## Practice

1. **[Best Time to Buy and Sell Stock](https://leetcode.com/problems/best-time-to-buy-and-sell-stock/)** (easy). Buy one day, sell a later day; the best profit. `[7, 1, 5, 3, 6, 4]` → `5`.
   <details><summary>Hint</summary>Keep the lowest price so far; the window is "from the cheapest day to today".</details>
2. **[Longest Repeating Character Replacement](https://leetcode.com/problems/longest-repeating-character-replacement/)** (medium). Replace up to *k* characters to make the longest run of one letter. `"AABABBA", k = 1` → `4`.
   <details><summary>Hint</summary>A window is fine while (its length − its most common letter's count) ≤ <i>k</i>.</details>
3. **[Permutation in String](https://leetcode.com/problems/permutation-in-string/)** (medium). Does `s2` contain some rearrangement of `s1` as a substring? `"ab", "eidbaooo"` → `true`.
   <details><summary>Hint</summary>A fixed window of len(s1); keep 26 counts for the window and compare with s1's.</details>
4. **[Minimum Window Substring](https://leetcode.com/problems/minimum-window-substring/)** (hard). The shortest substring of `s` containing every character of `t` (with counts). `"ADOBECODEBANC", "ABC"` → `"BANC"`.
   <details><summary>Hint</summary>Grow until the window has everything, then shrink from the left while it still does, recording the best. Track how many required characters are fully satisfied, so the check is O(1).</details>
5. **[Sliding Window Maximum](https://leetcode.com/problems/sliding-window-maximum/)** (hard). The maximum of every window of size *k*. `[1, 3, -1, -3, 5, 3, 6, 7], k = 3` → `[3, 3, 5, 5, 6, 7]`.
   <details><summary>Hint</summary>A deque of positions whose values decrease from front to back. A new value pops every smaller one from the back; the front is the maximum, once you drop positions that left the window.</details>

Next: [04. Stack](../04-stack/README.md).
