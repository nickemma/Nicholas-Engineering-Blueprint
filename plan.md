# Build plan: closing the gaps before Phase 8

This is the **build plan** for the Blueprint itself, the work list we tick off. The learner's map is still [JOURNEY.md](JOURNEY.md); everything here ends up there once it's built.

**Rule for every item:** the same standard as the phases. Code is inline and checked by `scripts/check_guides.py`; every output shown is real, captured on this machine; every claim is tested or measured. An item is ticked only when its "done when" list is all true.

**Deliberately not added:** more tools for their own sake (a second infrastructure-as-code tool, a third cloud, more databases, Kubernetes add-ons). Each item below closes a gap tied to a role on the career map or to the MSc.

## Before Phase 8

### 1. Push the branch and get CI green on GitHub
- [x] Branch `restructure/batch-1` pushed (not merged into `main`)
- [ ] The **Lessons** workflow green on GitHub, or every failure fixed and pushed again

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
- [ ] `lessons/perf-bridge/`: README (syllabus), TEACHING.md (type-along), exercises.md, learned.md, and `notes/learned/perf-bridge.md`
- [ ] Covers:
  - the USE method on a real slowdown;
  - CPU profiling with `pprof` and `perf`, read as flame graphs;
  - `strace` for system calls;
  - eBPF with `bpftrace` (in a privileged container) for latency histograms and off-CPU time;
  - memory and Go's garbage collector under load.

  Every one is used on Runway's own processes, with a planted problem to find.
- [ ] Every output captured on this machine; the guide replays in CI (the parts that need root are documented as such)

**Why before Phase 8:** SRE and infrastructure loops have a live troubleshooting round, and Phase 8 profiles GPU workloads.

### 6. Networking Bridge: the network under load (after Phase 5)
- [ ] `lessons/network-bridge/`: README, TEACHING.md, exercises.md, learned.md, and `notes/learned/network-bridge.md`
- [ ] Covers:
  - TCP congestion control measured under loss and delay (CUBIC against BBR, if the kernel module loads; otherwise against Reno, and said so);
  - head-of-line blocking: HTTP/1.1 against HTTP/2 against HTTP/3 (QUIC) on a lossy link;
  - anycast and BGP concepts;
  - what a CDN does to latency.

  Everything in containers with `tc netem`, with experiments planned and analysed the way Phase 7 does it.
- [ ] Every output captured on this machine; the guide replays in CI

**Why before Phase 8:** the MSc target is systems and networking, KESTREL is a networking question, and Phase 8's distributed training is limited by the network.

### 7. Maths track (parallel, like `dsa/`)
- [ ] `math/` with guides, Python code checked by CI:
  - probability and queueing theory: Little's law, M/M/1, why latency explodes near saturation, checked against a simulation and against Runway;
  - proofs and invariants: induction, and how Raft's safety argument and TLA+ fit;
  - linear algebra for ML and GPUs: vectors, matrices, the cost of a matrix multiply, and arithmetic intensity, which feeds Phase 8.
- [ ] JOURNEY's parallel-tracks table and career map (Research MSc row) link to it

### 8. Wire it all into the map
- [ ] JOURNEY: the route, the route table, the gap ledger, tools to install, the timeline, and the career map include the two bridges and the maths track
- [ ] README and `career.md` updated
- [ ] Full replay of every guide (`scripts/check_guides.py`) green locally, then pushed and green on GitHub

## Phase 8: AI infrastructure

- [x] `lessons/08-ai-infrastructure/` created, with a placeholder README (the outline; the guide is written when the phase starts)
- [ ] Step list designed with the user. Inputs:
  - PyTorch Distributed and Megatron-LM;
  - CUDA basics;
  - Ray;
  - the production-ready inference platform as the spine;
  - a performance and cost benchmark.
- [ ] **Plugged in here: supply-chain security.** A step that produces SBOMs, signs container images **and model weights**, and refuses unsigned ones at deploy (admission control), with provenance. Tampered weights are an AI-infrastructure threat, so this is the natural home. It also closes the gap Phase 6 handed to the capstone, and JOURNEY's ledger is updated to point here.
- [ ] **Plugged in here:** the maths track's linear-algebra guide is the prerequisite for the CUDA and matrix-multiply steps.
- [ ] Decide how the CUDA steps are verified: a rented GPU for the captures, or "you run it" steps with the expected output.

## After Phase 8

- [ ] **The interactive site** (`site/`: Astro with React islands, on Vercel), from the original restructure plan. Confirm scope before starting.
