# 07 Check interleavings, memory, and malformed input

> About 7 hours · Continue the `klog` package.

## The problem

A stress test sees one host’s schedules. A correct-looking FFI call can still read past the end of a slice. A parser can receive malformed input.

## The mental model

Loom explores a small model with instrumented atomics and cells. Miri checks Rust memory operations. TSan detects races observed during a native run. ASan detects memory faults along executed code paths. A fuzzer searches many inputs for failures and records reproductions.

## The pattern

Use each tool at a specific boundary. Keep the same ring implementation in the model and the native build, and label the tested counts and toolchain.

## Build it

### Step 1. Model the native ring with Loom atomics

The model imports the same ring implementation. Only the implementation of the scheduler-visible cell, strong references, and atomics changes. Model a capacity-one slot to keep the number of schedules manageable.

Create `checks/loom/Cargo.toml`.

<!-- file: checks/loom/Cargo.toml -->
~~~toml
[package]
name = "switchyard-loom"
version = "0.1.0"
edition = "2024"

[dependencies]
loom = "=0.7.2"
~~~

Create `checks/loom/src/lib.rs`.

<!-- file: checks/loom/src/lib.rs -->
~~~rust
#[cfg(test)]
mod ring_sync;

#[cfg(test)]
#[path = "../../../src/spsc.rs"]
mod spsc;

#[cfg(test)]
mod tests {
    use loom::sync::Arc;
    use loom::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use loom::thread;

    #[test]
    fn slot_is_published_before_read_and_reused_after_release() {
        loom::model(|| {
            let (mut tx, mut rx) = crate::spsc::channel::<u32, 1>();
            let producer = thread::spawn(move || {
                assert_eq!(tx.try_push(7), Ok(()));
                tx.try_push(9).is_ok()
            });
            let consumer = thread::spawn(move || {
                let first = rx.try_pop();
                (rx, first)
            });
            let sent_twice = producer.join().unwrap();
            let (mut rx, first) = consumer.join().unwrap();
            match first {
                None => {
                    assert!(!sent_twice);
                    assert_eq!(rx.try_pop(), Some(7));
                }
                Some(7) if sent_twice => assert_eq!(rx.try_pop(), Some(9)),
                Some(7) => {}
                Some(other) => panic!("unexpected value {other}"),
            }
            assert_eq!(rx.try_pop(), None);
        });
    }

    #[test]
    #[should_panic(expected = "relaxed flag allowed stale data")]
    fn relaxed_flag_has_a_counterexample() {
        loom::model(|| {
            let payload = Arc::new(AtomicUsize::new(0));
            let ready = Arc::new(AtomicBool::new(false));
            let write_payload = Arc::clone(&payload);
            let write_ready = Arc::clone(&ready);
            let writer = thread::spawn(move || {
                write_payload.store(42, Ordering::Relaxed);
                write_ready.store(true, Ordering::Relaxed);
            });
            if ready.load(Ordering::Relaxed) {
                assert_eq!(
                    payload.load(Ordering::Relaxed),
                    42,
                    "relaxed flag allowed stale data"
                );
            }
            writer.join().unwrap();
        });
    }
}
~~~

Create `checks/loom/src/ring_sync.rs`.

<!-- file: checks/loom/src/ring_sync.rs -->
~~~rust
pub(crate) use loom::sync::Arc;
pub(crate) use loom::sync::atomic::{AtomicUsize, Ordering};

use loom::cell::UnsafeCell;
use std::mem::MaybeUninit;

pub(crate) struct Slot<T>(UnsafeCell<MaybeUninit<T>>);

impl<T> Slot<T> {
    pub(crate) fn new() -> Self {
        Self(UnsafeCell::new(MaybeUninit::uninit()))
    }

    pub(crate) fn with<R>(&self, use_ptr: impl FnOnce(*const MaybeUninit<T>) -> R) -> R {
        self.0.with(use_ptr)
    }

    pub(crate) fn with_mut<R>(&self, use_ptr: impl FnOnce(*mut MaybeUninit<T>) -> R) -> R {
        self.0.with_mut(use_ptr)
    }
}

pub(crate) fn model(test: impl Fn() + Send + Sync + 'static) {
    loom::model(test);
}
~~~

~~~bash
cargo test --quiet --manifest-path checks/loom/Cargo.toml
~~~

~~~text
test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
~~~

### Step 2. Fuzz the parser

Feed bytes to the public cursor. Every successful frame must consume exactly its header and payload, and the returned memory must start inside the original slice. Stop on incomplete or malformed input. Seed a valid frame so the fuzzer can reach the successful branch as well.

Create `fuzz/Cargo.toml`.

<!-- file: fuzz/Cargo.toml -->
~~~toml
[package]
name = "switchyard-fuzz"
version = "0.0.0"
edition = "2024"
publish = false

[package.metadata]
cargo-fuzz = true

[dependencies]
libfuzzer-sys = "=0.4.10"
klog = { path = ".." }

[[bin]]
name = "frames"
path = "fuzz_targets/frames.rs"
test = false
doc = false
bench = false
~~~

Create `fuzz/fuzz_targets/frames.rs`.

<!-- file: fuzz/fuzz_targets/frames.rs -->
~~~rust
#![no_main]

use klog::frame_cursor::FrameCursor;
use klog::record::HEADER_LEN;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|bytes: &[u8]| {
    let mut cursor = FrameCursor::new(bytes);
    loop {
        let original = cursor.remaining();
        match cursor.next_frame() {
            Ok(Some(payload)) => {
                assert_eq!(payload.as_ptr(), original[HEADER_LEN..].as_ptr());
                assert_eq!(
                    original.len() - cursor.remaining().len(),
                    HEADER_LEN + payload.len()
                );
            }
            Ok(None) | Err(_) => {
                assert_eq!(cursor.remaining().len(), original.len());
                break;
            }
        }
    }
});
~~~

### Step 3. Run each tool on the failure it can observe

Miri interprets the Rust code and checks unsafe accesses at small counts. TSan instruments the native threaded test at its normal count. ASan instruments both the Rust wrapper and the C object by adding the flag in build.rs. Fuzzing executes a bounded number of inputs and checks the cursor assertions.

Create `scripts/check-nightly.sh`.

<!-- file: scripts/check-nightly.sh -->
~~~bash
#!/usr/bin/env bash
set -euo pipefail

nightly="${SWITCHYARD_NIGHTLY:-nightly-2026-03-25}"
target=$(rustc "+$nightly" -vV | sed -n 's/^host: //p')

case "${1:-}" in
  miri)
    timeout 180 cargo "+$nightly" miri test --lib spsc::tests
    timeout 180 cargo "+$nightly" miri test --test transport -- --nocapture
    ;;
  tsan)
    TSAN_OPTIONS=halt_on_error=1 RUSTFLAGS=-Zsanitizer=thread           timeout 300 cargo "+$nightly" test -Zbuild-std --target "$target"           --test transport -- --nocapture
    ;;
  asan)
    ASAN_OPTIONS=halt_on_error=1 SWITCHYARD_C_ASAN=1 RUSTFLAGS=-Zsanitizer=address           timeout 300 cargo "+$nightly" test -Zbuild-std --target "$target"           --lib native::tests
    ;;
  fuzz)
    corpus=$(mktemp -d)
    trap 'rm -rf "$corpus"' EXIT
    python3 - "$corpus/frame" <<'SEED'
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(bytes.fromhex("03000000 117863d6 389d964c 6a6f62"))
SEED
    timeout 300 cargo "+$nightly" fuzz run frames "$corpus" -- -runs=10000 -seed=305
    ;;
  *)
    printf 'usage: %s miri|tsan|asan|fuzz\n' "$0" >&2
    exit 2
    ;;
esac
~~~

~~~bash
rustup toolchain install nightly-2026-03-25 --profile minimal --component miri,rust-src
cargo +nightly-2026-03-25 install cargo-fuzz --version 0.13.1 --locked
(
  set -e
  for check in miri tsan asan fuzz; do
    bash scripts/check-nightly.sh "$check"
  done
)
~~~

~~~text
MIRI
transferred 32 ordered values

TSAN
transferred 20000 ordered values

ASAN
test native::tests::c_matches_the_rust_sum_at_the_slice_bounds ... ok

FUZZ
Done 10000 runs in 0 second(s)
~~~

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Explain what caused the relaxed publication assertion to fail. Explain why the C build needs instrumentation of its own for the ASan run.

## If it goes wrong

If the sanitizer stops during initialization, read the host and toolchain error first. A successful check shows what its test cases exercised. If fuzzing finds a failure, keep the corpus input and reproduce it in the unit test.
