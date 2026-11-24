# 08 Poll a future by hand

> About 6 hours · Continue the `klog` package.

## The problem

A task can yield while waiting for work. Something has to poll it again when progress becomes possible.

## The mental model

The executor pins the future, creates a context with a waker, and polls it. Pending leaves the state in the future. Ready returns an output. This executor parks one thread between polls.

## The pattern

Pair every deliberate Pending with an event that can wake the task. Treat a wake as permission to poll again and allow spurious wakes.

## Build it

### Step 1. Connect a waker to a parked thread

Ordinary async functions return a value that implements Future. The poll method returns Pending or Ready. A Waker asks an executor to poll again. Thread unpark preserves one token if a wake arrives before park.

Create `src/executor.rs`.

<!-- file: src/executor.rs -->
~~~rust
use std::future::Future;
use std::pin::{Pin, pin};
use std::sync::Arc;
use std::task::{Context, Poll, Wake, Waker};
use std::thread;
use std::time::{Duration, Instant};

struct ThreadWake(thread::Thread);

impl Wake for ThreadWake {
    fn wake(self: Arc<Self>) {
        self.0.unpark();
    }

    fn wake_by_ref(self: &Arc<Self>) {
        self.0.unpark();
    }
}

pub fn block_on<F: Future>(future: F, timeout: Duration) -> Option<F::Output> {
    let deadline = Instant::now().checked_add(timeout)?;
    let waker = Waker::from(Arc::new(ThreadWake(thread::current())));
    let mut context = Context::from_waker(&waker);
    let mut future = pin!(future);
    loop {
        if let Poll::Ready(output) = future.as_mut().poll(&mut context) {
            return Some(output);
        }
        let remaining = deadline.checked_duration_since(Instant::now())?;
        thread::park_timeout(remaining);
    }
}

#[derive(Default)]
pub struct YieldOnce(bool);

impl Future for YieldOnce {
    type Output = ();

    fn poll(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<()> {
        if self.0 {
            Poll::Ready(())
        } else {
            self.0 = true;
            context.waker().wake_by_ref();
            Poll::Pending
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wake_before_park_is_retained() {
        let task = async {
            YieldOnce::default().await;
            42
        };
        assert_eq!(block_on(task, Duration::from_secs(1)), Some(42));
    }

    #[test]
    fn waiting_without_a_wake_has_a_deadline() {
        let future = std::future::pending::<()>();
        assert_eq!(block_on(future, Duration::from_millis(5)), None);
    }
}
~~~

Register the module in `src/lib.rs`.

<!-- append: src/lib.rs -->
~~~rust
pub mod executor;
~~~

### Step 2. Exercise both poll outcomes

Create `src/bin/poll-once.rs`.

<!-- file: src/bin/poll-once.rs -->
~~~rust
use klog::executor::{YieldOnce, block_on};
use std::time::Duration;

fn main() {
    let task = async {
        println!("before yield");
        YieldOnce::default().await;
        println!("after yield");
        42
    };
    println!(
        "completed with {:?}",
        block_on(task, Duration::from_secs(1))
    );
}
~~~

~~~bash
cargo run --quiet --bin poll-once
~~~

<!-- run: cargo run --quiet --bin poll-once -->

~~~text
before yield
after yield
completed with Some(42)
~~~

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Trace the first poll, the unpark token, and the second poll. Remove the wake in a scratch copy and predict which test reaches its deadline.

## If it goes wrong

If a task repeatedly reads Pending, check who stores or calls the waker. A synchronous poll that never returns also prevents this tiny executor from enforcing its wait budget.
