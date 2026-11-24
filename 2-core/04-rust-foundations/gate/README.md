# Core 04 gate

Run the gate against the `klog` package you built. Use Linux, Rust 1.89 or newer with Rustfmt and Clippy, and Python 3. From the Blueprint repository:

~~~bash
bash 2-core/04-rust-foundations/gate/run.sh /path/to/klog
~~~

The gate runs formatting, lint, and Rust tests. It builds the CLI and runs it against disposable files. The reference log has two committed records.

| Check | Required result |
|---|---|
| Every incomplete byte cut of the second frame | The first record survives byte-for-byte. `check` reports how many torn bytes it removed. |
| Complete header and payload damage | `check`, `cat`, and `append` fail and preserve the damaged file. The checksum test covers the final frame as well. |
| A second writer while a lock is held | The append fails and the log stays unchanged. |
| SIGKILL after a writer signals that it has appended part of a frame | Reopening removes that suffix, preserves the earlier record, and accepts a new record. |

The crash test leaves the operating system and storage running. It exercises process recovery on a known partial write. The append code calls `sync_all` on the data and synchronizes the parent directory before acknowledging the first append through a handle.

See the [captured runs](../evidence/README.md) for the reference result and the result with payload checksum verification deliberately removed.
