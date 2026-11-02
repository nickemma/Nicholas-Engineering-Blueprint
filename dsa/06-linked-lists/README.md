# 06. Linked lists

<!-- continue: ../05-binary-search/README.md -->

A linked list is nodes joined by pointers. You can't jump to the *i*-th element, but once you hold a node you can insert or remove next to it in O(1), without moving anything else. Most list problems are about **rewiring pointers in the right order**, without losing the rest of the list.

**Recognise it when** the input is a list of nodes, or the problem needs:

- O(1) removal from the middle of a sequence you're also searching;
- reversing or reordering in place;
- detecting a cycle;
- a sequence that changes order on every access.

**Real systems:** an **LRU cache** (least recently used) is a hash map plus a doubly linked list, and worked problem 2 builds one. [Phase 3's Redis cache](../../lessons/03-durable-auditable-data/TEACHING.md#step-7-redis-cache-aside) evicts with an approximation of LRU when it's full. Go's `container/list` is a doubly linked list, and the Linux kernel's lists are the same structure in C.

## Worked problem 1: Reverse Linked List

[LeetCode 206](https://leetcode.com/problems/reverse-linked-list/). Reverse a singly linked list and return the new head.

| Input | Output |
|---|---|
| `1 → 2 → 3 → 4 → 5` | `5 → 4 → 3 → 2 → 1` |
| `1 → 2` | `2 → 1` |
| (empty) | (empty) |

**Think first.** Walk the list, turning each `Next` pointer around to point backwards.
- The danger is cutting a link before saving where it led: once `cur.Next = prev`, the rest of the list is unreachable.
- So save `next` first.
- Three pointers, `prev`, `cur` and `next`, and the order of the four assignments is the whole problem.

<!-- file: linkedlist/reverse.go -->
~~~go
// Package linkedlist holds the linked-list problems.
package linkedlist

// ListNode is one node of a singly linked list.
type ListNode struct {
	Val  int
	Next *ListNode
}

// Reverse reverses the list in place and returns its new head.
// O(n) time, O(1) space.
func Reverse(head *ListNode) *ListNode {
	var prev *ListNode
	for cur := head; cur != nil; {
		next := cur.Next // save the rest before cutting the link
		cur.Next = prev  // turn this link around
		prev, cur = cur, next
	}
	return prev
}
~~~

The tests build lists from slices and read them back, so each case is one line:

<!-- file: linkedlist/reverse_test.go -->
~~~go
package linkedlist

import (
	"slices"
	"testing"
)

func fromSlice(vals []int) *ListNode {
	var head *ListNode
	for i := len(vals) - 1; i >= 0; i-- {
		head = &ListNode{Val: vals[i], Next: head}
	}
	return head
}

func toSlice(head *ListNode) []int {
	out := []int{}
	for n := head; n != nil; n = n.Next {
		out = append(out, n.Val)
	}
	return out
}

func TestReverse(t *testing.T) {
	cases := []struct{ in, want []int }{
		{[]int{1, 2, 3, 4, 5}, []int{5, 4, 3, 2, 1}},
		{[]int{1, 2}, []int{2, 1}},
		{[]int{7}, []int{7}},
		{[]int{}, []int{}},
	}
	for _, c := range cases {
		if got := toSlice(Reverse(fromSlice(c.in))); !slices.Equal(got, c.want) {
			t.Errorf("Reverse(%v) = %v, want %v", c.in, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./linkedlist/ && go test ./linkedlist/ -->

<!-- file: linkedlist/reverse.py -->
~~~python
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class ListNode:
    val: int
    next: ListNode | None = None


def reverse(head: ListNode | None) -> ListNode | None:
    """Reverse the list in place; return the new head."""
    prev = None
    cur = head
    while cur:
        nxt = cur.next
        cur.next = prev
        prev, cur = cur, nxt
    return prev
~~~

`from __future__ import annotations` lets `ListNode` mention itself in its own type hints.

<!-- file: linkedlist/test_reverse.py -->
~~~python
import pytest

from linkedlist.reverse import ListNode, reverse


def from_list(vals):
    head = None
    for v in reversed(vals):
        head = ListNode(v, head)
    return head


def to_list(head):
    out = []
    while head:
        out.append(head.val)
        head = head.next
    return out


@pytest.mark.parametrize(
    ("vals", "want"),
    [([1, 2, 3, 4, 5], [5, 4, 3, 2, 1]), ([1, 2], [2, 1]), ([7], [7]), ([], [])],
)
def test_reverse(vals, want):
    assert to_list(reverse(from_list(vals))) == want
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q linkedlist -->

**Complexity:** O(*n*) time, O(1) space.

## Worked problem 2: LRU Cache

[LeetCode 146](https://leetcode.com/problems/lru-cache/). A cache with a fixed capacity. `Get(key)` returns the value if present; `Put(key, value)` stores it. When full, `Put` evicts the **least recently used** key. Both must be O(1).

~~~text
capacity 2
put(1, 1)            cache: 1
put(2, 2)            cache: 2, 1          (most recent first)
get(1)    -> 1       cache: 1, 2          (reading counts as a use)
put(3, 3)            cache: 3, 1          (2 was least recent: evicted)
get(2)    -> miss
~~~

**Think first.**
- A map gives O(1) lookup, but no order.
- A list gives order: most recent at the front, least recent at the back. But finding a key in it is O(*n*).
- **Use both:** the map points at list nodes. A doubly linked list then moves a node to the front, or removes the back, in O(1), because each node knows both neighbours.
- A **sentinel** node, a dummy that's always there, closes the list into a ring. The list is never empty, so there are no special cases for the first or last node.

<!-- file: linkedlist/lru.go -->
~~~go
package linkedlist

// LRU is a fixed-capacity cache that evicts the least recently used key.
// A map finds a key's node; a doubly linked list keeps the order of use,
// most recent first. Get and Put are O(1).
type LRU struct {
	capacity int
	nodes    map[int]*entry
	ring     entry // sentinel: ring.next is the most recent, ring.prev the least
}

type entry struct {
	key, val   int
	prev, next *entry
}

// NewLRU returns an empty cache. capacity must be at least 1.
func NewLRU(capacity int) *LRU {
	if capacity < 1 {
		panic("linkedlist: LRU capacity must be at least 1")
	}
	c := &LRU{capacity: capacity, nodes: make(map[int]*entry, capacity)}
	c.ring.next, c.ring.prev = &c.ring, &c.ring
	return c
}

// Get returns the value for key, and marks key as the most recently used.
func (c *LRU) Get(key int) (int, bool) {
	e, ok := c.nodes[key]
	if !ok {
		return 0, false
	}
	c.unlink(e)
	c.pushFront(e)
	return e.val, true
}

// Put stores key's value, evicting the least recently used key if full.
func (c *LRU) Put(key, val int) {
	if e, ok := c.nodes[key]; ok {
		e.val = val
		c.unlink(e)
		c.pushFront(e)
		return
	}
	if len(c.nodes) == c.capacity {
		oldest := c.ring.prev
		c.unlink(oldest)
		delete(c.nodes, oldest.key)
	}
	e := &entry{key: key, val: val}
	c.nodes[key] = e
	c.pushFront(e)
}

func (c *LRU) unlink(e *entry) {
	e.prev.next = e.next
	e.next.prev = e.prev
}

func (c *LRU) pushFront(e *entry) {
	e.prev, e.next = &c.ring, c.ring.next
	c.ring.next.prev = e
	c.ring.next = e
}
~~~

- `oldest.key` is why each entry stores its key: on eviction, the list knows the node but the map needs the key to delete it.
- Go returns `(value, found)` instead of a sentinel like −1, so a stored 0 and a miss look different.

<!-- file: linkedlist/lru_test.go -->
~~~go
package linkedlist

import "testing"

func TestLRUEvictsTheLeastRecentlyUsed(t *testing.T) {
	c := NewLRU(2)
	c.Put(1, 1)
	c.Put(2, 2)
	if v, ok := c.Get(1); !ok || v != 1 {
		t.Fatalf("Get(1) = %d, %v; want 1, true", v, ok)
	}
	c.Put(3, 3) // 2 is now the least recently used
	if _, ok := c.Get(2); ok {
		t.Fatal("2 should have been evicted")
	}
	c.Put(4, 4) // and now 1 is
	if _, ok := c.Get(1); ok {
		t.Fatal("1 should have been evicted")
	}
	for key, want := range map[int]int{3: 3, 4: 4} {
		if v, ok := c.Get(key); !ok || v != want {
			t.Errorf("Get(%d) = %d, %v; want %d, true", key, v, ok, want)
		}
	}
}

func TestUpdatingAKeyCountsAsAUse(t *testing.T) {
	c := NewLRU(2)
	c.Put(1, 1)
	c.Put(2, 2)
	c.Put(1, 10) // updates 1, and makes it the most recent
	c.Put(3, 3)  // so 2 is evicted, not 1
	if v, ok := c.Get(1); !ok || v != 10 {
		t.Errorf("Get(1) = %d, %v; want 10, true", v, ok)
	}
	if _, ok := c.Get(2); ok {
		t.Error("2 should have been evicted")
	}
}

func TestCapacityOne(t *testing.T) {
	c := NewLRU(1)
	c.Put(1, 1)
	c.Put(2, 2)
	if _, ok := c.Get(1); ok {
		t.Error("1 should have been evicted")
	}
	if v, ok := c.Get(2); !ok || v != 2 {
		t.Errorf("Get(2) = %d, %v; want 2, true", v, ok)
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./linkedlist/ && go test ./linkedlist/ -->

<!-- file: linkedlist/lru.py -->
~~~python
from __future__ import annotations


class _Entry:
    __slots__ = ("key", "val", "prev", "next")

    def __init__(self, key: int = 0, val: int = 0) -> None:
        self.key, self.val = key, val
        self.prev: _Entry = self
        self.next: _Entry = self


class LRU:
    """Fixed-capacity cache evicting the least recently used key; O(1) operations."""

    def __init__(self, capacity: int) -> None:
        if capacity < 1:
            raise ValueError("capacity must be at least 1")
        self.capacity = capacity
        self.nodes: dict[int, _Entry] = {}
        self.ring = _Entry()  # sentinel: ring.next is the most recent

    def get(self, key: int) -> int | None:
        e = self.nodes.get(key)
        if e is None:
            return None
        self._unlink(e)
        self._push_front(e)
        return e.val

    def put(self, key: int, val: int) -> None:
        e = self.nodes.get(key)
        if e is not None:
            e.val = val
            self._unlink(e)
            self._push_front(e)
            return
        if len(self.nodes) == self.capacity:
            oldest = self.ring.prev
            self._unlink(oldest)
            del self.nodes[oldest.key]
        e = _Entry(key, val)
        self.nodes[key] = e
        self._push_front(e)

    def _unlink(self, e: _Entry) -> None:
        e.prev.next = e.next
        e.next.prev = e.prev

    def _push_front(self, e: _Entry) -> None:
        e.prev, e.next = self.ring, self.ring.next
        self.ring.next.prev = e
        self.ring.next = e
~~~

- `__slots__` stops each entry carrying a dictionary of attributes, which saves memory when there are millions.
- In real Python code, `collections.OrderedDict` does this for you: `move_to_end(key)` and `popitem(last=False)`. Build it by hand once, so you know what those calls cost.

<!-- file: linkedlist/test_lru.py -->
~~~python
import pytest

from linkedlist.lru import LRU


def test_evicts_the_least_recently_used():
    c = LRU(2)
    c.put(1, 1)
    c.put(2, 2)
    assert c.get(1) == 1
    c.put(3, 3)
    assert c.get(2) is None
    c.put(4, 4)
    assert c.get(1) is None
    assert c.get(3) == 3
    assert c.get(4) == 4


def test_updating_a_key_counts_as_a_use():
    c = LRU(2)
    c.put(1, 1)
    c.put(2, 2)
    c.put(1, 10)
    c.put(3, 3)
    assert c.get(1) == 10
    assert c.get(2) is None


def test_capacity_must_be_positive():
    with pytest.raises(ValueError):
        LRU(0)
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q linkedlist -->

**Complexity:** O(1) time per operation; O(capacity) space.

## Pitfalls

- **Losing the rest of the list.** Save `next` before overwriting a pointer.
- **Special cases for the ends.** A sentinel (dummy) node removes them: the list is never empty.
- **Updating both directions.** In a doubly linked list, every insert and remove touches two pointers on each side. Draw it.
- **Cycles.** A bug that makes a cycle turns a loop to the end into a loop forever. Floyd's two pointers detect it (practice 2).

## Practice

1. **[Merge Two Sorted Lists](https://leetcode.com/problems/merge-two-sorted-lists/)** (easy). `1→2→4` and `1→3→4` → `1→1→2→3→4→4`.
   <details><summary>Hint</summary>A dummy head and a tail pointer; attach the smaller node each time.</details>
2. **[Linked List Cycle](https://leetcode.com/problems/linked-list-cycle/)** (easy). Does the list loop, in O(1) space?
   <details><summary>Hint</summary>A slow pointer moving one step and a fast one moving two. If there's a cycle, they meet.</details>
3. **[Remove Nth Node From End of List](https://leetcode.com/problems/remove-nth-node-from-end-of-list/)** (medium). One pass. `1→2→3→4→5, n = 2` → `1→2→3→5`.
   <details><summary>Hint</summary>Move a lead pointer <i>n</i> steps ahead, then move both until the lead hits the end. Start both at a dummy node, so removing the head isn't a special case.</details>
4. **[Reorder List](https://leetcode.com/problems/reorder-list/)** (medium). `1→2→3→4→5` → `1→5→2→4→3`, in place.
   <details><summary>Hint</summary>Three steps you already know: find the middle (slow and fast pointers), reverse the second half, then merge the two halves alternately.</details>

Next: [07. Trees](../07-trees/README.md).
