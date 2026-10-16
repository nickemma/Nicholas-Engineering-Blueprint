# The Blueprint: from first request to distributed systems and infrastructure

This is a complete path from your first web request to building, operating, securing and measuring distributed systems, and then running a research project of your own. You learn it by building one teaching system, **Runway**, phase by phase. You finish by choosing a **capstone research project** and taking it from problem to evidence.

This is the **only roadmap** in the repository. Everything else is a lesson (`lessons/`), a capstone brief (`capstones/`), interview practice (`dsa/`, `system-design/`), or a personal note (`notes/`).

**Contents**

1. [Who this is for](#1-who-this-is-for)
2. [What you'll build](#2-what-youll-build)
3. [How to study](#3-how-to-study)
4. [The route](#4-the-route)
5. [Foundation-gap ledger](#5-foundation-gap-ledger)
6. [Patterns ledger](#6-patterns-ledger)
7. [Languages and tools](#7-languages-and-tools)
8. [Parallel tracks: DSA, system design, writing](#8-parallel-tracks-dsa-system-design-writing)
9. [Books](#9-books)
10. [Timeline and progress tracker](#10-timeline-and-progress-tracker)
11. [Career map](#11-career-map)

---

## 1. Who this is for

- **Complete beginners.** Phase 0 assumes no Go, no Linux and no HTTP. Each idea is explained before it is used.
- **Working engineers** who want to relearn the foundations properly, in order, with evidence for each skill.
- **Anyone reading the author's code.** The phases teach the techniques the author's projects are built on.

The scope is **backend, distributed systems and infrastructure engineering**, plus the ML systems that increasingly run on that infrastructure. By the end you can design, build, test, operate, secure and measure a distributed system, and you have a public portfolio with evidence for each claim. You'll also have a research project you can defend, and practice for the coding and system-design interviews these roles use.

It is **not** a technology checklist. Every tool appears because the system needs it at that point, and phases end when their evidence is in place, not when a calendar says so.

**Time:** about 60 weeks at 12–15 focused hours a week, plus the capstone (see [§10](#10-timeline-and-progress-tracker)). Experienced engineers often move faster through Phases 0–2.

---

## 2. What you'll build

### Runway, the teaching system

**Runway** is a jobs platform. Clients submit work; the platform queues it, runs it on workers, records what happened, and reports back. Almost every backend you'll ever touch has this shape: payments, video processing, data pipelines, notifications, ML inference.

That makes Runway a good vehicle for learning systems. It starts as one Go program answering one request, and each phase adds what a real platform needs next:

| Phase | Runway gains | Because |
|---|---|---|
| 0 | A web service | Everything starts with a request |
| 1 | Reliable job handling | Requests overlap, stall and fail |
| 2 | Workers behind a message broker | Work must outlive a request and a process |
| 3 | Durable records, an outbox, caching, an event stream | Memory forgets; crashes happen between two writes |
| 4 | Replication, sharding, leases | One machine is a single point of failure, and too small |
| 5 | Containers, Kubernetes, AWS, observability | It has to run somewhere, and be operated |
| 6 | Identity, tenants, policy, rate limits, audit | Many users, some of them hostile |
| 7 | Experiments, a data pipeline, ML and AIOps on its own data | You must prove claims, and the platform's own data can improve it |

~~~mermaid
flowchart LR
    C[Clients] -- HTTP / gRPC --> LB[Load balancer]
    LB --> API1[API]
    LB --> API2[API]
    API1 --> PG[(PostgreSQL<br/>jobs + outbox)]
    API1 -.-> R[(Redis cache)]
    PG -- outbox relay --> MQ[[RabbitMQ<br/>commands]]
    PG -- outbox relay --> K[[Kafka<br/>event stream]]
    MQ --> W1[Workers]
    MQ --> W2[Workers]
    W1 -- events --> MQ
    K --> AUD[Rust audit log]
    K --> DP[Data pipeline → ML / AIOps]
    META[(Raft metadata store<br/>shard map, leases)] -.-> API1
    META -.-> W1
    OBS[Kubernetes / AWS · metrics · logs · traces] -. operates .-> API1
~~~

That's where Runway ends up by Phase 7. You build every box yourself, and you can explain why each one exists.

### Your capstone

Phase 8 is yours. You pick one of ten **research projects** in [`capstones/`](capstones/README.md), across fields such as networking, ML, cloud, health, supply chain and quantum systems. You take it through the full research loop:

> real-world problem → who has it → why existing solutions fall short → research question → system → experiment → evidence → limitations

The skills come from Runway; the capstone is where you show you can apply them to a question nobody has handed you an answer for. One of the ten, **KESTREL** (replication under intermittent, partial network partitions at under-resourced health sites), is the author's own capstone and serves as the worked example.

### Engineering rules the code follows

From Phase 0 to the capstone:

- **Claims need evidence.** Every guarantee has a test or a measurement, and every measurement records how to reproduce it.
- **Fail visibly.** Errors are explicit, logged, and mapped to precise status codes. Nothing fails silently.
- **Untrusted input is rejected at the edge.** That covers sizes, types, unknown fields and limits.
- **Every wait has a deadline, and every queue has a bound.**
- **Security by default.** Deny unless explicitly allowed, keep secrets out of code and logs, and grant least privilege.
- **Say what something doesn't guarantee**, as clearly as what it does.

---

## 3. How to study

### What is in a lesson

~~~text
lessons/03-durable-data/
  README.md       the syllabus: topics, outcomes, prerequisites, the exercise project
  TEACHING.md     the lesson: explanations plus a type-along build, with the code inline
  exercises.md    a different project you build alone, with a clear picture of the finished result
  learned.md      your answer sheet: explanations plus evidence
~~~

Each phase also has a question-only self-test in [`notes/learned/`](notes/learned).

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
| **Read** | One specific chapter or paper, placed after you've felt the problem. Readings live in the guides, at the step where they help |

Two labels tell you how each step is verified:

- **Checked in CI.** Built and tested on every push, so it's known to work.
- **Run locally.** The step needs something CI can't provide, such as your GitHub account, Kubernetes, `sudo`, a cloud account or a GPU. The guide gives the exact commands and what you should see.

### The rebuild rule

You follow each lesson in a scratch `practice/` folder. At the end of each phase you **close the guide and rebuild the phase in your own `runway` repository**, from the contracts and your notes. Looking up documentation is allowed; copying the guide isn't. Then you build the phase's **exercise project** alone. That's a different system, with a clear spec and no solution.

### What "done" means for a phase

1. Your own repository runs from a clean checkout, and CI is green.
2. You can explain its data flow without notes.
3. You reproduced the phase's key failures and can explain them.
4. You can point to evidence for each guarantee it claims.
5. You can name the trade-offs you made.
6. The exercise project meets its acceptance checks.
7. learned.md is complete and the self-test is answered.

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
| Python Bridge | [`uv`](https://docs.astral.sh/uv/), which also installs Python |
| Phase 2 | Docker with Compose; `protoc` (the protobuf compiler); `tcpdump` (usually preinstalled on Linux) |
| Rust Bridge | [`rustup`](https://rustup.rs/) |
| Phase 3 | The `psql` client. PostgreSQL, Redis and Kafka run in Docker |
| Phase 4 | Java 17+ and the [TLA+ tools](https://github.com/tlaplus/tlaplus/releases) (or the VS Code TLA+ extension) |
| Phase 5 | [`kind`](https://kind.sigs.k8s.io/), `kubectl`, [`helm`](https://helm.sh/), [`terraform`](https://developer.hashicorp.com/terraform/install); optionally the AWS CLI and an AWS account (the Terraform is planned offline for free; applying it costs about $2.50 a day while it runs, and the guide covers clean-up) |
| Phase 7 | Python ML libraries, installed through `uv`. No GPU is needed |
| Phase 8 | `govulncheck`, [`trivy`](https://trivy.dev/), [`syft`](https://github.com/anchore/syft), [`cosign`](https://docs.sigstore.dev/), plus whatever your capstone needs |

---

## 4. The route

~~~mermaid
flowchart LR
    P0[0 Request] --> P1[1 Reliable service] --> PY[Python Bridge] --> P2[2 Connected services]
    P2 --> RB[Rust Bridge] --> P3[3 Durable data] --> P4[4 Replication + scale]
    P4 --> P5[5 Operate] --> P6[6 Secure] --> P7[7 Measure + ML] --> P8[8 Capstone]
    DSA[dsa/ from Phase 0] -.-> P8
    SD[system-design/ from Phase 2] -.-> P8
~~~

| Phase | Question | You build | Weeks | Status |
|---|---|---|---|---|
| [0. Make one request work](lessons/00-request-service/README.md) | What happens between a command and an answer? | A Go HTTP service with validation, tests and CI | 2 | **Ready** |
| [1. Make one service reliable](lessons/01-reliable-service/README.md) | What happens when requests overlap, stall, or the process stops? | A layered jobs API: repository, DI, races, timeouts, graceful shutdown, metrics | 4 | **Ready** |
| [Python Bridge](lessons/python-bridge/README.md) | How do I measure what I built? | A Python load generator and analyser; three measurement experiments | 2 | **Ready** |
| [2. Connect services](lessons/02-connected-services/README.md) | What changes across process and network boundaries? | Workers behind RabbitMQ; events, idempotency, retries, a circuit breaker, gRPC | 4 | **Ready** |
| [Rust Bridge](lessons/rust-bridge/README.md) | What do bytes, memory and ownership really look like? | A checksummed append-only log that survives torn writes | 3 | **Ready** |
| [3. Make data durable](lessons/03-durable-auditable-data/README.md) | What survives a crash, and what happens between two writes? | PostgreSQL with pooling and transactions, an outbox, Kafka, Redis caching, background jobs, the Rust audit log | 7 | **Ready** |
| [4. Replicate and scale out](lessons/04-replicated-state/README.md) | What can several machines agree on, and how do you split work across them? | Your own Raft, simulation testing, linearizability checks, TLA+, sharding with consistent hashing, leases and fencing | 10 | **Ready** |
| [5. Operate it](lessons/05-constrained-operations/README.md) | Can you deploy, observe, diagnose and recover it? | Containers, Kubernetes, load balancing, Helm, CI/CD, tracing, SLOs, a controller, a game day, and Runway on AWS with Terraform | 9 | **Ready** |
| [6. Secure it](lessons/06-safe-shared-queries/README.md) | Who may do what, and how do you contain abuse? | A threat model; tokens, authorization, tenant isolation, rate limiting, signed webhooks, your own CA and mTLS, a sidecar, secrets from OpenBao, a tamper-evident audit log, privacy, cluster hardening, fuzzing, and a security game day | 10 | **Ready** |
| [7. Measure and learn](lessons/07-utility-evaluation/README.md) | Is it actually better, and can its own data improve it? | Rigorous experiments, a data pipeline, ML and deep learning, MLOps, AIOps, all on Runway's data | 8 | Being rebuilt |
| [8. Capstone](capstones/README.md) | Can you answer a research question nobody has answered for you? | One of ten research projects, end to end, plus a hardening review and a defended report | 10+ | Being rebuilt |

"Being rebuilt" means the phase is being written as a full type-along guide to the Phase 0 standard. Until then, its README is an outline.

### Phase 0: Make one request work

- **Build:** a Go HTTP service with `/`, `/greet` and `/health`, input validation, three levels of tests, and CI in your own repository.
- **Learn:** programs vs processes; ports; HTTP methods, status codes and headers; how the router picks a handler; JSON; validation; `httptest`.
- **Patterns:** guard clauses, table-driven tests, TDD.
- **Exercise:** tempconv, a temperature-conversion service.
- **Why next:** one endpoint that works is not a service that survives real traffic.

### Phase 1: Make one service reliable

- **Build:** Runway's jobs API, layered as handler → service → domain → repository, with an in-memory repository behind an interface and wiring in `main`.
- **Learn:** contracts and errors; `context` deadlines and cancellation; goroutines, mutexes and races; check-then-act and compare-and-swap; configuration from the environment; structured logs and Prometheus metrics; signals and graceful shutdown.
- **Patterns:** TDD; repository; dependency injection; middleware; functional options; tactical DDD; state machine; optimistic concurrency.
- **Exercise:** shortlinks, a URL shortener with exact concurrency guarantees.
- **Why next:** you can't improve what you can't measure.

### Python Bridge

- **Build:** `kload`, an open-loop async load generator, with percentile analysis and plots.
- **Learn:** Python, uv, pytest, asyncio, pandas; why averages lie; coordinated omission; checking that the measuring tool isn't the bottleneck.
- **Exercise:** logstat, a log analyser and health prober.
- **Why here:** every experiment from Phase 2 on is driven and analysed in Python, and Phase 7's ML builds on it.

### Phase 2: Connect services

- **Build:** a bounded worker pool, then versioned messages on an at-least-once bus, then RabbitMQ with the API and the workers as separate processes. Then idempotency keys, retries with full jitter, dead letters, a circuit breaker, and gRPC alongside HTTP.
- **Learn:** backpressure and Little's law; commands vs events; delivery guarantees; durability and acknowledgements; the three sources of duplicates; message versioning; protobuf compatibility; sockets and the TCP handshake.
- **Patterns:** worker pool; event-driven architecture; bounded contexts; tolerant reader; idempotency key and idempotent receiver; retry with backoff and jitter; dead-letter queue; circuit breaker; crash-only design.
- **Exercise:** hookshot, a webhook delivery service.
- **Why next:** the broker survives restarts, but Runway's records don't, and the gap between "store" and "publish" is still open.

### Rust Bridge

- **Build:** `klog`, an append-only log of checksummed records with a CRC-32C written from scratch. It recovers from torn writes and refuses real corruption, and many threads share one writer.
- **Learn:** ownership, borrowing and lifetimes; `Result` and custom errors; traits; bytes and little-endian encoding; files and `fsync`; `Send`, `Sync`, `Arc`, `Mutex` and channels.
- **Why here:** Phase 3 is where bytes on disk, crash consistency and memory layout matter, and Rust makes all three explicit.

### Phase 3: Make data durable

The user-requested topics are all here: pooling, transactions, queues, idempotency, caching, background jobs and circuit breakers.

- **Build:**
  - a PostgreSQL repository behind the **same interface** as Phase 1's (the same contract tests pass against both), with migrations;
  - **connection pooling**, sized and then exhausted on purpose;
  - **transactions**, with an isolation anomaly reproduced and fixed;
  - a **transactional outbox** and a relay that closes Phase 2's dual-write gap;
  - **idempotency keys and an inbox** stored in PostgreSQL;
  - **Kafka** as an event stream, contrasted with RabbitMQ (partitions, consumer groups, offsets, replay);
  - **Redis caching**, cache-aside with stampede protection;
  - **background jobs** that are safe with many workers (`FOR UPDATE SKIP LOCKED`);
  - a **circuit breaker** around the database and the cache;
  - the Rust audit log, fed from Kafka;
  - a backup-and-restore drill.
- **Learn:** schema design; indexes and `EXPLAIN ANALYZE`; isolation levels; write-ahead logging; the page cache and `fsync`; B-trees vs LSM trees; log-based messaging; cache invalidation; SQL injection.
- **Patterns:** repository (paying off); contract tests; unit of work; aggregates and domain events; transactional outbox; inbox; event sourcing; cache-aside; singleflight; competing background workers.
- **Why next:** one database on one machine can still die with the data on it, and eventually it's too small.

### Phase 4: Replicate and scale out

- **Build:**
  - **your own Raft** (elections, log replication, persistence, snapshots) on a deterministic simulated network, with Porcupine linearizability checks and a TLA+ model;
  - a replicated metadata store for Runway;
  - **sharding with consistent hashing**, including rebalancing when nodes join and leave;
  - **distributed locks with leases and fencing tokens**, with a demonstration of how locks go wrong without them.
- **Learn:** failure models; clocks; quorums; consistency models; Raft vs Paxos and Viewstamped Replication; FLP and CAP stated precisely; partitioning and hot keys; two-phase commit vs sagas.
- **Patterns:** replicated state machine; leader election and leases; fencing tokens; consistent hashing; snapshot and compaction; deterministic simulation testing.
- **A note on MIT 6.5840:** its labs are excellent extra practice, but do them in a **private** repository; MIT asks students not to publish solutions. The Raft here is independent of the lab's code.
- **Why next:** correct on your laptop isn't the same as running where people depend on it.

### Phase 5: Operate it

- **Build:**
  - container images; Kubernetes on kind, with **load balancing and service discovery** (Services, kube-proxy, DNS, a layer-7 balancer of your own) and a StatefulSet for Raft; a Helm chart with hooks, safe rollouts and a canary;
  - a CI/CD pipeline that builds once, smoke-tests on kind and publishes by digest;
  - OpenTelemetry traces through the outbox and the broker; Prometheus and Grafana; SLOs with tested burn-rate alerts;
  - a queue-driven autoscaler (a reconciliation controller with least-privilege RBAC);
  - network impairment and partial partitions; a game day, a runbook and a postmortem;
  - **Runway on AWS**, with Terraform: VPC, IAM, ECS on Fargate, RDS, S3, SQS (with an SQS adapter), an ALB, CloudWatch and a budget. It is planned offline and checked in CI; applying it is optional, with costs and clean-up spelled out.
- **Learn:** containers as processes (namespaces, cgroups); Kubernetes control loops; L4 vs L7 load balancing; DNS; cloud networking and IAM; SLOs and error budgets; the USE method; incident response.
- **Patterns:** reconciliation loop; liveness vs readiness; canary rollout; twelve-factor config; build once, deploy by digest; backpressure; infrastructure as code.
- **Why next:** the platform runs, but anyone who can reach it can use it.

### Phase 6: Secure it

- **Build:**
  - a threat model, written first, with evidence for every threat;
  - authentication with OIDC-style tokens from an issuer of your own (JWT, JWKS, key rotation);
  - authorization with roles and policies (a policy decision point checked by every handler);
  - **multi-tenancy with tenant isolation**, down to PostgreSQL row-level security;
  - **rate limiting** per tenant: a token bucket, then distributed through Redis;
  - signed, replay-protected webhooks, safe from SSRF;
  - your own certificate authority and mTLS between services, with rotation; a sidecar for software that can't speak it;
  - secrets management: OpenBao, per-Pod database logins, least-privilege roles, encryption as a service;
  - a tamper-evident audit log: a Merkle tree, signed checkpoints and a witness;
  - privacy: an inventory with canaries, redaction, retention, statistics with thresholds and noise;
  - cluster hardening (network policy, Pod Security) and fuzzing;
  - a security game day against the threat model, with tests drawn from the OWASP API Security Top 10.
- **Learn:** authentication vs authorization; least privilege; TLS and PKI; replay attacks; SSRF; noisy neighbours; threat modelling with STRIDE; transparency logs; differential privacy.
- **Patterns:** policy enforcement and decision points; token bucket; tenant context propagation; defence in depth; zero trust; sidecar; dynamic secrets; transparency log.
- **Why next:** a secure platform still has to prove it's good, and its own data can make it better.

### Phase 7: Measure and learn

- **Build, in Python on Runway's own data:**
  - **experiments** with hypotheses, baselines, repeated runs and confidence intervals;
  - a **data pipeline** from Runway's event stream to Parquet and DuckDB;
  - **big-data** concepts, via MapReduce and a Spark example;
  - **ML** that predicts job durations to improve scheduling: a baseline, then scikit-learn;
  - **deep learning** with PyTorch;
  - **MLOps**: MLflow tracking and a registry, model serving with FastAPI behind the Go API, drift checks, a shadow deployment;
  - **AIOps**: anomaly detection on Runway's metrics and logs, scored against injected incidents.
- **Learn:** experimental design and statistics; data contracts and pipelines; leakage and splits; error metrics; train/serve skew; evaluating detectors (precision and recall).
- **Patterns:** feature pipeline with train/serve parity; model registry; shadow deployment; gateway in front of model serving.
- **Why next:** you have every tool. Now apply them to a question of your own.

### Phase 8: Capstone

- **Choose** one of the ten [capstone projects](capstones/README.md), or propose your own in the same format.
- **Write a proposal:** problem, who has it, the gap, the research question, the hypothesis, the baseline, the measures.
- **Build** the system, reusing Runway's components where they fit.
- **Run** the experiments, including failure and adversarial cases.
- **Harden and defend:** threat model, supply chain (SBOM, signed images, vulnerability scans), fuzzing, a failure demo, a reproducible report with limits and negative results, and a presentation.
- **Career signal:** the strongest single piece of evidence in your portfolio, and a writing sample for research applications.

---

## 5. Foundation-gap ledger

This table shows each foundation gap, where it's introduced, where it's practised, what evidence **closes** it, and what remains outside this path. Use it to plan, to track yourself, and to explain your progression in interviews (see [§11](#11-career-map)).

| # | Gap | Why roles care | Introduced | Practised | Closed by (evidence) | Not covered |
|---|---|---|---|---|---|---|
| 1 | Shell: paths, pipes, environment | Every infrastructure role lives in a terminal | 0 | Every phase | Phase 0 `ss` transcript; Phase 5 runbooks | Full Linux administration |
| 2 | Git, GitHub and CI | Team workflow, reproducibility | 0 | Every phase; 5 CD | Red-then-green CI history; Phase 5 pipeline | Large-team release engineering |
| 3 | Go | The language of cloud-native infrastructure | 0 | 1–8 | Your Runway repository | Runtime internals |
| 4 | HTTP and API design | Backend, platform | 0 | 1 contracts; 2 gRPC; 6 auth | Contract tables and tests | GraphQL |
| 5 | Testing and TDD | Every role; a seniority signal | 0 | 1 TDD; 2 integration; 3 contract tests; 4 simulation; 8 fuzzing | Red-green history; real-broker tests; Raft simulation | Mutation testing |
| 6 | Code organisation and design patterns | Reading and writing real codebases | 1 | 2, 3, 6 | Layered Runway; Phase 3's storage swap with no handler changes | Architecture governance across teams |
| 7 | Processes, signals, file descriptors | SRE, systems | 0; 1 | 5 cgroups and limits | Shutdown under load; `/proc` evidence | Kernel scheduling |
| 8 | Concurrency and races | Backend, DS, systems | 1 | 2 workers; Rust Send/Sync; 4 interleavings | A race caught and fixed; compare-and-swap tests | Lock-free algorithms |
| 9 | Python and its tooling | ML, data, SRE scripting | Python Bridge | 2–8 experiments; 7 ML | `kload`; Phase 7 pipeline | Library packaging |
| 10 | Measurement and experimental method | Performance, SRE, research | 1; Python Bridge | 3 query plans; 5 capacity; 7 statistics; 8 capstone | Reproducible experiments with confidence intervals | Advanced statistics |
| 11 | Sockets, TCP/UDP, DNS | Infrastructure, DS | 2 | 5 DNS and load balancing; 6 TLS | Packet captures, explained | Kernel network stack |
| 12 | Messaging and event-driven design | Backend, DS, platform | 2 | 3 outbox and Kafka | Kill-a-worker experiment; outbox crash test | Kafka operations at scale |
| 13 | Serialization and schema evolution | DS, platform | 2 | 3 migrations | Upcasting tests; protobuf compatibility | Schema registries |
| 14 | Memory and ownership | Systems, storage | Rust Bridge | 3 audit log; 5 limits | Rust exercises; an observed OOM kill | Allocators |
| 15 | SQL, indexes, query plans | Every backend | 3 | 6 tenant queries; 7 analysis | Migrations; before-and-after `EXPLAIN ANALYZE` | Optimizer internals |
| 16 | Transactions, isolation, connection pools | Backend, DB | 3 | 4 consensus vs transactions | A reproduced anomaly; a pool-exhaustion experiment | Distributed transactions in production |
| 17 | Files, `fsync`, crash consistency | Storage, systems | Rust Bridge / 3 | 4 Raft persistence | Torn-write recovery; kill tests | Power-loss faults |
| 18 | Caching | Backend, performance | 3 | 6 rate limiting | Hit-rate and stampede measurements | CDN operations |
| 19 | Backup and restore | SRE, DB | 3 | 5 runbook | A restore drill | Point-in-time recovery at scale |
| 20 | Failure models, clocks, consensus | DS | 4 | 5 game day | Raft under randomised partitions; a bug write-up | Byzantine faults (named, not built) |
| 21 | Sharding, consistent hashing, leases | DS, storage | 4 | 5, 7 | Rebalancing measurements; fencing-token tests | Global geo-partitioning |
| 22 | Formal methods (TLA+) | DS research | 4 | 8 | TLC checks an invariant | Proofs |
| 23 | Containers and Kubernetes | Platform, DevOps, SRE | 5 | 8 | Manifests, Helm, a controller | Multi-cluster operations |
| 24 | Load balancing and service discovery | Infrastructure | 5 | 6 | L4/L7 experiments; readiness behaviour | Global traffic management |
| 25 | Cloud (AWS) and infrastructure as code | Cloud, platform | 5 | 8 | Runway deployed with Terraform, then destroyed | A second cloud |
| 26 | Observability and SLOs | SRE, platform | 1 | 5, 7 | A dashboard, an SLO, burn-rate alerts | Telemetry at huge scale |
| 27 | Incident response | SRE | 5 | 8 | A game day and a postmortem | Real on-call |
| 28 | Authentication, authorization, multi-tenancy | Security, platform | 2 (credentials); 6 | 8 | Allowed, denied, cross-tenant and replay tests | Enterprise IAM administration |
| 29 | TLS, PKI, mTLS, secrets | Security, infrastructure | 6 | 8 | A local CA, mTLS, rotation | Public PKI operations |
| 30 | API security and rate limiting | Backend, security | 0 validation | 1 limits; 3 injection; 6 OWASP, rate limits and fuzzing; 8 fuzzing | OWASP test cases; fuzzing findings | Penetration testing |
| 31 | Data engineering and big data | Data, ML infrastructure | 7 | 8 | A pipeline from events to Parquet; a MapReduce/Spark job | Streaming at scale |
| 32 | ML, deep learning, MLOps, AIOps | ML infrastructure, applied ML | 7 | 8 | Models with baselines; MLflow registry; a scored anomaly detector | Research-level ML |
| 33 | Supply-chain security | DevSecOps | 5 (pinned versions, digests, immutable tags, ECR scanning) | 8 | SBOM, signing, clean scans | Formal SLSA certification |
| 34 | Research method and technical writing | MSc, senior roles | Python Bridge | 7, 8 | The capstone report and defence | Peer-reviewed publication |
| 35 | Algorithms and data structures | Every coding interview | [dsa/](dsa/README.md) from Phase 0 | Continuous | Problem log; mock interviews | Competitive programming |
| 36 | System design | Interviews from mid-level up | [system-design/](system-design/README.md) from Phase 2 | Continuous | Scored designs, including "10M requests a second" | — |
| 37 | Communication | Every role | 0 learned.md | Every phase; 8 defence | Explanations, postmortems, the capstone talk | — |

**How to use it:** copy this table into your own repository and add a column for **your** evidence link. When the column is full, the gap is closed.

---

## 6. Patterns ledger

Every pattern is built in working code at the point where the system needs it. Knowing when **not** to use a pattern matters as much as knowing it.

| Pattern | Problem it solves | Where | Don't use it when |
|---|---|---|---|
| Guard clause | Bad input reaching the main logic | 0 | — |
| Table-driven tests | Many similar cases | 0 | The cases need very different setup |
| Test-driven development | Untested code; unclear requirements | 0; default from 1 | Throwaway spikes |
| Layered architecture / ports and adapters | HTTP or storage details leaking into rules | 1 | A 50-line script |
| Repository | Storage details in business logic | 1; 3 | Complex reporting queries |
| Dependency injection, composition root | Hidden globals; untestable code | 1 | You'd need a framework to do it |
| Middleware / decorator | Cross-cutting concerns | 1, 2, 6 | The logic belongs to one handler |
| Functional options | Many optional settings | 1 | One or two settings |
| Entity, value object, state machine | Scattered rules; illegal states | 1 | Plain CRUD |
| Optimistic concurrency (compare-and-swap) | Lost updates | 1, 2, 3 | Contention is constant (use a lock) |
| Timeouts and deadline propagation | Work that never ends | 1, 2 | — |
| Graceful shutdown | Lost in-flight work | 1, 2 | — |
| Worker pool and bounded queue | Unbounded concurrency; hidden overload | 2 | The work is trivial |
| Event-driven architecture | Tight coupling between services | 2 | You need an immediate answer |
| Envelope, versioning, upcasting | Changes breaking consumers | 2 | — |
| Tolerant reader | New fields breaking old readers | 2 | Public, untrusted input |
| Bounded context | One word meaning different things | 2 | One small team and model |
| Idempotency key / idempotent receiver | Duplicates from retries | 2, 3 | Naturally idempotent operations |
| Retry with backoff and jitter | Transient failures; retry storms | 2 | Non-idempotent operations |
| Circuit breaker | Hammering a failing dependency | 2, 3 | Rare calls; cheap failure |
| Dead-letter queue | Poison messages blocking the rest | 2 | — |
| Crash-only design | Rarely-tested recovery code | 2, 5 | Restart is very expensive |
| Unit of work | Partial writes | 3 | — |
| Transactional outbox / inbox | Database and broker writes that can't be atomic | 3 | Nothing outside the database cares |
| Log-based streaming (consumer groups, replay) | Many consumers; reprocessing history | 3 | One consumer; no replay needed |
| Event sourcing | Full history and audit | 3 | Most CRUD data |
| Cache-aside, singleflight | Slow reads; cache stampedes | 3 | Data that must always be fresh |
| Competing background jobs (`SKIP LOCKED`) | Many workers on one table | 3 | One worker |
| Contract tests | Implementations of one interface drifting | 3 | — |
| Replicated state machine | One machine's failure taking everything down | 4 | One machine plus backups is enough |
| Leader election, leases, fencing tokens | Deciding who decides; stale lock holders | 4 | — |
| Consistent hashing and sharding | Data too big or too hot for one node | 4 | It still fits on one machine |
| Deterministic simulation testing | Rare distributed bugs | 4 | — |
| Two-phase commit vs saga | Atomicity across services | 4 (compared) | — |
| Reconciliation loop | Drift between desired and actual state | 5 | One-shot tasks |
| Twelve-factor config | Images that only run in one environment | 5 | — |
| Canary rollout | A bad release reaching every user at once | 5 | Too little traffic to judge a small share |
| Build once, deploy by digest | Shipping something other than what was tested | 5 | — |
| Backpressure | A slow consumer turning into failures upstream | 2, 5 | Work that is better dropped than delayed |
| Sidecar | Adding a capability without changing the app | 5 (discussed), 6 | It doubles resource use for little gain |
| Liveness vs readiness | Bad restarts; traffic sent before ready | 5 | — |
| Load balancing and service discovery | Spreading load; finding instances | 5 | One instance |
| Infrastructure as code | Snowflake environments | 5 | — |
| Policy decision and enforcement points | Authorization logic everywhere | 6 | — |
| Token-bucket rate limiting | Abuse; noisy neighbours | 6 | — |
| Tenant isolation | One tenant seeing or starving another | 6 | Single-tenant systems |
| Signed, replay-protected messages | Forged or replayed requests between parties | 6 | Callers you can already authenticate with mTLS |
| Dynamic secrets | Long-lived credentials leaking | 6 | Secrets no system can mint (a partner's API key) |
| Transparency log (Merkle tree with a witness) | History rewritten by whoever runs the log | 6 | Logs nobody outside the operator needs to trust |
| Feature pipeline with train/serve parity | Training/serving skew | 7 | — |
| Model registry and shadow deployment | Unsafe model releases | 7 | — |
| Defence in depth / zero trust | A single control failing | 6, 8 | — |

---

## 7. Languages and tools

| Language | Enters | Role | Why |
|---|---|---|---|
| **Bash** | 0 | Running, inspecting and automating | Every server is operated from a shell |
| **Go** | 0 | APIs, workers, Raft, controllers | Most cloud-native infrastructure is written in Go |
| **Python** | Python Bridge | Load generation, experiments, data, ML | The language of measurement, data and ML |
| **Rust** | Rust Bridge | The audit log, byte-level parsing | Memory safety without a garbage collector; makes bytes and ownership explicit |
| **SQL** | 3 | Durable records, analysis | Every backend and data role needs it |
| **TLA+** | 4 | Model-checking a protocol | Standard where consensus correctness matters |
| **HCL (Terraform)** | 5 | Infrastructure as code | Expected in cloud and platform roles |
| **YAML** | 0 (CI); 5 | Workflows, Kubernetes manifests | Everywhere in operations |

**The principle:** Go for the control plane, Rust for the data plane, Python for measurement and ML.

**One tool per job, with alternatives studied but not rebuilt:**

| Job | Core | Compare only |
|---|---|---|
| HTTP routing | Go `net/http` | chi, Gin |
| Work queues | RabbitMQ | SQS (seen on AWS in Phase 5) |
| Event streams | Kafka | NATS JetStream, Redpanda |
| RPC | gRPC and protobuf | HTTP/JSON |
| Database | PostgreSQL (pgx, goose) | DynamoDB |
| Cache | Redis | Memcached |
| Consensus | Your own Raft | hashicorp/raft, etcd |
| Orchestration | Kubernetes (kind), Helm; ECS on AWS | EKS, Nomad |
| Cloud | AWS with Terraform | GCP, Azure |
| Observability | OpenTelemetry, Prometheus, Grafana | Loki, Tempo |
| ML | scikit-learn, PyTorch, MLflow, FastAPI | KServe |
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
| Job applications | Phase 5 (earlier for backend roles) | Tailored, with evidence links | See [§11](#11-career-map) |

---

## 9. Books

Each guide tells you exactly which chapter or paper to read, at the step where it helps. This is just the shelf.

| Book | Free? | Used in |
|---|---|---|
| *Operating Systems: Three Easy Pieces* (Arpaci-Dusseau) | [Yes](https://pages.cs.wisc.edu/~remzi/OSTEP/) | 0, 1, Rust, 3, 5 |
| *Computer Systems: A Programmer's Perspective* (Bryant & O'Hallaron, 3rd ed.) | No | 0, 1, 2, Rust, 3, 5 |
| *Computer Networking: A Top-Down Approach* (Kurose & Ross, 8th ed.) | No | 0, 2, 4, 5, 6 |
| *Designing Data-Intensive Applications* (Kleppmann) | No | 1–4, 7 |
| *Understanding Distributed Systems* (Vitillo) | No | 1–5 |
| *Distributed Systems* (van Steen & Tanenbaum, 4th ed.) | [Yes](https://www.distributed-systems.net/) | 2, 4, 5, 6 |
| *Site Reliability Engineering* (Google) | [Yes](https://sre.google/books/) | 1, 2, 3, 5, 7 |
| *The Rust Programming Language* | [Yes](https://doc.rust-lang.org/book/) | Rust Bridge |
| *Rust Atomics and Locks* (Bos) | [Yes](https://marabos.nl/atomics/) | Rust Bridge, 4 |
| *Database Internals* (Petrov) | No | 3, 4 |
| *Kubernetes in Action* (Lukša) | No | 5 |
| *Systems Performance* (Gregg, 2nd ed.) | No | 5, 7 |
| *Security Engineering* (Anderson, 3rd ed.) | Partly | 1, 6, 8 |
| *Designing Machine Learning Systems* (Huyen) | No | 7 |
| *The Linux Command Line* (Shotts) | [Yes](https://linuxcommand.org/tlcl.php) | Reference |

---

## 10. Timeline and progress tracker

These estimates assume 12–15 focused hours a week. A phase ends when its evidence is in place, not when the weeks run out.

| Phase | Weeks | Done | Evidence link | Exercise | Essay |
|---|---|---|---|---|---|
| 0. Request | 2 | ☐ | | tempconv ☐ | ☐ |
| 1. Reliable service | 4 | ☐ | | shortlinks ☐ | ☐ |
| Python Bridge | 2 | ☐ | | logstat ☐ | — |
| 2. Connected services | 4 | ☐ | | hookshot ☐ | ☐ |
| Rust Bridge | 3 | ☐ | | ☐ | — |
| 3. Durable data | 7 | ☐ | | ☐ | ☐ |
| 4. Replicate and scale | 10 | ☐ | technical report | ☐ | ☐ |
| 5. Operate | 9 | ☐ | postmortem | ☐ | ☐ |
| 6. Secure | 10 | ☐ | threat model, game-day report | flagpole ☐ | ☐ |
| 7. Measure and learn | 8 | ☐ | experiment report | ☐ | ☐ |
| 8. Capstone | 10+ | ☐ | final report and talk | — | ☐ |
| **Total** | **~69** | | | | |

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

| Role | Competitive after | Strong after | Evidence to show | Typical loop | Still needed for strong |
|---|---|---|---|---|---|
| Backend Engineer | 1 | 3 | Layered service with TDD; PostgreSQL, outbox, caching; messaging with idempotency | Coding, API and system design, behavioural | Product and frontend breadth |
| Platform / Developer Infrastructure Engineer | 5 | 5 + platform design track | A reconciler, pipelines, Helm, golden paths | Platform design, Kubernetes, coding | Running a platform for real users |
| Site Reliability / Production Engineer | 5 | 8 | SLOs, burn alerts, a game-day postmortem, runbooks, capacity data | Coding, troubleshooting, large-scale design, incident scenarios | Real on-call |
| Cloud / Infrastructure Engineer | 5 | 5 + the AWS work | Terraform on AWS, networking, Kubernetes, IAM | Cloud architecture, networking, troubleshooting | Production cloud ownership; optional AWS SAA certificate |
| DevOps Engineer | 5 | 5 + 8 | CI/CD, images, infrastructure as code, supply-chain scans | Linux, CI/CD design, scripting | Shared infrastructure for a team |
| Distributed Systems Engineer | 4 | 4 + 5 + distributed design track | Your own Raft with simulation, Porcupine and TLA+; sharding; leases | Harder DSA, distributed design, consensus deep dives | Production scale; often mid-level roles |
| Storage / Database Engineer | 3 (application side) | Stretch for engine teams | Rust log with crash tests; query plans; restore drills | DSA, storage internals, C++ or Rust | A larger storage engine; C++ |
| Data Infrastructure Engineer | 7 | 7 + Kafka depth | Kafka, the pipeline, Parquet and DuckDB, Spark basics | Data system design, SQL, coding | Streaming at scale |
| Systems Software Engineer | Stretch after Rust + 3 | Competitive after 4 | Rust log; concurrency; Raft | C or Rust, OS questions | C and kernel internals |
| Infrastructure Security Engineer | 6 | 8 | Threat model, mTLS, policy, tenant isolation, SBOM, fuzzing | Security design review, threat modelling | Offensive practice; cloud-security depth |
| ML Infrastructure / MLOps Engineer | 7 | 7 + applied-ML design track | Registry, serving behind a gateway, monitoring, Kubernetes | ML system design, infrastructure design | GPU scheduling; distributed training |
| Applied ML Engineer | Stretch after 7 | Competitive after 7 + more modelling | Phase 7 models with rigorous evaluation | ML system design, ML fundamentals | Modelling depth; statistics |
| Research MSc (systems and networking) | 4 + a technical report | 8 | The capstone report, TLA+ model, paper notes | Statement of purpose; supervisor fit | Maths readiness; publication optional |

### When to start applying

| After | Apply for |
|---|---|
| Phase 1 | Junior backend roles (with DSA practice under way) |
| Phase 3 | Backend roles generally; data-heavy backend roles |
| Phase 4 | Distributed-systems roles (expect a high coding bar) |
| Phase 5 | **The main wave:** SRE, platform, DevOps, cloud and infrastructure |
| Phase 7 | Data infrastructure, ML infrastructure and MLOps |
| Phase 8 | Security-leaning infrastructure roles; MSc applications, with the capstone as a writing sample |

### Preparing for the interview loop

| Loop part | What's being judged | Prepare with |
|---|---|---|
| Coding | Problem solving, clean code, testing, communication | [dsa/](dsa/README.md) |
| System design | Problem navigation, solution design, technical excellence, communication | [system-design/](system-design/README.md), in your role's track |
| Domain deep dive | Whether you really built what you claim | Your Runway repository and capstone; be able to rebuild any part on a whiteboard |
| Behavioural | Ownership, conflict, failure, learning | Postmortems and failure notes, written as stories |

### Telling your progression story

The gap ledger is your story. For any role, pick the rows its job description cares about and say, for each: **"I didn't know X. I closed it in Phase N by doing Y, and here's the evidence: Z."** For example:

> "I'd used queues but never reasoned about delivery guarantees. In Phase 2 I killed a worker mid-job and showed, with a test, that an idempotency key made the retry safe. Here's the test and the trace."

That's specific, checkable, and shows you learn by building. It's far stronger than a list of technologies.
