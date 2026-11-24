# 04 Integrity and encryption

> Storage engines track · Time 2 weeks at 12–15 hours a week · Status ready

## What you'll build

Give the Rust storage engine tenant-scoped keys and encrypt values before they reach the WAL. Build a separate audit feed that copies Switchyard job events into Rust `klog`, then add Merkle checkpoints that a witness can carry forward across restarts.

Start with the storage engine, the jobs event stream, and the tenant context from the shared authorization unit. [A Rust storage engine](../03-rust-storage-engine/README.md) · [Event streams](../../shared-units/event-streams/README.md) · [Tenancy and abuse control](../../shared-units/tenancy-and-abuse-control/README.md)

Use the [setup card](lessons/00-before-you-start.md) to assemble the learner workspace.

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [Keep storage operations inside a tenant namespace](lessons/01-scope-keys-to-a-tenant.md) | Scope reads, writes, scans, and snapshot handles to one tenant. |
| 1 | 02 | [Encrypt values before the WAL](lessons/02-encrypt-before-writing-the-wal.md) | Authenticate each envelope under its tenant key and verify old and new values through key rotation and reopen. |
| 1 | 03 | [Append job events before committing offsets](lessons/03-append-events-before-offset-commit.md) | Send allowlisted metadata to Rust `klog` and wait for durable acknowledgment before committing Kafka progress. |
| 2 | 04 | [Check a record against a signed Merkle root](lessons/04-check-a-signed-merkle-root.md) | Compare roots in Rust and Go and verify record inclusion under a signed checkpoint. |
| 2 | 05 | [Carry the last checkpoint forward with a witness](lessons/05-keep-an-independent-witness-head.md) | Persist a trusted head, then check consistency before advancing it after restart. |
| 2 | 06 | [Run the tenant, encryption, and audit gate](lessons/06-run-the-integrity-gate.md) | Verify the storage and audit properties against live fixtures and negative controls. |

Lesson 03 rebases Phase 3 step 10 onto the shared event-stream unit and the current `klog`. Lessons 04–05 adapt Phase 6 step 10’s Rust and Go trees, signed checkpoints, and witness. The storage namespace and encryption lessons are new. [Phase 3 audit feed](lessons/03-append-events-before-offset-commit.md) · [Phase 6 witnessed log](lessons/04-check-a-signed-merkle-root.md)

## The gate

- Give two tenants the same user keys and different values. Check point reads, writes, deletes, scans, and pinned snapshots for both tenants before and after reopen. Require a scan with a deliberately weakened tenant bound to fail the isolation assertion.
- Write distinct plaintext canaries and inspect the WAL and SSTables for those values. Verify decryption after rotation and reopen. Require the read path to refuse a changed ciphertext, a ciphertext presented under another tenant or key, and a value whose key ID is unavailable.
- Interrupt the event feed before durable append and after durable append but before offset commit. Compare consumed event IDs with the durable log after restart and account for duplicates. Check that Rust and Go agree on the root and that a valid inclusion proof verifies against the signed checkpoint.
- Restart the witness and advance it with a valid extension. Use fixed local fixtures to verify that the witness refuses a rewritten prefix, a conflicting same-size checkpoint, and rollback to an earlier signed head.

The namespace depends on the caller supplying verified tenant context. Encryption covers values and leaves keys, ordering metadata, and lengths visible. The witness protects history through its last accepted checkpoint. The audit feed keeps event metadata and exposes repeated delivery through event IDs. [Run the gate](gate/README.md)

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Trace a tenant write from the storage handle to a ciphertext record and identify the bytes that remain visible. |
| Intermediate | Explain the offset commit boundary, predict replay after each interruption, and verify a record against a signed checkpoint. |
| Senior | Defend the range bounds, key rotation behavior, and the witness’s assumptions about trusted state and checkpoint freshness. |

## Practice

- Trace old decryption keys, repeated events, and trusted receipts through restart. [Exercises](exercises.md)
- Predict what each boundary preserves before running the fixtures. [Self-check](self-check.md)
- Inspect the isolation, Kafka, and proof results. [Evidence](evidence/README.md)

Continue to [Capstone: a distributed KV store](../05-capstone-distributed-kv-store/README.md).
