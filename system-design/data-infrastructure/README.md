# Data infrastructure

For data infrastructure, data platform and ML infrastructure roles. These designs move, store and process data at scale: pipelines, streams, warehouses and change capture.

**Worked design:** [an event pipeline from services to a warehouse](event-pipeline.md). Do it yourself first, then compare.

**How to use the prompts:**
1. Set a 45-minute timer and design with the [template](../_template.md).
2. Open **the crux** only if you haven't named one by minute 10.
3. Open **what a strong answer covers** only after the timer, then score yourself with the [scorecard](../scorecard.md).

## 1. A stream processor for real-time metrics

Compute per-merchant payment totals and fraud signals in 1-minute and 1-hour windows from a stream of 100,000 events a second, with results within 10 seconds and correct despite late and duplicate events.

<details><summary>The crux</summary>Event time, not processing time: windows defined by when things happened, watermarks deciding when a window is complete, and state that survives crashes without double counting.</details>

<details><summary>What a strong answer covers</summary>

- Partitioning the stream by merchant; state per key.
- Windows, watermarks, allowed lateness and corrections.
- Exactly-once results: checkpoint state and input offsets together; idempotent or transactional sinks.
- State size and storage (an embedded LSM store), and rescaling.
- Back-pressure; hot keys (one giant merchant).
</details>

**Built in:** [Phase 7, step 3](../../lessons/07-utility-evaluation/TEACHING.md#step-3-a-data-contract-and-an-event-pipeline) (late events, deduplication), [capstone 9](../../capstones/09-streaming-late-data.md).

## 2. Change data capture

Stream every change from 50 PostgreSQL databases into Kafka and a search index, in order per row, within seconds, without slowing the databases or losing changes during failovers.

<details><summary>The crux</summary>Reading the database's own replication log (not polling tables), keeping per-row order, and resuming exactly where you left off, including across a database failover.</details>

<details><summary>What a strong answer covers</summary>

- Logical replication slots; decoding the WAL into change events.
- Initial snapshot plus streaming, stitched without gaps.
- Ordering per primary key (partition by key).
- Positions (LSNs) stored with offsets for resume; slots retaining WAL if the consumer stops (a disk-filling risk).
- Schema changes in the stream.
- Comparison with the transactional outbox.
</details>

**Built in:** [Phase 3](../../lessons/03-durable-auditable-data/README.md) (the WAL, the outbox, Kafka).

## 3. A data lake with compaction

Land 2 TB of events a day as Parquet in object storage, queryable by several engines, with updates and deletes (for privacy requests), and queries over a year in minutes.

<details><summary>The crux</summary>Object storage has no transactions and hates small files: a table format (snapshots and manifests, like Iceberg or Delta) gives atomic commits, deletes and time travel, and compaction keeps file counts sane.</details>

<details><summary>What a strong answer covers</summary>

- Partitioning by date and a second key; file sizes of hundreds of MB.
- A table format: atomic snapshots, schema evolution, deletes (copy-on-write or merge-on-read).
- Compaction and its scheduling; clustering for common filters.
- Deletion requests: find, rewrite, expire old snapshots.
- COST: does a single machine with DuckDB beat the cluster at this size?
</details>

**Built in:** [Phase 7, steps 3–4](../../lessons/07-utility-evaluation/TEACHING.md#step-4-big-data-honestly) (Parquet, compaction measured, MapReduce, Spark and COST).

## 4. A time-series database

Store 10 million metrics series at 15-second resolution for a year, with fast range queries and downsampling. (Compare with the [metrics system](../cloud-infra/metrics-alerting.md), which uses one.)

<details><summary>The crux</summary>Compression and layout: time-series data is append-mostly, ordered and highly compressible, so a specialised format (columnar blocks, delta encodings) beats general databases by an order of magnitude.</details>

<details><summary>What a strong answer covers</summary>

- A write path: WAL, in-memory head, immutable blocks.
- Compression: delta-of-delta timestamps, XOR floats.
- An inverted index from labels to series.
- Retention, downsampling, compaction of blocks.
- Cardinality limits.
</details>

**Built in:** [Phase 5, step 10](../../lessons/05-constrained-operations/TEACHING.md#step-10-prometheus-slos-and-burn-rate-alerts) (Prometheus).

## 5. Batch job orchestration

Run 5,000 daily data jobs with dependencies between them (a DAG), retries, backfills for past dates, and alerts when a critical table is late.

<details><summary>The crux</summary>Dependencies and time: each job runs for a logical date, after its inputs for that date are complete, and backfills must rerun ranges safely, which requires idempotent jobs that overwrite their output partitions.</details>

<details><summary>What a strong answer covers</summary>

- DAGs per logical date; a scheduler that starts jobs when their dependencies succeed.
- Idempotent jobs that write a whole partition atomically.
- Retries with backoff; failure states that stop downstream jobs.
- Backfills: ranges, concurrency limits, priority below daily runs.
- SLAs: "table X ready by 06:00", with alerts on lateness.
- Workers on a queue; resource pools per team.
</details>

**Built in:** [Phase 3, step 8](../../lessons/03-durable-auditable-data/TEACHING.md#step-8-background-jobs), [DSA guide 09](../../dsa/09-graphs/README.md) (topological sort).
