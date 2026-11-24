# 03 A Rust storage engine

> Storage engines track · Time 4 weeks at 12–15 hours a week · Status ready

## What you'll build

Build a single-node Rust key-value engine for the Storage engines capstone. Start with a write-ahead log (WAL) and an ordered in-memory table. Flush immutable sorted tables (SSTables), use an index and Bloom filter to narrow point lookups, then merge runs without changing what a pinned snapshot can read. Expose byte-key puts, deletes, point reads, and ordered range scans through a Rust library and a small local CLI.

Reuse Core 04’s Rust `klog` record framing and recovery work. The version-resolution exercise from Postgres in depth becomes an on-disk implementation. Part 02 supplies the replication context for the capstone. This module is new material in batch 13. [Rust foundations](../../../2-core/04-rust-foundations/README.md) · [B-tree and LSM read paths](../01-postgres-in-depth/lessons/03-compare-btree-and-lsm-paths.md) · [Consensus in depth](../02-consensus-in-depth/README.md)

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [Define the byte-key store](lessons/01-define-the-byte-key-store.md) | Distinguish empty values, missing keys, and deletes. Assign sequence numbers and use half-open scan bounds. |
| 1 | 02 | [Make acknowledged writes recoverable](lessons/02-replay-the-write-ahead-log.md) | Sync framed WAL records before acknowledging. Repair a torn tail and refuse a complete corrupt frame. |
| 2 | 03 | [Flush and publish an SSTable](lessons/03-publish-an-sstable.md) | Write sorted blocks and an index. Publish the run and rotate the WAL through one manifest replacement. |
| 2 | 04 | [Seek to a block and skip absent keys](lessons/04-measure-bloom-filter-lookups.md) | Use the index and Bloom filter for point reads. Count false positives and block probes with identical lookup inputs. |
| 3 | 05 | [Read a pinned snapshot across several runs](lessons/05-read-a-pinned-snapshot.md) | Merge ordered sources and resolve the newest visible version, including tombstones. |
| 3 | 06 | [Compact without losing a version](lessons/06-compact-with-pinned-readers.md) | Merge all published runs, preserve pinned views, and measure what becomes reclaimable when the pins are released. |
| 4 | 07 | [Restart during flush and compaction](lessons/07-restart-during-publication.md) | Stop and reopen a local engine around file sync, manifest publication, and cleanup. Check the selected files and the next sequence. |
| 4 | 08 | [Run the recovery and read-cost gate](lessons/08-run-the-storage-engine-gate.md) | Compare current and pinned reads with an independent ordered map, and verify the crash schedules and compaction control. |

## The gate

- Run a seeded workload containing overwrites, deletes, reinserts, empty values, and scans against an independent ordered reference model. Compare current and pinned reads across multiple flushes and compaction. Run a deliberately broken compaction that retains only the newest version and require a pinned-read mismatch.
- Stop the engine process before and after publishing a flushed or compacted table. Across reopen, require each acknowledged mutation and deletion to survive. Check that the replay watermark agrees with the manifest, and account separately for an in-flight mutation whose acknowledgment was never observed.
- Run identical present-key and absent-key workloads with Bloom filtering enabled and disabled. Require identical lookup results and a lower data-block probe count with filtering on the fixed absent-heavy fixture. Record false-positive counts and compaction input and output bytes.

The engine uses one process and one writer, with explicit flushes and compactions. Snapshots live within that process. A full compaction buffers the retained output and rewrites all published runs. The gate covers process interruption and counts logical block probes. The capstone adds replication and workload benchmarking. [Gate instructions](gate/README.md) · [Capstone plan](../05-capstone-distributed-kv-store/README.md)

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Trace a put from the WAL to an SSTable and explain when a Bloom filter can skip a block lookup. |
| Intermediate | Resolve a scan across overlapping runs and predict what each pinned snapshot sees through updates and deletes. |
| Senior | Defend the publication and recovery order at each crash boundary and use measurements to explain the read and write costs of compaction. |

## Practice

- Explore partial compaction and compare lookup work across different key layouts. [Exercises](exercises.md)
- Predict the recovery and visibility outcomes before checking the implementation. [Self-check](self-check.md)
- Inspect the measurements and crash outcomes from the reference run. [Evidence](evidence/README.md)

Continue to [Integrity and encryption](../04-integrity-and-encryption/README.md).
