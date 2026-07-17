# Level II — Distributed Systems

*A full mini-course: theory → labs → production flagship → exit criteria.*

*Part of [The Nicholas Emmanuel Engineering Blueprint](../../README.md) — v1.1*

---

# Chapter 20 · Level II — Distributed Systems

**Weeks 6–15 · Flagship: LATTICE (+ MERIDIAN re-examined) · Cloud: AWS · Pre-covers: CIS 5550 fully, CIS 5530, CIS 5050, parts of CIS 5500**

### Overview & why it matters

The heart of the blueprint and the anchor of the identity. Ten weeks that pre-cover CIS 5550 end-to-end by building its stated final project — a Google-style search engine on infrastructure you wrote — before the course begins. This is the level that makes “distributed systems engineer” a claim you can defend under hostile questioning, and LATTICE the single most legible proof on your GitHub.

### Objectives / Learning outcomes

- Reason about time, ordering, consensus, replication, and consistency at teach-it depth.
- Build a partitioned, replicated KV store; a MapReduce-style compute engine; a distributed crawler; an indexer/ranker; a query tier — all from scratch.
- Verify distributed correctness: linearizability checking, chaos testing, partition injection.
- Re-examine MERIDIAN with fresh theory — turning a shipped project into a defended one.

### Prerequisites

Level I complete (EMBER fronts LATTICE’s query tier). Comfort with gRPC helps; it’s built in Wk7 regardless.

### Timeline

Ten weeks: foundations & clocks (6–7) → storage & consensus (8–9) → the Dynamo-style KV (10) → compute engine (11) → crawler/index/rank (12–13) → serving (14) → verification & ship (15). MIT 6.824 runs in parallel, one lecture/week.

### Theory

- Failure models, partial failure, time & ordering, Lamport & vector clocks.
- RPC done right: deadlines, idempotent retries, hedged requests, backpressure.
- Storage & replication: WAL discipline, leader/follower vs quorum, read-your-writes.
- Consensus, second pass: Raft (membership, snapshots, read-index), Paxos for contrast, linearizability.
- Availability: consistent hashing, quorum R/W, hinted handoff, anti-entropy.
- Batch compute: MapReduce, DAGs, shuffle, deterministic re-execution.
- Search internals: crawling politeness, SimHash dedup, inverted indexes, TF-IDF, PageRank.

### Architecture concepts

- Consistency as a per-request choice (Meridian’s thesis, generalized to serving reads).
- Partitioning strategy: hash vs range — why the index shards by term and the frontier by host.
- Coordination avoidance: what LATTICE deliberately does without consensus, and why.
- End-to-end backpressure across crawler → KV → indexer.

### Hands-on labs & assignments

- Labs: clean-room Lamport + vector clocks (property-tested); a shared RPC layer with interceptors; a single-node WAL engine; a linearizability checker (ported from Meridian’s harness).
- Assignments: LatticeKV multi-node (ring, N=3, sloppy quorums, hinted handoff); WEAVE running wordcount on 10 GB then PageRank; a distributed crawler doing 100k+ polite fetches; a queryable inverted index; the full ≥1M-page run under a chaos suite.

### Production project — LATTICE

A Google-style search engine: LatticeKV (partitioned/replicated KV with quorum tunability), WEAVE (MapReduce-style compute with fault-tolerant re-execution), a distributed crawler (frontier in LatticeKV, S3 cold storage), an indexer/ranker (term-sharded inverted index + PageRank as WEAVE jobs), and a query tier behind EMBER returning per-stage latency budgets. Target: p99 < 200 ms over ≥1M pages, with the whole run’s dollar cost published. Full charter in Part VI.

### Reading — tiered

- **Required:** Designing Data-Intensive Applications (the whole book) · Kurose & Ross ch. 4–6 (finish) · the paper canon below.
- **Recommended:** Database Internals (Petrov) part II · van Steen & Tanenbaum ch. 1–6 as the formal reference.
- **Papers (one/week, logged):** Lamport “Time, Clocks” · “The Tail at Scale” · GFS · Raft (extended) + “Paxos Made Simple” · Dynamo · MapReduce + Spark/RDD · “Anatomy of a Large-Scale Search Engine” · Bigtable · Spanner · ZooKeeper/Chubby.
- **Blogs:** Cockroach Labs, Cloudflare, Jepsen (two analyses). **RFCs/specs:** the Raft paper as spec; gRPC docs. **Repos:** etcd’s raft package — read it, you’ve built this.

### Open source tasks

Ladder Stages 3–4: documentation PRs (Month 1) then small bug fixes (Month 2). **First merged PR by Week 9.** Stay in one subsystem — for etcd, the raft package you now know cold.

### Deliverables

- **GitHub:** lattice public from Wk8; LatticeKV design doc posted for critique Wk8; first OSS PR Wk9.
- **Portfolio:** LATTICE with live demo URL and the latency-budget UI.
- **Blog:** post #2 — “I Built Google, Badly, On Purpose: What a Million-Page Crawl Teaches You About Distributed Systems” + technical/architecture/reflection pieces per the writing package.

### Interview topics unlocked

CAP in practice; Raft vs Paxos; quorum math; consistent hashing; linearizability vs causal; “design a KV store / web crawler / search engine”; tail-latency mitigation; the full distributed-systems theory bank (gossip, vector clocks, replication, sharding, backpressure).

### Weekly schedule

Chapter 14 default; 6.824 lecture in a Monday learning slot; Saturday long-blocks on the KV/compute builds. Networking active (5 quality connects/week). Applications still pending until Wk18.

### Exit criteria

- LATTICE live behind EMBER, p99 < 200 ms over ≥1M pages, chaos suite passing.
- Meridian-Standard README; 6.824 lectures 1–10 watched; ~10 papers logged; first OSS PR merged.
- MERIDIAN’s README upgraded with the theory vocabulary from this level.

### Reflection questions

Where did the theory change a decision you’d have made by instinct? What did the linearizability checker catch that testing wouldn’t? Which paper most changed how you see your own systems?
