# 07 Tests

> Module: Go from zero · Time: ~3 h · Builds on: 06

## The problem

So far you've checked your code by running it and reading the output. That works once. It doesn't work on the fiftieth change, at 2 a.m., or when someone else edits your code next year. A **test** is code that runs your code and checks the answer automatically, in a second, every time. Every module from here on, and every gate, rests on tests. In Go they're built in: no extra tools to install.

## The mental model

~~~text
 wordcount/
   wordcount.go         package wordcount       the code
   wordcount_test.go    package wordcount       the tests: same package, so they see everything

 go test ./wordcount ──▶ builds both ──▶ runs every func TestXxx(t *testing.T)
                                          t.Errorf  → this test fails, keeps going
                                          t.Fatalf  → this test fails, stops now
                                          neither   → passes
~~~

## The pattern

**Table-driven tests.** List the cases as rows in a table, each with its inputs and the expected answer, and run them all through the same check. Adding a case is one line, and a failure names the exact row that broke.

## Build it

### Step 1: A package worth testing

This lesson's code is a real package, not a drill: `wordcount`, which counts the words in a text. A **package** is a folder of `.go` files that share a `package` name; other code imports it by its path, `gofromzero/wordcount`. It has no `main`, so you don't run it; you test it.

Create `wordcount/wordcount.go`:

<!-- file: wordcount/wordcount.go -->
~~~go
// Package wordcount counts the words in a text.
package wordcount

import (
	"strings"
)

// Count returns how often each word appears. Words are compared in lower case,
// and punctuation at either end of a word is ignored.
func Count(text string) map[string]int {
	counts := map[string]int{}
	for _, w := range strings.Fields(text) {
		w = strings.ToLower(strings.Trim(w, ".,;:!?\"'()"))
		if w != "" {
			counts[w]++
		}
	}
	return counts
}
~~~

`strings.Trim(w, ".,;...")` removes any of those characters from both ends; `strings.ToLower` lower-cases. A word that was only punctuation, such as `--`, becomes empty and is skipped.

### Step 2: A table-driven test

**Starter.** Create `wordcount/wordcount_test.go` with a test, `TestCount`, that checks `Count` against a table of cases: one word, a repeated word, mixed case, punctuation, an absent word, and empty text. Each row has a name, the text, the word to look up, and the count you want.

~~~go
func TestCount(t *testing.T) {
	tests := []struct {
		name string
		text string
		word string
		want int
	}{
		{"one word", "cat", "cat", 1},
		// TODO: five more rows
	}
	for _, tt := range tests {
		// TODO: run Count and compare, naming the row if it fails
	}
}
~~~

- A test file's name ends in `_test.go`; a test function's name starts with `Test` and takes `t *testing.T`.
- `[]struct{ ... }{ ... }` is a slice of an **anonymous struct**: a struct type used once, right here, with no name.
- `t.Run(name, func(t *testing.T) { ... })` runs one row as a **subtest**, so a failure says which row.

<details>
<summary>Hint</summary>

Inside the loop: `t.Run(tt.name, func(t *testing.T) { got := Count(tt.text)[tt.word]; if got != tt.want { t.Errorf(...) } })`. Make the message say what you called and what you expected.

</details>

<details>
<summary>The answer</summary>

<!-- file: wordcount/wordcount_test.go -->
~~~go
package wordcount

import (
	"testing"
)

func TestCount(t *testing.T) {
	tests := []struct {
		name string
		text string
		word string
		want int
	}{
		{"one word", "cat", "cat", 1},
		{"repeated", "cat cat cat", "cat", 3},
		{"case is ignored", "Cat cat CAT", "cat", 3},
		{"punctuation is ignored", "cat, cat. (cat)", "cat", 3},
		{"absent", "dog", "cat", 0},
		{"empty text", "", "cat", 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Count(tt.text)[tt.word]
			if got != tt.want {
				t.Errorf("Count(%q)[%q] = %d, want %d", tt.text, tt.word, got, tt.want)
			}
		})
	}
}
~~~

</details>

~~~bash
go test ./wordcount
~~~

<!-- run: gofmt -l wordcount | (! grep .) && go vet ./wordcount && go test ./wordcount -->

~~~text
ok  	gofromzero/wordcount	0.003s
~~~

`ok` and nothing else: every test passed. Silence on success is deliberate, so a real failure stands out.

### Step 3: Sorting, and tests that pin down the order

Now the most frequent words. A map has no order (lesson 04), so `Top` copies the counts into a slice and sorts it: most frequent first, and equal counts alphabetically, so the answer never depends on map order. Change the imports in `wordcount.go`:

<!-- edit: wordcount/wordcount.go -->
~~~go
import (
	"strings"
)
~~~

~~~go
import (
	"cmp"
	"slices"
	"strings"
)
~~~

and add at the end of the file:

<!-- append: wordcount/wordcount.go -->
~~~go
// WordCount is one word and how often it appears.
type WordCount struct {
	Word  string
	Count int
}

// Top returns the n most frequent words, most frequent first; equal counts are
// in alphabetical order, so the result never depends on map order.
func Top(counts map[string]int, n int) []WordCount {
	all := make([]WordCount, 0, len(counts))
	for w, c := range counts {
		all = append(all, WordCount{w, c})
	}
	slices.SortFunc(all, func(a, b WordCount) int {
		if a.Count != b.Count {
			return cmp.Compare(b.Count, a.Count)
		}
		return cmp.Compare(a.Word, b.Word)
	})
	return all[:min(n, len(all))]
}
~~~

- `make([]WordCount, 0, len(counts))` makes an empty slice with room for every word, so `append` never has to grow it (lesson 04).
- `slices.SortFunc` sorts with your comparison function, which returns a negative number if `a` comes first, positive if `b` does, and 0 if they're equal. `cmp.Compare(x, y)` does exactly that for numbers and strings. Comparing `b.Count` with `a.Count`, reversed, puts the biggest counts first.
- `min(n, len(all))` stops `all[:n]` from going past the end when there are fewer words than asked for.

Test the order, ties, and asking for too many. Add `slices` to the test file's imports:

<!-- edit: wordcount/wordcount_test.go -->
~~~go
import (
	"testing"
)
~~~

~~~go
import (
	"slices"
	"testing"
)
~~~

<!-- append: wordcount/wordcount_test.go -->
~~~go
func TestTop(t *testing.T) {
	counts := Count("b a c a b a")
	got := Top(counts, 2)
	want := []WordCount{{"a", 3}, {"b", 2}}
	if !slices.Equal(got, want) {
		t.Errorf("Top = %v, want %v", got, want)
	}
}

func TestTopBreaksTiesAlphabetically(t *testing.T) {
	got := Top(Count("pear apple fig"), 3)
	want := []WordCount{{"apple", 1}, {"fig", 1}, {"pear", 1}}
	if !slices.Equal(got, want) {
		t.Errorf("Top = %v, want %v", got, want)
	}
}

func TestTopAsksForMoreThanThereAre(t *testing.T) {
	if got := Top(Count("one"), 5); len(got) != 1 {
		t.Errorf("Top = %v, want one entry", got)
	}
}
~~~

<!-- run: gofmt -l wordcount | (! grep .) && go vet ./wordcount && go test -count=1 ./wordcount -->

`slices.Equal` compares two slices element by element. Run them all, with `-v` (verbose) to see each test and subtest:

~~~bash
go test -v ./wordcount
~~~

~~~text
=== RUN   TestCount
=== RUN   TestCount/one_word
=== RUN   TestCount/repeated
=== RUN   TestCount/case_is_ignored
=== RUN   TestCount/punctuation_is_ignored
=== RUN   TestCount/absent
=== RUN   TestCount/empty_text
--- PASS: TestCount (0.00s)
    --- PASS: TestCount/one_word (0.00s)
    --- PASS: TestCount/repeated (0.00s)
    --- PASS: TestCount/case_is_ignored (0.00s)
    --- PASS: TestCount/punctuation_is_ignored (0.00s)
    --- PASS: TestCount/absent (0.00s)
    --- PASS: TestCount/empty_text (0.00s)
=== RUN   TestTop
--- PASS: TestTop (0.00s)
=== RUN   TestTopBreaksTiesAlphabetically
--- PASS: TestTopBreaksTiesAlphabetically (0.00s)
=== RUN   TestTopAsksForMoreThanThereAre
--- PASS: TestTopAsksForMoreThanThereAre (0.00s)
PASS
ok  	gofromzero/wordcount	0.004s
~~~

### Step 4: Running some tests, and measuring coverage

`-run` takes a pattern and runs only the tests whose names match it:

~~~bash
go test -v -run TestTop ./wordcount
~~~

~~~text
=== RUN   TestTop
--- PASS: TestTop (0.00s)
=== RUN   TestTopBreaksTiesAlphabetically
--- PASS: TestTopBreaksTiesAlphabetically (0.00s)
=== RUN   TestTopAsksForMoreThanThereAre
--- PASS: TestTopAsksForMoreThanThereAre (0.00s)
PASS
ok  	gofromzero/wordcount	0.004s
~~~

`-cover` reports how much of the code the tests ran:

~~~bash
go test -cover ./wordcount
~~~

~~~text
ok  	gofromzero/wordcount	0.004s	coverage: 100.0% of statements
~~~

Every statement ran at least once. That's a useful warning sign when it's low: code no test ever ran is code nobody has checked. When it's high, it says less than it seems: a line can run under a test that checks nothing about it. Coverage tells you what wasn't tested, not what was tested well.

## Break it

Make `Count` case-sensitive by removing `strings.ToLower(` and its closing `)` from the line in `Count`, so it reads `w = strings.Trim(w, ".,;:!?\"'()")`:

~~~text
--- FAIL: TestCount (0.00s)
    --- FAIL: TestCount/case_is_ignored (0.00s)
        wordcount_test.go:26: Count("Cat cat CAT")["cat"] = 1, want 3
FAIL
FAIL	gofromzero/wordcount	0.004s
FAIL
~~~

The failure names the subtest, the line of the test, what was called, what came back and what was wanted. You know exactly what broke without running anything by hand. That's what a good failure message buys you. Put `strings.ToLower` back.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -cover ./...
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... && go test -count=1 ./... -->

That proves `wordcount` does what its tests say, on every run from now on. It doesn't prove the tests ask the right questions: a test is only as good as the cases you thought of. Lesson 10 adds `-race`, which finds a kind of bug no ordinary test can.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `no test files` | The file doesn't end in `_test.go`, or is in another folder | Name it `something_test.go`, next to the code |
| A test function never runs | Its name doesn't start with `Test` and a capital letter, or it has the wrong parameter | `func TestSomething(t *testing.T)` |
| `(cached)` instead of a time | Nothing changed since the last run, so Go reused the result | That's fine; `-count=1` forces a fresh run |
| A test passes alone and fails with others | Tests share some state | Make each test set up its own data |
| `undefined: Count` in the test | The test file's `package` line differs from the code's | Use the same `package wordcount` |
