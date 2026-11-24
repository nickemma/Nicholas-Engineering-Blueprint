# Core 06 evidence

The first eight lessons preserve the Performance Bridge lab and its earlier captures. The later runs use the Go and Rust wire built in this module.

| Capture | Observed result |
|---|---|
| [Page faults](lessons/09-memory.txt) · [Syscalls](lessons/09-strace-full.txt) | First touch of an 8 MiB file mapping incurred minor faults. The trace records `msync` and `fsync`. |
| [Readiness and BDP](lessons/10-ready.txt) · [TCP lab](lessons/10-tcp.txt) | Epoll made the socket readable, and the TCP capture showed SYN, SYN+ACK, and ACK. With the same rate limit, the clean run reported zero sender retransmits and the loss run reported 17. |
| [Rust short I/O](lessons/11-rust.txt) · [Go contract](lessons/12-go.txt) · [Socket smoke tests](lessons/12-smoke.txt) | Both transports accepted split frames, refused a corrupt header, checked HTTP bounds, and preserved trace ancestry. |
| [Trace tests](lessons/13-go.txt) · [Checksum benchmark](lessons/13-bench.txt) | The incoming trace ID appeared on both Go spans. The code change computes the same Castagnoli checksum, and the benchmark isolated its cost. |
| [Overloaded pilot](gate/pilot-overload.txt) · [Viable pilot](gate/pilot.txt) | At 650 requests/s the slow variant timed out and the load generator fell behind. At 95 requests/s both variants accepted the offered load. |
| [Full gate and p99 comparison](gate/extended.txt) · [Paired CSV and JSON files](profiles/paired-runs.tar.gz) | Five runs per build at 95 requests/s for four seconds. All 3,800 measured requests returned 200. |
| [Baseline profile](profiles/slow.pb.gz) · [Baseline top](profiles/slow.top.txt) · [Baseline flame graph](../images/wire-before.svg) | The bitwise CRC accounted for 790 ms of 860 ms of sampled CPU. |
| [Optimized profile](profiles/fast.pb.gz) · [Optimized top](profiles/fast.top.txt) · [Optimized flame graph](../images/wire-after.svg) | The profile contained 160 ms of CPU samples in the same sampling window. The top row was a syscall. |
| [Wrong-polynomial test](gate/wrong-polynomial.txt) | Using the IEEE checksum made the shared Rust fixture test fail. |
| [Clean replay](gate/replay.txt) | Rebuilds the module and its prerequisites, including the native wire gate. |

## Matched workload

The WSL2 lab ran a 64 KiB request over TCP to Rust. The Go process and a 4 ms work / 4 ms sleep competitor shared one CPU. The Rust container's egress had 1 ms delay and 0.05% configured loss. The qdisc recorded **8 actual drops** during the run. The competitor used **3,558 CPU ticks**. Profiles were collected in separate runs at the same offered load. The paired results below exclude warmups, profiles, and the overloaded pilot.

The capture used the cached `nettools:latest` image from the networking lab. A separate build of this module's tools Dockerfile verified that it provides `tc`, `iperf3`, `tcpdump`, and `ethtool`.

The `kload compare` result for **fast minus slow** was **−7.19 ms at p50** and **−15.81 ms at p99**. The p99 95% interval was **[−17.97, −13.97] ms**. The [complete comparison](profiles/comparison.txt) lists each run's p50 and p99. The baseline and optimized flame graphs have separate horizontal scales. Their absolute CPU totals are in the top tables.
