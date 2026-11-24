# 04 Rust foundations

> The core · Time: 4 weeks at 12–15 hours a week · Builds on: [03 Docker and Postgres](../03-docker-and-postgres/README.md) · Status: ready

## What you'll learn

Write Rust from the first bindings and functions through ownership, borrowing, explicit lifetimes, enums, typed errors, traits, generics, iterators, collections, and owning pointers. Use Cargo, tests, Rustfmt, and Clippy from the first lesson. Read real compiler diagnostics before fixing the underlying code.

## What you'll build

**`klog`**, Switchyard's first Rust data-plane component. It appends checksummed records to a file, reads them in order, removes an incomplete final frame, and refuses complete corruption. It uses a little-endian length and separate CRC-32C checks for the header and payload. The CLI and tests run on Linux with Rust 1.89 or newer. Start a new Cargo package for the drills and keep using it when you build the log.

## Lessons

| # | Lesson | What you'll build and check | Time |
|---|---|---|---|
| 01 | [A first Rust program](lessons/01-a-first-rust-program.md) | A Cargo executable with typed bindings, a loop, `Option`, exhaustive matching, and tests. | ~5 h |
| 02 | [Ownership, moves, and borrows](lessons/02-ownership-moves-and-borrows.md) | Borrow and mutate text, transfer ownership, and read the diagnostics for a move and an overlapping borrow. | ~6 h |
| 03 | [Enums, patterns, and errors](lessons/03-enums-patterns-and-errors.md) | A duration parser with typed errors, checked arithmetic, `Display`, and `?`. | ~5 h |
| 04 | [Traits, generics, and collections](lessons/04-traits-generics-and-collections.md) | One summary for multiple input types, with iterator chains and deterministic buckets. | ~6 h |
| 05 | [Lifetimes and shared ownership](lessons/05-lifetimes-and-shared-ownership.md) | A returned borrow, a rejected dangling reference, a recursive `Box` list, and shared `Rc` labels. | ~5 h |
| 06 | [Bytes, framing, and checksums](lessons/06-bytes-framing-and-checksums.md) | A bounded frame, CRC-32C, and a decoder that borrows the payload. | ~6 h |
| 07 | [Append a record and sync it](lessons/07-append-a-record-and-sync-it.md) | A streaming scanner and a locked CLI writer that synchronizes before acknowledgment. | ~5 h |
| 08 | [Recover a torn tail and refuse corruption](lessons/08-recover-a-torn-tail-and-refuse-corruption.md) | Truncate an incomplete tail and preserve the bytes of complete corrupt records. | ~7 h |
| 09 | [Measure syncs and prove recovery](lessons/09-measure-syncs-and-prove-recovery.md) | A matched sync benchmark and a gate that tests byte cuts, corruption, contention, and a killed writer. | ~5 h |

## The gate

The [automated gate](gate/README.md) checks every incomplete cut of a reference frame. It compares the surviving prefix byte-for-byte, corrupts complete records at several offsets, and checks that each CLI entry point refuses the damage and preserves the file. It also holds the file lock against another writer and kills a process after it has written a known partial frame. The Rust tests, formatting, and Clippy run before the CLI checks.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Build a tested Rust package, read ownership diagnostics, and handle a typed error. |
| Intermediate | Explain lifetime bounds, decode a borrowed payload, and enforce file-format limits before allocating. |
| Senior | Explain the acknowledgment and recovery boundaries, distinguish process-crash evidence from power-loss evidence, and measure the cost of changing the sync policy. |

## Practice

- **[Exercise](exercises.md).** Build a separate durable playlist CLI with the same care for atomic operations and recovery.
- **[Self-check](self-check.md).** Explain each lesson and rebuild the core ideas from memory.

## Next

[05 Rust for systems](../05-rust-for-systems/README.md) works with layouts, concurrency, and zero-copy parsing on Switchyard's data path.

[Captured compiler, CLI, gate, and benchmark runs](evidence/README.md) show what the module observed.
