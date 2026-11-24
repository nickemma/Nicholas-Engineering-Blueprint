# 01 How Python runs your code

> Module: Python runtime and honest measurement · Time: ~4 h · Builds on: Foundations 04 (or the test-out), Core 01 lesson 01

## The problem

In Foundations 04 you wrote Python that worked, and Python never asked you about memory, types or threads. That's convenient until you build a tool whose job is to measure something to the millisecond. Then you need to know what each line costs. In this module you'll build `kload`, a load generator that measures Switchyard, and a load generator that's slower than the thing it measures reports its own slowness as the server's.

Core 01 lesson 01 opened up Go's runtime. This lesson does the same for Python's: what a name and a value really are, when memory is freed, what instructions the interpreter runs, and what all of that costs next to Go.

## The mental model

~~~text
  names (in a function's frame)          objects (on the heap)
  ┌──────────┐                          ┌───────────────────────────────┐
  │ a ───────┼─────────────┐            │ list   refcount 2             │
  │ b ───────┼─────────────┴──────────▶ │ [ ptr, ptr, ptr ]             │
  └──────────┘                          └───┼─────┼─────┼───────────────┘
                                            ▼     ▼     ▼
                                        ┌──────┐┌──────┐┌──────┐
                                        │int 1 ││int 2 ││int 3 │  each one a full object:
                                        └──────┘└──────┘└──────┘  type, refcount, value

  your code ──compile──▶ bytecode ──▶ the interpreter loop runs one instruction at a time
~~~

- Every value is an **object** on the heap: an integer, a string, a function, `None`. Each object carries its type and a **reference count**.
- A **name** (`a`, `b`) holds a reference to an object, never the object itself. `b = a` copies the reference: two names, one object.
- A list holds references too, 8 bytes each, to objects stored elsewhere. In Go, a `[]int64` holds the numbers themselves.
- **Reference counting** frees an object the moment its count reaches zero. A separate **cycle collector** finds groups of objects that refer only to each other.
- Python compiles each function to **bytecode**, and the interpreter runs it one instruction at a time. CPython 3.14 also **specialises** instructions it sees used the same way again and again.

## The pattern

**Know what a line costs before you measure with it.** Each drill below prints what the runtime is doing: `is` and `id()` for identity, `sys.getsizeof` and `tracemalloc` for memory, `sys.getrefcount` and `gc` for freeing, `dis` for the instructions, and a timer around the same loop in Python and Go.

## Build it

`kload` is a uv project from the start. This lesson and the next two only put small experiments in its `drills/` folder; lesson 04 turns the rest of it into a package. Create it:

~~~bash
cd ~/blueprint && uv init --package kload && cd kload
mkdir drills
~~~

<!-- run: uv init --package --name kload . && mkdir drills -->

`uv init --package` makes `pyproject.toml`, `src/kload/__init__.py` and a `.python-version` file. It also starts a Git repository, and fills in `authors` from your Git identity. Check the Python it picked:

~~~bash
uv run python --version
~~~

~~~text
Using CPython 3.14.7
Creating virtual environment at: .venv
   Building kload @ file:///home/ada/blueprint/kload
      Built kload @ file:///home/ada/blueprint/kload
Installed 1 package in 3ms
Python 3.14.7
~~~

### Step 1: Names, objects and their sizes

Create `drills/objects.py`:

<!-- file: drills/objects.py -->
~~~python
"""Lesson 01: what a Python name, value and list really are."""

import sys
import tracemalloc


def names() -> None:
    print("== names are references")
    a = [1, 2]
    b = a  # a second name for the same list, not a copy
    b.append(3)
    print(f"a = {a}, b = {b}, same object: {a is b}, id(a) == id(b): {id(a) == id(b)}")
    c = list(a)  # a new list holding the same items
    print(f"c = {c}, c == a: {c == a}, c is a: {c is a}")


def sizes() -> None:
    print("== everything is an object")
    for value in (0, 1, 2**30, 2**64, 1.5, True, "", "a", None):
        print(f"{value!r:>22}  {type(value).__name__:>8}  {sys.getsizeof(value):>3} bytes")
    print(f"a list of 1,000 items: {sys.getsizeof([0] * 1000)} bytes (8 bytes per item: a pointer)")


def million() -> None:
    print("== a million integers")
    tracemalloc.start()
    numbers = list(range(1_000_000))
    current, _ = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    each = current / len(numbers)
    print(f"list(range(1_000_000)) holds {current / 1e6:.1f} MB ({each:.0f} bytes each)")


def small_ints() -> None:
    print("== small integers are shared")
    x, y = int("256"), int("256")
    print(f"256 is 256: {x is y}")
    x, y = int("257"), int("257")
    print(f"257 is 257: {x is y}  (compare numbers with ==, never with is)")


if __name__ == "__main__":
    names()
    sizes()
    million()
    small_ints()
~~~

Run it:

~~~bash
uv run python drills/objects.py
~~~

~~~text
== names are references
a = [1, 2, 3], b = [1, 2, 3], same object: True, id(a) == id(b): True
c = [1, 2, 3], c == a: True, c is a: False
== everything is an object
                     0       int   28 bytes
                     1       int   28 bytes
            1073741824       int   32 bytes
  18446744073709551616       int   36 bytes
                   1.5     float   24 bytes
                  True      bool   28 bytes
                    ''       str   41 bytes
                   'a'       str   42 bytes
                  None  NoneType   16 bytes
a list of 1,000 items: 8056 bytes (8 bytes per item: a pointer)
== a million integers
list(range(1_000_000)) holds 40.0 MB (40 bytes each)
== small integers are shared
256 is 256: True
257 is 257: False  (compare numbers with ==, never with is)
~~~

Read it from the top:

- `b = a` made a second name for the same list, so appending through `b` changed what `a` sees. `list(a)` made a new list: equal (`==`), but not the same object (`is`).
- The integer `0` takes 28 bytes: a type pointer, a reference count, and the digits. Integers grow as they need to, so `2**64` simply takes more bytes. They never overflow.
- A list of 1,000 items is 8,056 bytes: 56 bytes of list, then one 8-byte pointer per item.
- A million integers in a list take 40 MB: an 8-byte pointer plus a 32-byte integer object each (28 bytes, rounded up by the allocator). The same numbers in a Go `[]int64` take 8 MB.
- CPython keeps one shared object for each small integer, from −5 to 256. That's why `256 is 256` but not `257 is 257`. The rule to take away: compare values with `==`; `is` asks "the same object?", which you rarely mean.

### Step 2: Two traps that come from references

Create `drills/traps.py`:

<!-- file: drills/traps.py -->
~~~python
"""Lesson 01: two traps that come from names being references."""


def grid() -> None:
    print("== a grid made by multiplying a list")
    rows = [[0] * 3] * 3  # three references to ONE row
    rows[0][0] = 1
    print(f"[[0] * 3] * 3 after rows[0][0] = 1: {rows}")
    rows = [[0] * 3 for _ in range(3)]  # three separate rows
    rows[0][0] = 1
    print(f"a comprehension, after the same change: {rows}")


def add(item: str, into: list[str] = []) -> list[str]:  # noqa: B006 (the bug this drill shows)
    into.append(item)
    return into


def add_fixed(item: str, into: list[str] | None = None) -> list[str]:
    if into is None:
        into = []
    into.append(item)
    return into


def defaults() -> None:
    print("== a mutable default argument")
    print(f"add('a') = {add('a')}, then add('b') = {add('b')}")
    print(f"the default is one list, made once: {add.__defaults__}")
    print(f"add_fixed('a') = {add_fixed('a')}, then add_fixed('b') = {add_fixed('b')}")


if __name__ == "__main__":
    grid()
    defaults()
~~~

~~~bash
uv run python drills/traps.py
~~~

~~~text
== a grid made by multiplying a list
[[0] * 3] * 3 after rows[0][0] = 1: [[1, 0, 0], [1, 0, 0], [1, 0, 0]]
a comprehension, after the same change: [[1, 0, 0], [0, 0, 0], [0, 0, 0]]
== a mutable default argument
add('a') = ['a'], then add('b') = ['a', 'b']
the default is one list, made once: (['a', 'b'],)
add_fixed('a') = ['a'], then add_fixed('b') = ['b']
~~~

`[[0] * 3] * 3` makes one row and three references to it, so changing one "row" changes all three. The comprehension runs `[0] * 3` three times: three rows.

A default argument is evaluated **once**, when the `def` runs, not on every call. `add` keeps appending to the same list, and you can see it sitting in `add.__defaults__`. `None` as the default, and a new list inside the function, is the fix. Ruff's `B006` rule flags the bug, which is why the drill silences it with `noqa` on that one line.

### Step 3: When memory is freed

Create `drills/refcount.py`:

<!-- file: drills/refcount.py -->
~~~python
"""Lesson 01: when Python frees an object."""

import gc
import sys


class Noisy:
    """Says when it's freed."""

    def __init__(self, name: str) -> None:
        self.name = name
        self.partner: Noisy | None = None

    def __del__(self) -> None:
        print(f"   freed {self.name}")


def counting() -> None:
    print("== reference counting")
    a = Noisy("a")
    print(f"refcount of a: {sys.getrefcount(a)}")
    b = a
    print(f"after b = a: {sys.getrefcount(a)}")
    del b
    print(f"after del b: {sys.getrefcount(a)}")
    print("del a:")
    del a
    print("(freed at once: the count reached zero)")


def cycles() -> None:
    print("== a cycle")
    gc.disable()
    x, y = Noisy("x"), Noisy("y")
    x.partner, y.partner = y, x  # each keeps the other alive
    print("del x, y:")
    del x, y
    print("(nothing freed: each still has a reference from the other)")
    print("gc.collect():")
    found = gc.collect()
    print(f"(the cycle collector found {found} unreachable objects)")
    gc.enable()


if __name__ == "__main__":
    counting()
    cycles()
~~~

~~~bash
uv run python drills/refcount.py
~~~

~~~text
== reference counting
refcount of a: 1
after b = a: 2
after del b: 1
del a:
   freed a
(freed at once: the count reached zero)
== a cycle
del x, y:
(nothing freed: each still has a reference from the other)
gc.collect():
   freed x
   freed y
(the cycle collector found 108 unreachable objects)
~~~

The counts went 1, 2, 1: one reference per name. (Before Python 3.14, `getrefcount` printed one more, for its own reference to its argument. 3.14 often passes a local variable without taking a new reference, so the extra one no longer shows.) `__del__` runs as an object is freed, so `Noisy` shows you the moment. `a` was freed on the line `del a`, the instant its count reached zero: there was no pause, and no collector running in the background, as Go has. Most Python objects die this way.

`x` and `y` refer to each other, so after `del x, y` each still has a count of one. Reference counting alone would never free them. The **cycle collector** (`gc`) runs from time to time, finds groups that nothing outside refers to, and frees them. The drill turned it off with `gc.disable()` so you could see the cycle survive, then ran it by hand. Its count includes anything else unreachable that had piled up since it last ran, which is why it can be more than two.

### Step 4: The instructions Python runs

Create `drills/bytecode.py`:

<!-- file: drills/bytecode.py -->
~~~python
"""Lesson 01: the instructions Python runs."""

import dis


def total(numbers: list[int]) -> int:
    t = 0
    for n in numbers:
        t += n
    return t


if __name__ == "__main__":
    print("== the bytecode of total()")
    dis.dis(total)
    for _ in range(100):  # run it enough for the interpreter to specialise it
        total(list(range(100)))
    print("== after 100 calls, specialised for ints and lists")
    dis.dis(total, adaptive=True)
~~~

~~~bash
uv run python drills/bytecode.py
~~~

~~~text
== the bytecode of total()
  6           RESUME                   0

  7           LOAD_SMALL_INT           0
              STORE_FAST               1 (t)

  8           LOAD_FAST_BORROW         0 (numbers)
              GET_ITER
      L1:     FOR_ITER                11 (to L2)
              STORE_FAST               2 (n)

  9           LOAD_FAST_BORROW_LOAD_FAST_BORROW 18 (t, n)
              BINARY_OP               13 (+=)
              STORE_FAST               1 (t)
              JUMP_BACKWARD           13 (to L1)

  8   L2:     END_FOR
              POP_ITER

 10           LOAD_FAST_BORROW         1 (t)
              RETURN_VALUE
== after 100 calls, specialised for ints and lists
  6           RESUME_CHECK             0

  7           LOAD_SMALL_INT           0
              STORE_FAST               1 (t)

  8           LOAD_FAST_BORROW         0 (numbers)
              GET_ITER
      L1:     FOR_ITER_LIST           11 (to L2)
              STORE_FAST               2 (n)

  9           LOAD_FAST_BORROW_LOAD_FAST_BORROW 18 (t, n)
              BINARY_OP_ADD_INT       13 (+=)
              STORE_FAST               1 (t)
              JUMP_BACKWARD_NO_JIT    13 (to L1)

  8   L2:     END_FOR
              POP_ITER

 10           LOAD_FAST_BORROW         1 (t)
              RETURN_VALUE
~~~

Each line of `total` became a few instructions: load `t` and `n`, add them, store the result, jump back. The interpreter runs them one at a time, and each one does more work than it looks: `BINARY_OP` must check both operands' types, find their `+`, and make a new integer object for the result.

After 100 calls the **specialising interpreter** has rewritten some of them: `BINARY_OP` became `BINARY_OP_ADD_INT`, which assumes two integers and checks only that the guess still holds; `FOR_ITER` became `FOR_ITER_LIST`. Specialising makes Python faster, but every addition still builds an integer object.

### Step 5: The same loop in Python and in Go

Create `drills/loop.py`:

<!-- file: drills/loop.py -->
~~~python
"""Lesson 01: the same loop in Python, three ways. Compare with loop/main.go."""

import time

N = 10_000_000


def loop() -> int:
    total = 0
    for i in range(N):
        total += i * i
    return total


def generator() -> int:
    return sum(i * i for i in range(N))


def timed(name: str, fn) -> None:
    start = time.perf_counter()
    result = fn()
    took = time.perf_counter() - start
    print(f"{name:<22} {result}  {took:.3f} s  {took / N * 1e9:5.1f} ns per item")


if __name__ == "__main__":
    timed("for loop", loop)
    timed("sum(generator)", generator)
~~~

and the same loop in Go, `drills/loop/main.go`:

<!-- file: drills/loop/main.go -->
~~~go
// The same loop as loop.py, in Go.
package main

import (
	"fmt"
	"time"
)

const n = 10_000_000

func main() {
	start := time.Now()
	total := 0
	for i := range n {
		total += i * i
	}
	took := time.Since(start)
	fmt.Printf("%-22s %d  %.3f s  %5.1f ns per item\n", "Go for loop", total, took.Seconds(), float64(took.Nanoseconds())/n)
}
~~~

Run both. `go run` with a file name doesn't need a Go module:

~~~bash
uv run python drills/loop.py
go run drills/loop/main.go
~~~

~~~text
for loop               333333283333335000000  0.456 s   45.6 ns per item
sum(generator)         333333283333335000000  0.595 s   59.5 ns per item
Go for loop            1291890006563070912  0.004 s    0.4 ns per item
~~~

Your times will differ; the ratio won't, by much. Python spent about 46 ns per item, Go about 0.4 ns: a hundred times less. Every Python `+` and `*` dispatched on types and allocated an integer object; Go's compiled loop is a few machine instructions working in registers.

Now look at the totals. They don't match. The true sum is 333,333,283,333,335,000,000, which is more than an `int64` can hold. Go's addition **wrapped around** past 9.2 × 10¹⁸ without a word, so Go printed a wrong answer, quickly. Python's integers grow, so Python printed the right one, slowly. Neither is a bug in the language: they're the trade each one made. Go lets you choose `math/big` when you need it; Python lets you reach for NumPy or a compiled extension when you need speed.

<!-- run: uv run python drills/objects.py && uv run python drills/traps.py && uv run python drills/refcount.py && uv run python drills/bytecode.py > /dev/null && uv run python drills/loop.py -->

## Break it

**Copy the list "by assignment".** In `names()`, change `c = list(a)` to `c = a`, run `uv run python drills/objects.py | head -3`:

~~~text
== names are references
a = [1, 2, 3], b = [1, 2, 3], same object: True, id(a) == id(b): True
c = [1, 2, 3], c == a: True, c is a: True
~~~

`c is a` is now `True`: one list with three names. Change it back.

**Keep the cycle collector on.** Delete `gc.disable()` in `cycles()` and run it again:

~~~text
== reference counting
refcount of a: 1
after b = a: 2
after del b: 1
del a:
   freed a
(freed at once: the count reached zero)
== a cycle
del x, y:
(nothing freed: each still has a reference from the other)
gc.collect():
   freed x
   freed y
(the cycle collector found 2 unreachable objects)
~~~

The cycle still survived until `gc.collect()`: the collector runs only after enough new allocations, and this program makes few. Whether a cycle is freed "soon" depends on what else the program allocates: that's why objects whose `__del__` matters, a file or a socket, should be closed explicitly (`with`), never left for the collector. Put the line back.

## Check it

~~~bash
uv run python drills/traps.py
~~~

Then, from memory, without the drill open: why does `[[0] * 3] * 3` share rows? When is a Python object freed, and when isn't reference counting enough? Why is the Python loop so much slower than Go's? What did Go get wrong, and why?

This proves you can see what the interpreter does with a line of code. It doesn't prove a program is fast or slow: only measuring that program can tell you, and the next lessons do.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `uv: command not found` | uv isn't installed, or not on `PATH` in this terminal | Foundations 04, lesson 06; or open a new terminal |
| `go: command not found` | Go isn't on `PATH` | Foundations 01; `export PATH=$PATH:/usr/local/go/bin` |
| `uv init` says the project already exists | `~/blueprint/kload` is already there | Use it, or move it aside |
| Different sizes from the table | A Python other than 3.14 | `uv run python --version`; `uv python pin 3.14` |
| `go run drills/loop/main.go` says "no required module" | An old Go, or `GO111MODULE` set to `on` with no `go.mod` | `go version` (want 1.26 or later); `unset GO111MODULE` |
