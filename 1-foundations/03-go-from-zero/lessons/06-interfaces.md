# 06 Interfaces

> Module: Go from zero · Time: ~3 h · Builds on: 05

## The problem

You've written a function that prints a report to the screen. Next week someone wants the same report in a file; then sent over the network; then held in memory so a test can check it. Without a way to say "anything I can write to", you'd write four copies of the function. Go's answer is the **interface**: a type defined by what it can *do*, not by what it *is*. It's how one Go function can write to a terminal, a file, a network connection or a buffer.

## The mental model

~~~text
 type Shape interface { Area() float64 }        "anything with an Area() method"

   Rect   has Area()  ──┐
   Circle has Area()  ──┼──▶ both are Shapes, automatically
   Task   has no Area() ┘    not a Shape

 a value of interface type holds two things:  (the concrete type, the value)
   var s Shape = Rect{3, 4}   ──▶  (Rect, {3 4})
~~~

An interface lists methods. Any type that has those methods **satisfies** it, without saying so anywhere. That's different from languages where a class must declare which interfaces it implements.

## The pattern

**Accept interfaces, return concrete types.** Write functions that take the smallest interface they need (`io.Writer` rather than "a file"), so callers can hand them anything that fits.

## Build it

### Step 1: An interface, two types, and one function for both

Create `drills/shapes/main.go`:

<!-- file: drills/shapes/main.go -->
~~~go
// Lesson 06: interfaces.
package main

import (
	"fmt"
	"io"
	"math"
	"os"
)

// Shape is anything with an area. Types satisfy it just by having the method.
type Shape interface {
	Area() float64
}

type Rect struct{ W, H float64 }

type Circle struct{ R float64 }

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

func main() {
	shapes := []Shape{Rect{3, 4}, Circle{1}}
	report(os.Stdout, shapes)
}
~~~

There are three interfaces at work here, two of them from Go's standard library:

- **`Shape`**, yours. `Rect` and `Circle` each have an `Area() float64` method, so both are `Shape`s, and a `[]Shape` can hold either. `report` calls `s.Area()` without knowing which it has; Go calls the right method for the value inside.
- **`io.Writer`**, from the `io` package, is just `Write(p []byte) (n int, err error)`. `os.Stdout`, your terminal's standard output, has that method. So does an open file, a network connection, and much more. `fmt.Fprintf(w, ...)` is `Printf` that writes to any `io.Writer`.
- **`fmt.Stringer`** is `String() string`. When `fmt` prints a value with `%v` and the value has a `String` method, it uses it. That's why the rectangle prints as `3x4 rectangle` while the circle, which has no `String` method, prints its fields.

~~~bash
go run ./drills/shapes
~~~

<!-- run: go vet ./drills/shapes && go run ./drills/shapes | grep -qx 'total: 15.14' -->

~~~text
3x4 rectangle: 12.00
{1}: 3.14
total: 15.14
~~~

### Step 2: The same function, writing somewhere else

Now send the report into memory instead of the terminal, and read it back with another standard interface, `io.Reader` (`Read(p []byte) (n int, err error)`). Add `bufio` and `strings` to the imports:

<!-- edit: drills/shapes/main.go -->
~~~go
import (
	"fmt"
	"io"
	"math"
	"os"
)
~~~

~~~go
import (
	"bufio"
	"fmt"
	"io"
	"math"
	"os"
	"strings"
)
~~~

**Starter.** Write `countLines(r io.Reader) (int, error)`, which counts the lines it reads. Then, in `main`, write the report into a `strings.Builder` (it has a `Write` method, so it's an `io.Writer`), and count its lines by reading it back through `strings.NewReader(buf.String())`.

<details>
<summary>Hint</summary>

`bufio.NewScanner(r)` reads from any `io.Reader`; `for scanner.Scan() { ... }` runs once per line, and `scanner.Err()` reports any read error at the end. Pass `&buf`: `Write` has a pointer receiver on `strings.Builder`, so only a `*strings.Builder` is an `io.Writer`.

</details>

<details>
<summary>The answer</summary>

<!-- edit: drills/shapes/main.go -->
~~~go
	fmt.Fprintf(w, "total: %.2f\n", total)
}
~~~

~~~go
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
~~~

<!-- edit: drills/shapes/main.go -->
~~~go
	report(os.Stdout, shapes)
~~~

~~~go
	report(os.Stdout, shapes)

	var buf strings.Builder
	report(&buf, shapes)
	n, err := countLines(strings.NewReader(buf.String()))
	fmt.Println("the report has", n, "lines, error:", err)
~~~

</details>

<!-- run: go vet ./drills/shapes && go run ./drills/shapes | grep -qx 'the report has 3 lines, error: <nil>' -->

~~~text
3x4 rectangle: 12.00
{1}: 3.14
total: 15.14
the report has 3 lines, error: <nil>
~~~

`report` didn't change at all, yet it wrote somewhere completely different. `countLines` will read a file, standard input or a network connection just as happily, which is exactly what the log analyser in lesson 11 does with a file. An `error` that's `nil` prints as `<nil>`.

## Break it

Add a third shape that forgets its method. After the `Circle` type, add `type Triangle struct{ B, H float64 }`, and add `Triangle{3, 4}` to the `shapes` list:

~~~text
# gofromzero/drills/shapes
drills/shapes/main.go:51:43: cannot use Triangle{…} (value of struct type Triangle) as Shape value in array or slice literal: Triangle does not implement Shape (missing method Area)
~~~

Go checks at compile time that every value put into a `Shape` really has `Area`, and names the missing method. Remove `Triangle` again (or, as an exercise, give it an `Area` method: half the base times the height).

## Check it

~~~bash
gofmt -l . && go vet ./... && go run ./drills/shapes
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... -->

That proves one function can serve many kinds of value through an interface, checked by the compiler. It doesn't show how to find out which concrete type an interface holds (a **type switch**); you'll rarely need it, and Core 01 shows it when you do.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `X does not implement Y (missing method M)` | The type lacks a method the interface needs, or the signature differs | Add the method with exactly the interface's parameters and results |
| `X does not implement Y (method M has pointer receiver)` | Only `*X` has the method | Pass `&x` |
| `fmt` prints `{3 4}` instead of your format | The type has no `String() string`, or it's on the pointer and you passed a value | Add the method, on a value receiver |
| `impossible type assertion` or similar | Advanced interface features | Not needed yet; keep interfaces small |
