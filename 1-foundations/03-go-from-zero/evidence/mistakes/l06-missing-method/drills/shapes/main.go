// Lesson 06: interfaces.
package main

import (
	"bufio"
	"fmt"
	"io"
	"math"
	"os"
	"strings"
)

// Shape is anything with an area. Types satisfy it just by having the method.
type Shape interface {
	Area() float64
}

type Rect struct{ W, H float64 }

type Circle struct{ R float64 }

type Triangle struct{ B, H float64 }

func (r Rect) Area() float64   { return r.W * r.H }
func (c Circle) Area() float64 { return math.Pi * c.R * c.R }

// String makes Rect a fmt.Stringer, so fmt prints it this way.
func (r Rect) String() string { return fmt.Sprintf("%gx%g rectangle", r.W, r.H) }

// report writes to any io.Writer: the terminal, a file, a buffer, a network connection.
func report(w io.Writer, shapes []Shape) {
	total := 0.0
	for _, s := range shapes {
		fmt.Fprintf(w, "%v: %.2f\n", s, s.Area())
		total += s.Area()
	}
	fmt.Fprintf(w, "total: %.2f\n", total)
}

// countLines reads from any io.Reader.
func countLines(r io.Reader) (int, error) {
	scanner := bufio.NewScanner(r)
	n := 0
	for scanner.Scan() {
		n++
	}
	return n, scanner.Err()
}

func main() {
	shapes := []Shape{Rect{3, 4}, Circle{1}, Triangle{3, 4}}
	report(os.Stdout, shapes)

	var buf strings.Builder
	report(&buf, shapes)
	n, err := countLines(strings.NewReader(buf.String()))
	fmt.Println("the report has", n, "lines, error:", err)
}
