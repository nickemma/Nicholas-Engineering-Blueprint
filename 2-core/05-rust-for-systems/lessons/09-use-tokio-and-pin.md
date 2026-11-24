# 09 Use Tokio and keep a future pinned

> About 7 hours · Continue the `klog` package.

## The problem

A hand-written executor helps explain polling. Switchyard also needs a runtime with tasks, channels, and timers. Polling an arbitrary future requires a pinning guarantee.

## The mental model

Tokio schedules ready tasks. Send can yield when a bounded channel is full. Pin constrains movement of the value behind the handle in ways that matter to a future whose state can refer to itself.

## The pattern

Send ownership across an await. Borrow frames while processing an available buffer. Let the runtime pin its tasks and use a safe pinning primitive when polling by hand.

## Build it

### Step 1. Run a bounded Tokio channel

Keep a small integration package so the systems library remains free of runtime dependencies. A Tokio channel awaits available space without parking this runtime thread. Decode after a complete owned frame arrives.

Create `checks/tokio/Cargo.toml`.

<!-- file: checks/tokio/Cargo.toml -->
~~~toml
[package]
name = "switchyard-tokio"
version = "0.1.0"
edition = "2024"

[dependencies]
klog = { path = "../.." }
tokio = { version = "=1.49.0", features = ["macros", "rt", "sync", "time"] }
~~~

Create `checks/tokio/src/main.rs`.

<!-- file: checks/tokio/src/main.rs -->
~~~rust
use std::error::Error;
use std::time::Duration;

use klog::frame_cursor::FrameCursor;
use klog::record::encode_header;
use tokio::sync::mpsc;
use tokio::time::timeout;

async fn transfer() -> Result<Vec<Vec<u8>>, Box<dyn Error>> {
    let (tx, mut rx) = mpsc::channel::<Vec<u8>>(1);
    let producer = tokio::spawn(async move {
        for data in [b"one", b"two"] {
            let mut bytes = encode_header(data).expect("known record length").to_vec();
            bytes.extend_from_slice(data);
            tx.send(bytes).await.expect("receiver stayed open");
        }
    });
    let mut records = Vec::new();
    while let Some(bytes) = rx.recv().await {
        let mut cursor = FrameCursor::new(&bytes);
        let frame = cursor.next_frame()?.ok_or("incomplete frame on channel")?;
        if !cursor.remaining().is_empty() {
            return Err("extra bytes after frame".into());
        }
        records.push(frame.to_vec());
    }
    producer.await?;
    Ok(records)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn Error>> {
    let records = timeout(Duration::from_secs(3), transfer()).await??;
    println!(
        "received {:?}",
        records
            .iter()
            .map(|v| String::from_utf8_lossy(v))
            .collect::<Vec<_>>()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn sends_both_frames_through_one_slot() {
        let result = timeout(Duration::from_secs(3), transfer())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result, [b"one".to_vec(), b"two".to_vec()]);
    }
}
~~~

~~~bash
cargo run --quiet --manifest-path checks/tokio/Cargo.toml
~~~

~~~text
received ["one", "two"]
~~~

### Step 2. Move a pinned handle and compare addresses

A pinned reference can move while the pinning guarantee for the referenced value stays in force. A type that contains PhantomPinned opts out of automatic Unpin. The pin macro here pins it in a local scope.

Create `src/bin/pinned.rs`.

<!-- file: src/bin/pinned.rs -->
~~~rust
use std::marker::PhantomPinned;
use std::pin::{Pin, pin};

struct Position {
    id: u32,
    _pin: PhantomPinned,
}

fn address(pinned: Pin<&Position>) -> *const Position {
    std::ptr::from_ref(pinned.get_ref())
}

fn main() {
    let position = pin!(Position {
        id: 12,
        _pin: PhantomPinned,
    });
    let before = address(position.as_ref());
    let moved = position;
    assert_eq!(before, address(moved.as_ref()));
    println!("same address after moving the handle; id={}", moved.id);
}
~~~

Create `drills/missing_pin.rs`.

<!-- file: drills/missing_pin.rs -->
~~~rust
use std::marker::PhantomPinned;
use std::pin::Pin;

fn main() {
    let mut marker = PhantomPinned;
    let _ = Pin::new(&mut marker);
}
~~~

~~~bash
cargo run --quiet --bin pinned
bash drills/expect-error.sh drills/missing_pin.rs E0277
~~~

<!-- run: cargo run --quiet --bin pinned -->
<!-- run: bash drills/expect-error.sh drills/missing_pin.rs E0277 -->

~~~text
same address after moving the handle; id=12
error[E0277]: `PhantomPinned` cannot be unpinned
~~~

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Describe what happens when the one-slot channel is full. Then distinguish moving a pinned handle from moving the value it points to.

## If it goes wrong

If a task hangs, look for a retained sender or a missing wake. If Pin::new complains about Unpin, use an actual pinning primitive appropriate for the owner.
