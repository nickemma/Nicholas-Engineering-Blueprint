# Deep dive · C for Rust programmers

> Optional, after [Core 05 Rust for systems](../../05-rust-for-systems/README.md) · Time: about 2 weeks at 12–15 hours a week · Status: ready

## What you'll build

Write a small C byte-buffer library with an explicit ownership contract and a Makefile. Call it through a safe Rust wrapper. Then export a Rust checksum function through a C header and call it from a C program. Use the same binary fixtures in both directions so the boundary tests compare results byte for byte.

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| # | Lesson | What you'll build and check |
|---|---|---|
| 01 | [From source file to executable](lessons/01-from-source-file-to-executable.md) | Write a C CLI and split it into source, header, and test files. Compile object files, link an executable, and use Make to rebuild the targets affected by a header change. |
| 02 | [Pointers, arrays, and byte slices](lessons/02-pointers-arrays-and-byte-slices.md) | Pass a buffer with its length, distinguish its contents from its capacity, and compare pointer arithmetic with a Rust slice. Test empty input and subranges. |
| 03 | [Own and grow a buffer](lessons/03-own-and-grow-a-buffer.md) | Implement allocation, checked growth, append, and destruction. Inject allocation failure and verify that the existing buffer and its ownership remain intact. |
| 04 | [Read a sanitizer diagnosis](lessons/04-read-a-sanitizer-diagnosis.md) | Build the tests with AddressSanitizer and UndefinedBehaviorSanitizer. Read reports from small diagnostic examples, identify the violated contract, and verify the corrected build. |
| 05 | [Call the C library from Rust](lessons/05-call-the-c-library-from-rust.md) | Build and link the C archive with Cargo. Wrap its opaque handle with checked construction, a borrowed view, and a destructor that calls the C release function. |
| 06 | [Call a Rust library from C](lessons/06-call-a-rust-library-from-c.md) | Build a Rust static library, publish the matching C declaration, and call a checksum function from C. Review the pointer and length contract, status returns, and how the caller retains ownership of the input. |
| 07 | [Prove the round trip](lessons/07-prove-the-round-trip.md) | Run both callers against shared binary fixtures. Check empty input, embedded zero bytes, rejected inputs, and a failed buffer growth. Capture the C, Rust, and sanitizer results. |

## The gate

The [automated gate](gate/README.md) builds from a clean directory using Make and Cargo. Run the C tests in ordinary, ASan, and UBSan builds, then run both interoperability tests. The C and Rust callers must produce the same checksum from the shared fixtures. The allocation-failure check must preserve the bytes and leave the buffer usable. A deliberately broken build that drops an embedded zero byte must fail the same round-trip assertion.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Write a C function from a header, rebuild it, and identify who owns a buffer. |
| Intermediate | Handle allocation failure and explain a sanitizer report in terms of the violated contract. |
| Senior | Review an interface in both languages and defend its ABI, lifetime, failure, and cleanup rules. |

## Practice

- [Exercise](exercises.md). Build a separate binary record reader in C with a Rust caller.
- [C and C++ comparison](exercises.md#from-c-or-c-to-rust). Relate familiar language and toolchain features to Rust and test the ABI boundary.
- [Call a C++ record reader safely from Rust](deep-dives/cpp-record-reader.md). Follow the C ABI build and test ownership across the boundary.
- [Self-check](self-check.md). Rebuild the ownership and ABI contracts from memory.
- [Evidence](evidence/README.md). Review the compiler, sanitizer, and fixture captures.
