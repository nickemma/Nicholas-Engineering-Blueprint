# Track: Storage engines

> About 26 weeks: 15 of its own, plus 11 in shared units · Builds on: the end of the core · Status: ready

## Who it's for

You want to build the systems that keep data: databases, key-value stores, logs, and the consensus that replicates them.

## Roles it targets

Storage Engineer; Database Engineer; Data Infrastructure Engineer; Distributed Systems Engineer; Systems Software Engineer. See [career.md](../../career.md).

## Shared units it needs

Skip any you've already done on another track. [AWS and Terraform](../shared-units/aws-and-terraform/README.md) is optional here.

- [Kubernetes and delivery](../shared-units/kubernetes-and-delivery/README.md) (5 weeks)
- [Event streams](../shared-units/event-streams/README.md) (2 weeks)
- [Caching](../shared-units/caching/README.md) (1 week)
- [Tenancy and abuse control](../shared-units/tenancy-and-abuse-control/README.md) (3 weeks)

## Parts

| Part | What you learn and build |
|---|---|
| [01 Postgres in depth](01-postgres-in-depth/README.md) | Isolation anomalies, `EXPLAIN ANALYZE`, WAL, B-tree vs LSM, background jobs, backup and restore |
| [02 Consensus in depth](02-consensus-in-depth/README.md) | Snapshots, linearizability checking, TLA+, sharding and rebalancing, 2PC vs sagas |
| [03 A Rust storage engine](03-rust-storage-engine/README.md) | LSM-tree, SSTables, Bloom filters, compaction, MVCC |
| [04 Integrity and encryption](04-integrity-and-encryption/README.md) | A tamper-evident log, encryption at rest, tenant namespaces |
| [05 Capstone: a distributed KV store](05-capstone-distributed-kv-store/README.md) | Benchmarked with YCSB, with crash-recovery proofs |

**Optional deep dives:** event sourcing; Raft vs Paxos and Viewstamped Replication.
