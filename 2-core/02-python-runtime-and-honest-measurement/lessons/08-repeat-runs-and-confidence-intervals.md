# 08 Repeat runs and confidence intervals

> Module: Python runtime and honest measurement · Time: ~3 h · Builds on: 07

## The problem

You change Switchyard, measure it, and the p99 is 0.2 ms lower than yesterday's. Is the change faster? Run the same build twice and you'll get two different numbers, so a difference between two single runs might be the change, or might be the noise any run has. Worse, a difference can be real and still not be the change: if every "after" run happened when the laptop was warmer, the warmth is what you measured. This lesson makes `kload` answer "is B really different from A?" with repeat runs, a confidence interval, and an order that can't fool it.

## The mental model

~~~text
  A: run1 run2 run3 run4 run5     one p99 per run: 1.65 1.60 1.58 1.64 1.66
  B: run1 run2 run3 run4 run5     one p99 per run: 1.88 2.05 2.01 1.97 1.87

  bootstrap: 10,000 times, pick 5 of A's runs (with replacement) and 5 of B's,
             and record mean(B's picks) − mean(A's picks)
             ──▶ sort the 10,000 differences; the middle 95% is the interval

   −0.1    0     +0.1   +0.2   +0.3   +0.4   +0.5 ms
     │     │      │      ├──────■──────┤        interval excludes 0: a difference
     │   ├─┼──■───┤                             interval includes 0: no difference shown
~~~

- **Run-to-run variation:** each run's p99 differs a little from the last, even with nothing changed. The unit of evidence is a run, not a request: the requests in one run share that run's conditions.
- A **confidence interval** is the range of differences the data is consistent with. If it excludes zero, the data supports a difference; if it includes zero, the data can't tell, which is not the same as "no difference".
- The **bootstrap** builds that interval by resampling the runs you have, with no assumptions about the shape of the distribution. It's a computer doing what statisticians do with formulas.
- **Order bias:** something that drifts during the experiment (temperature, caches, background jobs) looks like a difference if all the A runs come first. Randomising the order spreads the drift over both.
- An **A/A test** compares a build with itself. It should show no difference; if it does, your method is biased, and its other answers can't be trusted either.

## The pattern

**Repeat, randomise, compare with an interval, and test the method on A against A first.** Save each run's settings, so the experiment can be run again exactly.

## Build it

### Step 1: One run proves nothing

With Switchyard running (`./bin/switchyard`), run the same thing five times:

~~~bash
for n in 1 2 3 4 5; do uv run kload load --rate 1000 --duration 3 --out results/again/run$n.csv | grep latency; done
~~~

~~~text
latency (2xx): p50 0.83 ms, p99 1.58 ms, max 6.06 ms
latency (2xx): p50 0.90 ms, p99 1.72 ms, max 7.39 ms
latency (2xx): p50 0.89 ms, p99 1.63 ms, max 5.02 ms
latency (2xx): p50 0.90 ms, p99 1.69 ms, max 9.53 ms
latency (2xx): p50 0.90 ms, p99 1.67 ms, max 9.18 ms
~~~

Nothing changed between those runs, yet the p99 moved from 1.58 to 1.72 ms, and the max from 5.02 to 9.53 ms. Any single run of a "before" and an "after" would differ by about that much with no change at all.

### Step 2: The bootstrap

Create `src/kload/compare.py`:

<!-- file: src/kload/compare.py -->
~~~python
"""Is B really different from A? Bootstrap confidence intervals over repeat runs."""

import random
from collections.abc import Sequence
from dataclasses import dataclass

from kload.load import Result
from kload.stats import percentile


@dataclass(frozen=True)
class Difference:
    """B's mean minus A's mean, with a confidence interval."""

    a: float
    b: float
    diff: float
    low: float
    high: float

    @property
    def shown(self) -> bool:
        """True when the interval excludes zero: a difference the data supports."""
        return self.low > 0 or self.high < 0


def run_percentile(results: Sequence[Result], p: float) -> float:
    """One run's p-th percentile latency in ms, over its 2xx responses."""
    latencies = [r.latency_s * 1000 for r in results if r.ok]
    if not latencies:
        raise ValueError("a run has no successful requests")
    return percentile(latencies, p)


def mean(values: Sequence[float]) -> float:
    return sum(values) / len(values)


def bootstrap(
    a: Sequence[float],
    b: Sequence[float],
    *,
    resamples: int = 10_000,
    confidence: float = 0.95,
    rng: random.Random | None = None,
) -> Difference:
    """Compare the mean of a with the mean of b, one value per run.

    Each resample draws len(a) runs from a and len(b) from b, with
    replacement, and records the difference of their means. The middle
    95% of those differences is the confidence interval: the range of
    differences these runs are consistent with.
    """
    if len(a) < 2 or len(b) < 2:
        raise ValueError("need at least 2 runs on each side")
    rng = rng or random.Random(1)
    diffs = sorted(
        mean(rng.choices(b, k=len(b))) - mean(rng.choices(a, k=len(a))) for _ in range(resamples)
    )
    tail = (1 - confidence) / 2
    low = diffs[int(tail * resamples)]
    high = diffs[int((1 - tail) * resamples) - 1]
    return Difference(mean(a), mean(b), mean(b) - mean(a), low, high)
~~~

- `run_percentile` reduces each run to one number, its p50 or p99 over `2xx` answers, so a run with a thousand requests counts as one piece of evidence, not a thousand.
- `rng.choices(b, k=len(b))` picks runs **with replacement**: some runs twice, some not at all. Each resample is a run set you might have got instead.
- The interval is read straight off the sorted differences: the 250th and the 9,750th of 10,000.
- `random.Random(1)` is seeded, so the same runs always give the same interval.

Create `tests/test_compare.py`:

<!-- file: tests/test_compare.py -->
~~~python
import random

import pytest

from kload.compare import bootstrap, run_percentile
from kload.load import Result


def test_identical_runs_show_no_difference():
    d = bootstrap([5.0, 5.2, 4.9, 5.1, 5.0], [5.1, 4.9, 5.0, 5.2, 5.0])
    assert not d.shown
    assert d.low <= 0 <= d.high


def test_a_clear_shift_is_shown_with_its_size():
    d = bootstrap([5.0, 5.2, 4.9, 5.1, 5.0], [7.0, 7.2, 6.9, 7.1, 7.0])
    assert d.shown
    assert d.diff == pytest.approx(2.0)
    assert 1.8 < d.low < d.diff < d.high < 2.2


def test_one_wild_run_widens_the_interval():
    calm = bootstrap([5.0, 5.1, 5.0, 5.1, 5.0], [5.6, 5.5, 5.6, 5.5, 5.6])
    wild = bootstrap([5.0, 5.1, 5.0, 5.1, 5.0], [5.6, 5.5, 5.6, 5.5, 9.0])
    assert (wild.high - wild.low) > 5 * (calm.high - calm.low)


def test_the_same_seed_gives_the_same_interval():
    a, b = [1.0, 2.0, 3.0], [2.0, 3.0, 4.0]
    first = bootstrap(a, b, rng=random.Random(7))
    assert bootstrap(a, b, rng=random.Random(7)) == first


def test_bootstrap_needs_two_runs_a_side():
    with pytest.raises(ValueError, match="at least 2 runs"):
        bootstrap([1.0], [1.0, 2.0])


def test_run_percentile_uses_only_2xx():
    run = [Result(i, 0, 0, 0.001 * (i + 1), 200) for i in range(10)] + [Result(10, 0, 0, 9, 503)]
    assert run_percentile(run, 99) == pytest.approx(10.0)
~~~

`test_one_wild_run_widens_the_interval` is the property that keeps you honest: one unusual run makes the interval much wider, so the comparison admits it knows less.

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_compare.py -->

### Step 3: `kload compare`, and runs you can repeat

Replace `src/kload/cli.py` with its final version, which adds `compare`, and `--settings` for `load`:

<!-- file: src/kload/cli.py -->
~~~python
"""The kload command line."""

import argparse
import asyncio
import json
import sys
import time
from collections import Counter
from pathlib import Path

import httpx

from kload.client import ApiError, SwitchyardClient
from kload.http1 import Pool
from kload.load import Result, Send, run_closed_loop, run_open_loop
from kload.results import read_results, write_results
from kload.stats import percentile, summarize

EXIT_FELL_BEHIND = 3
CPU_WARNING = 0.7  # above this share of one CPU, kload's own queueing creeps in


def cmd_summarize(args: argparse.Namespace) -> int:
    values = [float(word) for word in Path(args.file).read_text().split()]
    summary = summarize(values)
    for name in ("count", "mean", "p50", "p99", "max"):
        print(f"{name:>5}: {getattr(summary, name):g}")
    return 0


def cmd_smoke(args: argparse.Namespace) -> int:
    key = f"smoke-{time.time_ns()}"
    with httpx.Client(base_url=args.url, timeout=5) as http:
        client = SwitchyardClient(http)
        try:
            print(f"health: {client.health()}")
            job = client.create_job("smoke test", duration_ms=args.duration_ms, key=key)
            print(f"created job {job.id}: {job.state}")
            again = client.create_job("smoke test", duration_ms=args.duration_ms, key=key)
            print(
                f"same key again: job {again.id}"
                + (" (the same job)" if again.id == job.id else "")
            )
            job = client.cancel_job(job.id)
            print(f"cancelled job {job.id}: {job.state}")
        except (ApiError, httpx.HTTPError) as exc:
            print(f"kload: {exc}", file=sys.stderr)
            return 1
    return 0


def make_send(pool: Pool, method: str, path: str, body: str) -> Send:
    """Build the function that sends request number i through the pool.

    A POST carries an Idempotency-Key that is unique to this run and request,
    so Switchyard creates one job per request, and a retry wouldn't make two.
    """
    run = time.time_ns()
    content = body.encode()
    headers = {"Content-Type": "application/json"} if content else {}

    async def send(i: int) -> int:
        extra = {"Idempotency-Key": f"kload-{run}-{i}"} if method == "POST" else {}
        return (await pool.request(method, path, headers | extra, content)).status

    return send


def cmd_load(args: argparse.Namespace) -> int:
    async def go() -> list[Result]:
        pool = Pool(args.url)
        send = make_send(pool, args.method, args.path, args.body)
        try:
            if args.mode == "closed":
                return await run_closed_loop(send, args.rate, args.duration, timeout_s=args.timeout)
            return await run_open_loop(
                send,
                args.rate,
                args.duration,
                max_in_flight=args.max_in_flight,
                timeout_s=args.timeout,
            )
        finally:
            pool.close()

    wall, cpu = time.perf_counter(), time.process_time()
    results = asyncio.run(go())
    wall, cpu = time.perf_counter() - wall, time.process_time() - cpu

    settings = {k: v for k, v in vars(args).items() if k not in ("handler", "settings")}
    settings_path = write_results(results, Path(args.out), settings)
    fell_behind = report_run(results, args, wall, cpu)
    print(f"wrote {args.out} and {settings_path}")
    if all(r.status == 0 for r in results):
        print(
            f"kload: no request got a response: is anything listening at {args.url}?",
            file=sys.stderr,
        )
        return 1
    return EXIT_FELL_BEHIND if fell_behind else 0


def report_run(results: list[Result], args: argparse.Namespace, wall: float, cpu: float) -> bool:
    """Print what happened, and return True if kload fell behind its own schedule."""
    if args.mode == "closed":
        print(
            f"closed loop: {len(results)} requests at up to {args.rate:g}/s, one at a time,"
            f" in {wall:.2f} s (latency timed from sending: a stall is hidden)"
        )
    else:
        print(f"open loop: {len(results)} requests at {args.rate:g}/s over {args.duration:g} s")
    statuses = Counter(r.status or r.error for r in results)
    print("answers: " + ", ".join(f"{s} x{n}" for s, n in sorted(statuses.items(), key=str)))
    ok = [r.latency_s * 1000 for r in results if r.ok]
    if ok:
        print(
            f"latency (2xx): p50 {percentile(ok, 50):.2f} ms, p99 {percentile(ok, 99):.2f} ms,"
            f" max {max(ok):.2f} ms"
        )
    lags = [r.lag_s * 1000 for r in results]
    lag_p99 = percentile(lags, 99)
    print(
        f"kload itself: send lag p99 {lag_p99:.2f} ms, max {max(lags):.2f} ms;"
        f" CPU {cpu:.2f} s in {wall:.2f} s ({cpu / wall:.0%})"
    )
    if cpu / wall > CPU_WARNING:
        print(
            f"kload used {cpu / wall:.0%} of a CPU: close to its limit, so replies may have"
            " waited for it to read them. Lower the rate, or split it across processes.",
            file=sys.stderr,
        )
    if args.mode == "open" and lag_p99 > args.max_lag_ms:
        print(
            f"kload fell behind its schedule: send lag p99 {lag_p99:.1f} ms is over"
            f" --max-lag-ms {args.max_lag_ms:g}. These latencies include time spent"
            " waiting inside kload: don't trust them.",
            file=sys.stderr,
        )
        return True
    return False


def cmd_analyze(args: argparse.Namespace) -> int:
    from kload.analyze import load_frame, per_second, plot, report

    df = load_frame(Path(args.file))
    print(json.dumps(report(df), indent=2))
    print(per_second(df).to_string())
    if args.plot:
        plot(df, Path(args.plot))
        print(f"wrote {args.plot}")
    return 0


def cmd_compare(args: argparse.Namespace) -> int:
    from kload.compare import bootstrap, run_percentile

    sides = []
    for folder in (args.a, args.b):
        files = sorted(Path(folder).glob("*.csv"))
        if len(files) < 2:
            print(f"kload: {folder} needs at least 2 runs (CSV files)", file=sys.stderr)
            return 1
        sides.append([read_results(f) for f in files])
    for p in (50, 99):
        a, b = ([run_percentile(run, p) for run in side] for side in sides)
        for name, folder, values in (("A", args.a, a), ("B", args.b, b)):
            runs = " ".join(f"{v:.2f}" for v in values)
            print(f"p{p} {name} ({folder}, {len(values)} runs): {runs} ms")
        d = bootstrap(a, b)
        verdict = (
            f"B is {'slower' if d.diff > 0 else 'faster'}"
            if d.shown
            else "no difference shown: the interval includes 0"
        )
        print(f"p{p} B - A: {d.diff:+.2f} ms, 95% CI [{d.low:+.2f}, {d.high:+.2f}] ms: {verdict}")
    return 0


def build_parser(saved: dict | None = None) -> argparse.ArgumentParser:
    """The command line. saved holds a run's settings, used as load's defaults."""
    parser = argparse.ArgumentParser(prog="kload", description=__doc__)
    sub = parser.add_subparsers(required=True)

    p = sub.add_parser("summarize", help="summarize the numbers in a file")
    p.add_argument("file")
    p.set_defaults(handler=cmd_summarize)

    p = sub.add_parser("smoke", help="check a running Switchyard end to end")
    p.add_argument("--url", default="http://127.0.0.1:8080")
    p.add_argument("--duration-ms", type=int, default=100)
    p.set_defaults(handler=cmd_smoke)

    p = sub.add_parser("load", help="send load on a schedule and save the raw results")
    p.add_argument("--settings", type=Path, help="start from a saved run's settings")
    p.add_argument("--url", default="http://127.0.0.1:8080")
    p.add_argument("--method", choices=["GET", "POST"], default="GET")
    p.add_argument("--path", default="/health")
    p.add_argument("--body", default="", help="JSON to send with each request")
    p.add_argument(
        "--mode",
        choices=["open", "closed"],
        default="open",
        help="closed waits for each reply before the next request, for comparison",
    )
    p.add_argument("--rate", type=float, help="requests per second")
    p.add_argument("--duration", type=float, help="seconds")
    p.add_argument("--max-in-flight", type=int, default=500)
    p.add_argument(
        "--max-lag-ms",
        type=float,
        default=10.0,
        help="fail the run if kload sends later than this (p99)",
    )
    p.add_argument("--timeout", type=float, default=10.0, help="seconds per request")
    p.add_argument("--out", default="results/run.csv")
    p.set_defaults(handler=cmd_load, **(saved or {}))  # typed options still win

    p = sub.add_parser("analyze", help="report on a results file, and plot it")
    p.add_argument("file")
    p.add_argument("--plot", help="write a PNG here")
    p.set_defaults(handler=cmd_analyze)

    p = sub.add_parser("compare", help="compare two folders of repeat runs")
    p.add_argument("a", help="folder of runs for A")
    p.add_argument("b", help="folder of runs for B")
    p.set_defaults(handler=cmd_compare)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if getattr(args, "settings", None):
        parser = build_parser(json.loads(args.settings.read_text()))
        args = parser.parse_args(argv)
    if args.handler is cmd_load:
        if not (args.rate and args.duration):
            parser.error("load needs --rate and --duration (or --settings)")
        if not args.url.startswith("http://"):
            parser.error(f"kload speaks plain HTTP only: --url {args.url}")
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
~~~

- `cmd_compare` reads every CSV in two folders, prints each run's p50 and p99, and the bootstrap's verdict.
- `--settings` loads a saved run's JSON and uses it as the defaults for `load`, so the same experiment runs again exactly, and anything you type on the command line still wins. The defaults have to be set on the `load` subcommand itself: `parser.set_defaults` on the top-level parser never reaches a subcommand's options, which is why `build_parser` takes them.

Replace `tests/test_cli.py`:

<!-- file: tests/test_cli.py -->
~~~python
import json
import socket

import pytest

from kload.cli import EXIT_FELL_BEHIND, main
from kload.load import Result
from kload.results import read_results, write_results


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


def test_load_needs_a_rate_and_a_duration(capsys):
    with pytest.raises(SystemExit) as caught:
        main(["load", "--rate", "10"])
    assert caught.value.code == 2
    assert "needs --rate and --duration" in capsys.readouterr().err


def test_load_writes_results_and_settings(server_url, tmp_path, capsys):
    out = tmp_path / "run.csv"
    code = main(
        ["load", "--url", server_url, "--rate", "50", "--duration", "0.4", "--out", str(out)]
    )
    assert code == 0
    results = read_results(out)
    assert len(results) == 20 and all(r.status == 200 for r in results)
    settings = json.loads(out.with_suffix(".json").read_text())
    assert (settings["rate"], settings["path"], settings["mode"]) == (50, "/health", "open")
    assert "answers: 200 x20" in capsys.readouterr().out


def test_settings_rerun_the_same_experiment(server_url, tmp_path):
    first, second = tmp_path / "a.csv", tmp_path / "b.csv"
    main(["load", "--url", server_url, "--rate", "40", "--duration", "0.25", "--out", str(first)])
    assert main(["load", "--settings", str(first.with_suffix(".json")), "--out", str(second)]) == 0
    assert len(read_results(second)) == 10
    assert json.loads(second.with_suffix(".json").read_text())["out"] == str(second)


def test_a_run_that_falls_behind_exits_3(server_url, tmp_path, capsys):
    # A lag limit of 0 ms: no real run can meet it, so this one must fail.
    out = tmp_path / "run.csv"
    args = ["load", "--url", server_url, "--rate", "50", "--duration", "0.2", "--out", str(out)]
    assert main([*args, "--max-lag-ms", "0"]) == EXIT_FELL_BEHIND
    assert "kload fell behind its schedule" in capsys.readouterr().err
    assert out.exists()  # the raw results are kept, so you can see why


def test_nothing_listening_exits_1(tmp_path, capsys):
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]  # a port that was free a moment ago
    url = f"http://127.0.0.1:{port}"
    out = str(tmp_path / "run.csv")
    assert main(["load", "--url", url, "--rate", "20", "--duration", "0.1", "--out", out]) == 1
    assert "is anything listening" in capsys.readouterr().err


def write_runs(folder, latency_s: float, runs: int = 3) -> None:
    for n in range(runs):
        jitter = 0.0001 * n
        results = [Result(i, i * 0.01, i * 0.01, latency_s + jitter, 200) for i in range(100)]
        write_results(results, folder / f"run{n}.csv", {})


def test_compare_command(tmp_path, capsys):
    write_runs(tmp_path / "a", 0.005)
    write_runs(tmp_path / "b", 0.007)
    write_runs(tmp_path / "c", 0.005)
    assert main(["compare", str(tmp_path / "a"), str(tmp_path / "b")]) == 0
    assert "p99 B - A: +2.00 ms" in capsys.readouterr().out
    main(["compare", str(tmp_path / "a"), str(tmp_path / "c")])
    assert "no difference shown" in capsys.readouterr().out
~~~

~~~bash
uv run ruff format --check . && uv run ruff check . && uv run pytest -q
~~~

~~~text
30 files already formatted
All checks passed!
..................................................................       [100%]
66 passed in 12.37s
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

Rerun lesson 07's baseline from its saved settings:

~~~bash
uv run kload load --settings results/base.json --out results/base-again.csv | grep latency
~~~

~~~text
latency (2xx): p50 1.33 ms, p99 2.36 ms, max 5.20 ms
~~~

### Step 4: Compare two builds, in a random order

Core 01's `-race` builds add checks to every memory access. How much slower is `GET /health` with them? Build both:

~~~bash
cd ~/blueprint/switchyard
go build -o bin/switchyard ./cmd/switchyard
go build -race -o bin/switchyard-race ./cmd/switchyard
cd ~/blueprint/kload
~~~

Stop any Switchyard that's running: the experiment starts its own. Create `experiments/builds.sh`:

<!-- file: experiments/builds.sh -->
~~~bash
#!/usr/bin/env bash
# Five runs each of Switchyard's plain build, the same build again, and its
# race-detector build, in a random order, one Switchyard at a time, after one
# warm-up run that isn't kept.
#
#   bash experiments/builds.sh ~/blueprint/switchyard/bin results/builds
set -eu
bin=$1
out=$2
rm -rf "$out"
mkdir -p "$out/plain" "$out/plain-again" "$out/race"
order=$(uv run python -c '
import random
runs = [f"{build} {n}" for build in ("plain", "plain-again", "race") for n in range(1, 6)]
random.shuffle(runs)
print("\n".join(runs))')
echo "order: warm-up,$(echo "$order" | tr '\n' ',' | sed 's/,$//')"
while read -r build n; do
  exe=$bin/switchyard
  [ "$build" = race ] && exe=$bin/switchyard-race
  "$exe" > /dev/null 2>&1 &
  server=$!
  sleep 0.5
  csv=$out/$build/run$n.csv
  [ "$build" = warm-up ] && csv=$out/warm-up.csv
  status=0
  uv run kload load --rate 1000 --duration 3 --out "$csv" > /dev/null < /dev/null || status=$?
  kill "$server"
  wait "$server" || true
  if [ $status != 0 ]; then
    echo "run '$build $n': kload exited with $status, so this experiment's numbers can't be trusted" >&2
    exit 1
  fi
done <<< "warm-up 0
$order"
rm "$out/warm-up.csv" "$out/warm-up.json"
~~~

It runs three "builds" five times each: `plain`, `plain-again` (the same binary, as an A/A test) and `race`. Python shuffles the fifteen runs, and each gets a fresh Switchyard. Before them comes one **warm-up** run that isn't kept: the first run after a quiet spell is slower (the CPU is still raising its clock speed, and files aren't yet in the page cache), and whichever build it landed on would look slower. If any run falls behind, `kload` exits 3, and the experiment stops rather than compare numbers it can't trust. `< /dev/null` keeps `uv run` from reading the list the loop is reading.

~~~bash
bash experiments/builds.sh ~/blueprint/switchyard/bin results/builds
uv run kload compare results/builds/plain results/builds/plain-again
uv run kload compare results/builds/plain results/builds/race
~~~

~~~text
order: warm-up,plain 2,plain-again 1,plain 4,race 3,race 1,plain-again 2,plain-again 5,race 5,plain 3,race 4,plain-again 4,plain 1,plain 5,race 2,plain-again 3
p50 A (results/builds/plain, 5 runs): 0.89 0.88 0.89 0.89 0.87 ms
p50 B (results/builds/plain-again, 5 runs): 0.89 0.89 0.88 0.88 0.88 ms
p50 B - A: -0.00 ms, 95% CI [-0.01, +0.01] ms: no difference shown: the interval includes 0
p99 A (results/builds/plain, 5 runs): 1.65 1.62 1.69 1.70 1.64 ms
p99 B (results/builds/plain-again, 5 runs): 1.60 1.61 1.62 1.68 1.64 ms
p99 B - A: -0.03 ms, 95% CI [-0.07, +0.01] ms: no difference shown: the interval includes 0
p50 A (results/builds/plain, 5 runs): 0.89 0.88 0.89 0.89 0.87 ms
p50 B (results/builds/race, 5 runs): 1.05 1.08 1.04 1.05 1.04 ms
p50 B - A: +0.17 ms, 95% CI [+0.16, +0.18] ms: B is slower
p99 A (results/builds/plain, 5 runs): 1.65 1.62 1.69 1.70 1.64 ms
p99 B (results/builds/race, 5 runs): 1.78 1.98 1.81 1.80 1.86 ms
p99 B - A: +0.18 ms, 95% CI [+0.13, +0.26] ms: B is slower
~~~

Read the A/A comparison first. The same binary, measured twice: no difference shown at the p50 (interval [−0.01, +0.01] ms) or the p99 ([−0.07, +0.01] ms). The method passed, so the second comparison is worth reading: the race-detector build is slower by 0.17 ms at the p50 (95% CI [+0.16, +0.18]) and 0.18 ms at the p99 ([+0.13, +0.26]). Small, but real, on this machine, at this rate.

## Break it

**A fixed order, and no warm-up.** That's how the first version of this experiment ran. In `experiments/builds.sh`, replace the two lines that make and shuffle `runs` with one that takes the builds in turn:

~~~python
runs = [f"{build} {n}" for n in range(1, 6) for build in ("plain", "race", "plain-again")]
~~~

and feed the loop `"$order"` alone, without the `warm-up 0` line (and drop the `rm` of the warm-up files). Run the experiment and the A/A comparison again:

~~~text
order: plain 1,race 1,plain-again 1,plain 2,race 2,plain-again 2,plain 3,race 3,plain-again 3,plain 4,race 4,plain-again 4,plain 5,race 5,plain-again 5
p50 A (results/fixed/plain, 5 runs): 0.90 0.94 0.94 0.88 0.94 ms
p50 B (results/fixed/plain-again, 5 runs): 0.93 0.94 0.88 0.94 0.93 ms
p50 B - A: +0.00 ms, 95% CI [-0.03, +0.03] ms: no difference shown: the interval includes 0
p99 A (results/fixed/plain, 5 runs): 2.47 1.75 1.74 1.64 1.63 ms
p99 B (results/fixed/plain-again, 5 runs): 1.66 1.68 1.58 1.64 1.63 ms
p99 B - A: -0.21 ms, 95% CI [-0.53, -0.01] ms: B is faster
~~~

The A/A test failed: the same binary "B is faster" at the p99, with an interval, [−0.53, −0.01] ms, that excludes zero. Look at the runs: `plain`'s first p99 was 2.47 ms, against 1.58 to 1.75 ms for every other run. That run was the first of the whole experiment, on a machine that had been idle, and in a fixed order it always belongs to the same build. Without the A/A test you'd have believed it.

Run the broken version again, and it may pass. This module's second capture did:

~~~text
order: plain 1,race 1,plain-again 1,plain 2,race 2,plain-again 2,plain 3,race 3,plain-again 3,plain 4,race 4,plain-again 4,plain 5,race 5,plain-again 5
p50 A (results/fixed/plain, 5 runs): 0.87 0.89 0.94 0.89 0.90 ms
p50 B (results/fixed/plain-again, 5 runs): 0.93 0.94 0.94 0.89 0.91 ms
p50 B - A: +0.03 ms, 95% CI [-0.00, +0.05] ms: no difference shown: the interval includes 0
p99 A (results/fixed/plain, 5 runs): 1.56 1.67 1.71 1.65 1.67 ms
p99 B (results/fixed/plain-again, 5 runs): 1.73 1.66 1.59 1.63 1.73 ms
p99 B - A: +0.01 ms, 95% CI [-0.05, +0.08] ms: no difference shown: the interval includes 0
~~~

That's the danger: a biased method doesn't fail every time, so a passing run proves nothing about it. The warm-up run and the random order are what make the result trustworthy, not one lucky A/A test.

## Check it

~~~bash
uv run kload compare results/builds/plain results/builds/plain-again
~~~

Then run this module's gate. It builds its own server, whose answers take a known time and which logs when each request really arrived, and checks `kload` against it: on schedule and accurate at 200 requests a second, open and closed loops through a 1-second freeze, an honest exit 3 at 20,000 a second, and `kload compare` on runs it writes itself. Close other busy programs first, since it checks timing. It takes about a minute:

~~~bash
bash ~/Nicholas-Engineering-Blueprint/2-core/02-python-runtime-and-honest-measurement/gate/run.sh ~/blueprint/kload
~~~

~~~text
PASS  ruff format
PASS  ruff check
PASS  pytest
PASS  200 requests a second for 5 s against a 5 ms server: on schedule, and accurate
      arrived on schedule: p99 0.74 ms off, worst 1.32 ms
      p50: kload says 6.84 ms; the server took 5.54 ms
PASS  the server freezes for 1 s: open loop
      52 of 500 requests took 500 ms or more
PASS  the server freezes for 1 s: closed loop
      1 of 500 requests took 500 ms or more
PASS  at 20,000 requests a second, kload says it fell behind and exits 3
      kload fell behind its schedule: send lag p99 2489.7 ms is over --max-lag-ms 10. These latencies include time spent waiting inside kload: don't trust them.
      the server saw 40000 requests spread over 4.50 s, not 2 s
PASS  kload compare: two sets of runs from the same server
      p99 B - A: +0.01 ms, 95% CI [-0.16, +0.18] ms: no difference shown: the interval includes 0
PASS  kload compare: B is 2 ms slower in every run
      p99 B - A: +2.00 ms, 95% CI [+1.84, +2.17] ms: B is slower

gate passed
~~~

<!-- run: bash "$BLUEPRINT_ROOT/2-core/02-python-runtime-and-honest-measurement/gate/run.sh" . -->

Then, from memory: why is a run, not a request, the unit of evidence? What does an interval that includes zero mean, and what doesn't it mean? Why randomise the order of runs? What is an A/A test for?

This proves `kload compare` resamples and reads the interval correctly, and that your experiment's method passes an A/A test on your machine. It doesn't prove a difference matters: whether 0.2 ms is worth anything depends on what the service is for, which no statistic can tell you.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `kload: results/builds/race needs at least 2 runs` | The experiment stopped early, or the folder name is wrong | Read the experiment's output; `ls results/builds/race` |
| `bind: address already in use` in a run | Another Switchyard is still running | `pkill -x switchyard`, then run the experiment again |
| The A/A comparison shows a difference | Something drifted with the order, or a background job ran during some runs | Close other programs, rerun; if it persists, use more runs |
| Every interval is very wide | One or two wild runs | Look at the per-run values `compare` prints; rerun with more runs |
| `--settings` ignored a value you typed | It wasn't typed after `--settings`'s subcommand | Options go after `load`: `kload load --settings F --rate 500` |
