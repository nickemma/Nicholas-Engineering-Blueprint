# 05. Binary search

<!-- continue: ../04-stack/README.md -->

Binary search halves the candidates at every step, so a million candidates take about 20 steps. It works whenever you can ask a yes/no question that's **false up to some point and true after it**. A sorted array gives you that question ("is this element ≥ the target?"), but so do many problems with no array at all.

**Recognise it when:**

- the input is sorted, and the problem asks to find something, or where something would go;
- "find the **smallest** value that works" or "the **largest** that doesn't", and checking one candidate is easy;
- *n* is large (10⁵ or more) and O(*n*) per question is too slow;
- "find the first bad commit": `git bisect` is binary search.

**Real systems:** [Phase 4's consistent-hash ring](../../lessons/04-replicated-state/TEACHING.md#step-11-consistent-hashing-and-a-cache-spread-over-several-servers) finds a key's server with `slices.BinarySearchFunc` over the ring's sorted points. B-tree indexes in [Phase 3](../../lessons/03-durable-auditable-data/README.md) binary-search within each page.

## The one template to remember

Search for the **first** position where a condition becomes true. Keep the answer inside `[lo, hi]`, where `hi = n` means "nowhere":

~~~go
lo, hi := 0, n // the answer is in [lo, hi]; hi = n means "nowhere"
for lo < hi {
	mid := lo + (hi-lo)/2
	if condition(mid) {
		hi = mid // mid might be the answer; keep it
	} else {
		lo = mid + 1 // mid is not; drop it
	}
}
return lo // the first position where condition is true, or n
~~~

- `lo + (hi-lo)/2` instead of `(lo+hi)/2` avoids overflow when indexes are huge.
- The loop always shrinks the range, so it always ends.
- Every binary search below is this template with a different `condition`.

## Worked problem 1: Binary Search

[LeetCode 704](https://leetcode.com/problems/binary-search/). Find a target's position in a sorted array of distinct integers, or −1.

| Input | Target | Output |
|---|---|---|
| `[-1, 0, 3, 5, 9, 12]` | 9 | 4 |
| `[-1, 0, 3, 5, 9, 12]` | 2 | −1 |

**Think first.** The condition is `nums[mid] >= target`. The template finds the first position where it's true; the target is there if it's anywhere.

<!-- file: binarysearch/search.go -->
~~~go
// Package binarysearch holds the binary-search problems.
package binarysearch

// Search returns target's position in sorted nums, or -1. O(log n).
func Search(nums []int, target int) int {
	i := firstTrue(len(nums), func(mid int) bool { return nums[mid] >= target })
	if i < len(nums) && nums[i] == target {
		return i
	}
	return -1
}

// firstTrue returns the first i in [0, n) for which ok(i) is true, or n.
// ok must be false, then true: never true then false again.
func firstTrue(n int, ok func(int) bool) int {
	lo, hi := 0, n
	for lo < hi {
		mid := lo + (hi-lo)/2
		if ok(mid) {
			hi = mid
		} else {
			lo = mid + 1
		}
	}
	return lo
}
~~~

<!-- file: binarysearch/search_test.go -->
~~~go
package binarysearch

import "testing"

func TestSearch(t *testing.T) {
	nums := []int{-1, 0, 3, 5, 9, 12}
	cases := []struct{ target, want int }{
		{9, 4},
		{2, -1},
		{-1, 0},  // first
		{12, 5},  // last
		{-5, -1}, // smaller than everything
		{13, -1}, // larger than everything
	}
	for _, c := range cases {
		if got := Search(nums, c.target); got != c.want {
			t.Errorf("Search(%v, %d) = %d, want %d", nums, c.target, got, c.want)
		}
	}
	if got := Search(nil, 1); got != -1 {
		t.Errorf("Search(nil, 1) = %d, want -1", got)
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./binarysearch/ && go test ./binarysearch/ -->

<!-- file: binarysearch/search.py -->
~~~python
from collections.abc import Callable


def first_true(n: int, ok: Callable[[int], bool]) -> int:
    """First i in [0, n) with ok(i) true, or n. ok must be false, then true."""
    lo, hi = 0, n
    while lo < hi:
        mid = (lo + hi) // 2
        if ok(mid):
            hi = mid
        else:
            lo = mid + 1
    return lo


def search(nums: list[int], target: int) -> int:
    """Position of target in sorted nums, or -1."""
    i = first_true(len(nums), lambda mid: nums[mid] >= target)
    return i if i < len(nums) and nums[i] == target else -1
~~~

Python's integers don't overflow, so `(lo + hi) // 2` is safe there. Python also has this built in: `bisect.bisect_left(nums, target)` is `first_true` with the condition `nums[mid] >= target`.

<!-- file: binarysearch/test_search.py -->
~~~python
import pytest

from binarysearch.search import search

NUMS = [-1, 0, 3, 5, 9, 12]


@pytest.mark.parametrize(
    ("target", "want"), [(9, 4), (2, -1), (-1, 0), (12, 5), (-5, -1), (13, -1)]
)
def test_search(target, want):
    assert search(NUMS, target) == want


def test_empty():
    assert search([], 1) == -1
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q binarysearch -->

**Complexity:** O(log *n*) time, O(1) space.

## Worked problem 2: Koko Eating Bananas

[LeetCode 875](https://leetcode.com/problems/koko-eating-bananas/). Piles of bananas, and *h* hours. Each hour, Koko eats up to *k* bananas from one pile (if the pile has fewer, she finishes it and waits for the next hour). What's the **smallest** *k* that finishes everything in *h* hours?

| Piles | *h* | Output |
|---|---|---|
| `[3, 6, 7, 11]` | 8 | 4 |
| `[30, 11, 23, 4, 20]` | 5 | 30 |
| `[30, 11, 23, 4, 20]` | 6 | 23 |

**Think first.** There's no sorted array here, but there is a yes/no question with the right shape: *can she finish at speed k?*
- At a slow speed, no. At some speed and every speed above it, yes.
- So binary-search the **speed**, from 1 to the biggest pile (at that speed, each pile takes one hour, the fastest possible).
- Checking one speed costs O(*n*): each pile takes ⌈pile / *k*⌉ hours.
- This is **binary search on the answer**, and it's the version interviews love.

<!-- file: binarysearch/koko.go -->
~~~go
package binarysearch

import "slices"

// MinEatingSpeed returns the smallest bananas-per-hour that finishes every
// pile within h hours. Needs h >= len(piles). O(n log max) time.
func MinEatingSpeed(piles []int, h int) int {
	finishes := func(k int) bool {
		hours := 0
		for _, p := range piles {
			hours += (p + k - 1) / k // ⌈p / k⌉ in integers
		}
		return hours <= h
	}
	maxPile := slices.Max(piles)
	// Speeds 1..maxPile map to positions 0..maxPile-1.
	return 1 + firstTrue(maxPile, func(i int) bool { return finishes(i + 1) })
}
~~~

`(p + k - 1) / k` rounds up without floating point: adding *k* − 1 first pushes any remainder over to the next whole number.

<!-- file: binarysearch/koko_test.go -->
~~~go
package binarysearch

import "testing"

func TestMinEatingSpeed(t *testing.T) {
	cases := []struct {
		piles []int
		h     int
		want  int
	}{
		{[]int{3, 6, 7, 11}, 8, 4},
		{[]int{30, 11, 23, 4, 20}, 5, 30},
		{[]int{30, 11, 23, 4, 20}, 6, 23},
		{[]int{1}, 1, 1},
		{[]int{1000000000}, 2, 500000000},
	}
	for _, c := range cases {
		if got := MinEatingSpeed(c.piles, c.h); got != c.want {
			t.Errorf("MinEatingSpeed(%v, %d) = %d, want %d", c.piles, c.h, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./binarysearch/ && go test ./binarysearch/ -->

<!-- file: binarysearch/koko.py -->
~~~python
from binarysearch.search import first_true


def min_eating_speed(piles: list[int], h: int) -> int:
    """Smallest bananas-per-hour that finishes every pile within h hours."""

    def finishes(k: int) -> bool:
        return sum((p + k - 1) // k for p in piles) <= h

    return 1 + first_true(max(piles), lambda i: finishes(i + 1))
~~~

<!-- file: binarysearch/test_koko.py -->
~~~python
import pytest

from binarysearch.koko import min_eating_speed


@pytest.mark.parametrize(
    ("piles", "h", "want"),
    [
        ([3, 6, 7, 11], 8, 4),
        ([30, 11, 23, 4, 20], 5, 30),
        ([30, 11, 23, 4, 20], 6, 23),
        ([1], 1, 1),
        ([1_000_000_000], 2, 500_000_000),
    ],
)
def test_min_eating_speed(piles, h, want):
    assert min_eating_speed(piles, h) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q binarysearch -->

**Complexity:** O(*n* log *m*) time for *n* piles and the largest pile *m*; O(1) space.

## Pitfalls

- **Infinite loops** come from `lo = mid` with `mid` rounded down. With the template above (`hi = mid`, `lo = mid + 1`), the range always shrinks.
- **The condition must be monotonic**: false, false, ..., true, true. If it can flip back, binary search gives a wrong answer silently.
- **Know what the template returns:** the first true position, which may be *n* ("none"). Check it before indexing.
- **Searching the answer space:** write the check function first, test it on its own, then wrap the search around it.

## Practice

1. **[Search a 2D Matrix](https://leetcode.com/problems/search-a-2d-matrix/)** (medium). Each row sorted, each row's first number bigger than the previous row's last.
   <details><summary>Hint</summary>It's one sorted list of <i>m</i>·<i>n</i> numbers; position <i>i</i> is row <i>i</i> / <i>n</i>, column <i>i</i> % <i>n</i>.</details>
2. **[Find Minimum in Rotated Sorted Array](https://leetcode.com/problems/find-minimum-in-rotated-sorted-array/)** (medium). `[3, 4, 5, 1, 2]` → `1`.
   <details><summary>Hint</summary>The condition: is <code>nums[mid] <= nums[last]</code>? False before the minimum, true from it on.</details>
3. **[Search in Rotated Sorted Array](https://leetcode.com/problems/search-in-rotated-sorted-array/)** (medium). `[4, 5, 6, 7, 0, 1, 2], 0` → `4`.
   <details><summary>Hint</summary>Find the minimum's position first (practice 2), then binary-search the half that can contain the target.</details>
4. **[Time Based Key-Value Store](https://leetcode.com/problems/time-based-key-value-store/)** (medium). `set(key, value, time)`, and `get(key, time)` returns the value set at the latest time ≤ `time`.
   <details><summary>Hint</summary>Times arrive increasing, so each key's list is sorted. <code>get</code> finds the first time > <code>time</code> and steps back one. This is how multi-version databases read "as of" a timestamp.</details>
5. **[Median of Two Sorted Arrays](https://leetcode.com/problems/median-of-two-sorted-arrays/)** (hard). In O(log(*m* + *n*)).
   <details><summary>Hint</summary>Binary-search how many elements to take from the shorter array, so that everything on the left of both cuts is ≤ everything on the right.</details>

Next: [06. Linked lists](../06-linked-lists/README.md).
