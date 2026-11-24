# Integrity and encryption · Exercises

Work in a separate learner workspace with temporary keys and logs.

## Keep key rotation safe for older readers

Write one value with key 1, take a snapshot, then rotate to key 2 and overwrite the value. Flush and compact while that first snapshot stays pinned.

- Record which key IDs a latest read and a pinned read require.
- Try a keyring containing only key 2. Explain how a missing key differs from an authentication failure.
- Release the pin, compact again, and repeat the checks. Add a second, less recently written key to show why rewriting one value cannot establish that a key ID is safe to retire.

## Compare event identity with stream position

Publish the same logical job event twice with distinct Kafka offsets. Interrupt the feed after its next durable append and before committing progress.

- Record the durable event IDs and their partition positions.
- Report both the event that was redelivered at one offset and the logical event that appeared at two offsets.
- Show that the witness commitments cover each physically appended record, including replayed records.

## Reopen a witness between valid checkpoints

Create a first receipt, stop the witness, and preserve its state. Reopen it and offer a validly signed extension from the same log, then an earlier signed head.

- Verify both signatures on the accepted receipt using distinct public keys.
- Check that the earlier head is cryptographically valid for the signer and still fails the witness’s continuity check.
- Explain how an independent reader can use its last trusted receipt when the writer returns an older view.

Compare with the [gate results](evidence/README.md).
