# Phase 4: replicate approved state through failure

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: a type-along guide with the code inline, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This page previews the concepts, tools, readings, and exit evidence. Follow the full [self-study teaching guide](TEACHING.md) and record your work in [learned.md](learned.md).

The ordered reading list is embedded at the end of [TEACHING.md](TEACHING.md), beside the implementation stages it supports.

## Question and build

What guarantees can a cluster preserve when machines fail, messages are delayed, clocks disagree, or the network partitions?

Trace HashiCorp Raft's library interfaces, then implement and test the Raft core for a three-node key/value state-machine workload using the MIT 6.5840 lab skeleton and simulator. Use local etcd as a single-node reference for its API and persistence, not as a replication exercise. Keep the values synthetic metadata, never source records. The Rust log from Phase 3 is a separate storage experiment and is not wired into this consensus lab.

## Teach in this order

1. **State the model.** Define crash versus Byzantine failures, synchronous/asynchronous assumptions, and what the system can observe.
2. **Reason about time and detection.** Explore timeouts, failure detectors, physical/logical clocks, and why a timeout is suspicion rather than proof.
3. **Trace a maintained implementation.** Follow a write through HashiCorp Raft's `Apply`, FSM, log/store, and transport interfaces; this is a source/API walkthrough.
4. **Implement Raft incrementally.** Complete the official MIT 6.5840 Lab 3 stages 3A (election), 3B (log replication), 3C (persistence and safety), and 3D (snapshots). Keep its supplied skeleton and tests in the separate course checkout. Explain each invariant before adding code.
5. **Compare protocols.** Read VR/Paxos after Raft works; identify assumptions and failure behavior rather than memorizing names.
6. **Inject faults.** Kill nodes, delay/drop links, create partitions, and check linearizable histories with Porcupine. Separate safety from liveness.
7. **Model one property.** Write a small TLA+ model and check a safety property with TLC. Relate the model state to implementation state.
8. **Write the failure report.** Preserve a bug trace, model, seed, configuration, and limits.

## Foundations closed

Distributed failure models, clocks, leader election, quorums, replication, consistency, partitions, CAP/FLP limits, and Linux network fault injection. The lab does not teach a general distributed-transaction protocol.

## Reading placement

Follow the ordered reading table in [TEACHING.md](TEACHING.md): failure model and clocks first; Raft while implementing; consistency before history checking; VR/Paxos after a working Raft; then GFS, Spanner, FLP, CAP, and Dynamo when comparing alternatives.

## Exit evidence and career signal

Show the passing supplied 3A–3D suite, one node-stop and partition trace, and one bug found by the tests. If you build the optional key/value adapter, add a randomized linearizability history. Tie the TLA+ model to an implementation property.

This is the core Distributed Systems Engineer signal and a substantial research sample, not proof that every distributed protocol is mastered.
