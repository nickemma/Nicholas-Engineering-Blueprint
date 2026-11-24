# 03 Batching, concurrency and the knee

Static batching admits a group, then waits for its longest output. Continuous batching can admit another request when a slot becomes free. Build a token-tick simulator to isolate that scheduling decision. A tick is an abstract unit: this model predicts neither GPU speed nor real prefill interference.


<!-- file: serve/src/serve/batching.py -->
~~~python
"""Token-tick model: all jobs arrive at zero; no prefill or hardware cost."""


def finish_times(lengths, slots, continuous):
    pending = list(enumerate(lengths))
    active = []
    finished = {}
    tick = 0
    while pending or active:
        if continuous or not active:
            while pending and len(active) < slots:
                active.append(pending.pop(0))
        tick += 1
        next_active = []
        for i, left in active:
            if left == 1:
                finished[i] = tick
            else:
                next_active.append((i, left - 1))
        active = next_active
    return finished


if __name__ == "__main__":
    lengths = [2, 8, 2, 2]
    for continuous in (False, True):
        print(continuous, finish_times(lengths, 2, continuous))
~~~


<!-- file: serve/tests/test_batching.py -->
~~~python
from serve.batching import finish_times


def test_short_requests_can_reuse_a_slot_without_waiting_for_the_long_one():
    assert finish_times([2, 8, 2, 2], 2, False) == {0: 2, 1: 8, 2: 10, 3: 10}
    assert finish_times([2, 8, 2, 2], 2, True) == {0: 2, 2: 4, 3: 6, 1: 8}
~~~

<!-- run: cd serve && uv run pytest -q tests/test_batching.py && uv run python -m serve.batching -->

The short jobs finish at ticks 2, 10 and 10 with static batches, and 2, 4 and 6 with continuous admission. The long job still finishes at tick 8. Real batching amortises reading weights but consumes more KV memory and may increase per-token latency. Concurrency is requests in flight; batch size is work executed together. They are not interchangeable.

Now offer arrivals independently of completion. A closed-loop client slows its arrivals when the server slows, hiding the queue you need to see. This client preselects Poisson arrivals, records dispatch lag when its own thread pool saturates, and keeps every request. Do not publish a server capacity estimate when dispatch lag is material.


<!-- file: serve/src/serve/load.py -->
~~~python
"""Open-loop arrivals: retain every arrival, including client-side overload."""

import argparse
import concurrent.futures
import json
import random
import time
from dataclasses import asdict

from serve.stream import chat


def run(url, rate, n, seed, workers=32):
    if rate <= 0 or n <= 0:
        raise ValueError("positive rate and count required")
    rng = random.Random(seed)
    due = 0.0
    arrivals = []
    for i in range(n):
        due += rng.expovariate(rate)
        prompt = f"Request {rng.getrandbits(64)}: Explain backpressure in two sentences."
        arrivals.append((i, due, prompt))
    start = time.monotonic()

    def one(i, due, prompt):
        lag = time.monotonic() - start - due
        result = asdict(chat(url, prompt))
        result.update(id=i, arrival=due, dispatch_lag=max(0, lag))
        if result["ttft"] is not None:
            result["ttft"] += max(0, lag)
        return result

    rows = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        pending = []
        for i, due, prompt in arrivals:
            time.sleep(max(0, start + due - time.monotonic()))
            pending.append(pool.submit(one, i, due, prompt))
        for future in pending:
            rows.append(future.result())
    return rows


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--url", default="http://127.0.0.1:8000")
    p.add_argument("--rate", type=float, required=True)
    p.add_argument("--n", type=int, default=100)
    p.add_argument("--seed", type=int, default=1)
    args = p.parse_args()
    for row in run(args.url, args.rate, args.n, args.seed):
        print(json.dumps(row))
~~~

<!-- run: cd serve && uv run python -m compileall -q src -->

~~~bash
mkdir -p results
cd serve
uv run python -m serve.load --rate 0.2 --n 100 --seed 7 > ../results/slots1-rate02.jsonl
~~~

First measure low-load mean service time S, then try arrival rates 0.3/S, 0.6/S, 0.8/S and 1.1/S. Bound each run and retain timeout rows. Repeat with 1, 2 and 4 server slots, interleaving their order across at least five runs. Keep total context per slot fixed, as `server.sh` does. Record process RSS and model settings with each run. Warm up separately; discard by arrival ID, never by completion order. Use the [queueing guide](../../../../math/01-queueing/README.md) to compare observed queue length L with arrival rate times time in system. M/M/1 is a reference, not an exact model of a batched server with variable prompts.

The old knee experiments include clock-contaminated and interrupted captures. They do **not** establish a publishable saturation point. Re-run the grid; do not fill in the curve from the utilisation formula. The historical thread sweep also shows why cores are not free: 8 threads improved prefill versus 4, but 16 made both prefill and chunk gaps worse.

**Break it:** run beyond capacity. Check failures, dispatch lag, TTFT, memory and queue depth together. Lower the rate and verify the queue drains. Explain why unlimited queues change overload into arbitrarily late answers.
