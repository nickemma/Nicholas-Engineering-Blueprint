# 04 Put a deadline and a limit on upstream work

> A Rust edge proxy · Week 2 · Builds on lesson 03

## The problem

Connection reuse saves dial work. A stalled origin can still consume connections and hold live requests until it recovers.

## The mental model

An idle pool counts cached sockets. An in-flight limit counts work. A deadline bounds how long admitted work occupies the limit. Allocate that limit per origin so upstream A cannot occupy B’s slots.

## The pattern

Acquire a permit after reading the bounded downstream body. Refuse immediately with 503 if the origin has no permit. Keep the permit until the full upstream response is buffered, the exchange fails, or the deadline expires. The lab sends 504 when the exchange exceeds 750 ms. This bounds the proxy’s wait even if the origin continues working after its socket closes.

## Build it

### Step 1 — Define the failure experiment

Hold 32 requests at one origin. Predict what the next request to that origin sees and what a request to the other origin sees.

<details>
<summary>Hint</summary>

Check the stalled origin’s own peak count and verify both client statuses.

</details>

### Step 2 — Apply limits per origin

Give each address its own semaphore. Cover connect, headers, and all response bytes with the upstream exchange deadline. Reject a duplicate origin address so the two routes have distinct budgets.

<details>
<summary>Implementation</summary>

Find these regions in `src/http.rs` in order.

<!-- edit: src/http.rs -->
~~~rust
type Reply = Response<Full<Bytes>>;

struct Proxy {
    client: Client<HttpConnector, Full<Bytes>>,
    origins: [SocketAddr; 2],
}

pub async fn serve(listener: TcpListener, origins: [SocketAddr; 2]) -> io::Result<()> {
    let mut connector = HttpConnector::new();
    connector.set_connect_timeout(Some(Duration::from_secs(2)));
    connector.set_nodelay(true);
    let client = Client::builder(TokioExecutor::new())
~~~

Replace the selected lines with this block.

~~~rust
type Reply = Response<Full<Bytes>>;

const UPSTREAM_TIMEOUT: Duration = Duration::from_millis(750);
const IN_FLIGHT_PER_ORIGIN: usize = 32;

struct Origin {
    address: SocketAddr,
    slots: Semaphore,
}

impl Origin {
    fn new(address: SocketAddr) -> Self {
        Self {
            address,
            slots: Semaphore::new(IN_FLIGHT_PER_ORIGIN),
        }
    }
}

struct Proxy {
    client: Client<HttpConnector, Full<Bytes>>,
    origins: [Origin; 2],
}

pub async fn serve(listener: TcpListener, origins: [SocketAddr; 2]) -> io::Result<()> {
    if origins[0] == origins[1] {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "HTTP origins must use distinct socket addresses",
        ));
    }
    let mut connector = HttpConnector::new();
    connector.set_connect_timeout(Some(UPSTREAM_TIMEOUT));
    connector.set_nodelay(true);
    let client = Client::builder(TokioExecutor::new())
~~~

<!-- edit: src/http.rs -->
~~~rust
        .retry_canceled_requests(false)
        .build(connector);
    let proxy = Arc::new(Proxy { client, origins });
    let slots = Arc::new(Semaphore::new(256));
    loop {
~~~

Replace the selected lines with this block.

~~~rust
        .retry_canceled_requests(false)
        .build(connector);
    let proxy = Arc::new(Proxy {
        client,
        origins: origins.map(Origin::new),
    });
    let slots = Arc::new(Semaphore::new(256));
    loop {
~~~

<!-- edit: src/http.rs -->
~~~rust

        let origin = match parts.uri.path().split('/').nth(1) {
            Some("a") => self.origins[0],
            Some("b") => self.origins[1],
            _ => return reply(StatusCode::NOT_FOUND, "no route"),
        };
~~~

Replace the selected lines with this block.

~~~rust

        let origin = match parts.uri.path().split('/').nth(1) {
            Some("a") => &self.origins[0],
            Some("b") => &self.origins[1],
            _ => return reply(StatusCode::NOT_FOUND, "no route"),
        };
~~~

<!-- edit: src/http.rs -->
~~~rust
        parts.uri = Uri::builder()
            .scheme("http")
            .authority(origin.to_string())
            .path_and_query(target.as_str())
            .build()
~~~

Replace the selected lines with this block.

~~~rust
        parts.uri = Uri::builder()
            .scheme("http")
            .authority(origin.address.to_string())
            .path_and_query(target.as_str())
            .build()
~~~

<!-- edit: src/http.rs -->
~~~rust
        let request = Request::from_parts(parts, Full::new(body));

        match timeout(Duration::from_secs(2), self.exchange(request)).await {
            Ok(Ok(response)) => response,
            Ok(Err(status)) => reply(status, "upstream response failed"),
~~~

Replace the selected lines with this block.

~~~rust
        let request = Request::from_parts(parts, Full::new(body));

        let Ok(_slot) = origin.slots.try_acquire() else {
            return reply(StatusCode::SERVICE_UNAVAILABLE, "origin at capacity");
        };
        match timeout(UPSTREAM_TIMEOUT, self.exchange(request)).await {
            Ok(Ok(response)) => response,
            Ok(Err(status)) => reply(status, "upstream response failed"),
~~~

</details>

### Step 3 — Release stalled work and try again

Keep the fixture blocked long enough to measure the deadline, then release it and check that later requests can make progress.

<details>
<summary>Implementation</summary>

Find these regions in `lab/check.py` in order.

<!-- edit: lab/check.py -->
~~~python
"""Loopback checks against the built edge executable."""
import argparse
from contextlib import contextmanager
from http.client import HTTPConnection
~~~

Replace the selected lines with this block.

~~~python
"""Loopback checks against the built edge executable."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from http.client import HTTPConnection
~~~

<!-- edit: lab/check.py -->
~~~python


if __name__ == "__main__":
    checks = {check.__name__: check for check in (routing, pool,)}
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
~~~

Replace the selected lines with this block.

~~~python


def capacity(port, a, _):
    a.hold = True
    with ThreadPoolExecutor(max_workers=32) as workers:
        jobs = [workers.submit(request, port, "/a/item") for _ in range(32)]
        a.wait_for_hits(32)
        try:
            assert request(port, "/a/item")[:2] == (503, b"origin at capacity")
            assert request(port, "/b/item") == (200, b"b /b/item ", "b")
            assert all(job.result()[0] == 504 for job in jobs)
        finally:
            a.release.set()
    assert (a.hits, a.peak) == (32, 32)
    with a.changed:
        a.hold = False
    assert request(port, "/a/item")[0] == 200
    print("capacity: 32 timed out at the stalled origin, excess got 503, other origin got 200, stalled origin recovered")


if __name__ == "__main__":
    checks = {check.__name__: check for check in (routing, pool, capacity,)}
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
~~~

</details>

## Check it

~~~bash
cargo build --locked --target-dir target
python3 lab/check.py target/debug/switchyard-edge capacity
~~~

<!-- run: cargo build --locked --target-dir target && python3 lab/check.py target/debug/switchyard-edge capacity -->

The reference fixture returned 504 to the 32 held requests and 503 to the excess request. The other origin returned 200 during the stall and the stalled origin served again after release. [Gate transcript](../evidence/gate.txt)

## If it goes wrong

If B also returns 503, inspect where the semaphore lives. If the peak is below 32, look at arrival timing and the origin accept queue before changing the budget.

Continue to [Break the circuit and recover](05-break-the-circuit-and-recover.md).
