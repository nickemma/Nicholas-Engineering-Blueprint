# Build a Rust job-status service

After [Rust for systems](../../../2-core/05-rust-for-systems/README.md) and [Docker and Postgres](../../../2-core/03-docker-and-postgres/README.md), build a small standalone service for a jobs dashboard. Create and complete a job over REST, look it up over gRPC, and observe its current status over a WebSocket. You need Rust 1.94.1 or later, `protoc` and, for the final step, Docker with Compose.

## 1. Define the shared model and storage boundary

A job has a generated ID, a bounded title and a completion flag. HTTP and gRPC delegate to the same `Jobs` object. The in-memory mode lets tests control the state. The PostgreSQL mode persists it across processes. The startup transaction uses an advisory lock to serialize table creation by two fresh replicas. Each process uses one database connection for this lab.

Create `Cargo.toml`.

<!-- file: Cargo.toml -->
~~~~toml
[package]
name = "job-status"
version = "0.1.0"
edition = "2024"

[dependencies]
axum = { version = "0.8", features = ["ws"] }
prost = "0.14"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["macros", "net", "rt-multi-thread", "signal", "sync", "time"] }
tokio-postgres = "0.7"
tokio-stream = { version = "0.1", features = ["net"] }
tonic = "0.14"
tonic-prost = "0.14"
tower-http = { version = "0.6", features = ["trace"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
utoipa = { version = "5", features = ["axum_extras"] }
utoipa-axum = "0.2"

[build-dependencies]
tonic-prost-build = "0.14"

[dev-dependencies]
reqwest = { version = "0.12", default-features = false, features = ["json"] }
tokio-tungstenite = "0.29"
futures-util = "0.3"
~~~~

Create `src/lib.rs`.

<!-- file: src/lib.rs -->
~~~~rust
pub mod grpc;
pub mod http;
pub mod jobs;
~~~~

Create `src/jobs.rs`.

<!-- file: src/jobs.rs -->
~~~~rust
use std::{collections::BTreeMap, sync::Arc, time::Duration};

use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;
use tokio_postgres::{Client, NoTls, Row};
use utoipa::ToSchema;

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize, ToSchema)]
pub struct Job {
    pub id: i64,
    pub title: String,
    pub done: bool,
}

#[derive(Debug, PartialEq)]
pub enum Error {
    Invalid,
    Missing,
    Unavailable,
}

#[derive(Clone, Default)]
pub struct Jobs {
    store: Store,
}

#[derive(Clone)]
enum Store {
    Memory(Arc<Mutex<BTreeMap<i64, Job>>>),
    Postgres(Arc<Client>),
}

impl Default for Store {
    fn default() -> Self {
        Self::Memory(Arc::new(Mutex::new(BTreeMap::new())))
    }
}

impl Jobs {
    pub async fn postgres(url: &str) -> Result<Self, Error> {
        let (client, connection) = database(tokio_postgres::connect(url, NoTls)).await?;
        tokio::spawn(async move {
            if connection.await.is_err() {
                tracing::error!("database connection closed with an error");
            }
        });
        database(client.batch_execute(
            "BEGIN;
             SELECT pg_advisory_xact_lock(40217);
             CREATE TABLE IF NOT EXISTS jobs (
                id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                title text NOT NULL,
                done boolean NOT NULL DEFAULT false
            );
            COMMIT;",
        ))
        .await?;
        Ok(Self {
            store: Store::Postgres(Arc::new(client)),
        })
    }

    pub async fn ready(&self) -> Result<(), Error> {
        if let Store::Postgres(client) = &self.store {
            database(client.simple_query("SELECT 1")).await?;
        }
        Ok(())
    }

    #[tracing::instrument(skip_all)]
    pub async fn create(&self, title: &str) -> Result<Job, Error> {
        let title = title.trim();
        if title.is_empty() || title.chars().count() > 120 {
            return Err(Error::Invalid);
        }
        match &self.store {
            Store::Memory(jobs) => {
                let mut jobs = jobs.lock().await;
                let id = jobs.last_key_value().map_or(1, |(&id, _)| id + 1);
                let job = Job {
                    id,
                    title: title.into(),
                    done: false,
                };
                jobs.insert(id, job.clone());
                Ok(job)
            }
            Store::Postgres(client) => database(client.query_one(
                "INSERT INTO jobs (title) VALUES ($1) RETURNING id, title, done",
                &[&title],
            ))
            .await
            .map(read_job),
        }
    }

    #[tracing::instrument(skip(self))]
    pub async fn lookup(&self, id: i64) -> Result<Job, Error> {
        if id < 1 {
            return Err(Error::Invalid);
        }
        match &self.store {
            Store::Memory(jobs) => jobs.lock().await.get(&id).cloned().ok_or(Error::Missing),
            Store::Postgres(client) => {
                database(client.query_opt("SELECT id, title, done FROM jobs WHERE id = $1", &[&id]))
                    .await?
                    .map(read_job)
                    .ok_or(Error::Missing)
            }
        }
    }

    #[tracing::instrument(skip(self))]
    pub async fn complete(&self, id: i64) -> Result<Job, Error> {
        if id < 1 {
            return Err(Error::Invalid);
        }
        match &self.store {
            Store::Memory(jobs) => {
                let mut jobs = jobs.lock().await;
                let job = jobs.get_mut(&id).ok_or(Error::Missing)?;
                job.done = true;
                Ok(job.clone())
            }
            Store::Postgres(client) => database(client.query_opt(
                "UPDATE jobs SET done = true WHERE id = $1 RETURNING id, title, done",
                &[&id],
            ))
            .await?
            .map(read_job)
            .ok_or(Error::Missing),
        }
    }
}

async fn database<T>(
    operation: impl Future<Output = Result<T, tokio_postgres::Error>>,
) -> Result<T, Error> {
    match tokio::time::timeout(Duration::from_secs(2), operation).await {
        Ok(Ok(value)) => Ok(value),
        _ => Err(Error::Unavailable),
    }
}

fn read_job(row: Row) -> Job {
    Job {
        id: row.get("id"),
        title: row.get("title"),
        done: row.get("done"),
    }
}
~~~~

## 2. Generate the gRPC service

Define the Protocol Buffers contract first. `build.rs` runs the generator through Cargo. The adapter translates one domain lookup into a gRPC response and maps each domain error to a gRPC status. This lets a typed service client read the job written by a REST client. [Tonic code generation](https://docs.rs/tonic-build/latest/tonic_build/)

Create `proto/jobs.proto`.

<!-- file: proto/jobs.proto -->
~~~~protobuf
syntax = "proto3";

package jobs;

service JobStatus {
  rpc Lookup (LookupRequest) returns (JobReply);
}

message LookupRequest {
  int64 id = 1;
}

message JobReply {
  int64 id = 1;
  string title = 2;
  bool done = 3;
}
~~~~

Create `build.rs`.

<!-- file: build.rs -->
~~~~rust
fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-changed=proto/jobs.proto");
    tonic_prost_build::compile_protos("proto/jobs.proto")?;
    Ok(())
}
~~~~

Create `src/grpc.rs`.

<!-- file: src/grpc.rs -->
~~~~rust
use tonic::{Request, Response, Status};

use crate::jobs::{Error, Jobs};

tonic::include_proto!("jobs");

pub struct Lookup(pub Jobs);

#[tonic::async_trait]
impl job_status_server::JobStatus for Lookup {
    #[tracing::instrument(skip_all)]
    async fn lookup(&self, request: Request<LookupRequest>) -> Result<Response<JobReply>, Status> {
        let job = self
            .0
            .lookup(request.into_inner().id)
            .await
            .map_err(|error| match error {
                Error::Invalid => Status::invalid_argument("invalid job id"),
                Error::Missing => Status::not_found("job not found"),
                Error::Unavailable => Status::unavailable("storage unavailable"),
            })?;
        Ok(Response::new(JobReply {
            id: job.id,
            title: job.title,
            done: job.done,
        }))
    }
}
~~~~

## 3. Serve REST, OpenAPI and WebSockets

Keep route registration and its generated OpenAPI operation together. The JSON body limit protects the application before domain validation. The HTTP tracing layer creates a request span, and the instrumented storage call appears under that span.

A WebSocket subscriber receives the current row and then changes to that row. Each process admits eight subscribers. The subscriber polls the shared store, so a replica can see a completion written through another replica. A single snapshot in flight, a write buffer limit, and send and session deadlines bound the work. The stream is a view of current state. A durable event log would be needed to replay every intermediate change.

Create `src/http.rs`.

<!-- file: src/http.rs -->
~~~~rust
use std::{sync::Arc, time::Duration};

use axum::{
    Json, Router,
    extract::{
        DefaultBodyLimit, Path, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
};
use serde::{Deserialize, Serialize};
use tokio::sync::Semaphore;
use tower_http::trace::TraceLayer;
use utoipa::ToSchema;
use utoipa_axum::{router::OpenApiRouter, routes};

use crate::jobs::{Error, Job, Jobs};

#[derive(Clone)]
struct App {
    jobs: Jobs,
    subscriptions: Arc<Semaphore>,
}

#[derive(Deserialize, ToSchema)]
struct NewJob {
    #[schema(min_length = 1, max_length = 120)]
    title: String,
}

#[derive(Serialize, ToSchema)]
struct Problem {
    error: &'static str,
}

impl IntoResponse for Error {
    fn into_response(self) -> Response {
        let (status, error) = match self {
            Self::Invalid => (StatusCode::BAD_REQUEST, "invalid job"),
            Self::Missing => (StatusCode::NOT_FOUND, "job not found"),
            Self::Unavailable => (StatusCode::SERVICE_UNAVAILABLE, "storage unavailable"),
        };
        (status, Json(Problem { error })).into_response()
    }
}

pub fn router(jobs: Jobs) -> Router {
    let state = App {
        jobs,
        subscriptions: Arc::new(Semaphore::new(8)),
    };
    let (app, contract) = OpenApiRouter::new()
        .routes(routes!(create))
        .routes(routes!(lookup))
        .routes(routes!(complete))
        .split_for_parts();
    app.route("/openapi.json", get(move || async { Json(contract) }))
        .route("/ready", get(ready))
        .route("/jobs/{id}/watch", get(watch))
        .with_state(state)
        .layer(DefaultBodyLimit::max(1024))
        .layer(TraceLayer::new_for_http())
}

#[utoipa::path(post, path = "/jobs", request_body = NewJob,
    responses((status = 201, body = Job), (status = 400, body = Problem),
        (status = 413, description = "Body too large"),
        (status = 415, description = "Content type is not JSON"),
        (status = 422, description = "JSON does not match request schema"),
        (status = 503, body = Problem)))]
async fn create(
    State(app): State<App>,
    Json(input): Json<NewJob>,
) -> Result<(StatusCode, Json<Job>), Error> {
    Ok((
        StatusCode::CREATED,
        Json(app.jobs.create(&input.title).await?),
    ))
}

#[utoipa::path(get, path = "/jobs/{id}", params(("id" = i64, Path)),
    responses((status = 200, body = Job), (status = 400, body = Problem),
        (status = 404, body = Problem), (status = 503, body = Problem)))]
async fn lookup(State(app): State<App>, Path(id): Path<i64>) -> Result<Json<Job>, Error> {
    Ok(Json(app.jobs.lookup(id).await?))
}

#[utoipa::path(put, path = "/jobs/{id}/done", params(("id" = i64, Path)),
    responses((status = 200, body = Job), (status = 400, body = Problem),
        (status = 404, body = Problem), (status = 503, body = Problem)))]
async fn complete(State(app): State<App>, Path(id): Path<i64>) -> Result<Json<Job>, Error> {
    Ok(Json(app.jobs.complete(id).await?))
}

async fn ready(State(app): State<App>) -> Result<StatusCode, Error> {
    app.jobs.ready().await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn watch(
    State(app): State<App>,
    Path(id): Path<i64>,
    upgrade: WebSocketUpgrade,
) -> Result<Response, Error> {
    let permit = match app.subscriptions.try_acquire_owned() {
        Ok(permit) => permit,
        Err(_) => {
            return Ok((StatusCode::SERVICE_UNAVAILABLE, "subscription limit").into_response());
        }
    };
    let first = app.jobs.lookup(id).await?;
    Ok(upgrade
        .max_message_size(1024)
        .max_frame_size(1024)
        .write_buffer_size(0)
        .max_write_buffer_size(64 * 1024)
        .on_upgrade(move |socket| async move {
            let _permit = permit;
            let _ = tokio::time::timeout(Duration::from_secs(30), stream(app.jobs, first, socket))
                .await;
        }))
}

async fn stream(jobs: Jobs, first: Job, mut socket: WebSocket) {
    let mut previous = first;
    if !send(&mut socket, &previous).await {
        return;
    }
    let mut tick = tokio::time::interval(Duration::from_millis(200));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            incoming = socket.recv() => {
                if !matches!(incoming, Some(Ok(Message::Ping(_) | Message::Pong(_)))) {
                    return;
                }
            }
            _ = tick.tick() => {
                let Ok(current) = jobs.lookup(previous.id).await else { return; };
                if current != previous {
                    if !send(&mut socket, &current).await {
                        return;
                    }
                    previous = current;
                }
            }
        }
    }
}

async fn send(socket: &mut WebSocket, job: &Job) -> bool {
    let Ok(body) = serde_json::to_string(job) else {
        return false;
    };
    matches!(
        tokio::time::timeout(
            Duration::from_secs(1),
            socket.send(Message::Text(body.into()))
        )
        .await,
        Ok(Ok(()))
    )
}
~~~~

## 4. Configure the process and prove the client contract

Keep listener addresses and the storage implementation in startup configuration. The lab refuses an unknown storage mode and a missing or unreachable PostgreSQL connection before opening listeners. HTTP and gRPC receive the same shutdown signal. Each uses a separate listener in this build.

Create `src/main.rs`.

<!-- file: src/main.rs -->
~~~~rust
use std::{env, error::Error, io, net::SocketAddr};

use job_status::{
    grpc::{Lookup, job_status_server::JobStatusServer},
    http,
    jobs::Jobs,
};
use tokio::{
    net::TcpListener,
    signal::unix::{SignalKind, signal},
    sync::watch,
};
use tokio_stream::wrappers::TcpListenerStream;

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    tracing_subscriber::fmt()
        .with_span_events(tracing_subscriber::fmt::format::FmtSpan::CLOSE)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "job_status=info,tower_http=debug".into()),
        )
        .init();

    let http_address = address("HTTP_ADDR", "127.0.0.1:8080")?;
    let grpc_address = address("GRPC_ADDR", "127.0.0.1:50051")?;
    let jobs = match env::var("STORE").as_deref() {
        Ok("memory") => Jobs::default(),
        Ok("postgres") => {
            let url = env::var("DATABASE_URL")
                .map_err(|_| io::Error::other("DATABASE_URL is required"))?;
            Jobs::postgres(&url)
                .await
                .map_err(|_| io::Error::other("database unavailable at startup"))?
        }
        _ => return Err(io::Error::other("STORE must be memory or postgres").into()),
    };
    let http_listener = TcpListener::bind(http_address).await?;
    let grpc_listener = TcpListener::bind(grpc_address).await?;
    tracing::info!(http = %http_listener.local_addr()?, grpc = %grpc_listener.local_addr()?, "listening");

    let (stop, stopped) = watch::channel(false);
    let signal_task = tokio::spawn(async move {
        let mut terminate = signal(SignalKind::terminate())?;
        tokio::select! {
            _ = terminate.recv() => {},
            result = tokio::signal::ctrl_c() => result?,
        }
        let _ = stop.send(true);
        Ok::<(), io::Error>(())
    });
    let http = axum::serve(http_listener, http::router(jobs.clone()))
        .with_graceful_shutdown(wait_for_stop(stopped.clone()));
    let grpc = tonic::transport::Server::builder()
        .add_service(JobStatusServer::new(Lookup(jobs)))
        .serve_with_incoming_shutdown(
            TcpListenerStream::new(grpc_listener),
            wait_for_stop(stopped),
        );
    tokio::try_join!(async { http.await.map_err(io::Error::other) }, async {
        grpc.await.map_err(io::Error::other)
    },)?;
    signal_task.abort();
    Ok(())
}

fn address(key: &str, default: &str) -> Result<SocketAddr, io::Error> {
    env::var(key)
        .unwrap_or_else(|_| default.into())
        .parse()
        .map_err(|_| io::Error::other(format!("{key} must be a socket address")))
}

async fn wait_for_stop(mut stopped: watch::Receiver<bool>) {
    let _ = stopped.wait_for(|value| *value).await;
}
~~~~

Create `tests/contract.rs`.

<!-- file: tests/contract.rs -->
~~~~rust
use std::time::Duration;

use futures_util::StreamExt;
use job_status::{
    grpc::{
        Lookup, LookupRequest, job_status_client::JobStatusClient,
        job_status_server::JobStatusServer,
    },
    http,
    jobs::{Job, Jobs},
};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio_stream::wrappers::TcpListenerStream;

#[tokio::test]
async fn client_contract() {
    tokio::time::timeout(Duration::from_secs(10), check_clients())
        .await
        .expect("client contract timed out");
}

async fn check_clients() {
    let jobs = Jobs::default();
    let http_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let http_address = http_listener.local_addr().unwrap();
    let grpc_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let grpc_address = grpc_listener.local_addr().unwrap();

    let http_job = jobs.clone();
    let http_task = tokio::spawn(async move {
        axum::serve(http_listener, http::router(http_job))
            .await
            .unwrap();
    });
    let grpc_task = tokio::spawn(async move {
        tonic::transport::Server::builder()
            .add_service(JobStatusServer::new(Lookup(jobs)))
            .serve_with_incoming(TcpListenerStream::new(grpc_listener))
            .await
            .unwrap();
    });

    let http = reqwest::Client::new();
    let base = format!("http://{http_address}");
    let response = http
        .post(format!("{base}/jobs"))
        .json(&json!({"title": " "}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 400);
    let response = http
        .post(format!("{base}/jobs"))
        .json(&json!({"title": "index backlog"}))
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 201);
    let job: Job = response.json().await.unwrap();
    assert!(!job.done);

    let spec: Value = http
        .get(format!("{base}/openapi.json"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(
        spec["components"]["schemas"]["NewJob"]["required"],
        json!(["title"])
    );
    assert!(spec["paths"]["/jobs"]["post"]["responses"]["201"].is_object());
    assert!(spec["paths"]["/jobs/{id}"]["get"]["responses"]["404"].is_object());
    assert!(spec["paths"]["/jobs/{id}/done"]["put"]["responses"]["503"].is_object());

    let mut grpc = JobStatusClient::connect(format!("http://{grpc_address}"))
        .await
        .unwrap();
    let missing = grpc.lookup(LookupRequest { id: 99 }).await.unwrap_err();
    assert_eq!(missing.code(), tonic::Code::NotFound);

    let watch_url = format!("ws://{http_address}/jobs/{}/watch", job.id);
    let mut watchers = Vec::new();
    for _ in 0..8 {
        let (mut socket, _) = tokio_tungstenite::connect_async(&watch_url).await.unwrap();
        let first = socket.next().await.unwrap().unwrap().into_text().unwrap();
        assert_eq!(serde_json::from_str::<Job>(first.as_str()).unwrap(), job);
        watchers.push(socket);
    }
    let denied = tokio_tungstenite::connect_async(&watch_url).await;
    assert!(
        matches!(denied, Err(tokio_tungstenite::tungstenite::Error::Http(response)) if response.status() == 503)
    );

    let complete: Job = http
        .put(format!("{base}/jobs/{}/done", job.id))
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap()
        .json()
        .await
        .unwrap();
    let changed = watchers[0]
        .next()
        .await
        .unwrap()
        .unwrap()
        .into_text()
        .unwrap();
    assert!(complete.done);
    assert_eq!(
        serde_json::from_str::<Job>(changed.as_str()).unwrap(),
        complete
    );
    let reply = grpc
        .lookup(LookupRequest { id: job.id })
        .await
        .unwrap()
        .into_inner();
    assert_eq!(
        (reply.id, reply.title.as_str(), reply.done),
        (complete.id, complete.title.as_str(), true)
    );

    watchers.pop().unwrap().close(None).await.unwrap();
    let (mut replacement, _) = loop {
        if let Ok(connected) = tokio_tungstenite::connect_async(&watch_url).await {
            break connected;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    };
    let current = replacement
        .next()
        .await
        .unwrap()
        .unwrap()
        .into_text()
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Job>(current.as_str()).unwrap(),
        complete
    );
    http_task.abort();
    grpc_task.abort();
    println!("REST, OpenAPI, gRPC, and WebSocket agree; closed subscriber releases capacity");
}
~~~~

<!-- run: cargo generate-lockfile && cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings && cargo test --locked --test contract -- --nocapture -->
~~~~bash
cargo generate-lockfile && cargo fmt --check && cargo clippy --locked --all-targets -- -D warnings && cargo test --locked --test contract -- --nocapture
~~~~

The contract test uses real loopback connections. It looks for OpenAPI fields and responses, checks REST and gRPC status codes, observes a completion event, fills all eight subscription slots, and reconnects after releasing one. To see what the check detects, change the documented REST creation response from 201 to 200 without changing the handler. The test should fail on the missing OpenAPI entry. Restore the original response code before continuing.

~~~~text
REST, OpenAPI, gRPC, and WebSocket agree; closed subscriber releases capacity
~~~~

To inspect tracing by hand, run `STORE=memory cargo run` and submit a job with `curl -fsS -H 'Content-Type: application/json' -d '{"title":"trace me"}' http://127.0.0.1:8080/jobs`. Look for the HTTP request and the nested `create` span in the terminal.

## 5. Deploy to a disposable Compose environment

Reuse the executable built from the same Cargo project. Compose starts the database, waits for its health check, and starts the API with cluster-local database credentials. The HTTP and gRPC ports are published on loopback. The script owns its Compose project and data volume, and cleans those up when it exits.

Create `.dockerignore`.

<!-- file: .dockerignore -->
~~~~text
target
~~~~

Create `Dockerfile`.

<!-- file: Dockerfile -->
~~~~dockerfile
FROM rust:1.94.1-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Cargo.toml Cargo.lock build.rs ./
COPY proto proto
COPY src src
RUN cargo build --release --locked

FROM debian:bookworm-slim
COPY --from=build /build/target/release/job-status /usr/local/bin/job-status
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/job-status"]
~~~~

Create `compose.yaml`.

<!-- file: compose.yaml -->
~~~~yaml
services:
  db:
    image: postgres:17-alpine
    environment:
      POSTGRES_DB: lab
      POSTGRES_USER: lab
      POSTGRES_PASSWORD: lab-only
    volumes:
      - jobs:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U lab -d lab"]
      interval: 1s
      timeout: 2s
      retries: 20
  api:
    image: job-status:lab
    build: .
    environment:
      STORE: postgres
      DATABASE_URL: postgres://lab:lab-only@db/lab
      HTTP_ADDR: 0.0.0.0:8080
      GRPC_ADDR: 0.0.0.0:50051
      RUST_LOG: job_status=debug,tower_http=debug
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "127.0.0.1::8080"
      - "127.0.0.1::50051"
volumes:
  jobs:
~~~~

Create `check-compose.sh`.

<!-- file: check-compose.sh -->
~~~~bash
#!/usr/bin/env bash
set -euo pipefail

project="job-status-lab-$RANDOM-$$"
compose() { docker compose -p "$project" "$@"; }
cleanup() { compose down --volumes >/dev/null; }
trap cleanup EXIT

url() { printf 'http://%s' "$(compose port --index "$1" api 8080)"; }
wait_ready() {
  local endpoint="$1"
  for _ in {1..40}; do
    if curl --silent --fail --max-time 1 "$endpoint/ready" >/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  compose logs api >&2
  return 1
}

compose up -d --build
first="$(url 1)"
wait_ready "$first"
job="$(curl -fsS --max-time 3 -H 'Content-Type: application/json' \
  -d '{"title":"retained job"}' "$first/jobs")"
id="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$job")"

compose restart api
first="$(url 1)"
wait_ready "$first"
test "$(curl -fsS --max-time 3 "$first/jobs/$id")" = "$job"
echo "job $id survived API process restart"

compose up -d --no-build --scale api=2
second="$(url 2)"
wait_ready "$second"
test "$(curl -fsS --max-time 3 "$second/jobs/$id")" = "$job"
completed="$(curl -fsS --max-time 3 -X PUT "$second/jobs/$id/done")"
test "$(curl -fsS --max-time 3 "$first/jobs/$id")" = "$completed"
echo "both replicas read the same database and observe the update"

compose stop db
status="$(curl --silent --max-time 4 --output /dev/null --write-out '%{http_code}' "$first/jobs/$id")"
test "$status" = 503
echo "database stopped: REST surfaced 503"
~~~~

<!-- run: bash -n check-compose.sh -->
~~~~bash
bash -n check-compose.sh
~~~~

~~~~bash
bash check-compose.sh
~~~~

The live check first restarts the service, then scales it to two processes, then stops PostgreSQL. Follow the same job ID through the captured run.

~~~~text
job 1 survived API process restart
both replicas read the same database and observe the update
database stopped: REST surfaced 503
~~~~

To measure capacity, hold the load fixed with [the Core 02 load generator](../../../2-core/02-python-runtime-and-honest-measurement/README.md). Use the same read mix for one and two replicas, distribute the requests across both published ports and report completed requests, errors and p99. If PostgreSQL saturates, more API replicas may add connections without raising the completed rate.
