# 02 Route an HTTP request

> A Rust edge proxy · Week 1 · Builds on lesson 01

## The problem

Two services share one listener. Each request needs to reach the right service with the same query and body the client sent.

## The mental model

Each proxy hop has its own HTTP connection. Use the first path segment for the route and carry the parsed path and query through to the fixed origin. Header fields scoped to one connection end at that hop. The origin authority comes from the configured socket address.

## The pattern

Let Hyper parse HTTP/1.1 on both sides. Start with pooling disabled and a small buffered profile. Limit the request and response buffers to 64 KiB and 256 KiB, respectively, and drop trailers when you collect the body. Set a header deadline and a body deadline so the fixture has bounded waits.

## Build it

### Step 1 — Define what travels upstream

Draw the request and response headers on each side. Predict which origin receives /a/item and whether two repeated query fields reach it in order.

<details>
<summary>Hint</summary>

Use the parsed path and query together when building the next URI.

</details>

### Step 2 — Build the HTTP listener and route

Keep the origin socket address in the routing table, strip fields scoped to a connection, and return a local status for an unmatched route or unsupported request target.

<details>
<summary>Hint</summary>

A connection header can name other fields that belong to the same hop. Remove them before forwarding.

</details>

<details>
<summary>Implementation</summary>

Replace `src/lib.rs`.

<!-- file: src/lib.rs -->
~~~rust
//! The Switchyard edge proxy lab.
pub mod http;
pub mod tcp;
~~~

Create `src/http.rs`.

<!-- file: src/http.rs -->
~~~rust
use std::convert::Infallible;
use std::io;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use http_body_util::{BodyExt, Full, LengthLimitError, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::header::{CONNECTION, HOST, HeaderMap, HeaderName, UPGRADE};
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode, Uri, server};
use hyper_util::client::legacy::{Client, connect::HttpConnector};
use hyper_util::rt::{TokioExecutor, TokioIo, TokioTimer};
use tokio::net::TcpListener;
use tokio::sync::Semaphore;
use tokio::time::timeout;

type Reply = Response<Full<Bytes>>;

struct Proxy {
    client: Client<HttpConnector, Full<Bytes>>,
    origins: [SocketAddr; 2],
}

pub async fn serve(listener: TcpListener, origins: [SocketAddr; 2]) -> io::Result<()> {
    let mut connector = HttpConnector::new();
    connector.set_connect_timeout(Some(Duration::from_secs(2)));
    let client = Client::builder(TokioExecutor::new())
        .pool_max_idle_per_host(0)
        .retry_canceled_requests(false)
        .build(connector);
    let proxy = Arc::new(Proxy { client, origins });
    let slots = Arc::new(Semaphore::new(256));
    loop {
        let (socket, _) = listener.accept().await?;
        let Ok(slot) = slots.clone().try_acquire_owned() else {
            continue;
        };
        socket.set_nodelay(true)?;
        let proxy = proxy.clone();
        tokio::spawn(async move {
            let _slot = slot;
            let service = service_fn(move |request| {
                let proxy = proxy.clone();
                async move { Ok::<_, Infallible>(proxy.forward(request).await) }
            });
            let _ = server::conn::http1::Builder::new()
                .timer(TokioTimer::new())
                .header_read_timeout(Duration::from_secs(5))
                .serve_connection(TokioIo::new(socket), service)
                .await;
        });
    }
}

impl Proxy {
    async fn forward(&self, request: Request<Incoming>) -> Reply {
        let (mut parts, incoming) = request.into_parts();
        if parts.method == Method::CONNECT
            || parts.uri.scheme().is_some()
            || parts.uri.authority().is_some()
            || parts.headers.contains_key(UPGRADE)
        {
            return reply(StatusCode::BAD_REQUEST, "unsupported request target");
        }

        let origin = match parts.uri.path().split('/').nth(1) {
            Some("a") => self.origins[0],
            Some("b") => self.origins[1],
            _ => return reply(StatusCode::NOT_FOUND, "no route"),
        };
        let target = parts
            .uri
            .path_and_query()
            .expect("matched origin-form path");
        parts.uri = Uri::builder()
            .scheme("http")
            .authority(origin.to_string())
            .path_and_query(target.as_str())
            .build()
            .expect("configured socket address and parsed request target");
        if !strip_connection_headers(&mut parts.headers) {
            return reply(StatusCode::BAD_REQUEST, "invalid connection header");
        }
        for name in [
            HOST.as_str(),
            "forwarded",
            "x-forwarded-for",
            "x-forwarded-host",
            "x-forwarded-proto",
            "x-forwarded-port",
        ] {
            parts.headers.remove(name);
        }

        let body = match timeout(
            Duration::from_secs(2),
            Limited::new(incoming, 64 * 1024).collect(),
        )
        .await
        {
            Ok(Ok(body)) => body.to_bytes(),
            Ok(Err(error)) if error.is::<LengthLimitError>() => {
                return reply(StatusCode::PAYLOAD_TOO_LARGE, "request body too large");
            }
            Ok(Err(_)) => return reply(StatusCode::BAD_REQUEST, "incomplete request body"),
            Err(_) => return reply(StatusCode::REQUEST_TIMEOUT, "request body timed out"),
        };
        let request = Request::from_parts(parts, Full::new(body));

        match timeout(Duration::from_secs(2), self.exchange(request)).await {
            Ok(Ok(response)) => response,
            Ok(Err(status)) => reply(status, "upstream response failed"),
            Err(_) => reply(StatusCode::GATEWAY_TIMEOUT, "upstream timed out"),
        }
    }

    async fn exchange(&self, request: Request<Full<Bytes>>) -> Result<Reply, StatusCode> {
        let response = self
            .client
            .request(request)
            .await
            .map_err(|_| StatusCode::BAD_GATEWAY)?;
        let (mut parts, body) = response.into_parts();
        if !strip_connection_headers(&mut parts.headers) {
            return Err(StatusCode::BAD_GATEWAY);
        }
        let body = Limited::new(body, 256 * 1024)
            .collect()
            .await
            .map_err(|_| StatusCode::BAD_GATEWAY)?;
        Ok(Response::from_parts(parts, Full::new(body.to_bytes())))
    }
}

fn strip_connection_headers(headers: &mut HeaderMap) -> bool {
    let mut named = Vec::new();
    for value in headers.get_all(CONNECTION) {
        let Ok(value) = value.to_str() else {
            return false;
        };
        for name in value
            .split(',')
            .map(str::trim)
            .filter(|name| !name.is_empty())
        {
            let Ok(name) = HeaderName::from_bytes(name.as_bytes()) else {
                return false;
            };
            named.push(name);
        }
    }
    for name in named {
        headers.remove(name);
    }
    for name in [
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ] {
        headers.remove(name);
    }
    true
}

fn reply(status: StatusCode, body: &'static str) -> Reply {
    Response::builder()
        .status(status)
        .body(Full::new(Bytes::from_static(body.as_bytes())))
        .expect("fixed response")
}
~~~

Find these regions in `src/main.rs` in order.

<!-- edit: src/main.rs -->
~~~rust
            switchyard_edge::tcp::serve(listener, address).await?;
        }
        _ => return Err("usage: switchyard-edge tcp LISTEN UPSTREAM".into()),
    }
    Ok(())
~~~

Replace the selected lines with this block.

~~~rust
            switchyard_edge::tcp::serve(listener, address).await?;
        }
        [mode, listen, first, second] if mode == "http" => {
            let origins = [first.parse()?, second.parse()?];
            let listener = TcpListener::bind(listen).await?;
            println!("listening {}", listener.local_addr()?);
            switchyard_edge::http::serve(listener, origins).await?;
        }
        _ => {
            return Err(
                "usage: switchyard-edge tcp LISTEN UPSTREAM | http LISTEN ORIGIN_A ORIGIN_B".into(),
            );
        }
    }
    Ok(())
~~~

</details>

### Step 3 — Observe both origins

Use two loopback servers and distinct origin labels. Ask the local fixture to check raw query spelling, repeated query fields, binary request bytes, and the oversized-body response.

<details>
<summary>Implementation</summary>

Create `lab/check.py`.

<!-- file: lab/check.py -->
~~~python
"""Loopback checks against the built edge executable."""
import argparse
from contextlib import contextmanager
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import select
import subprocess
import threading


class Origin(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128

    def __init__(self, name):
        super().__init__(("127.0.0.1", 0), Handler)
        self.name = name
        self.sockets = 0
        self.hits = 0
        self.active = 0
        self.peak = 0
        self.status = 200
        self.hold = False
        self.changed = threading.Condition()
        self.release = threading.Event()

    @property
    def address(self):
        host, port = self.server_address
        return f"{host}:{port}"

    def get_request(self):
        pair = super().get_request()
        with self.changed:
            self.sockets += 1
        return pair

    def wait_for_hits(self, count):
        with self.changed:
            assert self.changed.wait_for(lambda: self.hits >= count, timeout=3)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        origin = self.server
        size = int(self.headers.get("Content-Length", 0))
        incoming = self.rfile.read(size)
        with origin.changed:
            origin.hits += 1
            origin.active += 1
            origin.peak = max(origin.peak, origin.active)
            origin.changed.notify_all()
            status = origin.status
            hold = origin.hold
        try:
            if hold:
                origin.release.wait(5)
            body = f"{origin.name} {self.path} ".encode() + incoming
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Origin", origin.name)
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with origin.changed:
                origin.active -= 1

    do_POST = do_GET

    def log_message(self, *_):
        pass


@contextmanager
def cluster(binary):
    with Origin("a") as a, Origin("b") as b:
        threads = [
            threading.Thread(target=origin.serve_forever, kwargs={"poll_interval": 0.05})
            for origin in (a, b)
        ]
        for thread in threads:
            thread.start()
        try:
            with subprocess.Popen(
                [binary, "http", "127.0.0.1:0", a.address, b.address],
                stdout=subprocess.PIPE,
                text=True,
            ) as proxy:
                try:
                    assert select.select([proxy.stdout], [], [], 5)[0], "proxy startup timed out"
                    line = proxy.stdout.readline()
                    assert line.startswith("listening "), line
                    port = int(line.rstrip().rsplit(":", 1)[1])
                    yield port, a, b
                finally:
                    proxy.terminate()
                    try:
                        proxy.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        proxy.kill()
                        proxy.wait()
        finally:
            for origin in (a, b):
                origin.release.set()
                origin.shutdown()
            for thread in threads:
                thread.join()


def request(port, path, body=None):
    connection = HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request("POST" if body is not None else "GET", path, body)
        response = connection.getresponse()
        assert response.version == 11
        return response.status, response.read(), response.getheader("X-Origin")
    finally:
        connection.close()


def routing(port, a, b):
    path = "/a/item?raw=%2f&item=1&item=2"
    assert request(port, path, b"\x00abc") == (200, b"a " + path.encode() + b" \x00abc", "a")
    assert request(port, "/b/item") == (200, b"b /b/item ", "b")
    assert request(port, "/abc/item")[0] == 404
    assert request(port, "/a/item", b"x" * (64 * 1024 + 1))[0] == 413
    assert (a.hits, b.hits) == (1, 1)
    print("routing: HTTP/1.1, exact query and bytes, separate origins, 404 and 413")


if __name__ == "__main__":
    checks = {check.__name__: check for check in (routing,)}
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("names", nargs="+", choices=list(checks))
    args = parser.parse_args()
    for name in args.names:
        with cluster(args.binary) as running:
            checks[name](*running)
~~~

</details>

## Check it

~~~bash
cargo build --locked --target-dir target
python3 lab/check.py target/debug/switchyard-edge routing
~~~

<!-- run: cargo build --locked --target-dir target && python3 lab/check.py target/debug/switchyard-edge routing -->

The routing check reports HTTP/1.1, exact query and bytes, separate origins, and local 404 and 413 responses. The two rejected requests leave the origin counts fixed. [Gate transcript](../evidence/gate.txt)

## If it goes wrong

If a path reaches the wrong origin, compare whole path segments. If the origin never finishes a request, check that the forwarded framing matches the buffered body and that the connection-specific fields ended at the proxy.

Continue to [Reuse upstream connections](03-reuse-upstream-connections.md).
