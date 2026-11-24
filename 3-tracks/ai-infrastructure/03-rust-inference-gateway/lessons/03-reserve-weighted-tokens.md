# 03 Reserve weighted tokens

> A Rust inference gateway · Week 1

## The problem

One request might generate a few tokens and another might request a long answer. A quota that only counts requests gives them the same cost.

## The mental model

~~~text
previous credit + elapsed refill, capped at capacity
                         → reserve prompt tokens + maximum output
                         → on shortage, wait for the missing credit
~~~

## The pattern

Store refill credit as scaled integers and use monotonic time. Compute the whole debit under one lock per tenant. Preserve fractional refill across short intervals. The lab keeps a reservation after a generation attempt starts, even when the response is cancelled. The per-process bucket applies to a single gateway replica.

## Build it

### Export the bucket

Keep quota arithmetic independent of HTTP.

Create or update `src/lib.rs` as shown.

<!-- file: src/lib.rs -->
~~~rust
pub mod protocol;
pub mod quota;
pub mod sse;
~~~

### Implement an exact weighted bucket

Compute a retry delay when capacity can refill. Treat a reservation larger than burst capacity as a permanent input refusal.

Create or update `src/quota.rs` as shown.

<!-- file: src/quota.rs -->
~~~rust
//! Weighted token accounting without rounding away fractional refill.

use std::time::{Duration, Instant};

const ONE: u128 = 1_000_000_000;

#[derive(Debug, PartialEq, Eq)]
pub enum Refusal {
    NeverFits,
    RetryAfter(Duration),
}

pub struct Bucket {
    capacity: u128,
    refill_per_second: u128,
    available: u128,
    updated: Instant,
}

impl Bucket {
    pub fn new(capacity: u32, refill_per_second: u32, now: Instant) -> Result<Self, &'static str> {
        if capacity == 0 || refill_per_second == 0 {
            return Err("bucket needs positive capacity and refill");
        }
        let capacity = u128::from(capacity) * ONE;
        Ok(Self {
            capacity,
            refill_per_second: u128::from(refill_per_second),
            available: capacity,
            updated: now,
        })
    }

    pub fn reserve(&mut self, amount: u32, now: Instant) -> Result<(), Refusal> {
        let cost = u128::from(amount) * ONE;
        if cost > self.capacity {
            return Err(Refusal::NeverFits);
        }
        let elapsed = now.saturating_duration_since(self.updated).as_nanos();
        self.updated = self.updated.max(now);
        let refill = elapsed.saturating_mul(self.refill_per_second);
        self.available = self.capacity.min(self.available.saturating_add(refill));
        if self.available < cost {
            let delay_ns = (cost - self.available).div_ceil(self.refill_per_second);
            // A u32 token capacity scaled by ONE fits in u64 nanoseconds.
            return Err(Refusal::RetryAfter(Duration::from_nanos(delay_ns as u64)));
        }
        self.available -= cost;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn weighted_debits_and_fractional_refill() {
        let at = Instant::now();
        let mut alpha = Bucket::new(9, 2, at).unwrap();
        let mut beta = Bucket::new(9, 2, at).unwrap();
        alpha.reserve(6, at).unwrap();
        assert_eq!(alpha.reserve(10, at), Err(Refusal::NeverFits));
        assert_eq!(
            alpha.reserve(4, at),
            Err(Refusal::RetryAfter(Duration::from_millis(500)))
        );
        assert!(beta.reserve(9, at).is_ok());
        let half = at + Duration::from_millis(250);
        assert_eq!(
            alpha.reserve(4, half),
            Err(Refusal::RetryAfter(Duration::from_millis(250)))
        );
        assert!(alpha.reserve(4, at + Duration::from_millis(500)).is_ok());
        assert!(alpha.reserve(9, at + Duration::from_secs(500)).is_ok());
        assert!(matches!(alpha.reserve(1, at), Err(Refusal::RetryAfter(_))));
        println!("quota: weighted spending, exact refill, and tenant buckets are independent");
    }
}
~~~

## Check it

~~~bash
cargo test --locked quota::tests -- --nocapture
~~~

<!-- run: cargo test --locked quota::tests -- --nocapture -->

Use exact test times to check both fractional refill and a second tenant with its own full bucket. Avoid sleeping to test arithmetic.
