# 06 Python from zero: values, collections and functions

> Module: Python and the internet from zero · Time: ~5 h · Builds on: Go from zero

## The problem

Go runs the servers in this course. Python runs the experiments: load generators, measurement scripts, data analysis, and later the machine-learning work in the AI track. It's quick to write and has a library for almost everything, at the price of being slower and checking less before your program runs. By lesson 09 you'll use it to send a thousand requests to your echo server and plot how long each one took. First, the language itself, compared with the Go you already know.

## The mental model

~~~text
 Go                                        Python
 compiled to a binary, then run            run by the interpreter, line by line, from source
 types checked before it runs              types checked as it runs (hints are optional notes)
 x := 5            (declared once)         x = 5            (assigning a name creates it)
 { ... }           blocks                  indentation       blocks
 []int, map        slices, maps            list, dict        (plus set and tuple)
 return v, err     errors as values        raise / except    exceptions (lesson 07)
 go.mod            the module               pyproject.toml    the project; uv manages it
~~~

In Python, every value is an **object** that knows its own type, and a variable is just a **name** that refers to an object. Two names can refer to the same object, which matters as soon as the object can change: you'll see it in step 4.

## The pattern

**One project, one environment, one tool.** Each Python project gets its own **virtual environment**: a private folder of packages, so projects never fight over versions. `uv` creates it, installs Python itself, and runs everything inside it with `uv run`, so you never have to activate anything or touch the system's Python.

## Build it

### Step 1: Install `uv`

Download `uv` and check its checksum, the way Foundations 01 did for Go. On Linux and WSL:

~~~bash
cd ~
curl -fsSLO https://github.com/astral-sh/uv/releases/download/0.12.7/uv-x86_64-unknown-linux-gnu.tar.gz
curl -fsSLO https://github.com/astral-sh/uv/releases/download/0.12.7/uv-x86_64-unknown-linux-gnu.tar.gz.sha256
sha256sum -c uv-x86_64-unknown-linux-gnu.tar.gz.sha256
tar -xzf uv-x86_64-unknown-linux-gnu.tar.gz
mkdir -p ~/.local/bin && mv uv-x86_64-unknown-linux-gnu/uv uv-x86_64-unknown-linux-gnu/uvx ~/.local/bin/
rm -r uv-x86_64-unknown-linux-gnu uv-x86_64-unknown-linux-gnu.tar.gz uv-x86_64-unknown-linux-gnu.tar.gz.sha256
~~~

~~~text
uv-x86_64-unknown-linux-gnu.tar.gz: OK
~~~

`OK` means the file matches the checksum the uv project published. Close the terminal and open a new one: Ubuntu adds `~/.local/bin` to your `PATH` at login once the folder exists. Then:

~~~bash
command -v uv && uv --version
~~~

~~~text
/home/ada/.local/bin/uv
uv 0.12.7 (x86_64-unknown-linux-gnu)
~~~

**macOS:** use `uv-aarch64-apple-darwin` in the three file names (or `uv-x86_64-apple-darwin` on an Intel Mac), and `shasum -a 256 -c` instead of `sha256sum -c`. If `uv` isn't found afterwards, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zprofile`.

### Step 2: A project

Make the Python project next to your Go server:

~~~bash
cd ~/blueprint/internet
mkdir measure && cd measure
uv init --bare --name measure --python 3.14
uv python pin 3.14
uv add --dev pytest ruff
ls -a
~~~

<!-- run: mkdir -p measure && cd measure && uv init --bare --name measure --python 3.14 && uv python pin 3.14 && uv add --dev pytest ruff -->

~~~text
Initialized project `measure`
Downloading cpython-3.14.7-linux-x86_64-gnu (download) (34.3MiB)
 Downloaded cpython-3.14.7-linux-x86_64-gnu (download)
Pinned `.python-version` to `3.14`
Using CPython 3.14.7
Creating virtual environment at: .venv
Resolved 8 packages in 5.36s
Downloading pygments (1.2MiB)
Downloading ruff (10.1MiB)
 Downloaded pygments
 Downloaded ruff
Prepared 6 packages in 5.18s
Installed 6 packages in 33ms
 + iniconfig==2.3.1
 + packaging==26.3
 + pluggy==1.7.0
 + pygments==2.21.0
 + pytest==9.2.0
 + ruff==0.17.5
.
..
.python-version
.venv
pyproject.toml
uv.lock
~~~

- `uv init --bare` writes a minimal `pyproject.toml`, the project's description, like `go.mod`.
- `uv python pin 3.14` writes `.python-version`, so this project always uses Python 3.14. `uv` downloads that Python the first time it's needed; you don't install it yourself.
- `uv add --dev pytest ruff` adds two tools used only while developing: `pytest` runs tests, `ruff` formats and checks code. `uv` created the virtual environment, `.venv`, installed them into it, and recorded the exact versions in `uv.lock`, so everyone gets the same ones.

Open `pyproject.toml` and make it match this. The `[tool.ruff]` sections set the line length and turn on extra checks: `E`/`F` for errors, `I` for import order, `B` for likely bugs, `UP` for modern syntax.

<!-- file: measure/pyproject.toml -->
~~~toml
[project]
name = "measure"
version = "0.1.0"
description = "Measure the latency of a line echo server"
requires-python = ">=3.14"
dependencies = []

[dependency-groups]
dev = [
    "pytest>=9",
    "ruff>=0.14",
]

[tool.ruff]
line-length = 100

[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP"]
~~~

Run Python inside the project:

~~~bash
uv run python --version
~~~

~~~text
Python 3.14.7
~~~

### Step 3: A first program

Create `measure/hello.py`:

<!-- file: measure/hello.py -->
~~~python
"""The first Python program: print, variables, a list and a loop."""

name = "Ada"
latencies_ms = [12, 15, 11, 250, 14]

print(f"Hello, {name}!")
print(f"{len(latencies_ms)} requests")
for latency in latencies_ms:
    if latency > 100:
        print(f"slow: {latency} ms")
~~~

- The first line, in triple quotes, is a **docstring**: documentation attached to the file. Functions and classes have them too.
- There's no `var` or `:=`. Assigning to a name creates it.
- `[12, 15, ...]` is a **list**, Python's growable array (like a Go slice).
- `f"Hello, {name}!"` is an **f-string**: expressions inside `{}` are filled in.
- `for latency in latencies_ms:` loops over the items. The colon starts a block, and the indented lines are its body. There are no parentheses around conditions and no braces.

~~~bash
uv run python hello.py
~~~

<!-- run: cd measure && [ "$(uv run python hello.py)" = "$(printf 'Hello, Ada!\n5 requests\nslow: 250 ms')" ] -->

~~~text
Hello, Ada!
5 requests
slow: 250 ms
~~~

You can also run `uv run python` with no file, which starts the **REPL**: type a line of Python, see its value at once. It's the quickest way to try things in this lesson. Leave it with `exit()` or Ctrl+D.

### Step 4: Values and types

Create `measure/drills/values.py`:

<!-- file: measure/drills/values.py -->
~~~python
"""Lesson 06: values and types."""

# Numbers: int has no size limit; float is a 64-bit floating-point number, as in Go.
print(7 / 2, 7 // 2, 7 % 2)
print(2**64)
print(0.1 + 0.2)
count, ratio, label, done = 7, 7.0, "7", True
print(type(count), type(ratio), type(label), type(done))

# Strings: len counts characters; encode() gives the UTF-8 bytes.
word = "café"
print(len(word), len(word.encode()))
print(word.upper(), word[0], word[-1], word[1:3])
print(int("42") + 1, str(42) + "1")

# Truth: empty and zero values count as false.
print(bool(0), bool(""), bool([]), bool("0"))
answer = None
print(answer is None)
~~~

~~~bash
uv run python drills/values.py
~~~

<!-- run: cd measure && uv run python drills/values.py | sed -n 2p | grep -qx 18446744073709551616 -->

~~~text
3.5 3 1
18446744073709551616
0.30000000000000004
<class 'int'> <class 'float'> <class 'str'> <class 'bool'>
4 5
CAFÉ c é af
43 421
False False False True
True
~~~

Line by line:

- `/` always gives a float (`3.5`); `//` divides and rounds down (`3`); `%` is the remainder. In Go, `7 / 2` is `3` for integers.
- `2**64` is 2 to the power 64. In Go, `int` stops at 2<sup>63</sup>−1 and wraps around (Go from zero, lesson 01); a Python `int` grows as big as it needs to, so it never overflows. It's slower for that.
- `0.1 + 0.2` isn't exactly `0.3`. It's the same 64-bit floating point as Go's `float64`, which can't store 0.1 exactly. Never compare floats with `==`; compare with a tolerance, or use whole numbers of a smaller unit.
- `count, ratio, label, done = ...` assigns four names at once. `type()` shows each value's type.
- `len("café")` is 4: Python's `str` counts characters. `.encode()` turns it into UTF-8 bytes, and that's 5, because `é` takes two bytes (Foundations 02, lesson 03). In Go, `len("café")` is 5: Go's `len` counts bytes.
- `word[0]` is the first character, `word[-1]` the last (negative indexes count from the end), `word[1:3]` is a **slice** from index 1 up to, not including, 3.
- `int("42")` turns text into a number; `str(42)` turns a number into text. Python never does it for you: `"42" + 1` is an error, not `"421"` or `43`.
- Zero, empty strings and empty collections count as false in an `if`; anything else is true, including the string `"0"`. `None` is Python's "no value", like Go's `nil`; test it with `is None`.

### Step 5: Collections

Create `measure/drills/containers.py`:

<!-- file: measure/drills/containers.py -->
~~~python
"""Lesson 06: lists, dictionaries, sets and tuples."""

# A list grows like a Go slice.
latencies = [12, 15, 11, 250, 14]
latencies.append(13)
print(latencies, len(latencies), latencies[0], latencies[-1], latencies[1:3])
print(sorted(latencies), max(latencies))

# Two names, one list.
other = latencies
other.append(999)
print(latencies[-1])
copy = list(latencies)
copy.append(1)
print(len(latencies), len(copy))

# A dictionary maps keys to values, and keeps the order keys were added.
ports = {"http": 80, "https": 443}
ports["ssh"] = 22
print(ports, ports["https"], ports.get("dns"), "ssh" in ports)
for name, port in ports.items():
    print(f"{name:>5} {port}")

# A set holds each value once.
seen = {"GET", "POST"}
seen.add("GET")
print(len(seen), "GET" in seen, sorted(seen))

# A tuple is a fixed group of values; unpack it into names.
address = ("127.0.0.1", 9000)
host, port = address
print(host, port)

# Comprehensions build a list from a loop in one expression.
squares = [n * n for n in range(5)]
slow = [ms for ms in latencies if ms > 100]
print(squares, slow)
~~~

~~~bash
uv run python drills/containers.py
~~~

<!-- run: cd measure && uv run python drills/containers.py | sed -n 3p | grep -qx 999 -->

~~~text
[12, 15, 11, 250, 14, 13] 6 12 13 [15, 11]
[11, 12, 13, 14, 15, 250] 250
999
7 8
{'http': 80, 'https': 443, 'ssh': 22} 443 None True
 http 80
https 443
  ssh 22
2 True ['GET', 'POST']
127.0.0.1 9000
[0, 1, 4, 9, 16] [250, 999]
~~~

- A **list** is ordered and changeable. `sorted()` returns a new sorted list and leaves the original alone.
- `other = latencies` doesn't copy anything: it's a second name for the same list, so appending through `other` changed `latencies` too. It's the shared backing array from Go from zero lesson 04, without the capacity rules: *every* assignment of a list shares it. `list(latencies)` makes a real copy.
- A **dict** (dictionary) is Go's map, with one difference you just saw: it keeps the order keys were added in. Go randomises map order on purpose. `ports["dns"]` would raise an error for a missing key; `ports.get("dns")` returns `None` instead. `in` tests whether a key is there.
- `f"{name:>5}"` right-aligns the name in 5 characters, like `%5s` in Go's `Printf`.
- A **set** keeps each value once, and checks membership quickly. Its order isn't fixed, so the drill sorts it before printing.
- A **tuple** is a fixed sequence that can't be changed. It's how Python returns several values from a function, and `host, port = address` **unpacks** it into names.
- A **comprehension** builds a list from a loop and a condition in one expression: "`ms`, for each `ms` in `latencies`, if `ms > 100`".

### Step 6: Functions

Create `measure/drills/functions.py`:

<!-- file: measure/drills/functions.py -->
~~~python
"""Lesson 06: functions."""


def greet(name: str, greeting: str = "Hello") -> str:
    """Return a greeting. greeting has a default, so callers may leave it out."""
    return f"{greeting}, {name}!"


def low_high(values: list[int]) -> tuple[int, int]:
    """Return the smallest and largest value: two results, as a tuple."""
    return min(values), max(values)


print(greet("Ada"))
print(greet("Ada", greeting="Hi"))
low, high = low_high([12, 15, 11, 250, 14])
print(low, high)
~~~

~~~bash
uv run python drills/functions.py
~~~

<!-- run: cd measure && uv run python drills/functions.py | sed -n 3p | grep -qx '11 250' -->

~~~text
Hello, Ada!
Hi, Ada!
11 250
~~~

- `def` defines a function. `name: str` and `-> str` are **type hints**: notes saying what the function expects and returns. Python itself doesn't check them (the "Break it" section shows what that means); editors and checkers such as `mypy` read them.
- `greeting: str = "Hello"` is a **default**, used when the caller leaves the argument out. `greeting="Hi"` passes an argument by name, which works for any parameter and makes calls easier to read.
- `return min(values), max(values)` returns a tuple, which the caller unpacks. It's Go's multiple return values.

### Step 7: A first test

Now a function worth testing. Create `measure/stats.py`:

<!-- file: measure/stats.py -->
~~~python
"""Summary statistics for request latencies."""


def summarize(values: list[float]) -> dict[str, float]:
    """Return the count, mean, minimum and maximum of values."""
    if not values:
        raise ValueError("cannot summarize an empty list")
    return {
        "count": len(values),
        "mean": sum(values) / len(values),
        "min": min(values),
        "max": max(values),
    }
~~~

- `if not values:` is true for an empty list.
- `raise ValueError(...)` raises an **exception**: the function stops, and the error travels up through every caller until something catches it, or the program stops with a message. It's Python's way of returning an error; lesson 07 shows how to catch one.
- `sum`, `len`, `min` and `max` are built-in functions.

Create `measure/test_stats.py`:

<!-- file: measure/test_stats.py -->
~~~python
import pytest

from stats import summarize


def test_summarize():
    assert summarize([12, 15, 11, 250, 14]) == {
        "count": 5,
        "mean": 60.4,
        "min": 11,
        "max": 250,
    }


def test_one_value():
    assert summarize([7.5]) == {"count": 1, "mean": 7.5, "min": 7.5, "max": 7.5}


def test_empty_list_is_an_error():
    with pytest.raises(ValueError, match="empty"):
        summarize([])
~~~

`pytest` finds files named `test_*.py` and functions named `test_*` in them, and runs them. A plain `assert` is enough: when it fails, pytest shows both sides of the comparison. `with pytest.raises(ValueError, match="empty"):` passes only if the code inside raises that exception with a message containing `empty`.

~~~bash
uv run pytest -v
~~~

<!-- run: cd measure && uv run pytest -q -->

~~~text
============================= test session starts ==============================
platform linux -- Python 3.14.7, pytest-9.2.0, pluggy-1.7.0 -- /home/ada/blueprint/internet/measure/.venv/bin/python
cachedir: .pytest_cache
rootdir: /home/ada/blueprint/internet/measure
configfile: pyproject.toml
collecting ... collected 3 items

test_stats.py::test_summarize PASSED                                     [ 33%]
test_stats.py::test_one_value PASSED                                     [ 66%]
test_stats.py::test_empty_list_is_an_error PASSED                        [100%]

============================== 3 passed in 0.10s ===============================
~~~

Then let `ruff` format the code and check it, as `gofmt` and `go vet` do for Go:

~~~bash
uv run ruff format . && uv run ruff check .
~~~

~~~text
6 files left unchanged
All checks passed!
~~~

<!-- run: cd measure && uv run ruff format --check . && uv run ruff check . -->

## Break it

**Indentation is syntax.** Make a file `bad.py` whose loop body isn't indented:

~~~python
for n in range(3):
print(n)
~~~

~~~bash
uv run python bad.py
~~~

~~~text
  File "/home/ada/blueprint/internet/measure/bad.py", line 2
    print(n)
    ^^^^^
IndentationError: expected an indented block after 'for' statement on line 1
~~~

Python refused to run any of it: the whole file is checked for syntax first. In Go, braces mark blocks and `gofmt` fixes the indentation; in Python, indentation *is* the block. Delete `bad.py`.

**Type hints aren't checked.** `summarize` says it takes a list of floats. Give it strings:

~~~bash
uv run python -c "from stats import summarize; summarize([\"12\", \"15\"])"
~~~

~~~text
Traceback (most recent call last):
  File "<string>", line 1, in <module>
    from stats import summarize; summarize(["12", "15"])
                                 ~~~~~~~~~^^^^^^^^^^^^^^
  File "/home/ada/blueprint/internet/measure/stats.py", line 10, in summarize
    "mean": sum(values) / len(values),
            ~~~^^^^^^^^
TypeError: unsupported operand type(s) for +: 'int' and 'str'
~~~

Python accepted the call and failed only when `sum` tried to add `0` and `"12"`. This is a **traceback**: the chain of calls that led to the error, the outermost first, ending with the line that failed and the exception. Read it from the bottom up. In Go, this wouldn't have compiled. Python programs rely on tests to catch what a compiler would, which is why every Python file in this course has them.

## Check it

~~~bash
uv run ruff format --check . && uv run ruff check . && uv run pytest -q
~~~

Then, from memory, in the REPL: make a dictionary of three status codes and their names, loop over it printing each pair, and build a list of only the 4xx codes with a comprehension.

That proves you can set up a Python project, use its basic types, and write and test a function. It doesn't cover reading files, handling errors, or classes: those are next.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `uv: command not found` | `~/.local/bin` isn't on your `PATH` yet | Open a new terminal; if that doesn't help, add `export PATH="$HOME/.local/bin:$PATH"` to `~/.profile` |
| `sha256sum: WARNING: 1 computed checksum did NOT match` | The download is broken or not what was published | Delete it and download again; never use a file that fails the check |
| `ModuleNotFoundError: No module named 'pytest'` | Running Python outside the project, or without `uv run` | `cd` into `measure`, and run everything as `uv run ...` |
| `IndentationError` or `unexpected indent` | Mixed or missing indentation | Indent with 4 spaces, and let `uv run ruff format .` fix the rest |
| A drill named `random.py`, `json.py` or `collections.py` breaks other imports | Your file has the same name as a standard library module, and Python finds yours first | Rename it |
| `TypeError: unsupported operand type(s)` | Mixing types, such as text and a number | Convert explicitly with `int()`, `float()` or `str()` |
