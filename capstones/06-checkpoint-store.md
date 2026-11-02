# 6. A checkpoint store that doesn't stop training

**Field:** distributed systems · storage · AI infrastructure · **Difficulty:** very high · **Language:** Rust

## Problem

Long training runs fail: a GPU, a node or a link dies. So teams checkpoint the model and optimiser state regularly, and a failure costs minutes instead of days. But checkpoints are big. A 7-billion-parameter model trained with Adam carries about 14 bytes per parameter:

- bf16 weights;
- fp32 master weights;
- two fp32 optimiser moments.

That's around 100 GB per checkpoint. Writing one synchronously stalls every GPU in the job, while checkpointing rarely means losing more work at each failure.

The store must also be **correct**. The pointer to the latest checkpoint must never name a half-written one, even if the writer or a store node dies mid-write. A restore that loads a torn checkpoint is worse than no checkpoint at all.

## Who

ML platform teams running multi-node training. More broadly, anyone snapshotting large state on a schedule: databases, simulations, stream processors.

## Gap

- These systems make checkpointing cheaper:
  - CheckFreq (Mohan et al., FAST 2021) pipelines the snapshot and the write, and tunes the frequency;
  - Check-N-Run (Eisenman et al., NSDI 2022) shrinks checkpoints of recommendation models;
  - Gemini (Wang et al., SOSP 2023) keeps checkpoints in the CPU memory of peer machines for fast recovery;
  - PyTorch's distributed checkpointing can save asynchronously.
- They mostly write to a file system or object store that already exists. The **storage side** is less studied in a small, reproducible system: how metadata consensus, chunk placement and replication interact with training stalls and recovery time.

## Research question

> How much training stall does an asynchronous, chunked checkpoint store remove compared with synchronous writes to an object store, while guaranteeing that the committed "latest" checkpoint is always complete? How do the replication factor and the checkpoint interval trade stall time against recovery time after node failures?

## Hypothesis and baseline

- **Baselines:**
  - (a) a synchronous `torch.save`, then an upload to an S3-compatible store (MinIO);
  - (b) PyTorch's asynchronous distributed checkpoint to the same store.
- **Hypothesis:**
  - Staging state in host memory and uploading chunks in the background cuts the stall to the copy out of device memory.
  - Keeping consensus on small metadata, apart from the bulk data path, keeps commit latency flat while gigabytes move.
  - Two copies in peer memory recover faster than the object store, but lose the checkpoint when two nodes fail together.

## System

- **Store nodes (Rust):**
  - **Metadata through Raft:** checkpoint manifests, chunk locations and the "latest" pointer. Use the [openraft](https://github.com/databendlabs/openraft) crate, or port Phase 4's Raft.
  - **A commit protocol:** write all chunks, confirm they're durable, then commit the manifest. Only a committed manifest can become "latest".
  - **Chunk servers:** content-addressed chunks, so unchanged tensors are stored once across checkpoints, with a write-ahead log for the chunk index (Phase 3, Rust Bridge).
  - **A separate data path:** bulk transfers on their own connections and tasks (tokio), so a 20 GB upload never delays Raft's heartbeats. Readers fetch weights asynchronously, without going through the consensus state machine.
- **A Python client:**
  - copies the state into pinned host memory, returns control to training, and uploads in the background;
  - restores by fetching chunks in parallel.
- **A training job:** a small GPT-style model with PyTorch DDP on CPU, plus **synthetic state** of configurable size (1–20 GB) to emulate a large model on a laptop.
- **Checking:**
  - a property-based test that kills nodes at random points in the commit protocol and asserts that "latest" is always restorable;
  - a TLA+ model of the commit (Phase 4).

## Suggested stack

| Part | Choice | Why |
|---|---|---|
| Store nodes, chunk servers | Rust, tokio | Predictable memory and I/O under gigabytes of traffic; Rust Bridge experience |
| Consensus | openraft, or your own Raft | Metadata only |
| Client | Python (PyTorch hooks), with the transfer in Rust through PyO3 if Python copying is the bottleneck | Measure it first |
| Control and monitoring | Go CLI, if needed; Prometheus | Operators don't need Rust |
| Baseline store | MinIO (S3-compatible) | A fair, common baseline |
| Network shaping | `tc` (Phase 5) | 1 and 10 Gbit/s links, with contention |

## Features to implement

1. Content-addressed chunks with deduplication across checkpoints.
2. The two-step commit, with "latest" moving only after every chunk is durable.
3. Chunk replication, and repair after a node loss.
4. Garbage collection of old checkpoints that never deletes a chunk a committed manifest still needs.
5. Parallel, asynchronous restore.
6. Separate control and data paths, with metrics proving that bulk traffic doesn't delay consensus.
7. Failure handling: a chunk server killed mid-write, the Raft leader killed during a commit, a client dying before commit (orphaned chunks are cleaned up).

## Experiment

| Variable | Values |
|---|---|
| Method | Synchronous + upload; PyTorch asynchronous checkpoint; this store with replication 1, 2 and 3 |
| Checkpoint size | 1, 5, 20 GB |
| Interval | Every 1, 5, 15 minutes, and the Young/Daly optimum |
| Network | 1 and 10 Gbit/s, with and without competing traffic |
| Failures | A store node killed during upload; two nodes together; the Raft leader during a commit; a training node, then restore |

## Measures

- **Stall per checkpoint:** how long training is blocked.
- Total checkpoint time, and throughput in GB/s.
- Commit latency p99 while bulk transfers run, and Raft elections caused by load (there should be none).
- **Recovery time:** from failure to training resumed.
- Work lost per failure.
- Storage used, with and without deduplication.

## Benchmark your work

- **Throughput versus stall:** for each size and network, the stall and the total time, as a frontier across methods.
- **Optimal interval:** with checkpoint cost *C* and mean time between failures *M*, Young's approximation of the best interval is √(2CM). Compute the expected waste per method, then check it against a run with injected failures.
- **Tail latency during failures:** commit p99 and client upload p99 in 10-second windows around each node kill.
- **Rigour:** at least 5 runs per condition; drop the page cache between runs where it would flatter a result; record disks, kernel and file system.

## What you might find

The stall may fall to almost nothing, while recovery time becomes the real cost. Deduplication may save little in full fine-tuning and a lot when most layers are frozen. Bulk traffic may cause Raft elections until the data path is separated, which makes a good before-and-after.

## Limitations to expect

- Synthetic tensors don't train, so "work lost" is modelled from step time.
- A laptop's disk and loopback network aren't a data-centre fabric.
- Real GPU-to-host copies (PCIe, pinned memory) aren't measured without a GPU.

## Skills used

Rust Bridge (bytes, checksums, files), Phases 3 (write-ahead logs, durability), 4 (Raft, failure models, TLA+), 5 (network shaping), 7 (experimental method) and 8 (distributed training, host and device memory).

## Read first

- Mohan et al., *CheckFreq: Frequent, Fine-Grained DNN Checkpointing*, FAST 2021
- Eisenman et al., *Check-N-Run: A Checkpointing System for Training Deep Learning Recommendation Models*, NSDI 2022
- Wang et al., *Gemini: Fast Failure Recovery in Distributed Training with In-Memory Checkpoints*, SOSP 2023
- Young, *A First Order Approximation to the Optimum Checkpoint Interval*, Communications of the ACM, 1974
- Ongaro and Ousterhout, *In Search of an Understandable Consensus Algorithm (Extended Version)*
