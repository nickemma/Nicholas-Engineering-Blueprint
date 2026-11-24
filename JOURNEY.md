# The Blueprint: control planes in Go, data planes in Rust

This is a path to systems and infrastructure engineering roles, from your first program to shipping a system of your own. Everyone builds the same core: **Switchyard**, a Go control plane running a Rust data plane on Linux. Then you pick a domain, **AI infrastructure**, **storage engines** or **cloud and network**, and ship that domain's system as your capstone.

This is the **only roadmap** in the repository. Everything else is a module (`1-foundations/`, `2-core/`, `3-tracks/`), interview practice (`dsa/`, `system-design/`), maths you check against real systems (`math/`), or the careers page ([career.md](career.md)).

**Contents**

1. [Who this is for](#1-who-this-is-for)
2. [What you'll build](#2-what-youll-build)
3. [How to study](#3-how-to-study)
4. [The route](#4-the-route)
5. [Languages and tools](#5-languages-and-tools)
6. [Alongside the route](#6-alongside-the-route)
7. [Books](#7-books)

---

## 1. Who this is for

- **Complete beginners.** Start with [Foundations](#foundations): they assume no programming, no Linux and no networking. Each idea is explained before it's used.
- **Experienced developers.** Take the [test-out](1-foundations/test-out/README.md) instead of Foundations: one timed task, a small Go command-line tool with tests and a Python script that calls it. If you pass, start at the core.
- **Working engineers** who want to relearn the foundations properly, in order, with evidence for each skill.

The goal: you learn enough to land a systems or infrastructure role in the domain you pick, and you can prove what you know. The roles and the companies hiring for them are on the [careers page](career.md).

It is **not** a technology checklist. Every tool appears because the system needs it at that point, and a module ends when its gate passes, not when a calendar says so.

**Time,** at 12–15 focused hours a week:

| Who | Path | Weeks |
|---|---|---|
| Beginner, one track | Foundations + core + track | about 68–77 |
| Experienced developer, one track | Test-out + core + track | about 60–69 |
| Each extra track | Its own parts, plus any shared units not yet done | +13–26 |

---

## 2. What you'll build

### Switchyard, the core system

Real infrastructure splits into two halves:

- The **control plane** decides what should happen: it holds the desired state (jobs, configuration, who runs what), agrees on it across machines, and keeps reconciling the world towards it. It's written in **Go**.
- The **data plane** does the work on the hot path: it reads frames off the wire, moves bytes, and writes them durably, where every allocation and every copy counts. It's written in **Rust**.

Cloudflare's network, Kubernetes, inference fleets and databases all have this shape. **Switchyard** is the system you build to learn it. It starts as one Go service answering one request, and each core module adds what a real platform needs next:

| Core module | Switchyard gains | Because |
|---|---|---|
| 01 | A Go service that handles jobs, deadlines, shutdown and backpressure, and reconciles state | Requests overlap, stall and fail |
| 02 | A load generator that measures it honestly | You can't improve what you can't measure |
| 03 | PostgreSQL and Docker | Memory forgets |
| 04 | `klog`, a crash-safe log in Rust | The data plane starts with bytes on disk |
| 05 | A zero-copy frame parser and a lock-free ring buffer | The hot path can't afford copies or locks |
| 06 | The wire between Go and Rust, profiled under loss | Two processes have to talk, fast |
| 07 | Your own Raft, persisting to the Rust log | One machine is a single point of failure |
| 08 | Containers, mTLS, secrets, SLOs and a runbook | It has to be shipped, secured and operated |

~~~mermaid
flowchart LR
    C[Clients] -- HTTP / gRPC --> CP[Go control plane<br/>jobs, desired state, reconciler]
    CP --> PG[(PostgreSQL)]
    CP <-- Raft --> META[(Replicated metadata)]
    CP -- framed wire<br/>TCP / Unix socket, mTLS --> DP[Rust data plane<br/>frame parser, ring buffer]
    DP --> LOG[(klog<br/>crash-safe log)]
    K[Python kload<br/>open-loop load] -. measures .-> CP
    OBS[Metrics · traces · flame graphs] -. observes .-> DP
~~~

You build every box yourself, and you can explain why each one exists.

### The capstones: one per track

Each track ends with the system the track ships. It's built on Switchyard's core, and it's published with reproducible benchmarks, before-and-after flame graphs, and a design doc:

| Track | Capstone | Benchmarked for |
|---|---|---|
| AI infrastructure | [An OpenAI-compatible inference gateway](3-tracks/ai-infrastructure/05-capstone-inference-gateway/README.md) | Time to first token, time per output token, throughput |
| Storage engines | [A distributed key-value store](3-tracks/storage-engines/05-capstone-distributed-kv-store/README.md) | YCSB workloads, with crash-recovery proofs |
| Cloud and network | [A programmable edge proxy](3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy/README.md) | Requests per second, memory, zero-downtime reloads |

### Engineering rules the code follows

From the first module to the capstone:

- **Claims need evidence.** Every guarantee has a test or a measurement, and every measurement records how to reproduce it.
- **Fail visibly.** Errors are explicit, logged, and mapped to precise status codes. Nothing fails silently.
- **Untrusted input is rejected at the edge.** That covers sizes, types, unknown fields and limits.
- **Every wait has a deadline, and every queue has a bound.**
- **Security by default.** Deny unless explicitly allowed, keep secrets out of code and logs, and grant least privilege.
- **Say what something doesn't guarantee**, as clearly as what it does.

---

## 3. How to study

### What is in a module

~~~text
2-core/01-go-runtime-and-reliable-services/
  README.md       the module page: what you'll learn and build, time, the gate, and what junior / intermediate / senior looks like
  lessons/        one file per lesson, in order
  gate/           the automated pass/fail check, run against your own code
  exercises.md    separate projects you build alone, each with a clear picture of the finished result
  self-check.md   explain-it questions for each lesson, then a test from memory
  evidence/       the raw runs behind the lessons' outputs and the gate (you don't need to read it)
~~~

### What is in a lesson

Every lesson has the same outline:

| Part | Purpose |
|---|---|
| **The problem** | A real failure, in plain English, before any jargon |
| **The mental model** | A diagram of where the bytes, the threads or the requests are |
| **The pattern** | The named pattern, and what the runtime or kernel does underneath |
| **Build it** | 5–7 steps. Each has starter code, the command to run, the real expected output, what a failure looks like, and hints if you're stuck, ending in the full answer |
| **Check it** | The test or measurement that proves the lesson works, and what it doesn't prove |
| **If it goes wrong** | The common failures and what they mean |

The code lives only in the lessons, next to its explanation. There are no solution folders. CI rebuilds every lesson's code from the lesson itself with [scripts/replay_lessons.py](scripts/replay_lessons.py), so every step is known to work, and every output shown was captured from a real run.

Steps that need something CI can't provide (your GitHub account, Kubernetes, `sudo`, a cloud account or a GPU) are marked **Run locally**, with the exact commands and what you should see.

### The rebuild rule

You follow each module in a scratch folder. At the end, **close the lessons and rebuild the module in your own repository**, from the contracts and your notes. Looking up documentation is allowed; copying the lessons isn't. Then build the module's exercise alone. That's a different system, with a clear spec and no solution.

### What "done" means for a module

1. **The gate passes** against your own rebuilt code. Every core module and track part ends with one: an automated check that injects a failure and tests what must still hold.
2. **One exercise is finished** and meets its acceptance checks.
3. **You can explain it.** Answer `self-check.md` with evidence from your own runs, then take its test from memory.

### A week, roughly

| Hours | Activity |
|---|---|
| ~9 | The current module: build, break, test, explain |
| ~3 | DSA: three 45–60 minute sessions ([dsa/](dsa/README.md)) |
| ~1.5 | One system-design session, from core 03 on ([system-design/](system-design/README.md)) |
| ~1 | Reading and writing notes |

### What to install, and when

Each module's lessons say exactly what to install, with a command to check it worked, when the tool is first needed. In outline:

| Before | Install |
|---|---|
| Foundations 01 | Go, Git, an editor (VS Code). On Windows, WSL2 with Ubuntu |
| Foundations 04 | [`uv`](https://docs.astral.sh/uv/), which also installs Python |
| Core 01 | `protoc`, the protobuf compiler, for the gRPC lesson |
| Core 03 | Docker with Compose, and the `psql` client |
| Core 04 | [`rustup`](https://rustup.rs/) |
| Core 05 | A C compiler and `ar`. For the full gate, the pinned Rust nightly with Miri and `rust-src`, `cargo-fuzz`, and a C++ compiler |
| Core 06 | `perf`, `strace`, `bpftrace`, `tc` and `iperf3`, in a lab image the lessons build |
| Kubernetes and delivery | [`kind`](https://kind.sigs.k8s.io/), `kubectl`, [`helm`](https://helm.sh/) |
| AWS and Terraform | [`terraform`](https://developer.hashicorp.com/terraform/install); optionally the AWS CLI and an account (planning is free and offline; applying costs money while it runs, and the lessons cover clean-up) |
| AI infrastructure | PyTorch, Ray and a small model server through `uv`. A GPU is optional: the steps that need one run on a rented GPU or come with their expected output |
| Storage engines | Java and the [TLA+ tools](https://github.com/tlaplus/tlaplus/releases), for the consensus part |
| Capstones | `govulncheck`, [`trivy`](https://trivy.dev/), [`syft`](https://github.com/anchore/syft), [`cosign`](https://docs.sigstore.dev/), [`wrk2`](https://github.com/giltene/wrk2), plus whatever your capstone needs |

---

## 4. The route

```text
1 FOUNDATIONS (beginners only, 8 wk)
                │
                ▼
2 CORE (everyone, 35 wk): Switchyard, a Go control plane running a Rust data plane
                │
     ┌──────────┼──────────────┐
     ▼          ▼              ▼
 AI INFRA    STORAGE       CLOUD & NETWORK
 (~34 wk)    (~26 wk)      (~25 wk)
     └──── each pulls the SHARED UNITS it needs ────┘
```

**Status** says how far each module is written: **Ready** (lessons, exercises and self-check written and checked), **In progress** (some lessons are in place), or **Planned** (includes outlines awaiting review). A gate marked "set at outline" is defined when that module is outlined.

### Foundations

For beginners. Experienced developers take the test-out instead.

| Module | You build | Gate | Weeks | Status |
|---|---|---|---|---|
| [01 Set up your machine](1-foundations/01-set-up-your-machine/README.md) | A Go program printing your OS, architecture and CPUs | Go, Git and your first program work, and the program reports the machine it runs on | <1 | Ready |
| [02 How the machine works](1-foundations/02-how-the-machine-works/README.md) | A shell system monitor and log rotator | The monitor matches the system; the rotator loses and repeats no line across 20 rotations of a full-speed writer; `shellcheck` is clean | 2 | Ready |
| [03 Go from zero](1-foundations/03-go-from-zero/README.md) | A CLI task engine; a JSON log analyser | Exact output on inputs you haven't seen; bad lines reported, not fatal; a million lines in under 64 MiB; the same answer with any number of workers; `-race` clean | 3 | Ready |
| [04 Python and the internet from zero](1-foundations/04-python-and-the-internet-from-zero/README.md) | A raw TCP echo server in Go, and a Python script that fires 1,000 requests at it and plots latency | Byte-exact echo for 100 clients at once while one sits silent; long lines refused with the message delivered; quiet clients dropped; p50 and p99 recomputed from your CSV; replies that arrive in pieces timed to the end | 3 | Ready |

### The core

For everyone. Each module builds on the one before it.

| Module | You build | Gate | Weeks | Status |
|---|---|---|---|---|
| [01 Go runtime and reliable services](2-core/01-go-runtime-and-reliable-services/README.md) | Switchyard's Go service: a jobs API with tests at three levels, deadlines, graceful shutdown, worker pools, idempotency, gRPC and a reconciliation loop | 10,000 state changes while workers are killed: state converges, the race detector is clean, no goroutines leak | 7 | Ready |
| [02 Python runtime and honest measurement](2-core/02-python-runtime-and-honest-measurement/README.md) | `kload`, an open-loop load generator, and the analysis behind it | Against a server that knows the truth: accurate on schedule, a freeze seen open and hidden closed, exit 3 when it falls behind, and repeat runs compared with an interval | 2 | Ready |
| [03 Docker and Postgres](2-core/03-docker-and-postgres/README.md) | A Postgres repository, bounded connection pooling, durable submissions, and worker recovery in Compose | Both repositories pass the contract; a killed control plane recovers the job and rejects the stale lease; replacing PostgreSQL preserves the data | 3 | Ready |
| [04 Rust foundations](2-core/04-rust-foundations/README.md) | Nine lessons, from Rust drills to `klog`, a checksummed append-only log | Preserve the verified prefix across every incomplete cut and a killed writer, and refuse complete corruption without rewriting bytes | 4 | Ready |
| [05 Rust for systems](2-core/05-rust-for-systems/README.md) | A zero-copy frame cursor, an SPSC ring, C and Python interop, and a hand-written executor | Check the ring with Loom, Miri, and TSan, fuzz the frame cursor, and run the C slice checks under ASan | 5 | Ready |
| [06 Linux, networking and profiling](2-core/06-linux-networking-and-profiling/README.md) | The Go ↔ Rust wire over TCP and Unix sockets, profiled and traced | Under injected loss and CPU contention: find the CPU bottleneck in a flame graph, fix it, and show the p99 gain | 5 | Ready |
| [07 Distributed-systems fundamentals](2-core/07-distributed-systems-fundamentals/README.md) | A Go Raft core on a simulated network and three Unix-socket peers backed by Rust `klog`; leases, fencing, and consistent hashing | Kill a writer mid-append during a partition. The majority commits, and the restarted peer repairs its log and catches up. | 6 | Ready |
| [08 Shipping safely](2-core/08-shipping-safely/README.md) | An mTLS gateway for Switchyard’s local Raft service, an external probe and alert, a recovery runbook, and an ADR | Break the upstream path, observe the alert, restore the saved configuration, and verify the original value | 3 | Ready |

**Optional deep dive, after core 05:** [C for Rust programmers](2-core/deep-dives/c-for-rust-programmers/README.md) (~2 weeks, Ready).

### When to take the extensions

Start at your current module. Use its gate to decide when to move on. Each extension builds on a specific skill from the route.

| Area | Learn when the route needs it | Go deeper when the work calls for it |
|---|---|---|
| Rust from C or C++ | Core 04 teaches Rust from first principles. Core 05 adds concurrency, native layout and C FFI. | [Wrap a C++ record reader in Rust](2-core/deep-dives/c-for-rust-programmers/deep-dives/cpp-record-reader.md) after Core 05 to see how a native component crosses the ABI. |
| Rust as a service | Core 01 teaches HTTP, error mapping, modular service boundaries and gRPC in Go. The Rust inference gateway and edge proxy apply service and networking skills to Rust workloads. | [Build a Rust job-status service](3-tracks/ai-infrastructure/deep-dives/rust-as-a-service.md) after Core 05 and Core 03 if you'll own a standalone Rust API. |
| Docker and Kubernetes | Learn Docker and Compose in Core 03 so you can run and debug a multi-process application. Use Kubernetes and delivery during your track to learn rollout, recovery and access boundaries. | Start with the [Kubernetes workload build](3-tracks/shared-units/kubernetes-and-delivery/deep-dives/workloads-and-rollouts.md), then take the [platform exercises](3-tracks/shared-units/kubernetes-and-delivery/exercises.md#kubernetes-platform-extensions) that match your work. |
| Debugging | Use tests, logs and traces from Core 01. Use Go profiles and Linux `perf` in Core 06 to find performance bottlenecks. | [Debug a failing Go program with Delve](2-core/06-linux-networking-and-profiling/deep-dives/debug-a-go-program.md) when you need to inspect live or saved process state. Take the Pod exercise after Kubernetes and delivery. |
| System design | Start with the [short-link lab](system-design/classic/url-shortener-lab.md) in Core 03 and practise weekly. | Use the [20 building blocks](system-design/fundamentals/README.md#20-system-design-building-blocks) as your designs add load, state, and failure modes. |

### Shared units

Written once, and pulled by the tracks that need them. If you take a second track, skip the units you've already done.

| Module | You build | Gate | Weeks | Status |
|---|---|---|---|---|
| [Kubernetes and delivery](3-tracks/shared-units/kubernetes-and-delivery/README.md) | Switchyard on kind with Helm, signed releases, Prometheus, and a worker controller | Block a failed canary, restore the last good release, and verify a replaced Raft voter reuses its volume | 5 | Ready |
| [AWS and Terraform](3-tracks/shared-units/aws-and-terraform/README.md) | Switchyard on Fargate and RDS, with private networking and scoped IAM | Mock both deployment phases, catch widened database ingress, and verify SQS receipt handling after a failed delivery | 2 | Ready |
| [Messaging and resilience](3-tracks/shared-units/messaging-and-resilience/README.md) | A versioned RabbitMQ producer and worker with PostgreSQL idempotency and dependency circuit breakers | Crash after commit, recover the completion from a redelivery, and prove that premature acknowledgment loses the delivery | 2 | Ready |
| [Event streams](3-tracks/shared-units/event-streams/README.md) | A Kafka job history and read model backed by a PostgreSQL outbox and inbox | Crash the relay and projector, resume from committed offsets, and rebuild the same model from the retained log | 2 | Ready |
| [Caching](3-tracks/shared-units/caching/README.md) | Redis cache-aside for PostgreSQL job status, with TTLs, invalidation, and singleflight | Measure one PostgreSQL read for 32 concurrent readers in one process and verify database fallback during a Redis pause | 1 | Ready |
| [Tenancy and abuse control](3-tracks/shared-units/tenancy-and-abuse-control/README.md) | A token issuer, explicit route policy, PostgreSQL row-level security, and a shared Redis quota | Verify key overlap and tenant isolation, then enforce one tenant budget across two API instances | 3 | Ready |

### The tracks

Pick one. Each lists the shared units it needs.

**[AI infrastructure](3-tracks/ai-infrastructure/README.md)** (~34 weeks with units). Needs: Kubernetes and delivery; Tenancy and abuse control.

| Module | You build | Gate | Weeks | Status |
|---|---|---|---|---|
| [01 ML for infrastructure](3-tracks/ai-infrastructure/01-ml-for-infrastructure/README.md) | A Parquet pipeline and CPU PyTorch job-duration model with a versioned registry | Beat the held-out baselines, refuse a weak release, detect a shifted input window, and restore the previous prediction over HTTP | 5 | Ready |
| [02 Serving and scaling models](3-tracks/ai-infrastructure/02-serving-and-scaling-models/README.md) | A serving lab and a bounded inference gateway; batching, data and model parallelism, Ray, CUDA | Pass every test and two-process training parity; remove the causal mask, the truncation check, failures from the denominator and a slot release, and see each caught | 7 | Ready |
| [03 A Rust inference gateway](3-tracks/ai-infrastructure/03-rust-inference-gateway/README.md) | A bounded Rust chat proxy with SSE framing and weighted tenant token buckets | Drop a client, observe the upstream body close, and verify the slot returns while the reservation stays charged | 3 | Ready |
| [04 Securing the AI layer](3-tracks/ai-infrastructure/04-securing-the-ai-layer/README.md) | A tool-using agent, attacked with real prompt injection, then defended outside the model | Pass the adversarial suite against a scripted model; remove each of six defences, from approval to the tool server's tenant check, and see each caught | 9 | Ready |
| [05 Capstone: an inference gateway](3-tracks/ai-infrastructure/05-capstone-inference-gateway/README.md) | A packaged streaming chat gateway with a CPU model benchmark and before-and-after profiles | Match the stream contract in both decoder builds, exclude incomplete streams from goodput, and separate parser speed from client latency | 2 | Ready |

**[Storage engines](3-tracks/storage-engines/README.md)** (~26 weeks with units). Needs: Kubernetes and delivery; Event streams; Caching; Tenancy and abuse control.

| Module | You build | Gate | Weeks | Status |
|---|---|---|---|---|
| [01 Postgres in depth](3-tracks/storage-engines/01-postgres-in-depth/README.md) | Transaction schedules, a partial B-tree index, and a fenced background-job queue | Catch a blocking claimant, preserve an acknowledged write after SIGKILL, and recover a deleted row from archived WAL | 3 | Ready |
| [02 Consensus in depth](3-tracks/storage-engines/02-consensus-in-depth/README.md) | A replicated key-value store with durable snapshots, a TLA+ election model, and a fenced range handoff | Recover through compaction and partitions, verify client histories and election safety, and recover a prepared transfer across shards | 4 | Ready |
| [03 A Rust storage engine](3-tracks/storage-engines/03-rust-storage-engine/README.md) | A Rust LSM engine with a WAL, indexed SSTables, Bloom filters, and MVCC reads | Recover acknowledged writes across interrupted publication, preserve pinned reads through compaction, and measure block probes | 4 | Ready |
| [04 Integrity and encryption](3-tracks/storage-engines/04-integrity-and-encryption/README.md) | Tenant-scoped storage, encrypted values, and a witnessed job-event log | Verify tenant boundaries, reject invalid ciphertext, and check audit replay and checkpoint continuity | 2 | Ready |
| [05 Capstone: a distributed KV store](3-tracks/storage-engines/05-capstone-distributed-kv-store/README.md) | A three-peer Go/Rust key-value service with a reproducible YCSB benchmark | Recover a committed write after leader loss, rebuild a lagging Rust projection, and compare read paths with matched workloads and profiles | 2 | Ready |

**[Cloud and network](3-tracks/cloud-and-network/README.md)** (~25 weeks with units). Needs: Kubernetes and delivery; AWS and Terraform; Messaging and resilience; Tenancy and abuse control.

| Module | You build | Gate | Weeks | Status |
|---|---|---|---|---|
| [01 Networking in depth](3-tracks/cloud-and-network/01-networking-in-depth/README.md) | A calibrated link lab, matched HTTP/2 and HTTP/3 workloads, and an anycast route simulator | Check negotiated protocols and edge cache hits, observe route and partial-partition recovery, and measure loss and loaded RTT | 4 | Ready |
| [02 A Rust edge proxy](3-tracks/cloud-and-network/02-rust-edge-proxy/README.md) | An L4/L7 proxy with pooling and circuit breaking, benchmarked against Envoy | Verify TCP half-close, HTTP routing and connection reuse, and fault isolation and breaker recovery with loopback origins | 4 | Ready |
| [03 The proxy's control plane](3-tracks/cloud-and-network/03-proxy-control-plane/README.md) | Config push, health checks, mTLS rotation, a sidecar, signed webhooks, eBPF/XDP | Verify request continuity across route updates, reject a peer with the wrong identity, and check webhook and key rotation | 3 | Ready |
| [04 Capstone: a programmable edge proxy](3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy/README.md) | A standalone programmable edge proxy with performance evidence and a design record | Verify in-flight requests survive reload and rollback, account for every load-test request, and rebuild from the export | 2 | Ready |

Track parts' weeks are estimates until each part is outlined. **Coming later:** kernel, embedded and robotics tracks ([coming-soon.md](3-tracks/coming-soon.md)).

---

## 5. Languages and tools

| Language | Enters | Role | Why |
|---|---|---|---|
| **Bash** | Foundations 02 | Running, inspecting and automating | Every server is operated from a shell |
| **Go** | Foundations 03 | The control plane: APIs, workers, Raft, controllers | Most cloud-native infrastructure is written in Go |
| **Python** | Foundations 04 | Load generation, experiments, data, ML | The language of measurement, data and ML |
| **SQL** | Core 03 | Durable records, analysis | Every backend and data role needs it |
| **Rust** | Core 04 | The data plane: logs, parsers, proxies, storage engines | Memory safety without a garbage collector; bytes and ownership made explicit |
| **YAML** | Core 01 (CI) | Workflows, Kubernetes manifests | Everywhere in operations |
| **C** | Optional deep dive | Reading and calling C libraries | Much systems code you'll meet is C or C++ |
| **HCL (Terraform)** | AWS and Terraform | Infrastructure as code | Expected in cloud and platform roles |
| **TLA+** | Storage engines 02 | Model-checking a protocol | Standard where consensus correctness matters |

**The principle:** Go for the control plane, Rust for the data plane, Python for measurement and ML. Each language is taught on its own terms, syntax and how it works first, before it's used to build anything.

**One tool per job, with alternatives studied but not rebuilt:**

| Job | Core | Compare only |
|---|---|---|
| HTTP routing | Go `net/http` | chi, Gin |
| RPC | gRPC and protobuf | HTTP/JSON |
| Database | PostgreSQL (pgx, goose) | DynamoDB |
| Async Rust | Tokio, after one executor by hand | async-std, smol |
| Consensus | Your own Raft | hashicorp/raft, etcd |
| Work queues | RabbitMQ | SQS |
| Event streams | Kafka | NATS JetStream, Redpanda |
| Cache | Redis | Memcached |
| Orchestration | Kubernetes (kind), Helm | EKS, Nomad |
| Cloud | AWS with Terraform | GCP, Azure |
| Proxies | Your own Rust proxy | Envoy, NGINX |
| Observability | OpenTelemetry, Prometheus, Grafana | Loki, Tempo |
| ML | PyTorch, MLflow | KServe |
| Security | govulncheck, Trivy, Syft, cosign | OPA/Rego |

---

## 6. Alongside the route

These run alongside the modules. The modules don't teach them, but they reuse what the modules build.

| Practice | Starts | Cadence | Where |
|---|---|---|---|
| Algorithms and data structures | Foundations 03 | 3 sessions a week, pattern by pattern, in Go and Python | [dsa/](dsa/README.md) |
| System design | Core 03 | 1 session a week, scored against a rubric | [system-design/](system-design/README.md) |
| Maths | Queueing with core 02; proofs with core 07; linear algebra before the AI track; capacity planning from Core 08 | One guide at a time, when its module needs it | [math/](math/README.md) |
| Production ownership | Core 08 | One tabletop after the game day | [Production ownership](ownership/README.md) |
| Writing | Core 01 | One essay per module, drawn from your failures and decisions | Your own blog |
| Paper reading | Core 06; weekly from core 07 | Three-pass method; one-page notes | Your own repository |
| Job applications | During your track (earlier for backend roles) | Tailored, with links to your evidence | [career.md](career.md) |

---

## 7. Books

Each lesson tells you exactly which chapter or paper to read, at the step where it helps. This is just the shelf.

| Book | Free? | Used in |
|---|---|---|
| *Operating Systems: Three Easy Pieces* (Arpaci-Dusseau) | [Yes](https://pages.cs.wisc.edu/~remzi/OSTEP/) | Foundations 02; core 04, 06 |
| *Computer Systems: A Programmer's Perspective* (Bryant & O'Hallaron, 3rd ed.) | No | Foundations 02; core 05, 06 |
| *Computer Networking: A Top-Down Approach* (Kurose & Ross, 8th ed.) | No | Foundations 04; core 06; cloud and network |
| *Designing Data-Intensive Applications* (Kleppmann) | No | Core 01, 03, 07; storage engines |
| *Understanding Distributed Systems* (Vitillo) | No | Core 01, 07 |
| *Distributed Systems* (van Steen & Tanenbaum, 4th ed.) | [Yes](https://www.distributed-systems.net/) | Core 07; storage engines |
| *Site Reliability Engineering* (Google) | [Yes](https://sre.google/books/) | Core 01, 08 |
| *The Rust Programming Language* | [Yes](https://doc.rust-lang.org/book/) | Core 04 |
| *Rust Atomics and Locks* (Bos) | [Yes](https://marabos.nl/atomics/) | Core 05 |
| *Database Internals* (Petrov) | No | Core 03; storage engines |
| *Kubernetes in Action* (Lukša) | No | Kubernetes and delivery |
| *Systems Performance* (Gregg, 2nd ed.) | No | Core 06 |
| *Security Engineering* (Anderson, 3rd ed.) | Partly | Core 08; tenancy and abuse control |
| *Designing Machine Learning Systems* (Huyen) | No | AI infrastructure |
| *The Linux Command Line* (Shotts) | [Yes](https://linuxcommand.org/tlcl.php) | Foundations 02; reference |
