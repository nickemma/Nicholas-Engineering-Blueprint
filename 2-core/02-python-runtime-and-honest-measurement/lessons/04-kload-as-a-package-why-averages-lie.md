# 04 `kload` as a package: why averages lie

> Module: Python runtime and honest measurement · Time: ~3 h · Builds on: 03; Foundations 04 lessons 07 and 09

## The problem

Ninety-nine requests take 10 ms and one takes 5,000 ms. The mean is about 60 ms: a number that describes no request that actually happened. Users don't experience the mean. They experience their own request, and they remember the slow ones.

Foundations 04's `measure.py` was one script. `kload` will be a real tool: several modules, a command with subcommands, and tests that run without a network. This lesson turns the uv project you made in lesson 01 into that package, starting with the statistics, because every number `kload` prints rests on them.

## The mental model

~~~text
 ~/blueprint/kload/
 ├── pyproject.toml          the project: name, dependencies, the `kload` command, ruff's rules
 ├── src/kload/              the package (import kload.stats, kload.cli)
 │   ├── __init__.py
 │   ├── stats.py            percentile, Summary, summarize
 │   └── cli.py              main(argv): parse the arguments, run a subcommand
 ├── tests/                  pytest finds test_*.py here
 └── drills/                 lessons 01–03

 `uv run kload summarize FILE` ─▶ [project.scripts] kload = "kload.cli:main" ─▶ main()
~~~

- The **src layout** keeps the package under `src/`, so tests import the installed package, the way a user would, never a stray file that happens to sit in the current folder.
- **`[project.scripts]`** names a command and the function it calls. uv installs the project into `.venv`, so `uv run kload` runs `kload.cli.main()`.
- **Subcommands** (`kload summarize`, later `kload load`, `kload compare`) each get their own arguments, like `git commit` and `git log`.
- **`main(argv)`** takes its arguments as a list, so a test can call `main(["summarize", "file.txt"])` and check what it printed and returned, without starting a process.

## The pattern

**The command line is a thin layer over functions you can test.** `stats.py` knows nothing about files or arguments; `cli.py` reads the file, calls `summarize`, and prints. The tests check each on its own.

## Build it

### Step 1: The package and its tools

`uv init --package` gave you a placeholder `main` in `src/kload/__init__.py`. Replace the file with a one-line description of the package:

<!-- file: src/kload/__init__.py -->
~~~python
"""kload: an open-loop load generator, and the analysis behind it."""
~~~

In `pyproject.toml`, describe the project and point the command at the module you're about to write. Change:

<!-- edit: pyproject.toml -->
~~~toml
description = "Add your description here"
~~~

to:

~~~toml
description = "An open-loop load generator, and the analysis behind it"
~~~

and change:

<!-- edit: pyproject.toml -->
~~~toml
kload = "kload:main"
~~~

to:

~~~toml
kload = "kload.cli:main"
~~~

Add ruff's settings at the end of `pyproject.toml`, the same as Foundations 04's:

<!-- append: pyproject.toml -->
~~~toml
[tool.ruff]
line-length = 100

[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP"]
~~~

and add pytest and ruff as development tools:

~~~bash
uv add --dev 'pytest>=9' 'ruff>=0.14'
~~~

<!-- run: uv add --dev 'pytest>=9' 'ruff>=0.14' -->

### Step 2: The statistics

Create `src/kload/stats.py`. `percentile` is Foundations 04's nearest-rank function; `summarize` now returns a frozen dataclass instead of a dictionary:

<!-- file: src/kload/stats.py -->
~~~python
"""Summary statistics for request latencies."""

import math
from collections.abc import Sequence
from dataclasses import dataclass


@dataclass(frozen=True)
class Summary:
    """The numbers that describe a batch of latencies."""

    count: int
    mean: float
    p50: float
    p99: float
    max: float


def percentile(values: Sequence[float], p: float) -> float:
    """Return the p-th percentile of values, by the nearest-rank method.

    Sort the values and take the one at position ceil(p/100 * n), counting
    from 1. The answer is always a value that really occurred.
    """
    if not values:
        raise ValueError("cannot take a percentile of an empty list")
    if not 0 < p <= 100:
        raise ValueError(f"p must be above 0 and at most 100, not {p}")
    ordered = sorted(values)
    rank = math.ceil(p / 100 * len(ordered))
    return ordered[rank - 1]


def summarize(values: Sequence[float]) -> Summary:
    """Describe values by their count, mean, p50, p99 and maximum."""
    if not values:
        raise ValueError("cannot summarize an empty list")
    return Summary(
        count=len(values),
        mean=sum(values) / len(values),
        p50=percentile(values, 50),
        p99=percentile(values, 99),
        max=max(values),
    )
~~~

- `Sequence[float]` accepts a list, a tuple, or anything else you can index and take the length of. `percentile` never changes its input: `sorted` returns a new list, where `values.sort()` would have reordered the caller's.
- `@dataclass(frozen=True)` writes the constructor, `==` and a readable printout for you, and refuses changes after it's made: a `Summary` is a value, like a Go struct you only ever copy.

Create `tests/test_stats.py`:

<!-- file: tests/test_stats.py -->
~~~python
import pytest

from kload.stats import Summary, percentile, summarize


@pytest.mark.parametrize(
    ("p", "expected"), [(1, 1), (10, 1), (50, 5), (90, 9), (99, 10), (100, 10)]
)
def test_percentile_nearest_rank(p, expected):
    assert percentile([3, 1, 4, 10, 5, 9, 2, 6, 8, 7], p) == expected


def test_percentile_leaves_the_input_alone():
    values = [3, 1, 2]
    percentile(values, 50)
    assert values == [3, 1, 2]


@pytest.mark.parametrize("p", [0, -1, 101])
def test_percentile_rejects_p_out_of_range(p):
    with pytest.raises(ValueError, match="p must be above 0"):
        percentile([1, 2, 3], p)


def test_summarize():
    values = [float(v) for v in range(1, 101)]
    assert summarize(values) == Summary(count=100, mean=50.5, p50=50, p99=99, max=100)


def test_one_slow_request_in_a_hundred_moves_only_the_mean_and_the_max():
    summary = summarize([10.0] * 99 + [5000.0])
    assert summary.mean == pytest.approx(59.9)  # describes no request that happened
    assert (summary.p50, summary.p99) == (10.0, 10.0)  # 99 of 100 were 10 ms
    assert summary.max == 5000.0


def test_two_slow_requests_in_a_hundred_reach_the_p99():
    assert summarize([10.0] * 98 + [5000.0] * 2).p99 == 5000.0


def test_summary_is_frozen():
    summary = summarize([1.0])
    with pytest.raises(AttributeError):
        summary.count = 2


def test_summarize_rejects_empty_input():
    with pytest.raises(ValueError, match="empty"):
        summarize([])
~~~

`@pytest.mark.parametrize` runs one test once per row: Python's table-driven test. `pytest.approx` compares floats with a tolerance, because `59.9` can't be stored exactly in binary.

~~~bash
uv run pytest -q
~~~

~~~text
...............                                                          [100%]
15 passed in 0.02s
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

### Step 3: A command with subcommands

Create `src/kload/cli.py`:

<!-- file: src/kload/cli.py -->
~~~python
"""The kload command line."""

import argparse
import sys
from pathlib import Path

from kload.stats import summarize


def cmd_summarize(args: argparse.Namespace) -> int:
    values = [float(word) for word in Path(args.file).read_text().split()]
    summary = summarize(values)
    for name in ("count", "mean", "p50", "p99", "max"):
        print(f"{name:>5}: {getattr(summary, name):g}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="kload", description=__doc__)
    sub = parser.add_subparsers(required=True)

    p = sub.add_parser("summarize", help="summarize the numbers in a file")
    p.add_argument("file")
    p.set_defaults(handler=cmd_summarize)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
~~~

- `add_subparsers(required=True)` makes the first word a subcommand; `set_defaults(handler=cmd_summarize)` attaches the function that runs it.
- `main` returns an exit status, and `sys.exit(main())` hands it to the shell. argparse exits with status 2, and a usage message, on arguments it can't parse.

Create `tests/test_cli.py`:

<!-- file: tests/test_cli.py -->
~~~python
import pytest

from kload.cli import main


def test_summarize_prints_each_statistic(tmp_path, capsys):
    data = tmp_path / "latencies.txt"
    data.write_text("12 15\n11 250\n14\n")
    assert main(["summarize", str(data)]) == 0
    out = capsys.readouterr().out
    assert "count: 5" in out
    assert "  p50: 14" in out
    assert "  max: 250" in out


def test_unknown_command_is_a_usage_error(capsys):
    with pytest.raises(SystemExit) as caught:
        main(["fly"])
    assert caught.value.code == 2
    assert "invalid choice" in capsys.readouterr().err
~~~

`tmp_path` and `capsys` are pytest **fixtures**: arguments pytest fills in for you, a fresh temporary folder and a capture of everything the test printed.

~~~bash
uv run pytest -q
uv run kload --help
~~~

~~~text
.................                                                        [100%]
17 passed in 0.04s
usage: kload [-h] {summarize} ...

The kload command line.

positional arguments:
  {summarize}
    summarize  summarize the numbers in a file

options:
  -h, --help   show this help message and exit
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

### Step 4: Why averages lie

Make a file of 99 requests at 10 ms and one at 5,000 ms, and summarize it. Then make it two slow requests in a hundred:

~~~bash
uv run python -c "print('\n'.join(['10'] * 99 + ['5000']))" > /tmp/one-slow.txt
uv run kload summarize /tmp/one-slow.txt
uv run python -c "print('\n'.join(['10'] * 98 + ['5000'] * 2))" > /tmp/two-slow.txt
uv run kload summarize /tmp/two-slow.txt
~~~

~~~text
count: 100
 mean: 59.9
  p50: 10
  p99: 10
  max: 5000
count: 100
 mean: 109.8
  p50: 10
  p99: 5000
  max: 5000
~~~

<!-- run: uv run python -c "print('\n'.join(['10'] * 99 + ['5000']))" > one-slow.txt && uv run kload summarize one-slow.txt | grep -q "p99: 10$" && rm one-slow.txt -->

Read the two summaries side by side:

- The **mean** was 59.9 ms, then 109.8 ms: never a time any request took. It moved, but it can't tell you whether one request in a hundred was slow by 5 seconds or every request by 50 ms.
- The **p50** stayed at 10: the typical request was fine both times.
- The **p99** stayed at 10 with one slow request, and jumped to 5,000 with two. With 100 values, the p99 is the 99th value in order, so it ignores exactly one outlier. A percentile tells you nothing about the requests beyond it.
- The **max** caught both, and would equally catch one freak request in a million.

So `kload` reports percentiles and the maximum, never the mean alone. And because a percentile from a small sample can only see so far into the tail, it keeps every raw latency, so you can count the slow ones yourself.

## Break it

**Sort in place.** In `percentile`, replace `ordered = sorted(values)` with `values.sort()` and `ordered = values`, and run the tests:

~~~text
tests/test_stats.py:16: AssertionError
=========================== short test summary info ============================
FAILED tests/test_stats.py::test_percentile_leaves_the_input_alone - assert [...
1 failed, 16 passed in 0.06s
~~~

`test_percentile_leaves_the_input_alone` failed: the caller's list came back reordered. Ruff can't see this kind of bug; a test that checks the input afterwards can. Put it back.

## Check it

~~~bash
uv run ruff format --check . && uv run ruff check . && uv run pytest -q
~~~

Then, from memory: compute the nearest-rank p95 of the numbers 1 to 20 by hand. Why does the src layout matter for tests? What does `[project.scripts]` do? What did the p99 miss in the first file, and what caught it?

This proves `kload`'s statistics are right on the cases the tests cover. It doesn't prove that the latencies it will feed them are right: that's lessons 06 and 07.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `ModuleNotFoundError: No module named 'kload.cli'` | `cli.py` not in `src/kload/`, or `[project.scripts]` still says `kload:main` | Check the path and the edit |
| `kload: error: the following arguments are required` | No subcommand | `uv run kload summarize FILE` |
| `ValueError: could not convert string to float` | A word in the file that isn't a number | `summarize` expects numbers separated by spaces or lines |
| A change to the code has no effect | Running a copied project whose `.venv` points at the old folder | Delete `.venv`; `uv run` rebuilds it |
| `E501 Line too long` | A line over 100 characters | `uv run ruff format .` wraps most of them |
