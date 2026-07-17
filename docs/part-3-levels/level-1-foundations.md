# Level I — Engineering Foundations

*A full mini-course: theory → labs → production flagship → exit criteria.*

*Part of [The Nicholas Emmanuel Engineering Blueprint](../../README.md) — v1.1*

---

# Chapter 19 · Level I — Engineering Foundations

**Weeks 1–5 · Flagship: EMBER · Cloud: AWS · Pre-covers: CIS 5050 (foundations), CIS 5530 (transport), CIS 5580 (machine-fluency prereq)**

### Overview & why it matters

Everything above the operating system is opinion; this level makes yours informed. Four-plus years of Go built fluency in abstractions — this level goes underneath them, to memory, syscalls, TCP, TLS, and threads, so that every later system is reasoned about from the metal up. It is short by design (you are closing gaps, not starting over) and dense by necessity.

### Objectives / Learning outcomes

- Explain and measure what a pointer dereference, a syscall, a TCP handshake, and a TLS negotiation actually cost.
- Write a correct epoll event loop in C and a production HTTP server in Go — and articulate the tradeoff between them.
- Restore the CIS 2400-level machine fluency that CIS 5580 assumes and CIS 5050/5530 build on.
- Ship EMBER: shared infrastructure that fronts every later flagship.

### Prerequisites

Comfortable Go; basic Linux command line; willingness to write C. Shore up first (Week 0, optional): a C refresher (K&R ch. 1–5) if C feels distant.

### Timeline

Five weeks, one theme each: memory → OS interface → networking → concurrency → TLS/security. Every week ends with committed, running code. No week of pure reading.

### Theory

- Memory & the machine: virtual memory, TLBs, cache lines, false sharing, stack vs heap, allocators.
- The OS interface: processes, fork/exec, signals, file descriptors, the select → poll → epoll progression, io_uring awareness.
- Networking from sockets: TCP lifecycle, Nagle, backlog, HTTP/1.1 grammar, HOL blocking.
- Concurrency: threads, mutexes, condvars, atomics, memory ordering; Go’s scheduler and race detector as contrast.
- TLS 1.3 & systems security: handshake, certificates, mTLS; sandboxing (seccomp, namespaces); fuzzing.

### Architecture concepts

- Event-driven vs thread-per-connection — why nginx and envoy chose what they chose.
- Control plane vs data plane as a design instinct, introduced early and reused everywhere after.
- Backpressure at the socket level: accept queues, read buffers, slow clients.
- Hot-reloadable config (atomic pointer swap) vs restart-to-apply.

### Hands-on labs

- Wk1: arena allocator in C; measure cache effects with perf; find the leak with valgrind.
- Wk2: epoll echo server in C handling 10k idle connections; strace its every move.
- Wk3: hand-written HTTP/1.1 parser + static server in C; watch every byte in tcpdump; fuzz the parser.
- Wk4: port to Go; goroutine-per-conn vs event-loop benchmark; race-detect under load.
- Wk5: add TLS 1.3 termination; run AFL on the parser; write up the findings.

### Assignments

- Integrate the labs into EMBER’s data plane (C core kept and documented; Go production build).
- Benchmark EMBER vs nginx on identical EC2; produce flamegraphs before/after one optimization.
- Cryptopals Set 1 complete (Crypto Thread warm-up).

### Production project — EMBER, the edge gateway

A production-grade edge gateway — TLS termination, reverse proxying, LRU caching, token-bucket rate limiting — built from raw sockets, with a BoltDB-backed control plane (routes, certs, limits, append-only audit), a middleware chain (limit → cache → circuit breaker → access log), Prometheus/Grafana observability, and a Next.js admin console. Multi-tenant, hot-reloadable, deployed on AWS behind your own TLS. Full charter in Part VI.

### Reading — tiered

- **Required:** CS:APP ch. 1–3, 5–6, 9, 12 · Beej’s Guide (all) · Kurose & Ross ch. 1–3 (begins) · “The C10K Problem.”
- **Recommended:** The Linux Programming Interface ch. 4–6, 24–27, 56–63 · Bulletproof TLS ch. 1–2 · Drepper, “What Every Programmer Should Know About Memory.”
- **Papers/RFCs:** RFC 9110 (HTTP semantics, skim) · RFC 8446 (TLS 1.3, the handshake section).
- **Blogs:** Cloudflare on epoll and TLS 1.3. **Talks:** Kavya Joshi, “The Scheduler Saga.” **Repos:** read a slice of nginx or fasthttp source.

### Open source tasks

Stage 1–2 of the ladder (Part IV): choose the organization (etcd recommended), set up the fork, read the architecture docs and the main loop. No PR required yet — the goal is orientation.

### Deliverables

- **GitHub:** ember repo public from Wk3; profile README rewritten around the identity sentence by Wk2.
- **Portfolio:** EMBER added to the site with its diagram and demo GIF.
- **Blog:** post #1 — “I Built an Edge Gateway from Raw Sockets: What nginx Does That I Didn’t Appreciate.”

### Interview topics unlocked

epoll vs threads; TCP tuning; what TLS actually negotiates; where backpressure lives; “design a rate limiter”; “what happens when you type a URL” — answered from having built it.

### Weekly schedule

Chapter 14 default, with mornings on the week’s systems theme and Saturday long-blocks on the C→Go builds. Applications not yet active; evening slots feed project and reading.

### Exit criteria

- EMBER serves your portfolio site in production on AWS, behind its own TLS.
- README meets the Meridian Standard; benchmark vs nginx published; one flamegraph story written.
- Cryptopals Set 1 done; blog post #1 drafted; reading-log entries 1–5 published.

### Reflection questions

What did building a server from sockets teach that using one never could? Where did C’s failure modes change how you’ll write Go? What did the nginx benchmark humble?
