# 7. Keeping gradient traffic moving: SLO-driven network priority for distributed training

**Field:** networking · AI infrastructure · distributed systems · **Difficulty:** high · **Languages:** Rust (node agent), Go (controller)

## Problem

In data-parallel training, every step ends with an **all-reduce**: the workers exchange gradients, and the step can't finish until the slowest transfer does. On shared networks, the same links also carry:

- data loading;
- checkpoint uploads;
- other jobs' traffic.

When synchronisation traffic queues behind bulk transfers, every accelerator in the job sits idle and waits. Step time p99 rises, and the whole job runs at the speed of its worst link at its worst moment.

## Who

Teams training on shared clusters or ordinary cloud networks without a dedicated training fabric, and the platform engineers who run those clusters.

## Gap

- Several systems schedule tensor transfers **inside one framework**:
  - ByteScheduler (Peng et al., SOSP 2019);
  - TicTac (Hashemi et al., MLSys 2019);
  - P3 (Jayarajan et al., SysML 2019).
- CASSINI (Rajasekaran et al., NSDI 2024) places **jobs** so that their communication phases interleave.
- A transparent, node-level mechanism is less explored. It would need no framework changes, protect synchronisation traffic only when a step-time objective is at risk, and account for the cost to the bulk traffic it delays.

## Research question

> When training traffic shares links with bulk traffic, does a node agent that raises the priority of gradient-synchronisation flows only when the step-time objective is breached cut p99 step time compared with no prioritisation and with always-on priority? How much does it delay the bulk traffic, and does a user-space proxy cost more than it saves compared with kernel queueing?

## Hypothesis and baseline

- **Baselines:**
  - FIFO (no shaping);
  - the kernel's default fair queueing;
  - static strict priority for synchronisation traffic, always on.
- **Hypothesis:**
  - Priority triggered by the objective gets most of static priority's benefit to step time, at a fraction of its cost to bulk transfers.
  - Kernel queueing (`tc`) beats a user-space proxy, whose own latency eats the gain on fast links.

## System

- **Training:**
  - PyTorch DDP with the `gloo` backend on CPU, in containers on kind or in network namespaces;
  - gloo uses TCP, so its traffic can be seen and shaped;
  - the model is sized so that the all-reduce is a large share of each step;
  - a small hook in the training loop exports step times.
- **A node agent (Rust):**
  - classifies flows by port and process: gloo, data loading, checkpoint upload;
  - measures per-flow latency and throughput from socket statistics;
  - when told to, programs Linux traffic control (HTB classes, DSCP marking) through netlink.
- **The experimental variant:** a user-space Rust proxy that forwards gloo traffic and schedules by priority itself.
- **A controller (Go):**
  - holds the step-time objective;
  - computes burn rates (Phase 5);
  - switches policy on all nodes together, with hysteresis so it doesn't flap.
- **Fail-safe:** if an agent dies, its rules are removed and traffic falls back to FIFO. The mechanism must never make things worse than doing nothing.
- **Contention:** iperf3 bulk flows, and real checkpoint uploads (capstone 6's store, if you built it).

## Suggested stack

| Part | Choice | Why |
|---|---|---|
| Node agent and proxy | Rust | It sits in or beside the data path; predictable latency and memory matter |
| Controller | Go | Control loops and an API, as in Phase 5 |
| Shaping | Linux `tc` (HTB, `fq_codel`), DSCP | Kernel queueing, no proxy in the data path |
| Training | Python, PyTorch DDP with gloo | Real collective traffic without GPUs |
| Observability | Prometheus, Grafana; optionally eBPF for per-flow timing | The evidence is per-flow |

## Features to implement

1. Flow classification without changing the training code.
2. A step-time objective and a burn-rate trigger.
3. Dynamic priority, applied consistently across nodes, with hysteresis.
4. Two enforcement modes: kernel queueing and a user-space proxy.
5. Fail-safe behaviour when the agent or controller dies.
6. Per-flow metrics, step-time metrics and policy-switch events on one timeline.

## Experiment

| Variable | Values |
|---|---|
| Policy | FIFO; fair queueing; static priority; objective-triggered priority (kernel); objective-triggered priority (proxy) |
| Contention | None; one bulk flow; many bulk flows; bursty checkpoint uploads |
| Link | 100 Mbit/s, 1 Gbit/s, 10 Gbit/s (emulated) |
| Workers | 2, 4, 8 |
| Failures | Kill a training worker (elastic restart with `torchrun`); kill the agent mid-run |

## Measures

- Step time p50 and p99, and training throughput (samples per second).
- All-reduce time per step.
- Bulk flow throughput and completion time.
- Policy switches and flaps.
- Proxy overhead: added latency and CPU.
- Objective attainment.

## Benchmark your work

- **Throughput versus latency:** raise contention step by step. Plot samples per second against step-time p99 for each policy.
- **Tails during failures:** step time in short windows around a worker kill and an agent kill; time until training is back to its normal step time.
- **Overhead:** the proxy's added latency with [wrk2](https://github.com/giltene/wrk2) through it at fixed rates against a direct path, and CPU per Gbit/s.
- **Utilisation:** CPU per node, link utilisation, and, on GPUs, the share of each step the accelerator is idle waiting for the network.
- **Rigour:** policies interleaved, at least 5 repeats, warm-up steps discarded, intervals, kernel version and `tc` configuration recorded.

## What you might find

Static priority may help step time most but starve checkpoints badly. Objective-triggered priority may land in between, but flap without hysteresis. The proxy may be fine at 100 Mbit/s and a bottleneck at 10 Gbit/s. All three are worth showing.

## Limitations to expect

- Real large-scale training uses NCCL over RDMA or InfiniBand, where `tc` doesn't apply. The findings are for TCP-based collectives.
- CPU training has a different ratio of compute to communication from GPU training; vary the model size to cover a range.
- Emulated links on one machine share a CPU.

## Skills used

Phases 2 (TCP, sockets), 4 (failure models), 5 (traffic control, network impairment, SLOs, controllers), 6 (sidecars), 7 (experimental method) and 8 (distributed training, collectives).

## Read first

- Peng et al., *A Generic Communication Scheduler for Distributed DNN Training Acceleration* (ByteScheduler), SOSP 2019
- Hashemi et al., *TicTac: Accelerating Distributed Deep Learning with Communication Scheduling*, MLSys 2019
- Jayarajan et al., *Priority-based Parameter Propagation for Distributed DNN Training*, SysML 2019
- Rajasekaran et al., *CASSINI: Network-Aware Job Scheduling in Machine Learning Clusters*, NSDI 2024
- Kurose and Ross, *Computer Networking*, the chapters on queueing and scheduling
