# 05 Publish data with atomics

> About 6 hours · Continue the `klog` package.

## The problem

A consumer needs to know when a producer’s payload is ready. Seeing an updated flag and seeing the payload are separate operations.

## The mental model

`producer: payload store -> Release flag
consumer: Acquire flag -> payload load`. Reading the published flag connects the arrows across threads.

## The pattern

Use Relaxed for local counters and an explicit release/acquire pair at ownership hand-offs. Write down what the acquire must observe.

## Build it

### Step 1. Publish a value with a release flag

The writer updates the payload with a relaxed atomic store, then publishes the flag with Release. A reader that observes the flag with Acquire can see the payload store. The payload is atomic in this drill, so using the wrong flag ordering exposes a logical bug without introducing a data race.

Create `src/bin/publish.rs`.

<!-- file: src/bin/publish.rs -->
~~~rust
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread;

fn main() {
    let payload = AtomicUsize::new(0);
    let ready = AtomicBool::new(false);
    thread::scope(|scope| {
        scope.spawn(|| {
            payload.store(42, Ordering::Relaxed);
            ready.store(true, Ordering::Release);
        });
        scope.spawn(|| {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
            while !ready.load(Ordering::Acquire) {
                assert!(
                    std::time::Instant::now() < deadline,
                    "publication timed out"
                );
                thread::yield_now();
            }
            assert_eq!(payload.load(Ordering::Relaxed), 42);
        });
    });
    println!("release/acquire published 42");
}
~~~

~~~bash
cargo run --quiet --bin publish
~~~

<!-- run: cargo run --quiet --bin publish -->

~~~text
release/acquire published 42
~~~

### Step 2. Draw both ordering edges

A standalone relaxed operation is atomic for its own value. Release and Acquire connect independent operations when the load observes that release. Lesson 07 uses Loom to exercise the outcome where relaxed publication is insufficient.

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Point at the two operations that synchronize. Predict whether the native drill alone reliably detects weakened ordering.

## If it goes wrong

If the stress run appears to pass with Relaxed everywhere, use the model check in lesson 07 to look for an execution the host did not happen to produce.
