# Exercise · Read binary records in C

Build a separate C record reader and call it from Rust. Use a two-byte unsigned little-endian payload length followed by exactly that many bytes. Set a maximum record size for the exercise and reject larger lengths before allocating.

## Finished behavior

- Return distinct outcomes for a complete record, clean end-of-file, a truncated header, a truncated payload, and a payload length above the limit.
- Preserve zero bytes. An empty payload is a complete record. An empty input stream is clean end-of-file.
- Decide whether each successful output borrows the input or owns an allocation. Explain in the header which operation ends the borrow or releases the allocation.
- Expose a safe Rust API that represents each outcome. If you return a borrowed record, tie it to input that remains live for its full use.

## Acceptance checks

1. Read a stream containing an empty record and a record with a zero byte in its middle. Compare the returned bytes exactly.
2. Truncate a multi-byte record at every byte offset. Test the result for each cut, including clean end-of-file between complete records.
3. Test the size limit on both sides of the bound. If you allocate storage, inject one allocation failure and show that an existing record or reader state is preserved.
4. Run the C suite in ordinary, ASan, and UBSan builds. Run the Rust checks against the same fixtures.
5. Document an intentionally changed version of one boundary rule and show the test that rejects it.

## From C or C++ to Rust

Use this comparison alongside [Rust foundations](../../04-rust-foundations/README.md) and [Rust for systems](../../05-rust-for-systems/README.md) if you already write C or C++. Install Rust with rustup if needed, update the stable toolchain, and check the versions in the Core 04 setup. Open the Cargo workspace in your editor with rust-analyzer and verify that diagnostics and go-to-definition work on the first package.

| Compare | Try it in the record reader |
|---|---|
| Primitive types, mutability, conversions and overflow | Choose explicit widths for encoded fields. Compare C integer conversions with Rust checked conversions and checked arithmetic. Test the largest valid length and an overflowing conversion. |
| Control flow, loops, strings, functions and scopes | Parse bytes with a slice cursor. Validate text separately as UTF-8. Compare a C loop with Rust iterator and pattern-matching code using the same fixtures. |
| Structs and methods, tuples and destructuring, enums | Represent the result of a read as a Rust enum with payloads. Destructure a tuple for a decoded length and the remaining input. Compare how the C API conveys the same states. |
| Containers, iterators, moves, borrows, slices, memory management and `Drop` | Compare a C pointer plus length and a C++ RAII owner with a borrowed Rust slice and an owning wrapper. Verify who can free the buffer and when a view expires. |
| Program organization, traits, generics, errors and concurrency | Split decoding and I/O into modules. Use a generic reader and typed errors. Compare passing owned data to a thread with sharing it and explain what `Send` and `Sync` enforce. |
| Native compilation, tool equivalents, tests and benchmarks | Compare Make or CMake build and test targets with Cargo. Run matched benchmarks in optimized builds on the same record sizes and include the cost of crossing the FFI boundary. |

Call the plain C reader from Rust. If your implementation is in C++, expose a C-compatible wrapper with an opaque handle and documented ownership. Convert C++ exceptions to a status at the boundary. Test that allocation and release stay paired and that no borrowed view outlives its owner.

Follow the [C++ record reader build](deep-dives/cpp-record-reader.md) to see those rules exercised by code and compiler checks.
