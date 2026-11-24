# Event streams · Exercises

## Rebuild inventory for a warehouse

Build a new application that records stock receipts and withdrawals in PostgreSQL and streams them to a Kafka topic. Accept a stable movement ID, a SKU, and a signed nonzero quantity. Use the SKU as the partition key to group movements for that item. Keep a balance per SKU in a projector.

### Acceptance

- Record +10 and −3 for one SKU and +4 for a second. The committed source history and the live projector agree on balances of 7 and 4.
- Reject a reuse of a movement ID with a different SKU or quantity. Leave the original movement and its publication intent intact.
- Kill the relay after the broker accepts the withdrawal and before the sent marker commits. Capture the two Kafka positions for the withdrawal and show that its quantity is applied once.
- Kill a projector after its database commit and before its offset commit. Capture the offset seen again by the same group.
- Build a fresh projection as a new group, replay the retained records, and compare its balances with the live projection. Record the number of raw records read and the number of distinct movements applied.

## Deliberately fail the projector transaction

Use the [manual gate setup](gate/README.md#inspect-a-stream-manually). Add a PostgreSQL check constraint that rejects a known count update. Run the projector and show its failure leaves both the inbox and count unchanged. Remove the constraint and restart the same group. Capture the position it retries and the resulting count.
