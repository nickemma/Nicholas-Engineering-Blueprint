# 01 Capture admission and completion

> ML for infrastructure · Week 1

## The problem

A scheduler needs an estimate when a job arrives. Its actual runtime becomes known at completion. A dataset that mixes these times can make a model appear accurate by giving it the answer.

## The mental model

~~~text
admission: work units, queue depth, worker pool
    ↓
completion: finish time, measured service time, stable event ID
    ↓
versioned job event joins the two views
~~~

## The pattern

Define inference features from information available at admission. Keep service time as the target. A seed gives the lab repeatable synthetic service times with work-size, pool, and queue effects. The generated event export includes an identical redelivery, malformed data, a different schema version, and a late completion.

## Build it

Create the lab package.

<!-- file: ml_lab/__init__.py -->
~~~python
"""Switchyard job duration lab."""
~~~

### Validate the source event and inference feature record

Set explicit ranges, a version, and a stable three-value projection. Keep the target outside the feature object.

Create `ml_lab/contract.py`.

<!-- file: ml_lab/contract.py -->
~~~python
"""Versioned job events and the admission-time feature contract."""

import json
import re
from dataclasses import asdict, dataclass

SCHEMA_VERSION = "switchyard.job.completed.v1"
FEATURE_VERSION = "job-admission.v1"
FEATURE_NAMES = ("work_units", "queue_depth", "slow_pool")
POOLS = ("fast", "slow")
ID = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\Z")
DAY = 86_400_000
START = 1_767_225_600_000  # 2026-01-01T00:00:00Z


class ContractError(ValueError):
    """Use stable reason codes when reporting a bad row."""


def bounded(value: object, low: int, high: int, reason: str) -> int:
    if type(value) is not int or not low <= value <= high:
        raise ContractError(reason)
    return value


@dataclass(frozen=True)
class Features:
    work_units: int
    queue_depth: int
    pool: str

    @classmethod
    def parse(cls, source: object) -> "Features":
        if not isinstance(source, dict) or set(source) != {"work_units", "queue_depth", "pool"}:
            raise ContractError("feature_shape")
        pool = source["pool"]
        if pool not in POOLS:
            raise ContractError("pool")
        return cls(
            bounded(source["work_units"], 1, 2000, "work_units"),
            bounded(source["queue_depth"], 0, 256, "queue_depth"),
            pool,
        )

    def numeric(self) -> tuple[int, int, int]:
        return self.work_units, self.queue_depth, int(self.pool == "slow")


@dataclass(frozen=True)
class Event:
    event_id: str
    submitted_ms: int
    finished_ms: int
    work_units: int
    queue_depth: int
    pool: str
    runtime_ms: int

    def features(self) -> Features:
        return Features(self.work_units, self.queue_depth, self.pool)

    def row(self) -> dict:
        return asdict(self)


def decode(line: bytes) -> Event:
    if len(line) > 4096:
        raise ContractError("record_size")
    try:
        obj = json.loads(line)
    except (UnicodeDecodeError, ValueError, RecursionError) as exc:
        raise ContractError("invalid_json") from exc
    if not isinstance(obj, dict) or obj.get("schema") != SCHEMA_VERSION:
        raise ContractError("schema")
    ident = obj.get("event_id")
    if not isinstance(ident, str) or not ID.fullmatch(ident):
        raise ContractError("event_id")
    features = Features.parse({key: obj.get(key) for key in ("work_units", "queue_depth", "pool")})
    submitted = bounded(obj.get("submitted_ms"), 0, 4_102_444_800_000, "submitted_ms")
    finished = bounded(obj.get("finished_ms"), submitted + 1, submitted + 7 * DAY, "finished_ms")
    runtime = bounded(obj.get("runtime_ms"), 1, finished - submitted, "runtime_ms")
    return Event(ident, submitted, finished, features.work_units, features.queue_depth, features.pool, runtime)
~~~

### Produce a repeatable workload

Generate 20 days of jobs with timestamped admissions and completions. Shuffle ingestion order to separate it from event time.

Create `ml_lab/fixture.py`.

<!-- file: ml_lab/fixture.py -->
~~~python
"""Generate a finite job workload with known synthetic costs."""

import json
import random
from pathlib import Path

from .contract import DAY, SCHEMA_VERSION, START

CANARY = "PRIVATE_FIXTURE_CANARY"


def generate(destination: Path, seed: int = 1729) -> None:
    rng = random.Random(seed)
    rows = []
    for day in range(20):
        for n in range(64):
            work = rng.randint(10, 760)
            depth = rng.randint(0, 14)
            pool = rng.choice(("fast", "slow"))
            submitted = START + day * DAY + n * 120_000
            service = round(18 + 0.24 * work + 0.0008 * work**2 + 12 * depth
                            + 110 * int(pool == "slow") + rng.gauss(0, 9))
            runtime = max(1, service)
            rows.append({
                "schema": SCHEMA_VERSION, "event_id": f"evt-{day:02d}-{n:02d}",
                "submitted_ms": submitted, "finished_ms": submitted + depth * 50 + runtime,
                "work_units": work, "queue_depth": depth, "pool": pool,
                "runtime_ms": runtime, "source_note": CANARY,
            })
    # The late label exists in the source export but was unavailable at the
    # boundary used to freeze the training set.
    cut = START + 10 * DAY
    rows.append({**rows[0], "event_id": "evt-late", "submitted_ms": cut - 30,
                 "finished_ms": cut + 90, "runtime_ms": 120})
    rows += [rows[0], {**rows[1], "schema": "unknown-version"}]
    rng.shuffle(rows)  # Arrival/order of ingestion can differ from event time.
    with destination.open("x", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, separators=(",", ":")) + "\n")
        handle.write("{unparseable synthetic row\n")
~~~

## Check it

~~~bash
uv run --locked python -c "from pathlib import Path; from ml_lab.fixture import generate; generate(Path('jobs.jsonl'))"
wc -l jobs.jsonl
~~~

<!-- run: uv run --locked python -c "from pathlib import Path; from ml_lab.fixture import generate; generate(Path('jobs.jsonl'))" && test "$(wc -l < jobs.jsonl)" -eq 1284 -->

The export has 1,284 lines. Start with a fresh path to regenerate it. If a completion predates the time its features were captured, quarantine the record before it reaches the dataset.
