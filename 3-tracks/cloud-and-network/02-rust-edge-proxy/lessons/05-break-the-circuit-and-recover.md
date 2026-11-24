# 05 Break the circuit and recover

> A Rust edge proxy · Week 3 · Builds on lesson 04

## The problem

A concurrency limit bounds the work in flight. Repeatedly admitting requests to an origin that is already failing still creates work and forces clients to wait.

## The mental model

In the closed state, count consecutive failed completions. In the open state, reject locally until the cooldown expires. One arriving request can take the half-open probe. The result of that probe either closes the circuit or opens it for another cooldown.

## The pattern

Track breaker state per origin behind a short synchronous lock. Hold the lock only to admit or record an attempt. An epoch keeps late completions from an earlier state from undoing a later recovery. Count transport errors, deadline expiry, and upstream 5xx as failures. Count local admission refusals separately.

## Build it

### Step 1 — Walk two completions out of order

Admit an extra request while closed. Open the circuit with other failures. Predict what happens if the extra request succeeds after a probe has been admitted.

<details>
<summary>Hint</summary>

Only an attempt from the current epoch may change the current phase.

</details>

### Step 2 — Build the state machine

Pass the current instant to the transition methods so the unit tests can advance time directly. Treat a dropped attempt as a failure so cancelling a probe releases the half-open state.

<details>
<summary>Implementation</summary>

Replace `src/lib.rs`.

<!-- file: src/lib.rs -->
~~~rust
//! The Switchyard edge proxy lab.
mod breaker;
pub mod http;
pub mod tcp;
~~~

Create `src/breaker.rs`.

<!-- file: src/breaker.rs -->
~~~rust
use std::sync::Mutex;
use std::time::{Duration, Instant};

enum Phase {
    Closed { failures: u32 },
    Open { until: Instant },
    Probe,
}

struct State {
    epoch: u64,
    phase: Phase,
}

pub(crate) struct Breaker {
    state: Mutex<State>,
    threshold: u32,
    cooldown: Duration,
}

impl Breaker {
    pub(crate) fn new(threshold: u32, cooldown: Duration) -> Self {
        Self {
            state: Mutex::new(State {
                epoch: 0,
                phase: Phase::Closed { failures: 0 },
            }),
            threshold,
            cooldown,
        }
    }

    pub(crate) fn admit(&self, now: Instant) -> Option<Attempt<'_>> {
        let mut state = self.state.lock().expect("breaker state");
        match state.phase {
            Phase::Closed { .. } => {}
            Phase::Open { until } if now >= until => state.phase = Phase::Probe,
            Phase::Open { .. } | Phase::Probe => return None,
        }
        Some(Attempt {
            breaker: self,
            epoch: state.epoch,
            finished: false,
        })
    }

    fn record(&self, epoch: u64, healthy: bool, now: Instant) {
        let mut state = self.state.lock().expect("breaker state");
        if state.epoch != epoch {
            return;
        }
        let next = match state.phase {
            Phase::Closed { .. } if healthy => Phase::Closed { failures: 0 },
            Phase::Closed { failures } if failures + 1 < self.threshold => Phase::Closed {
                failures: failures + 1,
            },
            Phase::Probe if healthy => Phase::Closed { failures: 0 },
            Phase::Closed { .. } | Phase::Probe => Phase::Open {
                until: now + self.cooldown,
            },
            Phase::Open { .. } => return,
        };
        if matches!(next, Phase::Open { .. }) || matches!(state.phase, Phase::Probe) {
            state.epoch += 1;
        }
        state.phase = next;
    }
}

pub(crate) struct Attempt<'a> {
    breaker: &'a Breaker,
    epoch: u64,
    finished: bool,
}

impl Attempt<'_> {
    pub(crate) fn finish(mut self, healthy: bool, now: Instant) {
        self.finished = true;
        self.breaker.record(self.epoch, healthy, now);
    }
}

impl Drop for Attempt<'_> {
    fn drop(&mut self) {
        if !self.finished {
            self.breaker.record(self.epoch, false, Instant::now());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn admits_one_probe_reopens_and_recovers() {
        let cooldown = Duration::from_secs(1);
        let breaker = Breaker::new(2, cooldown);
        let now = Instant::now();
        let stale = breaker.admit(now).unwrap();
        for _ in 0..2 {
            breaker.admit(now).unwrap().finish(false, now);
        }

        assert!(breaker.admit(now).is_none());
        let after_cooldown = now + cooldown;
        let probe = breaker.admit(after_cooldown).unwrap();
        stale.finish(true, after_cooldown);
        assert!(breaker.admit(after_cooldown).is_none());
        probe.finish(false, after_cooldown);

        assert!(breaker.admit(after_cooldown).is_none());
        let recovered = after_cooldown + cooldown;
        breaker.admit(recovered).unwrap().finish(true, recovered);
        assert!(breaker.admit(recovered).is_some());
    }

    #[test]
    fn cancelled_probe_releases_recovery_after_cooldown() {
        let cooldown = Duration::from_secs(1);
        let breaker = Breaker::new(1, cooldown);
        let now = Instant::now();
        breaker.admit(now).unwrap().finish(false, now);
        drop(breaker.admit(now + cooldown).unwrap());
        assert!(breaker.admit(Instant::now()).is_none());
        assert!(breaker.admit(Instant::now() + cooldown).is_some());
    }

    #[test]
    fn a_healthy_response_resets_the_failure_count() {
        let breaker = Breaker::new(2, Duration::from_secs(1));
        let now = Instant::now();
        for healthy in [false, true, false] {
            breaker.admit(now).unwrap().finish(healthy, now);
        }
        assert!(breaker.admit(now).is_some());
    }
}
~~~

</details>

### Step 3 — Connect admission to the request path

Check capacity first, then the breaker. Record the outcome after the deadline-wrapped request and full response body. Observe a failed and a successful probe at the origin.

<details>
<summary>Implementation</summary>

Find these regions in `src/http.rs` in order.

<!-- edit: src/http.rs -->
~~~rust
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use http_body_util::{BodyExt, Full, LengthLimitError, Limited};
~~~

Replace the selected lines with this block.

~~~rust
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::breaker::Breaker;

use http_body_util::{BodyExt, Full, LengthLimitError, Limited};
~~~

<!-- edit: src/http.rs -->
~~~rust
    address: SocketAddr,
    slots: Semaphore,
}
~~~

Replace the selected lines with this block.

~~~rust
    address: SocketAddr,
    slots: Semaphore,
    breaker: Breaker,
}
~~~

<!-- edit: src/http.rs -->
~~~rust
            address,
            slots: Semaphore::new(IN_FLIGHT_PER_ORIGIN),
        }
    }
~~~

Replace the selected lines with this block.

~~~rust
            address,
            slots: Semaphore::new(IN_FLIGHT_PER_ORIGIN),
            breaker: Breaker::new(3, Duration::from_secs(2)),
        }
    }
~~~

<!-- edit: src/http.rs -->
~~~rust
            return reply(StatusCode::SERVICE_UNAVAILABLE, "origin at capacity");
        };
        match timeout(UPSTREAM_TIMEOUT, self.exchange(request)).await {
            Ok(Ok(response)) => response,
            Ok(Err(status)) => reply(status, "upstream response failed"),
~~~

Replace the selected lines with this block.

~~~rust
            return reply(StatusCode::SERVICE_UNAVAILABLE, "origin at capacity");
        };
        let Some(attempt) = origin.breaker.admit(Instant::now()) else {
            return reply(StatusCode::SERVICE_UNAVAILABLE, "origin circuit open");
        };
        let outcome = timeout(UPSTREAM_TIMEOUT, self.exchange(request)).await;
        let healthy = matches!(&outcome, Ok(Ok(response)) if !response.status().is_server_error());
        attempt.finish(healthy, Instant::now());
        match outcome {
            Ok(Ok(response)) => response,
            Ok(Err(status)) => reply(status, "upstream response failed"),
~~~

Find these regions in `lab/check.py` in order.

<!-- edit: lab/check.py -->
~~~python
import subprocess
import threading
~~~

Replace the selected lines with this block.

~~~python
import subprocess
import threading
import time
~~~

<!-- edit: lab/check.py -->
~~~python
            a.release.set()
    assert (a.hits, a.peak) == (32, 32)
    with a.changed:
        a.hold = False
~~~

Replace the selected lines with this block.

~~~python
            a.release.set()
    assert (a.hits, a.peak) == (32, 32)
    time.sleep(2.05)
    with a.changed:
        a.hold = False
~~~

<!-- edit: lab/check.py -->
~~~python


if __name__ == "__main__":
    checks = {check.__name__: check for check in (routing, pool, capacity,)}
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
~~~

Replace the selected lines with this block.

~~~python


def breaker(port, a, _):
    a.status = 502
    for _ in range(3):
        assert request(port, "/a/item")[0] == 502
    observed = request(port, "/a/item")
    assert a.hits == 3, f"breaker: open request reached origin (count={a.hits})"
    assert observed[:2] == (503, b"origin circuit open")
    assert request(port, "/b/item")[0] == 200

    time.sleep(2.05)
    assert request(port, "/a/item")[0] == 502
    assert request(port, "/a/item")[0] == 503
    with a.changed:
        a.status = 200
        a.hold = True
    time.sleep(2.05)
    with ThreadPoolExecutor(max_workers=1) as workers:
        probe = workers.submit(request, port, "/a/item")
        a.wait_for_hits(5)
        try:
            assert request(port, "/a/item")[0] == 503
            assert a.hits == 5
        finally:
            a.release.set()
        assert probe.result()[0] == 200
    assert request(port, "/a/item")[0] == 200
    assert a.hits == 6
    print("breaker: open blocked origin work; failed probe reopened; single healthy probe recovered")


if __name__ == "__main__":
    checks = {check.__name__: check for check in (routing, pool, capacity, breaker,)}
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
~~~

</details>

## Check it

~~~bash
cargo test --locked breaker::tests
cargo build --locked --target-dir target
python3 lab/check.py target/debug/switchyard-edge breaker
~~~

<!-- run: cargo test --locked breaker::tests && cargo build --locked --target-dir target && python3 lab/check.py target/debug/switchyard-edge breaker -->

The controlled clock tests passed. The loopback fixture saw no extra origin hit while the circuit was open, then saw a failed probe reopen the circuit and a single healthy probe restore traffic. [Gate transcript](../evidence/gate.txt)

## If it goes wrong

If a successful older request closes an open circuit, inspect its epoch. If a cancelled probe leaves the circuit stuck, trace how the attempt guard drops.

Continue to [Compare the proxy with Envoy](06-compare-with-envoy.md).
