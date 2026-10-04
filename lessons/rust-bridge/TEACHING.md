# Rust Bridge: prepare to work with bytes and durable records

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: a type-along guide with the code inline, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This self-study bridge comes after Phase 2 and before Phase 3. It is deliberately small: learn enough Rust to understand a binary record and a storage experiment. The Go service remains the API and control plane.

## The goal and prerequisites

You should be able to make a small Rust command-line program, read and write a byte file, represent errors with Result, explain who owns a buffer, and explain why a safe shared value cannot be mutated concurrently without coordination.

You need Bash and a Rust stable toolchain. Check:

~~~bash
rustc --version
cargo --version
~~~

rustc is the compiler. Cargo creates, builds, tests, and manages a Rust package. If either command is missing, install Rust using the official rustup instructions linked at the end of this guide.

Create an independent practice package:

~~~bash
cd lessons/rust-bridge
mkdir -p practice
cd practice
cargo new record-lab
cd record-lab
cargo run
~~~

The generated program should print Hello, world! Cargo created a source folder and a manifest named Cargo.toml. The manifest identifies the package and dependencies. Rust source is in src/main.rs.

## 1. Read the program before changing it

The generated file contains a main function. Rust begins a binary program at main, just as Go begins at package main's main function. A let statement binds a name to a value. A String owns changeable text; a string slice borrows text for a shorter use.

Change the program to accept one text argument and print it. Run it with an argument and with no argument. Make the no-argument behavior an explicit error instead of allowing a panic. Use std::env::args and return a Result from main. Explain why returning an error is easier to diagnose than crashing without context.

Run:

~~~bash
cargo fmt --check
cargo test
cargo clippy
~~~

These check formatting, run tests, and run Rust's linter. A passing check means the tool found no configured issue; it is not a proof that the program is correct.

## 2. Introduce the record as bytes

A byte is an integer from 0 through 255. A file does not store a Go struct or Rust struct; it stores bytes. To reconstruct a value later, writer and reader must agree on field order, width, byte order, version, and error behavior.

Use this record specification:

~~~text
magic:       4 bytes, ASCII KSTR
version:     1 byte, currently 1
sequence:    8 bytes, unsigned big-endian integer
payload_len: 4 bytes, unsigned big-endian integer
payload:     payload_len bytes, maximum 1 MiB
checksum:    4 bytes, CRC32C of version through payload
~~~

Big-endian means the most significant byte is stored first. The magic identifies the file format. The version lets a future reader recognize a changed layout. The length tells the reader how many payload bytes belong to this record. The checksum detects many accidental changes and torn writes; it is not a cryptographic signature and does not prove who wrote a record.

Add a Record struct with sequence and payload fields. Implement an encoder that creates bytes in precisely this order and a decoder that checks the magic, version, maximum length, exact record boundary, and checksum before returning a Record. Use the Rust Book's slice and integer conversion guidance alongside the work.

Add tests for: the known record round trip; empty payload; maximum payload; oversized declared length; bad magic; unknown version; truncated header; truncated payload; and one changed payload byte. For invalid input, return a descriptive error. Never allocate a vector using a length from disk until the length limit has been checked.

## 3. Learn ownership from a real compiler message

Pass the encoded byte vector to the decoder as a borrowed slice, written as &[u8]. The caller owns the vector; the decoder temporarily borrows its bytes. The borrow must not outlive the owner. This allows the decoder to inspect bytes without copying the entire file.

In a temporary branch, try returning a slice that points into a local vector which is about to be dropped. Read the compiler's lifetime error. Do not memorize its wording: draw the owner and borrower, then explain why the returned reference would point to freed memory. Repair the function by returning an owned value or by borrowing from a caller-owned input.

Rust ownership is the rule for who is responsible for a value's lifetime. Borrowing gives temporary access without transferring ownership. A lifetime is the compiler's name for the period during which a reference remains valid.

## 4. Add file I/O and explicit errors

Add a command that encodes one record and appends it to a file, then a command that reads the file and prints each decoded sequence and payload. Use std::fs::OpenOptions, Read, Write, and write_all. Every file operation can fail because a path may be absent, permissions may deny access, a disk may be full, or bytes may be truncated. Propagate those errors with Result and add enough context to identify which operation failed.

Test a missing file, an empty file, a valid file with several records, and a file with a partial final record. Expected behavior: a missing file is a clear error unless the command is explicitly creating it; an empty file has no records; valid records appear in sequence order; a partial final record is reported as incomplete rather than decoded as valid data.

## 5. Add a checksum library and learn the boundary

Add the crc32c crate for the checksum algorithm, and write down the exact byte range covered by the checksum. Corrupt a byte and show the decoder rejecting it. Then answer this carefully: a checksum helps detect accidental corruption, but could an attacker change the data and recompute a public checksum? Yes. Tamper evidence requires a keyed MAC, digital signature, or protected/hash-chained log design plus a defined key-management and threat model. Phase 3 uses a checksum for a storage-learning experiment, not a claim of tamper-proof audit.

## 6. Understand Rust's safe concurrency boundary

Write a counter shared between threads. First use Arc<Mutex<u64>>: Arc shares ownership across threads, and Mutex requires a thread to acquire a lock before changing the value. Then read the compiler error from an intentionally unsafe unsynchronized mutation. Do not use unsafe to bypass the error. Run the counter repeatedly and explain which part guarantees shared ownership and which part serializes mutation.

Send and Sync are marker traits that describe whether values may safely move between threads or be referenced by multiple threads. Let the compiler error teach the boundary; read the relevant Rust Book section after trying the example.

## 7. Memory and storage connection

The stack is a region used for function-call data with a structured lifetime; the heap stores values whose size or lifetime is managed dynamically. A process sees virtual addresses, which the operating system maps to physical memory. The mapping is not the same thing as a file on disk.

Read OSTEP's address-space and memory-allocation chapters after viewing the small program. Then read CSAPP's virtual-memory introduction. Write one paragraph connecting a Rust Vec, a process's virtual address space, and the file bytes you encoded. Leave allocator internals and kernel page tables for later study.

## Evidence gate and Phase 3 entry

Save the source, tests, and one sample record in a temporary test folder. Your evidence must show a round trip, one rejected corruption, one rejected truncated record, an explained compiler borrow error, and a safe threaded counter.

Complete learned.md without copying the guide definitions. You are ready for Phase 3 when you can draw how the bytes are encoded, tell which object owns each buffer, and explain why a valid checksum is not proof of malicious-tampering protection.

## Read beside the work

Follow this order; read each section after the code has made the idea visible.

| When | Read | Carry this question into the reading |
|---|---|---|
| While changing the starter program | Rust Book, Chapters 1–3 | Which name owns a value, and which expression borrows it? |
| Before writing the record encoder | Rust Book, Chapters 4–10 and 13 | What lifetime does each reference have, and how does a trait help share behavior? |
| After handling a missing or corrupt file | Rust Book, Chapter 15 | Which error is returned to the caller, and which error can be handled here? |
| Before the shared counter | Rust Book, Chapter 16; *Rust Atomics and Locks*, Chapters 1–2 | Which rule prevents two threads from changing the same value unsafely? |
| After inspecting a running process | OSTEP, Chapters 13–14 and 17; CSAPP, Chapter 9 | How does a virtual address differ from a file offset or a physical address? |

Official references: [Rust Book](https://doc.rust-lang.org/book/), [Cargo guide](https://doc.rust-lang.org/cargo/), [Rust Atomics and Locks](https://marabos.nl/atomics/), [OSTEP](https://pages.cs.wisc.edu/~remzi/OSTEP/), and [CSAPP](https://csapp.cs.cmu.edu/3e/home.html).
