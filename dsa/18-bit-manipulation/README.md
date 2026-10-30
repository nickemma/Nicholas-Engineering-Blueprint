# 18. Bit manipulation

<!-- continue: ../17-greedy/README.md -->

An integer is a row of bits, and a few operators work on all of them at once:

| Operator | Go / Python | Does | Use |
|---|---|---|---|
| AND | `a & b` | 1 where both are 1 | test or clear bits (masks) |
| OR | `a \| b` | 1 where either is 1 | set bits |
| XOR | `a ^ b` | 1 where they differ | toggle bits; `x ^ x = 0`, `x ^ 0 = x` |
| shift | `a << k`, `a >> k` | move bits left or right | multiply or divide by 2ᵏ; build masks |
| AND NOT | `a &^ b` (Go) | clear the bits of `b` in `a` | |

Three facts solve most interview problems:

- **`x & (x − 1)` clears the lowest set bit.** Subtracting 1 turns the lowest 1 into 0 and every 0 below it into 1, and the AND removes them all.
- **XOR cancels pairs.** XOR everything together, and anything that appears twice vanishes.
- **`x & (1 << k)` tests bit *k*.**

**Recognise it when:**

- the problem says "without extra memory" and involves duplicates (XOR);
- it counts bits, or deals in powers of two;
- it's about sets of small integers: a 64-bit word is a set of up to 64 items;
- it involves flags or permissions.

**Real systems:**
- **Checksums.** The CRC-32C you wrote in the [Rust Bridge](../../lessons/rust-bridge/TEACHING.md#step-4-bytes-and-a-record-format) is nothing but shifts and XORs, one bit at a time.
- **Permissions:** Unix file modes (`0644`) are bit flags.
- **Bloom filters** set and test bits.
- **Network masks:** a `/24` subnet is `address & 0xFFFFFF00`, which is how [Phase 6](../../lessons/06-safe-shared-queries/README.md)'s privacy step truncates IPv4 addresses to their `/24`.

## Worked problem 1: Number of 1 Bits

[LeetCode 191](https://leetcode.com/problems/number-of-1-bits/). How many bits are set in a 32-bit unsigned integer? (This count is called the **population count**, or Hamming weight.)

| Input (binary) | Output |
|---|---|
| `1011` (11) | 3 |
| `10000000` (128) | 1 |

**Think first.** Checking all 32 bits works. Brian Kernighan's trick is better: `n & (n − 1)` removes one set bit at a time, so the loop runs once per **set** bit, not once per bit.

<!-- file: bits/ones.go -->
~~~go
// Package bits holds the bit-manipulation problems.
package bits

// OnesCount returns the number of set bits in n. The loop runs once per
// set bit (Kernighan's trick).
func OnesCount(n uint32) int {
	count := 0
	for n != 0 {
		n &= n - 1 // clear the lowest set bit
		count++
	}
	return count
}
~~~

In real Go code, use `math/bits.OnesCount32`. It compiles to a single CPU instruction (`POPCNT`) on most processors. The test checks this version against it:

<!-- file: bits/ones_test.go -->
~~~go
package bits

import (
	mathbits "math/bits"
	"testing"
)

func TestOnesCount(t *testing.T) {
	for _, n := range []uint32{0, 1, 11, 128, 0xFFFFFFFF, 0x80000000, 0xAAAAAAAA} {
		if got, want := OnesCount(n), mathbits.OnesCount32(n); got != want {
			t.Errorf("OnesCount(%#x) = %d, want %d", n, got, want)
		}
	}
}
~~~

`mathbits "math/bits"` imports the standard package under another name, because this package is also called `bits`.

<!-- run: test -z "$(gofmt -l .)" && go vet ./bits/ && go test ./bits/ -->

<!-- file: bits/ones.py -->
~~~python
def ones_count(n: int) -> int:
    """Number of set bits in a non-negative integer (Kernighan's trick)."""
    if n < 0:
        raise ValueError("n must be non-negative")
    count = 0
    while n:
        n &= n - 1
        count += 1
    return count
~~~

Python integers have no fixed width and negative numbers behave as if they had infinitely many leading 1s, so `n & (n − 1)` would never reach 0 for a negative *n*. Hence the check. Python 3.10+ also has `n.bit_count()`.

<!-- file: bits/test_ones.py -->
~~~python
import pytest

from bits.ones import ones_count


@pytest.mark.parametrize("n", [0, 1, 11, 128, 0xFFFFFFFF, 0x80000000, 0xAAAAAAAA])
def test_ones_count(n):
    assert ones_count(n) == n.bit_count()


def test_negative_is_rejected():
    with pytest.raises(ValueError):
        ones_count(-1)
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q bits -->

**Complexity:** O(*k*) for *k* set bits, at most 32; O(1) space.

## Worked problem 2: Single Number

[LeetCode 136](https://leetcode.com/problems/single-number/). Every value appears twice except one. Find it, in O(*n*) time and O(1) extra space.

| Input | Output |
|---|---|
| `[2, 2, 1]` | 1 |
| `[4, 1, 2, 1, 2]` | 4 |

**Think first.**
- A set would work, but it uses O(*n*) space.
- XOR everything together. XOR is commutative and associative, so the order doesn't matter, and each pair cancels (`x ^ x = 0`).
- What's left is the single value (`0 ^ x = x`).

<!-- file: bits/single.go -->
~~~go
package bits

// SingleNumber returns the one value in nums that doesn't appear twice.
// O(n) time, O(1) space.
func SingleNumber(nums []int) int {
	x := 0
	for _, n := range nums {
		x ^= n // pairs cancel: a ^ a = 0
	}
	return x
}
~~~

<!-- file: bits/single_test.go -->
~~~go
package bits

import "testing"

func TestSingleNumber(t *testing.T) {
	cases := []struct {
		nums []int
		want int
	}{
		{[]int{2, 2, 1}, 1},
		{[]int{4, 1, 2, 1, 2}, 4},
		{[]int{1}, 1},
		{[]int{-3, 7, 7}, -3}, // negatives work: XOR is on the bits
	}
	for _, c := range cases {
		if got := SingleNumber(c.nums); got != c.want {
			t.Errorf("SingleNumber(%v) = %d, want %d", c.nums, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./bits/ && go test ./bits/ -->

<!-- file: bits/single.py -->
~~~python
from functools import reduce
from operator import xor


def single_number(nums: list[int]) -> int:
    """The one value that doesn't appear twice."""
    return reduce(xor, nums, 0)
~~~

`reduce(xor, nums, 0)` folds the list with `^`, starting from 0: the same loop, in one line.

<!-- file: bits/test_single.py -->
~~~python
import pytest

from bits.single import single_number


@pytest.mark.parametrize(
    ("nums", "want"), [([2, 2, 1], 1), ([4, 1, 2, 1, 2], 4), ([1], 1), ([-3, 7, 7], -3)]
)
def test_single_number(nums, want):
    assert single_number(nums) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q bits -->

**Complexity:** O(*n*) time, O(1) space.

## Pitfalls

- **Precedence.** In Go, `&` binds tighter than `==`, but in Python (and C) comparisons bind tighter than `&` and `^`: write `(x & 1) == 1` with brackets in both.
- **Signed shifts.** Shifting a negative signed integer right copies the sign bit. Use unsigned types when you mean bits.
- **Python's unbounded integers.** There's no overflow to 32 bits; mask with `& 0xFFFFFFFF` when a problem expects it.
- **Clever isn't always clear.** In production, `bits.OnesCount` and a named constant beat a trick nobody can read.

## Practice

1. **[Counting Bits](https://leetcode.com/problems/counting-bits/)** (easy). The number of 1 bits for every number from 0 to *n*, in O(*n*).
   <details><summary>Hint</summary><code>count[i] = count[i >> 1] + (i & 1)</code>: a small DP over bits.</details>
2. **[Missing Number](https://leetcode.com/problems/missing-number/)** (easy). The one number missing from 0..*n*.
   <details><summary>Hint</summary>XOR all the indexes and all the values together; everything present cancels.</details>

Next: [19. Design problems](../19-design/README.md).
