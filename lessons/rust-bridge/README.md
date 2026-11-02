# Rust Bridge: bytes, ownership and a log that survives crashes

**Question:** what do bytes on disk, memory ownership and thread safety really look like, when a language makes you say them explicitly?

**Time:** about 3 weeks. **Prerequisites:** [Phase 2](../02-connected-services/README.md); Rust installed with rustup.

## Syllabus

| Step | Topic | You'll learn |
|---|---|---|
| 1 | A first program | Immutability by default, types, arrays and slices, `Option`, exhaustive `match`, iterators and closures, macros, tests, `cargo fmt`, `clippy` |
| 2 | Ownership and borrowing | Stack vs heap, the three ownership rules, moves, `&` and `&mut`, `String` vs `&str`, lifetimes, learning from compiler errors |
| 3 | Errors as values | `Result`, enums with data, traits (`Display`, `Error`), `derive`, `?`, overflow-safe arithmetic, `Debug` vs `Display` |
| 4 | Bytes and a record format | Length-prefixed framing, little-endian encoding, CRC-32C from scratch, known-answer tests, zero-copy decoding, untrusted lengths |
| 5 | A log file that survives crashes | The page cache and `fsync`, append-only files, torn writes, recovery, refusing real corruption, what recovery can't tell apart |
| 6 | Threads, safely | `Send` and `Sync`, `Arc` and `Mutex`, channels, a single owning writer, a deadlock the compiler can't catch |

## What you'll be able to do

- Read and write idiomatic Rust, and fix ownership and borrowing errors by reasoning, not trial and error.
- Design a binary record format, and implement and test a checksum.
- Explain exactly when a write is durable, and build recovery from torn writes.
- Use the type system to rule out data races, and recognise the concurrency bugs it doesn't rule out.

## How to work through it

1. Follow [TEACHING.md](TEACHING.md), typing every piece of code yourself.
2. Do the torn-write and corruption experiments on your own log files.
3. Answer [learned.md](learned.md).
4. Build the exercise project, **[bitlog](exercises.md)**, a Bitcask-style key-value store, on your own.
5. Take the [self-test](../../notes/learned/rust-bridge.md).

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where | Evidence |
|---|---|---|
| Memory and ownership (row 14) | Steps 1–2, 6 | The compiler errors you produced and fixed |
| Files, `fsync`, crash consistency (row 17) | Step 5 | The torn-write and corruption experiments |
| Concurrency and races (row 8) | Step 6 | A race that doesn't compile; the deadlock that does |

## Next

[Phase 3](../03-durable-auditable-data/README.md) uses `klog` as Runway's audit log, fed from Kafka, alongside PostgreSQL.
