# 00 Before you start

Use Linux with Rust 1.89+, Cargo, Rustfmt, Clippy, and Python 3.11+. Bring the completed `klog` crate from [Rust foundations](../../../../2-core/04-rust-foundations/README.md). The engine depends on the crate by path and builds offline.

<!-- continue: ../../../../2-core/04-rust-foundations into klog -->

## Setup card

From the Blueprint checkout, save its absolute path. Set `KLOG_DIR` to the directory where you finished the Core 04 crate. Then copy its manifest, lock file, and source into a fresh learner workspace.

~~~bash
export BLUEPRINT_ROOT="$PWD"
export KLOG_DIR="$HOME/klog"
mkdir -p "$HOME/switchyard-lsm/klog"
cd "$HOME/switchyard-lsm"
cp "$KLOG_DIR/Cargo.toml" "$KLOG_DIR/Cargo.lock" klog/
cp -R "$KLOG_DIR/src" klog/
rustc --version && cargo --version && python3 --version
~~~

Keep disk fixtures in temporary directories you own. The gate interrupts only the engine subprocesses it starts. The project requires no network services.

The implementation drawers contain the replayable code. Work through each design decision before opening its drawer, then compare the local check with the captured result.

Start with [Define the byte-key store](01-define-the-byte-key-store.md).
