# Gate · C for Rust programmers

From your finished scratch directory, run:

~~~bash
bash "$blueprint/2-core/deep-dives/c-for-rust-programmers/gate/run.sh" "$PWD"
~~~

Use Linux with a C17 compiler and its ASan and UBSan runtimes, GNU Make, Rust with Rustfmt and Clippy, and Python 3. The gate builds into temporary directories. The default ASan run checks address safety with leak detection disabled for sandbox compatibility. On a host that supports LeakSanitizer, set `ASAN_OPTIONS=detect_leaks=1` to include that check.

| Check | Passing result |
|---|---|
| Native ownership | The ordinary, ASan, and UBSan suites pass. An injected resize failure preserves the pointer and bytes. A retry succeeds and destruction calls the release function once. |
| Rust ownership | The wrapper returns the exact buffer contents. The compile-fail test confirms a view cannot remain in use across a mutable append. |
| C ABI | The C caller rejects a missing output and a null nonempty input. A rejected call leaves the initialized output unchanged. |
| Binary fixtures | Both programs match the known checksum for each of the same three files. The Rust caller also compares the resulting bytes directly. |
| Negative control | A temporary checksum variant that skips a zero byte returns the specific fixture mismatch. |

The final `negative control` line confirms that the intentional failure was caught. [Reference gate transcript](../evidence/07-gate.txt)
