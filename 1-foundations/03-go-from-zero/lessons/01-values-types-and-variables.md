# 01 Values, types and variables

> Module: Go from zero · Time: ~3 h · Builds on: [How the machine works](../../02-how-the-machine-works/README.md)

## The problem

In Foundations 02 you saw that everything is bytes, and that the meaning comes from how you read them. A programming language decides that for you: when you write `36` or `"Ada"`, it picks how many bytes to use and what they mean. Go makes those choices visible, and checks them before your program ever runs. Most of Go's error messages in your first weeks are about exactly this, so it pays to know what Go is checking.

## The mental model

~~~text
 a variable = a name + a type + a place in memory holding bytes

 age     int      8 bytes   00 00 00 00 00 00 00 24      (36)
 height  float64  8 bytes   a floating-point pattern     (1.65)
 ok      bool     1 byte    00                           (false)
 name    string   16 bytes  pointer to the bytes "Ada" + length 3
~~~

The **type** fixes how many bytes a value takes and what operations are allowed on it. Go never guesses: it won't add an `int` to a `float64`, or put a number into a `string`, unless you say so.

## The pattern

**Let the compiler catch it.** Go is **statically typed**: types are checked when you build, not when you run. Every mistake it catches at build time is one your users never see.

## Build it

### Step 1: A module and a first program

All of this module's code lives in one Go **module**, a folder of Go code with a `go.mod` file at the top:

~~~bash
mkdir -p ~/blueprint/gofromzero && cd ~/blueprint/gofromzero && go mod init gofromzero && cat go.mod
~~~

<!-- run: go mod init gofromzero -->

~~~text
go: creating new go.mod: module gofromzero
module gofromzero

go 1.27.4
~~~

Each lesson's small programs, the **drills**, go in their own folder under `drills/`. Create `drills/values/main.go`:

<!-- file: drills/values/main.go -->
~~~go
// Lesson 01: values, types and variables.
package main

import "fmt"

func main() {
	// Declaring variables.
	var name string = "Ada"
	age := 36
	height := 1.65
	fmt.Println(name, age, height)
	fmt.Printf("%v is a %T, %v is a %T, %v is a %T\n", name, name, age, age, height, height)
}
~~~

- `package main` and `func main()` mark a program you can run, as in Foundations 01.
- `var name string = "Ada"` declares a variable with its type spelled out. `age := 36` declares one and lets Go **infer** the type from the value: `36` is an `int`, and `1.65` a `float64`.
- `fmt.Println` prints its arguments with spaces between them. `fmt.Printf` prints a **format string**, filling each `%` verb with the next argument: `%v` is the value, `%T` its type, and `\n` ends the line.

~~~bash
go run ./drills/values
~~~

<!-- run: go vet ./drills/values && go run ./drills/values | head -1 | grep -qx 'Ada 36 1.65' -->

~~~text
Ada 36 1.65
Ada is a string, 36 is a int, 1.65 is a float64
~~~

`./drills/values` is the folder to build; `go run` compiles it and runs the result.

### Step 2: Zero values

A variable you declare without a value isn't empty or random: Go sets it to its type's **zero value**. Add this after the `Printf` line:

<!-- edit: drills/values/main.go -->
~~~go
	fmt.Printf("%v is a %T, %v is a %T, %v is a %T\n", name, name, age, age, height, height)
~~~

~~~go
	fmt.Printf("%v is a %T, %v is a %T, %v is a %T\n", name, name, age, age, height, height)

	// Zero values: every variable starts with one.
	var count int
	var ratio float64
	var ok bool
	var label string
	fmt.Printf("zero values: %d %v %v %q\n", count, ratio, ok, label)
~~~

`%d` prints a whole number; `%q` prints a string in quotes, so an empty one is visible.

~~~text
zero values: 0 0 false ""
~~~

(From here on, each step's output is the new lines at the end; `go run ./drills/values` prints the earlier lines too.) Zero, `false` and the empty string: never leftover bytes from whatever used that memory before. That rules out a whole family of bugs other languages have.

### Step 3: How much memory each type takes

`unsafe.Sizeof` reports how many bytes a value takes. (The package is called `unsafe` because most of it lets you break Go's rules; `Sizeof` is harmless.) Change the import to bring it in:

<!-- edit: drills/values/main.go -->
~~~go
import "fmt"
~~~

~~~go
import (
	"fmt"
	"unsafe"
)
~~~

and add after the zero values:

<!-- edit: drills/values/main.go -->
~~~go
	fmt.Printf("zero values: %d %v %v %q\n", count, ratio, ok, label)
~~~

~~~go
	fmt.Printf("zero values: %d %v %v %q\n", count, ratio, ok, label)

	// How much memory each type takes.
	fmt.Println("bytes: int", unsafe.Sizeof(count), "float64", unsafe.Sizeof(ratio),
		"bool", unsafe.Sizeof(ok), "string", unsafe.Sizeof(label))
~~~

<!-- run: go vet ./drills/values && go run ./drills/values | grep -qx 'bytes: int 8 float64 8 bool 1 string 16' -->

~~~text
bytes: int 8 float64 8 bool 1 string 16
~~~

An `int` is 8 bytes (64 bits) on a 64-bit machine. A `string` is 16 bytes however long it is: 8 for a pointer to where its bytes live, and 8 for its length. The text itself is stored elsewhere. You'll see the same split for slices in lesson 04.

### Step 4: Numbers have limits

In Foundations 02, the shell's arithmetic wrapped from the largest 64-bit number to the most negative one. Go does the same at run time. Add `math` to the imports:

<!-- edit: drills/values/main.go -->
~~~go
	"fmt"
	"unsafe"
~~~

~~~go
	"fmt"
	"math"
	"unsafe"
~~~

and after the sizes:

<!-- edit: drills/values/main.go -->
~~~go
		"bool", unsafe.Sizeof(ok), "string", unsafe.Sizeof(label))
~~~

~~~go
		"bool", unsafe.Sizeof(ok), "string", unsafe.Sizeof(label))

	// Integers have limits, and wrap around without warning.
	var big int64 = math.MaxInt64
	fmt.Println("largest int64:", big)
	big++
	fmt.Println("one more:     ", big)
~~~

<!-- run: go vet ./drills/values && go run ./drills/values | grep -qx 'one more:      -9223372036854775808' -->

~~~text
largest int64: 9223372036854775807
one more:      -9223372036854775808
~~~

`big++` adds one. No error, no warning: the bits wrapped round. Go's built-in integers never check for this at run time; when it matters (money, counters that grow forever), you check yourself.

### Step 5: Converting between types

Go converts between types only when you ask, by writing the type like a function: `float64(total)`. Add after the overflow lines:

<!-- edit: drills/values/main.go -->
~~~go
	fmt.Println("one more:     ", big)
~~~

~~~go
	fmt.Println("one more:     ", big)

	// Converting between types is always explicit.
	total := 7
	share := float64(total) / 2
	fmt.Println("share:", share, "rounded down:", total/2)
~~~

<!-- run: go vet ./drills/values && go run ./drills/values | grep -qx 'share: 3.5 rounded down: 3' -->

~~~text
share: 3.5 rounded down: 3
~~~

Dividing two `int`s gives an `int`: `7 / 2` is `3`, with the remainder thrown away. Converting first gives `3.5`.

### Step 6: Strings are bytes

Add the last section:

<!-- edit: drills/values/main.go -->
~~~go
	fmt.Println("share:", share, "rounded down:", total/2)
~~~

~~~go
	fmt.Println("share:", share, "rounded down:", total/2)

	// A string is a sequence of bytes, not characters.
	word := "café"
	fmt.Println("bytes:", len(word), "first byte:", word[0], "as a letter:", string(word[0]))
	for i, r := range word {
		fmt.Printf("byte %d: %c\n", i, r)
	}
~~~

<!-- run: go vet ./drills/values && go run ./drills/values | grep -qx 'byte 3: é' -->

~~~text
bytes: 5 first byte: 99 as a letter: c
byte 0: c
byte 1: a
byte 2: f
byte 3: é
~~~

`len` counts bytes: "café" is 5, because `é` is two bytes in UTF-8, as you saw with `xxd`. `word[0]` is a single **byte**, the number 99, which is `c` in ASCII. `for i, r := range word` walks the string one **rune** (one Unicode character) at a time, telling you the byte position each starts at: `é` starts at byte 3 and takes bytes 3 and 4. `%c` prints a rune as a character.

### Step 7: Building a program, and `go vet`

`go run` builds into a temporary folder and runs it. `go build` keeps the program:

~~~bash
go build -o values ./drills/values && ls -l values && ./values | head -2 && rm values
~~~

~~~text
-rwxrwxr-x 1 ada ada 2365196 Nov 19 07:27 values
Ada 36 1.65
Ada is a string, 36 is a int, 1.65 is a float64
~~~

About 2.3 MB: Go puts everything the program needs into one file, so it runs on another Linux machine without installing anything.

`go vet` looks for mistakes that compile but are almost certainly wrong. Run it on every change:

~~~bash
go vet ./...
~~~

`./...` means "this folder and everything under it". No output means no problems.

## Break it

Make each change, predict what Go will say, run it, then undo the change.

**A constant that doesn't fit.** Change `var big int64 = math.MaxInt64` to `math.MaxInt64 + 1`:

~~~text
# gofromzero/drills/values
drills/values/main.go:30:18: cannot use math.MaxInt64 + 1 (untyped int constant 9223372036854775808) as int64 value in variable declaration (overflows)
~~~

At run time, `big++` wrapped silently. Here, the value is a **constant** that Go works out while compiling, so it can see it won't fit, and refuses.

**Mixing types.** Change the `share` line to `share := total / 2.0 + height`:

~~~text
# gofromzero/drills/values
drills/values/main.go:37:11: invalid operation: total / 2.0 + height (mismatched types int and float64)
~~~

`total` is an `int` and `height` a `float64`. Convert one of them.

**The wrong format verb.** Change the first `Println` to `fmt.Printf("%d is %d\n", name, age)`. It compiles, and `go vet` catches it:

~~~text
drills/values/main.go:15:14: fmt.Printf format %d has arg name of wrong type string
~~~

## Check it

~~~bash
gofmt -l . && go vet ./... && go run ./drills/values
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... -->

`gofmt -l` lists files whose layout isn't Go's standard one; it should print nothing (`gofmt -w FILE` fixes one). Then you should see the twelve lines of output above. That proves your program compiles cleanly and behaves as described. It doesn't yet do anything useful: that starts in the next lesson, with decisions and functions.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `go: cannot find main module` | You're outside `~/blueprint/gofromzero` | `cd ~/blueprint/gofromzero` |
| `"unsafe" imported and not used` | An import nothing uses yet | Remove it, or add the code that uses it |
| `undefined: math` | The code uses a package that isn't imported | Add it to the `import` list |
| `syntax error: unexpected newline` | A missing `)` or `,` at the end of a split line | A line that continues must end with a `,` or an operator |
| Odd spacing in your file | Not formatted | `gofmt -w drills/values/main.go`; VS Code does it on save |
