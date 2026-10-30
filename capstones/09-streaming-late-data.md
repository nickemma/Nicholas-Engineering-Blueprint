# 9. Late data in stream processing: when is a window complete?

**Field:** big data · distributed systems · **Difficulty:** high · **Language:** Go (Python for analysis)

## Problem

Stream processors compute results over windows of **event time**: fraud attempts per card per minute, rides per zone per five minutes, errors per service per second. But events arrive late:

- phones go offline;
- producers retry;
- networks delay.

Runway's own event stream in Phase 7 had events up to 76 seconds late.

A **watermark** is the processor's guess that no more events older than time *t* will arrive, so the windows before *t* can be emitted. Too eager, and results miss events: they must be dropped or corrected later. Too cautious, and every result arrives late. Most deployments set a fixed delay by hand and hope.

## Who

Data platform teams behind fraud detection, monitoring, billing and logistics dashboards; anyone whose "real-time" numbers are quietly incomplete.

## Gap

- The Dataflow model (Akidau et al., VLDB 2015) and MillWheel (Akidau et al., VLDB 2013) defined watermarks, triggers and accumulation.
- Begoli et al. (VLDB 2021) compared watermark semantics in Apache Flink and Google Cloud Dataflow.
- Flink's standard strategy uses a fixed bound on out-of-orderness. Adaptive strategies that learn lateness from the stream have been proposed.
- How these strategies trade result latency against completeness and the cost of corrections is rarely measured reproducibly. The test conditions that matter are:
  - real, heavy-tailed lateness;
  - skewed partitions;
  - sources that go idle.

## Research question

> On event streams with heavy-tailed, per-source lateness and idle partitions, how do fixed-delay, per-partition quantile and adaptive watermarks trade result latency against completeness and correction cost, compared with an oracle that knows every event's arrival in advance?

## Hypothesis and baseline

- **Baselines:**
  - fixed-delay watermarks at several bounds;
  - processing-time windows (fast and wrong: the lower bound);
  - an oracle (the ceiling).
- **Hypothesis:**
  - Per-partition quantile watermarks beat any single fixed bound when sources differ.
  - A global watermark taken as the minimum across partitions is held back by the slowest or idle partition, unless idleness is detected.
  - Allowing corrections is cheaper than waiting, when consumers can accept updates.

## System

- **Kafka** (Phases 3 and 7) with partitioned sources.
- **A small stream processor in Go:**
  - event-time windows: tumbling, sliding, session;
  - per-partition watermarks combined across partitions, with idleness detection;
  - allowed lateness, with updates and retractions sent downstream;
  - state in [Pebble](https://github.com/cockroachdb/pebble) (an LSM store in Go), checkpointed atomically with Kafka offsets for exactly-once results (the same discipline as Phase 7's pipeline).
- **Sinks:**
  - Parquet and DuckDB for analysis (Phase 7);
  - a key-value sink with idempotent upserts for corrections.
- **A sanity baseline:** the same windows in Apache Flink, to check that the results agree on a simple stream.
- **A workload replayer:**
  - public event data, such as the [NYC TLC trip records](https://www.nyc.gov/site/tlc/about/tlc-trip-record-data.page) with their pickup times;
  - lateness drawn from measured distributions (Phase 7's Runway stream, or published mobile traces);
  - idle partitions, source outages and skew added on a schedule.

## Suggested stack

| Part | Choice | Why |
|---|---|---|
| Stream processor | Go | Concurrency per partition, explicit state, Runway's Kafka client |
| Log | Kafka | Partitions, offsets, replay |
| State | Pebble | Embedded LSM storage with snapshots |
| Comparison | Apache Flink | The common production engine as a reference |
| Analysis | Python, DuckDB, Parquet (Phase 7) | Completeness needs the full truth table |
| Hot paths | Rust only if profiling shows windowing or serialisation is the bottleneck | Measure first |

## Features to implement

1. Event-time windows: tumbling, sliding and session.
2. Pluggable watermark strategies: fixed delay, per-partition quantile, adaptive.
3. Idle-partition detection, so one quiet source doesn't stall every window.
4. Allowed lateness, with updates and retractions.
5. Exactly-once results across crashes: state and offsets committed together.
6. Replay and backfill from any offset.
7. Metrics: watermark lag per partition, late events, corrections, state size.

## Experiment

| Variable | Values |
|---|---|
| Strategy | Processing time; fixed delay (1 s, 10 s, 60 s); per-partition quantile (p99, p99.9); adaptive; oracle |
| Lateness | Measured distributions; synthetic heavy-tailed (log-normal, Pareto) with documented parameters |
| Partitions | 4, 16, 64, with skew and idle partitions |
| Window | Tumbling 1 min and 5 min; sliding; session |
| Failures | A processor crash mid-window; a Kafka broker restart |

## Measures

- **Result latency:** window end to first emission, p50 and p99.
- **Completeness at first emission:** the share of the window's events included.
- Corrections: how often, how large, and how late.
- Dropped events.
- State size.
- Throughput in events per second per core.
- Recovery time after a crash, and exactly-once verified: no duplicates, no losses.

## Benchmark your work

- **Throughput versus latency:** raise the event rate until result latency p99 breaks its objective; report the knee per strategy.
- **COST (Phase 7):** compare against a single-threaded implementation before claiming the parallel one scales.
- **Tails during failures:** result latency and completeness in the windows around a crash, and the time to catch up.
- **Bottlenecks:** CPU, state-store I/O or Kafka fetches. Profile at the knee and say which one limits.
- **Rigour:** at least 5 replays per condition with different seeds, intervals, and the dataset version and lateness parameters recorded.

## What you might find

No single fixed delay may be right for every partition. Idle partitions may matter more than heavy tails. The adaptive strategy may win on average and lose badly during sudden changes, which says when not to use it.

## Limitations to expect

- Replayed lateness is a model of real devices.
- One machine, so network effects between processors are small.
- Exactly-once holds only for the sinks you made idempotent or transactional.

## Skills used

Phases 2 (event-driven design), 3 (Kafka, write-ahead logs), 4 (failure models), 5 (observability, SLOs) and 7 (data contracts, Parquet, DuckDB, late events, COST, experimental method).

## Read first

- Akidau et al., *The Dataflow Model*, VLDB 2015
- Akidau et al., *MillWheel: Fault-Tolerant Stream Processing at Internet Scale*, VLDB 2013
- Begoli et al., *Watermarks in Stream Processing Systems: Semantics and Comparative Analysis of Apache Flink and Google Cloud Dataflow*, VLDB 2021
- Carbone et al., *Apache Flink: Stream and Batch Processing in a Single Engine*, IEEE Data Engineering Bulletin, 2015
- Kleppmann, *Designing Data-Intensive Applications*, chapter 11 (stream processing)
