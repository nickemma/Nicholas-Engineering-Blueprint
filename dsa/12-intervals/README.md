# 12. Intervals

<!-- continue: ../11-shortest-paths/README.md -->

An interval is a start and an end. Two intervals overlap when each starts before the other ends. Almost every interval problem becomes easy after one move: **sort by start**. Then an interval can only overlap the ones just before it, and one pass does the rest.

**Recognise it when** the input is ranges (meetings, bookings, time windows, byte ranges, IP ranges) and the problem asks to merge them, find overlaps or gaps, or count how many happen at once.

**Real systems:**
- **Leases.** [Phase 4's lock leases](../../lessons/04-replicated-state/TEACHING.md#step-10-locks-with-leases-and-fencing-tokens) are time intervals. A lock is safe only if two holders' intervals never overlap, and fencing tokens exist because clocks make the interval ends uncertain.
- **Byte ranges:** HTTP range requests, and the compaction of a log's segments.
- **Incidents:** in [Phase 7's anomaly detection](../../lessons/07-utility-evaluation/TEACHING.md#step-12-finding-incidents-nobody-wrote-a-rule-for), each alert span counts as caught only if it overlaps an incident's interval.

## Worked problem: Merge Intervals

[LeetCode 56](https://leetcode.com/problems/merge-intervals/). Merge every set of overlapping intervals.

| Input | Output |
|---|---|
| `[[1, 3], [2, 6], [8, 10], [15, 18]]` | `[[1, 6], [8, 10], [15, 18]]` |
| `[[1, 4], [4, 5]]` | `[[1, 5]]` (touching counts as overlapping here) |
| `[[1, 4], [2, 3]]` | `[[1, 4]]` (one inside another) |

**Think first.**
- Sort by start. Walk through, keeping the last merged interval.
- If the next one starts at or before that interval's end, they overlap: extend the end to the **larger** of the two ends. That covers `[1, 4], [2, 3]`, where the second ends earlier.
- Otherwise, start a new merged interval.

<!-- file: intervals/merge.go -->
~~~go
// Package intervals holds the interval problems.
package intervals

import (
	"cmp"
	"slices"
)

// Merge merges overlapping (or touching) intervals and returns them sorted
// by start. It doesn't change its input. O(n log n) time, O(n) space.
func Merge(in [][2]int) [][2]int {
	sorted := slices.Clone(in)
	slices.SortFunc(sorted, func(a, b [2]int) int { return cmp.Compare(a[0], b[0]) })
	var out [][2]int
	for _, iv := range sorted {
		if n := len(out); n > 0 && iv[0] <= out[n-1][1] {
			out[n-1][1] = max(out[n-1][1], iv[1]) // overlaps the last: extend it
		} else {
			out = append(out, iv)
		}
	}
	return out
}
~~~

`[2]int` is an array, a value: appending `iv` copies it, so extending `out[n-1]` never changes the caller's intervals.

<!-- file: intervals/merge_test.go -->
~~~go
package intervals

import (
	"reflect"
	"testing"
)

func TestMerge(t *testing.T) {
	cases := []struct {
		name string
		in   [][2]int
		want [][2]int
	}{
		{"example", [][2]int{{1, 3}, {2, 6}, {8, 10}, {15, 18}}, [][2]int{{1, 6}, {8, 10}, {15, 18}}},
		{"touching", [][2]int{{1, 4}, {4, 5}}, [][2]int{{1, 5}}},
		{"one inside another", [][2]int{{1, 4}, {2, 3}}, [][2]int{{1, 4}}},
		{"unsorted", [][2]int{{8, 10}, {1, 3}, {2, 6}}, [][2]int{{1, 6}, {8, 10}}},
		{"one chain", [][2]int{{1, 2}, {2, 3}, {3, 4}}, [][2]int{{1, 4}}},
		{"none", nil, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Merge(c.in); !reflect.DeepEqual(got, c.want) {
				t.Errorf("Merge(%v) = %v, want %v", c.in, got, c.want)
			}
		})
	}
}

func TestMergeLeavesTheInputAlone(t *testing.T) {
	in := [][2]int{{2, 6}, {1, 3}}
	Merge(in)
	if !reflect.DeepEqual(in, [][2]int{{2, 6}, {1, 3}}) {
		t.Errorf("input changed to %v", in)
	}
}
~~~

"One inside another" catches the most common bug: setting the end to the new interval's end instead of the larger one.

<!-- run: test -z "$(gofmt -l .)" && go vet ./intervals/ && go test ./intervals/ -->

<!-- file: intervals/merge.py -->
~~~python
def merge(intervals: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """Merge overlapping or touching intervals; sorted by start."""
    out: list[tuple[int, int]] = []
    for start, end in sorted(intervals):
        if out and start <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], end))
        else:
            out.append((start, end))
    return out
~~~

`sorted` on tuples sorts by the first element, then the second: by start, as needed.

<!-- file: intervals/test_merge.py -->
~~~python
import pytest

from intervals.merge import merge


@pytest.mark.parametrize(
    ("intervals", "want"),
    [
        ([(1, 3), (2, 6), (8, 10), (15, 18)], [(1, 6), (8, 10), (15, 18)]),
        ([(1, 4), (4, 5)], [(1, 5)]),
        ([(1, 4), (2, 3)], [(1, 4)]),
        ([(8, 10), (1, 3), (2, 6)], [(1, 6), (8, 10)]),
        ([(1, 2), (2, 3), (3, 4)], [(1, 4)]),
        ([], []),
    ],
)
def test_merge(intervals, want):
    assert merge(intervals) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q intervals -->

**Complexity:** O(*n* log *n*) time for the sort; O(*n*) space.

## Pitfalls

- **Open or closed ends?** Does `[1, 4]` touch `[4, 5]`? In this problem yes; in a booking system, a meeting ending at 4 and one starting at 4 don't clash. Ask, and test the boundary.
- **The end is the max, not the latest.** An interval can sit entirely inside the previous one.
- **Sort by start, or by end?** Merging sorts by start. "Remove the fewest to make the rest non-overlapping" sorts by **end** (practice 2): it's a greedy choice (guide 17).
- **Counting overlaps at once** (how many rooms?) is a sweep: +1 at each start, −1 at each end, sorted by time.

## Practice

1. **[Insert Interval](https://leetcode.com/problems/insert-interval/)** (medium). Insert into sorted, non-overlapping intervals, merging as needed.
   <details><summary>Hint</summary>Three phases in one pass: those ending before the new one, those overlapping it (merge), those starting after.</details>
2. **[Non-overlapping Intervals](https://leetcode.com/problems/non-overlapping-intervals/)** (medium). The fewest to remove so the rest don't overlap.
   <details><summary>Hint</summary>Sort by end; keep each interval that starts after the last kept one ends. Keeping the earliest-ending leaves the most room.</details>
3. **[Minimum Number of Arrows to Burst Balloons](https://leetcode.com/problems/minimum-number-of-arrows-to-burst-balloons/)** (medium).
   <details><summary>Hint</summary>The same greedy: sort by end, shoot at the end of the first unburst balloon.</details>
4. **[My Calendar I](https://leetcode.com/problems/my-calendar-i/)** (medium). Accept a booking only if it doesn't overlap an earlier accepted one. `[start, end)` is half-open.
   <details><summary>Hint</summary>Two half-open intervals overlap when each starts before the other ends: <code>s1 < e2 && s2 < e1</code>. A sorted structure finds the neighbours in O(log <i>n</i>); a list is fine to start.</details>

Next: [13. Backtracking](../13-backtracking/README.md).
