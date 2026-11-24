# 08 Benchmark performance, cost and quality together

Write a plan first. Compare slots 1/2/4, Q4/Q8 and two thread counts. Fix prompt/output limits, randomise configuration order, repeat at least five independent runs, and retain raw arrivals, failures and usage. Include both short and long prompts with no accidental shared prefix. Record image, model and tokenizer hashes, host CPU/memory and runtime versions, load seed and wall-clock start/end. Record cold starts separately. Resample whole runs, as [Core 02, lesson 08](../../../../2-core/02-python-runtime-and-honest-measurement/lessons/08-repeat-runs-and-confidence-intervals.md) does, for correlated measurements; a thousand requests in one run are not a thousand independent runs.

Cost per million **completed output tokens** is billed hourly price × elapsed hours × 1,000,000 / completed output tokens. Include idle time and unused reserved capacity for a deployment-cost comparison. For a rented benchmark also report model download/load costs separately. A synthetic price is an assumption, never a current vendor quote. Do not substitute chunk counts when the server omits token usage.


<!-- file: serve/src/serve/score.py -->
~~~python
"""All-arrivals objective and cost: missing evidence cannot pass a release gate."""

import argparse
import json
import math


def score(rows, seconds, hourly, quality):
    if not rows or seconds <= 0 or hourly < 0:
        raise ValueError("rows, positive duration and nonnegative price required")
    valid = [r for r in rows if not r["error"] and r["ttft"] is not None]
    good = [r for r in valid if r["ttft"] <= 1]
    tokens_known = all(r.get("output_tokens") is not None for r in valid)
    tokens = sum(r["output_tokens"] for r in valid) if tokens_known else None
    # A one-sided 95% Wilson lower bound; requests are treated as independent.
    # Correlated overload requires resampling whole runs instead (Core 02, lesson 08).
    n, p, z = len(rows), len(good) / len(rows), 1.645
    lower = (p + z * z / (2 * n) - z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))) / (
        1 + z * z / n
    )
    return {
        "offered": n,
        "completed": len(valid),
        "good_fraction": p,
        "good_lower95": lower,
        "output_tokens": tokens,
        "cost_per_million": hourly * seconds / 3600 * 1e6 / tokens if tokens else None,
        "quality": quality,
        "verdict": "pass" if lower >= 0.99 and quality is True and tokens else "not established",
    }


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("rows")
    p.add_argument("--seconds", type=float, required=True)
    p.add_argument("--hourly", type=float, required=True)
    p.add_argument("--quality", choices=["pass", "fail", "unknown"], default="unknown")
    a = p.parse_args()
    rows = [json.loads(line) for line in open(a.rows)]
    quality = {"pass": True, "fail": False, "unknown": None}[a.quality]
    print(json.dumps(score(rows, a.seconds, a.hourly, quality), indent=2))
~~~


<!-- file: serve/tests/test_score.py -->
~~~python
from serve.score import score


def test_failures_stay_in_denominator_and_unknown_tokens_cannot_pass():
    good = {"error": "", "ttft": 0.1, "output_tokens": 20}
    bad = {"error": "timeout", "ttft": None, "output_tokens": None}
    result = score([good, bad], 10, 1, True)
    assert result["good_fraction"] == 0.5
    assert result["cost_per_million"] > 0
    assert result["verdict"] == "not established"
    assert score([{**good, "output_tokens": None}], 10, 1, True)["cost_per_million"] is None
    assert score([good] * 1000, 10, 1, None)["verdict"] == "not established"
    assert score([good] * 1000, 10, 1, True)["verdict"] == "pass"
~~~

<!-- run: cd serve && uv run pytest -q tests/test_score.py -->

~~~bash
cd serve
uv run python -m serve.score ../results/slots1-rate02.jsonl --seconds 500 --hourly 0.10
~~~

Replace 500 with the actual full run duration and 0.10 with the explicitly assumed or billed hourly cost. The command returns `not established` when quality is unknown. Its Wilson bound assumes independent requests; for the real load grid, replace it with an interval across whole runs, as in Core 02. A point estimate of 100% on ten requests cannot establish a 99% objective.

Freeze twenty held-out prompts before comparing quantisation: extraction with exact fields, grounded questions with expected facts, short arithmetic and refusal of an unsupported answer. Store the expected outputs and a scoring rubric. Score blind to configuration, check every slice, and decide the minimum acceptable score before running. Small instruction models may fail the quality target entirely. Report that result rather than loosening the target after seeing it. `--quality pass` means the retained rubric evidence passed; it is not an automatic quality measurement.

**Break it:** feed the scorer an all-timeout run and an otherwise successful run with missing usage. Neither may manufacture a finite successful cost or pass verdict. Explain how dropping failed rows would make an overloaded configuration look cheap and fast.

## A reproducible CPU grid

The [2026-11-07 experiment plan](../evidence/2026-11-07/plan.md) fixes a short eight-output-token workload, twenty toy quality prompts, five repetitions and rates chosen from a separate low-load baseline. It compares Q4/Q8 and one/two slots at four threads. It does not replace the longer-context, additional-thread-count and GPU experiments above.

The runner below owns only the Docker container `blueprint-serve-llm` on loopback port 18080. Start that container with the exact one-slot Q4 settings before invoking the runner. Use a fresh result directory: rerunning into a partial directory would append incompatible runs. Never point it at a directory containing accepted evidence. The published capture used the same algorithm with local model/output paths substituted; its environment and frozen inputs are retained beside the results.

<!-- file: serve/src/serve/experiment.py -->
~~~python
import concurrent.futures
import hashlib
import json
import os
import platform
import random
import statistics
import subprocess
import time
from dataclasses import asdict
from pathlib import Path

from serve.stream import chat

OUT = Path(os.environ["SERVE_RESULTS"])
OUT.mkdir(parents=True, exist_ok=True)
MODEL = os.environ["SERVE_MODELS"]
IMAGE = (
    "ghcr.io/ggml-org/llama.cpp@sha256:"
    "e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b"
)
URL = "http://127.0.0.1:18080"
NAME = "blueprint-serve-llm"


def save(name, value):
    (OUT / name).write_text(json.dumps(value, indent=2) + "\n")


def restart(precision, slots):
    subprocess.run(["docker", "rm", "-f", NAME], capture_output=True, check=True)
    subprocess.run(
        [
            "docker",
            "run",
            "-d",
            "--name",
            NAME,
            "-p",
            "127.0.0.1:18080:8080",
            "-v",
            MODEL + ":/models:ro",
            IMAGE,
            "-m",
            f"/models/qwen2.5-0.5b-instruct-{precision}.gguf",
            "-c",
            str(4096 * slots),
            "-t",
            "4",
            "--parallel",
            str(slots),
            "--metrics",
            "--host",
            "0.0.0.0",
        ],
        capture_output=True,
        check=True,
    )
    import urllib.request

    for _ in range(120):
        try:
            with urllib.request.urlopen(URL + "/health", timeout=1) as r:
                if r.status == 200:
                    break
        except OSError:
            time.sleep(0.5)
    else:
        raise RuntimeError("model did not become ready")
    for i in range(3):
        result = chat(URL, f"Warmup {i}: Explain backpressure briefly.", 8)
        if result.error:
            raise RuntimeError(result.error)


def measure(rate, n, seed, precision, slots, rep):
    rng = random.Random(seed)
    due = 0
    arrivals = []
    for i in range(n):
        due += rng.expovariate(rate)
        arrivals.append(
            (i, due, f"Request {rng.getrandbits(64)}: Explain backpressure in two sentences.")
        )
    start = time.monotonic()
    wall = time.time()

    def one(i, due, prompt):
        lag = max(0, time.monotonic() - start - due)
        result = asdict(chat(URL, prompt, 8, timeout=30))
        if result["ttft"] is not None:
            result["ttft"] += lag
        result.update(
            id=i,
            arrival=due,
            dispatch_lag=lag,
            precision=precision,
            slots=slots,
            rep=rep,
            rate=rate,
            seed=seed,
        )
        return result

    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
        futures = []
        for i, due, prompt in arrivals:
            time.sleep(max(0, start + due - time.monotonic()))
            futures.append(pool.submit(one, i, due, prompt))
        rows = [f.result() for f in futures]
    seconds = time.monotonic() - start
    wall_seconds = time.time() - wall
    with (OUT / "arrivals.jsonl").open("a") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    completed = [r for r in rows if not r["error"] and r["ttft"] is not None]
    tokens = (
        sum(r["output_tokens"] for r in completed)
        if all(r["output_tokens"] is not None for r in completed)
        else None
    )
    summary = dict(
        precision=precision,
        slots=slots,
        rep=rep,
        rate=rate,
        seed=seed,
        offered=n,
        completed=len(completed),
        good=sum(r["ttft"] <= 1 for r in completed),
        seconds=seconds,
        wall_seconds=wall_seconds,
        clock_ratio=wall_seconds / seconds,
        max_dispatch_lag=max(r["dispatch_lag"] for r in rows),
        output_tokens=tokens,
        mean_ttft=statistics.mean(r["ttft"] for r in completed) if completed else None,
        mean_completion=statistics.mean(r["total"] + r["dispatch_lag"] for r in completed)
        if completed
        else None,
    )
    with (OUT / "runs.jsonl").open("a") as f:
        f.write(json.dumps(summary) + "\n")
    print(json.dumps(summary), flush=True)


quality = []
for i in range(1, 9):
    quality.append(
        {"prompt": f"Reply with only the result: {i} + {i + 1}.", "expected": str(2 * i + 1)}
    )
for word in ("river", "stone", "cloud", "garden", "signal", "window", "paper", "engine"):
    quality.append(
        {
            "prompt": f"Copy the word inside brackets. Reply with that word only: [{word}]",
            "expected": word,
        }
    )
for city, person in [("Lima", "Ada"), ("Oslo", "Ben"), ("Accra", "Cara"), ("Kyoto", "Dan")]:
    quality.append(
        {
            "prompt": (
                f"Use only this fact: {person} lives in {city}. "
                f"Which city does {person} live in? Reply with the city only."
            ),
            "expected": city,
        }
    )
save("quality-set.json", quality)
try:
    metadata = {
        "python": platform.python_version(),
        "system": platform.system(),
        "machine": platform.machine(),
        "logical_cpus": os.cpu_count(),
        "image": IMAGE,
        "price_assumption_usd_per_hour": 0.1,
        "threads": 4,
        "context_per_slot": 4096,
        "output_limit": 8,
        "model_sha256": {
            p.name: hashlib.file_digest(p.open("rb"), "sha256").hexdigest()
            for p in Path(MODEL).glob("*.gguf")
        },
    }
    save("environment.json", metadata)
    for i in range(3):
        chat(URL, f"Warmup baseline {i}. Explain a queue.", 8)
    baseline = [
        asdict(chat(URL, f"Baseline {i}: Explain backpressure briefly.", 8)) for i in range(8)
    ]
    assert all(not r["error"] for r in baseline)
    service = statistics.mean(r["total"] for r in baseline)
    save(
        "baseline.json",
        {
            "rows": baseline,
            "mean_service_seconds": service,
            "rates": [x / service for x in (0.4, 0.8, 1.2)],
        },
    )
    print(f"baseline S={service}", flush=True)
    rng = random.Random(20261107)
    for rep in range(1, 6):
        configs = [(p, s) for p in ("q4_k_m", "q8_0") for s in (1, 2)]
        rng.shuffle(configs)
        for precision, slots in configs:
            restart(precision, slots)
            for rate_index, multiple in enumerate((0.4, 0.8, 1.2)):
                measure(
                    multiple / service, 12, 20261107 + rep * 100 + rate_index, precision, slots, rep
                )
            if rep == 1:
                scored = []
                for item in quality:
                    result = asdict(chat(URL, item["prompt"], 32))
                    normal = result["text"].strip().rstrip(".!?").strip().casefold()
                    scored.append(
                        {
                            **item,
                            **result,
                            "exact_match": not result["error"]
                            and normal == item["expected"].casefold(),
                        }
                    )
                save(
                    f"quality-{precision}-slots{slots}.json",
                    {
                        "correct": sum(r["exact_match"] for r in scored),
                        "total": len(scored),
                        "rows": scored,
                    },
                )
finally:
    subprocess.run(["docker", "rm", "-f", NAME], capture_output=True)
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . -->

~~~bash
# From the lab root; SERVE_MODELS must contain both verified GGUF files.
export SERVE_MODELS="$PWD/models"
export SERVE_RESULTS="$PWD/results/cpu-grid-new"
mkdir -p "$SERVE_RESULTS"
docker run -d --name blueprint-serve-llm -p 127.0.0.1:18080:8080 \
  -v "$SERVE_MODELS:/models:ro" \
  ghcr.io/ggml-org/llama.cpp@sha256:e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b \
  -m /models/qwen2.5-0.5b-instruct-q4_k_m.gguf -c 4096 -t 4 \
  --parallel 1 --metrics --host 0.0.0.0
# Wait for /health to return 200 before starting the baseline.
cd serve
uv run python -m serve.experiment
~~~

All generated requests are synthetic. The hypothetical $0.10/hour CPU price exercises the accounting only. The quality set is intentionally small: passing it cannot establish general answer quality or model safety. The [evidence report](../evidence/2026-11-07/report.md) states which conclusions the capture supports and which remain unmeasured.

The report builder refuses missing/duplicate repetition blocks. Its t intervals describe run-level variability on this host, not independent users or a production acceptance guarantee. It returns missing cost/latency intervals when their required evidence is absent.

<!-- file: serve/src/serve/report.py -->
~~~python
"""Summarise independent run blocks, retaining failures and quality gates."""

import argparse
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path


def interval(values):
    mean = statistics.mean(values)
    if len(values) != 5:
        raise ValueError("the preregistered report requires five repetitions per condition")
    # Two-sided 95% Student t interval for five independent run-level means.
    half = 2.7764451051977987 * statistics.stdev(values) / math.sqrt(5)
    return [mean, mean - half, mean + half]


def summarize(root):
    groups = defaultdict(list)
    rows = [json.loads(line) for line in (root / "runs.jsonl").read_text().splitlines()]
    if len(rows) != 60:
        raise ValueError("incomplete grid: expected sixty runs")
    for row in rows:
        groups[(row["precision"], row["slots"], row["rate"])].append(row)
    results = []
    for (precision, slots, rate), runs in sorted(groups.items()):
        if sorted(r["rep"] for r in runs) != [1, 2, 3, 4, 5]:
            raise ValueError("missing/duplicate repetitions")
        quality = json.loads((root / f"quality-{precision}-slots{slots}.json").read_text())
        good = interval([r["good"] / r["offered"] for r in runs])
        costs = (
            [0.10 * r["seconds"] / 3600 * 1e6 / r["output_tokens"] for r in runs]
            if all(r["output_tokens"] for r in runs)
            else None
        )
        valid_timing = all(
            abs(r["clock_ratio"] - 1) <= 0.02 and r["max_dispatch_lag"] <= 0.05 for r in runs
        )
        # A t interval on short bounded proportions is exploratory, not a
        # production 99% acceptance test. Never promote from this small grid.
        results.append(
            {
                "precision": precision,
                "slots": slots,
                "rate": rate,
                "offered": sum(r["offered"] for r in runs),
                "completed": sum(r["completed"] for r in runs),
                "good_run_fraction_mean_ci95": good,
                "mean_ttft_seconds_ci95": (
                    interval([r["mean_ttft"] for r in runs])
                    if all(r["mean_ttft"] is not None for r in runs)
                    else None
                ),
                "hypothetical_usd_per_million_output_tokens_ci95": interval(costs)
                if costs is not None
                else None,
                "quality_correct": quality["correct"],
                "quality_total": quality["total"],
                "quality_pass": quality["correct"] >= 18,
                "clock_and_dispatch_checks_pass": valid_timing,
                "production_acceptance": "not established",
            }
        )
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.directory), indent=2))
~~~

~~~bash
cd serve
uv run python -m serve.report "$SERVE_RESULTS" > "$SERVE_RESULTS/summary.json"
~~~
