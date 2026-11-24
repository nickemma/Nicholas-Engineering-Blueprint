# Integrity and encryption · Evidence

The reference used Rust 1.94.1, Go 1.26.6, and a disposable local Apache Kafka 4.1.0 broker. The gate used temporary directories and fixture keys.

| Check | Observation |
|---|---|
| Tenant scope | Point reads, deletes, binary range bounds, and pinned reads stayed scoped through reopen. The deliberately weakened upper bound exposed a second namespace in the control. |
| Encryption | Neither plaintext canary appeared in the inspected WAL or SSTables. Rotation preserved historical reads, and reopen preserved the latest values. Modified and relocated envelopes failed authentication and an unavailable key ID failed the read. |
| Before audit append | No offset was committed at interruption. After restart the durable log held `[event-1 event-2]` and the group’s next offset was 2. |
| After durable append, before commit | The first append was already on disk when the feed stopped. After restart the log held `[event-1 event-1 event-2]` and the group’s next offset was 2. |
| Inclusion | Rust and Go agreed on roots at sizes 0, 1, 2, 3, 5, and 7. All seven record proofs verified against the signed checkpoint. |
| Witness | Reopening advanced the trusted head from size 3 to 5. The witness rejected signed rollback, a same-size conflict, and a larger tree with a changed prefix. |

The storage fixture protects value contents. Keys, order, and lengths remain visible. The witness preserves continuity from its trusted state. The Kafka fixture exercises one partition with two producer events.

- [Gate transcript](gate.txt)
- [Clean lesson replay](replay.txt)
