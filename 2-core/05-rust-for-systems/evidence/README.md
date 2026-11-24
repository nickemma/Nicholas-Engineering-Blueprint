# Core 05 evidence

The native and integration checks ran on Linux with stable Rust 1.94.1. The instrumented checks used nightly-2026-03-25 and cargo-fuzz 0.13.1.

| Capture | Observed result |
|---|---|
| [Layout](lessons/01-layout.txt) · [Borrowed parser](lessons/02-frame.txt) | Target layout and two passing cursor tests |
| [Native C](lessons/03-native.txt) · [Single owner](lessons/04-writer.txt) · [Send diagnostic](lessons/04-send.txt) | The wrapper handled every sub-slice of the fixture. One owner wrote and read back 100 records. Rust refused to send an `Rc` across a thread. |
| [Publication](lessons/05-publish.txt) · [Ring](lessons/06-ring.txt) | The native release/acquire drill published 42. The ring transferred 20,000 ordered values and dropped each owned value once. |
| [Polling](lessons/08-poll.txt) · [Pinning](lessons/09-pin.txt) | The hand executor reached Ready after a wake. Moving a pinned handle kept the referent address, and the compiler refused an invalid pin. |
| [Native gate](gate/native.txt) | Formatting, Clippy, Rust tests, and the native ring checks passed. |
| [Loom, Tokio, and PyO3](gate/integrations.txt) | Loom passed the real ring model and found the expected Relaxed flag counterexample. Tokio delivered both frames. Python returned the payload and rejected three invalid inputs. |
| [Weakened ring publication](gate/loom-weakened.txt) | Replacing the write index's Release store with Relaxed made the Loom model report concurrent read and write access. |
| [Miri](gate/miri.txt) | Counter wrap, dropped values, and 32 threaded transfers passed. |
| [TSan](gate/tsan.txt) · [ASan](gate/asan.txt) | The instrumented 20,000-value test and the instrumented C slice-boundary test passed. |
| [libFuzzer](gate/fuzz.txt) | The frame cursor completed 10,000 inputs from a valid-frame seed without a crash or failed assertion. |
| [Fresh extended replay](gate/replay.txt) | Rebuilds both Core 04 and Core 05 and runs the full Core 05 gate. |

The ring model uses capacity one. The native stress test uses capacity eight. The fuzz run uses one seed and a fixed run budget. These cases exercise distinct failure modes.
