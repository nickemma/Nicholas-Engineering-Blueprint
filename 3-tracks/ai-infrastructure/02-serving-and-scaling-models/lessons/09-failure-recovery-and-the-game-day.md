# 09 Failure, recovery and the game day

Lessons 04 to 08 built defences. The API returns 502 when the model is gone and 503 when the shared budget can't be checked. Admission refuses work it can't serve. Cancellation frees the model when a client leaves. A **game day** tests those defences on purpose: you break one thing at a time, watch what happens, and write it down. Finding out that a defence doesn't work is much cheaper on a quiet afternoon than during a real outage.

The rules:

1. **Write down what you expect first.** For each fault: what users should see, how you'll notice, what you'll do, and what counts as fixed. A drill with no prediction can't fail, so it can't teach you anything.
2. **One fault at a time.** With two faults at once, you can't tell which one caused what. If a drill fails, stop and fix the system before starting the next one.
3. **Four timestamps:** when the fault was injected, detected, mitigated and recovered. Use a monotonic clock: [Core 07](../../../../2-core/07-distributed-systems-fundamentals/lessons/01-what-a-node-can-know.md) showed that the wall clock can jump.
4. **Recovered means users are served.** Here, that's ten requests in a row through the API that stream a complete, nonempty answer. A green `/health` only says a process started. One failure among the ten restarts the count.
5. **Run every drill twice.** A fault that recovered once might have been luck.

| Fault | How you cause it | What users should see | Mitigation | Fixed when |
|---|---|---|---|---|
| Model exits | `docker kill` the model | 502, at once | Restart the same verified release | Ten good streams |
| Redis is down | `docker stop` Redis | 503: without the shared budget there's no generation (lesson 04 fails closed) | Restart Redis | Ten good streams |
| Overload | 18 long requests at the same instant | Some 503s within milliseconds; admitted requests still get answers | None: admission sheds the excess | The queue drains, then ten good streams |
| Client leaves mid-answer | Reset the connection while tokens stream | Nothing: that client is gone | Cancellation reaches the model | The model's slot is idle within 8 s |
| Scraper is down | `docker stop` Prometheus | Nothing: requests still succeed | Restart Prometheus | Ten good streams |
| Model runs out of memory | Shrink the model container's limit to 32 MiB | 502 once the kernel kills the model | Restore the limit, then restart | Ten good streams |

The scraper row looks odd, since users don't notice anything. That's the point: losing monitoring doesn't hurt anyone directly, but it means you can't see when something else does. No alerts doesn't mean healthy.

## The recovery check

This part needs no Docker, so it can be tested properly. Recovery and the record of each drill go in their own module:

<!-- file: serve/src/serve/recovery.py -->
~~~python
"""Recovery is measured with real requests, and a failed drill is still a result.

Recovery means ten consecutive completed, nonempty streams through the API.
A green /health only says the process started; it does not say users are served.
"""

import time
from collections.abc import Callable
from dataclasses import dataclass, field


class Clock:
    """Seconds since the drill started, on a clock that never jumps."""

    def __init__(self) -> None:
        self.start = time.monotonic()

    def __call__(self) -> float:
        return round(time.monotonic() - self.start, 3)


@dataclass
class Case:
    fault: str
    repetition: int
    injected: float
    detected: float | None = None
    mitigated: float | None = None
    recovered: float | None = None
    during: list[dict] = field(default_factory=list)
    recovery: list[dict] = field(default_factory=list)
    notes: dict = field(default_factory=dict)
    passed: bool = False
    failure: str = ""


class NotRecovered(Exception):
    pass


def recover(probe: Callable[[], dict], clock: Callable[[], float], need=10, limit=90.0):
    """Probe until `need` requests in a row succeed. Any failure restarts the count."""
    rows, streak = [], 0
    deadline = clock() + limit
    while streak < need:
        if clock() > deadline:
            raise NotRecovered(f"{streak} of {need} consecutive successes after {limit:.0f} s")
        row = probe()
        rows.append(row)
        streak = 0 if row["error"] else streak + 1
    return rows


def run_case(name, repetition, fault, recovery, clock) -> Case:
    """Inject, mitigate, then require recovery. A failed drill is a result: keep it."""
    case = Case(name, repetition, injected=clock())
    try:
        fault(case)
        case.mitigated = clock()
        case.recovery = recovery()
        case.recovered = clock()
        case.passed = True
    except Exception as exc:
        case.failure = f"{type(exc).__name__}: {exc}"
    return case


def summary(cases: list[Case]) -> str:
    lines = [f"{'fault':<18} {'rep':>3} {'detect s':>9} {'recover s':>10}  result"]
    for c in cases:
        detect = f"{c.detected - c.injected:.2f}" if c.detected is not None else "-"
        total = f"{c.recovered - c.injected:.1f}" if c.recovered is not None else "-"
        result = "passed" if c.passed else "FAILED " + c.failure
        lines.append(f"{c.fault:<18} {c.repetition:>3} {detect:>9} {total:>10}  {result}")
    return "\n".join(lines)
~~~

`recover` accepts any `probe` function and any clock. In a real drill, the probe streams a request through the API and the clock is `Clock`. The tests pass in a list of results and a fake clock that moves on one second every time it's read, so no test waits for real time. `run_case` deliberately catches every exception: a failed drill is a result to keep, not a crash to hide. The record stores the exception's name and message.

<!-- file: serve/tests/test_recovery.py -->
~~~python
import pytest

from serve.recovery import NotRecovered, recover, run_case


class FakeClock:
    """Each reading moves time on by one second."""

    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        self.now += 1
        return self.now


def probes(errors: list[str]):
    rows = iter(errors)
    return lambda: {"error": next(rows)}


def test_recovery_needs_consecutive_successes():
    # Five good, one failure, then ten good: the failure restarts the count.
    sequence = [""] * 5 + ["status 502"] + [""] * 10
    rows = recover(probes(sequence), FakeClock(), need=10, limit=100)
    assert len(rows) == 16


def test_recovery_gives_up_at_the_deadline():
    with pytest.raises(NotRecovered, match="0 of 10"):
        recover(lambda: {"error": "status 502"}, FakeClock(), need=10, limit=20)


def test_a_failed_drill_is_kept_with_its_reason():
    def broken(case):
        case.detected = 1.0
        raise AssertionError("expected 'status 503', got ''")

    case = run_case("redis-unavailable", 1, broken, lambda: [], FakeClock())
    assert not case.passed and case.recovered is None
    assert "expected 'status 503'" in case.failure

    ok = run_case("model-exit", 1, lambda case: None, lambda: [{"error": ""}], FakeClock())
    assert ok.passed and ok.injected < ok.mitigated < ok.recovered
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_recovery.py -->

~~~bash
cd serve
uv run pytest -q tests/test_recovery.py
~~~

All three tests pass.

**Break it:** make `recover` count *total* successes instead of successes *in a row*. Replace the `streak = 0 if ...` line with `streak += not row["error"]`, then run the tests again:

~~~text
>       assert len(rows) == 16
E       AssertionError: assert 11 == 16
1 failed, 2 passed
~~~

Five good answers, one failure and five more good ones, and it declared recovery. A service that keeps failing every few requests would pass that check. Put the line back.

## The faults

The drills themselves talk to Docker and to the running stack:

<!-- file: serve/src/serve/gameday.py -->
~~~python
"""Run a game day: inject one fault at a time, mitigate it, then prove recovery."""

import argparse
import concurrent.futures
import json
import os
import socket
import struct
import subprocess
import threading
import time
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from urllib.parse import urlsplit

from serve.recovery import Case, Clock, recover, run_case, summary
from serve.stream import chat

LONG = "Count from one to one thousand, one number per line."


@dataclass
class Lab:
    api: str
    model: str
    scraper: str
    model_container: str
    redis_container: str
    scraper_container: str
    clock: Clock

    def probe(self, max_tokens=8, prompt="Reply with the word river.") -> dict:
        started = self.clock()
        row = asdict(chat(self.api, prompt, max_tokens, timeout=35))
        del row["text"]  # keep timings and errors, not model output
        row["started"] = started
        return row

    def docker(self, *args: str) -> str:
        done = subprocess.run(["docker", *args], capture_output=True, text=True)
        if done.returncode:
            raise RuntimeError(f"docker {args[0]}: {done.stderr.strip()}")
        return done.stdout.strip()

    def model_get(self, path: str):
        with urllib.request.urlopen(self.model + path, timeout=2) as response:
            return json.load(response)

    def wait_ready(self, limit=60.0) -> None:
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            try:
                if self.model_get("/health").get("status") == "ok":
                    return
            except OSError:
                pass
            time.sleep(0.1)
        raise TimeoutError("model not ready")

    def busy_slots(self) -> int:
        return sum(1 for slot in self.model_get("/slots") if slot["is_processing"])


def expect(row: dict, error: str) -> None:
    if row["error"] != error:
        raise AssertionError(f"expected {error!r}, got {row['error']!r}")


def model_exit(lab: Lab, case: Case) -> None:
    lab.docker("kill", lab.model_container)
    case.during.append(lab.probe())
    expect(case.during[-1], "status 502")
    case.detected = lab.clock()
    lab.docker("start", lab.model_container)
    lab.wait_ready()


def redis_unavailable(lab: Lab, case: Case) -> None:
    lab.docker("stop", "-t", "1", lab.redis_container)
    case.during.append(lab.probe())
    expect(case.during[-1], "status 503")  # fail closed: no shared budget, no generation
    case.detected = lab.clock()
    lab.docker("start", lab.redis_container)


def overload(lab: Lab, case: Case, offered=18) -> None:
    gate = threading.Barrier(offered)

    def one(_):
        gate.wait()  # release every request at once
        return lab.probe(128, LONG)

    with concurrent.futures.ThreadPoolExecutor(max_workers=offered) as pool:
        case.during = list(pool.map(one, range(offered)))
    rejected = [r for r in case.during if r["error"] == "status 503"]
    if not rejected:
        raise AssertionError("no request was refused: admission is unbounded")
    case.detected = min(r["started"] + r["total"] for r in rejected)
    case.notes["rejected"] = len(rejected)
    case.notes["completed"] = sum(1 for r in case.during if not r["error"])


def client_disconnect(lab: Lab, case: Case) -> None:
    api = urlsplit(lab.api)
    body = json.dumps(
        {"messages": [{"role": "user", "content": LONG}], "stream": True, "max_tokens": 512}
    ).encode()
    head = (
        f"POST /v1/chat/completions HTTP/1.1\r\nHost: {api.hostname}\r\n"
        f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n"
        f"Authorization: Bearer {os.environ['SWITCHYARD_TOKEN']}\r\n\r\n"
    ).encode()
    conn = socket.create_connection((api.hostname, api.port), timeout=10)
    conn.sendall(head + body)
    received = b""
    while b"data:" not in received:
        received += conn.recv(4096)
    case.notes["busy_before"] = lab.busy_slots()
    if not case.notes["busy_before"]:
        raise AssertionError("model was not generating when the client left")
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    conn.close()  # linger 0 sends a reset, like a client that vanished
    case.notes["reset"] = lab.clock()
    deadline = time.monotonic() + 8
    while lab.busy_slots():
        if time.monotonic() > deadline:
            raise AssertionError("the abandoned request still holds a model slot")
        time.sleep(0.05)
    case.notes["slot_free"] = lab.clock()


def scraper_loss(lab: Lab, case: Case) -> None:
    lab.docker("stop", "-t", "1", lab.scraper_container)
    try:
        urllib.request.urlopen(lab.scraper + "/-/ready", timeout=2)
        raise AssertionError("scraper still answers")
    except OSError:
        case.detected = lab.clock()
    case.during.append(lab.probe())
    expect(case.during[-1], "")  # users are fine; you are blind, not down
    lab.docker("start", lab.scraper_container)


def model_oom(lab: Lab, case: Case) -> None:
    lab.docker("update", "--memory", "32m", "--memory-swap", "32m", lab.model_container)
    case.during.append(lab.probe(128, LONG))
    deadline = time.monotonic() + 15
    while json.loads(lab.docker("inspect", lab.model_container))[0]["State"]["Running"]:
        if time.monotonic() > deadline:
            raise AssertionError("model survived the memory limit")
        time.sleep(0.1)
    state = json.loads(lab.docker("inspect", lab.model_container))[0]["State"]
    case.notes["oom_killed"] = state["OOMKilled"]
    case.during.append(lab.probe())
    expect(case.during[-1], "status 502")
    case.detected = lab.clock()
    lab.docker("update", "--memory", "2g", "--memory-swap", "2g", lab.model_container)
    lab.docker("start", lab.model_container)
    lab.wait_ready()


FAULTS = {
    "model-exit": model_exit,
    "redis-unavailable": redis_unavailable,
    "overload": overload,
    "client-disconnect": client_disconnect,
    "scraper-loss": scraper_loss,
    "model-oom": model_oom,
}


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--api", default="http://127.0.0.1:18081")
    p.add_argument("--model", default="http://127.0.0.1:18080")
    p.add_argument("--scraper", default="http://127.0.0.1:19090")
    p.add_argument("--model-container", default="blueprint-serve-llm")
    p.add_argument("--redis-container", default="blueprint-serve-redis")
    p.add_argument("--scraper-container", default="blueprint-serve-prometheus")
    p.add_argument("--faults", default=",".join(FAULTS))
    p.add_argument("--repeat", type=int, default=2)
    p.add_argument("--out", type=Path, default=Path("results/gameday.json"))
    a = p.parse_args()
    clock = Clock()
    lab = Lab(
        a.api,
        a.model,
        a.scraper,
        a.model_container,
        a.redis_container,
        a.scraper_container,
        clock,
    )
    cases: list[Case] = []
    a.out.parent.mkdir(parents=True, exist_ok=True)
    for rep in range(1, a.repeat + 1):
        for name in a.faults.split(","):
            print(f"{clock():8.1f}  begin  {name} {rep}", flush=True)
            fault = FAULTS[name]
            case = run_case(
                name, rep, lambda c, f=fault: f(lab, c), lambda: recover(lab.probe, clock), clock
            )
            cases.append(case)
            a.out.write_text(json.dumps([asdict(c) for c in cases], indent=2) + "\n")
            print(
                f"{clock():8.1f}  {'passed' if case.passed else 'FAILED'}  {name} {rep}", flush=True
            )
            if not case.passed:
                print(summary(cases))
                raise SystemExit("stop: fix the system before injecting another fault")
    print(summary(cases))


if __name__ == "__main__":
    main()
~~~

<!-- run: cd serve && uv run ruff format --check . && uv run ruff check . && uv run python -m serve.gameday --help -->

How each drill works:

- **`model_exit` and `redis_unavailable`** kill or stop a container, send one request, check that it fails with the expected status, then restart the container. `expect` checks the exact error: a 500 where you designed a 503 means the failure took a path you didn't plan for.
- **`overload`** uses a `Barrier` to hold 18 threads until all of them are ready, so the requests arrive at the same instant. With one slot and a queue of eight, nine should be admitted and nine refused.
- **`client_disconnect`** writes the HTTP request by hand on a raw socket and waits for the first streamed event. Then it closes the socket with `SO_LINGER` set to zero. That sends a TCP reset, like a phone losing signal, instead of a polite goodbye. Finally it polls the model server's `/slots` until no slot is busy. The Go context being cancelled isn't enough: as lesson 04 showed, the model server itself has to stop generating.
- **`scraper_loss`** checks that Prometheus really is down, then expects a request to *succeed*.
- **`model_oom`** lowers the memory limit below what the model needs, waits until Docker reports the container stopped with `OOMKilled`, checks for the 502, and puts the 2 GiB limit back *before* restarting. The order matters, as the second Break it shows.
- **`main`** saves the JSON after every drill, so a drill that hangs still leaves the earlier records. It also stops at the first failure.

## Run it

The drills need the live stack from lessons 04 and 05:

| Service | Address | Notes |
|---|---|---|
| Model, `blueprint-serve-llm` | 127.0.0.1:18080 | As in lesson 08, plus a 2 GiB memory limit |
| Redis, `blueprint-serve-redis` | 127.0.0.1:16379 | Holds the shared token budget |
| Switchyard's API with the inference route | 127.0.0.1:18081 | From lesson 05, with `INFERENCE_UPSTREAM=http://127.0.0.1:18080`, `INFERENCE_REDIS_ADDR=127.0.0.1:16379`, `INFERENCE_SLOTS=1`, `INFERENCE_QUEUE=8` and authentication required |
| Prometheus, `blueprint-serve-prometheus` | 127.0.0.1:19090 | Scrapes the API every 2 seconds |

Prometheus needs a small config file:

<!-- file: experiments/gameday/prometheus.yaml -->
~~~yaml
global:
  scrape_interval: 2s
scrape_configs:
  - job_name: switchyard-api
    static_configs:
      - targets: ['127.0.0.1:18081']
~~~

Start the three containers. If lesson 08's model container is still there, remove it first (`docker rm -f blueprint-serve-llm`): it has no memory limit, and the out-of-memory drill restores 2 GiB.

~~~bash
# From the lab root; SERVE_MODELS is the verified model directory from lesson 08.
docker run -d --name blueprint-serve-llm -p 127.0.0.1:18080:8080 \
  --memory 2g --memory-swap 2g -v "$SERVE_MODELS:/models:ro" \
  ghcr.io/ggml-org/llama.cpp@sha256:e67d88af487390098c76d7982b1761484339fa147b7e41d3c64ae1318759f78b \
  -m /models/qwen2.5-0.5b-instruct-q4_k_m.gguf -c 4096 -t 4 \
  --parallel 1 --metrics --host 0.0.0.0 --port 8080
docker run -d --name blueprint-serve-redis -p 127.0.0.1:16379:6379 redis:8
docker run -d --name blueprint-serve-prometheus --network host \
  -v "$PWD/experiments/gameday/prometheus.yaml:/etc/prometheus/prometheus.yml:ro" \
  prom/prometheus:v3.15.0 \
  --config.file=/etc/prometheus/prometheus.yml --web.listen-address=127.0.0.1:19090
~~~

Start the API as in lesson 05. Put a token for a client with the `generator` role in `SWITCHYARD_TOKEN`; it's a secret, so never commit it or paste it into notes. Check that one stream works, then run the game day:

~~~bash
cd serve
uv run python -m serve.stream http://127.0.0.1:18081
uv run python -m serve.gameday
~~~

It takes about two minutes. Each drill prints a `begin` and a `passed` line, then you get a summary:

~~~text
fault              rep  detect s  recover s  result
model-exit           1      0.56        5.9  passed
redis-unavailable    1      1.05        5.3  passed
overload             1      0.03       33.0  passed
client-disconnect    1         -        3.2  passed
scraper-loss         1      0.27        3.8  passed
model-oom            1      0.62        4.7  passed
model-exit           2      0.43        4.5  passed
redis-unavailable    2      1.09        5.2  passed
overload             2      0.02       32.8  passed
client-disconnect    2         -        3.2  passed
scraper-loss         2      0.22        3.6  passed
model-oom            2      0.57        4.6  passed
~~~

Your times will differ. Here's what mine say:

- **Detection is fast because the drill is watching.** A dead model shows up in about half a second, because the drill sends a request straight after `docker kill`. In real life nobody sends that request on cue: you find out from lesson 05's alerts, which take minutes. The detect column measures the system's error path, not your monitoring.
- **The Redis 503 takes half a second.** That's the 500 ms Redis timeout from lesson 04's `SharedReservation`. Failing closed is right, but while Redis is down, every request waits that long before it's refused.
- **Most of the recovery time is the check itself.** Restarting the model until `/health` is ok took 1.5–2 s. The ten checks took another 3–4 s, about 0.3 s each.
- **The cancelled request freed the model's slot 0.11 s after the reset,** in both runs.
- **Docker reported `OOMKilled: true`** both times, so the memory drill really did run the model out of memory.
- **Overload took 33 s to recover, and the details show a real problem.** Nine requests were refused within 30 ms: good. The nine admitted requests are served one at a time, and a long answer takes about 4 s, so their first content arrived at 0.3, 5.1, 9.7, 14.1, 17.6, 20.9 and 24.6 s. The last two in the first run never finished: they hit the 30-second deadline, one as a 504 and one cut off mid-answer. In the second run, all nine finished, the last one just under the deadline. Over six overload runs with this setting, at least one admitted request failed in five of them.

An admitted request that then times out is the worst outcome: it used model time, and the user still got nothing. The queue is longer than the deadline can drain. One slot can serve about 30 s ÷ 4 s ≈ 7 long requests before the deadline, but one running plus eight waiting is nine.

**Your turn:** restart the API with `INFERENCE_QUEUE=5` and run only the overload drill:

~~~bash
uv run python -m serve.gameday --faults overload
~~~

~~~text
fault              rep  detect s  recover s  result
overload             1      0.03       25.5  passed
overload             2      0.02       25.3  passed
~~~

All six admitted requests finished in both runs (the slowest complete answer took 22.7 s), twelve were refused at once, and recovery took 25 s instead of 33. The model completed the same number of answers (six or seven either way), because it isn't any faster. The shorter queue only refused, straight away, requests that would otherwise have waited and failed. The right length depends on how long the answers are and on the hardware, so work it out again whenever either one changes. Keep the queue at 5 for the rest of this phase, and write the reason in the runbook.

**Break it:** in `model_oom`, delete the `docker update` line that puts back the 2 GiB limit. Run only that drill:

~~~bash
uv run python -m serve.gameday --faults model-oom --repeat 1
~~~

~~~text
     0.0  begin  model-oom 1
    61.3  FAILED  model-oom 1
stop: fix the system before injecting another fault
fault              rep  detect s  recover s  result
model-oom            1      0.80          -  FAILED TimeoutError: model not ready
~~~

The restarted model was killed again while it loaded its weights, and the drill gave up after 60 s. Restarting a process doesn't fix anything while the cause is still there. Roll back the whole release, meaning the image, the weights and their resource limits, not just the process. Fix it by hand, the way the runbook says:

~~~bash
docker update --memory 2g --memory-swap 2g blueprint-serve-llm
docker start blueprint-serve-llm
~~~

Then put the line back.

## The runbook

Write the runbook before the first drill, and correct it after every drill that surprised you. Mine, in order:

1. Identify the running release: image, model and chat-template digests.
2. Stop any rollout that's in progress.
3. Look at queue depth, memory use and error rates. Don't look at prompts.
4. Shed excess work.
5. Restore the last tested **image + model + template** release, including its resource limits.
6. Verify the signatures (lesson 07) and wait for readiness.
7. Run the ten-request check, and compare the all-arrivals objective from lesson 05.
8. Record the detection and recovery times.

Two more rules. **Never automatically retry a partly delivered answer:** the user may already have seen part of it, and would get duplicate text. A failed optional prediction, like ML for infrastructure's, can fall back to a default; a generation endpoint can't pretend a partial answer is complete. And **size the queue from the deadline:** slots × deadline ÷ time per long answer is the most work you can promise to finish.

**Done when:** every fault has passed twice, `results/gameday.json` is kept, the queue is sized from your measured answer time, and the runbook matches what you actually did. My raw results for every run above are in [evidence/2026-11-13-game-day](../evidence/2026-11-13-game-day/). The [platform report](../evidence/platform-validation/report.md) keeps an earlier run of the same six faults, plus Kubernetes drills (rolling back corrupt weights) that this local stack doesn't cover.

**What this proves, and what it doesn't.** It proves that each failure returns the status you designed, that cancellation frees the model, that admission bounds the work, and that the stack recovers on one machine. It doesn't prove how fast your *alerts* detect a fault, how the system behaves when a whole node or the network fails, or anything about production. Two runs per fault is a small sample: the overload result changed between runs, which is exactly why you repeat them.
