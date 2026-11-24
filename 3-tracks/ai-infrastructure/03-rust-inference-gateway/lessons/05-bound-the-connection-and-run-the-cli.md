# 05 Bound the connection and run the CLI

> A Rust inference gateway · Week 2

## The problem

An upstream deadline only advances when code drives its future. A peer can leave a response unconsumed and keep its transport task alive.

## The mental model

~~~text
accept loop → connection permit → bounded HTTP/1 connection
                                     └─ bounded handler and body
~~~

## The pattern

Use a separate connection cap and header deadline. Serve one request per HTTP/1 connection and set an independent connection lifetime. The outer timer can drop the HTTP task and the pending body even when polling the response stalls. Immediate connection shedding protects the server. Inside HTTP, the gateway distinguishes admission and quota decisions.

## Build it

### Expose the connection runner

Include the HTTP/1 listener in the library so the fixture can test it.

Create or update `src/lib.rs` as shown.

<!-- file: src/lib.rs -->
~~~rust
pub mod backend;
pub mod gateway;
pub mod protocol;
pub mod quota;
pub mod server;
pub mod sse;
~~~

### Serve each connection inside a bound

Use Hyper for transport framing and Axum for request routing.

Create or update `src/server.rs` as shown.

<!-- file: src/server.rs -->
~~~rust
use std::{io, sync::Arc, time::Duration};

use axum::Router;
use hyper::server::conn::http1;
use hyper_util::{
    rt::{TokioIo, TokioTimer},
    service::TowerToHyperService,
};
use tokio::{net::TcpListener, sync::Semaphore, time::timeout};

pub async fn serve(listener: TcpListener, app: Router, lifetime: Duration) -> io::Result<()> {
    let connections = Arc::new(Semaphore::new(64));
    loop {
        let (socket, _) = listener.accept().await?;
        let Ok(permit) = connections.clone().try_acquire_owned() else {
            continue;
        };
        let service = TowerToHyperService::new(app.clone());
        tokio::spawn(async move {
            let _permit = permit;
            let mut http = http1::Builder::new();
            // One request per connection gives the whole connection a
            // wall-clock ceiling, including blocked downstream writes.
            http.keep_alive(false)
                .timer(TokioTimer::new())
                .header_read_timeout(Duration::from_secs(2))
                .max_buf_size(32 * 1024);
            let _ = timeout(
                lifetime,
                http.serve_connection(TokioIo::new(socket), service),
            )
            .await;
        });
    }
}
~~~

### Wire the local executable

Read addresses and credentials from operator configuration and stop at loopback.

Create or update `src/main.rs` as shown.

<!-- file: src/main.rs -->
~~~rust
use std::{env, net::SocketAddr, time::Duration};

use switchyard_inference::{
    gateway::{Gateway, Limits, routes},
    server::serve,
};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let backend: SocketAddr = env::var("GATEWAY_MODEL_ADDR")?.parse()?;
    let listen: SocketAddr = env::var("GATEWAY_LISTEN")
        .unwrap_or_else(|_| "127.0.0.1:8080".to_owned())
        .parse()?;
    if !listen.ip().is_loopback() {
        return Err("gateway must listen on loopback".into());
    }
    let alice = env::var("GATEWAY_A_TOKEN")?;
    let bob = env::var("GATEWAY_B_TOKEN")?;
    let limits = Limits::default();
    let app = routes(Gateway::new(backend, [&alice, &bob], limits)?);
    let listener = TcpListener::bind(listen).await?;
    eprintln!("listening on {}", listener.local_addr()?);
    serve(listener, app, limits.total + Duration::from_secs(3)).await?;
    Ok(())
}
~~~

## Check it

~~~bash
cargo check --locked --all-targets
~~~

<!-- run: cargo check --locked --all-targets -->

See the [manual run](../gate/README.md#run-the-cli-manually) to start the gateway and matching fixture. Token state and counters are kept in this process.
