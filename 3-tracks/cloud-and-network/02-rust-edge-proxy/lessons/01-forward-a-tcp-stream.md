# 01 Forward a TCP stream

> A Rust edge proxy · Week 1 · Builds on lesson 00

## The problem

A client can finish writing a request while it is still waiting to read a response. A relay that drops both sockets at the first EOF loses that response.

## The mental model

A TCP connection has two byte streams. Track what each peer can still read and write after the client sends FIN. The upstream in this lab waits for EOF before it replies.

## The pattern

Use bidirectional copying with a write shutdown in each direction after that direction reaches EOF. Bound the active relays, the upstream connect, and the lifetime of the copy. Keep the upstream address fixed by the operator.

## Build it

### Step 1 — Predict the bytes and EOFs

Draw the two TCP connections. Mark the first FIN and the direction in which the response still has to travel.

<details>
<summary>Hint</summary>

The client closes its write half and leaves its read half open.

</details>

### Step 2 — Build the relay and its loopback test

Keep the semaphore permit for the full relay. Use binary fixtures so the check compares exact bytes in both directions.

<details>
<summary>Hint</summary>

Have the origin read to EOF before sending the response. The test will then detect a relay that misses either half-close.

</details>

<details>
<summary>Implementation</summary>

Replace `src/lib.rs`.

<!-- file: src/lib.rs -->
~~~rust
//! The Switchyard edge proxy lab.
pub mod tcp;
~~~

Create `src/tcp.rs`.

<!-- file: src/tcp.rs -->
~~~rust
use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::copy_bidirectional;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Semaphore;
use tokio::time::timeout;

pub async fn serve(listener: TcpListener, upstream: SocketAddr) -> io::Result<()> {
    let slots = Arc::new(Semaphore::new(128));
    loop {
        let (stream, _) = listener.accept().await?;
        if let Ok(slot) = slots.clone().try_acquire_owned() {
            tokio::spawn(async move {
                let _slot = slot;
                if let Err(error) = relay(stream, upstream).await {
                    eprintln!("tcp relay: {error}");
                }
            });
        }
    }
}

async fn relay(mut downstream: TcpStream, upstream: SocketAddr) -> io::Result<()> {
    let mut upstream = timeout(Duration::from_secs(2), TcpStream::connect(upstream)).await??;
    timeout(
        Duration::from_secs(30),
        copy_bidirectional(&mut downstream, &mut upstream),
    )
    .await??;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn relays_bytes_after_client_half_close() -> io::Result<()> {
        let origin = TcpListener::bind("127.0.0.1:0").await?;
        let origin_address = origin.local_addr()?;
        let edge = TcpListener::bind("127.0.0.1:0").await?;
        let edge_address = edge.local_addr()?;
        let server = tokio::spawn(serve(edge, origin_address));
        timeout(Duration::from_secs(2), async {
            let mut client = TcpStream::connect(edge_address).await?;
            let (mut upstream, _) = origin.accept().await?;
            client.write_all(b"\x00request\xff").await?;
            client.shutdown().await?;
            let mut request = Vec::new();
            upstream.read_to_end(&mut request).await?;
            assert_eq!(request, b"\x00request\xff");

            upstream.write_all(b"\xffresponse\x00").await?;
            upstream.shutdown().await?;
            let mut response = Vec::new();
            client.read_to_end(&mut response).await?;
            assert_eq!(response, b"\xffresponse\x00");
            Ok::<(), io::Error>(())
        })
        .await??;
        server.abort();
        Ok(())
    }
}
~~~

</details>

### Step 3 — Add a TCP command

Bind the configured listener and print its actual bound address. Port zero lets the kernel choose a free port.

<details>
<summary>Implementation</summary>

Create `src/main.rs`.

<!-- file: src/main.rs -->
~~~rust
use std::net::SocketAddr;

use tokio::net::TcpListener;

#[tokio::main(worker_threads = 2)]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    match args.as_slice() {
        [mode, listen, upstream] if mode == "tcp" => {
            let address: SocketAddr = upstream.parse()?;
            let listener = TcpListener::bind(listen).await?;
            println!("listening {}", listener.local_addr()?);
            switchyard_edge::tcp::serve(listener, address).await?;
        }
        _ => return Err("usage: switchyard-edge tcp LISTEN UPSTREAM".into()),
    }
    Ok(())
}
~~~

</details>

## Check it

~~~bash
cargo test --locked relays_bytes_after_client_half_close
~~~

<!-- run: cargo test --locked relays_bytes_after_client_half_close -->

The reference run reports `test tcp::tests::relays_bytes_after_client_half_close ... ok`. [Gate transcript](../evidence/gate.txt)

## If it goes wrong

If the origin waits until the test deadline, trace EOF from the downstream read side to the upstream write side. If the client sees an empty response, inspect when the relay returns and both sockets drop.

Continue to [Route an HTTP request](02-route-an-http-request.md).
