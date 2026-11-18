# Restructure plan: Control planes in Go, data planes in Rust

**Status:** draft for review. Nothing gets built until this is agreed.
**Original brainstorm:** `~/blueprint-scratch/plan-draft/plan-original-2026-11-17.md`. It also holds the two sample lessons (Raft election 4.1, zero-copy parser 2.1), which are kept there as format references.

---

## 1. Why we're restructuring

The goal: someone opens the Blueprint, learns enough to land a systems or infrastructure role, and is confident in what they know.

Today's Blueprint is one long route (about 83 weeks) that builds Runway, a jobs platform. That suits a product backend engineer. The roles we're aiming at (AI infrastructure, storage, cloud and networking at companies like Cloudflare, Anthropic, OpenAI, AWS and Datadog) ask for something else. Their postings keep repeating these:

- performance and latency; profiling and observability; debugging
- production ownership and on-call
- distributed systems; concurrency
- Rust; Linux; OS and memory internals
- networking (TCP/IP, protocols)
- using AI tools at work, and checking what they produce

The principles we're building to:

- **Learn the fundamentals plus your domain's internals:** memory (stack, heap, pointers, cache lines), the OS (processes, threads, syscalls, virtual memory), concurrency (atomics, locks, memory ordering), I/O and networking (TCP, epoll, io_uring).
- **One deep project beats ten tutorials.** If nobody runs it, it isn't proof.
- **Build real software:** climb from "build your own X" to something people actually run. Test it like it matters (fuzzing, sanitizers, Miri), measure it (benchmarks, flame graphs), and write it up (design choices and the numbers).
- **Every language has one job:**
  - Go: orchestration, APIs, consensus and control loops (the control plane).
  - Rust: storage engines, parsers, proxies and hot-path memory control (the data plane).
  - Python: load generation, analysis, ML and AI orchestration, and PyO3 bindings.
- **Security is designed in from the start, not bolted on at the end** (see §5).

---

## 2. The new shape

```text
PHASE 0: ZERO-TO-ONE FOUNDATIONS (8 weeks; experienced developers test out)
   Day-1 setup → 0A Machine & terminal → 0B Go from zero → 0C Internet & Python
                                   │
                                   ▼
STAGE 1: THE SHARED CORE (22 weeks; everyone)
   M01 Go control plane (4) → M02 Rust memory & concurrency (5) → M03 Linux I/O, networking & observability (4)
   → M04 Consensus & durable storage (6) → M05 Isolation, delivery & AI-assisted engineering (3)
                                   │
              ┌────────────────────┼────────────────────┐
              ▼                    ▼                    ▼
   TRACK A: AI infrastructure  TRACK B: Storage    TRACK C: Cloud & edge
   Python + Go + Rust          Rust + Go           Go + Rust + eBPF
   16 weeks                    16 weeks            16 weeks
              └──────────── capstone = the track's shipped system ────────────┘
```

A complete beginner's total is about 46 weeks (8 + 22 + 16). An experienced developer's is about 38 (22 + 16).

**Labs become verification gates.** Failure drills stop being optional side quests. Each module ends with an automated pass/fail gate: crash the disk mid-write, partition the network, inject loss, profile the tail. You haven't finished a module until its gate passes.

---

## 3. What each part builds

### Phase 0: Zero-to-one foundations (8 weeks)

| Part | Learn | Build |
|---|---|---|
| **0.0 Day-1 setup** (~45 min) | Why real servers run Linux. WSL2 + Ubuntu, macOS, or Linux; Git; Go; VS Code (on Windows, the WSL extension, with code kept inside Linux) | A Go program that prints OS, architecture and CPU count. It's the Day-1 gate. |
| **0A Machine & terminal** (2 wk) | Shell, filesystem, permissions, processes; how the CPU, RAM and disk store data; Git branches and commits | A shell system monitor and a log-rotation utility |
| **0B Go from zero** (3 wk) | Variables, types, loops, structs, slices, maps, interfaces, errors, tests, channels, `select` | A CLI task engine and a JSON log analyser |
| **0C Internet & Python** (3 wk) | IP, DNS, TCP vs UDP, the HTTP wire format; Python from zero (uv, lists and dicts, asyncio, plotting) | A raw TCP echo server in Go, and a Python script that fires 1,000 concurrent requests at it and plots the latency distribution |

### Stage 1: The shared core (22 weeks)

Everyone builds one system: a **Go control plane** that orchestrates and secures a **Rust data plane**, over Linux.

| Module | What you build | Under the hood | Security built in | Gate |
|---|---|---|---|---|
| **M01 Go control plane** (4 wk) | A desired-state job orchestrator and worker pool behind a gRPC API, with graceful shutdown. Raw `net.Conn` before `net/http`. | The G-M-P scheduler; escape analysis (`-gcflags=-m`); GC pacing (`GODEBUG=gctrace=1`) | Wire bounds (max sizes, deadlines, connection caps); per-client token buckets; HMAC-signed webhooks with replay protection | 10,000 rapid state changes while workers are killed: the system converges, with no leaked goroutines (`goleak`) |
| **M02 Rust memory & concurrency** (5 wk) | 2.0 Rust for Go developers → 2.1 zero-copy frame parser → 2.2 SPSC lock-free ring buffer → async: a hand-written `Future` and mini executor, then Tokio | Stack vs heap, `Box`/`Rc`/`Arc`, layout (`size_of`, alignment, cache lines); generics vs `dyn Trait` (vtables, fat pointers); atomics and memory ordering; `Pin`; how Tokio polls futures | Memory safety by construction; `cargo-fuzz`, Miri, ASan/TSan on malformed input | Concurrent stress tests pass clean under Miri and ThreadSanitizer (see fix 3 in §9) |
| **M03 Linux I/O, networking & observability** (4 wk) | Go control plane ↔ Rust data plane over TCP and Unix sockets, traced with OpenTelemetry, driven by a Python load harness | User vs kernel space, syscalls (`strace`), virtual memory, epoll vs io_uring, TCP congestion control, `perf` and flame graphs; the GIL, asyncio and PyO3 | Your own CA; mTLS between Go and Rust; certificate rotation without dropping traffic | Under injected loss and CPU contention: find the bottleneck with a flame graph, fix it, and show the p99 gain (see fix 4 in §9) |
| **M04 Consensus & durable storage** (6 wk) | A multi-node Go coordinator (Raft, consistent hashing, leases, fencing tokens) on a checksummed Rust WAL | The page cache and `fsync`; torn writes; clocks that lie; quorums; linearizability | CRC32C/BLAKE3 on every record; a hash-chained audit log; envelope encryption (DEK/KEK) | `kill -9` mid-flush plus a network partition: no corrupt records, no split-brain writes |
| **M05 Isolation, delivery & AI-assisted engineering** (3 wk) | A mini container from namespaces and cgroups; hardened images; IaC deploy; SLO burn-rate alerts | What a container really is | seccomp-bpf, read-only root, non-root, dropped capabilities; dynamic secrets (OpenBao); signed artifacts and SBOMs | A 30-minute chaos and tamper game day, plus a published ADR |

**The AI-assisted workflow** (taught in M05, used everywhere after): use AI to draft FFI bindings, property-based tests, fuzz harnesses, and explanations of legacy code. Then verify every line with tests, Miri, sanitizers and benchmarks before trusting it. This is the Blueprint's purpose ("learn the principles so you can check what AI generates") made into a skill.

### Stage 2: Domain tracks (pick one, 16 weeks)

Every track has the same three phases: **A. engine internals** (weeks 1–6), **B. distributed scale** (weeks 7–12), **C. ship and benchmark** (weeks 13–16).

| Track | A: Rust data plane | B: Go/Python control plane | C: Ship | Domain hardening |
|---|---|---|---|---|
| **AI infrastructure** | Async token-streaming proxy, SSE parser, token-bucket limiter, KV-cache metadata store | GPU-aware router, priority scheduler, vLLM/Ray worker pool, eval harness | An OpenAI-compatible inference gateway, benchmarked for TTFT, TPOT and throughput under bursty load | Per-tenant token budgets, tenant isolation on shared clusters, streaming PII and secret redaction, egress filtering and sandboxing for tool-calling agents |
| **Database & storage** | An LSM-tree (or B+tree) engine: memtable, SSTables, Bloom filters, compaction, MVCC | Shard placement, Raft replication groups, snapshot transfer, compaction scheduler, admin CLI | A distributed KV store, benchmarked with YCSB, with tail-latency flame graphs and crash-recovery proofs | Tenant namespaces, encrypted WAL and SSTables, RBAC on admin RPCs |
| **Cloud & edge** | An L4/L7 reverse proxy: connection pooling, HTTP/2 and HTTP/3, circuit breaking | Dynamic route and config push, health-check agreement, mTLS rotation, eBPF filtering | A programmable edge proxy, benchmarked for requests per second, memory, and zero-downtime reloads | eBPF/XDP drop rules, strict TLS 1.3, header sanitisation |

**Every capstone ships three things:** a public repo (or a workplace deployment) with reproducible benchmarks; flame graphs from before and after optimisation; and a design doc or ADR defending the trade-offs. "Real users" is the goal, not a requirement we can check.

---

## 4. How every lesson teaches

Every lesson uses the same five-part loop:

1. **The plain-English problem:** a real failure before any jargon ("two servers both think they're the leader").
2. **The mental model:** a diagram of where the bytes live (stack and heap, user and kernel space, control and data plane).
3. **The pattern, under the hood:** the named pattern (single-owner event loop, zero-copy framing, token bucket) and what the runtime is doing underneath.
4. **Incremental build steps:** 5–7 small checkpoints, each with the exact command to run it and its real expected output.
5. **The failure gate:** an automated chaos, profiling or security test against the learner's own code.

Supports on every build step:

- **Annotated skeleton:** the wiring is provided, the logic is left as `// TODO`. Beginners struggle with plumbing (structs, `select` loops, reply channels) as much as with the algorithm.
- **Run and inspect:** the test command, what a failing test looks like, and how to read it.
- **Stuck drawer:** hint 1 (a nudge), hint 2 (pseudocode), then a fully commented reference. *(This changes a current rule; see decision D4.)*
- **Syntax before use:** nothing in a module uses syntax the learner hasn't practised. Go comes in 0B, Python in 0C, and Rust in 2.0 (mapping struct, interface, nil and goroutine to struct, trait, `Option` and `tokio::spawn`).
- **Just-in-time setup cards:** tools arrive when they're first needed. Go on Day 1, Python in 0C, Rust and Miri in M02, `perf`, `strace` and flame-graph tools in M03, Docker, Terraform and OpenBao in M05. Each card ends with one verify command and its expected output.
- **Ownership levels** on every module: *junior* delivers a bounded, tested change; *intermediate* owns a safe service change and measures capacity; *senior* defends trade-offs in an ADR and debugs across both planes.

---

## 5. Security: where each layer lives

There's no separate security track. Each layer is built where it belongs:

| Layer | Where |
|---|---|
| 1. Service identity: mTLS, short-lived certificates, rotation, wire bounds | M01 (bounds), M03 (CA, mTLS, rotation) |
| 2. Workload isolation: namespaces, cgroups, seccomp, non-root, read-only root; microVM concepts (Firecracker, gVisor) | M05; AI track (agent sandboxes) |
| 3. Data integrity: checksums, hash-chained audit log, envelope encryption | M04 |
| 4. Secrets and supply chain: dynamic secrets, signing, SBOMs | M05 |
| 5. Tenant isolation and abuse: rate limits, load shedding, signed webhooks | M01; each track |
| 6. Domain hardening | The last column of the track table in §3 |

**Out of scope:** model alignment, jailbreak research and adversarial ML. Those are research and ML-security roles, not systems roles.

---

## 6. Changes to the other sections

| Section | Change |
|---|---|
| **Navigation** | From *Journey · Ownership · DSA · System design · Maths · Capstones · Labs* to *Journey · Ownership · DSA · Design · Maths · Capstones*. Labs move into Journey as gates. |
| **Landing page** | Headline: *Control planes in Go. Data planes in Rust.* Stats strip: 5 core modules (~22 wk) · 3 tracks (~16 wk each) · Go · Rust · Python · Linux · proof by flame graphs and chaos gates. Add a "Where you start → where you land" block below the tracks. |
| **Journey** | Two visual stages: the core, then tabs for the three tracks. Gates appear inside each module. |
| **Ownership** | Keep it prominent. Add a **senior proof checklist**: an ADR you wrote, published p99 flame graphs, a race or memory bottleneck you debugged. |
| **DSA** | Keep the 20 patterns. Practise in Go and **Rust** (Rust replaces Python here). Add systems structures: ring buffers (SPSC/MPMC), Bloom filters and Count-Min Sketch, consistent-hash rings, skip lists, memtables and B+trees, token buckets and sliding windows, tries and radix trees. |
| **System design** | Organise around control-plane vs data-plane trade-offs. Worked designs: an LLM inference router, a distributed KV store, a global L7 edge proxy. |
| **Maths** | Reframe around capacity and tails: Little's law and M/M/1 and M/M/c (why latency explodes past ~80% utilisation); tail amplification under fan-out (1 − 0.99ᴺ); IOPS, write amplification, bandwidth and memory overhead; Bloom-filter false positives and collision bounds. |
| **Capstones** | Replace the 12 research briefs with **3 domain capstones**, one per track (§3). |

---

## 7. Reusing what already exists

Most of today's content moves into the new structure rather than being thrown away:

| New part | Comes from today | New work needed |
|---|---|---|
| Phase 0 | Phase 0 (Go HTTP service); Python Bridge basics; "What to install, and when" | Day-1 gate; 0A from scratch; Go and Python from zero |
| M01 | Phase 1 (layered API, context, races, shutdown); Phase 2 (worker pool, retries, idempotency, breaker, gRPC); Phase 5's controller; Phase 6's rate limits and signed webhooks; Performance Bridge's Go profiles | Go runtime internals; raw `net.Conn`; `goleak` gate |
| M02 | Rust Bridge (`klog`, CRC-32C, torn writes) | Most of it: the 2.0 primer, parser, ring buffer, atomics, custom `Future`, `dyn` vs generics, fuzzing, Miri, sanitizers |
| M03 | Performance Bridge (`perf`, `strace`, eBPF, flame graphs); Networking Bridge (`netem`, congestion, `ss`); Phase 5's OTel; Phase 6's CA and mTLS; Python Bridge's load generator | Go↔Rust wire; epoll vs io_uring; GIL and PyO3 |
| M04 | Phase 4 (Raft, simulation testing, Porcupine, TLA+, consistent hashing, leases, fencing); Phase 3 (WAL, `fsync`, page cache); Phase 6's tamper-evident log | Raft on a Rust WAL; envelope encryption; combined crash and partition gate |
| M05 | Phase 5 (containers, Kubernetes, Helm, CI/CD, SLOs, game day, Terraform); Phase 6 (OpenBao, hardening, fuzzing); Phase 8 step 7 (SBOM, signing) | Mini container; seccomp; AI-assisted workflow; ADR |
| AI track | Phase 8 (serving, TTFT, batching, Ray, CUDA, cost benchmark); Phase 9 (agent attacks and guardrails); capstones 04 and 05 | Rust streaming gateway, SSE parser, KV-cache metadata |
| Storage track | Phase 3 (B-tree vs LSM, WAL); capstone 06 | Most of it: LSM engine, compaction, MVCC, YCSB |
| Cloud & edge track | Networking Bridge (HTTP/3, CDN); Phase 5's L7 balancer; Phase 6's mTLS and sidecar | Most of it: Rust proxy, config push, eBPF/XDP |
| Labs (site) | Existing interactive labs | Retitled and linked as module gates |

**Not yet placed (needs a decision, D2):** Phase 3's PostgreSQL, pooling, transactions, outbox, Kafka, Redis caching and background jobs, and Phase 7's statistics, data pipeline and ML.

---

## 8. Decisions needed before building

| # | Question | Options | Recommendation |
|---|---|---|---|
| **D1** | C and C++ | (a) drop entirely; (b) "enough C to read it": reading, debugging, FFI | **(b)**, as a short block in M02 (FFI to a C library under sanitizers). Most existing systems code is C, and the brainstorm's own "read legacy" principle asks for it. |
| **D2** | Backend data topics (Postgres, pooling, transactions, outbox, Kafka, Redis, background jobs), which you earlier required | (a) cut; (b) one "service data" block in M01/M04; (c) storage track only | **(b)**. Interviewers still ask about them, and the outbox and idempotency patterns are control-plane work. |
| **D3** | Phase 7 (experiments, pipelines, ML) | (a) cut; (b) move experiment statistics to Maths and model serving to the AI track; the rest goes | **(b)** |
| **D4** | Stuck drawer with full reference code | Today's rule is "guides, not solutions": code is inline and type-along, with no solution folders | Allow the **inline** collapsed reference inside TEACHING.md. Still no solution folders. |
| **D5** | Kernel, embedded and robotics | (a) show as "coming soon"; (b) remove | **(a)**: listed but not built |
| **D6** | Name of the core system | Keep "Runway" for the new control and data plane, or rename | Rename. The jobs-platform framing is what we're moving away from. |
| **D7** | Phase 9 and the agent lab, uncommitted on `main` | Commit as-is, finish the rebuild first, or park on a branch | Commit to a branch before restructuring, so nothing is lost and `main` stays clean |
| **D8** | Lesson code status | Every expected output is real and captured (today's standard), or illustrative for now | **Real.** Keep the current build workflow: scratch dir, snapshot per step, captured outputs, one replay per phase. |

---

## 9. Fixes to carry from the brainstorm

The draft had errors that mustn't reach the lessons:

1. **Broken install URLs.** The Go download (`https://go.dev`), Homebrew (`githubusercontent.com`), uv (`https://astral.sh`) and rustup (`https://rustup.rs`) links are truncated. Use the official install commands and pin the current versions at build time (not `go1.24.1`).
2. **Unverified job-market claims.** The salary ranges and quoted phrases attributed to Cloudflare, Anthropic, OpenAI and Datadog aren't sourced. Batch 0 replaces them with real postings, linked and dated, or drops them.
3. **The M02 gate's numbers are unrealistic.** Miri is orders of magnitude slower than native code, so a million operations under Miri won't finish in reasonable time. Use a small operation count under Miri and the full million under TSan and loom.
4. **The M03 gate is contradictory.** Packet loss can't be "fixed" in code. Make the gate: find the CPU bottleneck with a flame graph, fix it, and show the p99 gain under the same loss, without a fixed 30% target.
5. **The site is Astro, not Next.js.** The step-card tabs (instructions, starter, run, hints) must be built as Astro components and islands.
6. **The sample parser test uses `unsafe` needlessly.** Compare against `raw[9..].as_ptr()` instead.

---

## 10. Build order

Each batch ends with a review stop. No batch starts until the previous one is agreed.

| Batch | Work | Output for review |
|---|---|---|
| 0 | Lock decisions D1–D8. Collect 5–10 real senior postings (links and dates) and map each requirement to a module. | A `notes/` evidence table; gaps listed |
| 1 | Rewrite JOURNEY.md to the new map; README skeletons for every module and track; mark the old lessons' new homes | The new JOURNEY.md; folder layout |
| 2 | Phase 0 (Day-1 gate, 0A, 0B, 0C) | Guides with captured outputs |
| 3 | M01 Go control plane | Guide + gate |
| 4 | M02 Rust (the deepest module) | Guide + gate |
| 5 | M03 Linux I/O, networking, observability | Guide + gate |
| 6 | M04 Consensus and durable storage | Guide + gate |
| 7 | M05 Isolation, delivery, AI-assisted workflow | Guide + gate |
| 8 | AI infrastructure track (first, since it reuses Phases 8–9) | Track guide + capstone brief |
| 9 | Storage track | Track guide + capstone brief |
| 10 | Cloud and edge track | Track guide + capstone brief |
| 11 | DSA (Rust plus systems structures), Design, Maths, Ownership checklist, Capstones down to 3 | Updated sections |
| 12 | Site: navigation, landing page, Journey tabs, labs as gates, step cards | Built site, checked in the browser |

Each module follows the existing guide workflow: build in `~/blueprint-scratch`, snapshot each step, capture real outputs, and replay once at the end of the module.
