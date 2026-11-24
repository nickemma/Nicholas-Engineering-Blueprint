# 01 Push a versioned route snapshot

> The proxy’s control plane · Week 1 · Builds on lesson 00

## The problem

The controller may lose the response after the proxy applies an update. It needs to distinguish a retry from an attempt to overwrite the same generation with different content.

## The mental model

The generation orders updates. The SHA-256 digest identifies the canonical route mapping, encoded as the two decimal slot indices joined by a comma. Rust computes the digest again before it accepts the snapshot. Start with generation zero and route order 0,1.

## The pattern

Apply and acknowledge under the same lock. A repeated generation and identical content returns the current snapshot. A stale generation or conflicting digest leaves it intact. The Unix connection carries one bounded newline-delimited JSON command and one reply.

## Build it

### Step 1 — Define the state transitions

Predict the result of publishing generation 1 twice, conflicting with generation 1, then rolling back at generation 2.

<details>
<summary>Hint</summary>

Reserve separate outcomes for duplicate, stale, and conflicting generations.

</details>

### Step 2 — Add managed mode to the data plane

Keep one immutable selected origin per HTTP request. Bind the Unix listener inside a private directory and check the digest before replacing the active mapping.

<details>
<summary>Implementation</summary>

Find these regions in `Cargo.toml` in order.

<!-- edit: Cargo.toml -->
~~~toml
hyper-util = { version = "0.1.21", features = ["client-legacy", "http1", "tokio"] }
http-body-util = "0.1.5"
~~~

Replace the selected lines with this block.

~~~toml
hyper-util = { version = "0.1.21", features = ["client-legacy", "http1", "tokio"] }
http-body-util = "0.1.5"
serde = { version = "1.0.229", features = ["derive"] }
serde_json = "1.0.154"
sha2 = "0.10.9"
~~~

Find these regions in `Cargo.lock` in order.

<!-- edit: Cargo.lock -->
~~~toml

[[package]]
name = "bytes"
version = "1.12.2"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "776dfebd015e2d8732c684a2c71003674ccb49457b539b9e82151ba38e96dd7c"

[[package]]
~~~

Replace the selected lines with this block.

~~~toml

[[package]]
name = "block-buffer"
version = "0.10.4"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "3078c7629b62d3f0439517fa394996acacc5cbc91c5a20d8c658e77abd503a71"
dependencies = [
 "generic-array",
]

[[package]]
name = "bytes"
version = "1.12.2"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "776dfebd015e2d8732c684a2c71003674ccb49457b539b9e82151ba38e96dd7c"

[[package]]
name = "cfg-if"
version = "1.0.5"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "4e7648175b45a9a48536d676f68d918270699102aa8dab5496df06904c914600"

[[package]]
name = "cpufeatures"
version = "0.2.17"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "59ed5838eebb26a2bb2e58f6d5b5316989ae9d08bab10e0e6d103e656d1b0280"
dependencies = [
 "libc",
]

[[package]]
name = "crypto-common"
version = "0.1.7"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "78c8292055d1c1df0cce5d180393dc8cce0abec0a7102adb6c7b1eef6016d60a"
dependencies = [
 "generic-array",
 "typenum",
]

[[package]]
name = "digest"
version = "0.10.7"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "9ed9a281f7bc9b7576e61468ba615a66a5c8cfdff42420a70aa82701a3b1e292"
dependencies = [
 "block-buffer",
 "crypto-common",
]

[[package]]
~~~

<!-- edit: Cargo.lock -->
~~~toml
 "futures-task",
 "pin-project-lite",
]
~~~

Replace the selected lines with this block.

~~~toml
 "futures-task",
 "pin-project-lite",
]

[[package]]
name = "generic-array"
version = "0.14.7"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "85649ca51fd72272d7821adaf274ad91c288277713d9c18820d8499a7ff69e9a"
dependencies = [
 "typenum",
 "version_check",
]
~~~

<!-- edit: Cargo.lock -->
~~~toml

[[package]]
name = "mio"
version = "1.2.5"
~~~

Replace the selected lines with this block.

~~~toml

[[package]]
name = "memchr"
version = "2.8.3"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "cf8baf1c55e62ffcace7a9f06f4bd9cd3f0c4beb022d3b367256b91b87513d98"

[[package]]
name = "mio"
version = "1.2.5"
~~~

<!-- edit: Cargo.lock -->
~~~toml

[[package]]
name = "smallvec"
version = "1.16.6"
~~~

Replace the selected lines with this block.

~~~toml

[[package]]
name = "serde"
version = "1.0.229"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "4148590afebada386688f18773da617792bf2ef03ffc1e4cbd2b1d45b023e0ba"
dependencies = [
 "serde_core",
 "serde_derive",
]

[[package]]
name = "serde_core"
version = "1.0.229"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "67dca2c9c51e58a4791a4b1ed58308b39c64224d349a935ab5039aa360942a48"
dependencies = [
 "serde_derive",
]

[[package]]
name = "serde_derive"
version = "1.0.229"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "e7a5d71263a5a7d47b41f6b3f06ba276f10cc18b0931f1799f710578e2309348"
dependencies = [
 "proc-macro2",
 "quote",
 "syn",
]

[[package]]
name = "serde_json"
version = "1.0.154"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "e7e9cc8b1b85264074fbcc02a88680c4096b1e47df8f739dceb03bf482f04bd6"
dependencies = [
 "itoa",
 "memchr",
 "serde",
 "serde_core",
 "zmij",
]

[[package]]
name = "sha2"
version = "0.10.9"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "a7507d819769d01a365ab707794a4084392c824f54a7a6a7862f8c3d0892b283"
dependencies = [
 "cfg-if",
 "cpufeatures",
 "digest",
]

[[package]]
name = "smallvec"
version = "1.16.6"
~~~

<!-- edit: Cargo.lock -->
~~~toml
 "hyper",
 "hyper-util",
 "tokio",
]
~~~

Replace the selected lines with this block.

~~~toml
 "hyper",
 "hyper-util",
 "serde",
 "serde_json",
 "sha2",
 "tokio",
]
~~~

<!-- edit: Cargo.lock -->
~~~toml

[[package]]
name = "unicode-ident"
version = "1.0.27"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "a2c754d6c33795a1c324727428e5a7dedb5b06195f9890bdbcba760d3e246563"

[[package]]
~~~

Replace the selected lines with this block.

~~~toml

[[package]]
name = "typenum"
version = "1.20.1"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "b6f5e870be6c3b371b77fe0ee0bafb859fa4964b4404c27de1d380043c4dda20"

[[package]]
name = "unicode-ident"
version = "1.0.27"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "a2c754d6c33795a1c324727428e5a7dedb5b06195f9890bdbcba760d3e246563"

[[package]]
name = "version_check"
version = "0.9.5"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "0b928f33d975fc6ad9f86c8f283853ad26bdd5b10b7f1542aa2fa15e2289105a"

[[package]]
~~~

<!-- edit: Cargo.lock -->
~~~toml
 "windows-link",
]
~~~

Replace the selected lines with this block.

~~~toml
 "windows-link",
]

[[package]]
name = "zmij"
version = "1.0.23"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "29666d0abbfad1e3dc4dcf6144730dd3a3ab225bbbdac83319345b1b44ccfc1b"
~~~

Replace `src/lib.rs`.

<!-- file: src/lib.rs -->
~~~rust
//! The Switchyard edge proxy lab.
pub mod admin;
mod breaker;
pub mod http;
pub mod tcp;
~~~

Create `src/admin.rs`.

<!-- file: src/admin.rs -->
~~~rust
use std::io;
use std::path::Path;
use std::sync::{Arc, RwLock};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::time::timeout;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    generation: u64,
    order: [usize; 2],
    digest: String,
}

impl Snapshot {
    fn digest(order: [usize; 2]) -> String {
        format!("{:x}", Sha256::digest(format!("{},{}", order[0], order[1])))
    }
}

#[derive(Clone)]
pub struct Routes(Arc<RwLock<Snapshot>>);

impl Default for Routes {
    fn default() -> Self {
        Self(Arc::new(RwLock::new(Snapshot {
            generation: 0,
            order: [0, 1],
            digest: Snapshot::digest([0, 1]),
        })))
    }
}

impl Routes {
    pub(crate) fn origin_for(&self, route: usize) -> usize {
        self.0.read().expect("routes").order[route]
    }

    fn handle(&self, request: Command) -> Ack {
        let mut active = self.0.write().expect("routes");
        let result = match request {
            Command::Status => "current",
            Command::Apply { snapshot }
                if !matches!(snapshot.order, [0, 1] | [1, 0])
                    || snapshot.digest != Snapshot::digest(snapshot.order) =>
            {
                "invalid"
            }
            Command::Apply { snapshot } if snapshot.generation < active.generation => "stale",
            Command::Apply { snapshot } if snapshot.generation == active.generation => {
                if snapshot.digest == active.digest {
                    "unchanged"
                } else {
                    "conflict"
                }
            }
            Command::Apply { snapshot } => {
                *active = snapshot;
                "applied"
            }
        };
        Ack {
            result,
            snapshot: active.clone(),
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    Status,
    Apply { snapshot: Snapshot },
}

#[derive(Serialize)]
struct Ack {
    result: &'static str,
    snapshot: Snapshot,
}

pub async fn serve(path: &Path, routes: Routes) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("socket needs a directory"))?;
    if std::fs::metadata(parent)?.permissions().mode() & 0o077 != 0 {
        return Err(io::Error::other("socket directory must be private"));
    }
    let listener = UnixListener::bind(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    loop {
        let (stream, _) = listener.accept().await?;
        let _ = timeout(Duration::from_secs(1), exchange(stream, &routes)).await;
    }
}

async fn exchange(mut stream: UnixStream, routes: &Routes) -> io::Result<()> {
    let mut line = Vec::new();
    BufReader::new((&mut stream).take(2049))
        .read_until(b'\n', &mut line)
        .await?;
    if line.len() > 2048 || line.last() != Some(&b'\n') {
        return Err(io::Error::other("invalid admin frame"));
    }
    let command = serde_json::from_slice(&line)?;
    let mut response = serde_json::to_vec(&routes.handle(command))?;
    response.push(b'\n');
    stream.write_all(&response).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generations_and_digest() {
        let routes = Routes::default();
        let apply = |generation, order| {
            routes
                .handle(Command::Apply {
                    snapshot: Snapshot {
                        generation,
                        order,
                        digest: Snapshot::digest(order),
                    },
                })
                .result
        };
        assert_eq!(apply(1, [1, 1]), "invalid");
        assert_eq!(apply(1, [1, 0]), "applied");
        assert_eq!(routes.origin_for(0), 1);
        assert_eq!(apply(1, [1, 0]), "unchanged");
        assert_eq!(apply(1, [0, 1]), "conflict");
        assert_eq!(apply(0, [0, 1]), "stale");
        assert_eq!(routes.origin_for(0), 1);
        assert_eq!(apply(2, [0, 1]), "applied");
    }
}
~~~

Find these regions in `src/http.rs` in order.

<!-- edit: src/http.rs -->
~~~rust
use std::time::{Duration, Instant};

use crate::breaker::Breaker;
~~~

Replace the selected lines with this block.

~~~rust
use std::time::{Duration, Instant};

use crate::admin::Routes;
use crate::breaker::Breaker;
~~~

<!-- edit: src/http.rs -->
~~~rust
    client: Client<HttpConnector, Full<Bytes>>,
    origins: [Origin; 2],
}

pub async fn serve(listener: TcpListener, origins: [SocketAddr; 2]) -> io::Result<()> {
    if origins[0] == origins[1] {
        return Err(io::Error::new(
~~~

Replace the selected lines with this block.

~~~rust
    client: Client<HttpConnector, Full<Bytes>>,
    origins: [Origin; 2],
    routes: Routes,
}

pub async fn serve(listener: TcpListener, origins: [SocketAddr; 2]) -> io::Result<()> {
    serve_managed(listener, origins, Routes::default()).await
}

pub async fn serve_managed(
    listener: TcpListener,
    origins: [SocketAddr; 2],
    routes: Routes,
) -> io::Result<()> {
    if origins[0] == origins[1] {
        return Err(io::Error::new(
~~~

<!-- edit: src/http.rs -->
~~~rust
        client,
        origins: origins.map(Origin::new),
    });
    let slots = Arc::new(Semaphore::new(256));
~~~

Replace the selected lines with this block.

~~~rust
        client,
        origins: origins.map(Origin::new),
        routes,
    });
    let slots = Arc::new(Semaphore::new(256));
~~~

<!-- edit: src/http.rs -->
~~~rust

        let origin = match parts.uri.path().split('/').nth(1) {
            Some("a") => &self.origins[0],
            Some("b") => &self.origins[1],
            _ => return reply(StatusCode::NOT_FOUND, "no route"),
        };
~~~

Replace the selected lines with this block.

~~~rust

        let origin = match parts.uri.path().split('/').nth(1) {
            Some("a") => &self.origins[self.routes.origin_for(0)],
            Some("b") => &self.origins[self.routes.origin_for(1)],
            _ => return reply(StatusCode::NOT_FOUND, "no route"),
        };
~~~

Find these regions in `src/main.rs` in order.

<!-- edit: src/main.rs -->
~~~rust
use std::net::SocketAddr;

use tokio::net::TcpListener;
~~~

Replace the selected lines with this block.

~~~rust
use std::net::SocketAddr;
use std::path::Path;

use tokio::net::TcpListener;
~~~

<!-- edit: src/main.rs -->
~~~rust
            switchyard_edge::http::serve(listener, origins).await?;
        }
        _ => {
            return Err(
                "usage: switchyard-edge tcp LISTEN UPSTREAM | http LISTEN ORIGIN_A ORIGIN_B".into(),
            );
        }
~~~

Replace the selected lines with this block.

~~~rust
            switchyard_edge::http::serve(listener, origins).await?;
        }
        [mode, listen, first, second, socket] if mode == "managed" => {
            let listener = TcpListener::bind(listen).await?;
            let origins = [first.parse()?, second.parse()?];
            let routes = switchyard_edge::admin::Routes::default();
            println!("listening {}", listener.local_addr()?);
            tokio::try_join!(
                switchyard_edge::admin::serve(Path::new(socket), routes.clone()),
                switchyard_edge::http::serve_managed(listener, origins, routes)
            )?;
        }
        _ => {
            return Err(
                "usage: switchyard-edge tcp LISTEN UPSTREAM | http LISTEN ORIGIN_A ORIGIN_B | managed LISTEN ORIGIN_A ORIGIN_B SOCKET".into(),
            );
        }
~~~

</details>

### Step 3 — Send commands from Go

Use the same encoding and deadline on the other end of the socket. Construct the digest independently and cap acknowledgement size.

<details>
<summary>Implementation</summary>

Create `go.mod`.

<!-- file: go.mod -->
~~~go
module switchyard/edge

go 1.26
~~~

Create `control/wire.go`.

<!-- file: control/wire.go -->
~~~go
package control

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"time"
)

const maxFrame = 2048

type Snapshot struct {
	Generation uint64 `json:"generation"`
	Order      [2]int `json:"order"`
	Digest     string `json:"digest"`
}

func NewSnapshot(generation uint64, order [2]int) Snapshot {
	digest := sha256.Sum256(fmt.Appendf(nil, "%d,%d", order[0], order[1]))
	return Snapshot{generation, order, fmt.Sprintf("%x", digest)}
}

type Command struct {
	Op       string    `json:"op"`
	Snapshot *Snapshot `json:"snapshot,omitempty"`
}

type Ack struct {
	Result   string   `json:"result"`
	Snapshot Snapshot `json:"snapshot"`
}

type Send func(context.Context, Command) (Ack, error)

func Unix(socket string) Send {
	return func(ctx context.Context, command Command) (Ack, error) {
		ctx, cancel := context.WithTimeout(ctx, time.Second)
		defer cancel()
		conn, err := (&net.Dialer{}).DialContext(ctx, "unix", socket)
		if err != nil {
			return Ack{}, err
		}
		defer conn.Close()
		stop := context.AfterFunc(ctx, func() { conn.Close() })
		defer stop()
		if err := json.NewEncoder(conn).Encode(command); err != nil {
			return Ack{}, err
		}
		line, err := bufio.NewReaderSize(conn, maxFrame+1).ReadSlice('\n')
		if err != nil {
			return Ack{}, err
		}
		if len(line) > maxFrame {
			return Ack{}, errors.New("admin acknowledgement too large")
		}
		var ack Ack
		err = json.Unmarshal(line, &ack)
		return ack, err
	}
}
~~~

</details>

## Check it

~~~bash
cargo test --locked generations_and_digest
go test ./...
~~~

<!-- run: cargo test --locked generations_and_digest && go test ./... -->

The Rust state test accepted the first update and its idempotent retry, rejected stale and conflicting generations, and accepted rollback as a newer generation. [Portable gate capture](../evidence/portable.txt)

## If it goes wrong

For a digest mismatch, compare the exact bytes hashed in Go and Rust. For a bind failure, confirm the socket directory is private and the socket name is unused.

Continue to [Check origins and apply a route change](02-check-and-apply-a-route.md).
