# 04 Move work to a single owner

> About 6 hours · Continue the `klog` package.

## The problem

Many producers have records to write. Sharing the actual file gives each producer responsibility for synchronization and shutdown.

## The mental model

A bounded channel sits between producers and one consumer. The consumer owns its state. Dropping the last sender closes the channel after queued work is read.

## The pattern

Transfer ownership with a bounded channel. Join producers and drop the final sender before joining the writer.

## Build it

### Step 1. Pass an owned byte vector through a bounded channel

`Send` permits transfer to another thread. `Sync` permits sharing a reference across threads. A moved vector leaves its sender’s ownership. A bounded channel also gives the producer a place to wait when the consumer falls behind.

Create `src/bin/one-writer.rs`.

<!-- file: src/bin/one-writer.rs -->
~~~rust
use std::path::PathBuf;
use std::sync::mpsc::sync_channel;
use std::thread;

use klog::log::{Log, LogError, visit_records};

fn main() {
    let path = PathBuf::from(std::env::args_os().nth(1).expect("give a fresh log path"));
    let writer_path = path.clone();
    let (send, receive) = sync_channel::<Vec<u8>>(2);
    let writer = thread::spawn(move || -> Result<(), LogError> {
        let mut log = Log::open(&writer_path)?;
        for record in receive {
            log.append(&record)?;
        }
        Ok(())
    });

    thread::scope(|scope| {
        for producer in 0..4 {
            let send = send.clone();
            scope.spawn(move || {
                for n in 0..25 {
                    send.send(vec![producer, n]).expect("writer is alive");
                }
            });
        }
    });
    drop(send);
    writer
        .join()
        .expect("writer did not panic")
        .expect("appends succeeded");
    let mut count = 0;
    let mut bytes = 0;
    visit_records(&path, |record| {
        count += 1;
        bytes += record.len();
        Ok(())
    })
    .expect("read the committed frames");
    assert_eq!((count, bytes), (100, 200));
    println!("one owner received {count} records and {bytes} bytes");
}
~~~

~~~bash
work=$(mktemp -d) && trap 'rm -rf "$work"' EXIT && cargo run --quiet --bin one-writer -- "$work/log"
~~~

<!-- run: work=$(mktemp -d) && trap 'rm -rf "$work"' EXIT && cargo run --quiet --bin one-writer -- "$work/log" -->

~~~text
one owner received 100 records and 200 bytes
~~~

### Step 2. Ask the compiler to reject a non-atomic owner

`Rc` uses counts designed for one thread. `Arc` uses atomic reference counts, and a mutex can protect shared mutation of its contents. The single-owner version above uses a channel instead.

Create `drills/rc_across_threads.rs`.

<!-- file: drills/rc_across_threads.rs -->
~~~rust
use std::rc::Rc;
fn main() {
    let state = Rc::new(1);
    std::thread::spawn(move || println!("{state:?}"))
        .join()
        .unwrap();
}
~~~

~~~bash
bash drills/expect-error.sh drills/rc_across_threads.rs E0277
~~~

<!-- run: bash drills/expect-error.sh drills/rc_across_threads.rs E0277 -->

~~~text
error[E0277]: `Rc<i32>` cannot be sent between threads safely
~~~

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Trace what happens when the channel fills, and why retaining one sender while waiting for the writer to exit would deadlock.

## If it goes wrong

If the writer never exits, check which sender clones are still alive. If a type fails a thread-bound check, inspect what the closure owns.
