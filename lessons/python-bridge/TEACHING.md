# Python Bridge teaching: measure what you built

Phase 1 left you with a service that *feels* fast. This bridge teaches Python by building the tool that tells you whether it **is** fast: how fast, for whom, and how you'd know if a change made it worse. Along the way you'll learn why averages lie, why most homemade benchmarks are wrong in the same way, and how a measuring tool can become the bottleneck it was meant to find.

**The goal:** `kload`, a tested Python command-line tool. It talks to the Phase 1 API, generates load on a fixed schedule, saves raw results with the settings that produced them, and turns them into percentiles and plots.

**Time:** about 2 weeks. **Before you start:** finish Phase 1 and be able to run its server.

**Why Python now:** from Phase 2 on, every experiment (killing workers, partitions, slow networks, the Phase 7 evaluation and ML pipeline) is driven and analysed in Python. Go builds the system; Python measures it and, later, learns from its data.

| Step | What you add |
|---|---|
| 1 | Python, uv, a first function and a first test |
| 2 | Percentiles, dataclasses, parametrised tests |
| 3 | A real package and a command-line interface |
| 4 | Classes, exceptions, and an HTTP client tested without a network |
| 5 | `asyncio`, open-loop load, and coordinated omission |
| 6 | pandas, matplotlib, and three real experiments |

## Install uv

[uv](https://docs.astral.sh/uv/) installs Python itself, creates isolated environments, and manages dependencies, in one fast tool.

~~~bash
curl -LsSf https://astral.sh/uv/install.sh | sh
uv --version
~~~

Open a new terminal afterwards so your shell finds `uv`.

### Go and Python side by side

You know Go now. Most of Python maps across directly. These are the differences that trip people up:

| Idea | Go | Python |
|---|---|---|
| Blocks | `{ }` | **Indentation** (4 spaces). The indentation *is* the syntax |
| Types | Checked by the compiler | Checked at **run time**. Type hints (`x: int`) are documentation plus tooling; Python itself doesn't enforce them |
| Errors | Returned values: `if err != nil` | **Exceptions**: `raise`, and `try`/`except` |
| Visibility | Capital letter = exported | A leading `_` means "private by convention"; nothing is enforced |
| Formatting | `gofmt` | `ruff format` |
| Vetting | `go vet` | `ruff check` |
| Tests | `go test`, `func TestX(t *testing.T)` | `pytest`, `def test_x():` with plain `assert` |
| Modules | `go.mod` | `pyproject.toml`, plus `uv.lock` for exact versions (like `go.sum`) |
| Concurrency | Goroutines run in parallel | One thread runs Python at a time (the GIL, being phased out in newer versions). For network I/O you use `asyncio` |

---

## Step 1: A first script, a first function, a first test
<!-- run: uv init --bare --name kload --python 3.12 && uv python pin 3.12 -->

**The problem.** You need the basics: running Python, isolating a project's dependencies, writing a function, and testing it.

**New ideas.**

- A **virtual environment** (`.venv`) is a private folder of packages for one project, so projects never fight over versions. uv creates it automatically the first time you run anything.
- `pyproject.toml` describes the project. The **dependency group** `dev` lists tools used only while developing (pytest, ruff).
- `uv run <command>` runs a command inside the project's environment, creating or updating it first if needed.

Set up a practice folder from the repository root:

~~~bash
cd lessons/python-bridge
mkdir -p practice && cd practice
uv init --bare --name kload --python 3.12
uv add --dev pytest ruff
~~~

`uv init --bare` writes a minimal `pyproject.toml`, and `uv add --dev` adds the tools and writes `uv.lock`. Open `pyproject.toml` and make it match this. Fill in the description, and add the `[tool.ruff]` section, which sets the line length and turns on extra lint rules: `E`/`F` for errors, `I` for import order, `B` for likely bugs, `UP` for modern syntax.

<!-- file: pyproject.toml -->
~~~toml
[project]
name = "kload"
version = "0.1.0"
description = "Load generation and latency analysis for the KESTREL jobs API"
requires-python = ">=3.12"
dependencies = []

[dependency-groups]
dev = [
    "pytest>=8",
    "ruff>=0.8",
]

[tool.ruff]
line-length = 100

[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP"]
~~~

Create `hello.py`:

<!-- file: hello.py -->
~~~python
"""The first Python program: print, variables, a list and a loop."""

name = "Kestrel"
latencies_ms = [12, 15, 11, 250, 14]

print(f"Hello, {name}!")
print(f"{len(latencies_ms)} requests")
for latency in latencies_ms:
    if latency > 100:
        print(f"slow: {latency} ms")
~~~

- The first line in triple quotes is a **docstring**: documentation attached to the module.
- There's no `var` or `:=`. Assigning a name creates it.
- `[12, 15, ...]` is a **list**, Python's growable array (like a Go slice).
- `f"Hello, {name}!"` is an **f-string**: expressions inside `{}` are filled in.
- `for latency in latencies_ms:` loops over items. The colon starts a block, and the indented lines are the body. There are no parentheses around conditions.

~~~bash
uv run python hello.py
~~~

~~~text
Hello, Kestrel!
5 requests
slow: 250 ms
~~~

Now a function and its test. Create `stats.py`:

<!-- file: stats.py -->
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

- `def summarize(values: list[float]) -> dict[str, float]:` declares a function with **type hints**: `values` should be a list of floats, and it returns a **dict** (a map) from strings to floats.
- `if not values:` is true for an empty list. Empty collections, `0`, `""` and `None` all count as false.
- `raise ValueError(...)` throws an **exception**: the function stops, and the error travels up until something catches it. This is Python's equivalent of returning an error.
- `sum`, `len`, `min` and `max` are built-in functions.

Create `test_stats.py`:

<!-- file: test_stats.py -->
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

pytest finds files named `test_*.py` and functions named `test_*`, and runs them. A plain `assert` is enough: when it fails, pytest shows both sides of the comparison. `with pytest.raises(ValueError, match="empty"):` passes only if the code inside raises that exception with a matching message.

~~~bash
uv run pytest -v
uv run ruff format .
uv run ruff check .
~~~

**Break it.**

1. Make a file containing a `for` loop whose body isn't indented, and run it:

   ~~~text
     File "bad.py", line 2
       print(x)
       ^
   IndentationError: expected an indented block after 'for' statement on line 1
   ~~~

   In Go, braces define blocks. In Python, indentation does.
2. Type hints aren't enforced. Run `uv run python -c "from stats import summarize; summarize(['12', '15'])"`:

   ~~~text
   TypeError: unsupported operand type(s) for +: 'int' and 'str'
   ~~~

   Python accepted a list of strings and failed only when `sum` tried to add them. This is why Python projects lean so heavily on tests, and often add a type checker such as `mypy` or `pyright` as well.

**Explain it:** what does `.venv` contain, and why does each project get its own? What happens to the rest of a function after `raise`?

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

---

## Step 2: Why averages lie: percentiles

**The problem.** Ninety-nine requests take 10 ms and one takes 5,000 ms. The mean is about 60 ms, a number that describes *no request that actually happened*. Users don't experience averages. They experience their own request, and the slow ones are the ones they remember.

**New ideas.**

- The **p-th percentile** is the value that p percent of observations are at or below. p50 is the median; p99 means "1 in 100 requests is slower than this".
- The **nearest-rank** method sorts the values and takes the one at position `ceil(p/100 × n)`. Its result is always a value that actually occurred.
- The **tail** (p95, p99, max) is where problems show up first. At scale, one page load may make dozens of requests, so most users hit your p99 regularly.
- A **dataclass** generates the boilerplate for a class that mainly holds data: constructor, equality, a readable printout. `frozen=True` makes it immutable, like a value object.
- `sorted(values)` returns a **new** sorted list. `values.sort()` sorts the caller's list **in place**, a side effect.
- `@pytest.mark.parametrize` runs one test with many inputs. It's Python's table-driven test.

Replace `stats.py`:

<!-- file: stats.py -->
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
    p95: float
    p99: float
    max: float


def percentile(values: Sequence[float], p: float) -> float:
    """Return the p-th percentile of values using the nearest-rank method.

    The nearest-rank percentile is always one of the observed values: the
    smallest value that at least p percent of all values are less than or
    equal to.
    """
    if not values:
        raise ValueError("percentile of an empty sequence is undefined")
    if not 0 < p <= 100:
        raise ValueError(f"p must be in (0, 100], got {p}")
    ordered = sorted(values)
    rank = math.ceil(p / 100 * len(ordered))
    return ordered[rank - 1]


def summarize(values: Sequence[float]) -> Summary:
    """Describe values with their count, mean, tail percentiles and maximum."""
    if not values:
        raise ValueError("cannot summarize an empty sequence")
    return Summary(
        count=len(values),
        mean=sum(values) / len(values),
        p50=percentile(values, 50),
        p95=percentile(values, 95),
        p99=percentile(values, 99),
        max=max(values),
    )
~~~

- `@dataclass(frozen=True)` is a **decorator**: a function that takes the class and returns an enhanced version. The fields are declared with type hints.
- `Sequence[float]` accepts anything list-like (a list, a tuple), which is more flexible than `list[float]`.
- `0 < p <= 100` is a **chained comparison**, read as "p is greater than 0 and at most 100".
- Lists are indexed from 0, so rank 1 is `ordered[0]`.
- `Summary(count=..., ...)` passes **keyword arguments** by name, so the order can't get mixed up.

The tests pin down the method with a 10-value example, the mutation rule, the error cases, and the motivating example:

<!-- file: test_stats.py -->
~~~python
import pytest

from stats import Summary, percentile, summarize


@pytest.mark.parametrize(
    ("p", "expected"),
    [
        (50, 5),
        (90, 9),
        (95, 10),
        (100, 10),
        (10, 1),
        (1, 1),
    ],
)
def test_percentile_nearest_rank(p, expected):
    values = [3, 1, 4, 10, 5, 9, 2, 6, 8, 7]
    assert percentile(values, p) == expected


def test_percentile_does_not_change_the_input():
    values = [3, 1, 2]
    percentile(values, 50)
    assert values == [3, 1, 2]


def test_percentile_of_one_value():
    assert percentile([42.0], 99) == 42.0


@pytest.mark.parametrize("p", [0, -1, 101])
def test_percentile_rejects_p_out_of_range(p):
    with pytest.raises(ValueError, match="p must be in"):
        percentile([1, 2, 3], p)


def test_percentile_rejects_empty_input():
    with pytest.raises(ValueError, match="empty"):
        percentile([], 50)


def test_summarize():
    values = [float(v) for v in range(1, 101)]
    assert summarize(values) == Summary(count=100, mean=50.5, p50=50, p95=95, p99=99, max=100)


def test_one_slow_request_moves_the_tail_not_the_median():
    values = [10.0] * 99 + [5000.0]
    summary = summarize(values)
    assert summary.p50 == 10.0
    assert summary.p99 == 10.0
    assert summary.max == 5000.0
    assert summary.mean == pytest.approx(59.9)


def test_summarize_rejects_empty_input():
    with pytest.raises(ValueError):
        summarize([])
~~~

`[10.0] * 99` makes a list of 99 tens. `pytest.approx` compares floating-point numbers with a tolerance, because `0.1 + 0.2 != 0.3` in binary floating point.

Run the motivating example:

~~~bash
uv run python -c "from stats import summarize; print(summarize([10.0]*99 + [5000.0]))"
~~~

~~~text
Summary(count=100, mean=59.9, p50=10.0, p95=10.0, p99=10.0, max=5000.0)
~~~

The mean, 59.9 ms, describes no real request. p50 and p99 say "almost everything is 10 ms", and `max` reveals the outlier. You need several numbers to describe latency; no single number is enough.

**Break it.** In `percentile`, replace `ordered = sorted(values)` with `values.sort()` and then `ordered = values`. Run `uv run pytest`:

~~~text
>       assert values == [3, 1, 2]
E       assert [1, 2, 3] == [3, 1, 2]
FAILED test_stats.py::test_percentile_does_not_change_the_input - assert [1, ...
~~~

The function silently reordered the **caller's** list. In Python, lists are passed by reference, so a function can change data it was only meant to read. Restore `sorted`.

**Explain it:** why is the mean misleading for latency? What does p99 = 40 ms tell a user, and what doesn't it tell them?

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

---

## Step 3: A package and a command line

**The problem.** Scripts in one folder don't scale. A real tool is a **package** that can be installed and run as a command, with subcommands, `--help`, and its own tests.

**New ideas.**

- **The src layout.** Code goes in `src/kload/`, tests in `tests/`. A folder of `.py` files with an `__init__.py` is a **package**, so `from kload.stats import summarize` works.
- `[project.scripts] kload = "kload.cli:main"` in `pyproject.toml` creates a `kload` command that calls `main()`.
- `argparse` parses command-line arguments, including subcommands, `--help`, and errors for bad input.
- `main(argv: list[str] | None = None)` takes its arguments as a parameter. It's the same trick as Phase 1's `run(getenv)`: tests call `main(["summarize", path])` without starting a process. `list[str] | None` means "a list of strings, or `None`".

Reshape your practice folder into this layout:

~~~text
pyproject.toml
src/kload/__init__.py
src/kload/stats.py        (moved from step 2)
src/kload/cli.py
tests/test_stats.py       (now imports from kload.stats)
tests/test_cli.py
~~~

Move the files you already have:

<!-- run: mkdir -p src/kload tests && mv stats.py src/kload/stats.py && mv test_stats.py tests/test_stats.py && touch src/kload/__init__.py -->
~~~bash
mkdir -p src/kload tests
mv stats.py src/kload/stats.py
mv test_stats.py tests/test_stats.py
touch src/kload/__init__.py
~~~

`touch` creates an empty file, and an empty `__init__.py` is enough to make `src/kload` a package. The test's import changes because `stats` now lives inside `kload`. In `tests/test_stats.py`, change:

<!-- edit: tests/test_stats.py -->
~~~python
from stats import Summary, percentile, summarize
~~~

to:

~~~python
from kload.stats import Summary, percentile, summarize
~~~

Now create the command line, `src/kload/cli.py`:

<!-- file: src/kload/cli.py -->
~~~python
"""The kload command line."""

import argparse
import sys
from pathlib import Path

from kload.stats import summarize


def cmd_summarize(args: argparse.Namespace) -> int:
    text = Path(args.file).read_text()
    values = [float(word) for word in text.split()]
    summary = summarize(values)
    for name in ("count", "mean", "p50", "p95", "p99", "max"):
        print(f"{name:>5}: {getattr(summary, name):g}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="kload", description=__doc__)
    sub = parser.add_subparsers(required=True)

    p = sub.add_parser("summarize", help="summarize numbers from a file")
    p.add_argument("file")
    p.set_defaults(handler=cmd_summarize)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
~~~

- `[float(word) for word in text.split()]` is a **list comprehension**: build a list by transforming each item. `text.split()` splits on any whitespace.
- `Path(args.file).read_text()` reads a whole file. `pathlib.Path` is Python's path type.
- `("count", "mean", ...)` is a **tuple**, an immutable sequence. `getattr(summary, name)` reads a field by name.
- `{name:>5}` right-aligns the name in 5 characters, and `:g` prints a number compactly.
- `set_defaults(handler=cmd_summarize)` attaches the function to the subcommand, so `main` can call `args.handler(args)` without an `if`/`else` chain. Functions are values in Python, just as in Go.
- `if __name__ == "__main__":` is true only when the file is run directly, not when it's imported.

The CLI tests in `tests/test_cli.py` (below) use pytest's built-in **fixtures**. Naming a parameter `tmp_path` gives the test a fresh temporary folder, and `capsys` captures what was printed.

Make these changes to `pyproject.toml`:

Change:

<!-- edit: pyproject.toml -->
~~~toml

[dependency-groups]
~~~

to:

~~~toml

[project.scripts]
kload = "kload.cli:main"

[dependency-groups]
~~~

Change:

<!-- edit: pyproject.toml -->
~~~toml

[tool.ruff]
~~~

to:

~~~toml

[build-system]
requires = ["uv_build>=0.12.7,<0.13.0"]
build-backend = "uv_build"

[tool.ruff]
~~~

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


def test_unknown_command_exits_with_usage_error(capsys):
    with pytest.raises(SystemExit) as caught:
        main(["fly"])
    assert caught.value.code == 2
    assert "invalid choice" in capsys.readouterr().err


def test_bad_number_in_file_raises(tmp_path):
    data = tmp_path / "latencies.txt"
    data.write_text("12 fast\n")
    with pytest.raises(ValueError):
        main(["summarize", str(data)])
~~~

**Run it.**

~~~bash
printf '12 15\n11 250\n14\n' > lat.txt
uv run kload summarize lat.txt
uv run kload --help
~~~

~~~text
count: 5
 mean: 60.4
  p50: 14
  p95: 250
  p99: 250
  max: 250
~~~

With only five samples, p95 and p99 are both the maximum. **Percentiles need enough data**: a p99 from 5 samples is just the slowest request, and you need hundreds of samples before p99 means much.

**Break it.** Run `uv run kload fly`:

~~~text
usage: kload [-h] {summarize} ...
kload: error: argument {summarize}: invalid choice: 'fly' (choose from 'summarize')
~~~

The exit status is 2: argparse's convention for "usage error". `test_unknown_command_exits_with_usage_error` checks it.

**Explain it:** why does `main` accept `argv` instead of reading `sys.argv` itself? What is an `__init__.py` for?

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

---

## Step 4: An HTTP client, tested without a network

**The problem.** To drive the Phase 1 API you need a client that speaks its contract and turns errors into something meaningful. Its tests must not depend on a server being up.

**New ideas.**

- A **class** bundles data and the functions that work on it. `__init__` is the constructor, and `self` is the instance (Go's receiver, written explicitly).
- A custom **exception** is a class that inherits from `Exception`. `ApiError` carries the status and message, like Go's `requestError`.
- `@classmethod` defines a constructor that takes the class itself (`cls`) as its first argument. `Job.from_json(data)` builds a `Job` from a decoded JSON dict.
- **Dependency injection, again.** `JobsClient` receives an `httpx.Client` instead of creating one. In production, it gets a real client with a base URL and timeout. In tests, it gets one whose **transport** is `httpx.MockTransport(fake_api)`, so requests never leave the process.
- `match` / `case` is **structural pattern matching**: Python's `switch`, which can match on shapes like `("GET", "/health")`.
- `*expected` collects any number of positional arguments into a tuple: `_check(response, 200, 504)`.

Add httpx with `uv add httpx`.

<!-- run: uv add httpx -->
 Then create `src/kload/client.py`:

<!-- file: src/kload/client.py -->
~~~python
"""A small client for the Phase 1 jobs API."""

from dataclasses import dataclass
from typing import Any

import httpx


class ApiError(Exception):
    """The API answered with a status the caller didn't expect."""

    def __init__(self, status: int, message: str) -> None:
        super().__init__(f"{status}: {message}")
        self.status = status
        self.message = message


@dataclass(frozen=True)
class Job:
    id: int
    state: str
    description: str
    duration_ms: int
    failure_reason: str = ""

    @classmethod
    def from_json(cls, data: dict[str, Any]) -> "Job":
        return cls(
            id=data["id"],
            state=data["state"],
            description=data["description"],
            duration_ms=data["duration_ms"],
            failure_reason=data.get("failure_reason", ""),
        )


class JobsClient:
    """Calls the jobs API through an httpx.Client it is given.

    The caller builds the httpx.Client (base URL, timeouts, transport), so
    tests can pass one whose transport never touches the network.
    """

    def __init__(self, http: httpx.Client) -> None:
        self._http = http

    def health(self) -> str:
        return _check(self._http.get("/health"), 200)["status"]

    def create_job(self, description: str, duration_ms: int = 0) -> Job:
        response = self._http.post(
            "/jobs", json={"description": description, "duration_ms": duration_ms}
        )
        return Job.from_json(_check(response, 201))

    def get_job(self, job_id: int) -> Job:
        return Job.from_json(_check(self._http.get(f"/jobs/{job_id}"), 200))

    def run_job(self, job_id: int) -> Job:
        """Run a job. A 504 still returns the job, which is now failed."""
        return Job.from_json(_check(self._http.post(f"/jobs/{job_id}/run"), 200, 504))


def _check(response: httpx.Response, *expected: int) -> dict[str, Any]:
    if response.status_code not in expected:
        try:
            message = response.json().get("error", response.text)
        except ValueError:
            message = response.text.strip()
        raise ApiError(response.status_code, message)
    return response.json()
~~~

- `super().__init__(...)` calls the parent class's constructor, so `str(error)` prints `404: job not found`.
- `data.get("failure_reason", "")` returns a default if the key is missing. Remember the API's `omitempty`.
- `failure_reason: str = ""` gives a dataclass field a default value.
- `try: ... except ValueError:` catches the error `response.json()` raises when the body isn't JSON, which is true of the router's plain-text 404 and 405 responses from Phase 1.
- `_check` starts with `_`, so it's private by convention.
- `run_job` accepts **504** as a success, because the Phase 1 contract says a 504 still returns the (now failed) job.

The test's fake API and its fixture, from `tests/test_client.py` above:

<!-- file: tests/test_client.py -->
~~~python
import json

import httpx
import pytest

from kload.client import ApiError, Job, JobsClient


def fake_api(request: httpx.Request) -> httpx.Response:
    """Pretends to be the Phase 1 API, just enough for these tests."""
    job = {"id": 1, "state": "queued", "description": "resize", "duration_ms": 50}
    match (request.method, request.url.path):
        case ("GET", "/health"):
            return httpx.Response(200, json={"status": "ok"})
        case ("POST", "/jobs"):
            body = json.loads(request.content)
            if not body["description"]:
                return httpx.Response(
                    400, json={"error": "description must be between 1 and 200 characters"}
                )
            return httpx.Response(201, json=job)
        case ("GET", "/jobs/1"):
            return httpx.Response(200, json=job)
        case ("POST", "/jobs/1/run"):
            return httpx.Response(200, json=job | {"state": "completed"})
        case ("POST", "/jobs/2/run"):
            failed = job | {"id": 2, "state": "failed", "failure_reason": "deadline exceeded"}
            return httpx.Response(504, json=failed)
        case _:
            return httpx.Response(404, json={"error": "job not found"})


@pytest.fixture
def client():
    http = httpx.Client(base_url="http://kestrel.test", transport=httpx.MockTransport(fake_api))
    with http:
        yield JobsClient(http)


def test_health(client):
    assert client.health() == "ok"


def test_create_job(client):
    assert client.create_job("resize", duration_ms=50) == Job(
        id=1, state="queued", description="resize", duration_ms=50
    )


def test_run_job(client):
    assert client.run_job(1).state == "completed"


def test_run_past_deadline_returns_the_failed_job(client):
    job = client.run_job(2)
    assert (job.state, job.failure_reason) == ("failed", "deadline exceeded")


def test_api_error_carries_status_and_message(client):
    with pytest.raises(ApiError) as caught:
        client.create_job("")
    assert caught.value.status == 400
    assert "description" in caught.value.message


def test_unknown_job(client):
    with pytest.raises(ApiError, match="404: job not found"):
        client.get_job(99)
~~~

A **fixture** is a function pytest runs to provide a test argument. `yield` hands the value to the test, and after the test, execution continues past the `yield` and the `with` block closes the client. That's setup and teardown in one function. `with` is Python's equivalent of Go's `defer Close()`.

Also add a `smoke` subcommand to the CLI. It checks health, creates a job, and runs it; the changes to `cli.py` follow.

Make these changes to `src/kload/cli.py`:

Change:

<!-- edit: src/kload/cli.py -->
~~~python

from kload.stats import summarize
~~~

to:

~~~python

import httpx

from kload.client import ApiError, JobsClient
from kload.stats import summarize
~~~

Change:

<!-- edit: src/kload/cli.py -->
~~~python

def build_parser() -> argparse.ArgumentParser:
~~~

to:

~~~python

def cmd_smoke(args: argparse.Namespace) -> int:
    with httpx.Client(base_url=args.url, timeout=10) as http:
        client = JobsClient(http)
        try:
            print(f"health: {client.health()}")
            job = client.create_job("smoke test", duration_ms=args.duration_ms)
            print(f"created job {job.id}: {job.state}")
            job = client.run_job(job.id)
            print(f"ran job {job.id}: {job.state} {job.failure_reason}".rstrip())
        except (ApiError, httpx.HTTPError) as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
    return 0


def build_parser() -> argparse.ArgumentParser:
~~~

Change:

<!-- edit: src/kload/cli.py -->
~~~python
    p.set_defaults(handler=cmd_summarize)
    return parser
~~~

to:

~~~python
    p.set_defaults(handler=cmd_summarize)

    p = sub.add_parser("smoke", help="create and run one job against a live API")
    p.add_argument("--url", default="http://127.0.0.1:8080")
    p.add_argument("--duration-ms", type=int, default=100)
    p.set_defaults(handler=cmd_smoke)
    return parser
~~~

**Run it.** Start the Phase 1 server in another terminal, then:

~~~bash
uv run kload smoke --duration-ms 150
~~~

~~~text
health: ok
created job 1: queued
ran job 1: completed
~~~

Stop the server and run it again:

~~~text
error: [Errno 111] Connection refused
~~~

The exit status is 1. The CLI caught `httpx.HTTPError`, the parent class of every transport failure, and turned it into a message rather than a traceback.

**Break it.** Remove `504` from `run_job`'s accepted statuses and run the tests:

~~~text
E           kload.client.ApiError: 504: {"id":2,"state":"failed","description":"resize","duration_ms":50,"failure_reason":"deadline exceeded"}
FAILED tests/test_client.py::test_run_past_deadline_returns_the_failed_job - ...
~~~

The fake API played the Phase 1 contract's 504 case, and the client no longer honoured it. Restore it. Clients must implement *every* row of a contract, not only the happy path.

**Explain it:** why does `JobsClient` take an `httpx.Client` instead of a URL? What does `MockTransport` let you test that a real server makes hard?

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

---

## Step 5: Load on a schedule: asyncio and coordinated omission

**The problem.** To see how the service behaves under load, you need many requests in flight at once, sent at a **steady rate**, like real users arriving. One request at a time, in a loop, measures something else entirely, and gets the answer wrong in a specific, well-documented way.

**New ideas: concurrency in Python.**

- In standard CPython, only one thread runs Python bytecode at a time: the **global interpreter lock** (GIL). Threads still help with waiting on I/O, but for thousands of network requests Python uses **asyncio**.
- `async def` defines a **coroutine**: a function that can pause at each `await` and let other coroutines run. The **event loop** switches between them whenever one is waiting on the network or a timer. It's one thread, with cooperative switching. In Go, the runtime does this for you; in Python, you mark each pause point with `await`.
- `asyncio.run(main())` starts the loop. `asyncio.gather(*coros)` runs many coroutines at once and waits for them all. `await asyncio.sleep(d)` pauses *this* coroutine without blocking the others.
- An `asyncio.Semaphore(n)` lets at most `n` coroutines into a block at once. It bounds how many requests are in flight.
- `httpx.AsyncClient` is the async version of the client. Its calls are awaited.

**New ideas: open and closed loops.**

- A **closed-loop** generator sends a request, waits for the reply, and sends the next. If the server stalls for one second, the generator stalls with it, and **doesn't send** the requests real users would have sent during that second. The stall appears as **one** slow sample instead of hundreds. This bias is called **coordinated omission**: the tool coordinates with the server and omits the bad data.
- An **open-loop** generator sends each request when it's **scheduled** (request *i* at `i / rate` seconds), whether or not earlier ones have finished, and measures latency **from the scheduled time**. A stall then shows up in every request that should have been sent during it.

~~~mermaid
sequenceDiagram
    participant G as Closed loop
    participant S as Server (stalls 0.5 s)
    G->>S: request 10
    Note over S: stall
    S-->>G: 500 ms later
    G->>S: request 11 (only now)
    Note over G: requests users would have sent<br/>during the stall were never sent
~~~

Create `src/kload/load.py`:

<!-- file: src/kload/load.py -->
~~~python
"""Load generation: open-loop (correct) and closed-loop (misleading)."""

import asyncio
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

import httpx

RequestFn = Callable[[httpx.AsyncClient], Awaitable[httpx.Response]]
Clock = Callable[[], float]


@dataclass(frozen=True)
class Result:
    """One request's outcome.

    scheduled_s is when the request was due, in seconds after the run began.
    latency_s is measured from that moment until the response arrived.
    status is the HTTP status, or 0 if no response came back.
    """

    scheduled_s: float
    latency_s: float
    status: int
    error: str = ""


async def _send(client: httpx.AsyncClient, request: RequestFn) -> tuple[int, str]:
    try:
        response = await request(client)
        return response.status_code, ""
    except httpx.HTTPError as exc:
        return 0, type(exc).__name__


async def run_open_loop(
    client: httpx.AsyncClient,
    request: RequestFn,
    rate: float,
    duration_s: float,
    *,
    max_in_flight: int = 1000,
    clock: Clock = time.perf_counter,
) -> list[Result]:
    """Send `rate` requests per second for `duration_s` seconds on a fixed schedule.

    Requests go out when they are due, whether or not earlier ones have
    finished, the way real users arrive. Latency is measured from the scheduled
    time, so if the server stalls, every request that should have been sent
    during the stall records the wait.
    """
    if rate <= 0 or duration_s <= 0:
        raise ValueError("rate and duration must be positive")
    interval = 1 / rate
    total = round(rate * duration_s)
    in_flight = asyncio.Semaphore(max_in_flight)
    start = clock()

    async def one(i: int) -> Result:
        scheduled = start + i * interval
        delay = scheduled - clock()
        if delay > 0:
            await asyncio.sleep(delay)
        async with in_flight:
            status, error = await _send(client, request)
        return Result(scheduled - start, clock() - scheduled, status, error)

    return list(await asyncio.gather(*(one(i) for i in range(total))))


async def run_closed_loop(
    client: httpx.AsyncClient,
    request: RequestFn,
    count: int,
    *,
    clock: Clock = time.perf_counter,
) -> list[Result]:
    """Send `count` requests one after another, each when the previous one returns.

    This is how many simple benchmarks work. While the server is stalled the
    loop is stuck waiting too, so it doesn't send the requests real users
    would have sent. The stall shows up in one sample instead of many: this is
    called coordinated omission.
    """
    results = []
    start = clock()
    for _ in range(count):
        sent = clock()
        status, error = await _send(client, request)
        results.append(Result(sent - start, clock() - sent, status, error))
    return results
~~~

Read it slowly:

- `RequestFn` is a **type alias**: a function that takes an async client and returns something you can `await` to get a response. The generator doesn't know *what* request it sends, because the caller passes that in. That's dependency injection once more.
- `clock` is injectable, and it defaults to `time.perf_counter`, a high-resolution timer meant for measuring intervals (unlike wall-clock time, it never jumps backwards).
- The `*` in the parameter list makes everything after it **keyword-only**: you must write `max_in_flight=50`, never a bare `50`.
- `one(i)` is defined **inside** `run_open_loop`, so it can use `start`, `interval` and `in_flight`. That's a **closure**.
- Transport failures become `status=0` with the exception's class name. A load test must record failures, not crash on them.
- `(one(i) for i in range(total))` is a **generator expression**, and `*` spreads it into arguments for `gather`.

Results are saved by `results.py` (below) as raw CSV, plus a JSON file of the settings that produced them. **Keep raw data, not just summaries.** Anyone can recompute any statistic later, and the settings file says how to reproduce the run.

### The test that proves the difference

<!-- file: tests/test_load.py -->
~~~python
import asyncio

import httpx
import pytest

from kload.load import Result, run_closed_loop, run_open_loop
from kload.stats import percentile


def get_health(client: httpx.AsyncClient):
    return client.get("/health")


def async_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(base_url="http://kestrel.test", transport=httpx.MockTransport(handler))


async def ok(request: httpx.Request) -> httpx.Response:
    return httpx.Response(200, json={"status": "ok"})


def test_open_loop_sends_rate_times_duration_requests():
    async def scenario():
        async with async_client(ok) as client:
            return await run_open_loop(client, get_health, rate=50, duration_s=0.4)

    results = asyncio.run(scenario())
    assert len(results) == 20
    assert all(r.status == 200 for r in results)
    assert [round(r.scheduled_s, 3) for r in results[:3]] == [0.0, 0.02, 0.04]


def test_transport_errors_are_recorded_not_raised():
    async def refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    async def scenario():
        async with async_client(refuse) as client:
            return await run_open_loop(client, get_health, rate=20, duration_s=0.1)

    results = asyncio.run(scenario())
    assert {(r.status, r.error) for r in results} == {(0, "ConnectError")}


@pytest.mark.parametrize(("rate", "duration"), [(0, 1), (10, 0), (-1, 1)])
def test_open_loop_rejects_bad_arguments(rate, duration):
    with pytest.raises(ValueError):
        asyncio.run(run_open_loop(None, get_health, rate=rate, duration_s=duration))


class StallingServer:
    """Answers instantly, except for one request that freezes the whole server.

    The lock stands in for anything that stops a server answering anyone,
    such as a garbage-collection pause or a blocked event loop: requests
    that arrive during the stall wait for it to end.
    """

    def __init__(self, stall_on: int, stall_s: float) -> None:
        self.lock = asyncio.Lock()
        self.seen = 0
        self.stall_on = stall_on
        self.stall_s = stall_s

    async def __call__(self, request: httpx.Request) -> httpx.Response:
        async with self.lock:
            self.seen += 1
            if self.seen == self.stall_on:
                await asyncio.sleep(self.stall_s)
        return httpx.Response(200)


def p95_ms(results: list[Result]) -> float:
    return percentile([r.latency_s * 1000 for r in results], 95)


def test_closed_loop_hides_a_stall_that_open_loop_reveals():
    """A 0.5 s stall during a 1 s run at 50 requests per second.

    Real users would have sent about 25 requests during the stall, and every
    one of them would have waited. The closed loop sends none of them, so
    its p95 stays small. The open loop sends them on schedule and records the
    wait.
    """

    async def closed():
        async with async_client(StallingServer(stall_on=10, stall_s=0.5)) as client:
            return await run_closed_loop(client, get_health, count=50)

    async def open_():
        async with async_client(StallingServer(stall_on=10, stall_s=0.5)) as client:
            return await run_open_loop(client, get_health, rate=50, duration_s=1.0)

    closed_p95 = p95_ms(asyncio.run(closed()))
    open_p95 = p95_ms(asyncio.run(open_()))

    assert closed_p95 < 50, f"closed-loop p95 = {closed_p95:.1f} ms"
    assert open_p95 > 200, f"open-loop p95 = {open_p95:.1f} ms"
~~~

`__call__` makes an instance callable like a function, so it can serve as the mock transport's handler while keeping state (`seen`) between calls. The test runs both generators against a 0.5-second stall. It asserts that the closed loop's p95 stays under 50 ms (the stall hidden in one sample) while the open loop's p95 is over 200 ms (the stall visible across about 25 requests).

Create `tests/test_results.py`:

<!-- file: tests/test_results.py -->
~~~python
import csv

from kload.load import Result
from kload.results import write_results


def test_write_results_saves_rows_and_settings(tmp_path):
    path = tmp_path / "out" / "run.csv"
    results = [Result(0.0, 0.004, 200), Result(0.01, 0.0, 0, "ConnectError")]

    settings_path = write_results(results, path, {"rate": 5, "target": "health"})

    with path.open() as f:
        rows = list(csv.DictReader(f))
    assert rows[1] == {
        "scheduled_s": "0.01",
        "latency_s": "0.0",
        "status": "0",
        "error": "ConnectError",
    }
    assert settings_path.read_text() == '{\n  "rate": 5,\n  "target": "health"\n}\n'
~~~

Create `src/kload/results.py`:

<!-- file: src/kload/results.py -->
~~~python
"""Save a run's raw results next to the settings that produced them."""

import csv
import json
from dataclasses import asdict, fields
from pathlib import Path
from typing import Any

from kload.load import Result


def write_results(results: list[Result], path: Path, settings: dict[str, Any]) -> Path:
    """Write results as CSV, plus a JSON file with the settings beside it.

    Raw results, not just a summary, let anyone recompute any statistic
    later. The settings file records how to reproduce the run. Returns the
    settings file's path.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[field.name for field in fields(Result)])
        writer.writeheader()
        for result in results:
            writer.writerow(asdict(result))

    settings_path = path.with_suffix(".json")
    settings_path.write_text(json.dumps(settings, indent=2, sort_keys=True) + "\n")
    return settings_path
~~~

Make these changes to `src/kload/cli.py`:

Change:

<!-- edit: src/kload/cli.py -->
~~~python
import argparse
import sys
~~~

to:

~~~python
import argparse
import asyncio
import sys
~~~

Change:

<!-- edit: src/kload/cli.py -->
~~~python
from kload.client import ApiError, JobsClient
from kload.stats import summarize

~~~

to:

~~~python
from kload.client import ApiError, JobsClient
from kload.load import RequestFn, run_closed_loop, run_open_loop
from kload.results import write_results
from kload.stats import summarize

TARGETS: dict[str, RequestFn] = {
    "health": lambda client: client.get("/health"),
    "create": lambda client: client.post("/jobs", json={"description": "load test"}),
}

~~~

Change:

<!-- edit: src/kload/cli.py -->
~~~python

def build_parser() -> argparse.ArgumentParser:
~~~

to:

~~~python

def cmd_load(args: argparse.Namespace) -> int:
    async def go():
        # Keep every connection open between requests. httpx keeps only 20 idle
        # connections by default, so at high rates it would keep opening new
        # ones, and the generator would measure its own handshakes.
        limits = httpx.Limits(
            max_connections=args.max_in_flight, max_keepalive_connections=args.max_in_flight
        )
        async with httpx.AsyncClient(base_url=args.url, timeout=10, limits=limits) as client:
            if args.mode == "closed":
                count = round(args.rate * args.duration)
                return await run_closed_loop(client, TARGETS[args.target], count)
            return await run_open_loop(
                client,
                TARGETS[args.target],
                rate=args.rate,
                duration_s=args.duration,
                max_in_flight=args.max_in_flight,
            )

    results = asyncio.run(go())
    settings = {k: v for k, v in vars(args).items() if k != "handler"}
    settings_path = write_results(results, Path(args.out), settings)
    print(f"wrote {len(results)} results to {args.out} (settings: {settings_path})")
    return 0


def build_parser() -> argparse.ArgumentParser:
~~~

Change:

<!-- edit: src/kload/cli.py -->
~~~python
    p.set_defaults(handler=cmd_smoke)
    return parser
~~~

to:

~~~python
    p.set_defaults(handler=cmd_smoke)

    p = sub.add_parser("load", help="send open-loop load and save raw results")
    p.add_argument("--url", default="http://127.0.0.1:8080")
    p.add_argument("--target", choices=sorted(TARGETS), default="health")
    p.add_argument(
        "--mode",
        choices=["open", "closed"],
        default="open",
        help="closed sends rate*duration requests back to back (for comparison only)",
    )
    p.add_argument("--rate", type=float, required=True, help="requests per second")
    p.add_argument("--duration", type=float, required=True, help="seconds")
    p.add_argument("--max-in-flight", type=int, default=200)
    p.add_argument("--out", default="results/run.csv")
    p.set_defaults(handler=cmd_load)
    return parser
~~~

**Run it.** With the Phase 1 server running:

~~~bash
uv run kload load --target health --rate 100 --duration 5 --max-in-flight 50 --out results/base.csv
cat results/base.json
~~~

~~~text
wrote 500 results to results/base.csv (settings: results/base.json)
~~~

**Break it: coordinated omission inside an open loop.** Measuring from the *scheduled* time is what makes the open loop honest. Change `run_open_loop` to record `sent = clock()` just before `_send` and report `clock() - sent`. In the test, also pass `max_in_flight=1` to `run_open_loop`, then run `uv run pytest tests/test_load.py`:

~~~text
E       AssertionError: open-loop p95 = 0.9 ms
FAILED tests/test_load.py::test_closed_loop_hides_a_stall_that_open_loop_reveals
~~~

With only one request allowed in flight, requests queue *inside the generator* while the server is stalled. Measuring from when they finally leave hides the wait completely. Remove `max_in_flight=1` and the test passes again even with the wrong measurement, because nothing queues in the generator. That's exactly why this bug survives in real tools: it only shows up when the generator falls behind. Restore the original code.

**Explain it:** what is coordinated omission, in one sentence? Why does the closed loop hide a stall? Why does measuring from the scheduled time fix it?

**Read.** Gil Tene's talk *How NOT to Measure Latency* (search for it on YouTube or InfoQ). It's the classic explanation of coordinated omission. Carry this question in: which of your past benchmarks used a closed loop?

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

---

## Step 6: Analysis, plots, and three real experiments

**The problem.** 500 rows of CSV aren't an answer. You need headline numbers, a per-second view to spot *when* things went wrong, and plots a human can read at a glance.

**New ideas.**

- **pandas** holds tables as **DataFrames**: labelled columns you can filter, group and compute on, all at once. `df["latency_s"] * 1000` multiplies a whole column with no loop.
- `df.groupby(key)` splits rows into groups, so you can compute per-group statistics (here, per second of the run).
- **matplotlib** draws plots. `matplotlib.use("Agg")` draws to image files without opening a window, which is what you want on servers and in CI.
- A **log scale** on the histogram's y-axis keeps the rare slow requests visible next to thousands of fast ones.

The most important function, from `analyze.py` above:

<!-- file: src/kload/analyze.py -->
~~~python
"""Turn raw results into a report and plots."""

from pathlib import Path

import matplotlib

matplotlib.use("Agg")  # draw to files; no window needed

import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

from kload.stats import percentile  # noqa: E402


def load_results(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, keep_default_na=False)
    df["latency_ms"] = df["latency_s"] * 1000
    df["ok"] = df["status"].between(200, 399)
    return df


def report(df: pd.DataFrame) -> dict[str, float]:
    """Headline numbers. Percentiles cover successful requests only."""
    if df.empty:
        raise ValueError("no results to report")
    ok = df.loc[df["ok"], "latency_ms"].tolist()
    span = df["scheduled_s"].max() - df["scheduled_s"].min()
    return {
        "requests": len(df),
        "error_rate": round(1 - df["ok"].mean(), 4),
        "throughput_rps": round(len(df) / span, 1) if span > 0 else float(len(df)),
        "p50_ms": round(percentile(ok, 50), 2) if ok else float("nan"),
        "p95_ms": round(percentile(ok, 95), 2) if ok else float("nan"),
        "p99_ms": round(percentile(ok, 99), 2) if ok else float("nan"),
        "max_ms": round(max(ok), 2) if ok else float("nan"),
    }


def per_second(df: pd.DataFrame) -> pd.DataFrame:
    """Requests, errors and p95 latency for each second of the run."""
    second = df["scheduled_s"].astype(int).rename("second")
    grouped = df.groupby(second)
    return pd.DataFrame(
        {
            "requests": grouped.size(),
            "errors": grouped["ok"].apply(lambda ok: int((~ok).sum())),
            "p95_ms": grouped["latency_ms"].apply(lambda s: round(percentile(s.tolist(), 95), 2)),
        }
    )


def plot(df: pd.DataFrame, path: Path) -> None:
    """Latency over time (spot stalls) and a histogram (see the shape of the tail)."""
    fig, (timeline, histogram) = plt.subplots(1, 2, figsize=(11, 4))
    timeline.scatter(df["scheduled_s"], df["latency_ms"], s=4, c=~df["ok"], cmap="coolwarm")
    timeline.set(xlabel="scheduled time (s)", ylabel="latency (ms)", title="Latency over time")
    histogram.hist(df["latency_ms"], bins=50)
    histogram.set(xlabel="latency (ms)", ylabel="requests", title="Latency distribution")
    histogram.set_yscale("log")
    fig.tight_layout()
    fig.savefig(path, dpi=120)
    plt.close(fig)
~~~

- `df.loc[df["ok"], "latency_ms"]` selects the `latency_ms` column for rows where `ok` is true. Errors are excluded from latency percentiles and reported separately as `error_rate`: a fast failure isn't a fast success.
- `df["ok"].mean()` of a true/false column is the fraction that are true.
- `x if condition else y` is Python's inline conditional.
- It reuses your own `percentile`, so every number matches the definition you tested in step 2. (pandas' own `quantile` interpolates between values by default, and gives slightly different answers.)

<!-- run: uv add pandas matplotlib -->

Add `pandas` and `matplotlib` with `uv add pandas matplotlib`, add the `analyze` subcommand, and the `--mode closed` option used in experiment 2; the `cli.py` changes follow.

### Experiment 1: the baseline

~~~bash
uv run kload load --rate 100 --duration 5 --max-in-flight 50 --out results/base.csv
uv run kload analyze results/base.csv
~~~

Results from one run on a laptop (yours will differ):

~~~text
"requests": 500, "error_rate": 0.0, "p50_ms": 3.81, "p99_ms": 10.81
~~~

A healthy `/health` endpoint: single-digit milliseconds, no errors. Write this down. **A measurement means nothing without a baseline to compare it with.**

### Experiment 2: freeze the server, compare open and closed loops

`kill -STOP` freezes a process completely, much like a long garbage-collection pause or a virtual machine being paused. `kill -CONT` resumes it. Run the load in one terminal while freezing the server for one second, two seconds in:

~~~bash
PID=$(pgrep -x api)
(sleep 2; kill -STOP $PID; sleep 1; kill -CONT $PID) &
uv run kload load --rate 100 --duration 6 --max-in-flight 50 --out results/freeze.csv
uv run kload analyze results/freeze.csv --plot results/freeze.png
~~~

Then repeat with `--mode closed`. Results from one run:

| | p50 | p95 | p99 | max |
|---|---|---|---|---|
| Open loop, 1 s freeze | 313 ms | 1,097 ms | 1,568 ms | 2,198 ms |
| Closed loop, same freeze | 1.65 ms | 2.18 ms | 2.48 ms | 43 ms |

**The same freeze, measured two ways, gives answers 600 times apart.** The closed loop reports a perfectly healthy service: it was stuck waiting during the freeze, so it barely recorded it. The open loop shows what users would actually have experienced. Open `freeze.png` and find the freeze on the latency-over-time plot.

Look at the open loop's per-second table, and notice that latency stays high for **seconds after** the server resumed. Clearing a backlog takes time, because new requests keep arriving while the old ones drain. That's queueing, and it's why a short stall causes a much longer incident. Phase 2 studies it with real queues.

### Experiment 3: is the tool the bottleneck?

Run the baseline at increasing rates and watch the **generator's own** CPU use:

~~~bash
for r in 100 200 400; do
  /usr/bin/time -f "rate $r: generator CPU %P, wall %es" \
    uv run kload load --rate $r --duration 5 --max-in-flight 50 --out results/cap$r.csv
done
~~~

Results from one run:

| Rate | Generator CPU | Wall time for a 5 s run | p50 |
|---|---|---|---|
| 100/s | 32% | 5.3 s | 3.8 ms |
| 200/s | 57% | 5.3 s | 3.6 ms |
| 400/s | 96% | 9.1 s | 3,586 ms |

At 400 requests per second, the **Python generator** hit one full CPU core. It fell behind its own schedule (a 5-second run took 9 seconds), and every request recorded seconds of "latency" that was really time spent waiting inside the generator. The Go server was fine. **Always check that the measuring tool has headroom before blaming the system.** The fixes are to spread the load across several generator processes, use a faster tool (`oha`, `k6`, `wrk2`), or lower the rate.

### Something to investigate: the 7-second tail

With `--max-in-flight 200`, the freeze experiment produced tails of around **7 seconds**, not 1. During that run, the kernel's TCP counters (`nstat -az | grep TCPSynRetrans`) showed **44 SYN retransmissions**. During the freeze the generator tried to open many new connections, and some of those attempts were retried with TCP's backoff of 1, 2 then 4 seconds. A 1-second freeze turned into a 7-second tail. Don't take this explanation on trust: in Phase 2 you'll capture the packets and confirm or refute it. Writing down "observed X; hypothesis Y; how I'll test it" is what research practice looks like.

**Explain it:** why does the open-loop latency stay high after the freeze ends? How would you prove a load generator isn't the bottleneck?

Create `tests/test_analyze.py`:

<!-- file: tests/test_analyze.py -->
~~~python
from kload.analyze import load_results, per_second, plot, report
from kload.load import Result
from kload.results import write_results


def sample(tmp_path):
    results = [Result(i * 0.01, 0.005, 200) for i in range(150)]
    results[120] = Result(1.2, 0.0, 0, "ConnectError")
    results[130] = Result(1.3, 0.9, 200)
    path = tmp_path / "run.csv"
    write_results(results, path, {"rate": 100})
    return load_results(path)


def test_report(tmp_path):
    numbers = report(sample(tmp_path))
    assert numbers["requests"] == 150
    assert numbers["error_rate"] == round(1 / 150, 4)
    assert numbers["p50_ms"] == 5.0
    assert numbers["max_ms"] == 900.0


def test_per_second(tmp_path):
    table = per_second(sample(tmp_path))
    assert table["requests"].tolist() == [100, 50]
    assert table["errors"].tolist() == [0, 1]


def test_plot_writes_a_png(tmp_path):
    out = tmp_path / "plot.png"
    plot(sample(tmp_path), out)
    assert out.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
~~~

Make these changes to `src/kload/cli.py`:

Change:

<!-- edit: src/kload/cli.py -->
~~~python
import asyncio
import sys
~~~

to:

~~~python
import asyncio
import json
import sys
~~~

Change:

<!-- edit: src/kload/cli.py -->
~~~python

def build_parser() -> argparse.ArgumentParser:
~~~

to:

~~~python

def cmd_analyze(args: argparse.Namespace) -> int:
    from kload.analyze import load_results, per_second, plot, report

    df = load_results(Path(args.file))
    print(json.dumps(report(df), indent=2))
    print(per_second(df).to_string())
    if args.plot:
        plot(df, Path(args.plot))
        print(f"plot saved to {args.plot}")
    return 0


def build_parser() -> argparse.ArgumentParser:
~~~

Change:

<!-- edit: src/kload/cli.py -->
~~~python
    p.set_defaults(handler=cmd_load)
    return parser
~~~

to:

~~~python
    p.set_defaults(handler=cmd_load)

    p = sub.add_parser("analyze", help="report and plot a results file")
    p.add_argument("file")
    p.add_argument("--plot", help="write a PNG here")
    p.set_defaults(handler=cmd_analyze)
    return parser
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

---

## Checkpoint

You're ready for Phase 2 when you can, without the guide:

1. Explain why the mean is misleading for latency, and compute a nearest-rank p95 by hand for 20 values.
2. Write a pytest test with a fixture, a parametrised case, and an expected exception.
3. Explain `async`/`await`, the event loop, and why Python uses asyncio rather than threads for this tool.
4. Explain coordinated omission, and show the two measurements of the same freeze.
5. Show the experiment where the generator was the bottleneck, and say how you detected it.
6. Rerun any experiment from its saved settings file and get comparable numbers.

## If it goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `uv: command not found` | The installer's directory isn't on your PATH yet | Open a new terminal, or follow the installer's instructions |
| `ModuleNotFoundError: No module named 'kload'` | Running `python` outside the environment, or the src layout isn't installed | Use `uv run ...`; check `[build-system]` in `pyproject.toml` |
| A change to the code has no effect in tests | You copied a project folder and its `.venv` still points at the old source | Delete `.venv` and run `uv run` again |
| `IndentationError` / `TabError` | Mixed or missing indentation | Use 4 spaces; run `uv run ruff format .` |
| `RuntimeError: asyncio.run() cannot be called from a running event loop` | Calling `asyncio.run` inside async code | Use `await` inside coroutines; call `asyncio.run` once, at the top |
| `[Errno 111] Connection refused` | The Phase 1 server isn't running, or it's on another port | Start it; check `--url` |
| p50 in the seconds for `/health` | The generator is overloaded | Check its CPU (experiment 3); lower the rate |
| Different numbers each run | Normal variation | Repeat runs and report the spread; never trust a single run |

## Reading list

| When | Reading | Question to carry in |
|---|---|---|
| Step 1 | The [official Python tutorial](https://docs.python.org/3/tutorial/), §3–9 | How do Python's data structures compare with Go's? |
| Step 2 | Your Phase 1 histogram buckets; SRE Ch. 6, the section on latency | Why do SREs alert on percentiles, not averages? |
| Step 5 | Gil Tene, *How NOT to Measure Latency* (talk); the [asyncio docs](https://docs.python.org/3/library/asyncio.html) | Which tools you've used have a closed loop? |
| Step 6 | The [pandas "10 minutes" guide](https://pandas.pydata.org/docs/user_guide/10min.html); *Understanding Distributed Systems*, the monitoring chapter | Which plot would you show in an incident review? |
| After the bridge | Brendan Gregg, *Systems Performance*, Ch. 2 (*Methodologies*) | How do you avoid measuring the wrong thing? |
