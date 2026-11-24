# Postgres in depth · Exercises

## Run a reservation maintenance queue

Build a lab that processes expired room reservations. Keep a small claim transaction, an expiry time, a monotonically increasing attempt token, and a durable effect. Use a separate data set with most reservations already completed.

### Acceptance

- Create a cross-row constraint such as at least one usable room in a group. Reproduce a schedule that violates it under snapshot isolation and show a fresh Serializable retry preserves it.
- Capture a real plan before and after indexing a due-work query. Verify it returns the same ordered IDs and record buffer accesses and heap fetches.
- Hold worker A's claim open and show that worker B claims another ready item. Build a variant without skip-locked behavior and capture the deadline outcome.
- Let A's lease expire, reclaim it, and try completion with both tokens. Verify one effect for the accepted attempt.

## Reconcile two restore targets

Separate a logical snapshot from a named WAL recovery target. Add a committed mark between them and another after the target. Restore both into fresh lab database state and check which marks are present. Retain one external inventory of committed IDs for the drill and compare it with each restored set. Record the recovery point, restore time, and any work that would need reconciliation before reopening writes.

## Additional practice

[ledger, a money-transfer service](exercise-ledger.md)
