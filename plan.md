# Build plan: closing the gaps before Phase 8

This is the **build plan** for the Blueprint itself, the work list we tick off. The learner's map is still [JOURNEY.md](JOURNEY.md); everything here ends up there once it's built.

**Rule for every item:** the same standard as the phases. Code is inline and checked by `scripts/check_guides.py`; every output shown is real, captured on this machine; every claim is tested or measured. An item is ticked only when its "done when" list is all true.

**Deliberately not added:** more tools for their own sake (a second infrastructure-as-code tool, a third cloud, more databases, Kubernetes add-ons). Each item below closes a gap tied to a role on the career map or to the MSc.

## Before Phase 8

### 1. Push the branch and get CI green on GitHub
- [x] Branch `restructure/batch-1` pushed (not merged into `main`)
- [x] The **Lessons** workflow green on GitHub, or every failure fixed and pushed again (first run: green in 39 minutes)

**Why first:** 18+ commits of curriculum have never run on GitHub's CI. Phase 7's replay installs PyTorch and Spark, which may hit the runner's disk or time limits.

### 2. Disclose the evidence debts
- [x] Phase 7: the quiet-hour false-alarm test is marked "not measured" wherever its result is mentioned (README, learned.md, JOURNEY), with the command that would settle it
- [x] Phase 5: the AWS Terraform is described as "planned and checked offline, applied by the learner" in the README and JOURNEY, never as "deployed"
- [x] JOURNEY gains a short **Known limits** section listing both, and anything else found while checking

### 3. Open-source contribution track
- [x] `open-source/README.md`: how to read a real codebase (hashicorp/raft, etcd's raft, a Rust storage crate), find a first issue, write the change with tests, and get it merged, with checkpoints by phase
- [x] JOURNEY's parallel-tracks table links to it

### 4. Multi-region and disaster recovery, as a Phase 5 exercise
- [x] Phase 5's `exercises.md` gains **Runway in two regions**: a finished-state spec (RPO and RTO targets, a failover runbook, a rehearsed failover with measured data loss and recovery time), done-when checks, and no solution
- [x] JOURNEY's gap ledger points at it

### 5. Performance Bridge: Linux performance and debugging (after Phase 5)
- [x] `lessons/perf-bridge/`: README (syllabus), TEACHING.md (type-along), exercises.md, learned.md, and `notes/learned/perf-bridge.md`
- [x] Steps. The guide builds `hotspot`, a small Go jobs service shaped like Runway's API, with five planted problems. Each step finds one with the right tool, fixes it, and measures the difference:
  - [x] 1. A slow service and the USE method: the service, an open-loop load generator, a baseline (fine at 500 requests/s, collapsing at 800), and `vmstat`, `top` and `/proc`, which show it's waiting, not computing
  - [x] 2. Waiting: mutex and block profiles find a lock held across a slow call
  - [x] 3. Computing: CPU profiles with `pprof`, read as flame graphs, find a hidden O(*n*²)
  - [x] 4. `perf`: whole-process profiles and hardware counters (IPC, cache misses), connected to DSA guide 00's cache finding
  - [x] 5. `strace`: a storm of tiny system calls
  - [x] 6. The kernel's view with eBPF: `bpftrace` (in a privileged container) for system-call latency histograms and scheduler delay
  - [x] 7. Memory and the garbage collector: allocation profiles, `gctrace`, `GOGC` and `GOMEMLIMIT`
  - [x] 8. The method end to end: before and after for every fix, and a checklist for "this box is slow"
- [x] The exercise applies the same tools to Runway itself
- [x] Result: from collapsing at 800 requests/s to holding 8,000/s (p99 27 ms)
- [x] Every output captured on this machine; the guide replays in CI (the steps that need `perf`, root or Docker are marked as such and not run there)

**Why before Phase 8:** SRE and infrastructure loops have a live troubleshooting round, and Phase 8 profiles GPU workloads.

### 6. Networking Bridge: the network under load (after Phase 5)
- [x] `lessons/network-bridge/`: README, TEACHING.md, exercises.md, learned.md, and `notes/learned/network-bridge.md`
- [x] Steps. The guide builds `netlab`: containers joined by a link you control with `tc netem`, and Go programs to measure across it. Experiments are planned and analysed the way Phase 7 does it:
  - [x] 1. A network you can break: the lab, RTT, bandwidth, the bandwidth-delay product, and what `ss -ti` shows
  - [x] 2. What loss does to TCP: throughput against loss, checked against the Mathis formula; retransmissions in `tcpdump`
  - [x] 3. Congestion control: Reno, CUBIC and BBR under loss, bufferbloat, and sharing a link
  - [x] 4. Head-of-line blocking: HTTP/1.1, HTTP/2 and HTTP/3 (QUIC) on a lossy link
  - [x] 5. CDNs, anycast and BGP: what an edge saves, measured, and a small path-vector simulator of anycast failover
  - [x] 6. The method: a checklist for "the network is slow"
- [x] Results: the Mathis formula within its interval at all five loss rates; BBR at 91 Mbit/s against 3 at 1% loss, and starving CUBIC on a small queue; HTTP/3's win on tiny requests is head-of-line blocking, its win on bulk transfer isn't; a cache hit nine times faster
- [x] Every output captured on this machine; CI rebuilds the code and runs its tests (the live measurements need Docker and `tc`, and are marked as such)

**Why before Phase 8:** the MSc target is systems and networking, KESTREL is a networking question, and Phase 8's distributed training is limited by the network.

### 7. Maths track (parallel, like `dsa/`)
- [x] `math/` with guides, Python code checked by CI:
  - probability and queueing theory: Little's law, M/M/1, why latency explodes near saturation, checked against a simulation and against Runway;
  - proofs and invariants: induction, and how Raft's safety argument and TLA+ fit;
  - linear algebra for ML and GPUs: vectors, matrices, the cost of a matrix multiply, and arithmetic intensity, which feeds Phase 8.
- [x] Results: Little's law within about 2% on 27 stable runs of the real Runway; Pollaczek–Khinchine predicting it with a median ratio of 0.88 to 0.97 below 93% utilisation; every state of a small Raft election checked; a roofline predicting a case it wasn't fitted to, to within about 15%
- [x] JOURNEY's parallel-tracks table and career map (Research MSc row) link to it

### 8. Wire it all into the map
- [x] JOURNEY: the route, the route table, the gap ledger, tools to install, the timeline, and the career map include the two bridges and the maths track
- [x] README and `career.md` updated
- [x] Full replay of every guide (`scripts/check_guides.py`) green locally (2,348 steps), then pushed and green on GitHub

## Phase 8: AI infrastructure

- [x] `lessons/08-ai-infrastructure/` created, with a placeholder README (the outline; the guide is written when the phase starts)
- [x] Step list designed with the user (approved 2026-11-01). Serving first, then training, then the GPU:
  - [x] 1. What a model server does: tokens, prefill and decode, and the KV cache, on a tiny transformer
  - [ ] 2. A real model: `llama.cpp`, streaming, time to first token, inter-token latency, and the knee
  - [ ] 3. Batching and concurrency, checked against the queueing guide
  - [ ] 4. The gateway on Runway: auth, limits in tokens, an admission queue, cancellation
  - [ ] 5. Observability: metrics, traces and SLOs on time to first token
  - [ ] 6. Kubernetes: slow readiness, scaling on queue depth, cold starts
  - [ ] 7. Supply chain: SBOMs, signed images and weights, admission control
  - [ ] 8. A performance and cost benchmark, with quality checks
  - [ ] 9. Failure and recovery: a game day and a runbook
  - [ ] 10. Data parallelism: DDP on CPU processes, across `netlab`'s link
  - [ ] 11. Tensor and pipeline parallelism from scratch, then reading Megatron-LM
  - [ ] 12. Ray
  - [ ] 13. CUDA and vLLM on a GPU
  - [ ] 14. The report
- [ ] **Plugged in here: supply-chain security.** A step that produces SBOMs, signs container images **and model weights**, and refuses unsigned ones at deploy (admission control), with provenance. Tampered weights are an AI-infrastructure threat, so this is the natural home. It also closes the gap Phase 6 handed to the capstone, and JOURNEY's ledger is updated to point here.
- [ ] **Plugged in here:** the maths track's linear-algebra guide is the prerequisite for the CUDA and matrix-multiply steps.
- [x] CUDA steps are verified on a rented GPU: the user runs the script and supplies the output

## After Phase 8

- [ ] **The interactive site** (`site/`: Astro with React islands, on Vercel), from the original restructure plan. Confirm scope before starting.
