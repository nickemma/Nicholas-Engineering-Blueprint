# 8. Consistent authorization at scale: a Zanzibar-style permission service

**Field:** security · distributed systems · **Difficulty:** high · **Language:** Go

## Problem

Every request in a multi-tenant product asks: may this user do this to this object? Phase 6 answered with roles and a policy decision point. Real products need **relationships**:

- documents shared with groups;
- folders whose permissions pass to everything inside;
- organisations nested in organisations.

The checks sit on every request, so they must be fast. They must also stay correct after changes. Suppose Alice removes Bob from a folder, then puts a confidential document in it. Bob must not see that document. This is the "new enemy" problem. Caching and replicas make checks fast, and they make exactly this mistake easy.

## Who

SaaS teams with sharing (documents, code hosting, project tools); teams moving from roles to fine-grained permissions; and the security engineers who must say who can see what.

## Gap

- Google's Zanzibar (Pang et al., USENIX ATC 2019) solves this with three things:
  - relationship tuples;
  - a globally consistent database (Spanner);
  - snapshot tokens that let a check be "at least as fresh as" a given write.
- Open-source systems such as [SpiceDB](https://authzed.com/spicedb) and [OpenFGA](https://openfga.dev/) follow the model on ordinary databases, without Spanner's clocks.
- How the consistency choices trade check latency against new-enemy violations is rarely measured outside Google:
  - fully consistent checks;
  - snapshot tokens;
  - bounded staleness;
  - the comparison holds for deep and wide sharing graphs and under replication lag.

## Research question

> On a replicated relationship store without synchronised clocks, how do fully consistent checks, snapshot-token checks and bounded-staleness checks compare in check latency, throughput and new-enemy violations, for deep and wide sharing graphs? What does an index of nested groups buy, and what does it cost writes?

## Hypothesis and baseline

- **Baselines:**
  - Phase 6's role-based decision point, for latency (it can't express sharing);
  - fully consistent checks against the primary, for correctness.
- **Hypothesis:**
  - Snapshot tokens taken from PostgreSQL's write-ahead log position give near-replica latency with no violations, as long as clients pass their tokens.
  - Violations appear exactly when tokens are dropped.
  - Deeply nested groups dominate check latency, and a denormalised group index (Zanzibar's Leopard) cuts it at a write cost.

## System

- **A Go service:**
  - a schema language with namespaces, relations, and rewrites (union, intersection, exclusion, permissions inherited through a parent);
  - `Check`, `Expand`, `Read` and `Write` APIs over gRPC (Phase 2), with mTLS and an audit log of decisions (Phase 6).
- **A relationship store:** PostgreSQL with streaming replicas (Phases 3–4).
  - **Snapshot tokens are WAL positions:** `pg_current_wal_lsn()` after a write.
  - A replica may answer a check only once `pg_last_wal_replay_lsn()` has reached the token. Otherwise the check goes to the primary, or waits.
- **A check engine:** evaluates sub-problems concurrently, detects cycles, limits depth, and caches results with snapshot-aware keys.
- **A group index:** nested group membership, flattened and maintained on writes.
- **A new-enemy checker:** a test harness that interleaves permission changes and content writes from several clients. It flags any check that allowed access the client had already revoked, in causal order.

## Suggested stack

| Part | Choice | Why |
|---|---|---|
| Service, check engine | Go | Concurrent graph evaluation and gRPC, as in Runway |
| Store | PostgreSQL, primary plus replicas | Real replication lag, and WAL positions as tokens |
| Cache | In-process first; Redis only if several replicas must share it | Fewer moving parts |
| Load | [wrk2](https://github.com/giltene/wrk2) over an HTTP gateway, [ghz](https://ghz.sh/) for gRPC | Fixed-rate load for unary requests |
| Security | Phase 6's mTLS, audit log, fuzzing | A permission service is a high-value target |

## Features to implement

1. The schema language and its parser, fuzzed (Phase 6).
2. `Check` with union, intersection, exclusion and inheritance through parents.
3. Snapshot tokens returned by writes and accepted by checks.
4. Three consistency modes per request: full, at-least-as-fresh, bounded staleness.
5. The nested-group index, kept correct under concurrent writes.
6. A decision log: who asked, about what, under which snapshot, with what answer.
7. The new-enemy checker, run in CI.

## Experiment

| Variable | Values |
|---|---|
| Consistency mode | Full; snapshot token; bounded staleness (100 ms, 1 s, 10 s) |
| Graph shape | Group nesting depth 1–10; group sizes Zipf-distributed; folder depth 1–20 |
| Size | 10⁵, 10⁶, 10⁷ relationships |
| Replication lag | Natural; and injected 10 ms–5 s |
| Group index | Off; on |
| Failures | Replica killed; primary failover; a client that drops tokens |

## Measures

- Check latency p50 and p99, by graph depth.
- Checks per second per core.
- Cache hit rate.
- **New-enemy violations** (the number that decides correctness).
- Write latency, and the index's maintenance cost.
- Share of checks sent to the primary.

## Benchmark your work

- **Throughput versus latency:** wrk2 and ghz at fixed rates, stepped up until check p99 breaks a 10 ms objective, per mode.
- **Tails during failures:** p99 and errors in short windows around a replica kill and a primary failover; violations during the failover.
- **Bottlenecks:** profile the check engine (`pprof`) at the knee, and name whether CPU, the database or the cache limits throughput.
- **Rigour:** at least 5 runs per condition, intervals, the graph generator's seed and parameters, and PostgreSQL's settings recorded.

## What you might find

Tokens may cost almost nothing when replicas keep up, and push most checks to the primary when they lag. Deep nesting may matter more than graph size. Bounded staleness may look harmless in averages while still producing violations a security review would reject.

## Limitations to expect

- Synthetic graphs, not a real product's sharing patterns.
- One region; Zanzibar's global replication is out of scope.
- A violation checker can only find violations in the interleavings it tries.

## Skills used

Phases 2 (gRPC), 3 (PostgreSQL, caching), 4 (replication, consistency models), 6 (authorization, threat modelling, mTLS, audit, fuzzing) and 7 (experimental method).

## Read first

- Pang et al., *Zanzibar: Google's Consistent, Global Authorization System*, USENIX ATC 2019
- Corbett et al., *Spanner: Google's Globally-Distributed Database*, OSDI 2012 (the consistency Zanzibar relies on)
- Kleppmann, *Designing Data-Intensive Applications*, chapters 5 and 9 (replication, consistency)
- The OWASP API Security Top 10, *Broken Object Level Authorization*
