# 04. Stack and monotonic stack

<!-- continue: ../03-sliding-window/README.md -->

A stack is last in, first out. It remembers what's still **open**, so the most recent unfinished thing is always on top. A **monotonic** stack keeps its contents in increasing or decreasing order, which answers "what's the next bigger element?" for every position in one pass.

**Recognise it when** the problem asks about:

- matching pairs (brackets, tags), or nesting;
- undo, or "go back to the most recent";
- evaluating an expression;
- the **next** or **previous** greater or smaller element, spans, or how long until something bigger arrives.

**Real systems:** every parser keeps a stack of what's open. Go's `encoding/json`, which Runway has used since [Phase 0](../../lessons/00-request-service/README.md), scans JSON with a stack of open objects and arrays, and that's how it knows a `]` can't close a `{`. Your program's call stack is the same structure; a stack trace is it, printed.

## Worked problem 1: Valid Parentheses

[LeetCode 20](https://leetcode.com/problems/valid-parentheses/). A string of `()[]{}`. Is every bracket closed by the same type, in the right order?

| Input | Output |
|---|---|
| `"()[]{}"` | `true` |
| `"(]"` | `false` |
| `"([)]"` | `false` (closed in the wrong order) |
| `"{[]}"` | `true` |

**Think first.**
- An opening bracket must wait for its match, and the **most recent** unmatched one must close first. That's a stack.
- Push openers. On a closer, the top must be its opener; pop it.
- At the end, the stack must be empty: `"(("` has no wrong closer, but isn't valid.

<!-- file: stack/parentheses.go -->
~~~go
// Package stack holds the stack and monotonic-stack problems.
package stack

// opener maps each closing bracket to the opening one it must match.
var opener = map[byte]byte{')': '(', ']': '[', '}': '{'}

// ValidBrackets reports whether every bracket in s is closed by the same
// kind, in the right order. O(n) time, O(n) space.
func ValidBrackets(s string) bool {
	var open []byte // a slice used as a stack: append pushes, s[:len-1] pops
	for i := 0; i < len(s); i++ {
		c := s[i]
		want, isCloser := opener[c]
		if !isCloser {
			open = append(open, c)
			continue
		}
		if len(open) == 0 || open[len(open)-1] != want {
			return false
		}
		open = open[:len(open)-1]
	}
	return len(open) == 0
}
~~~

<!-- file: stack/parentheses_test.go -->
~~~go
package stack

import "testing"

func TestValidBrackets(t *testing.T) {
	cases := []struct {
		s    string
		want bool
	}{
		{"()[]{}", true},
		{"(]", false},
		{"([)]", false},
		{"{[]}", true},
		{"((", false}, // nothing wrong was closed, but something is left open
		{"))", false}, // a closer with nothing open
		{"", true},
	}
	for _, c := range cases {
		if got := ValidBrackets(c.s); got != c.want {
			t.Errorf("ValidBrackets(%q) = %v, want %v", c.s, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./stack/ && go test ./stack/ -->

<!-- file: stack/parentheses.py -->
~~~python
OPENER = {")": "(", "]": "[", "}": "{"}


def valid_brackets(s: str) -> bool:
    """Every bracket closed by the same kind, in the right order."""
    stack: list[str] = []
    for ch in s:
        if ch not in OPENER:
            stack.append(ch)
        elif not stack or stack.pop() != OPENER[ch]:
            return False
    return not stack
~~~

`stack.pop()` runs only when the stack isn't empty, because `or` stops at the first true operand.

<!-- file: stack/test_parentheses.py -->
~~~python
import pytest

from stack.parentheses import valid_brackets


@pytest.mark.parametrize(
    ("s", "want"),
    [
        ("()[]{}", True),
        ("(]", False),
        ("([)]", False),
        ("{[]}", True),
        ("((", False),
        ("))", False),
        ("", True),
    ],
)
def test_valid_brackets(s, want):
    assert valid_brackets(s) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q stack -->

**Complexity:** O(*n*) time, O(*n*) space.

## Worked problem 2: Daily Temperatures

[LeetCode 739](https://leetcode.com/problems/daily-temperatures/). For each day, how many days until a warmer one? 0 if none comes.

| Input | Output |
|---|---|
| `[73, 74, 75, 71, 69, 72, 76, 73]` | `[1, 1, 4, 2, 1, 1, 0, 0]` |
| `[30, 60, 90]` | `[1, 1, 0]` |

**Think first.**
- **Brute force:** for each day, scan forward until something warmer, O(*n*²) when temperatures fall for a long time.
- **Monotonic stack:** keep the days still **waiting** for a warmer one. Their temperatures can only decrease from bottom to top: a warmer day would already have answered the colder ones below it.
- When a new day arrives, it answers every waiting day colder than it. Pop those and record the gap. Then it waits too.
- Each day is pushed once and popped at most once, so the whole thing is O(*n*).

<!-- file: stack/temperatures.go -->
~~~go
package stack

// DaysUntilWarmer returns, for each day, how many days until a warmer one,
// or 0 if none comes. O(n) time, O(n) space.
func DaysUntilWarmer(temps []int) []int {
	out := make([]int, len(temps))
	var waiting []int // days with no warmer day yet; temperatures decrease upwards
	for day, t := range temps {
		for len(waiting) > 0 && temps[waiting[len(waiting)-1]] < t {
			prev := waiting[len(waiting)-1]
			waiting = waiting[:len(waiting)-1]
			out[prev] = day - prev
		}
		waiting = append(waiting, day)
	}
	return out // days still waiting keep their zero
}
~~~

<!-- file: stack/temperatures_test.go -->
~~~go
package stack

import (
	"slices"
	"testing"
)

func TestDaysUntilWarmer(t *testing.T) {
	cases := []struct {
		temps, want []int
	}{
		{[]int{73, 74, 75, 71, 69, 72, 76, 73}, []int{1, 1, 4, 2, 1, 1, 0, 0}},
		{[]int{30, 60, 90}, []int{1, 1, 0}},
		{[]int{90, 60, 30}, []int{0, 0, 0}},
		{[]int{50, 50, 51}, []int{2, 1, 0}}, // equal isn't warmer
		{nil, []int{}},
	}
	for _, c := range cases {
		if got := DaysUntilWarmer(c.temps); !slices.Equal(got, c.want) {
			t.Errorf("DaysUntilWarmer(%v) = %v, want %v", c.temps, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./stack/ && go test ./stack/ -->

<!-- file: stack/temperatures.py -->
~~~python
def days_until_warmer(temps: list[int]) -> list[int]:
    """For each day, days until a warmer one, or 0 if none comes."""
    out = [0] * len(temps)
    waiting: list[int] = []  # days without a warmer day yet
    for day, t in enumerate(temps):
        while waiting and temps[waiting[-1]] < t:
            prev = waiting.pop()
            out[prev] = day - prev
        waiting.append(day)
    return out
~~~

<!-- file: stack/test_temperatures.py -->
~~~python
import pytest

from stack.temperatures import days_until_warmer


@pytest.mark.parametrize(
    ("temps", "want"),
    [
        ([73, 74, 75, 71, 69, 72, 76, 73], [1, 1, 4, 2, 1, 1, 0, 0]),
        ([30, 60, 90], [1, 1, 0]),
        ([90, 60, 30], [0, 0, 0]),
        ([50, 50, 51], [2, 1, 0]),
        ([], []),
    ],
)
def test_days_until_warmer(temps, want):
    assert days_until_warmer(temps) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q stack -->

**Complexity:** O(*n*) time, O(*n*) space.

## Pitfalls

- **Popping an empty stack.** Check the length first: in Go it panics, in Python it raises.
- **Forgetting the leftovers.** What's still on the stack at the end is part of the answer (unclosed brackets; days with no warmer day).
- **Strict or not.** "Warmer" is `<`, not `<=`. Test equal values.
- **Store positions, not values**, when the answer is a distance.

## Practice

1. **[Min Stack](https://leetcode.com/problems/min-stack/)** (medium). A stack that also returns its minimum in O(1).
   <details><summary>Hint</summary>Push, with each value, the minimum of the stack at that moment.</details>
2. **[Evaluate Reverse Polish Notation](https://leetcode.com/problems/evaluate-reverse-polish-notation/)** (medium). `["2", "1", "+", "3", "*"]` → `9`.
   <details><summary>Hint</summary>Numbers are pushed; an operator pops two (careful with the order for − and /) and pushes the result. Division truncates towards zero.</details>
3. **[Car Fleet](https://leetcode.com/problems/car-fleet/)** (medium). Cars that catch up form a fleet; how many fleets arrive? `target = 12, position = [10, 8, 0, 5, 3], speed = [2, 4, 1, 1, 3]` → `3`.
   <details><summary>Hint</summary>Sort by position, nearest the target first. Compute each car's arrival time; a car arriving no later than the fleet ahead joins it.</details>
4. **[Largest Rectangle in Histogram](https://leetcode.com/problems/largest-rectangle-in-histogram/)** (hard). `[2, 1, 5, 6, 2, 3]` → `10`.
   <details><summary>Hint</summary>An increasing stack of bar positions. When a shorter bar arrives, each popped bar's rectangle ends here and starts just after the bar below it on the stack.</details>

Next: [05. Binary search](../05-binary-search/README.md).
