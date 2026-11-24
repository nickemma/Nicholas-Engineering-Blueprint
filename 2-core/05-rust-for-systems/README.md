# 05 Rust for systems

> The core · Time: 5 weeks at 12–15 hours a week · Builds on [04 Rust foundations](../04-rust-foundations/README.md) · Status: ready

## What you'll learn

Measure layout and alignment, read a C function before exposing it through FFI, and write down each `unsafe` obligation. Transfer ownership between threads, relate atomics to the data they publish, and recognize when a future can be polled again. Use Loom, Miri, TSan, ASan, and a bounded fuzz run to check different parts of the implementation.

## What you'll build

Continue the `klog` package from Core 04. A **zero-copy frame cursor** borrows validated records from caller-owned bytes. A **single-producer, single-consumer ring** transfers owned values through a fixed number of slots. The C wrapper, Tokio example, PyO3 extension, and verification crates exercise the same types at their boundaries. Core 06 puts the parser on the Go ↔ Rust wire.

## Lessons

| # | Lesson | What you'll build and check | Time |
|---|---|---|---|
| 01 | [Memory layout is an interface](lessons/01-memory-layout-is-an-interface.md) | Measure `repr(C)`, field offsets, padding, and alignment. Compare memory layout with little-endian wire bytes. | ~5 h |
| 02 | [Borrow a frame from the input](lessons/02-borrow-a-frame-from-the-input.md) | Parse several frames with one cursor. Keep partial and corrupt bytes available to the caller. | ~6 h |
| 03 | [Call a C library through a checked boundary](lessons/03-call-a-c-library.md) | Compile and link C, then wrap its pointer and length in a safe slice API. | ~7 h |
| 04 | [Move work to a single owner](lessons/04-move-work-to-a-single-owner.md) | Write 100 intact `klog` records from a bounded channel and read the compiler's `Send` diagnostic. | ~6 h |
| 05 | [Publish data with atomics](lessons/05-publish-data-with-atomics.md) | Explain release/acquire publication and distinguish it from relaxed atomicity. | ~6 h |
| 06 | [Build an SPSC ring](lessons/06-build-an-spsc-ring.md) | Transfer ownership through `UnsafeCell` and `MaybeUninit`. Verify counter wrap, FIFO order, and destruction. | ~8 h |
| 07 | [Check interleavings, memory, and malformed input](lessons/07-verify-the-systems-code.md) | Exercise the same ring under Loom, use Miri and sanitizers, and fuzz the borrowed cursor. | ~7 h |
| 08 | [Poll a future by hand](lessons/08-poll-a-future-by-hand.md) | Implement a future, waker, and executor with a bounded wait. | ~6 h |
| 09 | [Use Tokio and keep a future pinned](lessons/09-use-tokio-and-pin.md) | Send frames through a bounded Tokio channel and compare a value's address after moving its pinned handle. | ~7 h |
| 10 | [Expose the parser to Python](lessons/10-expose-the-parser-to-python.md) | Import the PyO3 library, make the buffer ownership explicit, and check errors from Python. | ~6 h |

## The gate

The [gate](gate/README.md) checks the native parser, FFI wrapper, ring, and executor. The full run adds Loom, Miri at small counts, TSan on 20,000 transfers, ASan across C and Rust, a 10,000-run fuzz session, and Tokio and PyO3 integration checks. Each tool prints the part of the design it exercised.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Explain a layout measurement, parse a borrowed frame, and test short and corrupt inputs. |
| Intermediate | Review an FFI safety contract, use bounded channels and async tasks, and reason about slot ownership. |
| Senior | Relate each ring hand-off to a memory-ordering edge and use distinct tools to challenge the invariants. |

## Practice

- **[Exercise](exercises.md).** Build a separate bounded telemetry relay.
- **[Self-check](self-check.md).** Explain the implementation and design verification from memory.

## Next

The optional [C for Rust programmers](../deep-dives/c-for-rust-programmers/README.md) deep dive builds and tests the FFI boundary in both directions.

[06 Linux, networking and profiling](../06-linux-networking-and-profiling/README.md) connects the two languages and profiles the data path.

[Recorded results](evidence/README.md) show which systems checks were run and what they observed.
