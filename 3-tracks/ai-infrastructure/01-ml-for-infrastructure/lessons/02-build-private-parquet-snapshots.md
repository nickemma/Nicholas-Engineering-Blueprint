# 02 Build private Parquet snapshots

> ML for infrastructure · Week 1

## The problem

Delivery can repeat and malformed rows can contain private data. Separate validation and curated output so retries and quarantine do not silently alter training.

## The mental model

~~~text
local event export → validate → project allowed columns → deduplicate by event ID
                  ↘ line number and reason only
          → date shards + manifest → publish snapshot
~~~

## The pattern

Write columnar Parquet shards by admission date. Keep one normalized copy per event. If copies disagree, refuse the snapshot and resolve the source conflict first. Quarantine records contain only a line number and a bounded reason code. Fingerprint the shards with SHA-256 and publish a manifest with the completed snapshot. [PyArrow Parquet writer](https://arrow.apache.org/docs/python/generated/pyarrow.parquet.write_table.html)

## Build it

### Materialize and read the dataset

Use a fixed Arrow schema and hash every published shard. Build in a scratch directory before publishing. The reader rechecks each shard and performs the time split used in the next lesson.

Create `ml_lab/dataset.py`.

<!-- file: ml_lab/dataset.py -->
~~~python
"""Project an event export to immutable, checksummed Parquet shards."""

import hashlib
import json
import re
import tempfile
from collections import defaultdict
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

from .contract import DAY, FEATURE_VERSION, START, ContractError, Event, decode

SHARD = re.compile(r"submitted-\d{4}-\d{2}-\d{2}\.parquet\Z")
SCHEMA = pa.schema([
    ("event_id", pa.string()), ("submitted_ms", pa.int64()), ("finished_ms", pa.int64()),
    ("work_units", pa.int32()), ("queue_depth", pa.int16()), ("pool", pa.string()),
    ("runtime_ms", pa.int32()),
])
TRAIN_END = START + 10 * DAY
VALID_END = START + 14 * DAY
TEST_END = START + 20 * DAY


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode() + b"\n"


def ingest(source: Path, destination: Path) -> dict:
    if not source.is_file() or source.stat().st_size > 4 * 1024 * 1024:
        raise ValueError("source must be a local file up to 4 MiB")
    if destination.exists():
        raise FileExistsError(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    seen: dict[str, Event] = {}
    rejected = []
    duplicates = 0
    with source.open("rb") as handle:
        for index, line in enumerate(handle, start=1):
            try:
                event = decode(line)
            except ContractError as exc:
                rejected.append({"line": index, "reason": str(exc)})
                continue
            prior = seen.get(event.event_id)
            if prior is not None:
                if prior != event:
                    raise ValueError("conflicting copies of an event ID")
                duplicates += 1
                continue
            seen[event.event_id] = event

    by_day = defaultdict(list)
    for event in sorted(seen.values(), key=lambda row: (row.submitted_ms, row.event_id)):
        day = datetime.fromtimestamp(event.submitted_ms / 1000, tz=UTC).date().isoformat()
        by_day[day].append(event.row())

    with tempfile.TemporaryDirectory(dir=destination.parent) as tmp:
        stage = Path(tmp) / "snapshot"
        stage.mkdir()
        shards = {}
        for day, rows in sorted(by_day.items()):
            file = stage / f"submitted-{day}.parquet"
            pq.write_table(pa.Table.from_pylist(rows, schema=SCHEMA), file, compression="zstd")
            shards[file.name] = digest(file.read_bytes())
        (stage / "quarantine.jsonl").write_bytes(b"".join(canonical(item) for item in rejected))
        manifest = {"feature_version": FEATURE_VERSION, "shards": shards, "rows": len(seen),
                    "duplicates": duplicates, "rejected": len(rejected)}
        (stage / "manifest.json").write_bytes(canonical(manifest))
        stage.rename(destination)
    return manifest


@dataclass(frozen=True)
class Split:
    train: list[Event]
    valid: list[Event]
    test: list[Event]
    late: int
    dataset_id: str


def load_split(directory: Path) -> Split:
    manifest_bytes = (directory / "manifest.json").read_bytes()
    manifest = json.loads(manifest_bytes)
    if manifest["feature_version"] != FEATURE_VERSION:
        raise ValueError("unexpected feature version")
    train, valid, test = [], [], []
    late = 0
    for name, checksum in sorted(manifest["shards"].items()):
        if not SHARD.fullmatch(name):
            raise ValueError("invalid shard name")
        contents = (directory / name).read_bytes()
        if digest(contents) != checksum:
            raise ValueError("Parquet shard digest mismatch")
        table = pq.read_table(pa.BufferReader(contents))
        if table.schema != SCHEMA:
            raise ValueError("Parquet schema mismatch")
        for row in table.to_pylist():
            event = Event(**row)
            start = event.submitted_ms
            if START <= start < TRAIN_END and event.finished_ms < TRAIN_END:
                train.append(event)
            elif TRAIN_END <= start < VALID_END and event.finished_ms < VALID_END:
                valid.append(event)
            elif VALID_END <= start < TEST_END and event.finished_ms < TEST_END:
                test.append(event)
            else:
                late += 1
    if not (train and valid and test) or len(train) + len(valid) + len(test) + late != manifest["rows"]:
        raise ValueError("missing split or inconsistent manifest")
    return Split(train, valid, test, late, digest(manifest_bytes))
~~~

## Check it

~~~bash
uv run --locked python -c "from pathlib import Path; from ml_lab.dataset import ingest; m=ingest(Path('jobs.jsonl'), Path('dataset')); print(m['rows'], m['duplicates'], m['rejected'])"
~~~

<!-- run: uv run --locked python -c "from pathlib import Path; from ml_lab.dataset import ingest; m=ingest(Path('jobs.jsonl'), Path('dataset')); assert (m['rows'], m['duplicates'], m['rejected']) == (1281, 1, 2)" -->

Expect `1281 1 2`. Inspect the Arrow schema and quarantine keys when checking privacy. Real event identifiers can still be sensitive, so treat data inventories, access, and retention as separate decisions before using operational records. The fixture IDs are generated. This lab replays a finite export from disk. The [Event streams unit](../../../shared-units/event-streams/README.md) covers Kafka offsets and consumer recovery.
