# 07. Trees: depth-first and breadth-first

<!-- continue: ../06-linked-lists/README.md -->

A tree is nodes with children and no cycles. Almost every tree problem is one of two walks:

- **Depth-first (DFS):** go down one branch to the bottom before trying the next. It's naturally recursive: solve the problem for the children, then combine their answers at the parent.
- **Breadth-first (BFS):** visit the tree level by level, with a queue.

**Recognise it when:**

- the input is a tree, or a hierarchy (folders, an org chart, nested JSON);
- the answer depends on **paths** from the root, or on **heights** and **depths**: use DFS;
- the answer depends on **levels**, or the **nearest** something: use BFS.

**Real systems:**
- [Phase 3's B-tree indexes](../../lessons/03-durable-auditable-data/TEACHING.md#step-8-background-jobs) are trees whose nodes are disk pages.
- Go's HTTP router, from [Phase 0](../../lessons/00-request-service/TEACHING.md#step-5-a-router-a-greeting-and-input-validation), keeps its routes in a tree.
- [Phase 7's gradient-boosted trees](../../lessons/07-utility-evaluation/TEACHING.md#step-6-gradient-boosted-trees-honestly-compared) make a prediction by walking from the root to a leaf.
- [Phase 6's audit log](../../lessons/06-safe-shared-queries/TEACHING.md#step-10-a-tamper-evident-audit-log) is a Merkle tree, whose root hash covers every leaf.

## Worked problem 1: Maximum Depth of Binary Tree

[LeetCode 104](https://leetcode.com/problems/maximum-depth-of-binary-tree/). The number of nodes on the longest path from the root down to a leaf.

~~~text
    3
   / \
  9   20        depth 3
     /  \
    15   7
~~~

**Think first.** Trust the recursion. If you knew the depths of the left and right subtrees, the answer would be 1 + the larger. An empty tree has depth 0. That's the whole solution; DFS problems usually are, once you state them as "combine the children's answers".

<!-- file: trees/depth.go -->
~~~go
// Package trees holds the binary-tree problems.
package trees

// TreeNode is a node of a binary tree.
type TreeNode struct {
	Val         int
	Left, Right *TreeNode
}

// MaxDepth returns the number of nodes on the longest root-to-leaf path.
// O(n) time; O(h) space for the recursion, where h is the tree's height.
func MaxDepth(root *TreeNode) int {
	if root == nil {
		return 0
	}
	return 1 + max(MaxDepth(root.Left), MaxDepth(root.Right))
}
~~~

The tests build trees with a tiny helper, `node(value, left, right)`, so each tree reads like its drawing:

<!-- file: trees/depth_test.go -->
~~~go
package trees

import "testing"

func node(v int, l, r *TreeNode) *TreeNode { return &TreeNode{Val: v, Left: l, Right: r} }
func leaf(v int) *TreeNode                 { return node(v, nil, nil) }

// example is the tree drawn above.
var example = node(3, leaf(9), node(20, leaf(15), leaf(7)))

func TestMaxDepth(t *testing.T) {
	cases := []struct {
		name string
		root *TreeNode
		want int
	}{
		{"example", example, 3},
		{"empty", nil, 0},
		{"one node", leaf(1), 1},
		{"a chain to the right", node(1, nil, node(2, nil, leaf(3))), 3},
	}
	for _, c := range cases {
		if got := MaxDepth(c.root); got != c.want {
			t.Errorf("%s: MaxDepth = %d, want %d", c.name, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./trees/ && go test ./trees/ -->

<!-- file: trees/depth.py -->
~~~python
from __future__ import annotations

from dataclasses import dataclass


@dataclass
class TreeNode:
    val: int
    left: TreeNode | None = None
    right: TreeNode | None = None


def max_depth(root: TreeNode | None) -> int:
    """Nodes on the longest root-to-leaf path."""
    if root is None:
        return 0
    return 1 + max(max_depth(root.left), max_depth(root.right))
~~~

<!-- file: trees/test_depth.py -->
~~~python
from trees.depth import TreeNode as T
from trees.depth import max_depth

EXAMPLE = T(3, T(9), T(20, T(15), T(7)))


def test_max_depth():
    assert max_depth(EXAMPLE) == 3
    assert max_depth(None) == 0
    assert max_depth(T(1)) == 1
    assert max_depth(T(1, None, T(2, None, T(3)))) == 3
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q trees -->

**Complexity:** O(*n*) time; O(*h*) space for the call stack. *h* is log *n* for a balanced tree, but *n* for a chain, and Python's default recursion limit is 1,000. For very deep trees, use an explicit stack.

## Worked problem 2: Binary Tree Level Order Traversal

[LeetCode 102](https://leetcode.com/problems/binary-tree-level-order-traversal/). The values level by level, left to right. For the tree above: `[[3], [9, 20], [15, 7]]`.

**Think first.** A queue visits nodes in the order they were found, which for a tree is level by level. To know where one level ends:
1. note the queue's length at the start of the level;
2. process exactly that many nodes, adding their children to the back.

<!-- file: trees/levels.go -->
~~~go
package trees

// LevelOrder returns the values of each level, top to bottom, left to right.
// O(n) time; O(w) space for the queue, where w is the widest level.
func LevelOrder(root *TreeNode) [][]int {
	var out [][]int
	if root == nil {
		return out
	}
	queue := []*TreeNode{root}
	for len(queue) > 0 {
		level := make([]int, 0, len(queue))
		for range len(queue) { // exactly the nodes on this level
			n := queue[0]
			queue = queue[1:]
			level = append(level, n.Val)
			if n.Left != nil {
				queue = append(queue, n.Left)
			}
			if n.Right != nil {
				queue = append(queue, n.Right)
			}
		}
		out = append(out, level)
	}
	return out
}
~~~

`for range len(queue)` evaluates `len(queue)` **once**, before the loop starts. That's exactly the level's size, even as children are appended. `queue = queue[1:]` drops the front without copying; the old elements are freed when the slice's backing array is replaced.

<!-- file: trees/levels_test.go -->
~~~go
package trees

import (
	"reflect"
	"testing"
)

func TestLevelOrder(t *testing.T) {
	cases := []struct {
		name string
		root *TreeNode
		want [][]int
	}{
		{"example", example, [][]int{{3}, {9, 20}, {15, 7}}},
		{"empty", nil, nil},
		{"lopsided", node(1, node(2, leaf(4), nil), leaf(3)), [][]int{{1}, {2, 3}, {4}}},
	}
	for _, c := range cases {
		if got := LevelOrder(c.root); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: LevelOrder = %v, want %v", c.name, got, c.want)
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./trees/ && go test ./trees/ -->

In Python, `collections.deque` gives O(1) removal from the front (a list's `pop(0)` is O(*n*)):

<!-- file: trees/levels.py -->
~~~python
from collections import deque

from trees.depth import TreeNode


def level_order(root: TreeNode | None) -> list[list[int]]:
    """Values of each level, top to bottom, left to right."""
    out: list[list[int]] = []
    queue = deque([root] if root else [])
    while queue:
        level = []
        for _ in range(len(queue)):
            n = queue.popleft()
            level.append(n.val)
            if n.left:
                queue.append(n.left)
            if n.right:
                queue.append(n.right)
        out.append(level)
    return out
~~~

<!-- file: trees/test_levels.py -->
~~~python
from trees.depth import TreeNode as T
from trees.levels import level_order


def test_level_order():
    assert level_order(T(3, T(9), T(20, T(15), T(7)))) == [[3], [9, 20], [15, 7]]
    assert level_order(None) == []
    assert level_order(T(1, T(2, T(4)), T(3))) == [[1], [2, 3], [4]]
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q trees -->

**Complexity:** O(*n*) time; O(*w*) space for the widest level, up to *n*/2 in a full tree.

## Pitfalls

- **Forgetting the empty tree.** `nil`/`None` is a valid input; make it the base case.
- **Deep recursion.** A chain of 100,000 nodes overflows Python's stack. Go's stack grows, but uses memory. Know how to switch to an explicit stack.
- **BFS level boundaries.** Snapshot the queue's length before the level starts.
- **Binary *search* trees** add an ordering (left < node < right). Use it: it turns O(*n*) searches into O(*h*). Validating one needs bounds passed down, not just a comparison with the children (practice 3).

## Practice

1. **[Invert Binary Tree](https://leetcode.com/problems/invert-binary-tree/)** (easy). Mirror the tree.
   <details><summary>Hint</summary>Swap the children, then invert each.</details>
2. **[Diameter of Binary Tree](https://leetcode.com/problems/diameter-of-binary-tree/)** (easy). The longest path between any two nodes, in edges.
   <details><summary>Hint</summary>A DFS that returns height, and on the side records left height + right height at every node.</details>
3. **[Validate Binary Search Tree](https://leetcode.com/problems/validate-binary-search-tree/)** (medium).
   <details><summary>Hint</summary>Pass down the allowed range (low, high). Comparing each node only with its children misses a grandchild on the wrong side.</details>
4. **[Lowest Common Ancestor of a BST](https://leetcode.com/problems/lowest-common-ancestor-of-a-binary-search-tree/)** (medium).
   <details><summary>Hint</summary>If both values are smaller, go left; both bigger, go right; otherwise you're there.</details>
5. **[Kth Smallest Element in a BST](https://leetcode.com/problems/kth-smallest-element-in-a-bst/)** (medium).
   <details><summary>Hint</summary>An in-order walk (left, node, right) visits a BST in sorted order; stop at the <i>k</i>-th.</details>
6. **[Serialize and Deserialize Binary Tree](https://leetcode.com/problems/serialize-and-deserialize-binary-tree/)** (hard). Turn a tree into a string and back.
   <details><summary>Hint</summary>A pre-order walk that writes a marker for every missing child is enough to rebuild the exact shape.</details>

Next: [08. Heaps and priority queues](../08-heaps/README.md).
