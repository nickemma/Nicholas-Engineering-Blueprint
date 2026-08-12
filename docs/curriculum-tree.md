# The Curriculum Tree

**Emmanuel Nicholas · @NickEmma · Distributed Systems & AI Infrastructure Engineer**

**End goal:** by month 12, design, implement, secure, operate, and explain a production-grade distributed AI infrastructure system.

---

## The budget

20 hrs/week · 3-4-hour lessons · ~4-5 lessons/week · **x stages, ~x lessons, x weeks**

| Day | Hours | What |
|---|---|---|
| Mon | 3 | Lesson |
| Tue | 3 | Lesson |
| Wed | 4 | Independent build / fix what broke |
| Thu | 3 | Lesson |
| Fri | 3 | Lesson (usually BREAK or EXPERIMENT type) |
| Sat | 3 | DSA (1.5) + system design (1.5) |
| Sun | 3 | Independent build (2) + reflection write-up (1) |

If a week slips, drop the Wednesday build before you drop a lesson. Never drop Sunday's reflection — the redesign answer is where the learning actually consolidates.

---

## The spine

Every stage answers one question. The question is the point; the technologies are how you answer it.

```
LAYER 1 — ONE MACHINE
  S1  How does a computer run your code?
  S2  How does an operating system keep programs from destroying each other?
  S3  How do two machines talk?
  S4  How does one machine serve many users reliably?

LAYER 2 — RUNNING THINGS
  S5  How do you package and place software on machines?
  S6  What is a model, and what does serving one actually require?

LAYER 3 — DATA THAT SURVIVES
  S7  How does a database not lose your data when the power cuts?
  S8  What breaks when one machine becomes many?
  S9  How do machines that disagree reach a decision?
  S10 How do you split data across machines and still be correct?

LAYER 4 — OPERATING AT SCALE
  S11 How do you run a stateful distributed system in production?
  S12 How do you know it's healthy, and what do you do at 3am?
  S13 How do you keep attackers out of all of it?

LAYER 5 — AI INFRASTRUCTURE
  S14 What is actually happening inside a model?
  S15 Why is serving an LLM different from serving an API?
  S16 What changes when the model doesn't fit on one GPU?
  S17 How do you turn that into a multi-tenant platform with an economy?
  S18 How do you secure a platform whose workload can be manipulated by input?

LAYER 6 — PROVING IT
  S19 Can you design one from scratch and defend it?
```

---

## Stage detail

Lesson counts for S1–S4 are fixed. S5 onward are ranges, finalised when we reach them — your pace through concurrency and consensus determines the rest.

### LAYER 1 — ONE MACHINE

**S1 · How does a computer run your code?** · 16 lessons · weeks 1–5
Programs, processes, memory, CPU, the kernel, signals, files. Then Go from zero: types, pointers, interfaces, goroutines, channels, mutexes, GC, profiling.
**You build:** a long-running Linux service in Go — config, signals, structured logs, metrics, graceful shutdown.
**Done when:** you can trace what happens from `go run main.go` to your code executing, and read a stack trace without guessing.

**S2 · How does an OS keep programs from destroying each other?** · 8 lessons · weeks 6–7
Virtual memory, paging, scheduling, system calls, namespaces, cgroups. Failure as a normal condition.
**You build:** a process supervisor — starts children, restarts crashed ones, captures logs, enforces memory limits, shuts down gracefully.
**Done when:** you can distinguish a SIGKILL, a SIGSEGV, and an OOM kill from the logs alone.

**S3 · How do two machines talk?** · 12 lessons · weeks 8–10
Sockets, IP, TCP (handshake, windows, congestion), UDP, DNS, TLS, HTTP/1.1, HTTP/2, QUIC. Reading actual packets.
**You build:** a TCP echo server → a protocol with framing → an HTTP server, all from `net.Listen` up.
**Done when:** you can explain every layer between `net.Listen("tcp", ":8080")` and a packet on the wire.

**S4 · How does one machine serve many users reliably?** · 10 lessons · weeks 11–13
Concurrency limits, backpressure, timeouts, retries, idempotency, circuit breakers, health checks, load balancing, RPC, gRPC.
**You build:** your own RPC framework on raw TCP — request IDs, serialisation, pooling, health checks — then rebuild it on gRPC and compare.
**Done when:** you can answer "what happens if the response is lost but the request succeeded?" with working code.

### LAYER 2 — RUNNING THINGS

**S5 · How do you package and place software on machines?** · 8 lessons · weeks 14–15
Images, layers, namespaces, cgroups (again, now as containers). Pods, services, deployments, probes, limits. Kubernetes as a user, not an operator.
**You build:** a container from scratch in Go (~200 lines), then your S4 service deployed on `kind`.

**S6 · What is a model, and what does serving one actually require?** · 8 lessons · weeks 16–17
Tokens, weights, context, prefill vs decode — plain English, no maths yet. Running a small model locally. Multi-tenancy, budgets, metering.
**You build:** the first running version of your inference gateway — CPU only, small model, real measurements. **It stays running from here to month 12.**

### LAYER 3 — DATA THAT SURVIVES

**S7 · How does a database not lose your data?** · 12 lessons · weeks 18–21
Write-ahead logs, fsync and what it actually guarantees, B-trees, LSM trees, memtables, SSTables, compaction, crash recovery, MVCC, isolation levels.
**You build:** a single-node storage engine in Go with a WAL and crash recovery.
**Case study:** PostgreSQL, RocksDB.

**S8 · What breaks when one machine becomes many?** · 10 lessons · weeks 22–24
Three friends with one notebook. Then: replication, clocks that disagree, ordering, causality, partial failure, the eight fallacies, CAP as an engineering constraint not a slogan.
**You build:** a replicated key-value store with no consensus — deliberately. You'll see it go wrong.

**S9 · How do machines that disagree reach a decision?** · 12 lessons · weeks 25–28
Leader election, log replication, terms, persistence, snapshots, safety proofs in plain English. Raft.
**You build:** Raft in Go, then kill nodes randomly until it recovers every time.
**Case study:** etcd → the Kubernetes control plane.

**S10 · How do you split data and stay correct?** · 10 lessons · weeks 29–31
Sharding, consistent hashing, rebalancing, quorums, linearizability vs serializability, distributed transactions, two-phase commit and why people avoid it.
**You build:** sharding and live reconfiguration on top of your Raft KV store.

### LAYER 4 — OPERATING AT SCALE

**S11 · How do you run a stateful distributed system in production?** · 12 lessons · weeks 32–35
StatefulSets, operators, storage, disruption budgets, rolling upgrades of stateful workloads, Kafka, ingest backpressure, dead letter queues, Terraform, GitOps.
**You build:** LATTICE — a search and retrieval platform. 1M documents, hybrid keyword + vector, Go indexer and query service.

**S12 · How do you know it's healthy, and what do you do at 3am?** · 10 lessons · weeks 36–38
Metrics, histograms, tracing, SLIs/SLOs/error budgets, alerting on symptoms, capacity planning, runbooks, postmortems. Chaos: kill nodes, fill disks, drop packets, expire certificates.
**You build:** the operational apparatus for LATTICE, plus a real postmortem from something you broke.

**S13 · How do you keep attackers out?** · 10 lessons · weeks 39–40
AuthN vs authZ, sessions, OAuth, JWT and its traps, secrets, mTLS, certificates, RBAC, network policies, seccomp, non-root containers, threat modelling.
**You build:** a hardened LATTICE + a written threat model.

### LAYER 5 — AI INFRASTRUCTURE

**S14 · What is actually happening inside a model?** · 8 lessons · weeks 41–42
Embeddings, attention (intuition first — "what does *it* refer to?"), transformers, training vs inference, quantisation. Maths introduced only where it changes a decision.
**You build:** a tiny transformer, once, so nothing downstream is magic.

**S15 · Why is serving an LLM different from serving an API?** · 12 lessons · weeks 43–45
Prefill vs decode, KV cache and its memory maths, continuous batching, chunked prefill, prefix caching, speculative decoding, TTFT vs inter-token latency, why memory bandwidth beats FLOPs.
**You build:** real vLLM on GPU behind your gateway. Measured TTFT, tokens/sec, cost per million tokens.
**Case study:** vLLM's scheduler and block manager.

**S16 · What changes when the model doesn't fit on one GPU?** · 10 lessons · weeks 46–47
GPU memory, tensor/pipeline/expert parallelism, collective communication, request routing, autoscaling on queue depth, GPU scheduling on Kubernetes.

**S17 · How does that become a platform?** · 12 lessons · weeks 48–50
Multi-tenancy, budgets enforced before the GPU, metering, model routing and fallback, semantic caching, model registry, versioning, canary and rollback. **LATTICE becomes the retrieval tier inside the platform.**
**You build:** one system — gateway → retrieval → inference → metering → audit.

**S18 · How do you secure a workload the input can manipulate?** · 8 lessons · weeks 51–52
Tenant isolation across a shared KV/prefix cache, model supply chain and signing, prompt injection at the infrastructure boundary (credentials, egress, blast radius — not model refusal), audit that survives the cluster.

### LAYER 6 — PROVING IT

**S19 · Can you design one from scratch and defend it?** · 8 lessons · week 52+
You write the design document for: *serve a 400B model to 50,000 concurrent users, 99.99% availability, strict tenant isolation, low latency, automatic failover.* Then I interrogate it the way a staff engineer on a hiring panel would. Capacity maths, failure domains, 20× traffic, why tensor parallel and not pipeline, what happens when a GPU dies mid-decode, where the cost actually goes.

You will not pass first time. That's the design.

---

## Running in parallel, all 49 weeks

- **Saturdays** — DSA in Go/Python (NeetCode 150/Blind 75 order) + system design. Non-negotiable, never merged into build time.
- **The gateway from S6 stays up.** Operating is a duration, not a drill.
- **One published write-up per month** — a finding, not a tutorial.
- **Reflection after every project and every failure** — see `04-TEMPLATES.md`.

---

## Where the flagship repos land

| Repo | Enters at | Leaves as |
|---|---|---|
| `tessera` | S6 (week 16) | The platform, S17–S18 |
| `lattice` | S11 (week 32) | The retrieval tier inside tessera, S17 |
| `synapse-ai` | Capstone Indepth | S18's thinking is its on-ramp and Your production credential |

---

*Adjust depth freely. If a topic needs 3 lessons instead of 1, it gets 3. If you already own something, we test it in ten minutes and move.*
