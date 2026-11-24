# 06 Linux, networking, and profiling

> The core · Time: 5 weeks at 12–15 hours a week · Builds on [02 Honest measurement](../02-python-runtime-and-honest-measurement/README.md), [03 Docker and Postgres](../03-docker-and-postgres/README.md), and [05 Rust for systems](../05-rust-for-systems/README.md) · Status: ready

## What you'll learn

Use the USE method to narrow down a slow service. Read Go CPU, heap, mutex, and block profiles, then use Linux tools to check what the process and network are doing. Measure virtual-memory faults, observe file synchronization, calculate bandwidth-delay product, and check actual drops on a shaped TCP link. Read a trace across the Go HTTP and wire client boundaries.

## What you'll build

First, diagnose five planted problems in the small Go service `hotspot`. Then add a framed probe to the real Switchyard control plane. Go sends a checked frame to the Rust data plane over TCP or a Unix socket, and Rust acknowledges the validated payload length. The Go caller bounds concurrent exchanges and forwards cancellation to the connection. The same wire contract is tested in both transports.

Start with [Before you start](lessons/00-before-you-start.md). There are **14 lessons** following setup.

For live debugging and post-mortem analysis, follow the [Delve build](deep-dives/debug-a-go-program.md) after the profiling lessons.

## Lessons

| # | Lesson | What you'll build or measure |
|---|---|---|
| 01 | [A slow service, and the USE method](lessons/01-a-slow-service-and-the-use-method.md) | A jobs service with planted bottlenecks, an open-loop load, and the saturation knee |
| 02 | [Waiting: mutex and block profiles](lessons/02-waiting-mutex-and-block-profiles.md) | Waiting attributed to a lock and its critical section |
| 03 | [Computing: CPU profiles and flame graphs](lessons/03-computing-cpu-profiles-and-flame-graphs.md) | Before and after CPU profiles for a computation hot path |
| 04 | [perf: the whole machine's view](lessons/04-perf-the-whole-machines-view.md) | Hardware counters, cache behavior, and symbolized samples |
| 05 | [strace: what is it asking the kernel?](lessons/05-strace-what-is-it-asking-the-kernel.md) | Syscall counts, batching, and the cost of observing a process |
| 06 | [The kernel's view, with eBPF](lessons/06-the-kernels-view-with-ebpf.md) | Counting and latency histograms from kernel events |
| 07 | [Memory and the garbage collector](lessons/07-memory-and-the-garbage-collector.md) | A heap profile, GC traces, and a bounded store |
| 08 | [The method, end to end](lessons/08-the-method-end-to-end.md) | An explanation supported by repeated measurements and profiles |
| 09 | [Process memory and the page cache](lessons/09-process-memory-and-the-page-cache.md) | File mappings, first-touch faults, and `msync` and `fsync` |
| 10 | [Watch TCP on a lossy link](lessons/10-watch-tcp-on-a-lossy-link.md) | A three-packet handshake, BDP, socket counters, egress loss, and readiness versus completion |
| 11 | [Serve framed bytes in Rust](lessons/11-serve-framed-bytes-in-rust.md) | A bounded Rust socket service using the Core 05 parser and short-I/O tests |
| 12 | [Connect Switchyard over TCP and Unix sockets](lessons/12-connect-switchyard-over-tcp-and-unix.md) | A deadline-bound Go pool and an opt-in HTTP probe in Switchyard |
| 13 | [Trace and profile the wire](lessons/13-trace-and-profile-the-wire.md) | OpenTelemetry span ancestry, a separate loopback profiler, two exact-compatible checksum builds |
| 14 | [Measure the fix under contention](lessons/14-measure-the-fix-under-contention.md) | Actual drops, a CPU competitor, flame graphs, and a matched p99 comparison |

## The gate

The [native gate](gate/README.md) builds both variants and exercises the real Go and Rust entry points over TCP and Unix sockets. It checks split frames, corrupted headers, request bounds, and trace ancestry. The extended gate adds packet loss and CPU contention, identifies the CPU bottleneck in the baseline, and checks the p99 change with `kload`.

## Checkpoint

| Level | Here, you can… |
|---|---|
| Junior | Read a TCP handshake, build the wire, and explain a Go profile |
| Intermediate | Assign a delay to a process, a queue, or a loss event using independent evidence |
| Senior | Design a matched experiment, justify a CPU fix from a profile, and defend the resulting latency claim |

- **[Exercises](exercises.md).** Investigate Switchyard or build a separate bounded frame relay.
- **[Self-check](self-check.md).** Explain each diagnosis and design a check from memory.
- **[Evidence](evidence/README.md).** Read the raw runs and their settings.

## Next

[07 Distributed systems fundamentals](../07-distributed-systems-fundamentals/README.md) builds coordination across processes that can disagree, stall, and restart.
