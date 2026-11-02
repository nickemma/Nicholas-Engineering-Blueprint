# Design: an event pipeline from services to a warehouse

**Track:** data-infrastructure · **Built in:** [Phase 3](../../lessons/03-durable-auditable-data/README.md) (outbox, Kafka), [Phase 7, step 3](../../lessons/07-utility-evaluation/TEACHING.md#step-3-a-data-contract-and-an-event-pipeline) (a data contract, Kafka to Parquet, late events) · **Time:** 45 minutes

This is a worked reference. Do the design yourself first, with a timer, then read this and note what you missed.

## 0. The crux

**Correctness end to end.** Every business event must reach the warehouse:
- **once**: not lost, not duplicated;
- **in a shape analysts can rely on**: even as producers change their schemas;
- **in the right time partition**: even when events arrive late.

The difficulty is in the seams: the database-to-broker gap, the broker-to-files gap, and producers changing schemas without telling anyone.

## 1. Requirements

**Functional**

1. Services publish domain events (an order placed, a job finished).
2. Events land in a warehouse, as tables partitioned by event time, queryable with SQL.
3. Backfills: replay a time range after a bug.
4. Analysts can trust the columns: types, meanings and versions.

**Non-functional**

| Property | Target |
|---|---|
| Volume | 20,000 events a second on average, 50,000 at peak; ~1 KB each as JSON |
| Freshness | Queryable within 15 minutes |
| Correctness | No loss; no duplicates in the warehouse |
| Retention | 2 years in the warehouse; 7 days in the broker |
| Late events | Accept events up to 3 days late into the right partition |

## 2. Estimates

- **Per day:** 20,000 × 86,400 ≈ 1.7 × 10⁹ events × 1 KB ≈ 1.7 TB of JSON.
- **In columnar Parquet:** compression is typically 5–10× on event data, so ~200–350 GB a day; ~150–250 TB over two years.
- **The broker:** 50 MB/s at peak; 7 days at the average 20 MB/s ≈ 12 TB, × 3 replicas ≈ 36 TB of Kafka storage. That's partitions spread over ~6–10 brokers.
- **Files:** writing every few minutes per partition makes many small files. **Compaction is required**, or queries spend their time opening files (Phase 7 measured 742 files → 31: ~12% faster and smaller).

**What this decides:**
- **Object storage plus Parquet**, not a row database, for the warehouse.
- **Kafka** in the middle, sized by retention, not throughput.

## 3. API

- Producers: write the event in the **same database transaction** as the business change, to an outbox table.
- Contracts: a schema per event type and version, in a registry, checked in CI.
- Consumers: SQL over the warehouse tables.

## 4. Core entities

- **Event:** `id` (unique), `type`, `version`, `occurred_at` (event time), `producer`, `payload`.
- **Contract:** the type, version, schema and compatibility rules.
- **Partition:** a table, an event date and an hour, holding files.

## 5. High-level design

~~~mermaid
flowchart LR
    SVC[Service] -->|same transaction| OB[(Outbox table)]
    OB --> RELAY[Relay] --> K[Kafka: topic per domain]
    REG[(Schema registry)] -.validate.-> RELAY
    K --> SINK[Sink: batch, write Parquet, then commit offsets]
    SINK --> OS[(Object storage: Parquet, by event date)]
    COMP[Compactor + deduplicator] --> OS
    OS --> WH[Query engine: DuckDB / Trino / warehouse]
    K -->|invalid events| DLQ[Dead-letter topic]
~~~

## 6. Deep dives

### 6.1 No loss, no duplicates (the crux, part 1)

Each seam, and what makes it safe:

1. **Service → broker.** "Write to the database, then publish" loses the event if the process dies between the two. The **transactional outbox** writes the event in the same transaction as the change; a relay publishes it afterwards. That's at-least-once: the relay can publish twice if it dies after publishing and before marking the event sent.
2. **Broker → files.** The sink:
   1. collects a batch;
   2. writes a Parquet file to a temporary name;
   3. renames it atomically into place;
   4. **only then** commits its Kafka offsets.

   A crash before the commit means the batch is read again and written again. Still at-least-once, never lost.
3. **Duplicates are removed by event ID**, which is assigned once, at the source.
   - The compactor deduplicates within a partition as it merges files.
   - Queries over fresh, uncompacted data use `DISTINCT ON (id)`, or the engine's merge-on-read.

**Exactly-once in the warehouse = at-least-once delivery + deduplication by a stable ID.** Say that sentence in the interview.

### 6.2 Contracts and schema evolution (the crux, part 2)

- **Every event has a type and a version**, and a schema in a registry.
- **Compatibility rules:**
  - adding an optional field is allowed;
  - removing a field, or changing a type, needs a **new version** with both published for a while;
  - CI fails a producer's build that breaks its contract.
- **Invalid events go to a dead-letter topic,** with an alert, and never silently into the warehouse.
- **Tables merge columns across versions by name.** A new optional field appears as a column that's null for older events.

### 6.3 Late events and partitions

- **Partition by event time** (`occurred_at`), because that's how analysts query: "orders on Tuesday". Not by arrival time.
- **A late event** goes into its old partition as a new file. The compactor later folds it in.
- **A watermark per partition** records when it's considered complete. "Tuesday is final 3 days later." Dashboards show a freshness marker, so nobody reports half a day as a whole.
- **Backfill** replays a time range from Kafka (if still within retention), or from the source's outbox history. Deduplication makes reruns safe.

## 7. Trade-offs

| Decision | Chose | Instead of | Because | Revisit when |
|---|---|---|---|---|
| Capture | Transactional outbox | Change data capture from the database log | Explicit domain events with contracts | Many legacy services can't be changed (then CDC) |
| Delivery | At-least-once + dedupe | Kafka transactions end to end | Simpler, and the sink writes files, not Kafka | — |
| Storage | Parquet on object storage | A row database | 200 TB, scans and aggregates | — |
| Partitioning | Event time | Arrival time | Matches the questions asked; late data handled explicitly | — |

## 8. Failure modes

| Failure | Effect | Detection | Mitigation |
|---|---|---|---|
| Kafka down | Outbox rows pile up; services unaffected | Outbox backlog | The outbox is the buffer; alert on its age |
| Sink crashes mid-batch | Batch re-read and rewritten | Duplicates found in compaction | Deduplication by ID |
| A breaking schema change | Events rejected | Dead-letter rate | CI contract checks; versions |
| Small files | Queries slow | Files per partition | Compaction |
| A bug wrote wrong data for a day | Bad analytics | Data-quality checks | Backfill the range; idempotent rewrite |
| A producer's clock is wrong | Events in the wrong partition | Lateness distribution | Use the server's time at the source; flag outliers |

## 9. With more time

- Data-quality checks (row counts, null rates) as contracts too.
- Lineage.
- Personal data: field-level tagging, deletion on request.
- A streaming path for sub-minute freshness.

## 10. Where you've built this

- [Phase 3](../../lessons/03-durable-auditable-data/README.md): the transactional outbox, and Kafka.
- [Phase 7, step 3](../../lessons/07-utility-evaluation/TEACHING.md#step-3-a-data-contract-and-an-event-pipeline):
  - a versioned data contract;
  - Kafka to Parquet with hourly partitions;
  - offsets committed after the atomic write;
  - deduplication, late events and a rebuild, queried with DuckDB.
- [Phase 7, step 4](../../lessons/07-utility-evaluation/TEACHING.md#step-4-big-data-honestly): compaction measured.

## 11. What an interviewer will push on

- "Where exactly can an event be lost? Where can it be duplicated?"
- "A producer renames a field. What happens?"
- "An event from three days ago arrives. Where does it go, and what do yesterday's dashboards show?"
- "Why not exactly-once Kafka transactions?"
