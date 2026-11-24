# Restructure plan: Control planes in Go, data planes in Rust

**Status:** agreed 2026-11-18. Batch 0 done on branch `restructure`; gaps and Q1–Q2 decided 2026-11-18 (§1, §10).
**Original brainstorm:** `~/blueprint-scratch/plan-draft/plan-original-2026-11-17.md` (with the two sample lessons, kept as format references).

## Rules this plan follows

1. **The core holds only what every domain needs.** Everything domain-specific lives in the track that uses it. A learner who wants two domains takes two tracks.
2. **Topics shared by tracks are written once, as shared units.** Each track lists the units it needs. A learner on a second track skips the units they've already done.
3. **Each language is taught on its own terms before it's used:** syntax and how it works first, then systems. This applies to Go, Python and Rust.
4. **Nothing a learner needs is dropped.** Connecting to a database, Docker, and the rest all have a home in the core or a track.
5. **Each track's capstone is the system the track ships.** The 12 research briefs and KESTREL are removed.
6. **Our teaching system is called Switchyard.** Learners can call theirs anything.
7. **Names say what's inside.** Numbers give the order; words give the content. No codes like `0a` or `c1`.

---

## 1. Why

The goal: someone opens the Blueprint, learns enough to land a systems or infrastructure role in the domain they pick, and is confident in what they know.

### Ten real postings

Read on 2026-11-18 from each company's own job board. "Posted" is the board's first-published date. Postings close, so a dead link means the role was filled, not that the evidence is wrong.

| # | Company and role | Where | Posted | Maps to |
|---|---|---|---|---|
| 1 | [Anthropic: Staff + Senior Software Engineer, Inference](https://job-boards.greenhouse.io/anthropic/jobs/5385998008) | Ontario, Canada | 2026-08-17 | Core 01, 06, 07; AI track 02, 03; Kubernetes and delivery |
| 2 | [Cloudflare: Senior Software Engineer, Network Connectivity (Go/Rust)](https://boards.greenhouse.io/cloudflare/jobs/7793013) | Austin, NYC, Lisbon, London | 2026-04-08 | Core 01, 04–06, 08; Cloud track 01, 02 |
| 3 | [Cloudflare: Senior Software Engineer, Quicksilver (distributed key-value)](https://boards.greenhouse.io/cloudflare/jobs/8140310) | US and EU cities | 2026-08-21 | Core 01, 06, 07; Storage track |
| 4 | [Cloudflare: Systems Reliability Engineer, Core](https://boards.greenhouse.io/cloudflare/jobs/8324908) | Lisbon, London | 2026-10-28 | Core 03, 06, 08; Kubernetes and delivery; AWS and Terraform; Event streams |
| 5 | [Cloudflare: Senior Systems Engineer, AI Gateway](https://boards.greenhouse.io/cloudflare/jobs/7560174) | In office | 2026-07-22 | Core 08; AI track 03, 04; Tenancy and abuse control; Caching |
| 6 | [Datadog: Senior Software Engineer, Distributed Systems](https://careers.datadoghq.com/detail/3851927/) | Boston, New York | 2022-01-27 (evergreen; updated 2026-11-05) | Core 01, 04–07; Event streams; Caching |
| 7 | [OpenAI: Software Engineer, Database Systems](https://jobs.ashbyhq.com/openai/2b5e8e15-7952-4170-a927-2ad68e318ed6) | San Francisco | 2025-07-29 | Core 05–07; Storage track; Kubernetes and delivery; AWS and Terraform |
| 8 | [OpenAI: Software Engineer, Model Runtime](https://jobs.ashbyhq.com/openai/ec317080-e2d2-4a73-93e6-e0a9ae6fdf96) | San Francisco | 2026-08-24 | Core 02, 05, 06; AI track 02 |
| 9 | [OpenAI: Software Engineer, Traffic Infrastructure](https://jobs.ashbyhq.com/openai/1d386acc-5fe0-44ed-b288-a6b1b891c9a8) | San Francisco, Seattle | 2026-10-29 | Core 06, 08; Cloud track; Kubernetes and delivery |
| 10 | [AWS: SDE II, EC2 Instance Networking (Nitro)](https://www.amazon.jobs/en/jobs/10594870/sde-ii-ec2-instance-networking-ec2-nitro) | Seattle | 2026-11-02 | Core 05, 06; Cloud track 01, 02 |

### What they keep asking for

| Ask | Postings | Where the Blueprint teaches it |
|---|---|---|
| Distributed systems: fault tolerance, horizontal scale, correctness | all 10 | Core 07; every track |
| Performance: find bottlenecks, latency, throughput, memory, profiling | 1–3, 5–10 | Core 02, 06; every capstone's flame graphs |
| Production ownership: on-call, incident response, postmortems, SLOs | 2–4, 7, 9, 10 | Core 08 |
| Debugging across layers of the stack, with evidence | 2–4, 6–10 | Core 06; every gate |
| Go or Rust named as the language | 2, 3, 5, 6, 9, 10 (C/C++ in 7, 8, 10) | Core 01, 04, 05; reading C in core 05 |
| Networking fundamentals: TCP/IP, DNS, TLS, HTTP, L3/L4/L7, BGP | 2, 4, 9, 10 | Core 06, 08; Cloud track 01 |
| Linux internals: memory management, storage subsystems | 4, 7, 10 | Core 06 |
| AI coding tools at work, **and checking their output** | 2, 4, 5, 6 | Core 08 (the AI-assisted workflow) |
| Load balancing, request routing, autoscaling | 1, 5, 9 | AI track 02, 03; Cloud track 02; Kubernetes and delivery |
| LLM inference: prefill vs decode, batching, KV cache, model parallelism | 1, 8 | AI track 02 |
| Kubernetes, Terraform, CI/CD, Prometheus and Grafana | 1, 4, 7, 9 | Kubernetes and delivery; AWS and Terraform |
| Kafka, Redis, Postgres and friends | 4, 6 | Core 03; Event streams; Caching |
| Design docs and explaining trade-offs | 5, 7, 9 | Core 08 (ADR); every capstone's design doc |

### What this tells us

- **The plan's emphasis holds.** Every ask has a home. "Use AI tools and check what they produce" appears in four of ten (Datadog: "validate, critique, and refine AI-generated output"), which backs the Blueprint's purpose.
- **Go/Rust is a real pairing.** Cloudflare's posting is titled "(Go/Rust)" and asks for "a desire to improve your skills in both".
- **These are senior roles.** Nine of ten are senior or staff; the AWS SDE II (3+ years) is the most junior. A beginner who finishes should aim at junior and new-grad versions of these teams, as `career.md` says, and treat these postings as where the path leads.
- **Gaps found, and what we decided (2026-11-18):**
  1. Postings 4 and 7 (a reliability role and a storage role) ask for Kubernetes and Terraform, which the storage track didn't pull. **Decided:** the storage track now pulls "Kubernetes and delivery" (+5 weeks). "AWS and Terraform" stays optional for storage learners: two postings is thin evidence for 2 more required weeks, and the unit is there to take.
  2. Postings 7, 8 and 10 want C or C++, and core 05 only teaches *reading* C. **Decided:** an optional deep dive, "C for Rust programmers", after core 05.
  3. Posting 9 names Envoy, NGINX, Istio and Cilium. **Decided:** the cloud track's edge-proxy part adds a lesson running Envoy beside the learner's proxy, with the same benchmark, for comparison.

---

## 2. The shape

```text
1 FOUNDATIONS (beginners only, 8 wk)
  Set up your machine → How the machine works → Go from zero → Python and the internet from zero
                                   │
                                   ▼
2 CORE (everyone, 35 wk): Switchyard, a Go control plane running a Rust data plane
  Go runtime & reliable services → Python runtime & honest measurement → Docker & Postgres
  → Rust foundations → Rust for systems → Linux, networking & profiling
  → Distributed-systems fundamentals → Shipping safely
                                   │
         ┌─────────────────────────┼─────────────────────────┐
         ▼                         ▼                         ▼
   AI INFRASTRUCTURE          STORAGE ENGINES           CLOUD & NETWORK
   (~27 wk incl. units)       (~26 wk incl. units)      (~25 wk incl. units)
         └──────────── each pulls the SHARED UNITS it needs ─────────┘

   Coming soon: kernel, embedded, robotics
```

**Time** (12–15 hours a week, as today):

| Who | Path | Weeks |
|---|---|---|
| Beginner, one track | Foundations + core + track | about 68–70 |
| Experienced developer, one track | Test-out + core + track | about 60–62 |
| Each extra track | Its own content, plus any units not yet done | +13–19 |

Today's single route is about 94 weeks. The core's first module was re-estimated at 7 weeks (not 5) once its lessons were listed out (§8), which brings the core to 35.

**Gates:** every core module and track part ends with an automated pass/fail gate, built from today's failure drills (the site's labs). You haven't finished until it passes.

---

## 3. Foundations (beginners, 8 weeks)

| Module | Learn | Build |
|---|---|---|
| **01 Set up your machine** (~45 min) | WSL2 + Ubuntu, macOS, or Linux; Git; Go; VS Code | A Go program printing OS, architecture and CPUs (the Day-1 gate) |
| **02 How the machine works** (2 wk) | Shell, files, permissions, processes; programs vs processes; how CPU, RAM and disk store data; Git | A shell system monitor and log rotator |
| **03 Go from zero** (3 wk) | Variables, types, loops, functions, structs, slices, maps, interfaces, errors, tests, goroutines, channels, `select`, each in small drills | A CLI task engine; a JSON log analyser |
| **04 Python and the internet from zero** (3 wk) | IP, DNS, TCP vs UDP, what a request and response are; Python with uv, types, collections, functions, classes, files, tests, `asyncio` basics, plotting | A raw TCP echo server in Go, plus a Python script that fires 1,000 requests at it and plots latency |

---

## 4. The core (everyone, 35 weeks)

| Module | Learn and build | From today | Gate |
|---|---|---|---|
| **01 Go runtime and reliable services** (7) | Detailed in §8 | Phase 0 steps 3–7; Phase 1; Phase 2 steps 1, 4 (without RabbitMQ) and 6 | 10,000 state changes while workers are killed: converges, race detector clean, no leaked goroutines |
| **02 Python runtime and honest measurement** (2) | The object model, the GIL, how the `asyncio` event loop works; `kload`, an open-loop load generator; percentiles, why averages lie, coordinated omission; repeat runs and confidence intervals | Python Bridge | Prove the load generator isn't the bottleneck |
| **03 Docker and Postgres** (3) | Images, containers, volumes, networks, Compose; schema, migrations, indexes; a Postgres repository behind the same interface as the in-memory one (contract tests); connection pooling, sized then exhausted; transactions; SQL injection | Phase 3's first steps | Contract tests pass on both repositories; pool exhaustion fails cleanly; data survives a container restart |
| **04 Rust foundations** (4) | From "no GC, so who frees memory?" to ownership, borrowing and lifetimes; enums and `match`, `Result`, traits and generics, iterators and closures, collections, smart pointers, modules and Cargo, tests, Clippy, benchmarks. Everything is drawn in memory, and borrow-checker errors are triggered on purpose and read. Build: drills, then `klog` | Rust Bridge | `klog` recovers from torn writes and refuses corruption |
| **05 Rust for systems** (5) | Layout and `repr(C)`; `unsafe` and its rules; reading C and FFI to a C library; `Send`/`Sync`; atomics and memory ordering; async by hand (a `Future` and mini executor, then Tokio, then `Pin`); PyO3; Miri, sanitizers, `cargo-fuzz`, loom. Build: a zero-copy frame parser, an SPSC ring buffer | New | Fuzzing finds no panic; Miri clean (small counts); TSan and loom clean (full counts); FFI clean under ASan |
| **06 Linux, networking and profiling** (5) | Virtual memory, syscalls, the page cache and `fsync`; sockets, the TCP handshake, loss, the bandwidth-delay product, `ss -ti`; epoll vs io_uring; Go profiles, `perf`, flame graphs, `strace`, `bpftrace`; OpenTelemetry basics. Build: the Go ↔ Rust wire over TCP and Unix sockets | Performance Bridge; Networking Bridge's first half; Phase 2 step 7 | Under injected loss and CPU contention: find the CPU bottleneck in a flame graph, fix it, and show the p99 gain |
| **07 Distributed-systems fundamentals** (6) | Failure models, clocks, quorums; your own Raft (elections, log replication, persistence on the Rust log) on a deterministic simulated network; leases and fencing tokens; consistent hashing | Phase 4's first half | `kill -9` mid-write plus a partition: no split-brain, no corrupt records |
| **08 Shipping safely** (3) | What a container is (namespaces and cgroups, by hand); a threat model; authn vs authz; your own CA, TLS and mTLS; secrets kept out of code; least privilege; SLOs, alerts, a runbook and a postmortem; the AI-assisted workflow (draft tests, fuzz harnesses and FFI with AI, then verify every line); an ADR | Parts of Phases 5 and 6 | Inject a fault: the alert fires, the runbook recovers it, and the ADR is defended |

**Optional deep dive, after core 05: C for Rust programmers** (~2 wk, outside the week counts). Writing C, not just reading it: pointers and manual memory, the build (headers, `make`, linking), undefined behaviour shown by ASan and UBSan, then a small C library called from Rust and a Rust library called from C. For the postings that ask for C or C++ (§1).

---

## 5. Shared units (written once; tracks pull what they need)

| Unit | Content | From today | Weeks | Used by |
|---|---|---|---|---|
| **Kubernetes and delivery** | Kubernetes on kind, Services, DNS, a layer-7 balancer, StatefulSets; Helm, safe rollouts, canary; CI/CD that builds once and deploys by digest; SBOMs and signing; Prometheus and Grafana, burn-rate alerts; an autoscaler controller with RBAC; network policy and Pod Security | Phase 5; Phase 6's cluster hardening; Phase 8's supply chain | 5 | All three |
| **AWS and Terraform** | VPC, IAM, ECS on Fargate, RDS, S3, SQS, ALB, CloudWatch, budgets; planned offline, applying it optional | Phase 5 | 2 | Cloud |
| **Messaging and resilience** | RabbitMQ; commands vs events; at-least-once delivery and duplicates; message versioning; dead letters; the circuit breaker | Phase 2 steps 2, 3, 5 | 2 | Cloud |
| **Event streams** | Kafka (partitions, consumer groups, offsets, replay); the transactional outbox and inbox | Phase 3 | 2 | Storage |
| **Caching** | Redis cache-aside, stampede protection, singleflight | Phase 3 | 1 | Storage |
| **Tenancy and abuse control** | Tokens from your own issuer (JWT, JWKS, rotation); authorization policies; tenant isolation down to row-level security; rate limiting, local then distributed | Phase 6 | 3 | All three |

---

## 6. The tracks

| | AI infrastructure | Storage engines | Cloud and network |
|---|---|---|---|
| **Units** | Kubernetes and delivery; Tenancy and abuse control | Kubernetes and delivery; Event streams; Caching; Tenancy and abuse control | Kubernetes and delivery; AWS and Terraform; Messaging and resilience; Tenancy and abuse control |
| **Parts** | **01 ML for infrastructure:** data contract, pipeline to Parquet, training basics in PyTorch, MLOps (registry, promotion, rollback, drift), privacy. **02 Serving and scaling models:** the serving platform, TTFT/TPOT, batching, KV caches, Ray, distributed training, CUDA memory, cost benchmark. **03 A Rust inference gateway:** token streaming, SSE parser, token buckets. **04 Securing the AI layer:** the agent, prompt injection, tool authorization, tenant leaks, cost attacks, AI supply chain. | **01 Postgres in depth:** isolation anomalies, `EXPLAIN ANALYZE`, WAL, B-tree vs LSM, background jobs (`SKIP LOCKED`), backup and restore. **02 Consensus in depth:** snapshots, linearizability checking (Porcupine), TLA+, sharding and rebalancing, 2PC vs sagas. **03 A Rust storage engine:** LSM-tree, SSTables, Bloom filters, compaction, MVCC. **04 Integrity and encryption:** tamper-evident log, encryption at rest, tenant namespaces. | **01 Networking in depth:** congestion control (Reno, CUBIC, BBR), bufferbloat, HTTP/2 and HTTP/3, CDNs, anycast and BGP, partial partitions. **02 A Rust edge proxy:** L4/L7, connection pooling, circuit breaking; then Envoy beside it on the same benchmark. **03 The proxy's control plane:** config push, health checks, mTLS rotation, sidecar, OpenBao, signed webhooks and SSRF, eBPF/XDP. |
| **From today** | Phase 7 (ML parts), Phase 8, Phase 9 | Phase 3 (rest), Phase 4 (rest), Phase 6's audit log | Networking Bridge (rest), Phase 5's impairment, Phase 6 (identity, secrets, webhooks) |
| **Deep dives (optional)** | MapReduce/Spark and COST, backprop by hand, gradient-boosted trees, AIOps, Megatron-style parallelism, the red-team exercise | Event sourcing, Raft vs Paxos/VR | — |
| **Capstone (the last part)** | An OpenAI-compatible inference gateway, benchmarked for TTFT, TPOT and throughput | A distributed KV store, benchmarked with YCSB, with crash-recovery proofs | A programmable edge proxy, benchmarked for requests per second, memory and zero-downtime reloads |
| **Weeks** | 19 + units 8 = ~27 | 15 + units 11 = ~26 | 13 + units 12 = ~25 |

- **Every capstone ships three things:** a public repo (or workplace deployment) with reproducible benchmarks, before-and-after flame graphs, and a design doc or ADR.
- **Deep dives** keep today's heavier material available without putting it on the required path or in the week counts. Each lives in a `deep-dives/` folder beside the modules it extends.
- **Kubernetes is now pulled by all three tracks, but stays a shared unit, not core:** the coming tracks (kernel, embedded, robotics) don't need it.

---

## 7. How every lesson teaches

Each lesson file follows the same outline:

```markdown
# 06 A race a mutex can't fix

> Module: Go runtime and reliable services · Time: ~3 h · Builds on: 05

## The problem            a real failure, in plain English, before any jargon
## The mental model       a diagram of where the bytes and the goroutines are
## The pattern            the named pattern, and what the runtime does underneath
## Build it               5–7 steps, each with:
### Step 1: …               starter code (wiring done, // TODO gaps), the run command,
                            the real expected output, what a failure looks like,
                            and a stuck drawer (hint 1 → hint 2 → collapsed commented answer)
## Check it               the test or measurement that proves this lesson works
## If it goes wrong       the common failures and what they mean
```

- **No syntax before it's taught.**
- **Setup cards** arrive when a tool is first needed, each ending in one verify command.
- **Junior, intermediate and senior expectations** are stated on every module page.
- **Unchanged:** every output is real and captured, and the code lives only in the lesson files, checked by replaying them. There are no solution folders.

---

## 8. Folders and files

### The whole repository

```text
README.md                 what the Blueprint is, who it's for, where to start
JOURNEY.md                the map: every module, unit and track, with time, gate and status
career.md                 the experience you'll have, roles to target, companies in Canada and the USA,
                          job boards, interview prep, optional certificates (learner-facing, no personal details)
1-foundations/
  01-set-up-your-machine/
  02-how-the-machine-works/
  03-go-from-zero/
  04-python-and-the-internet-from-zero/
2-core/
  deep-dives/
    c-for-rust-programmers/     optional, after 05
  01-go-runtime-and-reliable-services/
  02-python-runtime-and-honest-measurement/
  03-docker-and-postgres/
  04-rust-foundations/
  05-rust-for-systems/
  06-linux-networking-and-profiling/
  07-distributed-systems-fundamentals/
  08-shipping-safely/
3-tracks/
  shared-units/
    kubernetes-and-delivery/
    aws-and-terraform/
    messaging-and-resilience/
    event-streams/
    caching/
    tenancy-and-abuse-control/
  ai-infrastructure/
    README.md                   who it's for, the roles it targets, units needed, weeks
    01-ml-for-infrastructure/
    02-serving-and-scaling-models/
    03-rust-inference-gateway/
    04-securing-the-ai-layer/
    05-capstone-inference-gateway/
  storage-engines/
    README.md
    01-postgres-in-depth/
    02-consensus-in-depth/
    03-rust-storage-engine/
    04-integrity-and-encryption/
    05-capstone-distributed-kv-store/
  cloud-and-network/
    README.md
    01-networking-in-depth/
    02-rust-edge-proxy/
    03-proxy-control-plane/
    04-capstone-programmable-edge-proxy/
  coming-soon.md                kernel, embedded, robotics
dsa/                      kept in Go and Python; adds systems data structures
system-design/            kept; adds the three worked designs
math/                     kept; adds capacity framing
scripts/                  rewritten (below)
site/
```

**Naming rules:**
- Numbered prefixes (`1-`, `2-`, `3-`, then `01-`…) only where order matters, so GitHub lists folders in study order.
- Shared units and tracks aren't numbered: you pick them, you don't follow them in sequence.
- Every name is plain words for what you learn or build, in lowercase-with-hyphens.

**Removed:**
- `lessons/` (emptied into the new folders), `capstones/` (briefs and KESTREL), `open-source/`.
- `notes/`. Its per-phase self-tests merge into each module's `self-check.md`. `decisions.md`, `failures.md` and `research-track.md` leave the repo; they remain in git history, and you may want a private copy of `research-track.md`.
- **Site navigation becomes:** *Journey · Ownership · DSA · Design · Maths*. Capstones live in their tracks; labs become gates.

### Every module has the same files

```text
NN-module-name/
  README.md          the module page: what you'll learn, what you'll build, time, what it builds on,
                     the gate, and what junior / intermediate / senior looks like here
  lessons/
    NN-lesson-name.md  one file per lesson, in order (the outline in §7)
  gate/
    README.md        what the gate checks, how to run it, what a pass looks like
    run.sh           the automated check, run against the learner's own code
  exercises.md       separate practice projects, each with a finished-state spec
  self-check.md      explain-it questions per lesson + a from-memory test (today's learned.md
                     and notes/learned/ merged)
  evidence/          real outputs captured while building the lessons; reports for long runs
```

Today's single `TEACHING.md` per phase (Phase 2's is over 6,000 lines) becomes one file per lesson. The site already splits guides into step pages, so it maps across directly.

### Sample: `2-core/01-go-runtime-and-reliable-services/`

```text
01-go-runtime-and-reliable-services/
  README.md
  lessons/
    01-how-go-runs-your-code.md               new: G-M-P scheduler, goroutine stacks, escape analysis, GC pacing
    02-a-server-from-a-raw-socket.md          new: net.Conn, reading bytes, framing, before net/http
    03-an-http-service-with-a-contract.md     Phase 0 steps 3–5: server, response contract, routing, validation
    04-tests-at-three-levels-and-ci.md        Phase 0 steps 6–7
    05-the-domain-written-test-first.md       Phase 1 step 1
    06-a-repository-and-your-first-data-race.md   Phase 1 step 2
    07-a-race-a-mutex-cant-fix.md             Phase 1 step 3: check-then-act, compare-and-swap
    08-the-http-api.md                        Phase 1 step 4
    09-wiring-and-configuration.md            Phase 1 step 5: composition root, functional options
    10-deadlines-and-cancellation.md          Phase 1 step 6
    11-logs-metrics-and-panic-recovery.md     Phase 1 step 7
    12-signals-and-graceful-shutdown.md       Phase 1 step 8
    13-worker-pools-and-backpressure.md       Phase 2 step 1: bounded pool, Little's law
    14-timeouts-retries-and-idempotency.md    Phase 2 steps 4–5, reworked without RabbitMQ
    15-grpc-and-protocol-buffers.md           Phase 2 step 6
    16-the-reconciliation-loop.md             new: desired state vs actual, the loop behind Kubernetes controllers
  gate/
    README.md
    run.sh            starts the learner's service, issues 10,000 state changes, kills workers at random,
                      then checks: converged state, `go test -race` clean, goroutine count back to baseline
  exercises.md        tempconv (from Phase 0), shortlinks (from Phase 1)
  self-check.md
  evidence/
```

Phase 0's steps 0–2 (the terminal, a program and a process, requests and responses) move to Foundations 02 and 04.

### Scripts

```text
scripts/
  replay_lessons.py     was check_guides.py: rebuilds every lesson's code from its markers and runs its checks
  check_all.sh          was test_all.sh: everything CI runs, over the new folders
  check_links.py        new: every relative link and replay path resolves (essential while files move)
  templates/
    module-readme.md    the module page outline
    lesson.md           the §7 lesson outline
    gate-readme.md      the gate page outline
```

Changes to the replay tool:
- It reads a module's `lessons/` files in order, instead of one `TEACHING.md`.
- `continue:` points at a module folder. Every shared unit and track part continues from the end of the core, which everyone has. That's what lets a storage learner start "Event streams" without having done "Messaging and resilience".
- It caches each module's finished build, so a track doesn't rebuild the whole core every time it's checked.

The site's content loader (`site/src/lib/links.ts`) and CI (`.github/workflows/lessons.yml`) change in the same batch as the folders.

---

## 9. How we approach the rebuild

### Kinds of work

- **Move:** a guide relocates whole. Its code and outputs are untouched; paths are fixed, and the replay proves it still works.
- **Split:** a guide is cut across several homes (Phase 2 goes to core 01, core 06 and "Messaging and resilience"). Today's guides build on one growing codebase, so each piece is re-based onto its new starting point (the end of the core, for units and tracks), rebuilt, re-captured and replayed on its own.
- **New:** written from scratch: fresh code, freshly captured outputs.

### Where the work happens

- **One branch, `restructure`.** Everything lives there until every batch is done and reviewed; only then does it merge into `main`. Until then `main` keeps today's Blueprint as it is.
- **A step map**, made in batch 1, lists every step of every current guide and its new home (lesson file, unit, deep dive). A guide's old folder is deleted only when every one of its steps is marked done. This is how we prove nothing was lost.

### The cycle for every module, unit and track part

1. **Outline, then stop.** The module page and the list of lessons: what each teaches, what it builds, which old steps it takes, and the gate. **You review it before any code is written.** Questions get asked here.
2. **Build the code** in `~/blueprint-scratch/<module>`, one snapshot per lesson step.
3. **Capture real outputs** in a fresh environment. Steps that need a GPU, root, Kubernetes or a cloud account are documented with their expected output for the learner to run (as today).
4. **Write the lessons** from the snapshots, using the §7 outline and the replay markers.
5. **Build the gate,** and check it both ways: it passes on the reference build and fails on a deliberately broken one.
6. **Write `exercises.md` and `self-check.md`.**
7. **Replay the whole module once,** check the links, and get CI green.
8. **Review stop.** You read it. Nothing starts on the next module until this one is accepted.

### Batches

| Batch | Work | Kind |
|---|---|---|
| 0 | Real postings (5–10, linked and dated) mapped to modules. Housekeeping: commit Phase 9 and the agent lab. Create the `restructure` branch. `career.md` is tracked there (already rewritten for learners on 2026-11-18); its links to modules are added in batch 1. | Research |
| 1 | The scripts (replay over lesson files, link checker, templates, cache); the folder skeleton with module pages; the step map; whole-guide moves; site loader and CI on the new paths; new JOURNEY.md; remove `capstones/`, `open-source/`, `notes/`. **CI must be green.** | Move |
| 2 | Foundations 01–04 | New (+ Phase 0 steps 0–2) |
| 3 | Core 01 Go runtime and reliable services | Split + new |
| 4 | Core 02 Python runtime and honest measurement | Move + new |
| 5 | Core 03 Docker and Postgres | Split + new |
| 6 | Core 04 Rust foundations | New, around `klog` |
| 7 | Core 05 Rust for systems, then the optional deep dive "C for Rust programmers" | New |
| 8 | Core 06 Linux, networking and profiling | Move + split + new |
| 9 | Core 07 Distributed-systems fundamentals | Split + new |
| 10 | Core 08 Shipping safely | Split + new |
| 11 | The six shared units | Split |
| 12 | AI infrastructure track | Move (Phases 8–9) + split (Phase 7) + new (Rust gateway) |
| 13 | Storage engines track | Split + new |
| 14 | Cloud and network track | Split + new |
| 15 | Add systems data structures, worked system designs, capacity planning, and production ownership. Keep DSA in Go and Python. Use Rust where the lesson depends on Rust-specific behavior or extends an existing Rust component. | New |
| 16 | Site: navigation, landing page, Journey with tracks and gates, lesson pages, labs as gates. Close out the migration and remove the old top-level `lessons/` before merging. | New + migration closeout |
| — | Merge `restructure` into `main`, once every batch above is done and reviewed | — |

### Batch 15 additions

| Area | What to add | How to check it |
|---|---|---|
| DSA | Add a bounded ring buffer and a Bloom filter as worked problems in Go and Python. Link each to the corresponding Rust component in Switchyard. Keep the existing token bucket and consistent-hash ring in the design guide. | Replay both languages. Check FIFO order, wraparound, and full and empty behavior. Verify that every inserted Bloom-filter key is present and measure false positives on a fixed set of absent keys. |
| System design | Extend the existing inference gateway and key-value store writeups, and add a programmable edge proxy design. Use each capstone's actual interfaces, guarantees, and evidence. Cover one consequential design tradeoff and one failure timeline per system. | Use the existing scorecard. Trace each failure timeline to capstone evidence and check that each measured claim states its workload and scope. |
| Maths | Add a capacity-planning guide. Calculate request concurrency, replica counts with headroom, and capacity after losing one replica. Use a Python worksheet with units and a prediction checked against a captured run. | Replay calculations for steady load, bursts, and replica loss. Compare predicted and observed values and explain where the model's assumptions break down. |
| Production ownership | Add a short guide that takes a reader from an SLO alert through triage, mitigation, handoff, and a postmortem. Reuse the Core 08 game day and one capstone fixture. | Run a tabletop exercise against recorded evidence. Require a timeline, a mitigation and rollback decision, and follow-up actions with owners and verification criteria. |

Go and Python are the default for the new examples. Link to the existing Rust components when they illustrate a concept. Add Rust code where a lesson depends on Rust-specific behavior or extends one of those components.

### Batch 16 site and migration checks

| Area | What to build | How to check it |
|---|---|---|
| Landing page and navigation | Update the existing Astro site. Show the learner entry points and use Journey, Ownership, DSA, Design, and Maths as the primary navigation. | Follow the beginner, experienced-developer, and interview-preparation paths from the landing page. Check desktop and narrow navigation. |
| Journey and lessons | Show Foundations, Core, shared units, and the three tracks. Link each module to the first lesson and its gate where available. Keep lessons, exercises, and self-checks reachable from their module. | Build the static site and check course, lesson, capstone, and gate links, including the beginner DSA and design guides. |
| Interactive labs | Connect each useful interactive lab to the relevant module gate or exercise. Keep existing lab URLs working while changing how learners discover them. | Check every existing lab route and the corresponding gate link. Run the existing site and simulation tests. |

#### Legacy removal inventory

| Path | Disposition |
|---|---|
| `capstones/`, `notes/`, `open-source/` | Their old top-level copies are already removed from the working tree. Capstones live under their tracks. Retain the relocated self-tests and migration records. |
| `lessons/00-request-service/`, `lessons/python-bridge/`, `lessons/perf-bridge/`, `lessons/08-ai-infrastructure/`, `lessons/09-secure-ai-layer/` | Their old locations are already gone. The content that moved lives under Foundations, Core, or the AI track. |
| `scripts/test_all.sh`, `scripts/check_guides.py` | Already renamed to `scripts/check_all.sh` and `scripts/replay_lessons.py`. Current learner commands use the new scripts. Captured historical output stays with its evidence. |
| `lessons/01-reliable-service/` through `lessons/07-utility-evaluation/`, and `lessons/rust-bridge/` | Removed from the working tree after the replacement replays passed. The historical replay chain is available in Git history. |
| `lessons/network-bridge/` | Removed from the working tree. The networking module holds the replacement lessons, exercises, and review prompts. Legacy site URLs redirect to their new destinations. |
| `site/src/pages/labs/` and its simulation code | Keep for the gate integration. Existing lab URLs and interactive behavior still serve learners. |

#### Close out the legacy lesson migration

Batch 16 is complete when the old top-level `lessons/` is gone and the curriculum runs from its new locations. The `lessons/` directories inside individual modules are the new type-along guides and are part of the final layout.

1. Reconcile the remaining migration rows with the modules already built. Move outstanding exercises, self-tests, and supporting fixtures. Give the remaining privacy and optional AI deep-dive material a home in the appropriate track. Record the actual destinations in the [migration map](step-map.md).
2. Repoint learner-facing links and replay markers to the new homes. Replace the legacy replay chain through Phases 1–7, including the Phase 3 dependency on the Rust Bridge. Check references from the site, design and maths guides, and CI.
3. Verify in a clean checkout with the top-level tree absent. Run the full curriculum checks, build the Astro site, run its tests and link check, and check the learner paths. Update replay discovery and CI to use the final layout. Preserve public legacy URLs through redirects where there is a corresponding new page.
4. Remove the old top-level tree on `restructure` once the checks pass, then verify the resulting diff and CI before merging. Git history preserves the original files. All 29 local replay targets passed without the old tree across the baseline and targeted runs. The Astro build, tests, browser checks, and internal links passed with the old tree absent. The final site build verified 268 redirects. Remote CI and merge remain separate.

---

## 10. Decided late (2026-11-18)

| # | Question | Decision |
|---|---|---|
| Q1 | **Renaming Runway → Switchyard in the code.** Code names appear in captured outputs, so renaming them means re-capturing. | Rename in prose everywhere; rename in code when each guide is split or rebuilt. Whole-guide moves (Phases 8–9) keep `runway` in code until they're next rebuilt. |
| Q2 | **Test-out gate** for experienced developers skipping Foundations | One timed task: a small Go CLI with tests, and a Python script that calls it. Built in batch 2. |

## 11. Fixes to carry from the brainstorm

1. Broken install URLs (Go, Homebrew, uv, rustup): use the official commands and pin current versions.
2. Unsourced salaries and company quotes: replace with real postings, or drop.
3. Miri is too slow for a million operations: small counts under Miri, full counts under TSan and loom.
4. Packet loss can't be fixed in code: the networking gate measures the CPU fix under the same loss.
5. The site is Astro, not Next.js.
6. The sample parser test uses `unsafe` needlessly: use `raw[9..].as_ptr()`.
