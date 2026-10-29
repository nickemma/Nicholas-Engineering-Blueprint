# Phase 7 teaching: measure and learn

At the end of Phase 6, Runway is something strangers could use and customers could share: every request is authenticated, every tenant is kept apart, every connection is mutual TLS, and a game day checked each control against a threat model. It's secure. Is it any *good*? And it has been recording everything it does (every job, every state change, every metric) for six phases. Could that record make it better?

This phase answers both questions with evidence. It starts with how to make a claim about a system that survives someone checking it, because every later step makes one. Then it gives Runway's jobs real work to do, so how long a job takes becomes something worth predicting. It builds a pipeline from Runway's own event stream into files you can query, learns to predict job durations from them (first with baselines, then scikit-learn, then a neural network), serves the model behind the Go API, uses its predictions to schedule, and runs it like production software: a registry, a shadow, drift checks. Last, it turns the same tools on operations, and scores anomaly detectors against incidents you inject yourself.

**The goal:** every claim in this phase comes with the experiment behind it, written down before it ran, and with its uncertainty. A model goes into Runway only if it beats a simple baseline by more than the noise, and it fails safe: if the model server is slow or down, the API falls back to the baseline and nobody notices. When the jobs change, a drift check notices before the users do.

**Time:** about 10 weeks. **Before you start:** finish Phase 6, and keep its kind cluster and Compose services. You need `uv` (from the Python Bridge) and Java 17 or newer (for Spark, step 4; Phase 4's TLA+ already needed it). No GPU: every model here trains on a laptop CPU in minutes.

## How this guide works

The same as Phase 6: type everything, file by file, and run the checks at the end of each step. Most of this phase is Python, in a new project called `lab`, next to `kload`; the Go code changes where Runway itself changes (new job kinds in step 2, new events in step 3, calling the model in steps 8 and 9).

Your numbers will differ from mine, and more than in earlier phases: this phase measures, and a measurement depends on the machine it ran on. What should carry over is the *shape* of each result: which conditions differ, roughly by how much, and which don't. When yours disagrees, that's not a failure. It's a finding, and step 1 shows you how to tell the difference between a finding and noise.

**Measure before you explain.** An explanation that sounds right is not evidence. In this phase I'll show you several of mine that were wrong, and how a measurement exposed each one. When an AI assistant (or a colleague, or a blog post) tells you why something is slow or which model is better, the tools in this phase are how you check.

| Step | What you add |
|---|---|
| 1 | Experiments done right: a plan written first, A/A runs, interleaving, confidence intervals, and the traps |
| 2 | Jobs that do real work, so their duration is worth predicting; a workload generator |
| 3 | A data contract and a pipeline from Runway's events to Parquet, queried with DuckDB |
| 4 | Big data, honestly: MapReduce from scratch, Spark, and when one machine wins |
| 5 | A dataset and baselines: splits in time, leakage, and the right error metric |
| 6 | Machine learning with scikit-learn: gradient boosting, quantiles, and honest comparisons |
| 7 | Deep learning: backpropagation from scratch, then PyTorch |
| 8 | Serving: a model server with the same features as training, called safely from Go |
| 9 | Using the predictions: shortest-predicted-job-first, measured against FIFO |
| 10 | MLOps: tracking, a registry, a model card, and a gate in CI |
| 11 | A shadow deployment and drift detection |
| 12 | AIOps: anomaly detection on metrics and logs, scored against injected incidents |
| 13 | The report: an experiment someone else can rerun |

## Setup

Start from your finished Phase 6 code. From the repository root:

~~~bash
cd lessons/07-utility-evaluation
cp -r ../06-safe-shared-queries/practice practice
rm -rf practice/audit/target practice/kload/.venv
cd practice
go test ./...
~~~

<!-- continue: ../06-safe-shared-queries/TEACHING.md -->

Keep the Phase 6 variables (`RUNWAY_DATABASE_URL` and the rest) exported, the Compose services running, and the kind cluster up.

---
## Step 1: Experiments done right

**The problem.** Phase 6, step 8 measured what the TLS sidecar costs and concluded that the cost is the two extra hops, not TLS: plain relays and `tlsproxy` came out about the same. That conclusion came from a couple of runs. Here are four more, made while writing this step, one after another on the same machine:

~~~text
BenchmarkRoundTrip/relays-16         	   39811	     28292 ns/op
BenchmarkRoundTrip/tlsproxy-16         	   39530	     31959 ns/op
BenchmarkRoundTrip/relays-16         	   44180	     30970 ns/op
BenchmarkRoundTrip/tlsproxy-16         	   37195	     32407 ns/op
~~~

From these, TLS costs 9%. From Phase 6's, it cost nothing. Same code, same machine, two answers. Which is right? Neither pair of runs can say, because the difference between two runs of the *same* code (28,292 and 30,970 ns) is as big as the difference we're trying to measure. Every number in Phases 2 to 6 had this problem to some degree, and every later step in this phase makes a claim (this model is better, this schedule is faster) that will have it too. So first: how to make a claim about a system that survives someone checking it.

**New ideas.**

- **The experimental unit.** A benchmark run does about 40,000 round trips, but it's *one* measurement: all 40,000 share the same machine state (what else was running, how hot the CPU was, where memory happened to land). Treat them as 40,000 independent samples and every difference looks significant. The unit is the run; to learn about variation between runs, you need many runs.
- **An A/A experiment** compares a thing with itself. Any difference it finds is noise, so it measures how small an effect this machine can detect at all, before you look for one.
- **Interleaving.** Machines drift: a laptop heats up and slows down, another program starts. Run all of A and then all of B, and the drift lands on B alone and looks like an effect. Run them in alternating, randomly ordered rounds, and drift lands on both alike.
- **A confidence interval** is a range of effect sizes consistent with the data. "1.04 (95% CI 0.99 to 1.06)" says more than "p = 0.10": how big the effect might be, in both directions, and so whether more runs could ever make it matter. The **bootstrap** gets one without formulas: resample your runs with replacement many times, recompute the statistic each time, and use the spread.
- **A p-value** answers a narrower question: if there were no difference at all, how often would one this large turn up by chance? A **permutation test** computes it directly: shuffle the labels "A" and "B" thousands of times and count.
- **Significant isn't the same as important.** A difference can be real and too small to matter. Decide *before* running what size of change would matter (the **margin**), then ask both questions: is there a difference, and is it bigger than the margin?
- **Write the plan first.** The question, the metric, the number of runs and the comparisons, all fixed before the first run. Otherwise you'll decide them after seeing the data, and you'll pick (without meaning to) the ones that look interesting. Two traps follow from not doing this: testing many things and reporting the one that came out "significant", and **peeking**, checking after every run and stopping when the result looks good. Both find effects that aren't there, and the last part of this step counts how often.

### A project for experiments

The analysis is Python, in a new project next to `kload`, called `lab`:

<!-- run: mkdir -p lab/src/lab lab/tests && touch lab/src/lab/__init__.py && cd lab && uv python pin 3.12 -->
~~~bash
mkdir -p lab/src/lab lab/tests
touch lab/src/lab/__init__.py
cd lab && uv python pin 3.12
~~~

Create `lab/pyproject.toml`:

<!-- file: lab/pyproject.toml -->
~~~toml
[project]
name = "lab"
version = "0.1.0"
description = "Run and analyse experiments on Runway"
requires-python = ">=3.12"
dependencies = [
    "matplotlib>=3.11.2",
    "numpy>=2.5.4",
]

[project.scripts]
lab = "lab.cli:main"

[dependency-groups]
dev = [
    "pytest>=9.1.1",
    "ruff>=0.17.1",
]

[build-system]
requires = ["uv_build>=0.12.7,<0.13.0"]
build-backend = "uv_build"

[tool.ruff]
line-length = 100

[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP"]
~~~

It's `kload`'s, with NumPy for the arithmetic and Matplotlib for plots. (Not `uv init`: it writes your git name and email into the file.) Install everything:

<!-- run: cd lab && uv sync -->
~~~bash
uv sync
~~~

### Comparing two sets of runs

Create `lab/src/lab/stats.py`:

<!-- file: lab/src/lab/stats.py -->
~~~python
"""Comparing two sets of measurements: how different are they, and how sure can we be?

Every function takes the baseline's measurements first and the candidate's
second. Each measurement is one whole run (one benchmark run, one load
test), never one request inside a run: requests in the same run share the
same machine state, so they aren't independent of each other.
"""

from collections.abc import Sequence
from dataclasses import dataclass

import numpy as np


@dataclass(frozen=True)
class Comparison:
    """The candidate's median divided by the baseline's, with its uncertainty."""

    estimate: float  # 1.04 means the candidate's median is 4% higher
    low: float  # the confidence interval: a range of ratios consistent with the data
    high: float
    p_value: float  # how often a difference this large appears when there is none
    level: float  # 0.95 for a 95% interval


def ratio_of_medians(baseline: Sequence[float], candidate: Sequence[float]) -> float:
    return float(np.median(candidate) / np.median(baseline))


def bootstrap_ci(
    baseline: Sequence[float],
    candidate: Sequence[float],
    level: float = 0.95,
    resamples: int = 10_000,
    rng: np.random.Generator | None = None,
) -> tuple[float, float]:
    """A percentile bootstrap confidence interval for the ratio of medians.

    Each resample draws, with replacement, as many runs as each side really
    had, and computes the ratio again. The spread of those ratios stands in
    for the spread we'd see if we repeated the whole experiment.
    """
    rng = rng or np.random.default_rng()
    a, b = _array(baseline), _array(candidate)
    ma = np.median(a[rng.integers(0, len(a), size=(resamples, len(a)))], axis=1)
    mb = np.median(b[rng.integers(0, len(b), size=(resamples, len(b)))], axis=1)
    tail = (1 - level) / 2
    low, high = np.quantile(mb / ma, [tail, 1 - tail])
    return float(low), float(high)


def permutation_p(
    baseline: Sequence[float],
    candidate: Sequence[float],
    resamples: int = 10_000,
    rng: np.random.Generator | None = None,
) -> float:
    """The two-sided p-value for "both sides come from the same distribution".

    If they do, the labels "baseline" and "candidate" are arbitrary: shuffle
    them, and a ratio as far from 1 as the real one should turn up often.
    The p-value is how often it does.
    """
    rng = rng or np.random.default_rng()
    a, b = _array(baseline), _array(candidate)
    observed = abs(np.log(np.median(b) / np.median(a)))
    shuffled = rng.permuted(np.tile(np.concatenate([a, b]), (resamples, 1)), axis=1)
    ma = np.median(shuffled[:, : len(a)], axis=1)
    mb = np.median(shuffled[:, len(a) :], axis=1)
    extreme = np.abs(np.log(mb / ma)) >= observed - 1e-12
    # Counting the real labelling as one of the shuffles keeps p above zero:
    # 10,000 shuffles can't show anything rarer than 1 in 10,001.
    return float((extreme.sum() + 1) / (resamples + 1))


def compare(
    baseline: Sequence[float],
    candidate: Sequence[float],
    level: float = 0.95,
    resamples: int = 10_000,
    seed: int | None = None,
) -> Comparison:
    rng = np.random.default_rng(seed)
    low, high = bootstrap_ci(baseline, candidate, level, resamples, rng)
    return Comparison(
        estimate=ratio_of_medians(baseline, candidate),
        low=low,
        high=high,
        p_value=permutation_p(baseline, candidate, resamples, rng),
        level=level,
    )


def verdict(c: Comparison, margin: float) -> str:
    """Answer the two questions separately: is there a difference, and does it matter?

    margin is the smallest change worth caring about, decided before the
    experiment: 0.10 means anything within 10% either way doesn't matter.
    """
    within = 1 - margin <= c.low and c.high <= 1 + margin
    beyond = c.low > 1 + margin or c.high < 1 - margin
    differs = c.low > 1 or c.high < 1
    if beyond:
        return "different, by more than the margin"
    if within and differs:
        return "different, but by less than the margin"
    if within:
        return "equivalent within the margin"
    return "inconclusive: the interval is wider than the question"


def _array(values: Sequence[float]) -> np.ndarray:
    a = np.asarray(values, dtype=float)
    if a.ndim != 1 or len(a) < 2:
        raise ValueError("each side needs at least two measurements")
    if not np.all(a > 0):
        raise ValueError("measurements must be positive to compare as a ratio")
    return a
~~~

Everything compares *medians*, as a *ratio*. Medians, because one run disturbed by something else (a backup, a browser tab) shouldn't move the answer much; ratios, because "4% slower" means the same for a 10 µs operation as for a 10 s one. `bootstrap_ci` resamples both sides independently, 10,000 times, in two NumPy operations instead of a loop. `permutation_p` measures distance from "no difference" as `|log(ratio)|`, so 1.25 and 0.8 count as equally far from 1 (a quarter faster or a quarter slower). And `verdict` keeps the two questions apart: "different, but by less than the margin" is a perfectly good answer, and often the most useful one.

How do you know the statistics are right? Test them on data whose answer you know. Create `lab/tests/test_stats.py`:

<!-- file: lab/tests/test_stats.py -->
~~~python
import numpy as np
import pytest

from lab.stats import Comparison, bootstrap_ci, compare, permutation_p, ratio_of_medians, verdict


def runs(rng, median, n, spread=0.06):
    """n runs whose true median is median, with about spread run-to-run noise."""
    return median * np.exp(rng.normal(0, spread, n))


def test_ratio_of_medians():
    assert ratio_of_medians([10, 20, 30], [22, 11, 33]) == pytest.approx(1.1)


def test_a_clear_difference_is_found():
    rng = np.random.default_rng(1)
    c = compare(runs(rng, 100, 20), runs(rng, 120, 20), seed=1)
    assert 1.1 < c.low < c.estimate < c.high < 1.3
    assert c.p_value < 0.01


def test_the_same_seed_gives_the_same_answer():
    rng = np.random.default_rng(2)
    a, b = runs(rng, 100, 20), runs(rng, 100, 20)
    assert compare(a, b, seed=7) == compare(a, b, seed=7)


# The two tests below check the methods themselves, on data whose truth we
# know. A 95% interval that contains the true ratio 70% of the time, or a
# test that cries "different" a third of the time when nothing changed,
# would still print plausible numbers.


def test_the_interval_covers_the_truth_about_95_percent_of_the_time():
    rng = np.random.default_rng(3)
    trials, covered = 400, 0
    for _ in range(trials):
        low, high = bootstrap_ci(runs(rng, 100, 20), runs(rng, 104, 20), resamples=2000, rng=rng)
        covered += low <= 1.04 <= high
    assert 0.90 <= covered / trials <= 0.99, f"covered {covered} of {trials}"


def test_with_no_difference_p_is_below_005_about_5_percent_of_the_time():
    rng = np.random.default_rng(4)
    trials = 400
    hits = sum(
        permutation_p(runs(rng, 100, 20), runs(rng, 100, 20), resamples=1000, rng=rng) < 0.05
        for _ in range(trials)
    )
    assert 0.02 <= hits / trials <= 0.09, f"{hits} of {trials}"


@pytest.mark.parametrize(
    ("low", "high", "expected"),
    [
        (1.15, 1.25, "different, by more than the margin"),
        (0.80, 0.85, "different, by more than the margin"),
        (1.02, 1.06, "different, but by less than the margin"),
        (0.97, 1.04, "equivalent within the margin"),
        (0.97, 1.15, "inconclusive: the interval is wider than the question"),
        (1.05, 1.15, "inconclusive: the interval is wider than the question"),
    ],
)
def test_verdict(low, high, expected):
    c = Comparison(estimate=(low + high) / 2, low=low, high=high, p_value=0.5, level=0.95)
    assert verdict(c, margin=0.10) == expected


@pytest.mark.parametrize("bad", [[], [1.0], [1.0, 0.0], [1.0, -2.0]])
def test_compare_refuses_what_it_cannot_compare(bad):
    with pytest.raises(ValueError):
        compare([1.0, 2.0, 3.0], bad)
~~~

`runs` makes fake measurements with a known true median and about 6% noise between runs (what this machine shows, as you'll see). The two middle tests check the *methods*: across 400 simulated experiments with a true ratio of 1.04, the 95% interval should contain 1.04 about 95% of the time; and across 400 experiments with no difference at all, the test should say "p < 0.05" about 5% of the time. A broken bootstrap still prints plausible intervals. Only a test like this notices.

<!-- run: cd lab && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_stats.py -->
~~~bash
uv run pytest -q tests/test_stats.py
~~~

**Break it.** In `bootstrap_ci`, resample only the candidate's side: replace the `ma = ...` line with `ma = np.median(a)`. It's an easy mistake (it looks like a shortcut), and the intervals it prints still look reasonable. Run the tests:

~~~text
>       assert 0.90 <= covered / trials <= 0.99, f"covered {covered} of {trials}"
E       AssertionError: covered 321 of 400
~~~

The "95%" interval contained the truth only 80% of the time: it ignored the baseline's own noise, so it was too narrow, and too sure. Put it back. (Correct, it covers 96 to 97% at 5, 10, 20 and 40 runs a side: slightly cautious, because a median of few values can only take a few distinct values.)

### Reading benchmark output

The first experiment measures a Go benchmark, so `lab` needs to read `go test -bench` output. Create `lab/src/lab/gobench.py`:

<!-- file: lab/src/lab/gobench.py -->
~~~python
"""Reading `go test -bench` output."""

import re

# BenchmarkRoundTrip/relays-16    39811    28292 ns/op    512 B/op
# name, then GOMAXPROCS after the dash, then iterations, then value-unit pairs.
LINE = re.compile(r"^(Benchmark\S+?)(?:-(\d+))?\s+(\d+)\s+(.*)$")


def parse(output: str) -> list[dict[str, float | str]]:
    """Return one dict per result line: name, procs, iterations, and each unit's value."""
    results = []
    for line in output.splitlines():
        match = LINE.match(line.strip())
        if not match:
            continue
        name, procs, iterations, rest = match.groups()
        result: dict[str, float | str] = {
            "name": name,
            "procs": int(procs or 1),
            "iterations": int(iterations),
        }
        fields = rest.split()
        for value, unit in zip(fields[::2], fields[1::2], strict=False):
            result[unit] = float(value)
        results.append(result)
    return results


def value(output: str, unit: str) -> float:
    """The one value in output measured in unit. Anything else is an error, not a guess."""
    found = [r[unit] for r in parse(output) if unit in r]
    if len(found) != 1:
        raise ValueError(f"want exactly one {unit} result, found {len(found)}")
    return float(found[0])
~~~

`value` insists on exactly one result. If a command printed none (it failed quietly) or two (someone added `-count 2`), averaging whatever was there would hide the mistake.

Create `lab/tests/test_gobench.py`:

<!-- file: lab/tests/test_gobench.py -->
~~~python
import pytest

from lab.gobench import parse, value

OUTPUT = """goos: linux
goarch: amd64
pkg: runway/internal/tlsproxy
cpu: AMD Ryzen 7 5800H with Radeon Graphics
BenchmarkRoundTrip/relays-16         	   39811	     28292 ns/op
PASS
"""


def test_parse_reads_name_procs_iterations_and_units():
    assert parse(OUTPUT) == [
        {"name": "BenchmarkRoundTrip/relays", "procs": 16, "iterations": 39811, "ns/op": 28292.0}
    ]


def test_parse_reads_every_unit_on_a_line():
    (r,) = parse("BenchmarkX-8   100   12.5 ns/op   64 B/op   2 allocs/op")
    assert (r["ns/op"], r["B/op"], r["allocs/op"]) == (12.5, 64.0, 2.0)


def test_parse_without_procs_suffix():
    (r,) = parse("BenchmarkX   100   12.5 ns/op")
    assert (r["name"], r["procs"]) == ("BenchmarkX", 1)


def test_value():
    assert value(OUTPUT, "ns/op") == 28292.0


@pytest.mark.parametrize(
    "output",
    ["PASS\n", OUTPUT + OUTPUT, OUTPUT.replace("ns/op", "B/op")],
    ids=["none", "two", "other unit"],
)
def test_value_wants_exactly_one_result(output):
    with pytest.raises(ValueError, match="exactly one ns/op"):
        value(output, "ns/op")
~~~

### Running a plan

An experiment is a **plan** (a TOML file written before any run) and a **results** directory (everything the runs produced, never edited). Create `lab/src/lab/experiment.py`:

<!-- file: lab/src/lab/experiment.py -->
~~~python
"""Running an experiment from its plan, keeping every raw result."""

import json
import os
import platform
import subprocess
import time
import tomllib
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

import numpy as np

from lab import gobench

# Runs a shell command and returns what it printed. Tests pass a fake.
Execute = Callable[[str], str]


@dataclass(frozen=True)
class Plan:
    """Everything decided before the first run. See experiments/*/plan.toml."""

    name: str
    question: str
    hypothesis: str
    metric: str
    rounds: int
    seed: int
    conditions: dict[str, str]
    compare: list[dict] = field(default_factory=list)
    order: str = "interleaved"
    setup: str = ""


def load_plan(path: Path) -> Plan:
    with path.open("rb") as f:
        raw = tomllib.load(f)
    plan = Plan(name=path.parent.name, **raw)
    if plan.order not in ("interleaved", "sequential"):
        raise ValueError(f"order must be interleaved or sequential, not {plan.order!r}")
    if len(plan.conditions) < 2:
        raise ValueError("a plan needs at least two conditions")
    for c in plan.compare:
        for side in ("baseline", "candidate"):
            if c[side] not in plan.conditions:
                raise ValueError(f"compare names {c[side]!r}, which isn't a condition")
    return plan


def schedule(plan: Plan) -> list[tuple[int, str]]:
    """The (round, condition) pairs in the order they will run.

    Interleaved: every round runs each condition once, in a fresh random
    order, so anything that drifts during the experiment (a hot laptop,
    another program) lands on all conditions alike. Sequential runs every
    round of one condition before the next; it exists to show why not.
    """
    names = list(plan.conditions)
    if plan.order == "sequential":
        return [(r, n) for n in names for r in range(1, plan.rounds + 1)]
    rng = np.random.default_rng(plan.seed)
    return [(r, str(n)) for r in range(1, plan.rounds + 1) for n in rng.permutation(names)]


def shell(command: str) -> str:
    done = subprocess.run(command, shell=True, capture_output=True, text=True)
    if done.returncode != 0:
        raise RuntimeError(f"{command!r} exited {done.returncode}:\n{done.stderr[-2000:]}")
    return done.stdout


def run(plan: Plan, out: Path, execute: Execute = shell, log: Callable[[str], None] = print):
    """Run the plan, writing manifest.json, results.jsonl and raw/ into out."""
    if out.exists() and any(out.iterdir()):
        raise FileExistsError(f"{out} is not empty: results are never overwritten")
    (out / "raw").mkdir(parents=True)
    if plan.setup:
        execute(plan.setup)
    manifest = {
        "plan": plan.__dict__,
        "started": _now(),
        "host": {
            "cpus": os.cpu_count(),
            "platform": platform.platform(),
            "python": platform.python_version(),
            "load_before": os.getloadavg()[0],
        },
        "versions": {
            "go": _try(execute, "go version"),
            "commit": _try(execute, "git rev-parse --short HEAD"),
        },
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    order = schedule(plan)
    with (out / "results.jsonl").open("w") as results:
        for position, (round_, condition) in enumerate(order, start=1):
            load = os.getloadavg()[0]
            started = time.monotonic()
            output = execute(plan.conditions[condition])
            seconds = time.monotonic() - started
            raw = f"raw/{position:03d}-{condition}.txt"
            (out / raw).write_text(output)
            row = {
                "position": position,
                "round": round_,
                "condition": condition,
                "value": gobench.value(output, plan.metric),
                "seconds": round(seconds, 3),
                "load": load,
                "raw": raw,
            }
            results.write(json.dumps(row) + "\n")
            results.flush()
            log(f"{position}/{len(order)} {condition} {row['value']:g} {plan.metric}")


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _try(execute: Execute, command: str) -> str | None:
    """A version string if the command works here, None if not."""
    try:
        return execute(f"{command} 2>/dev/null").strip() or None
    except RuntimeError:
        return None
~~~

Look at what `run` keeps: the plan as it was used, the machine (CPUs, platform, load), the Go version and the commit, and for each run its position, round, value, duration, the load average just before it, and the full raw output. That's enough for someone else to see exactly what happened, and to recompute everything from `raw/` if they distrust `lab`. It refuses to write into a directory that has results in it: results are never overwritten, only added. `Plan(**raw)` refuses keys it doesn't know, so a typo like `rouds = 20` is an error instead of a silently ignored setting.

`schedule` is the interleaving. Each round runs every condition once, in a new random order drawn from the plan's seed, so the order is random but reproducible.

Create `lab/tests/test_experiment.py`:

<!-- file: lab/tests/test_experiment.py -->
~~~python
import json
from collections import Counter

import pytest

from lab.analyze import plot, report
from lab.experiment import Plan, load_plan, run, schedule

PLAN = """question = "Is b slower than a?"
hypothesis = "b is within 10% of a"
metric = "ns/op"
rounds = 4
seed = 1
setup = "make things"

[conditions]
a = "bench a"
b = "bench b"

[[compare]]
baseline = "a"
candidate = "b"
margin = 0.10
"""


def plan(**changes) -> Plan:
    fields = dict(
        name="t", question="q", hypothesis="h", metric="ns/op", rounds=3, seed=1,
        conditions={"a": "bench a", "b": "bench b", "c": "bench c"},
    )  # fmt: skip
    return Plan(**(fields | changes))


class FakeBench:
    """Answers each condition's command with a benchmark line; remembers what ran."""

    def __init__(self, values):
        self.values = values
        self.ran = []

    def __call__(self, command):
        self.ran.append(command)
        if command.startswith("bench "):
            name = command.removeprefix("bench ")
            return f"BenchmarkX-4  1000  {self.values[name]} ns/op\n"
        return ""


def test_load_plan(tmp_path):
    path = tmp_path / "toy" / "plan.toml"
    path.parent.mkdir()
    path.write_text(PLAN)
    p = load_plan(path)
    assert (p.name, p.rounds, p.order, p.conditions["b"]) == ("toy", 4, "interleaved", "bench b")


@pytest.mark.parametrize(
    ("old", "new", "error"),
    [
        ("seed = 1", 'seed = 1\norder = "random"', "order must be"),
        ("seed = 1", 'seed = 1\ncolour = "red"', "colour"),
        ('candidate = "b"', 'candidate = "c"', "isn't a condition"),
        ('b = "bench b"', "", "at least two conditions"),
    ],
)
def test_load_plan_refuses_a_plan_it_cannot_follow(tmp_path, old, new, error):
    path = tmp_path / "plan.toml"
    path.write_text(PLAN.replace(old, new))
    with pytest.raises((ValueError, TypeError), match=error):
        load_plan(path)


def test_interleaved_runs_every_condition_once_per_round_in_varying_order():
    order = schedule(plan(rounds=20))
    for r in range(1, 21):
        assert sorted(n for rr, n in order if rr == r) == ["a", "b", "c"]
    firsts = Counter(order[i][1] for i in range(0, len(order), 3))
    assert len(firsts) == 3, "every condition should sometimes go first"
    assert schedule(plan(rounds=20)) == order, "the same seed gives the same order"


def test_sequential_runs_one_condition_at_a_time():
    order = schedule(plan(order="sequential"))
    assert [n for _, n in order] == ["a"] * 3 + ["b"] * 3 + ["c"] * 3


def test_run_records_everything(tmp_path):
    bench = FakeBench({"a": 100, "b": 110, "c": 90})
    out = tmp_path / "out"
    run(plan(setup="make things"), out, execute=bench, log=lambda _: None)

    assert bench.ran[0] == "make things"
    manifest = json.loads((out / "manifest.json").read_text())
    assert manifest["plan"]["conditions"]["b"] == "bench b"
    assert manifest["host"]["cpus"] > 0
    rows = [json.loads(line) for line in (out / "results.jsonl").read_text().splitlines()]
    assert len(rows) == 9
    assert [r["position"] for r in rows] == list(range(1, 10))
    for r in rows:
        assert r["value"] == {"a": 100, "b": 110, "c": 90}[r["condition"]]
        assert (out / r["raw"]).read_text().startswith("BenchmarkX-4")


def test_run_never_overwrites_results(tmp_path):
    (tmp_path / "old.txt").write_text("last week's data")
    with pytest.raises(FileExistsError):
        run(plan(), tmp_path, execute=FakeBench({}), log=lambda _: None)


def test_report_answers_the_planned_comparison(tmp_path):
    bench = FakeBench({"a": 100, "b": 100})
    p = plan(rounds=6, conditions={"a": "bench a", "b": "bench b"},
             compare=[{"baseline": "a", "candidate": "b", "margin": 0.1}])  # fmt: skip
    run(p, tmp_path / "out", execute=bench, log=lambda _: None)
    text = report(tmp_path / "out")
    assert "b / a: 1.000" in text
    assert "margin ±10%: equivalent within the margin" in text
    assert plot(tmp_path / "out").stat().st_size > 0
~~~

`FakeBench` stands in for the shell, the same dependency injection as `kload`'s `MockTransport`: the runner's logic is tested in a second, without running a benchmark.

### Analysing, and the traps

Create `lab/src/lab/analyze.py`:

<!-- file: lab/src/lab/analyze.py -->
~~~python
"""Turning an experiment's raw results into the answer its plan asked for."""

import json
from pathlib import Path

import numpy as np
from matplotlib.figure import Figure  # draws straight to a file: no window, no pyplot state

from lab.stats import compare, verdict


def load(out: Path) -> tuple[dict, list[dict]]:
    manifest = json.loads((out / "manifest.json").read_text())
    rows = [json.loads(line) for line in (out / "results.jsonl").read_text().splitlines()]
    return manifest, rows


def values(rows: list[dict], condition: str) -> list[float]:
    return [r["value"] for r in rows if r["condition"] == condition]


def report(out: Path, seed: int = 1) -> str:
    """The plan's question, a summary of every condition, and each planned comparison.

    Only the comparisons the plan named are made. Comparing everything with
    everything after looking at the data is how chance results get reported.
    """
    manifest, rows = load(out)
    plan = manifest["plan"]
    lines = [
        f"{plan['name']}: {plan['question']}",
        f"order {plan['order']}, {plan['rounds']} rounds, seed {plan['seed']}, "
        f"load {manifest['host']['load_before']:.1f} before",
        "",
        f"{'condition':<12}{'runs':>5}{'median':>12}{'min':>12}{'max':>12}{'cv':>8}",
    ]
    for name in plan["conditions"]:
        v = np.array(values(rows, name))
        cv = v.std(ddof=1) / v.mean()
        lines.append(
            f"{name:<12}{len(v):>5}{np.median(v):>12.1f}{v.min():>12.1f}{v.max():>12.1f}{cv:>8.1%}"
        )
    for c in plan["compare"]:
        result = compare(values(rows, c["baseline"]), values(rows, c["candidate"]), seed=seed)
        lines += [
            "",
            f"{c['candidate']} / {c['baseline']}: {result.estimate:.3f} "
            f"({result.level:.0%} CI {result.low:.3f} to {result.high:.3f}), "
            f"p = {result.p_value:.4f}",
            f"  margin ±{c['margin']:.0%}: {verdict(result, c['margin'])}",
        ]
    return "\n".join(lines)


def plot(out: Path) -> Path:
    """Every run in the order it ran, with the machine's load: look before you trust a summary."""
    manifest, rows = load(out)
    fig = Figure(figsize=(9, 4))
    ax = fig.subplots()
    for name in manifest["plan"]["conditions"]:
        mine = [r for r in rows if r["condition"] == name]
        ax.plot([r["position"] for r in mine], [r["value"] for r in mine], "o", label=name)
    ax.set_xlabel("run, in the order it ran")
    ax.set_ylabel(manifest["plan"]["metric"])
    ax.legend(loc="upper left")
    load_ax = ax.twinx()
    load_ax.plot([r["position"] for r in rows], [r["load"] for r in rows], color="grey", lw=1)
    load_ax.set_ylabel("load average (grey)")
    fig.tight_layout()
    path = out / "runs.png"
    fig.savefig(path, dpi=100)
    return path
~~~

`report` makes only the comparisons the plan named. `plot` draws every run in the order it ran, with the load average beside it. Look at it before you believe any summary: a summary can't show you a trend, an outlier, or a block of runs that went wrong.

Create `lab/src/lab/sim.py`, which counts how often the two traps find effects that aren't there:

<!-- file: lab/src/lab/sim.py -->
~~~python
"""Simulated experiments in which nothing changes, to count how often we'd claim something did."""

import numpy as np

from lab.stats import permutation_p


def _aa(rng: np.random.Generator, n: int) -> tuple[np.ndarray, np.ndarray]:
    """Two sides of n runs each from the same distribution: an A/A experiment."""
    return 100 * np.exp(rng.normal(0, 0.06, n)), 100 * np.exp(rng.normal(0, 0.06, n))


def many_comparisons(tests: int, trials: int, n: int = 20, seed: int = 1) -> float:
    """How often at least one of `tests` A/A comparisons comes out "significant"."""
    rng = np.random.default_rng(seed)
    hits = 0
    for _ in range(trials):
        hits += any(
            permutation_p(*_aa(rng, n), resamples=500, rng=rng) < 0.05 for _ in range(tests)
        )
    return hits / trials


def peeking(rounds: int, first_look: int, trials: int, seed: int = 1) -> tuple[float, float]:
    """A/A false-positive rates when stopping at the first p < 0.05, and when looking once.

    The peeking analyst checks after every round from first_look on and stops
    as soon as the result looks significant. The patient one looks once, at
    the planned number of rounds, on the same data.
    """
    rng = np.random.default_rng(seed)
    peeked = patient = 0
    for _ in range(trials):
        a, b = _aa(rng, rounds)
        ps = [
            permutation_p(a[:k], b[:k], resamples=500, rng=rng)
            for k in range(first_look, rounds + 1)
        ]
        peeked += min(ps) < 0.05
        patient += ps[-1] < 0.05
    return peeked / trials, patient / trials
~~~

Create `lab/tests/test_sim.py`:

<!-- file: lab/tests/test_sim.py -->
~~~python
from lab.sim import many_comparisons, peeking


def test_more_comparisons_more_false_positives():
    one = many_comparisons(tests=1, trials=200)
    twenty = many_comparisons(tests=20, trials=200)
    assert one < 0.1
    assert twenty > 0.5


def test_peeking_finds_effects_that_are_not_there():
    peeked, patient = peeking(rounds=30, first_look=5, trials=200)
    assert patient < 0.1
    assert peeked > 2 * patient
~~~

And the command line, `lab/src/lab/cli.py`:

<!-- file: lab/src/lab/cli.py -->
~~~python
"""The lab command line: run an experiment, analyse it, or simulate the traps."""

import argparse
from pathlib import Path

from lab import analyze, experiment, sim


def cmd_run(args: argparse.Namespace) -> int:
    plan = experiment.load_plan(args.plan)
    out = args.out or args.plan.parent / "results" / args.label
    experiment.run(plan, out)
    print(f"results in {out}")
    return 0


def cmd_analyze(args: argparse.Namespace) -> int:
    print(analyze.report(args.results))
    print(f"\nplot: {analyze.plot(args.results)}")
    return 0


def cmd_simulate(args: argparse.Namespace) -> int:
    if args.trap == "many":
        for tests in (1, 5, 20):
            rate = sim.many_comparisons(tests, trials=args.trials)
            print(f"{tests:>2} A/A comparisons: at least one p < 0.05 in {rate:.0%} of experiments")
    else:
        peeked, patient = sim.peeking(rounds=40, first_look=5, trials=args.trials)
        print(f"look once at 40 rounds:          p < 0.05 in {patient:.0%} of A/A experiments")
        print(f"look after every round from 5:  p < 0.05 in {peeked:.0%} of A/A experiments")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="lab", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="run an experiment's plan")
    run.add_argument("plan", type=Path, help="path to plan.toml")
    run.add_argument("--label", default="latest", help="results/<label> beside the plan")
    run.add_argument("--out", type=Path, help="results directory (overrides --label)")
    run.set_defaults(func=cmd_run)

    an = sub.add_parser("analyze", help="answer the plan's question from its results")
    an.add_argument("results", type=Path, help="a results directory written by lab run")
    an.set_defaults(func=cmd_analyze)

    simulate = sub.add_parser(
        "simulate", help="count false positives in experiments with no effect"
    )
    simulate.add_argument("trap", choices=["many", "peeking"])
    simulate.add_argument("--trials", type=int, default=500)
    simulate.set_defaults(func=cmd_simulate)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)
~~~

<!-- run: cd lab && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->
~~~bash
uv run ruff format --check . && uv run ruff check . && uv run pytest -q
~~~

~~~text
..................................                                       [100%]
34 passed in 11.61s
~~~

Keep `lab`, the experiments and built binaries out of the Docker build context:

Change:

<!-- edit: .dockerignore -->
~~~text
kload
tla
~~~

to:

~~~text
kload
lab
experiments
bin
tla
~~~


### Run it: how noisy is this machine?

Go back to `practice/` (`cd ..`) and run everything from there from now on. First, an A/A experiment. Create `experiments/aa-relays/plan.toml`:

<!-- file: experiments/aa-relays/plan.toml -->
~~~toml
# An A/A experiment: both conditions run the same thing. Any "difference"
# it finds is noise, and the width of its interval is how small an effect
# this machine can see in this many rounds.
question = "How much do two identical runs of the relays benchmark differ?"
hypothesis = "a and b are the same, so their ratio's interval contains 1"
metric = "ns/op"
rounds = 20
seed = 1
setup = "go test -c -o bin/tlsproxy.test ./internal/tlsproxy"

[conditions]
a = "bin/tlsproxy.test -test.run '^$' -test.bench 'RoundTrip/^relays$' -test.benchtime 1s"
b = "bin/tlsproxy.test -test.run '^$' -test.bench 'RoundTrip/^relays$' -test.benchtime 1s"

[[compare]]
baseline = "a"
candidate = "b"
margin = 0.10
~~~

The `setup` command builds the benchmark into a binary once, so compiling doesn't happen inside the measurements. Each condition then runs only the `relays` sub-benchmark, for one second. Run it (about two minutes):

~~~bash
uv run --project lab lab run experiments/aa-relays/plan.toml --label first
uv run --project lab lab analyze experiments/aa-relays/results/first
~~~

~~~text
aa-relays: How much do two identical runs of the relays benchmark differ?
order interleaved, 20 rounds, seed 1, load 8.7 before

condition    runs      median         min         max      cv
a              20     28927.0     27699.0     36517.0    8.1%
b              20     28352.0     26466.0     31841.0    5.7%

b / a: 0.980 (95% CI 0.940 to 1.041), p = 0.4611
  margin ±10%: equivalent within the margin

plot: experiments/aa-relays/results/first/runs.png
~~~

Two identical conditions, and the ratio of their medians could be anywhere from 0.94 to 1.04: on this machine, with the kind cluster and Compose running, 20 rounds can't see an effect much smaller than about 5%. Open the plot:

![The A/A runs in order: both conditions spread between 26,000 and 36,000 ns, mixed together, while the load average climbs from 9 to 19.](images/s01-aa-first.png)

Two things in it. Both colours are mixed together across the whole run, as they should be when nothing differs. And the load average climbs from 9 to 19 *during* the experiment, which is mostly the benchmark itself: load average counts runnable threads, ours included.

### Run it: does TLS cost anything?

Now the question from the start of this step. Create `experiments/sidecar-cost/plan.toml`:

<!-- file: experiments/sidecar-cost/plan.toml -->
~~~toml
# Phase 6, step 8 claimed the sidecar's cost is the extra hops, not TLS:
# plain relays and tlsproxy measured about the same. That was two runs
# each. This plan was written before any of its runs.
question = "Does TLS add to the sidecar's cost, beyond the two extra hops?"
hypothesis = "tlsproxy's round trip is within 10% of plain relays'"
metric = "ns/op"
rounds = 20  # the A/A run's interval was about ±5%: enough to settle a ±10% question
seed = 2
setup = "go test -c -o bin/tlsproxy.test ./internal/tlsproxy"

[conditions]
direct = "bin/tlsproxy.test -test.run '^$' -test.bench 'RoundTrip/^direct$' -test.benchtime 1s"
relays = "bin/tlsproxy.test -test.run '^$' -test.bench 'RoundTrip/^relays$' -test.benchtime 1s"
tlsproxy = "bin/tlsproxy.test -test.run '^$' -test.bench 'RoundTrip/^tlsproxy$' -test.benchtime 1s"

# Two questions, both decided now. The main one: does TLS matter?
[[compare]]
baseline = "relays"
candidate = "tlsproxy"
margin = 0.10

# And for scale: what do the hops themselves cost?
[[compare]]
baseline = "direct"
candidate = "relays"
margin = 0.10
~~~

It names its margin (10%) and its two comparisons before any run, and the comment on `rounds` says why 20 is enough: the A/A interval was about ±5%, comfortably narrower than the ±10% that matters. Run it (about three minutes):

~~~bash
uv run --project lab lab run experiments/sidecar-cost/plan.toml --label first
uv run --project lab lab analyze experiments/sidecar-cost/results/first
~~~

~~~text
sidecar-cost: Does TLS add to the sidecar's cost, beyond the two extra hops?
order interleaved, 20 rounds, seed 2, load 15.8 before

condition    runs      median         min         max      cv
direct         20      9213.5      8366.0     10677.0    7.2%
relays         20     29481.0     27291.0     32617.0    4.3%
tlsproxy       20     30312.0     27856.0     34692.0    5.3%

tlsproxy / relays: 1.028 (95% CI 0.989 to 1.063), p = 0.1016
  margin ±10%: equivalent within the margin

relays / direct: 3.200 (95% CI 3.038 to 3.349), p = 0.0001
  margin ±10%: different, by more than the margin

plot: experiments/sidecar-cost/results/first/runs.png
~~~

The planned question has its answer: whatever TLS costs, it's within 10%, and Phase 6's conclusion stands. The hops are another matter: 3.2 times a direct round trip. But notice what this experiment *didn't* answer. Its interval, 0.989 to 1.063, contains 1: TLS might cost nothing, or 6%. That's not a failure; the plan asked whether the cost mattered, not whether it existed.

### Run it: a follow-up

To ask whether TLS costs *anything*, you might add rounds to `sidecar-cost` until the interval clears 1. Don't: that's peeking (you'll see its price below). Write a new plan instead, with its own question. An interval's width shrinks with the square root of the number of runs, so five times the rounds gives a bit under half the width. Create `experiments/tls-overhead/plan.toml`:

<!-- file: experiments/tls-overhead/plan.toml -->
~~~toml
# A follow-up, planned after sidecar-cost: its interval (0.989 to 1.063)
# couldn't say whether TLS costs anything at all. Not by adding rounds to
# that experiment, which would be peeking, but with a new plan. Interval
# width shrinks with the square root of the rounds: 5x the rounds, a bit
# under half the width.
question = "Does TLS cost anything measurable, and is it under 5%?"
hypothesis = "tlsproxy is slower than relays, by less than 5%"
metric = "ns/op"
rounds = 100
seed = 3
setup = "go test -c -o bin/tlsproxy.test ./internal/tlsproxy"

[conditions]
relays = "bin/tlsproxy.test -test.run '^$' -test.bench 'RoundTrip/^relays$' -test.benchtime 1s"
tlsproxy = "bin/tlsproxy.test -test.run '^$' -test.bench 'RoundTrip/^tlsproxy$' -test.benchtime 1s"

[[compare]]
baseline = "relays"
candidate = "tlsproxy"
margin = 0.05
~~~

My hypothesis, written before running it: TLS costs something, but less than 5%. This one takes about seven minutes:

~~~bash
uv run --project lab lab run experiments/tls-overhead/plan.toml --label first
uv run --project lab lab analyze experiments/tls-overhead/results/first
~~~

~~~text
tls-overhead: Does TLS cost anything measurable, and is it under 5%?
order interleaved, 100 rounds, seed 3, load 15.4 before

condition    runs      median         min         max      cv
relays        100     28780.0     25622.0     44584.0    9.4%
tlsproxy      100     30333.0     26014.0     40470.0    8.5%

tlsproxy / relays: 1.054 (95% CI 1.027 to 1.079), p = 0.0001
  margin ±5%: inconclusive: the interval is wider than the question

plot: experiments/tls-overhead/results/first/runs.png
~~~

TLS does cost something: the interval, 1.027 to 1.079, is clear of 1 (and p is as small as 10,000 shuffles can show). But my "under 5%" isn't supported: the best estimate is 5.4%, and the interval straddles the line. So the honest report is "TLS adds about 3 to 8% to a relayed round trip; whether that's under 5% is undecided", and Phase 6's "about the same" was rounding a real 5% away. It's still small next to the hops (+220%), so step 8's design advice stands: the cost of a sidecar is the hop.

Note what *not* to do now: run it again, or with more rounds, until it says "under 5%". A result you keep re-running until you like it is the peeking trap again, more slowly. If the 5% line mattered, the next plan would ask a sharper question, with its rounds chosen from this interval's width.

![The 200 runs of tls-overhead in order: tlsproxy mostly above relays throughout, with spikes in both when the load average jumps.](images/s01-tls-overhead.png)

### Check it against benchstat

`lab` is code I wrote and you typed; it could have a bug the tests don't catch. Go has its own tool for exactly this comparison, `benchstat`, written independently (it uses a different test, Mann-Whitney U). If both agree, it's unlikely both are wrong the same way. `benchstat` compares rows with the same name, so strip the sub-benchmark's name and label each file instead:

~~~bash
R=experiments/tls-overhead/results/first/raw
cat $R/*-relays.txt | sed 's#RoundTrip/relays#RoundTrip#' > /tmp/relays.txt
cat $R/*-tlsproxy.txt | sed 's#RoundTrip/tlsproxy#RoundTrip#' > /tmp/tlsproxy.txt
go run golang.org/x/perf/cmd/benchstat@v0.0.0-20261009192801-be2c69fb417e relays=/tmp/relays.txt tlsproxy=/tmp/tlsproxy.txt
~~~

~~~text
             │   relays    │              tlsproxy               │
             │   sec/op    │   sec/op     vs base                │
RoundTrip-16   28.78µ ± 2%   30.33µ ± 2%  +5.40% (p=0.000 n=100)
~~~

The same medians, the same +5.4%. On `sidecar-cost`'s raw files it says `29.48µ ± 3%   30.31µ ± 4%  ~ (p=0.076 n=20)`: `~` means "no significant difference", where `lab` said p = 0.10. Different tests, the same conclusion. (The `± 2%` is each median's own interval, not the difference's.)

### Break it: all of A, then all of B

Interleaving is a claim too. Test it: add `order = "sequential"` under `seed` in `experiments/aa-relays/plan.toml`, start the run, and when the first `b` run starts, load the machine from a second terminal, as if a build or a backup had begun:

~~~bash
uv run --project lab lab run experiments/aa-relays/plan.toml --label sequential
~~~

~~~bash
for i in $(seq 8); do timeout 45 sh -c 'while :; do :; done' & done
~~~

~~~bash
uv run --project lab lab analyze experiments/aa-relays/results/sequential
~~~

~~~text
aa-relays: How much do two identical runs of the relays benchmark differ?
order sequential, 20 rounds, seed 1, load 16.6 before

condition    runs      median         min         max      cv
a              20     27103.5     24941.0     29091.0    4.6%
b              20     41712.0     26590.0     52585.0   13.0%

b / a: 1.539 (95% CI 1.452 to 1.639), p = 0.0001
  margin ±10%: different, by more than the margin

plot: experiments/aa-relays/results/sequential/runs.png
~~~

The same code, run twice, is "54% slower", with p as small as it can be. Nothing in the summary warns you; only the plot does:

![Sequential A/A: all 20 a runs at about 27,000 ns, then all 20 b runs between 36,000 and 52,000 ns.](images/s01-aa-sequential.png)

Now take `order = "sequential"` out again, and repeat with the default interleaved order, starting the same load halfway (after 20 runs):

~~~text
aa-relays: How much do two identical runs of the relays benchmark differ?
order interleaved, 20 rounds, seed 1, load 22.8 before

condition    runs      median         min         max      cv
a              20     32067.0     24813.0     50533.0   27.8%
b              20     32390.0     25030.0     55609.0   30.7%

b / a: 1.010 (95% CI 0.666 to 1.735), p = 0.9516
  margin ±10%: inconclusive: the interval is wider than the question

plot: experiments/aa-relays/results/hog/runs.png
~~~

The load hit both conditions alike, so the estimate stayed at 1.01, and the interval (0.67 to 1.74) admits that this experiment can't tell you much. Interleaving doesn't remove noise. It turns noise into *uncertainty* that the interval reports, instead of a *bias* that nothing reports. (In both plots the grey line rises slowly after the load starts: the load average is a one-minute moving average, so it lags.)

### Break it: the traps, counted

`lab simulate` runs hundreds of A/A experiments on fake data, where we know nothing differs, and counts the "significant" results:

~~~bash
uv run --project lab lab simulate many
uv run --project lab lab simulate peeking
~~~

~~~text
 1 A/A comparisons: at least one p < 0.05 in 5% of experiments
 5 A/A comparisons: at least one p < 0.05 in 23% of experiments
20 A/A comparisons: at least one p < 0.05 in 63% of experiments
look once at 40 rounds:          p < 0.05 in 5% of A/A experiments
look after every round from 5:  p < 0.05 in 27% of A/A experiments
~~~

Compare 20 metrics (latency, throughput, p99 per endpoint...) and you'll "find" an effect in nearly two experiments out of three where nothing changed; the arithmetic is 1 − 0.95²⁰ = 64%. Check after every round and stop when it looks good, and a 5% false-alarm rate becomes 27%. This is why the plan names its comparisons and its rounds in advance, and why `report` makes only the comparisons the plan names. (If you truly need many comparisons, divide 0.05 by their number, the Bonferroni correction. It's crude, but it's honest.)

**Explain it:** why is a benchmark run, not an iteration, the unit of measurement? What does an A/A experiment tell you that an A/B can't? Why did the sequential A/A find a "difference" and the interleaved one didn't, under the same load? What does "different, but by less than the margin" mean, and why is it often the most useful verdict? Why must the follow-up be a new plan rather than more rounds of the old one? Why check `lab` against `benchstat`?

**Read.** Mytkowicz, Diwan, Hauswirth and Sweeney, *Producing Wrong Data Without Doing Anything Obviously Wrong!* (ASPLOS 2009): the size of your environment variables changed their benchmark results by more than many published improvements. Then Georges, Buytaert and Eeckhout, *Statistically Rigorous Java Performance Evaluation* (OOPSLA 2007), sections 1 to 4: what goes wrong when papers report one run. Then Kohavi, Tang and Xu, *Trustworthy Online Controlled Experiments* (2020), chapter 3, *Twyman's Law and Experimentation Trustworthiness*: "any figure that looks interesting or different is usually wrong".

---
## Step 2: Jobs that do real work

**The problem.** Every Runway job so far has done the same thing: slept for a duration its creator chose. That was enough to test queues, retries, timeouts and autoscaling, but it leaves nothing to learn: how long will a job take? Exactly as long as it says. The rest of this phase predicts how long jobs take and uses the predictions, so jobs need to do real work whose cost nobody declares: the cost depends on the input, and on what else the machine is doing.

**New ideas.**

- **Work has a fixed cost and a proportional cost.** Setting up (allocating buffers, making the input) costs the same for a tiny job and a big one; processing costs more per byte. On a log-log plot of time against size, a purely proportional cost is a straight line of slope 1; a fixed cost bends the line flat at the small end.
- **Contention.** A container's CPU limit is a share of a CPU over each 100 ms period (Phase 6, step 8: CFS throttling). Four jobs on a Pod limited to half a CPU share that half. A job's run time then depends on what else is running, which isn't in the job's request at all.
- **Event time and processing time.** When something happened (the worker started the work) and when the system *learned* of it (the API read the event from its queue) are different moments. A backed-up queue makes the second arbitrarily late. Measure durations with event times.
- **The zero value isn't a value.** Go's zero `time.Time` is midnight, 1 January of the year 1. Store it as a time, and every calculation with it is nonsense. "Unknown" must stay unknown: `NULL` in SQL, omitted in JSON.
- **Readers before writers.** A new message version can only be sent once everything that reads it understands it. Deploy the workers (readers of `RunJob`) before the API (its writer), or the new commands go to old workers that can only dead-letter them.
- **A workload is a model of users.** Real users arrive independently, so the gaps between their requests are random (a **Poisson process**: exponential gaps). Real job sizes have long tails (**log-normal**: most near the median, a few many times larger). Drawing the whole schedule from a seed makes a workload repeatable, so two runs differ only in what the system did.

### Work as a value

A job gets a **kind** (what it does) and a **size** (how much). `sleep` remains, so every client written in Phases 1 to 6 keeps working: no kind means sleep. In `internal/jobs/job.go`:

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
	ErrInvalidDuration    = errors.New("duration must be between 0 and 5s")
	ErrInvalidTransition  = errors.New("invalid state transition")
)

// Description is a value object: a string that is known to be valid,
~~~

to:

~~~go
	ErrInvalidDuration    = errors.New("duration must be between 0 and 5s")
	ErrInvalidWork        = errors.New("invalid work")
	ErrInvalidTransition  = errors.New("invalid state transition")
)

// Kind is what a job does. Until Phase 7 every job slept for a duration
// its creator chose, so how long it would take was never a question. The
// other kinds do real work, and nobody declares how long that takes.
type Kind string

const (
	KindSleep    Kind = "sleep"    // waits for its declared duration
	KindChecksum Kind = "checksum" // SHA-256 of Size bytes
	KindCompress Kind = "compress" // gzip of Size bytes of text
	KindSort     Kind = "sort"     // sorts Size numbers
)

// MaxSize bounds each kind's input, so that one job takes seconds, not
// minutes, on one CPU.
var MaxSize = map[Kind]int64{
	KindChecksum: 256 << 20,
	KindCompress: 64 << 20,
	KindSort:     2 << 20, // 16 MiB of numbers: four at once fit a worker Pod's memory
}

// Work is a value object: what a job does, and how much of it.
type Work struct {
	Kind     Kind
	Size     int64         // bytes, or numbers for sort; 0 for sleep
	Duration time.Duration // sleep only
}

// Sleep is the work of every job before Phase 7.
func Sleep(d time.Duration) Work {
	return Work{Kind: KindSleep, Duration: d}
}

// NewWork checks a request's work. An empty kind is sleep, so clients
// written before kinds existed keep working.
func NewWork(kind string, size int64, duration time.Duration) (Work, error) {
	k := Kind(kind)
	if k == "" {
		k = KindSleep
	}
	if k == KindSleep {
		if size != 0 {
			return Work{}, fmt.Errorf("%w: sleep takes a duration, not a size", ErrInvalidWork)
		}
		if duration < 0 || duration > MaxDuration {
			return Work{}, ErrInvalidDuration
		}
		return Sleep(duration), nil
	}
	limit, ok := MaxSize[k]
	if !ok {
		return Work{}, fmt.Errorf("%w: unknown kind %q", ErrInvalidWork, kind)
	}
	if duration != 0 {
		return Work{}, fmt.Errorf("%w: %s runs as long as it takes; it can't declare a duration", ErrInvalidWork, k)
	}
	if size < 1 || size > limit {
		return Work{}, fmt.Errorf("%w: %s size must be between 1 and %d", ErrInvalidWork, k, limit)
	}
	return Work{Kind: k, Size: size}, nil
}

// Description is a value object: a string that is known to be valid,
~~~

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
	Duration      time.Duration
~~~

to:

~~~go
	Kind          Kind
	Size          int64
	Duration      time.Duration // sleep only
~~~

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
	UpdatedAt     time.Time
}
~~~

to:

~~~go
	UpdatedAt     time.Time
	// StartedAt and FinishedAt come from the worker's clock (Phase 7): when
	// it began the work, and when it stopped. Zero until then.
	StartedAt  time.Time
	FinishedAt time.Time
}
~~~

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
func New(description Description, duration time.Duration, now time.Time) (Job, error) {
	if duration < 0 || duration > MaxDuration {
~~~

to:

~~~go
func New(description Description, work Work, now time.Time) (Job, error) {
	if work.Duration < 0 || work.Duration > MaxDuration {
~~~

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
		Duration:    duration,
~~~

to:

~~~go
		Kind:        work.Kind,
		Size:        work.Size,
		Duration:    work.Duration,
~~~

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
func (j *Job) Start(now time.Time) error {
	return j.transition(StateRunning, now)
~~~

to:

~~~go
// Start, Complete and Fail take two times: now, when the change is
// recorded, and at, when the worker says it happened.
func (j *Job) Start(now, at time.Time) error {
	if err := j.transition(StateRunning, now); err != nil {
		return err
	}
	j.StartedAt = at
	return nil
~~~

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
func (j *Job) Complete(now time.Time) error {
	return j.transition(StateCompleted, now)
~~~

to:

~~~go
func (j *Job) Complete(now, at time.Time) error {
	if err := j.transition(StateCompleted, now); err != nil {
		return err
	}
	j.FinishedAt = at
	return nil
~~~

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
func (j *Job) Fail(reason string, now time.Time) error {
~~~

to:

~~~go
func (j *Job) Fail(reason string, now, at time.Time) error {
~~~

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
	j.FailureReason = reason
	return nil
~~~

to:

~~~go
	j.FailureReason = reason
	j.FinishedAt = at
	return nil
~~~


`NewWork` is a value object's constructor, like `NewDescription`: the only way to get a `Work` that's known to be valid. Real work can't declare a duration (it takes as long as it takes), and each kind has a maximum size, so one job takes seconds, not minutes. `Start`, `Complete` and `Fail` now take two times: `now`, when the change is recorded, and `at`, when the worker says it happened.

Update the tests in `internal/jobs/job_test.go`:

Change:

<!-- edit: internal/jobs/job_test.go -->
~~~go
	job, err := New("resize", time.Second, t0)
~~~

to:

~~~go
	job, err := New("resize", Sleep(time.Second), t0)
~~~

Change:

<!-- edit: internal/jobs/job_test.go -->
~~~go
		if _, err := New("resize", d, t0); !errors.Is(err, ErrInvalidDuration) {
			t.Errorf("New(duration=%v) error = %v, want %v", d, err, ErrInvalidDuration)
		}
	}
}
~~~

to:

~~~go
		if _, err := New("resize", Sleep(d), t0); !errors.Is(err, ErrInvalidDuration) {
			t.Errorf("New(duration=%v) error = %v, want %v", d, err, ErrInvalidDuration)
		}
	}
}

func TestNewWork(t *testing.T) {
	tests := []struct {
		name     string
		kind     string
		size     int64
		duration time.Duration
		want     Work
		wantErr  error
	}{
		{"no kind is sleep", "", 0, time.Second, Sleep(time.Second), nil},
		{"sleep", "sleep", 0, 0, Sleep(0), nil},
		{"sleep with a size", "sleep", 10, 0, Work{}, ErrInvalidWork},
		{"sleep too long", "sleep", 0, MaxDuration + 1, Work{}, ErrInvalidDuration},
		{"checksum", "checksum", 1 << 20, 0, Work{Kind: KindChecksum, Size: 1 << 20}, nil},
		{"compress, the largest", "compress", MaxSize[KindCompress], 0, Work{Kind: KindCompress, Size: MaxSize[KindCompress]}, nil},
		{"sort", "sort", 1000, 0, Work{Kind: KindSort, Size: 1000}, nil},
		{"real work can't declare a duration", "sort", 1000, time.Second, Work{}, ErrInvalidWork},
		{"no size", "checksum", 0, 0, Work{}, ErrInvalidWork},
		{"too large", "sort", MaxSize[KindSort] + 1, 0, Work{}, ErrInvalidWork},
		{"unknown kind", "mine-bitcoin", 10, 0, Work{}, ErrInvalidWork},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NewWork(tt.kind, tt.size, tt.duration)
			if !errors.Is(err, tt.wantErr) || got != tt.want {
				t.Fatalf("NewWork = %+v, %v; want %+v, %v", got, err, tt.want, tt.wantErr)
			}
		})
	}
}
~~~

Change:

<!-- edit: internal/jobs/job_test.go -->
~~~go
func TestLifecycle(t *testing.T) {
	job, _ := New("resize", 0, t0)
	later := t0.Add(time.Minute)
~~~

to:

~~~go
func TestLifecycle(t *testing.T) {
	job, _ := New("resize", Work{Kind: KindSort, Size: 10}, t0)
	started, finished := t0.Add(10*time.Second), t0.Add(50*time.Second)
	later := t0.Add(time.Minute)
~~~

Change:

<!-- edit: internal/jobs/job_test.go -->
~~~go
	if err := job.Start(later); err != nil {
~~~

to:

~~~go
	if err := job.Start(later, started); err != nil {
~~~

Change:

<!-- edit: internal/jobs/job_test.go -->
~~~go
	if err := job.Complete(later); err != nil {
~~~

to:

~~~go
	if err := job.Complete(later, finished); err != nil {
~~~

Change:

<!-- edit: internal/jobs/job_test.go -->
~~~go
	if err := job.Complete(later); !errors.Is(err, ErrInvalidTransition) {
~~~

to:

~~~go
	// Run time is the worker's: 40 s, not however long the reports took
	// to arrive.
	if run := job.FinishedAt.Sub(job.StartedAt); run != 40*time.Second {
		t.Fatalf("run time = %v, want 40s", run)
	}
	if err := job.Complete(later, finished); !errors.Is(err, ErrInvalidTransition) {
~~~

Change:

<!-- edit: internal/jobs/job_test.go -->
~~~go
	job, _ := New("resize", 0, t0)
	_ = job.Start(t0)
	if err := job.Fail("deadline exceeded", t0); err != nil {
~~~

to:

~~~go
	job, _ := New("resize", Sleep(0), t0)
	_ = job.Start(t0, t0)
	if err := job.Fail("deadline exceeded", t0, t0.Add(time.Second)); err != nil {
~~~

Change:

<!-- edit: internal/jobs/job_test.go -->
~~~go
	if job.State != StateFailed || job.FailureReason != "deadline exceeded" {
~~~

to:

~~~go
	if job.State != StateFailed || job.FailureReason != "deadline exceeded" || !job.FinishedAt.Equal(t0.Add(time.Second)) {
~~~

Change:

<!-- edit: internal/jobs/job_test.go -->
~~~go
	job, _ := New(d, time.Second, t0)
~~~

to:

~~~go
	job, _ := New(d, Sleep(time.Second), t0)
~~~


### Recording when it ran

The service takes `Work` instead of a duration, and checks it (whoever built it, an HTTP or a gRPC request). The `Mark` methods take the event's time. In `internal/jobs/service.go`:

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
func (s *Service) Create(ctx context.Context, description string, duration time.Duration) (Job, error) {
~~~

to:

~~~go
func (s *Service) Create(ctx context.Context, description string, work Work) (Job, error) {
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	job, err := New(d, duration, s.now())
~~~

to:

~~~go
	// Checked here, whoever built it: HTTP and gRPC requests alike.
	work, err = NewWork(string(work.Kind), work.Size, work.Duration)
	if err != nil {
		return Job{}, err
	}
	job, err := New(d, work, s.now())
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
		_ = job.Fail("not dispatched: "+dispatchErr.Error(), s.now())
~~~

to:

~~~go
		now := s.now()
		_ = job.Fail("not dispatched: "+dispatchErr.Error(), now, now)
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
func (s *Service) MarkStarted(ctx context.Context, id ID) error {
~~~

to:

~~~go
//
// at is when the worker says it happened (the event's time), which can be
// well before the API hears of it: events wait in a queue. Run times are
// measured with at, so a backed-up queue doesn't make jobs look slow.
func (s *Service) MarkStarted(ctx context.Context, id ID, at time.Time) error {
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
		return job.Start(s.now())
~~~

to:

~~~go
		return job.Start(s.now(), at)
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
func (s *Service) MarkCompleted(ctx context.Context, id ID) error {
~~~

to:

~~~go
func (s *Service) MarkCompleted(ctx context.Context, id ID, at time.Time) error {
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
			if err := job.Start(s.now()); err != nil {
~~~

to:

~~~go
			// The "started" report hasn't arrived (yet): the job's start
			// is unknown, so it stays zero rather than becoming a guess.
			if err := job.Start(s.now(), time.Time{}); err != nil {
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
		return job.Complete(s.now())
~~~

to:

~~~go
		return job.Complete(s.now(), at)
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
func (s *Service) MarkFailed(ctx context.Context, id ID, reason string) error {
~~~

to:

~~~go
func (s *Service) MarkFailed(ctx context.Context, id ID, reason string, at time.Time) error {
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
		return job.Fail(reason, s.now())
~~~

to:

~~~go
		return job.Fail(reason, s.now(), at)
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
		if err := s.MarkFailed(tenant.With(ctx, job.Tenant), job.ID, "abandoned: no worker reported back"); err != nil {
~~~

to:

~~~go
		reason := "abandoned: no worker reported back"
		if err := s.MarkFailed(tenant.With(ctx, job.Tenant), job.ID, reason, s.now()); err != nil {
~~~


Note `MarkCompleted` for a job whose "started" report hasn't arrived: it moves through `running` with an *unknown* start, not a guessed one. A guess would make a run time out of nothing.

In `internal/jobs/service_test.go`:

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	job, err := svc.Create(ctx, "  resize  ", time.Second)
~~~

to:

~~~go
	job, err := svc.Create(ctx, "  resize  ", jobs.Sleep(time.Second))
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	if _, err := svc.Create(ctx, "", 0); !errors.Is(err, jobs.ErrInvalidDescription) {
		t.Fatalf("empty description error = %v", err)
	}
~~~

to:

~~~go
	if _, err := svc.Create(ctx, "", jobs.Sleep(0)); !errors.Is(err, jobs.ErrInvalidDescription) {
		t.Fatalf("empty description error = %v", err)
	}
}

// Run times come from the worker's reports, not from when the API heard
// of them.
func TestTheWorkersTimesAreKept(t *testing.T) {
	svc := jobs.NewService(memstore.New(), jobs.WithClock(fixedClock))
	started, finished := fixedNow.Add(-3*time.Second), fixedNow.Add(-time.Second)

	job, _ := svc.Create(acme, "sort", jobs.Work{Kind: jobs.KindSort, Size: 1000})
	_ = svc.MarkStarted(acme, job.ID, started)
	_ = svc.MarkCompleted(acme, job.ID, finished)
	got, _ := svc.Get(acme, job.ID)
	if !got.StartedAt.Equal(started) || !got.FinishedAt.Equal(finished) || !got.UpdatedAt.Equal(fixedNow) {
		t.Fatalf("started %v, finished %v, updated %v", got.StartedAt, got.FinishedAt, got.UpdatedAt)
	}
	if got.Kind != jobs.KindSort || got.Size != 1000 {
		t.Fatalf("work = %s/%d, want sort/1000", got.Kind, got.Size)
	}

	// A completion that overtakes its "started" leaves the start unknown:
	// zero, not a made-up time that would give a wrong run time.
	early, _ := svc.Create(acme, "sort", jobs.Work{Kind: jobs.KindSort, Size: 1000})
	_ = svc.MarkCompleted(acme, early.ID, finished)
	_ = svc.MarkStarted(acme, early.ID, started)
	got, _ = svc.Get(acme, early.ID)
	if !got.StartedAt.IsZero() || !got.FinishedAt.Equal(finished) {
		t.Fatalf("started %v, finished %v; want zero and %v", got.StartedAt, got.FinishedAt, finished)
	}
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	job, err := svc.Create(ctx, "resize", 0)
~~~

to:

~~~go
	job, err := svc.Create(ctx, "resize", jobs.Sleep(0))
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	svc := jobs.NewService(memstore.New())
	ctx := acme
	job, _ := svc.Create(ctx, "resize", 0)

	steps := []struct {
~~~

to:

~~~go
	svc := jobs.NewService(memstore.New())
	ctx := acme
	job, _ := svc.Create(ctx, "resize", jobs.Sleep(0))

	steps := []struct {
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
		{"started", func() error { return svc.MarkStarted(ctx, job.ID) }, jobs.StateRunning},
		{"started again", func() error { return svc.MarkStarted(ctx, job.ID) }, jobs.StateRunning},
		{"completed", func() error { return svc.MarkCompleted(ctx, job.ID) }, jobs.StateCompleted},
		{"completed again", func() error { return svc.MarkCompleted(ctx, job.ID) }, jobs.StateCompleted},
		{"a late failure", func() error { return svc.MarkFailed(ctx, job.ID, "late") }, jobs.StateCompleted},
~~~

to:

~~~go
		{"started", func() error { return svc.MarkStarted(ctx, job.ID, fixedNow) }, jobs.StateRunning},
		{"started again", func() error { return svc.MarkStarted(ctx, job.ID, fixedNow) }, jobs.StateRunning},
		{"completed", func() error { return svc.MarkCompleted(ctx, job.ID, fixedNow) }, jobs.StateCompleted},
		{"completed again", func() error { return svc.MarkCompleted(ctx, job.ID, fixedNow) }, jobs.StateCompleted},
		{"a late failure", func() error { return svc.MarkFailed(ctx, job.ID, "late", fixedNow) }, jobs.StateCompleted},
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	svc := jobs.NewService(memstore.New())
	ctx := acme
	job, _ := svc.Create(ctx, "resize", 0)

	if err := svc.MarkCompleted(ctx, job.ID); err != nil {
~~~

to:

~~~go
	svc := jobs.NewService(memstore.New())
	ctx := acme
	job, _ := svc.Create(ctx, "resize", jobs.Sleep(0))

	if err := svc.MarkCompleted(ctx, job.ID, fixedNow); err != nil {
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	if err := svc.MarkStarted(ctx, job.ID); err != nil {
~~~

to:

~~~go
	if err := svc.MarkStarted(ctx, job.ID, fixedNow); err != nil {
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	if err := svc.MarkStarted(acme, 99); !errors.Is(err, jobs.ErrNotFound) {
~~~

to:

~~~go
	if err := svc.MarkStarted(acme, 99, fixedNow); !errors.Is(err, jobs.ErrNotFound) {
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	job, _ := svc.Create(ctx, "resize", 0)
	_ = svc.MarkStarted(ctx, job.ID)
~~~

to:

~~~go
	job, _ := svc.Create(ctx, "resize", jobs.Sleep(0))
	_ = svc.MarkStarted(ctx, job.ID, fixedNow)
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
			errs <- svc.MarkCompleted(ctx, job.ID)
~~~

to:

~~~go
			errs <- svc.MarkCompleted(ctx, job.ID, fixedNow)
~~~

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
	stuck, _ := svc.Create(ctx, "stuck", time.Second)
	done, _ := svc.Create(ctx, "done", time.Second)
	_ = svc.MarkStarted(ctx, stuck.ID)
	_ = svc.MarkCompleted(ctx, done.ID)
~~~

to:

~~~go
	stuck, _ := svc.Create(ctx, "stuck", jobs.Sleep(time.Second))
	done, _ := svc.Create(ctx, "done", jobs.Sleep(time.Second))
	_ = svc.MarkStarted(ctx, stuck.ID, fixedNow)
	_ = svc.MarkCompleted(ctx, done.ID, fixedNow)
~~~


### Doing the work

Create `internal/work/work.go`:

<!-- file: internal/work/work.go -->
~~~go
// Package work does what a job asks for (Phase 7). Each kind does real
// work on an input generated from the job's ID, so the same job always
// does the same work, and how long it takes is something to measure, not
// something the client declared.
package work

import (
	"compress/gzip"
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"math/rand/v2"
	"slices"

	"runway/internal/jobs"
)

// chunk is how much input is made and processed at a time. Between chunks
// the work checks its context, so a cancelled or timed-out job stops within
// about a millisecond instead of running to the end.
const chunk = 64 << 10

// Run is a jobs.WorkFunc that does every kind of work.
func Run(ctx context.Context, job jobs.Job) error {
	switch job.Kind {
	case jobs.KindSleep, "":
		return jobs.Simulate(ctx, job)
	case jobs.KindChecksum:
		return checksum(ctx, job)
	case jobs.KindCompress:
		return compress(ctx, job)
	case jobs.KindSort:
		return sortNumbers(ctx, job)
	default:
		return fmt.Errorf("%w: unknown kind %q", jobs.ErrInvalidWork, job.Kind)
	}
}

func checksum(ctx context.Context, job jobs.Job) error {
	return feed(ctx, job, sha256.New())
}

func compress(ctx context.Context, job jobs.Job) error {
	zw := gzip.NewWriter(io.Discard)
	if err := feed(ctx, job, zw); err != nil {
		return err
	}
	return zw.Close()
}

// feed writes job.Size bytes of text to w, a chunk at a time.
func feed(ctx context.Context, job jobs.Job, w io.Writer) error {
	text := newText(job.ID)
	buf := make([]byte, chunk)
	for left := job.Size; left > 0; left -= int64(len(buf)) {
		if err := ctx.Err(); err != nil {
			return err
		}
		if left < int64(len(buf)) {
			buf = buf[:left]
		}
		text.fill(buf)
		if _, err := w.Write(buf); err != nil {
			return err
		}
	}
	return nil
}

func sortNumbers(ctx context.Context, job jobs.Job) error {
	r := rand.New(rand.NewPCG(uint64(job.ID), 0))
	numbers := make([]uint64, job.Size)
	for i := range numbers {
		if i%chunk == 0 {
			if err := ctx.Err(); err != nil {
				return err
			}
		}
		numbers[i] = r.Uint64()
	}
	// One call that can't be interrupted: at the largest size it takes
	// about a quarter of a second on one CPU, which bounds how late a
	// cancelled sort stops.
	slices.Sort(numbers)
	return ctx.Err()
}

// text makes something like prose: words from a fixed vocabulary, common
// ones far more often than rare ones (a Zipf distribution, as in real
// text). Each job gets its own block of it, 256 KiB, and its input cycles
// through the block from a random point. The block is much larger than
// gzip's 32 KiB window, so the repetition doesn't make compressing easy.
//
// Each job's Zipf exponent is different, between 1.05 and 1.5: some jobs'
// text repeats its common words more, and compresses faster and smaller.
// Nothing in the request says which. Real inputs vary like this too, and a
// model that knows only the kind and the size can't see it.
type text struct {
	block []byte
	pos   int
}

const blockSize = 256 << 10

var vocabulary = func() [][]byte {
	r := rand.New(rand.NewPCG(1, 2))
	words := make([][]byte, 5000)
	for i := range words {
		w := make([]byte, 2+r.IntN(9))
		for j := range w {
			w[j] = 'a' + byte(r.IntN(26))
		}
		words[i] = append(w, ' ')
	}
	return words
}()

func newText(id jobs.ID) *text {
	r := rand.New(rand.NewPCG(uint64(id), 1))
	zipf := rand.NewZipf(r, 1.05+0.45*r.Float64(), 1, uint64(len(vocabulary)-1))
	block := make([]byte, 0, blockSize+16)
	for len(block) < blockSize {
		block = append(block, vocabulary[zipf.Uint64()]...)
	}
	return &text{block: block[:blockSize], pos: r.IntN(blockSize)}
}

func (t *text) fill(buf []byte) {
	for n := 0; n < len(buf); {
		c := copy(buf[n:], t.block[t.pos:])
		n += c
		t.pos = (t.pos + c) % len(t.block)
	}
}
~~~

Three kinds, three shapes of cost. `checksum` hashes the input (SHA-256: fast, strictly proportional). `compress` gzips it (much slower, and how slow depends on the text). `sort` sorts that many 64-bit numbers (a bit more than proportional: *n* log *n*). The input is generated from the job's ID, so the same job always does the same work, and the work checks its context between 64 KiB chunks so a job past its deadline stops promptly.

The text needed care. My first version drew each word from the Zipf distribution as it went, and the benchmark showed that making the text cost more than hashing it: `checksum` measured the generator, not SHA-256. Now each job makes one 256 KiB block (the fixed cost) and cycles through it. And each job's text has its own Zipf exponent: across the first twelve job IDs, a megabyte compresses between 3.3 and 5.6 times, and the slowest took nearly twice as long as the fastest. Real inputs vary like this; it's a part of run time that no request field explains.

Create `internal/work/work_test.go`:

<!-- file: internal/work/work_test.go -->
~~~go
package work

import (
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"runway/internal/jobs"
)

func job(id jobs.ID, kind jobs.Kind, size int64) jobs.Job {
	return jobs.Job{ID: id, Kind: kind, Size: size}
}

func TestEveryKindRuns(t *testing.T) {
	for _, kind := range []jobs.Kind{jobs.KindChecksum, jobs.KindCompress, jobs.KindSort} {
		if err := Run(context.Background(), job(1, kind, 100_000)); err != nil {
			t.Errorf("%s: %v", kind, err)
		}
	}
	sleep := jobs.Job{ID: 1, Kind: jobs.KindSleep, Duration: time.Millisecond}
	if err := Run(context.Background(), sleep); err != nil {
		t.Errorf("sleep: %v", err)
	}
}

func TestAnUnknownKindFails(t *testing.T) {
	if err := Run(context.Background(), job(1, "mine-bitcoin", 10)); !errors.Is(err, jobs.ErrInvalidWork) {
		t.Fatalf("err = %v, want ErrInvalidWork", err)
	}
}

// The input is made from the job's ID: the same job always gets the same
// bytes, and its size is exactly what was asked for, however it falls
// across chunks and words.
func TestTextIsExactAndRepeatable(t *testing.T) {
	read := func(id jobs.ID, size int64) []byte {
		var buf bytes.Buffer
		if err := feed(context.Background(), job(id, jobs.KindChecksum, size), &buf); err != nil {
			t.Fatal(err)
		}
		return buf.Bytes()
	}
	for _, size := range []int64{1, 7, chunk - 1, chunk, chunk + 1, 3*chunk + 5} {
		got := read(42, size)
		if int64(len(got)) != size {
			t.Fatalf("size %d: got %d bytes", size, len(got))
		}
		if !bytes.Equal(got, read(42, size)) {
			t.Fatalf("size %d: the same job made different input", size)
		}
	}
	if bytes.Equal(read(1, 1000), read(2, 1000)) {
		t.Fatal("different jobs made the same input")
	}
}

// Like prose, the text compresses well, but not absurdly: 3 to 6 times,
// different for each job. A generator that repeated one word would make
// compress trivial; one that made random bytes, impossible.
func TestTextCompressesLikeText(t *testing.T) {
	ratios := map[string]bool{}
	for id := jobs.ID(1); id <= 10; id++ {
		var raw, packed bytes.Buffer
		if err := feed(context.Background(), job(id, jobs.KindCompress, 1<<20), &raw); err != nil {
			t.Fatal(err)
		}
		zw := gzip.NewWriter(&packed)
		zw.Write(raw.Bytes())
		zw.Close()
		ratio := float64(raw.Len()) / float64(packed.Len())
		if ratio < 3 || ratio > 6 {
			t.Errorf("job %d: compression ratio %.2f, want between 3 and 6", id, ratio)
		}
		ratios[fmt.Sprintf("%.1f", ratio)] = true
	}
	if len(ratios) < 4 {
		t.Errorf("ratios %v: jobs' text should differ", ratios)
	}
}

// A job past its deadline stops promptly, at the next chunk, whatever its
// size: the worker's job timeout depends on it.
func TestCancelledWorkStopsPromptly(t *testing.T) {
	for _, kind := range []jobs.Kind{jobs.KindChecksum, jobs.KindCompress, jobs.KindSort} {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
		start := time.Now()
		err := Run(ctx, job(1, kind, jobs.MaxSize[kind]))
		cancel()
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Errorf("%s: err = %v, want DeadlineExceeded", kind, err)
		}
		// sort can't stop inside slices.Sort, and -race slows everything.
		if took := time.Since(start); took > 3*time.Second {
			t.Errorf("%s: stopped after %v", kind, took)
		}
	}
}

// go test -run '^$' -bench Work ./internal/work
func BenchmarkWork(b *testing.B) {
	for _, kind := range []jobs.Kind{jobs.KindChecksum, jobs.KindCompress, jobs.KindSort} {
		for _, size := range []int64{1 << 16, 1 << 20, 1 << 24} {
			if size > jobs.MaxSize[kind] {
				continue
			}
			b.Run(fmt.Sprintf("kind=%s/size=%d", kind, size), func(b *testing.B) {
				for i := 0; b.Loop(); i++ {
					if err := Run(context.Background(), job(jobs.ID(i), kind, size)); err != nil {
						b.Fatal(err)
					}
				}
			})
		}
	}
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./internal/work/ ./internal/jobs/ && go test -race -count=1 ./internal/work/ ./internal/jobs/ -->

Run the benchmark (`go test -run '^$' -bench Work -benchtime 3x ./internal/work`):

~~~text
BenchmarkWork/kind=checksum/size=65536-16         	       3	   4533775 ns/op
BenchmarkWork/kind=checksum/size=1048576-16       	       3	   4898310 ns/op
BenchmarkWork/kind=checksum/size=16777216-16      	       3	  20068376 ns/op
BenchmarkWork/kind=compress/size=65536-16         	       3	  10632398 ns/op
BenchmarkWork/kind=compress/size=1048576-16       	       3	  61959721 ns/op
BenchmarkWork/kind=compress/size=16777216-16      	       3	1129469339 ns/op
BenchmarkWork/kind=sort/size=65536-16             	       3	   5830271 ns/op
BenchmarkWork/kind=sort/size=1048576-16           	       3	 125447322 ns/op
~~~

`checksum` takes about 4.5 ms whatever the size up to a megabyte (that's the fixed cost of making the block), then hashes about 1 GB/s. `compress` manages about 15 MB/s, so its largest jobs take several seconds. `sort` of a million numbers takes about 125 ms. These are one CPU with nothing else running; on the cluster, under limits and alongside other jobs, every number grows.

### Through the queue

The event handler passes each event's `OccurredAt`, the worker's clock, and the dispatcher puts the work into the command. In `internal/eventing/eventing.go`:

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
		MaxAttempts: messages.DefaultMaxAttempts,
	}, now)
~~~

to:

~~~go
		MaxAttempts: messages.DefaultMaxAttempts,
		Kind:        string(job.Kind),
		Size:        job.Size,
	}, now)
~~~

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
	MarkStarted(ctx context.Context, id jobs.ID) error
	MarkCompleted(ctx context.Context, id jobs.ID) error
	MarkFailed(ctx context.Context, id jobs.ID, reason string) error
~~~

to:

~~~go
	MarkStarted(ctx context.Context, id jobs.ID, at time.Time) error
	MarkCompleted(ctx context.Context, id jobs.ID, at time.Time) error
	MarkFailed(ctx context.Context, id jobs.ID, reason string, at time.Time) error
~~~

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
		return updater.MarkStarted(ctx, jobs.ID(event.JobID))
~~~

to:

~~~go
		return updater.MarkStarted(ctx, jobs.ID(event.JobID), msg.OccurredAt)
~~~

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
		return updater.MarkCompleted(ctx, jobs.ID(event.JobID))
~~~

to:

~~~go
		return updater.MarkCompleted(ctx, jobs.ID(event.JobID), msg.OccurredAt)
~~~

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
		return updater.MarkFailed(ctx, jobs.ID(event.JobID), event.Reason)
~~~

to:

~~~go
		return updater.MarkFailed(ctx, jobs.ID(event.JobID), event.Reason, msg.OccurredAt)
~~~


`RunJob` gets version 3. A version 1 or 2 command (still in a queue during the upgrade) was a sleep. In `internal/messages/messages.go`:

Change:

<!-- edit: internal/messages/messages.go -->
~~~go
// MaxAttempts.
~~~

to:

~~~go
// MaxAttempts; version 3 added Kind and Size (Phase 7).
~~~

Change:

<!-- edit: internal/messages/messages.go -->
~~~go
	MaxAttempts int    `json:"max_attempts"`
}
~~~

to:

~~~go
	MaxAttempts int    `json:"max_attempts"`
	Kind        string `json:"kind"`
	Size        int64  `json:"size"`
}
~~~

Change:

<!-- edit: internal/messages/messages.go -->
~~~go
	TypeRunJob:       2,
~~~

to:

~~~go
	TypeRunJob:       3,
~~~

Change:

<!-- edit: internal/messages/messages.go -->
~~~go
	}
	return cmd, nil
~~~

to:

~~~go
	}
	if cmd.Kind == "" { // versions 1 and 2: every job slept
		cmd.Kind = "sleep"
	}
	return cmd, nil
~~~


In `internal/messages/messages_test.go`:

Change:

<!-- edit: internal/messages/messages_test.go -->
~~~go
	if received.ID == "" || received.ID != msg.ID || received.Version != 2 || !received.OccurredAt.Equal(now) {
~~~

to:

~~~go
	if received.ID == "" || received.ID != msg.ID || received.Version != 3 || !received.OccurredAt.Equal(now) {
~~~

Change:

<!-- edit: internal/messages/messages_test.go -->
~~~go
		t.Fatalf("MaxAttempts = %d, want the default %d", cmd.MaxAttempts, DefaultMaxAttempts)
	}
}

~~~

to:

~~~go
		t.Fatalf("MaxAttempts = %d, want the default %d", cmd.MaxAttempts, DefaultMaxAttempts)
	}
	if cmd.Kind != "sleep" {
		t.Fatalf("Kind = %q, want sleep: every job before version 3 slept", cmd.Kind)
	}
}

~~~

Change:

<!-- edit: internal/messages/messages_test.go -->
~~~go
func TestVersion3IsNotUnderstoodYet(t *testing.T) {
	future := Envelope{Type: TypeRunJob, Version: 3, Payload: json.RawMessage(`{}`)}
~~~

to:

~~~go
func TestVersion3RunJobKeepsItsWork(t *testing.T) {
	msg, _ := New(TypeRunJob, RunJob{JobID: 5, Kind: "sort", Size: 1000}, now)
	cmd, err := DecodeRunJob(msg)
	if err != nil || cmd.Kind != "sort" || cmd.Size != 1000 {
		t.Fatalf("cmd = %+v, err = %v", cmd, err)
	}
}

func TestVersion4IsNotUnderstoodYet(t *testing.T) {
	future := Envelope{Type: TypeRunJob, Version: 4, Payload: json.RawMessage(`{}`)}
~~~


The worker copies the work from the command. In `internal/worker/worker.go`:

Change:

<!-- edit: internal/worker/worker.go -->
~~~go
		Description: jobs.Description(cmd.Description),
		Duration:    time.Duration(cmd.DurationMS) * time.Millisecond,
~~~

to:

~~~go
		Description: jobs.Description(cmd.Description),
		Kind:        jobs.Kind(cmd.Kind),
		Size:        cmd.Size,
		Duration:    time.Duration(cmd.DurationMS) * time.Millisecond,
~~~


`TestUnreadableCommandIsPermanent` used version 3 as "a version from the future"; it's now the present. In `internal/worker/worker_test.go`:

Change:

<!-- edit: internal/worker/worker_test.go -->
~~~go
	bad.Version = 3
~~~

to:

~~~go
	bad.Version = 4 // newer than this worker understands
~~~


And `cmd/worker` runs `work.Run`, which does every kind, sleep included. In `cmd/worker/main.go`:

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	"runway/internal/envconfig"
	"runway/internal/jobs"
~~~

to:

~~~go
	"runway/internal/envconfig"
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	"runway/internal/telemetry"
	"runway/internal/worker"
~~~

to:

~~~go
	"runway/internal/telemetry"
	"runway/internal/work"
	"runway/internal/worker"
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	work := jobs.Simulate
~~~

to:

~~~go
	run := work.Run // every kind of job (Phase 7); sleep is jobs.Simulate, as before
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
		work = worker.Flaky(work, cfg.FailRate, rand.Float64)
~~~

to:

~~~go
		run = worker.Flaky(run, cfg.FailRate, rand.Float64)
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
		metrics.observe(logged(logger, worker.New(events, work, cfg.JobTimeout).Handle)))
~~~

to:

~~~go
		metrics.observe(logged(logger, worker.New(events, run, cfg.JobTimeout).Handle)))
~~~


### Storing it

Create `internal/pgstore/migrations/0013_work.sql`:

<!-- file: internal/pgstore/migrations/0013_work.sql -->
~~~sql
-- +goose Up
-- What a job does, and when the worker ran it (Phase 7). Every job before
-- this was a sleep, so that's the default. A column added with a constant
-- default changes only the catalogue, not every row, so this is instant
-- however many jobs there are.
ALTER TABLE jobs
    ADD COLUMN kind TEXT NOT NULL DEFAULT 'sleep',
    ADD COLUMN size BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN started_at TIMESTAMPTZ,
    ADD COLUMN finished_at TIMESTAMPTZ;

-- The same rules as jobs.NewWork, as far as the shape goes: a sleep has a
-- duration and no size; real work has a size and no duration. The limits
-- on size are policy, and stay in Go. NOT VALID adds the check for new
-- rows at once, without scanning the old ones while holding a lock that
-- blocks writes; VALIDATE then checks the old rows under a lighter lock.
ALTER TABLE jobs ADD CONSTRAINT jobs_work_check CHECK (
    (kind = 'sleep' AND size = 0)
    OR (kind IN ('checksum', 'compress', 'sort') AND size > 0 AND duration_ms = 0)
) NOT VALID;
ALTER TABLE jobs VALIDATE CONSTRAINT jobs_work_check;

-- +goose Down
ALTER TABLE jobs DROP CONSTRAINT jobs_work_check;
ALTER TABLE jobs
    DROP COLUMN finished_at,
    DROP COLUMN started_at,
    DROP COLUMN size,
    DROP COLUMN kind;
~~~

Adding a column with a constant default is instant in PostgreSQL 11 and later: the default lives in the catalogue, and old rows read it from there. Adding a `CHECK` constraint normally scans the whole table under a lock that blocks writes; `NOT VALID` then `VALIDATE` splits that into a quick step that blocks and a slow one that doesn't. On a table of thousands of rows you won't notice; on billions, it's the difference between a migration and an outage.

In `internal/pgstore/pgstore.go`:

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
			INSERT INTO jobs (tenant, description, duration_ms, state, failure_reason, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7)
~~~

to:

~~~go
			INSERT INTO jobs (tenant, description, kind, size, duration_ms, state, failure_reason, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
			owner, job.Description, job.Duration.Milliseconds(), job.State, job.FailureReason, job.CreatedAt, job.UpdatedAt,
~~~

to:

~~~go
			owner, job.Description, job.Kind, job.Size, job.Duration.Milliseconds(), job.State, job.FailureReason, job.CreatedAt, job.UpdatedAt,
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
			SELECT id, tenant, description, duration_ms, state, failure_reason, created_at, updated_at
~~~

to:

~~~go
			SELECT id, tenant, description, kind, size, duration_ms, state, failure_reason,
			       created_at, updated_at, started_at, finished_at
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
			UPDATE jobs SET state = $2, failure_reason = $3, updated_at = $4
~~~

to:

~~~go
			UPDATE jobs SET state = $2, failure_reason = $3, updated_at = $4,
			                started_at = $6, finished_at = $7
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
			job.ID, job.State, job.FailureReason, job.UpdatedAt, expected)
~~~

to:

~~~go
			job.ID, job.State, job.FailureReason, job.UpdatedAt, expected,
			orNull(job.StartedAt), orNull(job.FinishedAt))
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
	err := row.Scan(&job.ID, &job.Tenant, &job.Description, &durationMS, &job.State, &job.FailureReason, &job.CreatedAt, &job.UpdatedAt)
~~~

to:

~~~go
	var started, finished *time.Time
	err := row.Scan(&job.ID, &job.Tenant, &job.Description, &job.Kind, &job.Size, &durationMS, &job.State,
		&job.FailureReason, &job.CreatedAt, &job.UpdatedAt, &started, &finished)
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
	job.CreatedAt, job.UpdatedAt = job.CreatedAt.UTC(), job.UpdatedAt.UTC()
	return job, err
~~~

to:

~~~go
	job.CreatedAt, job.UpdatedAt = job.CreatedAt.UTC(), job.UpdatedAt.UTC()
	if started != nil {
		job.StartedAt = started.UTC()
	}
	if finished != nil {
		job.FinishedAt = finished.UTC()
	}
	return job, err
~~~

Add this at the end of the file:

<!-- append: internal/pgstore/pgstore.go -->
~~~go
// orNull stores Go's zero time ("not yet", "unknown") as NULL. Stored as a
// time, it would be 1 January of the year 1, and every query that
// subtracted it from another time would get a run time of 2,000 years.
func orNull(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}
~~~


The repository contract gains two cases: the work and the worker's times survive a round trip, and an unknown start stays unknown. In `internal/jobs/jobstest/contract.go`:

Change:

<!-- edit: internal/jobs/jobstest/contract.go -->
~~~go
	job, err := jobs.New("resize", 250*time.Millisecond, t0)
~~~

to:

~~~go
	job, err := jobs.New("resize", jobs.Sleep(250*time.Millisecond), t0)
~~~

Change:

<!-- edit: internal/jobs/jobstest/contract.go -->
~~~go

	t.Run("get unknown is ErrNotFound", func(t *testing.T) {
~~~

to:

~~~go

	// Phase 7: what the job does, and when the worker ran it.
	t.Run("work and the worker's times are kept", func(t *testing.T) {
		repo := newRepo(t)
		job, _ := jobs.New("pack", jobs.Work{Kind: jobs.KindCompress, Size: 1 << 20}, t0)
		job, _ = repo.Create(ctx, job)
		started, finished := t0.Add(2*time.Second), t0.Add(5*time.Second)
		_ = job.Start(t0.Add(3*time.Second), started)
		if err := repo.Update(ctx, job, jobs.StateQueued); err != nil {
			t.Fatal(err)
		}
		got, _ := repo.Get(ctx, job.ID)
		if got.Kind != jobs.KindCompress || got.Size != 1<<20 || got.Duration != 0 {
			t.Fatalf("work = %s/%d/%v, want compress/%d/0", got.Kind, got.Size, got.Duration, 1<<20)
		}
		if got.StartedAt.Sub(started).Abs() > time.Microsecond || !got.FinishedAt.IsZero() {
			t.Fatalf("running: started %v, finished %v", got.StartedAt, got.FinishedAt)
		}
		_ = got.Complete(t0.Add(6*time.Second), finished)
		if err := repo.Update(ctx, got, jobs.StateRunning); err != nil {
			t.Fatal(err)
		}
		got, _ = repo.Get(ctx, job.ID)
		if got.FinishedAt.Sub(finished).Abs() > time.Microsecond {
			t.Fatalf("finished %v, want %v", got.FinishedAt, finished)
		}
	})

	t.Run("an unknown start stays unknown", func(t *testing.T) {
		repo := newRepo(t)
		job, _ := repo.Create(ctx, newJob(t))
		_ = job.Start(t0, time.Time{}) // the "started" report never came
		if err := repo.Update(ctx, job, jobs.StateQueued); err != nil {
			t.Fatal(err)
		}
		if got, _ := repo.Get(ctx, job.ID); !got.StartedAt.IsZero() {
			t.Fatalf("started = %v, want zero", got.StartedAt)
		}
	})

	t.Run("get unknown is ErrNotFound", func(t *testing.T) {
~~~

Change:

<!-- edit: internal/jobs/jobstest/contract.go -->
~~~go
		_ = job.Start(t0.Add(time.Second))
~~~

to:

~~~go
		_ = job.Start(t0.Add(time.Second), t0)
~~~

Change:

<!-- edit: internal/jobs/jobstest/contract.go -->
~~~go
		_ = job.Fail("first", t0)
~~~

to:

~~~go
		_ = job.Fail("first", t0, t0)
~~~

Change:

<!-- edit: internal/jobs/jobstest/contract.go -->
~~~go
		_ = job.Start(t0)
~~~

to:

~~~go
		_ = job.Start(t0, t0)
~~~

Change:

<!-- edit: internal/jobs/jobstest/contract.go -->
~~~go
		if err := started.Start(t0); err != nil {
~~~

to:

~~~go
		if err := started.Start(t0, t0); err != nil {
~~~


But "stays unknown" through Go can't tell `NULL` from the year 1: both come back as the zero `time.Time`. So PostgreSQL gets a test of its own that asks SQL. In `internal/pgstore/pgstore_test.go`:

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	store := New(asAPI(t))
	job, _ := jobs.New("resize", time.Second, t0)
	job, err := store.Create(ctx, job)
~~~

to:

~~~go
	store := New(asAPI(t))
	job, _ := jobs.New("resize", jobs.Sleep(time.Second), t0)
	job, err := store.Create(ctx, job)
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	_ = job.Start(t0.Add(time.Second))
~~~

to:

~~~go
	_ = job.Start(t0.Add(time.Second), t0.Add(time.Second))
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	_ = job.Fail("disk full", t0.Add(2*time.Second))
~~~

to:

~~~go
	_ = job.Fail("disk full", t0.Add(2*time.Second), t0.Add(2*time.Second))
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go

// If the event can't be written, the change it describes mustn't be either.
~~~

to:

~~~go

// An unknown time is NULL in the database, not Go's zero time. Read back
// through Go, both look the same (the contract can't tell them apart);
// in SQL, year 1 makes every run time 2,000 years long.
func TestUnknownTimesAreNull(t *testing.T) {
	owner := pgtest.Pool(t, Migrate)
	store := New(pgtest.As(t, owner, "runway_api"))
	job, _ := jobs.New("pack", jobs.Work{Kind: jobs.KindCompress, Size: 100}, t0)
	job, err := store.Create(acme, job)
	if err != nil {
		t.Fatal(err)
	}
	_ = job.Start(t0, time.Time{}) // the "started" report never came
	_ = job.Complete(t0, t0.Add(time.Second))
	if err := store.Update(acme, job, jobs.StateQueued); err != nil {
		t.Fatal(err)
	}
	var runTime *time.Duration
	err = owner.QueryRow(context.Background(),
		`SELECT finished_at - started_at FROM jobs WHERE id = $1`, job.ID).Scan(&runTime)
	if err != nil || runTime != nil {
		t.Fatalf("run time in SQL = %v, %v; want NULL: the start is unknown", runTime, err)
	}
}

// If the event can't be written, the change it describes mustn't be either.
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	store := New(pool)
	job, _ := jobs.New("resize", time.Second, t0)
	job, err := store.Create(ctx, job)
~~~

to:

~~~go
	store := New(pool)
	job, _ := jobs.New("resize", jobs.Sleep(time.Second), t0)
	job, err := store.Create(ctx, job)
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	_ = started.Start(t0.Add(time.Second))
~~~

to:

~~~go
	_ = started.Start(t0.Add(time.Second), t0.Add(time.Second))
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	}))
	job, _ := jobs.New("resize", time.Second, t0)
	if _, err := store.Create(ctx, job); err != nil {
~~~

to:

~~~go
	}))
	job, _ := jobs.New("resize", jobs.Sleep(time.Second), t0)
	if _, err := store.Create(ctx, job); err != nil {
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
		job, _ := jobs.New("resize", time.Second, at)
~~~

to:

~~~go
		job, _ := jobs.New("resize", jobs.Sleep(time.Second), at)
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
			_ = job.Start(at)
~~~

to:

~~~go
			_ = job.Start(at, at)
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
		job, _ := jobs.New("call Alice back", time.Second, at)
~~~

to:

~~~go
		job, _ := jobs.New("call Alice back", jobs.Sleep(time.Second), at)
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
		}
		_ = job.Start(at)
		if finish {
			_ = job.Complete(at)
~~~

to:

~~~go
		}
		_ = job.Start(at, at)
		if finish {
			_ = job.Complete(at, at)
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	job, _ := jobs.New("call Alice back", time.Second, t0)
	job, err := store.Create(acme, job)
	if err != nil {
		t.Fatal(err)
	}
	_ = job.Start(t0)
	_ = job.Complete(t0)
	if err := store.Update(acme, job, jobs.StateQueued); err != nil {
		t.Fatal(err)
	}

	conn, err := pool.Acquire(ctx)
~~~

to:

~~~go
	job, _ := jobs.New("call Alice back", jobs.Sleep(time.Second), t0)
	job, err := store.Create(acme, job)
	if err != nil {
		t.Fatal(err)
	}
	_ = job.Start(t0, t0)
	_ = job.Complete(t0, t0)
	if err := store.Update(acme, job, jobs.StateQueued); err != nil {
		t.Fatal(err)
	}

	conn, err := pool.Acquire(ctx)
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
		job, _ := jobs.New("resize", time.Second, t0)
~~~

to:

~~~go
		job, _ := jobs.New("resize", jobs.Sleep(time.Second), t0)
~~~

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
	job, _ := jobs.New("payroll for acme", time.Second, t0)
	job, err := store.Create(acme, job)
	if err != nil {
		t.Fatal(err)
	}
	_ = job.Start(t0)
	_ = job.Complete(t0)
	if err := store.Update(acme, job, jobs.StateQueued); err != nil {
		t.Fatal(err)
	}

	for _, sql := range []string{
~~~

to:

~~~go
	job, _ := jobs.New("payroll for acme", jobs.Sleep(time.Second), t0)
	job, err := store.Create(acme, job)
	if err != nil {
		t.Fatal(err)
	}
	_ = job.Start(t0, t0)
	_ = job.Complete(t0, t0)
	if err := store.Update(acme, job, jobs.StateQueued); err != nil {
		t.Fatal(err)
	}

	for _, sql := range []string{
~~~


The other tests only change how they call `New`, `Start`, `Complete` and `Fail`. In `internal/pgstore/peerstats_test.go`:

Change:

<!-- edit: internal/pgstore/peerstats_test.go -->
~~~go
			job, _ := jobs.New("resize", time.Second, at)
~~~

to:

~~~go
			job, _ := jobs.New("resize", jobs.Sleep(time.Second), at)
~~~

Change:

<!-- edit: internal/pgstore/peerstats_test.go -->
~~~go
				_ = job.Start(at)
				_ = job.Fail("disk full", at)
~~~

to:

~~~go
				_ = job.Start(at, at)
				_ = job.Fail("disk full", at, at)
~~~


In `internal/memstore/store_test.go`:

Change:

<!-- edit: internal/memstore/store_test.go -->
~~~go
	job, err := jobs.New("resize", 0, time.Now())
~~~

to:

~~~go
	job, err := jobs.New("resize", jobs.Sleep(0), time.Now())
~~~

Change:

<!-- edit: internal/memstore/store_test.go -->
~~~go
	_ = job.Start(time.Now())
~~~

to:

~~~go
	_ = job.Start(time.Now(), time.Time{})
~~~


In `internal/cache/cache_test.go`:

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
	job, _ := jobs.New("resize", time.Second, time.Now().UTC())
~~~

to:

~~~go
	job, _ := jobs.New("resize", jobs.Sleep(time.Second), time.Now().UTC())
~~~

Change:

<!-- edit: internal/cache/cache_test.go -->
~~~go
	_ = job.Start(time.Now().UTC())
~~~

to:

~~~go
	_ = job.Start(time.Now().UTC(), time.Time{})
~~~


In `internal/eventing/eventing_test.go`:

Change:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
	job, _ := jobs.New("resize", 250*time.Millisecond, t0)
~~~

to:

~~~go
	job, _ := jobs.New("resize", jobs.Sleep(250*time.Millisecond), t0)
~~~

Change:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
	_ = job.Start(t0.Add(time.Second))
~~~

to:

~~~go
	_ = job.Start(t0.Add(time.Second), t0.Add(time.Second))
~~~

Change:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
	t0 := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	job, _ := jobs.New("resize", time.Second, t0)
	job.ID = 7
	_ = job.Start(t0)
	_ = job.Fail("disk full", t0.Add(time.Second))
~~~

to:

~~~go
	t0 := time.Date(2026, 10, 5, 12, 0, 0, 0, time.UTC)
	job, _ := jobs.New("resize", jobs.Sleep(time.Second), t0)
	job.ID = 7
	_ = job.Start(t0, t0)
	_ = job.Fail("disk full", t0.Add(time.Second), t0.Add(time.Second))
~~~

Change:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
	t0 := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)
	job, _ := jobs.New("resize", time.Second, t0)
	job.ID, job.Tenant = 7, "acme"
	webhooks := OutboxMessages(Outbox{Webhooks: true})
	_ = job.Start(t0)
	if msgs, _ := webhooks(job); len(msgs) != 0 {
~~~

to:

~~~go
	t0 := time.Date(2026, 10, 9, 12, 0, 0, 0, time.UTC)
	job, _ := jobs.New("resize", jobs.Sleep(time.Second), t0)
	job.ID, job.Tenant = 7, "acme"
	webhooks := OutboxMessages(Outbox{Webhooks: true})
	_ = job.Start(t0, t0)
	if msgs, _ := webhooks(job); len(msgs) != 0 {
~~~

Change:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
	_ = job.Complete(t0.Add(time.Second))
~~~

to:

~~~go
	_ = job.Complete(t0.Add(time.Second), t0.Add(time.Second))
~~~


<!-- run: test -z "$(gofmt -l .)" && P="./internal/jobs/... ./internal/memstore/ ./internal/messages/ ./internal/worker/ ./internal/eventing/ ./internal/pgstore/ ./internal/cache/" && go vet $P && go test -race -count=1 $P -->

**Break it.** In `Update` in `pgstore.go`, pass `job.StartedAt, job.FinishedAt` instead of `orNull(job.StartedAt), orNull(job.FinishedAt)`, and run the PostgreSQL tests. The contract still passes, every case of it. The new test doesn't:

~~~text
--- FAIL: TestUnknownTimesAreNull (0.24s)
    pgstore_test.go:93: run time in SQL = 2385157h16m19.871345152s, <nil>; want NULL: the start is unknown
~~~

PostgreSQL computed `finished_at - started_at` as about 2,025 years. And Go couldn't even hold that: a `time.Duration` tops out at 292 years, so the number wrapped around to 272. Nonsense on nonsense, from one zero value. Put `orNull` back.

### The APIs

Requests take `kind` and `size`; responses give them back, with the worker's times once they're known. In `internal/httpapi/handler.go`:

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	Create(ctx context.Context, description string, duration time.Duration) (jobs.Job, error)
~~~

to:

~~~go
	Create(ctx context.Context, description string, work jobs.Work) (jobs.Job, error)
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	Description string `json:"description"`
	DurationMS  int64  `json:"duration_ms"`
~~~

to:

~~~go
	Description string `json:"description"`
	Kind        string `json:"kind"` // empty is sleep (Phase 7)
	Size        int64  `json:"size"`
	DurationMS  int64  `json:"duration_ms"`
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	ID            jobs.ID   `json:"id"`
	State         string    `json:"state"`
	Description   string    `json:"description"`
	DurationMS    int64     `json:"duration_ms"`
	FailureReason string    `json:"failure_reason,omitempty"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
~~~

to:

~~~go
	ID            jobs.ID    `json:"id"`
	State         string     `json:"state"`
	Description   string     `json:"description"`
	Kind          string     `json:"kind"`
	Size          int64      `json:"size,omitempty"`
	DurationMS    int64      `json:"duration_ms"`
	FailureReason string     `json:"failure_reason,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at"`
	StartedAt     *time.Time `json:"started_at,omitempty"`
	FinishedAt    *time.Time `json:"finished_at,omitempty"`
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
		Description:   string(job.Description),
		DurationMS:    job.Duration.Milliseconds(),
~~~

to:

~~~go
		Description:   string(job.Description),
		Kind:          string(job.Kind),
		Size:          job.Size,
		DurationMS:    job.Duration.Milliseconds(),
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
		UpdatedAt:     job.UpdatedAt,
	}
}

~~~

to:

~~~go
		UpdatedAt:     job.UpdatedAt,
		StartedAt:     timeOrNil(job.StartedAt),
		FinishedAt:    timeOrNil(job.FinishedAt),
	}
}

// timeOrNil leaves out a time that hasn't happened: a zero time.Time would
// be sent as "0001-01-01T00:00:00Z".
func timeOrNil(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	return &t
}

~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	job, err := h.jobs.Create(r.Context(), req.Description, time.Duration(req.DurationMS)*time.Millisecond)
~~~

to:

~~~go
	work := jobs.Work{Kind: jobs.Kind(req.Kind), Size: req.Size, Duration: time.Duration(req.DurationMS) * time.Millisecond}
	job, err := h.jobs.Create(r.Context(), req.Description, work)
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	case errors.Is(err, jobs.ErrInvalidDescription), errors.Is(err, jobs.ErrInvalidDuration):
~~~

to:

~~~go
	case errors.Is(err, jobs.ErrInvalidDescription), errors.Is(err, jobs.ErrInvalidDuration),
		errors.Is(err, jobs.ErrInvalidWork):
~~~


In `internal/httpapi/handler_test.go`:

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
	if job.ID != 1 || job.State != "queued" || job.DurationMS != 50 {
		t.Fatalf("created = %+v", job)
	}
~~~

to:

~~~go
	if job.ID != 1 || job.State != "queued" || job.DurationMS != 50 || job.Kind != "sleep" {
		t.Fatalf("created = %+v", job)
	}
	if job.StartedAt != nil || job.FinishedAt != nil || strings.Contains(created.Body.String(), "started_at") {
		t.Fatalf("a queued job has no start or finish: %s", created.Body)
	}
~~~

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
		t.Fatalf("GET = %d %s", fetched.Code, fetched.Body)
	}
~~~

to:

~~~go
		t.Fatalf("GET = %d %s", fetched.Code, fetched.Body)
	}
}

// Phase 7: real work, with a kind and a size and no declared duration.
func TestCreateWork(t *testing.T) {
	h := newTestHandler()
	created := do(t, h, http.MethodPost, "/jobs", `{"description":"pack","kind":"compress","size":1048576}`)
	if created.Code != http.StatusCreated {
		t.Fatalf("POST status = %d, body %s", created.Code, created.Body)
	}
	if job := decode(t, created); job.Kind != "compress" || job.Size != 1<<20 || job.DurationMS != 0 {
		t.Fatalf("created = %+v", job)
	}
~~~

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
		{"duration too long", "application/json", `{"description":"x","duration_ms":60000}`, http.StatusBadRequest, jobs.ErrInvalidDuration.Error()},
		{"oversized body", "application/json", `{"description":"` + strings.Repeat("a", 2000) + `"}`, http.StatusRequestEntityTooLarge, "request body must not exceed 1024 bytes"},
~~~

to:

~~~go
		{"duration too long", "application/json", `{"description":"x","duration_ms":60000}`, http.StatusBadRequest, jobs.ErrInvalidDuration.Error()},
		{"unknown kind", "application/json", `{"description":"x","kind":"mine","size":1}`, http.StatusBadRequest, `invalid work: unknown kind "mine"`},
		{"real work with a duration", "application/json", `{"description":"x","kind":"sort","size":10,"duration_ms":5}`, http.StatusBadRequest, "invalid work: sort runs as long as it takes; it can't declare a duration"},
		{"too much work", "application/json", `{"description":"x","kind":"sort","size":99999999}`, http.StatusBadRequest, "invalid work: sort size must be between 1 and 2097152"},
		{"oversized body", "application/json", `{"description":"` + strings.Repeat("a", 2000) + `"}`, http.StatusRequestEntityTooLarge, "request body must not exceed 1024 bytes"},
~~~


The same for gRPC. New fields get new numbers (never reuse one), so old clients skip what they don't know. In `proto/runway/jobs/v1/jobs.proto`:

Change:

<!-- edit: proto/runway/jobs/v1/jobs.proto -->
~~~
  int64 duration_ms = 2;
}
~~~

to:

~~~
  int64 duration_ms = 2;
  // Phase 7. An empty kind is "sleep", as every job was before.
  string kind = 3;
  int64 size = 4;
}
~~~

Change:

<!-- edit: proto/runway/jobs/v1/jobs.proto -->
~~~
  int64 updated_at_unix_ms = 7;
}
~~~

to:

~~~
  int64 updated_at_unix_ms = 7;
  // Phase 7. New fields get new numbers: old clients skip what they don't
  // know. A time of 0 means it hasn't happened, or isn't known.
  string kind = 8;
  int64 size = 9;
  int64 started_at_unix_ms = 10;
  int64 finished_at_unix_ms = 11;
}
~~~


Regenerate the Go code, with the generators you installed in Phase 2:

<!-- run: PATH=$PWD/bin:$PATH protoc --go_out=. --go_opt=module=runway --go-grpc_out=. --go-grpc_opt=module=runway proto/runway/jobs/v1/jobs.proto -->
~~~bash
PATH=$PWD/bin:$PATH protoc --go_out=. --go_opt=module=runway \
  --go-grpc_out=. --go-grpc_opt=module=runway proto/runway/jobs/v1/jobs.proto
~~~

In `internal/grpcapi/server.go`:

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
	Create(ctx context.Context, description string, duration time.Duration) (jobs.Job, error)
~~~

to:

~~~go
	Create(ctx context.Context, description string, work jobs.Work) (jobs.Job, error)
~~~

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
	job, err := s.jobs.Create(ctx, req.GetDescription(), time.Duration(req.GetDurationMs())*time.Millisecond)
~~~

to:

~~~go
	work := jobs.Work{
		Kind:     jobs.Kind(req.GetKind()),
		Size:     req.GetSize(),
		Duration: time.Duration(req.GetDurationMs()) * time.Millisecond,
	}
	job, err := s.jobs.Create(ctx, req.GetDescription(), work)
~~~

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
	case errors.Is(err, jobs.ErrInvalidDescription), errors.Is(err, jobs.ErrInvalidDuration):
~~~

to:

~~~go
	case errors.Is(err, jobs.ErrInvalidDescription), errors.Is(err, jobs.ErrInvalidDuration),
		errors.Is(err, jobs.ErrInvalidWork):
~~~

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
		Id:              int64(job.ID),
		State:           states[job.State],
		Description:     string(job.Description),
		DurationMs:      job.Duration.Milliseconds(),
		FailureReason:   job.FailureReason,
		CreatedAtUnixMs: job.CreatedAt.UnixMilli(),
		UpdatedAtUnixMs: job.UpdatedAt.UnixMilli(),
~~~

to:

~~~go
		Id:               int64(job.ID),
		State:            states[job.State],
		Description:      string(job.Description),
		DurationMs:       job.Duration.Milliseconds(),
		FailureReason:    job.FailureReason,
		CreatedAtUnixMs:  job.CreatedAt.UnixMilli(),
		UpdatedAtUnixMs:  job.UpdatedAt.UnixMilli(),
		Kind:             string(job.Kind),
		Size:             job.Size,
		StartedAtUnixMs:  unixMilliOrZero(job.StartedAt),
		FinishedAtUnixMs: unixMilliOrZero(job.FinishedAt),
~~~

Add this at the end of the file:

<!-- append: internal/grpcapi/server.go -->
~~~go
// unixMilliOrZero sends 0 for a time that hasn't happened. The zero
// time.Time is year 1, which as Unix milliseconds is a large negative
// number no client would expect.
func unixMilliOrZero(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixMilli()
}
~~~


In `internal/grpcapi/server_test.go`:

Change:

<!-- edit: internal/grpcapi/server_test.go -->
~~~go
		t.Fatalf("job = %v", got)
	}
}

~~~

to:

~~~go
		t.Fatalf("job = %v", got)
	}
	if got.GetKind() != "sleep" || got.GetStartedAtUnixMs() != 0 {
		t.Fatalf("job = %v, want a sleep that hasn't started", got)
	}

	// Phase 7: real work.
	sorted, err := c.CreateJob(ctx, &jobsv1.CreateJobRequest{Description: "sort", Kind: "sort", Size: 1000})
	if err != nil || sorted.GetKind() != "sort" || sorted.GetSize() != 1000 {
		t.Fatalf("CreateJob sort: %v, %v", sorted, err)
	}
}

~~~

Change:

<!-- edit: internal/grpcapi/server_test.go -->
~~~go
			_, err := c.CreateJob(ctx, &jobsv1.CreateJobRequest{})
			return err
~~~

to:

~~~go
			_, err := c.CreateJob(ctx, &jobsv1.CreateJobRequest{})
			return err
		}, codes.InvalidArgument},
		{"unknown kind", func() error {
			_, err := c.CreateJob(ctx, &jobsv1.CreateJobRequest{Description: "x", Kind: "mine", Size: 1})
			return err
~~~


`jobsctl` gets a `work` command. In `cmd/jobsctl/main.go`:

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
		job, err = client.CreateJob(ctx, &jobsv1.CreateJobRequest{Description: args[1], DurationMs: duration})
	case len(args) == 2 && args[0] == "get":
~~~

to:

~~~go
		job, err = client.CreateJob(ctx, &jobsv1.CreateJobRequest{Description: args[1], DurationMs: duration})
	case len(args) == 4 && args[0] == "work":
		size, parseErr := strconv.ParseInt(args[3], 10, 64)
		if parseErr != nil {
			return fmt.Errorf("SIZE must be a whole number: %w", parseErr)
		}
		job, err = client.CreateJob(ctx, &jobsv1.CreateJobRequest{Description: args[1], Kind: args[2], Size: size})
	case len(args) == 2 && args[0] == "get":
~~~

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
		return errors.New("usage: jobsctl create DESCRIPTION [DURATION_MS] | jobsctl get ID | jobsctl spread N")
~~~

to:

~~~go
		return errors.New("usage: jobsctl create DESCRIPTION [DURATION_MS] | jobsctl work DESCRIPTION KIND SIZE | jobsctl get ID | jobsctl spread N")
~~~

Change:

<!-- edit: cmd/jobsctl/main.go -->
~~~go
	fmt.Printf("job %d: %s %q (%d ms)\n", job.GetId(), job.GetState(), job.GetDescription(), job.GetDurationMs())
	return nil
}

~~~

to:

~~~go
	fmt.Printf("job %d: %s %q (%s)\n", job.GetId(), job.GetState(), job.GetDescription(), describeWork(job))
	return nil
}

// describeWork says what a job does and, once it has finished, how long
// the worker took.
func describeWork(job *jobsv1.Job) string {
	work := fmt.Sprintf("%d ms", job.GetDurationMs())
	if job.GetKind() != "" && job.GetKind() != "sleep" {
		work = fmt.Sprintf("%s %d", job.GetKind(), job.GetSize())
	}
	if start, end := job.GetStartedAtUnixMs(), job.GetFinishedAtUnixMs(); start != 0 && end != 0 {
		work += fmt.Sprintf(", ran %v", time.Duration(end-start)*time.Millisecond)
	}
	return work
}

~~~


The cached copy of a job changed shape, so its key prefix gets a new version (Phase 3's rule): an old copy would read back with no kind and no times for up to an hour. In `cmd/api/main.go`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		Prefix:      "runway:job:v2:", // v2: keys include the tenant (Phase 6)
~~~

to:

~~~go
		Prefix:      "runway:job:v3:", // v3: work and the worker's times (Phase 7); v2: the tenant (Phase 6)
~~~


<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

### A workload

kload sends one kind of request at one rate. A workload needs several tenants, each with its own rate and its own mix of jobs. Create `kload/src/kload/workload.py`:

<!-- file: kload/src/kload/workload.py -->
~~~python
"""A workload: several tenants, each sending its own mix of jobs (Phase 7).

The whole schedule (who sends what, when, and how big) is drawn from the
workload's seed before the first request, so the same file and seed always
send the same jobs at the same moments. Only the system's answers differ.
"""

import asyncio
import json
import math
import time
import tomllib
from collections.abc import Mapping
from dataclasses import asdict, dataclass
from pathlib import Path

import httpx
import numpy as np

# The API's limits (jobs.MaxSize): sizes are drawn, then clipped to these.
MAX_SIZE = {"checksum": 256 << 20, "compress": 64 << 20, "sort": 2 << 20}


@dataclass(frozen=True)
class Planned:
    """One job the workload will submit."""

    at_s: float  # seconds after the start
    tenant: str
    kind: str
    size: int


@dataclass
class Submitted:
    """What happened to one planned job: the API's reply, then the job's fate."""

    at_s: float
    tenant: str
    kind: str
    size: int
    status: int  # the POST's HTTP status, 0 if no response
    id: int = 0
    state: str = ""
    failure_reason: str = ""
    created_at: str = ""
    started_at: str = ""
    finished_at: str = ""


def load_workload(path: Path) -> dict:
    with path.open("rb") as f:
        workload = tomllib.load(f)
    for tenant in workload["tenants"]:
        for work in tenant["work"]:
            if work["kind"] not in MAX_SIZE:
                raise ValueError(f"{tenant['name']}: unknown kind {work['kind']!r}")
    return workload


def plan(workload: Mapping) -> list[Planned]:
    """Every job the workload sends, in order of time.

    Each tenant's jobs arrive as a Poisson process: the gaps between them are
    random (exponential), as when many independent users each act on their
    own. Sizes are log-normal: most jobs are near the median, and a few are
    many times larger, the long tail real workloads have.
    """
    rng = np.random.default_rng(workload["seed"])
    jobs = []
    for tenant in workload["tenants"]:
        weights = np.array([w["weight"] for w in tenant["work"]], dtype=float)
        t = rng.exponential(1 / tenant["rate"])
        while t < workload["duration"]:
            work = tenant["work"][rng.choice(len(weights), p=weights / weights.sum())]
            size = work["median"] * math.exp(rng.normal(0, work["spread"]))
            size = int(min(max(size, 1), MAX_SIZE[work["kind"]]))
            jobs.append(Planned(round(t, 4), tenant["name"], work["kind"], size))
            t += rng.exponential(1 / tenant["rate"])
    return sorted(jobs, key=lambda j: j.at_s)


async def submit(
    client: httpx.AsyncClient, planned: list[Planned], tokens: Mapping[str, str]
) -> list[Submitted]:
    """Send each planned job when it's due, whether or not earlier ones have answered."""
    start = time.perf_counter()

    async def one(job: Planned) -> Submitted:
        delay = start + job.at_s - time.perf_counter()
        if delay > 0:
            await asyncio.sleep(delay)
        row = Submitted(**asdict(job), status=0)
        body = {"description": f"{job.kind} for {job.tenant}", "kind": job.kind, "size": job.size}
        headers = {"Authorization": f"Bearer {tokens[job.tenant]}"}
        try:
            response = await client.post("/jobs", json=body, headers=headers)
        except httpx.HTTPError as exc:
            row.failure_reason = type(exc).__name__
            return row
        row.status = response.status_code
        if response.status_code == 201:
            _update(row, response.json())
        return row

    return list(await asyncio.gather(*(one(job) for job in planned)))


async def collect(
    client: httpx.AsyncClient,
    rows: list[Submitted],
    tokens: Mapping[str, str],
    *,
    timeout_s: float = 300,
    poll_s: float = 2,
) -> None:
    """Poll every accepted job until it has finished, or until timeout_s."""
    deadline = time.perf_counter() + timeout_s
    waiting = [r for r in rows if r.id and r.state not in ("completed", "failed")]
    while waiting and time.perf_counter() < deadline:
        for row in waiting:
            headers = {"Authorization": f"Bearer {tokens[row.tenant]}"}
            response = await client.get(f"/jobs/{row.id}", headers=headers)
            if response.status_code == 200:
                _update(row, response.json())
        waiting = [r for r in waiting if r.state not in ("completed", "failed")]
        if waiting:
            await asyncio.sleep(poll_s)


def _update(row: Submitted, job: dict) -> None:
    row.id = job["id"]
    row.state = job["state"]
    row.failure_reason = job.get("failure_reason", "")
    row.created_at = job["created_at"]
    row.started_at = job.get("started_at", "")
    row.finished_at = job.get("finished_at", "")


def write_rows(rows: list[Submitted], path: Path, settings: Mapping) -> Path:
    """One JSON object per job, and the settings beside them, as kload load does."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(asdict(r)) + "\n" for r in rows))
    settings_path = path.with_suffix(".settings.json")
    settings_path.write_text(json.dumps(dict(settings), indent=2) + "\n")
    return settings_path
~~~

`plan` draws everything first: each tenant's arrival times (exponential gaps), each job's kind (by weight) and size (log-normal, clipped to the API's limits). `submit` sends each job at its time, as `run_open_loop` does, without waiting for earlier ones. `collect` then polls every accepted job until it finishes. The tokens come from environment variables the workload names, so no token is ever written to a file.

Add the command, in `kload/src/kload/cli.py`:

Change:

<!-- edit: kload/src/kload/cli.py -->
~~~python
import json
import sys
from pathlib import Path
~~~

to:

~~~python
import json
import os
import sys
from collections import Counter
from pathlib import Path
~~~

Change:

<!-- edit: kload/src/kload/cli.py -->
~~~python

def cmd_analyze(args: argparse.Namespace) -> int:
~~~

to:

~~~python

def cmd_mix(args: argparse.Namespace) -> int:
    from kload.workload import collect, load_workload, plan, submit, write_rows

    workload = load_workload(Path(args.workload))
    planned = plan(workload)
    # Each tenant's token comes from the environment variable its entry
    # names, so no token is ever written to a file.
    tokens = {t["name"]: os.environ.get(t["token_env"], "") for t in workload["tenants"]}
    missing = [name for name, token in tokens.items() if not token]
    if missing:
        print(f"error: no token for {', '.join(missing)}", file=sys.stderr)
        return 1
    print(f"{len(planned)} jobs over {workload['duration']} s from {len(tokens)} tenants")

    async def go():
        limits = httpx.Limits(max_connections=200, max_keepalive_connections=200)
        async with httpx.AsyncClient(base_url=args.url, timeout=10, limits=limits) as client:
            rows = await submit(client, planned, tokens)
            accepted = sum(r.status == 201 for r in rows)
            print(f"submitted: {accepted} accepted, {len(rows) - accepted} refused")
            await collect(client, rows, tokens, timeout_s=args.collect_timeout)
            return rows

    rows = asyncio.run(go())
    settings = {"workload": workload, "url": args.url, "jobs": len(rows)}
    settings_path = write_rows(rows, Path(args.out), settings)
    states = Counter(r.state or f"http {r.status}" for r in rows)
    print(f"states: {dict(sorted(states.items()))}")
    print(f"wrote {args.out} (settings: {settings_path})")
    return 0


def cmd_analyze(args: argparse.Namespace) -> int:
~~~

Change:

<!-- edit: kload/src/kload/cli.py -->
~~~python

    p = sub.add_parser("analyze", help="report and plot a results file")
~~~

to:

~~~python

    p = sub.add_parser("mix", help="send a workload of several tenants' jobs, then collect them")
    p.add_argument("workload", help="a workload TOML file")
    p.add_argument("--url", default="http://127.0.0.1:8000")
    p.add_argument("--collect-timeout", type=float, default=300, help="seconds to wait for jobs")
    p.add_argument("--out", default="results/jobs.jsonl")
    p.set_defaults(handler=cmd_mix)

    p = sub.add_parser("analyze", help="report and plot a results file")
~~~


NumPy was already installed (pandas needs it), but `workload.py` imports it directly, so say so. In `kload/pyproject.toml`:

Change:

<!-- edit: kload/pyproject.toml -->
~~~toml
    "matplotlib>=3.11.2",
    "pandas>=3.0.6",
~~~

to:

~~~toml
    "matplotlib>=3.11.2",
    "numpy>=2.5.4",
    "pandas>=3.0.6",
~~~


Create `kload/tests/test_workload.py`:

<!-- file: kload/tests/test_workload.py -->
~~~python
import asyncio
import json
from collections import Counter

import httpx
import pytest

from kload.workload import MAX_SIZE, collect, load_workload, plan, submit

WORKLOAD = {
    "duration": 100,
    "seed": 1,
    "tenants": [
        {
            "name": "acme",
            "token_env": "ACME_TOKEN",
            "rate": 5.0,
            "work": [
                {"kind": "checksum", "weight": 3, "median": 1_000_000, "spread": 0.5},
                {"kind": "sort", "weight": 1, "median": 100_000, "spread": 0.5},
            ],
        },
        {
            "name": "globex",
            "token_env": "GLOBEX_TOKEN",
            "rate": 1.0,
            "work": [{"kind": "compress", "weight": 1, "median": 10_000_000, "spread": 3.0}],
        },
    ],
}


def test_plan_is_repeatable_and_in_order():
    jobs = plan(WORKLOAD)
    assert jobs == plan(WORKLOAD)
    assert [j.at_s for j in jobs] == sorted(j.at_s for j in jobs)
    assert 0 < jobs[0].at_s and jobs[-1].at_s < 100


def test_plan_follows_each_tenants_rate_and_mix():
    jobs = plan(WORKLOAD | {"duration": 2000})
    per_tenant = Counter(j.tenant for j in jobs)
    # Poisson arrivals: about rate × duration, give or take a few percent.
    assert per_tenant["acme"] == pytest.approx(10_000, rel=0.05)
    assert per_tenant["globex"] == pytest.approx(2_000, rel=0.1)
    kinds = Counter(j.kind for j in jobs if j.tenant == "acme")
    assert kinds["checksum"] / kinds["sort"] == pytest.approx(3, rel=0.1)


def test_sizes_have_a_long_tail_and_stay_within_the_limits():
    sizes = sorted(j.size for j in plan(WORKLOAD | {"duration": 2000}) if j.kind == "compress")
    median = sizes[len(sizes) // 2]
    assert median == pytest.approx(10_000_000, rel=0.2)
    assert sizes[-1] == MAX_SIZE["compress"], "the largest are clipped to the limit"
    assert sizes[0] >= 1


def test_load_workload_refuses_unknown_kinds(tmp_path):
    path = tmp_path / "w.toml"
    path.write_text(
        'duration = 1\nseed = 1\n[[tenants]]\nname = "a"\ntoken_env = "A"\nrate = 1.0\n'
        '[[tenants.work]]\nkind = "mine"\nweight = 1\nmedian = 1\nspread = 0.1\n'
    )
    with pytest.raises(ValueError, match="unknown kind 'mine'"):
        load_workload(path)


class FakeAPI:
    """Accepts jobs for known tokens; each job finishes on its second read."""

    def __init__(self):
        self.jobs = {}
        self.reads = Counter()

    def __call__(self, request: httpx.Request) -> httpx.Response:
        owner = {"Bearer a-token": "acme", "Bearer g-token": "globex"}.get(
            request.headers.get("Authorization")
        )
        if owner is None:
            return httpx.Response(401, json={"error": "authentication required"})
        if request.method == "POST":
            body = json.loads(request.content)
            job = {"id": len(self.jobs) + 1, "state": "queued", "created_at": "t0"} | body
            self.jobs[job["id"]] = (owner, job)
            return httpx.Response(201, json=job)
        job_id = int(request.url.path.rsplit("/", 1)[1])
        tenant, job = self.jobs[job_id]
        if tenant != owner:
            return httpx.Response(404, json={"error": "job not found"})
        self.reads[job_id] += 1
        if self.reads[job_id] >= 2:
            job |= {"state": "completed", "started_at": "t1", "finished_at": "t2"}
        return httpx.Response(200, json=job)


def test_submit_then_collect():
    api = FakeAPI()
    planned = plan(WORKLOAD | {"duration": 2})
    tokens = {"acme": "a-token", "globex": "g-token"}

    async def go():
        transport = httpx.MockTransport(api)
        async with httpx.AsyncClient(base_url="http://runway.test", transport=transport) as c:
            rows = await submit(c, planned, tokens)
            await collect(c, rows, tokens, poll_s=0)
            return rows

    rows = asyncio.run(go())
    assert len(rows) == len(planned) > 0
    for row, job in zip(rows, planned, strict=True):
        assert (row.tenant, row.kind, row.size, row.status) == (job.tenant, job.kind, job.size, 201)
        assert (row.state, row.started_at, row.finished_at) == ("completed", "t1", "t2")


def test_a_refused_job_is_kept_with_its_status():
    planned = plan(WORKLOAD | {"duration": 2})

    async def go():
        transport = httpx.MockTransport(FakeAPI())
        async with httpx.AsyncClient(base_url="http://runway.test", transport=transport) as c:
            return await submit(c, planned, {"acme": "wrong", "globex": "wrong"})

    rows = asyncio.run(go())
    assert {r.status for r in rows} == {401}
    assert all(r.id == 0 and r.state == "" for r in rows)
~~~

<!-- run: cd kload && uv sync && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

Now a workload. Create `workloads/three-tenants.toml`:

<!-- file: workloads/three-tenants.toml -->
~~~toml
# Three tenants with different habits. Rates are jobs per second, each
# tenant's jobs arriving at random (a Poisson process); sizes are log-normal
# around the median, spread being the standard deviation of log(size).
duration = 180
seed = 1

[[tenants]]
name = "acme"            # many small jobs
token_env = "ACME_TOKEN"
rate = 4.0
[[tenants.work]]
kind = "checksum"
weight = 3
median = 8_000_000
spread = 1.0
[[tenants.work]]
kind = "sort"
weight = 1
median = 200_000
spread = 1.0

[[tenants]]
name = "globex"          # a few big compressions
token_env = "GLOBEX_TOKEN"
rate = 0.5
[[tenants.work]]
kind = "compress"
weight = 1
median = 4_000_000
spread = 1.2

[[tenants]]
name = "initech"         # a bit of everything
token_env = "INITECH_TOKEN"
rate = 2.0
[[tenants.work]]
kind = "checksum"
weight = 1
median = 32_000_000
spread = 0.8
[[tenants.work]]
kind = "compress"
weight = 1
median = 1_000_000
spread = 0.8
[[tenants.work]]
kind = "sort"
weight = 1
median = 500_000
spread = 0.8
~~~

Keep it, and kload's results, out of the image build. In `.dockerignore`:

Change:

<!-- edit: .dockerignore -->
~~~text
experiments
bin
~~~

to:

~~~text
experiments
workloads
results
bin
~~~


### What run time depends on

`lab` gets a command to read `kload mix`'s rows. Create `lab/src/lab/jobs.py`:

<!-- file: lab/src/lab/jobs.py -->
~~~python
"""What a job's run time depends on, from the rows `kload mix` writes."""

import json
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import numpy as np
from matplotlib.figure import Figure


@dataclass(frozen=True)
class Job:
    tenant: str
    kind: str
    size: int
    state: str
    created: float  # seconds since the epoch, from the API
    started: float  # from the worker's clock; nan if unknown
    finished: float

    @property
    def run_s(self) -> float:
        return self.finished - self.started

    @property
    def wait_s(self) -> float:
        return self.started - self.created


def load(path: Path) -> list[Job]:
    """Every job that reached the API, with its times as numbers."""

    def seconds(text: str) -> float:
        return datetime.fromisoformat(text).timestamp() if text else float("nan")

    jobs = []
    for line in path.read_text().splitlines():
        row = json.loads(line)
        if row["id"]:
            jobs.append(
                Job(
                    row["tenant"],
                    row["kind"],
                    row["size"],
                    row["state"],
                    seconds(row["created_at"]),
                    seconds(row["started_at"]),
                    seconds(row["finished_at"]),
                )
            )
    return jobs


def running_at_start(jobs: list[Job]) -> np.ndarray:
    """For each job, how many other jobs were running when it started.

    Counted across all workers: the rows don't say which worker ran a job.
    """
    start = np.array([j.started for j in jobs])
    end = np.array([j.finished for j in jobs])
    busy = (start[None, :] <= start[:, None]) & (end[None, :] > start[:, None])
    return busy.sum(axis=1) - 1  # not counting itself


def size_fit(sizes: np.ndarray, runs: np.ndarray) -> tuple[float, float, np.ndarray]:
    """Fit log(run) = a + b·log(size). Returns b, a and the residuals.

    b is how run time scales: 1 means doubling the size doubles the time;
    below 1, a fixed cost per job matters, which shrinks as jobs grow.
    The residuals are what size doesn't explain.
    """
    x, y = np.log(sizes), np.log(runs)
    b, a = np.polyfit(x, y, 1)
    return float(b), float(a), y - (a + b * x)


def describe(jobs: list[Job]) -> str:
    done = [j for j in jobs if j.state == "completed" and not np.isnan(j.started)]
    running = running_at_start(done)
    lines = [
        f"{len(jobs)} jobs: {len(done)} completed with known times, "
        f"{sum(j.state == 'failed' for j in jobs)} failed",
        "",
        f"{'kind':<10}{'n':>5}{'run p50':>9}{'p99':>8}{'max':>8}{'wait p99':>10}"
        f"{'slope':>7}{'resid sd':>10}{'corr':>7}",
    ]
    for kind in sorted({j.kind for j in done}):
        mine = np.array([j.kind == kind for j in done])
        runs = np.array([j.run_s for j in done])[mine]
        waits = np.array([j.wait_s for j in done])[mine]
        sizes = np.array([j.size for j in done])[mine]
        slope, _, resid = size_fit(sizes, runs)
        corr = np.corrcoef(resid, running[mine])[0, 1]
        lines.append(
            f"{kind:<10}{mine.sum():>5}{np.median(runs):>9.3f}{np.quantile(runs, 0.99):>8.2f}"
            f"{runs.max():>8.2f}{np.quantile(waits, 0.99):>10.2f}{slope:>7.2f}"
            f"{resid.std():>10.2f}{corr:>7.2f}"
        )
    lines += [
        "",
        "run and wait in seconds; slope: of log(run) on log(size); resid sd: what size",
        "leaves unexplained, in log units; corr: of that with jobs running at the start",
    ]
    return "\n".join(lines)


def plot(jobs: list[Job], path: Path) -> Path:
    """Run time against size, and what's left over against how busy the system was."""
    done = [j for j in jobs if j.state == "completed" and not np.isnan(j.started)]
    running = running_at_start(done)
    fig = Figure(figsize=(11, 4))
    by_size, by_busy = fig.subplots(1, 2)
    for kind in sorted({j.kind for j in done}):
        mine = np.array([j.kind == kind for j in done])
        sizes = np.array([j.size for j in done])[mine]
        runs = np.array([j.run_s for j in done])[mine]
        by_size.loglog(sizes, runs, ".", alpha=0.5, label=kind)
        _, _, resid = size_fit(sizes, runs)
        jitter = np.random.default_rng(0).uniform(-0.2, 0.2, len(resid))
        by_busy.plot(running[mine] + jitter, np.exp(resid), ".", alpha=0.5, label=kind)
    by_size.set(xlabel="size (bytes, or numbers to sort)", ylabel="run time (s)")
    by_size.legend()
    by_busy.set(
        xlabel="other jobs running when it started",
        ylabel="run time ÷ what its size predicts",
        yscale="log",
    )
    fig.tight_layout()
    fig.savefig(path, dpi=100)
    return path
~~~

`size_fit` fits a straight line to log(run time) against log(size). Its slope says how run time scales; its residuals are what size doesn't explain. `running_at_start` counts, for each job, how many others were running when it started, across all workers. `describe` asks whether the residuals grow with that count: if they do, contention is part of run time.

Create `lab/tests/test_jobs.py`:

<!-- file: lab/tests/test_jobs.py -->
~~~python
import json

import numpy as np
import pytest

from lab.jobs import Job, describe, load, plot, running_at_start, size_fit


def test_load_reads_kloads_rows(tmp_path):
    path = tmp_path / "jobs.jsonl"
    rows = [
        {"id": 1, "tenant": "acme", "kind": "sort", "size": 10, "state": "completed",
         "created_at": "2026-10-17T00:00:00Z", "started_at": "2026-10-17T00:00:01Z",
         "finished_at": "2026-10-17T00:00:03.5Z"},
        {"id": 0, "tenant": "acme", "kind": "sort", "size": 10, "state": "",
         "created_at": "", "started_at": "", "finished_at": ""},  # refused: never a job
        {"id": 2, "tenant": "acme", "kind": "sort", "size": 10, "state": "completed",
         "created_at": "2026-10-17T00:00:00Z", "started_at": "",
         "finished_at": "2026-10-17T00:00:03Z"},
    ]  # fmt: skip
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))
    jobs = load(path)
    assert len(jobs) == 2
    assert (jobs[0].wait_s, jobs[0].run_s) == (1.0, 2.5)
    assert np.isnan(jobs[1].run_s), "an unknown start is not a start"


def job(start, end, kind="sort", size=10):
    return Job("acme", kind, size, "completed", 0.0, start, end)


def test_running_at_start_counts_the_others():
    jobs = [job(0, 10), job(1, 2), job(3, 4), job(10, 11)]
    # At 0: nobody else. At 1: the first. At 3: the first. At 10: the first
    # has just finished, so nobody.
    assert list(running_at_start(jobs)) == [0, 1, 1, 0]


def test_size_fit_recovers_how_time_scales():
    rng = np.random.default_rng(1)
    sizes = np.exp(rng.uniform(5, 15, 500))
    runs = 2e-6 * sizes**0.9 * np.exp(rng.normal(0, 0.1, 500))
    slope, intercept, resid = size_fit(sizes, runs)
    assert slope == pytest.approx(0.9, abs=0.02)
    assert np.exp(intercept) == pytest.approx(2e-6, rel=0.2)
    assert resid.std() == pytest.approx(0.1, abs=0.02)


def test_describe_and_plot(tmp_path):
    rng = np.random.default_rng(2)
    jobs = []
    for i in range(200):
        size = int(np.exp(rng.uniform(8, 14)))
        start = i * 0.5
        jobs.append(job(start, start + 1e-5 * size, kind=["sort", "checksum"][i % 2], size=size))
    text = describe(jobs + [Job("acme", "sort", 5, "failed", 0.0, 1.0, 2.0)])
    assert "201 jobs: 200 completed with known times, 1 failed" in text
    assert "checksum" in text and "sort" in text
    assert plot(jobs, tmp_path / "jobs.png").stat().st_size > 0
~~~

In `lab/src/lab/cli.py`:

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python
from lab import analyze, experiment, sim
~~~

to:

~~~python
from lab import analyze, experiment, jobs, sim
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python
    print(f"\nplot: {analyze.plot(args.results)}")
    return 0
~~~

to:

~~~python
    print(f"\nplot: {analyze.plot(args.results)}")
    return 0


def cmd_jobs(args: argparse.Namespace) -> int:
    rows = jobs.load(args.file)
    print(jobs.describe(rows))
    if args.plot:
        print(f"\nplot: {jobs.plot(rows, args.plot)}")
    return 0
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

    simulate = sub.add_parser(
~~~

to:

~~~python

    js = sub.add_parser("jobs", help="what jobs' run times depend on, from kload mix rows")
    js.add_argument("file", type=Path, help="a jobs.jsonl written by kload mix")
    js.add_argument("--plot", type=Path, help="write a PNG here")
    js.set_defaults(func=cmd_jobs)

    simulate = sub.add_parser(
~~~


<!-- run: cd lab && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

### Run it: deploy, readers first

Build, load and upgrade as in Phase 6. The `migrate` hook adds the columns before anything else changes. Then restart the workers *first*, so that by the time the API sends version 3 commands, every worker reads them:

~~~bash
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait
kubectl -n runway rollout restart deploy/worker && kubectl -n runway rollout status deploy/worker
kubectl -n runway rollout restart deploy/api deploy/idp deploy/gateway deploy/notifier sts/metad
kubectl -n runway rollout status deploy/api
~~~

The other order would dead-letter jobs. For the seconds between the new API starting and the last old worker stopping, version 3 commands would reach workers that refuse them as unreadable (`TestVersion4IsNotUnderstoodYet` is that refusal), and a refusal is permanent: those jobs would never run.

Get tokens for three tenants (the `idp` restarted, so restart its port-forward first), and create one job of each kind:

~~~bash
kubectl -n runway port-forward svc/idp 8081:8081 >/dev/null 2>&1 &
export ACME_TOKEN=$(token acme-ci) GLOBEX_TOKEN=$(token globex-ci) INITECH_TOKEN=$(token initech-ci)
for body in '{"description":"pack","kind":"compress","size":8000000}' \
            '{"description":"sum","kind":"checksum","size":100000000}' \
            '{"description":"order","kind":"sort","size":2000000}' \
            '{"description":"nap","duration_ms":200}'; do
  curl -s -X POST localhost:8000/jobs -H "Authorization: Bearer $ACME_TOKEN" -H 'Content-Type: application/json' -d "$body"; echo
done
~~~

~~~text
{"id":759,"state":"queued","description":"pack","kind":"compress","size":8000000,"duration_ms":0,"created_at":"2026-10-17T00:02:33.432744Z","updated_at":"2026-10-17T00:02:33.432744Z"}
{"id":760,"state":"queued","description":"sum","kind":"checksum","size":100000000,"duration_ms":0,"created_at":"2026-10-17T00:02:33.537204Z","updated_at":"2026-10-17T00:02:33.537204Z"}
{"id":761,"state":"queued","description":"order","kind":"sort","size":2000000,"duration_ms":0,"created_at":"2026-10-17T00:02:33.610055Z","updated_at":"2026-10-17T00:02:33.610055Z"}
{"id":762,"state":"queued","description":"nap","kind":"sleep","duration_ms":200,"created_at":"2026-10-17T00:02:33.646619Z","updated_at":"2026-10-17T00:02:33.646619Z"}
~~~

A few seconds later (use your own IDs):

~~~bash
for id in 759 760 761 762; do
  curl -s localhost:8000/jobs/$id -H "Authorization: Bearer $ACME_TOKEN" | jq -c '{id,kind,size,state,started_at,finished_at}'
done
~~~

~~~text
{"id":759,"kind":"compress","size":8000000,"state":"completed","started_at":"2026-10-17T00:02:33.535432Z","finished_at":"2026-10-17T00:02:35.662316Z"}
{"id":760,"kind":"checksum","size":100000000,"state":"completed","started_at":"2026-10-17T00:02:33.598153Z","finished_at":"2026-10-17T00:02:34.040724Z"}
{"id":761,"kind":"sort","size":2000000,"state":"completed","started_at":"2026-10-17T00:02:33.73978Z","finished_at":"2026-10-17T00:02:35.131855Z"}
{"id":762,"kind":"sleep","size":null,"state":"completed","started_at":"2026-10-17T00:02:33.725493Z","finished_at":"2026-10-17T00:02:34.125399Z"}
~~~

Compressing 8 MB took 2.1 s, where the benchmark predicts about 0.5 s. And the 200 ms sleep "ran" for 400 ms. What does `started_at` actually measure? It's the time on the worker's "started" event, stamped just before the worker publishes it. The work begins when RabbitMQ has confirmed it. So a run time includes that confirmation. How long is it? Measure, on a quiet system, with jobs whose work you know exactly: twenty 100 ms sleeps, one every 0.3 s:

~~~bash
uv run --project kload python - <<'EOF'
import os, time
from datetime import datetime
import httpx
c = httpx.Client(base_url="http://localhost:8000", timeout=10,
                 headers={"Authorization": f"Bearer {os.environ['ACME_TOKEN']}"})
ids = []
for _ in range(20):
    ids.append(c.post("/jobs", json={"description": "nap", "duration_ms": 100}).json()["id"])
    time.sleep(0.3)
time.sleep(3)
t = datetime.fromisoformat
run = [round((t(j["finished_at"]) - t(j["started_at"])).total_seconds() * 1000)
       for j in (c.get(f"/jobs/{i}").json() for i in ids)]
print("run ms", sorted(run))
EOF
~~~

~~~text
run ms [110, 110, 110, 111, 111, 111, 111, 111, 112, 112, 112, 113, 113, 113, 114, 114, 114, 115, 119, 122]
~~~

Ten to twenty milliseconds of confirmation: small, and steady. So the extra 200 ms wasn't the broker. That sleep shared its worker Pod with the compress and the sort, on half a CPU: even a sleep's timer, and the publish after it, waited their turn for the CPU. So on this cluster, run time includes waiting for a CPU, and that's not a measurement error. It's part of how long the job takes where it runs, and it's what the next run shows at scale.

### Run it: three tenants

Run the workload: about 1,100 jobs over three minutes, then however long they take to finish (tokens last five minutes, so get fresh ones first):

~~~bash
uv run --project kload kload mix workloads/three-tenants.toml --url http://localhost:8000 --out results/s02-old-limits.jsonl
~~~

~~~text
1116 jobs over 180 s from 3 tenants
submitted: 1116 accepted, 0 refused
states: {'completed': 1115, 'failed': 1}
wrote results/s02-old-limits.jsonl (settings: results/s02-old-limits.settings.json)
~~~

One job failed. Look at what the jobs say:

~~~bash
uv run --project lab lab jobs results/s02-old-limits.jsonl --plot results/s02-old-limits.png
~~~

~~~text
1116 jobs: 1115 completed with known times, 1 failed

kind          n  run p50     p99     max  wait p99  slope  resid sd   corr
checksum    594    0.045    0.42    0.87      0.72   0.41      0.77   0.67
compress    210    0.447    8.38    9.79      0.86   0.95      0.63   0.67
sort        311    0.128    1.59    1.76      0.74   0.92      0.69   0.64

run and wait in seconds; slope: of log(run) on log(size); resid sd: what size
leaves unexplained, in log units; corr: of that with jobs running at the start

plot: results/s02-old-limits.png
~~~

The failure was globex's largest compression, 47 MB, and its reason (`jq 'select(.state=="failed")' results/s02-old-limits.jsonl`) was `deadline exceeded`: the worker's 10-second job timeout. Look at compress's maximum, 9.79 s: the jobs that finished were brushing the same deadline. Sizes, timeouts and CPU limits were all chosen in Phase 5 for jobs that slept; real work needs more.

The table answers this step's question, too. `slope` is near 1 for compress and sort (time grows in proportion to size) but 0.41 for checksum, whose jobs are mostly the fixed cost of making the text. And `corr`: what size *doesn't* explain correlates at 0.64 to 0.67 with how many other jobs were running when it started. Contention is as large a part of run time as anything in the request.

### Give the worker room

Give each worker Pod a whole CPU, and a deadline with room for the largest job when four share it. In `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
  replicas: 2
  resources:
    requests: { cpu: 50m, memory: 32Mi }
    limits: { cpu: 500m, memory: 128Mi }
~~~

to:

~~~yaml
  replicas: 2
  # Phase 7: jobs do real work. Half a CPU shared by four consumers made a
  # 47 MB compression take over 10 s and fail at the old deadline. One CPU
  # each Pod, and a deadline that leaves room for the largest job when all
  # four consumers are busy.
  jobTimeout: 30s
  resources:
    requests: { cpu: 250m, memory: 32Mi }
    limits: { cpu: "1", memory: 128Mi }
~~~


In `deploy/helm/runway/templates/worker.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/worker.yaml -->
~~~yaml
            - { name: METRICS_ADDR, value: "0.0.0.0:9100" }
            {{- with include "runway.tracingEnv" (dict "root" $ "service" "worker") | trim }}
~~~

to:

~~~yaml
            - { name: METRICS_ADDR, value: "0.0.0.0:9100" }
            - { name: JOB_TIMEOUT, value: {{ .Values.worker.jobTimeout | quote }} }
            {{- with include "runway.tracingEnv" (dict "root" $ "service" "worker") | trim }}
~~~


<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway | grep -q 'name: JOB_TIMEOUT, value: "30s"' -->

Upgrade (this time the worker's Pod template changed, so it rolls by itself), get fresh tokens, and run the same workload again. Same file, same seed: the same jobs at the same moments.

~~~bash
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait
uv run --project kload kload mix workloads/three-tenants.toml --url http://localhost:8000 --out results/s02-new-limits.jsonl
uv run --project lab lab jobs results/s02-new-limits.jsonl --plot results/s02-new-limits.png
~~~

~~~text
1116 jobs over 180 s from 3 tenants
submitted: 1116 accepted, 0 refused
states: {'completed': 1116}
wrote results/s02-new-limits.jsonl (settings: results/s02-new-limits.settings.json)
~~~

~~~text
1116 jobs: 1116 completed with known times, 0 failed

kind          n  run p50     p99     max  wait p99  slope  resid sd   corr
checksum    594    0.038    0.21    0.33      0.14   0.34      0.40   0.52
compress    211    0.217    4.86    8.17      0.15   0.88      0.45   0.50
sort        311    0.078    0.58    0.80      0.12   0.79      0.36   0.55

run and wait in seconds; slope: of log(run) on log(size); resid sd: what size
leaves unexplained, in log units; corr: of that with jobs running at the start

plot: results/s02-new-limits.png
~~~

Every job finished. Compress's median halved (0.447 to 0.217 s) and its p99 nearly did (8.38 to 4.86 s). What size leaves unexplained halved too (`resid sd` 0.63 to 0.45 for compress, 0.69 to 0.36 for sort): less contention, less noise. But `corr` is still 0.5. Contention got smaller; it didn't go away.

This was a before-and-after comparison, not an interleaved experiment, so step 1's warning applies: anything that changed between the two runs is mixed into the difference. Here the effect is a factor of two, far beyond the 5% this machine's noise can produce. A smaller effect would need the step 1 treatment.

![Left: run time against size, log-log, by kind: checksum flat then rising, compress steepest, sort in between. Right: run time divided by what size predicts, against the number of other jobs running when it started: rising from about 0.8 with none to about 2 with four or more.](images/s02-new-limits.png)

Left: the three shapes. Checksum's curve bends flat below about 10 MB (the fixed cost); compress climbs to several seconds; sort sits between. Right: what each job took, divided by what its size predicts, against how busy the system was when it started. A job that starts alone takes about 0.8 times the prediction; one that starts beside four others, about twice. A model of run time that sees only kind and size will be wrong in exactly this way, and step 5 starts there.

**Explain it:** why can't a `compress` job declare its duration? Why are `started_at` and `finished_at` the worker's times, not the API's? What does `started_at` include besides the work itself, and how did you measure it? Why must workers be upgraded before the API? Why does the contract pass with the year 1 stored, and what catches it? What does a log-log slope of 0.41 tell you about checksum?

**Read.** Dean and Barroso, *The Tail at Scale* (Communications of the ACM, 2013): the sources of run-time variability you've just seen (shared resources, background work, queueing), and why they matter more as systems grow. Then *Designing Data-Intensive Applications*, chapter 4, *Encoding and Evolution*: the rules you followed for `RunJob` version 3 and the new proto fields, in general.

---
## Step 3: A data contract and an event pipeline

**The problem.** Step 2's numbers came from `kload mix`: it polled the API for each job it had sent, and wrote what it saw to a file. That's fine for one experiment, but it only knows about its own jobs, it holds a tenant's token, and it ends when the run ends. A model needs every job, from every tenant, for weeks, in a form a query can scan in seconds. Runway already streams every change of a job's state to Kafka (Phase 3's `JobChanged` events). This step makes those events carry what a model needs, writes down exactly what they promise, and builds the pipeline that turns them into files a query engine can read.

**New ideas.**

- **A data contract.** The events are an API between two teams: the one that writes them and the one that analyses them. Like any API it needs a written definition (here a JSON Schema), a version, and rules for changing it. Readers ignore fields they don't know, so a writer can add an *optional* field freely; removing, renaming or retyping one, or making one required, is a new version. A test on each side keeps the code and the document in step.
- **Columnar files.** A row store (PostgreSQL) keeps each row's fields together: right for "fetch job 42". An analytical query reads a few columns of every row ("the median run time by kind"), and a columnar file (**Parquet**) keeps each column together, compressed, with its minimum and maximum per block, so a query reads only the columns it needs and skips blocks that can't match.
- **Partitioning.** Files go in directories named for a column's value (`date=2026-10-17/hour=09/`), so a query for one hour opens one directory. Partition by **event time** (when it happened), not processing time (when the pipeline saw it), and a late event still lands in its own hour.
- **Write, then commit.** A Kafka consumer records how far it has read by committing an offset. Commit after the data is safely written, and a crash means reading some events again: **at least once**. Commit before, and a crash loses them. Writing each file under a temporary name and renaming it means a reader sees the whole file or nothing.
- **At least once means duplicates.** The outbox relay can send an event twice (Phase 3), and the pipeline can write one twice. Every event has an ID, so whoever reads deduplicates by it. **Exactly once** is at-least-once delivery plus an idempotent reader.
- **Quarantine, don't drop.** An event that breaks the contract is kept, whole, with the reason, for a person to look at. Dropping it silently makes the data wrong in a way nobody can see; stopping the pipeline for it lets one bad event block all the good ones.
- **Reconcile.** Two records of the same facts (the events, and the `jobs` table) should agree. Counting both, and explaining every difference, is how a data pipeline is tested in production.

### The event, version 2

`JobChanged` says that job 42 completed, and nothing else: not what it did, how big it was, or when it started. Every one of those is in the job when the outbox writes the event, so the event can carry them. In `internal/messages/messages.go`:

Change:

<!-- edit: internal/messages/messages.go -->
~~~go
	TypeJobChanged:   1,
~~~

to:

~~~go
	TypeJobChanged:   2,
~~~

Change:

<!-- edit: internal/messages/messages.go -->
~~~go
// changes. The envelope's OccurredAt is when it changed.
type JobChanged struct {
	JobID  int64  `json:"job_id"`
	State  string `json:"state"`
	Reason string `json:"reason,omitempty"`
~~~

to:

~~~go
// changes. The envelope's OccurredAt is when it changed.
//
// Version 2 (Phase 7) adds what the data pipeline needs: the work, and the
// job's times so far. Its shape is a contract with the pipeline, written
// down in contracts/job_changed.v2.schema.json; TestJobChangedKeepsItsContract
// keeps this struct and that file in step. omitzero leaves out a time that
// hasn't happened, as omitempty can't for a struct.
type JobChanged struct {
	JobID      int64     `json:"job_id"`
	State      string    `json:"state"`
	Reason     string    `json:"reason,omitempty"`
	Kind       string    `json:"kind"`
	Size       int64     `json:"size"`
	CreatedAt  time.Time `json:"created_at"`
	StartedAt  time.Time `json:"started_at,omitzero"`
	FinishedAt time.Time `json:"finished_at,omitzero"`
~~~


The times use `omitzero`, which Go 1.24 added: a field is left out when it's the zero value, which `omitempty` can't judge for a struct. A queued job hasn't started, so its event has no `started_at`, rather than one saying the year 1 (step 2's lesson). The description stays out, as it always has: it may hold personal data (Phase 6, step 11), and the pipeline has no use for it.

Why a new version, when Phase 2's rule says readers ignore fields they don't know? Because the pipeline will *require* `kind` and `size`, and a version-1 event doesn't have them: version 2 is the promise that they're there. The cost is Phase 2's lesson again. `Decode` refuses a version newer than it knows, and the notifier reads `JobChanged` (for webhooks), so the notifier must be upgraded before the API. Then fill the new fields, in `internal/eventing/eventing.go`:

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
		changed := messages.JobChanged{JobID: int64(event.JobID), State: string(event.State), Reason: event.Reason}
~~~

to:

~~~go
		changed := messages.JobChanged{
			JobID:      int64(event.JobID),
			State:      string(event.State),
			Reason:     event.Reason,
			Kind:       string(job.Kind),
			Size:       job.Size,
			CreatedAt:  job.CreatedAt,
			StartedAt:  job.StartedAt,
			FinishedAt: job.FinishedAt,
		}
~~~


### The contract, written down

The struct is the contract's Go side. The pipeline is Python, and the struct means nothing to it, so write the contract down in a form both can check. Create `contracts/job_changed.v2.schema.json`:

<!-- file: contracts/job_changed.v2.schema.json -->
~~~json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://runway.example/contracts/job_changed.v2.schema.json",
  "title": "JobChanged, version 2",
  "description": "One change of a job's state, as the API streams it to Kafka's runway.job-events topic, keyed by job ID. The contract between the API, which writes it, and the data pipeline, which reads it. Readers must ignore properties they don't know: writers may add optional properties without a new version, but not remove, rename or retype one, or make one required. Version 2 added kind, size and the job's times, and requires kind, size and created_at: a reader of version 2 may rely on those.",
  "type": "object",
  "required": ["id", "type", "version", "occurred_at", "tenant", "payload"],
  "properties": {
    "id": { "type": "string", "minLength": 1, "description": "Unique per event: a repeat with the same id is a duplicate." },
    "type": { "const": "jobs.job_changed" },
    "version": { "const": 2 },
    "occurred_at": { "type": "string", "format": "date-time", "description": "When the change was recorded: the event's time." },
    "tenant": { "type": "string", "minLength": 1 },
    "trace": { "type": "string" },
    "payload": {
      "type": "object",
      "required": ["job_id", "state", "kind", "size", "created_at"],
      "properties": {
        "job_id": { "type": "integer", "minimum": 1 },
        "state": { "enum": ["queued", "running", "completed", "failed"] },
        "reason": { "type": "string" },
        "kind": { "enum": ["sleep", "checksum", "compress", "sort"] },
        "size": { "type": "integer", "minimum": 0 },
        "created_at": { "type": "string", "format": "date-time" },
        "started_at": { "type": "string", "format": "date-time", "description": "When the worker began; absent until then, or if unknown." },
        "finished_at": { "type": "string", "format": "date-time", "description": "When the worker stopped; absent until then." }
      }
    }
  }
}
~~~

It's a **JSON Schema**: which properties exist, which are required, their types, the values `state` and `kind` may take. It sits at the top of the practice, not inside `lab/` or `internal/`, because it belongs to neither side. And it says how it may change, which is the part people forget.

Now a test that ties the Go side to it. It builds one known event, through the same `OutboxMessages` the API uses, and compares it byte for byte with an example file. In `internal/eventing/eventing_test.go`:

Change:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
import (
	"testing"
~~~

to:

~~~go
import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"testing"
~~~

Change:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
	if event != (messages.JobChanged{JobID: 7, State: "failed", Reason: "disk full"}) || !msg.Envelope.OccurredAt.Equal(t0.Add(time.Second)) {
		t.Fatalf("event %+v at %v", event, msg.Envelope.OccurredAt)
	}
~~~

to:

~~~go
	want := messages.JobChanged{
		JobID: 7, State: "failed", Reason: "disk full", Kind: "sleep",
		CreatedAt: t0, StartedAt: t0, FinishedAt: t0.Add(time.Second),
	}
	if event != want || !msg.Envelope.OccurredAt.Equal(t0.Add(time.Second)) {
		t.Fatalf("event %+v at %v", event, msg.Envelope.OccurredAt)
	}
}

var update = flag.Bool("update", false, "rewrite the contract's example from the code")

// The example in contracts/ is what the pipeline's tests read. This test
// fails if the event the code sends stops matching it, so a change to
// JobChanged can't reach the pipeline unnoticed. After a deliberate,
// compatible change (a new property), rewrite the example:
//
//	go test ./internal/eventing -run Contract -update
//
// and then the pipeline's own contract test checks it against the schema.
func TestJobChangedKeepsItsContract(t *testing.T) {
	t0 := time.Date(2026, 10, 17, 9, 30, 0, 123456000, time.UTC)
	job, _ := jobs.New("pack", jobs.Work{Kind: jobs.KindCompress, Size: 8_000_000}, t0)
	job.ID, job.Tenant = 42, "acme"
	_ = job.Start(t0.Add(2*time.Second), t0.Add(1500*time.Millisecond))
	_ = job.Complete(t0.Add(5*time.Second), t0.Add(4200*time.Millisecond))

	msgs, err := OutboxMessages(Outbox{StreamEvents: true})(job)
	if err != nil || len(msgs) != 1 {
		t.Fatalf("got %d messages, %v", len(msgs), err)
	}
	env := msgs[0].Envelope
	env.ID = "EXAMPLE5EVENT5ID" // random in real events
	got, _ := json.MarshalIndent(env, "", "  ")
	got = append(got, '\n')

	path := "../../contracts/examples/job_changed.v2.json"
	if *update {
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("the event no longer matches %s:\n%s", path, got)
	}
~~~


The first run writes the example, with `-update`:

~~~bash
mkdir -p contracts/examples
go test ./internal/eventing -run Contract -update
~~~

<!-- run: mkdir -p contracts/examples && go test ./internal/eventing -run Contract -update -->

Look at what it wrote, `contracts/examples/job_changed.v2.json`:

~~~json
{
  "id": "EXAMPLE5EVENT5ID",
  "type": "jobs.job_changed",
  "version": 2,
  "occurred_at": "2026-10-17T09:30:05.123456Z",
  "payload": {
    "job_id": 42,
    "state": "completed",
    "kind": "compress",
    "size": 8000000,
    "created_at": "2026-10-17T09:30:00.123456Z",
    "started_at": "2026-10-17T09:30:01.623456Z",
    "finished_at": "2026-10-17T09:30:04.323456Z"
  },
  "tenant": "acme"
}
~~~

From now on the test runs without `-update`, and fails if the code's event changes. Run the packages that build or read the event:

<!-- run: test -z "$(gofmt -l .)" && P="./internal/messages/ ./internal/eventing/ ./internal/notifier/ ./internal/audit/ ./internal/projection/ ./cmd/notifier/" && go vet $P && go test -race -count=1 $P -->

The Python side checks the same example against the schema: that's the next section. Together they make the chain: the Go code produces the example, the example must keep the schema, the pipeline checks every real event against the same schema.

### Checking events in Python

The pipeline needs Kafka, Parquet, DuckDB and JSON Schema. In `lab/pyproject.toml`:

Change:

<!-- edit: lab/pyproject.toml -->
~~~toml
dependencies = [
    "matplotlib>=3.11.2",
    "numpy>=2.5.4",
]
~~~

to:

~~~toml
dependencies = [
    "confluent-kafka>=2.16.0",
    "duckdb>=1.5.6",
    "jsonschema>=4.26.0",
    "matplotlib>=3.11.2",
    "numpy>=2.5.4",
    "pyarrow>=26.0.0",
    "pytz>=2026.5",
    "rfc3339-validator>=0.1.4",
]
~~~


`rfc3339-validator` is easy to miss, and `pytz` easier: the first is what makes `"format": "date-time"` checked at all, and DuckDB needs the second to hand a time with a time zone to Python. Create `lab/src/lab/contract.py`:

<!-- file: lab/src/lab/contract.py -->
~~~python
"""Checking events against their contract, contracts/job_changed.v2.schema.json."""

import json
from pathlib import Path

from jsonschema import Draft202012Validator


class Contract:
    def __init__(self, schema_path: Path):
        schema = json.loads(schema_path.read_text())
        Draft202012Validator.check_schema(schema)
        # "format": "date-time" is only a note unless a format checker is
        # given, and the checker for date-time needs the rfc3339-validator
        # package installed. Without either, any string passes.
        self.validator = Draft202012Validator(
            schema, format_checker=Draft202012Validator.FORMAT_CHECKER
        )

    def check(self, raw: bytes) -> tuple[dict | None, str | None]:
        """The event if it keeps the contract; otherwise None and the reason why not."""
        try:
            event = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            return None, f"not JSON: {exc}"
        # An event of another version gets that as its reason, not a list
        # of the fields it lacks: it may be fine, just not this contract's.
        if not isinstance(event, dict) or event.get("version") != 2:
            version = event.get("version") if isinstance(event, dict) else None
            return None, f"version {version}: this contract is version 2"
        errors = sorted(self.validator.iter_errors(event), key=lambda e: list(e.path))
        if errors:
            first = errors[0]
            where = "/".join(str(p) for p in first.path) or "(top)"
            return None, f"{where}: {first.message}"
        return event, None
~~~

`check` never raises. It returns the event, or a reason it can't be accepted, because the pipeline will keep the bad ones (quarantine) instead of stopping. Create `lab/tests/test_contract.py`:

<!-- file: lab/tests/test_contract.py -->
~~~python
import copy
import json
from pathlib import Path

import pytest

from lab.contract import Contract

# Both files belong to the practice, one level above lab/. The example is
# written by Go's TestJobChangedKeepsItsContract: this is where the two
# languages meet.
CONTRACTS = Path(__file__).parents[2] / "contracts"
EXAMPLE = json.loads((CONTRACTS / "examples" / "job_changed.v2.json").read_text())


@pytest.fixture(scope="module")
def contract():
    return Contract(CONTRACTS / "job_changed.v2.schema.json")


def raw(event) -> bytes:
    return json.dumps(event).encode()


def test_the_go_example_keeps_the_contract(contract):
    event, why = contract.check(raw(EXAMPLE))
    assert why is None
    assert event["payload"]["kind"] == "compress"


def test_readers_ignore_properties_they_dont_know(contract):
    newer = copy.deepcopy(EXAMPLE)
    newer["payload"]["priority"] = 5
    assert contract.check(raw(newer))[1] is None


def change(path: str, value):
    event = copy.deepcopy(EXAMPLE)
    *parents, last = path.split(".")
    target = event
    for key in parents:
        target = target[key]
    if value is None:
        target.pop(last, None)
    else:
        target[last] = value
    return raw(event)


@pytest.mark.parametrize(
    ("bad", "reason"),
    [
        (b"{not json", "not JSON"),
        (change("version", 1), "version 1: this contract is version 2"),
        (change("tenant", None), "(top): 'tenant' is a required property"),
        (change("payload.size", None), "payload: 'size' is a required property"),
        (change("payload.size", "8MB"), "payload/size: '8MB' is not of type 'integer'"),
        (change("payload.kind", "mine"), "payload/kind: 'mine' is not one of"),
        (change("payload.state", "done"), "payload/state: 'done' is not one of"),
        (change("payload.created_at", "yesterday"), "payload/created_at: 'yesterday' is not a"),
    ],
    ids=["json", "version", "tenant", "size", "size type", "kind", "state", "date"],
)
def test_events_that_break_it_are_refused_with_a_reason(contract, bad, reason):
    event, why = contract.check(bad)
    assert event is None
    assert why.startswith(reason), why
~~~

<!-- run: cd lab && uv sync && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_contract.py -->

The second test is the rule that lets the writer add an optional field: a reader that refused unknown properties (`"additionalProperties": false`) would turn every addition into an outage.

**Break it.** Rename the JSON field, as a tidy-minded Go developer might: in `messages.go`, give `JobChanged.Size` the tag `json:"bytes"`. Run the Go test:

~~~bash
go test ./internal/eventing -run Contract
~~~

~~~text
--- FAIL: TestJobChangedKeepsItsContract (0.00s)
    eventing_test.go:103: the event no longer matches ../../contracts/examples/job_changed.v2.json:
        {
          "id": "EXAMPLE5EVENT5ID",
          "type": "jobs.job_changed",
          "version": 2,
          "occurred_at": "2026-10-17T09:30:05.123456Z",
          "payload": {
            "job_id": 42,
            "state": "completed",
            "kind": "compress",
            "bytes": 8000000,
            "created_at": "2026-10-17T09:30:00.123456Z",
            "started_at": "2026-10-17T09:30:01.623456Z",
            "finished_at": "2026-10-17T09:30:04.323456Z"
          },
          "tenant": "acme"
        }
FAIL
FAIL	runway/internal/eventing	0.008s
FAIL
~~~

It prints the new event, with `"bytes"`. Now suppose they decide the example is just out of date and run it with `-update`. The Go side passes; run the Python side:

~~~bash
cd lab && uv run pytest -q tests/test_contract.py; cd ..
~~~

~~~text
FAILED tests/test_contract.py::test_the_go_example_keeps_the_contract - asser...
FAILED tests/test_contract.py::test_readers_ignore_properties_they_dont_know
FAILED tests/test_contract.py::test_events_that_break_it_are_refused_with_a_reason[kind]
FAILED tests/test_contract.py::test_events_that_break_it_are_refused_with_a_reason[state]
FAILED tests/test_contract.py::test_events_that_break_it_are_refused_with_a_reason[date]
5 failed, 5 passed in 0.25s
~~~

`payload: 'size' is a required property`. Updating the example can't sneak a breaking change past the schema: changing the schema itself is a decision someone has to make, in a file both teams own. Put the tag back and run `-update` again.

**Break it.** In `contract.py`, build the validator without `format_checker`. One test fails:

~~~text
E       AssertionError: assert {'id': 'EXAMPLE5EVENT5ID', 'type': 'jobs.job_changed', 'version': 2, 'occurred_at': '2026-10-17T09:30:05.123456Z', ...} is None
FAILED tests/test_contract.py::test_events_that_break_it_are_refused_with_a_reason[date]
1 failed, 9 passed in 0.13s
~~~

`"yesterday"` passed as a date-time. In JSON Schema, `format` is an annotation unless a checker is asked for. Uninstall `rfc3339-validator` (`uv remove rfc3339-validator`) with the checker in place, and the same test fails the same way: the checker quietly skips formats it has no library for. Put both back.

### Kafka to Parquet

Create `lab/src/lab/pipeline.py`:

<!-- file: lab/src/lab/pipeline.py -->
~~~python
"""From Runway's job-events topic to Parquet files: every event at least once.

The rule that makes it safe: write first, then commit. A batch's events are
written to files, the files are complete on disk, and only then is Kafka
told how far this consumer has read. A crash between the two means the
batch is read again on restart, and written again. Nothing is lost; the
cost is that an event can be in two files. A batch's file name comes from
its offsets, so a batch read again the same replaces its first file; but if
more events arrived meanwhile, the second batch is longer, has another
name, and both files stay. So readers dedupe by event ID, as the warehouse
views do: the topic itself can hold duplicates anyway (see warehouse.py).
"""

import json
import os
import time
from collections import Counter
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Protocol

import pyarrow as pa
import pyarrow.parquet as pq

from lab.contract import Contract

UTC_US = pa.timestamp("us", tz="UTC")

# One row per event. Times are microseconds, as PostgreSQL keeps them.
# kafka_time is when the outbox relay sent the event: minus occurred_at, how late.
SCHEMA = pa.schema(
    [
        ("event_id", pa.string()),
        ("occurred_at", UTC_US),
        ("tenant", pa.string()),
        ("job_id", pa.int64()),
        ("state", pa.string()),
        ("reason", pa.string()),
        ("kind", pa.string()),
        ("size", pa.int64()),
        ("created_at", UTC_US),
        ("started_at", UTC_US),
        ("finished_at", UTC_US),
        ("kafka_partition", pa.int32()),
        ("kafka_offset", pa.int64()),
        ("kafka_time", UTC_US),
    ]
)


@dataclass(frozen=True)
class Record:
    """One message as read from Kafka."""

    partition: int
    offset: int
    value: bytes
    timestamp: datetime | None = None  # when the producer sent it


class Source(Protocol):
    def poll(self, timeout: float) -> Record | None: ...

    def commit(self, offsets: dict[int, int]) -> None:
        """Record that every message before offsets[partition] has been handled."""


def to_row(event: dict, record: Record) -> dict:
    payload = event["payload"]

    def ts(text: str | None) -> datetime | None:
        return datetime.fromisoformat(text) if text else None

    return {
        "event_id": event["id"],
        "occurred_at": ts(event["occurred_at"]),
        "tenant": event["tenant"],
        "job_id": payload["job_id"],
        "state": payload["state"],
        "reason": payload.get("reason", ""),
        "kind": payload["kind"],
        "size": payload["size"],
        "created_at": ts(payload["created_at"]),
        "started_at": ts(payload.get("started_at")),
        "finished_at": ts(payload.get("finished_at")),
        "kafka_partition": record.partition,
        "kafka_offset": record.offset,
        "kafka_time": record.timestamp,
    }


class Sink:
    """Parquet files under root/events/date=.../hour=.../, by the time each event happened.

    Partitioning by event time, not by when the pipeline read the event,
    puts a late event (one that arrives an hour after it happened) in the
    hour it belongs to. Whatever reads an hour must allow that the hour can
    still gain files.
    """

    def __init__(self, root: Path):
        self.root = root

    def write(self, rows: list[dict], partition: int, first: int, last: int) -> list[Path]:
        by_hour: dict[tuple[str, str], list[dict]] = {}
        for row in rows:
            at = row["occurred_at"]
            by_hour.setdefault((at.strftime("%Y-%m-%d"), at.strftime("%H")), []).append(row)
        name = f"p{partition}-{first:012d}-{last:012d}.parquet"
        paths = []
        for (date, hour), group in sorted(by_hour.items()):
            path = self.root / "events" / f"date={date}" / f"hour={hour}" / name
            _atomic(path, lambda tmp, g=group: pq.write_table(pa.Table.from_pylist(g, SCHEMA), tmp))
            paths.append(path)
        return paths

    def quarantine(self, bad: list[tuple[Record, str]], partition: int, first: int, last: int):
        """Events that broke the contract, kept whole with the reason, for a person to look at."""
        path = self.root / "quarantine" / f"p{partition}-{first:012d}-{last:012d}.jsonl"
        lines = [
            json.dumps({"offset": r.offset, "reason": why, "raw": r.value.decode(errors="replace")})
            for r, why in bad
        ]
        _atomic(path, lambda tmp: tmp.write_text("\n".join(lines) + "\n"))
        return path


def _atomic(path: Path, write) -> None:
    """Write to a temporary name, then rename: a reader sees the whole file or none of it."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    write(tmp)
    os.replace(tmp, path)


def run(
    source: Source,
    sink: Sink,
    contract: Contract,
    *,
    batch_size: int = 500,
    max_age: float = 10.0,
    idle_polls: int = 5,
    follow: bool = False,
    clock: Callable[[], float] = time.monotonic,
) -> Counter:
    """Read until the topic has been quiet for idle_polls polls (or forever, with follow).

    A partition's batch is written when it holds batch_size events, or when
    its oldest event has waited max_age seconds, whichever comes first. Size
    alone isn't enough: under steady traffic too light to fill a batch, the
    topic is never quiet, and nothing would ever be written.
    """
    pending: dict[int, list[Record]] = {}
    since: dict[int, float] = {}  # when each partition's batch began
    stats: Counter = Counter()
    idle = 0
    while True:
        record = source.poll(1.0)
        if record is None:
            idle += 1
            if idle >= idle_polls:
                _flush(pending, source, sink, contract, stats)
                if not follow:
                    return stats
                idle = 0
        else:
            idle = 0
            if record.partition not in pending:
                since[record.partition] = clock()
            pending.setdefault(record.partition, []).append(record)
        now = clock()
        due = [
            p
            for p, batch in pending.items()
            if len(batch) >= batch_size or now - since[p] >= max_age
        ]
        if due:
            _flush({p: pending.pop(p) for p in due}, source, sink, contract, stats)


def _flush(
    pending: dict[int, list[Record]], source: Source, sink: Sink, contract: Contract, stats: Counter
) -> None:
    for partition, records in sorted(pending.items()):
        if not records:
            continue
        first, last = records[0].offset, records[-1].offset
        rows, bad = [], []
        for record in records:
            event, why = contract.check(record.value)
            if event is None:
                bad.append((record, why))
            else:
                rows.append(to_row(event, record))
        if rows:
            stats["files"] += len(sink.write(rows, partition, first, last))
        if bad:
            sink.quarantine(bad, partition, first, last)
        stats["events"] += len(rows)
        stats["quarantined"] += len(bad)
        # Only now, with the files complete, move the committed offset on.
        source.commit({partition: last + 1})
    pending.clear()


class KafkaSource:
    """A Source reading a topic as a consumer group, with Kafka's own commits off."""

    def __init__(self, brokers: str, topic: str, group: str):
        from confluent_kafka import Consumer  # imported here: the tests don't need Kafka

        self.topic = topic
        self.consumer = Consumer(
            {
                "bootstrap.servers": brokers,
                "group.id": group,
                "enable.auto.commit": False,  # we commit, after writing
                "auto.offset.reset": "earliest",  # a new group starts at the beginning
            }
        )
        self.consumer.subscribe([topic])

    def poll(self, timeout: float) -> Record | None:
        msg = self.consumer.poll(timeout)
        if msg is None:
            return None
        if msg.error():
            raise RuntimeError(f"Kafka: {msg.error()}")
        _, ms = msg.timestamp()  # set by the producer when it sent the message
        return Record(
            msg.partition(), msg.offset(), msg.value(), datetime.fromtimestamp(ms / 1000, UTC)
        )

    def commit(self, offsets: dict[int, int]) -> None:
        from confluent_kafka import TopicPartition

        parts = [TopicPartition(self.topic, p, o) for p, o in offsets.items()]
        self.consumer.commit(offsets=parts, asynchronous=False)

    def close(self) -> None:
        self.consumer.close()


def read_all(paths: Iterable[Path]) -> pa.Table:
    """Every row in the given Parquet files, for tests and quick looks."""
    return pa.concat_tables([pq.read_table(p) for p in paths])
~~~

Read it in this order:

- `run` collects records per Kafka partition. A partition's batch is written when it reaches `batch_size`, when its oldest record has waited `max_age` seconds, or when the topic goes quiet. Each of the three exists for a reason: size bounds memory, age bounds how stale the files are under light traffic, and quiet ends a one-off run.
- `_flush` checks each record against the contract, writes the good ones and quarantines the bad, and **only then** commits. That one ordering is the whole guarantee.
- `Sink.write` groups rows by the hour they *happened* and writes one file per hour per batch, named for the batch's partition and offsets. `_atomic` writes to `NAME.tmp` and renames it: on Linux a rename within a directory is atomic, so a reader sees no file or the whole file, never half.
- `KafkaSource` is the only part that knows Kafka. Auto-commit is off: left on, the client commits on a timer, whatever has or hasn't been written.

The tests drive `run` with a fake Kafka: one partition, offsets, commits, and a restart that starts from the last commit, which is all the pipeline relies on. Create `lab/tests/test_pipeline.py`:

<!-- file: lab/tests/test_pipeline.py -->
~~~python
import copy
import json
from collections import Counter
from datetime import UTC, datetime
from pathlib import Path

import pyarrow.parquet as pq
import pytest

from lab import warehouse
from lab.contract import Contract
from lab.pipeline import Record, Sink, run

CONTRACTS = Path(__file__).parents[2] / "contracts"
EXAMPLE = json.loads((CONTRACTS / "examples" / "job_changed.v2.json").read_text())
SENT = datetime(2026, 10, 17, 10, 0, 10, tzinfo=UTC)  # when each fake event reached Kafka


@pytest.fixture(scope="module")
def contract():
    return Contract(CONTRACTS / "job_changed.v2.schema.json")


def event(event_id, job_id, state, at, **payload) -> bytes:
    e = copy.deepcopy(EXAMPLE)
    e["id"], e["occurred_at"] = event_id, at
    e["payload"] |= {"job_id": job_id, "state": state} | payload
    if state != "completed":
        del e["payload"]["finished_at"]
    if state == "queued":
        del e["payload"]["started_at"]
    return json.dumps(e).encode()


class FakeKafka:
    """One partition's messages, read from the last committed offset; commits recorded."""

    def __init__(self, values: list[bytes], crash_on_commit: int = 0):
        self.values = values
        self.committed = 0
        self.commits = []
        self.position = 0
        self.crashes_left = crash_on_commit
        self.now = 0.0  # each poll takes a second

    def poll(self, timeout):
        self.now += 1
        if self.position >= len(self.values):
            return None
        record = Record(0, self.position, self.values[self.position], SENT)
        self.position += 1
        return record

    def commit(self, offsets):
        if self.crashes_left:
            self.crashes_left -= 1
            raise RuntimeError("killed before the commit")
        self.committed = offsets[0]
        self.commits.append(offsets[0])

    def restart(self):
        """A new consumer in the same group starts where the group committed."""
        self.position = self.committed


def stream():
    return [
        event("e1", 1, "queued", "2026-10-17T09:59:58Z"),
        event("e2", 1, "running", "2026-10-17T09:59:59Z"),
        event("e3", 1, "completed", "2026-10-17T10:00:02Z"),
        event("e4", 2, "queued", "2026-10-17T10:00:03Z"),
    ]


def test_events_land_in_the_hour_they_happened(tmp_path, contract):
    stats = run(FakeKafka(stream()), Sink(tmp_path), contract, idle_polls=1)
    assert stats == Counter(events=4, files=2)
    hours = sorted(p.parent.name for p in tmp_path.glob("events/**/*.parquet"))
    assert hours == ["hour=09", "hour=10"]


def test_the_jobs_view_has_each_job_once_with_its_times(tmp_path, contract):
    run(FakeKafka(stream()), Sink(tmp_path), contract, idle_polls=1)
    con = warehouse.connect(tmp_path)
    rows = con.execute("SELECT job_id, state, run_s, wait_s FROM jobs ORDER BY job_id").fetchall()
    # The example: created 09:30:00.123456, started 1.5 s later, ran 2.7 s.
    assert rows == [
        (1, "completed", pytest.approx(2.7), pytest.approx(1.5)),
        (2, "queued", None, None),
    ]


def test_steady_traffic_is_still_written(tmp_path, contract):
    kafka = FakeKafka(stream())
    run(kafka, Sink(tmp_path), contract, idle_polls=1, max_age=2, clock=lambda: kafka.now)
    # Events 1 to 3 waited two seconds; event 4 was written when the topic went quiet.
    assert kafka.commits == [3, 4]


def test_a_crash_before_the_commit_writes_nothing_twice(tmp_path, contract):
    kafka = FakeKafka(stream(), crash_on_commit=1)
    with pytest.raises(RuntimeError, match="killed"):
        run(kafka, Sink(tmp_path), contract, idle_polls=1)
    assert kafka.committed == 0, "the batch was written but never committed"

    kafka.restart()  # so all four events come again
    run(kafka, Sink(tmp_path), contract, idle_polls=1)
    con = warehouse.connect(tmp_path)
    files = len(list(tmp_path.glob("events/**/*.parquet")))
    rows = con.execute(
        "SELECT count(*) FROM read_parquet(?)", [str(tmp_path / "events/**/*.parquet")]
    )
    assert (files, rows.fetchone()[0], kafka.committed) == (2, 4, 4)


def test_a_crash_while_writing_loses_nothing(tmp_path, contract):
    class FullDisk(Sink):
        def write(self, *args):
            raise OSError("no space left on device")

    kafka = FakeKafka(stream())
    with pytest.raises(OSError):
        run(kafka, FullDisk(tmp_path), contract, idle_polls=1)
    assert kafka.committed == 0, "committed events that were never written"

    kafka.restart()
    run(kafka, Sink(tmp_path), contract, idle_polls=1)
    con = warehouse.connect(tmp_path)
    assert con.execute("SELECT count(*) FROM events").fetchone()[0] == 4


def test_events_written_twice_count_once(tmp_path, contract):
    kafka = FakeKafka(stream(), crash_on_commit=1)
    with pytest.raises(RuntimeError, match="killed"):
        run(kafka, Sink(tmp_path), contract, idle_polls=1)
    # While the pipeline was down, another event arrived: the batch read
    # after the restart is longer, so its files get other names.
    kafka.values.append(event("e5", 2, "running", "2026-10-17T10:00:05Z"))
    kafka.restart()
    run(kafka, Sink(tmp_path), contract, idle_polls=1)
    files = str(tmp_path / "events/**/*.parquet")
    con = warehouse.connect(tmp_path)
    rows = con.execute("SELECT count(*) FROM read_parquet(?)", [files]).fetchone()[0]
    assert (rows, con.execute("SELECT count(*) FROM events").fetchone()[0]) == (9, 5)


def test_a_duplicate_delivery_counts_once(tmp_path, contract):
    values = stream()
    values.insert(3, values[2])  # the relay sent "completed" twice: same id, new offset
    run(FakeKafka(values), Sink(tmp_path), contract, idle_polls=1)
    con = warehouse.connect(tmp_path)
    assert con.execute("SELECT count(*) FROM events").fetchone()[0] == 4


def test_a_late_event_joins_its_own_hour(tmp_path, contract):
    kafka = FakeKafka(stream())
    run(kafka, Sink(tmp_path), contract, idle_polls=1)
    # Job 2 finished at 10:00:09, but its events reached the pipeline only
    # after an outage, in a later batch.
    kafka.values.append(event("e5", 2, "running", "2026-10-17T10:00:05Z"))
    kafka.values.append(event("e6", 2, "completed", "2026-10-17T10:00:09Z"))
    run(kafka, Sink(tmp_path), contract, idle_polls=1)
    con = warehouse.connect(tmp_path)
    state = con.execute("SELECT state FROM jobs WHERE job_id = 2").fetchone()[0]
    assert state == "completed"
    assert len(list(tmp_path.glob("events/date=2026-10-17/hour=10/*.parquet"))) == 2


def test_events_that_break_the_contract_are_quarantined_not_lost(tmp_path, contract):
    values = stream()
    values.insert(1, b'{"id": "x", "type": "jobs.job_changed", "version": 3}')
    stats = run(FakeKafka(values), Sink(tmp_path), contract, idle_polls=1)
    assert (stats["events"], stats["quarantined"]) == (4, 1)
    (bad,) = tmp_path.glob("quarantine/*.jsonl")
    kept = json.loads(bad.read_text())
    assert kept["offset"] == 1 and kept["reason"] == "version 3: this contract is version 2"


def test_show_prints_a_table(tmp_path, contract):
    run(FakeKafka(stream()), Sink(tmp_path), contract, idle_polls=1)
    text = warehouse.show(warehouse.connect(tmp_path), "SELECT job_id, run_s FROM jobs ORDER BY 1")
    assert text.splitlines() == ["job_id  run_s", "------  -----", "     1  2.700", "     2   NULL"]


def test_files_from_before_a_column_was_added_still_count(tmp_path, contract):
    run(FakeKafka(stream()), Sink(tmp_path), contract, idle_polls=1)
    # Rewrite one file as an older pipeline wrote it: no kafka_time column.
    path = sorted(tmp_path.glob("events/**/*.parquet"))[0]
    pq.write_table(pq.read_table(path).drop_columns(["kafka_time"]), path)
    con = warehouse.connect(tmp_path)
    assert con.execute("SELECT count(*), count(kafka_time) FROM events").fetchone() == (4, 2)
~~~

### SQL over files

DuckDB runs SQL in your process, over the Parquet files directly: no server, no loading step. Create `lab/src/lab/warehouse.py`:

<!-- file: lab/src/lab/warehouse.py -->
~~~python
"""SQL over the pipeline's Parquet files, with DuckDB: no server, just files and a query.

Two views. events: every event once, however many times it was delivered.
jobs: one row per job, from its latest event, with its run and wait times.
"""

from pathlib import Path

import duckdb

# A job's events can share a timestamp (completed straight after started,
# within a microsecond), so ties go to the later state.
STATE_ORDER = "CASE state WHEN 'queued' THEN 1 WHEN 'running' THEN 2 ELSE 3 END"


def connect(data: Path) -> duckdb.DuckDBPyConnection:
    files = data / "events" / "**" / "*.parquet"
    if not any((data / "events").glob("**/*.parquet")):
        raise FileNotFoundError(f"no events under {data}: run the pipeline first")
    con = duckdb.connect()
    con.execute("SET TimeZone = 'UTC'")
    # The outbox relay sends at least once, so the topic itself can hold
    # an event twice, at two offsets: the same id is the same event.
    # union_by_name: files written before a column was added still count,
    # with NULL in it. Without it, the first file's columns are the view's.
    con.execute(f"""
        CREATE VIEW events AS
        SELECT * EXCLUDE (date, hour)
        FROM read_parquet('{files}', hive_partitioning = true, union_by_name = true)
        QUALIFY row_number() OVER (PARTITION BY event_id ORDER BY kafka_partition, kafka_offset) = 1
    """)
    con.execute(f"""
        CREATE VIEW jobs AS
        SELECT tenant, job_id, kind, size, state, reason, created_at, started_at, finished_at,
               epoch(finished_at - started_at) AS run_s,
               epoch(started_at - created_at) AS wait_s,
               occurred_at AS last_event_at
        FROM events
        QUALIFY row_number() OVER (
            PARTITION BY tenant, job_id ORDER BY occurred_at DESC, {STATE_ORDER} DESC) = 1
    """)
    return con


def show(con: duckdb.DuckDBPyConnection, sql: str, max_rows: int = 40) -> str:
    """A query's result as a plain table."""
    cursor = con.execute(sql)
    names = [d[0] for d in cursor.description]
    rows = cursor.fetchall()
    cells = [names] + [[_cell(v) for v in row] for row in rows[:max_rows]]
    widths = [max(len(r[i]) for r in cells) for i in range(len(names))]
    lines = ["  ".join(c.rjust(w) for c, w in zip(r, widths, strict=True)) for r in cells]
    lines.insert(1, "  ".join("-" * w for w in widths))
    if len(rows) > max_rows:
        lines.append(f"... {len(rows) - max_rows} more rows")
    return "\n".join(lines)


def _cell(value) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, float):
        return f"{value:.3f}"
    return str(value)
~~~

Two views, defined once, so every query agrees on what an event and a job are. `events` keeps one row per event ID, whatever was written twice. `jobs` takes each job's latest event, so `run_s` and `wait_s` come from the times it carries. `hive_partitioning` turns the `date=`/`hour=` directory names into columns, and DuckDB skips whole directories when a query filters on them.

Add the commands, in `lab/src/lab/cli.py`:

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python
        print(f"\nplot: {jobs.plot(rows, args.plot)}")
    return 0
~~~

to:

~~~python
        print(f"\nplot: {jobs.plot(rows, args.plot)}")
    return 0


def cmd_pipeline(args: argparse.Namespace) -> int:
    from lab.contract import Contract
    from lab.pipeline import KafkaSource, Sink, run

    source = KafkaSource(args.brokers, args.topic, args.group)
    try:
        stats = run(source, Sink(args.data), Contract(args.contract), follow=args.follow)
    finally:
        source.close()
    print(", ".join(f"{k} {v}" for k, v in sorted(stats.items())) or "nothing new")
    return 0


def cmd_sql(args: argparse.Namespace) -> int:
    from lab import warehouse

    print(warehouse.show(warehouse.connect(args.data), args.query))
    return 0
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

    simulate = sub.add_parser(
~~~

to:

~~~python

    pipe = sub.add_parser("pipeline", help="copy new job events from Kafka into Parquet")
    pipe.add_argument("--brokers", default="localhost:39092")
    pipe.add_argument("--topic", default="runway.job-events")
    pipe.add_argument("--group", default="lab-pipeline", help="the consumer group: its offsets")
    pipe.add_argument("--data", type=Path, default=Path("data"))
    pipe.add_argument("--contract", type=Path, default=Path("contracts/job_changed.v2.schema.json"))
    pipe.add_argument("--follow", action="store_true", help="keep reading; stop with Ctrl-C")
    pipe.set_defaults(func=cmd_pipeline)

    sql = sub.add_parser("sql", help="query the events and jobs views with DuckDB")
    sql.add_argument("query")
    sql.add_argument("--data", type=Path, default=Path("data"))
    sql.set_defaults(func=cmd_sql)

    simulate = sub.add_parser(
~~~


<!-- run: cd lab && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

The pipeline writes tenants' data into `data/`: keep it out of Git and the image. In `.gitignore`:

Add this at the end of the file:

<!-- append: .gitignore -->
~~~text
# The data pipeline's Parquet files (Phase 7): tenants' data, not code.
data/
~~~


In `.dockerignore`:

Change:

<!-- edit: .dockerignore -->
~~~text
results
bin
~~~

to:

~~~text
results
data
bin
~~~


**Break it.** In `_flush`, move `source.commit(...)` above the writes, so it commits first. Run the pipeline tests:

~~~bash
cd lab && uv run pytest -q tests/test_pipeline.py; cd ..
~~~

~~~text
E       AssertionError: committed events that were never written
FAILED tests/test_pipeline.py::test_a_crash_while_writing_loses_nothing - Ass...
FAILED tests/test_pipeline.py::test_events_written_twice_count_once - assert ...
2 failed, 9 passed in 1.86s
~~~

A full disk after the commit, and four events are gone for good: Kafka thinks they were handled, and no file has them. The second failure is the same swap seen from the other side: nothing was written before the crash, so no event is in two files. Duplicates are the price of the safe order, and the views pay it. Note which test *didn't* fail: `test_a_crash_before_the_commit_writes_nothing_twice` passes either way, because a commit that fails loses nothing in either order. Only a failure *after* a commit that worked, and before the write, tells the two orders apart, so only a test of that failure can. Put it back.

**Break it.** In `warehouse.py`, remove `union_by_name = true` and run the same tests:

~~~text
E       _duckdb.BinderException: Binder Error: Referenced column "kafka_time" not found in FROM clause!
FAILED tests/test_pipeline.py::test_files_from_before_a_column_was_added_still_count
1 failed, 10 passed in 1.02s
~~~

One file from before the `kafka_time` column existed, and the column vanishes from the whole view: DuckDB took its columns from the first file it read. Files outlive the code that wrote them, so every reader must expect older shapes. Put it back.

### Kafka on the cluster

Until now, Kafka ran only in Compose. The data a model needs comes from the cluster: three tenants, workers with CPU limits, the contention step 2 measured. Create `deploy/k8s/kafka.yaml`:

<!-- file: deploy/k8s/kafka.yaml -->
~~~yaml
# Kafka on the cluster (Phase 7): one broker, in KRaft mode, as in
# compose.yaml. The API streams every job change to it (Phase 3's
# JobChanged events), and the data pipeline reads them.
#
# Three listeners. INTERNAL is for Pods: clients are told to reconnect to
# kafka:9092. EXTERNAL is for you, through a port-forward: clients are told
# localhost:39092, which is where the port-forward listens on your machine.
# (A Kafka client connects twice: once to any broker to ask where the
# partitions are, then to the address the broker advertises. Advertise an
# address the client can't reach, and the first connection works and the
# second hangs.) CONTROLLER is KRaft's own.
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: runway
spec:
  serviceName: kafka
  replicas: 1
  selector:
    matchLabels: { app: kafka }
  template:
    metadata:
      labels: { app: kafka }
    spec:
      securityContext:
        runAsUser: 1000 # the image's appuser
        runAsGroup: 1000
        fsGroup: 1000 # so the broker can write to its volume
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
      automountServiceAccountToken: false
      containers:
        - name: kafka
          image: apache/kafka:4.1.0
          env:
            - { name: KAFKA_NODE_ID, value: "1" }
            - { name: KAFKA_PROCESS_ROLES, value: "broker,controller" }
            - { name: KAFKA_LISTENERS, value: "INTERNAL://:9092,EXTERNAL://:39092,CONTROLLER://:9093" }
            - { name: KAFKA_ADVERTISED_LISTENERS, value: "INTERNAL://kafka:9092,EXTERNAL://localhost:39092" }
            - { name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP, value: "INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT,CONTROLLER:PLAINTEXT" }
            - { name: KAFKA_INTER_BROKER_LISTENER_NAME, value: INTERNAL }
            - { name: KAFKA_CONTROLLER_LISTENER_NAMES, value: CONTROLLER }
            - { name: KAFKA_CONTROLLER_QUORUM_VOTERS, value: "1@localhost:9093" }
            - { name: KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR, value: "1" }
            - { name: KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR, value: "1" }
            - { name: KAFKA_TRANSACTION_STATE_LOG_MIN_ISR, value: "1" }
            - { name: KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS, value: "0" }
            # The image keeps its log in /tmp by default: gone with the Pod.
            - { name: KAFKA_LOG_DIRS, value: /var/lib/kafka/data }
            # A small heap for a laptop. The JVM's default is a quarter of
            # the machine, not of the container's limit.
            - { name: KAFKA_HEAP_OPTS, value: "-Xms256m -Xmx256m" }
          ports:
            - { name: internal, containerPort: 9092 }
            - { name: external, containerPort: 39092 }
          readinessProbe:
            tcpSocket: { port: internal }
            periodSeconds: 5
          resources:
            requests: { cpu: 100m, memory: 512Mi }
            limits: { memory: 768Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: data, mountPath: /var/lib/kafka/data }
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        resources:
          requests: { storage: 2Gi }
---
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: runway
spec:
  selector: { app: kafka }
  ports:
    - { name: internal, port: 9092, targetPort: internal }
---
# Only the API writes job events. A port-forward arrives from the node, so
# the pipeline on your machine needs no rule here: kubectl's own access
# (you are an administrator) is the control.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: kafka
  namespace: runway
spec:
  podSelector: { matchLabels: { app: kafka } }
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: { matchLabels: { app: api } }
      ports: [{ port: 9092 }]
~~~

Point the API at it. In `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
  allowHosts: []

~~~

to:

~~~yaml
  allowHosts: []

# The job-events stream (Phase 7): where the API sends every change of a
# job's state, for the data pipeline. deploy/k8s/kafka.yaml runs the
# broker. Empty: no stream, as before Phase 7.
kafka:
  brokers: kafka:9092

~~~


In `deploy/helm/runway/templates/_helpers.tpl`:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
        - { name: WEBHOOK_ALLOW_HOSTS, value: {{ join "," $root.Values.webhooks.allowHosts | quote }} }
        {{- if $root.Values.tls.enabled }}
~~~

to:

~~~yaml
        - { name: WEBHOOK_ALLOW_HOSTS, value: {{ join "," $root.Values.webhooks.allowHosts | quote }} }
        {{- with $root.Values.kafka.brokers }}
        - { name: KAFKA_BROKERS, value: {{ . | quote }} }
        {{- end }}
        {{- if $root.Values.tls.enabled }}
~~~


And let the API's egress policy reach it, in `deploy/helm/runway/templates/networkpolicy.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/networkpolicy.yaml -->
~~~yaml
      ports: [{ port: 6380 }]
    {{- include "runway.toCollector" . | nindent 4 }}
~~~

to:

~~~yaml
      ports: [{ port: 6380 }]
    {{- if .Values.kafka.brokers }}
    - to: [{ podSelector: { matchLabels: { app: kafka } } }] # job events (Phase 7)
      ports: [{ port: 9092 }]
    {{- end }}
    {{- include "runway.toCollector" . | nindent 4 }}
~~~


<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway | grep -q 'name: KAFKA_BROKERS, value: "kafka:9092"' -->

### Run it: Kafka first, then readers before writers

Start the broker and wait for it. The API creates the topic when it starts (three partitions, as Phase 3's projector expects), so Kafka must be there first; otherwise the new API Pods crash until it is:

~~~bash
kubectl apply -f deploy/k8s/kafka.yaml
kubectl -n runway rollout status sts/kafka
~~~

Then deploy as in step 2, with one more reader to upgrade first: the notifier reads `JobChanged`, so it must understand version 2 before the API sends it.

~~~bash
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
kubectl -n runway rollout restart deploy/worker deploy/notifier
kubectl -n runway rollout status deploy/worker && kubectl -n runway rollout status deploy/notifier
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait
kubectl -n runway rollout restart deploy/api deploy/idp deploy/gateway sts/metad
kubectl -n runway rollout status deploy/api && kubectl -n runway rollout status deploy/idp
~~~

Open the way to the broker from your machine, on the listener that advertises `localhost:39092`. Kafka's tools are inside the image; run them against that same listener, from inside the Pod (the `INTERNAL` one advertises `kafka:9092`, the Service, and the broker's own Pod may not connect to it: `default-deny` blocks its traffic out, and its policy admits only the API):

~~~bash
kubectl -n runway port-forward pod/kafka-0 39092:39092 >/dev/null 2>&1 &
kafkatool() { kubectl -n runway exec kafka-0 -- /opt/kafka/bin/$1 --bootstrap-server localhost:39092 "${@:2}"; }
kafkatool kafka-get-offsets.sh --topic runway.job-events
~~~

~~~text
runway.job-events:0:0
runway.job-events:1:0
runway.job-events:2:0
~~~

Three partitions, each at offset 0: empty. (A port-forward to a Pod ends when the Pod does. After any restart of `kafka-0`, start it again.)

### Run it: the workload, then the pipeline

Get fresh tokens (the `idp` restarted, so restart its port-forward too) and run step 2's workload:

~~~bash
kubectl -n runway port-forward svc/idp 8081:8081 >/dev/null 2>&1 &
export ACME_TOKEN=$(token acme-ci) GLOBEX_TOKEN=$(token globex-ci) INITECH_TOKEN=$(token initech-ci)
uv run --project kload kload mix workloads/three-tenants.toml --url http://localhost:8000 --out results/s03.jsonl
kafkatool kafka-get-offsets.sh --topic runway.job-events
~~~

~~~text
1116 jobs over 180 s from 3 tenants
submitted: 1116 accepted, 0 refused
states: {'completed': 1116}
wrote results/s03.jsonl (settings: results/s03.settings.json)
~~~

~~~text
runway.job-events:0:1077
runway.job-events:1:1185
runway.job-events:2:1086
~~~

3,348 messages: 1,116 jobs, three changes each (queued, running, completed), spread over the partitions by job ID. Now run the pipeline, from the top of the practice (its defaults are `data/` and `contracts/` there), and then again:

~~~bash
uv run --project lab lab pipeline
uv run --project lab lab pipeline
~~~

~~~text
events 3348, files 9, quarantined 0
~~~

~~~text
nothing new
~~~

The second run started where the first committed, so it found nothing. That's the consumer group's offsets at work: the pipeline keeps no state of its own. What it wrote:

~~~bash
find data -type f | sort; du -sh data
~~~

~~~text
data/events/date=2026-10-17/hour=03/p0-000000000000-000000000499.parquet
data/events/date=2026-10-17/hour=03/p0-000000000500-000000000999.parquet
data/events/date=2026-10-17/hour=03/p0-000000001000-000000001076.parquet
data/events/date=2026-10-17/hour=03/p1-000000000000-000000000499.parquet
data/events/date=2026-10-17/hour=03/p1-000000000500-000000000999.parquet
data/events/date=2026-10-17/hour=03/p1-000000001000-000000001184.parquet
data/events/date=2026-10-17/hour=03/p2-000000000000-000000000499.parquet
data/events/date=2026-10-17/hour=03/p2-000000000500-000000000999.parquet
data/events/date=2026-10-17/hour=03/p2-000000001000-000000001085.parquet
272K	data
~~~

Nine files: three batches for each partition (500, 500, and the rest), all in the one hour the run took. `du` rounds each file up to whole disk blocks; the files themselves total 248,024 bytes (`find data -name '*.parquet' -printf '%s\n' | awk '{s += $1} END {print s}'`), about 74 bytes an event. As JSON in Kafka, an event averages 366. A column with a handful of distinct values (tenant, kind, state) is stored as a small dictionary plus a code per row, and the timestamps as integers; the random event IDs are most of what's left.

### Run it: ask questions

~~~bash
sql() { uv run --project lab lab sql "$@"; }
sql "SELECT tenant, kind, count(*) AS jobs, median(run_s) AS run_p50, quantile_cont(run_s, 0.99) AS run_p99,
            median(wait_s) AS wait_p50 FROM jobs GROUP BY ALL ORDER BY ALL"
~~~

~~~text
 tenant      kind  jobs  run_p50  run_p99  wait_p50
-------  --------  ----  -------  -------  --------
   acme  checksum   494    0.023    0.102     0.056
   acme      sort   204    0.038    0.338     0.056
 globex  compress    96    0.451    3.167     0.054
initech  checksum   100    0.044    0.204     0.056
initech  compress   115    0.096    0.554     0.053
initech      sort   107    0.084    0.369     0.056
~~~

Step 2's table, from the events alone: no polling, no tenant tokens. And `wait_s` is new: the time from creation to start, which `kload` never reported. Every tenant waits about 55 ms at the median, whatever its jobs: the queue doesn't know what's in it. Step 9 changes that.

Are the events complete? Every job should have exactly one event of each state:

~~~bash
sql "SELECT state, count(*) AS events, count(DISTINCT job_id) AS jobs FROM events GROUP BY state ORDER BY events DESC"
~~~

~~~text
    state  events  jobs
---------  ------  ----
   queued    1116  1116
  running    1116  1116
completed    1116  1116
~~~

### Run it: reconcile

Two independent records of this run exist: what `kload` saw through the API, and what the events say. They should agree to the microsecond. DuckDB reads `kload`'s JSON lines directly:

~~~bash
sql "SELECT count(*) AS jobs,
            count(*) FILTER (WHERE abs(j.run_s - epoch(k.finished_at::TIMESTAMPTZ - k.started_at::TIMESTAMPTZ)) > 1e-6) AS run_differs
     FROM jobs j JOIN 'results/s03.jsonl' k ON k.tenant = j.tenant AND k.id = j.job_id"
~~~

~~~text
jobs  run_differs
----  -----------
1116            0
~~~

Now the system of record, PostgreSQL. Find the range of jobs the events cover, then count the `jobs` table on both sides of it:

~~~bash
sql "SELECT tenant, state, count(*) AS jobs, min(job_id) AS first, max(job_id) AS last FROM jobs GROUP BY ALL ORDER BY ALL"
~~~

~~~text
 tenant      state  jobs  first  last
-------  ---------  ----  -----  ----
   acme  completed   698   5270  6380
 globex  completed    96   5295  6381
initech  completed   322   5267  6382
~~~

~~~bash
first=$(sql "SELECT min(job_id) FROM jobs" | tail -1 | tr -d ' ')
kubectl -n runway exec postgres-0 -- psql -U runway -c "
  SELECT tenant, state, count(*) FILTER (WHERE id < $first) AS before_stream,
         count(*) FILTER (WHERE id >= $first) AS since
  FROM jobs GROUP BY 1, 2 ORDER BY 1, 2"
~~~

~~~text
 tenant  |   state   | before_stream | since 
---------+-----------+---------------+-------
 acme    | completed |          3448 |   698
 globex  | completed |           474 |    96
 globex  | failed    |             1 |     0
 hooli   | completed |            24 |     0
 initech | completed |          1318 |   322
 smoke   | completed |             1 |     0
(6 rows)

~~~

The `since` column matches the events exactly: 698, 96 and 322. The `before_stream` column is everything Runway ran before this step, since the database was created: thousands of jobs (step 2's one failed compression among them) that the pipeline has never seen, because their events were never sent. Your numbers there will differ; the shape won't. That's the first lesson of reconciling: the events are complete *from the moment they started*, and any dataset built from them begins there. Step 5 will need to say so.

### Break it: Kafka goes down

Run the pipeline the way it would really run, following the topic, and take Kafka away in the middle of a workload. Get fresh tokens, then:

~~~bash
uv run --project lab lab pipeline --follow 2> results/pipeline.log &
pipeline=$!
uv run --project kload kload mix workloads/three-tenants.toml --url http://localhost:8000 \
  --out results/s03-outage.jsonl > results/s03-outage.txt &
load=$!
sleep 60
kubectl -n runway scale sts kafka --replicas 0
for i in 1 2 3 4 5 6; do
  sleep 10
  kubectl -n runway exec postgres-0 -- psql -U runway -tAc "SELECT now()::time(0), count(*) FROM outbox
    WHERE published_at IS NULL AND destination = 'runway.job-events'"
done
kubectl -n runway scale sts kafka --replicas 1
kubectl -n runway rollout status sts/kafka
kubectl -n runway port-forward pod/kafka-0 39092:39092 >/dev/null 2>&1 &
wait $load; cat results/s03-outage.txt
sleep 15; kill -INT $pipeline; wait $pipeline; echo "pipeline exited: $?"
~~~

~~~text
statefulset.apps/kafka scaled
03:26:40|146
03:26:52|348
03:27:02|505
03:27:13|667
03:27:24|889
03:27:35|1058
statefulset.apps/kafka scaled
Waiting for 1 pods to be ready...
partitioned roll out complete: 1 new pods have been updated...
1116 jobs over 180 s from 3 tenants
submitted: 1116 accepted, 0 refused
states: {'completed': 1116}
wrote results/s03-outage.jsonl (settings: results/s03-outage.settings.json)
pipeline exited: 1
~~~

While Kafka was gone, the unsent events piled up in the outbox, 146 to 1,058 in a minute: Phase 3's outbox doing its job. And every job completed: commands go through RabbitMQ, and nothing in running a job waits for the stream. The pipeline, though, exited with an error. Why?

~~~bash
grep -c '^%' results/pipeline.log; grep -v '^%' results/pipeline.log | tail -3
~~~

~~~text
936
  File "/home/techieemma/blueprint-scratch/p7/lab/src/lab/pipeline.py", line 241, in commit
    self.consumer.commit(offsets=parts, asynchronous=False)
cimpl.KafkaException: KafkaError{code=_WAIT_COORD,val=-180,str="Commit failed: Local: Waiting for coordinator"}
~~~

936 lines of the Kafka client reporting lost connections (they start with `%`), then the end: a batch was written, and its commit failed because no broker was there to take it. The pipeline did exactly what it should. It didn't pretend the commit worked, and it didn't skip the batch: it stopped. Start it again now that Kafka is back:

~~~bash
uv run --project lab lab pipeline
sql "SELECT (SELECT count(*) FROM read_parquet('data/events/**/*.parquet')) AS rows_in_files,
            (SELECT count(*) FROM events) AS events, (SELECT count(DISTINCT job_id) FROM events) AS jobs"
~~~

~~~text
events 2405, files 6, quarantined 0
~~~

~~~text
rows_in_files  events  jobs
-------------  ------  ----
         6758    6696  2232
~~~

Two runs of 1,116 jobs: 2,232 jobs and 6,696 events, three each, none missing. And 62 rows more in the files than there are events: the batch whose commit failed, read and written again. The `events` view counts each once. That's at least once, working: a crash cost 62 duplicate rows, and lost nothing.

Kafka recorded when each event arrived, so the pipeline can tell you how late each one was:

~~~bash
sql "SELECT date_trunc('minute', occurred_at) AS minute, count(*) AS events,
            median(epoch(kafka_time - occurred_at)) AS late_p50, max(epoch(kafka_time - occurred_at)) AS late_max
     FROM events WHERE job_id IN (SELECT id FROM 'results/s03-outage.jsonl') GROUP BY 1 ORDER BY 1"
~~~

~~~text
                   minute  events  late_p50  late_max
-------------------------  ------  --------  --------
2026-10-17 03:25:00+00:00     596     0.045     0.109
2026-10-17 03:26:00+00:00     937     0.113    76.382
2026-10-17 03:27:00+00:00    1099    16.128    47.499
2026-10-17 03:28:00+00:00     716     0.048     0.110
~~~

Normally an event reaches Kafka in about 50 ms: the relay looks at the outbox every 100 ms, so an event waits half that on average. During the outage, up to 76 s late. Every one still went into the hour it *happened* in, because the files are partitioned by `occurred_at`. Had the outage crossed an hour, the earlier hour would have gained files after it ended (`test_a_late_event_joins_its_own_hour` is that case). So when is an hour finished? Never for certain: only "probably", once the outbox is empty and the latest lateness is small. Whatever reads this data must either wait (here, a few minutes beyond the longest lateness you're willing to believe) or accept that an hour can change after it was read. Step 5 waits.

### Backfill: rebuild from the log

The files are derived data; the topic is the record. So if the pipeline's code changes (a bug in `to_row`, a new column), or files are lost, rebuild: read the whole topic again, as a new consumer group into a new directory, and compare.

~~~bash
uv run --project lab lab pipeline --group lab-rebuild-1 --data data-rebuilt
for d in data data-rebuilt; do
  printf "%-13s %3s files  " $d $(find $d -name "*.parquet" | wc -l)
  sql --data $d "SELECT (SELECT count(*) FROM read_parquet('$d/events/**/*.parquet')) AS rows, count(*) AS jobs,
                        sum(hash(tenant, job_id, state, run_s, wait_s)) AS fingerprint FROM jobs" | tail -1
done
~~~

~~~text
events 6696, files 15, quarantined 0
~~~

~~~text
data           31 files  6758  2232  20775979046541484292485
data-rebuilt   15 files  6696  2232  20775979046541484292485
~~~

The same 2,232 jobs, the same fingerprint (the sum of a 64-bit hash of every job's row: different rows would almost certainly give a different sum). The rebuilt copy has half the files and no duplicate rows: one pass, full batches. Following the topic every 10 seconds makes many small files, and a rebuild is also how you compact them. Swap it in when it checks out (`mv data data-old && mv data-rebuilt data`).

How far back can you rebuild?

~~~bash
kubectl -n runway exec kafka-0 -- /opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:39092 --describe \
  --entity-type topics --entity-name runway.job-events --all | tr ' ' '\n' | grep -E '^(cleanup.policy|retention.ms)='
~~~

~~~text
cleanup.policy=delete
retention.ms=604800000
~~~

604,800,000 ms: seven days. Kafka deletes older segments, so after a week the Parquet files are the only copy of those events, and a backup of `data/` is a backup of history. A team that wants to rebuild further back keeps the topic longer (`retention.ms=-1` keeps everything, on disk they must pay for), or archives the raw events. Either way, decide it before the first week is gone.

**Explain it:** why did `JobChanged` need a new version, and why must the notifier be upgraded before the API? What does the Go contract test catch, and what does the Python one catch that it can't? Why does `format` need a checker? Why must the commit come after the write, and which test proves it? Why can the files hold an event twice, and why doesn't it matter? Why partition by `occurred_at`, and what does that cost a reader? What did the reconciliation with PostgreSQL find, and why can't the pipeline ever see those jobs? Why didn't the Kafka outage stop any job? How far back can you rebuild, and what decides it?

**Read.** Jay Kreps, *The Log: What every software engineer should know about real-time data's unifying abstraction* (2013): why the topic, not the files, is the record. Tyler Akidau, *Streaming 101* and *Streaming 102* (O'Reilly Radar, 2015–16): event time, processing time, and watermarks, the formal version of "when is an hour finished?". Then *Designing Data-Intensive Applications*, chapter 11, *Stream Processing*, for exactly-once and idempotence in general.

---
## Step 4: Big data, honestly

**The problem.** Step 3's pipeline holds a few thousand events. A month of Runway at step 2's rate (6.2 jobs a second, three events each) is 48 million: about 2 GB of Parquet. Is that big data? The tools with that name (MapReduce, Hadoop, Spark) were built for data that can't fit on one machine, and their ideas run through everything that processes data in parallel: Kafka's partitions, Spark and Flink, BigQuery, and DuckDB's own parallel aggregation. This step builds a MapReduce from scratch, to see those ideas work and fail. Then it measures what scaling out actually buys on one month of data, against one well-written program on one core.

**New ideas.**

- **Map, shuffle, reduce.** Cut the input into **splits**. A **map** task turns each record of its split into (key, value) pairs. The **shuffle** sends every pair to a **reduce** task chosen by its key, so that all the pairs with one key, from every map task, meet in one place. Each reduce task groups its pairs by key and reduces each group to an answer. Map tasks don't talk to each other, and neither do reduce tasks, which is why there can be thousands of each.
- **The partition function must agree everywhere.** Every map task must send key K to the same reducer. Python's built-in `hash()` of a string is salted with a random number chosen when each process starts, so two processes (two machines) would disagree. Use a hash defined by the bytes, like CRC-32.
- **Combiners, and what can be combined.** A combiner reduces each map task's own pairs before the shuffle, so less crosses it. That only works for **algebraic** aggregates, built from parts that merge in any order: a count, a sum, so a mean (sum and count). A median is **holistic**: no summary of part of the data short of all of it can be merged into the exact median of the whole. The way out is an approximation that does merge: a **mergeable sketch**, like a histogram with buckets of known relative width.
- **Skew.** One key with much of the data gives one reduce task much of the work, and the job waits for its slowest task. Customers are skewed (a few are huge), so a key of "tenant" is skewed.
- **Re-execution is the fault tolerance.** A task reads its input and writes its output, and nothing else. So a failed task is simply run again, and a slow one can be raced by a copy (**speculative execution**). Both need a task's output to be committed atomically, by the first attempt to finish: write privately, then rename into place, as step 3's pipeline does.
- **COST.** McSherry, Isard and Murray's measure (2015): the Configuration that Outperforms a Single Thread. How many cores does a system need before it beats one good single-threaded program? A system that "scales linearly" from a slow start can need hundreds.
- **What you measure is the machine too.** A file read from memory (the page cache) and from disk differ by a factor of several; a first run pays for loading code and filling caches. Time the runs after a warm-up, with nothing else competing for memory, and interleave the systems, as in step 1.

### Make room

This step reads 2 GB repeatedly and runs a JVM, and the comparison is only fair if the files stay in memory. If your machine has less than 16 GB, stop the cluster for this step (its data is kept; step 8 starts it again), and anything else you started for tests:

~~~bash
docker stop runway-control-plane runway-worker runway-worker2
free -m
~~~

Spark needs Java 17 or later: check with `java -version` (on Ubuntu, `sudo apt install openjdk-21-jre-headless`).

### A month of events

Generate the month from the real jobs in step 3's `data/`, so the shapes are real: each synthetic job is a real job's kind, size, wait and run time, drawn at random, with a new ID, time and tenant. Create `lab/src/lab/synth.py`:

<!-- file: lab/src/lab/synth.py -->
~~~python
"""A month of job events at any scale, shaped like the real ones.

Each synthetic job is a real job from the pipeline's data, drawn at random
(kind, size, wait and run time together, so their relationships survive),
given a new ID, a new creation time and a tenant. Tenants follow a Zipf
law, as customers do: the first is the biggest by far, and most are small.
The files have the pipeline's schema and layout, so everything that reads
the pipeline's data reads these.
"""

from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

from lab import warehouse
from lab.pipeline import SCHEMA, UTC_US

DAY_US = 86_400_000_000


@dataclass(frozen=True)
class Spec:
    jobs: int = 2_000_000
    days: int = 30
    tenants: int = 200
    skew: float = 1.1  # the Zipf exponent: 0 is equal shares
    seed: int = 1
    start: datetime = datetime(2026, 9, 1, tzinfo=UTC)


def tenant_shares(tenants: int, skew: float) -> np.ndarray:
    """Tenant i's share of all jobs, proportional to 1 / i**skew."""
    weights = 1.0 / np.arange(1, tenants + 1) ** skew
    return weights / weights.sum()


def real_jobs(data: Path) -> dict[str, np.ndarray]:
    """The finished jobs to draw from."""
    con = warehouse.connect(data)
    rows = con.execute(
        "SELECT kind, size, wait_s, run_s FROM jobs WHERE state = 'completed' "
        "AND wait_s IS NOT NULL AND run_s IS NOT NULL ORDER BY tenant, job_id"
    ).fetchnumpy()
    return {k: np.asarray(v) for k, v in rows.items()}


def make(real: dict[str, np.ndarray], out: Path, spec: Spec) -> int:
    """Write spec.jobs jobs, drawn from real, under out/events/; return the number of events."""
    if out.exists() and any(out.iterdir()):
        raise FileExistsError(f"{out} is not empty")
    rng = np.random.default_rng(spec.seed)
    shares = tenant_shares(spec.tenants, spec.skew)
    names = np.array([f"t{i:04d}" for i in range(1, spec.tenants + 1)])
    per_day = rng.multinomial(spec.jobs, np.full(spec.days, 1 / spec.days))
    start_us = int(spec.start.timestamp() * 1_000_000)
    first_id, events = 1, 0
    for day, n in enumerate(per_day):
        pick = rng.integers(0, len(real["kind"]), n)
        created = start_us + day * DAY_US + np.sort(rng.integers(0, DAY_US, n))
        started = created + (real["wait_s"][pick] * 1e6).astype(np.int64)
        finished = started + (real["run_s"][pick] * 1e6).astype(np.int64)
        job_id = np.arange(first_id, first_id + n)
        first_id += n
        jobs = {
            "tenant": names[rng.choice(spec.tenants, n, p=shares)],
            "job_id": job_id,
            "kind": real["kind"][pick],
            "size": real["size"][pick],
            "created_at": created,
            "started_at": started,
            "finished_at": finished,
        }
        table = _events(jobs, rng)
        events += table.num_rows
        _write(table, out, f"synth-{day:03d}.parquet")
    return events


def _events(jobs: dict[str, np.ndarray], rng: np.random.Generator) -> pa.Table:
    """Three events per job, as the API sends them: queued, running, completed."""
    n = len(jobs["job_id"])
    never = np.full(n, np.iinfo(np.int64).min)  # stands for NULL until masked below
    parts = []
    for state, at, started, finished in [
        ("queued", jobs["created_at"], never, never),
        ("running", jobs["started_at"], jobs["started_at"], never),
        ("completed", jobs["finished_at"], jobs["started_at"], jobs["finished_at"]),
    ]:
        ids = pa.array(jobs["job_id"]).cast(pa.string())
        late = rng.exponential(50_000, n).astype(np.int64)  # 50 ms, as measured
        parts.append(
            {
                "event_id": pc.binary_join_element_wise("s", ids, state[0], ""),
                "occurred_at": _ts(at),
                "tenant": pa.array(jobs["tenant"]),
                "job_id": pa.array(jobs["job_id"]),
                "state": pa.array(np.full(n, state)),
                "reason": pa.array(np.full(n, "")),
                "kind": pa.array(jobs["kind"]),
                "size": pa.array(jobs["size"]),
                "created_at": _ts(jobs["created_at"]),
                "started_at": _ts(started),
                "finished_at": _ts(finished),
                "kafka_partition": pa.array((jobs["job_id"] % 3).astype(np.int32)),
                "kafka_offset": pa.array(jobs["job_id"] * 3),
                "kafka_time": _ts(at + late),
            }
        )
    tables = [pa.table(p).cast(SCHEMA) for p in parts]
    return pa.concat_tables(tables).sort_by("occurred_at")


def _ts(us: np.ndarray) -> pa.Array:
    mask = us == np.iinfo(np.int64).min
    return pa.array(us, type=pa.int64(), mask=mask).cast(UTC_US)


def _write(table: pa.Table, out: Path, name: str) -> None:
    """One file per hour the events happened in (a day's jobs spill into the next day)."""
    hours = pc.floor_temporal(table["occurred_at"], unit="hour")
    for hour in pc.unique(hours).to_pylist():
        rows = table.filter(pc.equal(hours, pa.scalar(hour, UTC_US)))
        at = hour.astimezone(UTC)
        path = out / "events" / f"date={at:%Y-%m-%d}" / f"hour={at:%H}" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        pq.write_table(rows, path)


def describe(out: Path) -> str:
    """How much was written, and how the tenants share it."""
    files = sorted(out.glob("events/**/*.parquet"))
    size = sum(f.stat().st_size for f in files)
    return f"{len(files)} files, {size / 1e6:.0f} MB"
~~~

Tenants follow a **Zipf** law: the i-th biggest has a share proportional to 1/i^1.1. With 200 tenants that gives the biggest about a fifth of everything, which is how customers are: one or two huge, a long tail of small. And the files are the pipeline's own layout, one per hour, so anything that reads step 3's data reads these.

### MapReduce, from scratch

Create `lab/src/lab/mapreduce.py`:

<!-- file: lab/src/lab/mapreduce.py -->
~~~python
"""MapReduce from scratch: map tasks, a shuffle through files, reduce tasks.

The model (Dean and Ghemawat, 2004): the input is cut into splits; a map
task turns each record of its split into (key, value) pairs; the pairs are
partitioned by key, so every pair with the same key goes to the same reduce
task, wherever it was made (the shuffle); each reduce task groups its pairs
by key and reduces each group to a result. A combiner is a reduce run on
each map task's own output before the shuffle, so less crosses it.

Every task attempt is a separate process, standing in for a machine. An
attempt writes to a private directory and commits by renaming it into
place; the first attempt of a task to commit wins. That makes a task safe
to run twice, which buys two things: a failed attempt is simply run again
(fault tolerance), and a slow one can be raced by a backup copy
(speculative execution), whichever finishes first.
"""

import json
import multiprocessing
import os
import pickle
import shutil
import statistics
import time
import zlib
from collections import defaultdict, deque
from collections.abc import Callable, Hashable, Iterable
from dataclasses import dataclass, field
from multiprocessing.connection import wait
from pathlib import Path
from typing import Any

import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq

Pair = tuple[Hashable, Any]


@dataclass(frozen=True)
class Job:
    """What to compute. map, combine and reduce must be module-level functions."""

    columns: list[str]  # all map reads: a columnar file lets it skip the rest
    filters: list[tuple] | None  # rows map never sees, e.g. [("state", "==", "completed")]
    map: Callable[[tuple], Iterable[Pair]]
    reduce: Callable[[Hashable, list], Any]
    combine: Callable[[Hashable, list], Any] | None = None


def partition_of(key: Hashable, reducers: int) -> int:
    """The reduce task a key goes to: the same in every process, on every machine.

    Not hash(key): Python salts the hash of a string with a random number
    chosen when the process starts, so two processes would send the same
    key to different reduce tasks.
    """
    return zlib.crc32(repr(key).encode()) % reducers


def splits_of(files: list[Path], splits: int) -> list[list[Path]]:
    """Cut the input into about `splits` runs of consecutive files of similar total size."""
    total = sum(f.stat().st_size for f in files)
    target, out, current, size = total / splits, [], [], 0
    for f in files:
        current.append(f)
        size += f.stat().st_size
        if size >= target * (len(out) + 1) and len(out) < splits - 1:
            out.append(current)
            current = []
    if current:
        out.append(current)
    return out


# Faults to inject, for experiments: (phase, task, attempt) -> seconds to
# stall before starting, or float("inf") to crash instead.
Faults = dict[tuple[str, int, int], float]


@dataclass
class TaskStats:
    phase: str
    task: int
    attempt: int
    seconds: float
    records_in: int
    pairs_out: int
    bytes_out: int


@dataclass
class Result:
    output: dict
    stats: list[TaskStats] = field(default_factory=list)
    attempts: dict[str, int] = field(default_factory=dict)  # launched, per phase
    failures: int = 0
    backups: int = 0
    seconds: dict[str, float] = field(default_factory=dict)  # wall time, per phase


def run(
    job: str,
    files: list[Path],
    workdir: Path,
    *,
    workers: int,
    reducers: int,
    splits: int | None = None,
    combine: bool = True,
    speculate: bool = True,
    max_attempts: int = 3,
    faults: Faults | None = None,
) -> Result:
    """Run the job named in lab.bigjobs.JOBS over files, using workers processes at once."""
    if workdir.exists():
        shutil.rmtree(workdir)
    workdir.mkdir(parents=True)
    plan = splits_of(sorted(files), splits or 4 * workers)
    common = {"job": job, "workdir": str(workdir), "reducers": reducers, "combine": combine}
    result = Result(output={})
    map_specs = [common | {"files": [str(f) for f in split]} for split in plan]
    _phase("map", map_specs, workers, speculate, max_attempts, faults or {}, result)
    reduce_specs = [common | {"maps": len(plan)} for _ in range(reducers)]
    _phase("reduce", reduce_specs, workers, speculate, max_attempts, faults or {}, result)
    for r in range(reducers):
        with open(workdir / f"reduce-{r:04d}" / "output.pkl", "rb") as f:
            result.output.update(pickle.load(f))
    return result


def _phase(phase, specs, workers, speculate, max_attempts, faults, result: Result) -> None:
    ctx = multiprocessing.get_context("forkserver")
    ctx.set_forkserver_preload(["lab.mapreduce", "lab.bigjobs"])
    pending = deque(range(len(specs)))
    running: dict[
        int, tuple[int, int, Any, float]
    ] = {}  # sentinel -> task, attempt, process, start
    attempts: dict[int, int] = defaultdict(int)
    done: dict[int, float] = {}  # task -> seconds its winning attempt took
    began = time.monotonic()
    result.attempts[phase] = 0

    def launch(task: int) -> None:
        attempt = attempts[task]
        attempts[task] += 1
        result.attempts[phase] += 1
        fault = faults.get((phase, task, attempt), 0.0)
        p = ctx.Process(target=_attempt, args=(phase, specs[task], task, attempt, fault))
        p.start()
        running[p.sentinel] = (task, attempt, p, time.monotonic())

    while len(done) < len(specs):
        while pending and len(running) < workers:
            task = pending.popleft()
            if task not in done:
                launch(task)
        if speculate and not pending and len(running) < workers and done:
            # Every task has started and a worker is free: back up the
            # slowest straggler, if it has run far longer than tasks do.
            typical = statistics.median(done.values())
            now = time.monotonic()
            copies = defaultdict(int)
            for task, *_ in running.values():
                copies[task] += 1
            stragglers = [
                (now - start, task)
                for task, _, _, start in running.values()
                if copies[task] == 1 and now - start > max(2 * typical, 1.0)
            ]
            if stragglers:
                result.backups += 1
                launch(max(stragglers)[1])
        for sentinel in wait(list(running), timeout=0.05):
            task, attempt, p, start = running.pop(sentinel)
            p.join()
            committed = _committed(phase, specs[task], task)
            if p.exitcode == 0 and task not in done and committed.exists():
                done[task] = time.monotonic() - start
                stats = json.loads((committed / "stats.json").read_text())
                result.stats.append(TaskStats(phase, task, attempt, done[task], **stats))
                _cancel(task, running)  # the race is won: stop the other copy
            elif p.exitcode != 0 and task not in done:
                result.failures += 1
                if attempts[task] >= max_attempts:
                    raise RuntimeError(f"{phase} task {task} failed {max_attempts} times")
                pending.appendleft(task)
    result.seconds[phase] = time.monotonic() - began


def _cancel(task: int, running: dict) -> None:
    for sentinel, (t, _, p, _) in list(running.items()):
        if t == task:
            p.terminate()
            p.join()
            del running[sentinel]


def _committed(phase: str, spec: dict, task: int) -> Path:
    return Path(spec["workdir"]) / f"{phase}-{task:04d}"


def _attempt(phase: str, spec: dict, task: int, attempt: int, fault: float) -> None:
    """One attempt at one task, in its own process. Commits by renaming its directory."""
    from lab.bigjobs import JOBS

    if fault == float("inf"):
        raise SystemExit(f"{phase} task {task} attempt {attempt}: injected crash")
    time.sleep(fault)  # a slow machine
    job = JOBS[spec["job"]]
    final = _committed(phase, spec, task)
    tmp = final.with_name(f"{final.name}.a{attempt}.tmp")
    tmp.mkdir()
    if phase == "map":
        stats = _map(job, spec, tmp)
    else:
        stats = _reduce(job, spec, task, tmp)
    (tmp / "stats.json").write_text(json.dumps(stats))
    try:
        os.rename(tmp, final)  # atomic; fails if another attempt got there first
    except OSError:
        shutil.rmtree(tmp)


def _map(job: Job, spec: dict, out: Path) -> dict:
    reducers = spec["reducers"]
    buckets: list[dict[Hashable, list]] = [defaultdict(list) for _ in range(reducers)]
    records = pairs = 0
    for path in spec["files"]:
        table = pq.read_table(path, columns=job.columns, filters=job.filters)
        records += table.num_rows
        # Times as integers (microseconds since 1970): Python datetimes are slow.
        cols = [
            pc.cast(c, pa.int64()) if pa.types.is_timestamp(c.type) else c
            for c in table.itercolumns()
        ]
        for row in zip(*(c.to_pylist() for c in cols), strict=True):
            for key, value in job.map(row):
                buckets[partition_of(key, reducers)][key].append(value)
    written = 0
    for r, groups in enumerate(buckets):
        if spec["combine"] and job.combine:
            out_pairs = [(k, job.combine(k, vs)) for k, vs in groups.items()]
        else:
            out_pairs = [(k, v) for k, vs in groups.items() for v in vs]
        pairs += len(out_pairs)
        if out_pairs:
            path = out / f"part-{r:04d}.pkl"
            with open(path, "wb") as f:
                pickle.dump(out_pairs, f, protocol=pickle.HIGHEST_PROTOCOL)
            written += path.stat().st_size
    return {"records_in": records, "pairs_out": pairs, "bytes_out": written}


def _reduce(job: Job, spec: dict, r: int, out: Path) -> dict:
    groups: dict[Hashable, list] = defaultdict(list)
    pairs = 0
    work = Path(spec["workdir"])
    for m in range(spec["maps"]):
        path = work / f"map-{m:04d}" / f"part-{r:04d}.pkl"
        if path.exists():
            with open(path, "rb") as f:
                for key, value in pickle.load(f):
                    groups[key].append(value)
                    pairs += 1
    output = {key: job.reduce(key, values) for key, values in groups.items()}
    path = out / "output.pkl"
    with open(path, "wb") as f:
        pickle.dump(output, f)
    return {"records_in": pairs, "pairs_out": len(output), "bytes_out": path.stat().st_size}


def summary(result: Result) -> str:
    """Per phase: tasks, attempts, how long tasks took, and what went in and out."""
    from lab.warehouse import table

    names = "phase tasks attempts task_p50_s task_max_s in in_max out out_MB wall_s".split()
    rows = []
    for phase in ("map", "reduce"):
        stats = [s for s in result.stats if s.phase == phase]
        secs = [s.seconds for s in stats]
        ins = [s.records_in for s in stats]
        out = sum(s.pairs_out for s in stats)
        size = sum(s.bytes_out for s in stats) / 1e6
        rows.append([phase, len(stats), result.attempts[phase], statistics.median(secs), max(secs)])
        rows[-1] += [sum(ins), max(ins), out, size, result.seconds[phase]]
    text = table(names, rows)
    return text + f"\nfailed attempts {result.failures}, backup attempts {result.backups}"
~~~

It's long, but each part is one idea:

- `Job` says what to compute, and which columns map needs: a Parquet file lets a map task read the few columns it uses (four of fourteen, for the mean, and the one its filter tests) and never touch the rest. `filters` drops the rows map shouldn't see before it sees them. (Parquet keeps each column's minimum and maximum per row group, so a filter can skip whole groups; here every group has every state, so none can be skipped.)
- `partition_of` is the shuffle's routing: CRC-32 of the key's text, the same in every process. Its docstring is the bug it prevents.
- `run` plans the splits, runs the map phase, then the reduce phase, then gathers each reducer's output. The reduce phase starts only when every map task has finished: a reducer needs its pairs from *every* map task, and any one could still add one.
- `_phase` is the scheduler. It keeps up to `workers` attempts running, each a separate process standing in for a machine. A crashed attempt (non-zero exit) puts its task back in the queue, up to `max_attempts`. When every task has started and a worker is free, it launches a backup of the slowest task, if that task has run more than twice as long as tasks usually take. The first attempt to commit wins, and the other is stopped.
- `_attempt` writes into `NAME.aN.tmp/` and renames it to `NAME/`. If another attempt got there first, the rename fails and this one throws its work away. This is why running a task twice is safe.
- `_map` reads its files, calls `job.map` on each row, routes each pair to a bucket per reducer, applies the combiner to each bucket, and writes one file per reducer: that file is this map task's share of the shuffle. `_reduce` reads its file from every map task, groups by key, and reduces.

Real MapReduce sorts each map task's output by key and merges sorted runs in the reducer, so a reducer needn't hold every group in memory at once. This one groups in a dictionary, which is simpler and fine while a reducer's input fits in memory.

### Three questions

Create `lab/src/lab/bigjobs.py`:

<!-- file: lab/src/lab/bigjobs.py -->
~~~python
"""Three questions about a month of jobs, each as a MapReduce job and as SQL.

Times arrive in map as microseconds since 1970 (see mapreduce._map).
"""

import math
from collections import Counter

import numpy as np

from lab.mapreduce import Job

COMPLETED = [("state", "==", "completed")]


# 1. How many jobs, and how long they ran on average, per tenant and kind.
# A mean is a sum and a count, and sums add up in any order and grouping:
# a combiner can shrink each map task's pairs to one per key.


def mean_map(row):
    tenant, kind, started, finished = row
    yield (tenant, kind), (1, (finished - started) / 1e6)


def mean_combine(key, values):
    return (sum(n for n, _ in values), sum(s for _, s in values))


def mean_reduce(key, values):
    jobs, seconds = mean_combine(key, values)
    return {"jobs": jobs, "mean_run_s": seconds / jobs}


# 2. Each tenant's median and 99th-percentile run time, exactly. A
# percentile isn't made of parts that add up: the reducer needs every
# value. There is no combiner, and a tenant with a fifth of the jobs puts
# a fifth of the month on one reduce task.


def runs_map(row):
    tenant, started, finished = row
    yield tenant, (finished - started) / 1e6


def quantiles_reduce(key, values):
    p50, p99 = np.quantile(np.asarray(values), [0.5, 0.99])
    return {"jobs": len(values), "p50_s": float(p50), "p99_s": float(p99)}


# 3. The same percentiles, approximately, from histograms that do add up.
# Bucket i holds the values between GAMMA**(i-1) and GAMMA**i. Report a
# bucket's midpoint and the answer is within ALPHA of the true value,
# relative to it, whatever the data (the idea of DDSketch, Masson et al.,
# 2019). Histograms merge by adding counts, so a combiner can merge each
# map task's into one per tenant: a few hundred buckets cross the shuffle,
# not millions of values.

ALPHA = 0.01
GAMMA = (1 + ALPHA) / (1 - ALPHA)


def bucket_of(seconds: float) -> int:
    return math.ceil(math.log(max(seconds, 1e-6), GAMMA))


def value_of(bucket: int) -> float:
    """The bucket's estimate: within ALPHA of every value in it, relative to that value."""
    return 2 * GAMMA**bucket / (GAMMA + 1)


def histogram_map(row):
    tenant, started, finished = row
    yield tenant, {bucket_of((finished - started) / 1e6): 1}


def histogram_combine(key, values):
    merged = Counter()
    for histogram in values:
        merged.update(histogram)
    return dict(merged)


def histogram_quantile(histogram: dict[int, int], q: float) -> float:
    """The value of rank q * (n - 1), rounded down, to within ALPHA."""
    total = sum(histogram.values())
    rank, seen = q * (total - 1), 0
    for bucket in sorted(histogram):
        seen += histogram[bucket]
        if seen > rank:
            return value_of(bucket)
    raise ValueError("empty histogram")


def histogram_reduce(key, values):
    merged = histogram_combine(key, values)
    return {
        "jobs": sum(merged.values()),
        "p50_s": histogram_quantile(merged, 0.5),
        "p99_s": histogram_quantile(merged, 0.99),
    }


RUN = ["tenant", "started_at", "finished_at"]

JOBS = {
    "mean": Job(
        ["tenant", "kind", "started_at", "finished_at"],
        COMPLETED,
        mean_map,
        mean_reduce,
        mean_combine,
    ),
    "quantiles": Job(RUN, COMPLETED, runs_map, quantiles_reduce),
    "quantiles-approx": Job(RUN, COMPLETED, histogram_map, histogram_reduce, histogram_combine),
}

# The same questions in SQL, over the same files. {files} is the glob.
# Run time from whole microseconds, as map gets it: epoch(finished_at -
# started_at) gives the same answer, but makes an INTERVAL through the time
# zone code for every row: on a month of events, the mean took 9 times as
# long that way (39 s against 4.4 s, on one thread).
RUN_S = "(epoch_us(finished_at) - epoch_us(started_at)) / 1e6"
SQL = {
    "mean": f"""SELECT tenant, kind, count(*) AS jobs, avg({RUN_S}) AS mean_run_s
                FROM read_parquet('{{files}}') WHERE state = 'completed' GROUP BY ALL""",
    "quantiles": f"""SELECT tenant, count(*) AS jobs, quantile_cont({RUN_S}, 0.5) AS p50_s,
                            quantile_cont({RUN_S}, 0.99) AS p99_s
                     FROM read_parquet('{{files}}') WHERE state = 'completed' GROUP BY ALL""",
}
SQL["quantiles-approx"] = SQL["quantiles"]
~~~

The three jobs ask two questions. "How many jobs, and their mean run time, per tenant and kind" is algebraic, so it has a combiner. "Each tenant's median and p99 run time" is holistic, and asked twice: exactly, where the reducer must see every value, and approximately, from histograms that merge. `SQL` is the same questions for DuckDB, to check the answers and to race.

The histogram's guarantee is worth checking by hand. Bucket i holds values in (γ^(i-1), γ^i], with γ = (1+α)/(1-α). Its estimate, 2γ^i/(γ+1), is off by (γ-1)/(γ+1) = α at both edges, relative to the value there, and by less inside. So a p99 from it is within 1% of the true one, whatever the distribution, from a few hundred buckets.

### Tests

The tests use a small month (20,000 jobs over two days, from stand-in real jobs) and check every answer against DuckDB's. Create `lab/tests/test_bigdata.py`:

<!-- file: lab/tests/test_bigdata.py -->
~~~python
import os
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

import duckdb
import numpy as np
import pyarrow.parquet as pq
import pytest

from lab import bigjobs, cost, mapreduce, synth
from lab.pipeline import SCHEMA

# Stand-ins for the pipeline's jobs: three kinds, sizes and times spread out.
REAL = {
    "kind": np.array(["checksum", "compress", "sort"] * 20),
    "size": np.arange(60) * 1000 + 1,
    "wait_s": np.linspace(0.01, 0.2, 60),
    "run_s": np.geomspace(0.005, 3.0, 60),
}
SPEC = synth.Spec(jobs=20_000, days=2, tenants=20, skew=1.1, seed=7)


@pytest.fixture(scope="module")
def month(tmp_path_factory) -> Path:
    out = tmp_path_factory.mktemp("synth")
    synth.make(REAL, out, SPEC)
    return out


def duck(month: Path, sql: str):
    con = duckdb.connect()
    con.execute("SET TimeZone = 'UTC'")
    return con.execute(sql.format(files=month / "events/**/*.parquet")).fetchall()


def test_synth_writes_three_events_a_job_in_the_pipelines_schema(month):
    files = sorted(month.glob("events/**/*.parquet"))
    assert pq.read_schema(files[0]).remove_metadata() == SCHEMA
    counts = duck(month, "SELECT state, count(*) FROM '{files}' GROUP BY 1 ORDER BY 1")
    assert counts == [("completed", 20_000), ("queued", 20_000), ("running", 20_000)]


def test_each_file_holds_only_its_own_hour(month):
    for f in sorted(month.glob("events/**/*.parquet"))[:30]:
        date, hour = f.parent.parent.name[5:], int(f.parent.name[5:])
        times = pq.read_table(f, columns=["occurred_at"])["occurred_at"].to_pylist()
        assert {(t.strftime("%Y-%m-%d"), t.hour) for t in times} == {(date, hour)}


def test_tenants_follow_the_zipf_law(month):
    rows = duck(month, "SELECT tenant, count(*) FROM '{files}' WHERE state = 'queued' GROUP BY 1")
    share = dict(rows)["t0001"] / SPEC.jobs
    assert share == pytest.approx(synth.tenant_shares(20, 1.1)[0], rel=0.05)


def test_the_same_seed_makes_the_same_month(month, tmp_path):
    synth.make(REAL, tmp_path, SPEC)
    a = duck(month, "SELECT sum(hash(event_id, occurred_at, tenant, size)) FROM '{files}'")
    b = duck(tmp_path, "SELECT sum(hash(event_id, occurred_at, tenant, size)) FROM '{files}'")
    assert a == b


def test_splits_cover_every_file_once_in_order(month):
    files = sorted(month.glob("events/**/*.parquet"))
    splits = mapreduce.splits_of(files, 7)
    assert len(splits) <= 7 and [f for s in splits for f in s] == files


def test_a_key_goes_to_the_same_reducer_in_every_process():
    code = "from lab.mapreduce import partition_of; print(partition_of(('t0001', 'sort'), 16))"
    seen = set()
    for seed in ("1", "2", "3"):
        env = os.environ | {"PYTHONHASHSEED": seed}  # each process salts hash() differently
        out = subprocess.run([sys.executable, "-c", code], env=env, capture_output=True, text=True)
        seen.add(out.stdout.strip())
    assert len(seen) == 1, f"one key, several reducers: {seen}"


def mr(month, job, tmp_path, **options):
    files = sorted(month.glob("events/**/*.parquet"))
    return mapreduce.run(job, files, tmp_path / "work", workers=4, reducers=3, **options)


def test_mapreduce_means_match_sql(month, tmp_path):
    result = mr(month, "mean", tmp_path)
    want = {(t, k): (n, m) for t, k, n, m in duck(month, bigjobs.SQL["mean"])}
    got = {key: (v["jobs"], v["mean_run_s"]) for key, v in result.output.items()}
    assert got.keys() == want.keys()
    for key, (n, m) in want.items():
        assert got[key][0] == n and got[key][1] == pytest.approx(m, rel=1e-9)


def test_the_combiner_changes_what_crosses_the_shuffle_not_the_answer(month, tmp_path):
    combined = mr(month, "mean", tmp_path)
    raw = mr(month, "mean", tmp_path, combine=False)
    assert combined.output.keys() == raw.output.keys()
    for key, value in raw.output.items():
        assert combined.output[key]["jobs"] == value["jobs"]
        assert combined.output[key]["mean_run_s"] == pytest.approx(value["mean_run_s"])
    shuffled = [sum(s.pairs_out for s in r.stats if s.phase == "map") for r in (combined, raw)]
    assert shuffled[1] == 20_000 and shuffled[0] < shuffled[1] / 10


def test_exact_quantiles_match_sql(month, tmp_path):
    result = mr(month, "quantiles", tmp_path)
    for tenant, n, p50, p99 in duck(month, bigjobs.SQL["quantiles"]):
        got = result.output[tenant]
        assert got["jobs"] == n
        assert (got["p50_s"], got["p99_s"]) == pytest.approx((p50, p99), rel=1e-9)


def test_approximate_quantiles_are_within_alpha(month, tmp_path):
    result = mr(month, "quantiles-approx", tmp_path)
    sql = "SELECT tenant, list(epoch(finished_at - started_at)) FROM '{files}' "
    for tenant, runs in duck(month, sql + "WHERE state = 'completed' GROUP BY 1"):
        for q, name in ((0.5, "p50_s"), (0.99, "p99_s")):
            exact = np.quantile(runs, q, method="lower")
            assert result.output[tenant][name] == pytest.approx(exact, rel=bigjobs.ALPHA)


def test_every_value_is_within_alpha_of_its_buckets_estimate():
    values = np.random.default_rng(1).lognormal(-3, 2, 10_000)
    for v in values:
        estimate = bigjobs.value_of(bigjobs.bucket_of(v))
        assert abs(estimate - v) <= bigjobs.ALPHA * v * (1 + 1e-9)


def test_a_crashed_task_is_run_again(month, tmp_path):
    result = mr(month, "mean", tmp_path, faults={("map", 1, 0): float("inf")})
    assert result.failures == 1
    assert result.attempts["map"] == len([s for s in result.stats if s.phase == "map"]) + 1
    assert result.output == mr(month, "mean", tmp_path).output


def test_a_crashed_reduce_task_is_run_again(month, tmp_path):
    result = mr(month, "mean", tmp_path, faults={("reduce", 0, 0): float("inf")})
    assert result.failures == 1 and result.output == mr(month, "mean", tmp_path).output


def test_a_task_that_keeps_crashing_fails_the_job(month, tmp_path):
    faults = {("map", 0, a): float("inf") for a in range(3)}
    with pytest.raises(RuntimeError, match="map task 0 failed 3 times"):
        mr(month, "mean", tmp_path, faults=faults)


def test_a_backup_copy_overtakes_a_straggler(month, tmp_path):
    start = time.monotonic()
    result = mr(month, "mean", tmp_path, faults={("map", 0, 0): 60.0})
    assert time.monotonic() - start < 20, "waited for the straggler"
    assert result.backups >= 1
    winner = next(s for s in result.stats if s.phase == "map" and s.task == 0)
    assert winner.attempt == 1, "the backup should have won"
    assert result.output == mr(month, "mean", tmp_path).output


def test_cost_reports_the_first_width_that_beats_one_thread(tmp_path):
    runs = tmp_path / "cost.jsonl"
    lines = [("duckdb", 1, 2.0), ("duckdb", 4, 0.6), ("mapreduce", 1, 30), ("mapreduce", 4, 9)]
    lines += [("spark", 1, 5.0), ("spark", 4, 1.5)]
    runs.write_text(
        "".join(
            f'{{"system": "{s}", "workers": {w}, "repeat": 0, "seconds": {t}}}\n'
            for s, w, t in lines
        )
    )
    text = cost.report(runs)
    assert "mapreduce: none up to 4" in text and "spark: 4 workers" in text


def test_synth_starts_where_the_spec_says(month):
    first = duck(month, "SELECT min(occurred_at) FROM '{files}'")[0][0]
    assert first.astimezone(UTC) >= datetime(2026, 9, 1, tzinfo=UTC)
~~~

`test_a_key_goes_to_the_same_reducer_in_every_process` starts three Python processes with different `PYTHONHASHSEED` values, as three machines would have, and asks each where one key goes. `test_a_backup_copy_overtakes_a_straggler` stalls map task 0's first attempt for a minute and requires the job to finish in 20 seconds anyway.

### Spark, and the race

Spark is an optional extra: half a gigabyte, not needed by anything else. In `lab/pyproject.toml`:

Change:

<!-- edit: lab/pyproject.toml -->
~~~toml

[dependency-groups]
~~~

to:

~~~toml

[project.optional-dependencies]
spark = [
    "pyspark>=4.2.0",
]

[dependency-groups]
~~~


Create `lab/src/lab/sparkjobs.py`:

<!-- file: lab/src/lab/sparkjobs.py -->
~~~python
"""The same three questions in Spark, on this machine (local mode: one JVM, N threads).

Install it with the project's spark extra: uv sync --extra spark (it needs
Java 17 or later).
"""

import os


def session(workers: int):
    """A Spark session with `workers` threads. The JVM starts with the first one."""
    os.environ.setdefault("SPARK_LOCAL_IP", "127.0.0.1")
    from pyspark.sql import SparkSession

    spark = (
        SparkSession.builder.master(f"local[{workers}]")
        .appName("lab")
        .config("spark.driver.memory", "2g")
        .config("spark.sql.session.timeZone", "UTC")
        .config("spark.ui.showConsoleProgress", "false")
        .getOrCreate()
    )
    spark.sparkContext.setLogLevel("ERROR")
    return spark


def query(spark, job: str, data: str):
    """The DataFrame that answers job over the events under data. Collecting it runs it."""
    from pyspark.sql import functions as F

    run_s = (F.unix_micros("finished_at") - F.unix_micros("started_at")) / 1e6
    done = spark.read.parquet(data).where(F.col("state") == "completed").withColumn("run_s", run_s)
    if job == "mean":
        return done.groupBy("tenant", "kind").agg(
            F.count("*").alias("jobs"), F.avg("run_s").alias("mean_run_s")
        )
    if job == "quantiles":
        return done.groupBy("tenant").agg(
            F.count("*").alias("jobs"),
            F.percentile("run_s", 0.5).alias("p50_s"),
            F.percentile("run_s", 0.99).alias("p99_s"),
        )
    if job == "quantiles-approx":
        # Greenwald and Khanna's summary: rank error at most 1/accuracy.
        return done.groupBy("tenant").agg(
            F.count("*").alias("jobs"),
            F.percentile_approx("run_s", 0.5, 10_000).alias("p50_s"),
            F.percentile_approx("run_s", 0.99, 10_000).alias("p99_s"),
        )
    raise ValueError(f"no such job: {job}")
~~~

Spark's DataFrames are a plan, not a result: `query` builds one, and nothing reads a file until it's collected. Then the race. Create `lab/src/lab/cost.py`:

<!-- file: lab/src/lab/cost.py -->
~~~python
"""The same question three ways, at several degrees of parallelism: what does scaling out buy?

McSherry, Isard and Murray, "Scalability! But at what COST?" (HotOS 2015):
a system's COST is the number of cores it needs before it beats a
competent single-threaded program. A system that scales well from a slow
start can need dozens, or never get there.
"""

import json
import statistics
import time
from pathlib import Path

import duckdb

from lab import bigjobs, mapreduce


def files_of(data: Path) -> list[Path]:
    files = sorted(data.glob("events/**/*.parquet"))
    if not files:
        raise FileNotFoundError(f"no events under {data}")
    return files


def run_mapreduce(job: str, data: Path, workers: int, **options) -> tuple[dict, float, object]:
    work = data.parent / f"{data.name}-mr"  # beside the data, so on the same disk
    start = time.monotonic()
    result = mapreduce.run(job, files_of(data), work, workers=workers, reducers=workers, **options)
    return result.output, time.monotonic() - start, result


def run_duckdb(job: str, data: Path, threads: int) -> tuple[list, float]:
    con = duckdb.connect()
    con.execute(f"SET threads = {threads}")
    con.execute("SET TimeZone = 'UTC'")
    sql = bigjobs.SQL[job].format(files=data / "events" / "**" / "*.parquet")
    start = time.monotonic()
    rows = con.execute(sql).fetchall()
    return rows, time.monotonic() - start


def run_spark(spark, job: str, data: Path) -> tuple[list, float]:
    from lab import sparkjobs

    frame = sparkjobs.query(spark, job, str(data / "events"))
    start = time.monotonic()
    rows = frame.collect()
    return rows, time.monotonic() - start


def grid(job: str, data: Path, workers: list[int], repeats: int, out: Path, spark: bool) -> None:
    """Time every system at every width, interleaved, writing one JSON line per run."""
    if out.exists():
        raise FileExistsError(f"{out} exists: choose another name")
    with out.open("w") as f:
        for w in workers:
            session = None
            if spark:
                from lab import sparkjobs

                start = time.monotonic()
                session = sparkjobs.session(w)
                started = time.monotonic() - start
                _, warm = run_spark(session, job, data)  # the first query also compiles
                print(f"spark local[{w}]: started in {started:.1f} s, first query {warm:.1f} s")
            systems = ["mapreduce", "duckdb"] + (["spark"] if session else [])
            for r in range(repeats):
                for system in systems:
                    seconds = _time(system, job, data, w, session)
                    line = {"system": system, "workers": w, "repeat": r, "seconds": seconds}
                    f.write(json.dumps(line) + "\n")
                    f.flush()
                    print(f"{system:>9} {w:>2} workers: {seconds:7.2f} s")
            if session:
                session.stop()


def _time(system: str, job: str, data: Path, workers: int, session) -> float:
    if system == "mapreduce":
        return run_mapreduce(job, data, workers)[1]
    if system == "duckdb":
        return run_duckdb(job, data, workers)[1]
    return run_spark(session, job, data)[1]


def report(path: Path) -> str:
    """Median seconds per system and width, and each system's COST against DuckDB on one thread."""
    runs = [json.loads(line) for line in path.read_text().splitlines()]
    times: dict[tuple[str, int], list[float]] = {}
    for run in runs:
        times.setdefault((run["system"], run["workers"]), []).append(run["seconds"])
    medians = {k: statistics.median(v) for k, v in times.items()}
    systems = sorted({s for s, _ in medians})
    widths = sorted({w for _, w in medians})
    baseline = medians[("duckdb", 1)]
    lines = ["workers  " + "  ".join(f"{s:>9}" for s in systems)]
    for w in widths:
        cells = [f"{medians[(s, w)]:9.2f}" if (s, w) in medians else " " * 9 for s in systems]
        lines.append(f"{w:>7}  " + "  ".join(cells))
    lines.append(f"\nCOST, against DuckDB on 1 thread ({baseline:.2f} s):")
    for s in systems:
        beats = [w for w in widths if (s, w) in medians and medians[(s, w)] < baseline]
        lines.append(
            f"  {s:>9}: " + (f"{beats[0]} workers" if beats else f"none up to {widths[-1]}")
        )
    return "\n".join(lines)


def plot(path: Path, png: Path) -> None:
    from matplotlib.figure import Figure

    runs = [json.loads(line) for line in path.read_text().splitlines()]
    fig = Figure(figsize=(7, 4.5))
    ax = fig.subplots()
    for system in sorted({r["system"] for r in runs}):
        widths = sorted({r["workers"] for r in runs if r["system"] == system})
        meds = [
            statistics.median(
                r["seconds"] for r in runs if r["system"] == system and r["workers"] == w
            )
            for w in widths
        ]
        ax.plot(widths, meds, marker="o", label=system)
    one = statistics.median(
        r["seconds"] for r in runs if r["system"] == "duckdb" and r["workers"] == 1
    )
    ax.axhline(one, color="grey", linestyle="--", label="DuckDB, 1 thread")
    ax.set(xscale="log", yscale="log", xlabel="workers (processes or threads)", ylabel="seconds")
    ax.set_xticks(sorted({r["workers"] for r in runs}), labels=sorted({r["workers"] for r in runs}))
    ax.legend()
    ax.grid(True, which="both", alpha=0.3)
    fig.savefig(png, dpi=120, bbox_inches="tight")
~~~

`grid` runs every system at every width, in turn, `repeats` times: interleaved, so whatever the machine does during the run falls on all of them. Spark starts once per width (`local[N]` is fixed when the JVM's context starts), and its first query is run and reported but not counted: it includes compiling the query, which a long-running Spark application pays once.

Add the commands, and a plain table for any rows, in `lab/src/lab/warehouse.py`:

Change:

<!-- edit: lab/src/lab/warehouse.py -->
~~~python
    names = [d[0] for d in cursor.description]
    rows = cursor.fetchall()
~~~

to:

~~~python
    return table([d[0] for d in cursor.description], cursor.fetchall(), max_rows)


def table(names: list[str], rows: list, max_rows: int = 40) -> str:
    """Rows as a plain table, right-aligned, under their column names."""
~~~


In `lab/src/lab/cli.py`:

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

def cmd_simulate(args: argparse.Namespace) -> int:
~~~

to:

~~~python

def cmd_synth(args: argparse.Namespace) -> int:
    from lab import synth

    spec = synth.Spec(jobs=args.jobs, tenants=args.tenants, skew=args.skew, seed=args.seed)
    events = synth.make(synth.real_jobs(args.source), args.out, spec)
    print(f"{events:,} events from {args.jobs:,} jobs: {synth.describe(args.out)}")
    return 0


def top(names: list[str], rows: list, n: int) -> str:
    """The n rows with the most jobs (ties by the rest), for comparing systems' answers."""
    from lab.warehouse import table

    i = names.index("jobs")
    best = sorted(rows, key=lambda r: (-r[i], *r[:i]))[:n]
    return table(names, best) + f"\n({len(rows)} rows)"


def parse_faults(slow: list[str], crash: list[str]) -> dict:
    """--slow map:3=20 stalls map task 3's first attempt 20 s; --crash reduce:0 crashes it."""
    faults = {}
    for spec in slow:
        where, seconds = spec.split("=")
        phase, task = where.split(":")
        faults[(phase, int(task), 0)] = float(seconds)
    for where in crash:
        phase, task = where.split(":")
        faults[(phase, int(task), 0)] = float("inf")
    return faults


def cmd_mr(args: argparse.Namespace) -> int:
    from lab import cost, mapreduce

    output, seconds, result = cost.run_mapreduce(
        args.job,
        args.data,
        args.workers,
        combine=not args.no_combine,
        speculate=not args.no_speculate,
        faults=parse_faults(args.slow, args.crash),
    )
    keys = ["tenant", "kind"] if args.job == "mean" else ["tenant"]
    values = list(next(iter(output.values())))
    rows = [[*(k if isinstance(k, tuple) else (k,)), *v.values()] for k, v in output.items()]
    print(top(keys + values, rows, args.top))
    print(f"\n{mapreduce.summary(result)}\ntotal {seconds:.2f} s")
    return 0


def cmd_duck(args: argparse.Namespace) -> int:
    from lab import cost

    rows, seconds = cost.run_duckdb(args.job, args.data, args.threads)
    names = ["tenant", "kind", "jobs", "mean_run_s"] if args.job == "mean" else None
    names = names or ["tenant", "jobs", "p50_s", "p99_s"]
    print(top(names, [list(r) for r in rows], args.top))
    print(f"\n{seconds:.2f} s on {args.threads} thread{'s' * (args.threads != 1)}")
    return 0


def cmd_spark(args: argparse.Namespace) -> int:
    import time

    from lab import cost, sparkjobs

    start = time.monotonic()
    spark = sparkjobs.session(args.workers)
    print(f"Spark started in {time.monotonic() - start:.1f} s")
    try:
        if args.explain:
            sparkjobs.query(spark, args.job, str(args.data / "events")).explain()
        for attempt in range(args.repeats):
            rows, seconds = cost.run_spark(spark, args.job, args.data)
            print(f"query {attempt + 1}: {seconds:.2f} s")
        names = list(rows[0].asDict())
        print(top(names, [list(r) for r in rows], args.top))
    finally:
        spark.stop()
    return 0


def cmd_cost(args: argparse.Namespace) -> int:
    from lab import cost

    if not args.report_only:
        widths = [int(w) for w in args.workers.split(",")]
        cost.grid(args.job, args.data, widths, args.repeats, args.out, spark=not args.no_spark)
    print(cost.report(args.out))
    if args.plot:
        cost.plot(args.out, args.plot)
        print(f"\nplot: {args.plot}")
    return 0


def cmd_simulate(args: argparse.Namespace) -> int:
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

    simulate = sub.add_parser(
~~~

to:

~~~python

    syn = sub.add_parser("synth", help="make a month of job events, shaped like the pipeline's")
    syn.add_argument("--jobs", type=int, default=16_000_000)
    syn.add_argument("--tenants", type=int, default=200)
    syn.add_argument("--skew", type=float, default=1.1, help="the Zipf exponent of tenant sizes")
    syn.add_argument("--seed", type=int, default=1)
    syn.add_argument("--source", type=Path, default=Path("data"), help="real events to draw from")
    syn.add_argument("--out", type=Path, default=Path("data-big"))
    syn.set_defaults(func=cmd_synth)

    jobs_ = ["mean", "quantiles", "quantiles-approx"]
    mr = sub.add_parser("mr", help="answer a question with MapReduce, written from scratch")
    mr.add_argument("job", choices=jobs_)
    mr.add_argument("--data", type=Path, default=Path("data-big"))
    mr.add_argument("--workers", type=int, default=16, help="processes at once; also reducers")
    mr.add_argument("--no-combine", action="store_true")
    mr.add_argument("--no-speculate", action="store_true", help="no backup copies of stragglers")
    mr.add_argument("--slow", action="append", default=[], metavar="PHASE:TASK=SECONDS")
    mr.add_argument("--crash", action="append", default=[], metavar="PHASE:TASK")
    mr.add_argument("--top", type=int, default=5)
    mr.set_defaults(func=cmd_mr)

    duck = sub.add_parser("duck", help="answer a question with DuckDB")
    duck.add_argument("job", choices=jobs_)
    duck.add_argument("--data", type=Path, default=Path("data-big"))
    duck.add_argument("--threads", type=int, default=16)
    duck.add_argument("--top", type=int, default=5)
    duck.set_defaults(func=cmd_duck)

    spark = sub.add_parser("spark", help="answer a question with Spark, locally")
    spark.add_argument("job", choices=jobs_)
    spark.add_argument("--data", type=Path, default=Path("data-big"))
    spark.add_argument("--workers", type=int, default=16, help="threads: local[N]")
    spark.add_argument("--repeats", type=int, default=3)
    spark.add_argument("--explain", action="store_true", help="print the physical plan first")
    spark.add_argument("--top", type=int, default=5)
    spark.set_defaults(func=cmd_spark)

    cst = sub.add_parser("cost", help="time each system at each width; report each one's COST")
    cst.add_argument("--job", choices=jobs_, default="mean")
    cst.add_argument("--data", type=Path, default=Path("data-big"))
    cst.add_argument("--workers", default="1,2,4,8,16")
    cst.add_argument("--repeats", type=int, default=3)
    cst.add_argument("--no-spark", action="store_true")
    cst.add_argument("--out", type=Path, default=Path("results/cost.jsonl"))
    cst.add_argument("--report-only", action="store_true", help="report an earlier run's --out")
    cst.add_argument("--plot", type=Path)
    cst.set_defaults(func=cmd_cost)

    simulate = sub.add_parser(
~~~


The month goes in `data-big/`, and the rebuilt and compacted copies beside it: keep them all out of Git and the image. In `.gitignore`:

Add this at the end of the file:

<!-- append: .gitignore -->
~~~text
# Step 4's synthetic month and its copies: big, and made by lab synth.
data-*/
~~~


In `.dockerignore`:

Change:

<!-- edit: .dockerignore -->
~~~text
data
bin
~~~

to:

~~~text
data
data-*
bin
~~~


<!-- run: cd lab && uv sync --extra spark && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

### Run it: one month, three ways

Make the month (from step 3's `data/`; about a minute and a half, and 2 GB):

~~~bash
time uv run --project lab lab synth
~~~

~~~text
48,000,000 events from 16,000,000 jobs: 742 files, 1944 MB

real	1m23.628s
user	1m15.028s
sys	0m10.747s
~~~

Ask the first question with DuckDB, on one thread and then all of them. Run the first once without looking: it loads the files into the page cache, and the comparison should be between systems, not between a cold disk and a warm one.

~~~bash
uv run --project lab lab duck mean --threads 1 > /dev/null
uv run --project lab lab duck mean --threads 1
uv run --project lab lab duck mean --threads 16
~~~

~~~text
tenant      kind     jobs  mean_run_s
------  --------  -------  ----------
 t0001  checksum  1811924       0.038
 t0001      sort   948226       0.088
 t0002  checksum   845251       0.038
 t0001  compress   644223       0.433
 t0003  checksum   542104       0.038
(600 rows)

2.31 s on 1 thread
~~~

~~~text
tenant      kind     jobs  mean_run_s
------  --------  -------  ----------
 t0001  checksum  1811924       0.038
 t0001      sort   948226       0.088
 t0002  checksum   845251       0.038
 t0001  compress   644223       0.433
 t0003  checksum   542104       0.038
(600 rows)

0.69 s on 16 threads
~~~

Sixteen million completed jobs, grouped and averaged in 2.3 seconds by one thread. Now your MapReduce, with 16 processes:

~~~bash
uv run --project lab lab mr mean
~~~

~~~text
tenant      kind     jobs  mean_run_s
------  --------  -------  ----------
 t0001  checksum  1811924       0.038
 t0001      sort   948226       0.088
 t0002  checksum   845251       0.038
 t0001  compress   644223       0.433
 t0003  checksum   542104       0.038
(600 rows)

 phase  tasks  attempts  task_p50_s  task_max_s        in  in_max    out  out_MB  wall_s
------  -----  --------  ----------  ----------  --------  ------  -----  ------  ------
   map     64        64       4.478       5.457  16000000  267512  38400   1.356  18.728
reduce     16        16       1.222       1.303     38400    3008    600   0.024   1.320
failed attempts 0, backup attempts 0
total 20.09 s
~~~

The same answer, to the last job, in 20 seconds. Read the summary. 64 map tasks read 16 million records between them and, thanks to the combiner, sent on only 38,400 pairs: 64 tasks times 600 keys, one partial sum per tenant and kind per task. The reduce tasks had almost nothing to do. Nearly all the time is map: Python calling `mean_map` 16 million times.

And Spark, with its plan:

~~~bash
uv run --project lab lab spark mean --explain
~~~

~~~text
Spark started in 8.3 s
== Physical Plan ==
AdaptiveSparkPlan isFinalPlan=false
+- HashAggregate(keys=[tenant#2, kind#6], functions=[count(1), avg(run_s#17)])
   +- Exchange hashpartitioning(tenant#2, kind#6, 200), ENSURE_REQUIREMENTS, [plan_id=15]
      +- HashAggregate(keys=[tenant#2, kind#6], functions=[partial_count(1), partial_avg(run_s#17)])
         +- Project [tenant#2, kind#6, (cast((unix_micros(finished_at#10) - unix_micros(started_at#9)) as double) / 1000000.0) AS run_s#17]
            +- Filter (isnotnull(state#4) AND (state#4 = completed))
               +- FileScan parquet [tenant#2,state#4,kind#6,started_at#9,finished_at#10,date#14,hour#15] Batched: true, DataFilters: [isnotnull(state#4), (state#4 = completed)], Format: Parquet, Location: InMemoryFileIndex(1 paths)[file:/home/techieemma/blueprint-scratch/p7/data-big/events], PartitionFilters: [], PushedFilters: [IsNotNull(state), EqualTo(state,completed)], ReadSchema: struct<tenant:string,state:string,kind:string,started_at:timestamp,finished_at:timestamp>


query 1: 9.26 s
query 2: 3.74 s
query 3: 3.09 s
tenant      kind     jobs  mean_run_s
------  --------  -------  ----------
 t0001  checksum  1811924       0.038
 t0001      sort   948226       0.088
 t0002  checksum   845251       0.038
 t0001  compress   644223       0.433
 t0003  checksum   542104       0.038
(600 rows)
~~~

Read the plan from the bottom up, and it's the job you wrote. `FileScan parquet` reads five columns of fourteen (`ReadSchema`), and `PushedFilters` hands `state = completed` to the Parquet reader, like your `filters`. `HashAggregate ... partial_count, partial_avg` is the combiner: each task's partial sums. `Exchange hashpartitioning(tenant, kind, 200)` is the shuffle, into 200 partitions by a hash of the key, like `partition_of`. The top `HashAggregate` is the reducer, merging partials. Spark's first query took three times as long as the next ones: the first pays for compiling the plan to Java bytecode and warming the JVM.

### Run it: the combiner

Run it without the combiner:

~~~bash
uv run --project lab lab mr mean --no-combine
~~~

~~~text
tenant      kind     jobs  mean_run_s
------  --------  -------  ----------
 t0001  checksum  1811924       0.038
 t0001      sort   948226       0.088
 t0002  checksum   845251       0.038
 t0001  compress   644223       0.433
 t0003  checksum   542104       0.038
(600 rows)

 phase  tasks  attempts  task_p50_s  task_max_s        in   in_max       out   out_MB  wall_s
------  -----  --------  ----------  ----------  --------  -------  --------  -------  ------
   map     64        64       4.855       5.425  16000000   267512  16000000  308.498  19.962
reduce     16        16       4.055       7.119  16000000  2400915       600    0.024   7.179
failed attempts 0, backup attempts 0
total 27.21 s
~~~

The same answer. But the shuffle carried every one of the 16 million pairs, 308 MB of them, instead of 38,400 pairs in 1.4 MB, and reduce took 7.1 seconds instead of 1.3. On one machine the shuffle is a disk write and read; across a network, it's usually the most expensive part of a job.

Note `in_max`: one reduce task received 2.4 million pairs, where an even share is a million. That's skew. Every pair for (t0001, checksum), the biggest tenant's commonest kind, went to one reducer. The combiner hid it: after combining, that key is 64 pairs, one per map task, however big the tenant.

### Run it: when nothing can be combined

The second question can't be combined. Run it exactly, then approximately:

~~~bash
uv run --project lab lab mr quantiles
uv run --project lab lab mr quantiles-approx
~~~

~~~text
tenant     jobs  p50_s  p99_s
------  -------  -----  -----
 t0001  3404373  0.041  1.832
 t0002  1587241  0.041  1.832
 t0003  1017960  0.041  1.832
 t0004   741041  0.041  1.832
 t0005   580639  0.041  1.832
(200 rows)

 phase  tasks  attempts  task_p50_s  task_max_s        in   in_max       out   out_MB  wall_s
------  -----  --------  ----------  ----------  --------  -------  --------  -------  ------
   map     64        64       3.916       5.175  16000000   267512  16000000  233.306  16.818
reduce     16        16       2.272       3.516  16000000  3795794       200    0.008   3.532
failed attempts 0, backup attempts 0
total 20.48 s
~~~

~~~text
tenant     jobs  p50_s  p99_s
------  -------  -----  -----
 t0001  3404373  0.041  1.840
 t0002  1587241  0.041  1.840
 t0003  1017960  0.041  1.840
 t0004   741041  0.041  1.840
 t0005   580639  0.041  1.840
(200 rows)

 phase  tasks  attempts  task_p50_s  task_max_s        in  in_max    out  out_MB  wall_s
------  -----  --------  ----------  ----------  --------  ------  -----  ------  ------
   map     64        64       5.019       5.573  16000000  267512  12800  14.032  21.013
reduce     16        16       1.483       1.557     12800     960    200   0.008   1.587
failed attempts 0, backup attempts 0
total 22.71 s
~~~

Exactly: every one of 16 million values crossed the shuffle (233 MB), and one reduce task received 3.8 million of them, t0001's (21% of all jobs) and whatever else hashed beside it. That task took 3.5 s while the median took 2.3 s: the job waited for the one reducer with the big customer. With a thousand customers on a cluster, this is the reducer still running an hour after the rest finished.

Approximately: 12,800 small histograms crossed instead (14 MB), every reducer got about the same (`in_max` 960), and t0001's p99 came out 1.840 s against the exact 1.832 s, 0.4% off, inside the 1% promised. But look at the totals: 22.7 s against 20.5. The shuffle shrank 17 times and the job got *slower*, because map now builds a little dictionary for every row, in Python, and that costs more than the shuffle saved on one machine. On a cluster, with the shuffle crossing a network, the trade would go the other way. Measure; don't assume.

(Every tenant has the same p50 and p99 here: `synth` draws every tenant's jobs from the same pool of real ones. Real tenants differ, which step 5 will need.)

DuckDB and Spark, on the same question:

~~~bash
uv run --project lab lab duck quantiles --threads 1
uv run --project lab lab spark quantiles --repeats 2
uv run --project lab lab spark quantiles-approx --repeats 2
~~~

~~~text
tenant     jobs  p50_s  p99_s
------  -------  -----  -----
 t0001  3404373  0.041  1.832
 t0002  1587241  0.041  1.832
 t0003  1017960  0.041  1.832
 t0004   741041  0.041  1.832
 t0005   580639  0.041  1.832
(200 rows)

3.39 s on 1 thread
~~~

~~~text
Spark started in 7.7 s
query 1: 18.20 s
query 2: 12.52 s
tenant     jobs  p50_s  p99_s
------  -------  -----  -----
 t0001  3404373  0.041  1.832
 t0002  1587241  0.041  1.832
 t0003  1017960  0.041  1.832
 t0004   741041  0.041  1.832
 t0005   580639  0.041  1.832
(200 rows)
~~~

~~~text
Spark started in 8.3 s
query 1: 36.49 s
query 2: 28.36 s
tenant     jobs  p50_s  p99_s
------  -------  -----  -----
 t0001  3404373  0.041  1.832
 t0002  1587241  0.041  1.832
 t0003  1017960  0.041  1.832
 t0004   741041  0.041  1.832
 t0005   580639  0.041  1.832
(200 rows)
~~~

DuckDB's exact answer, on one thread, in 3.4 s. And Spark's approximate percentile took more than twice as long as its exact one (28.4 s against 12.5 s, warm). Its summary (Greenwald and Khanna's) is built by inserting every value into a structure it keeps compressing, which here costs more than the exact method's counting and sorting. The summary earns its keep when the values don't fit in memory. "Approximate" means smaller, not faster.

### Break it: a task crashes, a machine is slow

Crash the first attempt of map task 3:

~~~bash
uv run --project lab lab mr mean --crash map:3
~~~

~~~text
map task 3 attempt 0: injected crash
tenant      kind     jobs  mean_run_s
------  --------  -------  ----------
 t0001  checksum  1811924       0.038
 t0001      sort   948226       0.088
 t0002  checksum   845251       0.038
 t0001  compress   644223       0.433
 t0003  checksum   542104       0.038
(600 rows)

 phase  tasks  attempts  task_p50_s  task_max_s        in  in_max    out  out_MB  wall_s
------  -----  --------  ----------  ----------  --------  ------  -----  ------  ------
   map     64        65       3.973       4.672  16000000  267512  38400   1.356  17.086
reduce     16        16       1.463       1.787     38400    3008    600   0.024   1.831
failed attempts 1, backup attempts 0
total 19.03 s
~~~

One failed attempt, 65 attempts for 64 tasks, the same answer. The scheduler saw a non-zero exit and ran the task again; nothing else had to know. That's MapReduce's whole fault-tolerance story: a task's only effect is its committed output, so running it again is always safe.

Now make one machine slow: map task 0's first attempt stalls for a minute before starting. With speculation, then without:

~~~bash
uv run --project lab lab mr mean --slow map:0=60
time uv run --project lab lab mr mean --slow map:0=60 --no-speculate
~~~

~~~text
tenant      kind     jobs  mean_run_s
------  --------  -------  ----------
 t0001  checksum  1811924       0.038
 t0001      sort   948226       0.088
 t0002  checksum   845251       0.038
 t0001  compress   644223       0.433
 t0003  checksum   542104       0.038
(600 rows)

 phase  tasks  attempts  task_p50_s  task_max_s        in  in_max    out  out_MB  wall_s
------  -----  --------  ----------  ----------  --------  ------  -----  ------  ------
   map     64        65       3.767       4.322  16000000  267512  38400   1.356  17.438
reduce     16        16       1.288       1.366     38400    3008    600   0.024   1.410
failed attempts 0, backup attempts 1
total 18.91 s
~~~

~~~text
tenant      kind     jobs  mean_run_s
------  --------  -------  ----------
 t0001  checksum  1811924       0.038
 t0001      sort   948226       0.088
 t0002  checksum   845251       0.038
 t0001  compress   644223       0.433
 t0003  checksum   542104       0.038
(600 rows)

 phase  tasks  attempts  task_p50_s  task_max_s        in  in_max    out  out_MB  wall_s
------  -----  --------  ----------  ----------  --------  ------  -----  ------  ------
   map     64        64       3.872      61.822  16000000  267512  38400   1.356  62.131
reduce     16        16       1.223       1.311     38400    3008    600   0.024   1.354
failed attempts 0, backup attempts 0
total 63.55 s

real	1m4.515s
user	0m3.199s
sys	0m0.251s
~~~

With speculation: one backup attempt, and the job took 18.9 s, as if nothing had happened. The backup overtook the stalled attempt, committed first, and the stalled one was stopped. Without: 63.6 s, the slowest task's time. Dean and Ghemawat reported the same in 2004: without backup tasks, one of their sorts took 44% longer.

### Break it: hash()

In `mapreduce.py`, make `partition_of` return `hash(key) % reducers`. Run the tests, then the job:

~~~bash
cd lab && uv run pytest -q tests/test_bigdata.py; cd ..
uv run --project lab lab mr mean --top 3
~~~

~~~text
E       AssertionError: one key, several reducers: {'3', '4'}
FAILED tests/test_bigdata.py::test_a_key_goes_to_the_same_reducer_in_every_process
1 failed, 16 passed in 11.52s
~~~

~~~text
tenant      kind     jobs  mean_run_s
------  --------  -------  ----------
 t0001  checksum  1811924       0.038
 t0001      sort   948226       0.088
 t0002  checksum   845251       0.038
(600 rows)

 phase  tasks  attempts  task_p50_s  task_max_s        in  in_max    out  out_MB  wall_s
------  -----  --------  ----------  ----------  --------  ------  -----  ------  ------
   map     64        64       3.925       4.551  16000000  267512  38400   1.356  16.462
reduce     16        16       1.208       1.351     38400    3264    600   0.024   1.388
failed attempts 0, backup attempts 0
total 17.92 s
~~~

The test fails: three processes with three salts sent one key to reducers 3 and 4. And the real job gives the *right* answer. Every worker here is forked from one server process (`forkserver`), so all of them inherited its salt, and they agree with each other by accident. On two machines, or with `spawn`, each tenant's pairs would be split across reducers, and the output would have the same key twice with partial counts. A bug that only exists when the system is distributed can only be caught by a test that simulates it. Put CRC-32 back.

### Break it: a combiner that can't take its own output

In `bigjobs.py`, make `mean_combine` count the values it's given, `return (len(values), sum(s for _, s in values))`. That's correct for map's raw values, each `(1, seconds)`. Run the tests and the job, with and without the combiner:

~~~bash
cd lab && uv run pytest -q tests/test_bigdata.py; cd ..
uv run --project lab lab mr mean --top 3
uv run --project lab lab mr mean --top 3 --no-combine
~~~

~~~text
E           assert (16 == 75)
E           assert 16 == 616
FAILED tests/test_bigdata.py::test_mapreduce_means_match_sql - assert (16 == 75)
FAILED tests/test_bigdata.py::test_the_combiner_changes_what_crosses_the_shuffle_not_the_answer
2 failed, 15 passed in 10.79s
~~~

~~~text
tenant      kind  jobs  mean_run_s
------  --------  ----  ----------
 t0001  checksum    64    1086.211
 t0001  compress    64    4361.986
 t0001      sort    64    1301.461
(600 rows)

 phase  tasks  attempts  task_p50_s  task_max_s        in  in_max    out  out_MB  wall_s
------  -----  --------  ----------  ----------  --------  ------  -----  ------  ------
   map     64        64       4.034       4.770  16000000  267512  38400   1.356  16.899
reduce     16        16       1.303       1.397     38400    3008    600   0.024   1.426
failed attempts 0, backup attempts 0
total 18.39 s
~~~

~~~text
tenant      kind     jobs  mean_run_s
------  --------  -------  ----------
 t0001  checksum  1811924       0.038
 t0001      sort   948226       0.088
 t0002  checksum   845251       0.038
(600 rows)

 phase  tasks  attempts  task_p50_s  task_max_s        in   in_max       out   out_MB  wall_s
------  -----  --------  ----------  ----------  --------  -------  --------  -------  ------
   map     64        64       4.630       5.240  16000000   267512  16000000  308.498  19.357
reduce     16        16       4.064       6.839  16000000  2400915       600    0.024   6.908
failed attempts 0, backup attempts 0
total 26.33 s
~~~

Every count is 64 and every mean is in the thousands of seconds, with the combiner; without it, perfect. The reducer calls `mean_combine` too, on partial results `(n, total)`, where counting values counts map tasks. A combiner's output must be a valid input to itself, because a framework may apply it once, many times or not at all (Hadoop decides at run time). Put it back.

### Break it: the expression, not the engine

In `bigjobs.py`, write the run time the obvious way: `RUN_S = "epoch(finished_at - started_at)"`. Then (after a warm-up run):

~~~bash
uv run --project lab lab duck mean --threads 1 --top 3
~~~

~~~text
tenant      kind     jobs  mean_run_s
------  --------  -------  ----------
 t0001  checksum  1811924       0.038
 t0001      sort   948226       0.088
 t0002  checksum   845251       0.038
(600 rows)

21.05 s on 1 thread
~~~

The same answer, 9 times slower: 21 s against 2.3. Subtracting two `TIMESTAMPTZ` values makes an `INTERVAL` (months, days and microseconds, through the time zone code) for every one of 16 million rows, just to turn it back into seconds. One thread of DuckDB with the wrong expression loses to Spark with the right one. Before comparing systems, make sure each is asked the same question the same way. Put it back.

### Run it: what does scaling out buy?

Now the race: each system at 1, 2, 4, 8 and 16 workers (processes for MapReduce, threads for Spark and DuckDB), three times each, interleaved. It takes about ten minutes:

~~~bash
uv run --project lab lab cost --plot results/cost.png
~~~

~~~text
spark local[1]: started in 7.3 s, first query 16.4 s
mapreduce  1 workers:   45.17 s
   duckdb  1 workers:    2.21 s
    spark  1 workers:    8.45 s
...
~~~

~~~text
workers     duckdb  mapreduce      spark
      1       2.34      44.63       9.38
      2       1.22      25.19       5.80
      4       1.03      23.25       4.25
      8       0.77      18.03       3.38
     16       0.84      21.60       3.61

COST, against DuckDB on 1 thread (2.34 s):
     duckdb: 2 workers
  mapreduce: none up to 16
      spark: none up to 16

plot: results/cost.png
~~~

![Seconds against workers, both on log scales. MapReduce falls from 45 s to 18 s at 8 workers, then rises; Spark from 9.4 to 3.4 s; DuckDB from 2.3 to 0.8 s. A dashed line marks DuckDB on one thread, at 2.3 s: MapReduce and Spark stay above it at every width.](images/s04-cost.png)

Neither MapReduce nor Spark ever beats DuckDB on one thread. With all 16 workers, Spark takes 1.5 times as long as one DuckDB thread, and MapReduce 9 times: their COST, on this question and this machine, is "more cores than you have". That's not because they don't scale. Each got faster with more workers, about as much as DuckDB did. They start so far behind that scaling never catches up.

Where does the gap come from? Not the algorithm: all three read the same columns, filter, group by the same key, and add up. The difference is the cost of each row. DuckDB processes a column of values at a time, in compiled loops; Spark processes rows in generated Java code, after a planner and a scheduler that are built for clusters; MapReduce here runs Python for every row, and pickles every pair through files. Distribution adds its own costs on top (planning, scheduling, serialising, the shuffle), and they're worth paying only when one machine can't do the job.

And why does everything stop improving at 8? Try the machine itself, with nothing but arithmetic in each process:

~~~bash
python3 - <<'PY'
import multiprocessing as mp, time
def spin(_):
    t = time.perf_counter(); x = 0
    for i in range(20_000_000): x += i
    return time.perf_counter() - t
if __name__ == "__main__":
    for n in (1, 2, 4, 8, 16):
        with mp.Pool(n) as p:
            secs = p.map(spin, range(n))
        print(f"{n:>2} processes: each loop took {sum(secs)/n:.2f} s (alone: compare with 1)")
PY
~~~

~~~text
 1 processes: each loop took 0.57 s (alone: compare with 1)
 2 processes: each loop took 0.66 s (alone: compare with 1)
 4 processes: each loop took 0.85 s (alone: compare with 1)
 8 processes: each loop took 1.37 s (alone: compare with 1)
16 processes: each loop took 2.51 s (alone: compare with 1)
~~~

The same loop takes 2.5 times as long when eight run at once, and 4.5 times with sixteen. This laptop has 8 cores, each running two threads (`lscpu`: 2 threads per core), so sixteen processes share eight cores. And the likely reason eight are already slower: a laptop processor shares one power budget between its cores, so each runs at a lower clock speed when all are busy. Either way, eight processes do 8 / 2.5 = 3.2 times the work of one, and sixteen 3.6 times. That's the ceiling every system hit: each got about 3 times faster, and no software can get more out of this machine. Your machine's numbers will differ; measure them before you believe any scaling curve, including your own.

### Run it: small files

The pipeline writes one file per hour, and `synth` copied that: 742 files. Every file costs something to open and read the metadata of, whoever reads it. Compact them into one file per day, with DuckDB:

~~~bash
mkdir data-big-daily
time uv run --project lab lab sql --data data-big "COPY (SELECT * EXCLUDE (hour)
  FROM read_parquet('data-big/events/**/*.parquet', hive_partitioning = true))
  TO 'data-big-daily/events' (FORMAT parquet, PARTITION_BY (date))"
for d in data-big data-big-daily; do echo "$d: $(find $d -name '*.parquet' | wc -l) files, $(du -sh $d | cut -f1)"; done
~~~

~~~text
   Count
--------
48000000

real	0m14.200s
user	2m32.124s
sys	0m33.434s
~~~

~~~text
data-big: 742 files, 1.9G
data-big-daily: 31 files, 1.5G
~~~

Then race the two layouts, alternating, after a warm-up run of the new one:

~~~bash
for i in 1 2 3 4 5; do
  for d in data-big data-big-daily; do
    printf "%-15s %s\n" $d "$(uv run --project lab lab duck mean --data $d --threads 1 | tail -1)"
  done
done
~~~

~~~text
data-big        2.30 s on 1 thread
data-big-daily  1.98 s on 1 thread
data-big        2.24 s on 1 thread
data-big-daily  1.98 s on 1 thread
data-big        2.26 s on 1 thread
data-big-daily  2.22 s on 1 thread
data-big        2.27 s on 1 thread
data-big-daily  2.10 s on 1 thread
data-big        2.34 s on 1 thread
data-big-daily  1.99 s on 1 thread
~~~

Fewer, bigger files: 20% smaller (written by DuckDB, in bigger row groups), and about 12% faster to scan (medians 2.27 and 1.99 s). Real, but modest, with the files in memory. With them on disk, or in object storage where every file is a network request, the gap grows; it's why table formats like Iceberg and Delta Lake run compaction as routine maintenance. The trade: the pipeline can't write daily files until the day is over. So it writes small files for freshness, and a later job compacts them, as step 3's rebuild could.

### Put the cluster back

Step 8 needs the cluster again; start it whenever you like. OpenBao comes back sealed (Phase 6), so unseal it, and restart the port-forwards:

~~~bash
docker start runway-control-plane runway-worker runway-worker2
deploy/bao/init.sh ~/.runway/bao   # your key directory from Phase 6
kubectl -n runway get pods         # wait until everything is Running
kubectl -n runway port-forward svc/idp 8081:8081 >/dev/null 2>&1 &
kubectl -n runway port-forward pod/kafka-0 39092:39092 >/dev/null 2>&1 &
~~~

**Explain it:** what do map, the shuffle and reduce each do, and why must reduce wait for every map task? Why can't `partition_of` use `hash()`, and why did the job still work on one machine? What makes an aggregate combinable, and why must a combiner accept its own output? Why did the exact percentiles put most of the work on one reducer, and what fixed it? Why did the approximate version shrink the shuffle and still take longer? How does committing by rename make re-running and racing tasks safe? What is COST, what was each system's here, and where does the gap come from? Why did nothing get more than about three times faster, whatever the system?

**Read.** Jeffrey Dean and Sanjay Ghemawat, *MapReduce: Simplified Data Processing on Large Clusters* (OSDI 2004): short, and you've now built most of it; compare their section 3 with your `mapreduce.py`. Frank McSherry, Michael Isard and Derek Murray, *Scalability! But at what COST?* (HotOS 2015): four pages, and the table you just reproduced. Matei Zaharia and others, *Resilient Distributed Datasets* (NSDI 2012): how Spark keeps data in memory between stages, and why. And Charles Masson, Jee Rim and Homin Lee, *DDSketch* (VLDB 2019): the histogram you built, with its proof. Then *Designing Data-Intensive Applications*, chapter 10, *Batch Processing*.

---
## Step 5: The dataset, and the baselines to beat

**The problem.** From here on, the phase asks one question: when a job is submitted, how long will it run? Step 9 will use the answer to put short jobs ahead of long ones and to tell tenants when to expect a result. Before any model, two things decide whether the answer can be trusted. The data must hold only what was known when the question was asked, or the model learns from the future and fails in production. And there must be simple predictions to beat, measured in ways that suit the use, or a model's numbers mean nothing.

**New ideas.**

- **Point-in-time correctness.** A training row must look exactly like the question will look in production: the features as they were at the moment the job was submitted. Anything later (when it started, how long it waited, an average that includes later jobs) is **leakage**: it makes the model look better in evaluation than it can ever be in use. The reliable check: rebuild each row as it would have been built at that moment, with the rest of time unknown, and require the same answer.
- **Labels arrive late.** A job's run time is known only when it finishes. Keep only jobs old enough that every one of them has finished, not "the ones that have finished": in the last minute, those are the fast ones, so the newest data would be biased short. And wait for late events (step 3's lateness) before trusting the newest data at all.
- **Split by time.** Train on the past, validate and test on the future, in that order, because that's how the model will be used. A random split puts tomorrow's jobs in the training set, and when today resembles tomorrow (same burst, same busy workers) the score is flattering.
- **Baselines.** The median of everything; the median per kind; a straight line in log-log space per kind (a power law, time = a × size^b, which step 2's slopes suggested). A model is only worth having if it beats these clearly.
- **Choose the metric for the use.** **MAE** (mean absolute error, seconds) is dominated by long jobs. **MAPE** (mean absolute percentage error) is dominated by tiny jobs, and can be won by guessing low: an under-guess is at most 100% wrong, an over-guess unboundedly. **Log error** treats "twice as long" the same at every size. **Rank correlation** asks only whether the order is right, which is all shortest-job-first needs. An **upper bound** (an ETA a tenant can rely on) is a quantile, scored by **pinball loss** and checked by **coverage**: a p90 should be exceeded by 10% of jobs, not 2% or 30%.
- **Compare on the same jobs, with honest intervals.** Two models scored on the same test jobs are compared job by job (**paired**). And jobs submitted in the same minute shared a queue and busy workers, so they're not independent: resample whole minutes (a **block bootstrap**), or the interval is too narrow. Step 1's lesson, at a finer grain.

### More real data

Step 3 left two runs, about 2,200 jobs: too few, and all at one load. Collect more, at different loads, so the model sees quiet and busy workers. `kload mix` gets two options: another seed (another schedule from the same workload) and a load factor (every tenant's rate multiplied). In `kload/src/kload/workload.py`:

Change:

<!-- edit: kload/src/kload/workload.py -->
~~~python
import asyncio
import json
~~~

to:

~~~python
import asyncio
import copy
import json
~~~

Change:

<!-- edit: kload/src/kload/workload.py -->
~~~python
    return workload

~~~

to:

~~~python
    return workload


def vary(workload: Mapping, seed: int | None = None, load: float = 1.0) -> dict:
    """A copy of workload with another seed, or every tenant's rate times load."""
    varied = copy.deepcopy(dict(workload))
    if seed is not None:
        varied["seed"] = seed
    for tenant in varied["tenants"]:
        tenant["rate"] *= load
    return varied

~~~


In `kload/src/kload/cli.py`:

Change:

<!-- edit: kload/src/kload/cli.py -->
~~~python
    from kload.workload import collect, load_workload, plan, submit, write_rows
~~~

to:

~~~python
    from kload.workload import collect, load_workload, plan, submit, vary, write_rows
~~~

Change:

<!-- edit: kload/src/kload/cli.py -->
~~~python
    workload = load_workload(Path(args.workload))
~~~

to:

~~~python
    workload = vary(load_workload(Path(args.workload)), seed=args.seed, load=args.load)
~~~

Change:

<!-- edit: kload/src/kload/cli.py -->
~~~python
    p.add_argument("--collect-timeout", type=float, default=300, help="seconds to wait for jobs")
    p.add_argument("--out", default="results/jobs.jsonl")
~~~

to:

~~~python
    p.add_argument("--collect-timeout", type=float, default=300, help="seconds to wait for jobs")
    p.add_argument("--seed", type=int, help="draw another schedule from the same workload")
    p.add_argument("--load", type=float, default=1.0, help="multiply every tenant's rate")
    p.add_argument("--out", default="results/jobs.jsonl")
~~~


In `kload/tests/test_workload.py`:

Change:

<!-- edit: kload/tests/test_workload.py -->
~~~python
from kload.workload import MAX_SIZE, collect, load_workload, plan, submit
~~~

to:

~~~python
from kload.workload import MAX_SIZE, collect, load_workload, plan, submit, vary
~~~

Change:

<!-- edit: kload/tests/test_workload.py -->
~~~python
    assert sizes[0] >= 1

~~~

to:

~~~python
    assert sizes[0] >= 1


def test_vary_draws_another_schedule_or_scales_the_load():
    busier = plan(vary(WORKLOAD | {"duration": 2000}, load=1.5))
    assert len(busier) == pytest.approx(1.5 * 12_000, rel=0.05)
    other = plan(vary(WORKLOAD, seed=2))
    assert other != plan(WORKLOAD) and len(other) == pytest.approx(600, rel=0.15)
    assert WORKLOAD["seed"] == 1 and WORKLOAD["tenants"][0]["rate"] == 5.0, "a copy, not a change"

~~~


<!-- run: cd kload && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

Start the cluster if it's stopped (end of step 4), then run eight workloads, cycling the load through 1, 2 and 3: about 40 minutes, and 16,000 jobs. Tokens last five minutes, so each run gets fresh ones:

~~~bash
run=0
for spec in 11:1 12:2 13:3 14:1 15:2 16:3 17:1 18:2; do  # seed:load
  run=$((run + 1)) seed=${spec%:*} load=${spec#*:}
  export ACME_TOKEN=$(token acme-ci) GLOBEX_TOKEN=$(token globex-ci) INITECH_TOKEN=$(token initech-ci)
  echo "== run $run: seed $seed, load $load, $(date -u +%H:%M:%S)"
  uv run --project kload kload mix workloads/three-tenants.toml --seed $seed --load $load \
    --out results/s05-run$run.jsonl
done
uv run --project lab lab pipeline
~~~

### The data as it was

The dataset must be buildable as of any moment, so the warehouse gets an `as_of`: only the events that had happened by then. And step 4 showed what `epoch(finished_at - started_at)` costs; use whole microseconds here too. In `lab/src/lab/warehouse.py`:

Change:

<!-- edit: lab/src/lab/warehouse.py -->
~~~python

from pathlib import Path
~~~

to:

~~~python

from datetime import datetime
from pathlib import Path
~~~

Change:

<!-- edit: lab/src/lab/warehouse.py -->
~~~python
def connect(data: Path) -> duckdb.DuckDBPyConnection:
~~~

to:

~~~python
def connect(data: Path, as_of: datetime | None = None) -> duckdb.DuckDBPyConnection:
    """Views over data's events; with as_of, only the events that had happened by then."""
~~~

Change:

<!-- edit: lab/src/lab/warehouse.py -->
~~~python
        FROM read_parquet('{files}', hive_partitioning = true, union_by_name = true)
        QUALIFY row_number() OVER (PARTITION BY event_id ORDER BY kafka_partition, kafka_offset) = 1
~~~

to:

~~~python
        FROM read_parquet('{files}', hive_partitioning = true, union_by_name = true)
        {f"WHERE occurred_at <= '{as_of.isoformat()}'" if as_of else ""}
        QUALIFY row_number() OVER (PARTITION BY event_id ORDER BY kafka_partition, kafka_offset) = 1
~~~

Change:

<!-- edit: lab/src/lab/warehouse.py -->
~~~python
               epoch(finished_at - started_at) AS run_s,
               epoch(started_at - created_at) AS wait_s,
~~~

to:

~~~python
               (epoch_us(finished_at) - epoch_us(started_at)) / 1e6 AS run_s,
               (epoch_us(started_at) - epoch_us(created_at)) / 1e6 AS wait_s,
~~~


Create `lab/src/lab/dataset.py`:

<!-- file: lab/src/lab/dataset.py -->
~~~python
"""From events to a dataset: one row per finished job, with what was known when it was submitted.

The question every later step answers: when a job is submitted, how long
will it run? So a feature may use only what the API could know at that
moment: the request itself, and the state of the system just before. Never
when the job started, how long it waited, or anything that happened later.
test_dataset.py checks this the only way that can't be fooled: it builds
the dataset again as of an earlier moment, with the future cut off, and
requires every job created before then to get exactly the same features.
"""

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

from lab import warehouse

FEATURES = ["tenant", "kind", "size", "running_at_submit", "queued_at_submit", "tenant_recent"]
LABEL = "run_s"
RECENT = 60.0  # seconds: how far back tenant_recent looks


@dataclass(frozen=True)
class Window:
    """Which jobs a dataset built `now` may use.

    lateness: events can reach the pipeline this long after they happened
    (step 3 measured 76 s in an outage), so the newest data is incomplete.
    horizon: a job created this long before the data ends has certainly
    finished (the worker gives up at 30 s). Newer jobs are left out, not
    just the unfinished ones: dropping only those would keep the fast jobs
    of the last minute and lose its slow ones.
    """

    lateness: timedelta = timedelta(minutes=5)
    horizon: timedelta = timedelta(minutes=1)


def load_jobs(data: Path, as_of: datetime | None = None) -> dict[str, np.ndarray]:
    """Every job the events (up to as_of) know of, with its times so far, ordered by creation."""
    con = warehouse.connect(data, as_of)
    cols = con.execute("""
        SELECT tenant, job_id, kind, size, state, run_s, wait_s,
               epoch_us(created_at) AS created, epoch_us(started_at) AS started,
               epoch_us(finished_at) AS finished
        FROM jobs ORDER BY created, tenant, job_id
    """).fetchnumpy()
    # Columns with NULLs come back as masked arrays. Keep them masked:
    # np.asarray would keep the values under the mask, and an unknown
    # finish would become a finish in 1970.
    return dict(cols)


def features(jobs: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    """What the system looked like just before each job was created.

    Counts of events strictly before the job's creation: at that moment, a
    job is running if it has started and not finished, queued if it has
    been created and not started. Unknown times (NULL) are never counted.
    """
    created = jobs["created"]
    started, finished = np.ma.asarray(jobs["started"]), np.ma.asarray(jobs["finished"])
    starts = np.sort(started.compressed())
    # Only finishes whose start is known: a job that completed with its
    # start unknown (step 2's race) was never counted as running, so
    # counting its finish would leave every later count one too low.
    finishes = np.sort(finished[~np.ma.getmaskarray(started)].compressed())
    creations = np.sort(created)

    def before(times: np.ndarray, at: np.ndarray) -> np.ndarray:
        return np.searchsorted(times, at, side="left")  # how many are < at

    out = {
        "tenant": jobs["tenant"],
        "kind": jobs["kind"],
        "size": jobs["size"],
        "running_at_submit": before(starts, created) - before(finishes, created),
        "queued_at_submit": before(creations, created) - before(starts, created),
        "tenant_recent": np.zeros(len(created), dtype=np.int64),
    }
    for tenant in np.unique(jobs["tenant"]):
        mine = jobs["tenant"] == tenant
        times = np.sort(created[mine])
        recent = before(times, created[mine]) - before(times, created[mine] - RECENT * 1e6)
        out["tenant_recent"][mine] = recent
    return out


def build(
    data: Path, window: Window | None = None, now: datetime | None = None
) -> tuple[pa.Table, dict[str, int]]:
    """The dataset as it can be built at `now` (default: this moment, by the clock).

    The window is measured from the clock, not from the newest event: data
    that stopped arriving an hour ago is complete, however recent its last
    event. Returns the rows, and how many jobs were left out, and why.
    """
    window = window or Window()
    now = now or datetime.now(UTC)
    as_of = now - window.lateness
    jobs = load_jobs(data, as_of)
    feats = features(jobs)
    run = np.ma.filled(jobs[LABEL], np.nan)
    old_enough = jobs["created"] <= (as_of - window.horizon).timestamp() * 1e6
    completed = np.asarray(jobs["state"]) == "completed"
    # A job can complete with its start unknown: the worker's "started"
    # report arrived after its "completed" one (step 2), so no run time.
    known = ~np.isnan(run)
    keep = old_enough & completed & known
    counts = {
        "jobs": len(run),
        "too recent": int((~old_enough).sum()),
        "not completed": int((old_enough & ~completed).sum()),
        "start unknown": int((old_enough & completed & ~known).sum()),
        "rows": int(keep.sum()),
    }
    table = {
        "job_id": jobs["job_id"],
        "created_at": pa.array(jobs["created"], pa.int64()).cast(pa.timestamp("us", tz="UTC")),
        **feats,
        "wait_s": np.ma.filled(jobs["wait_s"], np.nan),
        LABEL: run,
    }
    rows = pa.table({k: (v if isinstance(v, pa.Array) else pa.array(v)) for k, v in table.items()})
    return rows.filter(pa.array(keep)), counts


def split_by_time(table: pa.Table, train: float = 0.6, valid: float = 0.2) -> pa.Table:
    """Label each row train, valid or test: the earliest jobs train, the latest test."""
    n = table.num_rows
    names = np.array(["train"] * n, dtype=object)
    names[int(n * train) : int(n * (train + valid))] = "valid"
    names[int(n * (train + valid)) :] = "test"
    order = np.argsort(np.asarray(table["created_at"].cast(pa.int64())), kind="stable")
    labels = np.empty(n, dtype=object)
    labels[order] = names
    return table.append_column("split", pa.array(labels.tolist()))


def split_at_random(table: pa.Table, seed: int = 1, train: float = 0.6, valid: float = 0.2):
    """The same proportions, drawn at random: the split a time series must not have."""
    rng = np.random.default_rng(seed)
    u = rng.random(table.num_rows)
    labels = np.where(u < train, "train", np.where(u < train + valid, "valid", "test"))
    return table.append_column("split", pa.array(labels.tolist()))


def save(table: pa.Table, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(table, path)


def load(path: Path) -> dict[str, np.ndarray]:
    """A saved dataset as NumPy columns."""
    t = pq.read_table(path)
    return {name: t[name].to_numpy(zero_copy_only=False) for name in t.column_names}
~~~

Read `features` slowly: it's where leakage would get in. For each job, the counts are of events strictly before the job's creation, computed by binary search over sorted times (`searchsorted`): the number of starts before that moment, minus the finishes, is how many jobs were running. Unknown times are left out, never guessed. That's everything the API could know when the job arrived, and step 8 will compute the same counts in the API itself.

`build` applies the window. It sees only events up to `now - lateness`, and keeps only jobs created at least `horizon` before that, all finished. `now` is the clock, not the newest event: data that stopped arriving an hour ago is complete.

### Baselines and metrics

Create `lab/src/lab/baselines.py`:

<!-- file: lab/src/lab/baselines.py -->
~~~python
"""The simplest predictions of a job's run time, to beat before anything cleverer is worth having.

Each model learns from training rows (fit) and predicts for any rows
(predict), from the dataset's columns. Run times span four orders of
magnitude and their errors grow with them, so the fitted lines work in
log(seconds): a straight line there is a power law, time = a * size^b.
"""

import numpy as np

Rows = dict[str, np.ndarray]


class Median:
    """One number for every job: the median run time."""

    name = "median"

    def fit(self, rows: Rows) -> "Median":
        self.value = float(np.median(rows["run_s"]))
        return self

    def predict(self, rows: Rows) -> np.ndarray:
        return np.full(len(rows["run_s"]), self.value)


class KindMedian:
    """The median run time of the job's kind."""

    name = "kind median"

    def __init__(self, scale: float = 1.0):
        self.scale = scale  # 0.5 makes the deliberately low guess that games MAPE
        if scale != 1.0:
            self.name = f"kind median x{scale:g}"

    def fit(self, rows: Rows) -> "KindMedian":
        self.fallback = float(np.median(rows["run_s"]))
        self.values = {
            k: float(np.median(rows["run_s"][rows["kind"] == k])) for k in np.unique(rows["kind"])
        }
        return self

    def predict(self, rows: Rows) -> np.ndarray:
        values = [self.values.get(k, self.fallback) for k in rows["kind"]]
        return self.scale * np.array(values)


class KindPowerLaw:
    """Per kind, log(run) = a + b log(size), and optionally + c * (jobs running at submit).

    Fitted by least squares in log space, so exp(prediction) estimates the
    median run time for that size (a log-normal's median), not the mean.
    """

    def __init__(self, contention: bool = False, quantile: float | None = None):
        self.contention = contention
        self.quantile = quantile  # also add this quantile of the training residuals
        self.name = "kind power law" + (" + running" if contention else "")
        if quantile:
            self.name += f" p{quantile * 100:g}"

    def _design(self, rows: Rows, mask: np.ndarray) -> np.ndarray:
        cols = [np.ones(mask.sum()), np.log(np.maximum(rows["size"][mask], 1))]
        if self.contention:
            cols.append(rows["running_at_submit"][mask])
        return np.column_stack(cols)

    def fit(self, rows: Rows) -> "KindPowerLaw":
        self.coef, self.offset = {}, {}
        for k in np.unique(rows["kind"]):
            mask = rows["kind"] == k
            x, y = self._design(rows, mask), np.log(rows["run_s"][mask])
            self.coef[k] = np.linalg.lstsq(x, y, rcond=None)[0]
            residuals = y - x @ self.coef[k]
            self.offset[k] = float(np.quantile(residuals, self.quantile)) if self.quantile else 0.0
        return self

    def predict(self, rows: Rows) -> np.ndarray:
        out = np.empty(len(rows["kind"]))
        for k in np.unique(rows["kind"]):
            mask = rows["kind"] == k
            out[mask] = np.exp(self._design(rows, mask) @ self.coef[k] + self.offset[k])
        return out


class KindQuantile:
    """The given quantile of the job's kind's run times: an upper bound, not a guess."""

    def __init__(self, quantile: float):
        self.quantile = quantile
        self.name = f"kind p{quantile * 100:g}"

    def fit(self, rows: Rows) -> "KindQuantile":
        self.values = {
            k: float(np.quantile(rows["run_s"][rows["kind"] == k], self.quantile))
            for k in np.unique(rows["kind"])
        }
        return self

    def predict(self, rows: Rows) -> np.ndarray:
        return np.array([self.values[k] for k in rows["kind"]])
~~~

`KindPowerLaw` fits a straight line to log(time) against log(size), per kind: two numbers per kind, a and b, by least squares. With `contention=True` it adds a third, for the number of jobs running at submission. With `quantile=0.9` it shifts the line up by the 90th percentile of its training residuals: an upper bound that grows with size, instead of one number per kind.

Create `lab/src/lab/metrics.py`:

<!-- file: lab/src/lab/metrics.py -->
~~~python
"""How wrong a prediction of run time is: several answers, because "wrong" depends on the use.

MAE is in seconds, so the few long jobs dominate it. MAPE divides each
error by the true value, so the many tiny jobs dominate it, and it punishes
a guess that's too high far more than one that's too low (too low can be
at most 100% wrong; too high, any amount): a model can win on MAPE by
guessing low. Log error treats a factor of two the same at every size.
Rank correlation asks only whether the order is right, which is all
shortest-job-first scheduling needs. Pinball loss scores an upper bound.
"""

import numpy as np


def mae(y: np.ndarray, pred: np.ndarray) -> float:
    """Mean absolute error, in seconds."""
    return float(np.mean(np.abs(pred - y)))


def mape(y: np.ndarray, pred: np.ndarray) -> float:
    """Mean absolute percentage error."""
    return float(np.mean(np.abs(pred - y) / y) * 100)


def log_error(y: np.ndarray, pred: np.ndarray) -> float:
    """Mean |log(pred / y)|, reported as the typical factor off: 1.5 means 50% either way."""
    return float(np.exp(np.mean(np.abs(np.log(pred / y)))))


def spearman(y: np.ndarray, pred: np.ndarray) -> float:
    """Rank correlation: 1 if the predictions put every job in the right order."""
    ry, rp = _ranks(y), _ranks(pred)
    return float(np.corrcoef(ry, rp)[0, 1])


def _ranks(x: np.ndarray) -> np.ndarray:
    """Ranks with ties given their average rank (a constant prediction has no order)."""
    order = np.argsort(x, kind="stable")
    ranks = np.empty(len(x))
    ranks[order] = np.arange(len(x))
    _, inverse, counts = np.unique(x, return_inverse=True, return_counts=True)
    sums = np.bincount(inverse, weights=ranks)
    return (sums / counts)[inverse]


def pinball(y: np.ndarray, pred: np.ndarray, q: float) -> float:
    """Quantile loss: what predicting the q-th quantile minimises (q = 0.5 is MAE / 2)."""
    diff = y - pred
    return float(np.mean(np.maximum(q * diff, (q - 1) * diff)))


def coverage(y: np.ndarray, pred: np.ndarray) -> float:
    """The share of jobs that finished within the prediction: a p90 should cover 90%."""
    return float(np.mean(y <= pred))


def paired_bootstrap(
    errors_a: np.ndarray,
    errors_b: np.ndarray,
    blocks: np.ndarray,
    resamples: int = 2000,
    seed: int = 1,
) -> tuple[float, float, float]:
    """B's mean error minus A's, with a 95% interval, resampling whole blocks of rows.

    Both models are scored on the same jobs, so compare them job by job
    (paired). And jobs submitted in the same minute shared the same queue
    and the same busy workers: they aren't independent, so resample whole
    minutes (blocks), not single jobs, or the interval comes out too narrow.
    """
    diff = errors_b - errors_a
    ids, inverse = np.unique(blocks, return_inverse=True)
    sums = np.bincount(inverse, weights=diff)
    counts = np.bincount(inverse)
    rng = np.random.default_rng(seed)
    picks = rng.integers(0, len(ids), size=(resamples, len(ids)))
    means = sums[picks].sum(axis=1) / counts[picks].sum(axis=1)
    low, high = np.quantile(means, [0.025, 0.975])
    return float(diff.mean()), float(low), float(high)
~~~

And `lab/src/lab/evaluate.py`, which fits on the training rows, scores on another split, and compares each model with the per-kind median, job by job, in blocks of a minute:

<!-- file: lab/src/lab/evaluate.py -->
~~~python
"""Fit models on the training rows and score them on another split, with honest uncertainty."""

import numpy as np

from lab import metrics
from lab.warehouse import table

Rows = dict[str, np.ndarray]


def rows_of(data: Rows, split: str) -> Rows:
    mask = data["split"] == split
    return {k: v[mask] for k, v in data.items()}


def minutes(rows: Rows) -> np.ndarray:
    """Each job's block for the bootstrap: the minute it was created in."""
    return rows["created_at"].astype("datetime64[m]").astype(np.int64)


def point_report(data: Rows, models: list, split: str, reference: str = "kind median") -> str:
    """Models of a typical run time: their errors, and each against the reference model."""
    reference = [m.name for m in models].index(reference)
    train, rows = rows_of(data, "train"), rows_of(data, split)
    y = rows["run_s"]
    preds = [m.fit(train).predict(rows) for m in models]
    names = ["model", "MAE_s", "MAPE_%", "log_factor", "spearman", "MAE_vs_ref_s", "95% CI"]
    out = []
    ref_err = np.abs(preds[reference] - y)
    for m, p in zip(models, preds, strict=True):
        diff, low, high = metrics.paired_bootstrap(ref_err, np.abs(p - y), minutes(rows))
        ci = "" if m is models[reference] else f"{low:+.4f} .. {high:+.4f}"
        spearman = metrics.spearman(y, p) if np.ptp(p) > 0 else float("nan")
        out.append(
            [m.name, metrics.mae(y, p), metrics.mape(y, p), metrics.log_error(y, p), spearman]
        )
        out[-1] += ["" if m is models[reference] else f"{diff:+.4f}", ci]
    head = f"{len(y)} {split} jobs, models trained on {len(train['run_s'])}"
    head += f"; MAE_vs_ref compares each with {models[reference].name}"
    return head + "\n" + table(names, out)


def bound_report(data: Rows, models: list, split: str, q: float) -> str:
    """Models of an upper bound (the q-th quantile): pinball loss, and how often they held."""
    train, rows = rows_of(data, "train"), rows_of(data, split)
    y = rows["run_s"]
    out = []
    for m in models:
        p = m.fit(train).predict(rows)
        out.append([m.name, metrics.pinball(y, p, q), metrics.coverage(y, p) * 100])
    return table(["model", f"pinball_{q:g}", "covered_%"], out)


def plot(data: Rows, split: str, png) -> None:
    """Left: run time against size, per kind, with the power law. Right: what it misses, by load."""
    from matplotlib.figure import Figure

    from lab.baselines import KindPowerLaw

    train, rows = rows_of(data, "train"), rows_of(data, split)
    model = KindPowerLaw().fit(train)
    ratio = rows["run_s"] / model.predict(rows)
    fig = Figure(figsize=(11, 4.5))
    left, right = fig.subplots(1, 2)
    for kind in np.unique(rows["kind"]):
        mask = rows["kind"] == kind
        left.scatter(rows["size"][mask], rows["run_s"][mask], s=4, alpha=0.3, label=kind)
        sizes = np.geomspace(rows["size"][mask].min(), rows["size"][mask].max(), 50)
        a, b = model.coef[kind]
        left.plot(sizes, np.exp(a) * sizes**b, color="black", linewidth=1)
    left.set(xscale="log", yscale="log", xlabel="size", ylabel="run time (s)")
    left.set_title(f"{split}: run time by size, with each kind's power law")
    left.legend(markerscale=4)
    running = rows["running_at_submit"]
    levels = np.arange(0, np.quantile(running, 0.99) + 1)
    medians = [
        np.median(ratio[running == r]) if (running == r).sum() >= 20 else np.nan for r in levels
    ]
    right.scatter(
        running + np.random.default_rng(1).uniform(-0.3, 0.3, len(running)), ratio, s=4, alpha=0.2
    )
    right.plot(levels, medians, color="black", marker="o", label="median")
    right.axhline(1, color="grey", linestyle="--")
    right.set(
        yscale="log",
        xlabel="jobs running when it was submitted",
        ylabel="actual / power law's prediction",
    )
    right.set_title("what size doesn't explain, by how busy the workers were")
    right.legend()
    fig.savefig(png, dpi=110, bbox_inches="tight")
~~~

### Tests

The tests build a day of synthetic jobs that wait and run for seconds, so that at most moments several are in flight. Create `lab/tests/test_dataset.py`:

<!-- file: lab/tests/test_dataset.py -->
~~~python
from datetime import UTC, datetime, timedelta

import numpy as np
import pyarrow as pa
import pytest

from lab import dataset, metrics, synth
from lab.baselines import KindMedian, KindPowerLaw, KindQuantile, Median

# Jobs that wait and run for seconds, arriving every few seconds, so that
# many overlap: the counts at submission are rarely zero.
REAL = {
    "kind": np.array(["checksum", "compress", "sort"] * 20),
    "size": np.geomspace(1e4, 1e8, 60).astype(np.int64),
    "wait_s": np.linspace(0.05, 8.0, 60),
    "run_s": np.geomspace(0.02, 20.0, 60),
}
SPEC = synth.Spec(jobs=30_000, days=1, tenants=5, seed=3)
START = SPEC.start
LONG_AFTER = START + timedelta(days=3)


@pytest.fixture(scope="module")
def data(tmp_path_factory):
    out = tmp_path_factory.mktemp("events")
    synth.make(REAL, out, SPEC)
    return out


def test_features_dont_see_the_future(data):
    """Each job's features, built at the moment it was submitted, with the rest of time unknown.

    That moment is when the API will ask for a prediction, so it's the only
    test that counts: a cut at noon would only check the few jobs in flight
    at noon.
    """
    jobs = dataset.load_jobs(data)
    full = dataset.features(jobs)
    for i in np.linspace(100, len(jobs["created"]) - 100, 25).astype(int):
        at = datetime.fromtimestamp(jobs["created"][i] / 1e6, UTC)
        then = dataset.load_jobs(data, as_of=at)
        j = np.flatnonzero(then["job_id"] == jobs["job_id"][i])[0]
        known = dataset.features(then)
        for name in dataset.FEATURES:
            assert full[name][i] == known[name][j], f"{name} saw the future"


def test_counts_are_what_was_true_just_before_submission():
    us = 1_000_000
    jobs = {  # created, started, finished, in seconds; job 3 never started
        "tenant": np.array(["a", "a", "b", "a"]),
        "kind": np.array(["sort"] * 4),
        "size": np.array([1, 2, 3, 4]),
        "created": np.array([0, 1, 2, 70]) * us,
        "started": np.ma.masked_array([5, 6, 0, 75], mask=[0, 0, 1, 0]) * us,
        "finished": np.ma.masked_array([8, 80, 0, 90], mask=[0, 0, 1, 0]) * us,
    }
    f = dataset.features(jobs)
    assert f["queued_at_submit"].tolist() == [0, 1, 2, 1]  # at 70 s, only job 3 waits
    assert f["running_at_submit"].tolist() == [0, 0, 0, 1]  # at 70 s, job 2 runs
    assert f["tenant_recent"].tolist() == [0, 1, 0, 0]  # a's jobs at 0 and 1 are > 60 s old


def test_a_finish_without_a_known_start_doesnt_lower_the_counts():
    us = 1_000_000
    jobs = {  # job 0 completed with its start unknown; job 1 runs from 20 s to 40 s
        "tenant": np.array(["a", "a", "a"]),
        "kind": np.array(["sort"] * 3),
        "size": np.array([1, 2, 3]),
        "created": np.array([0, 10, 30]) * us,
        "started": np.ma.masked_array([0, 20, 35], mask=[1, 0, 0]) * us,
        "finished": np.ma.masked_array([5, 40, 50], mask=[0, 0, 0]) * us,
    }
    assert dataset.features(jobs)["running_at_submit"].tolist() == [0, 0, 1]


def test_only_jobs_old_enough_to_have_finished_are_kept(data):
    window = dataset.Window(lateness=timedelta(minutes=5), horizon=timedelta(minutes=1))
    now = START + timedelta(hours=6)
    rows, counts = dataset.build(data, window, now=now)
    newest = rows["created_at"].to_pylist()[-1]
    assert newest <= now - timedelta(minutes=6)
    assert not np.isnan(rows["run_s"].to_numpy()).any()
    assert rows.num_rows > 6_000
    assert counts["rows"] == rows.num_rows and 0 < counts["too recent"] < 100


def test_a_finished_month_is_complete_however_recent_its_last_event(data):
    rows, counts = dataset.build(data, now=LONG_AFTER)
    assert rows.num_rows == SPEC.jobs and counts["too recent"] == 0


def test_the_time_split_keeps_the_future_out_of_training(data):
    rows = dataset.split_by_time(dataset.build(data, now=LONG_AFTER)[0])
    created = rows["created_at"].cast(pa.int64()).to_numpy()
    split = np.array(rows["split"].to_pylist())
    assert created[split == "train"].max() < created[split == "valid"].min()
    assert created[split == "valid"].max() < created[split == "test"].min()
    assert (split == "train").mean() == pytest.approx(0.6, abs=0.001)


def test_the_random_split_mixes_the_times(data):
    rows = dataset.split_at_random(dataset.build(data, now=LONG_AFTER)[0])
    created = rows["created_at"].cast(pa.int64()).to_numpy()
    split = np.array(rows["split"].to_pylist())
    assert created[split == "train"].max() > created[split == "test"].min()


def test_the_power_law_recovers_a_power_law():
    rng = np.random.default_rng(1)
    size = rng.integers(1_000, 10_000_000, 5_000)
    run = 2e-6 * size**0.8 * rng.lognormal(0, 0.1, 5_000)
    rows = {"kind": np.array(["sort"] * 5_000), "size": size, "run_s": run}
    model = KindPowerLaw().fit(rows)
    a, b = model.coef["sort"]
    assert b == pytest.approx(0.8, abs=0.01) and np.exp(a) == pytest.approx(2e-6, rel=0.1)


def test_baselines_predict_one_value_per_row():
    rows = {
        "kind": np.array(["a", "a", "b", "b"]),
        "run_s": np.array([1.0, 3.0, 10.0, 30.0]),
        "size": np.array([1, 2, 3, 4]),
    }
    assert Median().fit(rows).predict(rows).tolist() == [6.5] * 4
    assert KindMedian().fit(rows).predict(rows).tolist() == [2.0, 2.0, 20.0, 20.0]
    assert KindMedian(0.5).fit(rows).predict(rows).tolist() == [1.0, 1.0, 10.0, 10.0]
    assert KindQuantile(1.0).fit(rows).predict(rows).tolist() == [3.0, 3.0, 30.0, 30.0]


def test_mape_rewards_guessing_low_and_mae_doesnt():
    y = np.array([0.1, 0.1, 0.1, 10.0])
    low, right = np.full(4, 0.05), np.array([0.1, 0.1, 0.1, 1.0])
    assert metrics.mape(y, low) < metrics.mape(y, np.full(4, 0.2))  # half as low as doubled
    assert metrics.mae(y, right) < metrics.mae(y, low)


def test_metrics_by_hand():
    y, p = np.array([1.0, 2.0, 4.0]), np.array([2.0, 2.0, 2.0])
    assert metrics.mae(y, p) == pytest.approx(1.0)
    assert metrics.mape(y, p) == pytest.approx((100 + 0 + 50) / 3)
    assert metrics.log_error(y, p) == pytest.approx(np.exp((np.log(2) * 2) / 3))
    assert metrics.pinball(y, p, 0.9) == pytest.approx((0.1 * 1 + 0 + 0.9 * 2) / 3)
    assert metrics.coverage(y, p) == pytest.approx(2 / 3)
    assert metrics.spearman(np.array([1.0, 2, 3]), np.array([10.0, 20, 30])) == pytest.approx(1)


def test_the_block_bootstrap_is_wider_when_blocks_move_together():
    rng = np.random.default_rng(2)
    blocks = np.repeat(np.arange(50), 20)  # 50 minutes of 20 jobs
    shared = rng.normal(0, 1, 50)[blocks]  # each minute's jobs err together
    diff = shared + rng.normal(0, 0.1, 1000)
    _, lo_b, hi_b = metrics.paired_bootstrap(np.zeros(1000), diff, blocks)
    _, lo_j, hi_j = metrics.paired_bootstrap(np.zeros(1000), diff, np.arange(1000))
    assert (hi_b - lo_b) > 3 * (hi_j - lo_j), "per-job resampling understates the uncertainty"


def test_dates_in_the_fixture_start_where_synth_says(data):
    first = dataset.load_jobs(data)["created"].min() / 1e6
    assert datetime.fromtimestamp(first, UTC) >= START
~~~

`test_features_dont_see_the_future` is the one that matters. For 25 jobs spread through the day, it rebuilds everything as of the moment that job was submitted, and requires that job's features to be identical. That moment is when step 8 will ask for a prediction, so it's the only cut-off that tests what production does. A single cut at noon would only check the handful of jobs in flight at noon.

Add the commands, in `lab/src/lab/cli.py`:

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

def cmd_simulate(args: argparse.Namespace) -> int:
~~~

to:

~~~python

def cmd_dataset(args: argparse.Namespace) -> int:
    from lab import dataset

    rows, counts = dataset.build(args.data)
    print(", ".join(f"{k} {v}" for k, v in counts.items()))
    split = dataset.split_at_random if args.random_split else dataset.split_by_time
    rows = split(rows)
    dataset.save(rows, args.out)
    data = dataset.load(args.out)
    created = data["created_at"]
    print(f"{len(data['run_s'])} finished jobs, from {created.min()} to {created.max()}")
    for name in ("train", "valid", "test"):
        mask = data["split"] == name
        created = data["created_at"][mask]
        print(f"  {name:>5}: {mask.sum():>5} jobs, {created.min()} to {created.max()}")
    print(f"wrote {args.out}")
    return 0


def cmd_baselines(args: argparse.Namespace) -> int:
    from lab import dataset, evaluate
    from lab.baselines import KindMedian, KindPowerLaw, KindQuantile, Median

    data = dataset.load(args.dataset)
    points = [
        Median(),
        KindMedian(),
        KindMedian(scale=0.5),
        KindPowerLaw(),
        KindPowerLaw(contention=True),
    ]
    print(evaluate.point_report(data, points, args.split, args.reference))
    bounds = [KindQuantile(0.9), KindPowerLaw(quantile=0.9), KindPowerLaw(True, quantile=0.9)]
    print("\nUpper bounds (p90):")
    print(evaluate.bound_report(data, bounds, args.split, 0.9))
    if args.plot:
        evaluate.plot(data, args.split, args.plot)
        print(f"\nplot: {args.plot}")
    return 0


def cmd_simulate(args: argparse.Namespace) -> int:
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

    simulate = sub.add_parser(
~~~

to:

~~~python

    ds = sub.add_parser("dataset", help="build the run-time dataset from the pipeline's events")
    ds.add_argument("--data", type=Path, default=Path("data"))
    ds.add_argument("--out", type=Path, default=Path("results/dataset.parquet"))
    ds.add_argument("--random-split", action="store_true", help="split at random, not by time")
    ds.set_defaults(func=cmd_dataset)

    bl = sub.add_parser("baselines", help="fit the baselines on train, score them on a split")
    bl.add_argument("dataset", type=Path)
    bl.add_argument("--split", choices=["valid", "test"], default="valid")
    bl.add_argument("--plot", type=Path, help="write a PNG here")
    bl.add_argument("--reference", default="kind median", help="compare every model with this one")
    bl.set_defaults(func=cmd_baselines)

    simulate = sub.add_parser(
~~~


<!-- run: cd lab && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

### Run it: collect

Run the loop from "More real data" now (the cluster must be running).

~~~text
== run 1: seed 11, load 1, 10:26:31
1215 jobs over 180 s from 3 tenants
submitted: 1215 accepted, 0 refused
states: {'completed': 1215}
wrote results/s05-run1.jsonl (settings: results/s05-run1.settings.json)
== run 2: seed 12, load 2, 10:29:46
2315 jobs over 180 s from 3 tenants
submitted: 2315 accepted, 0 refused
states: {'completed': 2315}
wrote results/s05-run2.jsonl (settings: results/s05-run2.settings.json)
== run 3: seed 13, load 3, 10:33:14
3444 jobs over 180 s from 3 tenants
submitted: 3444 accepted, 0 refused
states: {'completed': 3444}
wrote results/s05-run3.jsonl (settings: results/s05-run3.settings.json)
== run 4: seed 14, load 1, 10:36:51
1190 jobs over 180 s from 3 tenants
submitted: 1190 accepted, 0 refused
states: {'completed': 1190}
wrote results/s05-run4.jsonl (settings: results/s05-run4.settings.json)
== run 5: seed 15, load 2, 10:40:05
2305 jobs over 180 s from 3 tenants
submitted: 2305 accepted, 0 refused
states: {'completed': 2305}
wrote results/s05-run5.jsonl (settings: results/s05-run5.settings.json)
== run 6: seed 16, load 3, 10:43:30
3436 jobs over 180 s from 3 tenants
submitted: 3436 accepted, 0 refused
states: {'completed': 3436}
wrote results/s05-run6.jsonl (settings: results/s05-run6.settings.json)
== run 7: seed 17, load 1, 10:47:04
1220 jobs over 180 s from 3 tenants
submitted: 1220 accepted, 0 refused
states: {'completed': 1220}
wrote results/s05-run7.jsonl (settings: results/s05-run7.settings.json)
== run 8: seed 18, load 2, 10:50:17
2438 jobs over 180 s from 3 tenants
submitted: 2438 accepted, 0 refused
states: {'completed': 2438}
wrote results/s05-run8.jsonl (settings: results/s05-run8.settings.json)
~~~

17,563 jobs, every one completed, and the pipeline has copied their events into `data/`.

### Run it: the dataset, at once and later

Build the dataset straight away, the moment the collection ends:

~~~bash
uv run --project lab lab dataset --out results/dataset-early.parquet
~~~

~~~text
jobs 17989, too recent 654, not completed 0, start unknown 7, rows 17328
17328 finished jobs, from 2026-10-17T03:21:28.582058 to 2026-10-17T10:50:01.167938
  train: 10396 jobs, 2026-10-17T03:21:28.582058 to 2026-10-17T10:40:06.738216
  valid:  3466 jobs, 2026-10-17T10:40:06.844674 to 2026-10-17T10:44:30.694921
   test:  3466 jobs, 2026-10-17T10:44:30.762591 to 2026-10-17T10:50:01.167938
wrote ../tmp/dataset-early.parquet
~~~

The window at work. Built at 10:56, it saw only events up to 10:51 (lateness), and of the 17,989 jobs it knew of, it left out the 654 created in the minute before that (horizon): some of them might still be running. Why not keep the ones that had finished? Because those are the short ones. Look back at moments during the collection, comparing the jobs submitted in the ten seconds before with the ones among them that had finished by then:

~~~bash
uv run --project lab python - <<'PY'
import numpy as np
from datetime import UTC, datetime
from pathlib import Path
from lab import dataset

jobs = dataset.load_jobs(Path("data"))  # everything, as known now
created = jobs["created"]
finished = np.ma.filled(jobs["finished"], np.iinfo(np.int64).max)
run = np.ma.filled(jobs["run_s"], np.nan)
done = jobs["state"] == "completed"
print("moment    jobs in the last 10 s  finished by then  mean run_s: of those finished  of all")
for t in np.quantile(created, np.linspace(0.1, 0.95, 8)):
    minute = (created >= t - 10e6) & (created < t) & done & ~np.isnan(run)
    seen = minute & (finished <= t)
    at = datetime.fromtimestamp(t / 1e6, UTC).strftime("%H:%M:%S")
    print(f"{at}  {minute.sum():>21}  {seen.sum():>16}  {run[seen].mean():>28.3f}  {run[minute].mean():>6.3f}")
PY
~~~

~~~text
moment    jobs in the last 10 s  finished by then  mean run_s: of those finished  of all
03:27:57                     71                71                         0.261   0.261
10:30:59                    143               140                         0.127   0.177
10:34:09                    193               185                         0.149   0.182
10:36:13                    199               196                         0.168   0.176
10:41:39                    140               136                         0.152   0.154
10:44:38                    177               174                         0.230   0.240
10:47:46                     59                59                         0.076   0.076
10:52:06                    123               120                         0.169   0.166
~~~

At 10:30:59, the jobs that had finished averaged 0.127 s, and all of them, 0.177 s: 28% short. A model trained on the finished ones learns that recent jobs are quick. (The one moment the other way, 10:52:06, is within noise: three jobs out of 123.)

Five minutes later, everything is old enough:

~~~bash
uv run --project lab lab dataset
uv run --project lab lab dataset --random-split --out results/dataset-random.parquet
~~~

~~~text
jobs 19795, too recent 0, not completed 0, start unknown 7, rows 19788
19788 finished jobs, from 2026-10-17T03:21:28.582058 to 2026-10-17T10:53:18.280106
  train: 11872 jobs, 2026-10-17T03:21:28.582058 to 2026-10-17T10:42:01.707344
  valid:  3958 jobs, 2026-10-17T10:42:01.768506 to 2026-10-17T10:46:16.232259
   test:  3958 jobs, 2026-10-17T10:46:16.282234 to 2026-10-17T10:53:18.280106
wrote results/dataset.parquet
~~~

Every job, but seven: `start unknown`. Find them:

~~~bash
sql() { uv run --project lab lab sql "$@"; }
sql "SELECT job_id, state, started_at, run_s FROM jobs WHERE state = 'completed' AND started_at IS NULL"
~~~

They're step 2's race, for real. Under load, a worker's "completed" report reached the API before its "started" one, and the API recorded what it knew: completed, start unknown. When the late "started" report came, the job had already finished, so it changed nothing, and no "running" event was ever sent. The dataset can't know their run times, so it leaves them out and says so. Seven in 17,563 is 0.04%, at loads 2 and 3 only.

### Break it: leaks

Two features that look reasonable. First, in `features`, add how busy the system was when the job *started*, and list it in `FEATURES`:

~~~python
    started_us = np.ma.filled(started, -1)
    out["running_at_start"] = np.where(
        started_us >= 0, before(starts, started_us) - before(finishes, started_us), -1
    )
~~~

~~~bash
cd lab && uv run pytest -q tests/test_dataset.py; cd ..
~~~

~~~text
E               AssertionError: running_at_start saw the future
FAILED tests/test_dataset.py::test_features_dont_see_the_future - AssertionEr...
1 failed, 12 passed in 2.33s
~~~

At the moment of submission the job hasn't started, so its start-time count doesn't exist yet. It's leakage, and a model would use it eagerly: step 2 found that contention at the start correlates at 0.5 with what size doesn't explain. Remove it.

Second, the tenant's mean run time, a classic "target encoding". Add it the obvious way, over all of the data:

~~~python
    run = np.ma.filled(jobs["run_s"], np.nan)
    out["tenant_mean_run"] = np.zeros(len(created))
    for tenant in np.unique(jobs["tenant"]):
        mine = jobs["tenant"] == tenant
        out["tenant_mean_run"][mine] = np.nanmean(run[mine])
~~~

~~~text
E               AssertionError: tenant_mean_run saw the future
FAILED tests/test_dataset.py::test_features_dont_see_the_future - AssertionEr...
FAILED tests/test_dataset.py::test_counts_are_what_was_true_just_before_submission
FAILED tests/test_dataset.py::test_a_finish_without_a_known_start_doesnt_lower_the_counts
3 failed, 10 passed in 2.16s
~~~

Its mean includes jobs that ran after the one being predicted, and the job itself: the label leaks into its own feature. (The other two failures are only the hand-made jobs in those tests having no `run_s`.) A point-in-time version would average only the tenant's jobs finished before the submission; step 6 will need that kind of feature. Remove it.

Note what caught them: the test rebuilt each job's row *as of its own submission*. A first version of that test cut the data once, at noon, and `running_at_start` passed it, because only the few jobs in flight at noon could differ, and in that test's day there were too few. In production every prediction is made at that moment, so that's the cut-off to test.

### Break it: two bugs the tests found

Both of these were in my first version of `dataset.py`, and real data found them.

First, in `load_jobs`, return `{name: np.asarray(col) for name, col in cols.items()}`: it looks like a harmless conversion.

~~~text
E               AssertionError: running_at_submit saw the future
FAILED tests/test_dataset.py::test_features_dont_see_the_future - AssertionEr...
1 failed, 12 passed in 1.88s
~~~

DuckDB returns a column with NULLs as a NumPy *masked* array. `np.asarray` keeps the values and drops the mask, so an unknown finish becomes whatever number sat under it, here 0: 1 January 1970. Every job still running at the cut-off counted as long finished. Only rows built at a moment with jobs in flight are affected, which is exactly the rows production predicts.

Second, in `features`, count every known finish, `finishes = np.sort(finished.compressed())`:

~~~text
E       assert [0, -1, 0] == [0, 0, 1]
FAILED tests/test_dataset.py::test_a_finish_without_a_known_start_doesnt_lower_the_counts
1 failed, 12 passed in 6.87s
~~~

The seven completed-with-unknown-start jobs each subtract a finish that was never preceded by a start. Every job after them sees one fewer running job per such job, and the count goes negative: in the real data, the median was -6 by the test period. The model with that feature looked *worse* than without it on validation, which is how I found it. A feature that can't be negative should be tested for being negative.

### Run it: the baselines

Fit each baseline on the training jobs and score it on the validation jobs:

~~~bash
uv run --project lab lab baselines results/dataset.parquet --plot results/s05-baselines.png
~~~

~~~text
3958 valid jobs, models trained on 11872; MAE_vs_ref compares each with kind median
                   model  MAE_s  MAPE_%  log_factor  spearman  MAE_vs_ref_s              95% CI
------------------------  -----  ------  ----------  --------  ------------  ------------------
                  median  0.143  69.182       2.308       nan       +0.0137  +0.0116 .. +0.0165
             kind median  0.129  64.757       2.017     0.507                                  
        kind median x0.5  0.145  58.431       2.825     0.507       +0.0154  +0.0110 .. +0.0205
          kind power law  0.075  38.925       1.582     0.775       -0.0541  -0.0606 .. -0.0474
kind power law + running  0.060  33.106       1.441     0.855       -0.0695  -0.0892 .. -0.0529

Upper bounds (p90):
                       model  pinball_0.9  covered_%
----------------------------  -----------  ---------
                    kind p90        0.059     87.847
          kind power law p90        0.021     85.953
kind power law + running p90        0.017     85.700

plot: results/s05-baselines.png
~~~

![Left: run time against size on log scales, one colour per kind, each with its fitted straight line; checksum lies low and shallow, compress steep, sort between. Right: actual over predicted run time against the number of jobs running at submission; the median rises from about 0.75 with none running to about 2 with eight.](images/s05-baselines.png)

Read the table a column at a time:

- **MAE.** The kind's median is wrong by 0.129 s on average; the power law in size by 0.075 s; adding the jobs running at submission, 0.060 s. Each improvement's 95% interval excludes zero.
- **MAPE.** Look at `kind median x0.5`: it guesses half the median, every time. Its MAE and log error are worse than the median's, but its MAPE is *better*, 58% against 65%. MAPE can't be wrong by more than 100% when it guesses low, and can be wrong by any amount when it guesses high, so it rewards guessing low. A model tuned for MAPE learns to under-predict. Never choose a model by MAPE alone.
- **log_factor.** The power law with contention is typically off by a factor of 1.44 either way. For a job that will take 0.1 s, that's 0.07 to 0.14 s.
- **spearman.** 0.855: it puts most pairs of jobs in the right order, which is what shortest-job-first needs (step 9). The kind median, 0.507, can only order kinds.

The plot shows why contention helps. On the right, a job submitted with nothing running takes about 0.75 of what its size predicts; with eight running, about twice. Size alone averages over that.

Is contention worth its parameter? Compare the two power laws directly:

~~~bash
uv run --project lab lab baselines results/dataset.parquet --reference "kind power law" | head -9
~~~

~~~text
3958 valid jobs, models trained on 11872; MAE_vs_ref compares each with kind power law
                   model  MAE_s  MAPE_%  log_factor  spearman  MAE_vs_ref_s              95% CI
------------------------  -----  ------  ----------  --------  ------------  ------------------
                  median  0.143  69.182       2.308       nan       +0.0678  +0.0590 .. +0.0762
             kind median  0.129  64.757       2.017     0.507       +0.0541  +0.0474 .. +0.0606
        kind median x0.5  0.145  58.431       2.825     0.507       +0.0695  +0.0582 .. +0.0808
          kind power law  0.075  38.925       1.582     0.775                                  
kind power law + running  0.060  33.106       1.441     0.855       -0.0154  -0.0286 .. -0.0038

~~~

0.0154 s better, between 0.0038 and 0.0286 with 95% confidence. That interval resamples whole minutes. Resample single jobs instead, as if each were independent:

~~~text
resampling whole minutes: -0.0154 s, 95% CI -0.0286 .. -0.0038 (width 0.0249)
resampling   single jobs: -0.0154 s, 95% CI -0.0184 .. -0.0127 (width 0.0056)
~~~

Four times narrower, and wrong: jobs in the same minute share a queue and workers, so they're one piece of evidence each minute, not dozens.

### Run it: the upper bounds, and a random split

The bounds, from the same table: `kind power law + running p90` has the lowest pinball loss, but covers only 85.7% of validation jobs, not 90%. Why? Compare how busy the system was in each split:

~~~text
train mean running at submit 2.65
valid mean running at submit 3.23
test mean running at submit 2.14
~~~

The validation period was busier on average than the training period (it's mostly run 6, at load 3), so jobs ran longer than the bounds allowed for. Now score the same models on the random split:

~~~bash
uv run --project lab lab baselines results/dataset-random.parquet
~~~

~~~text
3917 valid jobs, models trained on 11914; MAE_vs_ref compares each with kind median
                   model  MAE_s  MAPE_%  log_factor  spearman  MAE_vs_ref_s              95% CI
------------------------  -----  ------  ----------  --------  ------------  ------------------
                  median  0.150  80.689       2.333       nan       +0.0139  +0.0113 .. +0.0162
             kind median  0.136  71.190       1.992     0.543                                  
        kind median x0.5  0.148  54.996       2.534     0.543       +0.0121  +0.0070 .. +0.0164
          kind power law  0.082  47.336       1.597     0.774       -0.0542  -0.0635 .. -0.0436
kind power law + running  0.067  36.582       1.425     0.878       -0.0689  -0.0803 .. -0.0564

Upper bounds (p90):
                       model  pinball_0.9  covered_%
----------------------------  -----------  ---------
                    kind p90        0.066     90.146
          kind power law p90        0.027     89.660
kind power law + running p90        0.019     89.967
~~~

The bounds cover 89.7 to 90.1%: perfectly calibrated, apparently. Training and validation were drawn from the same mix of quiet and busy minutes, so the random split *can't* show that the future may be busier than the past. The point errors don't look much better here; what the random split hides is the shift. A random split answers "how good is this on jobs like the ones it saw?", not "how good will it be next week?".

### Run it: the test, once

The validation set chose the model: the power law with contention, for the typical time and for the bound. Now score it on the test set, once:

~~~bash
uv run --project lab lab baselines results/dataset.parquet --split test --reference "kind power law"
~~~

~~~text
3958 test jobs, models trained on 11872; MAE_vs_ref compares each with kind power law
                   model  MAE_s  MAPE_%  log_factor  spearman  MAE_vs_ref_s              95% CI
------------------------  -----  ------  ----------  --------  ------------  ------------------
                  median  0.132  81.434       2.299       nan       +0.0638  +0.0435 .. +0.0820
             kind median  0.122  76.921       2.002     0.511       +0.0536  +0.0364 .. +0.0679
        kind median x0.5  0.129  54.306       2.424     0.511       +0.0607  +0.0368 .. +0.0823
          kind power law  0.068  48.754       1.594     0.780                                  
kind power law + running  0.053  34.328       1.418     0.879       -0.0145  -0.0208 .. -0.0103

Upper bounds (p90):
                       model  pinball_0.9  covered_%
----------------------------  -----------  ---------
                    kind p90        0.062     90.323
          kind power law p90        0.024     90.955
kind power law + running p90        0.016     89.161
~~~

MAE 0.053 s, 0.0145 s better than size alone (0.010 to 0.021). The p90 covers 89.2%, because the test period was quieter than training (mean 2.14 running, against 2.65). The same bound covered 86% of a busier period and 89% of a quieter one: a bound learned from the past holds only while the future resembles it. Step 6's models will learn the effect of contention better, and step 11 watches for the day the future stops resembling the past.

These are the numbers to beat. Step 6's gradient-boosted trees, with every feature, must beat MAE 0.053 and log factor 1.42 on this test set, by more than these intervals, or they aren't worth their complexity.

**Explain it:** what makes a feature leak, and why does a test that rebuilds each row as of its own submission catch leaks a single cut-off misses? Why leave out *all* recent jobs, not just the unfinished ones? Why does the window run from the clock, not from the newest event? Which of MAE, MAPE, log error and rank correlation suits shortest-job-first, and which an ETA? How can a model win on MAPE by being worse? Why resample whole minutes? What did the random split hide, and why couldn't it show it? Why did the same p90 cover 86% of one period and 89% of another?

**Read.** Shachar Kaufman, Saharon Rosset and Claudia Perlich, *Leakage in Data Mining: Formulation, Detection, and Avoidance* (KDD 2011): the kinds of leak, with real cases from competitions. Rob Hyndman and George Athanasopoulos, *Forecasting: Principles and Practice*, chapter 5, the sections on evaluating forecast accuracy (why percentage errors mislead) and on time series cross-validation. Roger Koenker and Kevin Hallock, *Quantile Regression* (Journal of Economic Perspectives, 2001): what pinball loss is minimised by, and why.

---
## Step 6: Gradient-boosted trees, honestly compared

**The problem.** Step 5 left a bar: the power law with contention, typically off by a factor of 1.42 on the test set, MAE 0.053 s. The usual next move is a machine-learning library and a stronger model. This step does that properly with scikit-learn. One object holds the features' preparation and the model, so nothing leaks between rows. Hyperparameters are chosen on the training rows only, in time order. Every gain carries an interval, errors are broken down by slice, and an upper bound is calibrated. Then it asks whether all of that was worth it.

**New ideas.**

- **A pipeline.** Preparing features (encoding categories, scaling) is part of the model: it learns from data. Fit it on the training rows alone, inside the same object as the model, so validation and test rows never shape it, and so serving (step 8) applies exactly what training learned.
- **Gradient-boosted trees.** A sum of hundreds of small decision trees, each fitted to what the trees before it got wrong. Trees split on order, not distance, so they need no log of size, find thresholds and interactions a straight line can't, and handle missing values. `HistGradientBoostingRegressor` first bins each feature into at most 256 values, which makes it fast.
- **Fit to the error you care about.** The trees learn log(run time), like the power law, so they minimise "times too long or short", and exp(prediction) is a median. With **quantile loss** the same trees learn a p90 instead.
- **Tuning without leaks.** Choose hyperparameters by cross-validation *within the training rows*, never on the test set. And choose the folds as the model will be used: **time-ordered folds** train on the past and score on what followed; shuffled folds train on the minutes around the ones they score, and promise too much.
- **Conformal calibration.** Measure on recent data how far actual values overshoot a bound, and raise the bound by that much. If the future resembles that recent data (the technical word is **exchangeable**), the bound then holds as often as promised, whatever the model got wrong. If it doesn't, nothing is promised.
- **Slices.** An average hides where a model fails. Score it per kind, per tenant and per load, and look at the worst slice, because that's someone's experience.
- **Permutation importance.** Shuffle one feature's values and see how much worse the fitted model gets. It measures how much *this model* relies on the feature, not whether the feature is needed: two features carrying the same information can each look essential.

### A tenant's history, point in time

Step 5 removed a leaky tenant average. Here's the point-in-time version: for each job, the mean log run time of the same tenant's jobs *of the same kind* that had **finished** before it was submitted. In `lab/src/lab/dataset.py`:

Change:

<!-- edit: lab/src/lab/dataset.py -->
~~~python
FEATURES = ["tenant", "kind", "size", "running_at_submit", "queued_at_submit", "tenant_recent"]
~~~

to:

~~~python
FEATURES = [
    "tenant",
    "kind",
    "size",
    "running_at_submit",
    "queued_at_submit",
    "tenant_recent",
    "history_log_run",
]
~~~

Change:

<!-- edit: lab/src/lab/dataset.py -->
~~~python
        out["tenant_recent"][mine] = recent
    return out
~~~

to:

~~~python
        out["tenant_recent"][mine] = recent
    out["history_log_run"] = history(jobs)
    return out


def history(jobs: dict[str, np.ndarray]) -> np.ndarray:
    """Per job: the mean log run time of the same tenant's jobs of the same kind
    that had finished before it was submitted (NaN if there were none).

    A target encoding done point in time: only finished jobs count, and
    only those finished before the moment of the question.
    """
    created = jobs["created"]
    finished = np.ma.filled(np.ma.asarray(jobs["finished"]), np.iinfo(np.int64).max)
    log_run = np.log(np.ma.filled(np.ma.asarray(jobs["run_s"]), np.nan))
    out = np.full(len(created), np.nan)
    pairs = np.char.add(np.asarray(jobs["tenant"], str), "/" + np.asarray(jobs["kind"], str))
    for pair in np.unique(pairs):
        mine = pairs == pair
        known = mine & ~np.isnan(log_run)
        if not known.any():
            continue  # none of this pair's jobs has finished: all NaN
        order = np.argsort(finished[known])
        times, sums = finished[known][order], np.cumsum(log_run[known][order])
        n = np.searchsorted(times, created[mine], side="left")  # finished strictly before
        with np.errstate(invalid="ignore", divide="ignore"):
            out[mine] = np.where(n > 0, sums[np.maximum(n - 1, 0)] / n, np.nan)
    return out
~~~


It's step 5's counting trick again: sort the finished jobs by when they finished, keep a running sum, and binary-search each submission time. Add a test of it by hand, and give the hand-made jobs in the other tests run times, which `history` needs. In `lab/tests/test_dataset.py`:

Change:

<!-- edit: lab/tests/test_dataset.py -->
~~~python
        "finished": np.ma.masked_array([8, 80, 0, 90], mask=[0, 0, 1, 0]) * us,
    }
~~~

to:

~~~python
        "finished": np.ma.masked_array([8, 80, 0, 90], mask=[0, 0, 1, 0]) * us,
        "run_s": np.ma.masked_array([3.0, 74.0, 0, 15.0], mask=[0, 0, 1, 0]),
    }
~~~

Change:

<!-- edit: lab/tests/test_dataset.py -->
~~~python
        "finished": np.ma.masked_array([5, 40, 50], mask=[0, 0, 0]) * us,
    }
    assert dataset.features(jobs)["running_at_submit"].tolist() == [0, 0, 1]

~~~

to:

~~~python
        "finished": np.ma.masked_array([5, 40, 50], mask=[0, 0, 0]) * us,
        "run_s": np.ma.masked_array([0, 20.0, 15.0], mask=[1, 0, 0]),
    }
    assert dataset.features(jobs)["running_at_submit"].tolist() == [0, 0, 1]


def test_history_averages_only_jobs_finished_before_submission():
    us = 1_000_000
    jobs = {  # tenant a's sorts: 1 s (done at 11 s), 4 s (done at 26 s), then two more
        "tenant": np.array(["a", "a", "a", "a", "b"]),
        "kind": np.array(["sort", "sort", "sort", "sort", "sort"]),
        "created": np.array([0, 20, 25, 30, 30]) * us,
        "finished": np.ma.masked_array([11, 26, 0, 40, 35], mask=[0, 0, 1, 0, 0]) * us,
        "run_s": np.ma.masked_array([1.0, 4.0, 0, 9.0, 2.0], mask=[0, 0, 1, 0, 0]),
    }
    h = dataset.history(jobs)
    assert np.isnan(h[0]) and np.isnan(h[4]), "nothing finished before them"
    assert h[1] == pytest.approx(0.0) and h[2] == pytest.approx(0.0)  # log 1
    assert h[3] == pytest.approx(np.log(4) / 2)  # mean of log 1 and log 4

~~~


`test_features_dont_see_the_future` now checks the new feature too, because it's in `FEATURES`. That's the point of having written it.

**Break it.** In `history`, sort and search by when jobs were *created* rather than when they *finished*: `order = np.argsort(created[known])` and `times = created[known][order]`. A job submitted before this one but still running counts with its run time, which nobody knew yet.

~~~text
E               AssertionError: history_log_run saw the future
E         comparison failed
E         comparison failed
FAILED tests/test_dataset.py::test_features_dont_see_the_future - AssertionEr...
FAILED tests/test_dataset.py::test_history_averages_only_jobs_finished_before_submission
2 failed, 12 passed in 4.05s
~~~

Put it back. Rebuild the dataset with the new column:

~~~bash
uv run --project lab lab dataset
~~~

~~~text
jobs 19795, too recent 0, not completed 0, start unknown 7, rows 19788
19788 finished jobs, from 2026-10-17T03:21:28.582058 to 2026-10-17T10:53:18.280106
  train: 11872 jobs, 2026-10-17T03:21:28.582058 to 2026-10-17T10:42:01.707344
  valid:  3958 jobs, 2026-10-17T10:42:01.768506 to 2026-10-17T10:46:16.232259
   test:  3958 jobs, 2026-10-17T10:46:16.282234 to 2026-10-17T10:53:18.280106
wrote results/dataset.parquet
~~~

### The model

scikit-learn and pandas (scikit-learn takes columns by name from a DataFrame). In `lab/pyproject.toml`:

Change:

<!-- edit: lab/pyproject.toml -->
~~~toml
    "numpy>=2.5.4",
    "pyarrow>=26.0.0",
~~~

to:

~~~toml
    "numpy>=2.5.4",
    "pandas>=3.0.6",
    "pyarrow>=26.0.0",
~~~

Change:

<!-- edit: lab/pyproject.toml -->
~~~toml
    "rfc3339-validator>=0.1.4",
]
~~~

to:

~~~toml
    "rfc3339-validator>=0.1.4",
    "scikit-learn>=1.9.1",
]
~~~


Create `lab/src/lab/model.py`:

<!-- file: lab/src/lab/model.py -->
~~~python
"""Gradient-boosted trees for run time, as scikit-learn pipelines.

A pipeline is the features' preparation and the model as one object: fit
learns both from the training rows only, and predict applies both, so
nothing about the validation or test rows (a category's code, a scale)
can leak into training. Step 8 serves the same object.

The trees learn log(run time), as the power law did: errors in log space
are "times too long or too short", the same at every size, and the
prediction exp(mean log) estimates the median, not the mean.
"""

import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer, TransformedTargetRegressor
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.metrics import make_scorer
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OrdinalEncoder

Rows = dict[str, np.ndarray]

CATEGORIES = ["tenant", "kind"]
NUMBERS = ["size", "running_at_submit", "queued_at_submit", "tenant_recent", "history_log_run"]


def frame(rows: Rows, features: list[str]) -> pd.DataFrame:
    return pd.DataFrame({name: rows[name] for name in features})


def pipeline(features: list[str], **params) -> Pipeline:
    """Categories to codes (unknown ones to NaN), numbers as they are, then the trees.

    Trees split on order, so size needs no log here (a power law needs
    it); and they treat the codes as categories, not as numbers.
    """
    cats = [f for f in features if f in CATEGORIES]
    nums = [f for f in features if f not in CATEGORIES]
    prepare = ColumnTransformer(
        [
            (
                "categories",
                OrdinalEncoder(handle_unknown="use_encoded_value", unknown_value=np.nan),
                cats,
            ),
            ("numbers", "passthrough", nums),
        ]
    )
    trees = HistGradientBoostingRegressor(
        categorical_features=list(range(len(cats))), random_state=1, **params
    )
    return Pipeline([("prepare", prepare), ("trees", trees)])


class Boosted:
    """Gradient-boosted trees on log(run time); with quantile, an upper bound."""

    def __init__(self, name: str, features: list[str], quantile: float | None = None, **params):
        self.name, self.features, self.quantile, self.params = name, features, quantile, params

    def estimator(self) -> TransformedTargetRegressor:
        params = dict(self.params)
        if self.quantile:
            # A quantile of log(time) is the log of the quantile of time.
            params |= {"loss": "quantile", "quantile": self.quantile}
        return TransformedTargetRegressor(
            pipeline(self.features, **params), func=np.log, inverse_func=np.exp
        )

    def fit(self, rows: Rows) -> "Boosted":
        self.fitted = self.estimator().fit(frame(rows, self.features), rows["run_s"])
        return self

    def predict(self, rows: Rows) -> np.ndarray:
        return self.fitted.predict(frame(rows, self.features))


class Conformal:
    """Split conformal calibration of an upper bound (Romano, Patterson and Candès, 2019).

    Fit the model on the older part of the training rows, then measure, on
    the newest part, how far actual run times overshoot its bound (in log
    space). Raise the bound by the overshoot that only (1 - q) of those
    jobs exceed. If tomorrow resembles that recent past, a q bound then
    holds for q of jobs, whatever the model got wrong.
    """

    def __init__(self, model, q: float, calibrate: float = 0.25):
        self.model, self.q, self.calibrate = model, q, calibrate
        self.name = model.name + " conformal"

    def fit(self, rows: Rows) -> "Conformal":
        n = len(rows["run_s"])
        cut = int(n * (1 - self.calibrate))  # rows are in time order
        older = {k: v[:cut] for k, v in rows.items()}
        newer = {k: v[cut:] for k, v in rows.items()}
        self.model.fit(older)
        overshoot = np.log(newer["run_s"]) - np.log(self.model.predict(newer))
        m = len(overshoot)
        level = min(1.0, np.ceil((m + 1) * self.q) / m)
        self.lift = float(np.quantile(overshoot, level, method="higher"))
        return self

    def predict(self, rows: Rows) -> np.ndarray:
        return self.model.predict(rows) * np.exp(self.lift)


def log_error(y: np.ndarray, pred: np.ndarray) -> float:
    return float(np.mean(np.abs(np.log(pred) - np.log(y))))


# For scikit-learn's model selection: higher is better, so the negative.
LOG_ERROR = make_scorer(log_error, greater_is_better=False)
~~~

Three things to notice. `OrdinalEncoder` maps each tenant and kind to a code, and maps a value it never saw in training to "missing", which the trees handle: a new tenant gets a prediction instead of an error. `TransformedTargetRegressor` takes the log of run time before fitting and the exponential after predicting, so callers deal in seconds. And `Conformal` fits on the older three quarters of the training rows, measures overshoot on the newest quarter, and lifts the bound by the 90th percentile of that overshoot.

Create `lab/src/lab/tune.py`:

<!-- file: lab/src/lab/tune.py -->
~~~python
"""Choosing hyperparameters on the training rows only, and how the choice of folds misleads.

Cross-validation scores each candidate on parts of the training rows held
out in turn. Shuffled K-fold holds out random rows, so every fold trains
on the minutes around the ones it's tested on: the same burst, the same
busy workers. Time-ordered folds (TimeSeriesSplit) always train on the
past and test on what came after, as the model will be used.
"""

import itertools
import time

import numpy as np
from sklearn.model_selection import KFold, TimeSeriesSplit, cross_val_score

from lab import model
from lab.warehouse import table

GRID = {
    "learning_rate": [0.03, 0.1, 0.3],
    "max_leaf_nodes": [7, 31, 127],
    "min_samples_leaf": [5, 50],
}


def candidates() -> list[dict]:
    return [dict(zip(GRID, values, strict=True)) for values in itertools.product(*GRID.values())]


def search(rows, folds, features: list[str]) -> list[tuple[float, dict]]:
    """Every candidate's cross-validated log error on these rows, best first."""
    x, y = model.frame(rows, features), rows["run_s"]
    scored = []
    for params in candidates():
        est = model.Boosted("trees", features, **params).estimator()
        score = -cross_val_score(est, x, y, cv=folds, scoring=model.LOG_ERROR).mean()
        scored.append((score, params))
    return sorted(scored, key=lambda s: s[0])


def report(train, valid, features: list[str]) -> str:
    """For each way of folding: its best candidate, its CV score, and that candidate on valid."""
    rows = []
    for name, folds in [
        ("shuffled 5-fold", KFold(5, shuffle=True, random_state=1)),
        ("time-ordered 5-fold", TimeSeriesSplit(5)),
    ]:
        start = time.monotonic()
        scored = search(train, folds, features)
        cv, params = scored[0]
        m = model.Boosted("trees", features, **params).fit(train)
        actual = model.log_error(valid["run_s"], m.predict(valid))
        rows.append([name, _short(params), np.exp(cv), np.exp(actual), time.monotonic() - start])
    names = ["folds", "best (lr, leaves, min_leaf)", "cv_factor", "valid_factor", "seconds"]
    return table(names, rows)


def _short(params: dict) -> str:
    return f"{params['learning_rate']:g}, {params['max_leaf_nodes']}, {params['min_samples_leaf']}"
~~~

Eighteen candidates (learning rate, tree size, smallest leaf), each scored by five-fold cross-validation on the training rows, once with shuffled folds and once in time order. Each way's winner is then fitted on all the training rows and scored on validation, to see which promise was kept.

Add slices and importance to the evaluation, and let the comparison use log error as well as seconds. Most of `point_report` changes, so here is the whole of `lab/src/lab/evaluate.py`:

<!-- file: lab/src/lab/evaluate.py -->
~~~python
"""Fit models on the training rows and score them on another split, with honest uncertainty."""

import numpy as np

from lab import metrics
from lab.warehouse import table

Rows = dict[str, np.ndarray]


def rows_of(data: Rows, split: str) -> Rows:
    mask = data["split"] == split
    return {k: v[mask] for k, v in data.items()}


def minutes(rows: Rows) -> np.ndarray:
    """Each job's block for the bootstrap: the minute it was created in."""
    return rows["created_at"].astype("datetime64[m]").astype(np.int64)


def point_report(
    data: Rows, models: list, split: str, reference: str = "kind median", compare: str = "MAE"
) -> str:
    """Models of a typical run time: their errors, and each against the reference model.

    compare is the error the comparison column uses: "MAE" (seconds) or
    "log" (|log(prediction / actual)|, the error the power laws and trees
    are fitted to minimise).
    """
    reference = [m.name for m in models].index(reference)
    train, rows = rows_of(data, "train"), rows_of(data, split)
    y = rows["run_s"]
    preds = [m.fit(train).predict(rows) for m in models]
    column = "MAE_vs_ref_s" if compare == "MAE" else "logerr_vs_ref"
    names = ["model", "MAE_s", "MAPE_%", "log_factor", "spearman", column, "95% CI"]

    def errors(p: np.ndarray) -> np.ndarray:
        return np.abs(p - y) if compare == "MAE" else np.abs(np.log(p / y))

    out = []
    ref_err = errors(preds[reference])
    for m, p in zip(models, preds, strict=True):
        diff, low, high = metrics.paired_bootstrap(ref_err, errors(p), minutes(rows))
        ci = "" if m is models[reference] else f"{low:+.4f} .. {high:+.4f}"
        spearman = metrics.spearman(y, p) if np.ptp(p) > 0 else float("nan")
        out.append(
            [m.name, metrics.mae(y, p), metrics.mape(y, p), metrics.log_error(y, p), spearman]
        )
        out[-1] += ["" if m is models[reference] else f"{diff:+.4f}", ci]
    head = f"{len(y)} {split} jobs, models trained on {len(train['run_s'])}"
    label = "MAE_vs_ref" if compare == "MAE" else "logerr_vs_ref"
    head += f"; {label} compares each with {models[reference].name}"
    return head + "\n" + table(names, out)


def bound_report(data: Rows, models: list, split: str, q: float) -> str:
    """Models of an upper bound (the q-th quantile): pinball loss, and how often they held."""
    train, rows = rows_of(data, "train"), rows_of(data, split)
    y = rows["run_s"]
    out = []
    for m in models:
        p = m.fit(train).predict(rows)
        out.append([m.name, metrics.pinball(y, p, q), metrics.coverage(y, p) * 100])
    return table(["model", f"pinball_{q:g}", "covered_%"], out)


def plot(data: Rows, split: str, png) -> None:
    """Left: run time against size, per kind, with the power law. Right: what it misses, by load."""
    from matplotlib.figure import Figure

    from lab.baselines import KindPowerLaw

    train, rows = rows_of(data, "train"), rows_of(data, split)
    model = KindPowerLaw().fit(train)
    ratio = rows["run_s"] / model.predict(rows)
    fig = Figure(figsize=(11, 4.5))
    left, right = fig.subplots(1, 2)
    for kind in np.unique(rows["kind"]):
        mask = rows["kind"] == kind
        left.scatter(rows["size"][mask], rows["run_s"][mask], s=4, alpha=0.3, label=kind)
        sizes = np.geomspace(rows["size"][mask].min(), rows["size"][mask].max(), 50)
        a, b = model.coef[kind]
        left.plot(sizes, np.exp(a) * sizes**b, color="black", linewidth=1)
    left.set(xscale="log", yscale="log", xlabel="size", ylabel="run time (s)")
    left.set_title(f"{split}: run time by size, with each kind's power law")
    left.legend(markerscale=4)
    running = rows["running_at_submit"]
    levels = np.arange(0, np.quantile(running, 0.99) + 1)
    medians = [
        np.median(ratio[running == r]) if (running == r).sum() >= 20 else np.nan for r in levels
    ]
    right.scatter(
        running + np.random.default_rng(1).uniform(-0.3, 0.3, len(running)), ratio, s=4, alpha=0.2
    )
    right.plot(levels, medians, color="black", marker="o", label="median")
    right.axhline(1, color="grey", linestyle="--")
    right.set(
        yscale="log",
        xlabel="jobs running when it was submitted",
        ylabel="actual / power law's prediction",
    )
    right.set_title("what size doesn't explain, by how busy the workers were")
    right.legend()
    fig.savefig(png, dpi=110, bbox_inches="tight")


def load_band(running: np.ndarray) -> np.ndarray:
    """How busy the workers were when the job arrived, in four bands."""
    return np.select([running <= 1, running <= 3, running <= 5], ["0-1", "2-3", "4-5"], "6+")


def slice_report(data: Rows, models: list, split: str) -> str:
    """Each model's typical factor off, per kind, tenant and load band: where does it fail?"""
    train, rows = rows_of(data, "train"), rows_of(data, split)
    y = rows["run_s"]
    preds = [m.fit(train).predict(rows) for m in models]
    slices = [("kind", rows["kind"]), ("tenant", rows["tenant"])]
    slices.append(("load", load_band(rows["running_at_submit"])))
    out = []
    for by, values in slices:
        for value in np.unique(values):
            mask = values == value
            out.append([by, value, int(mask.sum())])
            out[-1] += [metrics.log_error(y[mask], p[mask]) for p in preds]
    return table(["slice", "value", "jobs"] + [m.name for m in models], out)


def importance(data: Rows, boosted, split: str, repeats: int = 5) -> str:
    """How much worse the fitted trees get when each feature's values are shuffled."""
    from sklearn.inspection import permutation_importance

    from lab.model import LOG_ERROR, frame

    rows = rows_of(data, split)
    x = frame(rows, boosted.features)
    result = permutation_importance(
        boosted.fitted, x, rows["run_s"], scoring=LOG_ERROR, n_repeats=repeats, random_state=1
    )
    order = np.argsort(-result.importances_mean)
    out = [
        [boosted.features[i], result.importances_mean[i], result.importances_std[i]] for i in order
    ]
    return table(["feature", "log_error_increase", "std"], out)
~~~

Add the commands, in `lab/src/lab/cli.py`:

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

def cmd_simulate(args: argparse.Namespace) -> int:
~~~

to:

~~~python

def cmd_train(args: argparse.Namespace) -> int:
    from lab import dataset, evaluate
    from lab.baselines import KindPowerLaw
    from lab.model import CATEGORIES, NUMBERS, Boosted, Conformal

    data = dataset.load(args.dataset)
    every = CATEGORIES + NUMBERS
    points = [
        KindPowerLaw(contention=True),
        Boosted("trees", [f for f in every if f != "history_log_run"]),
        Boosted("trees + history", every),
    ]
    for compare in ("MAE", "log"):
        print(evaluate.point_report(data, points, args.split, "kind power law + running", compare))
        print()
    bounds = [
        KindPowerLaw(contention=True, quantile=0.9),
        Boosted("trees p90", every, quantile=0.9),
        Conformal(Boosted("trees p90", every, quantile=0.9), 0.9),
    ]
    print("Upper bounds (p90):")
    print(evaluate.bound_report(data, bounds, args.split, 0.9))
    print("\nTypical factor off, by slice:")
    print(evaluate.slice_report(data, points, args.split))
    print("\nPermutation importance (trees + history):")
    print(evaluate.importance(data, points[2], args.split))
    return 0


def cmd_tune(args: argparse.Namespace) -> int:
    from lab import dataset, evaluate, tune
    from lab.model import CATEGORIES, NUMBERS

    data = dataset.load(args.dataset)
    train, valid = evaluate.rows_of(data, "train"), evaluate.rows_of(data, "valid")
    print(f"{len(tune.candidates())} candidates, each cross-validated on the training rows:")
    print(tune.report(train, valid, CATEGORIES + NUMBERS))
    return 0


def cmd_simulate(args: argparse.Namespace) -> int:
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

    simulate = sub.add_parser(
~~~

to:

~~~python

    tr = sub.add_parser("train", help="gradient-boosted trees against the best baseline")
    tr.add_argument("dataset", type=Path)
    tr.add_argument("--split", choices=["valid", "test"], default="valid")
    tr.set_defaults(func=cmd_train)

    tu = sub.add_parser("tune", help="search hyperparameters with shuffled and time-ordered folds")
    tu.add_argument("dataset", type=Path)
    tu.set_defaults(func=cmd_tune)

    simulate = sub.add_parser(
~~~


### Tests

The tests make jobs whose run time is a power law in size, slowed 2.5 times once six or more jobs are running: a step no straight line can follow. Then they check that the trees find it, that a p90 covers about 90% of jobs from the same world, that conformal calibration repairs a bound that's too low, and that a new tenant or a missing history doesn't break anything. Create `lab/tests/test_model.py`:

<!-- file: lab/tests/test_model.py -->
~~~python
import numpy as np
import pytest

from lab import metrics, tune
from lab.baselines import KindPowerLaw
from lab.model import CATEGORIES, NUMBERS, Boosted, Conformal

FEATURES = CATEGORIES + NUMBERS


def jobs(n: int, seed: int) -> dict[str, np.ndarray]:
    """Run time = a power law in size, slowed 2.5 times once six or more jobs are running."""
    rng = np.random.default_rng(seed)
    size = rng.integers(10_000, 10_000_000, n)
    running = rng.integers(0, 10, n)
    slow = np.where(running >= 6, 2.5, 1.0)  # a step: no straight line fits it; trees can
    return {
        "tenant": rng.choice(["acme", "globex"], n),
        "kind": rng.choice(["sort", "compress"], n),
        "size": size,
        "running_at_submit": running,
        "queued_at_submit": rng.integers(0, 5, n),
        "tenant_recent": rng.integers(0, 50, n),
        "history_log_run": rng.normal(-2, 1, n),
        "run_s": 1e-5 * size**0.8 * slow * rng.lognormal(0, 0.1, n),
    }


@pytest.fixture(scope="module")
def train():
    return jobs(6_000, 1)


@pytest.fixture(scope="module")
def later():
    return jobs(4_000, 2)  # the same world, later: tomorrow resembles today


def test_trees_find_what_a_straight_line_cant(train, later):
    trees = Boosted("trees", FEATURES).fit(train).predict(later)
    line = KindPowerLaw(contention=True).fit(train).predict(later)
    y = later["run_s"]
    assert metrics.log_error(y, trees) < metrics.log_error(y, line) - 0.02
    assert metrics.log_error(y, trees) < 1.15  # the noise alone is about 1.08


def test_a_p90_from_trees_covers_about_90_percent(train, later):
    bound = Boosted("p90", FEATURES, quantile=0.9).fit(train).predict(later)
    assert metrics.coverage(later["run_s"], bound) == pytest.approx(0.9, abs=0.03)


def test_conformal_repairs_a_bound_that_is_too_low(train, later):
    low = Boosted("p50 as a bound", FEATURES, quantile=0.5)  # covers only half
    assert metrics.coverage(later["run_s"], low.fit(train).predict(later)) < 0.6
    repaired = Conformal(Boosted("p50 as a bound", FEATURES, quantile=0.5), 0.9).fit(train)
    assert repaired.lift > 0
    assert metrics.coverage(later["run_s"], repaired.predict(later)) == pytest.approx(0.9, abs=0.03)


def test_a_tenant_never_seen_in_training_still_gets_a_prediction(train):
    model = Boosted("trees", FEATURES).fit(train)
    new = {k: v[:3].copy() for k, v in train.items()}
    new["tenant"] = np.array(["hooli"] * 3)
    pred = model.predict(new)
    assert np.all(np.isfinite(pred)) and np.all(pred > 0)


def test_missing_history_is_allowed(train):
    model = Boosted("trees", FEATURES).fit(train)
    first = {k: v[:3].copy() for k, v in train.items()}
    first["history_log_run"] = np.full(3, np.nan)  # a tenant's first job of a kind
    assert np.all(np.isfinite(model.predict(first)))


def test_the_grid_has_every_combination():
    assert len(tune.candidates()) == 3 * 3 * 2
~~~

<!-- run: cd lab && uv sync && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

**Break it.** In `pipeline`, use a plain `OrdinalEncoder()`:

~~~text
E                   ValueError: Found unknown categories ['hooli'] in column 0 during transform
FAILED tests/test_model.py::test_a_tenant_never_seen_in_training_still_gets_a_prediction
1 failed, 5 passed in 8.53s
~~~

Training never saw tenant `hooli`, so the encoder refuses it, and in production that's an error for every job of every new customer, on their first day. Put `handle_unknown` back.

### Run it: the trees against the bar

Train on the training rows and score on validation:

~~~bash
uv run --project lab lab train results/dataset.parquet
~~~

~~~text
3958 valid jobs, models trained on 11872; MAE_vs_ref compares each with kind power law + running
                   model  MAE_s  MAPE_%  log_factor  spearman  MAE_vs_ref_s              95% CI
------------------------  -----  ------  ----------  --------  ------------  ------------------
kind power law + running  0.060  33.106       1.441     0.855                                  
                   trees  0.056  34.263       1.382     0.885       -0.0040  -0.0098 .. +0.0010
         trees + history  0.055  33.308       1.380     0.886       -0.0044  -0.0120 .. +0.0022

3958 valid jobs, models trained on 11872; logerr_vs_ref compares each with kind power law + running
                   model  MAE_s  MAPE_%  log_factor  spearman  logerr_vs_ref              95% CI
------------------------  -----  ------  ----------  --------  -------------  ------------------
kind power law + running  0.060  33.106       1.441     0.855                                   
                   trees  0.056  34.263       1.382     0.885        -0.0424  -0.0726 .. -0.0273
         trees + history  0.055  33.308       1.380     0.886        -0.0436  -0.0704 .. -0.0287

Upper bounds (p90):
                       model  pinball_0.9  covered_%
----------------------------  -----------  ---------
kind power law + running p90        0.017     85.700
                   trees p90        0.017     86.230
         trees p90 conformal        0.022     76.933

Typical factor off, by slice:
 slice     value  jobs  kind power law + running  trees  trees + history
------  --------  ----  ------------------------  -----  ---------------
  kind  checksum  2258                     1.468  1.391            1.394
  kind  compress   688                     1.385  1.356            1.361
  kind      sort  1012                     1.421  1.378            1.361
tenant      acme  2421                     1.467  1.407            1.404
tenant    globex   278                     1.373  1.336            1.340
tenant   initech  1259                     1.408  1.344            1.344
  load       0-1  1100                     1.331  1.270            1.265
  load       2-3  1196                     1.401  1.387            1.375
  load       4-5   845                     1.562  1.465            1.472
  load        6+   817                     1.540  1.449            1.458

Permutation importance (trees + history):
          feature  log_error_increase    std
-----------------  ------------------  -----
             size               0.712  0.009
  history_log_run               0.548  0.011
             kind               0.315  0.006
running_at_submit               0.116  0.004
 queued_at_submit               0.051  0.003
    tenant_recent               0.006  0.001
           tenant               0.001  0.000
~~~

Read it in order.

**Point predictions.** The trees are typically off by 1.38, against the power law's 1.44, and rank jobs better (0.885 against 0.855). On log error the gain is clear: -0.042, between -0.073 and -0.027. In seconds it isn't: -0.004 s, and the interval includes zero. Both statements are true at once. The trees improve the many short jobs proportionally, and MAE is dominated by the few long ones. Which matters depends on the use: shortest-job-first (step 9) needs the order, so the trees' gain is real for it.

**History** adds almost nothing (1.380 against 1.382): here, tenants differ in *what* they submit, not in how fast the same job runs, and size and kind already say what they submit.

**Upper bounds.** The trees' p90 covers 86% of validation jobs, no better than the power law's, and the **conformal** version covers *77%*, worse. Look at what it calibrated on: the newest quarter of the training rows, which happened to be quiet (loads 1 and 2: 1.7 jobs running on average, against 3.0 in the rest of training). The model's bound looked generous there, so conformal *lowered* it, by 23%, just before the busiest run in the data. Its guarantee holds when the future resembles the calibration data. Here it didn't, and no method can promise coverage of a future unlike its past.

**Slices.** The trees are better in every slice, and every model gets worse as the workers get busier: typically off by 1.27 with 0 or 1 jobs running, about 1.45 to 1.47 with 4 or more. Contention is the hard part, and nothing in the features says how much CPU the running jobs are using, only how many there are.

**Importance.** Size first, then `history_log_run` second, at 0.548. Yet the trees *without* history are just as accurate. Both are true: this model leans on history (shuffle it and the model breaks), but history carries what tenant and kind together already say, so a model without it learns the same thing from those. Importance describes a model, not the world.

### Run it: tuning

~~~bash
time uv run --project lab lab tune results/dataset.parquet
~~~

~~~text
18 candidates, each cross-validated on the training rows:
              folds  best (lr, leaves, min_leaf)  cv_factor  valid_factor  seconds
-------------------  ---------------------------  ---------  ------------  -------
    shuffled 5-fold                   0.1, 31, 5      1.309         1.379   59.575
time-ordered 5-fold                    0.1, 7, 5      1.432         1.381   51.723

real	1m54.071s
user	13m59.262s
sys	0m10.420s
~~~

Shuffled folds promised 1.309 and delivered 1.379 on validation: each fold trained on jobs from the same minutes it was scored on, so it measured how well the model knows *those* minutes. Time-ordered folds promised 1.432, too gloomy in the other direction, because their first folds train on only a sixth of the rows, the oldest and quietest. Neither estimate was right; the time-ordered one at least erred the safe way. And the winners? 1.379 and 1.381, against 1.380 for the defaults that `lab train` used. Fourteen minutes of CPU, and nothing to show for it: the defaults were already as good as this data allows. That's a common result, and it's only known because it was measured. (So `lab train` keeps the defaults.)

### Run it: the test, once

Validation chose: the trees with history, for the typical time. For the bound, nothing was clearly better than the power law. Now the test set, once:

~~~bash
uv run --project lab lab train results/dataset.parquet --split test
~~~

~~~text
3958 test jobs, models trained on 11872; MAE_vs_ref compares each with kind power law + running
                   model  MAE_s  MAPE_%  log_factor  spearman  MAE_vs_ref_s              95% CI
------------------------  -----  ------  ----------  --------  ------------  ------------------
kind power law + running  0.053  34.328       1.418     0.879                                  
                   trees  0.052  30.535       1.347     0.910       -0.0016  -0.0084 .. +0.0045
         trees + history  0.052  28.552       1.339     0.913       -0.0010  -0.0080 .. +0.0059

3958 test jobs, models trained on 11872; logerr_vs_ref compares each with kind power law + running
                   model  MAE_s  MAPE_%  log_factor  spearman  logerr_vs_ref              95% CI
------------------------  -----  ------  ----------  --------  -------------  ------------------
kind power law + running  0.053  34.328       1.418     0.879                                   
                   trees  0.052  30.535       1.347     0.910        -0.0510  -0.0804 .. -0.0290
         trees + history  0.052  28.552       1.339     0.913        -0.0569  -0.0814 .. -0.0408

Upper bounds (p90):
                       model  pinball_0.9  covered_%
----------------------------  -----------  ---------
kind power law + running p90        0.016     89.161
                   trees p90        0.016     85.321
         trees p90 conformal        0.017     85.397

Typical factor off, by slice:
 slice     value  jobs  kind power law + running  trees  trees + history
------  --------  ----  ------------------------  -----  ---------------
  kind  checksum  2223                     1.425  1.350            1.339
  kind  compress   699                     1.426  1.351            1.360
  kind      sort  1036                     1.397  1.339            1.326
tenant      acme  2418                     1.433  1.366            1.352
tenant    globex   299                     1.391  1.351            1.362
tenant   initech  1241                     1.395  1.311            1.310
  load       0-1  2002                     1.333  1.263            1.255
  load       2-3  1063                     1.433  1.403            1.387
  load       4-5   490                     1.613  1.502            1.498
  load        6+   403                     1.597  1.462            1.470

Permutation importance (trees + history):
          feature  log_error_increase    std
-----------------  ------------------  -----
             size               0.786  0.004
  history_log_run               0.550  0.012
             kind               0.340  0.004
running_at_submit               0.148  0.002
 queued_at_submit               0.053  0.001
    tenant_recent               0.009  0.001
           tenant               0.001  0.000
~~~

The trees with history are typically off by 1.339 against 1.418, rank jobs better (0.913 against 0.879), and their log error is lower by 0.057 (0.041 to 0.081). In seconds, they tie. Against step 5's bar: beaten on log error and on order, by more than the interval; not beaten on MAE.

The bounds tell the other half. On this quieter period, the power law's p90 covers 89.2%; the trees' covers 85.3%, and conformal doesn't help (85.4%). A likely reason: quantile trees fit their training rows' quantiles closely, and a bound that hugs the training data is too tight on new data. So the plan for step 9: the trees for order, the power law (or something calibrated better) for the ETA a tenant is promised. Two models, chosen per use, by the metric that use needs.

**Explain it:** why must the encoder be inside the pipeline? Why do the trees need no log of size, and the power law does? Why does a quantile of log(time) give the same bound as a quantile of time? What did the history feature need to be point in time, and how did the test know? Why did the trees win on log error and tie on MAE, and which matters for shortest-job-first? Why did conformal calibration make coverage worse here? What did shuffled folds measure? Why can a feature look important and be unnecessary? Was tuning worth it, and how do you know?

**Read.** The scikit-learn user guide's chapters on *Pipelines and composite estimators*, *Cross-validation* (especially "Cross validation of time series data") and *Permutation feature importance* (with its warning about correlated features). Jerome Friedman, *Greedy Function Approximation: A Gradient Boosting Machine* (Annals of Statistics, 2001), the idea the trees are built on. Yaniv Romano, Evan Patterson and Emmanuel Candès, *Conformalized Quantile Regression* (NeurIPS 2019): the method, and the exchangeability it rests on. And Anastasios Angelopoulos and Stephen Bates, *A Gentle Introduction to Conformal Prediction and Distribution-Free Uncertainty Quantification* (2021), section on distribution shift.

---
## Step 7: Neural networks, from scratch and in PyTorch

**The problem.** Step 6's trees are the model to beat. Neural networks are the other family everyone reaches for, and the one most AI-generated code uses. To judge that code you need to know what's inside one: a forward pass, a backward pass that's just the chain rule, and an optimiser. And you need to know how they compare on a problem like this one: rows of numbers and categories, not images or text. This step writes a network by hand, proves its gradients right, rebuilds it in PyTorch, and then races both against the trees on accuracy, on luck and on cost.

**New ideas.**

- **A neural network is a function with weights.** Here: multiply the inputs by a matrix, add a bias, apply ReLU (max(0, x)), and repeat; the last layer gives log(run time). Training nudges every weight in the direction that lowers the loss.
- **Backpropagation** is the chain rule, applied from the loss back to each weight, layer by layer. Each layer needs only what its forward pass computed and the gradient arriving from above. Get one step wrong and nothing crashes: the network still trains, worse.
- **Gradient checking.** Nudge one weight by a tiny amount up and down, measure how the loss changes, and compare that slope with what backpropagation computed. If they agree to many digits, the backward pass is right. It's slow, so you check a small network once, not every training run.
- **Inputs must be on similar scales.** A network sees distances: an input in the millions next to inputs under ten makes one learning rate wrong for every weight. Take logs of anything spanning orders of magnitude, then **standardise** (subtract the training mean, divide by the training spread), using the training rows' statistics only.
- **Embeddings.** A category becomes a small learned vector, one per value, instead of a column per value. Similar values end up with similar vectors, and a category with thousands of values (tenants, at scale) stays cheap.
- **Adam** gives each weight its own step size, from the recent size of its gradients. **Early stopping** watches error on held-out rows and keeps the weights from the epoch where it was lowest.
- **Seeds.** A network starts from random weights and sees batches in random order: two runs differ. Report the spread across seeds, not one lucky run.
- **Cost is part of the answer.** Training CPU, latency for one prediction, and size all matter when the model sits in a request path (step 8).

### PyTorch, without the gigabytes

PyTorch's default Linux packages include GPU libraries of several gigabytes. Install the CPU-only build, from PyTorch's own package index, as an optional extra like Spark. In `lab/pyproject.toml`:

Change:

<!-- edit: lab/pyproject.toml -->
~~~toml
    "pyspark>=4.2.0",
]

[dependency-groups]
~~~

to:

~~~toml
    "pyspark>=4.2.0",
]
deep = [
    "torch>=2.0",
]

[dependency-groups]
~~~

Change:

<!-- edit: lab/pyproject.toml -->
~~~toml
    "ruff>=0.17.1",
]

[build-system]
~~~

to:

~~~toml
    "ruff>=0.17.1",
]

# PyTorch from its CPU-only index: the default Linux wheels bring GPU
# libraries of several gigabytes that nothing here would use.
[[tool.uv.index]]
name = "pytorch-cpu"
url = "https://download.pytorch.org/whl/cpu"
explicit = true

[tool.uv.sources]
torch = { index = "pytorch-cpu" }

[build-system]
~~~


`explicit = true` means only packages that ask for that index (here, `torch`) come from it; everything else still comes from PyPI.

### A network by hand

Create `lab/src/lab/nn.py`:

<!-- file: lab/src/lab/nn.py -->
~~~python
"""A neural network from scratch, in NumPy: the forward pass, the backward pass, and the check.

One hidden layer: h = relu(x W1 + b1), prediction = h W2 + b2, trained to
minimise the mean of (prediction - log run time)^2 / 2. The backward pass
is the chain rule, applied by hand, layer by layer, from the loss back to
each weight. gradient_check compares it with the slope measured by nudging
each weight a little: if they disagree, the backward pass is wrong, and
training would still run, just badly. That's why it needs a test.
"""

from dataclasses import dataclass

import numpy as np

Rows = dict[str, np.ndarray]

NUMBERS = ["size", "running_at_submit", "queued_at_submit", "tenant_recent", "history_log_run"]
CATEGORIES = ["tenant", "kind"]


@dataclass
class Encoder:
    """Turns rows into standardised numbers, learning everything from the training rows only.

    Size becomes log(size): a network, unlike a tree, sees distances, and
    sizes span four orders of magnitude. Each number is then standardised
    (minus the training mean, over the training spread), so all inputs are
    of similar scale and one learning rate suits every weight. A missing
    history becomes the training mean, plus a column saying it was missing.
    Categories become one column per training value (one-hot), and the
    codes an embedding needs; a value never seen in training gets all zeros,
    or code 0.
    """

    def fit(self, rows: Rows) -> "Encoder":
        self.fill = float(np.nanmean(rows["history_log_run"]))
        x = self._numbers(rows, fill=self.fill)
        self.mean, self.std = x.mean(axis=0), x.std(axis=0) + 1e-9
        self.levels = {c: sorted(np.unique(rows[c]).tolist()) for c in CATEGORIES}
        return self

    def _numbers(self, rows: Rows, fill: float | None) -> np.ndarray:
        history = rows["history_log_run"].astype(float)
        missing = np.isnan(history)
        if fill is not None:
            history = np.where(missing, fill, history)
        cols = [
            np.log(np.maximum(rows["size"], 1)),
            rows["running_at_submit"],
            rows["queued_at_submit"],
            rows["tenant_recent"],
            history,
            missing,
        ]
        return np.column_stack(cols).astype(float)

    def numbers(self, rows: Rows) -> np.ndarray:
        return (self._numbers(rows, self.fill) - self.mean) / self.std

    def codes(self, rows: Rows, category: str) -> np.ndarray:
        """1 + the value's position among the training values; 0 for one never seen."""
        index = {v: i + 1 for i, v in enumerate(self.levels[category])}
        return np.array([index.get(v, 0) for v in rows[category]])

    def one_hot(self, rows: Rows) -> np.ndarray:
        parts = []
        for c in CATEGORIES:
            codes = self.codes(rows, c)
            parts.append(np.eye(len(self.levels[c]) + 1)[codes][:, 1:])  # code 0: all zeros
        return np.hstack(parts)

    def transform(self, rows: Rows) -> np.ndarray:
        return np.hstack([self.numbers(rows), self.one_hot(rows)])


class MLP:
    """Weights, and the passes forward and back."""

    def __init__(self, inputs: int, hidden: int, seed: int = 1):
        rng = np.random.default_rng(seed)
        # He initialisation: weights scaled so a ReLU layer's outputs keep
        # about the spread of its inputs, layer after layer.
        self.params = {
            "W1": rng.normal(0, np.sqrt(2 / inputs), (inputs, hidden)),
            "b1": np.zeros(hidden),
            "W2": rng.normal(0, np.sqrt(2 / hidden), (hidden, 1)),
            "b2": np.zeros(1),
        }

    def forward(self, x: np.ndarray) -> tuple[np.ndarray, dict]:
        p = self.params
        z = x @ p["W1"] + p["b1"]
        h = np.maximum(z, 0)
        out = (h @ p["W2"] + p["b2"]).ravel()
        return out, {"x": x, "z": z, "h": h}

    def loss(self, x: np.ndarray, y: np.ndarray) -> float:
        out, _ = self.forward(x)
        return float(np.mean((out - y) ** 2) / 2)

    def backward(self, cache: dict, out: np.ndarray, y: np.ndarray) -> dict:
        """d(loss)/d(each parameter), by the chain rule, last layer first."""
        p, n = self.params, len(y)
        d_out = ((out - y) / n)[:, None]  # d loss / d out
        grads = {"W2": cache["h"].T @ d_out, "b2": d_out.sum(axis=0)}
        d_h = d_out @ p["W2"].T  # back through the second layer
        d_z = d_h * (cache["z"] > 0)  # back through ReLU: it passes only where z > 0
        grads["W1"] = cache["x"].T @ d_z
        grads["b1"] = d_z.sum(axis=0)
        return grads


def gradient_check(net: MLP, x: np.ndarray, y: np.ndarray, eps: float = 1e-6) -> dict[str, float]:
    """For each parameter, the largest relative difference between backward's gradient and
    the slope measured by central differences: (loss(w + eps) - loss(w - eps)) / (2 eps).
    A correct backward pass gives well under 1e-5 (in float64); a wrong one, far more.
    """
    out, cache = net.forward(x)
    grads = net.backward(cache, out, y)
    worst = {}
    for name, value in net.params.items():
        measured = np.zeros_like(value)
        for i in np.ndindex(value.shape):
            keep = value[i]
            value[i] = keep + eps
            up = net.loss(x, y)
            value[i] = keep - eps
            down = net.loss(x, y)
            value[i] = keep
            measured[i] = (up - down) / (2 * eps)
        diff = np.abs(grads[name] - measured) / np.maximum(
            np.abs(grads[name]) + np.abs(measured), 1e-12
        )
        worst[name] = float(diff.max())
    return worst


class Adam:
    """Adam (Kingma and Ba, 2015): each weight's step scaled by its own recent gradients."""

    def __init__(self, params: dict, lr: float = 1e-3, b1: float = 0.9, b2: float = 0.999):
        self.lr, self.b1, self.b2, self.t = lr, b1, b2, 0
        self.m = {k: np.zeros_like(v) for k, v in params.items()}  # mean of gradients
        self.v = {k: np.zeros_like(v) for k, v in params.items()}  # mean of their squares

    def step(self, params: dict, grads: dict) -> None:
        self.t += 1
        for k in params:
            self.m[k] = self.b1 * self.m[k] + (1 - self.b1) * grads[k]
            self.v[k] = self.b2 * self.v[k] + (1 - self.b2) * grads[k] ** 2
            m = self.m[k] / (1 - self.b1**self.t)  # early steps: correct the bias to zero
            v = self.v[k] / (1 - self.b2**self.t)
            params[k] -= self.lr * m / (np.sqrt(v) + 1e-8)


class NumpyNet:
    """The from-scratch network as a model: fit on rows, predict seconds."""

    def __init__(self, hidden: int = 32, epochs: int = 40, batch: int = 128, seed: int = 1):
        self.hidden, self.epochs, self.batch, self.seed = hidden, epochs, batch, seed
        self.name = "numpy net"

    def fit(self, rows: Rows) -> "NumpyNet":
        self.encoder = Encoder().fit(rows)
        x, y = self.encoder.transform(rows), np.log(rows["run_s"])
        self.net = MLP(x.shape[1], self.hidden, self.seed)
        adam = Adam(self.net.params, lr=3e-3)
        rng = np.random.default_rng(self.seed)
        for _ in range(self.epochs):
            order = rng.permutation(len(y))  # shuffled mini-batches, a new order every epoch
            for start in range(0, len(y), self.batch):
                i = order[start : start + self.batch]
                out, cache = self.net.forward(x[i])
                adam.step(self.net.params, self.net.backward(cache, out, y[i]))
        return self

    def predict(self, rows: Rows) -> np.ndarray:
        out, _ = self.net.forward(self.encoder.transform(rows))
        return np.exp(out)
~~~

Read `backward` with the forward pass beside it. The loss is (out - y)^2 / 2, averaged, so d(loss)/d(out) is (out - y) / n. The output is h W2 + b2, so W2's gradient is h transposed times that, and b2's is its sum. Going down through W2 gives d(loss)/d(h). ReLU passes a gradient only where its input was positive, so multiply by the mask `z > 0`. Then W1 and b1 follow exactly as W2 and b2 did. Each line is one application of the chain rule.

`Encoder` turns rows into numbers, and everything it learns (means, spreads, the list of tenants) comes from the training rows. `Adam` is ten lines: keep a running mean of each weight's gradients and of their squares, correct both for starting at zero, and step by the first over the square root of the second.

Check the gradients. Add a command, in `lab/src/lab/cli.py`:

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

def cmd_simulate(args: argparse.Namespace) -> int:
~~~

to:

~~~python

def cmd_deep(args: argparse.Namespace) -> int:
    from lab import compare, dataset, evaluate
    from lab.baselines import KindPowerLaw
    from lab.model import CATEGORIES, NUMBERS, Boosted
    from lab.nn import NumpyNet
    from lab.torchnet import TorchNet

    data = dataset.load(args.dataset)
    every = CATEGORIES + NUMBERS
    models = [KindPowerLaw(contention=True), Boosted("trees + history", every), NumpyNet()]
    models.append(TorchNet())
    print(evaluate.point_report(data, models, args.split, "trees + history", "log"))
    seeds = list(range(1, args.seeds + 1))
    makers = [
        lambda s: Boosted("trees + history", every, random_state=s),
        lambda s: NumpyNet(seed=s),
        lambda s: TorchNet(seed=s),
    ]
    print(f"\nThe same models, trained with {len(seeds)} different seeds:")
    print(compare.seeds_report(data, makers, args.split, seeds))
    print("\nWhat each costs:")
    print(compare.cost_report(data, models, args.split))
    return 0


def cmd_gradcheck(args: argparse.Namespace) -> int:
    import numpy as np

    from lab import nn

    rng = np.random.default_rng(args.seed)
    net = nn.MLP(inputs=5, hidden=4, seed=args.seed)
    x, y = rng.normal(size=(20, 5)), rng.normal(size=20)
    for name, worst in nn.gradient_check(net, x, y).items():
        verdict = "ok" if worst < 1e-5 else "WRONG"
        print(f"{name}: largest relative difference {worst:.1e}  {verdict}")
    return 0


def cmd_simulate(args: argparse.Namespace) -> int:
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

    simulate = sub.add_parser(
~~~

to:

~~~python

    dp = sub.add_parser("deep", help="neural networks against the trees, with seeds and costs")
    dp.add_argument("dataset", type=Path)
    dp.add_argument("--split", choices=["valid", "test"], default="valid")
    dp.add_argument("--seeds", type=int, default=5)
    dp.set_defaults(func=cmd_deep)

    gc = sub.add_parser("gradcheck", help="check nn.py's backward pass against measured slopes")
    gc.add_argument("--seed", type=int, default=3)
    gc.set_defaults(func=cmd_gradcheck)

    simulate = sub.add_parser(
~~~


~~~bash
uv run --project lab lab gradcheck
~~~

~~~text
W1: largest relative difference 2.1e-08  ok
b1: largest relative difference 4.0e-09  ok
W2: largest relative difference 3.7e-10  ok
b2: largest relative difference 1.4e-11  ok
~~~

Backpropagation and the measured slopes agree to eight digits or more.

**Break it.** In `backward`, go back through the ReLU as if it weren't there: `d_z = d_h`. Check, then train anyway and score on validation:

~~~text
W1: largest relative difference 1.0e+00  WRONG
b1: largest relative difference 4.4e-01  WRONG
W2: largest relative difference 3.7e-10  ok
b2: largest relative difference 1.4e-11  ok
~~~

~~~text
numpy net on validation: typically off by 1.461
~~~

The check points at the layer below the ReLU: W2 and b2 are still right. And training *worked*: no error, no NaN, a model typically off by 1.461 instead of 1.412. Nothing but the check says the code is wrong. That's the case for checking every hand-written gradient, and for using autograd. Put the mask back.

**Break it.** In `Encoder`, feed size in as it is (`rows["size"]`, not its log) and return the numbers unstandardised from `numbers`:

~~~text
numpy net on validation: typically off by 8299758558.402
~~~

Off by a factor of eight billion. Sizes in the tens of millions make the first layer's outputs, and its gradients, millions of times larger than anything else; Adam's steps can't suit both, and the predictions fly off. The trees didn't care: they only compare values. Put both back:

~~~text
numpy net on validation: typically off by 1.412
~~~

### The same in PyTorch

Create `lab/src/lab/torchnet.py`:

<!-- file: lab/src/lab/torchnet.py -->
~~~python
"""The same network in PyTorch, with embeddings, early stopping, and nothing derived by hand.

PyTorch records the operations of the forward pass and applies the chain
rule itself (autograd): loss.backward() is nn.py's backward, for any
network. Tenant and kind go in as embeddings: a small learned vector per
value, instead of a one-hot column per value, which is what makes
categories with thousands of values (tenants, at scale) workable.

Install it with the project's deep extra: uv sync --extra deep.
"""

import copy

import numpy as np

from lab.nn import CATEGORIES, Encoder

Rows = dict[str, np.ndarray]


def _network(encoder: Encoder, numbers: int, hidden: int, width: int):
    import torch
    from torch import nn

    class Net(nn.Module):
        def __init__(self):
            super().__init__()
            # One extra row per table: code 0, a value never seen in training.
            self.embed = nn.ModuleList(
                nn.Embedding(len(encoder.levels[c]) + 1, width) for c in CATEGORIES
            )
            self.layers = nn.Sequential(
                nn.Linear(numbers + width * len(CATEGORIES), hidden),
                nn.ReLU(),
                nn.Linear(hidden, hidden),
                nn.ReLU(),
                nn.Linear(hidden, 1),
            )

        def forward(self, x, codes):
            parts = [x] + [emb(codes[:, i]) for i, emb in enumerate(self.embed)]
            return self.layers(torch.cat(parts, dim=1)).squeeze(1)

    return Net()


class TorchNet:
    """Two hidden layers, embeddings for tenant and kind, Adam, early stopping."""

    def __init__(
        self,
        hidden: int = 64,
        width: int = 4,
        batch: int = 128,
        max_epochs: int = 200,
        patience: int = 10,
        seed: int = 1,
        threads: int = 1,
    ):
        self.hidden, self.width, self.batch = hidden, width, batch
        self.max_epochs, self.patience, self.seed = max_epochs, patience, seed
        # One thread: these matrices are small, and on 8 threads training took
        # the same wall time and 8 times the CPU.
        self.threads = threads
        self.name = "torch net"

    def _tensors(self, rows: Rows):
        import torch

        x = torch.tensor(self.encoder.numbers(rows), dtype=torch.float32)
        codes = np.column_stack([self.encoder.codes(rows, c) for c in CATEGORIES])
        return x, torch.tensor(codes, dtype=torch.long)

    def fit(self, rows: Rows) -> "TorchNet":
        import torch

        torch.manual_seed(self.seed)
        torch.set_num_threads(self.threads)
        # Early stopping watches the newest tenth of the training rows, kept
        # out of training: stop when it stops improving, keep the best.
        cut = int(len(rows["run_s"]) * 0.9)
        fit_rows = {k: v[:cut] for k, v in rows.items()}
        watch = {k: v[cut:] for k, v in rows.items()}
        self.encoder = Encoder().fit(fit_rows)
        x, codes = self._tensors(fit_rows)
        y = torch.tensor(np.log(fit_rows["run_s"]), dtype=torch.float32)
        wx, wcodes = self._tensors(watch)
        wy = torch.tensor(np.log(watch["run_s"]), dtype=torch.float32)
        self.net = _network(self.encoder, x.shape[1], self.hidden, self.width)
        opt = torch.optim.Adam(self.net.parameters(), lr=1e-3)
        best, best_state, waited = float("inf"), None, 0
        self.epochs = 0
        for _ in range(self.max_epochs):
            self.net.train()
            for i in torch.randperm(len(y)).split(self.batch):
                opt.zero_grad()
                loss = ((self.net(x[i], codes[i]) - y[i]) ** 2).mean() / 2
                loss.backward()  # autograd: every gradient, by the chain rule
                opt.step()
            self.epochs += 1
            self.net.eval()
            with torch.no_grad():
                watched = float(((self.net(wx, wcodes) - wy).abs()).mean())
            if watched < best - 1e-4:
                best, best_state, waited = watched, copy.deepcopy(self.net.state_dict()), 0
            else:
                waited += 1
                if waited >= self.patience:
                    break
        self.net.load_state_dict(best_state)
        return self

    def predict(self, rows: Rows) -> np.ndarray:
        import torch

        self.net.eval()
        with torch.no_grad():
            return np.exp(self.net(*self._tensors(rows)).numpy().astype(float))
~~~

The network is a list of layers, and `loss.backward()` replaces all of `nn.py`'s `backward`: PyTorch recorded every operation of the forward pass and runs the chain rule back through them. Tenant and kind each get a four-number embedding, looked up by the encoder's codes, and concatenated with the standardised numbers. Training watches the newest tenth of the training rows and keeps the best epoch.

Why one thread? Measure it:

~~~bash
uv run --project lab python - <<'PY'
import time
from pathlib import Path
import torch
from lab import dataset
from lab.evaluate import rows_of
from lab.torchnet import TorchNet
d = dataset.load(Path("results/dataset.parquet"))
train = rows_of(d, "train")
TorchNet().fit(train)  # once to warm up: the first run loads and compiles
for threads in (1, 8):
    cpu, wall = time.process_time(), time.monotonic()
    m = TorchNet(threads=threads).fit(train)
    print(f"{threads} thread(s): {m.epochs} epochs, {time.process_time() - cpu:.1f} s CPU, {time.monotonic() - wall:.1f} s wall")
PY
~~~

~~~text
1 thread(s): 20 epochs, 2.0 s CPU, 2.0 s wall
8 thread(s): 20 epochs, 28.8 s CPU, 3.6 s wall
~~~

Eight threads used 14 times the CPU and took *longer*. Each batch is 128 rows through layers of 64: too little work to split, so the threads spend their time handing work over. PyTorch's default is one thread per core, chosen for big models. Small models want one.

### The race

The trees take a seed now, too: with more than 10,000 rows, scikit-learn stops boosting early, judged on a random tenth of them. In `lab/src/lab/model.py`:

Change:

<!-- edit: lab/src/lab/model.py -->
~~~python
    trees = HistGradientBoostingRegressor(
        categorical_features=list(range(len(cats))), random_state=1, **params
    )
~~~

to:

~~~python
    # Above 10,000 rows the trees stop early, judged on a random tenth of
    # the rows they're given: random_state picks that tenth.
    params = {"random_state": 1} | params
    trees = HistGradientBoostingRegressor(categorical_features=list(range(len(cats))), **params)
~~~


Create `lab/src/lab/compare.py`, which retrains each model with several seeds, and measures what each costs:

<!-- file: lab/src/lab/compare.py -->
~~~python
"""Models compared on what they cost, not only on how accurate they are."""

import io
import pickle
import statistics
import time

import numpy as np

from lab import metrics
from lab.evaluate import rows_of
from lab.warehouse import table


def seeds_report(data, makers: list, split: str, seeds: list[int]) -> str:
    """Each model trained once per seed: how much does the answer depend on luck?"""
    train, rows = rows_of(data, "train"), rows_of(data, split)
    out = []
    for make in makers:
        factors = []
        for seed in seeds:
            model = make(seed).fit(train)
            factors.append(metrics.log_error(rows["run_s"], model.predict(rows)))
        out.append([make(seeds[0]).name, len(seeds), statistics.mean(factors)])
        out[-1] += [statistics.stdev(factors), min(factors), max(factors)]
    return table(["model", "seeds", "mean_factor", "sd", "best", "worst"], out)


def size_of(model) -> int:
    """Bytes to store the fitted model (a torch network: its weights, saved as torch does)."""
    if hasattr(model, "net") and hasattr(model.net, "state_dict"):
        import torch

        buf = io.BytesIO()
        torch.save(model.net.state_dict(), buf)
        return buf.tell() + len(pickle.dumps(model.encoder))
    return len(pickle.dumps(model))


def cost_report(data, models: list, split: str) -> str:
    """Training time (CPU and wall), prediction latency for one job and for a thousand, size."""
    train, rows = rows_of(data, "train"), rows_of(data, split)
    one = {k: v[:1] for k, v in rows.items()}
    many = {k: v[:1000] for k, v in rows.items()}
    out = []
    for m in models:
        cpu, wall = time.process_time(), time.monotonic()
        m.fit(train)
        cpu, wall = time.process_time() - cpu, time.monotonic() - wall
        singles = []
        for _ in range(200):
            start = time.perf_counter()
            m.predict(one)
            singles.append(time.perf_counter() - start)
        start = time.perf_counter()
        m.predict(many)
        batch = time.perf_counter() - start
        out.append([m.name, cpu, wall, np.median(singles) * 1e3, batch * 1e3, size_of(m) / 1e3])
    names = ["model", "train_cpu_s", "train_wall_s", "predict_1_ms", "predict_1000_ms", "size_kB"]
    return table(names, out)
~~~

### Tests

The tests check the gradients for three random networks, check that the check *catches* a backward pass without the ReLU mask, and check that the encoder learns its scale from training rows only and handles a new tenant and a missing history. Then both networks must learn step 6's test world, and the same seed must give the same PyTorch network. Create `lab/tests/test_nn.py`:

<!-- file: lab/tests/test_nn.py -->
~~~python
import numpy as np
import pytest
from test_model import FEATURES, jobs  # the step-6 world: a power law with a step

from lab import compare, metrics, nn


@pytest.fixture(scope="module")
def train():
    return jobs(6_000, 1)


@pytest.fixture(scope="module")
def later():
    return jobs(4_000, 2)


@pytest.mark.parametrize("seed", [1, 2, 3])
def test_the_backward_pass_matches_the_measured_slopes(seed):
    rng = np.random.default_rng(seed)
    net = nn.MLP(inputs=5, hidden=4, seed=seed)
    x, y = rng.normal(size=(20, 5)), rng.normal(size=20)
    assert max(nn.gradient_check(net, x, y).values()) < 1e-5


def test_the_check_catches_a_backward_pass_that_forgets_relu(monkeypatch):
    def wrong(self, cache, out, y):
        p, n = self.params, len(y)
        d_out = ((out - y) / n)[:, None]
        d_z = d_out @ p["W2"].T  # missing: * (cache["z"] > 0)
        return {
            "W2": cache["h"].T @ d_out,
            "b2": d_out.sum(axis=0),
            "W1": cache["x"].T @ d_z,
            "b1": d_z.sum(axis=0),
        }

    monkeypatch.setattr(nn.MLP, "backward", wrong)
    rng = np.random.default_rng(1)
    worst = nn.gradient_check(nn.MLP(5, 4, seed=1), rng.normal(size=(20, 5)), rng.normal(size=20))
    assert worst["W1"] > 1e-2 and worst["W2"] < 1e-5, "only the layer below the ReLU is wrong"


def test_the_encoder_learns_its_scale_from_training_rows_only(train, later):
    enc = nn.Encoder().fit(train)
    x = enc.numbers(train)
    assert np.allclose(x.mean(axis=0)[:5], 0, atol=1e-9)
    assert np.allclose(x.std(axis=0)[:5], 1, atol=1e-6)
    assert not np.allclose(enc.numbers(later).mean(axis=0)[:5], 0, atol=1e-9)


def test_unknown_categories_and_missing_history_are_encoded():
    rows = jobs(10, 3)
    enc = nn.Encoder().fit(rows)
    new = {k: v[:2].copy() for k, v in rows.items()}
    new["tenant"] = np.array(["hooli", "hooli"])
    new["history_log_run"] = np.array([np.nan, -1.0])
    assert enc.codes(new, "tenant").tolist() == [0, 0]
    assert enc.one_hot(new)[:, : len(enc.levels["tenant"])].sum() == 0
    x = enc._numbers(new, enc.fill)
    assert x[0, 4] == pytest.approx(enc.fill) and x[:, 5].tolist() == [1.0, 0.0]


def test_the_numpy_net_learns_the_world(train, later):
    pred = nn.NumpyNet(seed=1).fit(train).predict(later)
    assert metrics.log_error(later["run_s"], pred) < 1.2


def test_the_torch_net_learns_the_world_and_repeats_itself(train, later):
    pytest.importorskip("torch")
    from lab.torchnet import TorchNet

    a = TorchNet(seed=1).fit(train).predict(later)
    b = TorchNet(seed=1).fit(train).predict(later)
    assert metrics.log_error(later["run_s"], a) < 1.2
    assert np.array_equal(a, b), "the same seed must give the same network"
    new = {k: v[:3].copy() for k, v in later.items()}
    new["tenant"] = np.array(["hooli"] * 3)
    assert np.all(np.isfinite(TorchNet(seed=1).fit(train).predict(new)))


def test_sizes_are_measured(train):
    model = nn.NumpyNet(epochs=1).fit(train)
    assert 1_000 < compare.size_of(model) < 100_000


def test_feature_list_matches_the_trees():
    assert set(nn.NUMBERS + nn.CATEGORIES) == set(FEATURES)
~~~

<!-- run: cd lab && uv sync --extra deep && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

### Run it: accuracy, luck and cost

~~~bash
uv run --project lab lab deep results/dataset.parquet
~~~

~~~text
3958 valid jobs, models trained on 11872; logerr_vs_ref compares each with trees + history
                   model  MAE_s  MAPE_%  log_factor  spearman  logerr_vs_ref              95% CI
------------------------  -----  ------  ----------  --------  -------------  ------------------
kind power law + running  0.060  33.106       1.441     0.855        +0.0436  +0.0287 .. +0.0704
         trees + history  0.055  33.308       1.380     0.886                                   
               numpy net  0.052  39.205       1.412     0.883        +0.0232  +0.0088 .. +0.0301
               torch net  0.052  33.689       1.390     0.879        +0.0075  +0.0004 .. +0.0150

The same models, trained with 5 different seeds:
          model  seeds  mean_factor     sd   best  worst
---------------  -----  -----------  -----  -----  -----
trees + history      5        1.380  0.002  1.378  1.382
      numpy net      5        1.402  0.007  1.396  1.412
      torch net      5        1.388  0.006  1.380  1.396

What each costs:
                   model  train_cpu_s  train_wall_s  predict_1_ms  predict_1000_ms  size_kB
------------------------  -----------  ------------  ------------  ---------------  -------
kind power law + running        0.006         0.006         0.024            0.487    0.467
         trees + history        3.031         0.416        11.196            9.639  379.616
               numpy net        0.579         0.496         0.038            0.385    4.298
               torch net        2.115         2.109         0.211            0.717   24.501
~~~

**Accuracy.** The trees are still best on log error. The PyTorch network is close behind (1.390 against 1.380; the interval only just excludes zero), the hand-written one further (1.412). On MAE both networks are *better* than the trees (0.052 against 0.055 s): they predict the long jobs better and the short ones a little worse.

**Luck.** Retrained with five seeds, the trees move by 0.002; the networks, three or four times as much. The PyTorch network's *best* seed (1.380) matches the trees; its average doesn't. One run of a network proves little.

**Cost.** Training: the NumPy network takes half a CPU-second, PyTorch two, the trees three (spread over threads, so 0.4 s of wall time). And prediction: one job through the trees takes **11 ms**, one through the NumPy network **0.04 ms**, nearly 300 times less. A thousand through the trees take about the same 10 ms as one. So the trees' cost is the call, not the arithmetic: building a pandas DataFrame, checking its columns, running the pipeline's steps. Step 8 predicts one job per request, so this is the number that matters there. The tree model is also 380 kB, against 4 kB for the hand-written network: hundreds of trees with all their split points, against a few thousand weights.

### Run it: the test, once

~~~bash
uv run --project lab lab deep results/dataset.parquet --split test
~~~

~~~text
3958 test jobs, models trained on 11872; logerr_vs_ref compares each with trees + history
                   model  MAE_s  MAPE_%  log_factor  spearman  logerr_vs_ref              95% CI
------------------------  -----  ------  ----------  --------  -------------  ------------------
kind power law + running  0.053  34.328       1.418     0.879        +0.0569  +0.0408 .. +0.0814
         trees + history  0.052  28.552       1.339     0.913                                   
               numpy net  0.052  33.044       1.359     0.910        +0.0147  +0.0062 .. +0.0216
               torch net  0.048  30.478       1.352     0.906        +0.0098  -0.0014 .. +0.0167

The same models, trained with 5 different seeds:
          model  seeds  mean_factor     sd   best  worst
---------------  -----  -----------  -----  -----  -----
trees + history      5        1.337  0.002  1.336  1.340
      numpy net      5        1.351  0.007  1.340  1.359
      torch net      5        1.353  0.009  1.344  1.369

What each costs:
                   model  train_cpu_s  train_wall_s  predict_1_ms  predict_1000_ms  size_kB
------------------------  -----------  ------------  ------------  ---------------  -------
kind power law + running        0.014         0.014         0.072            1.037    0.467
         trees + history        3.929         0.543        12.524           11.237  379.616
               numpy net        0.637         0.559         0.047            0.493    4.298
               torch net        2.034         2.028         0.200            0.763   24.501
~~~

On the test set, the PyTorch network has the lowest MAE (0.048 s), and on log error it's within the noise of the trees (+0.0098, between -0.0014 and +0.0167); the hand-written one is slightly but clearly worse. Across seeds: trees 1.337, give or take 0.002; networks about 1.35, give or take 0.007 to 0.009.

So, for this problem: the networks are about as accurate as the trees, less stable, and far cheaper to call. The trees remain the accuracy and stability choice; a network is the latency choice. The usual finding for tabular data (Grinsztajn and others, 2022) holds here. Trees match or beat networks on rows of mixed features, with less tuning, and a network's case has to be made on something else. Here, that something is a factor of 300 in prediction latency.

**Explain it:** what does each line of `backward` compute, and why does ReLU need a mask? How does gradient checking work, and why is it slow? Why did the wrong backward pass still train? Why must a network's inputs be standardised, and why don't trees care? What is an embedding, and why is it better than one-hot for tenants at scale? Why did eight threads take longer than one? Why is one tree prediction 300 times slower than one network prediction, and why does that matter for step 8? What does the spread across seeds tell you that one run can't?

**Read.** Michael Nielsen, *Neural Networks and Deep Learning*, chapter 2 (*How the backpropagation algorithm works*), free online: the equations you implemented. The *Gradient checking* section of Stanford's CS231n notes. Diederik Kingma and Jimmy Ba, *Adam: A Method for Stochastic Optimization* (ICLR 2015): Algorithm 1 is your `Adam` class. Léo Grinsztajn, Edouard Oyallon and Gaël Varoquaux, *Why do tree-based models still outperform deep learning on typical tabular data?* (NeurIPS 2022): the result you just reproduced, at scale.

---
## Step 8: Serving predictions

**The problem.** A model in a notebook predicts nothing. The API has to ask a model, for every job, at the moment the job arrives, and the answer has to be computed from the same features the model learned from: the same definitions, as of that same moment, from the same events. And the asking can't make job creation slow or unreliable. The prediction is an improvement, so when it isn't available, the job goes ahead without one. This step builds the prediction service, wires the API to it through Phase 6's mutual TLS, and then measures it in production: how often it answers, how fast, and whether the features it serves are the ones it was trained on.

**New ideas.**

- **Online and offline features.** Training computed features in a batch, looking back from each job's submission. The service has to compute them as events arrive, in a long-running process. Two implementations of one definition drift apart unless a test holds them together: replay recorded events through the online code, and require, job by job, exactly what the batch computed. That's a **parity test**.
- **Train/serve skew.** Even with identical code, the service sees the world a little late: events reach it through the outbox, Kafka and a consumer. Measure the features it actually served against the batch's for the same jobs, and what that costs in accuracy.
- **Which clock?** An event can carry several times: when the work started (the worker's clock) and when the API *recorded* it (the event's time). A feature may use only what the system knew, so it must use when things were recorded.
- **A model is an artifact.** Fitted on all the data once evaluation is done, saved with its version and the features it expects, and deployed separately from the code that serves it.
- **A dependency in the request path** gets a deadline (a slow answer is no answer), a circuit breaker (a dead service isn't waited for on every request), a fallback (no prediction, job created anyway), and a count of every outcome.
- **Cost per call.** A model that answers in 8 ms in a quiet process can take 30 ms, or time out, on a machine busy with other work. Cheaper predictions survive contention; the step 7 measurement becomes the deciding one here.

### Two clocks: the parity test

The service will keep the system's state up to date as events arrive. Create `lab/src/lab/online.py`:

<!-- file: lab/src/lab/online.py -->
~~~python
"""The system as the event stream has told it so far: features for a job about to be submitted.

dataset.features computes each job's features in a batch, looking back
from its submission. A prediction service can't wait for a batch: it keeps
this state up to date as each event arrives, and reads the features off it
when the API asks. Two implementations of one definition will drift apart
unless something checks them against each other, so parity() replays
recorded events through this class and compares, job by job, with the
batch: the same features, or the test fails.

Events arrive at least once (step 3), so applying one twice must change
nothing: every transition only moves a job forward.
"""

import itertools
import math
from collections import deque
from dataclasses import dataclass, field

import numpy as np

from lab import dataset

RECENT_US = int(dataset.RECENT * 1e6)


@dataclass
class State:
    queued: set = field(default_factory=set)  # (tenant, job_id) created, not yet started
    running: set = field(default_factory=set)  # started, not yet finished
    done: set = field(default_factory=set)  # finished: later events about them change nothing
    created: dict = field(default_factory=dict)  # tenant -> creation times, oldest first
    history: dict = field(default_factory=dict)  # (tenant, kind) -> [jobs, sum of log run time]
    applied: int = 0
    newest_us: int = 0  # the latest occurred_at seen

    def apply(self, event: dict) -> None:
        """One JobChanged event, as the contract describes it."""
        p = event["payload"]
        key = (event["tenant"], p["job_id"])
        self.applied += 1
        self.newest_us = max(self.newest_us, _us(event["occurred_at"]))
        if key in self.done:
            return  # a duplicate, or a late report about a finished job
        state = p["state"]
        if state == "queued":
            if key not in self.queued and key not in self.running:
                self.queued.add(key)
                self.created.setdefault(event["tenant"], deque()).append(_us(p["created_at"]))
        elif state == "running":
            self.queued.discard(key)
            self.running.add(key)
        else:  # completed or failed: it leaves the queue, or the workers
            self.queued.discard(key)
            self.running.discard(key)
            self.done.add(key)
            if state == "completed" and p.get("started_at") and p.get("finished_at"):
                run = (_us(p["finished_at"]) - _us(p["started_at"])) / 1e6
                total = self.history.setdefault((event["tenant"], p["kind"]), [0, 0.0])
                total[0] += 1
                total[1] += math.log(run)

    def features(self, tenant: str, kind: str, size: int, at_us: int) -> dict:
        """The features of a job submitted at at_us, from everything applied so far."""
        times = self.created.get(tenant, deque())
        while times and times[0] < at_us - RECENT_US:
            times.popleft()  # more than a minute old: never counted again
        recent = sum(1 for t in times if t < at_us)
        jobs, total = self.history.get((tenant, kind), (0, 0.0))
        return {
            "tenant": tenant,
            "kind": kind,
            "size": size,
            "running_at_submit": len(self.running),
            "queued_at_submit": len(self.queued),
            "tenant_recent": recent,
            "history_log_run": total / jobs if jobs else float("nan"),
        }


def _us(text: str) -> int:
    """An RFC 3339 time as whole microseconds since 1970."""
    return int(np.datetime64(text.replace("Z", "").split("+")[0], "us").astype(np.int64))


def parity(events: list[dict], jobs: dict[str, np.ndarray]) -> list[str]:
    """Replay events in the order they happened; at each job's submission, compare with the batch.

    jobs is dataset.load_jobs's output for the same data. Returns the
    differences, as readable lines: none means the two agree.
    """
    batch = dataset.features(jobs)
    where = {(t, j): i for i, (t, j) in enumerate(zip(jobs["tenant"], jobs["job_id"], strict=True))}
    order = sorted(events, key=lambda e: _us(e["occurred_at"]))
    state, problems, compared = State(), [], set()
    # Events of the same microsecond are simultaneous (two API Pods can
    # create two jobs at once): neither knew of the other, so read every
    # submission's features before applying any of them.
    for _, group in itertools.groupby(order, key=lambda e: _us(e["occurred_at"])):
        group = list(group)
        for e in group:
            p = e["payload"]
            key = (e["tenant"], p["job_id"])
            # Once per job, at its first "queued": a duplicate comes later.
            if p["state"] != "queued" or key not in where or key in compared:
                continue
            compared.add(key)
            got = state.features(e["tenant"], p["kind"], p["size"], _us(p["created_at"]))
            for name in dataset.FEATURES:
                want = batch[name][where[key]]
                if not _same(got[name], want):
                    problems.append(
                        f"job {key[1]} ({key[0]}): {name} online {got[name]}, batch {want}"
                    )
        for e in sorted(group, key=lambda e: _rank(e["payload"]["state"])):
            state.apply(e)
    return problems


def _rank(state: str) -> int:
    """Events at the same microsecond: queued, then running, then finished."""
    return {"queued": 0, "running": 1}.get(state, 2)


def _same(a, b) -> bool:
    if isinstance(a, str) or isinstance(b, str):
        return a == b
    if np.isnan(a) or np.isnan(b):
        return bool(np.isnan(a) and np.isnan(b))
    return bool(np.isclose(a, b, rtol=1e-12, atol=0))


def events_from(data) -> list[dict]:
    """Every event in the pipeline's files, duplicates and all, shaped as the contract says."""
    import duckdb

    con = duckdb.connect()
    con.execute("SET TimeZone = 'UTC'")
    files = f"{data}/events/**/*.parquet"
    rows = con.execute(f"""
        SELECT event_id, strftime(occurred_at, '%Y-%m-%dT%H:%M:%S.%fZ'), tenant, job_id, state,
               kind, size, strftime(created_at, '%Y-%m-%dT%H:%M:%S.%fZ'),
               strftime(started_at, '%Y-%m-%dT%H:%M:%S.%fZ'),
               strftime(finished_at, '%Y-%m-%dT%H:%M:%S.%fZ')
        FROM read_parquet('{files}', union_by_name = true)""").fetchall()
    return [
        {
            "id": r[0],
            "occurred_at": r[1],
            "tenant": r[2],
            "payload": {
                "job_id": r[3],
                "state": r[4],
                "kind": r[5],
                "size": r[6],
                "created_at": r[7],
                **({"started_at": r[8]} if r[8] else {}),
                **({"finished_at": r[9]} if r[9] else {}),
            },
        }
        for r in rows
    ]


def served_from(log_lines) -> list[dict]:
    """The predictions the service logged: one JSON line each, with the features it used."""
    import json

    out = []
    for line in log_lines:
        line = line.strip()
        if line.startswith("{") and '"served"' in line:
            out.append(json.loads(line))
    return out


def skew(served: list[dict], jobs: dict[str, np.ndarray]) -> dict:
    """Compare the features the service used with the batch's, for the same jobs.

    A served prediction is matched to the job of the same tenant, kind and
    size created closest to it, within a second: the API stamps the job's
    creation time, then asks, then stores the job.
    """
    batch = dataset.features(jobs)
    index = {}
    for i, key in enumerate(zip(jobs["tenant"], jobs["kind"], jobs["size"], strict=True)):
        index.setdefault(tuple(key), []).append(i)
    matched, diffs = 0, {name: [] for name in dataset.FEATURES[3:]}
    for s in served:
        f = s["features"]
        candidates = index.get((f["tenant"], f["kind"], f["size"]), [])
        if not candidates:
            continue
        i = min(candidates, key=lambda c: abs(int(jobs["created"][c]) - s["at_us"]))
        if abs(int(jobs["created"][i]) - s["at_us"]) < 1_000_000:
            matched += 1
            for name in diffs:
                online = np.nan if f[name] is None else float(f[name])
                diffs[name].append((online, float(batch[name][i])))
    report = {"served": len(served), "matched": matched}
    for name, pairs in diffs.items():
        if not pairs:
            report[name] = {
                "same": float("nan"),
                "mean_diff": float("nan"),
                "max_abs": float("nan"),
            }
            continue
        on, off = np.array(pairs).T
        same = (np.isnan(on) & np.isnan(off)) | np.isclose(on, off, rtol=1e-9, atol=0)
        d = on - off
        report[name] = {
            "same": float(np.mean(same)),
            "mean_diff": float(np.nanmean(d)) if not np.isnan(d).all() else 0.0,
            "max_abs": float(np.nanmax(np.abs(d))) if not np.isnan(d).all() else 0.0,
        }
    return report
~~~

`State.apply` moves each job forward through queued, running and done, and never back: a duplicate, or a late report about a finished job, changes nothing (step 3: events arrive at least once). `State.features` reads the counts off the state for a job submitted now. `parity` replays recorded events in the order they happened, and at each job's first submission event compares the online features with `dataset.features`'s. Events of the same microsecond are treated as simultaneous: two API Pods can create two jobs at once, and neither knew of the other. (`served_from` and `skew` are for later, when the service is running.)

Add the command, in `lab/src/lab/cli.py` (with the others this step adds; each is explained where it's used):

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python
from lab import analyze, experiment, jobs, sim
~~~

to:

~~~python
# Each command imports what it uses, inside it: the prediction service
# runs this file too, and mustn't load plotting code it never calls
# (Matplotlib crashed it, wanting a writable home directory: step 8).
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python
def cmd_run(args: argparse.Namespace) -> int:
    plan = experiment.load_plan(args.plan)
~~~

to:

~~~python
def cmd_run(args: argparse.Namespace) -> int:
    from lab import experiment

    plan = experiment.load_plan(args.plan)
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python
def cmd_analyze(args: argparse.Namespace) -> int:
    print(analyze.report(args.results))
~~~

to:

~~~python
def cmd_analyze(args: argparse.Namespace) -> int:
    from lab import analyze

    print(analyze.report(args.results))
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python
def cmd_jobs(args: argparse.Namespace) -> int:
    rows = jobs.load(args.file)
~~~

to:

~~~python
def cmd_jobs(args: argparse.Namespace) -> int:
    from lab import jobs

    rows = jobs.load(args.file)
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

def cmd_simulate(args: argparse.Namespace) -> int:
    if args.trap == "many":
~~~

to:

~~~python

def cmd_parity(args: argparse.Namespace) -> int:
    from lab import dataset, online

    events = online.events_from(args.data)
    problems = online.parity(events, dataset.load_jobs(args.data))
    print(f"{len(events)} events replayed; {len(problems)} differences from the batch")
    for line in problems[: args.show]:
        print(f"  {line}")
    return 1 if problems else 0


def cmd_skew(args: argparse.Namespace) -> int:
    from lab import dataset, online
    from lab.warehouse import table

    served = online.served_from(args.log.read_text().splitlines())
    report = online.skew(served, dataset.load_jobs(args.data))
    print(f"{report.pop('served')} predictions logged, {report.pop('matched')} matched to jobs")
    rows = [[name, r["same"] * 100, r["mean_diff"], r["max_abs"]] for name, r in report.items()]
    print(table(["feature", "same_%", "mean_online_minus_batch", "max_abs_diff"], rows))
    return 0


def cmd_export(args: argparse.Namespace) -> int:
    from lab import export

    artifact = export.export(args.dataset, args.out, args.point)
    print(f"{artifact['version']}: {artifact['rows']} jobs, up to {artifact['data_until']}")
    print(f"wrote {args.out} ({args.out.stat().st_size / 1e3:.0f} kB)")
    return 0


def cmd_serve(args: argparse.Namespace) -> int:
    import logging

    import uvicorn

    from lab import export, serve
    from lab.contract import Contract

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    stream = serve.KafkaStream(args.brokers, args.topic)
    service = serve.Service(export.load(args.model), stream, Contract(args.contract))
    if args.metrics_port:
        # Metrics on a port of their own, so Prometheus can be let in to
        # them without being let in to /predict.
        from prometheus_client import start_http_server

        start_http_server(args.metrics_port, registry=service.registry)
    uvicorn.run(serve.create_app(service), host=args.host, port=args.port, access_log=False)
    return 0


def cmd_simulate(args: argparse.Namespace) -> int:
    from lab import sim

    if args.trap == "many":
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

    simulate = sub.add_parser(
~~~

to:

~~~python

    par = sub.add_parser("parity", help="replay events through the online state; compare")
    par.add_argument("--data", type=Path, default=Path("data"))
    par.add_argument("--show", type=int, default=10)
    par.set_defaults(func=cmd_parity)

    sk = sub.add_parser("skew", help="served features against the batch's, for the same jobs")
    sk.add_argument("log", type=Path, help="the predictor's log (kubectl logs)")
    sk.add_argument("--data", type=Path, default=Path("data"))
    sk.set_defaults(func=cmd_skew)

    ex = sub.add_parser("export", help="fit the served models on every row and save them")
    ex.add_argument("dataset", type=Path)
    ex.add_argument("--out", type=Path, default=Path("models/runtime.pkl"))
    ex.add_argument(
        "--point", choices=["trees", "numpy"], default="trees", help="typical-time model"
    )
    ex.set_defaults(func=cmd_export)

    sv = sub.add_parser("serve", help="answer predictions over HTTP, following the job events")
    sv.add_argument("--model", type=Path, default=Path("models/runtime.pkl"))
    sv.add_argument("--brokers", default="localhost:39092")
    sv.add_argument("--topic", default="runway.job-events")
    sv.add_argument("--contract", type=Path, default=Path("contracts/job_changed.v2.schema.json"))
    sv.add_argument("--host", default="127.0.0.1")
    sv.add_argument("--port", type=int, default=8000)
    sv.add_argument("--metrics-port", type=int, default=0, help="also serve /metrics here")
    sv.set_defaults(func=cmd_serve)

    simulate = sub.add_parser(
~~~


Each command now imports what it uses inside itself. The service runs this file too, and an import at the top pulled in Matplotlib, which the service never draws with and which, on its read-only filesystem, refused to start. More on that when it happened.

Run the parity check with step 5's `dataset.py` unchanged:

~~~text
Using CPython 3.12.3 interpreter at: /usr/bin/python3.12
Creating virtual environment at: /home/techieemma/blueprint-scratch/tmp/brk8/lab/.venv
   Building lab @ file:///home/techieemma/blueprint-scratch/tmp/brk8/lab
      Built lab @ file:///home/techieemma/blueprint-scratch/tmp/brk8/lab
Installed 52 packages in 369ms
87612 events replayed; 22652 differences from the batch
  job 5269 (initech): running_at_submit online 0, batch 2
  job 5269 (initech): queued_at_submit online 2, batch 0
  job 5270 (acme): running_at_submit online 0, batch 2
  job 5270 (acme): queued_at_submit online 3, batch 1
~~~

Tens of thousands of differences. Look at the first: when job 5269 was submitted, the batch says two jobs were running, and the online state says they were still queued. Who's right? The batch counts a job as running from `started_at`, the time on the *worker's* clock when the work began. The online state counts it from when the API *recorded* the start: the event's `occurred_at`, after the worker's report crossed RabbitMQ and the API processed it. How far apart are they?

~~~bash
uv run --project lab lab sql "SELECT state, count(*) AS events,
  median(epoch_us(occurred_at) - epoch_us(CASE state WHEN 'running' THEN started_at
    WHEN 'queued' THEN created_at ELSE finished_at END)) / 1000 AS lag_p50_ms,
  quantile_cont(epoch_us(occurred_at) - epoch_us(CASE state WHEN 'running' THEN started_at
    WHEN 'queued' THEN created_at ELSE finished_at END), 0.99) / 1000 AS lag_p99_ms
  FROM events GROUP BY 1 ORDER BY 1"
~~~

~~~text
    state  events  lag_p50_ms  lag_p99_ms
---------  ------  ----------  ----------
completed   19795      22.988     983.525
   queued   19795       0.000       0.000
  running   19788      24.156     922.522
~~~

The API learns of a start 24 ms after it happens, at the median, and nearly a second later at the 99th percentile, under load. During that time, no API could have known the job had started. So step 5's batch features used information that wasn't available at the moment of the question: a leak, of milliseconds to a second. Its leak test didn't catch it because it ran on `synth`'s data, where every event is recorded at exactly the worker's time. A test can only find a bug its data can show.

Fix the batch: count from when each change was recorded. In `lab/src/lab/dataset.py`:

Change:

<!-- edit: lab/src/lab/dataset.py -->
~~~python
    """Every job the events (up to as_of) know of, with its times so far, ordered by creation."""
~~~

to:

~~~python
    """Every job the events (up to as_of) know of, with its times so far, ordered by creation.

    started and finished are the worker's clock: when the work ran, for
    run_s. start_seen and finish_seen are when the API recorded each:
    when the system knew. Features must use those (step 8 found why).
    """
~~~

Change:

<!-- edit: lab/src/lab/dataset.py -->
~~~python
    cols = con.execute("""
        SELECT tenant, job_id, kind, size, state, run_s, wait_s,
~~~

to:

~~~python
    cols = con.execute("""
        WITH seen AS (
            SELECT tenant, job_id,
                   epoch_us(min(occurred_at) FILTER (WHERE state = 'running')) AS start_seen,
                   epoch_us(min(occurred_at) FILTER (WHERE state IN ('completed', 'failed')))
                       AS finish_seen
            FROM events GROUP BY ALL)
        SELECT tenant, job_id, kind, size, state, run_s, wait_s,
~~~

Change:

<!-- edit: lab/src/lab/dataset.py -->
~~~python
               epoch_us(finished_at) AS finished
        FROM jobs ORDER BY created, tenant, job_id
~~~

to:

~~~python
               epoch_us(finished_at) AS finished, start_seen, finish_seen
        FROM jobs JOIN seen USING (tenant, job_id)
        ORDER BY created, tenant, job_id
~~~

Change:

<!-- edit: lab/src/lab/dataset.py -->
~~~python
    """What the system looked like just before each job was created.
~~~

to:

~~~python
    """What the system knew just before each job was created.
~~~

Change:

<!-- edit: lab/src/lab/dataset.py -->
~~~python
    Counts of events strictly before the job's creation: at that moment, a
    job is running if it has started and not finished, queued if it has
    been created and not started. Unknown times (NULL) are never counted.
~~~

to:

~~~python
    Counts of events recorded strictly before the job's creation: at that
    moment, a job is running if its start has been recorded and its finish
    hasn't; queued if it has been created and hasn't left the queue. It
    leaves the queue when its start is recorded, or, if no start ever is
    (step 2's race), when its finish is. Unknown times are never counted.
~~~

Change:

<!-- edit: lab/src/lab/dataset.py -->
~~~python
    started, finished = np.ma.asarray(jobs["started"]), np.ma.asarray(jobs["finished"])
    starts = np.sort(started.compressed())
    # Only finishes whose start is known: a job that completed with its
    # start unknown (step 2's race) was never counted as running, so
    # counting its finish would leave every later count one too low.
    finishes = np.sort(finished[~np.ma.getmaskarray(started)].compressed())
~~~

to:

~~~python
    start, finish = np.ma.asarray(jobs["start_seen"]), np.ma.asarray(jobs["finish_seen"])
    started = ~np.ma.getmaskarray(start)
    starts = np.sort(start.compressed())
    # Only finishes of jobs whose start was recorded: a job never counted as
    # running mustn't be subtracted from the running.
    finishes = np.sort(finish[started].compressed())
    leaves = np.sort(np.ma.where(started, start, finish).compressed())
~~~

Change:

<!-- edit: lab/src/lab/dataset.py -->
~~~python
        "queued_at_submit": before(creations, created) - before(starts, created),
~~~

to:

~~~python
        "queued_at_submit": before(creations, created) - before(leaves, created),
~~~

Change:

<!-- edit: lab/src/lab/dataset.py -->
~~~python
    that had finished before it was submitted (NaN if there were none).
~~~

to:

~~~python
    whose finish was recorded before it was submitted (NaN if there were none).
~~~

Change:

<!-- edit: lab/src/lab/dataset.py -->
~~~python
    finished = np.ma.filled(np.ma.asarray(jobs["finished"]), np.iinfo(np.int64).max)
~~~

to:

~~~python
    finished = np.ma.filled(np.ma.asarray(jobs["finish_seen"]), np.iinfo(np.int64).max)
~~~


`load_jobs` now also returns `start_seen` and `finish_seen`, the first recorded time of each, and `features` and `history` use those. A job leaves the queue when its start is recorded or, if no start ever is (step 5's seven racing jobs), when its finish is. The old code left those seven jobs queued forever, so every later `queued_at_submit` was too high, by up to seven.

The tests' hand-made jobs now say what the API recorded. In `lab/tests/test_dataset.py`:

Change:

<!-- edit: lab/tests/test_dataset.py -->
~~~python
        "started": np.ma.masked_array([5, 6, 0, 75], mask=[0, 0, 1, 0]) * us,
        "finished": np.ma.masked_array([8, 80, 0, 90], mask=[0, 0, 1, 0]) * us,
~~~

to:

~~~python
        "start_seen": np.ma.masked_array([5, 6, 0, 75], mask=[0, 0, 1, 0]) * us,
        "finish_seen": np.ma.masked_array([8, 80, 0, 90], mask=[0, 0, 1, 0]) * us,
~~~

Change:

<!-- edit: lab/tests/test_dataset.py -->
~~~python
        "started": np.ma.masked_array([0, 20, 35], mask=[1, 0, 0]) * us,
        "finished": np.ma.masked_array([5, 40, 50], mask=[0, 0, 0]) * us,
~~~

to:

~~~python
        "start_seen": np.ma.masked_array([0, 20, 35], mask=[1, 0, 0]) * us,
        "finish_seen": np.ma.masked_array([5, 40, 50], mask=[0, 0, 0]) * us,
~~~

Change:

<!-- edit: lab/tests/test_dataset.py -->
~~~python
    assert dataset.features(jobs)["running_at_submit"].tolist() == [0, 0, 1]
~~~

to:

~~~python
    f = dataset.features(jobs)
    assert f["running_at_submit"].tolist() == [0, 0, 1]
    assert f["queued_at_submit"].tolist() == [0, 0, 0], "job 0 left the queue when it finished"


def test_a_start_counts_from_when_the_api_recorded_it():
    us = 1_000_000
    jobs = {  # job 0's worker began at 5 s, but the API heard of it at 8 s
        "tenant": np.array(["a", "a"]),
        "kind": np.array(["sort", "sort"]),
        "size": np.array([1, 2]),
        "created": np.array([0, 6]) * us,
        "started": np.ma.masked_array([5, 9], mask=[0, 0]) * us,
        "start_seen": np.ma.masked_array([8, 10], mask=[0, 0]) * us,
        "finish_seen": np.ma.masked_array([20, 30], mask=[0, 0]) * us,
        "run_s": np.ma.masked_array([10.0, 15.0], mask=[0, 0]),
    }
    f = dataset.features(jobs)
    assert (f["running_at_submit"][1], f["queued_at_submit"][1]) == (0, 1), "at 6 s, still queued"
~~~

Change:

<!-- edit: lab/tests/test_dataset.py -->
~~~python
        "finished": np.ma.masked_array([11, 26, 0, 40, 35], mask=[0, 0, 1, 0, 0]) * us,
~~~

to:

~~~python
        "finish_seen": np.ma.masked_array([11, 26, 0, 40, 35], mask=[0, 0, 1, 0, 0]) * us,
~~~


Create `lab/tests/test_online.py`. Its `lagged` fixture is a synthetic day whose starts and finishes are recorded up to a second late, as on the cluster, one lag per job so that each job's events stay in order. The online state and the batch must agree on it, and must *disagree* if the batch goes back to the worker's clock. That's the test step 5 needed:

<!-- file: lab/tests/test_online.py -->
~~~python
import math
from datetime import UTC, datetime, timedelta

import numpy as np
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.parquet as pq
import pytest

from lab import dataset, online, synth

US = 1_000_000
BASE = int(datetime(2026, 10, 17, tzinfo=UTC).timestamp()) * US  # event() times count from here


def event(job, state, at, tenant="a", kind="sort", created=0, started=None, finished=None):
    def iso(us):
        t = datetime(2026, 10, 17, tzinfo=UTC) + timedelta(microseconds=us)
        return t.strftime("%Y-%m-%dT%H:%M:%S.%fZ")

    payload = {"job_id": job, "state": state, "kind": kind, "size": 1, "created_at": iso(created)}
    if started is not None:
        payload["started_at"] = iso(started)
    if finished is not None:
        payload["finished_at"] = iso(finished)
    return {"id": f"{job}{state}", "occurred_at": iso(at), "tenant": tenant, "payload": payload}


def test_a_job_moves_through_the_state_and_duplicates_change_nothing():
    s = online.State()
    s.apply(event(1, "queued", 0))
    s.apply(event(1, "queued", 0))  # delivered twice
    assert (len(s.queued), len(s.running)) == (1, 0)
    s.apply(event(1, "running", 2 * US, started=1 * US))
    assert (len(s.queued), len(s.running)) == (0, 1)
    s.apply(event(1, "completed", 5 * US, started=1 * US, finished=4 * US))
    s.apply(event(1, "running", 2 * US, started=1 * US))  # a late duplicate
    assert (len(s.queued), len(s.running)) == (0, 0)
    assert s.history[("a", "sort")] == [1, pytest.approx(math.log(3.0))]


def test_a_job_that_completes_with_no_start_leaves_the_queue():
    s = online.State()
    s.apply(event(1, "queued", 0))
    s.apply(event(1, "completed", 5 * US, finished=4 * US))
    assert (len(s.queued), len(s.running), s.history) == (0, 0, {})


def test_recent_counts_the_last_minute_up_to_but_not_including_now():
    s = online.State()
    for job, at in [(1, 0), (2, 30), (3, 59)]:
        s.apply(event(job, "queued", at * US, created=at * US))
    assert s.features("a", "sort", 1, BASE + 60 * US)["tenant_recent"] == 3  # 0 s: a minute ago
    assert s.features("a", "sort", 1, BASE + 61 * US)["tenant_recent"] == 2


@pytest.fixture(scope="module")
def lagged(tmp_path_factory):
    """A synthetic day whose starts and finishes the API records late, as on the cluster:
    the worker's clock says one moment, the event another (step 8 measured 24 ms to a second)."""
    out = tmp_path_factory.mktemp("lagged")
    real = {
        "kind": np.array(["checksum", "compress", "sort"] * 20),
        "size": np.geomspace(1e4, 1e8, 60).astype(np.int64),
        "wait_s": np.linspace(0.05, 8.0, 60),
        "run_s": np.geomspace(0.02, 20.0, 60),
    }
    synth.make(real, out, synth.Spec(jobs=8_000, days=1, tenants=4, seed=5))
    for path in out.glob("events/**/*.parquet"):
        t = pq.read_table(path)
        recorded = pc.not_equal(t["state"], "queued")
        # One lag per job, up to a second, the same for its start and its
        # finish: the API records a job's changes in the order they happen.
        lag = pc.multiply(pc.bit_wise_and(pc.multiply(t["job_id"], 7919), 1023), 1000)
        at = pc.cast(t["occurred_at"], pa.int64())
        at = pc.if_else(recorded, pc.add(at, lag), at)
        t = t.set_column(1, "occurred_at", pc.cast(at, t.schema.field("occurred_at").type))
        pq.write_table(t, path)
    return out


def test_online_and_batch_agree_when_events_are_recorded_late(lagged):
    events = online.events_from(lagged)
    assert online.parity(events, dataset.load_jobs(lagged)) == []


def test_and_disagree_if_the_batch_uses_the_workers_clock(lagged):
    jobs = dataset.load_jobs(lagged)
    jobs["start_seen"], jobs["finish_seen"] = jobs["started"], jobs["finished"]  # the step 5 leak
    assert len(online.parity(online.events_from(lagged), jobs)) > 100


def test_skew_matches_each_prediction_to_its_job():
    jobs = {  # two jobs alike but for when; the second is the one predicted
        "tenant": np.array(["a", "a"]),
        "job_id": np.array([1, 2]),
        "kind": np.array(["sort", "sort"]),
        "size": np.array([5, 5]),
        "created": np.array([0, 100 * US]),
        "start_seen": np.ma.masked_array([1 * US, 0], mask=[0, 1]),
        "finish_seen": np.ma.masked_array([2 * US, 0], mask=[0, 1]),
        "run_s": np.ma.masked_array([1.0, 0.0], mask=[0, 1]),
    }
    served = [  # asked 3 ms after job 2's creation was stamped, seeing one job too many queued
        {
            "at_us": 100 * US + 3_000,
            "features": {
                "tenant": "a",
                "kind": "sort",
                "size": 5,
                "running_at_submit": 0,
                "queued_at_submit": 1,
                "tenant_recent": 0,
                "history_log_run": 0.0,
            },
        }
    ]
    report = online.skew(served, jobs)
    assert report["matched"] == 1
    assert (
        report["queued_at_submit"]["same"] == 0.0 and report["queued_at_submit"]["mean_diff"] == 1
    )
    assert report["running_at_submit"]["same"] == 1.0
~~~

<!-- run: cd lab && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_dataset.py tests/test_online.py -->

Now run it again on the real data:

~~~bash
uv run --project lab lab parity
~~~

~~~text
87612 events replayed; 0 differences from the batch
~~~

None. On the way there, the replay also found two smaller bugs, both mine. My first comparison counted duplicates, comparing again at a job's second "queued" event, by which time it had queued itself. And the online `tenant_recent` dropped a submission exactly sixty seconds old, which the batch counts. Each was one line, and each would otherwise have been skew in production.

How much did the leak matter? Rebuild the dataset and retrain:

~~~bash
uv run --project lab lab dataset && uv run --project lab lab train results/dataset.parquet | head -6
~~~

~~~text
3958 valid jobs, models trained on 11872; MAE_vs_ref compares each with kind power law + running
                   model  MAE_s  MAPE_%  log_factor  spearman  MAE_vs_ref_s              95% CI
------------------------  -----  ------  ----------  --------  ------------  ------------------
kind power law + running  0.062  33.459       1.455     0.849                                  
                   trees  0.054  32.756       1.383     0.881       -0.0082  -0.0169 .. -0.0000
         trees + history  0.054  31.382       1.378     0.884       -0.0085  -0.0181 .. +0.0005
~~~

Against step 6's validation table: the power law with contention got worse (1.441 to 1.455). Its `running_at_submit` had been carrying a little of the future. The trees didn't move (1.380 to 1.378). Steps 5 to 7 measured what they measured; from here on, the features are the honest ones.

### The model, as an artifact

Evaluation is over, so the served model is fitted on every row: the newest data, and the most. Create `lab/src/lab/export.py`:

<!-- file: lab/src/lab/export.py -->
~~~python
"""The model the service serves: fitted on every row, saved with what it is.

Evaluation is over, so the final fit uses all the data, training,
validation and test, which is the most recent and the most. The file
holds two models (step 7's verdict: the trees for the typical run time,
the power law for the bound a tenant is promised), the features they
expect, and a version that names the data they learned from.
"""

import hashlib
import pickle
from datetime import datetime
from pathlib import Path

import numpy as np

from lab import dataset
from lab.baselines import KindPowerLaw
from lab.model import CATEGORIES, NUMBERS, Boosted
from lab.nn import NumpyNet

FORMAT = 1  # what the file holds; the service refuses others


def export(dataset_path: Path, out: Path, point_model: str = "trees") -> dict:
    """point_model: "trees" (step 6's, the most accurate) or "numpy" (step 7's network:
    nearly as accurate, and a hundred times cheaper to ask)."""
    data = dataset.load(dataset_path)
    if point_model == "numpy":
        point = NumpyNet().fit(data)
    else:
        point = Boosted("trees + history", CATEGORIES + NUMBERS).fit(data)
    bound = KindPowerLaw(contention=True, quantile=0.9).fit(data)
    newest = np.max(data["created_at"]).astype("datetime64[s]").astype(datetime)
    digest = hashlib.sha256(dataset_path.read_bytes()).hexdigest()[:8]
    artifact = {
        "format": FORMAT,
        "version": f"runtime-{point_model}-{newest:%Y%m%d-%H%M}-{digest}",
        "features": CATEGORIES + NUMBERS,
        "point": point,
        "bound": bound,
        "rows": len(data["run_s"]),
        "data_until": newest.isoformat() + "Z",
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(pickle.dumps(artifact))
    return artifact


def load(path: Path) -> dict:
    """A saved artifact. Unpickling runs code from the file: load only files you made."""
    artifact = pickle.loads(path.read_bytes())
    if artifact.get("format") != FORMAT:
        raise ValueError(f"{path}: format {artifact.get('format')}, want {FORMAT}")
    return artifact
~~~

The file holds two models, per step 7's verdict: the trees for the typical run time (or, with `--point numpy`, step 7's hand-written network, which matters later) and the power law for the p90. It also holds the features they expect, and a version naming the data they learned from. It's a pickle, and unpickling runs code from the file: load only files you made, which is also why step 10 will keep them in a registry.

### The service

FastAPI and uvicorn to serve it, the Prometheus client for its metrics, and httpx2 for FastAPI's test client. In `lab/pyproject.toml`:

Change:

<!-- edit: lab/pyproject.toml -->
~~~toml
    "duckdb>=1.5.6",
    "jsonschema>=4.26.0",
~~~

to:

~~~toml
    "duckdb>=1.5.6",
    "fastapi>=0.143.3",
    "jsonschema>=4.26.0",
~~~

Change:

<!-- edit: lab/pyproject.toml -->
~~~toml
    "pandas>=3.0.6",
    "pyarrow>=26.0.0",
~~~

to:

~~~toml
    "pandas>=3.0.6",
    "prometheus-client>=0.26.0",
    "pyarrow>=26.0.0",
~~~

Change:

<!-- edit: lab/pyproject.toml -->
~~~toml
    "scikit-learn>=1.9.1",
]
~~~

to:

~~~toml
    "scikit-learn>=1.9.1",
    "uvicorn>=0.54.0",
]
~~~

Change:

<!-- edit: lab/pyproject.toml -->
~~~toml
dev = [
    "pytest>=9.1.1",
~~~

to:

~~~toml
dev = [
    "httpx2>=2.13.1",
    "pytest>=9.1.1",
~~~


Create `lab/src/lab/serve.py`:

<!-- file: lab/src/lab/serve.py -->
~~~python
"""The prediction service: the API asks, before it creates a job, how long the job will run.

The request carries only what the API knows of the job itself: tenant,
kind and size. Everything about the rest of the system (how many jobs are
running and queued, what this tenant has been doing) comes from the job
events, which a background thread reads from Kafka into online.State:
from the start of the topic when the service starts, then as they come.
The service isn't ready until it has caught up, because until then its
counts are wrong.

Sleep jobs aren't predicted: their run time is the duration they declare.
"""

import json
import logging
import threading
import time
from contextlib import asynccontextmanager
from typing import Literal, Protocol

import numpy as np
from fastapi import FastAPI, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)
from pydantic import BaseModel, Field

from lab.contract import Contract
from lab.online import State

log = logging.getLogger("predictor")


class Stream(Protocol):
    def next(self, timeout: float) -> bytes | None: ...

    def caught_up(self) -> bool:
        """True once every message that existed when the service started has been read."""


class KafkaStream:
    """The topic, every partition from its first offset, with no consumer group commits:
    each start replays everything still in the topic (seven days, step 3)."""

    def __init__(self, brokers: str, topic: str):
        from confluent_kafka import OFFSET_BEGINNING, Consumer, TopicPartition

        self.consumer = Consumer(
            {"bootstrap.servers": brokers, "group.id": "predictor", "enable.auto.commit": False}
        )
        partitions = self.consumer.list_topics(topic, timeout=10).topics[topic].partitions
        self.parts = [TopicPartition(topic, p, OFFSET_BEGINNING) for p in partitions]
        self.consumer.assign(self.parts)
        # Where each partition ended when we started: the replay is done
        # when the read position passes all of them.
        self.ends = {
            p.partition: self.consumer.get_watermark_offsets(p, timeout=10)[1] for p in self.parts
        }
        self.read = {p: 0 for p in self.ends}

    def next(self, timeout: float) -> bytes | None:
        msg = self.consumer.poll(timeout)
        if msg is None or msg.error():
            return None
        self.read[msg.partition()] = msg.offset() + 1
        return msg.value()

    def caught_up(self) -> bool:
        return all(self.read[p] >= end for p, end in self.ends.items())


class Ask(BaseModel):
    tenant: str = Field(min_length=1, max_length=64)
    kind: Literal["checksum", "compress", "sort"]
    size: int = Field(gt=0)


class Service:
    def __init__(self, artifact: dict, stream: Stream, contract: Contract, clock=time.time):
        self.artifact, self.stream, self.contract, self.clock = artifact, stream, contract, clock
        self.state, self.lock = State(), threading.Lock()
        self.ready = threading.Event()
        self.stopping = threading.Event()
        self.registry = CollectorRegistry()
        self.latency = Histogram(
            "predict_seconds",
            "Time to answer one prediction.",
            buckets=(0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 1),
            registry=self.registry,
        )
        self.rejected = Counter(
            "events_rejected_total", "Events that broke the contract.", registry=self.registry
        )
        Gauge(
            "events_applied", "Events applied to the state.", registry=self.registry
        ).set_function(lambda: self.state.applied)
        Gauge(
            "state_lag_seconds",
            "How long ago the newest applied event happened.",
            registry=self.registry,
        ).set_function(lambda: self.clock() - self.state.newest_us / 1e6)
        Gauge("caught_up", "1 once the replay has caught up.", registry=self.registry).set_function(
            lambda: float(self.ready.is_set())
        )

    def follow(self) -> None:
        """Apply events as they arrive, until stopped. Runs in its own thread."""
        while not self.stopping.is_set():
            raw = self.stream.next(0.5)
            if raw is not None:
                event, why = self.contract.check(raw)
                if event is None:
                    self.rejected.inc()
                    log.warning("event refused: %s", why)
                else:
                    with self.lock:
                        self.state.apply(event)
            if not self.ready.is_set() and self.stream.caught_up():
                self.ready.set()
                log.info("caught up: %d events applied", self.state.applied)

    def predict(self, ask: Ask) -> dict:
        start = time.perf_counter()
        at_us = int(self.clock() * 1e6)
        with self.lock:
            features = self.state.features(ask.tenant, ask.kind, ask.size, at_us)
        rows = {name: np.array([value]) for name, value in features.items()}
        run_s = float(self.artifact["point"].predict(rows)[0])
        p90_s = float(self.artifact["bound"].predict(rows)[0])
        self.latency.observe(time.perf_counter() - start)
        # Two models can disagree, and a bound below the typical time is no bound.
        answer = {"run_s": run_s, "p90_s": max(p90_s, run_s), "model": self.artifact["version"]}
        # One line per prediction, with the features it saw: step 8 checks
        # them against the batch's, for the same jobs, afterwards.
        log.info(json.dumps({"served": answer, "at_us": at_us, "features": _plain(features)}))
        return answer | {"features": _plain(features)}


def _plain(features: dict) -> dict:
    out = {}
    for k, v in features.items():
        if isinstance(v, float) and np.isnan(v):
            out[k] = None
        elif isinstance(v, np.integer):
            out[k] = int(v)
        else:
            out[k] = v
    return out


def create_app(service: Service) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        thread = threading.Thread(target=service.follow, name="follow", daemon=True)
        thread.start()
        yield
        service.stopping.set()
        thread.join(timeout=5)

    app = FastAPI(title="Runway run-time predictor", lifespan=lifespan)

    @app.post("/predict")
    def predict(ask: Ask, response: Response) -> dict:
        if not service.ready.is_set():
            response.status_code = 503
            return {"error": "not caught up with the job events yet"}
        return service.predict(ask)

    @app.get("/health")
    def health() -> dict:
        return {"status": "ok"}

    @app.get("/ready")
    def ready(response: Response) -> dict:
        if not service.ready.is_set():
            response.status_code = 503
            return {"ready": False, "applied": service.state.applied}
        return {
            "ready": True,
            "applied": service.state.applied,
            "model": service.artifact["version"],
        }

    @app.get("/metrics")
    def metrics() -> Response:
        return Response(generate_latest(service.registry), media_type=CONTENT_TYPE_LATEST)

    return app
~~~

`KafkaStream` assigns itself every partition of the topic from the first offset, with no consumer group commits: each start replays everything still in the topic, which rebuilds the state from scratch, and records where each partition ended at that moment. `Service.follow` runs in its own thread, checking each event against step 3's contract and applying it. Until the replay has passed those end offsets, `/ready` answers 503 and so does `/predict`: before that its counts are wrong, and a wrong prediction is worse than none. `predict` reads the features under a lock (the follower writes them), asks both models, and logs one line with the features it used, which is how skew gets measured later. Sleeps are refused: their run time is the duration they declare.

Create `lab/tests/test_serve.py`. A fake stream feeds it events, including a duplicate and one that breaks the contract:

<!-- file: lab/tests/test_serve.py -->
~~~python
import json
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from test_model import FEATURES, jobs

from lab.baselines import KindPowerLaw
from lab.contract import Contract
from lab.model import Boosted
from lab.serve import Service, create_app

CONTRACTS = Path(__file__).parents[2] / "contracts"
EXAMPLE = json.loads((CONTRACTS / "examples" / "job_changed.v2.json").read_text())
NOW = 1_800_000_000.0  # a fixed clock, after the example's times


class ListStream:
    """Messages from a list; caught up once they're all read (or never, if stuck)."""

    def __init__(self, values: list[bytes], stuck: bool = False):
        self.values, self.stuck = list(values), stuck

    def next(self, timeout):
        if self.values:
            return self.values.pop(0)
        time.sleep(0.01)
        return None

    def caught_up(self):
        return not self.values and not self.stuck


def running(job_id: int) -> bytes:
    e = json.loads(json.dumps(EXAMPLE))
    e["id"], e["payload"]["job_id"], e["payload"]["state"] = f"r{job_id}", job_id, "running"
    del e["payload"]["finished_at"]
    return json.dumps(e).encode()


@pytest.fixture(scope="module")
def artifact():
    rows = jobs(3_000, 1)
    return {
        "format": 1,
        "version": "test-1",
        "features": FEATURES,
        "point": Boosted("trees", FEATURES).fit(rows),
        "bound": KindPowerLaw(contention=True, quantile=0.9).fit(rows),
    }


def client(artifact, values, stuck=False):
    service = Service(
        artifact,
        ListStream(values, stuck),
        Contract(CONTRACTS / "job_changed.v2.schema.json"),
        clock=lambda: NOW,
    )
    return TestClient(create_app(service))


def wait_ready(c, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if c.get("/ready").status_code == 200:
            return
        time.sleep(0.02)
    raise AssertionError("never became ready")


def test_it_predicts_from_the_events_it_has_seen(artifact):
    with client(artifact, [running(1), running(2), running(2)]) as c:  # 2 delivered twice
        wait_ready(c)
        r = c.post("/predict", json={"tenant": "acme", "kind": "compress", "size": 8_000_000})
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["model"] == "test-1" and 0 < body["run_s"] <= body["p90_s"]
        assert body["features"]["running_at_submit"] == 2
        assert body["features"]["history_log_run"] is None  # nothing finished yet


def test_it_refuses_to_predict_until_caught_up(artifact):
    with client(artifact, [], stuck=True) as c:
        assert c.get("/ready").status_code == 503
        r = c.post("/predict", json={"tenant": "acme", "kind": "sort", "size": 1000})
        assert r.status_code == 503


def test_sleeps_and_nonsense_are_refused(artifact):
    with client(artifact, []) as c:
        wait_ready(c)
        for ask in [
            {"tenant": "acme", "kind": "sleep", "size": 1},  # a sleep's run time is declared
            {"tenant": "acme", "kind": "sort", "size": 0},
            {"tenant": "", "kind": "sort", "size": 10},
        ]:
            assert c.post("/predict", json=ask).status_code == 422


def test_events_that_break_the_contract_are_counted_not_applied(artifact):
    with client(artifact, [b'{"version": 9}', running(1)]) as c:
        wait_ready(c)
        metrics = c.get("/metrics").text
        assert "events_rejected_total 1.0" in metrics and "events_applied 1.0" in metrics


def test_serving_loads_no_plotting_code():
    """The image's root filesystem is read-only, and Matplotlib, imported,
    insists on a writable directory: the service crashed on start (step 8)."""
    import subprocess
    import sys

    code = "import sys, lab.cli, lab.serve; print('matplotlib' in sys.modules)"
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True)
    assert out.stdout.strip() == "False"
~~~

The last test is the Matplotlib one: the service's process must not import plotting code.

Two more changes the service needs. The pipeline keeps the prediction, which the API will put in the events: in `lab/src/lab/pipeline.py`:

Change:

<!-- edit: lab/src/lab/pipeline.py -->
~~~python
        ("kafka_time", UTC_US),
    ]
~~~

to:

~~~python
        ("kafka_time", UTC_US),
        # Step 8: the prediction made at creation, when there was one.
        ("predicted_run_s", pa.float64()),
        ("predicted_p90_s", pa.float64()),
        ("prediction_model", pa.string()),
    ]
~~~

Change:

<!-- edit: lab/src/lab/pipeline.py -->
~~~python
        "kafka_time": record.timestamp,
    }
~~~

to:

~~~python
        "kafka_time": record.timestamp,
        "predicted_run_s": payload.get("predicted_run_s"),
        "predicted_p90_s": payload.get("predicted_p90_s"),
        "prediction_model": payload.get("prediction_model"),
    }
~~~


`synth` writes the pipeline's schema, so it needs the new columns too, empty. In `lab/src/lab/synth.py`:

Change:

<!-- edit: lab/src/lab/synth.py -->
~~~python
                "kafka_time": _ts(at + late),
            }
~~~

to:

~~~python
                "kafka_time": _ts(at + late),
                # No predictions here: these jobs were never served (step 8).
                "predicted_run_s": pa.nulls(n, pa.float64()),
                "predicted_p90_s": pa.nulls(n, pa.float64()),
                "prediction_model": pa.nulls(n, pa.string()),
            }
~~~


And an empty batch must get an empty answer: `codes` built its array without a type, and an empty list becomes floats, which can't index. In `lab/src/lab/nn.py`:

Change:

<!-- edit: lab/src/lab/nn.py -->
~~~python
        return np.array([index.get(v, 0) for v in rows[category]])
~~~

to:

~~~python
        return np.array([index.get(v, 0) for v in rows[category]], dtype=np.int64)
~~~


In `lab/tests/test_nn.py`:

At the end of the file, change:

<!-- edit: lab/tests/test_nn.py -->
~~~python
    assert set(nn.NUMBERS + nn.CATEGORIES) == set(FEATURES)
~~~

to:

~~~python
    assert set(nn.NUMBERS + nn.CATEGORIES) == set(FEATURES)


def test_an_empty_batch_gets_an_empty_answer(train):
    model = nn.NumpyNet(epochs=1).fit(train)
    none = {k: v[:0] for k, v in train.items()}
    assert model.predict(none).shape == (0,)
~~~


<!-- run: cd lab && uv sync --extra deep && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

### The API asks

In the domain, a job gets an optional prediction, and the service an optional predictor. In `internal/jobs/service.go`:

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	Dispatch(ctx context.Context, job Job) error
}
~~~

to:

~~~go
	Dispatch(ctx context.Context, job Job) error
}

// Prediction is how long a job is expected to run (Phase 7, step 8):
// typically RunS seconds, and within P90S for nine jobs in ten, by the
// named model.
type Prediction struct {
	RunS  float64
	P90S  float64
	Model string
}

// Predictor predicts a job's run time from what it is and who sent it,
// before it's created.
type Predictor interface {
	Predict(ctx context.Context, owner tenant.ID, work Work) (Prediction, error)
}
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	dispatch Dispatcher
	now      func() time.Time
~~~

to:

~~~go
	dispatch Dispatcher
	predict  Predictor
	now      func() time.Time
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	return func(s *Service) { s.dispatch = d }
}
~~~

to:

~~~go
	return func(s *Service) { s.dispatch = d }
}

// WithPredictor predicts every new job's run time with p. A prediction is
// an improvement, not a requirement: if p fails, the job is created
// without one.
func WithPredictor(p Predictor) Option {
	return func(s *Service) { s.predict = p }
}
~~~

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	job.Tenant = owner
	job, err = s.repo.Create(ctx, job)
~~~

to:

~~~go
	job.Tenant = owner
	// A sleep's run time is the duration it declares; only real work is
	// predicted. The predictor reports its own failures (metrics, logs);
	// here, a failure only means no prediction.
	if s.predict != nil && work.Kind != KindSleep {
		if p, err := s.predict.Predict(ctx, owner, work); err == nil {
			job.Prediction = &p
		}
	}
	job, err = s.repo.Create(ctx, job)
~~~


The rule is in `Create`: real work is predicted, a sleep isn't, and a failed prediction means no prediction, never a failed job. In `internal/jobs/job.go`:

Change:

<!-- edit: internal/jobs/job.go -->
~~~go
	FinishedAt time.Time
}
~~~

to:

~~~go
	FinishedAt time.Time
	// Prediction is the run time predicted when the job was created
	// (Phase 7, step 8), or nil if there was none.
	Prediction *Prediction
}
~~~


In `internal/jobs/service_test.go`:

Change:

<!-- edit: internal/jobs/service_test.go -->
~~~go
		t.Fatalf("started %v, finished %v; want zero and %v", got.StartedAt, got.FinishedAt, finished)
	}
~~~

to:

~~~go
		t.Fatalf("started %v, finished %v; want zero and %v", got.StartedAt, got.FinishedAt, finished)
	}
}

// predictor answers with a fixed prediction, or an error, and counts calls.
type predictor struct {
	p     jobs.Prediction
	err   error
	calls atomic.Int32
}

func (f *predictor) Predict(_ context.Context, owner tenant.ID, w jobs.Work) (jobs.Prediction, error) {
	f.calls.Add(1)
	return f.p, f.err
}

// A prediction is kept with the job; a predictor that fails costs the job
// its prediction, never its creation; and a sleep isn't predicted at all.
func TestCreatePredictsRealWorkOnly(t *testing.T) {
	ok := &predictor{p: jobs.Prediction{RunS: 0.4, P90S: 1.2, Model: "m1"}}
	svc := jobs.NewService(memstore.New(), jobs.WithPredictor(ok))
	job, err := svc.Create(acme, "pack", jobs.Work{Kind: jobs.KindCompress, Size: 1 << 20})
	if err != nil || job.Prediction == nil || *job.Prediction != ok.p {
		t.Fatalf("job %+v, %v", job.Prediction, err)
	}
	if got, _ := svc.Get(acme, job.ID); got.Prediction == nil || *got.Prediction != ok.p {
		t.Fatalf("stored prediction %+v", got.Prediction)
	}
	if nap, _ := svc.Create(acme, "nap", jobs.Sleep(time.Second)); nap.Prediction != nil || ok.calls.Load() != 1 {
		t.Fatalf("sleep predicted: %+v, calls %d", nap.Prediction, ok.calls.Load())
	}

	down := &predictor{err: errors.New("connection refused")}
	svc = jobs.NewService(memstore.New(), jobs.WithPredictor(down))
	job, err = svc.Create(acme, "pack", jobs.Work{Kind: jobs.KindCompress, Size: 1 << 20})
	if err != nil || job.ID == 0 || job.Prediction != nil {
		t.Fatalf("job %+v, %v: want created, without a prediction", job, err)
	}
~~~


The adapter does the asking. Create `internal/predict/predict.go`:

<!-- file: internal/predict/predict.go -->
~~~go
// Package predict asks the prediction service how long a job will run
// (Phase 7, step 8). It's jobs.Predictor over HTTP, with the three things a
// call in the request path needs: a deadline, so a slow predictor can't
// make job creation slow; a circuit breaker, so a dead one isn't waited for
// on every request; and a count of every outcome, so someone notices.
package predict

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"

	"runway/internal/breaker"
	"runway/internal/jobs"
	"runway/internal/tenant"
)

// Client calls the predictor at URL (POST URL/predict).
type Client struct {
	URL     string
	Timeout time.Duration
	HTTP    *http.Client
	Breaker *breaker.Breaker

	calls   *prometheus.CounterVec
	latency prometheus.Histogram
}

func New(url string, timeout time.Duration, b *breaker.Breaker) *Client {
	return &Client{
		URL: url, Timeout: timeout, HTTP: &http.Client{}, Breaker: b,
		calls: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "predictions_total",
			Help: "Calls to the predictor, by outcome: ok, timeout, error, or open (not tried: the breaker was open).",
		}, []string{"outcome"}),
		latency: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name:    "prediction_seconds",
			Help:    "Time spent asking the predictor, including the calls that timed out.",
			Buckets: []float64{.001, .0025, .005, .01, .025, .05, .1, .25},
		}),
	}
}

// Collectors are the client's metrics, to register.
func (c *Client) Collectors() []prometheus.Collector {
	return []prometheus.Collector{c.calls, c.latency}
}

type ask struct {
	Tenant string `json:"tenant"`
	Kind   string `json:"kind"`
	Size   int64  `json:"size"`
}

type answer struct {
	RunS  float64 `json:"run_s"`
	P90S  float64 `json:"p90_s"`
	Model string  `json:"model"`
}

// Predict asks, within c.Timeout. Any failure is an error for the caller
// to shrug off: jobs.Service creates the job without a prediction.
func (c *Client) Predict(ctx context.Context, owner tenant.ID, work jobs.Work) (jobs.Prediction, error) {
	start := time.Now()
	ctx, cancel := context.WithTimeout(ctx, c.Timeout)
	defer cancel()
	var got answer
	err := c.Breaker.Do(func() error {
		var err error
		got, err = c.call(ctx, ask{Tenant: string(owner), Kind: string(work.Kind), Size: work.Size})
		return err
	})
	if !errors.Is(err, breaker.ErrOpen) {
		c.latency.Observe(time.Since(start).Seconds())
	}
	c.calls.WithLabelValues(outcome(err)).Inc()
	if err != nil {
		return jobs.Prediction{}, err
	}
	return jobs.Prediction{RunS: got.RunS, P90S: got.P90S, Model: got.Model}, nil
}

func (c *Client) call(ctx context.Context, a ask) (answer, error) {
	body, _ := json.Marshal(a)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.URL+"/predict", bytes.NewReader(body))
	if err != nil {
		return answer{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return answer{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return answer{}, fmt.Errorf("predictor: %s", resp.Status)
	}
	var got answer
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		return answer{}, fmt.Errorf("predictor: %w", err)
	}
	if got.RunS <= 0 || got.P90S < got.RunS {
		return answer{}, fmt.Errorf("predictor: implausible answer %+v", got)
	}
	return got, nil
}

func outcome(err error) string {
	switch {
	case err == nil:
		return "ok"
	case errors.Is(err, breaker.ErrOpen):
		return "open"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	default:
		return "error"
	}
}
~~~

The deadline comes first, so a slow predictor costs each request at most `Timeout`. The breaker comes next, with its own instance: a failing predictor mustn't open the database's breaker. And every call is counted by outcome: `ok`, `timeout`, `error`, or `open` (not tried). An answer that makes no sense (a negative time, a bound below the typical time) is an error, not a prediction. Create `internal/predict/predict_test.go`:

<!-- file: internal/predict/predict_test.go -->
~~~go
package predict

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"

	"runway/internal/breaker"
	"runway/internal/jobs"
)

var work = jobs.Work{Kind: jobs.KindCompress, Size: 8_000_000}

// server answers after delay with status and body, counting requests.
func server(t *testing.T, delay time.Duration, status int, body string) (*httptest.Server, *atomic.Int32) {
	var n atomic.Int32
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n.Add(1)
		select {
		case <-time.After(delay):
		case <-r.Context().Done():
			return
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(s.Close)
	return s, &n
}

func client(url string) *Client {
	return New(url, 50*time.Millisecond, breaker.New(3, time.Minute, time.Now))
}

func TestAnAnswerBecomesAPrediction(t *testing.T) {
	s, _ := server(t, 0, 200, `{"run_s": 0.4, "p90_s": 1.2, "model": "m1", "features": {}}`)
	c := client(s.URL)
	p, err := c.Predict(context.Background(), "acme", work)
	if err != nil || p != (jobs.Prediction{RunS: 0.4, P90S: 1.2, Model: "m1"}) {
		t.Fatalf("got %+v, %v", p, err)
	}
	if n := testutil.ToFloat64(c.calls.WithLabelValues("ok")); n != 1 {
		t.Fatalf("ok calls %v", n)
	}
}

// A slow predictor costs each request at most the timeout.
func TestASlowPredictorIsGivenUpOn(t *testing.T) {
	s, _ := server(t, time.Second, 200, `{"run_s": 1, "p90_s": 2, "model": "m1"}`)
	c := client(s.URL)
	start := time.Now()
	_, err := c.Predict(context.Background(), "acme", work)
	if !errors.Is(err, context.DeadlineExceeded) || time.Since(start) > 200*time.Millisecond {
		t.Fatalf("err %v after %v", err, time.Since(start))
	}
	if n := testutil.ToFloat64(c.calls.WithLabelValues("timeout")); n != 1 {
		t.Fatalf("timeouts %v", n)
	}
}

// After three failures in a row the breaker opens: the predictor isn't
// called at all, and the answer comes at once.
func TestADeadPredictorIsNotWaitedFor(t *testing.T) {
	s, calls := server(t, 0, 503, `{"error": "not caught up"}`)
	c := client(s.URL)
	for range 5 {
		_, _ = c.Predict(context.Background(), "acme", work)
	}
	if calls.Load() != 3 {
		t.Fatalf("predictor called %d times, want 3", calls.Load())
	}
	if n := testutil.ToFloat64(c.calls.WithLabelValues("open")); n != 2 {
		t.Fatalf("refused by the open breaker: %v, want 2", n)
	}
}

func TestNonsenseIsRefused(t *testing.T) {
	for _, body := range []string{`{"run_s": -1, "p90_s": 1}`, `{"run_s": 2, "p90_s": 1}`, `not json`} {
		s, _ := server(t, 0, 200, body)
		if _, err := client(s.URL).Predict(context.Background(), "acme", work); err == nil {
			t.Fatalf("%s accepted", body)
		}
	}
}
~~~

Storage. Create `internal/pgstore/migrations/0014_prediction.sql`:

<!-- file: internal/pgstore/migrations/0014_prediction.sql -->
~~~sql
-- +goose Up
-- The run time predicted when a job was created (Phase 7, step 8), and the
-- model that predicted it. NULL: no prediction (a sleep, or the predictor
-- didn't answer in time). Nullable columns with no default: instant.
ALTER TABLE jobs
    ADD COLUMN predicted_run_s DOUBLE PRECISION,
    ADD COLUMN predicted_p90_s DOUBLE PRECISION,
    ADD COLUMN prediction_model TEXT;

-- +goose Down
ALTER TABLE jobs
    DROP COLUMN prediction_model,
    DROP COLUMN predicted_p90_s,
    DROP COLUMN predicted_run_s;
~~~

In `internal/pgstore/pgstore.go`:

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
func (s *Store) Create(ctx context.Context, job jobs.Job) (jobs.Job, error) {
	err := s.inTenant(ctx, func(owner tenant.ID, tx pgx.Tx) error {
~~~

to:

~~~go
func (s *Store) Create(ctx context.Context, job jobs.Job) (jobs.Job, error) {
	runS, p90S, model := predictionColumns(job.Prediction)
	err := s.inTenant(ctx, func(owner tenant.ID, tx pgx.Tx) error {
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
			INSERT INTO jobs (tenant, description, kind, size, duration_ms, state, failure_reason, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
~~~

to:

~~~go
			INSERT INTO jobs (tenant, description, kind, size, duration_ms, state, failure_reason, created_at, updated_at,
			                  predicted_run_s, predicted_p90_s, prediction_model)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
			owner, job.Description, job.Kind, job.Size, job.Duration.Milliseconds(), job.State, job.FailureReason, job.CreatedAt, job.UpdatedAt,
		).Scan(&job.ID, &job.CreatedAt, &job.UpdatedAt)
~~~

to:

~~~go
			owner, job.Description, job.Kind, job.Size, job.Duration.Milliseconds(), job.State, job.FailureReason, job.CreatedAt, job.UpdatedAt,
			runS, p90S, model,
		).Scan(&job.ID, &job.CreatedAt, &job.UpdatedAt)
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
			       created_at, updated_at, started_at, finished_at
~~~

to:

~~~go
			       created_at, updated_at, started_at, finished_at,
			       predicted_run_s, predicted_p90_s, prediction_model
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go
	var started, finished *time.Time
	err := row.Scan(&job.ID, &job.Tenant, &job.Description, &job.Kind, &job.Size, &durationMS, &job.State,
		&job.FailureReason, &job.CreatedAt, &job.UpdatedAt, &started, &finished)
~~~

to:

~~~go
	var started, finished *time.Time
	var runS, p90S *float64
	var model *string
	err := row.Scan(&job.ID, &job.Tenant, &job.Description, &job.Kind, &job.Size, &durationMS, &job.State,
		&job.FailureReason, &job.CreatedAt, &job.UpdatedAt, &started, &finished, &runS, &p90S, &model)
	if runS != nil && p90S != nil && model != nil {
		job.Prediction = &jobs.Prediction{RunS: *runS, P90S: *p90S, Model: *model}
	}
~~~

Change:

<!-- edit: internal/pgstore/pgstore.go -->
~~~go

// orNull stores Go's zero time ("not yet", "unknown") as NULL. Stored as a
~~~

to:

~~~go

// predictionColumns is a prediction as its three columns' values: all
// NULL when there's none.
func predictionColumns(p *jobs.Prediction) (runS, p90S *float64, model *string) {
	if p == nil {
		return nil, nil, nil
	}
	return &p.RunS, &p.P90S, &p.Model
}

// orNull stores Go's zero time ("not yet", "unknown") as NULL. Stored as a
~~~


In `internal/pgstore/pgstore_test.go`:

Change:

<!-- edit: internal/pgstore/pgstore_test.go -->
~~~go
		t.Fatalf("run time in SQL = %v, %v; want NULL: the start is unknown", runTime, err)
	}
~~~

to:

~~~go
		t.Fatalf("run time in SQL = %v, %v; want NULL: the start is unknown", runTime, err)
	}
}

// A prediction is stored with its job and read back; no prediction stays
// none (NULL), not a prediction of zero seconds.
func TestPredictionIsKept(t *testing.T) {
	store := New(pgtest.As(t, pgtest.Pool(t, Migrate), "runway_api"))
	for _, want := range []*jobs.Prediction{{RunS: 0.42, P90S: 1.5, Model: "runtime-1"}, nil} {
		job, _ := jobs.New("pack", jobs.Work{Kind: jobs.KindCompress, Size: 100}, t0)
		job.Prediction = want
		job, err := store.Create(acme, job)
		if err != nil {
			t.Fatal(err)
		}
		got, err := store.Get(acme, job.ID)
		if err != nil || (want == nil) != (got.Prediction == nil) || (want != nil && *got.Prediction != *want) {
			t.Fatalf("stored %+v, read %+v, %v", want, got.Prediction, err)
		}
	}
~~~


The HTTP API shows it as an object, absent when there's none. In `internal/httpapi/handler.go`:

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
	ID            jobs.ID    `json:"id"`
	State         string     `json:"state"`
	Description   string     `json:"description"`
	Kind          string     `json:"kind"`
	Size          int64      `json:"size,omitempty"`
	DurationMS    int64      `json:"duration_ms"`
	FailureReason string     `json:"failure_reason,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
	UpdatedAt     time.Time  `json:"updated_at"`
	StartedAt     *time.Time `json:"started_at,omitempty"`
	FinishedAt    *time.Time `json:"finished_at,omitempty"`
~~~

to:

~~~go
	ID            jobs.ID     `json:"id"`
	State         string      `json:"state"`
	Description   string      `json:"description"`
	Kind          string      `json:"kind"`
	Size          int64       `json:"size,omitempty"`
	DurationMS    int64       `json:"duration_ms"`
	FailureReason string      `json:"failure_reason,omitempty"`
	CreatedAt     time.Time   `json:"created_at"`
	UpdatedAt     time.Time   `json:"updated_at"`
	StartedAt     *time.Time  `json:"started_at,omitempty"`
	FinishedAt    *time.Time  `json:"finished_at,omitempty"`
	Prediction    *prediction `json:"prediction,omitempty"`
}

// prediction is how long the job was expected to run, when it was created
// (Phase 7, step 8). Absent when there was no prediction.
type prediction struct {
	RunS  float64 `json:"run_s"`
	P90S  float64 `json:"p90_s"`
	Model string  `json:"model"`
~~~

Change:

<!-- edit: internal/httpapi/handler.go -->
~~~go
		FinishedAt:    timeOrNil(job.FinishedAt),
	}
}

~~~

to:

~~~go
		FinishedAt:    timeOrNil(job.FinishedAt),
		Prediction:    predictionOrNil(job.Prediction),
	}
}

func predictionOrNil(p *jobs.Prediction) *prediction {
	if p == nil {
		return nil
	}
	return &prediction{RunS: p.RunS, P90S: p.P90S, Model: p.Model}
}

~~~


In `internal/httpapi/handler_test.go`:

Change:

<!-- edit: internal/httpapi/handler_test.go -->
~~~go
	if job := decode(t, created); job.Kind != "compress" || job.Size != 1<<20 || job.DurationMS != 0 {
		t.Fatalf("created = %+v", job)
	}
}
~~~

to:

~~~go
	if job := decode(t, created); job.Kind != "compress" || job.Size != 1<<20 || job.DurationMS != 0 {
		t.Fatalf("created = %+v", job)
	}
}

type fixedPredictor struct{}

func (fixedPredictor) Predict(context.Context, tenant.ID, jobs.Work) (jobs.Prediction, error) {
	return jobs.Prediction{RunS: 0.4, P90S: 1.2, Model: "m1"}, nil
}

// Step 8: a prediction is shown with the job; a job without one (a sleep)
// has no "prediction" at all, not one of zero seconds.
func TestPredictionIsShown(t *testing.T) {
	h := NewHandler(jobs.NewService(memstore.New(), jobs.WithPredictor(fixedPredictor{})))
	created := do(t, h, http.MethodPost, "/jobs", `{"description":"pack","kind":"compress","size":1048576}`)
	if p := decode(t, created).Prediction; p == nil || *p != (prediction{RunS: 0.4, P90S: 1.2, Model: "m1"}) {
		t.Fatalf("prediction %+v in %s", p, created.Body)
	}
	nap := do(t, h, http.MethodPost, "/jobs", `{"description":"nap","duration_ms":50}`)
	if strings.Contains(nap.Body.String(), "prediction") {
		t.Fatalf("a sleep shows a prediction: %s", nap.Body)
	}
}
~~~


The gRPC API too: a message field, because a message, unlike a number, can be absent. In `proto/runway/jobs/v1/jobs.proto`:

Change:

<!-- edit: proto/runway/jobs/v1/jobs.proto -->
~~~
  int64 finished_at_unix_ms = 11;
}
~~~

to:

~~~
  int64 finished_at_unix_ms = 11;
  // Step 8: the run time predicted at creation. Unset when there was none:
  // a message field, unlike a number, can say "absent".
  Prediction prediction = 12;
}
~~~

Add this at the end of the file:

<!-- append: proto/runway/jobs/v1/jobs.proto -->
~~~
message Prediction {
  double run_s = 1;
  double p90_s = 2;
  string model = 3;
}
~~~


<!-- run: PATH=$PWD/bin:$PATH protoc --go_out=. --go_opt=module=runway --go-grpc_out=. --go-grpc_opt=module=runway proto/runway/jobs/v1/jobs.proto -->

In `internal/grpcapi/server.go`:

Change:

<!-- edit: internal/grpcapi/server.go -->
~~~go
		FinishedAtUnixMs: unixMilliOrZero(job.FinishedAt),
	}
}

~~~

to:

~~~go
		FinishedAtUnixMs: unixMilliOrZero(job.FinishedAt),
		Prediction:       predictionToProto(job.Prediction),
	}
}

func predictionToProto(p *jobs.Prediction) *jobsv1.Prediction {
	if p == nil {
		return nil
	}
	return &jobsv1.Prediction{RunS: p.RunS, P90S: p.P90S, Model: p.Model}
}

~~~


And the events carry it, so the pipeline (and step 11) can compare predictions with what happened. Step 3's contract says an optional property needs no new version: readers ignore what they don't know. In `internal/messages/messages.go`:

Change:

<!-- edit: internal/messages/messages.go -->
~~~go
	FinishedAt time.Time `json:"finished_at,omitzero"`
}
~~~

to:

~~~go
	FinishedAt time.Time `json:"finished_at,omitzero"`
	// Step 8: the prediction made at creation, if any. Optional properties,
	// so still version 2: readers that don't know them ignore them.
	PredictedRunS   float64 `json:"predicted_run_s,omitzero"`
	PredictedP90S   float64 `json:"predicted_p90_s,omitzero"`
	PredictionModel string  `json:"prediction_model,omitempty"`
}
~~~


In `internal/eventing/eventing.go`:

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
		}
		if o.StreamEvents {
~~~

to:

~~~go
		}
		if p := job.Prediction; p != nil {
			changed.PredictedRunS, changed.PredictedP90S, changed.PredictionModel = p.RunS, p.P90S, p.Model
		}
		if o.StreamEvents {
~~~


The contract test's job gets a prediction, so the example shows the new properties. In `internal/eventing/eventing_test.go`:

Change:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
	job.ID, job.Tenant = 42, "acme"
	_ = job.Start(t0.Add(2*time.Second), t0.Add(1500*time.Millisecond))
~~~

to:

~~~go
	job.ID, job.Tenant = 42, "acme"
	job.Prediction = &jobs.Prediction{RunS: 2.5, P90S: 6.25, Model: "runtime-20261017-1053-73dba17d"}
	_ = job.Start(t0.Add(2*time.Second), t0.Add(1500*time.Millisecond))
~~~


And the schema documents them, as optional. In `contracts/job_changed.v2.schema.json`:

Change:

<!-- edit: contracts/job_changed.v2.schema.json -->
~~~json
        "finished_at": { "type": "string", "format": "date-time", "description": "When the worker stopped; absent until then." }
~~~

to:

~~~json
        "finished_at": { "type": "string", "format": "date-time", "description": "When the worker stopped; absent until then." },
        "predicted_run_s": { "type": "number", "exclusiveMinimum": 0, "description": "Added in step 8, optional: the run time predicted at creation." },
        "predicted_p90_s": { "type": "number", "exclusiveMinimum": 0, "description": "Added in step 8, optional: nine jobs in ten should finish within this." },
        "prediction_model": { "type": "string", "description": "Added in step 8, optional: the model that predicted." }
~~~


The contract test now fails, as it should: the event changed. This is the deliberate, compatible change step 3 described, so rewrite the example, and the Python side checks it against the schema:

<!-- run: go test ./internal/eventing -run Contract -update -->

~~~bash
go test ./internal/eventing -run Contract -update
cd lab && uv run pytest -q tests/test_contract.py; cd ..
~~~

Finally, the wiring: `PREDICTOR_URL` and `PREDICT_TIMEOUT`, the client with its own breaker, and the cache's key goes to `v4` because cached jobs now carry a prediction. In `cmd/api/main.go`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	"runway/internal/pki"
	"runway/internal/rabbit"
~~~

to:

~~~go
	"runway/internal/pki"
	"runway/internal/predict"
	"runway/internal/rabbit"
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	StatsMinTenants int
}
~~~

to:

~~~go
	StatsMinTenants int
	// Phase 7, step 8: ask PredictorURL how long each new job will run,
	// waiting at most PredictTimeout. Empty: no predictions.
	PredictorURL   string
	PredictTimeout time.Duration
}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	cfg.StatsEpsilon = 1
	if v := getenv("STATS_EPSILON"); v == "off" {
~~~

to:

~~~go
	cfg.StatsEpsilon = 1
	cfg.PredictorURL = getenv("PREDICTOR_URL")
	if cfg.PredictTimeout, err = envconfig.Duration(getenv, "PREDICT_TIMEOUT", 100*time.Millisecond); err != nil {
		return config{}, err
	}
	if v := getenv("STATS_EPSILON"); v == "off" {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		Prefix:      "runway:job:v3:", // v3: work and the worker's times (Phase 7); v2: the tenant (Phase 6)
~~~

to:

~~~go
		Prefix:      "runway:job:v4:", // v4: the prediction (step 8); v3: work and the worker's times; v2: the tenant (Phase 6)
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	}
	var service *jobs.Service
~~~

to:

~~~go
	}
	var serviceOptions []jobs.Option
	if cfg.PredictorURL != "" {
		// Its own breaker: a failing predictor mustn't open the database's.
		predictBreaker := breaker.New(cfg.BreakerThreshold, cfg.BreakerCooldown, time.Now)
		predictor := predict.New(cfg.PredictorURL, cfg.PredictTimeout, predictBreaker)
		metrics.MustRegister(predictor.Collectors()...)
		metrics.MustRegister(prometheus.NewGaugeFunc(prometheus.GaugeOpts{
			Name: "predictor_breaker_state",
			Help: "The predictor's circuit breaker: 0 closed, 1 open, 2 half-open.",
		}, func() float64 { return float64(predictBreaker.State()) }))
		serviceOptions = append(serviceOptions, jobs.WithPredictor(predictor))
	}
	var service *jobs.Service
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		service = jobs.NewService(memstore.New(), jobs.WithDispatcher(dispatcher))
~~~

to:

~~~go
		service = jobs.NewService(memstore.New(), append(serviceOptions, jobs.WithDispatcher(dispatcher))...)
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		service = jobs.NewService(withCache(cfg, redisClient, guarded, metrics))
~~~

to:

~~~go
		service = jobs.NewService(withCache(cfg, redisClient, guarded, metrics), serviceOptions...)
~~~


<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

### The predictor in the cluster

Its image is lab's project and the contract. The top-level `.dockerignore` keeps `lab/` out of the Go image, so this image gets its own: Docker uses a file named after the Dockerfile, beside it, instead of the top-level one. Create `deploy/predictor/Dockerfile`:

<!-- file: deploy/predictor/Dockerfile -->
~~~dockerfile
# The prediction service (Phase 7, step 8): lab's code, served by uvicorn.
# Build from the top of the practice, so contracts/ is in reach:
#   docker build -f deploy/predictor/Dockerfile -t runway-predictor:dev .
# Dockerfile.dockerignore beside this file replaces the top-level
# .dockerignore for this build, which keeps lab/ out of the Go image.
FROM python:3.12-slim AS build
COPY --from=ghcr.io/astral-sh/uv:0.12.7 /uv /bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
WORKDIR /app/lab
# Dependencies first, as their own layer: they change far less often than
# the code, so most rebuilds reuse this one.
COPY lab/pyproject.toml lab/uv.lock lab/.python-version ./
RUN uv sync --frozen --no-dev --no-install-project
COPY lab/src ./src
RUN uv sync --frozen --no-dev

FROM python:3.12-slim
COPY --from=build /app/lab /app/lab
COPY contracts /app/contracts
# The same numeric user as the Go image, so the chart's fsGroup works.
USER 65532:65532
ENV PATH=/app/lab/.venv/bin:$PATH PYTHONUNBUFFERED=1
ENTRYPOINT ["lab", "serve", "--contract", "/app/contracts/job_changed.v2.schema.json"]
~~~

Create `deploy/predictor/Dockerfile.dockerignore`:

<!-- file: deploy/predictor/Dockerfile.dockerignore -->
~~~text
# Only what the predictor's image needs: lab's project and the contract.
*
!lab/pyproject.toml
!lab/uv.lock
!lab/.python-version
!lab/src
!contracts
**/__pycache__
~~~

Exported models are made from data, so they stay out of Git and the Go image. In `.gitignore`:

Add this at the end of the file:

<!-- append: .gitignore -->
~~~text
# Exported models (Phase 7, step 8): made by lab export, from data.
models/
~~~


In `.dockerignore`:

Change:

<!-- edit: .dockerignore -->
~~~text
data-*
bin
~~~

to:

~~~text
data-*
models
bin
~~~


The chart. In `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml
  brokers: kafka:9092

~~~

to:

~~~yaml
  brokers: kafka:9092

# The run-time predictor (Phase 7, step 8): lab serve, in its own image
# (deploy/predictor/Dockerfile), following the job events on kafka.brokers.
# The API asks it, through the sidecars, how long each new job will run, and
# creates the job without a prediction if no answer comes within timeout.
# The model is the ConfigMap modelConfigMap, made from lab export's file.
# Needs tls.enabled and redisProxy.enabled: the API's sidecar carries the
# calls, on localPort.
predictor:
  enabled: true
  image: { repository: runway-predictor, tag: dev }
  modelConfigMap: predictor-model
  timeout: 100ms
  localPort: 17100
  # A whole CPU requested, so it gets its share even when jobs keep every
  # core busy; and no CPU limit, so a burst isn't throttled (step 8 measured
  # both: at 100m with a limit of 1, nearly half the predictions failed).
  resources:
    requests: { cpu: "1", memory: 256Mi }
    limits: { memory: 512Mi }

~~~


The CPU settings, and the thread counts in the template below, come from measurements later in this step; read them again after the "busy hour" section. Create `deploy/helm/runway/templates/predictor.yaml`:

<!-- file: deploy/helm/runway/templates/predictor.yaml -->
~~~yaml
{{- if .Values.predictor.enabled }}
{{- if not (and .Values.tls.enabled .Values.redisProxy.enabled) }}
{{- fail "predictor.enabled needs tls.enabled and redisProxy.enabled: the API's sidecar carries its calls" }}
{{- end }}
# The run-time predictor (Phase 7, step 8). lab serve answers on 8000 inside
# the Pod; its sidecar takes mutual TLS on 8443 from the API alone, so
# predictions travel encrypted, and nothing else can ask. Metrics have a
# port of their own, 9100, for Prometheus.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: predictor
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  replicas: 1
  selector:
    matchLabels: { app: predictor }
  template:
    metadata:
      labels: { app: predictor }
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9100"
    spec:
      securityContext:
        runAsNonRoot: true
        fsGroup: 65532 # so the image's user can read the certificate and the model
      automountServiceAccountToken: false
      initContainers:
        - name: tlsproxy
          image: {{ include "runway.image" (list $ .Values.image.tag) }}
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          restartPolicy: Always
          command: ["/usr/local/bin/tlsproxy", "-tls", "/etc/runway/tls",
                    "-in", "0.0.0.0:8443,127.0.0.1:8000,spiffe://runway/api"]
          ports:
            - { name: tls, containerPort: 8443 }
            - { name: proxy-admin, containerPort: 9901 }
          startupProbe:
            httpGet: { path: /ready, port: proxy-admin }
            periodSeconds: 1
            failureThreshold: 30
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits: { memory: 64Mi }
          {{- include "runway.containerSecurity" . | nindent 10 }}
          volumeMounts:
            {{- include "runway.tlsMount" . | nindent 12 }}
      containers:
        - name: predictor
          image: "{{ .Values.predictor.image.repository }}:{{ .Values.predictor.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          args: ["--model", "/models/runtime.pkl", "--brokers", {{ .Values.kafka.brokers | quote }},
                 "--host", "0.0.0.0", "--port", "8000", "--metrics-port", "9100"]
          env:
            # One thread each for OpenMP (the trees) and OpenBLAS (NumPy):
            # left alone, each starts one per CPU of the node, sixteen here,
            # in a container allowed one, and the kernel throttles them all.
            - { name: OMP_NUM_THREADS, value: "1" }
            - { name: OPENBLAS_NUM_THREADS, value: "1" }
          ports:
            - { name: http, containerPort: 8000 }
            - { name: metrics, containerPort: 9100 }
          # Ready only once it has replayed the job events: before that,
          # its counts of running and queued jobs are wrong.
          readinessProbe:
            httpGet: { path: /ready, port: http }
            periodSeconds: 2
          livenessProbe:
            httpGet: { path: /health, port: http }
            periodSeconds: 10
          resources:
            {{- toYaml .Values.predictor.resources | nindent 12 }}
          {{- include "runway.containerSecurity" . | nindent 10 }}
          volumeMounts:
            - { name: model, mountPath: /models, readOnly: true }
      volumes:
        {{- include "runway.tlsVolume" "predictor" | nindent 8 }}
        - name: model
          configMap: { name: {{ .Values.predictor.modelConfigMap }} }
---
apiVersion: v1
kind: Service
metadata:
  name: predictor
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  selector: { app: predictor }
  ports:
    - { name: tls, port: 8443, targetPort: tls }
{{- end }}
~~~

The predictor listens on 8000 inside its Pod. Its sidecar takes mutual TLS on 8443 and admits `spiffe://runway/api` alone, so predictions travel encrypted and nothing else can ask. Prometheus gets a port of its own, 9100, so it can be let in to the metrics without being let in to `/predict`. The API's sidecar gets a route to it, and the API its address, in `deploy/helm/runway/templates/_helpers.tpl`:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
        {{- end }}
      ports:
~~~

to:

~~~yaml
        {{- end }}
        {{- if $root.Values.predictor.enabled }}
        - -out # the predictor (Phase 7, step 8)
        - {{ printf "127.0.0.1:%d,predictor:8443,spiffe://runway/predictor" (int $root.Values.predictor.localPort) }}
        {{- end }}
      ports:
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
        - { name: KAFKA_BROKERS, value: {{ . | quote }} }
        {{- end }}
~~~

to:

~~~yaml
        - { name: KAFKA_BROKERS, value: {{ . | quote }} }
        {{- end }}
        {{- if $root.Values.predictor.enabled }}
        - { name: PREDICTOR_URL, value: {{ printf "http://127.0.0.1:%d" (int $root.Values.predictor.localPort) | quote }} }
        - { name: PREDICT_TIMEOUT, value: {{ $root.Values.predictor.timeout | quote }} }
        {{- end }}
~~~


And the network policies: the API may reach the predictor's sidecar, the predictor may reach Kafka and nothing else. In `deploy/helm/runway/templates/networkpolicy.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/networkpolicy.yaml -->
~~~yaml
    {{- end }}
    {{- include "runway.toCollector" . | nindent 4 }}
---
apiVersion: networking.k8s.io/v1
~~~

to:

~~~yaml
    {{- end }}
    {{- if .Values.predictor.enabled }}
    - to: [{ podSelector: { matchLabels: { app: predictor } } }] # through the sidecars
      ports: [{ port: 8443 }]
    {{- end }}
    {{- include "runway.toCollector" . | nindent 4 }}
{{- if .Values.predictor.enabled }}
---
# The predictor: the API, through its sidecar, and Prometheus, to the
# metrics port; out, only to Kafka. Its plain HTTP port is for the Pod's own
# sidecar and the kubelet's probes, which come from the node.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: predictor
  labels:
    {{- include "runway.labels" . | nindent 4 }}
spec:
  podSelector: { matchLabels: { app: predictor } }
  policyTypes: [Ingress, Egress]
  ingress:
    - from: [{ podSelector: { matchLabels: { app: api } } }]
      ports: [{ port: 8443 }]
    {{- include "runway.fromPrometheus" 9100 | nindent 4 }}
  egress:
    - to: [{ podSelector: { matchLabels: { app: kafka } } }]
      ports: [{ port: 9092 }]
{{- end }}
---
apiVersion: networking.k8s.io/v1
~~~


<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway | grep -q 'predictor:8443,spiffe://runway/predictor' -->

Kafka must let the predictor in. In `deploy/k8s/kafka.yaml`:

Change:

<!-- edit: deploy/k8s/kafka.yaml -->
~~~yaml
# Only the API writes job events. A port-forward arrives from the node, so
~~~

to:

~~~yaml
# Only the API writes job events, and only the predictor (step 8) reads
# them in the cluster. A port-forward arrives from the node, so
~~~

Change:

<!-- edit: deploy/k8s/kafka.yaml -->
~~~yaml
        - podSelector: { matchLabels: { app: api } }
      ports: [{ port: 9092 }]
~~~

to:

~~~yaml
        - podSelector: { matchLabels: { app: api } }
        - podSelector: { matchLabels: { app: predictor } }
      ports: [{ port: 9092 }]
~~~


And the predictor needs a certificate, with its own identity. In `deploy/certs.sh`:

Change:

<!-- edit: deploy/certs.sh -->
~~~bash
  [migrate]=""
)
for service in api gateway idp metad redis bao notifier migrate; do
~~~

to:

~~~bash
  [migrate]=""
  [predictor]="" # its sidecar's; only the API calls it (Phase 7, step 8)
)
for service in api gateway idp metad redis bao notifier migrate predictor; do
~~~


### Run it: deploy

Rebuild the dataset if you haven't since the parity fix, export the model, and make it a ConfigMap. A ConfigMap holds up to 1 MiB, and a binary file goes in as `binaryData`. The model's version then changes without the image's:

~~~bash
uv run --project lab lab dataset
uv run --project lab lab export results/dataset.parquet
kubectl -n runway create configmap predictor-model --from-file=runtime.pkl=models/runtime.pkl \
  --dry-run=client -o yaml | kubectl apply --server-side --field-manager=lab -f -
~~~

~~~text
runtime-trees-20261017-2316-c0e7da40: 29178 jobs, up to 2026-10-17T23:16:39Z
wrote models/runtime.pkl (379 kB)
~~~

(29,178 jobs here, because I ran workloads while building this step; yours will be the jobs in your dataset.)

Build the predictor's image and load it, issue the certificates, let the predictor into Kafka, and deploy as before. The migration adds the columns; the event's change is optional, so no reader has to go first:

~~~bash
docker build -f deploy/predictor/Dockerfile -t runway-predictor:dev .
kind load docker-image runway-predictor:dev --name runway
deploy/certs.sh ~/.runway/ca
kubectl apply -f deploy/k8s/kafka.yaml
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait
kubectl -n runway rollout restart deploy/api deploy/idp deploy/gateway sts/metad
kubectl -n runway rollout status deploy/api && kubectl -n runway rollout status deploy/predictor
kubectl -n runway logs deploy/predictor -c predictor | grep "caught up"
~~~

The image is 1.1 GB, mostly lab's dependencies. 260 MB of them (pyarrow, DuckDB, Matplotlib) are for code serving never runs, reached only because `online.py` imports `dataset.py`. Splitting them out is an exercise. The first time I deployed, the predictor crashed at once:

~~~text
OSError: Matplotlib requires access to a writable cache directory, but there was an issue with the default path (/.config/matplotlib), and a temporary directory could not be created; set the MPLCONFIGDIR environment variable to a writable directory
~~~

The chart gives every container a read-only root filesystem (Phase 6), and the CLI imported Matplotlib at the top for commands the service never runs. The fix was the lazy imports above, not a writable directory: the service has no business loading a plotting library.

### Run it: the first predictions

Restart the port-forwards (the idp restarted), get tokens, and create one job of each kind:

~~~bash
for body in '{"description":"pack","kind":"compress","size":8000000}' \
            '{"description":"sum","kind":"checksum","size":100000000}' \
            '{"description":"nap","duration_ms":200}'; do
  curl -s -X POST localhost:8000/jobs -H "Authorization: Bearer $ACME_TOKEN" -H 'Content-Type: application/json' -d "$body"; echo
done
~~~

~~~text
{"id":36759,"state":"queued","description":"pack","kind":"compress","size":8000000,"duration_ms":0,"created_at":"2026-10-17T23:35:42.526029Z","updated_at":"2026-10-17T23:35:42.526029Z"}

{"id":36760,"state":"queued","description":"sum","kind":"checksum","size":100000000,"duration_ms":0,"created_at":"2026-10-17T23:35:42.606273Z","updated_at":"2026-10-17T23:35:42.606273Z"}

{"id":36761,"state":"queued","description":"nap","kind":"sleep","duration_ms":200,"created_at":"2026-10-17T23:35:42.650244Z","updated_at":"2026-10-17T23:35:42.650244Z"}

~~~

No predictions, and that's right twice over. The sleep isn't predicted. The other two missed the deadline. They were the first calls since the predictor started: most likely, setting up new mutual TLS connections through two sidecars, and running the model's code for the first time, took longer than 100 ms. The jobs were created anyway; the next ones, on warm connections, get their predictions. Every request path has a first call, and a deadline sized for warm calls will miss it.

### Run it: a busy hour

Now a workload at twice step 2's rate, about 2,350 jobs in three minutes, while watching what the API's calls to the predictor did. Prometheus has the counts. Port-forward it (`kubectl -n observability port-forward svc/prometheus 9091:9090 &`), note the counters, run, and compare:

~~~bash
prom() { curl -s localhost:9091/api/v1/query --data-urlencode "query=$1" | jq -c '[.data.result[] | [.metric.outcome // "", .value[1]]]'; }
prom 'sum by (outcome) (predictions_total)'          # before
uv run --project kload kload mix workloads/three-tenants.toml --seed 21 --load 2 --out results/s08-trees.jsonl
prom 'sum by (outcome) (predictions_total)'          # after: the difference is this run
prom 'histogram_quantile(0.5, sum by (le) (rate(predict_seconds_bucket[5m])))'
prom 'histogram_quantile(0.99, sum by (le) (rate(predict_seconds_bucket[5m])))'
~~~

The differences, summarised (with the API's own latency for creating a job, `http_request_duration_seconds` for `POST /jobs`):

~~~text
2347 jobs over 180 s from 3 tenants
submitted: 2347 accepted, 0 refused
states: {'completed': 2347}
wrote results/s08-trees.jsonl (settings: results/s08-trees.settings.json)
~~~

~~~text
API calls to the predictor, by outcome: error 2 (0%), ok 1409 (60%), open 712 (30%), timeout 226 (10%)
   API, whole call: p50 39.5 ms, p90 142.1 ms, p99 239.2 ms
 predictor, inside: p50 27.7 ms, p90 95.3 ms, p99 567.8 ms
        POST /jobs: p50 38.7 ms, p90 126.0 ms, p99 237.6 ms
~~~

Every job was created, which is the fallback working. But only 60% got a prediction. 10% of the calls timed out, and after a few timeouts in a row each API Pod's breaker opened and skipped the next calls for a while: 30%. Inside the predictor, the median prediction took 28 ms and the slowest 1% over half a second, where step 7 measured 12 ms.

One caution reading these: Prometheus estimates a quantile from histogram buckets, assuming values spread evenly inside a bucket. The API's buckets jump from 100 ms to 250 ms, so a call cut off at the 100 ms deadline is reported as "somewhere up to 250 ms", and the p99s near 240 ms are those timeouts.

Where do 28 ms come from? Ask the service one call at a time, on a quiet system, from inside its Pod:

~~~bash
kubectl -n runway exec deploy/predictor -c predictor -- python -c "
import json, time, urllib.request
body = json.dumps({'tenant': 'acme', 'kind': 'compress', 'size': 8000000}).encode()
def call():
    r = urllib.request.Request('http://127.0.0.1:8000/predict', body, {'Content-Type': 'application/json'})
    return urllib.request.urlopen(r).read()
call(); ts = []
for _ in range(200):
    t = time.perf_counter(); call(); ts.append(time.perf_counter() - t)
ts.sort(); print(f'one at a time, idle: p50 {ts[100]*1000:.1f} ms, p90 {ts[180]*1000:.1f} ms, p99 {ts[198]*1000:.1f} ms')"
~~~

~~~text
one at a time, idle: p50 13.3 ms, p90 22.1 ms, p99 28.8 ms
~~~

And time the pieces of one prediction, with the model the service loaded:

~~~bash
kubectl -n runway exec deploy/predictor -c predictor -- python -c "
import time
from pathlib import Path
import numpy as np
from lab import export
from lab.model import frame
a = export.load(Path('/models/runtime.pkl'))
f = {'tenant': 'acme', 'kind': 'compress', 'size': 8000000, 'running_at_submit': 3,
     'queued_at_submit': 1, 'tenant_recent': 40, 'history_log_run': -1.5}
rows = {k: np.array([v]) for k, v in f.items()}
pipe = a['point'].fitted.regressor_
x = frame(rows, a['point'].features)
xt = pipe[0].transform(x)
for name, fn in [('trees, the whole call', lambda: a['point'].predict(rows)),
                 ('  building the DataFrame', lambda: frame(rows, a['point'].features)),
                 ('  encoding the categories', lambda: pipe[0].transform(x)),
                 ('  the trees themselves', lambda: pipe[1].predict(xt)),
                 ('power law (the bound)', lambda: a['bound'].predict(rows))]:
    fn(); t = time.perf_counter()
    for _ in range(200): fn()
    print(f'{name}: {(time.perf_counter() - t) / 200 * 1000:.2f} ms')"
~~~

~~~text
trees, the whole call: 7.94 ms
  building the DataFrame: 0.34 ms
  encoding the categories: 3.87 ms
  the trees themselves: 2.88 ms
power law (the bound): 0.04 ms
~~~

Eight milliseconds for the trees, half of it encoding two categories (scikit-learn's input checks on a one-row DataFrame), and 13 ms for a whole request when nothing else is running. The busy hour made it 28 ms at the median. During an earlier run of this workload, Prometheus showed the namespace using up to 7.4 CPUs on an 8-core laptop (`sum(rate(container_cpu_usage_seconds_total{namespace="runway"}[1m]))`): the workers, compressing and sorting, used all of it. Every kind "node" is a container on that one machine, so the predictor competed with the jobs themselves for a core, and its requests waited. Two settings in the chart help it compete fairly, and the next section shows what happens without them.

### Break it: a starved predictor

Two defaults hurt here. First, scikit-learn's trees use OpenMP, and NumPy uses OpenBLAS. Each starts one thread per CPU *of the node*: 16 here, inside a container allowed far less, so the kernel throttles them all (Phase 6, step 8). The template sets both to one thread. Second, a small CPU request with a CPU limit. Put those back, as a first version of the chart had them:

~~~bash
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait \
  --set predictor.resources.requests.cpu=100m --set predictor.resources.limits.cpu=1
~~~

The same workload, the same seed:

~~~text
API calls to the predictor, by outcome: ok 1143 (49%), open 988 (42%), timeout 216 (9%)
   API, whole call: p50 41.6 ms, p90 157.5 ms, p99 240.8 ms
 predictor, inside: p50 31.0 ms, p90 132.5 ms, p99 777.4 ms
        POST /jobs: p50 32.5 ms, p90 129.3 ms, p99 237.9 ms
~~~

49% served, against 60%, and the slowest 1% of predictions at 0.8 s. With 100m requested, the predictor's share of a contended CPU is a tenth of a core. With the limit, a burst of its threads is throttled even when the node has CPU to spare. (The container's `container_cpu_cfs_throttled_periods_total` counts the throttled periods; on an earlier run of this, 9% of them.) Put them back:

~~~bash
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait \
  --set predictor.resources.requests.cpu=1 --set predictor.resources.limits.cpu=null
~~~

Even fairly scheduled, though, the trees got 60%: they're simply too expensive to ask at this rate, on a machine this busy.

### Run it: the cheaper model

Step 7 measured a model that predicts in 0.05 ms, nearly as accurately: the hand-written network. Export it, swap it in, and run the same workload:

~~~bash
uv run --project lab lab export results/dataset.parquet --point numpy --out models/runtime-numpy.pkl
kubectl -n runway create configmap predictor-model --from-file=runtime.pkl=models/runtime-numpy.pkl \
  --dry-run=client -o yaml | kubectl apply --server-side --field-manager=lab -f -
kubectl -n runway rollout restart deploy/predictor && kubectl -n runway rollout status deploy/predictor
~~~

~~~text
runtime-numpy-20261017-2316-c0e7da40: 29178 jobs, up to 2026-10-17T23:16:39Z
wrote models/runtime-numpy.pkl (5 kB)
~~~

~~~text
API calls to the predictor, by outcome: ok 2343 (100%), timeout 4 (0%)
   API, whole call: p50 7.6 ms, p90 17.4 ms, p99 26.3 ms
 predictor, inside: p50 0.8 ms, p90 2.2 ms, p99 3.9 ms
        POST /jobs: p50 20.2 ms, p90 41.3 ms, p99 65.0 ms
~~~

Every call answered but four (most likely the first ones after the restart, on new connections), in under 4 ms inside the predictor, and job creation itself got faster: `POST /jobs` 20 ms at the median, 65 ms at the 99th percentile, against 39 and up to 240 with the trees. Step 7's comparison said the trees were about 1.5% more accurate (1.339 against 1.359). A model that answers 60% of the time is wrong, for the other 40%, by as much as having no model at all. The model to serve is the one that's accurate *and* answers, and only measuring it in place could show that. Keep the network.

### Run it: skew, and what it costs

Copy the run's events into the files, and keep the predictor's log, which has a line for every prediction with the features it used:

~~~bash
uv run --project lab lab pipeline
kubectl -n runway logs deploy/predictor -c predictor > results/predictor.log
~~~

After five minutes (the lateness window), rebuild the dataset, and compare the features the predictor served with the batch's, job by job:

~~~bash
uv run --project lab lab dataset
uv run --project lab lab skew results/predictor.log
~~~

~~~text
2347 predictions logged, 2346 matched to jobs
          feature  same_%  mean_online_minus_batch  max_abs_diff
-----------------  ------  -----------------------  ------------
running_at_submit  44.587                    0.006         4.000
 queued_at_submit  41.816                   -0.133         5.000
    tenant_recent  28.218                   -1.351         7.000
  history_log_run   0.000                   -0.016         0.019
~~~

The parity test proved the code agrees. This shows the *world* doesn't, quite. The counts match 42 to 45% of the time, and on average differ by almost nothing (+0.006 running, -0.13 queued), but by up to five. `tenant_recent` is lower online by 1.35 on average: the submissions of the last fraction of a second haven't reached the predictor yet. The outbox relay looks every 100 ms (Phase 3), then Kafka and the consumer add their part, and a tenant submitting eight jobs a second has about one in flight. History never matches exactly but is within 0.02; part of that is mine (a trial run from step 5 that's in Kafka but not in my files), and in your world it would match, until Kafka's seven-day retention drops events the files still have.

Does the skew matter? Score the live predictions (they're in the events now) against the same model on the batch's features, for the same jobs:

~~~bash
uv run --project lab python - <<'PY'
from pathlib import Path
import duckdb
import numpy as np
from lab import dataset, export, metrics

model = export.load(Path("models/runtime-numpy.pkl"))
d = dataset.load(Path("results/dataset.parquet"))
con = duckdb.connect()
live = dict(con.execute("""
    SELECT job_id, any_value(predicted_run_s) FROM read_parquet('data/events/**/*.parquet', union_by_name = true)
    WHERE prediction_model = ? GROUP BY 1""", [model["version"]]).fetchall())
mask = np.isin(d["job_id"], list(live))
rows = {k: v[mask] for k, v in d.items()}
y, served = rows["run_s"], np.array([live[j] for j in rows["job_id"]])
batch = model["point"].predict(rows)  # the same model, on the batch's features
print(f"{mask.sum()} jobs predicted live by {model['version']}")
print(f"live predictions (served features): typically off by {metrics.log_error(y, served):.3f}")
print(f"same model, batch features:         typically off by {metrics.log_error(y, batch):.3f}")
print(f"live / batch prediction: median {np.median(served / batch):.4f}; "
      f"99% within a factor {np.exp(np.quantile(np.abs(np.log(served / batch)), 0.99)):.3f}")
PY
~~~

~~~text
2342 jobs predicted live by runtime-numpy-20261017-2316-c0e7da40
live predictions (served features): typically off by 1.461
same model, batch features:         typically off by 1.434
live / batch prediction: median 1.0002; 99% within a factor 1.585
~~~

Live, typically off by 1.461; the same model, given the batch's features, 1.434. The skew costs about 2%: small, real, and now measured. A model evaluated only offline would have been reported 2% better than it is.

### Break it: the predictor goes away

Scale it to zero and run a workload:

~~~bash
kubectl -n runway scale deploy/predictor --replicas 0
uv run --project kload kload mix workloads/three-tenants.toml --seed 22 --out results/s08-down.jsonl
kubectl -n runway scale deploy/predictor --replicas 1
~~~

~~~text
1199 jobs over 180 s from 3 tenants
submitted: 1199 accepted, 0 refused
states: {'completed': 1199}
wrote results/s08-down.jsonl (settings: results/s08-down.settings.json)
~~~

~~~text
API calls to the predictor, by outcome: open 1134 (95%), timeout 65 (5%)
   API, whole call: p50 175.0 ms, p90 235.0 ms, p99 248.5 ms
 predictor, inside: p50 nan ms, p90 nan ms, p99 nan ms
        POST /jobs: p50 12.1 ms, p90 23.5 ms, p99 215.9 ms
~~~

Every job created and completed. 95% of the calls were never made: the breakers were open. The other 5% were the breakers' trials: five failures open each API Pod's breaker, then it tries once every 10 s (`BREAKER_THRESHOLD`, `BREAKER_COOLDOWN`), so three Pods over three minutes make about 3 × (5 + 18) = 69 calls, each cut off at the deadline. And job creation got *faster* at the median, 12 ms, because there was nothing to ask, with a tail of 100 ms timeouts. ("whole call p50 175 ms" is the bucket estimate again: every one of those calls ended at 100 ms.) That's what "an improvement, not a requirement" looks like: a dependency that can vanish without anyone but the dashboard noticing.

**Explain it:** why must the online and batch features be tested against each other, and what did the parity test find that step 5's leak test couldn't? Which clock may a feature use, and why? What is train/serve skew, how did you measure it, and what did it cost? Why does the predictor refuse to answer until it has caught up? Why a deadline, a breaker *and* a fallback, and what does each prevent? Why did the first predictions miss the deadline? Why did the trees answer 60% of the time and the network 100%, and why does that outweigh 1% of accuracy? What did the CPU request and limit change, and why do thread pools need setting in containers? Why are p99s near 240 ms really 100 ms?

**Read.** D. Sculley and others, *Hidden Technical Debt in Machine Learning Systems* (NeurIPS 2015), especially training/serving skew and the cost of glue. Google's *Rules of Machine Learning* (Martin Zinkevich), rules 29 to 37, on training/serving skew. The Prometheus documentation on *Histograms and summaries*, for why quantiles from buckets are estimates. And Michael Nygard, *Release It!* (2nd edition), the chapters on timeouts, circuit breakers and fail fast.

---
## Step 9: Using the predictions

**The problem.** Every job has a predicted run time now, and nothing uses it. The classic use is scheduling. A one-second job that queues behind a twenty-second one waits twenty times its own length, while the twenty-second job that queues behind the one-second one hardly notices. Serving short jobs first (**shortest job first**, SJF) minimises the mean wait, and with predictions instead of known run times it can be approximated. This step does that in two ways, predicts the result by simulation before trying it, and then measures it on the cluster: mean wait, the tails, and the cost to long jobs.

**New ideas.**

- **Shortest job first** minimises the mean wait when run times are known, and it's the reason supermarkets have express lanes. With predictions it becomes "predicted shortest first", and a wrong prediction puts a long job in the short class.
- **Work-conserving or not.** A scheduler is work-conserving if no server idles while work waits. **Priority** (one queue, short jobs delivered first to every consumer) is. **Reserved lanes** (a queue of their own for short jobs, served by consumers kept for it) aren't: when the short lane is empty its consumers idle, even with long jobs waiting.
- **Plan by work, not by count.** Two thirds of the jobs can be a fifth of the work. A lane's share of the capacity must match its share of the *work*.
- **Starvation.** Strict priority serves long jobs only when no short job waits. Under a steady flow of short jobs, long jobs can wait forever. Measure the cost to the class you're not helping.
- **Simulate, then measure.** A discrete-event simulation replays recorded arrivals and run times through each policy in a second: a prediction to check, written down before the experiment (step 1's pre-registration). Where the measurement disagrees, the simulation's assumptions are what to examine.
- **Capacity is what's actually scarce.** Four consumers sharing one CPU are four slots but one core. A model that counts slots overstates capacity when the work is CPU-bound.
- **An ETA is a promise about wait plus run.** A p90 of the run time is only a promise about the run. Whether it holds as a finish time depends on the queue.

### Two ways to put short jobs first

Both start in the outbox, where a new job's RunJob command is written. A job is short if it has a prediction and the job's *own size* is predicted within `ShortMax`: how long it would take with nothing else running, which the predictor now returns as `alone_s` (why that and not the expected run time is this step's main finding, in "Break it" below). With no prediction (the predictor didn't answer) it's long, the safe default. Then either the command goes to a queue of its own (`Reserved`), or it goes to the one queue at a higher priority. In `internal/messages/messages.go`, the short lane's queue and a priority on the envelope:

Change:

<!-- edit: internal/messages/messages.go -->
~~~go
// Finished jobs go to the notifier, which sends webhooks (Phase 6).
const (
	CommandsQueue = "jobs.commands"
	EventsQueue   = "jobs.events"
	WebhooksQueue = "webhooks.deliveries"
~~~

to:

~~~go
// Finished jobs go to the notifier, which sends webhooks (Phase 6).
//
// ShortCommandsQueue is the short lane when lanes are reserved (Phase 7,
// step 9): jobs predicted to run briefly, served by consumers kept apart
// for them, so they never wait behind long ones. CommandsQueue is then the
// long lane, and every job without a prediction goes there.
const (
	CommandsQueue      = "jobs.commands"
	ShortCommandsQueue = "jobs.commands.short"
	EventsQueue        = "jobs.events"
	WebhooksQueue      = "webhooks.deliveries"
~~~

Change:

<!-- edit: internal/messages/messages.go -->
~~~go
	Tenant string `json:"tenant,omitempty"`
}
~~~

to:

~~~go
	Tenant string `json:"tenant,omitempty"`
	// Priority is how soon the message should be delivered, 0 to 9 (Phase
	// 7, step 9): RabbitMQ's quorum queues deliver every message above 4
	// before any at 4 or below. Only commands set it; events leave it out.
	Priority uint8 `json:"priority,omitempty"`
}
~~~


The envelope also carries events to Kafka, and `omitempty` keeps `priority` out of them: only commands set it, so the event contract doesn't change. RabbitMQ takes the priority from the message's properties. In `internal/rabbit/rabbit.go`:

Change:

<!-- edit: internal/rabbit/rabbit.go -->
~~~go
		Type:         msg.Type,
		Timestamp:    msg.OccurredAt,
~~~

to:

~~~go
		Type:         msg.Type,
		Priority:     msg.Priority,
		Timestamp:    msg.OccurredAt,
~~~


The predictor computes `alone_s` with the same model, on the same features, with the counts of running and queued jobs set to zero. In `lab/src/lab/online.py`:

At the end of the file, change:

<!-- edit: lab/src/lab/online.py -->
~~~python
    return report
~~~

to:

~~~python
    return report


def alone(rows: dict) -> dict:
    """The same jobs, as if nothing else were running or queued: their own size.

    Step 9: lanes chosen by the contention-aware prediction stopped working
    under load, because every prediction grew with the queue, so nothing
    counted as short just when lanes mattered. A job's lane depends on the
    job, not on the moment.
    """
    zero = np.zeros(len(rows["size"]), dtype=np.int64)
    return rows | {"running_at_submit": zero, "queued_at_submit": zero}
~~~


In `lab/src/lab/serve.py`:

Change:

<!-- edit: lab/src/lab/serve.py -->
~~~python
from lab.online import State
~~~

to:

~~~python
from lab.online import State, alone
~~~

Change:

<!-- edit: lab/src/lab/serve.py -->
~~~python
        p90_s = float(self.artifact["bound"].predict(rows)[0])
        self.latency.observe(time.perf_counter() - start)
~~~

to:

~~~python
        p90_s = float(self.artifact["bound"].predict(rows)[0])
        alone_s = float(self.artifact["point"].predict(alone(rows))[0])
        self.latency.observe(time.perf_counter() - start)
~~~

Change:

<!-- edit: lab/src/lab/serve.py -->
~~~python
        answer = {"run_s": run_s, "p90_s": max(p90_s, run_s), "model": self.artifact["version"]}
~~~

to:

~~~python
        answer = {
            "run_s": run_s,
            "p90_s": max(p90_s, run_s),
            "alone_s": alone_s,
            "model": self.artifact["version"],
        }
~~~


In `lab/tests/test_serve.py`:

Change:

<!-- edit: lab/tests/test_serve.py -->
~~~python
        assert body["model"] == "test-1" and 0 < body["run_s"] <= body["p90_s"]
        assert body["features"]["running_at_submit"] == 2
~~~

to:

~~~python
        assert body["model"] == "test-1" and 0 < body["run_s"] <= body["p90_s"]
        assert 0 < body["alone_s"] <= body["run_s"] * 1.01  # nothing running: not slower
        assert body["features"]["running_at_submit"] == 2
~~~


The API reads it, and the domain carries it for the one moment it's needed: choosing the lane when the job is created. It isn't stored. In `internal/jobs/service.go`:

Change:

<!-- edit: internal/jobs/service.go -->
~~~go
	Model string
}
~~~

to:

~~~go
	Model string
	// AloneS (step 9) is how long the job would take with nothing else
	// running: its own size. It decides the job's lane when it's created,
	// and isn't stored.
	AloneS float64
}
~~~


In `internal/predict/predict.go`:

Change:

<!-- edit: internal/predict/predict.go -->
~~~go
	RunS  float64 `json:"run_s"`
	P90S  float64 `json:"p90_s"`
	Model string  `json:"model"`
~~~

to:

~~~go
	RunS   float64 `json:"run_s"`
	P90S   float64 `json:"p90_s"`
	AloneS float64 `json:"alone_s"`
	Model  string  `json:"model"`
~~~

Change:

<!-- edit: internal/predict/predict.go -->
~~~go
	return jobs.Prediction{RunS: got.RunS, P90S: got.P90S, Model: got.Model}, nil
~~~

to:

~~~go
	return jobs.Prediction{RunS: got.RunS, P90S: got.P90S, Model: got.Model, AloneS: got.AloneS}, nil
~~~


In `internal/predict/predict_test.go`:

Change:

<!-- edit: internal/predict/predict_test.go -->
~~~go
	s, _ := server(t, 0, 200, `{"run_s": 0.4, "p90_s": 1.2, "model": "m1", "features": {}}`)
~~~

to:

~~~go
	s, _ := server(t, 0, 200, `{"run_s": 0.4, "p90_s": 1.2, "alone_s": 0.3, "model": "m1", "features": {}}`)
~~~

Change:

<!-- edit: internal/predict/predict_test.go -->
~~~go
	if err != nil || p != (jobs.Prediction{RunS: 0.4, P90S: 1.2, Model: "m1"}) {
~~~

to:

~~~go
	if err != nil || p != (jobs.Prediction{RunS: 0.4, P90S: 1.2, Model: "m1", AloneS: 0.3}) {
~~~


In `internal/eventing/eventing.go`:

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
	Webhooks     bool // finished jobs, to the notifier (Phase 6)
}
~~~

to:

~~~go
	Webhooks     bool // finished jobs, to the notifier (Phase 6)
	// Lanes (Phase 7, step 9): how short jobs get ahead of long ones.
	Lanes Lanes
}

// Lanes says which jobs are short, and what being short gets them. A job
// predicted to run for at most ShortMax is short; zero ShortMax means no
// lanes, first come first served. Short jobs either go to a queue of their
// own, served by consumers reserved for them (Reserved), or share the one
// queue at a higher priority, so every consumer takes them first.
type Lanes struct {
	ShortMax time.Duration
	Reserved bool
}

// HighPriority is a short job's command priority: above 4, which is what
// RabbitMQ's quorum queues deliver first.
const HighPriority = 5

// Short reports whether job is a short one: predicted to finish within
// ShortMax by its own size (AloneS), whatever else is running; or, from a
// predictor that doesn't say, by its expected run time. A job with no
// prediction isn't short.
func (l Lanes) Short(job jobs.Job) bool {
	if l.ShortMax <= 0 || job.Prediction == nil {
		return false
	}
	size := job.Prediction.AloneS
	if size <= 0 {
		size = job.Prediction.RunS
	}
	return size <= l.ShortMax.Seconds()
}

// Command is where a new job's RunJob command goes, and at what priority.
func (l Lanes) Command(job jobs.Job) (queue string, priority uint8) {
	switch {
	case !l.Short(job):
		return messages.CommandsQueue, 0
	case l.Reserved:
		return messages.ShortCommandsQueue, 0
	default:
		return messages.CommandsQueue, HighPriority
	}
}
~~~

Change:

<!-- edit: internal/eventing/eventing.go -->
~~~go
			msgs = append(msgs, outbox.Message{Destination: messages.CommandsQueue, Envelope: cmd})
~~~

to:

~~~go
			queue, priority := o.Lanes.Command(job)
			cmd.Priority = priority
			msgs = append(msgs, outbox.Message{Destination: queue, Envelope: cmd})
~~~


In `internal/eventing/eventing_test.go`:

Change:

<!-- edit: internal/eventing/eventing_test.go -->
~~~go
// Only finished jobs are sent to the notifier, each with its tenant.
func TestOutboxMessagesNotifyFinishedJobs(t *testing.T) {
~~~

to:

~~~go
// Only finished jobs are sent to the notifier, each with its tenant.
// Step 9: a short job goes to the short lane's queue, or to the shared
// queue at high priority; long work, sleeps and anything unpredicted go to
// the shared queue at normal priority; and with no threshold, there are no
// lanes at all.
func TestJobsGoToTheirLane(t *testing.T) {
	t0 := time.Date(2026, 10, 18, 9, 0, 0, 0, time.UTC)
	job := func(runS float64) jobs.Job {
		j, _ := jobs.New("j", jobs.Work{Kind: jobs.KindSort, Size: 1000}, t0)
		if runS > 0 {
			j.Prediction = &jobs.Prediction{RunS: runS, P90S: 2 * runS, Model: "m"}
		}
		return j
	}
	short, shared := messages.ShortCommandsQueue, messages.CommandsQueue
	limit := 100 * time.Millisecond
	for _, c := range []struct {
		runS     float64
		lanes    Lanes
		queue    string
		priority uint8
	}{
		{0.05, Lanes{ShortMax: limit, Reserved: true}, short, 0},
		{0.1, Lanes{ShortMax: limit, Reserved: true}, short, 0}, // at the threshold: short
		{0.4, Lanes{ShortMax: limit, Reserved: true}, shared, 0},
		{0, Lanes{ShortMax: limit, Reserved: true}, shared, 0}, // no prediction
		{0.05, Lanes{ShortMax: limit}, shared, HighPriority},
		{0.4, Lanes{ShortMax: limit}, shared, 0},
		{0.05, Lanes{}, shared, 0}, // no lanes
	} {
		msgs, err := OutboxMessages(Outbox{Lanes: c.lanes})(job(c.runS))
		if err != nil || len(msgs) != 1 || msgs[0].Destination != c.queue || msgs[0].Envelope.Priority != c.priority {
			t.Errorf("predicted %.2f s, %+v: %+v, %v; want %s at %d", c.runS, c.lanes, msgs, err, c.queue, c.priority)
		}
	}
}

// Step 9: the lane follows the job's own size, not how busy the system
// was: a short job predicted slow only because of a queue stays short.
func TestTheLaneFollowsTheJobsOwnSize(t *testing.T) {
	j, _ := jobs.New("j", jobs.Work{Kind: jobs.KindSort, Size: 1000}, time.Now())
	j.Prediction = &jobs.Prediction{RunS: 0.6, P90S: 1.0, Model: "m", AloneS: 0.05}
	lanes := Lanes{ShortMax: 100 * time.Millisecond}
	if !lanes.Short(j) {
		t.Fatal("alone 0.05 s, busy 0.6 s: want short")
	}
	j.Prediction.AloneS = 0.3
	if lanes.Short(j) {
		t.Fatal("alone 0.3 s: want long")
	}
}

func TestOutboxMessagesNotifyFinishedJobs(t *testing.T) {
~~~


Does the broker really deliver by priority, and how? Quorum queues have supported message priorities since RabbitMQ 4.0, with two levels: above 4, and the rest. I expected them to share deliveries between the levels so the low one isn't starved. Don't trust memory; test it. In `internal/rabbit/rabbit_test.go`:

Change:

<!-- edit: internal/rabbit/rabbit_test.go -->
~~~go
	"errors"
	"os"
	"sync/atomic"
~~~

to:

~~~go
	"errors"
	"fmt"
	"os"
	"sync"
	"sync/atomic"
~~~

Add this at the end of the file:

<!-- append: internal/rabbit/rabbit_test.go -->
~~~go
// Phase 7, step 9: a quorum queue delivers every high-priority message
// before any normal one, whatever order they arrived in. (Strictly: no
// share is kept for the normal ones, so a steady stream of high ones would
// starve them.)
func TestHighPriorityIsDeliveredFirst(t *testing.T) {
	client, queue := setup(t, defaults())
	for i, p := range []uint8{0, 0, 0, 5, 5, 5} {
		msg := newMsg(t)
		msg.ID, msg.Priority = fmt.Sprintf("%d-%d", i, p), p
		if err := client.Publish(context.Background(), queue, msg); err != nil {
			t.Fatal(err)
		}
	}
	var mu sync.Mutex
	var got []uint8
	stop := consume(client, queue, func(_ context.Context, m messages.Envelope) error {
		mu.Lock()
		defer mu.Unlock()
		got = append(got, m.Priority)
		return nil
	})
	defer stop()
	eventually(t, func() bool { mu.Lock(); defer mu.Unlock(); return len(got) == 6 })
	if fmt.Sprint(got) != "[5 5 5 0 0 0]" {
		t.Fatalf("delivered in priority order %v", got)
	}
}
~~~


~~~bash
RUNWAY_AMQP_URL=amqp://guest:guest@localhost:5672/ go test -count=1 -run Priority -v ./internal/rabbit/
~~~

~~~text
--- PASS: TestHighPriorityIsDeliveredFirst (1.00s)
ok  	runway/internal/rabbit	1.008s
~~~

Strict: all three high-priority messages before any normal one, though the normal ones arrived first. (A probe with thirty of each gave thirty high, then thirty normal.) So on this broker, priority means a long job waits as long as any short job does. That's the starvation risk, and the experiment must look for it.

The API chooses the lanes from its configuration: `SHORT_LANE_MAX` (0, no lanes) and `SHORT_LANE_MODE`. In `cmd/api/main.go`:

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	PredictTimeout time.Duration
}
~~~

to:

~~~go
	PredictTimeout time.Duration
	// Step 9: jobs predicted to run for at most SHORT_LANE_MAX are short
	// (0: no lanes). SHORT_LANE_MODE says what that gets them: "priority",
	// ahead of the rest in the one queue; or "reserved", a queue of their own
	// with consumers kept for it.
	Lanes eventing.Lanes
}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	cfg.PredictorURL = getenv("PREDICTOR_URL")
	if cfg.PredictTimeout, err = envconfig.Duration(getenv, "PREDICT_TIMEOUT", 100*time.Millisecond); err != nil {
~~~

to:

~~~go
	cfg.PredictorURL = getenv("PREDICTOR_URL")
	// "0" is a value here, not a mistake: no lanes. Duration insists on more.
	if v := getenv("SHORT_LANE_MAX"); v != "" && v != "0" {
		if cfg.Lanes.ShortMax, err = envconfig.Duration(getenv, "SHORT_LANE_MAX", 0); err != nil {
			return config{}, err
		}
	}
	switch mode := getenv("SHORT_LANE_MODE"); mode {
	case "", "priority":
	case "reserved":
		cfg.Lanes.Reserved = true
	default:
		return config{}, fmt.Errorf("SHORT_LANE_MODE=%q: want priority or reserved", mode)
	}
	if cfg.Lanes.ShortMax > 0 && cfg.PredictorURL == "" {
		return config{}, errors.New("SHORT_LANE_MAX needs PREDICTOR_URL: lanes are chosen by predicted run time")
	}
	if cfg.PredictTimeout, err = envconfig.Duration(getenv, "PREDICT_TIMEOUT", 100*time.Millisecond); err != nil {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
	q := []string{messages.CommandsQueue, messages.EventsQueue}
	if cfg.Webhooks {
~~~

to:

~~~go
	q := []string{messages.CommandsQueue, messages.EventsQueue}
	if cfg.Lanes.ShortMax > 0 && cfg.Lanes.Reserved {
		q = append(q, messages.ShortCommandsQueue)
	}
	if cfg.Webhooks {
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		storeOptions := []pgstore.Option{pgstore.WithOutbox(eventing.OutboxMessages(eventing.Outbox{StreamEvents: producer != nil, Webhooks: cfg.Webhooks}))}
~~~

to:

~~~go
		storeOptions := []pgstore.Option{pgstore.WithOutbox(eventing.OutboxMessages(eventing.Outbox{StreamEvents: producer != nil, Webhooks: cfg.Webhooks, Lanes: cfg.Lanes}))}
~~~

Change:

<!-- edit: cmd/api/main.go -->
~~~go
		destinations := []string{messages.CommandsQueue}
		if producer != nil {
~~~

to:

~~~go
		destinations := []string{messages.CommandsQueue}
		if cfg.Lanes.ShortMax > 0 && cfg.Lanes.Reserved {
			destinations = append(destinations, messages.ShortCommandsQueue)
		}
		if producer != nil {
~~~


"0" is handled before the duration parser for a reason: `envconfig.Duration` accepts only positive durations, and the chart's default of "0" crashed every API Pod on my first deploy. Nothing had tested the default. Now something does. In `cmd/api/main_test.go`:

Add this at the end of the file:

<!-- append: cmd/api/main_test.go -->
~~~go
// Step 9: lanes. "0" means none (the chart's default, which once crashed
// the API: a duration of zero isn't a positive one); a threshold needs the
// predictor; the mode must be one of two.
func TestLanesConfig(t *testing.T) {
	for _, off := range []string{"", "0"} {
		cfg, err := loadConfig(env(map[string]string{"SHORT_LANE_MAX": off}))
		if err != nil || cfg.Lanes.ShortMax != 0 {
			t.Fatalf("SHORT_LANE_MAX=%q: %+v, %v", off, cfg.Lanes, err)
		}
	}
	on := map[string]string{"SHORT_LANE_MAX": "100ms", "PREDICTOR_URL": "http://127.0.0.1:17100", "SHORT_LANE_MODE": "reserved"}
	cfg, err := loadConfig(env(on))
	if err != nil || cfg.Lanes.ShortMax != 100*time.Millisecond || !cfg.Lanes.Reserved {
		t.Fatalf("%+v, %v", cfg.Lanes, err)
	}
	if _, err := loadConfig(env(map[string]string{"SHORT_LANE_MAX": "100ms"})); err == nil {
		t.Fatal("lanes without a predictor accepted")
	}
	on["SHORT_LANE_MODE"] = "fastest"
	if _, err := loadConfig(env(on)); err == nil {
		t.Fatal("an unknown mode accepted")
	}
}
~~~


With reserved lanes, each worker gives some of its consumers to the short lane. In `cmd/worker/main.go`:

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	"os/signal"
	"sync"
~~~

to:

~~~go
	"os/signal"
	"strconv"
	"sync"
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	MetricsAddr   string // empty: no metrics endpoint
}
~~~

to:

~~~go
	MetricsAddr   string // empty: no metrics endpoint
	// Step 9: how many of the Workers consumers serve the short lane; the
	// rest serve the long one. Zero: one lane, every consumer on it.
	ShortLaneWorkers int
}
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	if cfg.MetricsAddr, err = envconfig.HostPort(getenv, "METRICS_ADDR", ""); err != nil {
		return config{}, err
	}
	return cfg, nil
~~~

to:

~~~go
	if cfg.MetricsAddr, err = envconfig.HostPort(getenv, "METRICS_ADDR", ""); err != nil {
		return config{}, err
	}
	if v := getenv("SHORT_LANE_WORKERS"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n < 0 || n >= cfg.Workers {
			return config{}, fmt.Errorf("SHORT_LANE_WORKERS=%q: want 0 to %d, so the long lane keeps a consumer", v, cfg.Workers-1)
		}
		cfg.ShortLaneWorkers = n
	}
	if cfg.ShortLaneWorkers > 0 && cfg.SQSPrefix != "" {
		return config{}, errors.New("SHORT_LANE_WORKERS needs RabbitMQ: the SQS bus has one commands queue")
	}
	return cfg, nil
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	handle := telemetry.Handler(messages.CommandsQueue,
		metrics.observe(logged(logger, worker.New(events, run, cfg.JobTimeout).Handle)))
~~~

to:

~~~go
	handler := metrics.observe(logged(logger, worker.New(events, run, cfg.JobTimeout).Handle))
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	for range cfg.Workers {
~~~

to:

~~~go
	// One consumer per slot (prefetch 1), each on its lane's queue: a short
	// slot never takes a long job, so short jobs never wait behind one.
	for i := range cfg.Workers {
		queue := messages.CommandsQueue
		if i < cfg.ShortLaneWorkers {
			queue = messages.ShortCommandsQueue
		}
		handle := telemetry.Handler(queue, handler)
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
			if err := client.Subscribe(stopConsuming, messages.CommandsQueue, handle); err != nil {
~~~

to:

~~~go
			if err := client.Subscribe(stopConsuming, queue, handle); err != nil {
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	logger.Info("worker ready", "consumers", cfg.Workers)
~~~

to:

~~~go
	logger.Info("worker ready", "consumers", cfg.Workers, "short_lane", cfg.ShortLaneWorkers)
~~~

Change:

<!-- edit: cmd/worker/main.go -->
~~~go
	}, messages.CommandsQueue, messages.EventsQueue)
~~~

to:

~~~go
	}, queues(cfg)...)
~~~

Add this at the end of the file:

<!-- append: cmd/worker/main.go -->
~~~go
// queues are the queues the worker declares: the short lane's too, if it
// serves one.
func queues(cfg config) []string {
	q := []string{messages.CommandsQueue, messages.EventsQueue}
	if cfg.ShortLaneWorkers > 0 {
		q = append(q, messages.ShortCommandsQueue)
	}
	return q
}
~~~


Each consumer has a prefetch of one, so each is one job at a time, a "slot". A slot on the short lane never takes a long job: that's what makes the lane reserved, and also why it can sit idle. In `cmd/worker/main_test.go`:

Add this at the end of the file:

<!-- append: cmd/worker/main_test.go -->
~~~go
// Step 9: some consumers for the short lane, never all of them.
func TestShortLaneWorkers(t *testing.T) {
	amqp := "amqp://guest:guest@localhost:5672/"
	cfg, err := loadConfig(env(map[string]string{"AMQP_URL": amqp, "WORKERS": "4", "SHORT_LANE_WORKERS": "1"}))
	if err != nil || cfg.ShortLaneWorkers != 1 || len(queues(cfg)) != 3 {
		t.Fatalf("cfg %+v, queues %v, %v", cfg, queues(cfg), err)
	}
	for _, bad := range []string{"4", "-1", "two"} {
		_, err := loadConfig(env(map[string]string{"AMQP_URL": amqp, "WORKERS": "4", "SHORT_LANE_WORKERS": bad}))
		if err == nil || !strings.Contains(err.Error(), "SHORT_LANE_WORKERS") {
			t.Fatalf("SHORT_LANE_WORKERS=%s: %v", bad, err)
		}
	}
	if cfg, _ := loadConfig(env(map[string]string{"AMQP_URL": amqp})); len(queues(cfg)) != 2 {
		t.Fatalf("one lane declares %v", queues(cfg))
	}
}
~~~


The autoscaler counted only `jobs.commands`; with a second queue, it would miss the short lane's work. In `internal/autoscale/sources.go`:

Change:

<!-- edit: internal/autoscale/sources.go -->
~~~go
	"net/url"
	"time"
~~~

to:

~~~go
	"net/url"
	"strings"
	"time"
~~~

Change:

<!-- edit: internal/autoscale/sources.go -->
~~~go
	Queue    string
~~~

to:

~~~go
	Queue    string // one queue, or several separated by commas: their backlogs add up
~~~

Change:

<!-- edit: internal/autoscale/sources.go -->
~~~go

func (q RabbitQueue) Backlog(ctx context.Context) (int, error) {
	vhost := q.VHost
~~~

to:

~~~go

// Backlog is the work waiting or in progress, summed over the queues: with
// lanes (Phase 7, step 9), the short lane's jobs are work for the same
// workers.
func (q RabbitQueue) Backlog(ctx context.Context) (int, error) {
	total := 0
	for name := range strings.SplitSeq(q.Queue, ",") {
		n, err := q.backlogOf(ctx, strings.TrimSpace(name))
		if err != nil {
			return 0, err
		}
		total += n
	}
	return total, nil
}

func (q RabbitQueue) backlogOf(ctx context.Context, queue string) (int, error) {
	vhost := q.VHost
~~~

Change:

<!-- edit: internal/autoscale/sources.go -->
~~~go
	u := fmt.Sprintf("%s/api/queues/%s/%s", q.BaseURL, url.PathEscape(vhost), url.PathEscape(q.Queue))
~~~

to:

~~~go
	u := fmt.Sprintf("%s/api/queues/%s/%s", q.BaseURL, url.PathEscape(vhost), url.PathEscape(queue))
~~~


In `internal/autoscale/autoscale_test.go`:

Add this at the end of the file:

<!-- append: internal/autoscale/autoscale_test.go -->
~~~go
// Step 9: with lanes, both lanes' work is the workers' work.
func TestRabbitQueueAddsUpLanes(t *testing.T) {
	counts := map[string]string{
		"/api/queues/%2F/jobs.commands":       `{"messages_ready": 30, "messages_unacknowledged": 6}`,
		"/api/queues/%2F/jobs.commands.short": `{"messages_ready": 2, "messages_unacknowledged": 2}`,
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, ok := counts[r.URL.EscapedPath()]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = io.WriteString(w, body)
	}))
	defer server.Close()
	q := RabbitQueue{BaseURL: server.URL, User: "u", Password: "p", Queue: "jobs.commands, jobs.commands.short"}
	if got, err := q.Backlog(context.Background()); err != nil || got != 40 {
		t.Fatalf("Backlog = %d, %v; want 40", got, err)
	}
}
~~~


<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go test -race -count=1 ./... -->

The chart sets all three together. In `deploy/helm/runway/values.yaml`:

Change:

<!-- edit: deploy/helm/runway/values.yaml -->
~~~yaml

# The queue-depth autoscaler (step 11).
~~~

to:

~~~yaml

# Lanes (Phase 7, step 9): a job whose own size is predicted within
# shortMax is short. mode priority: short jobs share the one queue,
# delivered before the rest. mode reserved: they get a queue of their own,
# served by shortWorkers of each worker Pod's consumers. shortMax "0": no
# lanes, first come first served. Needs predictor.enabled. Step 9's
# experiment chose priority at 50 ms; plan the threshold again (lab lanes
# plan) whenever the model or the workload changes.
lanes:
  shortMax: 50ms
  mode: priority
  shortWorkers: 1

# The queue-depth autoscaler (step 11).
~~~


In `deploy/helm/runway/templates/_helpers.tpl`:

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
        - { name: PREDICT_TIMEOUT, value: {{ $root.Values.predictor.timeout | quote }} }
        {{- end }}
~~~

to:

~~~yaml
        - { name: PREDICT_TIMEOUT, value: {{ $root.Values.predictor.timeout | quote }} }
        - { name: SHORT_LANE_MAX, value: {{ $root.Values.lanes.shortMax | quote }} }
        - { name: SHORT_LANE_MODE, value: {{ $root.Values.lanes.mode | quote }} }
        {{- end }}
~~~

Change:

<!-- edit: deploy/helm/runway/templates/_helpers.tpl -->
~~~yaml
{{/* ...and spans may go to the collector (Phase 5, step 9). */}}
{{- define "runway.toCollector" -}}
~~~

to:

~~~yaml
{{/* ...and spans may go to the collector (Phase 5, step 9). */}}
{{/* Whether short jobs have a queue of their own (step 9): lanes on, and reserved. */}}
{{- define "runway.reservedLanes" -}}
{{- if and .Values.predictor.enabled (ne (toString .Values.lanes.shortMax) "0") (eq .Values.lanes.mode "reserved") }}true{{ end }}
{{- end }}

{{- define "runway.toCollector" -}}
~~~


In `deploy/helm/runway/templates/worker.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/worker.yaml -->
~~~yaml
            - { name: JOB_TIMEOUT, value: {{ .Values.worker.jobTimeout | quote }} }
            {{- with include "runway.tracingEnv" (dict "root" $ "service" "worker") | trim }}
~~~

to:

~~~yaml
            - { name: JOB_TIMEOUT, value: {{ .Values.worker.jobTimeout | quote }} }
            {{- if include "runway.reservedLanes" . }}
            - { name: SHORT_LANE_WORKERS, value: {{ .Values.lanes.shortWorkers | quote }} }
            {{- end }}
            {{- with include "runway.tracingEnv" (dict "root" $ "service" "worker") | trim }}
~~~


In `deploy/helm/runway/templates/autoscaler.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/autoscaler.yaml -->
~~~yaml
            - { name: SCALE_DOWN_AFTER, value: {{ .Values.autoscaler.scaleDownAfter | quote }} }
          resources:
~~~

to:

~~~yaml
            - { name: SCALE_DOWN_AFTER, value: {{ .Values.autoscaler.scaleDownAfter | quote }} }
            {{- if include "runway.reservedLanes" . }}
            - { name: AUTOSCALE_QUEUE, value: "jobs.commands,jobs.commands.short" } # both lanes (step 9)
            {{- end }}
          resources:
~~~


<!-- run: helm lint deploy/helm/runway && helm template runway deploy/helm/runway --set lanes.shortMax=100ms --set lanes.mode=reserved | grep -q 'name: SHORT_LANE_WORKERS' -->

### Plan, then simulate

Create `lab/src/lab/lanes.py`:

<!-- file: lab/src/lab/lanes.py -->
~~~python
"""Two lanes for jobs: planning them, simulating them, and measuring them.

Shortest job first minimises the mean wait: a short job that waits behind
a long one waits a long time, while a long job that waits behind a short
one hardly notices. Run times aren't known in advance, so the API puts
jobs *predicted* to be short in their own lane, served by consumers kept
for it. Two questions decide whether that works: is the short lane's
share of the slots enough for its share of the *work* (not of the jobs)?
And does making short jobs wait less make long jobs wait much more?
"""

import heapq
from collections.abc import Iterable

import numpy as np

from lab.warehouse import table

Rows = dict[str, np.ndarray]


def plan(predicted: np.ndarray, run_s: np.ndarray, thresholds: Iterable[float]) -> str:
    """For each threshold: the share of jobs, and of work, that would go to the short lane."""
    out = []
    total = run_s.sum()
    for t in thresholds:
        short = predicted <= t
        out.append([t, short.mean() * 100, run_s[short].sum() / total * 100])
        out[-1] += [np.median(run_s[short]) if short.any() else np.nan]
    return table(["threshold_s", "jobs_short_%", "work_short_%", "short_median_run_s"], out)


def simulate(
    arrivals: np.ndarray, runs: np.ndarray, lanes: list[tuple[np.ndarray, int]]
) -> np.ndarray:
    """Each job's wait, with each lane a first-come-first-served queue and its own servers.

    lanes: (which jobs go to it, how many servers it has). Service times are
    the recorded run times, as if they wouldn't change: in the cluster they
    do, because jobs on one worker Pod share its CPU.
    """
    waits = np.zeros(len(arrivals))
    for members, servers in lanes:
        free = [0.0] * servers  # when each server is next free
        heapq.heapify(free)
        for i in np.flatnonzero(members)[np.argsort(arrivals[members], kind="stable")]:
            soonest = heapq.heappop(free)
            start = max(arrivals[i], soonest)
            waits[i] = start - arrivals[i]
            heapq.heappush(free, start + runs[i])
    return waits


def simulate_priority(
    arrivals: np.ndarray, runs: np.ndarray, short: np.ndarray, servers: int, ratio: int = 0
) -> np.ndarray:
    """Each job's wait with one queue and every server, short jobs first.

    ratio 0: strictly first (a long job starts only when no short one waits).
    ratio n: when both kinds wait, n short jobs, then one long one, as
    RabbitMQ 4's quorum queues share out their two priorities.
    """
    order = np.argsort(arrivals, kind="stable")
    free = [0.0] * servers
    heapq.heapify(free)
    waiting = {True: [], False: []}  # arrival-ordered queues of job indices
    waits = np.zeros(len(arrivals))
    nxt, served_short = 0, 0
    pending = len(order)
    while pending:
        now = heapq.heappop(free)
        # Everything that has arrived by the time a server frees up is waiting.
        while nxt < len(order) and arrivals[order[nxt]] <= now:
            i = order[nxt]
            waiting[bool(short[i])].append(i)
            nxt += 1
        if not waiting[True] and not waiting[False]:
            i = order[nxt]  # idle until the next arrival
            waiting[bool(short[i])].append(i)
            nxt += 1
            now = arrivals[i]
        both = waiting[True] and waiting[False]
        take_short = bool(waiting[True]) and not (both and ratio and served_short >= ratio)
        if take_short:
            i = waiting[True].pop(0)
            served_short += 1
        else:
            i = waiting[False].pop(0)
            served_short = 0
        start = max(now, arrivals[i])
        waits[i] = start - arrivals[i]
        heapq.heappush(free, start + runs[i])
        pending -= 1
    return waits


def describe(waits: np.ndarray, groups: dict[str, np.ndarray]) -> list[list]:
    rows = []
    for name, mask in groups.items():
        w = waits[mask]
        if len(w):
            rows.append([name, len(w), w.mean(), np.median(w), np.quantile(w, 0.99), w.max()])
    return rows


WAIT_NAMES = ["jobs", "mean_wait_s", "p50_wait_s", "p99_wait_s", "max_wait_s"]


def compare(arms: dict[str, Rows], threshold: float, by: str = "predicted_run_s") -> str:
    """Measured waits per arm, overall and per predicted class, and how the p90 promise held."""
    out, promise = [], []
    for arm, rows in arms.items():
        wait, run = rows["wait_s"], rows["run_s"]
        short = rows[by] <= threshold
        groups = {"all": np.ones(len(wait), bool), "short": short, "long": ~short}
        for row in describe(wait, groups):
            out.append([arm] + row)
        for name, mask in groups.items():
            bound = rows["predicted_p90_s"][mask]
            total_ok = (wait[mask] + run[mask]) <= bound
            promise.append([arm, name, total_ok.mean() * 100, (run[mask] <= bound).mean() * 100])
    text = table(["arm", "jobs_in"] + WAIT_NAMES, out)
    text += "\n\nThe p90 as a promise: the share of jobs that finished within it\n"
    text += table(["arm", "jobs", "wait+run_%", "run_alone_%"], promise)
    return text


def difference(a: Rows, b: Rows, what: str = "wait_s") -> tuple[float, float, float]:
    """b's mean minus a's, with a 95% interval from resampling whole minutes of each arm."""
    rng = np.random.default_rng(1)

    def means(rows: Rows) -> np.ndarray:
        minute = rows["created_at"].astype("datetime64[m]").astype(np.int64)
        ids, inverse = np.unique(minute, return_inverse=True)
        sums = np.bincount(inverse, weights=rows[what])
        counts = np.bincount(inverse)
        picks = rng.integers(0, len(ids), size=(2000, len(ids)))
        return sums[picks].sum(axis=1) / counts[picks].sum(axis=1)

    diff = means(b) - means(a)
    return float(b[what].mean() - a[what].mean()), *np.quantile(diff, [0.025, 0.975])


def arm_rows(data, results_file, dataset_rows: Rows, model=None) -> Rows:
    """The dataset's rows for the jobs one kload run submitted, with the predictions they were
    served (from the events: NaN for a job that got none), and, given the served model, each
    job's own size (alone_s): the prediction with nothing else running, as the API used it."""
    import json

    import duckdb

    ids = [json.loads(line)["id"] for line in open(results_file)]
    con = duckdb.connect()
    served = dict(
        (job, (run, p90))
        for job, run, p90 in con.execute(
            f"""SELECT job_id, any_value(predicted_run_s), any_value(predicted_p90_s)
                FROM read_parquet('{data}/events/**/*.parquet', union_by_name = true)
                WHERE job_id IN (SELECT unnest(?)) GROUP BY 1""",
            [ids],
        ).fetchall()
    )
    mask = np.isin(dataset_rows["job_id"], ids)
    rows = {k: v[mask] for k, v in dataset_rows.items()}
    pairs = [served.get(int(j), (None, None)) for j in rows["job_id"]]
    rows["predicted_run_s"] = np.array([np.nan if r is None else r for r, _ in pairs])
    rows["predicted_p90_s"] = np.array([np.nan if p is None else p for _, p in pairs])
    if model is not None:
        from lab.online import alone

        rows["alone_s"] = model["point"].predict(alone(rows)) if len(rows["size"]) else np.array([])
    return rows


def rounds(runs: list[tuple[str, Rows]], threshold: float, by: str) -> str:
    """One line per run: how many jobs, how many short, and how long they waited."""
    out = []
    for name, rows in runs:
        short = rows[by] <= threshold
        w = rows["wait_s"]
        out.append([name, len(w), short.mean() * 100, w.mean(), np.quantile(w, 0.99)])
        out[-1] += [w[~short].mean(), rows["run_s"].sum()]
    names = ["run", "jobs", "short_%", "mean_wait_s", "p99_wait_s", "long_mean_wait_s", "work_s"]
    return table(names, out)


def against_fifo(arms: dict[str, Rows], threshold: float, by: str = "predicted_run_s") -> str:
    """Each arm's mean wait minus fifo's, overall and per class, with intervals."""

    def part(rows: Rows, name: str) -> Rows:
        short = rows[by] <= threshold
        mask = {"all": np.ones(len(short), bool), "short": short, "long": ~short}[name]
        return {k: v[mask] for k, v in rows.items()}

    out = []
    for arm, rows in arms.items():
        if arm == "fifo":
            continue
        for name in ("all", "short", "long"):
            diff, low, high = difference(part(arms["fifo"], name), part(rows, name))
            out.append([arm, name, diff, f"{low:+.3f} .. {high:+.3f}"])
    return table(["arm", "jobs", "minus_fifo_s", "95% CI"], out)
~~~

`simulate` is a discrete-event simulation of first-come-first-served queues: each job takes the server that's free soonest, at its arrival or when that server frees up, whichever is later. With two lanes, it runs once per lane. `simulate_priority` keeps one queue and every server; each time a server frees up, it takes the oldest short job waiting, if there is one. Neither preempts: a running job finishes. `arm_rows`, `compare`, `difference` and `against_fifo` are for the measurements.

Create `lab/tests/test_lanes.py`, small cases worked out by hand:

<!-- file: lab/tests/test_lanes.py -->
~~~python
import numpy as np
import pytest

from lab import lanes

# One long job arrives first, then three short ones, on one server.
ARRIVALS = np.array([0.0, 0.1, 0.2, 0.3])
RUNS = np.array([10.0, 1.0, 1.0, 1.0])
SHORT = np.array([False, True, True, True])


def test_fifo_makes_short_jobs_wait_behind_a_long_one():
    waits = lanes.simulate(ARRIVALS, RUNS, [(np.ones(4, bool), 1)])
    # Job 1 starts at 10, job 2 at 11, job 3 at 12.
    assert waits.tolist() == pytest.approx([0.0, 9.9, 10.8, 11.7])


def test_priority_cant_overtake_a_job_already_running():
    # The long job started at 0 before any short one arrived: no preemption.
    waits = lanes.simulate_priority(ARRIVALS, RUNS, SHORT, servers=1)
    assert waits.tolist() == pytest.approx([0.0, 9.9, 10.8, 11.7])


def test_priority_puts_short_jobs_first_among_those_waiting():
    arrivals = np.array([0.0, 0.1, 0.2, 0.3])
    runs = np.array([5.0, 10.0, 1.0, 1.0])  # job 1 is long and arrived before the short ones
    short = np.array([False, False, True, True])
    waits = lanes.simulate_priority(arrivals, runs, short, servers=1)
    # At 5 the waiting are 1 (long), 2 and 3 (short): 2 goes, then 3, then 1.
    assert waits.tolist() == pytest.approx([0.0, 1.9 + 5.0, 4.8, 5.7])


def test_a_ratio_lets_a_long_job_through():
    arrivals = np.zeros(5)
    runs = np.ones(5)
    short = np.array([False, True, True, True, True])
    strict = lanes.simulate_priority(arrivals, runs, short, servers=1)
    shared = lanes.simulate_priority(arrivals, runs, short, servers=1, ratio=2)
    assert strict[0] == 4.0, "strict priority: the long job goes last"
    assert shared[0] == 2.0, "two short, then the long one"


def test_reserved_lanes_keep_short_jobs_off_the_long_ones_servers():
    waits = lanes.simulate(ARRIVALS, RUNS, [(SHORT, 1), (~SHORT, 1)])
    assert waits.tolist() == pytest.approx([0.0, 0.0, 0.9, 1.8])


def test_plan_counts_jobs_and_work():
    text = lanes.plan(np.array([0.05, 0.05, 1.0]), np.array([1.0, 1.0, 8.0]), [0.1])
    row = text.splitlines()[2].split()
    assert float(row[1]) == pytest.approx(66.667, abs=0.01) and float(row[2]) == pytest.approx(20.0)
~~~

Add the command, in `lab/src/lab/cli.py`:

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

def cmd_export(args: argparse.Namespace) -> int:
~~~

to:

~~~python

def cmd_lanes(args: argparse.Namespace) -> int:
    import json

    import numpy as np

    from lab import dataset, export, lanes
    from lab.online import alone
    from lab.warehouse import table

    data = dataset.load(args.dataset)

    def predicted_size():
        point = export.load(args.model)["point"]
        return point.predict(alone(data) if args.by == "alone" else data)

    if args.action == "plan":
        predicted = predicted_size()
        print(lanes.plan(predicted, data["run_s"], [0.03, 0.05, 0.08, 0.1, 0.15, 0.2]))
    elif args.action == "simulate":
        predicted = predicted_size()
        created = data["created_at"].astype("datetime64[us]").astype(np.int64) / 1e6
        for run in args.runs:
            ids = [json.loads(line)["id"] for line in open(run)]
            sel = np.isin(data["job_id"], ids)
            arr, runs, short = created[sel], data["run_s"][sel], predicted[sel] <= args.threshold
            busy = runs.sum() / (arr.max() - arr.min()) / args.slots
            every = np.ones(len(arr), bool)
            arms = {
                "fifo": lanes.simulate(arr, runs, [(every, args.slots)]),
                "priority": lanes.simulate_priority(arr, runs, short, args.slots),
                "reserved": lanes.simulate(
                    arr, runs, [(short, args.short_slots), (~short, args.slots - args.short_slots)]
                ),
            }
            groups = {"all": every, "short": short, "long": ~short}
            print(f"{run}: {sel.sum()} jobs, {args.slots} slots {busy:.0%} busy")
            rows = [[a] + r for a, w in arms.items() for r in lanes.describe(w, groups)]
            print(table(["arm", "jobs_in"] + lanes.WAIT_NAMES, rows) + "\n")
    else:  # compare or rounds: ARM=RESULTS ...
        model = export.load(args.model)
        by = "alone_s" if args.by == "alone" else "predicted_run_s"
        runs = []
        for spec in args.runs:
            arm, path = spec.split("=")
            runs.append((arm, Path(path).stem, lanes.arm_rows(args.data, path, data, model)))
        if args.action == "rounds":
            named = [(f"{arm} {stem}", rows) for arm, stem, rows in runs]
            print(lanes.rounds(named, args.threshold, by))
            return 0
        arms: dict = {}
        for arm, _, rows in runs:
            if arm in arms:
                rows = {k: np.concatenate([arms[arm][k], rows[k]]) for k in rows}
            arms[arm] = rows
        print(lanes.compare(arms, args.threshold, by))
        if "fifo" in arms:
            print("\nMean wait against fifo, with 95% intervals (whole minutes resampled):")
            print(lanes.against_fifo(arms, args.threshold, by))
    return 0


def cmd_export(args: argparse.Namespace) -> int:
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

    ex = sub.add_parser("export", help="fit the served models on every row and save them")
~~~

to:

~~~python

    ln = sub.add_parser("lanes", help="plan, simulate and measure short and long lanes")
    ln.add_argument("action", choices=["plan", "simulate", "compare", "rounds"])
    ln.add_argument("runs", nargs="*", help="kload results: FILE (simulate) or ARM=FILE (compare)")
    ln.add_argument("--dataset", type=Path, default=Path("results/dataset.parquet"))
    ln.add_argument("--data", type=Path, default=Path("data"))
    ln.add_argument("--model", type=Path, default=Path("models/runtime-numpy.pkl"))
    ln.add_argument(
        "--threshold", type=float, default=0.05, help="seconds: short if predicted within"
    )
    ln.add_argument("--slots", type=int, default=8, help="consumers in all: 2 worker Pods x 4")
    ln.add_argument("--short-slots", type=int, default=2, help="reserved for the short lane")
    ln.add_argument(
        "--by",
        choices=["alone", "served"],
        default="alone",
        help="short by the job's own size, or by the run time it was served",
    )
    ln.set_defaults(func=cmd_lanes)

    ex = sub.add_parser("export", help="fit the served models on every row and save them")
~~~


<!-- run: cd lab && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_lanes.py -->

How short is short? Ask the served model about every job in the dataset, by its own size:

~~~bash
uv run --project lab lab lanes plan
~~~

~~~text
threshold_s  jobs_short_%  work_short_%  short_median_run_s
-----------  ------------  ------------  ------------------
      0.030        44.030        10.835               0.050
      0.050        64.356        18.638               0.061
      0.080        77.429        26.824               0.073
      0.100        82.193        30.886               0.078
      0.150        88.915        38.961               0.086
      0.200        91.897        44.234               0.090
~~~

At 0.05 s, nearly two thirds of the jobs are short, but they're under a fifth of the work. With one consumer of each worker's four reserved, the short lane has a quarter of the slots for 19% of the work: room to spare. That's the threshold: 50 ms.

Now predict the outcome, replaying two of step 5's recorded runs (load 2 and load 3) through eight slots, each way:

~~~bash
uv run --project lab lab lanes simulate results/s05-run2.jsonl results/s05-run3.jsonl --threshold 0.05
~~~

~~~text
results/s05-run2.jsonl: 2314 jobs, 8 slots 36% busy
     arm  jobs_in  jobs  mean_wait_s  p50_wait_s  p99_wait_s  max_wait_s
--------  -------  ----  -----------  ----------  ----------  ----------
    fifo      all  2314        0.040       0.000       1.424       1.985
    fifo    short  1469        0.041       0.000       1.442       1.925
    fifo     long   845        0.038       0.000       1.403       1.985
priority      all  2314        0.021       0.000       0.507       2.086
priority    short  1469        0.009       0.000       0.272       0.572
priority     long   845        0.041       0.000       1.466       2.086
reserved      all  2314        0.042       0.000       1.115       2.886
reserved    short  1469        0.011       0.000       0.360       0.682
reserved     long   845        0.096       0.000       2.168       2.886

results/s05-run3.jsonl: 3438 jobs, 8 slots 67% busy
     arm  jobs_in  jobs  mean_wait_s  p50_wait_s  p99_wait_s  max_wait_s
--------  -------  ----  -----------  ----------  ----------  ----------
    fifo      all  3438        1.473       0.000      11.651      12.427
    fifo    short  2161        1.544       0.000      11.648      12.427
    fifo     long  1277        1.353       0.000      11.661      12.195
priority      all  3438        0.683       0.000      13.407      14.636
priority    short  2161        0.079       0.000       1.050       1.671
priority     long  1277        1.704       0.000      13.991      14.636
reserved      all  3438        1.140       0.000      14.506      15.839
reserved    short  2161        0.320       0.000       5.620       6.304
reserved     long  1277        2.529       0.062      15.165      15.839

~~~

Write down what this predicts before measuring anything. At load 3, **priority** should halve the mean wait (1.47 to 0.68 s), make short jobs' waits nearly vanish (a mean of 0.08 s), and cost long jobs about a quarter more (1.35 to 1.70 s). **Reserved** lanes should help less (a mean of 1.14 s), and cost long jobs nearly double (2.53 s): the short lane's quarter of the slots idles whenever it has no work, while long jobs queue for the rest. Reserving capacity isn't work-conserving.

### Run it: deploy, with the workers held still

Build and load both images (the predictor returns `alone_s` now), and deploy. For the experiment, turn the autoscaler off and hold the workers at two: eight consumers on two CPUs. Otherwise the number of workers changes during a run, and that, not the lanes, would explain the differences:

~~~bash
docker build -f deploy/predictor/Dockerfile -t runway-predictor:dev .
kind load docker-image runway-predictor:dev --name runway
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
kubectl -n runway rollout restart deploy/predictor
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait \
  --set autoscaler.enabled=false --set worker.replicas=2 --set lanes.shortMax=0
kubectl -n runway rollout restart deploy/api deploy/worker deploy/idp deploy/gateway
~~~

At what load? Too light and nothing queues, so no policy matters; too heavy and the queue grows for the whole run, and every policy just decides who waits forever. I tried three loads with FIFO: 2 (42% busy, a mean wait of 0.13 s), 3 (overloaded: waits growing to 70 s), and 2.5 (83% busy, a mean wait of 3.8 s). 2.5 it is. And between 2 and 3, the work done went from 601 to 1,590 seconds: two and a half times as much for half as many jobs again, because four jobs sharing one CPU each take four times as long. The real capacity is two CPUs, not eight slots, and the simulation's eight servers flatter it.

### Run it: the experiment

Nine runs at load 2.5: three rounds, each with its own seed, in which every arm runs once. The arms' order changes each round (a Latin square), so none always runs first or last, when the cluster may differ. Within a round all three arms send exactly the same jobs at the same moments. Switching arms is a Helm upgrade:

~~~bash
arm() { # NAME ROUND SEED SHORTMAX MODE
  helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait \
    --set lanes.shortMax=$4 --set lanes.mode=$5
  kubectl -n runway rollout status deploy/api && kubectl -n runway rollout status deploy/worker
  sleep 20
  export ACME_TOKEN=$(token acme-ci) GLOBEX_TOKEN=$(token globex-ci) INITECH_TOKEN=$(token initech-ci)
  uv run --project kload kload mix workloads/three-tenants.toml --seed $3 --load 2.5 --out results/s09-$1-$2.jsonl
}
arm fifo 3 51 0 priority;        arm priority 3 51 50ms priority; arm reserved 3 51 50ms reserved
arm priority 4 52 50ms priority; arm reserved 4 52 50ms reserved; arm fifo 4 52 0 priority
arm reserved 5 53 50ms reserved; arm fifo 5 53 0 priority;        arm priority 5 53 50ms priority
uv run --project lab lab pipeline
~~~

About fifty minutes. Every job completed in every run.

Wait until the data is complete before reading it, and the dataset now says when it isn't. In `lab/src/lab/dataset.py`:

Change:

<!-- edit: lab/src/lab/dataset.py -->
~~~python
    keep = old_enough & completed & known
    counts = {
        "jobs": len(run),
~~~

to:

~~~python
    keep = old_enough & completed & known
    everything = (
        warehouse.connect(data)
        .execute("SELECT count(*) FROM (SELECT DISTINCT tenant, job_id FROM events)")
        .fetchone()[0]
    )
    counts = {
        # Jobs whose events all came after as_of: not even known yet. Without
        # this, "too recent 0" can look like "complete" when it isn't.
        "not yet seen": int(everything - len(run)),
        "jobs": len(run),
~~~


I learnt that the hard way. "too recent 0" doesn't mean complete: a job whose events all came after the lateness window isn't counted at all, not even as too recent, and my first analysis silently left out a whole run. `not yet seen` counts those jobs. Wait for both to be zero:

~~~bash
until uv run --project lab lab dataset | head -1 | grep -q "not yet seen 0, .* too recent 0,"; do sleep 20; done
~~~

One line per run first:

~~~bash
R="fifo=results/s09-fifo-3.jsonl priority=results/s09-priority-3.jsonl reserved=results/s09-reserved-3.jsonl"
R="$R priority=results/s09-priority-4.jsonl reserved=results/s09-reserved-4.jsonl fifo=results/s09-fifo-4.jsonl"
R="$R reserved=results/s09-reserved-5.jsonl fifo=results/s09-fifo-5.jsonl priority=results/s09-priority-5.jsonl"
uv run --project lab lab lanes rounds $R
~~~

~~~text
                    run  jobs  short_%  mean_wait_s  p99_wait_s  long_mean_wait_s    work_s
-----------------------  ----  -------  -----------  ----------  ----------------  --------
        fifo s09-fifo-3  2945   62.886       21.881      46.735            21.727  1461.525
priority s09-priority-3  2945   62.784       11.708      36.980            20.577  1413.582
reserved s09-reserved-3  2946   62.729       11.925      37.895             3.358  1128.029
priority s09-priority-4  2993   64.116        1.666      11.906             4.212  1074.421
reserved s09-reserved-4  2991   64.059        7.698      24.241             1.937  1009.474
        fifo s09-fifo-4  2992   64.071        3.113      11.989             3.167  1109.591
reserved s09-reserved-5  2964   65.891       21.058      69.483             8.367  1266.361
        fifo s09-fifo-5  2963   65.778       10.349      22.467            10.358  1246.207
priority s09-priority-5  2964   65.688        1.229       7.599             3.135  1092.817
~~~

Read it round by round, because only arms within a round saw the same jobs. In every round **priority** beat FIFO: 21.9 to 11.7 s, 3.1 to 1.7 s, 10.3 to 1.2 s. **Reserved** lanes beat FIFO once and lost twice. And look across rounds: FIFO's mean wait was 21.9, 3.1 and 10.3 s for three seeds of the same workload, with 2,945 to 2,993 jobs each. At 83% busy, small differences in load and in the cluster make large ones in waiting, which is why every comparison here is within a round.

All rounds together, with intervals:

~~~bash
uv run --project lab lab lanes compare $R
~~~

~~~text
     arm  jobs_in  jobs  mean_wait_s  p50_wait_s  p99_wait_s  max_wait_s
--------  -------  ----  -----------  ----------  ----------  ----------
    fifo      all  8900       11.733       8.442      45.893      48.005
    fifo    short  5718       11.676       8.470      46.042      48.005
    fifo     long  3182       11.834       8.369      44.755      47.592
priority      all  8902        4.843       0.428      34.200      39.678
priority    short  5715        2.248       0.243      20.317      23.506
priority     long  3187        9.496       5.023      36.648      39.678
reserved      all  8901       13.546       9.502      65.270      70.575
reserved    short  5717       18.601      14.327      67.120      70.575
reserved     long  3184        4.469       3.622      14.053      33.168

The p90 as a promise: the share of jobs that finished within it
     arm   jobs  wait+run_%  run_alone_%
--------  -----  ----------  -----------
    fifo    all       8.618       90.921
    fifo  short       2.676       90.609
    fifo   long      19.296       91.483
priority    all       5.381       80.566
priority  short       4.672       80.612
priority   long       6.652       80.483
reserved    all      18.414       94.607
reserved  short       2.484       94.193
reserved   long      47.016       95.352

Mean wait against fifo, with 95% intervals (whole minutes resampled):
     arm   jobs  minus_fifo_s             95% CI
--------  -----  ------------  -----------------
priority    all        -6.890  -14.017 .. -0.811
priority  short        -9.429  -15.995 .. -4.032
priority   long        -2.338  -10.653 .. +5.221
reserved    all         1.813   -6.305 .. +9.229
reserved  short         6.925  -2.368 .. +15.798
reserved   long        -7.365  -13.860 .. -1.761
~~~

**Priority** cut the mean wait by 6.9 s (between 0.8 and 14.0 s), short jobs' by 9.4 s, and long jobs, the ones that could have starved, didn't: their mean fell too, by 2.3 s, not significantly. With shorter queues overall, even the jobs at the back got through sooner. On this workload strict priority didn't starve anyone. It would if short jobs arrived faster than the workers could run them, and nothing here guarantees they won't, so step 11 should watch long jobs' waits.

**Reserved** lanes did the opposite of what the simulation said: short jobs waited *longer* than with FIFO (18.6 s against 11.7), and long jobs less (4.5 against 11.8). Only the second is beyond noise, though: long jobs' interval, −13.9 to −1.8 s, is below zero, but short jobs' +6.9 s has an interval from −2.4 to +15.8, which includes it. Reserved lanes certainly didn't deliver the help for short jobs the simulation promised, but this experiment can't say they hurt them. (A first draft of this step said they did, and step 13's report caught it.) Was the short lane under-provisioned after all?

~~~text
run          short jobs' share of the work   their run time: predicted alone / actual (medians)
reserved-3                           18%   0.024 s / 0.098 s
reserved-4                           20%   0.024 s / 0.083 s
reserved-5                           19%   0.024 s / 0.103 s
fifo-3                               17%   0.024 s / 0.113 s
fifo-4                               20%   0.024 s / 0.102 s
fifo-5                               20%   0.024 s / 0.111 s
~~~

No: short jobs were 18 to 20% of the work, inside the lane's quarter of the slots, even though they ran about four times longer than their own size (step 6's contention: each shares a CPU with long jobs). On average the short lane had room. But arrivals come in bursts, about ten short jobs a second on average, and two slots that are 56 to 67% busy on average queue badly in a burst, with no way to borrow from the six long ones. Priority can use all eight. The simulation, replaying run times recorded under other conditions, missed both the bursts' effect on two servers and the contention. Its prediction for priority held; for reserved lanes, it didn't. The measurement decides.

The **p90 as a promise**: the run alone stayed within it for 81 to 95% of jobs; wait plus run, for 2 to 47%. A p90 of the run time is a promise about the run, and under queueing a tenant cares about the finish. An honest ETA needs a prediction of the wait too, which depends on the queue, the lane and the policy. That's the exercise.

The experiment's verdict goes into the chart: priority lanes at 50 ms are the default now (the values above). Put the autoscaler back:

~~~bash
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait \
  --set autoscaler.enabled=true --set lanes.shortMax=50ms --set lanes.mode=priority
~~~

### Break it: lanes that switch themselves off

My first version chose lanes by the run time the predictor expected, `RunS`, not the job's own size. It seems the obvious choice, and here's what it did. To reproduce it, make `Lanes.Short` use `job.Prediction.RunS` only. With that rule, the plan and the simulation (on step 5's data) said a threshold of 100 ms:

~~~bash
uv run --project lab lab lanes plan --by served
uv run --project lab lab lanes simulate results/s05-run2.jsonl results/s05-run3.jsonl --by served --threshold 0.1
~~~

~~~text
threshold_s  jobs_short_%  work_short_%  short_median_run_s
-----------  ------------  ------------  ------------------
      0.030        14.194         1.850               0.024
      0.050        38.455         7.143               0.032
      0.080        57.090        13.863               0.039
      0.100        65.875        18.239               0.043
      0.150        77.559        26.268               0.050
      0.200        83.818        32.551               0.054
~~~

~~~text
results/s05-run2.jsonl: 2314 jobs, 8 slots 36% busy
     arm  jobs_in  jobs  mean_wait_s  p50_wait_s  p99_wait_s  max_wait_s
--------  -------  ----  -----------  ----------  ----------  ----------
    fifo      all  2314        0.040       0.000       1.424       1.985
    fifo    short  1509        0.023       0.000       0.889       1.925
    fifo     long   805        0.073       0.000       1.636       1.985
priority      all  2314        0.028       0.000       1.262       1.822
priority    short  1509        0.004       0.000       0.133       0.287
priority     long   805        0.073       0.000       1.560       1.822
reserved      all  2314        0.086       0.000       2.444       3.354
reserved    short  1509        0.003       0.000       0.065       0.241
reserved     long   805        0.240       0.000       2.978       3.354

results/s05-run3.jsonl: 3438 jobs, 8 slots 67% busy
     arm  jobs_in  jobs  mean_wait_s  p50_wait_s  p99_wait_s  max_wait_s
--------  -------  ----  -----------  ----------  ----------  ----------
    fifo      all  3438        1.473       0.000      11.651      12.427
    fifo    short  1840        0.832       0.000      10.265      11.830
    fifo     long  1598        2.211       0.109      11.873      12.427
priority      all  3438        1.095       0.000      12.441      13.293
priority    short  1840        0.023       0.000       0.277       0.780
priority     long  1598        2.329       0.120      12.713      13.293
reserved      all  3438        2.957       0.000      23.313      23.771
reserved    short  1840        0.007       0.000       0.128       0.237
reserved     long  1598        6.352       2.638      23.430      23.771

~~~

Then I ran an experiment like the one above, at 100 ms, in two rounds: FIFO, priority, reserved with seed 41; reserved, priority, FIFO with seed 42:

~~~bash
R="fifo=results/s09-fifo-1.jsonl priority=results/s09-priority-1.jsonl reserved=results/s09-reserved-1.jsonl"
R="$R reserved=results/s09-reserved-2.jsonl priority=results/s09-priority-2.jsonl fifo=results/s09-fifo-2.jsonl"
uv run --project lab lab lanes rounds $R --by served --threshold 0.1
~~~

~~~text
                    run  jobs  short_%  mean_wait_s  p99_wait_s  long_mean_wait_s    work_s
-----------------------  ----  -------  -----------  ----------  ----------------  --------
        fifo s09-fifo-1  2816   39.844        1.314       4.647             1.687  1084.107
priority s09-priority-1  2817   17.714        2.875       6.473             3.455  1238.809
reserved s09-reserved-1  2817   26.021        2.133       7.633             2.808  1015.048
reserved s09-reserved-2  2904    7.025       12.216      40.206            13.130  1055.206
priority s09-priority-2  2902    8.132       10.662      39.190            11.590  1319.705
        fifo s09-fifo-2  2904    7.128       11.250      41.911            12.067  1365.606
~~~

Two things went wrong, and neither is in the simulation. First, look at `short_%`. The plan said two thirds of jobs would be short. Under FIFO in round 1, 40% were; in the lanes runs, 18 and 26%; in round 2, 7%. The model predicts run time *including contention*: `running_at_submit` and `queued_at_submit` are its features, and step 5 showed they matter. When a queue builds, every prediction grows, fewer jobs count as short, and the lanes do less. Lanes chosen by the expected run time switch themselves off at exactly the load they're for. It's a feedback loop: the decision changes the system, the system changes the features, the features change the decision. The simulation couldn't show it, because it replayed recorded predictions, made under different load.

Classify the same jobs by their own size, and the share is the same in every run, because it's a property of the job:

~~~bash
uv run --project lab lab lanes rounds $R --by alone --threshold 0.1
~~~

~~~text
                    run  jobs  short_%  mean_wait_s  p99_wait_s  long_mean_wait_s    work_s
-----------------------  ----  -------  -----------  ----------  ----------------  --------
        fifo s09-fifo-1  2816   81.925        1.314       4.647             1.312  1084.107
priority s09-priority-1  2817   81.931        2.875       6.473             3.172  1238.809
reserved s09-reserved-1  2817   81.896        2.133       7.633             2.506  1015.048
reserved s09-reserved-2  2904   81.267       12.216      40.206            12.184  1055.206
priority s09-priority-2  2902   81.254       10.662      39.190            10.020  1319.705
        fifo s09-fifo-2  2904   81.302       11.250      41.911            10.656  1365.606
~~~

Second, round 2. Seed 42 sends 3% more jobs than seed 41 (2,904 against 2,818), and every arm's mean wait rose from between 1.3 and 2.9 s to between 10.7 and 12.2 s. At 83% busy the system sits at the knee of the queueing curve, where a small increase in load makes a large one in waiting. Only comparisons within a round mean anything, and two rounds can't separate three policies from that noise. Hence the design above: lanes by own size (which needs `alone_s`, so the predictor, client and domain all change), a threshold planned by own size, and three rounds in a Latin square.

A model's best features for *predicting* aren't necessarily the right inputs for *deciding*. Contention helps predict how long a job will take. It's the wrong thing to sort jobs by, because sorting them changes it.

**Explain it:** why does shortest job first lower the mean wait, and what does it risk? What makes a scheduler work-conserving, and why did that decide between priority and reserved lanes? Why plan a lane by its share of the work, not of the jobs, and why wasn't that enough? What feedback loop switched the first lanes off, and why couldn't the simulation see it? Why does a job's lane have to depend on the job alone? Why must comparisons stay within a round? What did the broker's strict priority risk, and did it happen? Why is a p90 of the run time not an ETA?

**Read.** Mor Harchol-Balter, *Performance Modeling and Design of Computer Systems* (2013), chapters on scheduling (SRPT and the cost of priority to long jobs) and on the knee of the queueing curve. Adam Wierman and Bert Zwart, *Is Tail-Optimal Scheduling Possible?* (Operations Research, 2012), on what favouring short jobs does to the tail. The RabbitMQ documentation on quorum queue message priority. And Jeffrey Dean and Luiz Barroso, *The Tail at Scale* (2013) again, on why the slowest requests set the user's experience.

---
## Step 10: Models with a history

**The problem.** The model serving now was trained once, by hand, with `lab export`, and copied into a ConfigMap. Ask which data it learned from, which code made it, how it scored, what it replaced, or how to put back the one before, and the only answers are in your memory. Every later model raises one more question: is it actually better, or did it get lucky on the test set? This step gives models a history and a gate. Every training run is recorded, every model is versioned, one is the champion, and a challenger replaces it only when it's better beyond noise and no worse where it matters. Deployment and rollback become one command each. And the first thing the gate finds is that the model serving now has been badly wrong for a while.

**New ideas.**

- **Experiment tracking.** Each training run records its parameters, its data, its code, its environment and its scores, so any number in a report can be traced to what produced it. MLflow does this here, in a SQLite file and a folder: no server.
- **A model registry.** Each model that might serve gets a version number that never changes. **Aliases** are names that point at versions: `champion` serves, `previous` served before. Promoting and rolling back move aliases; nothing is rebuilt.
- **Reproducible training.** Same data, same code, same locked environment, same seed: same model. Record a fingerprint of each of the four, and prove it by retraining.
- **Champion and challenger.** The new model is compared with the serving one on the same, newest jobs, which neither trained on, job by job.
- **A gate beyond noise.** Promote only if the improvement's 95% interval is below zero (step 5's paired, minute-block bootstrap), and only if the guardrails hold: the p90 still covers what it did, and one prediction still fits the latency budget step 8 set. A point estimate alone promotes noise.
- **A model card.** What the model is for, what it learned from, how good it is on unseen data, where it's worst, the range of inputs it was trained on, and its known limits. Written by code from the run, so it can't drift from the facts.
- **Pull-based deployment.** The cluster doesn't build models. A deploy step copies the champion into the predictor's ConfigMap and restarts it; rollback is the same step after moving the alias back.

### A dependency that won't install

MLflow, as an optional extra like Spark and PyTorch. `uv add --optional mlops mlflow` *succeeds*, and installs MLflow 1.27, from 2022, which then fails to import. Every MLflow 3 requires `pyarrow` below 26, and step 3's `uv add pyarrow` wrote `pyarrow>=26.0.0`: "at least what was newest that day". uv found the only MLflow it could combine with that. Asking for `mlflow>=3` says why:

~~~text
      And because mlflow>=3.15.0 depends on pyarrow>=4.0.0,<26 and lab[mlops]
      depends on mlflow>=3, we can conclude that lab[mlops] depends on
      pyarrow>=4.0.0,<26.
      And because your project depends on pyarrow>=26.0.0 and your project
      requires lab[mlops], we can conclude that your project's requirements
      are unsatisfiable.
~~~

Nothing here needs pyarrow 26. A lower bound should say what the code needs, not what was newest; relax it, and ask for MLflow 3. In `lab/pyproject.toml`:

Change:

<!-- edit: lab/pyproject.toml -->
~~~toml
    "pyarrow>=26.0.0",
~~~

to:

~~~toml
    "pyarrow>=20",
~~~

Change:

<!-- edit: lab/pyproject.toml -->
~~~toml
    "torch>=2.0",
]
~~~

to:

~~~toml
    "torch>=2.0",
]
mlops = [
    "mlflow>=3.0",
]
~~~


<!-- run: cd lab && uv sync --extra mlops --extra deep -->

### Fitting, apart from saving

The registry needs to fit a model on a chosen slice of the data, with a chosen seed, and to know the range of each number it was trained on. In `lab/src/lab/export.py`:

Change:

<!-- edit: lab/src/lab/export.py -->
~~~python
def export(dataset_path: Path, out: Path, point_model: str = "trees") -> dict:
    """point_model: "trees" (step 6's, the most accurate) or "numpy" (step 7's network:
    nearly as accurate, and a hundred times cheaper to ask)."""
    data = dataset.load(dataset_path)
~~~

to:

~~~python
def fit(rows: dict, point_model: str = "trees", seed: int = 1) -> dict:
    """The two served models, fitted on rows, with what they are (no version yet).

    point_model: "trees" (step 6's, the most accurate) or "numpy" (step 7's
    network: nearly as accurate, and a hundred times cheaper to ask).
    """
~~~

Change:

<!-- edit: lab/src/lab/export.py -->
~~~python
        point = NumpyNet().fit(data)
~~~

to:

~~~python
        point = NumpyNet(seed=seed).fit(rows)
~~~

Change:

<!-- edit: lab/src/lab/export.py -->
~~~python
        point = Boosted("trees + history", CATEGORIES + NUMBERS).fit(data)
    bound = KindPowerLaw(contention=True, quantile=0.9).fit(data)
    newest = np.max(data["created_at"]).astype("datetime64[s]").astype(datetime)
    digest = hashlib.sha256(dataset_path.read_bytes()).hexdigest()[:8]
    artifact = {
        "format": FORMAT,
        "version": f"runtime-{point_model}-{newest:%Y%m%d-%H%M}-{digest}",
        "features": CATEGORIES + NUMBERS,
        "point": point,
~~~

to:

~~~python
        point = Boosted("trees + history", CATEGORIES + NUMBERS, random_state=seed).fit(rows)
    bound = KindPowerLaw(contention=True, quantile=0.9).fit(rows)
    newest = np.max(rows["created_at"]).astype("datetime64[s]").astype(datetime)
    # The range each number was trained on: outside it, a model is guessing,
    # and a network guesses in straight lines (step 10 found by how much).
    ranges = {n: [float(np.nanmin(rows[n])), float(np.nanmax(rows[n]))] for n in NUMBERS}
    return {
        "format": FORMAT,
        "features": CATEGORIES + NUMBERS,
        "ranges": ranges,
        "point": point,
~~~

Change:

<!-- edit: lab/src/lab/export.py -->
~~~python
        "rows": len(data["run_s"]),
~~~

to:

~~~python
        "rows": len(rows["run_s"]),
~~~

Change:

<!-- edit: lab/src/lab/export.py -->
~~~python
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(pickle.dumps(artifact))
    return artifact

~~~

to:

~~~python
    }


def export(dataset_path: Path, out: Path, point_model: str = "trees") -> dict:
    """Fit on every row of the dataset, and save it, named for the data."""
    artifact = fit(dataset.load(dataset_path), point_model)
    digest = hashlib.sha256(dataset_path.read_bytes()).hexdigest()[:8]
    until = datetime.fromisoformat(artifact["data_until"].rstrip("Z"))
    artifact["version"] = f"runtime-{point_model}-{until:%Y%m%d-%H%M}-{digest}"
    save(artifact, out)
    return artifact


def save(artifact: dict, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(pickle.dumps(artifact))

~~~


### The registry

Create `lab/src/lab/registry.py`:

<!-- file: lab/src/lab/registry.py -->
~~~python
"""Models with a history: every training run recorded, every model versioned, one champion.

MLflow keeps three things here, in mlflow/ beside the data (a SQLite file
and a folder of artifacts; no server needed). Runs: what was trained, on
which data, with which code, and how it scored. The registry: the model
from each run that might serve, numbered 1, 2, 3... Aliases: names that
point at a version, so "champion" is whatever serves now and "previous" is
what served before it. Promoting moves an alias; rolling back moves it
back; deploying copies the champion to the cluster. A version, once made,
never changes.

Install it with the project's mlops extra: uv sync --extra mlops.
"""

import hashlib
import os
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from lab import dataset, export, metrics
from lab.evaluate import load_band
from lab.warehouse import table

NAME = "runway-runtime"  # the registered model
EXPERIMENT = "runtime"
LAB = Path(__file__).parents[2]  # lab/: its code and lock file are part of a model's version

Rows = dict[str, np.ndarray]


def client(root: Path = Path("mlflow")):
    """Point MLflow at root's SQLite file and artifact folder, and return its client."""
    os.environ.setdefault("MLFLOW_DISABLE_AGENT_HINT", "1")
    import mlflow
    from mlflow import MlflowClient

    root = root.absolute()
    root.mkdir(parents=True, exist_ok=True)
    mlflow.set_tracking_uri(f"sqlite:///{root / 'mlflow.db'}")
    if mlflow.get_experiment_by_name(EXPERIMENT) is None:
        mlflow.create_experiment(EXPERIMENT, artifact_location=(root / "artifacts").as_uri())
    mlflow.set_experiment(EXPERIMENT)
    return MlflowClient()


def digest(paths: list[Path]) -> str:
    """One hash of several files' contents, in a fixed order."""
    h = hashlib.sha256()
    for p in sorted(paths):
        h.update(p.relative_to(LAB).as_posix().encode())
        h.update(p.read_bytes())
    return h.hexdigest()[:12]


def code_version() -> str:
    return digest(sorted((LAB / "src").glob("**/*.py")))


def lock_version() -> str:
    return digest([LAB / "uv.lock"])


def data_version(rows: Rows) -> str:
    """A hash of exactly the rows trained on: which jobs, when, how long, their features."""
    h = hashlib.sha256()
    for name in ["job_id", "created_at", "run_s", *dataset.FEATURES]:
        h.update(np.ascontiguousarray(rows[name]).astype(str).tobytes())
    return h.hexdigest()[:12]


def rows_between(data: Rows, start=None, end=None) -> Rows:
    created = data["created_at"]
    mask = np.ones(len(created), bool)
    if start is not None:
        mask &= created >= np.datetime64(start)
    if end is not None:
        mask &= created < np.datetime64(end)
    return {k: v[mask] for k, v in data.items()}


class RuntimeModel:
    """MLflow's wrapper for our artifact: it travels as the file lab export writes."""

    @staticmethod
    def python_model():
        import mlflow.pyfunc
        import pandas as pd

        class Model(mlflow.pyfunc.PythonModel):
            def load_context(self, context):
                self.artifact = export.load(Path(context.artifacts["runtime"]))

            def predict(self, context, model_input: pd.DataFrame) -> list[float]:
                rows = {c: model_input[c].to_numpy() for c in model_input.columns}
                return self.artifact["point"].predict(rows).tolist()

        return Model()


def train(rows: Rows, point: str, seed: int, note: str = "") -> str:
    """Fit on rows, record the run, register the model; return its version number."""
    import mlflow

    artifact = export.fit(rows, point, seed)
    versions = {"data": data_version(rows), "code": code_version(), "lock": lock_version()}
    artifact["version"] = f"runtime-{point}-{versions['data'][:8]}-s{seed}"
    with tempfile.TemporaryDirectory() as tmp, mlflow.start_run(run_name=artifact["version"]):
        path = Path(tmp) / "runtime.pkl"
        export.save(artifact, path)
        mlflow.log_params({"point": point, "seed": seed, "rows": artifact["rows"]})
        mlflow.log_params({"data_until": artifact["data_until"]})
        mlflow.set_tags({f"{k}_version": v for k, v in versions.items()} | {"note": note})
        info = mlflow.pyfunc.log_model(
            name="runtime",
            python_model=RuntimeModel.python_model(),
            artifacts={"runtime": str(path)},
            registered_model_name=NAME,
        )
    return str(info.registered_model_version)


def adopt(path: Path, note: str) -> str:
    """Register a model trained before the registry existed, as it is."""
    import mlflow

    artifact = export.load(path)
    with tempfile.TemporaryDirectory() as tmp, mlflow.start_run(run_name=artifact["version"]):
        copy = Path(tmp) / "runtime.pkl"  # the same name every version's file has
        copy.write_bytes(path.read_bytes())
        mlflow.log_params({"rows": artifact["rows"], "data_until": artifact["data_until"]})
        mlflow.set_tags({"note": note, "adopted_from": path.name})
        info = mlflow.pyfunc.log_model(
            name="runtime",
            python_model=RuntimeModel.python_model(),
            artifacts={"runtime": str(copy)},
            registered_model_name=NAME,
        )
    return str(info.registered_model_version)


def fetch(client, ref: str) -> tuple[str, dict]:
    """A version (a number, or an alias such as champion): its number, and its artifact."""
    import mlflow

    mv = (
        client.get_model_version(NAME, ref)
        if ref.isdigit()
        else client.get_model_version_by_alias(NAME, ref)
    )
    with tempfile.TemporaryDirectory() as tmp:
        where = mlflow.artifacts.download_artifacts(f"models:/{NAME}/{mv.version}", dst_path=tmp)
        found = next(Path(where).glob("**/artifacts/*.pkl"))
        return str(mv.version), export.load(found)


@dataclass
class Scores:
    errors: np.ndarray  # |log(predicted / actual)| per job
    covered: float  # the share within the p90
    latency_ms: float  # one prediction, median of many
    factor: float  # typical factor off


def score(artifact: dict, rows: Rows) -> Scores:
    y = rows["run_s"]
    pred = artifact["point"].predict(rows)
    bound = artifact["bound"].predict(rows)
    one = {k: v[:1] for k, v in rows.items()}
    times = []
    for _ in range(100):
        start = time.perf_counter()
        artifact["point"].predict(one)
        times.append(time.perf_counter() - start)
    errors = np.abs(np.log(pred / y))
    return Scores(
        errors, metrics.coverage(y, bound), np.median(times) * 1e3, float(np.exp(errors.mean()))
    )


@dataclass
class Gate:
    """What a challenger must do to replace the champion."""

    budget_ms: float = 1.0  # one prediction, in-process: step 8's lesson
    coverage_drop: float = 0.02  # the p90 may cover at most 2 points less


def judge(champion: Scores, challenger: Scores, rows: Rows, gate: Gate) -> tuple[bool, str]:
    """Better beyond noise, and no worse where it matters; the reasons, either way."""
    minutes = rows["created_at"].astype("datetime64[m]").astype(np.int64)
    diff, low, high = metrics.paired_bootstrap(champion.errors, challenger.errors, minutes)
    checks = [
        (
            high < 0,
            f"log error {diff:+.4f} (95% CI {low:+.4f} .. {high:+.4f}): better beyond noise",
        ),
        (
            challenger.covered >= champion.covered - gate.coverage_drop,
            f"p90 covers {challenger.covered:.1%} (champion {champion.covered:.1%},"
            f" may drop {gate.coverage_drop:.0%})",
        ),
        (
            challenger.latency_ms <= gate.budget_ms,
            f"one prediction {challenger.latency_ms:.3f} ms (budget {gate.budget_ms:g} ms)",
        ),
    ]
    lines = [f"  {'pass' if ok else 'FAIL'}  {why}" for ok, why in checks]
    return all(ok for ok, _ in checks), "\n".join(lines)


def card(version: str, artifact: dict, run, scores: Scores, rows: Rows) -> str:
    """The model card: what it is, what it learned from, how good it is, and where it fails."""
    y, pred = rows["run_s"], artifact["point"].predict(rows)
    slices = []
    for by, values in [("kind", rows["kind"]), ("load", load_band(rows["running_at_submit"]))]:
        for v in np.unique(values):
            m = values == v
            slices.append([by, v, int(m.sum()), metrics.log_error(y[m], pred[m])])
    tags, params = run.data.tags, run.data.params
    worst = max(slices, key=lambda r: r[3])
    trained = artifact.get("ranges", {})
    ranges = [
        [n, *trained.get(n, ["?", "?"]), float(np.nanmax(rows[n]))]
        for n in ("size", "running_at_submit", "queued_at_submit", "tenant_recent")
    ]
    return f"""# Model card: {NAME} version {version} ({artifact["version"]})

**What it does.** Predicts how long a Runway job will run, when it's submitted:
a typical time (the point model) and a time nine jobs in ten finish within (the
p90 bound). Used for the job's lane (step 9) and shown to the tenant.

**Trained on.** {artifact["rows"]} finished jobs, up to {artifact["data_until"]}.
Data version {tags.get("data_version", "?")}, code version {tags.get("code_version", "?")},
locked environment {tags.get("lock_version", "?")}, point model {params.get("point", "?")},
seed {params.get("seed", "?")}. Retraining with the same four gives the same model.

**Features.** {", ".join(artifact["features"])}: what the API knows at submission,
counted from the job events as the API recorded them (step 8).

**How good, on {len(y)} jobs it never saw.** Typically off by a factor of
{scores.factor:.3f}; the p90 covered {scores.covered:.1%}; one prediction takes
{scores.latency_ms:.3f} ms.

{table(["slice", "value", "jobs", "log_factor"], slices)}

**Operating range.** The numbers it was trained on; outside them it extrapolates,
and a network extrapolates in straight lines without limit.

{table(["feature", "trained_from", "to", "here_max"], ranges)}

**Known limits.**
- Worst slice here: {worst[0]} {worst[1]}, typically off by {worst[3]:.3f}.
- Served features lag the batch's by the outbox and Kafka; it cost about 2% live (step 8).
- The p90 is about the run, not the wait: under queueing it's no finishing time (step 9).
- A tenant or kind never seen in training gets a prediction from the others' patterns.
- Trained on one cluster's machines: new hardware changes every run time.
"""


def deploy(client, ref: str = "champion", namespace: str = "runway") -> str:
    """Copy a version's artifact into the predictor's ConfigMap and restart it on it."""
    version, artifact = fetch(client, ref)
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "runtime.pkl"
        export.save(artifact, path)
        made = subprocess.run(
            [
                "kubectl",
                "-n",
                namespace,
                "create",
                "configmap",
                "predictor-model",
                f"--from-file=runtime.pkl={path}",
                "--dry-run=client",
                "-o",
                "yaml",
            ],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["kubectl", "apply", "--server-side", "--field-manager=lab", "-f", "-"],
            input=made.stdout,
            check=True,
            capture_output=True,
        )
    for cmd in (
        ["rollout", "restart", "deploy/predictor"],
        ["rollout", "status", "deploy/predictor", "--timeout=5m"],
    ):
        subprocess.run(["kubectl", "-n", namespace, *cmd], check=True, capture_output=True)
    return f"version {version} ({artifact['version']}) is serving"


def alias(client, name: str) -> str | None:
    """The version an alias points at, or None."""
    try:
        return str(client.get_model_version_by_alias(NAME, name).version)
    except Exception:  # MLflow raises a generic error for an unknown alias
        return None


def promote(client, version: str) -> str:
    """version becomes champion; the champion until now becomes previous."""
    current = alias(client, "champion")
    if current:
        client.set_registered_model_alias(NAME, "previous", current)
    client.set_registered_model_alias(NAME, "champion", version)
    return f"champion: version {version} (previous: {current})"


def rollback(client) -> str:
    """Swap champion and previous: the model that served before serves again."""
    champion, previous = alias(client, "champion"), alias(client, "previous")
    if previous is None:
        raise RuntimeError("no previous version to roll back to")
    client.set_registered_model_alias(NAME, "champion", previous)
    client.set_registered_model_alias(NAME, "previous", champion)
    return f"champion: version {previous} (previous: {champion})"


def listing(client) -> str:
    """Every version: its name, its tags, and which aliases point at it."""
    aliases: dict[str, list[str]] = {}
    for name in ("champion", "previous"):
        v = alias(client, name)
        if v:
            aliases.setdefault(v, []).append(name)
    out = []
    for mv in sorted(client.search_model_versions(f"name='{NAME}'"), key=lambda m: int(m.version)):
        run = client.get_run(mv.run_id)
        out.append(
            [
                mv.version,
                run.info.run_name,
                run.data.params.get("rows", ""),
                run.data.tags.get("data_version", "-"),
                run.data.tags.get("note", ""),
                ",".join(aliases.get(str(mv.version), [])),
            ]
        )
    return table(["version", "model", "rows", "data", "note", "aliases"], out)
~~~

Read it in this order:

- `client` points MLflow at `mlflow/mlflow.db` and `mlflow/artifacts`.
- `data_version`, `code_version` and `lock_version` are the fingerprints: a hash of exactly the rows trained on (job IDs, times, run times, features); of every file in `lab/src`; and of `uv.lock`.
- `train` fits, records the run (parameters, the three fingerprints as tags, a note), and logs the model so that MLflow registers it as the next version. `adopt` registers a model made before the registry existed, as it is.
- `fetch` downloads a version's file, by number or by alias.
- `score` measures a model on rows: each job's error, coverage, and one prediction's latency. `judge` is the gate.
- `card` writes the model card. `promote`, `rollback` and `deploy` move aliases and copy the champion into the cluster.

### Tests

The tests use a throwaway registry in a temporary directory, and step 6's synthetic jobs. They check five things:

- Retraining reproduces a model exactly.
- The gate refuses a copy of the champion, and refuses a model whose average is better only by noise.
- A better model passes, and fails a latency budget it can't meet.
- Promotion and rollback move the aliases, and `list` shows them.
- The card shows the training range and the worst slice.

Create `lab/tests/test_registry.py`:

<!-- file: lab/tests/test_registry.py -->
~~~python
import numpy as np
import pytest

pytest.importorskip("mlflow")

from test_model import jobs  # noqa: E402

from lab import registry  # noqa: E402


def rows(n: int, seed: int, start: str) -> dict:
    r = jobs(n, seed)
    r["job_id"] = np.arange(n) + seed * 100_000
    r["created_at"] = np.datetime64(start) + np.arange(n) * np.timedelta64(1, "s")
    return r


@pytest.fixture
def client(tmp_path):
    return registry.client(tmp_path / "mlflow")


TRAIN = rows(3_000, 1, "2026-10-18T00:00:00")
HOLDOUT = rows(1_500, 2, "2026-10-18T02:00:00")


def test_the_same_inputs_make_the_same_model(client):
    a = registry.train(TRAIN, "numpy", seed=1)
    b = registry.train(TRAIN, "numpy", seed=1)
    (_, art_a), (_, art_b) = registry.fetch(client, a), registry.fetch(client, b)
    assert np.array_equal(art_a["point"].predict(HOLDOUT), art_b["point"].predict(HOLDOUT))
    tags_a = client.get_run(client.get_model_version(registry.NAME, a).run_id).data.tags
    tags_b = client.get_run(client.get_model_version(registry.NAME, b).run_id).data.tags
    for key in ("data_version", "code_version", "lock_version"):
        assert tags_a[key] == tags_b[key]


def test_other_data_is_another_data_version():
    assert registry.data_version(TRAIN) != registry.data_version(HOLDOUT)


def test_a_model_no_better_than_the_champion_is_not_promoted(client):
    v1 = registry.train(TRAIN, "numpy", seed=1)
    v2 = registry.train(TRAIN, "numpy", seed=1)  # the same model again
    s1 = registry.score(registry.fetch(client, v1)[1], HOLDOUT)
    s2 = registry.score(registry.fetch(client, v2)[1], HOLDOUT)
    ok, why = registry.judge(s1, s2, HOLDOUT, registry.Gate())
    assert not ok and "FAIL  log error" in why


def test_a_better_model_passes_and_a_slow_one_fails(client):
    weak = registry.train(registry.rows_between(TRAIN, end="2026-10-18T00:01:40"), "numpy", 1)
    strong = registry.train(TRAIN, "numpy", seed=1)
    s_weak = registry.score(registry.fetch(client, weak)[1], HOLDOUT)
    s_strong = registry.score(registry.fetch(client, strong)[1], HOLDOUT)
    ok, why = registry.judge(s_weak, s_strong, HOLDOUT, registry.Gate())
    assert ok, why
    ok, why = registry.judge(s_weak, s_strong, HOLDOUT, registry.Gate(budget_ms=1e-6))
    assert not ok and "FAIL  one prediction" in why


def test_promotion_and_rollback_move_the_aliases(client):
    v1 = registry.train(TRAIN, "numpy", seed=1)
    v2 = registry.train(TRAIN, "numpy", seed=2)
    registry.promote(client, v1)
    registry.promote(client, v2)
    assert (registry.alias(client, "champion"), registry.alias(client, "previous")) == (v2, v1)
    registry.rollback(client)
    assert (registry.alias(client, "champion"), registry.alias(client, "previous")) == (v1, v2)
    rows = {line.split()[0]: line.split()[-1] for line in registry.listing(client).splitlines()[2:]}
    assert (rows[v1], rows[v2]) == ("champion", "previous")


def test_rolling_back_with_nothing_before_is_refused(client):
    registry.promote(client, registry.train(TRAIN, "numpy", seed=1))
    with pytest.raises(RuntimeError, match="no previous version"):
        registry.rollback(client)


def test_a_better_average_within_noise_is_not_enough():
    rng = np.random.default_rng(3)
    champion = rng.lognormal(-1, 1, 2_000)
    noise = rng.normal(0, 0.2, 2_000)
    challenger = champion + (noise - noise.mean()) - 0.002  # a hair better on average, very noisy
    rows = {
        "created_at": np.datetime64("2026-10-18T00:00") + np.arange(2_000) * np.timedelta64(30, "s")
    }
    s1 = registry.Scores(champion, 0.9, 0.1, 1.0)
    s2 = registry.Scores(challenger, 0.9, 0.1, 1.0)
    assert challenger.mean() < champion.mean(), "the point estimate says better"
    ok, why = registry.judge(s1, s2, rows, registry.Gate())
    assert not ok and "FAIL  log error" in why


def test_the_card_says_where_the_model_was_trained_and_where_it_is_worst(client):
    v = registry.train(TRAIN, "numpy", seed=1)
    _, artifact = registry.fetch(client, v)
    run = client.get_run(client.get_model_version(registry.NAME, v).run_id)
    text = registry.card(v, artifact, run, registry.score(artifact, HOLDOUT), HOLDOUT)
    lo, hi = artifact["ranges"]["running_at_submit"]
    assert (lo, hi) == (0.0, 9.0)  # jobs() draws 0 to 9
    assert "Operating range" in text and "Worst slice here:" in text
~~~

Add the command, in `lab/src/lab/cli.py`:

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

def cmd_export(args: argparse.Namespace) -> int:
~~~

to:

~~~python

def cmd_mlops(args: argparse.Namespace) -> int:
    import numpy as np

    from lab import dataset, registry
    from lab.warehouse import table

    client = registry.client(args.root)
    a = args.action
    if a == "list":
        print(registry.listing(client))
        return 0
    if a == "adopt":
        print(f"version {registry.adopt(args.file, args.note)}")
        return 0
    if a == "rollback":
        print(registry.rollback(client))
        return 0
    if a == "deploy":
        print(registry.deploy(client, args.version or "champion"))
        return 0
    data = dataset.load(args.dataset)
    if a == "train":
        rows = registry.rows_between(data, end=args.until)
        print(f"version {registry.train(rows, args.point, args.seed, args.note)}")
        return 0
    holdout = registry.rows_between(data, start=args.holdout_from)
    if a == "card":
        version, artifact = registry.fetch(client, args.version)
        run = client.get_run(client.get_model_version(registry.NAME, version).run_id)
        text = registry.card(version, artifact, run, registry.score(artifact, holdout), holdout)
        client.log_text(run.info.run_id, text, "model_card.md")
        print(text)
        return 0
    # gate or promote: the challenger against the champion, on jobs neither trained on
    if registry.alias(client, "champion") is None:
        print("no champion yet: nothing to beat")
        if a == "promote":
            print(registry.promote(client, args.version))
        return 0
    champion_v, champion = registry.fetch(client, "champion")
    challenger_v, challenger = registry.fetch(client, args.version)
    for name, art in (("champion", champion), ("challenger", challenger)):
        until = np.datetime64(art["data_until"].rstrip("Z"))
        if holdout["created_at"].min() < until:
            print(f"the {name} trained on jobs up to {until}: start the holdout after that")
            return 2
    scores = {
        v: registry.score(art, holdout)
        for v, art in ((champion_v, champion), (challenger_v, challenger))
    }
    rows = [
        [f"{role} v{v}", art["version"], s.factor, s.covered * 100, s.latency_ms]
        for role, v, art, s in (
            ("champion", champion_v, champion, scores[champion_v]),
            ("challenger", challenger_v, challenger, scores[challenger_v]),
        )
    ]
    print(f"{len(holdout['run_s'])} jobs from {args.holdout_from} on, which neither trained on")
    print(table(["", "model", "log_factor", "p90_covers_%", "one_ms"], rows))
    ok, why = registry.judge(scores[champion_v], scores[challenger_v], holdout, registry.Gate())
    print(why)
    if not ok:
        print(f"version {challenger_v} stays a challenger")
        return 1
    if a == "promote":
        print(registry.promote(client, challenger_v))
    else:
        print(f"version {challenger_v} may be promoted")
    return 0


def cmd_export(args: argparse.Namespace) -> int:
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

    ex = sub.add_parser("export", help="fit the served models on every row and save them")
~~~

to:

~~~python

    ml = sub.add_parser("mlops", help="train, register, gate, promote, roll back, deploy")
    ml.add_argument(
        "action",
        choices=["list", "adopt", "train", "gate", "promote", "rollback", "deploy", "card"],
    )
    ml.add_argument("version", nargs="?", help="a version number, or an alias such as champion")
    ml.add_argument("--root", type=Path, default=Path("mlflow"), help="MLflow's database and files")
    ml.add_argument("--dataset", type=Path, default=Path("results/dataset.parquet"))
    ml.add_argument("--file", type=Path, help="adopt: a model file made by lab export")
    ml.add_argument("--until", help="train: on jobs created before this time")
    ml.add_argument("--holdout-from", help="gate, promote, card: score on jobs from this time")
    ml.add_argument("--point", choices=["trees", "numpy"], default="numpy")
    ml.add_argument("--seed", type=int, default=1)
    ml.add_argument("--note", default="", help="why this version exists")
    ml.set_defaults(func=cmd_mlops)

    ex = sub.add_parser("export", help="fit the served models on every row and save them")
~~~


MLflow's files stay out of Git and the image. In `.gitignore`:

Add this at the end of the file:

<!-- append: .gitignore -->
~~~text
# MLflow's runs and registry (Phase 7, step 10): a database and artifacts.
mlflow/
~~~


In `.dockerignore`:

Change:

<!-- edit: .dockerignore -->
~~~text
models
bin
~~~

to:

~~~text
models
mlflow
bin
~~~


<!-- run: cd lab && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

### CI for the Python

The workflow tests the Go code, and has never tested `lab` or `kload`. Add a job, beside `test`, which the image waits for too. In `.github/workflows/ci.yml`:

Change:

<!-- edit: .github/workflows/ci.yml -->
~~~yaml

  # Build once. The smoke test and the publish job both use this exact
~~~

to:

~~~yaml

  # Phase 7: the Python projects, lab and kload. Their tests use no
  # services: the ones that need MLflow or PyTorch get them from their
  # extras, and the ones that need data make their own.
  python:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: astral-sh/setup-uv@v10
      - name: Test lab
        working-directory: lab
        run: |
          uv sync --locked --extra mlops --extra deep
          uv run ruff format --check .
          uv run ruff check .
          uv run pytest -q
      - name: Test kload
        working-directory: kload
        run: |
          uv sync --locked
          uv run ruff format --check .
          uv run ruff check .
          uv run pytest -q

  # Build once. The smoke test and the publish job both use this exact
~~~

Change:

<!-- edit: .github/workflows/ci.yml -->
~~~yaml
    needs: test
~~~

to:

~~~yaml
    needs: [test, python]
~~~


`--locked` fails if `uv.lock` doesn't match `pyproject.toml`, instead of quietly re-resolving: CI tests exactly the environment you locked. Check the workflow with `actionlint .github/workflows/ci.yml`, then push it (**run on GitHub**): a fourth job, `python`, should pass, running the same commands that pass on your machine; installing PyTorch's CPU build takes most of its time. This CI tests the *code*. It can't train or gate a model, because the data lives on your machine and your cluster: the gate runs where the data is, below.

### Run it: the first champion

Adopt the model serving now, from step 8, as version 1, and make it the champion. Nothing to beat yet:

~~~bash
mlops() { uv run --project lab lab mlops "$@"; }
mlops adopt --file models/runtime-numpy.pkl --note "served since step 8"
mlops promote 1
~~~

~~~text
2026/10/18 02:40:25 INFO mlflow.store.db.utils: Creating initial MLflow database tables...
2026/10/18 02:40:25 INFO mlflow.store.db.utils: Updating database tables
2026/10/18 02:40:32 WARNING mlflow.pyfunc: Passing a Python object as `python_model` causes it to be serialized using CloudPickle, it requires exercising caution as Python object serialization mechanisms may execute arbitrary code during deserialization.Consider using a file path (str or Path) instead. See https://mlflow.org/docs/latest/ml/model/models-from-code/ for details.
2026/10/18 02:40:32 WARNING mlflow.pyfunc: Failed to infer model signature: Type hint <input: <class 'pandas.DataFrame'>, output: list[float]> cannot be used to infer model signature and input example is not provided, model signature cannot be inferred.
2026/10/18 02:40:40 WARNING mlflow.utils.environment: Failed to resolve installed pip version. ``pip`` will be added to conda.yaml environment spec without a version specifier.
Successfully registered model 'runway-runtime'.
Created version '1' of model 'runway-runtime'.
version 1
~~~

~~~text
no champion yet: nothing to beat
champion: version 1 (previous: None)
~~~

MLflow warns as it logs: about the Python object it pickles (unpickling runs code, which is why `export.load` says to load only files you made, and why the registry should be writable only by you), about the model's signature (it can't infer one from a DataFrame type hint, and the service checks its own inputs anyway), and about pip (uv installed this environment, not pip). The warnings on the following runs are the same.

### Run it: a challenger

Hold out the newest jobs: step 9's second experiment, from 01:40 on. Train a challenger on everything before them, and gate it against the champion on them:

~~~bash
H=2026-10-18T01:40:00   # your experiment 2's start
mlops train --until $H --note "every job before the holdout"
mlops gate 2 --holdout-from $H
~~~

~~~text
2026/10/18 02:41:03 WARNING mlflow.pyfunc: Passing a Python object as `python_model` causes it to be serialized using CloudPickle, it requires exercising caution as Python object serialization mechanisms may execute arbitrary code during deserialization.Consider using a file path (str or Path) instead. See https://mlflow.org/docs/latest/ml/model/models-from-code/ for details.
2026/10/18 02:41:03 WARNING mlflow.pyfunc: Failed to infer model signature: Type hint <input: <class 'pandas.DataFrame'>, output: list[float]> cannot be used to infer model signature and input example is not provided, model signature cannot be inferred.
2026/10/18 02:41:10 WARNING mlflow.utils.environment: Failed to resolve installed pip version. ``pip`` will be added to conda.yaml environment spec without a version specifier.
Registered model 'runway-runtime' already exists. Creating a new version of this model...
Created version '2' of model 'runway-runtime'.
version 2
~~~

~~~text
26703 jobs from 2026-10-18T01:40:00 on, which neither trained on
                                              model  log_factor  p90_covers_%  one_ms
-------------  ------------------------------------  ----------  ------------  ------
  champion v1  runtime-numpy-20261017-2316-c0e7da40       4.442        70.251   0.098
challenger v2             runtime-numpy-c9eb62a5-s1       1.436        85.657   0.094
  pass  log error -1.1296 (95% CI -1.5775 .. -0.7130): better beyond noise
  pass  p90 covers 85.7% (champion 70.3%, may drop 2%)
  pass  one prediction 0.094 ms (budget 1 ms)
version 2 may be promoted
~~~

The challenger passes every check, and by a margin that's hard to believe. The champion, the model that's been serving, is typically off by a factor of **4.4** on these jobs, and its p90 covers only 70%. Something is badly wrong, and it isn't the challenger. Look at the inputs:

~~~bash
uv run --project lab python - <<'PY'
from pathlib import Path
import numpy as np
from lab import dataset, export, registry
d = dataset.load(Path("results/dataset.parquet"))
v1 = export.load(Path("models/runtime-numpy.pkl"))
trained = registry.rows_between(d, end=v1["data_until"].rstrip("Z"))
holdout = registry.rows_between(d, start="2026-10-18T01:40:00")
q, t = holdout["queued_at_submit"], trained["queued_at_submit"]
print(f"queued_at_submit: version 1 trained on at most {t.max()}; the holdout's median {np.median(q):.0f}, max {q.max()}")
ratio = v1["point"].predict(holdout) / holdout["run_s"]
for lo, hi in [(0, 10), (10, 50), (50, 150), (150, None)]:
    m = (q >= lo) & (q < (hi or np.inf))
    print(f"  queued {lo:>3} to {hi or 'more':<4}: {m.sum():>5} jobs, predicted / actual: median {np.median(ratio[m]):6.2f}, max {ratio[m].max():8.1f}")
PY
~~~

~~~text
queued_at_submit: version 1 trained on at most 92; the holdout's median 118, max 536
  queued   0 to 10  :  2657 jobs, predicted / actual: median   0.83, max      3.3
  queued  10 to 50  :  6491 jobs, predicted / actual: median   1.00, max      5.5
  queued  50 to 150 :  5940 jobs, predicted / actual: median   2.02, max     14.5
  queued 150 to more: 11615 jobs, predicted / actual: median  11.05, max   2631.6
~~~

Step 9's experiment held the workers at two and ran them at 83% busy, so queues reached hundreds of jobs: a median of 118, a maximum of 536. Version 1 had never seen more than 92. A tree would have treated 536 like the largest value it knew; a ReLU network extrapolates in straight lines, so its predictions grew with the queue without limit: eleven times too long at the median beyond 150 queued, and once 2,631 times too long. The predictions and p90s stored for jobs submitted behind long queues in step 9's experiment 2 were wrong in that way. (The lanes weren't: they use `alone_s`, with the queue set to zero.) Nothing alerted, because nothing was watching the inputs. That's step 11. The challenger trained on step 9's first experiment, which saturated too, so it knows that range.

### Run it: promote, card, deploy

~~~bash
mlops promote 2 --holdout-from $H
mlops card 2 --holdout-from $H > models/card-v2.md
mlops deploy
~~~

~~~text
26703 jobs from 2026-10-18T01:40:00 on, which neither trained on
                                              model  log_factor  p90_covers_%  one_ms
-------------  ------------------------------------  ----------  ------------  ------
  champion v1  runtime-numpy-20261017-2316-c0e7da40       4.442        70.251   0.096
challenger v2             runtime-numpy-c9eb62a5-s1       1.436        85.657   0.096
  pass  log error -1.1296 (95% CI -1.5775 .. -0.7130): better beyond noise
  pass  p90 covers 85.7% (champion 70.3%, may drop 2%)
  pass  one prediction 0.096 ms (budget 1 ms)
champion: version 2 (previous: 1)
~~~

~~~text
version 2 (runtime-numpy-c9eb62a5-s1) is serving
~~~

The card, also logged to the run in MLflow:

~~~markdown
# Model card: runway-runtime version 2 (runtime-numpy-c9eb62a5-s1)

**What it does.** Predicts how long a Runway job will run, when it's submitted:
a typical time (the point model) and a time nine jobs in ten finish within (the
p90 bound). Used for the job's lane (step 9) and shown to the tenant.

**Trained on.** 63111 finished jobs, up to 2026-10-18T01:25:20Z.
Data version c9eb62a5e2a6, code version 48fa71b6795f,
locked environment fd508dfe4d29, point model numpy,
seed 1. Retraining with the same four gives the same model.

**Features.** tenant, kind, size, running_at_submit, queued_at_submit, tenant_recent, history_log_run: what the API knows at submission,
counted from the job events as the API recorded them (step 8).

**How good, on 26703 jobs it never saw.** Typically off by a factor of
1.436; the p90 covered 85.7%; one prediction takes
0.108 ms.

slice     value   jobs  log_factor
-----  --------  -----  ----------
 kind  checksum  15323       1.486
 kind  compress   4635       1.317
 kind      sort   6745       1.409
 load       0-1    558       1.474
 load       2-3   1399       1.557
 load       4-5   6512       1.468
 load        6+  18234       1.414

**Operating range.** The numbers it was trained on; outside them it extrapolates,
and a network extrapolates in straight lines without limit.

          feature  trained_from             to       here_max
-----------------  ------------  -------------  -------------
             size         0.000  268435456.000  268435456.000
running_at_submit         0.000         26.000          8.000
 queued_at_submit         0.000        746.000        536.000
    tenant_recent         0.000        750.000        659.000

**Known limits.**
- Worst slice here: load 2-3, typically off by 1.557.
- Served features lag the batch's by the outbox and Kafka; it cost about 2% live (step 8).
- The p90 is about the run, not the wait: under queueing it's no finishing time (step 9).
- A tenant or kind never seen in training gets a prediction from the others' patterns.
- Trained on one cluster's machines: new hardware changes every run time.

~~~

Its operating range is the lesson of version 1, written down: trained on queues up to 746, and the newest jobs reach 536, inside it. When the inputs leave that range, the card says what to expect. And which model answers the API now? Create five jobs:

~~~bash
serving() {
  for i in 1 2 3 4 5; do
    curl -s -X POST localhost:8000/jobs -H "Authorization: Bearer $ACME_TOKEN" -H 'Content-Type: application/json' \
      -d '{"description":"pack","kind":"compress","size":8000000}' | jq -r '.prediction.model // "no prediction"'
    sleep 1
  done
}
serving
~~~

~~~text
runtime-numpy-c9eb62a5-s1
runtime-numpy-c9eb62a5-s1
runtime-numpy-c9eb62a5-s1
runtime-numpy-c9eb62a5-s1
runtime-numpy-c9eb62a5-s1
~~~

### Run it: is it reproducible?

Train version 2 again, with exactly the same inputs, and compare:

~~~bash
mlops train --until $H --note "version 2 again: the same inputs"
uv run --project lab python - <<'PY'
from pathlib import Path
import numpy as np
from lab import dataset, registry
client = registry.client(Path("mlflow"))
d = registry.rows_between(dataset.load(Path("results/dataset.parquet")), start="2026-10-18T01:40:00")
(_, a), (_, b) = registry.fetch(client, "2"), registry.fetch(client, "3")
pa, pb = a["point"].predict(d), b["point"].predict(d)
print(f"versions 2 and 3, on {len(pa)} jobs: identical predictions: {np.array_equal(pa, pb)}")
for v in ("2", "3"):
    tags = client.get_run(client.get_model_version(registry.NAME, v).run_id).data.tags
    print(f"  version {v}: data {tags['data_version']}, code {tags['code_version']}, lock {tags['lock_version']}")
PY
~~~

~~~text
versions 2 and 3, on 26703 jobs: identical predictions: True
  version 2: data c9eb62a5e2a6, code 48fa71b6795f, lock fd508dfe4d29
  version 3: data c9eb62a5e2a6, code 48fa71b6795f, lock fd508dfe4d29
~~~

Identical, on 26,703 jobs: same four fingerprints, same model. Anyone with this registry, this repository and this data can make version 2 again, and check that they did.

### Break it: a lucky seed

Train the same model with another seed:

~~~bash
mlops train --until $H --seed 4 --note "another seed"
mlops gate 4 --holdout-from $H
~~~

~~~text
26703 jobs from 2026-10-18T01:40:00 on, which neither trained on
                                   model  log_factor  p90_covers_%  one_ms
-------------  -------------------------  ----------  ------------  ------
  champion v2  runtime-numpy-c9eb62a5-s1       1.436        85.657   0.106
challenger v4  runtime-numpy-c9eb62a5-s4       1.434        85.657   0.090
  FAIL  log error -0.0012 (95% CI -0.0042 .. +0.0018): better beyond noise
  pass  p90 covers 85.7% (champion 85.7%, may drop 2%)
  pass  one prediction 0.090 ms (budget 1 ms)
version 4 stays a challenger
~~~

Its average error is lower: 1.434 against 1.436. A point estimate would call that better. The interval, -0.0042 to +0.0018, says the difference could be either way, so the gate refuses it. Now make the gate look only at the point estimate: in `judge`, change `high < 0` to `diff < 0`. The tests:

~~~text
FAILED tests/test_registry.py::test_a_better_average_within_noise_is_not_enough
1 failed, 7 passed, 1 warning in 72.24s (0:01:12)
~~~

And the gate itself:

~~~text
26703 jobs from 2026-10-18T01:40:00 on, which neither trained on
                                   model  log_factor  p90_covers_%  one_ms
-------------  -------------------------  ----------  ------------  ------
  champion v2  runtime-numpy-c9eb62a5-s1       1.436        85.657   0.142
challenger v4  runtime-numpy-c9eb62a5-s4       1.434        85.657   0.114
  pass  log error -0.0012 (95% CI -0.0042 .. +0.0018): better beyond noise
  pass  p90 covers 85.7% (champion 85.7%, may drop 2%)
  pass  one prediction 0.114 ms (budget 1 ms)
version 4 may be promoted
~~~

"May be promoted": a model no better than the champion, replacing it because of which random numbers it drew. Repeat that often enough and the champion becomes whoever was luckiest on this holdout. Put `high < 0` back.

### Break it: the better model nobody can afford

The trees, step 6's most accurate model:

~~~bash
mlops train --until $H --point trees --note "the trees"
mlops gate 5 --holdout-from $H
~~~

~~~text
26703 jobs from 2026-10-18T01:40:00 on, which neither trained on
                                   model  log_factor  p90_covers_%  one_ms
-------------  -------------------------  ----------  ------------  ------
  champion v2  runtime-numpy-c9eb62a5-s1       1.436        85.657   0.092
challenger v5  runtime-trees-c9eb62a5-s1       1.440        85.657  18.841
  FAIL  log error +0.0027 (95% CI -0.0050 .. +0.0110): better beyond noise
  pass  p90 covers 85.7% (champion 85.7%, may drop 2%)
  FAIL  one prediction 18.841 ms (budget 1 ms)
version 5 stays a challenger
~~~

Two refusals: no better here (the interval spans zero), and 11.9 ms for one prediction, against a budget of 1 ms. Step 8 measured what that costs in production: 60% of predictions answered. A gate that checks only accuracy would have sent that back to the cluster.

### Run it: roll back, roll forward

Suppose version 2 misbehaved after deploying. Roll back, deploy, and check:

~~~bash
mlops rollback && mlops deploy
serving
~~~

~~~text
champion: version 1 (previous: 2)
~~~

~~~text
version 1 (runtime-numpy-20261017-2316-c0e7da40) is serving
~~~

~~~text
runtime-numpy-20261017-2316-c0e7da40
runtime-numpy-20261017-2316-c0e7da40
runtime-numpy-20261017-2316-c0e7da40
runtime-numpy-20261017-2316-c0e7da40
runtime-numpy-20261017-2316-c0e7da40
~~~

Version 1 answers again (the first call, on a fresh connection to the restarted predictor, got none: step 8's cold start). Rolling back is the same command again, which swaps `champion` and `previous`:

~~~bash
mlops rollback && mlops deploy
serving
mlops list
~~~

~~~text
champion: version 2 (previous: 1)
~~~

~~~text
no prediction
runtime-numpy-c9eb62a5-s1
runtime-numpy-c9eb62a5-s1
runtime-numpy-c9eb62a5-s1
runtime-numpy-c9eb62a5-s1
~~~

~~~text
version                                 model   rows          data                              note   aliases
-------  ------------------------------------  -----  ------------  --------------------------------  --------
      1  runtime-numpy-20261017-2316-c0e7da40  29178             -               served since step 8  previous
      2             runtime-numpy-c9eb62a5-s1  63111  c9eb62a5e2a6      every job before the holdout  champion
      3             runtime-numpy-c9eb62a5-s1  63111  c9eb62a5e2a6  version 2 again: the same inputs          
      4             runtime-numpy-c9eb62a5-s4  63111  c9eb62a5e2a6                      another seed          
      5             runtime-trees-c9eb62a5-s1  63111  c9eb62a5e2a6                         the trees          
~~~

Five versions, every one kept, each with its data version and its reason. Two aliases say which serves and which served before.

**Explain it:** what do the four fingerprints identify, and why all four? What does an alias give you that a version number doesn't? Why must the champion and challenger be scored on jobs neither trained on, and job by job? Why does the gate need the interval, and what did a point estimate promote? Why does the gate check latency and coverage as well as accuracy? Why did version 1 go so wrong, and why didn't the trees' kind of model fail that way? What does the model card's operating range tell its reader? Why can't GitHub's CI gate a model here, and what does it test instead?

**Read.** D. Sculley and others, *Hidden Technical Debt in Machine Learning Systems* (NeurIPS 2015) again, now with a registry in hand. Margaret Mitchell and others, *Model Cards for Model Reporting* (FAT* 2019): the card's sections, and why each is there. Eric Breck and others, *The ML Test Score: A Rubric for ML Production Readiness and Technical Debt Reduction* (IEEE Big Data 2017): score this phase against it. And the MLflow documentation on the model registry and aliases.

---
## Step 11: Watching a model in production

**The problem.** Version 2 passed its gate on the jobs of one evening, and has served since. The gate said it was good on *those* jobs. The jobs it sees now come from a cluster that has changed since then: the autoscaler keeps the queue short, lanes reorder the work, and tenants change what they send. A run time is known only once the job finishes, so a model can be wrong for a long time before anyone counts its errors. This step watches the model in production. The predictor counts, on every request, the inputs its model never trained on, and an alert fires when they become common. `lab drift` compares everything the predictor saw with what its model learned from, and with what really happened. A challenger runs in the predictor's **shadow**: it is asked every question, and its answers are logged, never served, until the live jobs show whether it is better. Then a new tenant arrives.

**New ideas.**

- **Drift.** The world a model serves stops looking like the one it learned from. The inputs can shift (**data drift**, or covariate shift: other tenants, other sizes, shorter queues). What the inputs *mean* for the answer can shift (**concept drift**: the same queue length, a different run time). The answers can shift (**prediction drift**), and so can the truth (**label drift**).
- **PSI and KS.** Two sizes for how far a distribution moved. The population stability index bins the training values by their deciles, and adds up, over the bins, (new share − old share) × ln(new share / old share). By convention, under 0.1 is stable, 0.1 to 0.25 a moderate shift, and above 0.25 a major one. The Kolmogorov–Smirnov statistic is the largest gap between the two cumulative distributions, 0 to 1. Each comes with a p-value, but with thousands of values, every gap is "significant": read the size.
- **Out of range, and unseen.** A number beyond any the model trained on, or a tenant it never saw. There, the model is guessing. Step 10 measured how badly a network guesses past its range. These are cheap to count on every request, so they can drive an alert.
- **Drift isn't damage.** A feature can move without hurting accuracy, and accuracy can fall without any input moving. Only the labels, once they arrive, measure damage. Drift tells you where to look.
- **A shadow deployment.** The challenger runs beside the champion, on live traffic, with no say in the answer. It shows how the challenger would have done on the jobs that actually came, at no risk to them.

### Measuring drift

Create `lab/src/lab/drift.py`:

<!-- file: lab/src/lab/drift.py -->
~~~python
"""Has the world moved away from what the model learned? Comparing distributions.

A model is trained on one distribution of inputs and labels, and served on
whatever arrives. When they differ (drift), its accuracy may suffer, or may
not: drift is a reason to look, not proof of damage. The measures:

PSI (population stability index): bin the training values (here by their
deciles), and compare the share of new values in each bin with the
training's: sum((new - old) * ln(new / old)). By convention, under 0.1 is
stable, 0.1 to 0.25 a moderate shift, over 0.25 a major one.

KS (Kolmogorov-Smirnov): the largest gap between the two cumulative
distributions, 0 to 1. Its p-value says how surprising the gap is if
nothing changed; with thousands of values, even a trivial gap is
"significant", so read the size, not the p-value.

Categories get PSI too, with a bin for values the model never saw.
"""

import numpy as np

EPS = 1e-4  # an empty bin isn't impossible, just rare: avoid log(0)
SAMPLE = 2_000


def reference(values: np.ndarray, seed: int = 1) -> dict:
    """What a feature looked like in training: enough to compare with later."""
    values = np.asarray(values)
    if values.dtype.kind in "OUS":
        names, counts = np.unique(values.astype(str), return_counts=True)
        return {
            "kind": "category",
            "props": dict(zip(names.tolist(), (counts / counts.sum()).tolist(), strict=True)),
        }
    v = values[~np.isnan(values.astype(float))].astype(float)
    edges = np.unique(np.quantile(v, np.linspace(0.1, 0.9, 9)))
    props = np.bincount(np.searchsorted(edges, v, side="right"), minlength=len(edges) + 1) / len(v)
    rng = np.random.default_rng(seed)
    sample = rng.choice(v, size=min(SAMPLE, len(v)), replace=False)
    return {
        "kind": "number",
        "edges": edges.tolist(),
        "props": props.tolist(),
        "sample": sample.tolist(),
        "range": [float(v.min()), float(v.max())],
    }


def psi(expected: np.ndarray, actual: np.ndarray) -> float:
    e, a = np.maximum(expected, EPS), np.maximum(actual, EPS)
    return float(np.sum((a - e) * np.log(a / e)))


def compare(ref: dict, values: np.ndarray) -> dict:
    """PSI, KS and the share of unusual values, for one feature's new values."""
    values = np.asarray(values)
    if ref["kind"] == "category":
        names = list(ref["props"])
        new = values.astype(str)
        unseen = ~np.isin(new, names)
        props = np.array([np.mean(new == n) for n in names] + [unseen.mean()])
        expected = np.array([ref["props"][n] for n in names] + [0.0])
        return {"psi": psi(expected, props), "ks": float("nan"), "unusual": float(unseen.mean())}
    from scipy.stats import ks_2samp

    v = values.astype(float)
    v = v[~np.isnan(v)]
    edges = np.array(ref["edges"])
    props = np.bincount(np.searchsorted(edges, v, side="right"), minlength=len(edges) + 1) / len(v)
    lo, hi = ref["range"]
    return {
        "psi": psi(np.array(ref["props"]), props),
        "ks": float(ks_2samp(np.array(ref["sample"]), v).statistic),
        "unusual": float(np.mean((v < lo) | (v > hi))),
    }


def verdict(value: float) -> str:
    if np.isnan(value):
        return ""
    return "stable" if value < 0.1 else "moderate" if value < 0.25 else "MAJOR"


def report(
    artifact: dict, served: list[dict], labels: np.ndarray, predicted: np.ndarray
) -> list[list]:
    """One row per feature, then the model's predictions, then the labels (actual run times).

    served: the predictor's log lines. labels and predicted: actual and
    predicted run times of the served jobs that have finished.
    """
    ref = artifact["reference"]
    rows = []
    for name in artifact["features"]:
        values = np.array(
            [np.nan if s["features"][name] is None else s["features"][name] for s in served]
        )
        if ref[name]["kind"] == "category":
            values = values.astype(str)
        rows.append([name, *_measures(ref[name], values)])
    served_log = np.log([s["served"]["run_s"] for s in served])
    rows.append(["prediction", *_measures(ref["prediction"], served_log)])
    if len(labels):
        rows.append(["label (run time)", *_measures(ref["label"], np.log(labels))])
    return rows


def _measures(ref: dict, values: np.ndarray) -> list:
    m = compare(ref, values)
    return [m["psi"], verdict(m["psi"]), m["ks"], m["unusual"] * 100]


NAMES = ["what", "psi", "verdict", "ks", "unusual_%"]
~~~

`reference` keeps what a feature looked like in training, small enough to travel with the model. For a category, its share of each value. For a number: the inner edges of its deciles, the share of training values in each bin, a random sample of up to 2,000 values for KS, and the range. `compare` measures new values against that reference. A category gets one extra bin for values never seen, so a new tenant adds to the PSI. `report` makes one row per feature, one for the model's predictions, and one for the labels (the actual run times, on a log scale like the predictions).

### What the model saw, kept with it

Every model fitted from now on keeps its references. That includes what it predicted on its own training rows, and what really happened on them. In `lab/src/lab/export.py`:

Change:

<!-- edit: lab/src/lab/export.py -->
~~~python
from lab import dataset
~~~

to:

~~~python
from lab import dataset, drift
~~~

Change:

<!-- edit: lab/src/lab/export.py -->
~~~python
        "ranges": ranges,
        "point": point,
~~~

to:

~~~python
        "ranges": ranges,
        "reference": references(point, rows),
        "point": point,
~~~

Change:

<!-- edit: lab/src/lab/export.py -->
~~~python
    }

~~~

to:

~~~python
    }


def references(point, rows: dict) -> dict:
    """What the model saw in training, per feature, for step 11 to compare with production.

    And what it predicted, and what really happened (log run times), on
    those same rows.
    """
    reference = {name: drift.reference(rows[name]) for name in CATEGORIES + NUMBERS}
    reference["prediction"] = drift.reference(np.log(point.predict(rows)))
    reference["label"] = drift.reference(np.log(rows["run_s"]))
    return reference

~~~


### Watching in the service

On every request, the predictor checks the request's features against its model's references. It counts a number outside the training range as `out_of_range` and a category never seen as `unseen`, both labelled with the feature. It can also hold a shadow model: asked the same question, logged beside the served answer, never returned. In `lab/src/lab/serve.py`:

Change:

<!-- edit: lab/src/lab/serve.py -->
~~~python
    def __init__(self, artifact: dict, stream: Stream, contract: Contract, clock=time.time):
        self.artifact, self.stream, self.contract, self.clock = artifact, stream, contract, clock
        self.state, self.lock = State(), threading.Lock()
~~~

to:

~~~python
    def __init__(
        self,
        artifact: dict,
        stream: Stream,
        contract: Contract,
        clock=time.time,
        shadow: dict | None = None,
    ):
        self.artifact, self.stream, self.contract, self.clock = artifact, stream, contract, clock
        # A shadow (step 11): a second model, asked the same question every
        # time, whose answer is logged and never served. How a challenger
        # would do on live traffic, at no risk to it.
        self.shadow = shadow
        self.state, self.lock = State(), threading.Lock()
~~~

Change:

<!-- edit: lab/src/lab/serve.py -->
~~~python
            lambda: float(self.ready.is_set())
        )
~~~

to:

~~~python
            lambda: float(self.ready.is_set())
        )
        # Step 11: inputs the model never learned from. A number outside its
        # training range (where a network extrapolates in straight lines), or
        # a category it never saw.
        self.inputs = Counter(
            "prediction_inputs_total", "Predictions asked for.", registry=self.registry
        )
        self.unusual = Counter(
            "prediction_inputs_unusual_total",
            "Inputs outside the training range (out_of_range) or never seen in training (unseen).",
            ["feature", "why"],
            registry=self.registry,
        )
~~~

Change:

<!-- edit: lab/src/lab/serve.py -->
~~~python
        self.latency.observe(time.perf_counter() - start)
        # Two models can disagree, and a bound below the typical time is no bound.
~~~

to:

~~~python
        self.latency.observe(time.perf_counter() - start)
        self.watch(features)
        # Two models can disagree, and a bound below the typical time is no bound.
~~~

Change:

<!-- edit: lab/src/lab/serve.py -->
~~~python
        }
        # One line per prediction, with the features it saw: step 8 checks
~~~

to:

~~~python
        }
        line = {"served": answer, "at_us": at_us, "features": _plain(features)}
        if self.shadow is not None:
            line["shadow"] = {
                "run_s": float(self.shadow["point"].predict(rows)[0]),
                "model": self.shadow["version"],
            }
        # One line per prediction, with the features it saw: step 8 checks
~~~

Change:

<!-- edit: lab/src/lab/serve.py -->
~~~python
        log.info(json.dumps({"served": answer, "at_us": at_us, "features": _plain(features)}))
        return answer | {"features": _plain(features)}

~~~

to:

~~~python
        log.info(json.dumps(line))
        return answer | {"features": _plain(features)}

    def watch(self, features: dict) -> None:
        """Count this request's inputs that fall outside what the model was trained on."""
        self.inputs.inc()
        reference = self.artifact.get("reference", {})
        for name, value in features.items():
            ref = reference.get(name)
            if ref is None:
                continue
            if ref["kind"] == "category" and str(value) not in ref["props"]:
                self.unusual.labels(name, "unseen").inc()
            elif ref["kind"] == "number" and not _isnan(value):
                lo, hi = ref["range"]
                if not lo <= value <= hi:
                    self.unusual.labels(name, "out_of_range").inc()


def _isnan(value) -> bool:
    return isinstance(value, float) and np.isnan(value)

~~~


`watch` reads only the reference's range and category list: two comparisons per feature, nothing like the cost of a prediction.

### Matching predictions to jobs

`lab drift` and `lab shadow` both need step 8's pairing of a logged prediction with the job it was for. That pairing was inside `skew`; take it out, as `match`. In `lab/src/lab/online.py`:

Change:

<!-- edit: lab/src/lab/online.py -->
~~~python
def skew(served: list[dict], jobs: dict[str, np.ndarray]) -> dict:
    """Compare the features the service used with the batch's, for the same jobs.
~~~

to:

~~~python
def match(served: list[dict], jobs: dict[str, np.ndarray]) -> list[tuple[int, int]]:
    """Pairs (i, j): served[i] was the prediction for job j.
~~~

Change:

<!-- edit: lab/src/lab/online.py -->
~~~python
    A served prediction is matched to the job of the same tenant, kind and
    size created closest to it, within a second: the API stamps the job's
    creation time, then asks, then stores the job.
    """
    batch = dataset.features(jobs)
    index = {}
    for i, key in enumerate(zip(jobs["tenant"], jobs["kind"], jobs["size"], strict=True)):
        index.setdefault(tuple(key), []).append(i)
    matched, diffs = 0, {name: [] for name in dataset.FEATURES[3:]}
    for s in served:
~~~

to:

~~~python
    The job of the same tenant, kind and size created closest to the
    prediction, within a second: the API stamps the job's creation time,
    then asks, then stores the job.
    """
    index = {}
    for j, key in enumerate(zip(jobs["tenant"], jobs["kind"], jobs["size"], strict=True)):
        index.setdefault(tuple(key), []).append(j)
    pairs = []
    for i, s in enumerate(served):
~~~

Change:

<!-- edit: lab/src/lab/online.py -->
~~~python
        i = min(candidates, key=lambda c: abs(int(jobs["created"][c]) - s["at_us"]))
        if abs(int(jobs["created"][i]) - s["at_us"]) < 1_000_000:
            matched += 1
            for name in diffs:
                online = np.nan if f[name] is None else float(f[name])
                diffs[name].append((online, float(batch[name][i])))
~~~

to:

~~~python
        j = min(candidates, key=lambda c: abs(int(jobs["created"][c]) - s["at_us"]))
        if abs(int(jobs["created"][j]) - s["at_us"]) < 1_000_000:
            pairs.append((i, j))
    return pairs


def skew(served: list[dict], jobs: dict[str, np.ndarray]) -> dict:
    """Compare the features the service used with the batch's, for the same jobs."""
    batch = dataset.features(jobs)
    pairs = match(served, jobs)
    matched, diffs = len(pairs), {name: [] for name in dataset.FEATURES[3:]}
    for i, j in pairs:
        f = served[i]["features"]
        for name in diffs:
            online = np.nan if f[name] is None else float(f[name])
            diffs[name].append((online, float(batch[name][j])))
~~~


### Older models, and the shadow in the deploy

Version 2 was trained before models kept references. Its training rows are still in the dataset, so the references can be rebuilt from them, as long as those rows are still there. `deploy` learns to send a second model, as the shadow, and to rebuild the references of a model without them. In `lab/src/lab/registry.py`:

Change:

<!-- edit: lab/src/lab/registry.py -->
~~~python
def deploy(client, ref: str = "champion", namespace: str = "runway") -> str:
    """Copy a version's artifact into the predictor's ConfigMap and restart it on it."""
    version, artifact = fetch(client, ref)
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "runtime.pkl"
        export.save(artifact, path)
        made = subprocess.run(
~~~

to:

~~~python
def with_references(artifact: dict, dataset_path: Path) -> str:
    """Add what the model saw in training (step 11), if it was made before they were kept.

    They are rebuilt from its training rows: every row up to its data_until.
    That works for as long as those rows are still in the dataset.
    """
    if "reference" in artifact:
        return ""
    data = dataset.load(dataset_path)
    # data_until is to the second: every row created before the next one.
    until = np.datetime64(artifact["data_until"].rstrip("Z")) + np.timedelta64(1, "s")
    trained = {k: v[data["created_at"] < until] for k, v in data.items()}
    artifact["reference"] = export.references(artifact["point"], trained)
    n = len(trained["run_s"])
    if n != artifact["rows"]:  # the dataset was rebuilt since, and changed
        return f"references rebuilt from {n} rows; it trained on {artifact['rows']}"
    return f"references rebuilt from its {n} training rows"


def deploy(
    client,
    ref: str = "champion",
    shadow: str | None = None,
    dataset_path: Path = Path("results/dataset.parquet"),
    namespace: str = "runway",
) -> str:
    """Copy a version's artifact into the predictor's ConfigMap and restart it on it.

    shadow: a second version for it to ask on every request and log, never
    serve (step 11). Deploying without one removes it.
    """
    version, artifact = fetch(client, ref)
    models = {"runtime.pkl": artifact}
    said = f"version {version} ({artifact['version']}) is serving"
    if shadow is not None:
        shadow_version, models["shadow.pkl"] = fetch(client, shadow)
        said += f", version {shadow_version} ({models['shadow.pkl']['version']}) in its shadow"
    for art in models.values():
        if note := with_references(art, dataset_path):
            said = f"{art['version']}: {note}\n{said}"
    with tempfile.TemporaryDirectory() as tmp:
        files = []
        for name, art in models.items():
            export.save(art, Path(tmp) / name)
            files.append(f"--from-file={name}={Path(tmp) / name}")
        made = subprocess.run(
~~~

Change:

<!-- edit: lab/src/lab/registry.py -->
~~~python
                f"--from-file=runtime.pkl={path}",
~~~

to:

~~~python
                *files,
~~~

Change:

<!-- edit: lab/src/lab/registry.py -->
~~~python
    return f"version {version} ({artifact['version']}) is serving"
~~~

to:

~~~python
    return said
~~~


`data_until` is kept to the second, so "up to `data_until`" means every row created before the next second. The first version of `with_references` used `<= data_until`, and rebuilt version 2's from 63,100 rows, not the 63,111 it trained on: the last second's jobs were missing. The row count, checked against the one recorded at training, caught it.

### Tests

The tests check that PSI and KS stay small for new values from the same distribution and grow for a shifted one. They check that values beyond the range, and categories never seen, count as unusual; and that missing numbers don't. For the service: that each kind of unusual input is counted, and that the shadow's answer is logged but never served. For the registry: that references rebuilt from the training rows equal those kept at training.

Create `lab/tests/test_drift.py`:

<!-- file: lab/tests/test_drift.py -->
~~~python
import numpy as np

from lab import drift

RNG = np.random.default_rng(1)
TRAINED = RNG.lognormal(0, 1, 20_000)


def test_the_same_distribution_is_stable():
    ref = drift.reference(TRAINED)
    m = drift.compare(ref, RNG.lognormal(0, 1, 5_000))  # new values, the same world
    assert m["psi"] < 0.02 and m["ks"] < 0.05 and drift.verdict(m["psi"]) == "stable"


def test_a_shifted_distribution_is_a_major_shift():
    ref = drift.reference(TRAINED)
    m = drift.compare(ref, RNG.lognormal(1, 1, 5_000))  # everything e times bigger
    assert m["psi"] > 0.25 and m["ks"] > 0.3 and drift.verdict(m["psi"]) == "MAJOR"


def test_values_beyond_the_training_range_are_unusual():
    ref = drift.reference(TRAINED)
    values = np.concatenate([TRAINED[:900], np.full(100, TRAINED.max() * 10)])
    assert drift.compare(ref, values)["unusual"] == 0.1


def test_a_category_never_seen_is_unusual_and_shifts_the_psi():
    ref = drift.reference(np.array(["acme"] * 600 + ["globex"] * 400))
    same = drift.compare(ref, np.array(["acme"] * 60 + ["globex"] * 40))
    assert same["psi"] < 1e-9 and same["unusual"] == 0
    new = drift.compare(ref, np.array(["acme"] * 50 + ["globex"] * 30 + ["hooli"] * 20))
    assert new["unusual"] == 0.2 and new["psi"] > 0.25


def test_missing_numbers_are_left_out_not_counted_as_unusual():
    ref = drift.reference(np.array([1.0, 2.0, np.nan, 3.0] * 100))
    assert ref["range"] == [1.0, 3.0]
    assert drift.compare(ref, np.array([np.nan, 2.0, 2.0]))["unusual"] == 0
~~~

In `lab/tests/test_serve.py`:

Change:

<!-- edit: lab/tests/test_serve.py -->
~~~python

from lab.baselines import KindPowerLaw
~~~

to:

~~~python

from lab import export
from lab.baselines import KindPowerLaw
~~~

At the end of the file, change:

<!-- edit: lab/tests/test_serve.py -->
~~~python
    assert out.stdout.strip() == "False"
~~~

to:

~~~python
    assert out.stdout.strip() == "False"


def test_inputs_the_model_never_trained_on_are_counted(artifact):
    rows = jobs(3_000, 1)
    watched = artifact | {"reference": export.references(artifact["point"], rows)}
    with client(watched, []) as c:
        wait_ready(c)
        for ask in [
            {"tenant": "acme", "kind": "sort", "size": 8_000_000},  # all as in training
            {"tenant": "hooli", "kind": "sort", "size": 8_000_000},  # a tenant never seen
            {"tenant": "acme", "kind": "sort", "size": 900_000_000},  # bigger than any trained
        ]:
            assert c.post("/predict", json=ask).status_code == 200
        metrics = c.get("/metrics").text
    assert "prediction_inputs_total 3.0" in metrics
    assert 'prediction_inputs_unusual_total{feature="tenant",why="unseen"} 1.0' in metrics
    assert 'prediction_inputs_unusual_total{feature="size",why="out_of_range"} 1.0' in metrics


def test_a_shadow_is_asked_and_logged_but_never_served(artifact, caplog):
    shadow = artifact | {"version": "test-2", "point": KindPowerLaw().fit(jobs(3_000, 1))}
    service = Service(
        artifact,
        ListStream([]),
        Contract(CONTRACTS / "job_changed.v2.schema.json"),
        clock=lambda: NOW,
        shadow=shadow,
    )
    caplog.set_level("INFO", logger="predictor")
    with TestClient(create_app(service)) as c:
        wait_ready(c)
        body = c.post("/predict", json={"tenant": "acme", "kind": "sort", "size": 8_000_000}).json()
    assert body["model"] == "test-1" and "shadow" not in body
    line = json.loads(next(r.message for r in caplog.records if '"served"' in r.message))
    assert line["shadow"]["model"] == "test-2"
    assert line["shadow"]["run_s"] != line["served"]["run_s"]  # another model, another answer
~~~


In `lab/tests/test_registry.py`:

At the end of the file, change:

<!-- edit: lab/tests/test_registry.py -->
~~~python
    assert "Operating range" in text and "Worst slice here:" in text
~~~

to:

~~~python
    assert "Operating range" in text and "Worst slice here:" in text


def test_references_rebuilt_from_the_training_rows_match_the_ones_kept(client, tmp_path):
    import pyarrow as pa

    from lab import dataset

    _, artifact = registry.fetch(client, registry.train(TRAIN, "numpy", seed=1))
    kept = artifact.pop("reference")
    path = tmp_path / "dataset.parquet"  # the rows it trained on, and later ones
    dataset.save(pa.table({k: np.concatenate([TRAIN[k], HOLDOUT[k]]) for k in TRAIN}), path)
    assert (
        registry.with_references(artifact, path) == "references rebuilt from its 3000 training rows"
    )
    assert artifact["reference"] == kept
~~~


### The commands

`lab drift LOG` compares one predictor log with a version's references. It also reports the live error on the jobs that have finished, overall and per tenant. `lab shadow LOG` compares the served model with the shadow on the same finished jobs, with step 5's paired, minute-block bootstrap. `lab serve --shadow` loads the shadow, if the file is there. `lab mlops deploy --shadow VERSION` puts it there. In `lab/src/lab/cli.py`:

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python
        print(registry.deploy(client, args.version or "champion"))
~~~

to:

~~~python
        print(registry.deploy(client, args.version or "champion", args.shadow, args.dataset))
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

def cmd_export(args: argparse.Namespace) -> int:
~~~

to:

~~~python

def _served_and_jobs(args):
    """The predictor's log lines, and the jobs they were for (with run times where known)."""
    from lab import dataset, online

    served = online.served_from(args.log.read_text().splitlines())
    jobs = dataset.load_jobs(args.data)
    return served, jobs, online.match(served, jobs)


def cmd_drift(args: argparse.Namespace) -> int:
    import numpy as np

    from lab import drift, metrics, registry
    from lab.warehouse import table

    served, jobs, pairs = _served_and_jobs(args)
    _, artifact = registry.fetch(registry.client(args.root), args.version)
    if note := registry.with_references(artifact, args.dataset):
        print(f"({note})")
    run = np.ma.filled(jobs["run_s"], np.nan)
    done = [(i, j) for i, j in pairs if not np.isnan(run[j])]
    labels = np.array([run[j] for _, j in done])
    predicted = np.array([served[i]["served"]["run_s"] for i, _ in done])
    print(f"{len(served)} predictions by {artifact['version']}; {len(done)} of their jobs finished")
    print(table(drift.NAMES, drift.report(artifact, served, labels, predicted)))
    if len(done):
        print(f"\nlive: typically off by {metrics.log_error(labels, predicted):.3f}")
        tenants = np.array([served[i]["features"]["tenant"] for i, _ in done])
        rows = []
        for t in np.unique(tenants):
            m = tenants == t
            seen = t in artifact["reference"]["tenant"]["props"]
            rows.append(
                [t, "yes" if seen else "NO", m.sum(), metrics.log_error(labels[m], predicted[m])]
            )
        print(table(["tenant", "trained_on", "jobs", "log_factor"], rows))
    return 0


def cmd_shadow(args: argparse.Namespace) -> int:
    import numpy as np

    from lab import metrics
    from lab.warehouse import table

    served, jobs, pairs = _served_and_jobs(args)
    run = np.ma.filled(jobs["run_s"], np.nan)
    both = [(i, j) for i, j in pairs if "shadow" in served[i] and not np.isnan(run[j])]
    if not both:
        print("no finished jobs with a shadow prediction")
        return 1
    y = np.array([run[j] for _, j in both])
    live = np.array([served[i]["served"]["run_s"] for i, _ in both])
    shadow = np.array([served[i]["shadow"]["run_s"] for i, _ in both])
    names = (served[both[0][0]]["served"]["model"], served[both[0][0]]["shadow"]["model"])
    minutes = (jobs["created"][[j for _, j in both]] // 60_000_000).astype(np.int64)
    diff, low, high = metrics.paired_bootstrap(
        np.abs(np.log(live / y)), np.abs(np.log(shadow / y)), minutes
    )
    rows = [
        ["served", names[0], metrics.log_error(y, live)],
        ["shadow", names[1], metrics.log_error(y, shadow)],
    ]
    print(f"{len(y)} finished jobs, both models asked")
    print(table(["", "model", "log_factor"], rows))
    print(f"shadow minus served, log error: {diff:+.4f} (95% CI {low:+.4f} .. {high:+.4f})")
    return 0


def cmd_export(args: argparse.Namespace) -> int:
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python
    service = serve.Service(export.load(args.model), stream, Contract(args.contract))
~~~

to:

~~~python
    shadow = export.load(args.shadow) if args.shadow and args.shadow.exists() else None
    service = serve.Service(export.load(args.model), stream, Contract(args.contract), shadow=shadow)
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python
    ml.add_argument("--note", default="", help="why this version exists")
    ml.set_defaults(func=cmd_mlops)

~~~

to:

~~~python
    ml.add_argument("--note", default="", help="why this version exists")
    ml.add_argument("--shadow", help="deploy: a version to ask alongside, and log, never serve")
    ml.set_defaults(func=cmd_mlops)

    dr = sub.add_parser("drift", help="what the predictor saw, against what its model learned")
    dr.add_argument("log", type=Path, help="the predictor's log (kubectl logs)")
    dr.add_argument("--version", default="champion", help="the registry version that served")
    dr.add_argument("--data", type=Path, default=Path("data"))
    dr.add_argument("--root", type=Path, default=Path("mlflow"))
    dr.add_argument("--dataset", type=Path, default=Path("results/dataset.parquet"))
    dr.set_defaults(func=cmd_drift)

    sh = sub.add_parser("shadow", help="the shadow model against the served one, on live jobs")
    sh.add_argument("log", type=Path, help="the predictor's log (kubectl logs)")
    sh.add_argument("--data", type=Path, default=Path("data"))
    sh.set_defaults(func=cmd_shadow)

~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python
    sv.add_argument("--model", type=Path, default=Path("models/runtime.pkl"))
    sv.add_argument("--brokers", default="localhost:39092")
~~~

to:

~~~python
    sv.add_argument("--model", type=Path, default=Path("models/runtime.pkl"))
    sv.add_argument("--shadow", type=Path, help="a second model to ask and log, never serve")
    sv.add_argument("--brokers", default="localhost:39092")
~~~


<!-- run: cd lab && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

The chart always passes `--shadow`; the file exists only while a shadow is deployed. In `deploy/helm/runway/templates/predictor.yaml`:

Change:

<!-- edit: deploy/helm/runway/templates/predictor.yaml -->
~~~yaml
          args: ["--model", "/models/runtime.pkl", "--brokers", {{ .Values.kafka.brokers | quote }},
~~~

to:

~~~yaml
          # The shadow is loaded only if lab mlops deploy --shadow put one there.
          args: ["--model", "/models/runtime.pkl", "--shadow", "/models/shadow.pkl",
                 "--brokers", {{ .Values.kafka.brokers | quote }},
~~~


### An alert

One prediction with a new tenant is nothing. One in twenty, for ten minutes, means the world has moved. It's a ticket, not a page: predictions still flow, and the API has its fallback. In `deploy/prometheus/rules.yml`:

Add this at the end of the file:

<!-- append: deploy/prometheus/rules.yml -->
~~~yaml
  - name: predictions
    rules:
      # Inputs the model never trained on (Phase 7, step 11): a tenant or
      # kind it never saw, a number beyond any in its training rows. One
      # now and then is nothing; a steady share means the world has moved,
      # and its answers there are guesses. Not a page: predictions still
      # flow, and the fallback is there. A reason to run lab drift.
      - alert: PredictorInputsUnusual
        expr: |
          sum by (feature, why) (rate(prediction_inputs_unusual_total{job="predictor"}[10m]))
            / on() group_left sum(rate(prediction_inputs_total{job="predictor"}[10m]))
            > 0.05
        for: 10m
        labels:
          severity: ticket
        annotations:
          summary: The predictor is seeing inputs its model never trained on
          description: "{{ $value | humanizePercentage }} of predictions had {{ $labels.feature }} {{ $labels.why }}. Run lab drift on its log; retrain if accuracy suffers."
~~~


The share is computed per feature and reason, against all predictions (`on() group_left` divides each series by the one total). Its test: a new tenant arrives at minute 10, one prediction in ten. A single odd size, once, must raise nothing. In `deploy/prometheus/rules_test.yml`:

Add this at the end of the file:

<!-- append: deploy/prometheus/rules_test.yml -->
~~~yaml
  # A new tenant arrives at minute 10: one prediction in ten is for it.
  # The share crosses 5% once half the ten-minute window has it, then
  # waits ten minutes more before raising a ticket.
  - name: a steady share of unusual inputs raises a ticket
    interval: 1m
    input_series:
      - series: 'prediction_inputs_total{job="predictor"}'
        values: '0+60x40'
      - series: 'prediction_inputs_unusual_total{job="predictor",feature="tenant",why="unseen"}'
        values: '0x10 0+6x30'
      - series: 'prediction_inputs_unusual_total{job="predictor",feature="size",why="out_of_range"}'
        values: '0x20 1x20'  # one odd size, once: nothing
    alert_rule_test:
      - eval_time: 22m
        alertname: PredictorInputsUnusual
        exp_alerts: []
      - eval_time: 30m
        alertname: PredictorInputsUnusual
        exp_alerts:
          - exp_labels: { severity: ticket, feature: tenant, why: unseen }
            exp_annotations:
              summary: The predictor is seeing inputs its model never trained on
              description: "10% of predictions had tenant unseen. Run lab drift on its log; retrain if accuracy suffers."
~~~


~~~bash
docker run --rm -v $PWD/deploy/prometheus:/r -w /r --entrypoint promtool prom/prometheus:v3.15.0 test rules rules_test.yml
~~~

~~~text
  SUCCESS

~~~

### Run it: the champion, watched

Build and load the predictor's image, upgrade the chart (the predictor's arguments changed), and load the new rule into Prometheus. Then deploy the champion again, so that it carries its references:

~~~bash
docker build -f deploy/predictor/Dockerfile -t runway-predictor:dev .
kind load docker-image runway-predictor:dev --name runway
helm upgrade runway deploy/helm/runway -n runway --reset-then-reuse-values --wait
kubectl -n observability create configmap prometheus --from-file=deploy/prometheus/ --dry-run=client -o yaml | kubectl apply -f -
sleep 60 && curl -s -X POST localhost:9091/-/reload   # the kubelet updates the mounted file within a minute or so
mlops deploy
~~~

~~~text
runtime-numpy-c9eb62a5-s1: references rebuilt from its 63111 training rows
version 2 (runtime-numpy-c9eb62a5-s1) is serving
~~~

All 63,111 rows, as recorded at training. Now the three tenants, as in steps 9 and 10, for three minutes. Save the predictor's log, copy the events into Parquet, and compare:

~~~bash
tokens() { export ACME_TOKEN=$(token acme-ci) GLOBEX_TOKEN=$(token globex-ci) INITECH_TOKEN=$(token initech-ci) HOOLI_TOKEN=$(token hooli-ci); }
tokens
uv run --project kload kload mix workloads/three-tenants.toml --seed 61 --load 2.5 --out results/s11-base.jsonl
kubectl -n runway logs deploy/predictor -c predictor > results/s11-base.log
uv run --project lab lab pipeline
uv run --project lab lab drift results/s11-base.log --version 2
~~~

~~~text
(references rebuilt from its 63111 training rows)
2983 predictions by runtime-numpy-c9eb62a5-s1; 2977 of their jobs finished
             what    psi   verdict     ks  unusual_%
-----------------  -----  --------  -----  ---------
           tenant  0.001    stable    nan      0.000
             kind  0.002    stable    nan      0.000
             size  0.003    stable  0.018      0.000
running_at_submit  0.243  moderate  0.139      0.000
 queued_at_submit  1.628     MAJOR  0.270      0.000
    tenant_recent  0.979     MAJOR  0.227      0.000
  history_log_run  4.866     MAJOR  0.563      0.000
       prediction  0.542     MAJOR  0.187      0.000
 label (run time)  0.069    stable  0.077      0.000

live: typically off by 1.582
 tenant  trained_on  jobs  log_factor
-------  ----------  ----  ----------
   acme         yes  1801       1.642
 globex         yes   248       1.470
initech         yes   928       1.501
~~~

The same tenants, sending the same kinds and sizes, and no input outside the training range. Yet four features read MAJOR. Take them one at a time, because they are different stories.

`history_log_run` (PSI 4.9) moved by design. It's each tenant's mean log run time over every job of that kind finished so far. In training, that mean was still settling from its first jobs; by now it has thousands of jobs behind it, and barely moves. A feature built from all of history is never stationary: its PSI will grow for as long as the system runs, and say nothing about the model. If you alert on PSI, leave such features out or measure them differently.

`queued_at_submit` (PSI 1.6) is the one that matters. The live error is 1.582, against 1.436 on step 10's holdout: about 10% worse, for every tenant. Where?

~~~bash
uv run --project lab python - <<'PY'
"""Step 11: version 2's bias by queue length, on its step-10 holdout and live (the base run)."""
from pathlib import Path
import numpy as np
from lab import dataset, online, registry
BUCKETS = [(0, 1), (1, 3), (3, 10), (10, None)]
def show(name, queued, ratio):
    print(f"{name}: {len(ratio)} jobs, median predicted/actual {np.exp(np.median(np.log(ratio))):.2f}")
    for lo, hi in BUCKETS:
        m = (queued >= lo) & (queued < (hi or np.inf))
        label = f"{lo} to {hi - 1}" if hi else f"{lo} or more"
        print(f"  queued {label:<10} {m.mean():6.1%} of jobs, median predicted/actual {np.exp(np.median(np.log(ratio[m]))):.2f}")
_, v2 = registry.fetch(registry.client(Path("mlflow")), "2")
d = registry.rows_between(dataset.load(Path("results/dataset.parquet")), start="2026-10-18T01:40:00", end="2026-10-18T03:00:00")
show("step 10's holdout", d["queued_at_submit"], v2["point"].predict(d) / d["run_s"])
served = online.served_from(Path("results/s11-base.log").read_text().splitlines())
jobs = dataset.load_jobs(Path("data"))
run = np.ma.filled(jobs["run_s"], np.nan)
pairs = [(i, j) for i, j in online.match(served, jobs) if not np.isnan(run[j])]
q = np.array([served[i]["features"]["queued_at_submit"] for i, _ in pairs])
ratio = np.array([served[i]["served"]["run_s"] / run[j] for i, j in pairs])
show("live, the base run", q, ratio)
PY
~~~

~~~text
step 10's holdout: 26703 jobs, median predicted/actual 1.01
  queued 0 to 0       0.9% of jobs, median predicted/actual 1.41
  queued 1 to 2       3.6% of jobs, median predicted/actual 1.28
  queued 3 to 9       5.4% of jobs, median predicted/actual 1.05
  queued 10 or more  90.0% of jobs, median predicted/actual 1.00
live, the base run: 2977 jobs, median predicted/actual 1.44
  queued 0 to 0      14.2% of jobs, median predicted/actual 1.45
  queued 1 to 2      36.9% of jobs, median predicted/actual 1.55
  queued 3 to 9      37.1% of jobs, median predicted/actual 1.48
  queued 10 or more  11.8% of jobs, median predicted/actual 0.95
~~~

Two things went wrong at once. First, nine in ten of the holdout's jobs met a queue of ten or more; live, only one in eight did. Version 2 had always overestimated jobs that met a short queue, by 1.3 to 1.4 times. But those jobs were 10% of the holdout, and its average hid them. Now they are most of the traffic. That is **data drift** into a region where the model was weak, and PSI pointed straight at it.

Second, even at the same queue length, three to nine, it overestimates 1.48 times live against 1.05 times on the holdout. The same input now means a shorter run. That is **concept drift**, and no comparison of inputs can show it: only the labels do. The cause is the autoscaler. Step 9's experiments, the holdout's jobs and much of the training data, ran with two fixed workers, so a queue of five meant eight consumers sharing two CPUs. The autoscaler is back on, and during these runs it moved between two and seven workers:

~~~text
minutes with N workers, 10:20 to 11:05:
  2 workers: 23 min
  3 workers: 7 min
  4 workers: 5 min
  5 workers: 6 min
  6 workers: 4 min
  7 workers: 1 min
the autoscaler, during the shadow run:
  10:59:53 backlog 18: 2 -> 3
  10:59:59 backlog 28: 3 -> 4
  11:01:07 backlog 7: 4 -> 2
  11:01:12 backlog 28: 2 -> 4
  11:01:17 backlog 38: 4 -> 5
  11:02:20 backlog 15: 5 -> 2
  11:02:30 backlog 20: 2 -> 3
  11:02:34 backlog 26: 3 -> 4
  11:03:42 backlog 0: 4 -> 2
~~~

Five queued jobs, with five workers to take them, run faster than five queued behind two. The model learned what a queue meant on one cluster, and the cluster changed under it. (And look at the autoscaler: from five workers to two, then up to four again within ten seconds, every minute or so. Step 12 has its first anomaly to find.)

`label (run time)` is stable (0.069): the run times as a whole look as they did. A label check alone would have said all is well. Run times are just as long as before; what changed is which conditions they come with.

### Break it: a new tenant

Hooli signs up, and sends big compressions and checksums. Create `workloads/hooli-arrives.toml`: the three tenants, as in `three-tenants.toml`, and hooli:

<!-- file: workloads/hooli-arrives.toml -->
~~~toml
# The three tenants of three-tenants.toml, and a fourth, new one (Phase 7,
# step 11): hooli sends big compressions and checksums, and no model has
# seen it yet. Rates are jobs per second, each tenant's jobs arriving at
# random (a Poisson process); sizes are log-normal around the median,
# spread being the standard deviation of log(size).
duration = 180
seed = 1

[[tenants]]
name = "acme"            # many small jobs
token_env = "ACME_TOKEN"
rate = 4.0
[[tenants.work]]
kind = "checksum"
weight = 3
median = 8_000_000
spread = 1.0
[[tenants.work]]
kind = "sort"
weight = 1
median = 200_000
spread = 1.0

[[tenants]]
name = "globex"          # a few big compressions
token_env = "GLOBEX_TOKEN"
rate = 0.5
[[tenants.work]]
kind = "compress"
weight = 1
median = 4_000_000
spread = 1.2

[[tenants]]
name = "initech"         # a bit of everything
token_env = "INITECH_TOKEN"
rate = 2.0
[[tenants.work]]
kind = "checksum"
weight = 1
median = 32_000_000
spread = 0.8
[[tenants.work]]
kind = "compress"
weight = 1
median = 1_000_000
spread = 0.8
[[tenants.work]]
kind = "sort"
weight = 1
median = 500_000
spread = 0.8

[[tenants]]
name = "hooli"           # new: big compressions and checksums
token_env = "HOOLI_TOKEN"
rate = 0.5
[[tenants.work]]
kind = "compress"
weight = 1
median = 8_000_000
spread = 0.6
[[tenants.work]]
kind = "checksum"
weight = 3
median = 128_000_000
spread = 0.5
~~~

Hooli's client already exists at the idp (`hooli-ci`, from Phase 6), and `tokens` above gets its token too. Restart the predictor, so its counters start from zero, and run six three-minute runs one after another, about twenty minutes, with fresh tokens before each (they last five minutes). Note when the third ends: the model is retrained on what came before, and gated on what came after. In another terminal, watch the share of predictions with an unusual input, and the alert, once a minute:

~~~bash
kubectl -n runway rollout restart deploy/predictor && kubectl -n runway rollout status deploy/predictor
for seed in 62 63 64 65 66 67; do
  tokens
  uv run --project kload kload mix workloads/hooli-arrives.toml --seed $seed --load 2.5 --out results/s11-hooli-$seed.jsonl
  [ $seed = 64 ] && date -u +%Y-%m-%dT%H:%M:%S > results/s11-middle.txt
done
~~~

~~~bash
share='sum by (feature, why) (rate(prediction_inputs_unusual_total{job="predictor"}[10m]))
  / on() group_left sum(rate(prediction_inputs_total{job="predictor"}[10m]))'
while true; do
  echo "$(date -u +%H:%M) $(prom "$share") $(prom 'ALERTS{alertname="PredictorInputsUnusual"}')"
  sleep 60
done
~~~

The watch, condensed (the share per feature, then the alert's state):

~~~text
10:28 none; alert: inactive
10:29 tenant unseen 1.8%, history_log_run out_of_range 0.2%; alert: inactive
10:30 tenant unseen 3.1%, history_log_run out_of_range 0.8%; alert: inactive
10:32 tenant unseen 3.7%, history_log_run out_of_range 0.9%; alert: inactive
10:33 tenant unseen 4.2%, history_log_run out_of_range 1.1%; alert: inactive
10:34 tenant unseen 5.4%, history_log_run out_of_range 1.3%; alert: pending (tenant)
10:35 tenant unseen 6.6%, history_log_run out_of_range 1.6%; alert: pending (tenant)
10:36 tenant unseen 6.8%, history_log_run out_of_range 1.7%; alert: pending (tenant)
10:37 tenant unseen 6.7%, history_log_run out_of_range 1.7%; alert: pending (tenant)
10:38 tenant unseen 6.9%, history_log_run out_of_range 1.7%; alert: pending (tenant)
10:39 tenant unseen 7%, history_log_run out_of_range 1.8%; alert: pending (tenant)
10:40 tenant unseen 6.9%, history_log_run out_of_range 1.8%; alert: pending (tenant)
10:41 tenant unseen 7.1%, history_log_run out_of_range 1.8%; alert: pending (tenant)
10:42 tenant unseen 7%, history_log_run out_of_range 1.8%; alert: pending (tenant)
10:43 tenant unseen 7%, history_log_run out_of_range 1.9%; alert: pending (tenant)
10:44 tenant unseen 7%, history_log_run out_of_range 2%; alert: firing (tenant)
10:45 tenant unseen 7.2%, history_log_run out_of_range 1.9%; alert: firing (tenant)
10:46 tenant unseen 7.2%, history_log_run out_of_range 1.9%; alert: firing (tenant)
10:47 tenant unseen 7.2%, history_log_run out_of_range 1.9%; alert: firing (tenant)
10:48 tenant unseen 6.9%, history_log_run out_of_range 1.8%; alert: firing (tenant)
10:49 tenant unseen 7%, history_log_run out_of_range 1.8%; alert: firing (tenant)
10:50 tenant unseen 7%, history_log_run out_of_range 1.7%; alert: firing (tenant)
10:51 tenant unseen 7.2%, history_log_run out_of_range 1.7%; alert: firing (tenant)
10:52 tenant unseen 7.2%, history_log_run out_of_range 1.7%; alert: firing (tenant)
~~~

The share grows as the ten-minute window fills with hooli's traffic, and passes 5% at 10:34. The alert is pending for the ten minutes its `for` asks, and fires at 10:44, sixteen minutes after hooli's first job. `history_log_run` out of range is hooli too: a mean over a new tenant's first few jobs can be anything. The share stays under 5%, as it should: the history settles within minutes.

Every job completed in all six runs:

~~~text
== base (10:22:23)
submitted: 2983 accepted, 0 refused
states: {'completed': 2983}
== hooli-62 (10:28:52)
submitted: 3127 accepted, 0 refused
states: {'completed': 3127}
== hooli-63 (10:32:51)
submitted: 3191 accepted, 0 refused
states: {'completed': 3191}
== hooli-64 (10:36:36)
submitted: 3146 accepted, 0 refused
states: {'completed': 3146}
== hooli-65 (10:40:19)
submitted: 3217 accepted, 0 refused
states: {'completed': 3217}
== hooli-66 (10:44:07)
submitted: 3125 accepted, 0 refused
states: {'completed': 3125}
== hooli-67 (10:47:50)
submitted: 3187 accepted, 0 refused
states: {'completed': 3187}
== shadow (10:59:42)
submitted: 3076 accepted, 0 refused
states: {'completed': 3076}
~~~

Now the drift report. Wait until the dataset is complete before using it (step 9). I didn't: I built it three minutes after the last run, while 1,459 jobs were still unseen. Every row the model trains on below is from before 10:40, long since complete; but the holdout stops at 10:48, before the last run's end. Wait:

~~~bash
kubectl -n runway logs deploy/predictor -c predictor > results/s11-hooli.log
uv run --project lab lab pipeline
until uv run --project lab lab dataset | head -1 | grep -q "not yet seen 0, .* too recent 0,"; do sleep 20; done
uv run --project lab lab drift results/s11-hooli.log --version 2
~~~

~~~text
not yet seen 1459, jobs 110387, too recent 993, not completed 0, start unknown 58, rows 109336
109336 finished jobs, from 2026-10-17T03:21:28.582058 to 2026-10-18T10:48:33.084843
  train: 65601 jobs, 2026-10-17T03:21:28.582058 to 2026-10-18T01:45:47.646396
  valid: 21867 jobs, 2026-10-18T01:45:47.660634 to 2026-10-18T02:25:03.361820
   test: 21868 jobs, 2026-10-18T02:25:03.430226 to 2026-10-18T10:48:33.084843
wrote results/dataset.parquet
~~~

~~~text
(references rebuilt from its 63111 training rows)
18993 predictions by runtime-numpy-c9eb62a5-s1; 18962 of their jobs finished
             what    psi   verdict     ks  unusual_%
-----------------  -----  --------  -----  ---------
           tenant  0.469     MAJOR    nan      7.071
             kind  0.002    stable    nan      0.000
             size  0.017    stable  0.065      0.000
running_at_submit  0.188  moderate  0.123      0.000
 queued_at_submit  1.192     MAJOR  0.238      0.000
    tenant_recent  0.651     MAJOR  0.235      0.000
  history_log_run  4.862     MAJOR  0.553      1.780
       prediction  0.550     MAJOR  0.183      0.000
 label (run time)  0.027    stable  0.039      0.000

live: typically off by 1.747
 tenant  trained_on   jobs  log_factor
-------  ----------  -----  ----------
   acme         yes  10925       1.747
 globex         yes   1355       1.606
  hooli          NO   1342       2.625
initech         yes   5340       1.610
~~~

Hooli is 7.1% of the predictions, and the tenant's PSI is MAJOR (0.47). Its jobs are off by a factor of 2.6, against 1.6 to 1.75 for the others. Why so bad? Not the cold start, as I'd guessed:

~~~bash
uv run --project lab python - <<'PY'
"""Step 11: why was hooli predicted so badly? Its errors, by what the predictor knew of it."""
from pathlib import Path
import numpy as np
from lab import dataset, metrics, online, registry
served = online.served_from(Path("results/s11-hooli.log").read_text().splitlines())
jobs = dataset.load_jobs(Path("data"))
run = np.ma.filled(jobs["run_s"], np.nan)
rows = []
for i, j in online.match(served, jobs):
    f = served[i]["features"]
    if f["tenant"] == "hooli" and not np.isnan(run[j]):
        rows.append((f["kind"], f["history_log_run"] is None, served[i]["served"]["run_s"], run[j]))
print("hooli's jobs, as version 2 served them:")
print(f"  {'kind':<9} {'history':<8} {'jobs':>5}  {'log_factor':>10}  {'median predicted/actual':>22}")
for kind in ("checksum", "compress"):
    for missing in (True, False):
        m = [(p, y) for k, miss, p, y in rows if k == kind and miss == missing]
        if m:
            p, y = np.array(m).T
            print(f"  {kind:<9} {'none' if missing else 'known':<8} {len(m):>5}  {metrics.log_error(y, p):>10.3f}  {np.median(p / y):>22.2f}")
client = registry.client(Path("mlflow"))
holdout = registry.rows_between(dataset.load(Path("results/dataset.parquet")), start=Path("results/s11-middle.txt").read_text().strip())
print("\nthe gate's holdout, by tenant:")
print(f"  {'tenant':<8} {'jobs':>5}  {'v2':>6}  {'v6':>6}")
preds = {v: registry.fetch(client, v)[1]["point"].predict(holdout) for v in ("2", "6")}
for t in np.unique(holdout["tenant"]):
    m = holdout["tenant"] == t
    e = [metrics.log_error(holdout["run_s"][m], preds[v][m]) for v in ("2", "6")]
    print(f"  {t:<8} {m.sum():>5}  {e[0]:>6.3f}  {e[1]:>6.3f}")
PY
~~~

~~~text
hooli's jobs, as version 2 served them:
  kind      history   jobs  log_factor  median predicted/actual
  checksum  none         1      12.560                    0.08
  checksum  known     1001       2.658                    2.63
  compress  none         1      15.515                    0.06
  compress  known      339       2.507                    2.51

the gate's holdout, by tenant:
  tenant    jobs      v2      v6
  acme      4108   1.762   1.402
  globex     519   1.634   1.390
  hooli      486   2.616   1.358
  initech   1962   1.624   1.394
~~~

Only one job of each kind came before hooli had a history; those two were off by twelve and fifteen times. Every other hooli job had its history, and was still overestimated about 2.6 times. To the network, an unseen tenant is a row of zeros where the tenant's one-hot code goes (step 7). No training row ever looked like that, so the answer there is whatever the weights happen to give: a guess, as the counter said. The other tenants got worse too (acme 1.642 → 1.747): hooli's big jobs take CPUs from everyone's.

### Run it: retrain, and let the gate decide

Train on everything before the middle, and gate on everything after:

~~~bash
M=$(cat results/s11-middle.txt)
mlops train --until $M --note "with hooli's first nine minutes"
mlops gate 6 --holdout-from $M
~~~

~~~text
7075 jobs from 2026-10-18T10:40:16 on, which neither trained on
                                   model  log_factor  p90_covers_%  one_ms
-------------  -------------------------  ----------  ------------  ------
  champion v2  runtime-numpy-c9eb62a5-s1       1.760        94.049   0.145
challenger v6  runtime-numpy-dfbef870-s1       1.396        95.095   0.118
  pass  log error -0.2319 (95% CI -0.2597 .. -0.2034): better beyond noise
  pass  p90 covers 95.1% (champion 94.0%, may drop 2%)
  pass  one prediction 0.118 ms (budget 1 ms)
version 6 may be promoted
~~~

Better beyond noise by a wide margin, 1.760 → 1.396, and both guardrails hold. And per tenant, from the end of the script above: hooli goes from 2.616 to 1.358, the best of the four. But it is only 486 of the 7,075 jobs. Every other tenant improves just as much, 1.62–1.76 → 1.39–1.40. Most of the gain is the queue story, not hooli: version 6 learned what a queue means with the autoscaler on.

### Run it: in the shadow

The gate scored version 6 on rows from the dataset: the batch's features. Before it serves, ask it on live traffic, beside the champion, with the features the predictor computes:

~~~bash
mlops deploy --shadow 6
tokens
uv run --project kload kload mix workloads/hooli-arrives.toml --seed 68 --load 2.5 --out results/s11-shadow.jsonl
kubectl -n runway logs deploy/predictor -c predictor > results/s11-shadow.log
sleep 30 && uv run --project lab lab pipeline
uv run --project lab lab shadow results/s11-shadow.log
~~~

~~~text
runtime-numpy-c9eb62a5-s1: references rebuilt from its 63111 training rows
version 2 (runtime-numpy-c9eb62a5-s1) is serving, version 6 (runtime-numpy-dfbef870-s1) in its shadow
~~~

~~~text
3013 finished jobs, both models asked
                            model  log_factor
------  -------------------------  ----------
served  runtime-numpy-c9eb62a5-s1       1.624
shadow  runtime-numpy-dfbef870-s1       1.397
shadow minus served, log error: -0.1504 (95% CI -0.1921 .. -0.0908)
~~~

The same verdict on live traffic: 1.624 served, 1.397 for the shadow, which would have been better beyond noise. Users never saw an answer from version 6.

### Break it: the counter that missed 60 calls

The shadow run submitted 3,076 jobs; the predictor logged 3,016 predictions. Count what the database stored, and what Prometheus said:

~~~text
run       jobs  no_prediction
base       2983     10
hooli-62   3127     34
hooli-65   3217      0
shadow     3076     78
~~~

~~~text
      run                              p50_ms p99_ms timeouts
 hooli-62  just restarted, one model     1.82  17.68       34
 hooli-65  warm, one model               1.33   4.92        0
   shadow  just restarted, two models    1.76   9.24        4
~~~

Each restart costs predictions in its first minute or two (step 8's cold start): 34 after one, 78 after the other, none in a warm run. One restart each can't say how much the shadow added, and the predictor's own p99, 9 ms with two models, is under the 18 ms of the restart with one. But Prometheus counted only 4 failed calls, against 78 jobs without a prediction. The raw counters, per API Pod:

~~~text
api-d768ffc6d-cgvfb open 60
api-d768ffc6d-cgvfb timeout 22
api-d768ffc6d-pqwlg timeout 25
api-d768ffc6d-rwd85 timeout 18
~~~

One Pod's breaker opened, and it refused 60 calls without trying. Its `open` series didn't exist until then: a labelled counter is born at its first increment. This one was born at 60, between two scrapes. `increase()` and `rate()` take a series' first sample as its starting point, so those 60 calls counted as none. A dashboard and an alert built on `rate(predictions_total{outcome="open"})` would never have seen this breaker open. Every outcome should exist, at 0, from the start. In `internal/predict/predict.go`:

Change:

<!-- edit: internal/predict/predict.go -->
~~~go
	return &Client{
~~~

to:

~~~go
	c := &Client{
~~~

Change:

<!-- edit: internal/predict/predict.go -->
~~~go
		}),
	}
}

~~~

to:

~~~go
		}),
	}
	// Every outcome exported at 0 from the start. A labelled series is
	// otherwise born at its first increment, and Prometheus's rate() and
	// increase() take a series' first sample as its starting point: the
	// breaker's first 60 "open" calls, all in one scrape, counted as none
	// (step 11).
	for _, o := range []string{"ok", "timeout", "error", "open"} {
		c.calls.WithLabelValues(o)
	}
	return c
}

~~~


In `internal/predict/predict_test.go`:

Add this at the end of the file:

<!-- append: internal/predict/predict_test.go -->
~~~go
func TestEveryOutcomeIsExportedBeforeItHappens(t *testing.T) {
	c := client("http://127.0.0.1:1")
	if n := testutil.CollectAndCount(c.calls); n != 4 {
		t.Fatalf("%d outcome series before any call, want 4 (ok, timeout, error, open)", n)
	}
}
~~~


Without the loop, the test fails:

~~~text
--- FAIL: TestEveryOutcomeIsExportedBeforeItHappens (0.00s)
    predict_test.go:95: 0 outcome series before any call, want 4 (ok, timeout, error, open)
FAIL
FAIL	runway/internal/predict	0.018s
FAIL
~~~

<!-- run: go test -count=1 ./internal/predict/ -->

### Run it: promote

~~~bash
mlops promote 6 --holdout-from $M
mlops deploy                   # without --shadow: the shadow leaves
kubectl -n runway get configmap predictor-model -o json | jq -r '.binaryData | keys | join(", ")'
docker build -t runway:dev . && kind load docker-image runway:dev --name runway
kubectl -n runway rollout restart deploy/api && kubectl -n runway rollout status deploy/api
~~~

~~~text
7075 jobs from 2026-10-18T10:40:16 on, which neither trained on
                                   model  log_factor  p90_covers_%  one_ms
-------------  -------------------------  ----------  ------------  ------
  champion v2  runtime-numpy-c9eb62a5-s1       1.760        94.049   0.080
challenger v6  runtime-numpy-dfbef870-s1       1.396        95.095   0.105
  pass  log error -0.2319 (95% CI -0.2597 .. -0.2034): better beyond noise
  pass  p90 covers 95.1% (champion 94.0%, may drop 2%)
  pass  one prediction 0.105 ms (budget 1 ms)
champion: version 6 (previous: 2)
~~~

~~~text
version 6 (runtime-numpy-dfbef870-s1) is serving
~~~

~~~text
runtime.pkl
~~~

The shadow's file went with the next deploy. `kubectl apply --server-side` removes the fields it set before and no longer sets. Hooli's jobs are now predicted by a model that has seen them, and the new API Pods export `open` from the start:

~~~text
{"model":"runtime-numpy-dfbef870-s1","run_s":0.1608242546301148}
{"model":"runtime-numpy-dfbef870-s1","run_s":0.16065556858730742}
{"model":"runtime-numpy-dfbef870-s1","run_s":0.16048041379790073}
~~~

~~~text
api-659c45b59-p254t open 0
api-659c45b59-tg57f open 0
api-d768ffc6d-cgvfb open 60
~~~

(The third line is the old Pod, on its way out.)

**Explain it:** what's the difference between data drift and concept drift, and which of them can a check on inputs find? Why did `history_log_run` read MAJOR with nothing wrong? Why did version 2's holdout score hide its weakness at short queues? Why is the alert built on unusual inputs and not on PSI? What does a model guess for a tenant it never saw, and why is that a guess? Why run a challenger in the shadow when it has already passed the gate? Why did Prometheus miss the breaker's 60 refusals, and what fixed it?

**Read.** João Gama and others, *A Survey on Concept Drift Adaptation* (ACM Computing Surveys, 2014): the kinds of drift, and what detects each. Shreya Shankar and others, *Operationalizing Machine Learning: An Interview Study* (2022): how teams watch models, and what they wish they had. Google's *Rules of Machine Learning*, the rules on training–serving skew and monitoring. And the Prometheus documentation on `rate()` and `increase()`, and its advice on initialising labelled metrics ("Avoid missing metrics", in the instrumentation guide).

---
## Step 12: Finding incidents nobody wrote a rule for

**The problem.** Runway's alerts are rules someone wrote in advance (Phase 5): error budget burning, latency budget burning, a queue backing up, a dead letter. Each asks one question about one signal. An incident that breaks something nobody thought to ask about stays silent: a predictor that's down, an event stream that has stopped, a node full of someone else's work. **AIOps** promises to find those by learning what normal looks like across every signal and log, and calling out what isn't. It also promises fewer pages, faster. Promises can be measured. This step breaks the system six times on a seeded schedule, writes down exactly when, and scores four anomaly detectors, a log-template miner and Runway's own alerts against that truth. On the way, a real incident nobody injected showed up first.

**New ideas.**

- **Ground truth.** A detector's score needs the right answers: when, exactly, something was wrong. Real outages are few, unlabelled and never the same twice. Inject them instead, on a schedule drawn from a seed, after a quiet warm-up to learn from, and record each one's start and end.
- **Precision, recall, time to detect, false alarms.** Recall is the share of incidents found. Precision is the share of alarms that were about an incident. Time to detect is from the incident's start to the first alarm. False alarms per hour is what wakes people up for nothing. A detector is a trade-off between them, set by its threshold.
- **Static and adaptive baselines.** A static baseline learns normal once (mean and standard deviation, or median and MAD). An adaptive one keeps learning (EWMA), so it follows slow change, and also gets used to an incident that lasts.
- **Robust statistics.** Real signals have long tails. The median and the median absolute deviation (MAD) aren't moved by a few spikes in the warm-up; the mean and standard deviation are.
- **Multivariate detection.** An isolation forest looks at all signals together, and can flag a combination that is odd when no signal alone is.
- **Absence is a signal.** A metric that was always there and has stopped is often the clearest symptom: whatever reported it is gone.
- **Logs as signals.** Drain (2017) turns log lines into templates, in one pass, without being told them. Count lines per template, and a template never seen before is news.
- **Symptoms and causes.** Alerts on symptoms (users are failing) page for what matters. Anomalies in causes (a database got slower) find more, earlier, and include many that users never felt.

### Found first: a login that outlived its renewal

Before any incident was injected, Prometheus was already paging: `DatabaseLoginNotRenewed`, for every API Pod and the notifier. OpenBao was unsealed and healthy. The logins had expired eight hours earlier, and the services hadn't tried to renew them:

~~~text
api-659c45b59-hjrd6 overdue 30273 s
api-659c45b59-hjrd6 expires in -29074 s
~~~

The last line the API logged about it was the login itself, at 11:13, valid for an hour. Then the laptop slept for nine hours. `Run` (Phase 6, step 9) computes the wait until two thirds of the login's life, and sleeps it with `time.After`. A Go timer counts the **monotonic** clock, and on Linux the monotonic clock stops while the machine is suspended. So nine hours later, by the wall clock that OpenBao and PostgreSQL go by, the timer still had half an hour to run. And there is a second trap behind the first. `Fetched` comes from `time.Now()`, which carries a monotonic reading, and `Sub` and `Before` compare the monotonic readings when both times have one. So even a loop that kept looking at the clock would have been fooled. The services kept working on the connections they held, and could open no new ones.

A server that never sleeps would never show this; laptops, VMs that get paused, and containers that get frozen do. The fix compares wall-clock times only (`Round(0)` drops the monotonic reading), and never sleeps more than 30 seconds without looking at the clock again. In `internal/secrets/dblogin.go`:

Change:

<!-- edit: internal/secrets/dblogin.go -->
~~~go
	OnRotate func()

~~~

to:

~~~go
	OnRotate func()
	// Recheck is the longest Run sleeps before looking at the clock again.
	Recheck time.Duration

~~~

Change:

<!-- edit: internal/secrets/dblogin.go -->
~~~go
		client: client,
		path:   "database/creds/" + role,
		logger: logger,
		now:    time.Now,
		Grace:  time.Minute,
~~~

to:

~~~go
		client:  client,
		path:    "database/creds/" + role,
		logger:  logger,
		now:     time.Now,
		Grace:   time.Minute,
		Recheck: 30 * time.Second,
~~~

Change:

<!-- edit: internal/secrets/dblogin.go -->
~~~go
	now := d.now()
~~~

to:

~~~go
	// The wall clock alone (Round(0) drops the monotonic reading), as
	// OpenBao and PostgreSQL count the login's life: see Run.
	now := d.now().Round(0)
~~~

Change:

<!-- edit: internal/secrets/dblogin.go -->
~~~go
		wait := max(renewAt(cur).Sub(d.now()), 0)
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
~~~

to:

~~~go
		// Wait in short steps, looking at the wall clock after each. A
		// timer counts the monotonic clock, which stops while the machine
		// is suspended: one long wait, begun before a laptop slept for
		// nine hours, ended long after the login had expired (step 12).
		if wait := renewAt(cur).Sub(d.now().Round(0)); wait > 0 {
			select {
			case <-ctx.Done():
				return
			case <-time.After(min(wait, d.Recheck)):
			}
			continue
~~~


The client's own token has the same flaw. In `internal/secrets/bao.go`:

Change:

<!-- edit: internal/secrets/bao.go -->
~~~go
	now := c.now()
~~~

to:

~~~go
	now := c.now().Round(0) // the wall clock, as OpenBao counts the token's life
~~~


A real suspend can't be staged in a test, but the two properties the fix rests on can be checked. Times kept for renewal carry no monotonic reading, and `Run` renews soon after the wall clock passes the renewal time, however far ahead its last wait was set. In `internal/secrets/secrets_test.go`:

Change:

<!-- edit: internal/secrets/secrets_test.go -->
~~~go
	"os"
	"sync/atomic"
~~~

to:

~~~go
	"os"
	"strings"
	"sync"
	"sync/atomic"
~~~

Add this at the end of the file:

<!-- append: internal/secrets/secrets_test.go -->
~~~go
// fakeBao answers logins and database credentials of a 1-hour life,
// counting the credentials it hands out.
func fakeBao(t *testing.T) (*Client, *atomic.Int32) {
	var creds atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/auth/kubernetes/login":
			io.WriteString(w, `{"auth":{"client_token":"t","lease_duration":3600}}`)
		case "/v1/database/creds/api":
			creds.Add(1)
			io.WriteString(w, `{"lease_id":"database/creds/api/x","lease_duration":3600,"data":{"username":"u","password":"p"}}`)
		}
	}))
	t.Cleanup(srv.Close)
	jwt := t.TempDir() + "/token"
	os.WriteFile(jwt, []byte("a-kubernetes-token"), 0o600)
	return WithKubernetes(srv.URL, srv.Client(), "api", jwt), &creds
}

// A time from time.Now carries a monotonic reading, and Sub and Before
// compare those when both times have one. The monotonic clock stops while
// the machine sleeps, OpenBao's clock doesn't: the times that decide
// renewal must be wall-clock times.
func TestRenewalTimesAreWallClockTimes(t *testing.T) {
	c, _ := fakeBao(t)
	d := NewDBLogins(c, "api", slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err := d.Fetch(context.Background()); err != nil {
		t.Fatal(err)
	}
	l := d.Current()
	for name, at := range map[string]time.Time{"fetched": l.Fetched, "expires": l.Expires, "token renewal": c.renewAt} {
		if strings.Contains(at.String(), " m=") {
			t.Errorf("%s %v carries a monotonic reading", name, at)
		}
	}
}

// The wall clock jumps two hours, as after a laptop's sleep: Run must
// renew within a recheck, not when a timer set an hour earlier fires.
func TestRunRenewsAfterTheWallClockJumps(t *testing.T) {
	c, creds := fakeBao(t)
	d := NewDBLogins(c, "api", slog.New(slog.NewTextHandler(io.Discard, nil)))
	var mu sync.Mutex
	now := time.Date(2026, 10, 18, 11, 0, 0, 0, time.UTC)
	d.now = func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	d.Recheck = 10 * time.Millisecond
	if err := d.Fetch(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go d.Run(ctx)
	time.Sleep(50 * time.Millisecond)
	if n := creds.Load(); n != 1 {
		t.Fatalf("%d logins before the jump, want 1: renewal is 40 minutes away", n)
	}
	mu.Lock()
	now = now.Add(2 * time.Hour)
	mu.Unlock()
	deadline := time.Now().Add(time.Second)
	for creds.Load() < 2 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if n := creds.Load(); n < 2 {
		t.Fatalf("%d logins a second after the clock passed the renewal time, want 2", n)
	}
}
~~~


<!-- run: go test -count=1 ./internal/secrets/ -->

Without the `Round(0)`s, and then without the 30-second cap, each fails:

~~~text
--- FAIL: TestRenewalTimesAreWallClockTimes (0.01s)
    secrets_test.go:126: fetched 2026-10-18 13:21:22.795350731 -0700 PDT m=+0.013858480 carries a monotonic reading
    secrets_test.go:126: expires 2026-10-18 14:21:22.795350731 -0700 PDT m=+3600.013858480 carries a monotonic reading
    secrets_test.go:126: token renewal 2026-10-18 14:01:22.792682526 -0700 PDT m=+2400.011190295 carries a monotonic reading
FAIL
FAIL	runway/internal/secrets	0.079s
FAIL
~~~

~~~text
--- FAIL: TestRunRenewsAfterTheWallClockJumps (1.07s)
    secrets_test.go:158: 1 logins a second after the clock passed the renewal time, want 2
FAIL
FAIL	runway/internal/secrets	1.076s
FAIL
~~~

Build and load the image, and restart what logs in to the database (`docker build -t runway:dev . && kind load docker-image runway:dev --name runway`, then `kubectl -n runway rollout restart deploy/api deploy/notifier`). Every service logs in afresh, and the page clears. It also meant starting the experiment again: an incident nobody had written down was running through its warm-up, and would have been learnt as normal.

### Found again: the second sleep

The fix had a real test sooner than planned. The laptop slept again, for 37 hours, in the middle of the quiet hour below. On waking:

- **The database logins.** Every service tried to renew within a minute: the 30-second recheck saw the wall clock. Before the fix, they would have slept on for hours. The notifier's first attempts failed because its Kubernetes service-account token had expired during the sleep too. The kubelet replaced it, and the notifier was logged in 76 seconds after waking.
- **The certificates.** One API Pod went on failing, with `x509: certificate has expired or is not yet valid`. Every certificate `deploy/certs.sh` issues lives a day (Phase 6, step 7), and nobody was awake to run it again. Two other API Pods had logged in anyway, over connections to OpenBao opened before the expiry: TLS checks a certificate when a connection is made, not for as long as it lasts. Running `deploy/certs.sh` again, as Phase 6 says to, fixed it with no restarts.
- **The logs.** The log collector had been killed while frozen, and its 29 `kubectl` followers kept running, orphaned. SIGTERM ends Python at once, skipping `finally`. `collect` now turns SIGTERM into an ordinary exit, which runs the cleanup; tested by hand, 29 followers before, none after.

A short-lived certificate is only as good as the thing that renews it. Here that's a person running a script, which a cron job, cert-manager or the services themselves should replace (the capstone's hardening review). The quiet hour was started again from the start. It didn't finish either (the end of this step says why).

### Ground truth: incidents on a schedule

Create `lab/src/lab/incidents.py`:

<!-- file: lab/src/lab/incidents.py -->
~~~python
"""Incidents on a schedule, for detectors to find: the ground truth (step 12).

A detector is only as good as its score, and a score needs the truth:
when, exactly, was something wrong? Waiting for real outages gives few,
unlabelled, and never the same twice. So break the system on purpose, as
Phase 5's game day did, but on a schedule drawn from a seed, and write
down when each break started and ended. A quiet warm-up comes first: the
detectors learn what normal looks like from it.

A plan (TOML):

    warmup_s = 900          # nothing injected: normal, to learn from
    gap_s = [300, 480]      # quiet time after each incident, drawn at random
    seed = 1
    tail_s = 0              # more quiet time at the end (optional)

    [[incidents]]
    name = "db-slow"
    start = "deploy/chaos/netem.sh postgres-0 delay 150ms"
    stop = "deploy/chaos/netem.sh postgres-0 clear"
    duration_s = 180

The incidents run in a random order, one at a time. Each line of the
output records one: its name, when its start command finished (the break
is in place), and when its stop command was issued.
"""

import json
import subprocess
import time
import tomllib
from dataclasses import dataclass
from pathlib import Path

import numpy as np


@dataclass(frozen=True)
class Incident:
    name: str
    start: str
    stop: str
    duration_s: float


def load(path: Path) -> dict:
    plan = tomllib.loads(path.read_text())
    plan["incidents"] = [Incident(**i) for i in plan.get("incidents", [])]
    return plan


def schedule(plan: dict) -> tuple[list[tuple[float, Incident]], float]:
    """(seconds after the start, incident), in order: the warm-up, then each
    incident followed by a random gap. And when the last gap ends."""
    rng = np.random.default_rng(plan["seed"])
    order = rng.permutation(len(plan["incidents"]))
    lo, hi = plan["gap_s"]
    at, out = float(plan["warmup_s"]), []
    for k in order:
        incident = plan["incidents"][k]
        out.append((at, incident))
        at += incident.duration_s + float(rng.uniform(lo, hi))
    return out, at + plan.get("tail_s", 0)


def _sh(command: str) -> None:
    subprocess.run(["bash", "-c", command], check=True, capture_output=True, text=True)


def run(plan: dict, out: Path, clock=time.time, sleep=time.sleep) -> None:
    """Inject each incident at its time, and write down when it really was.

    The stop command runs even if the plan is interrupted mid-incident:
    leave a database slowed by accident and the next experiment measures
    the wrong thing.
    """
    begin = clock()
    with out.open("w") as f:
        f.write(json.dumps({"plan_start": begin}) + "\n")
        timetable, end = schedule(plan)
        for at, incident in timetable:
            sleep(max(0.0, begin + at - clock()))
            _sh(incident.start)
            started = clock()
            try:
                sleep(max(0.0, started + incident.duration_s - clock()))
            finally:
                stopping = clock()
                _sh(incident.stop)
            line = {"name": incident.name, "start": started, "end": stopping}
            f.write(json.dumps(line) + "\n")
            f.flush()
        sleep(max(0.0, begin + end - clock()))
        f.write(json.dumps({"plan_end": clock()}) + "\n")


def truth(path: Path) -> tuple[float, float, list[dict]]:
    """The run's start and end, and its incidents, from run's output."""
    lines = [json.loads(line) for line in path.read_text().splitlines()]
    begin = lines[0]["plan_start"]
    end = lines[-1].get("plan_end", lines[-1].get("end"))
    return begin, end, [line for line in lines if "name" in line]
~~~

The plan: six incidents, from Phase 5's chaos scripts and a few new ones, each one a pair of shell commands. Create `experiments/incidents/plan.toml`:

<!-- file: experiments/incidents/plan.toml -->
~~~toml
# Step 12's ground truth: six incidents, one at a time, in an order and
# with gaps drawn from the seed, after fifteen quiet minutes. Run from the
# top of the practice, under steady load:
#   uv run --project lab lab incidents run experiments/incidents/plan.toml --out results/s12-truth.jsonl
warmup_s = 900
gap_s = [300, 480]
seed = 12

[[incidents]]
name = "db-slow"            # every query 150 ms later: the API slows (Phase 5's game day)
start = "deploy/chaos/netem.sh postgres-0 delay 150ms"
stop = "deploy/chaos/netem.sh postgres-0 clear"
duration_s = 180

[[incidents]]
name = "broker-slow"        # RabbitMQ 100 ms later: commands and acknowledgements lag
start = "deploy/chaos/netem.sh rabbitmq-0 delay 100ms 20ms"
stop = "deploy/chaos/netem.sh rabbitmq-0 clear"
duration_s = 180

[[incidents]]
name = "predictor-down"     # no predictions: jobs are still created, without one (step 8)
start = "kubectl -n runway scale deploy/predictor --replicas 0 && kubectl -n runway wait --for=delete pod -l app=predictor --timeout 2m"
stop = "kubectl -n runway scale deploy/predictor --replicas 1"
duration_s = 180

[[incidents]]
name = "kafka-down"         # the outbox holds the events; the predictor's state stops moving (step 3)
start = "kubectl -n runway scale sts/kafka --replicas 0 && kubectl -n runway wait --for=delete pod/kafka-0 --timeout 2m"
stop = "kubectl -n runway scale sts/kafka --replicas 1"
duration_s = 180

[[incidents]]
name = "cpu-hog"            # a noisy neighbour: eight busy loops on one node, which shares the machine's CPUs
start = "docker exec -d runway-worker sh -c 'for i in 1 2 3 4 5 6 7 8; do timeout 240 sh -c \"while :; do :; done\" & done'"
stop = "docker exec runway-worker pkill -f 'while :; do :; done' || true"
duration_s = 180

[[incidents]]
name = "api-pods-lost"      # two of the three API Pods deleted at once; their replacements start
start = "kubectl -n runway get pods -l app=api -o name | head -2 | xargs kubectl -n runway delete --wait=false"
stop = "kubectl -n runway rollout status deploy/api --timeout 3m"
duration_s = 60
~~~

They cover different kinds of trouble. Some slow a dependency (the database, the broker). Some take a component away (the predictor, Kafka, two API Pods). One starves everything of CPU from outside Kubernetes, where no Pod's metrics will show it.

### Every log, kept

Kubernetes deletes a container's log with its Pod, and two of the incidents delete Pods. Create `lab/src/lab/logs.py`:

<!-- file: lab/src/lab/logs.py -->
~~~python
"""Every container's log in a namespace, kept on disk (step 12).

Kubernetes keeps a container's log only as long as its Pod: delete the Pod
and its log goes too, which is exactly when you want it. A log shipper
(Fluent Bit, Vector, Promtail) follows every container and sends the lines
somewhere that outlives the Pod. This is one in miniature: every few
seconds it lists the Pods, and follows each container it isn't following
yet with `kubectl logs -f --timestamps`, appending to one file each.

    POD.CONTAINER.log   lines as kubectl gives them: "TIMESTAMP message"
"""

import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path


def containers(namespace: str) -> list[tuple[str, str]]:
    """(Pod, container) for every running container, sidecars included."""
    out = subprocess.run(
        [
            "kubectl",
            "-n",
            namespace,
            "get",
            "pods",
            "-o",
            "jsonpath={range .items[*]}{.metadata.name}{' '}"
            "{range .status.containerStatuses[*]}{.name}{','}{end}"
            "{range .status.initContainerStatuses[*]}{.name}{','}{end}{'\\n'}{end}",
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    pairs = []
    for line in out.splitlines():
        pod, _, names = line.partition(" ")
        pairs += [(pod, name) for name in names.split(",") if name]
    return pairs


def collect(namespace: str, out: Path, seconds: float, every: float = 5.0) -> int:
    """Follow every container for `seconds`; returns how many were followed."""
    out.mkdir(parents=True, exist_ok=True)
    since = datetime.now().astimezone().isoformat(timespec="seconds")
    following: dict[tuple[str, str], subprocess.Popen] = {}
    deadline = time.monotonic() + seconds
    # Stopped with SIGTERM (kill, a job control system), Python exits at
    # once, skipping the finally below, and every kubectl it started keeps
    # running, orphaned (step 12). Make SIGTERM an ordinary exit.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        while time.monotonic() < deadline:
            for pod, container in containers(namespace):
                running = following.get((pod, container))
                if running is not None and running.poll() is None:
                    continue
                # New, or its follower ended (the container restarted):
                # follow it again from where this collection began.
                # Lines already written come again, once: read() drops them.
                log = (out / f"{pod}.{container}.log").open("a")
                following[(pod, container)] = subprocess.Popen(
                    [
                        "kubectl",
                        "-n",
                        namespace,
                        "logs",
                        "-f",
                        "--timestamps",
                        f"--since-time={since}",
                        pod,
                        "-c",
                        container,
                    ],
                    stdout=log,
                    stderr=subprocess.DEVNULL,
                )
                log.close()  # the follower has its own copy
            time.sleep(every)
    finally:
        for p in following.values():
            p.terminate()
    return len(following)


def read(directory: Path) -> list[tuple[float, str, str]]:
    """(epoch seconds, source, message) for every line, in time order; each
    line once. The source is the container's name, with its Pod's
    Deployment ("api/api", "api/tlsproxy"): Pods come and go, services stay."""
    lines = set()
    for path in sorted(directory.glob("*.log")):
        pod, container = path.name.removesuffix(".log").rsplit(".", 1)
        service = pod.rsplit("-", 2)[0] if pod.count("-") >= 2 else pod.rstrip("-0123456789")
        for raw in path.read_text(errors="replace").splitlines():
            stamp, _, message = raw.partition(" ")
            try:
                at = datetime.fromisoformat(stamp).timestamp()
            except ValueError:
                continue
            lines.add((at, f"{service}/{container}", message, pod))
    return [(at, source, message) for at, source, message, _ in sorted(lines)]
~~~

### The signals

Thirteen series that describe the system's health from the outside in: what clients see, then what's inside. Create `lab/src/lab/signals.py`:

<!-- file: lab/src/lab/signals.py -->
~~~python
"""The system's vital signs, from Prometheus, as one table (step 12).

Each signal is a PromQL query, evaluated every `step` seconds over a time
range (the query_range API). A signal that has no value at a moment is
NaN there: its target was down, or the series didn't exist. That absence
can itself be the symptom (the predictor, scaled to zero, reports
nothing), so it's kept, not filled in.
"""

import json
import urllib.parse
import urllib.request
from pathlib import Path

import numpy as np

# Requests from clients: the probes and Prometheus's own scrapes left out.
_CLIENTS = 'job="api",route!~"GET /(health|ready|metrics)"'

SIGNALS = {
    "api_requests": f"sum(rate(http_requests_total{{{_CLIENTS}}}[1m]))",
    "api_errors": f'(sum(rate(http_requests_total{{{_CLIENTS},code=~"5.."}}[1m])) or vector(0))'
    f" / sum(rate(http_requests_total{{{_CLIENTS}}}[1m]))",
    "api_p50_s": "histogram_quantile(0.5, sum by (le) "
    f"(rate(http_request_duration_seconds_bucket{{{_CLIENTS}}}[1m])))",
    "api_p99_s": "histogram_quantile(0.99, sum by (le) "
    f"(rate(http_request_duration_seconds_bucket{{{_CLIENTS}}}[1m])))",
    "db_pool_waits": "sum(rate(db_pool_waits_total[1m]))",
    "outbox_pending": "sum(outbox_pending)",
    "queue_ready": "sum(rabbitmq_detailed_queue_messages_ready"
    '{queue=~"jobs[.]commands.*",queue!~".*dead"})',
    "workers": 'count(up{job="worker"} == 1)',
    "workers_busy": "sum(worker_busy_consumers)",
    "job_p50_s": "histogram_quantile(0.5, sum by (le) "
    "(rate(worker_command_duration_seconds_bucket[1m])))",
    "predictions_failed": '(sum(rate(predictions_total{outcome!="ok"}[1m])) or vector(0))'
    " / sum(rate(predictions_total[1m]))",
    "predictor_lag_s": 'max(state_lag_seconds{job="predictor"})',
    "cpu_throttled": 'avg(pod:cpu_throttled:ratio{pod=~"(api|worker)-.*"})',
}

# The smallest change in each that matters: below it, nothing is unusual
# enough to alarm, however steady the signal was. A signal that was always
# zero has no spread, and then one failed prediction is infinitely
# unusual. Statistics can't say what size of change matters; someone who
# knows the system has to, which is what an alert rule's threshold is.
MIN_CHANGE = {
    "api_requests": 5.0,  # requests a second
    "api_errors": 0.01,  # 1% of requests: the availability SLO's budget
    "api_p50_s": 0.05,
    "api_p99_s": 0.1,
    "db_pool_waits": 1.0,  # waits a second
    "outbox_pending": 100,
    "queue_ready": 20,  # commands waiting
    "workers": 2,  # the autoscaler adding one is its job
    "workers_busy": 4,
    "job_p50_s": 0.1,
    "predictions_failed": 0.05,  # 5% of predictions
    "predictor_lag_s": 5.0,
    "cpu_throttled": 0.1,
}

# Prometheus's own alerts, for comparison: 1 while firing, else 0.
ALERTS = ["ApiErrorBudgetBurn", "ApiErrorBudgetBurnSlow", "ApiLatencyBudgetBurn", "JobQueueBacklog"]


def query_range(url: str, expr: str, start: float, end: float, step: float) -> dict[float, float]:
    params = urllib.parse.urlencode({"query": expr, "start": start, "end": end, "step": step})
    reply = json.loads(urllib.request.urlopen(f"{url}/api/v1/query_range?{params}").read())
    result = reply["data"]["result"]
    if not result:
        return {}
    return {float(t): float(v) for t, v in result[0]["values"]}


def fetch(url: str, start: float, end: float, step: float = 15.0) -> dict[str, np.ndarray]:
    """Every signal, and every alert, on the same grid of times."""
    start = np.floor(start / step) * step  # on the grid, so Prometheus's times match ours exactly
    times = np.arange(start, end, step)
    table = {"time": times}
    for name, expr in SIGNALS.items():
        got = query_range(url, expr, start, end, step)
        table[name] = np.array([got.get(float(t), np.nan) for t in times])
    for name in ALERTS:
        got = query_range(
            url, f'max(ALERTS{{alertname="{name}",alertstate="firing"}})', start, end, step
        )
        table[f"alert:{name}"] = np.array([got.get(float(t), 0.0) for t in times])
    return table


def save(table: dict[str, np.ndarray], path: Path) -> None:
    import pyarrow as pa
    import pyarrow.parquet as pq

    path.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(pa.table(table), path)


def load(path: Path) -> dict[str, np.ndarray]:
    import pyarrow.parquet as pq

    t = pq.read_table(path)
    return {name: t[name].to_numpy() for name in t.column_names}
~~~

`MIN_CHANGE` came later, from the first run's results; it is explained below.

### The detectors

Create `lab/src/lab/anomaly.py`:

<!-- file: lab/src/lab/anomaly.py -->
~~~python
"""Finding when something is wrong, without being told what to look for (step 12).

An alert rule is a question someone thought to ask: "are more than 1% of
requests failing?" Anomaly detection asks a vaguer one of every signal at
once: "is this unlike what it usually is?" It can find what nobody
thought to write a rule for, and it raises alarms for things nobody cares
about. Which wins depends on the system, so measure: inject incidents at
known times (incidents.py) and score every detector on the same truth.

Each detector learns "usual" from a quiet stretch (the warm-up), then
gives every signal at every moment a score: how unusual it is. Above the
detector's threshold for `need` moments in a row is an alarm. The
detectors, simplest first:

- threshold: how many standard deviations from the warm-up's mean. Fine
  for a bell curve; real signals have long tails, and their rare normal
  spikes look like incidents.
- mad: the same, from the median, in units of the median absolute
  deviation. Robust: a few spikes in the warm-up don't stretch the scale.
- ewma: from an exponentially weighted moving average and variance that
  keep learning. Follows slow change (a busier afternoon is not an
  incident), and so also gets used to an incident that lasts.
- forest: an isolation forest over all signals together. It isolates
  points with random cuts; the unusual ones take few cuts. It can find a
  combination that's odd when no signal alone is.

A signal that was there all through the warm-up and then has no value is
unusual too (Prometheus's absent()): the thing reporting it is gone.
"""

from dataclasses import dataclass

import numpy as np

MAD_TO_SD = 1.4826  # the MAD of a normal distribution is 0.6745 standard deviations


def _scale_floor(center: np.ndarray, scale: np.ndarray) -> np.ndarray:
    """A signal that never moved in the warm-up has a spread of zero, and
    then any change at all is infinitely unusual. Floor the spread at 5% of
    the signal's typical size (and a tiny absolute amount, for zero)."""
    return np.maximum(scale, np.maximum(0.05 * np.abs(center), 1e-6))


def _absent(train: np.ndarray, x: np.ndarray) -> np.ndarray:
    """True where a signal that (almost) always had a value has none."""
    present = np.mean(~np.isnan(train), axis=0) > 0.99
    return np.isnan(x) & present


def _score(x, center, scale, absent, min_change) -> np.ndarray:
    """How many spreads x is from center; 0 for a change smaller than min_change."""
    with np.errstate(invalid="ignore"):
        dev = np.abs(x - center)
        z = np.where(dev < min_change, 0.0, dev / scale)
    return np.where(absent, np.inf, np.nan_to_num(z, nan=0.0))


def threshold_scores(train: np.ndarray, x: np.ndarray, min_change=0.0) -> np.ndarray:
    center = np.nanmean(train, axis=0)
    scale = _scale_floor(center, np.nanstd(train, axis=0))
    return _score(x, center, scale, _absent(train, x), min_change)


def mad_scores(train: np.ndarray, x: np.ndarray, min_change=0.0) -> np.ndarray:
    center = np.nanmedian(train, axis=0)
    mad = np.nanmedian(np.abs(train - center), axis=0) * MAD_TO_SD
    return _score(x, center, _scale_floor(center, mad), _absent(train, x), min_change)


def ewma_scores(
    train: np.ndarray, x: np.ndarray, min_change=0.0, halflife: float = 20, clip: float = 3
) -> np.ndarray:
    """Each moment scored against the average and variance of everything
    before it, weighted so that a point `halflife` moments old counts half.
    Starts from the warm-up's mean and variance; learns from every value."""
    alpha = 1 - 0.5 ** (1 / halflife)
    mean, var = np.nanmean(train, axis=0), np.nanvar(train, axis=0)
    absent = _absent(train, x)
    out = np.zeros_like(x, dtype=float)
    for t in range(len(x)):
        scale = _scale_floor(mean, np.sqrt(var))
        out[t] = _score(x[t], mean, scale, absent[t], min_change)
        seen = ~np.isnan(x[t])
        # Learn from at most `clip` spreads of change per moment. Unclipped,
        # one huge value inflates the variance so much that the next looks
        # normal: the alarm, needing two in a row, never comes (its test).
        diff = np.clip(np.where(seen, x[t] - mean, 0.0), -clip * scale, clip * scale)
        mean = mean + alpha * diff
        var = np.where(seen, (1 - alpha) * (var + alpha * diff**2), var)
    return out


def forest_scores(train: np.ndarray, x: np.ndarray, min_change=0.0, seed: int = 1) -> np.ndarray:
    """One score per moment, for all signals together: how much more easily
    the forest isolates it than the warm-up's typical moment. Signals are
    put on one scale first (median and MAD), a missing value is a value of
    its own, far from any real one."""
    from sklearn.ensemble import IsolationForest

    center = np.nanmedian(train, axis=0)
    scale = _scale_floor(center, np.nanmedian(np.abs(train - center), axis=0) * MAD_TO_SD)

    def prepare(a):
        dev = a - center
        z = np.where(np.abs(dev) < min_change, 0.0, dev / scale)
        return np.nan_to_num(np.clip(z, -1e3, 1e3), nan=-1e3)

    forest = IsolationForest(n_estimators=200, random_state=seed).fit(prepare(train))
    usual = -forest.score_samples(prepare(train))  # higher: more unusual
    raw = -forest.score_samples(prepare(x))
    # In units of the warm-up's own spread of scores, like the others.
    center_s = np.median(usual)
    scale_s = max(np.median(np.abs(usual - center_s)) * MAD_TO_SD, 1e-9)
    return ((raw - center_s) / scale_s)[:, None]


DETECTORS = {
    "threshold": threshold_scores,
    "mad": mad_scores,
    "ewma": ewma_scores,
    "forest": forest_scores,
}

# Each detector's limit, chosen on step 12's incident run, then frozen
# before the quiet hour that tests them. The forest's scores are
# compressed (a point far out isolates in hardly fewer cuts than one just
# outside), so its limit is lower.
LIMITS = {"threshold": 5.0, "mad": 5.0, "ewma": 5.0, "forest": 3.0}


def alarms(scores: np.ndarray, limit: float, need: int = 2) -> np.ndarray:
    """True where a score has been above limit for `need` moments in a row
    (any signal): one odd sample is noise more often than an incident."""
    over = (scores > limit).any(axis=1)
    run = np.zeros(len(over), int)
    for t, o in enumerate(over):
        run[t] = run[t - 1] + 1 if o and t else int(o)
    return run >= need


def events(times: np.ndarray, alarm: np.ndarray, merge_s: float = 60) -> list[tuple[float, float]]:
    """Alarmed moments as (start, end) spans, joining spans less than
    merge_s apart: one problem, one page, not ten."""
    out = []
    for t, a in zip(times, alarm, strict=True):
        if not a:
            continue
        if out and t - out[-1][1] <= merge_s:
            out[-1] = (out[-1][0], t)
        else:
            out.append((t, t))
    return out


@dataclass
class Score:
    found: dict[str, float | None]  # incident -> seconds to the first alarm, None if missed
    alarms: int  # alarm events after the warm-up
    false: int  # of those, the ones not during (or just after) an incident
    quiet_hours: float  # time with no incident on, after the warm-up
    alarmed: float  # the share of the time after the warm-up spent alarmed
    windows: float  # the share of it inside an incident's window: what alarming at random would hit
    quiet_alarmed: float  # the share of the quiet time spent alarmed: false alarms, by the clock

    @property
    def recall(self) -> float:
        if not self.found:
            return float("nan")
        return sum(v is not None for v in self.found.values()) / len(self.found)

    @property
    def precision(self) -> float:
        return (self.alarms - self.false) / self.alarms if self.alarms else float("nan")

    @property
    def false_per_hour(self) -> float:
        return self.false / self.quiet_hours


def score(
    times: np.ndarray, alarm: np.ndarray, truth: list[dict], from_s: float, grace_s: float = 120
) -> Score:
    """An incident is found if an alarm falls within it, or within grace_s
    after it ends (signals lag: a one-minute rate takes a minute to fall).
    An alarm event is false if it touches no incident's window."""
    windows = [(i["start"], i["end"] + grace_s) for i in truth]
    after = times >= from_s
    found = {}
    for i, (lo, hi) in zip(truth, windows, strict=True):
        hits = times[alarm & after & (times >= lo) & (times <= hi)]
        found[i["name"]] = float(hits[0] - i["start"]) if len(hits) else None
    spans = events(times[after], alarm[after])
    false = sum(not any(s <= hi and e >= lo for lo, hi in windows) for s, e in spans)
    step = float(np.median(np.diff(times)))
    busy = np.zeros(len(times), bool)
    for lo, hi in windows:
        busy |= (times >= lo) & (times <= hi)
    quiet = float((after & ~busy).sum() * step / 3600)
    n = max(after.sum(), 1)
    calm = after & ~busy
    return Score(
        found,
        len(spans),
        false,
        quiet,
        (alarm & after).sum() / n,
        (busy & after).sum() / n,
        (alarm & calm).sum() / max(calm.sum(), 1),
    )


def evaluate(
    table: dict[str, np.ndarray],
    names: list[str],
    truth: list[dict],
    learned_until: float,
    limits: dict[str, float],
    need: int = 2,
    min_change: np.ndarray | float = 0.0,
) -> dict[str, tuple[Score, np.ndarray, np.ndarray]]:
    """Every detector on the same signals and truth: its score, its alarms,
    and, per moment, the signal that scored highest (what it would blame)."""
    times = table["time"]
    x = np.column_stack([table[n] for n in names])
    train = x[times < learned_until]
    out = {}
    for name, detector in DETECTORS.items():
        s = detector(train, x, min_change)
        alarm = alarms(s, limits[name], need)
        out[name] = (score(times, alarm, truth, learned_until), alarm, np.argmax(s, axis=1))
    return out
~~~

Read it in this order. `threshold_scores`, `mad_scores` and `ewma_scores` each turn a matrix of signals (moments × signals) into scores of the same shape. `forest_scores` returns one column, for all signals together. `alarms` applies a limit and the two-in-a-row rule. `events` joins alarmed moments into spans. `score` compares those with the truth. `evaluate` runs them all.

### Logs as signals: Drain

Create `lab/src/lab/drain.py`:

<!-- file: lab/src/lab/drain.py -->
~~~python
"""Log lines into templates: Drain (He, Zhu, Zheng and Lyu, ICWS 2017), from scratch (step 12).

A log line is a template filled in with values: "connection from
10.244.1.7:5321 closed after 312 ms" is "connection from <*> closed after
<*> ms". Count lines per template and a log becomes a set of signals,
like metrics, and a template never seen before is news. Drain finds the
templates as the lines arrive, in one pass, without being told them:

1. Mask what is obviously a value (numbers, addresses, IDs) as <*>.
2. Walk a tree of fixed depth: first by the number of tokens (lines of a
   template have the same length), then by the first few tokens (where
   the constant words usually are; a token with a digit in it goes the
   <*> way). The leaf holds the templates that might match.
3. Pick the leaf's template with the most identical tokens. If enough of
   them match (sim_threshold), the line is that template's, and tokens
   that differ become <*>; otherwise it starts a template of its own.

Structured (JSON) lines are flattened first, to "level msg key=value
...", and go through the same steps: their msg is usually the template
already, which is what structured logging is for.
"""

import json
import re
from dataclasses import dataclass, field

import numpy as np

WILD = "<*>"
MASKS = [
    re.compile(r"\d{4}-\d{2}-\d{2}[T ][\d:.]+(Z|[+-]\d{2}:?\d{2})?"),  # timestamps
    re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"),  # UUIDs
    re.compile(r"\b\d{1,3}(\.\d{1,3}){3}(:\d+)?\b"),  # IPv4, with a port
    re.compile(r"\b(0x)?[0-9a-f]{12,}\b"),  # long hexadecimal: hashes, IDs
    re.compile(r"(?<![\w.])-?\d+(\.\d+)?(ms|µs|us|ns|s|m|h|B|KiB|MiB|%)?(?![\w.])"),  # numbers
]


def flatten(message: str) -> str:
    """A JSON line as text: level, msg, then key=value by key. Others as they are."""
    if not message.startswith("{"):
        return message
    try:
        record = json.loads(message)
    except ValueError:
        return message
    if not isinstance(record, dict):
        return message
    level, msg = record.pop("level", ""), record.pop("msg", "")
    record.pop("time", None)
    rest = " ".join(f"{k}={v}" for k, v in sorted(record.items()))
    return f"{level} {msg} {rest}".strip()


def mask(text: str) -> str:
    for pattern in MASKS:
        text = pattern.sub(WILD, text)
    return text


@dataclass
class Template:
    id: int
    tokens: list[str]
    count: int = 0

    @property
    def text(self) -> str:
        return " ".join(self.tokens)


@dataclass
class Drain:
    depth: int = 4  # the tree's levels: the root, the length, then depth - 2 first tokens
    sim_threshold: float = 0.4
    max_children: int = 100
    templates: list[Template] = field(default_factory=list)
    tree: dict = field(default_factory=dict)

    def add(self, line: str) -> Template:
        """The template line belongs to, made or widened as needed."""
        tokens = mask(flatten(line)).split() or [""]
        node = self.tree.setdefault(len(tokens), {})
        for token in tokens[: self.depth - 2]:
            key = WILD if any(c.isdigit() for c in token) else token
            if key not in node and len(node) >= self.max_children:
                key = WILD  # a full node sends the rest down one shared branch
            node = node.setdefault(key, {})
        leaf = node.setdefault(None, [])  # the templates live under the key None
        best, best_sim = None, -1.0
        for t in leaf:
            same = sum(a == b for a, b in zip(t.tokens, tokens, strict=True) if a != WILD)
            sim = same / len(tokens)
            if sim > best_sim:
                best, best_sim = t, sim
        if best is None or best_sim < self.sim_threshold:
            best = Template(len(self.templates), tokens)
            self.templates.append(best)
            leaf.append(best)
        else:
            best.tokens = [a if a == b else WILD for a, b in zip(best.tokens, tokens, strict=True)]
        best.count += 1
        return best


TROUBLE = re.compile(
    r"\b(error|warn\w*|fail\w*|refused|timeout|denied|panic|fatal)\b", re.IGNORECASE
)


def troubled(message: str) -> bool:
    """Does the line report a problem? A JSON line says so in its level or
    its error field (an empty error= is no error); any other line, in words."""
    if message.startswith("{"):
        try:
            record = json.loads(message)
        except ValueError:
            record = None
        if isinstance(record, dict):
            return record.get("level") in ("WARN", "ERROR") or bool(record.get("error"))
    return bool(TROUBLE.search(message))


def log_signals(
    rows: list[tuple[float, str, str]], times: np.ndarray, learned_until: float
) -> tuple[dict[str, np.ndarray], Drain, dict[int, float]]:
    """Two signals from the logs, on the metrics' grid of times:
    log_new: lines of templates first seen after learned_until (news);
    log_trouble: lines that say error, failure, refusal, timeout.
    And the Drain that read them, and each template's first time."""
    d, first = Drain(), {}
    step = float(np.median(np.diff(times)))
    new = np.zeros(len(times))
    trouble = np.zeros(len(times))
    for at, source, message in rows:
        t = d.add(f"{source} {message}")
        first.setdefault(t.id, at)
        k = int((at - times[0]) // step)
        if not 0 <= k < len(times):
            continue
        if first[t.id] > learned_until:
            new[k] += 1
        if troubled(message):
            trouble[k] += 1
    return {"log_new": new, "log_trouble": trouble}, d, first
~~~

### Tests

The tests cover each detector on a synthetic signal with a known incident, Drain on lines with known templates, and the incident runner with a fake clock. For the detectors:

- Every detector finds a large step quickly.
- Long tails stretch the standard deviation and not the MAD.
- EWMA gets used to an incident that never ends.
- A signal that vanishes is an alarm.
- A change smaller than the minimum isn't.
- The score counts what it should.

Create `lab/tests/test_anomaly.py`:

<!-- file: lab/tests/test_anomaly.py -->
~~~python
import numpy as np

from lab import anomaly

STEP = 15.0
TIMES = np.arange(0, 3600, STEP)  # an hour, every 15 s
LEARN = 900.0  # the first fifteen minutes are the warm-up
INCIDENT = {"name": "slow", "start": 1800.0, "end": 1980.0}


def signal(seed=1, tail=False):
    rng = np.random.default_rng(seed)
    x = rng.standard_t(2, len(TIMES)) if tail else rng.normal(0, 1, len(TIMES))
    x = 10 + x
    x[(TIMES >= INCIDENT["start"]) & (TIMES < INCIDENT["end"])] += 15  # the incident
    return x[:, None]


def run(name, x, limit=5.0):
    s = anomaly.DETECTORS[name](x[TIMES < LEARN], x)
    alarm = anomaly.alarms(s, limit)
    return anomaly.score(TIMES, alarm, [INCIDENT], LEARN)


def test_every_detector_finds_a_big_step_quickly():
    for name in anomaly.DETECTORS:
        sc = run(name, signal())
        assert sc.found["slow"] is not None and sc.found["slow"] <= 2 * STEP, name


def test_long_tails_fool_the_mean_and_standard_deviation_less_than_you_think():
    """A t-distribution with 2 degrees of freedom: normal spikes ten times
    the typical spread. Scored in standard deviations, a spike in the
    warm-up inflates the scale; the median and MAD aren't moved by it."""
    x = signal(seed=4, tail=True)
    train = x[TIMES < LEARN]
    sd_scale = np.std(train)
    mad_scale = np.median(np.abs(train - np.median(train))) * anomaly.MAD_TO_SD
    assert sd_scale > 1.5 * mad_scale  # the spikes stretched the standard deviation
    assert run("mad", x).false >= run("threshold", x).false  # and so threshold alarms less


def test_ewma_gets_used_to_an_incident_that_lasts():
    x = signal()
    x[TIMES >= INCIDENT["start"]] = 25  # it never ends: from 10 to 25 for good
    s = anomaly.ewma_scores(x[TIMES < LEARN], x)
    assert s[np.searchsorted(TIMES, INCIDENT["start"]), 0] > 5  # it notices
    assert s[-1, 0] < 1  # and an hour later it's the new normal


def test_a_signal_that_disappears_is_an_alarm():
    x = signal()
    x[TIMES >= 2400] = np.nan  # its exporter is gone
    s = anomaly.mad_scores(x[TIMES < LEARN], x)
    assert np.isinf(s[-1, 0])


def test_alarms_need_moments_in_a_row_and_events_join_close_ones():
    scores = np.array([0, 9, 0, 9, 9, 0, 0, 0, 0, 0, 9, 9, 9])[:, None]
    alarm = anomaly.alarms(scores, 5, need=2)
    assert alarm.tolist() == [False] * 4 + [True] + [False] * 6 + [True, True]
    times = np.arange(len(alarm)) * STEP
    assert anomaly.events(times, alarm, merge_s=60) == [(60.0, 60.0), (165.0, 180.0)]
    assert anomaly.events(times, alarm, merge_s=120) == [(60.0, 180.0)]


def test_the_score_counts_found_missed_and_false():
    alarm = np.zeros(len(TIMES), bool)
    alarm[np.searchsorted(TIMES, 1830)] = True  # 30 s into the incident
    alarm[np.searchsorted(TIMES, 3000)] = True  # nothing happening: false
    alarm[np.searchsorted(TIMES, 300)] = True  # in the warm-up: not counted
    other = {"name": "never", "start": 2500.0, "end": 2600.0}
    sc = anomaly.score(TIMES, alarm, [INCIDENT, other], LEARN)
    assert sc.found == {"slow": 30.0, "never": None}
    assert (sc.alarms, sc.false, sc.recall, sc.precision) == (2, 1, 0.5, 0.5)


def test_a_change_too_small_to_matter_is_no_alarm_however_steady_the_signal_was():
    x = np.zeros((len(TIMES), 1))  # failed predictions: none at all in the warm-up
    x[TIMES >= 2000] = 0.01  # then 1%
    plain = anomaly.mad_scores(x[TIMES < LEARN], x)
    assert plain[-1, 0] > 1e3  # a spread of zero: 1% is thousands of spreads away
    floored = anomaly.mad_scores(x[TIMES < LEARN], x, min_change=np.array([0.05]))
    assert floored[-1, 0] == 0  # under the 5% that matters
~~~

Create `lab/tests/test_drain.py`:

<!-- file: lab/tests/test_drain.py -->
~~~python
from lab import drain


def test_lines_of_one_template_become_one_template():
    d = drain.Drain()
    a = d.add("connection from 10.244.1.7:5321 closed after 312 ms")
    b = d.add("connection from 10.244.2.9:40001 closed after 7 ms")
    c = d.add("checkpoint starting: time")
    assert a is b and c is not a
    assert a.text == "connection from <*> closed after <*> ms" and a.count == 2


def test_a_value_drain_cannot_mask_becomes_a_wildcard_by_comparison():
    d = drain.Drain()
    a = d.add("login by alice accepted from the web")
    b = d.add("login by bob accepted from the web")
    assert a is b and a.text == "login by <*> accepted from the web"


def test_a_value_among_the_first_tokens_splits_the_template():
    """The first depth - 2 tokens choose the branch: lines that differ there
    are never compared. Drain's bet is that lines begin with constants."""
    d = drain.Drain()
    assert d.add("alice logged in from the web") is not d.add("bob logged in from the web")


def test_too_different_lines_of_the_same_length_stay_apart():
    d = drain.Drain()
    a = d.add("queue jobs.commands declared durable")
    b = d.add("queue jobs.events purged by admin")
    assert a is not b


def test_json_lines_are_flattened_by_key_without_their_time():
    line = (
        '{"time":"2026-10-18T20:17:00Z","level":"INFO","msg":"request",'
        '"route":"POST /jobs","status":201}'
    )
    assert drain.flatten(line) == "INFO request route=POST /jobs status=201"
    d = drain.Drain()
    t = d.add(line)
    assert t is d.add(line.replace("201", "503").replace("20:17:00", "20:18:30"))
    assert t.text == "INFO request route=POST /jobs status=<*>"  # a status code is a number: masked


def test_trouble_is_the_level_or_an_error_for_json_and_words_otherwise():
    assert not drain.troubled('{"level":"INFO","msg":"command handled","error":""}')
    assert drain.troubled('{"level":"INFO","msg":"command handled","error":"deadline exceeded"}')
    assert drain.troubled('{"level":"WARN","msg":"slow"}')
    assert drain.troubled("2026-10-18 20:31:02 UTC [77] FATAL:  password authentication failed")
    assert not drain.troubled("2026-10-18 20:31:02 UTC [77] LOG:  checkpoint complete")
~~~

Create `lab/tests/test_incidents.py`:

<!-- file: lab/tests/test_incidents.py -->
~~~python
import json

import pytest

from lab import incidents

PLAN = {
    "warmup_s": 100,
    "gap_s": [10, 20],
    "seed": 3,
    "incidents": [
        incidents.Incident("a", "echo a-on >> {log}", "echo a-off >> {log}", 30),
        incidents.Incident("b", "echo b-on >> {log}", "echo b-off >> {log}", 40),
    ],
}


class Clock:
    """A fake clock that sleep moves forward."""

    def __init__(self):
        self.now = 1000.0

    def time(self):
        return self.now

    def sleep(self, s):
        self.now += s


def plan_logging_to(path):
    p = dict(PLAN)
    p["incidents"] = [
        incidents.Incident(i.name, i.start.format(log=path), i.stop.format(log=path), i.duration_s)
        for i in PLAN["incidents"]
    ]
    return p


def test_the_schedule_is_the_seeds():
    a, end_a = incidents.schedule(PLAN)
    b, end_b = incidents.schedule(PLAN)
    assert [(at, i.name) for at, i in a] == [(at, i.name) for at, i in b] and end_a == end_b
    assert a[0][0] == 100 and {i.name for _, i in a} == {"a", "b"}
    first, second = a
    assert 10 <= second[0] - (first[0] + first[1].duration_s) <= 20


def test_run_writes_down_when_each_incident_was_on(tmp_path):
    clock, log, out = Clock(), tmp_path / "commands.log", tmp_path / "truth.jsonl"
    incidents.run(plan_logging_to(log), out, clock=clock.time, sleep=clock.sleep)
    begin, end, truth = incidents.truth(out)
    timetable, total = incidents.schedule(PLAN)
    assert begin == 1000.0 and end == 1000.0 + total
    for (at, incident), seen in zip(timetable, truth, strict=True):
        assert seen == {
            "name": incident.name,
            "start": 1000.0 + at,
            "end": 1000.0 + at + incident.duration_s,
        }
    first = timetable[0][1].name
    assert log.read_text().split()[:2] == [f"{first}-on", f"{first}-off"]


def test_an_interrupted_incident_is_still_stopped(tmp_path):
    clock, log = Clock(), tmp_path / "commands.log"

    def sleep(s):
        if log.exists() and log.read_text().endswith("-on\n"):
            raise KeyboardInterrupt  # Ctrl-C, mid-incident
        clock.sleep(s)

    with pytest.raises(KeyboardInterrupt):
        incidents.run(plan_logging_to(log), tmp_path / "t.jsonl", clock=clock.time, sleep=sleep)
    on, off = log.read_text().split()
    assert on.endswith("-on") and off == on.replace("-on", "-off")
    assert json.loads((tmp_path / "t.jsonl").read_text().splitlines()[0]) == {"plan_start": 1000.0}


def test_a_quiet_plan_is_its_warm_up_and_tail():
    timetable, end = incidents.schedule(
        {"warmup_s": 900, "gap_s": [0, 0], "seed": 1, "tail_s": 2700, "incidents": []}
    )
    assert timetable == [] and end == 3600
~~~

Two of these tests caught my own first versions out. EWMA first learnt from every value as it was. One incident value, fifteen spreads out, inflated its variance so much that the next value looked normal, so the two-in-a-row rule never fired:

~~~text
E           AssertionError: ewma
tests/test_anomaly.py:28: AssertionError
1 failed, 5 deselected in 0.35s
~~~

Hence `clip`: learn from at most three spreads of change per moment. And Drain kept "alice logged in" and "bob logged in" apart. That's not a bug but Drain's design: the first tokens choose the branch, and lines that differ there are never compared. The test now says so.

### The commands

In `lab/src/lab/cli.py`:

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

def cmd_export(args: argparse.Namespace) -> int:
~~~

to:

~~~python

def cmd_incidents(args: argparse.Namespace) -> int:
    from lab import incidents

    plan = incidents.load(args.plan)
    timetable, end = incidents.schedule(plan)
    for at, incident in timetable:
        print(f"{at / 60:5.1f} min  {incident.name} for {incident.duration_s:.0f} s")
    print(f"{end / 60:5.1f} min  the end")
    if args.action == "run":
        incidents.run(plan, args.out)
        print(f"wrote {args.out}")
    return 0


def cmd_logs(args: argparse.Namespace) -> int:
    from lab import logs

    n = logs.collect(args.namespace, args.out, args.seconds)
    print(f"followed {n} containers for {args.seconds:.0f} s into {args.out}")
    return 0


def cmd_signals(args: argparse.Namespace) -> int:
    from lab import incidents, signals

    begin, end, _ = incidents.truth(args.truth)
    table = signals.fetch(args.prometheus, begin, end, args.step)
    signals.save(table, args.out)
    n = len(table["time"])
    print(f"{n} moments of {len(table) - 1} signals, {args.step:.0f} s apart: {args.out}")
    return 0


def cmd_detect(args: argparse.Namespace) -> int:
    import numpy as np

    from lab import anomaly, drain, incidents, logs, signals
    from lab.warehouse import table as show

    begin, _, truth = incidents.truth(args.truth)
    learned_until = begin + incidents.load(args.plan)["warmup_s"]
    data = signals.load(args.signals)
    names = list(signals.SIGNALS)
    limits = dict.fromkeys(anomaly.DETECTORS, args.limit) if args.limit else anomaly.LIMITS
    floors = np.array([signals.MIN_CHANGE[n] for n in names]) if args.min_change else 0.0
    results = anomaly.evaluate(data, names, truth, learned_until, limits, args.need, floors)
    times = data["time"]
    # Prometheus's own alerts, as a detector: alarmed while any fires.
    fired = np.column_stack([data[f"alert:{a}"] for a in signals.ALERTS]).max(axis=1) > 0
    results["alerts"] = (anomaly.score(times, fired, truth, learned_until), fired, None)
    if args.logs:
        rows = logs.read(args.logs)
        found, d, _ = drain.log_signals(rows, times, learned_until)
        x = np.column_stack([found["log_new"], found["log_trouble"]])
        s = anomaly.mad_scores(x[times < learned_until], x)
        alarm = anomaly.alarms(s, args.limit or 5.0, need=1)
        results["logs"] = (anomaly.score(times, alarm, truth, learned_until), alarm, None)
        print(f"logs: {len(rows)} lines, {len(d.templates)} templates")

    def ttd(v):
        return "missed" if v is None else f"{v:.0f} s"

    rows = []
    for name, (sc, _, _) in results.items():
        found = [v for v in sc.found.values() if v is not None]
        rows.append(
            [
                name,
                f"{len(found)}/{len(sc.found)}",
                sc.alarms,
                sc.false,
                sc.false_per_hour,
                sc.precision,
                float(np.median(found)) if found else float("nan"),
                sc.alarmed * 100,
                sc.quiet_alarmed * 100,
            ]
        )
    some = next(iter(results.values()))[0]
    print(
        f"after the warm-up: {some.quiet_hours * 60:.0f} quiet minutes;"
        f" incident windows (with 2 minutes' grace) are {some.windows:.0%} of the time"
    )
    learned_min = (learned_until - times[0]) / 60
    said = args.limit or ", ".join(f"{k} {v:g}" for k, v in limits.items())
    print(f"limits {said}; {args.need} in a row; learned from the first {learned_min:.0f} min")
    print(
        show(
            [
                "detector",
                "found",
                "alarms",
                "false",
                "false_per_h",
                "precision",
                "median_ttd_s",
                "alarmed_%",
                "quiet_alarmed_%",
            ],
            rows,
        )
    )
    print()
    rows = []
    for i in truth:
        row = [i["name"], f"{(i['end'] - i['start']):.0f} s"]
        for sc, _, _ in results.values():
            row.append(ttd(sc.found[i["name"]]))
        rows.append(row)
    print("seconds from the start of each incident to the first alarm:")
    print(show(["incident", "lasted", *results], rows))
    if args.blame:
        sc, alarm, blame = results[args.blame]
        print(f"\n{args.blame}: the signal it blames at its first alarm in each incident")
        for i in truth:
            v = sc.found[i["name"]]
            if v is not None:
                k = int(np.searchsorted(times, i["start"] + v))
                print(f"  {i['name']:<15} {names[blame[k]]}")
    return 0


def cmd_export(args: argparse.Namespace) -> int:
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

    ex = sub.add_parser("export", help="fit the served models on every row and save them")
~~~

to:

~~~python

    inc = sub.add_parser("incidents", help="break the system on a schedule, and record when")
    inc.add_argument("action", choices=["plan", "run"], help="plan: print the schedule only")
    inc.add_argument("plan", type=Path)
    inc.add_argument("--out", type=Path, default=Path("results/truth.jsonl"))
    inc.set_defaults(func=cmd_incidents)

    lg = sub.add_parser("logs", help="follow every container's log in a namespace, to files")
    lg.add_argument("out", type=Path)
    lg.add_argument("--namespace", default="runway")
    lg.add_argument("--seconds", type=float, required=True)
    lg.set_defaults(func=cmd_logs)

    sg = sub.add_parser(
        "signals", help="the system's signals from Prometheus, over an incident run"
    )
    sg.add_argument("--truth", type=Path, required=True, help="lab incidents run's output")
    sg.add_argument("--prometheus", default="http://localhost:9091")
    sg.add_argument("--step", type=float, default=15.0)
    sg.add_argument("--out", type=Path, default=Path("results/signals.parquet"))
    sg.set_defaults(func=cmd_signals)

    dt = sub.add_parser("detect", help="score anomaly detectors against the incidents' truth")
    dt.add_argument("signals", type=Path)
    dt.add_argument("--truth", type=Path, required=True)
    dt.add_argument(
        "--plan", type=Path, required=True, help="the incident plan: its warm-up is learnt from"
    )
    dt.add_argument("--logs", type=Path, help="lab logs' directory: add the logs detector")
    dt.add_argument("--limit", type=float, help="alarm above this score (default: anomaly.LIMITS)")
    dt.add_argument("--need", type=int, default=2, help="moments in a row above the limit")
    dt.add_argument(
        "--min-change", action="store_true", help="ignore changes below signals.MIN_CHANGE"
    )
    dt.add_argument(
        "--blame", choices=["threshold", "mad", "ewma"], help="show the signal it blames"
    )
    dt.set_defaults(func=cmd_detect)

    ex = sub.add_parser("export", help="fit the served models on every row and save them")
~~~


<!-- run: cd lab && uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

### Run it: an hour of incidents

Three things at once, for 70 minutes:
- **steady load:** two loops of the three tenants at load 1, offset by 90 s, so the load never stops between runs, with fresh tokens before each;
- **every log followed;**
- **the incidents.**

~~~bash
lab() { uv run --project lab lab "$@"; }
lab incidents plan experiments/incidents/plan.toml
~~~

~~~text
 15.0 min  broker-slow for 180 s
 23.5 min  kafka-down for 180 s
 32.6 min  predictor-down for 180 s
 41.3 min  api-pods-lost for 60 s
 49.3 min  cpu-hog for 180 s
 57.6 min  db-slow for 180 s
 68.3 min  the end
wrote results/s12-truth.jsonl
~~~

~~~bash
loop() { # FIRST_SEED UNTIL: three-minute runs until the time
  local seed=$1
  while (( $(date +%s) < $2 )); do
    tokens
    uv run --project kload kload mix workloads/three-tenants.toml --seed $seed --load 1 --out results/s12-load-$seed.jsonl
    seed=$((seed + 2))
  done
}
until=$(( $(date +%s) + 4160 ))
lab logs results/s12-logs --seconds 4220 &
loop 1201 $until &
sleep 90; loop 1202 $until &
sleep 30; lab incidents run experiments/incidents/plan.toml --out results/s12-truth.jsonl
wait
~~~

46,982 jobs were accepted and 17 refused: all 17 during db-slow, requests that ran past the API's 2 s timeout. Not one during api-pods-lost: the API's remaining Pod took the traffic while the other two started. The log collector followed 70 containers, counting the replacements.

### Score it

~~~bash
lab signals --truth results/s12-truth.jsonl --out results/s12-signals.parquet
lab detect results/s12-signals.parquet --truth results/s12-truth.jsonl --plan experiments/incidents/plan.toml \
  --logs results/s12-logs --limit 5 --blame mad
~~~

~~~text
logs: 218248 lines, 274 templates
after the warm-up: 26 quiet minutes; incident windows (with 2 minutes' grace) are 52% of the time
limits 5.0; 2 in a row; learned from the first 15 min
 detector  found  alarms  false  false_per_h  precision  median_ttd_s  alarmed_%  quiet_alarmed_%
---------  -----  ------  -----  -----------  ---------  ------------  ---------  ---------------
threshold    6/6       6      0        0.000      1.000        30.518     45.327           18.627
      mad    6/6       7      1        2.353      0.857        21.987     60.748           34.314
     ewma    6/6       6      0        0.000      1.000        28.923     40.654           11.765
   forest    0/6       0      0        0.000        nan           nan      0.000            0.000
   alerts    0/6       0      0        0.000        nan           nan      0.000            0.000
     logs    4/6       4      0        0.000      1.000        10.993     33.645           21.569

seconds from the start of each incident to the first alarm:
      incident  lasted  threshold    mad   ewma  forest  alerts    logs
--------------  ------  ---------  -----  -----  ------  ------  ------
   broker-slow   183 s       33 s   33 s   33 s  missed  missed   153 s
    kafka-down   183 s        7 s    7 s    7 s  missed  missed     7 s
predictor-down   183 s       28 s   13 s   13 s  missed  missed    13 s
 api-pods-lost    61 s      131 s  116 s  116 s  missed  missed  missed
       cpu-hog   180 s       46 s   31 s   46 s  missed  missed  missed
       db-slow   180 s       24 s    9 s   24 s  missed  missed     9 s

mad: the signal it blames at its first alarm in each incident
  broker-slow     queue_ready
  kafka-down      outbox_pending
  predictor-down  predictor_lag_s
  api-pods-lost   db_pool_waits
  cpu-hog         queue_ready
  db-slow         db_pool_waits
~~~

At first sight the detectors win outright. Threshold, MAD and EWMA find all six incidents, typically within half a minute, and raise at most one false alarm. Runway's own alerts find none.

### Why the alerts found nothing

They weren't broken. When each was pending or firing, from Prometheus's `ALERTS` series, with `scripts/p7-pf-prom.sh` forwarding it to localhost:9091. Create `scripts/alert_spans.py`:

<!-- file: scripts/alert_spans.py -->
~~~python
"""When each of Runway's alerts was pending or firing during step 12's
incident run, and during which incidents. Needs Prometheus on
localhost:9091 (scripts/p7-pf-prom.sh or a port-forward)."""

import json
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

from lab import incidents

PROMETHEUS = "http://localhost:9091"
STEP = 15  # seconds between samples

begin, end, truth = incidents.truth(Path("results/s12-truth.jsonl"))


def clock(t: float) -> str:
    return datetime.fromtimestamp(t, UTC).strftime("%H:%M:%S")


for state in ("pending", "firing"):
    # DatabaseLoginNotRenewed fired for the expired certificate, not an incident.
    query = (
        f'max by (alertname) (ALERTS{{alertstate="{state}",'
        f'alertname!="DatabaseLoginNotRenewed"}})'
    )
    url = f"{PROMETHEUS}/api/v1/query_range?" + urllib.parse.urlencode(
        {"query": query, "start": begin, "end": end, "step": STEP}
    )
    for series in json.loads(urllib.request.urlopen(url).read())["data"]["result"]:
        times = [float(t) for t, _ in series["values"]]
        # Samples more than a step apart start a new span.
        spans, start = [], times[0]
        for a, b in zip(times, times[1:] + [None], strict=True):
            if b is None or b - a > STEP:
                spans.append((start, a))
                start = b
        for lo, hi in spans:
            during = [
                i["name"] for i in truth if lo <= i["end"] + 120 and hi >= i["start"]
            ]
            print(
                f"{series['metric']['alertname']:<24} {state:<8} "
                f"{clock(lo)} to {clock(hi)}  {(hi - lo) / 60 + STEP / 60:4.1f} min  "
                f"{', '.join(during) or '(no incident)'}"
            )
~~~

~~~bash
uv run --project lab python scripts/alert_spans.py
~~~

~~~text
JobQueueBacklog          pending  20:44:10 to 20:44:10   0.2 min  broker-slow
JobQueueBacklog          pending  20:45:40 to 20:46:10   0.8 min  broker-slow
JobQueueBacklog          pending  21:26:10 to 21:29:40   3.8 min  db-slow
PredictorInputsUnusual   pending  21:27:55 to 21:36:10   8.5 min  db-slow
~~~

`JobQueueBacklog` noticed broker-slow and db-slow, and waits five minutes before raising a ticket; each incident lasted three. `PredictorInputsUnusual` noticed what db-slow did to the queue lengths the predictor sees (step 11), and waits ten. The burn-rate alerts never even went pending, though during db-slow the API's p50 reached 1.7 s, seven times its 250 ms objective. Over the last five minutes 82% of job submissions were too slow, far past the 14.4% that pages. But the page also needs the last *hour* past 14.4%, and three slow minutes are 3.6% of an hour. That is the multi-window design (Phase 5): page only when the month's error budget is really in danger, which three minutes aren't. The detectors answer "is this unusual?"; the alerts answer "does this cost what we promised?". A short incident is a yes to the first and a no to the second, and both answers are right.

### Break it: an alarm that never stops

A detector that alarms all the time can score well on found, false and precision all at once. Count the time instead of the alarms: the table's last two columns are the share of the time after the warm-up spent alarmed, and the share of the *quiet* time. The incident windows, with two minutes' grace, are 52% of the time after the warm-up, and MAD was alarmed 61% of it: more than all the incidents put together. "Found 6/6, no false alarms" mostly meant "alarmed so long that the alarms ran into the incidents". Two things were inflating it.

First, signals that were exactly zero all through the warm-up: failed predictions, the queue, waits for a database connection. Their spread is zero, so one failed prediction scores as unusual without limit. Statistics alone can't say how big a change has to be before it matters. Someone who knows the system has to say it, and that is what an alert rule's threshold is. Hence `MIN_CHANGE` in `signals.py`, each value chosen for what the signal means: 5% of predictions failing, 20 commands waiting, a second worker added.

Second, where the remaining quiet-time alarms fell. Create `scripts/aftermath.py`:

<!-- file: scripts/aftermath.py -->
~~~python
"""The alarms step 12's detectors raised in quiet time: how long after the
last incident ended, and which signals they blamed."""

from collections import Counter
from pathlib import Path

import numpy as np

from lab import anomaly, incidents, signals

d = signals.load(Path("results/s12-signals.parquet"))
begin, _, truth = incidents.truth(Path("results/s12-truth.jsonl"))
learn = begin + incidents.load(Path("experiments/incidents/plan.toml"))["warmup_s"]
t, names = d["time"], list(signals.SIGNALS)
x = np.column_stack([d[n] for n in names])
floors = np.array([signals.MIN_CHANGE[n] for n in names])

busy = np.zeros(len(t), bool)
for i in truth:
    busy |= (t >= i["start"]) & (t <= i["end"] + 120)
quiet = (t >= learn) & ~busy
ends = np.array(sorted(i["end"] for i in truth))

for name in ("threshold", "mad", "ewma"):
    s = anomaly.DETECTORS[name](x[t < learn], x, floors)
    alarmed = np.where(anomaly.alarms(s, 5) & quiet)[0]
    since = [(t[k] - ends[ends < t[k]].max()) / 60 for k in alarmed]
    blamed = Counter(names[np.argmax(s[k])] for k in alarmed)
    print(
        f"{name}: {len(alarmed)} of {quiet.sum()} quiet moments alarmed;"
        f" minutes since the last incident ended:"
        f" {np.round(np.percentile(since, [0, 50, 100]), 1).tolist()};"
        f" blamed: {dict(blamed.most_common(3))}"
    )
~~~

~~~bash
uv run --project lab python scripts/aftermath.py
~~~

~~~text
threshold: 19 of 102 quiet moments alarmed; minutes since the last incident ended: [2.2, 3.2, 5.4]; blamed: {'predictor_lag_s': 10, 'api_requests': 5, 'predictions_failed': 4}
mad: 20 of 102 quiet moments alarmed; minutes since the last incident ended: [2.2, 3.3, 5.4]; blamed: {'predictions_failed': 10, 'api_requests': 5, 'predictor_lag_s': 4}
ewma: 11 of 102 quiet moments alarmed; minutes since the last incident ended: [2.2, 3.4, 4.7]; blamed: {'predictor_lag_s': 10, 'predictions_failed': 1}
~~~

Every one of them came 2 to 5.4 minutes after an incident's stop command: the system was still recovering. The restarted predictor was replaying its events and timing out its first calls (step 8's cold start), and clients were catching up. The incident ended when the system was healthy again, not when the fault was removed. Those alarms are true, and the truth file is what's wrong.

And the forest, with no alarm at limit 5, isn't broken either. An isolation forest's score is a rank, not a distance: a point a thousand spreads out isolates in hardly fewer cuts than one just outside, so its scores are compressed (here, from 0 to about 4). It learnt from 60 moments in 13 dimensions, too. Each detector needs its own limit. The trade-off, per detector, with `MIN_CHANGE`. Create `scripts/sweep.py`:

<!-- file: scripts/sweep.py -->
~~~python
"""Each of step 12's detectors at a range of limits: the incidents found,
against the share of quiet time alarmed."""

from pathlib import Path

import numpy as np

from lab import anomaly, incidents, signals

LIMITS = [2, 2.5, 3, 4, 5, 6, 8, 10, 15, 20]

d = signals.load(Path("results/s12-signals.parquet"))
begin, _, truth = incidents.truth(Path("results/s12-truth.jsonl"))
learn = begin + incidents.load(Path("experiments/incidents/plan.toml"))["warmup_s"]
t, names = d["time"], list(signals.SIGNALS)
x = np.column_stack([d[n] for n in names])
floors = np.array([signals.MIN_CHANGE[n] for n in names])

print(
    "found/6, and the share of quiet time alarmed, at each limit"
    " (two moments in a row; MIN_CHANGE):"
)
print(f"{'detector':>10} " + " ".join(f"{limit:>9}" for limit in LIMITS))
for name, detector in anomaly.DETECTORS.items():
    s = detector(x[t < learn], x, floors)
    cells = []
    for limit in LIMITS:
        sc = anomaly.score(t, anomaly.alarms(s, limit), truth, learn)
        found = sum(v is not None for v in sc.found.values())
        cells.append(f"{found} {sc.quiet_alarmed:4.0%}")
    print(f"{name:>10} " + " ".join(f"{c:>9}" for c in cells))
~~~

~~~bash
uv run --project lab python scripts/sweep.py
~~~

~~~text
found/6, and the share of quiet time alarmed, at each limit (two moments in a row; MIN_CHANGE):
  detector         2       2.5         3         4         5         6         8        10        15        20
 threshold    5  29%    5  23%    5  21%    5  20%    5  19%    5  16%    5  13%    5  13%    5  13%    5  13%
       mad    6  43%    6  23%    6  21%    6  20%    6  20%    6  19%    6  16%    6  15%    6  15%    5  15%
      ewma    5  17%    5  13%    5  13%    5  11%    5  11%    5  11%    4  10%    4  10%    4  10%    4  10%
    forest    6  30%    6  22%    5  14%    3   7%    3   1%    3   0%    0   0%    0   0%    0   0%    0   0%
~~~

Lower limits find more and alarm more, as any detector must. The forest at 3 finds five of six with 14% of the quiet time alarmed, in line with the others at 5.

I chose `MIN_CHANGE` and the limits *after* seeing this run, so its scores are now tuned to it, and flatter the detectors. The honest test is data they haven't seen. I froze them, recorded their files' hashes, and wrote down a prediction for an hour with nothing injected, before that hour was over:

~~~text
frozen 2026-10-18T21:47:56Z, before the quiet hour's end
a03c5ea4464e7b20f7ea0f9ca658afb74ed63a382cf4bd1dca20044c4638d4a6 lab/anomaly.py
ca3a175450ec2d7afcec61d051e3d24f5d48cbd40a450ba6c1f4c3f8a42cea82 lab/signals.py
338ecc18fd086df9acc8ae3fb1f5e21ccb2f542ed1dcefa3ef2a4662c46206b8 lab/drain.py
~~~

~~~text
prediction recorded 2026-10-18T21:58:27Z (the comment first said 21:59; corrected at 22:00:44Z, wording unchanged)
dbfc13f050ccbbc5d688c1f90f9b287fc2d70c2bc1664de9f6f75d4c58917fca
~~~

The incident run, scored with them: each detector's own limit from `anomaly.LIMITS`, and `MIN_CHANGE`.

~~~bash
lab detect results/s12-signals.parquet --truth results/s12-truth.jsonl --plan experiments/incidents/plan.toml \
  --logs results/s12-logs --min-change --blame mad
~~~

~~~text
logs: 218248 lines, 274 templates
after the warm-up: 26 quiet minutes; incident windows (with 2 minutes' grace) are 52% of the time
limits threshold 5, mad 5, ewma 5, forest 3; 2 in a row; learned from the first 15 min
 detector  found  alarms  false  false_per_h  precision  median_ttd_s  alarmed_%  quiet_alarmed_%
---------  -----  ------  -----  -----------  ---------  ------------  ---------  ---------------
threshold    5/6       5      0        0.000      1.000        27.588     43.925           18.627
      mad    6/6       6      0        0.000      1.000        30.518     49.533           19.608
     ewma    5/6       5      0        0.000      1.000        27.588     34.579           10.784
   forest    5/6       5      0        0.000      1.000        46.386     29.907           13.725
   alerts    0/6       0      0        0.000        nan           nan      0.000            0.000
     logs    4/6       4      0        0.000      1.000        10.993     33.645           21.569

seconds from the start of each incident to the first alarm:
      incident  lasted  threshold    mad    ewma  forest  alerts    logs
--------------  ------  ---------  -----  ------  ------  ------  ------
   broker-slow   183 s       33 s   33 s    33 s    33 s  missed   153 s
    kafka-down   183 s       22 s   22 s    22 s   232 s  missed     7 s
predictor-down   183 s       28 s   28 s    28 s   298 s  missed    13 s
 api-pods-lost    61 s     missed  131 s  missed  missed  missed  missed
       cpu-hog   180 s       46 s   46 s    46 s    46 s  missed  missed
       db-slow   180 s       24 s   24 s    24 s    24 s  missed     9 s

mad: the signal it blames at its first alarm in each incident
  broker-slow     queue_ready
  kafka-down      predictor_lag_s
  predictor-down  predictor_lag_s
  api-pods-lost   workers
  cpu-hog         predictions_failed
  db-slow         queue_ready
~~~

Fewer found (api-pods-lost goes, apart from MAD's late alarm in its aftermath), and the time alarmed falls. The one incident users barely felt (two API Pods out of three) is the one the metrics barely show. MAD blames a plausible signal for each incident: the queue for the slow broker and the slow database, the predictor's lag for Kafka and the predictor. For cpu-hog it blames the failed predictions: the hog runs outside every Pod, so no Pod's CPU shows it. Only its victims do.

### What the logs saw

The logs row hasn't changed between the two tables: `MIN_CHANGE` and the limits are for the metrics. It found four incidents of six, three of them faster than any metric, and missed api-pods-lost and cpu-hog. Which templates were new after the warm-up, and when? Create `scripts/templates.py`:

<!-- file: scripts/templates.py -->
~~~python
"""The log templates first seen after step 12's warm-up, counted by the
incident they appeared in and by service; and the ones outside every
incident, in full.

    uv run --project lab python scripts/templates.py [RUN]   (default s12)"""

import sys
from collections import Counter
from pathlib import Path

from lab import drain, incidents, logs, signals

run = sys.argv[1] if len(sys.argv) > 1 else "s12"
begin, _, truth = incidents.truth(Path(f"results/{run}-truth.jsonl"))
learn = begin + 900
d = signals.load(Path(f"results/{run}-signals.parquet"))
rows = logs.read(Path(f"results/{run}-logs"))
_, reader, first = drain.log_signals(rows, d["time"], learn)
new = sorted((at, i) for i, at in first.items() if at > learn)


def during(at: float) -> str:
    names = [i["name"] for i in truth if i["start"] - 30 <= at <= i["end"] + 120]
    return names[0] if names else "(none)"


print(f"{len(reader.templates)} templates; {len(new)} first seen after the warm-up:")
print("by incident (first seen from 30 s before its start to 2 min after its end):")
for name, n in Counter(during(at) for at, _ in new).most_common():
    print(f"  {name:<15} {n:4d}")
print("by service:")
services = Counter(reader.templates[i].text.split("/")[0] for _, i in new)
for name, n in services.most_common():
    print(f"  {name:<15} {n:4d}")
print("outside every incident:")
for at, i in new:
    if during(at) == "(none)":
        t = reader.templates[i]
        print(f"  +{(at - begin) / 60:5.1f} min  {t.count:>6}x  {t.text[:120]}")
~~~

~~~bash
uv run --project lab python scripts/templates.py
~~~

~~~text
274 templates; 248 first seen after the warm-up:
by incident (first seen from 30 s before its start to 2 min after its end):
  kafka-down       218
  predictor-down    14
  api-pods-lost     10
  db-slow            3
  (none)             2
  broker-slow        1
by service:
  kafka            214
  api               17
  predictor         12
  bao                2
  notifier           2
  gateway            1
outside every incident:
  + 38.4 min       1x  api/tlsproxy {"time":"<*>","level":"WARN","msg":"connection unreachable","listener":"<*>","from":"<*>","error":"dial tcp
  + 40.4 min       1x  predictor/predictor caught up: <*> events applied
~~~

Kafka's shutdown alone wrote 218 of the 248: a component announcing its own death in detail, which is easy to see. Drain only knows that a line is new, not whether it matters, and most of those 218 are routine shutdown chatter. cpu-hog wrote nothing new at all. A starved process logs nothing about being starved: it runs slower and says the same things. The logs see what fails loudly, and the metrics see what slows down. Neither sees everything.

### The test that wasn't run

The prediction above has no result. Its hour was started twice and lost twice: first to the 37-hour sleep, then, two days later, to every Docker container on the machine stopping 30 minutes in, kind's nodes among them. I stopped there. So step 13's report lists this claim as **inconclusive: not measured**, and that's what it is. Everything above about false alarms comes from the incident run's 26 quiet minutes, the data `MIN_CHANGE` and the limits were chosen on. Those numbers flatter the detectors by an unknown amount. Don't quote them as a false-alarm rate.

A prediction with no result isn't worthless. It was written down, with the detectors' hashes, before any of its data existed, so whoever runs the hour can't be accused of moving the goalposts. Run it yourself. Create `experiments/incidents/quiet.toml`:

<!-- file: experiments/incidents/quiet.toml -->
~~~toml
# Step 12's control: an hour with nothing injected, under the same load.
# Every alarm after the warm-up is a false one: the false-alarm rate,
# measured over three times the quiet time the incident run has.
warmup_s = 900
gap_s = [0, 0]
seed = 12
tail_s = 2700

# The prediction, written before the quiet hour ended (2026-10-18, 21:58
# UTC), with the detectors already frozen: every quiet-time alarm in the
# incident run came 2 to 5 minutes after an incident (recovery, not
# noise), so with nothing injected, threshold, mad and ewma each raise
# at most one alarm after the warm-up, and are alarmed under 5% of the time.
~~~

Then the same three things at once as before, for an hour (`lab incidents plan` says 60 minutes; the collector runs one more): the two load loops, the log collector, and `lab incidents run experiments/incidents/quiet.toml --out results/s12-quiet-truth.jsonl`, with `s12-quiet` in place of `s12` in every file name. Keep the machine awake and Docker running throughout. A gap in the data spoils the hour, and the only remedy is to start again. Then:

~~~bash
lab signals --truth results/s12-quiet-truth.jsonl --out results/s12-quiet-signals.parquet
lab detect results/s12-quiet-signals.parquet --truth results/s12-quiet-truth.jsonl --plan experiments/incidents/quiet.toml \
  --logs results/s12-quiet-logs --min-change --blame mad
sha256sum lab/src/lab/{anomaly,signals,drain}.py   # the detectors you're testing
~~~

With no incidents, `found` is empty, and every alarm counts as false. The prediction holds if threshold, MAD and EWMA each raise at most one alarm and `alarmed_%` is under 5 for each. If your hashes differ from the frozen ones, you changed a detector after seeing data, and the test is no longer held out. Step 13's report picks up `results/s12-quiet-signals.parquet` as soon as it exists.


**Explain it:** why inject incidents instead of waiting for real ones, and what does the truth file get wrong about when an incident ends? What do recall, precision, time to detect and false alarms per hour each measure, and why can a detector that alarms all the time look good on the first three? Why do long tails stretch the standard deviation and not the MAD? Why did EWMA need `clip`? Why does a signal that was zero through the warm-up need `MIN_CHANGE`, and who should choose it? Why did the burn-rate alerts find none of the incidents, and why is that right? What does the logs detector see that the metrics don't, and the other way round? Why must a held-out test be predicted, with the detectors' hashes, before its data exists? And why did a laptop's sleep break the database logins, and what does a monotonic clock have to do with it?

**Read.** Varun Chandola, Arindam Banerjee and Vipin Kumar, *Anomaly Detection: A Survey* (ACM Computing Surveys, 2009): the families of detectors, and what each assumes. Christophe Leys and others, *Detecting outliers: Do not use standard deviation around the mean, use absolute deviation around the median* (Journal of Experimental Social Psychology, 2013). Fei Tony Liu, Kai Ming Ting and Zhi-Hua Zhou, *Isolation Forest* (ICDM 2008). Pinjia He and others, *Drain: An Online Log Parsing Approach with Fixed Depth Tree* (ICWS 2017). And the *Site Reliability Workbook*'s chapter "Alerting on SLOs": why the burn-rate alerts are built the way they are.

---
## Step 13: The report

**The problem.** Twelve steps reached conclusions: TLS is cheap, the trees beat the baselines, priority lanes help, the detectors find incidents. Each was measured once, at its step, on the data of that day, with the code of that day. Since then the code has changed under every one of them: step 8 fixed a leak in the features that steps 5 to 7 were measured with. The dataset is five times bigger, and the cluster has an autoscaler that wasn't on when some of them ran. Which conclusions still hold? A report that copies its numbers out of the guide can't say. This step writes one that can't go stale without saying so. Every conclusion becomes a claim with a test that could fail. The claims run again, from the saved data, with today's code, each time the report is made. `--check` fails if any verdict differs from the one its step reported.

**New ideas.**

- **A claim is a conclusion that can fail.** "The trees are better" is an opinion. "On the test split, the trees' paired log-error difference against the best baseline has a 95% interval below zero" is a test, decided before running it.
- **Replication.** Running the same analysis on new data, here the final dataset, five times the size, is the cheapest check that a result wasn't luck or an artefact of one day. Re-analysing the same saved results only checks the arithmetic.
- **Negative results.** What didn't work is evidence too: an inconclusive interval, a calibration that made coverage worse, a scheduler that didn't help the jobs it was meant to help. A report that leaves them out overstates what was learnt.
- **Threats to validity.** Every result carries the conditions it was measured under: one machine, short runs, synthetic tenants, choices tuned on the data they were scored on. Saying so is what lets a reader decide how far to trust it.
- **Provenance.** The report lists every input, with a fingerprint of its contents. Anyone with the same files gets the same numbers, and a changed file is visible.

### Claims as code

Create `lab/src/lab/report.py`:

<!-- file: lab/src/lab/report.py -->
~~~python
"""Phase 7's conclusions, tested again: the report, as code (step 13).

A report that copies numbers from notes goes stale the day the code or
the data changes, and nobody can tell which numbers still hold. This one
recomputes every claim from the files the steps saved, with today's code,
each time it's made. A claim is a conclusion a step reached, stated so
it can fail. Its test says what result would support it. Each run gives
every claim a verdict: holds, fails, or inconclusive. And each claim
records the verdict the step itself reached (`reported`), so that
`lab report --check` can fail when a conclusion stops holding.

Some claims are re-measured, not just re-read: steps 5 to 7 compared
models on 19,795 jobs; here they're refitted on the final dataset, over
five times as many, with the code as it is now. That makes them a
replication, and a claim may hold on the old data and fail on the new.
Nothing is run against the cluster: experiments are re-analysed from
their saved results, not repeated.
"""

import hashlib
import json
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from functools import cached_property
from pathlib import Path

import numpy as np

from lab import metrics

HOLDS, FAILS, INCONCLUSIVE = "holds", "fails", "inconclusive"


@dataclass(frozen=True)
class Claim:
    step: int
    says: str  # the conclusion, as the step reached it
    test: str  # what result here supports it
    reported: str  # the verdict the step reached
    run: Callable[["Inputs"], tuple[str, str]]  # -> (verdict, evidence)
    negative: bool = False  # a result that says something didn't work


class Inputs:
    """The saved files the claims read, loaded once each, relative to the practice's top."""

    def __init__(self, root: Path):
        self.root = root

    def path(self, name: str) -> Path:
        return self.root / name

    @cached_property
    def dataset(self) -> dict[str, np.ndarray]:
        from lab import dataset

        return dataset.load(self.path("results/dataset.parquet"))

    def split(self, name: str) -> dict[str, np.ndarray]:
        from lab.evaluate import rows_of

        return rows_of(self.dataset, name)

    @cached_property
    def fitted(self) -> dict:
        """Steps 5 to 7's models, fitted on the final dataset's training rows."""
        from lab.baselines import KindMedian, KindPowerLaw
        from lab.model import CATEGORIES, NUMBERS, Boosted
        from lab.nn import NumpyNet

        train = self.split("train")
        every = CATEGORIES + NUMBERS
        models = {
            "kind median": KindMedian(),
            "kind median x0.5": KindMedian(scale=0.5),
            "power law": KindPowerLaw(),
            "power law + running": KindPowerLaw(contention=True),
            "trees + history": Boosted("trees + history", every, random_state=1),
            "numpy network": NumpyNet(seed=1),
        }
        return {name: m.fit(train) for name, m in models.items()}

    @cached_property
    def registry(self):
        from lab import registry

        return registry.client(self.path("mlflow"))


def _paired(y, a, b, created) -> tuple[float, float, float]:
    """b's mean |log error| minus a's, with a 95% interval, resampling whole minutes."""
    minutes = created.astype("datetime64[m]").astype(np.int64)
    return metrics.paired_bootstrap(np.abs(np.log(a / y)), np.abs(np.log(b / y)), minutes)


def _ci(diff, low, high) -> str:
    return f"{diff:+.4f} (95% CI {low:+.4f} to {high:+.4f})"


def _below(low: float, high: float) -> str:
    """A claim that a difference is below zero: holds if the whole interval is,
    fails if the whole interval is above, and an interval that includes zero
    can't tell (step 1's rule)."""
    return HOLDS if high < 0 else FAILS if low > 0 else INCONCLUSIVE


def _all(*verdicts: str) -> str:
    """A claim made of parts: it fails if any part fails, holds if all hold."""
    return FAILS if FAILS in verdicts else HOLDS if set(verdicts) == {HOLDS} else INCONCLUSIVE


# Step 1 ---------------------------------------------------------------------------------------


def tls_under_five_percent(i: Inputs):
    from lab import analyze
    from lab.stats import compare, verdict

    _, rows = analyze.load(i.path("experiments/tls-overhead/results/first"))
    c = compare(analyze.values(rows, "relays"), analyze.values(rows, "tlsproxy"), seed=1)
    said = verdict(c, 0.05)
    v = HOLDS if said.startswith(("equivalent", "different, but")) else FAILS
    v = INCONCLUSIVE if said.startswith("inconclusive") else v
    return v, f"tlsproxy / relays {c.estimate:.3f} (95% CI {c.low:.3f} to {c.high:.3f}): {said}"


def order_fakes_a_difference(i: Inputs):
    from lab import analyze
    from lab.stats import compare

    out = {}
    for run in ("sequential", "hog"):
        _, rows = analyze.load(i.path(f"experiments/aa-relays/results/{run}"))
        out[run] = compare(analyze.values(rows, "a"), analyze.values(rows, "b"), seed=1)
    s, h = out["sequential"], out["hog"]
    fake = s.low > 1 or s.high < 1
    gone = h.low <= 1 <= h.high
    return (HOLDS if fake and gone else FAILS), (
        f"same benchmark twice, under a CPU hog: in sequence {s.estimate:.3f}"
        f" ({s.low:.3f} to {s.high:.3f});"
        f" interleaved {h.estimate:.3f} ({h.low:.3f} to {h.high:.3f})"
    )


# Step 4 ---------------------------------------------------------------------------------------


def duckdb_has_no_cost(i: Inputs):
    import statistics

    runs = [json.loads(line) for line in i.path("results/cost.jsonl").read_text().splitlines()]
    times: dict = {}
    for r in runs:
        times.setdefault((r["system"], r["workers"]), []).append(r["seconds"])
    med = {k: statistics.median(v) for k, v in times.items()}
    one = med[("duckdb", 1)]
    best = {s: min(t for (x, _), t in med.items() if x == s) for s in ("mapreduce", "spark")}
    ok = all(t > one for t in best.values())
    return (HOLDS if ok else FAILS), (
        f"DuckDB on 1 thread {one:.2f} s; best of MapReduce {best['mapreduce']:.2f} s,"
        f" of Spark {best['spark']:.2f} s, at any width"
    )


# Steps 5 to 7 ---------------------------------------------------------------------------------


def contention_helps(i: Inputs):
    test, m = i.split("test"), i.fitted
    d = _paired(
        test["run_s"],
        m["power law"].predict(test),
        m["power law + running"].predict(test),
        test["created_at"],
    )
    return _below(d[1], d[2]), (
        f"on {len(test['run_s'])} test jobs, + running minus plain, log error {_ci(*d)}"
    )


def mape_rewards_guessing_low(i: Inputs):
    test, m = i.split("test"), i.fitted
    y = test["run_s"]
    full, half = m["kind median"].predict(test), m["kind median x0.5"].predict(test)
    mapes = metrics.mape(y, full), metrics.mape(y, half)
    logs = metrics.log_error(y, full), metrics.log_error(y, half)
    ok = mapes[1] < mapes[0] and logs[1] > logs[0]
    return (HOLDS if ok else FAILS), (
        f"kind median, then halved: MAPE {mapes[0]:.1f} -> {mapes[1]:.1f}%,"
        f" log factor {logs[0]:.3f} -> {logs[1]:.3f}"
    )


def trees_beat_the_baseline(i: Inputs):
    test, m = i.split("test"), i.fitted

    def diff(rows):
        return _paired(
            rows["run_s"],
            m["power law + running"].predict(rows),
            m["trees + history"].predict(rows),
            rows["created_at"],
        )

    d = diff(test)
    # Context, not the test: tenants the training rows never saw (step 11's hooli).
    seen = np.isin(test["tenant"], np.unique(i.split("train")["tenant"]))
    known = diff({k: v[seen] for k, v in test.items()})
    return _below(d[1], d[2]), (
        f"trees minus power law + running, log error {_ci(*d)};"
        f" without the {(~seen).sum()} jobs of tenants unseen in training {_ci(*known)}"
    )


def conformal_covers_ninety(i: Inputs):
    from lab.model import CATEGORIES, NUMBERS, Boosted, Conformal

    train, test = i.split("train"), i.split("test")
    every = CATEGORIES + NUMBERS
    bound = Conformal(Boosted("trees p90", every, quantile=0.9, random_state=1), 0.9).fit(train)
    plain = Boosted("trees p90", every, quantile=0.9, random_state=1).fit(train)
    c, p = (metrics.coverage(test["run_s"], b.predict(test)) for b in (bound, plain))
    ok = 0.88 <= c <= 0.92
    return (
        HOLDS if ok else FAILS
    ), f"p90 covers {c:.1%} calibrated, {p:.1%} uncalibrated (aim 90%)"


def network_matches_trees_cheaper(i: Inputs):
    import time

    test, m = i.split("test"), i.fitted
    y = test["run_s"]
    trees, net = m["trees + history"], m["numpy network"]
    ratio = metrics.log_error(y, net.predict(test)) / metrics.log_error(y, trees.predict(test))
    one = {k: v[:1] for k, v in test.items()}

    def ms(model):
        times = []
        for _ in range(50):
            start = time.perf_counter()
            model.predict(one)
            times.append(time.perf_counter() - start)
        return float(np.median(times) * 1e3)

    t_ms, n_ms = ms(trees), ms(net)
    ok = ratio <= 1.02 and t_ms / n_ms >= 100
    return (HOLDS if ok else FAILS), (
        f"network's log factor {ratio:.3f}x the trees'; one prediction {n_ms:.3f} ms"
        f" against {t_ms:.1f} ms ({t_ms / n_ms:.0f}x)"
    )


# Step 8 ---------------------------------------------------------------------------------------


def served_features_cost_little(i: Inputs):
    from lab import dataset, export, online

    served = online.served_from(i.path("results/predictor.log").read_text().splitlines())
    jobs = dataset.load_jobs(i.path("data"))
    model = export.load(i.path("models/runtime-numpy.pkl"))
    row_of = {int(j): k for k, j in enumerate(i.dataset["job_id"])}
    live, batch_rows, y = [], [], []
    for s, j in online.match(served, jobs):
        k = row_of.get(int(jobs["job_id"][j]))
        if k is not None:
            live.append(served[s]["served"]["run_s"])
            batch_rows.append(k)
            y.append(i.dataset["run_s"][k])
    rows = {name: v[batch_rows] for name, v in i.dataset.items()}
    y = np.array(y)
    on, off = (
        metrics.log_error(y, np.array(live)),
        metrics.log_error(y, model["point"].predict(rows)),
    )
    ok = on / off <= 1.05
    return (HOLDS if ok else FAILS), (
        f"{len(y)} jobs: served features {on:.3f}, the batch's {off:.3f} ({on / off - 1:+.1%})"
    )


# Step 9 ---------------------------------------------------------------------------------------


def priority_lanes_help(i: Inputs):
    from lab import export, lanes

    model = export.load(i.path("models/runtime-numpy.pkl"))
    arms: dict = {}
    for arm in ("fifo", "priority", "reserved"):
        parts = [
            lanes.arm_rows(i.path("data"), i.path(f"results/s09-{arm}-{r}.jsonl"), i.dataset, model)
            for r in (3, 4, 5)
        ]
        arms[arm] = {k: np.concatenate([p[k] for p in parts]) for k in parts[0]}

    def short(rows, yes=True):
        s = rows["alone_s"] <= 0.05
        return {k: v[s == yes] for k, v in rows.items()}

    p = lanes.difference(arms["fifo"], arms["priority"])
    r = lanes.difference(short(arms["fifo"]), short(arms["reserved"]))
    return _all(_below(*p[1:]), _below(-r[2], -r[1])), (
        f"mean wait, priority minus FIFO {p[0]:+.1f} s ({p[1]:+.1f} to {p[2]:+.1f});"
        f" short jobs, reserved minus FIFO {r[0]:+.1f} s ({r[1]:+.1f} to {r[2]:+.1f})"
    )


# Steps 10 and 11 ------------------------------------------------------------------------------


def _gate(i: Inputs, champion: str, challenger: str, start: str, end: str):
    from lab import registry

    rows = registry.rows_between(i.dataset, start=start, end=end)
    a = registry.score(registry.fetch(i.registry, champion)[1], rows)
    b = registry.score(registry.fetch(i.registry, challenger)[1], rows)
    minutes = rows["created_at"].astype("datetime64[m]").astype(np.int64)
    return len(rows["run_s"]), a, b, metrics.paired_bootstrap(a.errors, b.errors, minutes)


def gate_promotes_only_real_gains(i: Inputs):
    n, v1, v2, d2 = _gate(i, "1", "2", "2026-10-18T01:40:00", "2026-10-18T03:00:00")
    *_, d4 = _gate(i, "2", "4", "2026-10-18T01:40:00", "2026-10-18T03:00:00")
    ok = d2[2] < 0 and not d4[2] < 0
    return (HOLDS if ok else FAILS), (
        f"step 10's {n} holdout jobs: v2 minus v1 {_ci(*d2)}"
        f" (v1 {v1.factor:.2f}, v2 {v2.factor:.3f});"
        f" v4 (another seed) minus v2 {_ci(*d4)}"
    )


def retraining_fixes_the_new_tenant(i: Inputs):
    from lab import dataset, online

    middle = i.path("results/s11-middle.txt").read_text().strip()
    n, v2, v6, d = _gate(i, "2", "6", middle, "2026-10-18T10:50:00")
    served = online.served_from(i.path("results/s11-shadow.log").read_text().splitlines())
    jobs = dataset.load_jobs(i.path("data"))
    run = np.ma.filled(jobs["run_s"], np.nan)
    both = [(s, j) for s, j in online.match(served, jobs) if "shadow" in served[s]]
    both = [(s, j) for s, j in both if not np.isnan(run[j])]
    y = np.array([run[j] for _, j in both])
    live = np.array([served[s]["served"]["run_s"] for s, _ in both])
    shadow = np.array([served[s]["shadow"]["run_s"] for s, _ in both])
    created = jobs["created"][[j for _, j in both]]
    minutes = (created // 60_000_000).astype(np.int64)
    s = metrics.paired_bootstrap(np.abs(np.log(live / y)), np.abs(np.log(shadow / y)), minutes)
    return _all(_below(d[1], d[2]), _below(s[1], s[2])), (
        f"{n} holdout jobs: v6 minus v2 {_ci(*d)}; in the shadow, {len(y)} live jobs: {_ci(*s)}"
    )


# Step 12 --------------------------------------------------------------------------------------


def _detected(i: Inputs, run: str):
    from lab import anomaly, incidents, signals

    data = signals.load(i.path(f"results/{run}-signals.parquet"))
    begin, _, truth = incidents.truth(i.path(f"results/{run}-truth.jsonl"))
    plan = "plan" if run == "s12" else "quiet"
    learn = begin + incidents.load(i.path(f"experiments/incidents/{plan}.toml"))["warmup_s"]
    names = list(signals.SIGNALS)
    floors = np.array([signals.MIN_CHANGE[n] for n in names])
    results = anomaly.evaluate(data, names, truth, learn, anomaly.LIMITS, 2, floors)
    fired = np.column_stack([data[f"alert:{a}"] for a in signals.ALERTS]).max(axis=1) > 0
    results["alerts"] = (anomaly.score(data["time"], fired, truth, learn), fired, None)
    return {name: r[0] for name, r in results.items()}


def detectors_find_incidents(i: Inputs):
    s = _detected(i, "s12")
    plain = ("threshold", "mad", "ewma")
    found = {n: sum(v is not None for v in s[n].found.values()) for n in (*plain, "alerts")}
    ttd = {n: np.median([v for v in s[n].found.values() if v is not None]) for n in plain}
    ok = all(found[n] >= 5 and ttd[n] < 60 for n in plain) and found["alerts"] == 0
    each = ", ".join(f"{n} {found[n]}/6 in {ttd[n]:.0f} s" for n in plain)
    return (HOLDS if ok else FAILS), f"{each}; Prometheus's alerts {found['alerts']}/6"


def detectors_quiet_when_nothing_happens(i: Inputs):
    if not i.path("results/s12-quiet-signals.parquet").exists():
        # Step 12's two attempts were cut short (a sleep, then Docker stopping).
        return INCONCLUSIVE, "not measured: the quiet hour's signals are missing"
    s = _detected(i, "s12-quiet")
    plain = ("threshold", "mad", "ewma")
    ok = all(s[n].alarms <= 1 and s[n].alarmed < 0.05 for n in plain)
    each = ", ".join(f"{n} {s[n].alarms} ({s[n].alarmed:.1%} of the time)" for n in plain)
    return (
        HOLDS if ok else FAILS
    ), f"alarms in {s['mad'].quiet_hours * 60:.0f} quiet minutes: {each}"


CLAIMS = [
    Claim(
        1,
        "TLS between the services costs under 5% of a relay's time.",
        "the 95% interval of tlsproxy/relays lies within 1.05",
        INCONCLUSIVE,
        tls_under_five_percent,
        negative=True,
    ),
    Claim(
        1,
        "Running the conditions one after the other, under background load, fakes a "
        "difference; interleaving them removes it.",
        "A/A in sequence: the interval excludes 1; interleaved: it includes 1",
        HOLDS,
        order_fakes_a_difference,
    ),
    Claim(
        4,
        "DuckDB on one thread beats MapReduce and Spark at any width: their COST is "
        "unbounded on this machine.",
        "DuckDB's 1-thread median is below every other system's best median",
        HOLDS,
        duckdb_has_no_cost,
    ),
    Claim(
        5,
        "Counting the jobs running at submission improves the power law beyond noise.",
        "paired log-error difference: the interval is below 0",
        HOLDS,
        contention_helps,
    ),
    Claim(
        5,
        "MAPE rewards guessing low.",
        "halving the kind median lowers MAPE and raises the log error",
        HOLDS,
        mape_rewards_guessing_low,
    ),
    Claim(
        6,
        "Gradient-boosted trees with the tenant's history beat the best baseline beyond noise.",
        "paired log-error difference against power law + running: interval below 0",
        HOLDS,
        trees_beat_the_baseline,
    ),
    Claim(
        6,
        "Conformal calibration makes the trees' p90 cover 90% of later jobs.",
        "calibrated coverage on the test split within 88 to 92%",
        FAILS,
        conformal_covers_ninety,
        negative=True,
    ),
    Claim(
        7,
        "A small network is as accurate as the trees (within 2%), and at least a hundred "
        "times cheaper to ask.",
        "log factor ratio at most 1.02, one prediction at least 100x faster",
        HOLDS,
        network_matches_trees_cheaper,
    ),
    Claim(
        8,
        "The features the service computes live cost little accuracy against the batch's.",
        "live log factor within 5% of the same model's on batch features, same jobs",
        HOLDS,
        served_features_cost_little,
    ),
    Claim(
        9,
        "Priority for short jobs cuts the mean wait beyond noise; reserved lanes make short "
        "jobs wait longer.",
        "priority-FIFO interval below 0; short jobs' reserved-FIFO interval above 0",
        HOLDS,
        priority_lanes_help,
    ),
    Claim(
        10,
        "The gate promotes a real improvement and refuses one within noise.",
        "v2 beats v1 beyond noise; v4 (a reseed) does not beat v2",
        HOLDS,
        gate_promotes_only_real_gains,
    ),
    Claim(
        11,
        "Retraining with the new tenant's jobs beats the champion beyond noise, offline "
        "and in the shadow.",
        "v6-v2 interval below 0 on the holdout and on the shadow's live jobs",
        HOLDS,
        retraining_fixes_the_new_tenant,
    ),
    Claim(
        12,
        "Simple detectors find the injected incidents within a minute; the burn-rate "
        "alerts find none of them.",
        "threshold, mad and ewma each find at least 5 of 6, median under 60 s; alerts 0 of 6",
        HOLDS,
        detectors_find_incidents,
    ),
    Claim(
        12,
        "With nothing wrong, the detectors stay quiet (pre-registered before the quiet hour).",
        "in the quiet hour, each of threshold, mad, ewma: at most 1 alarm, under 5% of the time",
        INCONCLUSIVE,
        detectors_quiet_when_nothing_happens,
    ),
]


def digest(path: Path) -> str:
    h = hashlib.sha256()
    files = sorted(p for p in path.rglob("*") if p.is_file()) if path.is_dir() else [path]
    for p in files:
        h.update(p.read_bytes())
    return h.hexdigest()[:12]


INPUTS = [
    "results/dataset.parquet",
    "data",
    "experiments/tls-overhead/results/first",
    "experiments/aa-relays/results",
    "results/cost.jsonl",
    "results/predictor.log",
    "models/runtime-numpy.pkl",
    "mlflow",
    "results/s11-shadow.log",
    "results/s12-signals.parquet",
    "results/s12-quiet-signals.parquet",
]

LIMITS = """\
- **One machine.** Every measurement ran on one laptop: a kind cluster of three
  nodes sharing eight cores, a database, a broker and the load generator. Absolute
  numbers (milliseconds, jobs per second) are this machine's; the comparisons are
  what should travel, and even they may not on another machine.
- **Short runs.** Experiments lasted minutes to an hour. Effects that need days
  (a week's cycle, slow leaks, a month's error budget) are out of reach.
- **Synthetic tenants.** The workload is three (then four) made-up tenants with
  log-normal sizes. Real tenants are burstier, and correlated with each other.
- **Tuned, then tested.** Where a choice was made after looking at the data (step 12's
  minimum changes and limits, step 6's hyperparameters), the honest number is the
  one measured on data the choice didn't see; the report says which is which.
- **The data moved under the models.** The autoscaler was off in step 9's experiments
  and on afterwards, which changed what a queue length means (step 11). Models
  compared in steps 5 to 7 are refitted here on the final dataset, which mixes both.
- **Injected incidents aren't real ones.** Six kinds, one at a time, three minutes each.
  Real incidents overlap, creep in slowly, and come in kinds nobody injected: the two
  this phase met by accident (a login and certificates that outlived a laptop's sleep)
  were in none of the plans.
"""


def run(root: Path, claims: list[Claim] = CLAIMS) -> list[tuple[Claim, str, str]]:
    """Every claim's verdict and evidence. A claim that can't run (an input is
    missing, or its code fails) is inconclusive, saying why: it can't be
    allowed to look like it holds, and one broken claim mustn't hide the rest."""
    inputs = Inputs(root)
    out = []
    for claim in claims:
        try:
            verdict, evidence = claim.run(inputs)
        except FileNotFoundError as e:
            verdict, evidence = INCONCLUSIVE, f"missing input: {e.filename}"
        except Exception as e:  # noqa: BLE001 (reported, not hidden)
            verdict, evidence = INCONCLUSIVE, f"could not run: {type(e).__name__}: {e}"
        out.append((claim, verdict, evidence))
    return out


def card(root: Path) -> str:
    """The champion's model card, scored on step 11's holdout."""
    from lab import registry

    client = registry.client(root / "mlflow")
    version, artifact = registry.fetch(client, "champion")
    middle = (root / "results/s11-middle.txt").read_text().strip()
    inputs = Inputs(root)
    rows = registry.rows_between(inputs.dataset, start=middle, end="2026-10-18T10:50:00")
    run_ = client.get_run(client.get_model_version(registry.NAME, version).run_id)
    return registry.card(version, artifact, run_, registry.score(artifact, rows), rows)


def write(root: Path, results: list[tuple[Claim, str, str]], model_card: str) -> str:
    now = datetime.now(UTC).strftime("%Y-%m-%d %H:%M UTC")
    same = sum(v == c.reported for c, v, _ in results)
    lines = [
        "# Phase 7: what held up",
        "",
        f"Made by `lab report` on {now}, from the files below, with the code as it is now."
        " Every number here is recomputed each time; none is copied from the guide."
        f" {same} of {len(results)} conclusions reached the verdict their step reported.",
        "",
        "| step | claim | verdict | the step said |",
        "|---:|---|---|---|",
    ]
    for c, v, _ in results:
        mark = "" if v == c.reported else " **(changed)**"
        lines.append(f"| {c.step} | {c.says} | {v}{mark} | {c.reported} |")
    lines += ["", "## The evidence", ""]
    for c, v, evidence in results:
        lines += [
            f"**Step {c.step}: {c.says}** {v.capitalize()}.",
            f"Supported if {c.test}. Here: {evidence}.",
            "",
        ]
    lines += ["## What didn't work", ""]
    for c, v, evidence in results:
        if c.negative or v != HOLDS:
            lines.append(f"- Step {c.step}: {c.says} *{v}*: {evidence}.")
    lines += [
        "- Step 6: tuning eighteen hyperparameter settings with time-ordered folds gained"
        " nothing over the defaults (not rerun here: 14 CPU-minutes).",
        "- Step 8: the trees, the most accurate model, answered only 49 to 60% of"
        " predictions in time on a shared CPU; the network replaced them.",
        "- Step 9: lanes chosen by the served (contention-aware) prediction fed back on"
        " themselves: the busier the cluster, the fewer jobs counted as short.",
        "- Step 12: the isolation forest, the most sophisticated detector, found the"
        " fewest incidents at the common limit; its scores are compressed.",
        "",
        "## Limits",
        "",
        LIMITS,
        "## The model serving now",
        "",
        model_card.replace("# Model card", "### Model card"),
        "## Inputs",
        "",
        "Each file or folder, with a fingerprint of its contents (SHA-256, first 12 hex digits):",
        "",
    ]
    for name in INPUTS:
        p = root / name
        lines.append(f"- `{name}`: {digest(p) if p.exists() else 'missing'}")
    lines += [
        "",
        "Make it again with `uv run --project lab lab report`; `--check` exits 1 if a"
        " verdict differs from the one its step reported.",
        "",
    ]
    return "\n".join(lines)
~~~

Read it in this order. `Claim` is one conclusion: its step, what it says, the test that would support it, the verdict its step reached, and the function that decides it now. `Inputs` loads each saved file once, and fits steps 5 to 7's models once, on the final dataset's training rows. Each claim's function returns a verdict and one line of evidence. `run` runs them all: a claim that can't run is inconclusive, never quietly left out. `write` makes the Markdown: the verdicts, the evidence, what didn't work, the limits, the model card, the inputs' fingerprints.

### Tests

The tests check the machinery, not the conclusions:
- a claim that crashes, or whose input is missing, is inconclusive, with the reason;
- a verdict that differs from the reported one is marked;
- a fingerprint changes with any byte.

Create `lab/tests/test_report.py`:

<!-- file: lab/tests/test_report.py -->
~~~python
from pathlib import Path

from lab import report


def claim(verdict, reported, run=None):
    return report.Claim(
        9, f"a claim that {verdict}", "a test", reported, run or (lambda i: (verdict, "why"))
    )


def broken(inputs):
    raise ZeroDivisionError("a bug in the claim")


def missing(inputs):
    return Path(inputs.path("nowhere.txt")).read_text()


def test_a_claim_that_cannot_run_is_inconclusive_and_says_why(tmp_path):
    results = report.run(tmp_path, [claim("x", "holds", broken), claim("x", "holds", missing)])
    (_, v1, e1), (_, v2, e2) = results
    assert (v1, v2) == ("inconclusive", "inconclusive")
    assert "ZeroDivisionError: a bug in the claim" in e1 and e2.endswith("nowhere.txt")


def test_the_report_marks_a_verdict_that_changed(tmp_path):
    claims = [claim("holds", "holds"), claim("fails", "holds")]
    text = report.write(tmp_path, report.run(tmp_path, claims), "# Model card: none")
    assert "1 of 2 conclusions reached the verdict their step reported" in text
    assert "| a claim that fails | fails **(changed)** | holds |" in text
    assert "## What didn't work" in text and "- Step 9: a claim that fails *fails*: why." in text


def test_a_digest_changes_with_any_byte_of_a_folder(tmp_path):
    (tmp_path / "a").mkdir()
    (tmp_path / "a" / "x.txt").write_text("1")
    before = report.digest(tmp_path / "a")
    (tmp_path / "a" / "x.txt").write_text("2")
    assert report.digest(tmp_path / "a") != before


def test_an_interval_that_includes_zero_decides_nothing():
    assert report._below(-0.3, -0.1) == "holds"
    assert report._below(0.1, 0.3) == "fails"
    assert report._below(-0.1, 0.3) == "inconclusive"
    assert report._all("holds", "inconclusive") == "inconclusive"
    assert report._all("inconclusive", "fails") == "fails"
    assert report._all("holds", "holds") == "holds"
~~~

In `lab/src/lab/cli.py`:

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

def cmd_export(args: argparse.Namespace) -> int:
~~~

to:

~~~python

def cmd_report(args: argparse.Namespace) -> int:
    from lab import report

    results = report.run(args.root)
    for c, v, evidence in results:
        mark = "" if v == c.reported else f"  CHANGED: the step said {c.reported}"
        print(f"step {c.step:>2}  {v:<12}{mark}\n          {evidence}")
    changed = [c for c, v, _ in results if v != c.reported]
    if args.check:
        return 1 if changed else 0
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(report.write(args.root, results, report.card(args.root)))
    print(f"wrote {args.out}: {len(results) - len(changed)} of {len(results)} as reported")
    return 0


def cmd_export(args: argparse.Namespace) -> int:
~~~

Change:

<!-- edit: lab/src/lab/cli.py -->
~~~python

    ex = sub.add_parser("export", help="fit the served models on every row and save them")
~~~

to:

~~~python

    rp = sub.add_parser(
        "report", help="test every conclusion of Phase 7 again, and write the report"
    )
    rp.add_argument("--root", type=Path, default=Path("."), help="the practice's top")
    rp.add_argument("--out", type=Path, default=Path("docs/report/phase7.md"))
    rp.add_argument(
        "--check", action="store_true", help="exit 1 if a verdict changed; write nothing"
    )
    rp.set_defaults(func=cmd_report)

    ex = sub.add_parser("export", help="fit the served models on every row and save them")
~~~


<!-- run: cd lab && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_report.py -->

### Run it

From the top of the practice, with every step's data in place:

~~~bash
uv run --project lab lab report
~~~

~~~text
step  1  inconclusive
          tlsproxy / relays 1.054 (95% CI 1.027 to 1.079): inconclusive: the interval is wider than the question
step  1  holds       
          same benchmark twice, under a CPU hog: in sequence 1.539 (1.452 to 1.639); interleaved 1.010 (0.666 to 1.735)
step  4  holds       
          DuckDB on 1 thread 2.34 s; best of MapReduce 18.03 s, of Spark 3.38 s, at any width
step  5  holds       
          on 21868 test jobs, + running minus plain, log error -0.0305 (95% CI -0.0534 to -0.0083)
step  5  holds       
          kind median, then halved: MAPE 80.2 -> 56.6%, log factor 2.091 -> 2.567
step  6  fails         CHANGED: the step said holds
          trees minus power law + running, log error +0.0753 (95% CI +0.0345 to +0.1123); without the 1151 jobs of tenants unseen in training -0.0399 (95% CI -0.0687 to -0.0175)
step  6  fails       
          p90 covers 93.6% calibrated, 95.9% uncalibrated (aim 90%)
step  7  holds       
          network's log factor 0.997x the trees'; one prediction 0.144 ms against 17.6 ms (123x)
step  8  holds       
          2345 jobs: served features 1.463, the batch's 1.436 (+1.9%)
step  9  inconclusive  CHANGED: the step said holds
          mean wait, priority minus FIFO -6.9 s (-14.0 to -0.8); short jobs, reserved minus FIFO +6.9 s (-2.4 to +15.8)
step 10  holds       
          step 10's 26703 holdout jobs: v2 minus v1 -1.1296 (95% CI -1.5775 to -0.7130) (v1 4.44, v2 1.436); v4 (another seed) minus v2 -0.0012 (95% CI -0.0042 to +0.0018)
step 11  holds       
          7075 holdout jobs: v6 minus v2 -0.2319 (95% CI -0.2597 to -0.2034); in the shadow, 3013 live jobs: -0.1504 (95% CI -0.1921 to -0.0908)
step 12  holds       
          threshold 5/6 in 28 s, mad 6/6 in 31 s, ewma 5/6 in 28 s; Prometheus's alerts 0/6
step 12  inconclusive
          not measured: the quiet hour's signals are missing
wrote docs/report/phase7.md: 12 of 14 as reported
~~~

It takes about 25 seconds, most of it refitting steps 5 to 7's models on 65,601 training jobs, three times step 5's whole dataset. The report it wrote, `docs/report/phase7.md`, opens with this table:

~~~markdown
# Phase 7: what held up

Made by `lab report` on 2026-10-28 00:32 UTC, from the files below, with the code as it is now. Every number here is recomputed each time; none is copied from the guide. 12 of 14 conclusions reached the verdict their step reported.

| step | claim | verdict | the step said |
|---:|---|---|---|
| 1 | TLS between the services costs under 5% of a relay's time. | inconclusive | inconclusive |
| 1 | Running the conditions one after the other, under background load, fakes a difference; interleaving them removes it. | holds | holds |
| 4 | DuckDB on one thread beats MapReduce and Spark at any width: their COST is unbounded on this machine. | holds | holds |
| 5 | Counting the jobs running at submission improves the power law beyond noise. | holds | holds |
| 5 | MAPE rewards guessing low. | holds | holds |
| 6 | Gradient-boosted trees with the tenant's history beat the best baseline beyond noise. | fails **(changed)** | holds |
| 6 | Conformal calibration makes the trees' p90 cover 90% of later jobs. | fails | fails |
| 7 | A small network is as accurate as the trees (within 2%), and at least a hundred times cheaper to ask. | holds | holds |
| 8 | The features the service computes live cost little accuracy against the batch's. | holds | holds |
| 9 | Priority for short jobs cuts the mean wait beyond noise; reserved lanes make short jobs wait longer. | inconclusive **(changed)** | holds |
| 10 | The gate promotes a real improvement and refuses one within noise. | holds | holds |
| 11 | Retraining with the new tenant's jobs beats the champion beyond noise, offline and in the shadow. | holds | holds |
| 12 | Simple detectors find the injected incidents within a minute; the burn-rate alerts find none of them. | holds | holds |
| 12 | With nothing wrong, the detectors stay quiet (pre-registered before the quiet hour). | inconclusive | inconclusive |

~~~

Below the table come the evidence, what didn't work, the limits, the serving model's card and the inputs' fingerprints. Twelve of fourteen verdicts agree with their steps. The two that don't are the reason for writing the report this way.

### What changed: step 6's trees

On step 5's test split, the trees beat the best baseline by 0.057. On the final dataset's, they lose to it by 0.075, beyond noise. Same code, same features, more data, opposite answer. Slice it by tenant, and the cause is plain: the test split now includes hooli, the tenant that arrived in step 11, after the training rows end. On hooli's 1,151 jobs, the trees' predictions are off by a log factor of 2.65, against the power law's 0.50: step 11's unseen-tenant problem again. The trees never saw the category, and treat it as missing; its history was there for all but two of its jobs, and didn't save it. The power law uses only the kind, the size and the jobs running, so a new tenant costs it nothing. Without the unseen tenants, the trees still win beyond noise, which is the second half of the evidence line.

So which is the conclusion? Both, stated properly. "The trees beat the baseline" was true of tenants the model had seen. It's false of a population that includes new ones, and the claim, as step 6 wrote it, didn't say which it meant. A replication doesn't just check a number. It finds the conditions a result depended on that nobody wrote down.

### What changed: step 9's reserved lanes

Step 9 said reserved lanes made short jobs wait longer. Its own table said +6.9 s, with an interval from −2.4 to +15.8. The interval includes zero, so the experiment couldn't tell. Step 9 read the point estimate and wrote it down as a finding (it's corrected there now). Nobody re-reads a step's prose against its tables. The report re-reads every claim against its numbers on every run, which is how it caught this.

The report nearly made the same mistake itself. My first version of these claims had two verdicts: "holds" if the interval was on the claimed side of zero, "fails" otherwise. An interval across zero counted as a failure, so step 9's claim read "fails": refuted, when it was only unproven. That's step 1's lesson again, an interval across zero decides nothing. `_below` gives three answers, and `_all` combines the parts of a claim. A test now holds the rule in place.

### Break it: two verdicts instead of three

Make `_below` two-way, `return HOLDS if high < 0 else FAILS`, and run the tests:

~~~text
        assert report._below(-0.3, -0.1) == "holds"
        assert report._below(0.1, 0.3) == "fails"
>       assert report._below(-0.1, 0.3) == "inconclusive"
E       AssertionError: assert 'fails' == 'inconclusive'
~~~

Put it back.

### What held, and what to make of it

- **Replicated on the bigger data:** contention helps the power law (−0.031 now, −0.015 at step 5); MAPE still rewards guessing low; the network still matches the trees and is over a hundred times cheaper to ask; served features cost 2%; the gate's and the retrain's comparisons, re-scored from the registry, give step 10's and 11's numbers exactly.
- **Still failing:** conformal calibration. At step 6 it under-covered (85%); on the final data it over-covers (94%). Wrong in both directions, depending on what the newest quarter of the training rows happened to look like: calibrating on one recent slice only works if the next slice resembles it.
- **Fragile:** the network's cost claim measures live timings each run. Two runs gave 123× and 126×, near the claim's 100× line. On a busy machine it could flip. That says something about the claim (the margin was always thin), not the code.
- **Never measured:** the quiet hour. The report says so, and lists the file that would settle it as missing.

`lab report --check` now exits 1, and it should, until someone decides. For each changed verdict there are only two honest moves: fix the code, if the change is a bug, or change the claim and its `reported` verdict, with the reason, if the world changed. Never the third: loosening the test until it passes.

**Explain it:** what makes a conclusion a claim that can fail? Why recompute every number instead of copying it from the steps? What's the difference between re-analysing a saved result and replicating it on new data, and what can each catch? Why did the trees' win reverse, and what should step 6's claim have said? Why is an interval across zero "inconclusive", not "fails"? What belongs in "what didn't work", and why does a report without it overstate? What do the inputs' fingerprints let a reader do? Which of the limits would you check first before trusting a result on another machine?

**Read.** John Ioannidis, *Why Most Published Research Findings Are False* (PLoS Medicine, 2005): how small samples, many comparisons and flexible analyses produce findings that don't replicate. Brian Nosek and others, *The preregistration revolution* (PNAS, 2018). Ron Kohavi, Diane Tang and Ya Xu, *Trustworthy Online Controlled Experiments* (2020), the chapters on threats to validity and on trustworthiness checks. Timnit Gebru and others, *Datasheets for Datasets* (Communications of the ACM, 2021): provenance for the data, as the model card is for the model.

---
