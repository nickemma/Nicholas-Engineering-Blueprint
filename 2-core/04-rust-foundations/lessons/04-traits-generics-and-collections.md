# 04 Traits, generics, and collections

> About 6 hours · Work in the same `klog` package throughout the module.

## The problem

You have measurements from two sources. You want one summary function and a predictable order when printing its buckets.

## The mental model

A trait specifies behavior a type can provide. A type parameter lets a function work with many concrete types. `Vec<T>` owns a growable sequence, while a `BTreeMap<K, V>` stores keyed values in sorted-key order.

## The pattern

Use a small trait bound at the operation that needs it. Borrow the input. Use iterator adapters for selection and counting, and use an ordered map where stable output matters.

## Build it

### Step 1. Define a trait and two implementations

A trait implementation supplies `millis` for each concrete type. A closure can capture `cutoff` from its enclosing scope.

Create `src/summary.rs`.

<!-- file: src/summary.rs -->
~~~rust
use std::collections::BTreeMap;

pub trait Measurement {
    fn millis(&self) -> u64;
}

pub struct Sample {
    pub elapsed_ms: u64,
}

impl Measurement for Sample {
    fn millis(&self) -> u64 {
        self.elapsed_ms
    }
}

impl Measurement for u64 {
    fn millis(&self) -> u64 {
        *self
    }
}

pub fn slow<T: Measurement>(samples: &[T], cutoff: u64) -> Vec<u64> {
    samples
        .iter()
        .map(Measurement::millis)
        .filter(|&ms| ms > cutoff)
        .collect()
}

pub fn buckets<T: Measurement>(samples: &[T]) -> BTreeMap<u64, usize> {
    let mut counts = BTreeMap::new();
    for sample in samples {
        let bucket = sample.millis() / 10 * 10;
        *counts.entry(bucket).or_insert(0) += 1;
    }
    counts
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_types_can_use_the_same_summary() {
        let samples = [Sample { elapsed_ms: 12 }, Sample { elapsed_ms: 29 }];
        assert_eq!(slow(&samples, 20), slow(&[12, 29], 20));
    }

    #[test]
    fn bucket_order_is_stable() {
        let counts = buckets(&[24, 10, 21, 12, 9]);
        assert_eq!(
            counts.into_iter().collect::<Vec<_>>(),
            [(0, 1), (10, 2), (20, 2)]
        );
    }
}
~~~

Add this to `src/lib.rs`.

<!-- append: src/lib.rs -->
~~~rust
pub mod summary;
~~~

### Step 2. Read the iterator chain

`.iter()` borrows each value. `.map()` turns it into milliseconds. `.filter()` borrows each mapped value while it decides whether to keep it. `.collect()` allocates the resulting vector.

Create `src/bin/summarize.rs`.

<!-- file: src/bin/summarize.rs -->
~~~rust
fn main() {
    let samples = [24, 10, 21, 12, 9];
    println!("slow: {:?}", klog::summary::slow(&samples, 20));
    println!("buckets: {:?}", klog::summary::buckets(&samples));
}
~~~

~~~bash
cargo run --quiet --bin summarize
~~~

<!-- run: cargo run --quiet --bin summarize -->

~~~text
slow: [24, 21]
buckets: {0: 1, 10: 2, 20: 2}
~~~

~~~bash
cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet
~~~

<!-- run: cargo fmt --check && cargo clippy --quiet --all-targets -- -D warnings && cargo test --quiet -->

## Check it

Add another measurement type and reuse the same tests. Explain which iterator operations can run without allocating a new vector.

## If it goes wrong

If a closure has one more reference than expected, read the signatures of the neighboring iterator adapters. If tests compare ordering, pick a collection whose iteration order is part of its contract.
