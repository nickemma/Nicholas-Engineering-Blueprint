# 07 Python from zero: classes, files, errors and tests

> Module: Python and the internet from zero · Time: ~5 h · Builds on: 06

## The problem

Lesson 09's measurement script will produce a thousand results and has to keep them somewhere: in memory as tidy values, then on disk as a file that the gate and your later analysis can read back. Reading a file is also where programs meet the outside world's mistakes: a missing file, a damaged line, a number that isn't a number. This lesson builds that piece, `results.py`, and on the way covers how Python groups data into classes, reads and writes files, and handles errors, all under tests.

## The mental model

~~~text
 Result(request=7, connection=2, size=4096, latency_ms=1.235)     a dataclass: named fields
        │  write_csv                                    ▲
        ▼                                               │  read_csv
 results.csv                                            │
   request,connection,bytes,latency_ms\r\n     ─────────┘  each row turned back into a Result;
   7,2,4096,1.235\r\n                                       a bad row raises ValueError naming its line

 an exception travels up through the callers until an except catches it:
   main() ──calls──▶ read_csv() ──calls──▶ float("fast")  ✗ ValueError
     ▲ except ValueError: print a message, exit 1   ◀────────── raised here, passes through read_csv
~~~

## The pattern

**Raise early, catch at the edge.** Functions deep inside a program raise an exception the moment something's wrong, with a message that says what and where. Only the outermost code, the part that talks to the user, catches it, prints one clear line and chooses an exit code. It's Go's "return the error up" with less typing: everything in between passes it on without a word.

## Build it

### Step 1: A class, by hand and as a dataclass

A **class** defines a new type: what data each value of it holds, and what you can do with it (its **methods**). Create `measure/drills/classes.py`:

<!-- file: measure/drills/classes.py -->
~~~python
"""Lesson 07: a class written by hand, then the same as a dataclass."""

from dataclasses import dataclass


class Request:
    """One request, written by hand."""

    def __init__(self, number: int, latency_ms: float) -> None:
        self.number = number
        self.latency_ms = latency_ms

    def slow(self, limit_ms: float = 100) -> bool:
        return self.latency_ms > limit_ms


a = Request(1, 250.0)
b = Request(1, 250.0)
print(a.slow(), a.slow(limit_ms=300))
print(a == b)
print(a)


@dataclass(frozen=True)
class Timed:
    """The same, as a dataclass: __init__, ==, and printing come for free."""

    number: int
    latency_ms: float

    def slow(self, limit_ms: float = 100) -> bool:
        return self.latency_ms > limit_ms


c = Timed(1, 250.0)
d = Timed(1, 250.0)
print(c.slow(), c == d)
print(c)
~~~

~~~bash
uv run python drills/classes.py
~~~

<!-- run: cd measure && uv run python drills/classes.py | tail -1 | grep -qx 'Timed(number=1, latency_ms=250.0)' -->

~~~text
True False
False
<__main__.Request object at 0x74000daeb8c0>
True True
Timed(number=1, latency_ms=250.0)
~~~

- `__init__` runs when you create a value, `Request(1, 250.0)`, and sets its fields. `self` is the value being created or used; Python passes it to every method as the first argument, the way Go's receiver works (`func (r *Request) slow()`).
- `a.slow()` calls a method. Inside it, `self.latency_ms` is `a`'s field.
- `a == b` is `False`, though both hold the same numbers: for a plain class, `==` asks "is this the same object?", unless you write a method that says otherwise. `print(a)` is just as unhelpful: a type name and a memory address, which will differ on your machine.
- `@dataclass` is a **decorator**: it takes the class below it and adds methods. From the list of fields it writes `__init__`, an `==` that compares the fields, and a readable printout. `frozen=True` makes the fields read-only, like a value you can pass around without worrying that someone changes it.

Try to change a frozen one:

~~~bash
uv run python -c "from drills.classes import Timed; t = Timed(1, 250.0); t.latency_ms = 1.0"
~~~

~~~text
True False
False
<drills.classes.Request object at 0x72c57c113b60>
True True
Timed(number=1, latency_ms=250.0)
Traceback (most recent call last):
  File "<string>", line 1, in <module>
    from drills.classes import Timed; t = Timed(1, 250.0); t.latency_ms = 1.0
                                                           ^^^^^^^^^^^^
  File "<string>", line 16, in __setattr__
dataclasses.FrozenInstanceError: cannot assign to field 'latency_ms'
~~~

Importing `drills.classes` ran the whole file first, so its prints come before the error. Then the assignment failed: a frozen value can't be changed after it's made; you make a new one.

### Step 2: Exceptions

When an operation fails, Python **raises** an exception. If nothing catches it, the program stops and prints a traceback:

~~~bash
uv run python -c "from pathlib import Path; Path(\"/nope\").read_text()"
~~~

~~~text
Traceback (most recent call last):
  File "<string>", line 1, in <module>
    from pathlib import Path; Path("/nope").read_text()
                              ~~~~~~~~~~~~~~~~~~~~~~~^^
  File "/home/ada/.local/share/uv/python/cpython-3.14.7-linux-x86_64-gnu/lib/python3.14/pathlib/__init__.py", line 787, in read_text
    with self.open(mode='r', encoding=encoding, errors=errors, newline=newline) as f:
         ~~~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  File "/home/ada/.local/share/uv/python/cpython-3.14.7-linux-x86_64-gnu/lib/python3.14/pathlib/__init__.py", line 771, in open
    return io.open(self, mode, buffering, encoding, errors, newline)
           ~~~~~~~^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
FileNotFoundError: [Errno 2] No such file or directory: '/nope'
~~~

Read it from the bottom: the exception type, `FileNotFoundError`, with its message. Above it, each call that led there, innermost last. `[Errno 2]` is the operating system's error number for "no such file", the same `ENOENT` that Go reports as `no such file or directory`.

To handle it instead, wrap the code in `try` and catch the type you expect with `except`. Create `measure/drills/errors.py`:

<!-- file: measure/drills/errors.py -->
~~~python
"""Lesson 07: exceptions."""

from pathlib import Path


def first_line(path: Path) -> str:
    """Return the first line of a file, without its newline."""
    with path.open() as f:
        return f.readline().rstrip("\n")


def port_from(text: str) -> int:
    """Turn text into a port number, or raise ValueError saying why not."""
    try:
        port = int(text)
    except ValueError as err:
        raise ValueError(f"port {text!r} is not a number") from err
    if not 1 <= port <= 65535:
        raise ValueError(f"port {port} is out of range 1-65535")
    return port


print(first_line(Path("hello.py")))
try:
    first_line(Path("/nope"))
except FileNotFoundError as err:
    print("caught:", err)

for text in ["9000", "http", "70000"]:
    try:
        print("port", port_from(text))
    except ValueError as err:
        print("bad:", err)
~~~

~~~bash
uv run python drills/errors.py
~~~

<!-- run: cd measure && uv run python drills/errors.py | tail -1 | grep -qx 'bad: port 70000 is out of range 1-65535' -->

~~~text
"""The first Python program: print, variables, a list and a loop."""
caught: [Errno 2] No such file or directory: '/nope'
port 9000
bad: port 'http' is not a number
bad: port 70000 is out of range 1-65535
~~~

- `Path` (from `pathlib`) is a file path with methods: `.open()`, `.read_text()`, `.exists()`, and `/` to join paths.
- `with path.open() as f:` opens the file, and closes it when the block ends, however it ends: normally, by `return`, or by an exception. It's Go's `defer f.Close()`, built into the syntax. Use `with` for anything that must be closed.
- `except FileNotFoundError as err:` catches only that type. Anything else still stops the program, which is what you want: catch only what you know how to handle.
- `raise ValueError(...) from err` raises a new, clearer exception and keeps the original as its cause, like `%w` in Go's `fmt.Errorf`. A traceback shows both.
- `{text!r}` formats a value as Python source, with quotes: `'http'`. It makes empty strings and stray spaces visible in messages.
- `1 <= port <= 65535` is a chained comparison: both must hold.

### Step 3: Results, to a file and back

Now the real piece. Create `measure/results.py`:

<!-- file: measure/results.py -->
~~~python
"""One result per request, saved to and loaded from a CSV file."""

import csv
from dataclasses import dataclass
from pathlib import Path

HEADER = ["request", "connection", "bytes", "latency_ms"]


@dataclass(frozen=True)
class Result:
    """How one request went."""

    request: int
    connection: int
    size: int
    latency_ms: float


def write_csv(path: Path, results: list[Result]) -> None:
    """Write results to path, one row per request, after a header row."""
    with path.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(HEADER)
        for r in results:
            writer.writerow([r.request, r.connection, r.size, f"{r.latency_ms:.3f}"])


def read_csv(path: Path) -> list[Result]:
    """Read results written by write_csv. A bad row is an error naming its line."""
    with path.open(newline="") as f:
        rows = csv.reader(f)
        if next(rows, None) != HEADER:
            raise ValueError(f"{path}: the first line must be {','.join(HEADER)}")
        results = []
        for line, row in enumerate(rows, start=2):
            try:
                request, connection, size, latency_ms = row
                results.append(Result(int(request), int(connection), int(size), float(latency_ms)))
            except ValueError as err:
                raise ValueError(f"{path}, line {line}: {err}") from err
    return results
~~~

- **CSV** (comma-separated values) is the simplest table format: one row per line, fields separated by commas, and the first row naming the columns. Every spreadsheet, database and data library reads it. The `csv` module handles the awkward parts, such as a field that contains a comma.
- `path.open("w", newline="")` opens for writing, replacing what was there. `newline=""` is what the `csv` module asks for: it writes its own line endings, `\r\n`, as the CSV standard says.
- The field is called `size` in Python, but the column is `bytes`: `bytes` is also the name of a built-in type, and a field shouldn't hide it.
- `f"{r.latency_ms:.3f}"` writes three decimal places: a thousandth of a millisecond, a microsecond, finer than anything you'll measure.
- `next(rows, None)` takes the first row, or `None` if the file is empty.
- `enumerate(rows, start=2)` counts the rows as it goes, starting at 2 because the header was line 1. A message that names the line saves whoever has to fix the file from searching.
- `request, connection, size, latency_ms = row` unpacks the row. If it doesn't have exactly four fields, that raises a `ValueError` too, which the same `except` catches.

Write one result and read it back:

~~~bash
uv run python -c "from pathlib import Path; from results import Result, write_csv, read_csv; write_csv(Path(\"try.csv\"), [Result(0, 0, 16, 0.4567)]); print(repr(Path(\"try.csv\").read_bytes())); print(read_csv(Path(\"try.csv\")))" && rm try.csv
~~~

~~~text
b'request,connection,bytes,latency_ms\r\n0,0,16,0.457\r\n'
[Result(request=0, connection=0, size=16, latency_ms=0.457)]
~~~

`read_bytes()` shows the file exactly, `\r\n` included; `0.4567` was written as `0.457`. And a file with a bad row:

~~~bash
printf "request,connection,bytes,latency_ms\n0,0,16,fast\n" > bad.csv
uv run python -c "from pathlib import Path; from results import read_csv; read_csv(Path(\"bad.csv\"))" 2>&1 | tail -3
rm bad.csv
~~~

~~~text
  File "/home/ada/blueprint/internet/measure/results.py", line 41, in read_csv
    raise ValueError(f"{path}, line {line}: {err}") from err
ValueError: bad.csv, line 2: could not convert string to float: 'fast'
~~~

The message says which file, which line and what was wrong, and `from err` kept `float()`'s own message in it.

### Step 4: Tests, with fixtures and tables

Create `measure/test_results.py`:

<!-- file: measure/test_results.py -->
~~~python
import pytest

from results import Result, read_csv, write_csv


def test_round_trip(tmp_path):
    path = tmp_path / "results.csv"
    results = [Result(0, 0, 16, 0.25), Result(1, 1, 256, 12.5)]
    write_csv(path, results)
    assert read_csv(path) == results


def test_file_layout(tmp_path):
    path = tmp_path / "results.csv"
    write_csv(path, [Result(7, 2, 4096, 1.23456)])
    assert path.read_bytes() == b"request,connection,bytes,latency_ms\r\n7,2,4096,1.235\r\n"


def test_missing_header(tmp_path):
    path = tmp_path / "results.csv"
    path.write_text("7,2,4096,1.235\n")
    with pytest.raises(ValueError, match="first line"):
        read_csv(path)


@pytest.mark.parametrize(
    ("row", "error"),
    [
        ("7,2,4096\n", "not enough values"),
        ("7,2,4096,fast\n", "could not convert"),
        ("seven,2,4096,1.0\n", "invalid literal"),
    ],
)
def test_bad_row_names_its_line(tmp_path, row, error):
    path = tmp_path / "results.csv"
    path.write_text("request,connection,bytes,latency_ms\n0,0,16,0.5\n" + row)
    with pytest.raises(ValueError, match=f"line 3: {error}"):
        read_csv(path)
~~~

- `tmp_path` is a **fixture**: name it as a parameter, and pytest passes in a fresh, empty temporary folder for that test alone, and cleans up afterwards. Tests that write files never touch your own.
- `test_round_trip` checks the most important property: what you write, you read back unchanged. Dataclass `==` makes the comparison one line.
- `test_file_layout` pins the exact bytes, because the gate and other programs will read this file.
- `@pytest.mark.parametrize` is Python's table-driven test (Go from zero, lesson 07): the test runs once per row, and each row shows up separately in the results.

~~~bash
uv run pytest -v test_results.py
~~~

<!-- run: cd measure && uv run pytest -q test_results.py -->

~~~text
============================= test session starts ==============================
platform linux -- Python 3.14.7, pytest-9.2.0, pluggy-1.7.0 -- /home/ada/blueprint/internet/measure/.venv/bin/python
cachedir: .pytest_cache
rootdir: /home/ada/blueprint/internet/measure
configfile: pyproject.toml
collecting ... collected 6 items

test_results.py::test_round_trip PASSED                                  [ 16%]
test_results.py::test_file_layout PASSED                                 [ 33%]
test_results.py::test_missing_header PASSED                              [ 50%]
test_results.py::test_bad_row_names_its_line[7,2,4096\n-not enough values] PASSED [ 66%]
test_results.py::test_bad_row_names_its_line[7,2,4096,fast\n-could not convert] PASSED [ 83%]
test_results.py::test_bad_row_names_its_line[seven,2,4096,1.0\n-invalid literal] PASSED [100%]

============================== 6 passed in 0.05s ===============================
~~~

## Break it

**Change the file format.** In `write_csv`, write two decimal places instead of three (`:.2f`), and run the tests:

~~~bash
uv run pytest -q test_results.py
~~~

~~~text
.F....                                                                   [100%]
=================================== FAILURES ===================================
_______________________________ test_file_layout _______________________________

tmp_path = PosixPath('/tmp/pytest-of-ada/pytest-1/test_file_layout0')

    def test_file_layout(tmp_path):
        path = tmp_path / "results.csv"
        write_csv(path, [Result(7, 2, 4096, 1.23456)])
>       assert path.read_bytes() == b"request,connection,bytes,latency_ms\r\n7,2,4096,1.235\r\n"
E       AssertionError: assert b'request,con...4096,1.23\r\n' == b'request,con...096,1.235\r\n'
E         
E         At index 50 diff: b'\r' != b'5'
E         Use -v to get more diff

test_results.py:16: AssertionError
=========================== short test summary info ============================
FAILED test_results.py::test_file_layout - AssertionError: assert b'request,c...
1 failed, 5 passed in 0.07s
~~~

One test caught it: `test_file_layout`, which shows the exact bytes that differ, `1.23` where `1.235` was expected. `test_round_trip` still passed, because its values, `0.25` and `12.5`, survive two decimal places. A test only catches what its data exercises, which is why `test_file_layout` uses a number with more decimals than the format keeps. A change to a file format is a change to a promise other programs rely on, and it should break a test. Put `.3f` back.

## Check it

~~~bash
uv run ruff format --check . && uv run ruff check . && uv run pytest -q
~~~

~~~text
10 files already formatted
All checks passed!
.........                                                                [100%]
9 passed in 0.04s
~~~

<!-- run: cd measure && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

That proves you can define data types, write and read files, raise and catch exceptions with useful messages, and test all of it. What's missing is the network: the next lesson connects Python to your echo server, many connections at once.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `TypeError: Result.__init__() missing 1 required positional argument` | A value was created with too few fields | Pass every field, in order, or by name |
| `dataclasses.FrozenInstanceError: cannot assign to field` | Changing a frozen dataclass | Make a new value instead: `dataclasses.replace(r, latency_ms=1.0)` |
| The CSV has blank lines between rows on Windows | The file was opened without `newline=""` | Always pass `newline=""` when using the `csv` module |
| `ValueError: not enough values to unpack` | A row has fewer fields than names on the left | Check the file; `read_csv` reports which line |
| A test passes alone but fails with others | Tests share a file or a global | Use `tmp_path`, so each test has its own folder |
| `fixture 'tmp_path' not found` | A typo in the parameter name | Fixtures are matched by exact name |
