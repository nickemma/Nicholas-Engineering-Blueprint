# Core 05 gate

Run this from the Blueprint repository with your finished `klog` checkout:

~~~bash
bash 2-core/05-rust-for-systems/gate/run.sh /path/to/klog
~~~

The native gate needs Linux, Rust 1.89 or newer with Rustfmt and Clippy, a C compiler, and `ar`. It checks the parser and FFI against known inputs, exercises ring counter wrap and destruction, and transfers 20,000 ordered values across two threads.

For the full gate, install the pinned nightly, Miri, and cargo-fuzz from [lesson 07](../lessons/07-verify-the-systems-code.md). The integration checks also need Python 3 and access to the pinned Cargo dependencies. The fuzz build uses a C++ compiler. Select the C toolchain through `CC` and `AR`.

~~~bash
bash 2-core/05-rust-for-systems/gate/run.sh /path/to/klog --extended
~~~

The full gate also runs:

- Loom on the same ring source with modeled atomics and cells. A deliberately relaxed publication must produce a counterexample.
- Miri on the wrap test and smaller threaded transfer and destruction checks.
- TSan on the full native transfer.
- ASan on the C build and its Rust wrapper.
- A 10,000-run libFuzzer session on the borrowed frame cursor.
- The bounded Tokio example and Python extension checks.

See the [recorded runs](../evidence/README.md) for the toolchain and outcome of each check.

Set `SWITCHYARD_C05_INTEGRATIONS=1` for the stable Loom, Tokio, and PyO3 checks. Set `SWITCHYARD_C05_EXTENDED=1` for the full check during lesson replay.
