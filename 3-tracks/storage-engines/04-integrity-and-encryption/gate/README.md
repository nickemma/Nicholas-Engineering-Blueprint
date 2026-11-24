# Tenant, encryption, and audit gate

Run from the learner workspace. The gate checks storage fixtures, builds the Rust audit writer, runs Go proof and feed checks, and builds a disposable source variant to verify that tenant-bound regressions are caught.

For the complete gate, supply a reachable disposable Kafka broker. The test creates a topic and consumer groups and requests cleanup when finished.

~~~bash
export INTEGRITY_KAFKA_BROKERS=127.0.0.1:9092
bash "$BLUEPRINT_ROOT/3-tracks/storage-engines/04-integrity-and-encryption/gate/run.sh" "$PWD"
~~~

CI supplies `RUNWAY_KAFKA_BROKERS`. Without either broker variable, the storage, Rust-child protocol, Merkle, and witness checks run and the live Kafka check is skipped.

| Check | Required result |
|---|---|
| Tenant scope | Identical keys, binary bounds, deletes, and pinned reads remain scoped before and after reopen. Removing the scan’s tenant upper bound triggers the isolation assertion. |
| Encryption | Storage files contain ciphertext for both canaries. A pinned revision remains readable during rotation. Modified ciphertext, moved ciphertext, and an unavailable key ID produce errors. |
| Durable feed | The child acknowledges only after append. The broker offset stays uncommitted at both interruption boundaries. Restart consumes both event IDs, with one repeated delivery if the first append had already synced. |
| Signed inclusion | Rust and Go agree on roots for the same bytes. The signer’s checkpoint verifies under the configured log identity. Inclusion succeeds for each matching record. |
| Witness continuity | Reopening carries the trusted head forward. Signed rollback, a same-size conflict, and a larger tree with a changed prefix are all refused. |

Use disposable fixture keys. A new witness trusts the configured signer on bootstrap. Its state and signing key belong outside the writer’s trust boundary. Use the [reference evidence](../evidence/README.md) to compare outcomes.
