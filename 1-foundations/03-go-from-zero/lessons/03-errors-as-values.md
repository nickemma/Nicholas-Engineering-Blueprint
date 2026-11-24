# 03 Errors as values

> Module: Go from zero · Time: ~3 h · Builds on: 02

## The problem

Things go wrong all the time: a file is missing, a user types `abc` where you wanted a number, a network call times out. A program that ignores this does something worse than crashing: it carries on with a wrong value and reports nonsense, or corrupts data. Go's answer is unusual and deliberate. A function that can fail returns an **error** as an ordinary result, next to its value, and you check it right there. Most of the Go you'll read is shaped by this one rule.

## The mental model

~~~text
 n, err := strconv.Atoi("abc")
           │
           ├── success:  n = 36,  err = nil
           └── failure:  n = 0,   err = an error describing what went wrong
                                   └─ wrapping adds context, layer by layer:
                                      "parsing age \"abc\": strconv.Atoi: parsing \"abc\": invalid syntax"
~~~

`error` is a type like any other. `nil` means "no error". You decide, at every call, what a failure means *there*.

## The pattern

**Check, wrap, return.** At each step: check the error; if it's not `nil`, add what you were trying to do (wrap it) and return it to your caller. The caller can still find out exactly what the original failure was.

## Build it

### Step 1: A function that can fail

`strconv.Atoi` ("ASCII to integer") turns text into an `int`, and returns an error when it can't. You'll build `parseAge`, which also rejects numbers no person's age could be.

**Starter.** Create `drills/errs/main.go`, and fill in `parseAge` so that:
- text that isn't a number returns an error wrapping `strconv.Atoi`'s, with the text in it;
- a number below 0 or above 150 returns an error wrapping `ErrOutOfRange`;
- anything else returns the number and `nil`.

~~~go
// ErrOutOfRange is returned for an age no person has.
var ErrOutOfRange = errors.New("out of range")

// parseAge turns text into an age from 0 to 150.
func parseAge(text string) (int, error) {
	n, err := strconv.Atoi(text)
	// TODO: if err isn't nil, return 0 and the error, wrapped with the text
	// TODO: if n is out of range, return 0 and ErrOutOfRange, wrapped with n
	return n, nil
}
~~~

- `errors.New("out of range")` makes an error with that message. Declaring it once, as a package-level variable, makes it a **sentinel**: a known error your callers can test for.
- `fmt.Errorf("...: %w", err)` makes a new error whose message adds your context, and which **wraps** `err`, keeping it inside.

<details>
<summary>Hint</summary>

`if err != nil { return 0, fmt.Errorf("parsing age %q: %w", text, err) }`. The range check is the same shape, with `ErrOutOfRange` in place of `err`.

</details>

<details>
<summary>The answer</summary>

<!-- file: drills/errs/main.go -->
~~~go
// Lesson 03: errors as values.
package main

import (
	"errors"
	"fmt"
	"strconv"
)

// ErrOutOfRange is returned for an age no person has.
var ErrOutOfRange = errors.New("out of range")

// parseAge turns text into an age from 0 to 150.
func parseAge(text string) (int, error) {
	n, err := strconv.Atoi(text)
	if err != nil {
		return 0, fmt.Errorf("parsing age %q: %w", text, err)
	}
	if n < 0 || n > 150 {
		return 0, fmt.Errorf("age %d: %w", n, ErrOutOfRange)
	}
	return n, nil
}

func main() {
	for _, text := range []string{"36", "abc", "-4", "200"} {
		age, err := parseAge(text)
		if errors.Is(err, ErrOutOfRange) {
			fmt.Println("rejected, out of range:", err)
			continue
		}
		if err != nil {
			fmt.Println("rejected:", err)
			continue
		}
		fmt.Println("age:", age)
	}
}
~~~

</details>

`||` means "or". In `main`, `continue` skips to the next pass of the loop.

~~~bash
go run ./drills/errs
~~~

<!-- run: go vet ./drills/errs && go run ./drills/errs | grep -qx 'rejected, out of range: age 200: out of range' -->

~~~text
age: 36
rejected: parsing age "abc": strconv.Atoi: parsing "abc": invalid syntax
rejected, out of range: age -4: out of range
rejected, out of range: age 200: out of range
~~~

Read the second line from left to right: each layer added what *it* was doing. `parseAge` said "parsing age \"abc\""; `strconv.Atoi` said "parsing \"abc\": invalid syntax". When something fails in production, a message like that tells you where to look without a debugger.

### Step 2: Asking what went wrong

`main` treats the two failures differently, and uses `errors.Is` to tell them apart. `errors.Is(err, ErrOutOfRange)` looks inside every layer of wrapping for that sentinel. That's why `%w` matters: with `%v` instead, the message would read the same, but the original error wouldn't be inside any more, and `errors.Is` would say no.

**Your turn.** Change the `%w` in the range check to `%v`, run it, and explain what changed in the output. Then put it back.

<details>
<summary>What you should see</summary>

The `-4` and `200` lines start with `rejected:` instead of `rejected, out of range:`. The message is identical, but `errors.Is` no longer finds `ErrOutOfRange`, so `main` takes the general path.

</details>

## Break it

Create one more small program, `drills/ignored/main.go`:

~~~go
package main

import (
	"fmt"
	"strconv"
)

func main() {
	n, _ := strconv.Atoi("abc") // the error is thrown away
	fmt.Println("n is", n)

	nums := []int{1, 2, 3}
	i := 5
	fmt.Println(nums[i])
}
~~~

~~~bash
go run ./drills/ignored
~~~

~~~text
n is 0
panic: runtime error: index out of range [5] with length 3

goroutine 1 [running]:
main.main()
	/home/ada/blueprint/gofromzero/drills/ignored/main.go:14 +0x7f
exit status 2
~~~

Two different failures:

- **The ignored error.** `_` threw the error away, so `n` is silently 0. Nothing crashed, and the program carried on with a wrong value. This is the bug Go's style exists to prevent; `_` for an error should make you stop and think.
- **The panic.** Asking for item 5 of a three-item list isn't something to check and handle: it's a mistake in the program. Go **panics**: it stops, prints what happened and where (file and line 14), and exits with status 2. Panics are for bugs; errors are for things that can go wrong in a correct program.

Delete `drills/ignored` when you're done: `rm -r drills/ignored`.

## Check it

~~~bash
gofmt -l . && go vet ./... && go run ./drills/errs
~~~

<!-- run: [ -z "$(gofmt -l .)" ] && go vet ./... -->

That proves `parseAge` reports both kinds of failure with context, and that callers can tell them apart. It doesn't prove every case: you've only tried four inputs. Lesson 07 turns those into tests that run on every change.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `declared and not used: err` | You received an error and never checked it | Check it: `if err != nil { ... }` |
| `errors.Is` returns false for an error you wrapped | You wrapped with `%v`, not `%w` | Use `%w` (exactly one per `Errorf`) |
| `too many return values` / `not enough return values` | A `return` doesn't match the function's result types | Return one value per result: `return 0, err` |
| `panic: runtime error: index out of range` | Reading past the end of a list | Check `len(list)` first; it's a bug, not an error to handle |
| The program prints `0` where you expected a number | An error was thrown away with `_` | Check it |
