# 1. KESTREL: replication under partial and intermittent partitions at health sites

**Field:** networking and distributed systems · health · **Difficulty:** high · **Language:** Go · **The author's own capstone, and the worked example**

## Problem

Community health organisations in low-resource regions keep records at each site and need shared summaries (supply levels, case counts, referrals) across sites. Their connectivity is unreliable, and not in the tidy way textbooks assume. A site may reach the regional hub but not its neighbour, or send messages but not receive them, or have a link that works for an hour at dawn. These are **partial** and **intermittent** network partitions. Replication protocols built for data centres tend to assume a partition is all-or-nothing.

## Who

Small clinics, community health workers and regional coordinators, and the engineers who build the systems they rely on. More broadly: anyone running replicated systems at the network edge (retail branches, field research stations, ships).

## Gap

- Consensus protocols such as Raft and Paxos keep data correct, but they can stall or lose a leader under **partial** partitions.
- Studies of production cloud systems have found that partial network partitions cause serious failures, including data loss and stale reads, and that standard designs don't handle them well (Alquraan et al., OSDI 2018; Alfatafta et al., OSDI 2020).
- **Local-first** designs (Kleppmann et al., Onward! 2019) and **CRDTs** (Shapiro et al., 2011) keep every site writable offline. But they give up strong consistency, and their behaviour under *asymmetric*, *intermittent* links in low-bandwidth settings is rarely measured.
- Nobody has measured how these choices trade freshness, availability, bandwidth and correctness **under realistic, partial, intermittent connectivity at under-resourced sites**.

## Research question

> Under partial and intermittent network partitions typical of under-resourced sites, how do consensus-based, CRDT-based and hybrid replication strategies compare in summary freshness, write availability, bandwidth use and correctness? Can a partition-aware hybrid outperform both?

## Hypothesis and baseline

- **Baselines:**
  - (a) a centralised hub, where sites send everything to one server;
  - (b) Raft across sites;
  - (c) CRDT-based local-first replication.
- **Hypothesis:** a hybrid will beat Raft on availability and CRDTs on correctness. The hybrid uses consensus only for small, critical metadata, CRDTs for counters and summaries, and routes around asymmetric links through reachable peers. Its bandwidth will be competitive on links under 1 Mbit/s.

## System

- **Site nodes** built from Runway: Go APIs, a PostgreSQL repository and an outbox.
- **A replication layer** with pluggable strategies: Phase 4's Raft, a CRDT implementation (counters and maps), and the hybrid.
- **A partition emulator** (Phase 5's network namespaces and `tc netem`, extended) that replays connectivity traces: full, asymmetric (A→B works, B→A doesn't), partial (A↔B and B↔C work, A↔C doesn't) and intermittent (scheduled up/down windows).
- **Linearizability and convergence checkers** (Porcupine from Phase 4, plus your own convergence checker for CRDTs), and a TLA+ model of the hybrid's safety property.

## Experiment

| Variable | Values |
|---|---|
| Strategy | Hub, Raft, CRDT, hybrid |
| Topology | 3, 5, 9 sites |
| Connectivity trace | Full; asymmetric; partial; intermittent (based on published mobile and rural connectivity patterns, or synthetic with documented parameters) |
| Link quality | 50 kbit/s to 10 Mbit/s, 50–800 ms latency, 0–10% loss |
| Workload | Synthetic visits and supply updates; summary queries |

## Measures

- Summary **staleness**: the age of the newest update included.
- **Write availability**: the fraction of writes accepted.
- **Bandwidth** per site.
- **Correctness**: linearizability violations for consensus data; convergence time for CRDTs.
- Time to recover after reconnection.

## Suggested stack

| Part | Choice | Why |
|---|---|---|
| Site nodes, replication layer, hybrid router | Go | Runway's code, Phase 4's Raft and the CRDTs share one language and one test harness |
| Storage | PostgreSQL per site, with the outbox (Phase 3) | Each site keeps authority over its own records |
| Partition emulator | Linux network namespaces, `tc netem`, `iptables` (Phase 5), driven by a Go or Python trace player | Asymmetric and partial partitions need per-direction, per-pair rules |
| Checkers | Porcupine (Phase 4), your own convergence checker, TLA+ | Correctness has to be checked, not eyeballed |
| Load and analysis | `kload` (Python Bridge) and Phase 7's `lab` | Open-loop load, and intervals on every comparison |

## Features to implement

1. Site nodes with a summary API: write visits and supply updates, read cross-site summaries with their staleness.
2. Pluggable replication: hub, Raft, CRDT (counters, last-writer-wins and observed-remove maps), hybrid.
3. The hybrid's router: forwards through reachable peers when the direct link is down or one-way.
4. A trace player that applies connectivity traces per site pair and per direction, on a schedule.
5. Staleness reported with every answer: "this summary includes updates up to t from sites A and B; C is unreachable".
6. Recovery: anti-entropy after reconnection, with bandwidth caps.
7. Site identity and minimal disclosure: mTLS between sites (Phase 6), and only summaries leave a site.

## Benchmark your work

- **Throughput versus staleness:** raise the write rate at each link quality until summaries fall behind, and report the knee for every strategy.
- **Tail latency during failures:** write and summary-read p99 in 10-second windows before, during and after each partition starts and heals. Record Raft leader changes on the same timeline.
- **Bandwidth:** bytes per site per hour, split into payload, metadata and anti-entropy.
- **Rigour:** at least 5 runs per condition, interleaved; bootstrap intervals; the traces, seeds and kernel version saved with the results.

## What you might find

You might find that Raft's leader churns under partial partitions while CRDTs stay available but show stale or conflicting summaries. A hybrid might help most for asymmetric links, and least for long, full outages.

## Limitations to expect

- Emulated networks aren't real rural links.
- Synthetic health workloads may miss real usage patterns.
- Real deployment would need domain partners, consent and ethics approval.

## Skills used

Phases 2 (messaging), 3 (outbox), 4 (Raft, Porcupine, TLA+), 5 (network emulation), 6 (site identity, minimal disclosure) and 7 (experimental method).

## Read first

- Alquraan et al., *An Analysis of Network-Partitioning Failures in Cloud Systems*, OSDI 2018
- Alfatafta et al., *Toward a Generic Fault Tolerance Technique for Partial Network Partitioning*, OSDI 2020
- Kleppmann et al., *Local-First Software*, Onward! 2019
- Shapiro et al., *Conflict-free Replicated Data Types*, SSS 2011
- Ongaro and Ousterhout, *In Search of an Understandable Consensus Algorithm (Extended Version)*
