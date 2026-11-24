# 03 Reuse upstream connections

> A Rust edge proxy · Week 2 · Builds on lesson 02

## The problem

A proxy that dials the origin once per request churns upstream sockets even if many requests could use the same connection.

## The mental model

There are two independent connection lifetimes. To prove that the upstream side reuses a connection, close each downstream client connection and count accepted upstream sockets. An origin request counter alone only shows that requests arrived.

## The pattern

Keep the upstream client for the lifetime of the proxy and bound its idle pool per authority. Configure an idle timer so old connections can expire. Reading the entire bounded response gives the HTTP client the opportunity to return the socket to its pool.

## Build it

### Step 1 — Predict the counts

Write down how many upstream accepts you expect for 12 serial requests when pooling is enabled and when it is disabled.

<details>
<summary>Hint</summary>

Both trials should record 12 upstream requests.

</details>

### Step 2 — Enable and bound the pool

Keep up to 32 idle connections per authority for 30 seconds. Enable TCP no-delay on upstream sockets and handle failure to configure an accepted downstream socket within that connection.

<details>
<summary>Implementation</summary>

Find these regions in `src/http.rs` in order.

<!-- edit: src/http.rs -->
~~~rust
    let mut connector = HttpConnector::new();
    connector.set_connect_timeout(Some(Duration::from_secs(2)));
    let client = Client::builder(TokioExecutor::new())
        .pool_max_idle_per_host(0)
        .retry_canceled_requests(false)
        .build(connector);
~~~

Replace the selected lines with this block.

~~~rust
    let mut connector = HttpConnector::new();
    connector.set_connect_timeout(Some(Duration::from_secs(2)));
    connector.set_nodelay(true);
    let client = Client::builder(TokioExecutor::new())
        .pool_max_idle_per_host(32)
        .pool_idle_timeout(Duration::from_secs(30))
        .pool_timer(TokioTimer::new())
        .retry_canceled_requests(false)
        .build(connector);
~~~

<!-- edit: src/http.rs -->
~~~rust
            continue;
        };
        socket.set_nodelay(true)?;
        let proxy = proxy.clone();
        tokio::spawn(async move {
~~~

Replace the selected lines with this block.

~~~rust
            continue;
        };
        if let Err(error) = socket.set_nodelay(true) {
            eprintln!("http socket: {error}");
            continue;
        }
        let proxy = proxy.clone();
        tokio::spawn(async move {
~~~

</details>

### Step 3 — Make reuse an assertion

Verify the complete response on every request and compare the upstream request count with the observed socket accepts.

<details>
<summary>Implementation</summary>

Find these regions in `lab/check.py` in order.

<!-- edit: lab/check.py -->
~~~python


if __name__ == "__main__":
    checks = {check.__name__: check for check in (routing,)}
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
~~~

Replace the selected lines with this block.

~~~python


def pool(port, a, _):
    for _ in range(12):
        assert request(port, "/a/item") == (200, b"a /a/item ", "a")
    assert a.hits == 12
    assert a.sockets < a.hits, f"pool: {a.sockets} sockets for {a.hits} requests"
    print(f"pool: {a.sockets} upstream socket for {a.hits} serial requests")


if __name__ == "__main__":
    checks = {check.__name__: check for check in (routing, pool,)}
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
~~~

</details>

## Check it

~~~bash
cargo build --locked --target-dir target
python3 lab/check.py target/debug/switchyard-edge pool
~~~

<!-- run: cargo build --locked --target-dir target && python3 lab/check.py target/debug/switchyard-edge pool -->

The reference origin accepted one upstream socket for 12 serial requests. The gate in lesson 07 repeats the fixture with reuse disabled and observes 12 sockets. [Gate transcript](../evidence/gate.txt)

## If it goes wrong

If the two counts are equal, check that the client is shared across requests, that the upstream stays open after a response, and that the whole body was consumed.

Continue to [Put a deadline and a limit on upstream work](04-bound-upstream-work.md).
