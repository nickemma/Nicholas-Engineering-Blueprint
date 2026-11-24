# Distributed KV capstone · Evidence

The reference ran on WSL2 Linux with Go 1.26.6, Rust 1.94.1, Java 21, and YCSB 0.17.0. Each trial used a fresh local three-peer group, 64 one-field records, two workers, a uniform key distribution, and 400 measured operations after load. Workload order was fixed and read-path order alternated. All 3,200 measured operations succeeded. [Workload definitions](https://github.com/brianfrankcooper/YCSB/wiki/Core-Workloads)

The recovery gate preserved the committed write with a lost reply, rebuilt a lagging peer’s Rust projection, preserved the tenant boundary through failover, and caught the deliberately early acknowledgment. The logical history had five observations.

| Workload | Singleton range throughput (ops/s) | Indexed point throughput (ops/s) | Range read p99 (ms) | Point read p99 (ms) |
|---|---:|---:|---:|---:|
| A | 42.7–43.0 | 41.1 | 101–112 | 109–123 |
| C | 32.3–52.6 | 51.4–52.2 | 74–250 | 75–97 |

Unprofiled Rust lookups took 4.93–5.14 s with the range path and 2.67–3.09 s with the indexed point path. The point path was about 1.75× as fast by the mean of the two timings for each mode. Both processed 75,000 lookups with 37,500 hits. The full-system matrix showed no consistent throughput gain across both workloads. The A trials sampled different proportions of reads and updates, which are in the raw results.

- [Gate transcript](gate.txt)
- [Client history](history.json)
- [Clean lesson replay](replay.txt)
- [Design decision record](ADR.md)
- [YCSB matrix](ycsb/matrix.json)
- Workload A raw results [range trial 1](ycsb/1-range-a.txt), [point trial 1](ycsb/1-point-a.txt), [range trial 2](ycsb/2-range-a.txt), [point trial 2](ycsb/2-point-a.txt)
- Workload C raw results [range trial 1](ycsb/1-range-c.txt), [point trial 1](ycsb/1-point-c.txt), [range trial 2](ycsb/2-range-c.txt), [point trial 2](ycsb/2-point-c.txt)
- [Range CPU flame graph](profile/flame-range.svg) and [indexed point CPU flame graph](profile/flame-point.svg)
- [CPU sample totals](profile/sample.jsonl) and [unprofiled lookup timings](profile/timing.jsonl)

The CPU profiles sample the lookup implementation on the fixed Rust fixture. YCSB includes Java and HTTP, inter-peer communication, disk synchronization, and application. The profiles and the benchmarks measure different work.
