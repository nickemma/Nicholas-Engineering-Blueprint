# 16. Tries

<!-- continue: ../15-dp-2d/README.md -->

A trie (said "try", from re**trie**val) stores strings character by character down a tree. Words that share a prefix share a path. So "every word starting with *pre*" is one walk down three edges plus whatever's below, however many words there are. Looking up a word of length *k* costs O(*k*), independent of how many words are stored.

**Recognise it when** the problem involves:

- **prefixes:** autocomplete, "starts with", the longest common prefix;
- many words checked against one text (word search, spell-checking);
- the **longest prefix** that matches (routing tables).

**Real systems:**
- **Go's HTTP router.** It matches a request's path against its patterns segment by segment through a tree, which is how the `/greet` route found its handler in [Phase 0](../../lessons/00-request-service/TEACHING.md#step-5-a-router-a-greeting-and-input-validation).
- **IP routing.** Every router does **longest-prefix match** on addresses, usually with a compressed trie: `10.0.0.0/8` and `10.1.0.0/16` share a path, and the deeper match wins.
- **Key-value stores** use prefix trees for range scans, and Ethereum's state is a Merkle-Patricia trie.

## Worked problem: Implement Trie

[LeetCode 208](https://leetcode.com/problems/implement-trie-prefix-tree/). Build a trie of lowercase words with `Insert(word)`, `Search(word)` (is this exact word stored?) and `StartsWith(prefix)` (is any stored word prefixed by this?).

~~~text
insert("apple")
search("apple")    -> true
search("app")      -> false   ("app" is a path, but no word ends there)
startsWith("app")  -> true
insert("app")
search("app")      -> true
~~~

**Think first.**
- Each node has up to 26 children, one per letter, and a flag: **does a word end here?**
- The flag is what separates `Search` from `StartsWith`. Without it, inserting "apple" would make "app" look like a word.
- Both operations walk the same path; they differ only in what they check at the end.

<!-- file: tries/trie.go -->
~~~go
// Package tries holds the trie problems.
package tries

// Trie stores lowercase words (a–z) for exact and prefix lookups.
type Trie struct {
	root node
}

type node struct {
	children [26]*node
	end      bool // a word ends at this node
}

// Insert adds word. O(k) for a word of length k.
func (t *Trie) Insert(word string) {
	n := &t.root
	for i := 0; i < len(word); i++ {
		c := word[i] - 'a'
		if n.children[c] == nil {
			n.children[c] = &node{}
		}
		n = n.children[c]
	}
	n.end = true
}

// Search reports whether word itself was inserted.
func (t *Trie) Search(word string) bool {
	n := t.walk(word)
	return n != nil && n.end
}

// StartsWith reports whether any inserted word starts with prefix.
func (t *Trie) StartsWith(prefix string) bool {
	return t.walk(prefix) != nil
}

// walk follows s from the root and returns the node it ends at, or nil if
// the path stops early.
func (t *Trie) walk(s string) *node {
	n := &t.root
	for i := 0; i < len(s) && n != nil; i++ {
		n = n.children[s[i]-'a']
	}
	return n
}
~~~

- A zero-value `Trie` is ready to use: its root is an empty node. That's Go's "make the zero value useful" idiom.
- `[26]*node` costs 208 bytes per node on a 64-bit machine. For a large or non-English alphabet, a `map[rune]*node` is smaller, but slower.

<!-- file: tries/trie_test.go -->
~~~go
package tries

import "testing"

func TestTrie(t *testing.T) {
	var tr Trie
	tr.Insert("apple")
	checks := []struct {
		name string
		got  bool
		want bool
	}{
		{`Search("apple")`, tr.Search("apple"), true},
		{`Search("app")`, tr.Search("app"), false}, // a path, but not a word
		{`StartsWith("app")`, tr.StartsWith("app"), true},
		{`StartsWith("apples")`, tr.StartsWith("apples"), false},
		{`Search("b")`, tr.Search("b"), false},
		{`StartsWith("")`, tr.StartsWith(""), true}, // every word starts with ""
	}
	for _, c := range checks {
		if c.got != c.want {
			t.Errorf("%s = %v, want %v", c.name, c.got, c.want)
		}
	}
	tr.Insert("app")
	if !tr.Search("app") {
		t.Error(`after Insert("app"), Search("app") = false`)
	}
	if !tr.Search("apple") {
		t.Error(`inserting "app" must not remove "apple"`)
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./tries/ && go test ./tries/ -->

<!-- file: tries/trie.py -->
~~~python
from __future__ import annotations


class _Node:
    __slots__ = ("children", "end")

    def __init__(self) -> None:
        self.children: dict[str, _Node] = {}
        self.end = False


class Trie:
    """Words stored character by character, for exact and prefix lookups."""

    def __init__(self) -> None:
        self.root = _Node()

    def insert(self, word: str) -> None:
        n = self.root
        for ch in word:
            n = n.children.setdefault(ch, _Node())
        n.end = True

    def search(self, word: str) -> bool:
        n = self._walk(word)
        return n is not None and n.end

    def starts_with(self, prefix: str) -> bool:
        return self._walk(prefix) is not None

    def _walk(self, s: str) -> _Node | None:
        n: _Node | None = self.root
        for ch in s:
            if n is None:
                return None
            n = n.children.get(ch)
        return n
~~~

<!-- file: tries/test_trie.py -->
~~~python
from tries.trie import Trie


def test_trie():
    t = Trie()
    t.insert("apple")
    assert t.search("apple")
    assert not t.search("app")
    assert t.starts_with("app")
    assert not t.starts_with("apples")
    assert not t.search("b")
    assert t.starts_with("")
    t.insert("app")
    assert t.search("app")
    assert t.search("apple")
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q tries -->

**Complexity:** O(*k*) per operation for a word of length *k*; O(total characters) space in the worst case, less when prefixes are shared.

## Pitfalls

- **No end-of-word flag**, so every prefix of a stored word looks stored.
- **Assuming the alphabet.** `c - 'a'` breaks on capitals and digits. Ask, or use a map.
- **Memory.** A trie of random strings shares little and uses far more memory than a hash set. Use it when prefixes matter.
- **Deleting** must remove the flag and then prune nodes that no longer lead to any word, bottom up.

## Practice

1. **[Design Add and Search Words](https://leetcode.com/problems/design-add-and-search-words-data-structure/)** (medium). Search where `.` matches any letter.
   <details><summary>Hint</summary>A trie; on <code>.</code>, try every child recursively.</details>
2. **[Replace Words](https://leetcode.com/problems/replace-words/)** (medium). Replace each word in a sentence by its shortest root from a dictionary.
   <details><summary>Hint</summary>Insert the roots; for each word, walk until the first node with the end flag.</details>
3. **[Word Search II](https://leetcode.com/problems/word-search-ii/)** (hard). Find every dictionary word in a letter grid.
   <details><summary>Hint</summary>Put the words in a trie and run guide 13's grid backtracking once, walking the trie as you walk the grid. Prune trie branches once their words are found.</details>

Next: [17. Greedy](../17-greedy/README.md).
