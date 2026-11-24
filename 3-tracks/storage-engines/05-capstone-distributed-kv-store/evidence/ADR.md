# One replicated history and rebuildable local indexes

## Decision

The Go Raft group owns mutation order and durable recovery. Each peer uses a bounded child protocol to apply committed operations to a local Rust LSM engine. A peer rebuilds a fresh projection from the ciphertext values in an installed or restored Raft snapshot, then applies the committed suffix in order. It can recompute the projection from an uncompacted committed log too. A client sees success only after quorum commit and local application. Reads go through the committed log, which keeps the same freshness contract across failover.

The authenticated tenant is part of every physical key. Rust seals writes before the Go proposal so both persistence layers see ciphertext. The transport above the peer boundary is a loopback lab API with temporary bearer tokens. Keys, operation type, sizes, and access patterns remain visible. The keyring is supplied outside both persistence directories.

A mutation receipt is keyed by tenant, key, and client ID. A client uses one outstanding mutation per key and reuses its sequence and operation when retrying. The latest matching receipt returns the original success. The first accepted payload wins for that identifier. Older sequences and reuse for a different operation are refused. The snapshot carries both encrypted state and these receipts.

## Consequences

The projection is replaceable, and its storage sequence is independent of the Raft index. Rebuilding costs local writes and delays readiness. The Raft snapshot also retains a value image, so the capstone targets bounded workloads. Each restart builds a fresh view. Abruptly stopped processes can leave an old view in the lab directory until it is removed.

The reference compares a singleton range and an indexed point lookup under the same replicated read contract. The isolated CPU stacks locate lookup work. The YCSB matrix also pays for HTTP, replica exchange, Raft persistence, and local application, so the observed system effect can be smaller or vary by workload.
