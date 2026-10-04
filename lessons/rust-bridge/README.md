# Rust Bridge: prepare for durable storage

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: full code in `steps/`, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This page previews the concepts, tools, readings, and exit evidence. Follow the full [self-study teaching guide](TEACHING.md) and record your work in [learned.md](learned.md). This prerequisite is before Phase 3, not a numbered phase.

The Rust, memory, and concurrency readings are embedded at the end of [TEACHING.md](TEACHING.md), beside each exercise.

## Question and build

What is a record when it is only bytes on disk, and how does Rust make ownership of those bytes explicit?

Build three small programs: a command-line tool that reads/writes a binary file, a checksummed record format, and a threaded counter.

## Teach in this order

1. Install/check the Rust toolchain and create a Cargo project. Explain source, package, compiler, and test commands by comparison with the Go work already known.
2. Introduce variables, types, functions, enums, structs, and pattern matching through the record parser.
3. Add Result and error propagation. Make invalid length, version, and checksum behavior explicit.
4. Introduce ownership and borrowing only when the parser needs to pass bytes without copying. Read one borrow-checker error and repair it by understanding who owns the buffer.
5. Use byte slices and file I/O to encode/decode a record. Explain endianness and record length.
6. Add a checksum and tests for truncation/corruption. Then introduce threads and Send/Sync using the counter.
7. Compare stack/heap and virtual address space concepts with the same small program.

## Foundations closed

Rust ownership, borrowing, lifetimes, Result, traits/generics, Send/Sync, basic memory layout, and binary files. This gives the vocabulary needed for Phase 3; it is not a general Rust specialization course.

## Reading placement

Use the Rust Book Chapters 1–10, 13, 15, and 16 alongside the matching code. Read OSTEP Chapters 13, 14, and 17 after observing the process's memory behavior; read CSAPP Chapter 9 during virtual-memory discussion. Use *Rust Atomics and Locks* Chapters 1–2 with the threaded counter.

## Exit evidence

Explain one borrow-checker error in your own words; encode, decode, and reject a corrupted record; show a race that Rust's type rules prevent.

The bridge is preparation for the Phase 3 storage experiment, not a switch away from Go for the API/control plane.
