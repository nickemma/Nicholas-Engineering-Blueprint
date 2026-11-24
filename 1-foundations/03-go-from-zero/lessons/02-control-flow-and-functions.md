# 02 Control flow and functions

> Module: Go from zero · Time: ~3 h · Builds on: 01

## The problem

A program that only prints values can't decide anything. Real code makes choices ("is this server overloaded?"), repeats work ("for every line in the log…"), and splits a big job into small named pieces you can test one at a time. In Go there are only a few tools for this, `if`, `for`, `switch` and functions, and each has one or two rules that trip up newcomers.

## The mental model

~~~text
 main()
   ├── calls classify(0.5, 4) ──▶ returns "fine"
   ├── calls divmod(17, 5) ──────▶ returns 3, 2   (two results)
   └── loops: for ... { ... }      (Go's only loop keyword)
~~~

A **function** takes inputs (**parameters**, each with a type), runs, and hands back zero or more **results**, each with a type. Every value it needs comes in through its parameters, and everything it produces goes out through its results.

## The pattern

**Small functions with clear inputs and outputs.** A function that takes its data as parameters and returns its answer, without printing or reading files itself, is easy to test (lesson 07) and easy to reuse.

## Build it

### Step 1: A decision with `switch`

`classify` takes a server's load average (Foundations 02) and its number of CPUs, and says how busy it is. Create `drills/flow/main.go`:

**Starter.** Fill in the `switch`, so that load per CPU below 0.7 is `"fine"`, below 1.0 is `"busy"`, and anything else is `"overloaded"`:

~~~go
// classify says how busy a server is from its load and its number of CPUs.
func classify(load float64, cpus int) string {
	switch perCPU := load / float64(cpus); {
	// TODO: three cases
	}
}
~~~

- `func classify(load float64, cpus int) string` declares a function with two parameters, of different types, and one `string` result.
- `switch perCPU := load / float64(cpus); { ... }` first runs the short statement, creating `perCPU` (it exists only inside the `switch`), then picks the first `case` whose condition is true. Unlike some languages, Go stops after the matching case: there's no "falling through" into the next.

<details>
<summary>Hint</summary>

Each case is `case CONDITION:` followed by its code, here a `return`. `default:` catches everything the cases above didn't.

</details>

<details>
<summary>The answer</summary>

<!-- file: drills/flow/main.go -->
~~~go
// Lesson 02: control flow and functions.
package main

import "fmt"

// classify says how busy a server is from its load and its number of CPUs.
func classify(load float64, cpus int) string {
	switch perCPU := load / float64(cpus); {
	case perCPU < 0.7:
		return "fine"
	case perCPU < 1.0:
		return "busy"
	default:
		return "overloaded"
	}
}

func main() {
	for _, load := range []float64{0.5, 3.2, 7.9, 12} {
		fmt.Printf("load %.1f on 4 CPUs: %s\n", load, classify(load, 4))
	}
}
~~~

</details>

`for _, load := range []float64{...}` runs once for each value in the list; `_` throws away the position, which you don't need. `%.1f` prints a float with one decimal place.

~~~bash
go run ./drills/flow
~~~

<!-- run: go vet ./drills/flow && go run ./drills/flow | grep -qx 'load 7.9 on 4 CPUs: overloaded' -->

~~~text
load 0.5 on 4 CPUs: fine
load 3.2 on 4 CPUs: busy
load 7.9 on 4 CPUs: overloaded
load 12.0 on 4 CPUs: overloaded
~~~

### Step 2: Several results

A Go function can return more than one result. You'll use this constantly in the next lesson, where functions return a value *and* an error. Add `divmod` after `classify`:

<!-- edit: drills/flow/main.go -->
~~~go
		return "overloaded"
	}
}
~~~

~~~go
		return "overloaded"
	}
}

// divmod returns the quotient and the remainder.
func divmod(a, b int) (int, int) {
	return a / b, a % b
}
~~~

and call it at the end of `main`:

<!-- edit: drills/flow/main.go -->
~~~go
		fmt.Printf("load %.1f on 4 CPUs: %s\n", load, classify(load, 4))
	}
~~~

~~~go
		fmt.Printf("load %.1f on 4 CPUs: %s\n", load, classify(load, 4))
	}

	q, r := divmod(17, 5)
	fmt.Println("17 / 5 =", q, "remainder", r)
~~~

<!-- run: go vet ./drills/flow && go run ./drills/flow | grep -qx '17 / 5 = 3 remainder 2' -->

~~~text
17 / 5 = 3 remainder 2
~~~

`(a, b int)` is short for `(a int, b int)`. `(int, int)` lists the result types, and `q, r := divmod(17, 5)` receives both. `%` is the remainder.

### Step 3: The three shapes of `for`

Go has one loop keyword, `for`, used three ways. Add after the `divmod` lines:

<!-- edit: drills/flow/main.go -->
~~~go
	fmt.Println("17 / 5 =", q, "remainder", r)
~~~

~~~go
	fmt.Println("17 / 5 =", q, "remainder", r)

	// The three shapes of for.
	sum := 0
	for i := 1; i <= 10; i++ {
		sum += i
	}
	n := 1
	for n < 100 {
		n *= 2
	}
	tries := 0
	for {
		tries++
		if tries == 3 {
			break
		}
	}
	fmt.Println("sum:", sum, "first power of two over 100:", n, "tries:", tries)
~~~

<!-- run: go vet ./drills/flow && go run ./drills/flow | grep -qx 'sum: 55 first power of two over 100: 128 tries: 3' -->

~~~text
sum: 55 first power of two over 100: 128 tries: 3
~~~

1. `for start; condition; step { }` counts: start once, check the condition before each pass, run the step after each.
2. `for condition { }` repeats while the condition is true (other languages call this `while`).
3. `for { }` repeats forever, until a `break` leaves the loop (or a `return` leaves the function).

`sum += i` is short for `sum = sum + i`.

### Step 4: `if`, with a short statement

`if` can also start with a short statement whose variable exists only inside the `if` and its `else`. Add at the end of `main`:

<!-- edit: drills/flow/main.go -->
~~~go
	fmt.Println("sum:", sum, "first power of two over 100:", n, "tries:", tries)
~~~

~~~go
	fmt.Println("sum:", sum, "first power of two over 100:", n, "tries:", tries)

	// if with a short statement: x exists only inside the if.
	if x := sum % 7; x == 0 {
		fmt.Println(sum, "divides by 7")
	} else {
		fmt.Println(sum, "leaves", x, "when divided by 7")
	}
~~~

<!-- run: go vet ./drills/flow && go run ./drills/flow | grep -qx '55 leaves 6 when divided by 7' -->

~~~text
55 leaves 6 when divided by 7
~~~

A variable's **scope** is the part of the code that can see it. `x` is visible in both branches, and nowhere after the closing `}`. Keeping variables in the smallest scope stops them being used by mistake later.

## Break it

**A variable you never use.** Add `unused := 42` on the line before `q, r := divmod(17, 5)`:

~~~text
# gofromzero/drills/flow
drills/flow/main.go:28:2: declared and not used: unused
~~~

Other languages warn; Go refuses to compile. An unused variable is usually a bug, a result you meant to check, so Go makes you deal with it. (Delete it, or assign it to `_` if you really mean to ignore it.)

**A path with no `return`.** In `classify`, replace `default:` with `case perCPU >= 1.0:`:

~~~text
# gofromzero/drills/flow
drills/flow/main.go:16:1: missing return
~~~

You know the three cases cover every number, but Go doesn't reason about the conditions: it only sees that if none of them matched, the function would end without returning a `string`. `default` makes the last case unconditional.

## Check it

~~~bash
gofmt -l . && go vet ./... && go run ./drills/flow
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... -->

You should see the seven lines above. That proves you can branch, loop and split code into functions with results. It doesn't handle anything going wrong: `divmod(1, 0)` would crash the program. Handling failure, the Go way, is the next lesson.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `syntax error: unexpected newline, expected {` | The `{` is on its own line | In Go, `{` must end the line that starts the block |
| `undefined: x` | `x` was declared inside an `if` or loop and used outside it | Declare it before the `if` if you need it afterwards |
| `assignment mismatch: 1 variable but divmod returns 2 values` | You received one result from a function that returns two | `q, r := divmod(...)`, or `q, _ :=` to ignore one |
| A `for` that never ends | Its condition never becomes false, or there's no `break` | Press Ctrl+C, then check the condition and the step |
| `invalid operation: ... (mismatched types float64 and int)` | Mixing types in a calculation | Convert one side, as with `float64(cpus)` |
