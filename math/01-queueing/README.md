# 01. Probability and queueing

Everything that waits is a queue: requests at a server, jobs in RabbitMQ, packets at a router, threads at a lock, GPUs at a scheduler. This guide gives you the small amount of probability that explains them, and shows why a system at 90% utilisation can feel broken when one at 70% feels fine. You check the answer three ways: a formula, a simulation, and your own Runway.

**Real systems:** [Phase 2](../../lessons/02-connected-services/README.md) introduced Little's law; the [Performance Bridge](../../lessons/perf-bridge/README.md) found a service collapsing at its knee; the [Networking Bridge](../../lessons/network-bridge/README.md) measured a queue at a router. This is the theory behind all three, and behind every "keep utilisation under 70%" rule you'll hear.

## Set up the project

Make a new repository of your own (not inside this one), called `math-track`. Each guide gets a folder.

<!-- run: uv init --bare --name math-track --python 3.12 && uv python pin 3.12 -->

~~~bash
uv init --bare --name math-track --python 3.12
uv python pin 3.12
~~~

Then make `pyproject.toml` match this:

<!-- file: pyproject.toml -->
~~~toml
[project]
name = "math-track"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = []

[dependency-groups]
dev = [
    "pytest>=8",
    "ruff>=0.8",
]

[tool.pytest.ini_options]
addopts = "--import-mode=importlib"
pythonpath = ["."]

[tool.ruff]
line-length = 100

[tool.ruff.lint]
select = ["E", "F", "I", "B", "UP"]
~~~

<!-- file: .gitignore -->
~~~text
.venv/
__pycache__/
.pytest_cache/
.ruff_cache/
results/
~~~

## Three facts about randomness

**An average isn't enough.** Two services that each take 50 ms on average can behave very differently: one always takes 50, while the other usually takes 5 and sometimes takes 500. What separates them is **variance**, the average squared distance from the mean. The number that compares it across scales is the **squared coefficient of variation**:

```
cv² = variance / mean²
```

It's 0 when everything takes the same time, and 1 for the distribution below.

**Exponential gaps.** If events happen independently at an average rate λ, the time between them follows the **exponential distribution**, with mean 1/λ. Requests from many unrelated users are close to this, and such a stream is called a **Poisson process**. It has a strange property: it's **memoryless**. However long you've waited, the wait still to come has the same distribution. That's what makes the mathematics tractable.

**Utilisation.** One server taking *S* seconds per job, with λ jobs arriving per second, is busy a share ρ (rho) of the time:

```
ρ = λ × S
```

If ρ ≥ 1, work arrives faster than it can be done, and the queue grows without limit. Below 1 it's stable, but stable doesn't mean fast.

## Little's law

Pick any system. Let *L* be the average number of items inside it, λ the rate they arrive, and *W* the average time each spends inside. Then:

```
L = λ × W
```

It looks too simple, and it needs almost no assumptions: no particular distribution, no particular scheduling, only a system that's stable. Here's the argument. Draw the number of items in the system over time. The area under that line is the total item-seconds spent inside. You can add that area up in two ways: over time, which gives *L* × *T*; or over items, which gives (λ*T*) × *W*. They're the same area, so *L* = λ*W*.

Use it in your head. A worker pool holds 20 jobs on average, at 100 jobs a second? Each spends 200 ms inside. A database has 50 connections busy, and queries take 10 ms? It's doing 5,000 queries a second, and can't do more without more connections or faster queries.

## The formulas

The simplest queue with randomness is **M/M/1**: Poisson arrivals, exponential service, one server. Its mean time in the queue, before service starts, is:

```
         ρ × S
Wq  =  --------
         1 - ρ
```

Everything interesting is in that denominator. When ρ is 0.5, you wait one service time. At 0.9, nine. At 0.99, ninety-nine. **Waiting is proportional to 1/(1 − ρ).**

Real jobs aren't exponential, and **Pollaczek–Khinchine** handles any distribution of service time (M/G/1):

```
         ρ × S     1 + cv²
Wq  =  -------- × ---------
         1 - ρ        2
```

The second factor is the cost of variability. For exponential service, cv² is 1, and this is M/M/1 again. For fixed service, cv² is 0, and **the wait halves**. Nothing got faster on average: the jobs just became predictable.

Put them in code:

<!-- file: queueing/models.py -->
~~~python
"""Queueing formulas. Times are in seconds, rates in items per second."""

import math


def littles_law(arrival_rate: float, time_in_system: float) -> float:
    """Return L, the average number in the system: L = lambda * W."""
    return arrival_rate * time_in_system


def utilisation(arrival_rate: float, service_time: float) -> float:
    """Return rho, the share of time one server is busy."""
    return arrival_rate * service_time


def mm1_wait(arrival_rate: float, service_time: float) -> float:
    """Return the mean time in the queue, before service starts, for M/M/1."""
    rho = utilisation(arrival_rate, service_time)
    if rho >= 1:
        return math.inf
    return rho * service_time / (1 - rho)


def pk_wait(arrival_rate: float, service_time: float, cv2: float) -> float:
    """Return the mean queueing time for M/G/1 (Pollaczek-Khinchine).

    cv2 is the squared coefficient of variation of the service time:
    variance / mean^2. It's 1 for exponential service and 0 for fixed.
    """
    return mm1_wait(arrival_rate, service_time) * (1 + cv2) / 2


def mm1_percentile(arrival_rate: float, service_time: float, p: float) -> float:
    """Return the p-th percentile (0 to 1) of time in system, for M/M/1.

    In M/M/1, time in system is exponential, at rate mu - lambda.
    """
    return -math.log(1 - p) / (1 / service_time - arrival_rate)
~~~

## A simulator

Don't take a formula on trust. A single first-come, first-served queue is easy to simulate, because each customer's wait depends only on the one before: you wait for whatever the customer ahead still had to do, less the gap between you. That's **Lindley's recursion**, and it replaces a whole event loop with one line.

<!-- file: queueing/simulate.py -->
~~~python
"""A single-server queue, simulated one customer at a time."""

import random
from collections.abc import Callable
from dataclasses import dataclass


@dataclass
class Run:
    waits: list[float]  # time in the queue, for each customer
    sojourns: list[float]  # time in the system: queue plus service
    busy_time: float
    duration: float

    @property
    def mean_wait(self) -> float:
        return sum(self.waits) / len(self.waits)

    @property
    def mean_sojourn(self) -> float:
        return sum(self.sojourns) / len(self.sojourns)

    def percentile(self, p: float) -> float:
        ordered = sorted(self.sojourns)
        return ordered[min(int(p * len(ordered)), len(ordered) - 1)]


def simulate(
    arrival_rate: float,
    service: Callable[[random.Random], float],
    n: int,
    seed: int = 1,
    warm_up: float = 0.1,
) -> Run:
    """Run n customers through one first-come, first-served server.

    Each customer's wait follows from the one before (Lindley's recursion):
    you wait for what the customer ahead had left, less the gap between you.
    The first warm_up share is dropped, since the queue starts empty.
    """
    rng = random.Random(seed)
    wait = 0.0
    previous_service = 0.0
    now = busy = 0.0
    waits: list[float] = []
    sojourns: list[float] = []
    skip = int(n * warm_up)
    for i in range(n):
        gap = rng.expovariate(arrival_rate)
        wait = max(0.0, wait + previous_service - gap)
        previous_service = service(rng)
        now += gap
        if i >= skip:
            waits.append(wait)
            sojourns.append(wait + previous_service)
            busy += previous_service
    return Run(waits, sojourns, busy, now * (1 - warm_up))
~~~

The tests pit one against the other, a million customers at a time:

<!-- file: queueing/load.py -->
~~~python
"""Send jobs to a running Runway at Poisson-random times.

The arrival times are decided before the first request goes out, so a slow
response can't delay the next one: an open loop, as in the Python Bridge.
"""

import argparse
import json
import random
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor


def arrival_times(rate: float, n: int, rng: random.Random) -> list[float]:
    """Return n arrival times, in seconds from 0, with exponential gaps."""
    now = 0.0
    times = []
    for _ in range(n):
        now += rng.expovariate(rate)
        times.append(now)
    return times


def durations(kind: str, mean_ms: int, n: int, rng: random.Random) -> list[int]:
    """Return n job lengths in ms: all equal, or exponentially distributed."""
    if kind == "fixed":
        return [mean_ms] * n
    return [min(round(rng.expovariate(1 / mean_ms)), 5000) for _ in range(n)]


def post(url: str, description: str, duration_ms: int) -> int:
    body = json.dumps({"description": description, "duration_ms": duration_ms}).encode()
    req = urllib.request.Request(url, body, {"content-type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)["id"]


def wait_until_done(url: str, job_id: int) -> None:
    while True:
        with urllib.request.urlopen(f"{url}/{job_id}", timeout=30) as resp:
            if json.load(resp)["state"] in ("completed", "failed"):
                return
        time.sleep(0.2)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True, help="stored in each job's description")
    parser.add_argument("--rate", type=float, required=True, help="jobs per second")
    parser.add_argument("--n", type=int, default=1000)
    parser.add_argument("--kind", choices=["exp", "fixed"], default="exp")
    parser.add_argument("--mean-ms", type=int, default=50)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--url", default="http://localhost:8080/jobs")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    times = arrival_times(args.rate, args.n, rng)
    lengths = durations(args.kind, args.mean_ms, args.n, rng)
    ids: list[int] = []
    lock = threading.Lock()

    def send(duration_ms: int) -> None:
        job_id = post(args.url, args.tag, duration_ms)
        with lock:
            ids.append(job_id)

    start = time.monotonic()
    with ThreadPoolExecutor(max_workers=32) as pool:
        for at, duration_ms in zip(times, lengths, strict=True):
            time.sleep(max(0.0, at - (time.monotonic() - start)))
            pool.submit(send, duration_ms)
    wait_until_done(args.url, max(ids))
    print(f"{args.tag}: sent {len(ids)} in {time.monotonic() - start:.0f}s")


if __name__ == "__main__":
    main()
~~~

`load.py` comes first because the tests use it. It's what you'll point at Runway below: it decides every arrival time up front, so a slow response can't hold the next request back. That's the **open loop** from the [Python Bridge](../../lessons/python-bridge/README.md). A closed loop would quietly slow down exactly when the system is struggling, and hide the queue you're trying to measure.

<!-- file: queueing/test_models.py -->
~~~python
import math
import random

import pytest

from queueing import models
from queueing.load import arrival_times, durations
from queueing.simulate import simulate


def test_littles_law():
    assert models.littles_law(20, 0.05) == pytest.approx(1.0)


def test_mm1_at_half_load_waits_one_service_time():
    assert models.mm1_wait(10, 0.05) == pytest.approx(0.05)


def test_saturation_never_drains():
    assert models.mm1_wait(20, 0.05) == math.inf
    assert models.mm1_wait(30, 0.05) == math.inf


def test_pk_is_mm1_for_exponential_service():
    assert models.pk_wait(16, 0.05, 1) == pytest.approx(models.mm1_wait(16, 0.05))


def test_pk_halves_the_wait_for_fixed_service():
    assert models.pk_wait(16, 0.05, 0) == pytest.approx(models.mm1_wait(16, 0.05) / 2)


@pytest.mark.parametrize("rho", [0.5, 0.8, 0.9])
def test_simulation_matches_mm1(rho):
    s = 0.05
    run = simulate(rho / s, lambda rng: rng.expovariate(1 / s), 1_000_000)
    assert run.mean_wait == pytest.approx(models.mm1_wait(rho / s, s), rel=0.03)


def test_simulation_matches_pk_for_fixed_service():
    s = 0.05
    run = simulate(16, lambda rng: s, 1_000_000)
    assert run.mean_wait == pytest.approx(models.pk_wait(16, s, 0), rel=0.03)


def test_simulated_p99_matches_the_formula():
    s = 0.05
    run = simulate(16, lambda rng: rng.expovariate(1 / s), 1_000_000)
    assert run.percentile(0.99) == pytest.approx(models.mm1_percentile(16, s, 0.99), rel=0.03)


def test_littles_law_holds_in_the_simulation():
    run = simulate(16, lambda rng: rng.expovariate(1 / 0.05), 1_000_000)
    # Measure L as customer-seconds in the system, per second.
    in_system = sum(run.sojourns) / run.duration
    assert in_system == pytest.approx(models.littles_law(16, run.mean_sojourn), rel=0.02)


def test_the_simulator_reports_utilisation():
    run = simulate(16, lambda rng: 0.05, 200_000)
    assert run.busy_time / run.duration == pytest.approx(0.8, rel=0.02)


def test_arrival_times_have_the_right_rate():
    times = arrival_times(10, 100_000, random.Random(1))
    assert times == sorted(times)
    assert 100_000 / times[-1] == pytest.approx(10, rel=0.02)


def test_durations():
    rng = random.Random(1)
    assert durations("fixed", 50, 3, rng) == [50, 50, 50]
    exp = durations("exp", 50, 100_000, rng)
    assert sum(exp) / len(exp) == pytest.approx(50, rel=0.02)
~~~

<!-- run: uv run pytest -q queueing && uv run ruff check . && uv run ruff format --check . -->

~~~bash
uv run pytest -q queueing
~~~

## Why latency explodes

Here's a 50 ms service, as utilisation rises. For M/M/1, time in the system is itself exponential, with rate μ − λ, which gives a formula for percentiles as well.

<!-- file: queueing/explode.py -->
~~~python
"""Print how a queue behaves as a server fills up: formula against simulation."""

from queueing import models
from queueing.simulate import simulate

SERVICE = 0.050  # seconds


def main() -> None:
    print(f"{'rho':>5} {'mean ms':>8} {'simulated':>10} {'p99 ms':>7} {'simulated':>10}")
    for rho in (0.1, 0.5, 0.7, 0.8, 0.9, 0.95, 0.99):
        rate = rho / SERVICE
        run = simulate(rate, lambda rng: rng.expovariate(1 / SERVICE), 2_000_000)
        mean = models.mm1_wait(rate, SERVICE) + SERVICE
        p99 = models.mm1_percentile(rate, SERVICE, 0.99)
        print(
            f"{rho:5.2f} {mean * 1000:8.0f} {run.mean_sojourn * 1000:10.0f} "
            f"{p99 * 1000:7.0f} {run.percentile(0.99) * 1000:10.0f}"
        )


if __name__ == "__main__":
    main()
~~~

<!-- run: uv run python -m queueing.explode > /dev/null -->

~~~bash
uv run python -m queueing.explode
~~~

~~~text
  rho  mean ms  simulated  p99 ms  simulated
 0.10       56         56     256        256
 0.50      100        100     461        460
 0.70      167        167     768        771
 0.80      250        249    1151       1141
 0.90      500        503    2303       2315
 0.95     1000       1025    4605       4863
 0.99     5000       5317   23026      27447
~~~

The formula and the simulator agree closely up to 90%. At 95% and 99% the simulator runs high: a queue that full swings so widely that even two million customers don't pin it down. Read down the first column of numbers:

- **From 10% to 50%, latency doubles.** You've given up very little.
- **From 80% to 90%, it doubles again,** from 250 ms to 500, and p99 goes from 1.2 to 2.3 seconds.
- **From 95% to 99%, it goes up five times.** The last few percent of capacity are ruinously expensive.

That's the **knee** you found in the Performance Bridge. It isn't a defect in the code, it's arithmetic. It's why capacity plans aim for 60–70% utilisation, and why an autoscaler has to act before a system looks busy. It's also why a small slowdown near the knee causes a large outage: a service at 90% that gets 5% slower isn't 5% worse. It's twice as bad.

## Testing it on Runway

Formulas and simulators can agree with each other and both be wrong about your system. So point this at the real thing: your Phase 5 Runway, with `WORKERS=1`, so that one consumer takes jobs from RabbitMQ one at a time. That's one server, with a queue in front of it.

**This part needs your running Runway, so CI doesn't run it.** The numbers below were captured by hand, on one laptop.

Start RabbitMQ and PostgreSQL with Phase 5's Compose file, then run the API and worker with one slot and a large queue, so that the queue is never full:

~~~bash
export AMQP_URL=amqp://guest:guest@localhost:5672/
export DATABASE_URL=postgres://runway:runway@localhost:5432/runway
export WORKERS=1 QUEUE_CAPACITY=100000 OUTBOX_INTERVAL=5ms
./bin/api &
./bin/worker &
~~~

### Measure the service time first

You can't work out ρ without *S*. A job with `duration_ms: 50` doesn't take the worker 50 ms: it also has to take the message, publish events and acknowledge. Find out by sending far more than it can handle, and timing the gap between completions. Nothing else can limit it, since the queue is never empty:

~~~bash
uv run python -m queueing.load --tag cal-exp --rate 200 --n 400 --kind exp
uv run python -m queueing.load --tag cal-fixed --rate 200 --n 400 --kind fixed
~~~

| Jobs | Mean sleep | Measured *S* | cv² |
|---|---|---|---|
| Exponential | 52 ms | 75 ms | 0.51 |
| Fixed | 50 ms | 73 ms | 0.01 |

Two lessons before you've run the experiment. **About 23 ms of every job is overhead**, the broker and the event bookkeeping, and it's fixed. So even with exponential sleeps, the job isn't exponential, and cv² is about 0.5, not 1. M/M/1 is the wrong model for your own system, and if you'd assumed it, you'd have overestimated the wait. That's why Pollaczek–Khinchine is here.

### The experiment

Two kinds of job with nearly the same mean, at five utilisations, in shuffled order, three times over. Each job's description records its run. Set `S_EXP` and `S_FIXED` to your own measurements; the defaults are this laptop's, read before the problem described below was found, and `report.py`'s `cv2` values are too.

<!-- file: experiments/runway_queue.sh -->
~~~bash
#!/bin/bash
# Load one Runway worker at five utilisations, with jobs of two shapes, in
# shuffled order. Service times are measured first (S_EXP and S_FIXED, in
# seconds). Each job's description records its kind, utilisation and run.
set -eu
S_EXP=${S_EXP:-0.0714}
S_FIXED=${S_FIXED:-0.0686}
for run in $(seq 1 "${REPEATS:-3}"); do
  for job in $(for k in exp fixed; do for rho in 0.14 0.5 0.7 0.8 0.9; do echo "$k,$rho"; done; done | shuf); do
    kind=${job%,*}; rho=${job#*,}
    s=$S_EXP; [ "$kind" = fixed ] && s=$S_FIXED
    rate=$(awk -v r="$rho" -v s="$s" 'BEGIN {print r / s}')
    n=1000; [ "$rho" = 0.14 ] && n=240
    python3 queueing/load.py --tag "q-$kind-$rho-$run" --kind "$kind" --rate "$rate" --n "$n" --seed "$RANDOM"
    sleep 2
  done
done
~~~

<!-- run: chmod +x experiments/runway_queue.sh && bash -n experiments/runway_queue.sh -->

It takes about 55 minutes. Keep the machine awake and otherwise idle. Then export every state change, in the order PostgreSQL stored them:

~~~bash
chmod +x experiments/runway_queue.sh
./experiments/runway_queue.sh
docker compose exec -T postgres psql -U runway -At -F' ' -c \
  "select e.id, j.description, e.job_id, e.state, extract(epoch from e.at), j.duration_ms
   from job_events e join jobs j on j.id = e.job_id order by e.id" > results/events.txt
~~~

### The clock lied

The first analysis of these runs was wrong. 146 of 25,440 jobs finished **before they started**, by up to 1.6 seconds. Arrival rates also came out about 6% above what the load generator had been told to send.

There's a lesson here worth more than the queueing. `job_events` stores **wall-clock** timestamps, and a wall clock isn't a stopwatch. Compare the kernel's clocks directly:

~~~python
import time

def snap():
    return time.clock_gettime(time.CLOCK_MONOTONIC), time.clock_gettime(time.CLOCK_REALTIME)
~~~

Sampled every half-second for a minute, on the laptop that ran this:

~~~text
step at 10.0 s: realtime jumped -1.554s vs monotonic
step at 42.0 s: realtime jumped -1.614s vs monotonic
60 s: monotonic 60.171 realtime 57.003 raw 57.268
~~~

The laptop had slept earlier, and after waking, the virtual machine's clock ran about 5% fast, while something stepped the wall clock back every half-minute to keep it right. Real machines do milder versions of this all the time, through NTP corrections. **Never work out a duration by subtracting two wall-clock timestamps** without knowing that. Inside one process, Go's `time.Since` uses a monotonic clock for exactly this reason. Across machines, you need to think about it far harder (Phase 4).

The data was still usable. PostgreSQL's `id` gives the true order of events, so a timestamp that falls well below the latest one means the clock moved, and the step can be undone. After the repair, there isn't one negative time among 25,440 jobs, and the arrival rate lands on what was asked: 12.60 a second against 12.61. If your own machine's clock is healthy, it finds no steps and does nothing.

<!-- file: queueing/report.py -->
~~~python
"""Turn Runway's job_events into a table of measured queues.

Read lines of "id description job state epoch-seconds duration-ms", in id
order, as exported by the psql command in the guide.
"""

import argparse
import statistics
from collections import defaultdict
from dataclasses import dataclass

from queueing.models import littles_law, pk_wait


def unstep(times: list[float], tolerance: float = 0.6) -> tuple[list[float], int]:
    """Undo backward clock steps in timestamps listed in the order they happened.

    Rows are numbered in insertion order, so a timestamp that falls well
    below the latest one seen means the clock moved. Returns the repaired
    times and how many steps were found.
    """
    offset = 0.0
    latest = float("-inf")
    steps = 0
    repaired = []
    for t in times:
        t += offset
        if t < latest - tolerance:
            offset += latest - t
            t = latest
            steps += 1
        latest = max(latest, t)
        repaired.append(t)
    return repaired, steps


@dataclass
class Measured:
    arrival_rate: float  # jobs per second
    service: float  # seconds per job, while the queue wasn't empty
    sojourn: float  # mean seconds from queued to completed
    p99: float
    in_system: float  # time-average number of jobs in the system


def measure(jobs: list[tuple[float, float]], warm_up: float = 0.1) -> Measured:
    """Measure one run, given (queued, completed) times for each job."""
    jobs = sorted(jobs)
    finishing = sorted(jobs, key=lambda job: job[1])
    busy_gaps = [
        after[1] - before[1]
        for before, after in zip(finishing, finishing[1:], strict=False)
        if after[0] < before[1] - 0.05  # the next job was already waiting
    ]
    kept = jobs[int(len(jobs) * warm_up) :]
    sojourns = sorted(done - queued for queued, done in kept)

    changes = sorted([(q, 1) for q, _ in kept] + [(d, -1) for _, d in kept])
    area = 0.0
    count = 0
    previous = changes[0][0]
    for at, change in changes:
        area += count * (at - previous)
        previous = at
        count += change

    return Measured(
        arrival_rate=(len(kept) - 1) / (kept[-1][0] - kept[0][0]),
        service=statistics.mean(busy_gaps),
        sojourn=statistics.mean(sojourns),
        p99=sojourns[int(0.99 * len(sojourns))],
        in_system=area / (changes[-1][0] - changes[0][0]),
    )


def read_runs(path: str) -> tuple[dict[str, list[tuple[float, float]]], int]:
    """Return each run's jobs as (queued, completed), and the steps repaired."""
    rows = [line.split() for line in open(path)]
    times, steps = unstep([float(row[4]) for row in rows])
    stamps: dict[tuple[str, str], float] = {}
    tags = {}
    for row, t in zip(rows, times, strict=True):
        stamps[row[2], row[3]] = t
        tags[row[2]] = row[1]
    runs = defaultdict(list)
    for job, tag in tags.items():
        if (job, "completed") in stamps:
            runs[tag].append((stamps[job, "queued"], stamps[job, "completed"]))
    return runs, steps


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("events")
    parser.add_argument("--delay", type=float, default=0.09, help="seconds at no load")
    args = parser.parse_args()
    runs, steps = read_runs(args.events)
    print(f"repaired {steps} clock steps")
    print(f"{'run':16} {'rho':>6} {'W ms':>7} {'predict':>8} {'p99':>7} {'L':>6} {'lam*W':>6}")
    rows = []
    for tag, jobs in sorted(runs.items()):
        if tag.startswith("q-"):
            m = measure(jobs)
            cv2 = 0.51 if tag.startswith("q-exp") else 0.0
            rho = m.arrival_rate * m.service
            predicted = args.delay + pk_wait(m.arrival_rate, m.service, cv2)
            rows.append((rho, tag, m, predicted))
    for rho, tag, m, predicted in sorted(rows, key=lambda row: row[0]):
        print(
            f"{tag:16} {rho:6.3f} {m.sojourn * 1000:7.0f} {predicted * 1000:8.0f} "
            f"{m.p99 * 1000:7.0f} {m.in_system:6.2f} "
            f"{littles_law(m.arrival_rate, m.sojourn):6.2f}"
        )


if __name__ == "__main__":
    main()
~~~

<!-- append: queueing/test_models.py -->
~~~python
def test_unstep_removes_a_backward_jump():
    times, steps = unstep([10.0, 10.1, 10.2, 8.7, 8.8])
    assert steps == 1
    assert times == pytest.approx([10.0, 10.1, 10.2, 10.2, 10.3])


def test_unstep_ignores_small_disorder():
    assert unstep([10.0, 9.9, 10.1])[1] == 0


def test_measure_two_jobs_one_after_the_other():
    # A job finishes at 1.0, and the next, queued at 0.5, at 2.0.
    jobs = [(0.0, 1.0), (0.5, 2.0), (1.5, 3.0)]
    m = measure(jobs, warm_up=0)
    assert m.service == pytest.approx(1.0)
    assert m.sojourn == pytest.approx(4 / 3)
    assert m.arrival_rate == pytest.approx(2 / 1.5)
~~~

<!-- edit: queueing/test_models.py -->
~~~python
from queueing.load import arrival_times, durations
from queueing.simulate import simulate
~~~
~~~python
from queueing.load import arrival_times, durations
from queueing.report import measure, unstep
from queueing.simulate import simulate
~~~

<!-- run: uv run ruff format . && uv run ruff check . && uv run pytest -q queueing -->

### What Runway does

~~~bash
uv run python -m queueing.report results/events.txt
~~~

The output has one row per run: its true utilisation, measured *W*, the Pollaczek–Khinchine prediction (with 90 ms added for the time a job takes at no load), p99, and both sides of Little's law. Here are some rows:

~~~text
run                 rho    W ms  predict     p99      L  lam*W
q-exp-0.5-1       0.505     130      148     436   0.87   0.87
q-fixed-0.5-1     0.553     131      135     295   0.99   0.99
q-exp-0.7-1       0.739     198      252     678   1.93   1.93
q-fixed-0.8-1     0.833     227      270     745   2.63   2.63
q-exp-0.8-1       0.844     334      392    1314   3.80   3.80
q-fixed-0.9-1     0.893     378      389    1269   4.71   4.72
q-exp-0.9-1       0.947     688     1103    2141   8.65   8.67
q-fixed-0.9-2     0.973     913     1414    1803  12.03  12.29
q-exp-0.9-3       1.026    2493      inf    3326  31.44  32.71
~~~

Asking for a utilisation of 0.9 gave anything from 0.89 to 1.06, because *S* itself moved between 70 and 82 ms from run to run. So the guide compares each run with the prediction for its **own** measured ρ.

**Little's law holds.** *L* and λ*W* agree to within about 2% on all 27 stable runs, and mostly to the last digit shown, on a real system with a message broker in the middle. That's the most reliable tool you own.

**The formula works, to a point.** Below 93% utilisation, across 19 runs, measured time divided by predicted time had a median of 0.88 for exponential jobs and 0.97 for fixed ones, ranging from 0.76 to 1.14. For a formula that treats a broker, a database and a Go service as "one server", that's useful. It leans a little high, partly because in a real system *S* isn't quite independent of load. Plain M/M/1 would have predicted 450 ms for the fixed run at 0.833, where the truth was 227.

**Variability costs what the formula says.** Compare runs at nearly the same load: exponential at 0.844 took 334 ms, and fixed at 0.833 took 227. Take off the 90 ms at no load, and the wait is 244 against 137. The jobs had the same mean, within 3 ms. Making them **predictable** nearly halved the waiting, as the (1 + cv²)/2 factor said it would.

**Above about 93%, the prediction overshoots, and that's a limit of the experiment.** The formula describes the long-run average, and a queue that close to saturation takes far longer than an 80-second run to reach it. At 0.95 the measured 688 ms is what you get before it settles. Three runs went over 1 and never settled: the queue just grew, averaging about 30 jobs, until the load stopped. There, Little's law is only approximate too, since a run that ends with a full queue isn't stable.

**Limits.** These are 3 runs per setting, with the clock repaired after the fact, on one laptop. The 90 ms is a single round figure for the no-load time. Trust the shape and the ratios, not the digits.

## What to do with this

- **Keep headroom.** Waiting scales with 1/(1 − ρ). Decide your target from your latency objective, not from wanting to use what you've paid for.
- **Reduce variance, not just the mean.** Separate long jobs from short ones. [Phase 7, step 9](../../lessons/07-utility-evaluation/README.md)'s short lane is exactly this: it stops a few long jobs setting everyone's queue time.
- **Watch utilisation of the bottleneck.** It's the only ρ that matters.
- **Use Little's law as a sanity check** on any dashboard. If *L*, λ and *W* don't multiply, one of the three is measured wrongly.
- **Never estimate from the average when the system is near the knee.** A small change in ρ makes a large change in latency.

## Practice

Solve these alone, and check with the simulator or a calculator. There are no solutions here.

1. A service handles 800 requests a second with 12 in flight on average. What's its mean latency?
2. A single-threaded server takes 4 ms per request. At what arrival rate does the mean wait reach 40 ms, for exponential service, and for fixed service?
3. Extend `simulate` to *c* servers sharing one queue. Compare one server at speed 2 with two servers at speed 1, at the same ρ. Which is better, and why does the answer change as ρ falls?
4. Add **hedged requests** to the simulator: send a copy to a second server if the first hasn't answered by the p95. What does it do to p99, and to utilisation?
5. Using your own measured *S* and cv², what's the highest ρ that keeps Runway's mean queueing time under 100 ms? Test it.
6. Your service has a retry policy of three attempts. At ρ = 0.9, 10% of requests time out. What's the effective ρ? What does that tell you about retry storms?

## Read

- Mor Harchol-Balter, *Performance Modeling and Design of Computer Systems*: the standard text, and readable.
- John Little and Stephen Graves, [*Little's Law*](https://people.cs.umass.edu/~emery/classes/cmpsci691st/readings/OS/Littles-Law-50-Years-Later.pdf), on why the law holds so generally.
- Marc Brooker, [*Why Do Queues Fail?*](https://brooker.co.za/blog/2021/08/05/utilization.html) on latency and utilisation.
