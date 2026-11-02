# 02. Two pointers

<!-- continue: ../01-arrays-hashing/README.md -->

Two indexes walk through a sequence, usually from both ends towards the middle, or both forwards at different speeds. Each step rules out a whole set of candidates, so one pass replaces a nested loop.

**Recognise it when:**

- the input is **sorted**, or sorting it doesn't lose anything you need;
- you're looking for **pairs** or **triples** that meet a condition;
- you compare the two **ends** of something (a palindrome, the widest container);
- you must change an array **in place** (remove duplicates, merge).

**Real systems:** merging two sorted runs with one pointer each is how LSM-tree storage engines compact their files, which [Phase 3](../../lessons/03-durable-auditable-data/README.md) compares with B-trees. Merge-sort's merge step and the "merge sorted arrays" practice problem below are the same move.

## Worked problem 1: Valid Palindrome

[LeetCode 125](https://leetcode.com/problems/valid-palindrome/). Ignoring everything except letters and digits, and ignoring case, does a string read the same forwards and backwards?

| Input | Output |
|---|---|
| `"A man, a plan, a canal: Panama"` | `true` |
| `"race a car"` | `false` |
| `" "` | `true` (nothing left to compare) |

**Think first.** Building a cleaned copy and reversing it works, in O(*n*) extra space. Two pointers need none: one from each end, skipping what doesn't count, comparing what does, moving inwards until they meet.

<!-- file: twopointers/palindrome.go -->
~~~go
// Package twopointers holds the two-pointer problems.
package twopointers

// IsPalindrome reports whether s reads the same both ways, looking only at
// ASCII letters and digits and ignoring case. O(n) time, O(1) space.
func IsPalindrome(s string) bool {
	i, j := 0, len(s)-1
	for i < j {
		switch {
		case !isAlnum(s[i]):
			i++
		case !isAlnum(s[j]):
			j--
		case lower(s[i]) != lower(s[j]):
			return false
		default:
			i++
			j--
		}
	}
	return true
}

func isAlnum(c byte) bool {
	return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9'
}

func lower(c byte) byte {
	if 'A' <= c && c <= 'Z' {
		return c + 'a' - 'A'
	}
	return c
}
~~~

- Indexing a Go string (`s[i]`) gives a **byte**, not a character. That's correct here because the problem is ASCII; for general text you'd iterate runes.
- A `switch` with no value tests each `case` as a condition, in order.

<!-- file: twopointers/palindrome_test.go -->
~~~go
package twopointers

import "testing"

func TestIsPalindrome(t *testing.T) {
	cases := []struct {
		s    string
		want bool
	}{
		{"A man, a plan, a canal: Panama", true},
		{"race a car", false},
		{" ", true},
		{"", true},
		{"0P", false}, // a digit and a letter: lowercasing must not equate them
		{"ab_a", true},
	}
	for _, c := range cases {
		if got := IsPalindrome(c.s); got != c.want {
			t.Errorf("IsPalindrome(%q) = %v, want %v", c.s, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./twopointers/ && go test ./twopointers/ -->

<!-- file: twopointers/palindrome.py -->
~~~python
def is_palindrome(s: str) -> bool:
    """Same both ways, counting only letters and digits, ignoring case."""
    i, j = 0, len(s) - 1
    while i < j:
        if not s[i].isalnum():
            i += 1
        elif not s[j].isalnum():
            j -= 1
        elif s[i].lower() != s[j].lower():
            return False
        else:
            i, j = i + 1, j - 1
    return True
~~~

<!-- file: twopointers/test_palindrome.py -->
~~~python
import pytest

from twopointers.palindrome import is_palindrome


@pytest.mark.parametrize(
    ("s", "want"),
    [
        ("A man, a plan, a canal: Panama", True),
        ("race a car", False),
        (" ", True),
        ("", True),
        ("0P", False),
        ("ab_a", True),
    ],
)
def test_is_palindrome(s, want):
    assert is_palindrome(s) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q twopointers -->

**Complexity:** O(*n*) time, O(1) space.

## Worked problem 2: 3Sum

[LeetCode 15](https://leetcode.com/problems/3sum/). Find every distinct triple of values in a list that adds up to zero. No triple may appear twice.

| Input | Output |
|---|---|
| `[-1, 0, 1, 2, -1, -4]` | `[[-1, -1, 2], [-1, 0, 1]]` |
| `[0, 1, 1]` | `[]` |
| `[0, 0, 0, 0]` | `[[0, 0, 0]]` |

**Think first.**
- **Brute force:** three nested loops, O(*n*³), plus a set to remove duplicate triples.
- **Better: sort first.** Fix the smallest number `a`. The other two must sum to `−a`, and in the sorted rest that's a two-pointer search: if the sum is too small, move the left pointer right; if too big, move the right pointer left. That's O(*n*²) overall.
- **Duplicates are avoided by skipping**, not by a set. Skip a first number equal to the previous one; after a match, skip left-pointer values equal to the one just used.

<!-- file: twopointers/three_sum.go -->
~~~go
package twopointers

import "slices"

// ThreeSum returns every distinct triple that sums to zero, each in
// ascending order, sorted by first element. O(n²) time; O(n) space for the
// sorted copy.
func ThreeSum(nums []int) [][]int {
	s := slices.Clone(nums)
	slices.Sort(s)
	var out [][]int
	for i := 0; i+2 < len(s); i++ {
		if s[i] > 0 {
			break // the smallest is positive: nothing further can sum to zero
		}
		if i > 0 && s[i] == s[i-1] {
			continue // the same first number gives the same triples
		}
		lo, hi := i+1, len(s)-1
		for lo < hi {
			switch sum := s[i] + s[lo] + s[hi]; {
			case sum < 0:
				lo++
			case sum > 0:
				hi--
			default:
				out = append(out, []int{s[i], s[lo], s[hi]})
				lo++
				for lo < hi && s[lo] == s[lo-1] {
					lo++ // skip copies of the value just used
				}
				hi--
			}
		}
	}
	return out
}
~~~

<!-- file: twopointers/three_sum_test.go -->
~~~go
package twopointers

import (
	"reflect"
	"testing"
)

func TestThreeSum(t *testing.T) {
	cases := []struct {
		nums []int
		want [][]int
	}{
		{[]int{-1, 0, 1, 2, -1, -4}, [][]int{{-1, -1, 2}, {-1, 0, 1}}},
		{[]int{0, 1, 1}, nil},
		{[]int{0, 0, 0, 0}, [][]int{{0, 0, 0}}},
		{[]int{-2, 0, 1, 1, 2}, [][]int{{-2, 0, 2}, {-2, 1, 1}}},
		{[]int{-2, 0, 0, 2, 2}, [][]int{{-2, 0, 2}}},
		{[]int{1, 2}, nil},
	}
	for _, c := range cases {
		if got := ThreeSum(c.nums); !reflect.DeepEqual(got, c.want) {
			t.Errorf("ThreeSum(%v) = %v, want %v", c.nums, got, c.want)
		}
	}
}
~~~

Two cases guard the two skips. Without the first-number skip, `[0, 0, 0, 0]` reports `[0, 0, 0]` twice. Without the skip after a match, `[-2, 0, 0, 2, 2]` reports `[-2, 0, 2]` twice.

<!-- run: test -z "$(gofmt -l .)" && go vet ./twopointers/ && go test ./twopointers/ -->

<!-- file: twopointers/three_sum.py -->
~~~python
def three_sum(nums: list[int]) -> list[list[int]]:
    """Every distinct triple summing to zero, each ascending, sorted by first."""
    s = sorted(nums)
    out: list[list[int]] = []
    for i in range(len(s) - 2):
        if s[i] > 0:
            break
        if i > 0 and s[i] == s[i - 1]:
            continue
        lo, hi = i + 1, len(s) - 1
        while lo < hi:
            total = s[i] + s[lo] + s[hi]
            if total < 0:
                lo += 1
            elif total > 0:
                hi -= 1
            else:
                out.append([s[i], s[lo], s[hi]])
                lo += 1
                while lo < hi and s[lo] == s[lo - 1]:
                    lo += 1
                hi -= 1
    return out
~~~

<!-- file: twopointers/test_three_sum.py -->
~~~python
import pytest

from twopointers.three_sum import three_sum


@pytest.mark.parametrize(
    ("nums", "want"),
    [
        ([-1, 0, 1, 2, -1, -4], [[-1, -1, 2], [-1, 0, 1]]),
        ([0, 1, 1], []),
        ([0, 0, 0, 0], [[0, 0, 0]]),
        ([-2, 0, 1, 1, 2], [[-2, 0, 2], [-2, 1, 1]]),
        ([-2, 0, 0, 2, 2], [[-2, 0, 2]]),
        ([1, 2], []),
    ],
)
def test_three_sum(nums, want):
    assert three_sum(nums) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q twopointers -->

**Complexity:** O(*n*²) time; O(*n*) space for the sorted copy (sorting dominates nothing here, because the pair search is already O(*n*²)).

## Pitfalls

- **Sorting changes positions.** If the problem asks for original indices (Two Sum), sorting loses them; use a map instead, or sort pairs of (value, index).
- **`i < j`, not `i <= j`**, when the pointers must name different elements.
- **Infinite loops.** Every branch must move at least one pointer.
- **Duplicates.** Decide whether the problem wants distinct values or distinct positions, and skip accordingly.

## Practice

1. **[Two Sum II](https://leetcode.com/problems/two-sum-ii-input-array-is-sorted/)** (medium). Two Sum on a sorted array, in O(1) extra space. `[2, 7, 11, 15], 9` → `[1, 2]` (1-based).
   <details><summary>Hint</summary>Start at both ends. Too small: move left. Too big: move right.</details>
2. **[Container With Most Water](https://leetcode.com/problems/container-with-most-water/)** (medium). Two lines and the x-axis form a container; find the largest area. `[1, 8, 6, 2, 5, 4, 8, 3, 7]` → `49`.
   <details><summary>Hint</summary>Start widest. The shorter line limits the area, so moving the taller one can never help: move the shorter one.</details>
3. **[Merge Sorted Array](https://leetcode.com/problems/merge-sorted-array/)** (easy). Merge one sorted array into another that has room at its end, in place. `[1, 2, 3, 0, 0, 0], [2, 5, 6]` → `[1, 2, 2, 3, 5, 6]`.
   <details><summary>Hint</summary>Fill from the back, taking the larger of the two last elements, so you never overwrite something you still need.</details>
4. **[Trapping Rain Water](https://leetcode.com/problems/trapping-rain-water/)** (hard). How much water do bars of these heights trap? `[0, 1, 0, 2, 1, 0, 1, 3, 2, 1, 2, 1]` → `6`.
   <details><summary>Hint</summary>Water above a bar = min(tallest to its left, tallest to its right) − its height. Two pointers keep both maxima; move the side with the smaller maximum, because that side's answer is already decided.</details>

Next: [03. Sliding window](../03-sliding-window/README.md).
