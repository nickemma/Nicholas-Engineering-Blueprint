# 01. Arrays and hashing

<!-- continue: ../00-complexity/README.md -->

A hash map answers "have I seen this before?" in O(1) on average. Most problems that look like they need two nested loops need one loop and a map instead.

**Recognise it when** the problem asks:

- whether something is a duplicate, or appeared before;
- how many times each value occurs;
- which items belong together (the same letters, the same key);
- for two values that combine to something ("find a pair that sums to...").

**Real systems:** [Phase 2's idempotency keys](../../lessons/02-connected-services/TEACHING.md#step-4-idempotency-end-to-end) are this pattern. "Have I processed this key before?" is a lookup in a map (later, in [PostgreSQL](../../lessons/03-durable-auditable-data/TEACHING.md#step-5-idempotency-keys-in-postgresql)). So is grouping by a key: Runway's cache groups jobs by tenant.

## Worked problem 1: Two Sum

[LeetCode 1](https://leetcode.com/problems/two-sum/). Given a list of integers and a target, return the positions of the two numbers that add up to the target. Use each position at most once. Return nothing if no pair exists.

| Input | Target | Output |
|---|---|---|
| `[2, 7, 11, 15]` | 9 | `[0, 1]` |
| `[3, 2, 4]` | 6 | `[1, 2]` |
| `[3, 3]` | 6 | `[0, 1]` |

**Think first.**
- **Brute force:** check every pair, which is O(*n*²).
- **The better idea:** for each number *n*, the partner it needs is `target − n`. If you remember every number you've passed, with its position, then "have I already seen my partner?" is one map lookup. One pass, O(*n*).
- Check for the partner **before** adding the current number. Otherwise `[3]` with target 6 would pair 3 with itself.

<!-- file: arrays/two_sum.go -->
~~~go
// Package arrays holds the arrays-and-hashing problems.
package arrays

// TwoSum returns the positions of the two numbers that add up to target,
// or nil if no pair does. It makes one pass, remembering each number's
// position, and asks whether the partner it needs was already seen.
func TwoSum(nums []int, target int) []int {
	seen := make(map[int]int, len(nums)) // number → its position
	for i, n := range nums {
		if j, ok := seen[target-n]; ok {
			return []int{j, i}
		}
		seen[n] = i
	}
	return nil
}
~~~

<!-- file: arrays/two_sum_test.go -->
~~~go
package arrays

import (
	"slices"
	"testing"
)

func TestTwoSum(t *testing.T) {
	cases := []struct {
		name   string
		nums   []int
		target int
		want   []int
	}{
		{"first two", []int{2, 7, 11, 15}, 9, []int{0, 1}},
		{"not the first", []int{3, 2, 4}, 6, []int{1, 2}},
		{"same value twice", []int{3, 3}, 6, []int{0, 1}},
		{"negatives", []int{-3, 4, 3, 90}, 0, []int{0, 2}},
		{"a number can't pair with itself", []int{3}, 6, nil},
		{"no pair", []int{1, 2, 3}, 100, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := TwoSum(c.nums, c.target); !slices.Equal(got, c.want) {
				t.Errorf("TwoSum(%v, %d) = %v, want %v", c.nums, c.target, got, c.want)
			}
		})
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./arrays/ && go test ./arrays/ -->

~~~bash
go test ./arrays/
~~~

The same in Python:

<!-- file: arrays/two_sum.py -->
~~~python
def two_sum(nums: list[int], target: int) -> list[int] | None:
    """Return the positions of two numbers adding up to target, or None."""
    seen: dict[int, int] = {}  # number -> its position
    for i, n in enumerate(nums):
        if target - n in seen:
            return [seen[target - n], i]
        seen[n] = i
    return None
~~~

<!-- file: arrays/test_two_sum.py -->
~~~python
import pytest

from arrays.two_sum import two_sum


@pytest.mark.parametrize(
    ("nums", "target", "want"),
    [
        ([2, 7, 11, 15], 9, [0, 1]),
        ([3, 2, 4], 6, [1, 2]),
        ([3, 3], 6, [0, 1]),
        ([-3, 4, 3, 90], 0, [0, 2]),
        ([3], 6, None),
        ([1, 2, 3], 100, None),
    ],
)
def test_two_sum(nums, target, want):
    assert two_sum(nums, target) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q arrays -->

~~~bash
uv run pytest -q arrays
~~~

**Complexity:** O(*n*) time, O(*n*) space for the map.

## Worked problem 2: Group Anagrams

[LeetCode 49](https://leetcode.com/problems/group-anagrams/). Given a list of lowercase words, group together the words that are anagrams of each other (the same letters, in any order).

| Input | Output |
|---|---|
| `["eat", "tea", "tan", "ate", "nat", "bat"]` | `[["eat", "tea", "ate"], ["tan", "nat"], ["bat"]]` |
| `[""]` | `[[""]]` |

**Think first.** Two words are anagrams exactly when they have the same letter counts. So compute a **key** that's the same for all anagrams, and group by it. Two choices of key:

| Key | Cost per word of length *k* |
|---|---|
| The word's letters, sorted (`"eat"` → `"aet"`) | O(*k* log *k*) |
| The count of each of the 26 letters | O(*k*) |

The counts are cheaper, and in Go an array of 26 counts can be a map key directly, because arrays (unlike slices) are comparable.

The groups come back in the order their first word appeared, so the output is the same on every run. Go's map iteration order is random, which is why the code keeps the groups in a slice and the map only remembers where each one is.

<!-- file: arrays/group_anagrams.go -->
~~~go
package arrays

// GroupAnagrams groups words that use the same letters. Words must be
// lowercase a–z. Groups appear in the order of their first word.
func GroupAnagrams(words []string) [][]string {
	var groups [][]string
	where := make(map[[26]int]int) // letter counts → index in groups
	for _, w := range words {
		var key [26]int
		for _, r := range w {
			key[r-'a']++
		}
		i, ok := where[key]
		if !ok {
			i = len(groups)
			where[key] = i
			groups = append(groups, nil)
		}
		groups[i] = append(groups[i], w)
	}
	return groups
}
~~~

<!-- file: arrays/group_anagrams_test.go -->
~~~go
package arrays

import (
	"reflect"
	"testing"
)

func TestGroupAnagrams(t *testing.T) {
	cases := []struct {
		name  string
		words []string
		want  [][]string
	}{
		{"mixed", []string{"eat", "tea", "tan", "ate", "nat", "bat"},
			[][]string{{"eat", "tea", "ate"}, {"tan", "nat"}, {"bat"}}},
		{"empty word", []string{""}, [][]string{{""}}},
		{"same letters, different counts", []string{"aab", "abb"}, [][]string{{"aab"}, {"abb"}}},
		{"no words", nil, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := GroupAnagrams(c.words); !reflect.DeepEqual(got, c.want) {
				t.Errorf("GroupAnagrams(%q) = %q, want %q", c.words, got, c.want)
			}
		})
	}
}
~~~

The test `"aab"` against `"abb"` is the one that catches a key built from the **set** of letters instead of their counts.

<!-- run: test -z "$(gofmt -l .)" && go vet ./arrays/ && go test ./arrays/ -->

~~~bash
go test ./arrays/
~~~

In Python, a tuple of counts is the key, and a `dict` keeps insertion order, so the groups come out in first-seen order without extra work:

<!-- file: arrays/group_anagrams.py -->
~~~python
def group_anagrams(words: list[str]) -> list[list[str]]:
    """Group lowercase words that use the same letters, in first-seen order."""
    groups: dict[tuple[int, ...], list[str]] = {}
    for word in words:
        counts = [0] * 26
        for ch in word:
            counts[ord(ch) - ord("a")] += 1
        groups.setdefault(tuple(counts), []).append(word)
    return list(groups.values())
~~~

- A list can't be a dict key (it can change), so the counts become a `tuple`.
- `setdefault(key, [])` returns the existing list or stores and returns a new one.

<!-- file: arrays/test_group_anagrams.py -->
~~~python
import pytest

from arrays.group_anagrams import group_anagrams


@pytest.mark.parametrize(
    ("words", "want"),
    [
        (
            ["eat", "tea", "tan", "ate", "nat", "bat"],
            [["eat", "tea", "ate"], ["tan", "nat"], ["bat"]],
        ),
        ([""], [[""]]),
        (["aab", "abb"], [["aab"], ["abb"]]),
        ([], []),
    ],
)
def test_group_anagrams(words, want):
    assert group_anagrams(words) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q arrays -->

~~~bash
uv run pytest -q arrays
~~~

**Complexity:** O(*n*·*k*) time for *n* words of length up to *k*; O(*n*·*k*) space.

## Pitfalls

- **Iteration order.** Go's map order is random by design. Never let a result depend on it; keep order in a slice.
- **Mutable keys.** Python lists and Go slices can't be keys. Use tuples, strings or arrays.
- **Adding before checking.** In Two Sum, adding the current number before looking for its partner pairs a number with itself.
- **Assuming the alphabet.** `r - 'a'` only works for lowercase a–z. Say the assumption out loud in an interview, and ask.

## Practice

Solve each in Go, then Python, with tests, in your own `dsa` repository. Open a hint only after 15 minutes stuck.

1. **[Contains Duplicate](https://leetcode.com/problems/contains-duplicate/)** (easy). Is any value in the list more than once? `[1, 2, 3, 1]` → `true`.
   <details><summary>Hint</summary>You built this in guide 00. Do it again from a blank file.</details>
2. **[Valid Anagram](https://leetcode.com/problems/valid-anagram/)** (easy). Do two strings use exactly the same letters? `"anagram", "nagaram"` → `true`.
   <details><summary>Hint</summary>Count up for one string and down for the other; every count must end at zero.</details>
3. **[Top K Frequent Elements](https://leetcode.com/problems/top-k-frequent-elements/)** (medium). Return the *k* most frequent values. `[1, 1, 1, 2, 2, 3], k = 2` → `[1, 2]`.
   <details><summary>Hint</summary>Count with a map. Then, instead of sorting by count, put each value in a bucket indexed by its count (counts can't exceed <i>n</i>), and read buckets from the top: O(<i>n</i>).</details>
4. **[Product of Array Except Self](https://leetcode.com/problems/product-of-array-except-self/)** (medium). For each position, the product of every other element, without division. `[1, 2, 3, 4]` → `[24, 12, 8, 6]`.
   <details><summary>Hint</summary>The answer at <i>i</i> is (product of everything left of <i>i</i>) × (product of everything right of <i>i</i>). Two passes.</details>
5. **[Longest Consecutive Sequence](https://leetcode.com/problems/longest-consecutive-sequence/)** (medium). The length of the longest run of consecutive integers, in O(*n*). `[100, 4, 200, 1, 3, 2]` → `4`.
   <details><summary>Hint</summary>Put everything in a set. Only start counting from a number whose predecessor isn't in the set.</details>
6. **[Valid Sudoku](https://leetcode.com/problems/valid-sudoku/)** (medium). Does a partly filled 9×9 board break any row, column or box rule?
   <details><summary>Hint</summary>One set per row, per column and per box. Box number = (row / 3) × 3 + column / 3.</details>

Add each to your [spaced-review log](../README.md#spaced-review).

Next: [02. Two pointers](../02-two-pointers/README.md).
