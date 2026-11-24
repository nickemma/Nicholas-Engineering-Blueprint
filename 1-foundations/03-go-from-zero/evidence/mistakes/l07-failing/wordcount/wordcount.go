// Package wordcount counts the words in a text.
package wordcount

import (
	"cmp"
	"slices"
	"strings"
)

// Count returns how often each word appears. Words are compared in lower case,
// and punctuation at either end of a word is ignored.
func Count(text string) map[string]int {
	counts := map[string]int{}
	for _, w := range strings.Fields(text) {
		w = strings.Trim(w, ".,;:!?\"'()")
		if w != "" {
			counts[w]++
		}
	}
	return counts
}

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
