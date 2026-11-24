# Latency and throughput numbers

Know the **order of magnitude** of each step on a request's path. Then you can see where the time goes before measuring, and you can tell when a design is impossible ("five cross-region round trips in a 100 ms budget").

These are rough, and hardware changes. **Measure your own**, as every phase of the Blueprint does.

## Latency

| Operation | Roughly | Scale |
|---|---|---|
| CPU cache (L1) hit | 1 ns | nanoseconds |
| Main memory access | 100 ns | |
| Uncontended mutex lock and unlock | 20 ns | |
| Hashing or copying 1 KB in memory | 0.1–1 µs | microseconds |
| Context switch between threads | 1–5 µs | |
| SSD random read (4 KB) | 20–100 µs | |
| Round trip within one data centre (same zone) | 0.2–0.5 ms | milliseconds |
| Round trip between zones in one region | 0.5–2 ms | |
| Disk (HDD) seek | 5–10 ms | |
| Round trip across a continent | 40–80 ms | |
| Round trip between continents | 100–200 ms | |
| A TLS handshake on a new connection | 1–2 round trips | |

The useful consequences:

- **Memory is ~1,000 times faster than SSD; SSD is ~100 times faster than a seek.** Caches exist because of these gaps.
- **One cross-region round trip costs more than thousands of local operations.** Design so a request crosses regions at most once, or never.
- **Connections are expensive to open.** Reuse them (connection pools, HTTP keep-alive, gRPC's long-lived connections).

## Throughput

| Resource | Roughly |
|---|---|
| Memory bandwidth, one core | 10–20 GB/s |
| NVMe SSD, sequential | 2–7 GB/s |
| SATA SSD, sequential | 0.5 GB/s |
| 1 Gbit/s network | 125 MB/s |
| 10 Gbit/s network | 1.25 GB/s |
| A simple HTTP API on one core | thousands of requests a second (measure yours) |
| A single PostgreSQL primary | thousands to tens of thousands of simple writes a second, depending on durability settings and disks |

## How it goes wrong

- **Averages hide the tail.** p99 is what users feel on a page that makes 100 calls (core 02).
- **Fan-out multiplies the tail.** A request that waits for 50 backends waits for the slowest. With each backend at a 1% chance of being slow, the request is slow 1 − 0.99⁵⁰ ≈ 40% of the time (Dean and Barroso, *The Tail at Scale*).
- **Queueing.** Near saturation, latency grows without bound long before throughput stops rising: Little's law and the knee you measured.

## In an interview

Build a **latency budget**: list the steps on the request path, give each a number from this page, and check the total against the requirement. *"200 ms p99, of which the cross-region hop takes 80, so the rest has 120."*

## Where you built it

- **The tail:** [core 02](../../2-core/02-python-runtime-and-honest-measurement/README.md) measured percentiles and coordinated omission.
- **Little's law:** [Core 01](../../2-core/01-go-runtime-and-reliable-services/lessons/13-worker-pools-and-backpressure.md) checks it against a live queue: the sampled queue length matches arrival rate times wait.
- **The cost of a hop:** a TLS sidecar's cost is usually the extra hops, not the encryption. Measure a plain relay beside it before you blame TLS; [The proxy's control plane](../../3-tracks/cloud-and-network/03-proxy-control-plane/README.md) builds the sidecar to try it on.
- **A whole request path:** [Core 06](../../2-core/06-linux-networking-and-profiling/README.md) breaks one request's time into its pieces, from the socket to the profile.
