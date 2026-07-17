# LATTICE — Distributed Search Engine

*Organization-grade project charter (24-point standard).*

*Part of [The Nicholas Emmanuel Engineering Blueprint](../../README.md) — v1.1*

---

# Chapter 42 · LATTICE — Distributed Search Engine

**Level II · Weeks 6–15 · AWS · Consumes: EMBER (query-tier front door) · Provides: the distributed-systems vocabulary for all later work**

### 1–2 · Vision & problem

Search is the canonical distributed-systems problem: crawl the web, store it, compute over it, serve it fast. LATTICE builds a Google-style engine on infrastructure written from scratch — the single most legible proof of distributed-systems depth, and a live pre-build of CIS 5550’s final project.

### 3 · Functional requirements

- Crawl ≥1M pages politely (robots, per-host rate); dedup with SimHash; store raw pages in S3.
- Build an inverted index and PageRank as distributed compute jobs; serve ranked queries.
- Return results with a per-stage latency breakdown; expose corpus/index stats.

### 4 · Non-functional requirements

- Query p99 < 200 ms over ≥1M pages; index build scales near-linearly 3→9 workers.
- Survives node loss: partial results within deadline; deterministic job re-execution.
- Whole-run cost measured and published.

### 5–6 · Constraints & trade-offs

- **Constraint:** no managed data services — KV store, compute engine, queue all hand-built; S3 for cold pages only.
- **Trade-off:** LatticeKV chooses availability + tunable quorums (Dynamo-style) over strong consistency everywhere — correct for a search corpus, explicitly wrong for, say, payments. Documented as a conscious choice.
- **Trade-off:** term-sharded index (fast queries, harder rebalancing) vs document-sharded — chose query latency.

### 7–9 · Architecture / sequence / component (described)

- **Architecture:** Crawler → LatticeKV (frontier, pages, index, pagerank tables) ← WEAVE (index + rank jobs); Query tier reads the index, fronted by EMBER; S3 holds raw pages.
- **Sequence (query):** client → EMBER (TLS, cache) → query tier → scatter to index shards → gather partial results within deadline → rank → respond with stage timings.
- **Component:** kv (ring, replica, quorum, repair) · weave (coordinator, worker, shuffle) · crawler · indexer · rank · query · chaos harness.

### 10–11 · Schema & API

- **LatticeKV tables:** frontier(url→state,depth,next_fetch) · pages(url→s3_ref,simhash) · index(term→posting shards) · pagerank(url→score) · hosts(host→robots,delay).
- **API:** GET /v1/search?q=&limit= (results + stage latencies) · GET /v1/stats. **Internal gRPC:** kv.Get/Put/Scan (quorum params) · weave.SubmitJob/TaskStream · crawler.LeaseURLs/ReportFetch.

### 14–15 · Threat model & security

Assets: the corpus, the serving path. Adversaries: crawler traps, query-path abuse. Controls: crawl budgets and politeness, query rate limits (EMBER), input validation on the search API, resource caps on scatter-gather.

### 19–20 · Testing & benchmarks

- Unit (hashing, ranking); integration (crawl→index→query); property (KV linearizability on strong path); chaos (shard kill, ring partition, worker death mid-PageRank).
- Published: pages crawled, index build scaling curve (3→9 workers), query p50/p99 with/without EMBER cache, total dollar cost.

### 22–24 · Scalability roadmap, future, lessons

- **Scale:** more index shards + workers; read replicas for hot terms; tiered storage. **Future:** semantic ranking, incremental crawl, query autocomplete. **Lessons:** the million-page-crawl blog post — backpressure and tail latency, learned the hard way.
