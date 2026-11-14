# 12. One bad replica: what an authenticated insider can do to a replicated store

**Field:** security · distributed systems · **Difficulty:** high · **Language:** Go

## Problem

Phase 4's Raft assumes nodes crash but never lie. Phase 6 gave every service a cryptographic identity and mutual TLS, so an outsider can no longer pretend to be a replica. But identity only says *who* sent a message, not whether that sender is honest. A replica whose host is compromised still holds a valid certificate. It can:

- replay old messages from an earlier term;
- send different log entries to different followers (equivocation);
- vote in ways that keep the cluster leaderless;
- lead slowly enough to hurt everyone without ever looking dead;
- report entries as committed that a quorum never accepted.

Byzantine fault-tolerant protocols tolerate this, but they need 3f + 1 replicas instead of 2f + 1, and more messages per decision. Most production systems therefore run crash-tolerant consensus and accept the insider risk without measuring it.

## Who

Teams running replicated stores across trust boundaries (several organisations, edge sites, untrusted hosts); security engineers who must state what a single compromised node can do; and anyone deciding whether mTLS between replicas is "enough".

## Gap

- PBFT (Castro and Liskov, OSDI 1999) made Byzantine agreement practical; HotStuff (Yin et al., PODC 2019) made its message pattern linear.
- Aardvark (Clement et al., NSDI 2009) showed that a single faulty node can cripple the *performance* of BFT systems that are correct on paper.
- Between "crash-tolerant Raft over mTLS" and "a full BFT protocol" sits a range of cheaper defences: signed log entries, replay windows bound to terms, commit certificates clients can verify, and leader rotation on slowness. Which attacks each one closes, and at what cost, is rarely measured on the same system.

## Research question

> In a Raft-based key-value store whose replicas authenticate with mTLS, which attacks by one compromised but authenticated replica succeed, which of them do cheap defences (signed entries, term-bound replay protection, verifiable commit certificates, slowness-triggered leader change) prevent or detect, and what do those defences cost in latency and throughput compared with a minimal Byzantine fault-tolerant protocol on 4 replicas?

## Hypothesis and baseline

- **Baselines:**
  - Phase 4's Raft over Phase 6's mTLS, for performance and for the attacks that succeed;
  - a minimal BFT protocol (PBFT or HotStuff) on 4 replicas, for what full tolerance costs.
- **Hypothesis:**
  - mTLS alone stops every outsider attack and none of the insider ones.
  - Signed entries and verifiable commit certificates *detect* forgery and false commit claims cheaply, but don't keep the cluster available.
  - Equivocation and liveness attacks need a BFT protocol; it costs about one extra round trip per decision and a fourth replica, and its tail latency suffers most under a slow-but-correct-looking leader.

## System

- **The store:** your Phase 4 Raft key-value store, with Phase 6's mTLS between replicas and the Rust audit log (Phase 3) for decisions.
- **A malicious-replica harness:** one replica's code can be switched into an attack mode: replay, forged entries, equivocation, vote withholding, slow leadership, false commit reports. Every attack is driven by tests, as in Phase 4's simulation.
- **Defences, each switchable:**
  - per-node signing keys on log entries and votes;
  - nonces bound to the term, rejecting replays;
  - commit certificates: a quorum's signatures that a client can check itself;
  - leader change when progress falls below a threshold.
- **A minimal BFT comparison:** PBFT's normal case and view change, or HotStuff's chained form, on 4 replicas.
- **Checkers:** Phase 4's linearizability checker for safety, and progress measurements for liveness.

## Suggested stack

| Part | Choice | Why |
|---|---|---|
| Store, protocols, harness | Go | Phase 4's Raft and simulation |
| Identity | Phase 6's CA and SPIFFE identities | Replicas already have them |
| Signatures | Ed25519 (Go's standard library) | Fast and small; Phase 6's tokens use it |
| Network faults | Phase 5's netem and the Networking Bridge | Real delay and loss under attack |
| Safety checking | Phase 4's linearizability checker; TLA+ for the defence logic | Prove what the tests can only sample |

## Features to implement

1. The six attack modes, each with a test that shows it succeeding against plain Raft over mTLS.
2. Each defence, with a test that shows which attacks it now stops, detects or still allows.
3. Client-side verification of commit certificates.
4. The minimal BFT protocol, passing the same linearizability checks.
5. A results table per attack and defence: prevented, detected, or succeeded.

## Experiment

| Variable | Values |
|---|---|
| Protocol | Raft over mTLS; plus each defence; plus all defences; BFT on 4 replicas |
| Attack | None; replay; forged entry; equivocation; vote withholding; slow leader; false commit |
| Cluster size | 3 and 5 (Raft); 4 (BFT) |
| Network | Natural; 10–100 ms injected delay; 1% loss |
| Load | Fixed request rates up to saturation |

## Measures

- **Safety violations** found by the linearizability checker (the number that decides correctness).
- **Detection:** whether and how quickly an attack is noticed, and by whom.
- Latency p50 and p99, and throughput at a fixed latency objective.
- Time without progress under liveness attacks.
- Bytes and messages per committed request.

## Benchmark your work

- **Throughput versus latency** per protocol and defence, stepped up to the knee (Phase 7).
- **Tails under attack:** p99 in short windows while each attack runs.
- **Rigour:** at least 5 runs per condition, intervals, and the seeds of every simulated schedule recorded.

## What you might find

Signing may cost less than expected, because consensus is usually waiting on the network, not the CPU. The slow leader may be the most damaging attack and the hardest to detect, as Aardvark found. The honest conclusion may be a table: which insider attacks a team accepts with crash-tolerant consensus, and which ones justify a fourth replica.

## Limitations to expect

- One compromised replica, not collusion between several.
- A minimal BFT implementation, not an optimised production one; compare shapes, not absolute speed.
- Simulation and one host cannot reproduce every real network's timing.

## Skills used

Phases 3 (audit log), 4 (Raft, simulation testing, linearizability, TLA+), 5 (network faults), 6 (CA, mTLS, identities, threat modelling), 7 (experimental method) and 9 (attack method, reports).

## Read first

- Lamport, Shostak and Pease, *The Byzantine Generals Problem*, ACM TOPLAS 1982
- Castro and Liskov, *Practical Byzantine Fault Tolerance*, OSDI 1999
- Ongaro and Ousterhout, *In Search of an Understandable Consensus Algorithm*, USENIX ATC 2014
- Clement et al., *Making Byzantine Fault Tolerant Systems Tolerate Byzantine Faults*, NSDI 2009
- Yin et al., *HotStuff: BFT Consensus with Linearity and Responsiveness*, PODC 2019
