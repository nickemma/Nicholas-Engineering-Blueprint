# The Blueprint journey

This is a complete path from beginner to advanced systems engineering. You learn it by building one real system, **KESTREL**, one phase at a time. Every phase is taught end to end with working, tested code.

This is the **only roadmap** in the repository. Everything else is a lesson (`lessons/`), interview practice (`dsa/`, `system-design/`), or a personal note (`notes/`).

**Contents**

1. [Who this is for](#1-who-this-is-for)
2. [What we're building and why](#2-what-were-building-and-why)
3. [How to study](#3-how-to-study)
4. [The route](#4-the-route)
5. [Foundation-gap ledger](#5-foundation-gap-ledger)
6. [Patterns ledger](#6-patterns-ledger)
7. [Languages and tools](#7-languages-and-tools)
8. [Parallel tracks: DSA, system design, writing](#8-parallel-tracks-dsa-system-design-writing)
9. [Reading index](#9-reading-index)
10. [Timeline and progress tracker](#10-timeline-and-progress-tracker)
11. [Career map](#11-career-map)

---

## 1. Who this is for

- **Complete beginners.** Phase 0 assumes no Go, no Linux and no HTTP. Each idea is explained before it is used.
- **Working engineers** who want to relearn the foundations properly, in order, with evidence.
- **Anyone reading the author's code.** Each phase is the reference implementation that the author's own projects build on, so working through a phase is the fastest way to understand them.

By the end you will be able to design, build, test, operate, secure, measure and explain a distributed system. You will have a public portfolio of evidence for each claim, and practice for the coding and system-design interviews that roles in this space use.

It is **not** a checklist of technologies, a clinical product, or a promise of a job. Phases end when their evidence is in place, not when a calendar says so.

**Time:** about 59 weeks at 12–15 focused hours a week (see [§10](#10-timeline-and-progress-tracker)). Experienced engineers often move faster through Phases 0–2.

---

## 2. What we're building and why

### The problem

Small community health organisations need to coordinate around shared information. Their records are sensitive, their infrastructure is limited, and their internet connections drop. A central service may be unreachable during an outage, or may require them to give up control of their data.

**KESTREL** is a research prototype that asks:

> How can small, resource-constrained health organisations produce timely and trustworthy cross-site summaries when records remain under local control and network connectivity is intermittent?

That question forces a real trade-off between **freshness, availability, latency, bandwidth, privacy and operator effort**. No design wins on all six, and the project measures the trade-offs instead of claiming one design is best.

### Who it would serve

| Group | What they need |
|---|---|
| Community health workers and local organisations | Useful shared summaries without sending every record to one central service |
| Data stewards | Control over which questions can be asked, by whom, and what leaves each site |
| Operators | A system that recovers from outages and explains what happened while disconnected |
| Researchers and reviewers | Reproducible evidence about guarantees, failures, privacy limits and real usefulness |

The system makes **no** diagnoses and does not replace clinical judgement. It uses **synthetic or public data only**. Real data would need partners, consent, a security review and research-ethics approval.

### The system you will build

~~~mermaid
flowchart LR
    Q[Authorised summary question]
    NET[Intermittent, constrained links]

    subgraph A[Site A: records stay local]
      APIA[Go API] --> QA[Bounded queue]
      QA --> WA[Worker]
      WA --> DBA[(PostgreSQL)]
      DBA --> LOGA[Rust audit log]
      DBA --> SUMA[Approved summary]
      PA[Identity and policy] --> APIA
    end

    subgraph B[Site B: records stay local]
      APIB[Go API] --> QB[Bounded queue]
      QB --> WB[Worker]
      WB --> DBB[(PostgreSQL)]
      DBB --> LOGB[Rust audit log]
      DBB --> SUMB[Approved summary]
      PB[Identity and policy] --> APIB
    end

    Q --> NET
    NET --> PA
    NET --> PB
    SUMA --> NET
    SUMB --> NET
    NET --> RESULT[Minimum approved cross-site answer]
    RESULT --> Q

    R1[Raft node 1] <--> R2[Raft node 2]
    R2 <--> R3[Raft node 3]
    R3 <--> R1
    R1 -. coordination metadata only .- PA
    R2 -. coordination metadata only .- PB

    OBS[Containers, Kubernetes, metrics, logs, traces, runbooks] -. operates .-> A
    OBS -. operates .-> B
    ML[Phase 7 forecast model: trained on approved aggregates only] -. evaluated against a simple baseline .-> RESULT
~~~

This is the target, not a promise that every box belongs in the final design. For example, Phase 4 teaches replicated metadata, but whether KESTREL needs it on the query path must be justified by measurements. PostgreSQL stays the source of truth, and the Rust log is a focused audit and storage experiment. The ML model sees only approved aggregates, never source records, and it has to beat a simple baseline to earn its place.

### Ground rules the code follows

Security and privacy are design constraints from Phase 0, not features added at the end. The implementation must:

- deny access unless a site and user have explicit permission;
- keep source records under the authority of the site that collected them;
- release only the minimum approved answer to a cross-site query;
- authenticate the communicating sites and protect data in transit;
- record who asked what, which policy applied, what was released, and when;
- fail closed: refuse protected operations when identity or policy can't be checked;
- test allowed use, denied use, and attempts to bypass the enforcement path.

These controls reduce risk. They do not prove that aggregates are harmless or that a deployment complies with health-privacy law. Inference from repeated queries, compromised endpoints and operator mistakes stay in the threat model, and every report states those limits.

### What counts as success

The project succeeds if another person can **reproduce its experiments and judge its claims**. The final report covers:

- which data and queries are synthetic, public or approved;
- freshness and availability during disconnection and recovery;
- latency and bandwidth across realistic network conditions;
- what each role can access, and what can leak through aggregate answers;
- how operators detect, recover from and audit failures;
- limitations, negative results, and cases where the simple centralised baseline wins.

A demo that works is not a result. Each major feature answers a question, compares against a baseline, and keeps enough evidence to rerun.

---

## 3. How to study

### What is in a lesson

~~~text
lessons/03-durable-auditable-data/
  README.md       the syllabus: what the phase covers, outcomes, prerequisites, the exercise project
  TEACHING.md     the lesson: explanations plus a type-along build, with the code inline
  exercises.md    a different project you build alone, with a clear picture of the finished result
  learned.md      your answer sheet: explanations plus evidence
~~~

### The step loop

Every step in every TEACHING.md has the same parts. [Phase 0](lessons/00-request-service/TEACHING.md) is the model.

| Part | Purpose |
|---|---|
| **The problem** | What is missing or broken without this step |
| **New ideas** | Every new term, defined before you use it |
| **The code** | Shown inline: the whole file the first time, then exact edits. You type it. CI rebuilds the code from the guide with [scripts/check_guides.py](scripts/check_guides.py), so every step is known to work |
| **Run it** | Exact commands and real expected output |
| **Break it** | A deliberate mistake: predict, run, explain |
| **Explain it** | Questions you answer in learned.md, with evidence |
| **Read** | One specific chapter, placed after you've felt the problem |

Two labels tell you how each step is verified:

- **Checked in CI.** The step's code is built and tested on every push, so it is known to work.
- **Run locally.** The step needs something CI can't provide, such as your GitHub account, a Kubernetes cluster, `sudo` network tools or a cloud account. The guide gives the exact commands and what you should see. If yours differs, the guide explains how to diagnose it.

### The rebuild rule

You follow each lesson in a scratch `practice/` folder, which Git ignores. Then, at the end of each phase, you **close the guide and rebuild the phase in your own `kestrel` repository** from the contract tables and your notes. Looking up language and library documentation is allowed; copying lesson code is not. Your repository grows phase by phase into your own KESTREL, with its own CI history.

If you can rebuild it, you understand it. If you get stuck, the place you got stuck is exactly what to review.

### What "done" means for a phase

1. It runs from a clean checkout of **your** repository, and CI is green.
2. You can explain its data flow without notes.
3. You reproduced at least one relevant failure and can explain it.
4. You can point to evidence for each guarantee it claims.
5. You can name one trade-off you made and what you gave up.
6. learned.md is complete.

### A week, roughly

| Hours | Activity |
|---|---|
| ~9 | The current phase: build, break, test, explain |
| ~3 | DSA: three 45–60 minute sessions ([dsa/](dsa/README.md)) |
| ~1.5 | One system-design session, from Phase 2 on ([system-design/](system-design/README.md)) |
| ~1 | Reading and writing notes |

### What to install, and when

| Before | Install |
|---|---|
| Phase 0 | Go 1.26+, Git, curl, an editor (VS Code with the Go extension). On Windows, use WSL |
| Phase 1 | [`oha`](https://github.com/hatoo/oha) or [`hey`](https://github.com/rakyll/hey) for load testing |
| Python Bridge | [`uv`](https://docs.astral.sh/uv/), which also installs Python |
| Phase 2 | Docker Engine or Docker Desktop with Compose, `tcpdump`, [`grpcurl`](https://github.com/fullstorydev/grpcurl), [`buf`](https://buf.build/docs/installation); Wireshark is optional |
| Rust Bridge | [`rustup`](https://rustup.rs/) |
| Phase 3 | The `psql` client and [`goose`](https://github.com/pressly/goose). PostgreSQL itself runs in Docker |
| Phase 4 | Java 17+ and the [TLA+ tools](https://github.com/tlaplus/tlaplus/releases) (or the VS Code TLA+ extension) |
| Phase 5 | [`kind`](https://kind.sigs.k8s.io/), `kubectl`, [`helm`](https://helm.sh/), [`terraform`](https://developer.hashicorp.com/terraform/install), [`k6`](https://k6.io/) |
| Phase 7 | Python ML libraries, installed through `uv` in the lesson. No GPU is needed |
| Phase 8 | `govulncheck`, [`trivy`](https://trivy.dev/), [`syft`](https://github.com/anchore/syft), [`cosign`](https://docs.sigstore.dev/) |

---

## 4. The route

~~~mermaid
flowchart LR
    P0[0 Request] --> P1[1 Reliable service] --> PY[Python Bridge] --> P2[2 Connected services]
    P2 --> RB[Rust Bridge] --> P3[3 Durable data] --> P4[4 Replicated state]
    P4 --> P5[5 Operate] --> P6[6 Safe queries] --> P7[7 Evaluate + applied ML] --> P8[8 Capstone]
    DSA[dsa/ from Phase 0] -.-> P8
    SD[system-design/ from Phase 2] -.-> P8
~~~

| Phase | Question | You build | Weeks | Status |
|---|---|---|---|---|
| [0. Make one request work](lessons/00-request-service/README.md) | What happens between a command and an answer? | A Go HTTP service with validation, tests and CI | 2 | **Ready** |
| [1. Make one service reliable](lessons/01-reliable-service/README.md) | What happens when requests overlap, stall, or the process stops? | A layered jobs API: repository, DI, races, timeouts, graceful shutdown, metrics | 4 | **Ready** |
| [Python Bridge](lessons/python-bridge/README.md) | How do I measure what I built? | A Python load generator and latency analysis against Phase 1 | 2 | **Ready** |
| [2. Connect services](lessons/02-connected-services/README.md) | What changes across process and network boundaries? | API, RabbitMQ and a worker; event-driven design, idempotency, retries, gRPC | 4 | **Ready** |
| [Rust Bridge](lessons/rust-bridge/README.md) | What do bytes, memory and ownership really look like? | Binary records with checksums; thread safety the compiler enforces | 3 | Being rebuilt |
| [3. Make data durable and auditable](lessons/03-durable-auditable-data/README.md) | What survives a crash? | A Postgres repository behind the same interface, transactional outbox, Rust audit log, restore drill | 6 | Being rebuilt |
| [4. Replicate state through failure](lessons/04-replicated-state/README.md) | What can three nodes agree on when things fail? | Your own Raft, a deterministic simulation harness, linearizability checks, a TLA+ model | 10 | Being rebuilt |
| [5. Operate under constraints](lessons/05-constrained-operations/README.md) | Can you deploy, observe, diagnose and recover it? | Containers, Kubernetes on kind, Terraform, OpenTelemetry, SLOs, network impairment, game day | 8 | Being rebuilt |
| [6. Enforce safe shared queries](lessons/06-safe-shared-queries/README.md) | Who may ask what, and what can an answer reveal? | Authentication, policy, CQRS summaries, scatter-gather queries, audit, inference tests | 6 | Being rebuilt |
| [7. Evaluate, then add applied ML](lessons/07-utility-evaluation/README.md) | Does it help enough to justify its cost? Does a model beat the baseline? | A reproducible experiment; a forecasting pipeline with MLflow, served by FastAPI behind the Go gateway | 8 | Being rebuilt |
| [8. Defend the design](lessons/08-research-capstone/README.md) | Can someone else reproduce and challenge it? | Hardening, mTLS, SBOM and signing, fuzzing, a threat model, a report | 6 | Being rebuilt |

"Being rebuilt" means the phase's README and TEACHING.md are still outlines. Each one is being rewritten as a full type-along guide, to the Phase 0 standard.

### Phase 0: Make one request work

- **Build:** a Go HTTP service with `/`, `/greet` and `/health`, input validation, three levels of tests, and CI in your own repository.
- **Learn:** programs vs processes; ports; HTTP methods, status codes and headers; how the router picks a handler; JSON; validation; `httptest`.
- **Patterns:** guard clauses, table-driven tests, TDD.
- **Exit proof:** show 200/400/404/405 with curl; explain the request path; show a red-then-green test and CI run.
- **Career signal:** backend foundations.
- **Why next:** one endpoint that works is not a service that survives real traffic.

### Phase 1: Make one service reliable

- **Build:** a jobs API (`POST /jobs`, `GET /jobs/{id}`, `POST /jobs/{id}/complete`), layered as handler → service → domain → repository. It uses an in-memory repository behind an interface, with dependencies wired in `main`.
- **Learn:**
  - designing a contract and errors;
  - `context`, timeouts and cancellation;
  - goroutines, shared memory, mutexes and data races;
  - configuration from the environment;
  - structured logs (`log/slog`) and Prometheus metrics;
  - graceful shutdown on SIGTERM;
  - processes, signals and file descriptors at the OS level.
- **Patterns:**
  - TDD as the default;
  - repository;
  - dependency injection (constructor injection plus a composition root);
  - middleware/decorator;
  - functional options;
  - tactical DDD (entity, value object, invariants that live in the domain);
  - a state machine for the job lifecycle.
- **Exit proof:** a race caught by `go test -race` and then fixed; the timeout path; shutdown under load with a record of which requests finished; a note on what disappears at restart.
- **Career signal:** backend reliability, plus first SRE vocabulary (golden signals, timeouts).
- **Why next:** you can't improve what you can't measure, and everything still lives in one process.

### Python Bridge (between Phases 1 and 2)

- **Build:**
  - an async load generator in Python (`httpx`, `asyncio`) that drives the Phase 1 API;
  - a script that turns raw latencies into percentiles (p50/p95/p99) and plots;
  - pytest tests for both.
- **Learn:** Python syntax and types, virtual environments with `uv`, packages, pytest, async I/O, pandas basics, why averages hide tail latency.
- **Why here:** from Phase 2 on, every experiment (retries, crashes, partitions, network impairment) is driven and analysed with Python. Phase 7 builds the ML pipeline on this base.

### Phase 2: Connect services

- **Build:** the API publishes work to RabbitMQ and a separate worker consumes it. Versioned event envelopes travel between them, and an idempotency key makes retries safe. The phase also includes:
  - a bounded queue that pushes back with `429`;
  - a circuit breaker;
  - the same call done with gRPC/Protobuf for comparison;
  - a packet capture of one request.
- **Learn:**
  - client/server and process boundaries;
  - sockets, the TCP handshake, UDP vs TCP, ports and DNS;
  - delivery guarantees (at-most-once, at-least-once, and "exactly once in effect");
  - schema evolution;
  - RPC vs messaging;
  - service identity as the first trust boundary.
- **Patterns:**
  - event-driven architecture (commands vs events, work queue vs pub/sub);
  - strategic DDD (bounded contexts: Intake, Processing, Sharing);
  - idempotency key;
  - retry with exponential backoff and jitter;
  - circuit breaker;
  - bulkhead/backpressure;
  - worker pool.
- **Exit proof:** kill the worker mid-job, restart it, and show the job completed exactly once in effect; capture the request's packets; show overload being refused, not queued forever.
- **Career signal:** the distributed-systems basics interviews start with.
- **Why next:** the queue and the job state are still volatile.

### Rust Bridge (between Phases 2 and 3)

- **Build:** a CLI that writes and reads a binary record file; a record format with a CRC32C checksum; a multi-threaded counter that the compiler refuses to let you break.
- **Learn:** ownership, borrowing and lifetimes; `Result` errors; traits and generics; `Send`/`Sync`; stack vs heap; what `unsafe` means, and why you'll avoid it; virtual memory.
- **Why here:** Phase 3 is where bytes on disk, memory layout and `fsync` matter, and Rust makes all three explicit.

### Phase 3: Make data durable and auditable

- **Build:**
  - a Postgres repository that implements the **same interface** as Phase 1's in-memory one. The same contract tests pass against both, and the handlers don't change at all;
  - migrations with goose;
  - a transactional outbox that feeds Phase 2's broker;
  - a Rust append-only audit log with crash recovery and compaction;
  - a backup-and-restore drill.
- **Learn:**
  - schema design and constraints;
  - transactions and isolation levels, with anomalies you reproduce;
  - indexes and `EXPLAIN ANALYZE`;
  - write-ahead logging, the page cache and `fsync`;
  - crash consistency;
  - B-trees vs LSM trees;
  - SQL injection and parameterised queries.
- **Patterns:**
  - repository (now paying off);
  - contract tests;
  - unit of work;
  - aggregates and domain events;
  - transactional outbox;
  - event sourcing (the audit log);
  - snapshot and compaction.
- **Exit proof:** kill the process during writes to both Postgres and the Rust log, then recover a consistent state; a measured index decision; a restore to a second database.
- **Career signal:** storage/database (application side) and systems-software credibility.
- **Why next:** one machine can still die with the data on it.

### Phase 4: Replicate state through failure

- **Build:**
  - **your own Raft** in Go: elections, log replication, persistence, snapshots;
  - a deterministic simulated network that can drop, delay, reorder and partition messages, for repeatable failure tests;
  - Porcupine checks on client histories, to confirm linearizability;
  - a TLA+ model of one safety property;
  - a three-node metadata store on top.
- **Learn:**
  - system and failure models (crash vs Byzantine);
  - failure detection;
  - physical and logical clocks;
  - quorums;
  - consistency models (linearizable, serializable, eventual);
  - Raft, Paxos and Viewstamped Replication compared;
  - partitioning;
  - two-phase commit vs sagas;
  - FLP and CAP, stated precisely.
- **Patterns:** replicated state machine, leader election and leases, snapshot plus log compaction, deterministic simulation testing.
- **A note on the MIT 6.5840 labs:** they're excellent for extra practice, but do them in a **private** repository. MIT asks students not to publish lab solutions. The Raft built in this repository is independent of the lab's code.
- **Exit proof:** randomised partition and crash runs that pass; Porcupine confirms hundreds of histories; a written report on one bug the tests found; a TLC counterexample connected to the fix.
- **Career signal:** core Distributed Systems Engineer evidence, and the strongest research sample before an MSc.
- **Why next:** it's correct on your laptop; now run it where people could depend on it.

### Phase 5: Operate under constraints

- **Build:**
  - multi-stage container images;
  - a local Kubernetes cluster on kind, with Deployments, a StatefulSet for the Raft nodes, and Services;
  - a Helm chart;
  - a `terraform plan` for a cloud version (applying it is optional and costs money);
  - a GitHub Actions pipeline that builds, scans and deploys to kind;
  - OpenTelemetry traces, Prometheus metrics and Grafana dashboards;
  - an SLO with a burn-rate alert;
  - delay, loss and bandwidth limits between sites, applied with `tc netem` in network namespaces;
  - a game day and a postmortem.
- **Learn:**
  - containers as processes (namespaces, cgroups);
  - Kubernetes objects and control loops;
  - IP, subnets, NAT, load balancing and DNS in practice;
  - the USE method and profiling;
  - SLOs and error budgets;
  - incident response.
- **Patterns:** reconciliation loop (you write a tiny controller), sidecar, liveness vs readiness checks, canary rollout, twelve-factor config.
- **Run locally:** kind, `sudo` network namespaces and cloud steps are mapped in the guide with expected output for you to run.
- **Exit proof:** recreate the deployment from scratch; diagnose an injected incident from dashboards only; publish the postmortem; report repeated latency, availability and bandwidth measurements.
- **Career signal:** SRE, Platform, DevOps and Cloud/Infrastructure. This is the point to start applying seriously.
- **Why next:** the platform runs general services; now decide what sites may share.

### Phase 6: Enforce safe shared queries

- **Build:**
  - per-site identity (OIDC-style tokens verified locally, and mTLS between sites);
  - a policy decision point checked by every handler;
  - approved summaries kept as CQRS read models;
  - scatter-gather queries across sites, with a minimum group size and Laplace noise;
  - replay protection;
  - a hash-chained audit trail.
- **Learn:**
  - authentication vs authorisation;
  - least privilege and purpose limitation;
  - TLS and PKI;
  - the OWASP API Top 10;
  - inference from aggregates and repeated queries;
  - fail-closed behaviour when identity, policy or a site is unavailable.
- **Patterns:** policy enforcement and decision points, CQRS and read models, materialised views, scatter-gather, API gateway, token-bucket rate limiting.
- **Exit proof:** tests for allowed, denied, expired, replayed and repeated-query cases; an audit record for each decision; a written analysis of what each site learns and what remains exposed.
- **Career signal:** infrastructure security and privacy-engineering foundations.
- **Why next:** correct enforcement doesn't show that the system helps anyone.

### Phase 7: Evaluate, then add applied ML

- **Part A, evaluation:**
  - a reproducible experiment comparing a centralised baseline with the local-first design;
  - impaired networks and controlled faults;
  - Python scripts that regenerate every table and plot from raw data.
- **Part B, applied ML:**
  - forecast next week's demand per site from **approved aggregates only** (synthetic data);
  - a naive baseline first, then scikit-learn, then a small PyTorch model;
  - MLflow tracking and a model registry;
  - a FastAPI inference service behind the Go gateway;
  - offline vs online evaluation, a shadow deployment and a drift check;
  - measuring what training on noised aggregates costs in accuracy.
- **Learn:**
  - hypotheses and fair baselines;
  - workload design;
  - train/validation/test splits and time-series leakage;
  - error metrics;
  - train/serve skew;
  - model versioning;
  - the privacy cost of a model.
- **Patterns:** feature pipeline with train/serve parity, model registry, shadow deployment, gateway in front of model serving.
- **Exit proof:** someone else reruns the experiment and gets your tables; the model either beats the baseline or the report says it didn't, and why.
- **Career signal:** applied systems research, ML infrastructure/MLOps, and an introduction to applied ML.
- **Why next:** consolidate everything into claims someone else can challenge.

### Phase 8: Defend the design

- **Build:**
  - a hardened prototype: mTLS everywhere, secrets handling and least-privilege service accounts;
  - an SBOM, signed images, and `govulncheck` and Trivy in CI;
  - Go fuzz tests on every parser;
  - a STRIDE threat model, a failure demo and an attempted policy bypass;
  - a technical report.
- **Learn:** threat modelling, PKI and TLS 1.3, supply-chain integrity, fuzzing, chaos experiments, how to write a claim and its limits.
- **Patterns:** defence in depth, zero trust.
- **Exit proof:** a clean reproduction from a fresh checkout; a demonstrated failure and a blocked bypass; a report with evidence, limits and open questions. It claims neither legal compliance nor production readiness.
- **Career signal:** consolidates systems, operations, security, research and communication.

---

## 5. Foundation-gap ledger

This table shows each foundation gap, where it is first introduced, where it is practised, what evidence **closes** it, and what remains outside this program. Use it to plan, to track yourself, and to explain your progression in interviews (see [§11](#11-career-map)).

| # | Gap | Why roles care | Introduced | Practised | Closed by (evidence) | Not covered |
|---|---|---|---|---|---|---|
| 1 | Shell: paths, pipes, environment | Every infrastructure role lives in a terminal | 0 | Every phase; 5 operations | Phase 0 `ss` transcript; Phase 5 runbook | Full Linux administration |
| 2 | Git, GitHub and CI | Team workflow, reproducibility | 0 | Every phase; 5 CD pipeline | Red-then-green CI history; Phase 5 build-scan-deploy pipeline | Large-team release engineering |
| 3 | Go | The language of cloud-native infrastructure | 0 | 1–8 | Every phase's code in your repository | Runtime internals |
| 4 | HTTP and API design | Backend, platform | 0 | 1 contracts; 2 gRPC; 6 auth | Phase 1 contract table and tests | GraphQL, versioning at scale |
| 5 | Testing and TDD | Every role; a seniority signal | 0 | 1 TDD by default; 3 contract tests; 4 simulation; 8 fuzzing | Red-green history; contract tests passing against two stores; Raft simulation | Mutation testing |
| 6 | Code organisation and design patterns | Reading and writing real codebases | 1 | 2, 3, 6 | The layered Phase 1 service; the Phase 3 storage swap with no handler changes | Architecture governance across teams |
| 7 | Processes, signals, file descriptors, limits | SRE, systems | 0 (idea); 1 | 5 cgroups and limits | Shutdown under load; a file-descriptor limit experiment | Kernel scheduling |
| 8 | Concurrency: goroutines, threads, locks, races | Backend, DS, systems | 1 | 2 worker pool; Rust Send/Sync; 4 distributed interleavings | A race caught and fixed; a race Rust rejects at compile time | Lock-free algorithms, memory models in depth |
| 9 | Python and its tooling | ML, data, SRE scripting | Python Bridge | 2–8 experiments; 7 ML | A load generator with tests; Phase 7 pipeline | Library packaging, async frameworks in depth |
| 10 | Measurement and experimental method | Performance, SRE, research | 1; Python Bridge percentiles | 3 query plans; 5 capacity; 7 baseline | An experiment that regenerates its plots from raw data | Statistics beyond descriptive stats and basic intervals |
| 11 | Sockets, TCP/UDP, ports, DNS | Infrastructure, DS | 2 | 5 routing and DNS; 6 TLS | A packet capture of a request, explained | Kernel network stack |
| 12 | Messaging and event-driven design | Backend, DS, platform | 2 | 3 outbox; 6 events | Redelivery after a worker kill; exactly-once-in-effect test | Kafka operations at scale |
| 13 | Serialization and schema evolution | DS, platform | 2 | 3 migrations | A versioned event with a compatibility test | Schema-registry tooling |
| 14 | Memory: stack, heap, virtual memory, ownership | Systems, storage | Rust Bridge | 3 byte log; 5 memory limits | Rust ownership exercises; an observed OOM kill | Allocators, kernel memory management |
| 15 | SQL, schema design, indexes, query plans | Every backend; DB | 3 | 6 policy queries; 7 analysis | Migrations; `EXPLAIN ANALYZE` before and after an index | Optimizer internals |
| 16 | Transactions and isolation | Backend, DB, DS | 3 | 4 consensus vs transactions | A reproduced anomaly and its fix; outbox atomicity test | Distributed transactions in production |
| 17 | Files, `fsync`, page cache, crash consistency | Storage, systems | Rust Bridge / 3 | 4 Raft persistence | The Rust log recovers a valid prefix and rejects corruption under kill tests | Power-loss and device faults |
| 18 | Backup and restore | SRE, DB | 3 | 5 runbook | A restore drill to a second database | Point-in-time recovery at scale |
| 19 | Failure models, clocks, consensus | DS | 4 | 5 game day; 6 offline behaviour | Raft passes randomised partitions; Porcupine histories; a bug write-up | Byzantine faults (named, not built) |
| 20 | Formal methods (TLA+) | DS research, high assurance | 4 | 8 claims | TLC checks an invariant; a counterexample explained | Proofs, large specifications |
| 21 | Containers: namespaces, cgroups, images | Platform, DevOps, SRE | 5 | 8 image scanning | A multi-stage image; namespaces inspected; limits observed | Container runtime internals |
| 22 | Kubernetes and infrastructure as code | Platform, cloud, SRE | 5 | 8 | Manifests and Helm on kind; `terraform plan`; a small controller | Multi-cluster and production cloud operations |
| 23 | Observability and SLOs | SRE, platform | 1 logs and metrics | 5 OpenTelemetry, Prometheus, Grafana; 7 | A dashboard, an SLO and a burn-rate alert | Large-scale telemetry pipelines |
| 24 | IP, routing, NAT, load balancing, constrained links | Infrastructure | 5 | 7 experiments | `netem` experiments with measured results | Operating a real WAN |
| 25 | Incident response and postmortems | SRE | 5 | 8 | A game day and a blameless postmortem | Real on-call experience |
| 26 | Authentication and authorisation | Security, platform, backend | 2 service identity; 6 | 8 | Allowed, denied, expired and replayed tests | Enterprise IAM administration |
| 27 | TLS, PKI, mTLS | Security, infrastructure | 2 (concept); 6 | 8 | A local CA, mTLS between sites, a rotation test | Public PKI operations |
| 28 | API and web security | Backend, security | 0 validation | 1 limits; 3 SQL injection; 6 OWASP; 8 fuzzing | OWASP-based test cases; fuzzing findings | Penetration-testing qualification |
| 29 | Privacy and inference risk | Privacy engineering, research | 6 | 7 cost of privacy for the model | Threshold and noise tests; a repeated-query leakage analysis | Formal DP proofs, legal compliance |
| 30 | ML fundamentals | ML engineering, ML infrastructure | 7 | 7 | Splits without leakage; baseline vs model; error metrics; reproducible runs | Deep-learning theory |
| 31 | ML systems: tracking, serving, monitoring | ML infrastructure, MLOps | 7 | 8 hardening | MLflow registry; FastAPI behind the Go gateway; drift check; shadow deployment | GPU scheduling, distributed training |
| 32 | Supply-chain security | DevSecOps, platform | 5 CI scan | 8 | SBOM, signed image, clean `govulncheck` and Trivy | Formal SLSA certification |
| 33 | Research method and technical writing | MSc, senior roles | 2 (one question, one trace) | 4, 5, 7, 8 | A technical report with a baseline and limits | Peer-reviewed publication |
| 34 | Algorithms and data structures | Every coding interview | [dsa/](dsa/README.md) from Phase 0 | Continuous | Tracked problem log; explain-aloud practice | Competitive programming |
| 35 | System design | Interviews from mid-level up | [system-design/](system-design/README.md) from Phase 2 | Continuous | Scored designs in each track | — |
| 36 | Communication | Every role | 0 learned.md | Every phase; 8 defence | Written explanations, design reviews, a postmortem, the report | — |

**How to use it:** copy this table into your own repository and add a column for **your** evidence link. When the column is full, the gap is closed.

---

## 6. Patterns ledger

Every pattern is built in working code at the point where the system needs it, not taught as theory. Knowing when **not** to use a pattern matters as much as knowing it.

| Pattern | Problem it solves | Where you build it | Don't use it when |
|---|---|---|---|
| Guard clause (early return) | Bad input reaching the main logic | 0 | — |
| Table-driven tests | Many similar cases | 0 | Cases need such different setup that the table fills with flags |
| Test-driven development | Untested code; unclear requirements | 0 exercises; default from 1 | Exploratory spikes. Throw the spike away, then build it test-first |
| Layered architecture | HTTP details leaking into business rules | 1 | A 50-line script |
| Ports and adapters (hexagonal) | Core logic tied to a database or framework | 1 interfaces; 3 Postgres adapter | The indirection costs more than any swap it enables |
| Repository | Storage details inside business logic; swapping stores | 1 in-memory; 3 Postgres | Complex reporting queries; use a read model or direct SQL |
| Dependency injection (constructor injection, composition root) | Hidden globals; untestable code | 1 | You'd need a DI framework. In Go, wiring by hand in `main` is enough |
| Middleware / decorator | Cross-cutting concerns: logging, metrics, auth | 1; 6 auth | The logic belongs to one handler |
| Functional options | Many optional settings | 1 | There are one or two settings; use parameters |
| Entity and value object (tactical DDD) | Rules scattered around; invalid states | 1 | Plain CRUD with no rules |
| State machine | Illegal transitions | 1 job lifecycle; 4 Raft roles | — |
| Timeout and deadline propagation | Work that never ends | 1, 2 | — |
| Graceful shutdown | Losing in-flight work on deploy | 1 | — |
| Worker pool | Unbounded goroutines | 2 | The work is cheap enough to do inline |
| Work queue (producer/consumer) | Slow work blocking requests | 2 | The caller needs the result now |
| Pub/sub | Many independent reactions to one fact | 2 | Exactly one consumer must act |
| Event-driven architecture (commands vs events) | Tight coupling between services | 2 | You need an immediate answer; use request/response |
| Event envelope and schema versioning | Changes breaking consumers | 2 | — |
| Bounded context (strategic DDD) | One word meaning different things in different places | 2 | One small team, one small model |
| Idempotency key | Duplicates caused by retries | 2 | The operation is naturally idempotent |
| Retry with backoff and jitter | Transient failures; synchronised retry storms | 2 | The operation isn't idempotent |
| Circuit breaker | Hammering a dependency that is down | 2 | Calls are rare, or failure is cheap |
| Bulkhead and backpressure | Overload spreading | 2 | — |
| Unit of work | Partial writes | 3 | — |
| Aggregate and domain events | Unclear consistency boundaries | 3 | Data with no invariants |
| Transactional outbox | A database write and a message publish that can't be atomic | 3 | Nothing outside the database needs to know |
| Event sourcing | Needing full history and audit | 3 audit log | Most CRUD data |
| Contract tests | Two implementations of one interface drifting apart | 3 | — |
| Snapshot and log compaction | Logs growing forever | 3, 4 | — |
| Replicated state machine | One machine's failure taking everything down | 4 | One machine plus backups is enough |
| Leader election and leases | Deciding who decides | 4 | — |
| Two-phase commit vs saga (compared) | Atomicity across parties | 4 | — |
| Deterministic simulation testing | Rare distributed bugs that can't be reproduced | 4 | — |
| Reconciliation loop | Drift between desired and actual state | 5 | One-shot tasks |
| Sidecar | Adding a capability without changing the app | 5 | It doubles resource use for little gain |
| Liveness vs readiness checks | Bad restarts; traffic sent before the app is ready | 5 | — |
| Canary rollout | Risky deploys | 5 | — |
| Twelve-factor config | Separate builds per environment | 1, 5 | — |
| Policy enforcement and decision points | Authorisation logic scattered everywhere | 6 | — |
| CQRS and read models | Reads and writes needing different shapes | 6 | Simple CRUD |
| Materialised view | The same expensive query, repeated | 6 | The data must always be fresh |
| Scatter-gather | Answering from many sites | 6 | — |
| API gateway | One entry point for auth and limits | 6, 7 | One service, one client |
| Rate limiting (token bucket) | Abuse; fairness | 6 | — |
| Feature pipeline with train/serve parity | Training/serving skew | 7 | — |
| Model registry | Not knowing which model is live | 7 | — |
| Shadow deployment | Testing a model safely on real traffic | 7 | — |
| Defence in depth / zero trust | A single control failing | 8 | — |

---

## 7. Languages and tools

| Language | Enters | Role | Why |
|---|---|---|---|
| **Bash** | 0 | Running, inspecting and automating | Every server is operated from a shell |
| **Go** | 0 | APIs, workers, Raft, gateway, controller | Most cloud-native infrastructure (Kubernetes, etcd, Prometheus) is written in Go |
| **Python** | Python Bridge | Load generation, experiment analysis, the ML pipeline, model serving | The language of measurement, data and ML |
| **Rust** | Rust Bridge | The audit log and byte-level parsing | Memory safety without a garbage collector; makes ownership and bytes explicit |
| **SQL** | 3 | Durable records, policy queries | Every backend and data role needs it |
| **TLA+** | 4 | Specifying and model-checking a protocol | Standard in distributed-systems research and teams that run consensus |
| **HCL (Terraform)** | 5 | Infrastructure as code | Expected in cloud and platform roles |
| **YAML** | 0 (CI); 5 | CI workflows, Kubernetes manifests | Everywhere in operations |

**The principle:** Go for the control plane, Rust for the data plane, Python for measurement and ML. That split mirrors many real systems, and it gives you a defensible answer to "why three languages?"

**Core tools vs comparisons.** The path uses the standard library first, then one tool per job. Alternatives are studied for context without rebuilding everything:

| Job | Core | Compare only |
|---|---|---|
| HTTP routing | Go `net/http` | chi, Gin (Phase 0 exercise) |
| Messaging | RabbitMQ | NATS JetStream, Kafka |
| RPC | gRPC and Protobuf | HTTP/JSON |
| Database | PostgreSQL (pgx, goose) | — |
| Consensus | Your own Raft | hashicorp/raft, etcd |
| Orchestration | Kubernetes on kind, Helm | Kustomize |
| IaC | Terraform (plan) | — |
| Observability | OpenTelemetry, Prometheus, Grafana | Loki, Tempo |
| ML | scikit-learn, PyTorch, MLflow, FastAPI | KServe (architecture survey) |
| Security | govulncheck, Trivy, Syft, cosign | OPA/Rego |

---

## 8. Parallel tracks: DSA, system design, writing

These run alongside the phases. The phases don't teach them, but they reuse what the phases build.

| Track | Starts | Cadence | Where |
|---|---|---|---|
| Algorithms and data structures | Phase 0 | 3 sessions a week, pattern by pattern, in Go and Python | [dsa/](dsa/README.md) |
| System design | Phase 2 | 1 session a week, scored against a rubric | [system-design/](system-design/README.md) |
| Writing | Phase 1 | One essay per phase, drawn from your failures and decisions | Your own blog |
| Paper reading | Phase 2; weekly from Phase 4 | Three-pass method; one-page notes | Your own repository |
| Open source | Phase 3 | Read a real codebase (hashicorp/raft, etcd, a Rust storage crate); first merged PR by Phase 4–5 | — |
| Job applications | Phase 5 (earlier for backend) | Tailored, with evidence links | See [§11](#11-career-map) |

---

## 9. Reading index

Read a chapter **after** you've felt the problem in code, never before. Each lesson places its readings at the exact step where they help. This index lists them all in one place.

### Books

| Book | Edition | Free? | Used in |
|---|---|---|---|
| *Operating Systems: Three Easy Pieces* (Arpaci-Dusseau) | Complete | [Yes](https://pages.cs.wisc.edu/~remzi/OSTEP/) | 0, 1, Rust, 3, 5 |
| *Computer Systems: A Programmer's Perspective* (Bryant & O'Hallaron) | 3rd | No | 0, 1, 2, Rust, 3, 5 |
| *Computer Networking: A Top-Down Approach* (Kurose & Ross) | 8th | No | 0, 2, 4, 5, 6, 8 |
| *Designing Data-Intensive Applications* (Kleppmann) | 1st or 2nd | No | 1, 2, 3, 4, 7 |
| *Understanding Distributed Systems* (Vitillo) | 1st or 2nd | No | 1, 2, 3, 4, 5 |
| *Distributed Systems* (van Steen & Tanenbaum) | 4th | [Yes](https://www.distributed-systems.net/) | 2, 4, 5, 8 |
| *Site Reliability Engineering* (Google) | — | [Yes](https://sre.google/books/) | 1, 2, 3, 4, 5, 7 |
| *The Rust Programming Language* | — | [Yes](https://doc.rust-lang.org/book/) | Rust Bridge |
| *Rust Atomics and Locks* (Bos) | — | [Yes](https://marabos.nl/atomics/) | Rust Bridge, 4 |
| *The Linux Command Line* (Shotts) | — | [Yes](https://linuxcommand.org/tlcl.php) | 0–1, reference |
| *Beej's Guide to Network Programming* | — | [Yes](https://beej.us/guide/bgnet/) | 2 |
| *Readings in Database Systems* ("Red Book") | 5th | [Yes](http://www.redbook.io/) | 3, 4 |
| *Database Internals* (Petrov) | 1st | No | 3, 4 |
| *Kubernetes in Action* (Lukša) | 2nd if possible (verify 1st-edition commands) | No | 5 |
| *Systems Performance* (Gregg) | 2nd | No | 5 |
| *Security Engineering* (Anderson) | 3rd | Partly | 1, 2, 6, 8 |
| *The Web Application Hacker's Handbook* | 2nd (pair with current OWASP) | No | 0, 1, 3, 8 |
| *Designing Machine Learning Systems* (Huyen) | 1st | No | 7 |
| *Python Crash Course* or the [official tutorial](https://docs.python.org/3/tutorial/) | — | Tutorial is free | Python Bridge |

### Papers, in reading order

| Phase | Papers |
|---|---|
| 2 | MapReduce (Dean & Ghemawat, 2004), §3.3 on fault tolerance |
| 3 | Bigtable (Chang et al., 2006): SSTables, memtables, compaction |
| 4 | Lamport, *Time, Clocks, and the Ordering of Events* (1978); Raft, extended (Ongaro & Ousterhout, 2014); *Viewstamped Replication Revisited* (Liskov & Cowling, 2012); *Paxos Made Simple* (Lamport, 2001); GFS (2003); Spanner (2012); FLP (1985); Gilbert & Lynch, CAP proof (2002); Dynamo (2007); Jepsen analyses |
| 5 | Borg (Verma et al., 2015) |
| 6 | Zanzibar (2019); Dwork & Roth, *The Algorithmic Foundations of Differential Privacy*, Ch. 1–3 (free) |
| 7 | Sculley et al., *Hidden Technical Debt in Machine Learning Systems* (2015) |
| 8 | in-toto (Torres-Arias et al., 2019); *The Byzantine Generals Problem* (1982); *Simple Testing Can Prevent Most Critical Failures* (OSDI 2014) |
| Before any paper | Keshav, *How to Read a Paper* |

### Readings by phase (chapter level)

- **Phase 0:** Kurose & Ross §1.1–1.5, §2.1–2.2; OSTEP Ch. 2, 4, 5; WAHH Ch. 3 (skim); CSAPP Ch. 1.
- **Phase 1:**
  - OSTEP Ch. 26–28 (before shared state), then Ch. 29, 30 and 32 (after your first race);
  - CSAPP §12.1 and §12.3–12.7, and §8.1–8.2 and §8.4–8.5 (before shutdown);
  - SRE Ch. 6 (after metrics); Vitillo, Introduction and Part IV, downstream resiliency;
  - DDIA Ch. 1; WAHH Ch. 2; Anderson Ch. 1.
- **Python Bridge:** the official tutorial §3–9; *Understanding Distributed Systems*, the monitoring chapter on percentiles; Gil Tene, *How NOT to Measure Latency* (talk).
- **Phase 2:**
  - Kurose & Ross §2.7, §3.1–3.5;
  - CSAPP Ch. 11;
  - Vitillo Part I (reliable links, discovery, APIs);
  - van Steen §3.4, §4.2–4.3;
  - DDIA Ch. 4, and the first section of Ch. 11;
  - MapReduce;
  - SRE Ch. 21–22;
  - Vitillo Part IV (failure causes, upstream resiliency);
  - Anderson Ch. 4.
- **Rust Bridge:** *The Rust Book* Ch. 1–10, 13, 15, 16; OSTEP Ch. 13, 14, 17; CSAPP §9.1–9.9; *Rust Atomics and Locks* Ch. 1–2.
- **Phase 3:**
  - DDIA Ch. 7 (with Postgres); WAHH Ch. 9 (SQL injection);
  - the Red Book chapters *Traditional RDBMS Systems* and *Techniques Everyone Should Know*;
  - OSTEP Ch. 36, 37, 39, 40, then Ch. 42 (the most important reading this phase), then Ch. 43, 44;
  - CSAPP Ch. 10 and §6.1–6.3;
  - DDIA Ch. 3 (before compaction); Bigtable;
  - Vitillo Part II (transactions); SRE Ch. 26;
  - *Database Internals* Part I.
- **Phase 4, in this order:**
  1. DDIA Ch. 5; Vitillo Part II (models, failure detection, time, leader election, replication)
  2. DDIA Ch. 8; van Steen §5.1–5.4; Lamport 1978
  3. Raft §1–8 while building, §9–11 after the tests pass
  4. DDIA Ch. 9; VR Revisited; *Paxos Made Simple*
  5. van Steen §7.1–7.5, §8.1–8.2, §8.5; SRE Ch. 23
  6. DDIA Ch. 6; the Red Book chapter *Weak Isolation and Distribution*; Kurose & Ross §3.6–3.8
  7. GFS; Spanner; FLP; CAP; Dynamo; *Database Internals* Part II
- **Phase 5:**
  1. OSTEP Ch. 6, 7 (intro) and Appendix B; van Steen §3.2; CSAPP §7.1–7.7 and §7.10–7.12 (why Go images can be tiny)
  2. Borg; *Kubernetes in Action* Ch. 1–11, 14, 17; OSTEP Ch. 18–22 (memory limits and OOM)
  3. Kurose & Ross §2.4, 2.6, 4.1–4.3, 4.5, 6.4, 6.6, 6.7; van Steen Ch. 6 (skim)
  4. SRE Ch. 1, 3, 4, 5, 8, 10–15 and Appendices B–D; Vitillo Part V
  5. Gregg Ch. 2 and Ch. 6; CSAPP §5.1–5.7 and §5.14
  6. *Team Topologies* Ch. 4–5 (the platform team)
- **Phase 6:** Anderson Ch. 6 (access control) and Ch. 21 (network attack and defence); Kurose & Ross Ch. 8 (security, TLS); the OWASP API Security Top 10; Zanzibar; Dwork & Roth Ch. 1–3; Nissenbaum, *Privacy in Context* (selections).
- **Phase 7:** Huyen Ch. 1–2, 4, 6–9; Sculley et al.; SRE availability chapters; the evaluation sections of two papers close to your question.
- **Phase 8:** Anderson Ch. 2 (who the opponents are), Ch. 27 (secure development) and Ch. 28 (assurance); OWASP ASVS; in-toto; the Byzantine Generals paper; the Go fuzzing docs.

---

## 10. Timeline and progress tracker

These estimates assume 12–15 focused hours a week. A phase ends when its exit proof passes, not when the weeks run out.

| Phase | Weeks | Status | Exit proof passed | Evidence link | Essay |
|---|---|---|---|---|---|
| 0. Request | 2 | ☐ | ☐ | | ☐ |
| 1. Reliable service | 4 | ☐ | ☐ | | ☐ |
| Python Bridge | 2 | ☐ | ☐ | | — |
| 2. Connected services | 4 | ☐ | ☐ | | ☐ |
| Rust Bridge | 3 | ☐ | ☐ | | — |
| 3. Durable data | 6 | ☐ | ☐ | | ☐ |
| 4. Replicated state | 10 | ☐ | ☐ | technical report | ☐ |
| 5. Operations | 8 | ☐ | ☐ | postmortem | ☐ |
| 6. Safe queries | 6 | ☐ | ☐ | leakage analysis | ☐ |
| 7. Evaluate + ML | 8 | ☐ | ☐ | experiment + model report | ☐ |
| 8. Capstone | 6 | ☐ | ☐ | final report | ☐ |
| **Total** | **59** | | | | |

Copy this table into your own repository's README and fill it in as you go.

---

## 11. Career map

### How to read it

| Fit | Meaning |
|---|---|
| **Strong** | You can show evidence for most of a typical job description and pass the usual interview loop with normal preparation |
| **Competitive** | The core is there. Expect one or two gaps; apply, and close them with the "extra" noted |
| **Stretch** | Possible only with the extra work noted. Apply selectively |

The phases prove **skills**, not **years**. A beginner who finishes Phase 5 is a strong junior or new-grad candidate for the roles marked strong. An engineer with prior professional experience can aim for mid-level with the same evidence. Senior roles need a track record of production ownership that no curriculum can replace.

### Role by role

| Role | Competitive after | Strong after | Evidence to show | Typical interview loop | Still needed for strong |
|---|---|---|---|---|---|
| Backend Engineer | 1 | 3 | Layered service with TDD; Postgres and outbox; messaging with idempotency | Coding (DSA), API and system design, behavioural | Product and frontend breadth (not covered here) |
| DevOps Engineer | 5 | 5 + 8 | CI/CD pipeline, images, Kubernetes, Terraform plan, supply-chain scans | Linux and networking troubleshooting, CI/CD design, scripting | Applying real cloud infrastructure; running shared infrastructure for a team |
| Cloud / Infrastructure Engineer | 5 | 5 + a real cloud apply | Terraform, network design, Kubernetes, SLOs | Cloud architecture, networking, troubleshooting | Hands-on AWS or GCP (an optional paid exercise in Phase 5); a cert is optional (AWS SAA, Terraform Associate) |
| Site Reliability Engineer | 5 | 8 | SLO dashboard, burn alerts, game-day postmortem, runbooks, capacity data | Coding, Linux and network troubleshooting, large-scale design, incident scenarios | Real on-call experience |
| Platform Engineer | 5 | 5 + the platform design track | A reconciler, pipelines, a golden-path deployment | Platform design, Kubernetes internals, coding | Running a platform for real internal users |
| Distributed Systems Engineer | 4 | 4 + 5 + the distributed-systems design track | Your own Raft with simulation, Porcupine and TLA+; outbox; idempotency | Harder DSA, distributed design, deep dives on consensus and consistency | Production-scale operations. Many such roles are mid-level |
| Storage / Database Engineer | 3 (application side) | Stretch for engine teams | Rust log with crash tests; query plans; restore drill | DSA, storage-internals deep dive, C++ or Rust coding | A larger storage engine (B-tree or LSM); C++ |
| Systems Software Engineer | Stretch after Rust Bridge + 3 | Competitive after 4 | Rust log; concurrency evidence; Raft | C or Rust coding, OS questions | C and kernel internals |
| Infrastructure Security Engineer | 6 | 8 | Threat model, mTLS, policy tests, SBOM, signing, fuzzing | Security design review, threat modelling, coding | Offensive practice; cloud-security depth |
| Privacy Engineer | Stretch after 6 | Competitive after 7 | Inference analysis, noise demo, data minimisation, model privacy cost | Privacy design review, threat modelling | Privacy law and formal differential privacy |
| ML Infrastructure / MLOps Engineer | 7 | 7 + the applied-ML design track | Registry, serving behind a gateway, monitoring, Kubernetes | ML system design, infrastructure design, coding | GPU scheduling, distributed training |
| AI / LLM Infrastructure Engineer | Stretch after 7 | Competitive after 7 + an LLM serving project | Inference gateway, quotas, telemetry | LLM serving design, batching, GPU questions | GPU and CUDA depth; inference-engine internals |
| Applied ML / ML Engineer | Stretch after 7 | Competitive after 7 + two more modelling projects | Phase 7 pipeline with rigorous evaluation | ML system design (ranking, recommendations), ML fundamentals, coding | Modelling depth, statistics, more ML projects |
| Research MSc (systems) | 4 + a technical report | 7–8 | Report, TLA+ model, paper notes, reproducible experiment | Statement of purpose, supervisor fit | Maths readiness; publication optional |

### When to start applying

| After | Apply for |
|---|---|
| Phase 1 | Junior backend roles (with DSA practice under way) |
| Phase 3 | Backend roles generally; data-heavy backend roles |
| Phase 4 | Distributed-systems roles (expect a high coding bar); research outreach |
| Phase 5 | **The main wave:** SRE, DevOps, Platform, Cloud/Infrastructure |
| Phase 7 | ML infrastructure and MLOps; applied-ML roles as a stretch |
| Phase 8 | Infrastructure security; MSc applications with the report as a writing sample |

### Preparing for the interview loop

| Loop part | What's being judged | Prepare with |
|---|---|---|
| Coding | Problem solving, clean code, testing, communication | [dsa/](dsa/README.md) |
| System design | Problem navigation, solution design, technical excellence, communication | [system-design/](system-design/README.md), in the track for your role |
| Domain deep dive | Whether you really built what you claim | Your phase evidence; be able to rebuild any part on a whiteboard |
| Behavioural | Ownership, conflict, failure, learning | Postmortems and failure notes, written as stories: situation, task, action, result |

### Telling your progression story

The gap ledger is your story. For any role, pick the rows its job description cares about and say, for each: **"I didn't know X. I closed it in Phase N by doing Y, and here is the evidence: Z."** For example:

> "I'd used queues but never reasoned about delivery guarantees. In Phase 2 I killed a worker mid-job and showed, with a test, that an idempotency key made the retry safe. Here's the test and the trace."

That's specific, checkable, and shows you learn by building. It's far stronger than a list of technologies.
