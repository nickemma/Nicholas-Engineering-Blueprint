package main

import (
	"fmt"
	"os"
	"strings"

	"gofromzero/logs"
)

// The wrong way: read the whole file into memory, then split it.
func main() {
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	s := logs.NewStats()
	for i, l := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		s.Add(i+1, l)
	}
	fmt.Printf("lines: %d\nmalformed: %d\n", s.Lines, len(s.Malformed))
}
