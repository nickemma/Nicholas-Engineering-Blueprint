# 06 Build an SPSC ring

> About 8 hours · Continue the `klog` package.

## The problem

A producer needs to hand off records without allocating a queue node for every send. The buffer must also return ownership if it is full.

## The mental model

Two counters delimit a run of initialized slots. Each end has one writer for its counter. Store the slot first, publish the new counter second. Reading a slot and allowing the producer to reuse it are two distinct events.

## The pattern

Keep ownership hand-offs and their memory ordering next to each unsafe access. Model the storage and atomics through a small internal interface so the same ring code can be exercised under Loom.

## Build it

### Step 1. Set the representation and endpoint contract

Use one producer and one consumer. Endpoint methods take exclusive borrows and neither endpoint can be cloned. Positions advance with wrapping addition. A power-of-two capacity makes the slot mask work across an integer wrap. The wrapping difference is the number of occupied slots.

Create `src/ring_sync.rs`.

<!-- file: src/ring_sync.rs -->
~~~rust
pub(crate) use std::sync::Arc;
pub(crate) use std::sync::atomic::{AtomicUsize, Ordering};

use std::cell::UnsafeCell;
use std::mem::MaybeUninit;

pub(crate) struct Slot<T>(UnsafeCell<MaybeUninit<T>>);

impl<T> Slot<T> {
    pub(crate) fn new() -> Self {
        Self(UnsafeCell::new(MaybeUninit::uninit()))
    }

    pub(crate) fn with<R>(&self, use_ptr: impl FnOnce(*const MaybeUninit<T>) -> R) -> R {
        use_ptr(self.0.get())
    }

    pub(crate) fn with_mut<R>(&self, use_ptr: impl FnOnce(*mut MaybeUninit<T>) -> R) -> R {
        use_ptr(self.0.get())
    }
}

#[cfg(test)]
pub(crate) fn model(test: impl Fn() + Send + Sync + 'static) {
    test();
}
~~~

Register the private storage module.

<!-- append: src/lib.rs -->
~~~rust
mod ring_sync;
~~~

### Step 2. Hand ownership across both positions

The producer first acquires the consumer’s released read index before reusing a slot. The consumer acquires the producer’s released write index before reading an initialized value. The other loads are of positions owned by their respective endpoint. Each endpoint returns promptly on full or empty.

Create `src/spsc.rs`.

<!-- file: src/spsc.rs -->
~~~rust
use crate::ring_sync::{Arc, AtomicUsize, Ordering, Slot};

struct Inner<T, const N: usize> {
    slots: [Slot<T>; N],
    read: AtomicUsize,
    write: AtomicUsize,
}

// SAFETY: only the producer writes a free slot, and only the consumer
// reads an initialized slot. Release/Acquire hands each slot to the other
// endpoint. T: Send permits transfer of the owned value between threads.
unsafe impl<T: Send, const N: usize> Sync for Inner<T, N> {}

pub struct Producer<T, const N: usize>(Arc<Inner<T, N>>);
pub struct Consumer<T, const N: usize>(Arc<Inner<T, N>>);

pub fn channel<T, const N: usize>() -> (Producer<T, N>, Consumer<T, N>) {
    assert!(N.is_power_of_two() && N <= isize::MAX as usize);
    channel_starting_at(0)
}

fn channel_starting_at<T, const N: usize>(start: usize) -> (Producer<T, N>, Consumer<T, N>) {
    let inner = Arc::new(Inner {
        slots: std::array::from_fn(|_| Slot::new()),
        read: AtomicUsize::new(start),
        write: AtomicUsize::new(start),
    });
    (Producer(Arc::clone(&inner)), Consumer(inner))
}

impl<T, const N: usize> Producer<T, N> {
    pub fn try_push(&mut self, value: T) -> Result<(), T> {
        let write = self.0.write.load(Ordering::Relaxed);
        let read = self.0.read.load(Ordering::Acquire);
        if write.wrapping_sub(read) >= N {
            return Err(value);
        }
        let slot = &self.0.slots[write & (N - 1)];
        slot.with_mut(|ptr| {
            // SAFETY: this free slot belongs to the producer. The acquire
            // ensures the consumer finished reading its previous value.
            unsafe { (*ptr).write(value) };
        });
        self.0.write.store(write.wrapping_add(1), Ordering::Release);
        Ok(())
    }
}

impl<T, const N: usize> Consumer<T, N> {
    pub fn try_pop(&mut self) -> Option<T> {
        let read = self.0.read.load(Ordering::Relaxed);
        let write = self.0.write.load(Ordering::Acquire);
        if read == write {
            return None;
        }
        let slot = &self.0.slots[read & (N - 1)];
        // SAFETY: the producer initialized this slot before publishing it.
        // The producer cannot reuse it until we release the new read index.
        let value = slot.with(|ptr| unsafe { (*ptr).assume_init_read() });
        self.0.read.store(read.wrapping_add(1), Ordering::Release);
        Some(value)
    }
}

impl<T, const N: usize> Drop for Inner<T, N> {
    fn drop(&mut self) {
        let mut read = self.read.load(Ordering::Relaxed);
        let write = self.write.load(Ordering::Relaxed);
        while read != write {
            let slot = &self.slots[read & (N - 1)];
            // SAFETY: the last Arc owns the ring. Only the values between
            // these positions were initialized and have yet to be taken.
            slot.with_mut(|ptr| unsafe { (*ptr).assume_init_drop() });
            read = read.wrapping_add(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wrapped_positions_preserve_fifo_and_capacity() {
        crate::ring_sync::model(|| {
            let (mut tx, mut rx) = channel_starting_at::<_, 2>(usize::MAX);
            assert_eq!(rx.try_pop(), None);
            assert_eq!(tx.try_push(7), Ok(()));
            assert_eq!(tx.try_push(8), Ok(()));
            assert_eq!(tx.try_push(9), Err(9));
            assert_eq!(rx.try_pop(), Some(7));
            assert_eq!(tx.try_push(9), Ok(()));
            assert_eq!(rx.try_pop(), Some(8));
            assert_eq!(rx.try_pop(), Some(9));
            assert_eq!(rx.try_pop(), None);
        });
    }
}
~~~

Register the module in `src/lib.rs`.

<!-- append: src/lib.rs -->
~~~rust
pub mod spsc;
~~~

### Step 3. Verify wrapping, contention, and destruction

The unit test starts at the largest position instead of waiting for a counter to wrap. The threaded test transfers distinct values in order. A drop-counting type proves that a rejected value stays with its caller and that unread values are destroyed exactly once.

Create `tests/transport.rs`.

<!-- file: tests/transport.rs -->
~~~rust
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use klog::spsc::channel;

#[test]
fn two_threads_transfer_in_order() {
    let count = if cfg!(miri) { 32 } else { 20_000 };
    let (mut sender, mut receiver) = channel::<usize, 8>();
    thread::scope(|scope| {
        scope.spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(20);
            for number in 0..count {
                while sender.try_push(number).is_err() {
                    assert!(Instant::now() < deadline, "producer timed out");
                    thread::yield_now();
                }
            }
        });
        scope.spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(20);
            for number in 0..count {
                loop {
                    if let Some(value) = receiver.try_pop() {
                        assert_eq!(value, number);
                        break;
                    }
                    assert!(Instant::now() < deadline, "consumer timed out");
                    thread::yield_now();
                }
            }
            assert!(receiver.try_pop().is_none());
        });
    });
    println!("transferred {count} ordered values");
}

#[test]
fn rejected_popped_and_unread_values_drop_once() {
    struct Item(Arc<AtomicUsize>);
    impl Drop for Item {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::Relaxed);
        }
    }

    let count = Arc::new(AtomicUsize::new(0));
    let item = || Item(Arc::clone(&count));
    let (mut tx, mut rx) = channel::<Item, 2>();
    assert!(tx.try_push(item()).is_ok());
    assert!(tx.try_push(item()).is_ok());
    let rejected = tx.try_push(item()).expect_err("ring should be full");
    assert_eq!(count.load(Ordering::Relaxed), 0);
    drop(rejected);
    drop(rx.try_pop());
    assert_eq!(count.load(Ordering::Relaxed), 2);
    drop(tx);
    assert_eq!(count.load(Ordering::Relaxed), 2);
    drop(rx);
    assert_eq!(count.load(Ordering::Relaxed), 3);
}
~~~

~~~bash
cargo test --quiet --test transport -- --nocapture
~~~

<!-- run: cargo test --quiet --test transport -- --nocapture -->

~~~text

running 2 tests
.transferred 20000 ordered values
.
test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
~~~

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Walk through a capacity-two ring as the counters wrap. Trace who owns a slot before publication, after the consumer’s acquire, and after the consumer releases it.

## If it goes wrong

If the producer overwrites an unread value, examine both the full calculation and the acquire of the read index. If values leak or drop twice, check the initialized range and endpoint lifetime.
