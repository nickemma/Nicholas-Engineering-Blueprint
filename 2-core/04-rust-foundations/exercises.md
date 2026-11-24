# Exercise · A durable playlist queue

Build a separate Rust CLI called `playlist`. It keeps a queue by replaying an append-only file of playlist operations. Define your own record encoding and document the maximum record size, checksums, and recovery behavior.

## What the finished tool does

| Command | Behavior |
|---|---|
| `playlist add FILE TRACK` | Appends an operation that adds the quoted track name to the end of the queue. |
| `playlist skip FILE` | Appends an operation that removes the oldest pending track. Refuses an empty queue. |
| `playlist list FILE` | Replays operations in order and prints the remaining tracks, one per line. |
| `playlist check FILE` | Verifies the log, reports an incomplete final frame that it repaired, and refuses a complete corrupt frame. |

A successful add or skip is durable after the sync returns. Handle an empty track, an oversized record, an unknown operation, and I/O errors explicitly. A failed append must produce a nonzero exit code.

## Acceptance checks

1. Add three distinct tracks in three separate processes. Skip once. Confirm that a fresh process lists the last two tracks in order.
2. Feed the open routine a file with a torn final add and compare against the verified prefix. Confirm a subsequent add succeeds.
3. Alter a complete frame's payload and then its header in separate copies. Check that recovery refuses both files and leaves their raw bytes unchanged.
4. Test that an invalid or oversized input leaves the previously acknowledged operations intact. Include an error test for skipping an empty queue.
5. Run Rustfmt, Clippy with warnings denied, and the tests. Document which failure cases your evidence exercises.

## Additional practice

[bitlog, a log-structured key-value store](exercise-bitlog.md)
