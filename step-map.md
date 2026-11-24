# Step map: every current step and its new home

Working file for the restructure (plan.md §9). It lives only on the `restructure` branch and is deleted before the merge.

**Rule:** an old guide's folder is deleted only when every row for it is `done`.

**Kinds:**
- **move:** the step goes over unchanged. Paths are fixed and the replay proves it still works.
- **split:** the step is re-based onto its new starting point, rebuilt, re-captured and replayed.
- **absorb:** the step's content goes into a new lesson that's written from scratch.
- **deep dive:** the step moves into an optional `deep-dives/` folder.

**Status:** `todo` → `done`. The six proposed placements were accepted on 2026-11-18.

Short names: C01–C08 = `2-core/01…08`; F01–F04 = `1-foundations/01…04`; AI, ST, CN = the three tracks (AI infrastructure, storage engines, cloud and network). Unit names are the shared units.

## Phase 0: `lessons/00-request-service` (standalone)

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 0 | The terminal | F02 lesson 01 (the terminal and the shell) | absorb | done |
| 1 | A program and a process | F02 lesson 04 (program vs process); the first Go program is F01's Day-1 program | absorb | done |
| 2 | What a request and a response are | F04 lesson 05 (what a request and a response are) | absorb | done |
| 3 | Turn the program into a server | C01 lesson 03 | split | done |
| 4 | Give the response a contract | C01 lesson 03 | split | done |
| 5 | A router, a greeting, and input validation | C01 lesson 03 | split | done |
| 6 | Tests at three levels | C01 lesson 04 | split | done |
| 7 | Your own repository and CI | C01 lesson 04 | split | done |
| exercises | tempconv | C01 exercises.md | move | done |

## Phase 1: `lessons/01-reliable-service`

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 1 | The domain, written test-first | C01 lesson 05 | split | done |
| 2 | A repository, and your first data race | C01 lesson 06 | split | done |
| 3 | The service, and a race a mutex can't fix | C01 lesson 07 | split | done |
| 4 | The HTTP API | C01 lesson 08 | split | done |
| 5 | The composition root and configuration | C01 lesson 09 | split | done |
| 6 | Deadlines and cancellation | C01 lesson 10 | split | done |
| 7 | Logs, metrics and panic recovery | C01 lesson 11 | split | done |
| 8 | Signals and graceful shutdown | C01 lesson 12 | split | done |
| exercises | shortlinks | C01 exercises.md | move | done |

## Phase 2: `lessons/02-connected-services`

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 1 | Accept now, run later | C01 lesson 13 | split | done |
| 2 | Messages, a bus, and an event-driven worker | Messaging and resilience lessons 01–03 | split | done |
| 3 | RabbitMQ, and two separate processes | Messaging and resilience lessons 02–03 and 06 | split | done |
| 4 | Idempotency, end to end | C01 lesson 14 · Messaging and resilience lessons 03 and 06 | split | done |
| 5 | Retries, versioning, dead letters and a circuit breaker | C01 lesson 14 · Messaging and resilience lessons 01 and 04–06 | split | done |
| 6 | gRPC and Protocol Buffers | C01 lesson 15 | split | done |
| 7 | Look at the wire | C06 lesson 10 | split | done |

## Phase 3: `lessons/03-durable-auditable-data`

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 1 | PostgreSQL behind the same port | C03 lessons 01–04 | split | done |
| 2 | Connection pooling | C03 lesson 04 | split | done |
| 3 | Transactions | C03 lesson 05 (atomic completion and row locking) · ST 01 lesson 01 (isolation anomalies and their alternatives) | split | done |
| 4 | The transactional outbox | Event streams lessons 02–03 and 06 | split | done |
| 5 | Idempotency keys in PostgreSQL | C03 lesson 06 | split | done |
| 6 | Kafka, an event stream | Event streams lessons 01 and 03–06 | split | done |
| 7 | Redis, cache-aside | Caching lessons 01–05 | split | done |
| 8 | Background jobs | ST 01 lessons 02–04 and 07 | split | done |
| 9 | A circuit breaker around the database | Messaging and resilience lessons 03 and 05 | split | done |
| 10 | The audit log, in Rust | ST 04 lesson 03 | split | done |
| 11 | Backup, restore and crash recovery | ST 01 lessons 05–07 | split | done |

## Phase 4: `lessons/04-replicated-state`

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 1 | A simulated network, and what a node can know | C07 lesson 01 | split | done |
| 2 | Raft, part 1, electing a leader | C07 lesson 02 | split | done |
| 3 | Raft, part 2, replicating the log | C07 lessons 03–04 | split | done |
| 4 | Persistence, what must be saved first | C07 lessons 05–06 (simulated disk, then Rust `klog`) | split | done |
| 5 | Snapshots and log compaction | ST 02 lessons 02–03 | split | done |
| 6 | Partial partitions, PreVote and CheckQuorum | ST 02 lesson 04 · CN 01 lesson 08 teaches the network side and links here | split | done |
| 7 | A replicated key-value store, checked for linearizability | ST 02 lessons 01 and 05 | split | done |
| 8 | Running it for real | C07 lessons 07–08 (real processes and the gate) | split | done |
| 9 | A TLA+ model of elections | ST 02 lesson 06 | split | done |
| 10 | Locks with leases, and fencing tokens | C07 lesson 09 | split | done |
| 11 | Consistent hashing, and a cache spread over several servers | C07 lesson 10 | split | done |
| 12 | Transactions across shards | ST 02 lesson 08 | split | done |
| exercises | Chain replication | ST 02 exercises.md | move | done |

## Phase 5: `lessons/05-constrained-operations`

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 1 | Containers are processes | C08 lesson 01 | split | done |
| 2 | The whole of Runway in Docker Compose | C03 lesson 08 (Switchyard, worker, and Postgres on the project network) | split | done |
| 3 | Kubernetes on kind | Kubernetes and delivery lesson 01 | split | done |
| 4 | Services, DNS and load balancing | Kubernetes and delivery lesson 02 | split | done |
| 5 | All of Runway on Kubernetes | Kubernetes and delivery lesson 03 | split | done |
| 6 | `metad` as a StatefulSet | Kubernetes and delivery lesson 04 | split | done |
| 7 | Helm and safe rollouts | Kubernetes and delivery lesson 05 | split | done |
| 8 | CI/CD: build once, test it, publish it by digest | Kubernetes and delivery lesson 06 | split | done |
| 9 | Tracing with OpenTelemetry | C06 lesson 13 (span ancestry and a local exporter) · Kubernetes and delivery lesson 07 (collector and deployment wiring) | split | done |
| 10 | Prometheus, SLOs and burn-rate alerts | SLOs and alerts → C08 lesson 05; Prometheus, Grafana, burn-rate → Kubernetes and delivery lesson 08 | split | done |
| 11 | A controller of your own | Kubernetes and delivery lesson 09 | split | done |
| 12 | A game day | C08 lesson 07 (runbook, postmortem) · CN 01 lessons 08–09 (impairment and diagnosis) | split | done |
| 13 | Runway on AWS, with Terraform | AWS and Terraform lessons 01–06 | split | done |

## Phase 6: `lessons/06-safe-shared-queries`

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 1 | A threat model | C08 lesson 02 | split | done |
| 2 | Tokens | Tenancy and abuse control lessons 01–03 | split | done |
| 3 | Authorization | C08 lessons 02–03 · Tenancy and abuse control lessons 05, 07–08 | split | done |
| 4 | Tenants | Tenancy and abuse control lessons 04 and 08 | split | done |
| 5 | Rate limiting | Tenancy and abuse control lessons 05–06 and 08 | split | done |
| 6 | Signed webhooks | CN 03 lesson 05 (signature, freshness, idempotent receipt, and destination policy) | split | done |
| 7 | TLS and your own certificate authority | C08 lesson 03 (lab CA and mTLS) · CN 03 lessons 03–04 (per-peer identity and leaf rotation) | split | done |
| 8 | A sidecar proxy | CN 03 lesson 03 (management mTLS and a private Unix socket) | split | done |
| 9 | Secrets | Kept out of code → C08 lesson 04; OpenBao and key rotation → CN 03 lesson 06 | split | done |
| 10 | A tamper-evident audit log | ST 04 lessons 04–05 | split | done |
| 11 | Privacy | C08 lesson 04 (data inventory and log canary) · Tenancy and abuse control retention and aggregate privacy exercise | split | done |
| 12 | Cluster hardening | Kubernetes and delivery lesson 10 | split | done |
| 13 | A security game day | C08 lessons 03–04 and 07 (core controls and verification) · CN 03 lesson 08 (proxy control-plane game day) | split | core and proxy game days done |

## Phase 7: `lessons/07-utility-evaluation`

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 1 | Experiments done right | C02 lessons 07–08 (experiments, repeat runs, confidence intervals) and Go benchmark comparison · historical plots in AI deep-dives evidence | split | done |
| 2 | Jobs that do real work | AI 01 lesson 01 (synthetic workload) | split | done |
| 3 | A data contract and an event pipeline | AI 01 lessons 01–03 (event export to Parquet) · Event streams (Kafka replay) | split | done |
| 4 | Big data, honestly | AI deep dive on MapReduce, Spark and COST, with local aggregation replay, Spark parity, and historical plot | deep dive | done |
| 5 | The dataset, and the baselines to beat | AI 01 lessons 03–04 | split | done |
| 6 | Gradient-boosted trees, honestly compared | AI deep dive with residual-stump replay, held-out boosted model comparison, and point-in-time exercise | deep dive | done |
| 7 | Neural networks, from scratch and in PyTorch | PyTorch → AI 01 lesson 04; from scratch → AI deep dive with finite differences and CPU PyTorch gradient parity | split | done |
| 8 | Serving predictions | AI 01 lessons 06 and 08–09 | split | done |
| 9 | Using the predictions | AI 01 lesson 07 (scheduling simulation) | split | done |
| 10 | Models with a history | AI 01 lessons 05 and 08–09 | split | done |
| 11 | Watching a model in production | AI 01 lessons 07 and 09 (input drift) | split | done |
| 12 | Finding incidents nobody wrote a rule for | AI operations deep dive with local detector replay and held-out isolation-forest evaluation | deep dive | done |
| 13 | The report | AI 01 lesson 09 and evidence | split | done |

## Phase 8: `lessons/08-ai-infrastructure` → `3-tracks/ai-infrastructure/02-serving-and-scaling-models`

Moved 2026-11-18, one lesson file per step (setup in `00-before-you-start.md`). Phase 8 starts from scratch (no `continue:`); batch 12 re-bases it onto the end of the core.

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 1 | What a model server does | AI 02 lesson 01 | move | done |
| 2 | A real model, and honest streaming measurements | AI 02 lesson 02 | move | done |
| 3 | Batching, concurrency and the knee | AI 02 lesson 03 | move | done |
| 4 | Put an admission boundary on Runway | AI 02 lesson 04 · Rust companion in AI 03 lessons 03–05 | move | done |
| 5 | Observe the user contract | AI 02 lesson 05 · Rust companion in AI 03 lessons 02 and 06 | move | done |
| 6 | Deploy a slow-starting dependency | AI 02 lesson 06 | move | done |
| 7 | A supply chain for code and weights | AI 02 lesson 07 (Kubernetes and delivery teaches signing first) | move | done |
| 8 | Benchmark performance, cost and quality together | AI 02 lesson 08 | move | done |
| 9 | Failure, recovery and the game day | AI 02 lesson 09 | move | done |
| 10 | Data parallelism, with a reference you can check | AI 02 lesson 10 | move | done |
| 11 | Split the model, not just the examples | AI 02 lesson 11 (Megatron-style detail → deep dive in batch 12) | move | done |
| 12 | Ray, and where distribution helps | AI 02 lesson 12 | move | done |
| 13 | CUDA, transfers, and vLLM | AI 02 lesson 13 | move | done |
| 14 | A report that preserves the limits | AI 02 lesson 14 | move | done |

## Phase 9: `lessons/09-secure-ai-layer` → `3-tracks/ai-infrastructure/04-securing-the-ai-layer`

Moved 2026-11-18; replays from the moved Phase 8.

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 1 | A threat model for the AI layer | AI 04 lesson 01 | move | done |
| 2 | How to attack a system | AI 04 lesson 02 | move | done |
| 3 | Retrieval over the tenant's runbooks and jobs | AI 04 lesson 03 | move | done |
| 4 | A tool-using agent | AI 04 lesson 04 | move | done |
| 5 | Authorization outside the model | AI 04 lesson 05 | move | done |
| 6 | Direct prompt injection | AI 04 lesson 06 | move | done |
| 7 | Indirect injection and approval for side effects | AI 04 lesson 07 | move | done |
| 8 | Unsafe model output | AI 04 lesson 08 | move | done |
| 9 | Leaks between tenants | AI 04 lesson 09 | move | done |
| 10 | Secrets and canary tokens | AI 04 lesson 10 | move | done |
| 11 | Resource abuse and per-tenant limits | AI 04 lesson 11 | move | done |
| 12 | The AI supply chain | AI 04 lesson 12 | move | done |
| 13 | The adversarial suite | AI 04 lesson 13 | move | done |
| 14 | Red team, then the report | AI 04 lesson 14; plan.md's "red-team exercise" deep dive is this step's extension | move | done |

## Python Bridge: `lessons/python-bridge` → `2-core/02-python-runtime-and-honest-measurement`

Moved 2026-11-18; rebuilt in batch 4 (2026-11-20): steps 2–3 became C02 lesson 04, step 4 lesson 05, step 5 lesson 06 (now with its own HTTP client, a dispatcher, and a closed loop on the same schedule), step 6 lesson 07; lessons 01–03 and 08 are new.

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 1 | A first script, a first function, a first test | F04 lesson 06 absorbs it (batch 2); the C02 copy is dropped in batch 4 (decided 2026-11-18) | move | done |
| 2 | Why averages lie: percentiles | C02 lesson 04 | split | done |
| 3 | A package and a command line | C02 lesson 04 | split | done |
| 4 | An HTTP client, tested without a network | C02 lesson 05 | split | done |
| 5 | Load on a schedule: asyncio and coordinated omission | C02 lesson 06 | split | done |
| 6 | Analysis, plots, and three real experiments | C02 lesson 07 | split | done |

## Performance Bridge: `lessons/perf-bridge` → `2-core/06-linux-networking-and-profiling`

Moved 2026-11-18. Batch 8 adds Linux internals and the Go ↔ Rust wire around it.

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 1 | A slow service, and the USE method | C06 | move | done |
| 2 | Waiting: mutex and block profiles | C06 | move | done |
| 3 | Computing: CPU profiles and flame graphs | C06 | move | done |
| 4 | perf: the whole machine's view | C06 | move | done |
| 5 | strace: what is it asking the kernel? | C06 | move | done |
| 6 | The kernel's view, with eBPF | C06 · CN 03 lesson 07 (pass-through XDP counter) | move | done |
| 7 | Memory and the garbage collector | C06 | move | done |
| 8 | The method, end to end | C06 | move | done |

## Networking Bridge: `lessons/network-bridge` (standalone)

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 1 | A network you can break | C06 lesson 10 | split | done |
| 2 | What loss does to TCP | C06 lessons 10 and 14 (drops, retransmits, and impairment) · CN 01 lessons 01–03 | split | done |
| 3 | Congestion control | CN 01 lessons 03–04 | split | done |
| 4 | Head-of-line blocking | CN 01 lesson 05 | split | done |
| 5 | CDNs, anycast and BGP | CN 01 lessons 06–07 | split | done |
| 6 | The method | CN 01 lessons 08–09 | split | done |
| exercises | Fix the queue and measure a real path | CN 01 exercises.md | move | done |
| review | Self-test and evidence prompts | CN 01 self-check.md | absorb | done |

## Rust Bridge: `lessons/rust-bridge`

Taught today side by side with Go; rule 3 says Rust is taught on its own terms, so these become new lessons. The record format and crash-safe log become `klog`.

| Step | Title | New home | Kind | Status |
|---|---|---|---|---|
| 1 | A first program | C04 lesson 01 | absorb | done |
| 2 | Ownership and borrowing | C04 lessons 02 and 05 | absorb | done |
| 3 | Errors as values | C04 lesson 03 | absorb | done |
| 4 | Bytes and a record format | C04 lesson 06 | absorb | done |
| 5 | A log file that survives crashes | C04 lessons 07–09 and the gate | absorb | done |
| 6 | Threads, safely | C05 lesson 04 and the ring in lessons 05–07 | absorb | done |

The original Phase 3 replay used the Rust Bridge. The active audit and Rust Foundations replays use the new layout, and the legacy tree has been removed.

## Other files

| Today | New home | Status |
|---|---|---|
| Phase 1 and Phase 4 exercises | Core 01 `shortlinks` and Storage 02 `chainkv` in the matching `exercises.md` | done |
| Phase 2, 3, 5, 6 and 7 exercises and Rust Bridge exercise | Messaging `hookshot`, Storage 01 `ledger`, Core 08 `beacon` and two regions, Tenancy `flagpole`, AI 01 `buildcast`, Core 04 `bitlog`. Each is linked from its module's `exercises.md`. | done |
| Legacy review questions and evidence worksheets | The matching module's `self-check.md` or linked `extended-review.md`. Phase 1–7 and Rust Bridge review sheets now have new entry points. | done |
| `lessons/_TEMPLATE.md` | `scripts/templates/` | done |
| `capstones/` (12 briefs, KESTREL) | removed (in git history) | done |
| `open-source/` | removed | done |
| `notes/decisions.md`, `failures.md`, `research-track.md` | removed (in git history; private copies in `~/blueprint-scratch/private/`) | done |
| `scripts/check_guides.py`, `test_all.sh` | `replay_lessons.py`, `check_all.sh` | done |
| `JOURNEY.md` ledgers (foundation gaps, patterns) | each module page's own "gaps closed" and "patterns introduced" sections (decided 2026-11-18) | done |
| `JOURNEY.md` career map | `career.md` | done |
