# 00. Complexity and Big-O

Every pattern in this track is a way to do less work. This first guide gives you the tool for saying how much less: **Big-O notation**, checked by measurement instead of taken on faith. It also sets up the project that every later pattern adds to.

**Real systems:** capacity planning starts here. In [Phase 5](../../lessons/05-constrained-operations/README.md), you'll ask whether a design survives ten times the load; Big-O tells you which part breaks first.

## Set up the project

Make a new repository of your own (not inside this one), called `dsa`. It holds one Go module and one Python project. Each pattern gets a folder, used as both a Go package and a Python package.

<!-- file: go.mod -->
~~~text
module dsa

go 1.26
~~~

Create the Python project. `uv python pin` records the Python version, as in the [Python Bridge](../../lessons/python-bridge/README.md).

<!-- run: uv init --bare --name dsa --python 3.12 && uv python pin 3.12 -->

~~~bash
uv init --bare --name dsa --python 3.12
uv python pin 3.12
~~~

Then make `pyproject.toml` match this:

<!-- file: pyproject.toml -->
~~~toml
[project]
name = "dsa"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = []

[dependency-groups]
dev = [
    "pytest>=8",
    "ruff>=0.8",
]

[tool.pytest.ini_options]
addopts = "--import-mode=importlib"
pythonpath = ["."]

[tool.ruff]
line-length = 100

[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP"]
~~~

- `pythonpath = ["."]` lets a test import `complexity.duplicates` from the project root.
- `--import-mode=importlib` lets two folders each have a test file with the same name.

<!-- file: .gitignore -->
~~~text
.venv/
__pycache__/
.ruff_cache/
.pytest_cache/
~~~

## What Big-O says

Big-O describes how the work grows as the input grows, ignoring constant factors. Write *n* for the input's size.

| Class | Name | Doubling *n* does this to the time | Fine up to roughly |
|---|---|---|---|
| O(1) | constant | nothing | any *n* |
| O(log *n*) | logarithmic | adds one step | any *n* |
| O(*n*) | linear | doubles it | 10⁸ |
| O(*n* log *n*) | linearithmic | a bit more than doubles it | 10⁷ |
| O(*n*²) | quadratic | quadruples it | 10⁴ |
| O(2ⁿ) | exponential | squares it | 25 |

The last column assumes about 10⁸ simple operations a second. It's a rule of thumb, not a law, but it answers the question you'll ask in every interview: *with these constraints, which complexity do I need?* If *n* can be 10⁵, an O(*n*²) answer does about 10¹⁰ steps, which is too slow, so look for O(*n* log *n*) or better.

Three rules turn code into a class:

1. **Drop constants.** Two passes over the input are O(2*n*), which is O(*n*).
2. **Keep the dominant term.** O(*n*² + *n*) is O(*n*²).
3. **Different inputs get different letters.** A loop over *a* inside a loop over *b* is O(*a*·*b*), not O(*n*²).

**Space** complexity counts the extra memory used, not counting the input. Say both, every time.

## One question, three answers

Does a list contain the same number twice? Here are three ways to answer, from slowest to fastest:

- **Compare every pair:** O(*n*²) time, O(1) space.
- **Sort, then compare neighbours:** O(*n* log *n*) time, and O(*n*) space for the copy.
- **Remember what you've seen in a set:** O(*n*) time, O(*n*) space.

<!-- file: complexity/duplicates.go -->
~~~go
// Package complexity answers one question three ways, so their growth can
// be measured instead of guessed.
package complexity

import "slices"

// HasDuplicateBrute compares every pair: O(n²) time, O(1) extra space.
func HasDuplicateBrute(nums []int) bool {
	for i := 0; i < len(nums); i++ {
		for j := i + 1; j < len(nums); j++ {
			if nums[i] == nums[j] {
				return true
			}
		}
	}
	return false
}

// HasDuplicateSorted sorts a copy, then compares neighbours: O(n log n)
// time, O(n) extra space for the copy. Sorting the caller's slice in place
// would save the space, but surprise the caller.
func HasDuplicateSorted(nums []int) bool {
	sorted := slices.Clone(nums)
	slices.Sort(sorted)
	for i := 1; i < len(sorted); i++ {
		if sorted[i] == sorted[i-1] {
			return true
		}
	}
	return false
}

// HasDuplicateSet remembers what it has seen: O(n) time, O(n) space.
func HasDuplicateSet(nums []int) bool {
	seen := make(map[int]struct{}, len(nums))
	for _, n := range nums {
		if _, ok := seen[n]; ok {
			return true
		}
		seen[n] = struct{}{}
	}
	return false
}
~~~

- `map[int]struct{}` is Go's set: `struct{}` takes no memory, so only the keys count.
- `slices.Clone` and `slices.Sort` are in the standard library's `slices` package.

The test runs every implementation against the same cases. That's how you know the fast ones are also right. The benchmark measures each one on inputs of 1,000 to 8,000 numbers, all different. That's the worst case, because no early return ever happens.

<!-- file: complexity/duplicates_test.go -->
~~~go
package complexity

import (
	"fmt"
	"math/rand/v2"
	"testing"
)

var impls = []struct {
	name string
	f    func([]int) bool
}{
	{"brute", HasDuplicateBrute},
	{"sorted", HasDuplicateSorted},
	{"set", HasDuplicateSet},
}

func TestHasDuplicate(t *testing.T) {
	cases := []struct {
		name string
		nums []int
		want bool
	}{
		{"empty", nil, false},
		{"one", []int{7}, false},
		{"distinct", []int{3, 1, 2}, false},
		{"adjacent", []int{1, 1, 2}, true},
		{"far apart", []int{5, 2, 9, 4, 5}, true},
		{"negative", []int{-1, 0, -1}, true},
	}
	for _, impl := range impls {
		for _, c := range cases {
			t.Run(impl.name+"/"+c.name, func(t *testing.T) {
				if got := impl.f(c.nums); got != c.want {
					t.Errorf("%s(%v) = %v, want %v", impl.name, c.nums, got, c.want)
				}
			})
		}
	}
}

func TestDoesNotReorderTheInput(t *testing.T) {
	nums := []int{3, 1, 2}
	HasDuplicateSorted(nums)
	if nums[0] != 3 || nums[1] != 1 || nums[2] != 2 {
		t.Errorf("input changed to %v", nums)
	}
}

func BenchmarkHasDuplicate(b *testing.B) {
	rng := rand.New(rand.NewPCG(1, 2)) // a fixed seed: the same input every run
	for _, impl := range impls {
		for _, n := range []int{1000, 2000, 4000, 8000} {
			nums := rng.Perm(n) // n different numbers, shuffled: the worst case
			b.Run(fmt.Sprintf("%s/n=%d", impl.name, n), func(b *testing.B) {
				for b.Loop() {
					impl.f(nums)
				}
			})
		}
	}
}
~~~

- `rng.Perm(n)` returns the numbers 0 to *n*−1 in a random order. Already-sorted input would flatter the sorting version.
- `b.Loop()` runs the body as many times as the benchmark needs for a stable time.

Run the tests:

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test ./complexity/ -->

~~~bash
go test ./complexity/
~~~

Then the benchmark. `-run '^$'` skips the tests, and `-benchtime 200x` runs each case 200 times:

<!-- run: go test -run '^$' -bench . -benchtime 200x ./complexity/ > /dev/null -->

~~~bash
go test -run '^$' -bench . -benchtime 200x ./complexity/
~~~

On one laptop (an 8-core Ryzen 7 5850U) it printed this. Your numbers will differ; the **ratios** are what matter:

~~~text
BenchmarkHasDuplicate/brute/n=1000-16         	     200	    153381 ns/op
BenchmarkHasDuplicate/brute/n=2000-16         	     200	    585075 ns/op
BenchmarkHasDuplicate/brute/n=4000-16         	     200	   2323773 ns/op
BenchmarkHasDuplicate/brute/n=8000-16         	     200	   9134870 ns/op
BenchmarkHasDuplicate/sorted/n=1000-16        	     200	     17462 ns/op
BenchmarkHasDuplicate/sorted/n=2000-16        	     200	     36063 ns/op
BenchmarkHasDuplicate/sorted/n=4000-16        	     200	    155696 ns/op
BenchmarkHasDuplicate/sorted/n=8000-16        	     200	    369422 ns/op
BenchmarkHasDuplicate/set/n=1000-16           	     200	     33853 ns/op
BenchmarkHasDuplicate/set/n=2000-16           	     200	     60650 ns/op
BenchmarkHasDuplicate/set/n=4000-16           	     200	    129004 ns/op
BenchmarkHasDuplicate/set/n=8000-16           	     200	    261260 ns/op
~~~

Read it as a **doubling experiment**:
- Each time *n* doubles, the brute force takes about **4×** as long: 0.15, 0.59, 2.3, 9.1 milliseconds. That's O(*n*²).
- The set takes about **2×**, which is O(*n*).
- At 8,000 numbers, the brute force is already 35 times slower than the set. At a million, it would be thousands of times slower.

When you're unsure of a complexity, this is how to check it: double *n* and watch the ratio.

**But look at the sorting version.** It's O(*n* log *n*), worse than the set's O(*n*), and yet it's **faster** at every size here. Big-O ignores constant factors, and they're not small. Each set operation hashes a number, probes a table, and sometimes grows it. Each sorting step compares two numbers that sit next to each other in memory.

Does the set win once *n* is large enough? The same laptop, at bigger sizes:

| *n* | sorted | set |
|---|---|---|
| 8,000 | 0.42 ms | 0.44 ms |
| 64,000 | 4.5 ms | 3.7 ms |
| 512,000 | 41 ms | 76 ms |
| 4,096,000 | 377 ms | 877 ms |

It doesn't. From 64,000 numbers up, the set falls further behind, and it grows **faster than linearly**: 512 times the input took 2,000 times as long. The most likely reason is the CPU's caches.
- Sorting walks memory in order, which the caches and prefetcher handle well.
- A large map scatters its entries, so once it's bigger than the caches, each lookup waits for main memory.

Big-O counts steps, but it doesn't say that all steps cost the same.

So use Big-O to rule designs out: O(*n*²) at a million is hopeless, whatever the constants. Then measure to choose between the ones that are left. That's the same habit as [Phase 7's](../../lessons/07-utility-evaluation/README.md) experiments, at a smaller scale.

## The same in Python

<!-- file: complexity/duplicates.py -->
~~~python
"""One question, three answers: does a list contain a value twice?"""


def has_duplicate_brute(nums: list[int]) -> bool:
    """Compare every pair: O(n^2) time, O(1) extra space."""
    for i in range(len(nums)):
        for j in range(i + 1, len(nums)):
            if nums[i] == nums[j]:
                return True
    return False


def has_duplicate_sorted(nums: list[int]) -> bool:
    """Sort a copy, compare neighbours: O(n log n) time, O(n) space."""
    ordered = sorted(nums)
    return any(a == b for a, b in zip(ordered, ordered[1:], strict=False))


def has_duplicate_set(nums: list[int]) -> bool:
    """Remember what has been seen: O(n) time, O(n) space."""
    seen: set[int] = set()
    for n in nums:
        if n in seen:
            return True
        seen.add(n)
    return False
~~~

- `sorted(nums)` returns a new list; `nums.sort()` would reorder the caller's.
- `zip(ordered, ordered[1:])` pairs each element with the next one.

<!-- file: complexity/test_duplicates.py -->
~~~python
import pytest

from complexity.duplicates import has_duplicate_brute, has_duplicate_set, has_duplicate_sorted

CASES = [
    ([], False),
    ([7], False),
    ([3, 1, 2], False),
    ([1, 1, 2], True),
    ([5, 2, 9, 4, 5], True),
    ([-1, 0, -1], True),
]


@pytest.mark.parametrize("impl", [has_duplicate_brute, has_duplicate_sorted, has_duplicate_set])
@pytest.mark.parametrize(("nums", "want"), CASES)
def test_has_duplicate(impl, nums, want):
    assert impl(nums) == want
~~~

`@pytest.mark.parametrize` twice runs every implementation against every case: 3 × 6 = 18 tests.

<!-- run: uv sync && uv run ruff format --check . && uv run ruff check . && uv run pytest -q complexity -->

~~~bash
uv sync
uv run ruff format --check . && uv run ruff check . && uv run pytest -q complexity
~~~

## Pitfalls

- **Hidden loops.** `x in some_list` in Python and `slices.Contains` in Go are O(*n*). Inside a loop, they make O(*n*²).
- **Copies cost.** Slicing a Python list (`nums[1:]`) copies it: O(*n*) time and space.
- **Amortised isn't worst case.** Appending to a Go slice or a Python list is O(1) *on average*, because the backing array doubles when it fills; one append in a while copies everything.
- **Hash maps aren't magic.** O(1) on average, but hashing a long string costs its length, a bad hash puts everything in one bucket, and a map bigger than the CPU's caches pays for a memory access on almost every lookup.

## Practice: what's the complexity?

Say the time and space complexity of each, out loud, before opening the answer.

1. A loop over *n* items that, for each one, does a binary search in a sorted list of *m* items.
   <details><summary>Answer</summary>O(<i>n</i> log <i>m</i>) time, O(1) space.</details>
2. Building every substring of a string of length *n*, and putting each in a set.
   <details><summary>Answer</summary>There are O(<i>n</i>²) substrings, each up to <i>n</i> long to copy and hash: O(<i>n</i>³) time, O(<i>n</i>³) space in the worst case.</details>
3. A recursive function that calls itself twice on *n* − 1, with no memory of earlier answers.
   <details><summary>Answer</summary>O(2<sup><i>n</i></sup>) time; O(<i>n</i>) space for the call stack.</details>
4. Halving *n* until it reaches 1, doing O(1) work each time.
   <details><summary>Answer</summary>O(log <i>n</i>) time, O(1) space.</details>
5. Sorting *n* strings, each of length *k*.
   <details><summary>Answer</summary>O(<i>n</i> log <i>n</i>) comparisons, each up to O(<i>k</i>): O(<i>k</i>·<i>n</i> log <i>n</i>) time.</details>

Next: [01. Arrays and hashing](../01-arrays-hashing/README.md).
