# 03 Compare congestion controllers on the same link

> Networking in depth · Week 2 · Builds on lesson 02

## The problem

A controller can complete an isolated transfer quickly and still take a very different share when a second flow competes for the same bottleneck.

## The mental model

Use the same short path, rate limiter, loss settings, and payload for each algorithm. Verify the algorithm from the sender. Then run two transfers against the same egress queue at the same time.

## The pattern

Reno and CUBIC respond to congestion with different window-growth rules. BBR uses estimates of path capacity and round-trip time. Record the available algorithms from the running kernel and measure only those verified by the sender.

## Build it

### Step 1 — Predict sharing

Identify which trials compare solo goodput and which compare concurrent shares. Write which direction both data flows must take.

<details>
<summary>Hint</summary>

Using separate receivers does not imply separate bottlenecks.

</details>

### Step 2 — Parse the observations

Read measured receiver goodput, sender retransmissions, observed algorithm, and qdisc evidence. Keep the individual runs.

<details>
<summary>Hint</summary>

Check the configured rate in bytes per second and convert it to decimal Mbit/s.

</details>

<details>
<summary>Implementation</summary>

Create `experiments/figures.py`.

<!-- file: experiments/figures.py -->
~~~python
"""Interpret the raw transport outputs without changing the fixtures."""

import json
from pathlib import Path
import re
from statistics import median


def read(path):
    return json.loads(path.read_text())


def flow(directory, name):
    result = read(directory / f"{name}.json")
    if "error" in result:
        raise ValueError(f"{name}: {result['error']}")
    end = result["end"]
    return {
        "mbit_s": round(end["sum_received"]["bits_per_second"] / 1e6, 3),
        "retransmits": end["sum_sent"]["retransmits"],
        "controller": end["sender_tcp_congestion"],
    }


def transport(directory):
    baseline = flow(directory, "baseline")
    measured = {
        "baseline": baseline,
        "short": flow(directory, "short"),
        "small_window": flow(directory, "small-window"),
        "loss": [flow(directory, f"loss-{n}") for n in range(1, 4)],
    }
    names = (directory / "controllers.txt").read_text().split()
    measured["controllers"] = {
        name: [flow(directory, f"{name}-{n}") for n in (1, 2)]
        for name in ("reno", "cubic", "bbr") if name in names
    }
    measured["unavailable"] = [name for name in ("reno", "cubic", "bbr") if name not in names]
    for name, runs in measured["controllers"].items():
        assert all(run["controller"] == name for run in runs), runs
    measured["sharing"] = [flow(directory, f"share-{n}") for n in (1, 2)]
    assert all(run["mbit_s"] > 0 for run in measured["sharing"])
    measured["failed_control_attempts"] = sorted(path.name for path in directory.glob("*-attempt-*.json"))
    assert 14 < baseline["mbit_s"] < 21, baseline
    rate = read(directory / "baseline-edge-qdisc.json")[0]["options"]["rate"]
    assert rate == 2_500_000, rate  # tc JSON reports bytes/s.
    assert sum(row["retransmits"] for row in measured["loss"]) > 0
    assert sum(read(directory / f"loss-{n}-origin-qdisc.json")[0]["drops"] for n in range(1, 4)) > 0
    return measured


def rtt(path):
    samples = [float(number) for number in re.findall(r"time[=<]([\d.]+) ms", path.read_text())]
    if not samples:
        raise ValueError(f"no echo timings in {path}")
    return round(median(samples), 2)


if __name__ == "__main__":
    import sys

    print(json.dumps(transport(Path(sys.argv[1])), indent=2))
~~~

</details>

### Step 3 — Account for missing features

Read `controllers.txt` before interpreting the summary. Read the available algorithm names in the live namespace.

<details>
<summary>Hint</summary>

The reference kernel offered Reno and CUBIC. The summary records BBR as unavailable in that run.

</details>

## Check it

~~~bash
python3 -B experiments/figures.py "$NETWORK_EVIDENCE_DIR/transport"
~~~

<!-- run: python3 -B -c 'import ast; ast.parse(open("experiments/figures.py").read())' -->

The live report records each controller’s goodput, retransmissions, and the two concurrent flow rates. [Reference summary](../evidence/summary.json)

## If it goes wrong

If the configured and observed sender algorithms differ, check which endpoint sent the data and how iperf set its socket options.
