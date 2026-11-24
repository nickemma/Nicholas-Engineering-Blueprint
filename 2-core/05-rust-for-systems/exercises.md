# Exercise · Bounded telemetry relay

Build a separate Rust program that reads framed telemetry bytes and relays valid payloads to one consumer thread. Use one producer, one consumer, and a ring with a configured capacity. The CLI reads from a file or standard input and prints the number and byte total of accepted frames.

Define the record format in the project's README. Set a maximum length and checksum policy. The decoder should return a borrowed view of a complete frame. Make the ownership transfer into the worker explicit when the backing input buffer will be reused.

## Acceptance checks

1. Decode the same fixture in every split between two reads. Report the same records in the same order.
2. Reject a bad checksum and an incomplete final frame. Both exit nonzero with a message naming the failure.
3. Run with capacity one. Verify slow consumption exercises backpressure and no accepted frame is lost or reordered.
4. Use a drop-counting owned payload to prove that a rejected send leaves ownership with the caller and unread values are released once.
5. Model the critical hand-off under Loom, then weaken one ordering in a scratch copy and show which check detects it.
6. Capture Rustfmt, Clippy, tests, and a bounded fuzz or Miri run. Document what each run exercised.
