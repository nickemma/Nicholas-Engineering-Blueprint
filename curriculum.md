# Curriculum

The companion to [`structure.md`](structure.md). The roadmap says **what** we build and in what order. This file says **how**: which languages and tools enter at each phase, which foundation gaps we close there, what to read (book, chapter, and timing), which careers each phase opens, and how it all prepares for a research MSc in secure distributed systems.

> The rule from the roadmap still holds: **one active phase, one project, one next problem.** Reading and gap-filling serve the build. They never replace it.

---

## 1. Destination

A **Distributed Systems & AI Infrastructure Engineer** who can design, build, secure, operate, and explain a production-grade distributed AI platform, and who arrives at a thesis-based MSc ready to do research in **secure distributed systems**.

Two outcomes, one path:

| Outcome | What proves it |
|---|---|
| Industry-ready | A deployed, observable, multi-tenant AI platform with incident reports, runbooks, and a threat model |
| Research-ready | Paper notes, a reproduced result, a tested consensus implementation, and a short technical report on a failure or security property you measured |

---

## 2. Languages: who does what

| Language | Enters | Role in the platform | Why this split |
|---|---|---|---|
| **Go** | Phase 0 | Services, APIs, workers, control plane, Raft labs | Fast to build networked services; most cloud-native tooling (Kubernetes, etcd, Prometheus) is Go |
| **Rust** | Phase 3 (after the Rust Bridge) | Storage engine, data-plane hot paths, security-sensitive parsing, the mTLS sidecar | Memory safety without garbage collection; used in databases, proxies, and increasingly in infrastructure security |
| **SQL** | Phase 3 | Postgres job store | Every infrastructure role needs it |
| **Bash** | Phase 0, continuous | Automation, diagnostics | Linux fluency |
| **Python** | Phase 6 | Model runtimes, benchmarks, analysis notebooks | The AI serving ecosystem is Python |
| **HCL (Terraform)** | Phase 5 | Cloud infrastructure as code | Required by cloud and platform roles |
| **TLA+** | Phase 4 (light), research track | Specifying and model-checking protocols | Standard in distributed systems research and at companies running consensus |

**Principle:** Go for the control plane, Rust for the data plane. That split mirrors how many real systems are built, and it gives you a defensible answer when an interviewer asks "why two languages?"

---

## 3. Foundation gaps and where they get closed

These are the gaps identified for the target roles. Each is filled in the phase where the system first needs it, never as a separate course.

| Gap | Phase(s) | How the build forces it |
|---|---|---|
| **Linux basics** (shell, files, permissions) | 0 | Running and inspecting your first server |
| **Processes, signals, file descriptors** | 1 | Graceful shutdown on `SIGTERM`; `lsof`, `ulimit` |
| **Concurrency** (threads, locks, races) | 1 | Concurrent requests and `go test -race` |
| **Networking: sockets, TCP, UDP, DNS** | 2, 5 | Two processes talking; `tcpdump`, `ss`, `dig` |
| **Storage and crash consistency** | 3 | `fsync`, write-ahead logs, recovery after a kill |
| **Memory: virtual memory, paging, allocation** | Rust Bridge, 6 | Rust ownership; the KV cache is paging for GPUs |
| **Clocks, partitions, consensus** | 4 | Killing and partitioning nodes with `tc netem` and `iptables` |
| **OS isolation: namespaces, cgroups** | 5 | What a container actually is |
| **Performance analysis** | 5, 6 | USE method, `perf`, flame graphs, GPU utilization |
| **IP, routing, load balancing, data-center networks** | 5, 7 | Kubernetes networking, service routing |
| **Applied cryptography, TLS, PKI** | 7, 8 | Signed API keys, mTLS between services |
| **Web and API security** | 0–1 (validation), 7–8 | Tenant isolation, authorization bugs |
| **Systems security** (capabilities, seccomp, supply chain) | 8 | Hardening the deployed platform |
| **Algorithms and coding interviews** | Parallel track, always | See section 7 |
| **System design breadth** | Parallel track, from Phase 2 | See section 7 |

---

## 4. The phases

Each phase lists:
- **Build**: the system we grow.
- **Learn**: the concepts it needs.
- **Gap-fill**: foundations closed here.
- **Tools**: what you'll use.
- **Read**: book, chapter, and when to read it.
- **Proof**: the exit gate from `structure.md`.
- **Careers opened**: what the phase adds to your profile.
- **Next**: why the next phase follows.

Reading rule: read a chapter **after** you've felt the problem in code, never before. Budget 2–4 hours a week. Skimming is allowed where noted.

---

### Phase 0: Make one request work
*Estimated: 2 weeks*

**Build:** `projects/00-request-service`, a Go HTTP service with `/health`, input validation, and tests.

**Learn:**
- programs vs processes
- ports, HTTP methods, status codes
- JSON
- unit tests with `httptest`
- validating untrusted input

**Gap-fill:**
- Linux shell: navigation, files, permissions, pipes, environment variables
- Git: commits, branches, pushes, `.gitignore`

**Tools:** terminal, Bash, Git, GitHub, Go (`go run`, `go test`, `go vet`, `gofmt`), `curl`, GitHub Actions (one workflow running tests on every push).

**Read:**

| When | Source | Chapters / sections |
|---|---|---|
| Week 1, after the server runs | *Computer Systems: A Programmer's Perspective* (CSAPP, 3rd ed.) | Ch. 1, *A Tour of Computer Systems* |
| Week 1 | *Operating Systems: Three Easy Pieces* (OSTEP) | Ch. 2 *Introduction*; Ch. 4 *The Process*; Ch. 5 *Process API* |
| Week 1–2 | *Computer Networking: A Top-Down Approach* (Kurose & Ross, 8th ed.) | 1.1–1.5; 2.1–2.2 (the Web and HTTP) |
| Week 2, after adding validation | *The Web Application Hacker's Handbook* (2nd ed.) | Ch. 3 *Web Application Technologies* (skim) |

**Proof:** run from a clean checkout, call it with `curl`, change it, explain the request path, and pass CI.

**Careers opened:** foundations only. You're consolidating the backend skills you already use.

**Next:** one endpoint that works isn't a service that survives real traffic. Phase 1 adds real work, concurrency, and failure handling.

---

### Phase 1: Make one service reliable
*Estimated: 4 weeks*

**Build:** `projects/01-reliable-service`, a jobs API (`POST /jobs`, `GET /jobs/{id}`) with in-memory state.

**Learn:**
- data modelling and error design
- `context`, timeouts, and cancellation
- concurrency: goroutines, mutexes, data races
- configuration from the environment
- structured logs and metrics
- graceful shutdown

**Gap-fill:**
- Processes and signals: what `Ctrl+C` and `SIGTERM` actually do
- File descriptors and their limits
- Threads and locks at the OS level
- A first threat-modelling habit: "what could a hostile client send?"

**Tools:** `log/slog`, Prometheus client for Go, `go test -race`, `hey` or `oha` for load, `ps`, `top`, `htop`, `lsof`, `ulimit`, `kill`.

**Read:**

| When | Source | Chapters / sections |
|---|---|---|
| Week 1, before concurrency | OSTEP | Ch. 26 *Concurrency: An Introduction*; Ch. 27 *Thread API*; Ch. 28 *Locks* |
| Week 2, after your first race | OSTEP | Ch. 29 *Lock-based Concurrent Data Structures*; Ch. 30 *Condition Variables*; Ch. 32 *Common Concurrency Problems* |
| Week 2 | CSAPP | Ch. 12 *Concurrent Programming* (12.1, 12.3–12.7) |
| Week 3, before graceful shutdown | CSAPP | Ch. 8 *Exceptional Control Flow* (8.1–8.2, 8.4–8.5: processes and signals) |
| Week 3, after adding metrics | *Site Reliability Engineering* (Google) | Ch. 6 *Monitoring Distributed Systems* (the four golden signals) |
| Week 3 | *Understanding Distributed Systems* (Vitillo, 1st ed.) | *Introduction*; Part IV *Downstream resiliency* (timeouts) |
| Week 4 | *Designing Data-Intensive Applications* (DDIA, 1st ed.) | Ch. 1 *Reliable, Scalable, and Maintainable Applications* |
| Week 4 | Web Application Hacker's Handbook | Ch. 2 *Core Defense Mechanisms* (input handling) |
| Week 4 | *Security Engineering* (Anderson, 3rd ed.) | Ch. 1 *What Is Security Engineering?* |

**Proof:** show a concurrent request, a bad request, and a graceful shutdown under load.

**Careers opened:** a stronger backend profile, plus your first real SRE vocabulary (golden signals, timeouts).

**Next:** everything still lives in one process, so if it dies, the work dies. Phase 2 moves work into a separate process.

---

### Phase 2: Make services work together
*Estimated: 4 weeks*

**Build:** the API plus a background **worker** and a **queue** (a Go channel first, then Redis or NATS). Services talk over HTTP, then gRPC.

**Learn:**
- client/server boundaries
- RPC and serialization
- schema evolution
- queues and delivery guarantees (at-most-once, at-least-once)
- retries with exponential backoff and jitter
- idempotency keys
- backpressure (`429`, bounded queues)
- service-to-service authentication (a first trust boundary)

**Gap-fill:**
- **Networking:** sockets, TCP handshake and teardown, UDP vs TCP, ports, DNS lookups
- Watching real packets

**Tools:** gRPC and Protocol Buffers (`protoc`, `buf`), Redis or NATS, `tcpdump`, Wireshark, `ss`, `nc`, `dig`, Docker Compose (only to run Redis/NATS locally).

**Read:**

| When | Source | Chapters / sections |
|---|---|---|
| Week 1, before the worker talks over the network | Kurose & Ross | 2.7 *Socket Programming*; 3.1–3.3 (transport services, multiplexing, UDP) |
| Week 1 | CSAPP | Ch. 11 *Network Programming* |
| Week 2, before retries | Kurose & Ross | 3.4 *Principles of Reliable Data Transfer*; 3.5 *TCP* |
| Week 2 | Understanding Distributed Systems | Part I: *Reliable links*, *Discovery*, *APIs* |
| Week 2 | *Distributed Systems* (van Steen & Tanenbaum, 4th ed.) | 3.4 *Servers*; 4.2 *Remote procedure call*; 4.3 *Message-oriented communication* |
| Week 3, when adding gRPC | DDIA | Ch. 4 *Encoding and Evolution* |
| Week 3 | DDIA | Ch. 11 *Stream Processing*, first section only (message brokers) |
| Week 3, when the worker crashes | **Paper:** MapReduce (Dean & Ghemawat, 2004) | Full paper. Focus on §3.3 (fault tolerance, re-executing failed tasks). |
| Week 4, when adding backpressure | Site Reliability Engineering | Ch. 21 *Handling Overload*; Ch. 22 *Addressing Cascading Failures* |
| Week 4 | Understanding Distributed Systems | Part IV: *Common failure causes*, *Upstream resiliency* |
| Week 4, when deciding where the API/worker line goes | *Software Architecture: The Hard Parts* (excerpt) | Ch. 7 *Service Granularity* |
| Week 4 | Security Engineering | Ch. 4 *Protocols* |

**Proof:** kill the worker mid-job, restart it, and show the job is completed exactly once in effect.

**Careers opened:** the distributed systems basics that interviews start with (retries, idempotency, delivery semantics).

**Next:** the queue and job state are still volatile. Phase 3 makes data survive crashes.

---

### Rust Bridge (opens Phase 3)
*Estimated: 3 weeks, the only language detour in the curriculum*

**Why now:** Phase 3 is where memory layout, bytes on disk, and `fsync` matter. That's exactly what Rust makes explicit.

**Build:** small Rust programs that lead up to the storage engine:
1. a CLI that reads and writes a binary file;
2. a checksummed record format;
3. a multi-threaded counter that the compiler refuses to let you break.

**Learn:**
- ownership, borrowing, and lifetimes
- `Result` and error handling
- traits and generics
- `Send` and `Sync`
- `unsafe` (what it is, and why you'll avoid it)
- the stack vs the heap

**Gap-fill:**
- **Memory:** virtual memory, the heap, allocation
- The OS's view of memory

**Tools:** `rustup`, `cargo`, `clippy`, `rustfmt`, `cargo test`, `serde`, `anyhow` or `thiserror`.

**Read:**

| When | Source | Chapters / sections |
|---|---|---|
| Weeks 1–2 | *The Rust Programming Language* (free at doc.rust-lang.org/book), **not in your collection** | Ch. 1–10, 13, 15, 16 |
| Week 2 | OSTEP | Ch. 13 *Address Spaces*; Ch. 14 *Memory API*; Ch. 17 *Free-Space Management* |
| Week 3 | CSAPP | Ch. 9 *Virtual Memory* (9.1–9.9) |
| Week 3 | *Rust Atomics and Locks* (Mara Bos, free to read online), **not in your collection** | Ch. 1–2 |

**Proof:** explain one borrow-checker error in your own words, and show a data race that Rust rejects at compile time.

---

### Phase 3: Make data survive
*Estimated: 6 weeks*

**Build:**
- the Go job store moved to **PostgreSQL**;
- **in Rust:** an append-only log with checksums, crash recovery, and compaction. This is the seed of an LSM storage engine.

**Learn:**
- transactions, isolation levels, and the anomalies you can reproduce
- indexes and query plans
- write-ahead logging
- `fsync` and the page cache
- crash recovery
- the outbox pattern
- B-trees vs LSM trees
- backups and restore drills

**Gap-fill:**
- **OS persistence:** files, file systems, journaling, disks and SSDs
- **Security:** SQL injection and parameterized queries

**Tools:**
- **Database:** PostgreSQL, `psql`, `EXPLAIN ANALYZE`, `goose` (migrations), `pg_dump`/`pg_restore`, `sqlc` or `pgx`.
- **Rust side:** `criterion` (benchmarks), `proptest` (property tests).
- **Linux:** `strace`, `iostat`, `df`, `du`.

**Read:**

| When | Source | Chapters / sections |
|---|---|---|
| Week 1, with Postgres | DDIA | Ch. 7 *Transactions* |
| Week 1 | Web Application Hacker's Handbook | Ch. 9 *Attacking Data Stores* (SQL injection sections) |
| Week 2 | *Readings in Database Systems* (Red Book, 5th ed.) | *Traditional RDBMS Systems*; *Techniques Everyone Should Know* |
| Week 3, before the Rust log | OSTEP | Ch. 36 *I/O Devices*; Ch. 37 *Hard Disk Drives*; Ch. 39 *Files and Directories*; Ch. 40 *File System Implementation* |
| Week 3 | CSAPP | Ch. 10 *System-Level I/O*; Ch. 6 *The Memory Hierarchy* (6.1–6.3) |
| Week 4, before crash recovery (most important reading this phase) | OSTEP | Ch. 42 *Crash Consistency: FSCK and Journaling* |
| Week 4 | OSTEP | Ch. 43 *Log-structured File Systems*; Ch. 44 *Data Integrity and Protection*; Appendix I *Flash-based SSDs* |
| Week 5, before compaction | DDIA | Ch. 3 *Storage and Retrieval* |
| Week 5 | **Paper:** Bigtable (Chang et al., 2006) | Full paper. Focus on SSTables, memtables, and compaction. |
| Week 5 | Understanding Distributed Systems | Part II *Transactions* |
| Week 6 | Site Reliability Engineering | Ch. 26 *Data Integrity: What You Read Is What You Wrote* |
| Week 6 (optional) | DDIA | Ch. 2 *Data Models and Query Languages* (skim) |

> **Collection note:** your `Database Internals.pdf` is a 238-page *summary* (Bookey), not Alex Petrov's book. Use it for orientation only. If you get the real book, read Part I (Ch. 1–7, storage engines) in this phase and Part II (Ch. 8–14, distribution) in Phase 4. It is one of the best references for exactly this work.

**Proof:** kill the process during a write (both Postgres and your Rust log), recover, and show a consistent result. Include a test that proves it.

**Careers opened:** storage/database engineering (entry level), plus credibility for Systems Engineer (systems software).

**Next:** one machine can still die with the data on it. Phase 4 spreads state across machines.

---

### Phase 4: Make state survive multiple machines
*Estimated: 10 weeks. The research core of the curriculum.*

**Build:** a **three-node key-value / metadata service**.
1. First with `hashicorp/raft`, to *feel* replication.
2. Then your own Raft in Go, built through the MIT 6.5840 lab structure.
3. Nodes store data in your **Rust storage engine** from Phase 3.

**Learn:**
- system models and failure models (crash vs Byzantine)
- failure detection
- physical and logical clocks
- leader election
- replication strategies
- quorums
- consistency models: linearizability, serializability, eventual
- consensus: Raft, Paxos, Viewstamped Replication
- partitioning
- distributed transactions and two-phase commit
- the FLP impossibility result and the CAP theorem, stated precisely

**Gap-fill:**
- **Networking under failure:** congestion, tail latency, partitions
- **Linux network fault injection**
- Time synchronization (NTP/chrony)

**Tools:** `hashicorp/raft`, MIT 6.5840 lab framework (free), Porcupine (linearizability checker), `tc netem`, `iptables`/`nftables`, chrony, TLA+ with the TLC model checker (light use).
- **Optional Rust:** `tokio`, `tonic` (gRPC), `loom` (concurrency testing).

**Read (in this order; it builds up):**

| When | Source | Chapters / sections |
|---|---|---|
| Week 1 | DDIA | Ch. 5 *Replication* |
| Week 1 | Understanding Distributed Systems | Part II: *System models*, *Failure detection*, *Time*, *Leader election*, *Replication* |
| Week 2 | DDIA | Ch. 8 *The Trouble with Distributed Systems* |
| Week 2 | van Steen & Tanenbaum | 5.1 *Clock synchronization*; 5.2 *Logical clocks*; 5.3 *Mutual exclusion*; 5.4 *Election algorithms* |
| Week 2 | **Paper (add):** Lamport, *Time, Clocks, and the Ordering of Events* (1978) | Full |
| Week 3 | Nancy Lynch, *Distributed Algorithms* lecture slides (your `Distributed Algorithm.pdf`) | All 85 slides: synchronous vs asynchronous models, leader election, proofs |
| Week 3–5, while building Raft | **Paper:** Raft, extended version (Ongaro & Ousterhout) | §1–8 first; §9–11 after your implementation passes tests |
| Week 5 | DDIA | Ch. 9 *Consistency and Consensus* |
| Week 6 | **Paper:** Viewstamped Replication Revisited (Liskov & Cowling) | Full. Compare it to Raft in `notes/decisions.md`. |
| Week 6 | *Paxos Made Simple* student slides (your `paxosfinal.pdf`), then **Paper:** Paxos Made Simple (Lamport) | Slides as warm-up, then the full paper |
| Week 7 | van Steen & Tanenbaum | Ch. 7 *Consistency and Replication* (7.1–7.5); 8.1–8.2 (fault tolerance, process resilience); 8.5 *Distributed commit* |
| Week 7 | Site Reliability Engineering | Ch. 23 *Managing Critical State: Distributed Consensus for Reliability* |
| Week 8 | DDIA | Ch. 6 *Partitioning* |
| Week 8 | Red Book | *Weak Isolation and Distribution* |
| Week 8 | Kurose & Ross | 3.6–3.7 (congestion control); 3.8 (QUIC and newer transports) |
| Week 9 | **Paper:** The Google File System (2003) | Full |
| Week 9 | **Paper:** Spanner (2012) | Full; focus on TrueTime and Appendix A (leader leases) |
| Week 10 | **Papers (add):** FLP (1985); Gilbert & Lynch CAP proof (2002); Dynamo (2007) | Full |

**Proof:**
- Disconnect or kill nodes, and explain which guarantees still hold.
- Porcupine confirms linearizability across hundreds of randomized runs.
- A written report in `notes/` describes one bug your tests found.

**Careers opened:** **Distributed Systems Engineer** (core), plus the strongest research signal you'll have before the MSc.

**Next:** the system is correct on your laptop. Phase 5 runs it where strangers could depend on it.

---

### Phase 5: Run it like a production system
*Estimated: 8 weeks, including a game-day block*

**Build:** the whole stack in containers, deployed to Kubernetes, first locally and then on **AWS or GCP with Terraform**, with CI/CD and full observability.

**Learn:**
- containers as processes (namespaces, cgroups)
- images and registries
- Kubernetes objects and control loops
- StatefulSets for the KV cluster
- CI/CD and progressive rollouts
- metrics, logs, and traces
- SLOs, error budgets, and burn-rate alerts
- capacity planning and load testing
- runbooks, on-call, incident management, postmortems

**Gap-fill:**
- **Linux:** namespaces, cgroups, systemd, journald
- **Performance:** USE method, `perf`, flame graphs
- **Networking:** IP addressing and subnets, NAT, load balancers, DNS in production, data-center networks
- **Cloud:** VPCs, IAM, managed databases

**Tools:** Docker (multi-stage builds), `kind`, `kubectl`, Helm, Kustomize, Terraform, AWS or GCP, GitHub Actions (build, test, push, deploy), OpenTelemetry, Prometheus, Grafana, Alertmanager, Loki, Jaeger or Tempo, k6, `perf`, `vmstat`, `iostat`.
- **Rust CI:** `clippy`, `cargo-audit`, `cargo-deny`.

**Read:**

| When | Source | Chapters / sections |
|---|---|---|
| Week 1, before Docker | OSTEP | Ch. 6 *Limited Direct Execution*; Ch. 7 *Scheduling* (intro); Appendix B *Virtual Machine Monitors* |
| Week 1 | van Steen & Tanenbaum | 3.2 *Virtualization* |
| Week 1 | CSAPP | Ch. 7 *Linking* (7.1–7.7, 7.10–7.12). Explains static Go binaries in tiny images. |
| Week 2 | **Paper:** Large-scale cluster management at Google with Borg (2015) | Full |
| Weeks 2–4 | *Kubernetes in Action* (Lukša, 1st ed.) | Ch. 1–9, then Ch. 10 *StatefulSets* (deploy your Phase 4 cluster) |
| Week 4 | Kubernetes in Action | Ch. 11 *Understanding Kubernetes Internals*; Ch. 14 *Managing Pods' Computational Resources*; Ch. 17 *Best Practices* |
| Week 4 | OSTEP | Ch. 18–22 (paging, TLBs, swapping). Explains OOM kills and memory limits. |
| Week 5, with networking | Kurose & Ross | 2.4 *DNS*; 2.6 *CDNs*; 4.1–4.3 (network layer, IP, addressing); 4.5 *Middleboxes*; 6.4 *Switched LANs*; 6.6 *Data Center Networking*; 6.7 *A Day in the Life of a Web Page Request* |
| Week 5 | van Steen & Tanenbaum | Ch. 6 *Naming* (6.1–6.3, skim) |
| Week 6, SRE block | Site Reliability Engineering | Ch. 1, 3, 4, 5, 8, 10, 11, 12, 13, 14, 15; Appendices B, C, D |
| Week 6 | Understanding Distributed Systems | Part V: *Testing*, *Continuous delivery and deployment*, *Monitoring*, *Observability* |
| Week 7, when profiling | *Systems Performance* (Gregg, 2nd ed.), **excerpt: Ch. 6 only** | Ch. 6 *CPUs* (6.1–6.6) |
| Week 7 | CSAPP | Ch. 5 *Optimizing Program Performance* (5.1–5.7, 5.14) |
| Week 8, platform view | *Platform Engineering* (excerpt) | Ch. 1 *Why Platform Engineering Is Becoming Essential* |
| Week 8 | *Team Topologies* (partial copy) | Ch. 4–5 (static and fundamental team topologies; the platform team) |
| Optional | Kubernetes in Action | Ch. 18 *Extending Kubernetes* (operators; the seed of VEYRONIX) |

> **Collection notes:** *Kubernetes in Action* 1st edition (2018) has dated API versions and mentions rkt. Learn the concepts from the book and check commands against kubernetes.io. Your *Systems Performance* file contains only Ch. 6; the full book's Ch. 2 *Methodologies* and the memory, file system, and network chapters are worth getting later.

**Game days (week 8):** someone else (or I) injects faults from the fault catalogue in your *Blueprint, Built* handbook, such as fd exhaustion, a slow memory leak, connection-pool starvation, clock skew, or Terraform drift. You diagnose using only your dashboards and logs, then write an incident report within 48 hours.

**Proof:** find and repair a deliberately introduced production-style incident using a runbook, and publish the postmortem.

**Careers opened:** **SRE, Platform Engineer, DevOps Engineer, Cloud/Infrastructure Engineer.** This is the point to start applying seriously.
- Optional certifications: CKA, AWS Solutions Architect Associate, Terraform Associate.

**Next:** the platform runs general services. Phase 6 asks what changes when the workload is an LLM.

---

### Phase 6: Serve a model through it
*Estimated: 6 weeks*

**Build:** a model runtime behind the existing gateway with **streaming** responses. Start with llama.cpp or Ollama on CPU, then vLLM on a rented GPU. Add a benchmark harness.

**Learn:**
- tokens and tokenizers
- context windows
- transformer inference at a working level
- prefill vs decode
- the KV cache and why it's memory-bound
- batching, including continuous batching
- quantization
- GPU memory and utilization
- latency metrics: TTFT (time to first token), TPOT (time per output token), throughput, and the trade-offs between them
- honest benchmarking methodology

**Gap-fill:**
- **Memory paging applied to GPUs:** PagedAttention is virtual memory for the KV cache
- CPU vs GPU execution
- PCIe and NUMA basics

**Tools:** Python, `uv` or `pip`, llama.cpp, Ollama, vLLM, Hugging Face `transformers` and `tokenizers` (a Rust library with Python bindings; use it from your Rust code too), `nvidia-smi`, DCGM exporter, server-sent events, a cloud GPU rental, Jupyter for analysis.

**Read:**

| When | Source | Chapters / sections |
|---|---|---|
| Week 1 | OSTEP | Re-read Ch. 18–20 (paging, TLBs, smaller tables) with the KV cache in mind |
| Week 2 | **Paper (add):** *Attention Is All You Need* (2017) | §1–3 only (the architecture), for vocabulary |
| Week 3 | **Paper (add):** Orca, continuous batching (OSDI 2022) | Full |
| Week 3 | **Paper (add):** vLLM / PagedAttention (SOSP 2023) | Full |
| Week 4 | **Paper (add):** *The Tail at Scale* (Dean & Barroso, 2013) | Full |
| Week 5 | Systems Performance excerpt | Re-read 6.4–6.6 and compare with GPU utilization analysis |

**Proof:** measure time-to-first-token, tokens per second, and the bottleneck, including a graph and an explanation.

**Careers opened:** **AI Infrastructure / LLM Inference / MLOps** (entry).
- **ML Engineer** is still not covered; it needs a separate track in model training and evaluation.

**Next:** one model and one user is a demo. Phase 7 makes it a shared, economical platform.

---

### Phase 7: Turn it into a shared AI platform
*Estimated: 8 weeks*

**Build:** a **multi-tenant AI gateway** with:
- authentication (API keys signed with HMAC)
- per-tenant quotas and budgets
- token-bucket rate limiting
- usage metering
- model routing with fallback
- response caching
- retrieval (RAG) with pgvector
- autoscaling

**Learn:**
- tenant isolation (noisy neighbors)
- admission control and priority
- rate-limiting algorithms
- cache design and invalidation
- load balancing
- autoscaling signals
- cost accounting
- authorization models
- control plane vs data plane

**Gap-fill:**
- **Applied crypto:** HMAC, key storage, key rotation
- **API and web security:** authentication, sessions, access control bugs
- Load balancing internals

**Tools:** Redis (rate limiting), PostgreSQL with pgvector, JWT/JWS libraries, Kubernetes HPA or KEDA, Envoy (optional), OpenTelemetry for per-tenant metrics.
- **Optional Rust:** the rate-limiter hot path.

**Read:**

| When | Source | Chapters / sections |
|---|---|---|
| Week 1 | **Paper:** Borg, re-read §2 and §5 (quota, priority, admission, isolation) | Sections as listed |
| Week 1 | Kubernetes in Action | Ch. 15 *Automatic Scaling*; Ch. 16 *Advanced Scheduling* (taints for GPU nodes) |
| Week 2 | Understanding Distributed Systems | Part III: *Functional decomposition*, *Partitioning*, *Duplication* (load balancing, caching) |
| Week 2 | Site Reliability Engineering | Ch. 19 *Load Balancing at the Frontend*; Ch. 20 *Load Balancing in the Datacenter* |
| Week 3, with API keys | *Cryptography for Developers* (St Denis & Johnson, 2006) | Ch. 1 *Introduction* (threat models); Ch. 5 *Hash Functions*; Ch. 6 *MAC Algorithms* |
| Week 3 | Kurose & Ross | 8.1–8.3 (network security, crypto principles, integrity and signatures) |
| Week 4, with authentication | Web Application Hacker's Handbook | Ch. 6 *Attacking Authentication*; Ch. 7 *Attacking Session Management*; Ch. 8 *Attacking Access Controls* |
| Week 5 | Security Engineering | Ch. 6 *Access Control* |
| Week 6 | **Paper (add):** Zanzibar, Google's authorization system (2019) | Full |
| Week 7 | Platform Engineering excerpt | Ch. 12 *Your Platforms Are Trusted*; Ch. 13 *Your Platforms Manage Complexity* |
| Week 7 | Team Topologies | Ch. 6–7 (team-first boundaries, interaction modes) |
| Optional | DDIA | Ch. 10 *Batch Processing* (skim) |

**Proof:** a noisy tenant cannot exceed its limit or starve another tenant, backed by a load test and graphs.

**Careers opened:** **AI Platform Engineer, MLOps, Platform Engineer (senior-leaning).**

**Next:** it works and scales. Phase 8 asks whether you can defend it under failure *and* attack.

---

### Phase 8: Prove it is secure and resilient
*Estimated: 8 weeks, including a second game-day block*

**Build:**
- a threat model and a hardened deployment;
- mTLS between services (a Rust sidecar using `rustls`, or a service mesh);
- a secrets manager, OIDC identity, and policy-as-code authorization;
- a signed and verifiable supply chain;
- fuzzing of your Rust storage parser;
- LLM-specific defenses;
- chaos experiments and a final design review.

**Learn:**
- threat modelling (STRIDE)
- security in distributed systems: trust, authentication, authorization, and the Byzantine failure model
- PKI and certificates, mTLS, TLS 1.3
- secret management
- least privilege
- supply-chain security (SBOMs, signing, provenance)
- container hardening
- the OWASP Top 10 and the OWASP Top 10 for LLM Applications (prompt injection, data leakage)
- side channels in multi-tenant systems
- chaos engineering
- incident response

**Gap-fill:**
- **Systems security:** Linux users, capabilities, seccomp, AppArmor/SELinux basics, audit logging
- **Network security:** firewalls, intrusion detection, TLS internals
- Cryptographic primitives in more depth

**Tools:** STRIDE worksheets, HashiCorp Vault or SOPS, an OIDC provider (Keycloak or Dex), Open Policy Agent or Kyverno, cert-manager, `rustls`, Linkerd or Istio (optional), Syft (SBOM), cosign/Sigstore (signing), Trivy and Grype (scanning), `cargo-fuzz`, `govulncheck`, Falco (optional), Chaos Mesh, OWASP ZAP.

**Read:**

| When | Source | Chapters / sections |
|---|---|---|
| Week 1, threat model | Security Engineering | Ch. 2 *Who Is the Opponent?*; Ch. 7 *Distributed Systems* (essential) |
| Week 1 | van Steen & Tanenbaum | Ch. 9 *Security* (all of it) |
| Week 2, mTLS | Kurose & Ross | 8.4 *End-Point Authentication*; 8.6 *Securing TCP Connections: TLS*; 8.9 *Firewalls and IDS* |
| Week 2 | Security Engineering | Ch. 5 *Cryptography* |
| Week 2 | Cryptography for Developers | Ch. 3 *Random Number Generation*; Ch. 7 *Encrypt and Authenticate Modes*; Ch. 9 *Public Key Algorithms*. **Dated (2006):** pair with current guidance on TLS 1.3, X25519, and Ed25519. Ch. 2 *ASN.1* only if you parse X.509 yourself. |
| Week 3 | Kubernetes in Action | Ch. 12 *Securing the API Server*; Ch. 13 *Securing Cluster Nodes and the Network* |
| Week 3 | Kurose & Ross | 1.6 *Networks Under Attack*; 8.7 *IPsec and VPNs* (skim) |
| Week 4, self-assessment | Web Application Hacker's Handbook | Ch. 10 *Attacking Back-End Components*; Ch. 11 *Application Logic*; Ch. 17 *Application Architecture*; Ch. 21 *Methodology* (use as a checklist against your own platform) |
| Week 5 | Security Engineering | Ch. 19 *Side Channels*; Ch. 21 *Network Attack and Defence* |
| Week 6 | Security Engineering | Ch. 27 *Secure Systems Development*; Ch. 28 *Assurance and Sustainability* |
| Week 6 | **Paper (add):** in-toto, supply-chain integrity (USENIX Security 2019) | Full |
| Week 7 | Site Reliability Engineering | Ch. 17 *Testing for Reliability*; Ch. 27 *Reliable Product Launches at Scale*; Appendix E *Launch Coordination Checklist* |
| Week 7 | **Paper (add):** *The Byzantine Generals Problem* (Lamport, Shostak, Pease, 1982) | Full; this bridges into the research track |
| Optional | Security Engineering | Ch. 8 *Economics*; Ch. 10 *Boundaries* |
| Skip | Web Application Hacker's Handbook | Ch. 12–13 (browser attacks) and Ch. 16 (native code) are outside this platform's scope |

**Game days (week 8):** security and policy faults from the handbook catalogue, such as an expired intermediate certificate, an over-broad policy, a leaked-then-revoked key you must prove was never used, or a gap in the audit chain.

**Proof:** present the architecture, handle failure scenarios live, and show the security and operations evidence (threat model, SBOM, signatures, chaos results, incident reports).

**Careers opened:** stronger versions of all previous roles, plus **Cloud Security Engineer, DevSecOps Engineer, Infrastructure/Product Security Engineer.**
- Optional certification: CKS.
- Penetration testing and SOC/detection roles still need their own track.

**Next:** the industry path is complete. The research track (section 6) continues into the MSc.

---

## 5. Reading list: master index

### Books you have

| Source | Edition / status | Used in phases | Notes |
|---|---|---|---|
| Computer Systems: A Programmer's Perspective | 3rd ed. (2016) | 0, 1, 2, Bridge, 3, 5 | Primary systems text |
| `csapp.beta.pdf` | 2001 beta draft | none | Superseded by the 3rd ed.; don't read |
| Operating Systems: Three Easy Pieces | Complete | 0, 1, Bridge, 3, 4, 5, 6 | Primary OS text; free online |
| Computer Networking: A Top-Down Approach | 8th ed. | 0, 2, 4, 5, 7, 8 | Chapter 7 (wireless) is out of scope |
| Designing Data-Intensive Applications | 1st ed. (2017) | 1, 2, 3, 4, 7 | Core text for Phases 3–4 |
| Understanding Distributed Systems | 1st ed. | 1, 2, 3, 4, 5, 7 | Short, practical; references use part and chapter names |
| Distributed Systems (van Steen & Tanenbaum) | 4th ed. | 2, 4, 5, 8, research | Academic depth; free from distributed-systems.net |
| Site Reliability Engineering | Complete | 1, 2, 3, 4, 5, 7, 8 | Free at sre.google |
| Kubernetes in Action | 1st ed. (2018) | 5, 7, 8 | Concepts current; verify commands |
| Security Engineering (Anderson) | 3rd ed. (2020) | 1, 2, 7, 8, research | The research-grade security text; skip Ch. 12–18, 22–26 unless curious |
| Cryptography for Developers | 2006 | 7, 8 | Implementation insight, but dated algorithms |
| The Web Application Hacker's Handbook | 2nd ed. (2011) | 0, 1, 3, 7, 8 | Pair with the current OWASP Top 10 |
| Readings in Database Systems (Red Book) | 5th ed. | 3, 4 | Short essays with paper pointers |
| Systems Performance (Gregg) | **Excerpt: Ch. 6 only** | 5, 6 | Consider the full book later |
| Database Internals (Petrov) | **Summary, not the book** | 3 (orientation) | Get the real book if possible |
| Team Topologies | **Partial copy** (up to Ch. 7) | 5, 7 | Enough for our purposes |
| Platform Engineering | **Excerpt: Ch. 1, 12, 13** | 5, 7 | Enough for our purposes |
| Software Architecture: The Hard Parts | **Excerpt: Ch. 7 only** | 2 | Enough for our purposes |
| The Blueprint, Built (your handbook v2) | Your own | 5, 8, section 7 | Reuse the fault catalogue and parallel track |

### Papers and slides you have

| Paper | Phase | Order |
|---|---|---|
| MapReduce (2004) | 2 | First paper you read |
| Bigtable (2006) | 3 | With your Rust LSM work |
| Lynch, Distributed Algorithms slides | 4 | Before Raft |
| Raft, extended (2014) | 4 | Core |
| Viewstamped Replication Revisited (2012) | 4 | After Raft |
| Paxos Made Simple, student slides | 4 | Warm-up for Lamport's paper |
| Paxos Made Simple (2001) | 4 | After VR |
| GFS (2003) | 4 | Late Phase 4 |
| Spanner (2012) | 4 | Last in Phase 4 |
| Borg (2015) | 5, 7 | Before Kubernetes internals; re-read for multi-tenancy |

### Free sources to add (not in your collection)

| Source | Phase |
|---|---|
| *The Rust Programming Language* (doc.rust-lang.org/book) | Rust Bridge |
| *Rust Atomics and Locks* (Mara Bos, free online) | Rust Bridge, 4 |
| *The Linux Command Line* (William Shotts, free online) | 0–1, as reference |
| *Beej's Guide to Network Programming* | 2 |
| MIT 6.5840 Distributed Systems labs and lecture notes | 4 |
| Lamport, *Time, Clocks, and the Ordering of Events* (1978) | 4 |
| Fischer, Lynch, Paterson, *Impossibility of Distributed Consensus with One Faulty Process* (1985) | 4 |
| Gilbert & Lynch, *Brewer's Conjecture* (CAP proof, 2002) | 4 |
| DeCandia et al., *Dynamo* (2007) | 4 |
| Kyle Kingsbury, Jepsen analyses (jepsen.io) | 4, 5 |
| Dean & Barroso, *The Tail at Scale* (2013) | 6 |
| Vaswani et al., *Attention Is All You Need* (2017) | 6 |
| Yu et al., *Orca* (OSDI 2022) | 6 |
| Kwon et al., *vLLM / PagedAttention* (SOSP 2023) | 6 |
| Pang et al., *Zanzibar* (USENIX ATC 2019) | 7 |
| Torres-Arias et al., *in-toto* (USENIX Security 2019) | 8 |
| Lamport, Shostak, Pease, *The Byzantine Generals Problem* (1982) | 8 |
| OWASP Top 10 and OWASP Top 10 for LLM Applications | 8 |
| Keshav, *How to Read a Paper* | Research track, read first |

---

## 6. Research track: preparing for a thesis MSc

**Targets:** University of Waterloo (MMath, Computer Science, thesis) and UBC (MSc Computer Science, thesis, Vancouver).
**Interest:** secure distributed systems, and distributed systems broadly.

### What admissions committees and supervisors look for
- evidence you can do research: read papers critically, form a question, run an honest experiment, and write it up;
- fit with a supervisor's work;
- solid fundamentals.

The build gives you the fundamentals. This track adds the other two.

### Research habits (start in Phase 2, deepen in Phase 4)
1. **Read papers with the three-pass method** (Keshav). Keep a one-page note per paper in `notes/papers/` covering:
   - the problem;
   - the key idea;
   - the assumptions and failure model;
   - how it was evaluated;
   - one weakness;
   - one question it leaves open.
2. **Reproduce one result.** For example, reproduce a Raft or VR behavior under partition, or reproduce a Jepsen-style anomaly in a real database, and document where your numbers differ.
3. **Write one technical report** (4–6 pages, in LaTeX) from Phase 4 or Phase 8. Examples:
   - "Measuring leader-election latency under asymmetric partitions";
   - "Fuzzing a log-structured storage engine: bugs found and their causes."

   This becomes a writing sample and a strong basis for your statement of purpose.
4. **Specify one protocol in TLA+** and model-check a safety property.
5. **Learn LaTeX** and a reference manager (Zotero).

### Research areas in secure distributed systems to explore

Read one or two papers per area and note which ones pull you in. Your statement of purpose should name a direction, not everything.

| Area | Starter papers (free) |
|---|---|
| Byzantine fault-tolerant replication | PBFT (Castro & Liskov, OSDI 1999); HotStuff (PODC 2019) |
| Accountability and auditing | PeerReview (SOSP 2007) |
| Verified distributed systems | IronFleet (SOSP 2015); Verdi (PLDI 2015) |
| Testing distributed systems | Jepsen analyses; *Simple Testing Can Prevent Most Critical Failures* (OSDI 2014) |
| Authorization at scale | Zanzibar (2019) |
| Supply-chain integrity | in-toto (2019) |
| Confidential computing / trusted hardware | Start with Security Engineering Ch. 18–20 context, then SGX-based system papers |
| Security of ML / LLM serving systems | OWASP LLM Top 10, then recent USENIX Security and IEEE S&P papers |

### Research groups to study (verify current faculty and intake before contacting anyone)
- **Waterloo, Cheriton School of Computer Science:**
  - the Systems and Networking group (syn.uwaterloo.ca);
  - the Data Systems Group (Khuzaima Daudjee works on distributed systems and data management);
  - the CrySP group (Ian Goldberg; N. Asokan, whose interests include cryptographic techniques for secure protocols in distributed systems).
- **UBC Computer Science:**
  - the Systopia lab (operating systems, distributed systems, security, provenance);
  - the Security & Privacy group;
  - Ivan Beschastnikh works on distributed systems.
- **Faculty move:** Thomas Pasquier (secure, auditable systems) announced he is moving to Oxford in September 2026. This kind of change is why you verify before writing.

For each potential supervisor, read two recent papers and write a short note connecting them to something you built. That note is the core of a good contact email.

### Mathematical readiness (the MMath is in the Faculty of Mathematics)
Keep discrete math, probability, and proof-writing sharp alongside your BSc. The Lynch slides and the FLP paper are good practice in reading distributed systems proofs, and TLA+ builds formal reasoning.

---

## 7. Parallel tracks (continuous, not phase-gated)

These come from section 8 of your *Blueprint, Built* handbook. The build does not teach them.

| Track | Starts | Cadence |
|---|---|---|
| Algorithms and coding interviews | Phase 0 | 3 × 45 min per week, pattern-first; aim for 150+ problems over the program |
| System design on unfamiliar problems | Phase 2 | 1 × 45 min per week, outside your own domain |
| Open source contributions | Phase 3 | Read a real codebase (e.g., `hashicorp/raft`, etcd, or a Rust storage crate); first merged PR by Phase 4–5 |
| Writing | Phase 1 | One Medium essay per phase, drawn from `notes/failures.md` and `notes/decisions.md` |
| Research reading | Phase 2 | One paper per week from Phase 4 onward (section 6) |
| Job applications | Phase 5 | Tailored applications once the portfolio has operations evidence |

---

## 8. Careers by phase

| Role | Fit | Opens at | Remaining gap after Phase 8 |
|---|---|---|---|
| Distributed Systems Engineer | Full | Phase 4 | none; deepen via research |
| Site Reliability Engineer | Full | Phase 5 | Real on-call experience |
| Platform Engineer | Full | Phase 5, stronger at 7 | Operator/controller depth (optional VEYRONIX work) |
| Cloud / Infrastructure Engineer | Full | Phase 5 | A second cloud provider, optionally |
| AI Infrastructure / LLM Platform / MLOps | Full | Phase 6, stronger at 7 | GPU kernels (CUDA/Triton) for specialist roles |
| Systems Engineer | Full (ops sense); strong (systems-software sense) | Phase 3–5 | Deeper C, kernel, and OS internals for kernel-level roles |
| Security Engineer | Strong for cloud security, DevSecOps, infrastructure/product security | Phase 8 | A separate offensive/defensive track for pentesting and SOC roles |
| ML Engineer | Partial (serving only) | Phase 6 | A separate track: linear algebra, statistics, PyTorch, training, evaluation |
| Backend / DevOps Engineer | Full | Phase 1–5 | none |
| Storage / Database Engineer | Strong | Phase 3–4 | The real *Database Internals* book and a larger storage project |

---

## 9. Timeline (honest estimate)

This assumes 12–15 focused hours a week alongside the BSc and client work. It is a guide, not a deadline; phases end when their proof passes.

| Phase | Weeks |
|---|---|
| 0: Request service | 2 |
| 1: Reliable service | 4 |
| 2: Services together | 4 |
| Rust Bridge | 3 |
| 3: Durable data | 6 |
| 4: Distributed state | 10 |
| 5: Operations | 8 |
| 6: Model serving | 6 |
| 7: AI platform | 8 |
| 8: Capstone | 8 |
| **Total** | **~59 weeks (about 14–16 months with normal slippage)** |

For MSc preparation, the phases that matter most are **0–4** plus the research habits in section 6. If the MSc starts in fall 2027, having Phase 4 and one technical report complete before then is a realistic and valuable goal.

---

## 10. Progress tracker

| Phase | Status | Proof passed | Postmortem / report | Essay |
|---|---|---|---|---|
| 0 | ◐ in progress | ☐ | n/a | ☐ |
| 1 | ○ | ☐ | ☐ | ☐ |
| 2 | ○ | ☐ | ☐ | ☐ |
| Rust Bridge | ○ | ☐ | n/a | n/a |
| 3 | ○ | ☐ | ☐ | ☐ |
| 4 | ○ | ☐ | ☐ technical report | ☐ |
| 5 | ○ | ☐ | ☐ game days | ☐ |
| 6 | ○ | ☐ | ☐ benchmark | ☐ |
| 7 | ○ | ☐ | ☐ | ☐ |
| 8 | ○ | ☐ | ☐ game days + design review | ☐ |
