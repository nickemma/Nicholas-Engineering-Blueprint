// Command loganalyse reads a log of JSON lines and reports what it holds.
//
//	loganalyse [-workers N] FILE
package main

import (
	"bufio"
	"flag"
	"fmt"
	"maps"
	"os"
	"runtime"
	"slices"
	"sync"

	"gofromzero/logs"
)

// numbered is one line of the file, with its line number.
type numbered struct {
	n    int
	text string
}

func main() {
	workers := flag.Int("workers", runtime.NumCPU(), "how many goroutines parse lines")
	flag.Parse()
	if flag.NArg() != 1 || *workers < 1 {
		fmt.Fprintln(os.Stderr, "usage: loganalyse [-workers N] FILE")
		os.Exit(2)
	}
	stats, err := analyse(flag.Arg(0), *workers)
	if err != nil {
		fmt.Fprintln(os.Stderr, "loganalyse:", err)
		os.Exit(1)
	}
	report(stats)
}

// analyse streams the file through a pool of workers. Each worker keeps its own
// Stats, so they never share memory; the results are merged at the end.
func analyse(path string, workers int) (*logs.Stats, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	lines := make(chan numbered, 1024)
	results := make([]*logs.Stats, workers)
	var wg sync.WaitGroup
	for w := range workers {
		results[w] = logs.NewStats()
		wg.Add(1)
		go func(s *logs.Stats) {
			defer wg.Done()
			for l := range lines {
				s.Add(l.n, l.text)
			}
		}(results[w])
	}

	scanner := bufio.NewScanner(f)
	n := 0
	for scanner.Scan() {
		n++
		lines <- numbered{n, scanner.Text()} // Text copies the line; the scanner reuses its buffer
	}
	close(lines)
	wg.Wait()
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("line %d: %w", n+1, err)
	}

	total := logs.NewStats()
	for _, s := range results {
		total.Merge(s)
	}
	return total, nil
}

func report(s *logs.Stats) {
	fmt.Printf("lines: %d\n", s.Lines)
	fmt.Printf("malformed: %d\n", len(s.Malformed))
	for _, status := range slices.Sorted(maps.Keys(s.ByStatus)) {
		fmt.Printf("status %d: %d\n", status, s.ByStatus[status])
	}
	if s.SlowestLine != 0 {
		fmt.Printf("slowest: %d ms %s (line %d)\n", s.Slowest.MS, s.Slowest.Path, s.SlowestLine)
	}
	if len(s.Malformed) > 0 {
		slices.SortFunc(s.Malformed, func(a, b logs.Bad) int { return a.Line - b.Line })
		fmt.Println("malformed lines:")
		for _, b := range s.Malformed[:min(10, len(s.Malformed))] {
			fmt.Printf("  line %d: %s\n", b.Line, b.Reason)
		}
		if extra := len(s.Malformed) - 10; extra > 0 {
			fmt.Printf("  ... and %d more\n", extra)
		}
	}
}
