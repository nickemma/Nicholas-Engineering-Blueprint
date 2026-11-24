# C for Rust programmers · Evidence

Captured on Linux with GCC 13.3.0 and Rust 1.94.1. Filesystem paths and timings depend on the host.

| Check | Capture |
|---|---|
| Compile and link the C CLI | [01-build](01-build.txt) |
| Empty, bounded, and rejected views | [02-view](02-view.txt) |
| Preserve ownership after a failed allocation | [03-buffer](03-buffer.txt) |
| ASan shadow inspection, expected UBSan result, and instrumented C tests | [04-diagnostics](04-diagnostics.txt) |
| Rust wrapper and borrow compile-fail check | [05-rust](05-rust.txt) |
| Rust static link dependencies and the two callers' checksums | [06-link](06-link.txt) |
| Shared binary fixtures and the embedded-zero negative control | [07-gate](07-gate.txt) |
