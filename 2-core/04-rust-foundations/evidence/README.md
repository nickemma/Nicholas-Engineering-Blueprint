# Core 04 evidence

These are local captures from the Rust drills and `klog` checks. The reference toolchain was Rust 1.94.1 on Linux.

| Evidence | Run |
|---|---|
| [Compiler rejects an incomplete match](lessons/01-error.txt) | Missing `None` |
| [Use after move](lessons/02-move.txt) · [Borrow conflict](lessons/02-alias.txt) | Two ownership diagnostics |
| [Parser](lessons/03-parse.txt) · [Summary](lessons/04-summary.txt) · [Dangling reference](lessons/05-dangling.txt) | Typed errors, generic collection output, and a rejected lifetime |
| [Frame](lessons/06-frame.txt) · [CLI](lessons/07-cli.txt) | Framing bytes and successful durable appends |
| [Torn suffix](lessons/08-recover.txt) · [Corrupt final frame](lessons/08-corrupt.txt) | A partial append was repaired. A complete record with a checksum mismatch was refused and left unchanged. |
| [Benchmark](lessons/09-benchmark.txt) | Over five trials per policy, median time for 250 records was 910.443 ms syncing each record and 41.646 ms syncing groups of 25. The capture includes the filesystem label and all ten timings. |
| [Gate pass](gate/pass.txt) · [Payload verification disabled](gate/checksum-disabled.txt) | The reference passed 18 cut positions, corruption refusal, locking, and SIGKILL recovery. The altered binary accepted a corrupt payload, which the gate flagged. |
| [Clean replay](gate/replay.txt) | All 56 lesson actions replayed from a fresh working directory, including the gate. |

The benchmark timed encoding, file writes, and file syncs. The benchmark filesystem and sync policy determine the observed latency. The process-crash drill kept the operating system running.
