# 04 Own admission through the response

> A Rust inference gateway · Week 2

## The problem

A handler can return headers while its most expensive work continues inside the response body. The upstream and admission slot still need an owner.

## The mental model

~~~text
authenticate → try one slot → read and validate → tokenize → reserve quota → model POST
                                                                  ↓
                                  response body owns permit + model body
~~~

## The pattern

Authenticate with generated local fixture credentials and reject immediately when all slots are busy. Use the configured model's `/apply-template` and `/tokenize` endpoints before reserving prompt and maximum output tokens. Bind the request to one operator-configured loopback model. Transfer the slot and response to the stream, which reads upstream as the HTTP transport polls it. The async stream drops both when the client disappears. [Serving lab admission](../../02-serving-and-scaling-models/lessons/04-put-an-admission-boundary-on-switchyard.md) · [Tokio permits](https://docs.rs/tokio/1.54.1/tokio/sync/struct.Semaphore.html)

Bound request bytes, tokenizer responses, upstream wire bytes, total request time, and the wait for the next validated event. Errors before headers get an HTTP status. Errors after headers terminate with an SSE error and leave out the success marker.

## Build it

### Expose the gateway components

Add the model client and the gateway orchestration.

Create or update `src/lib.rs` as shown.

<!-- file: src/lib.rs -->
~~~rust
pub mod backend;
pub mod gateway;
pub mod protocol;
pub mod quota;
pub mod sse;
~~~

### Call the model contract under a deadline

Use one HTTP client at a fixed loopback address and validate the response media type before forwarding.

Create or update `src/backend.rs` as shown.

<!-- file: src/backend.rs -->
~~~rust
use std::{net::SocketAddr, time::Duration};

use reqwest::{Client, Response, StatusCode, header, redirect::Policy};
use serde::{Deserialize, de::DeserializeOwned};
use serde_json::{Value, json};
use tokio::time::{Instant, timeout_at};

use crate::protocol::Request;

const MAX_TOKENIZER_RESPONSE: usize = 64 * 1024;

#[derive(Debug)]
pub enum Failure {
    Timeout,
    Unavailable,
}

pub struct Backend {
    client: Client,
    origin: String,
}

impl Backend {
    pub fn new(address: SocketAddr) -> Result<Self, &'static str> {
        if !address.ip().is_loopback() {
            return Err("model address must be loopback");
        }
        let client = Client::builder()
            .no_proxy()
            .redirect(Policy::none())
            .connect_timeout(Duration::from_secs(2))
            .build()
            .map_err(|_| "could not build model client")?;
        Ok(Self {
            client,
            origin: format!("http://{address}"),
        })
    }

    async fn post(&self, path: &str, body: Value, deadline: Instant) -> Result<Response, Failure> {
        let request = self
            .client
            .post(format!("{}{path}", self.origin))
            .json(&body);
        let response = timeout_at(deadline, request.send())
            .await
            .map_err(|_| Failure::Timeout)?
            .map_err(|err| {
                if err.is_timeout() {
                    Failure::Timeout
                } else {
                    Failure::Unavailable
                }
            })?;
        if response.status() != StatusCode::OK {
            return Err(Failure::Unavailable);
        }
        Ok(response)
    }

    async fn json<T: DeserializeOwned>(
        &self,
        path: &str,
        body: Value,
        deadline: Instant,
    ) -> Result<T, Failure> {
        let mut response = self.post(path, body, deadline).await?;
        let mut bytes = Vec::new();
        while let Some(chunk) = timeout_at(deadline, response.chunk())
            .await
            .map_err(|_| Failure::Timeout)?
            .map_err(|_| Failure::Unavailable)?
        {
            if chunk.len() > MAX_TOKENIZER_RESPONSE - bytes.len() {
                return Err(Failure::Unavailable);
            }
            bytes.extend_from_slice(&chunk);
        }
        serde_json::from_slice(&bytes).map_err(|_| Failure::Unavailable)
    }

    pub async fn tokens(&self, request: &Request, deadline: Instant) -> Result<u32, Failure> {
        #[derive(Deserialize)]
        struct Template {
            prompt: String,
        }
        #[derive(Deserialize)]
        struct Tokens {
            tokens: Vec<u32>,
        }

        let formatted: Template = self
            .json(
                "/apply-template",
                json!({"messages": request.messages, "add_generation_prompt": true}),
                deadline,
            )
            .await?;
        if formatted.prompt.is_empty() || formatted.prompt.len() > 32 * 1024 {
            return Err(Failure::Unavailable);
        }
        let tokenized: Tokens = self
            .json(
                "/tokenize",
                json!({"content": formatted.prompt, "add_special": true}),
                deadline,
            )
            .await?;
        u32::try_from(tokenized.tokens.len()).map_err(|_| Failure::Unavailable)
    }

    pub async fn chat(&self, request: &Request, deadline: Instant) -> Result<Response, Failure> {
        let response = self
            .post("/v1/chat/completions", request.upstream(), deadline)
            .await?;
        let media = response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|header| header.to_str().ok())
            .and_then(|value| value.split(';').next());
        if !media.is_some_and(|value| value.trim().eq_ignore_ascii_case("text/event-stream")) {
            return Err(Failure::Unavailable);
        }
        Ok(response)
    }
}
~~~

### Keep the slot in the streaming body

Return 503 for a busy slot, 429 for refillable quota exhaustion, and 422 when the request could never fit. Move the permit into a lease and count observed terminal states on drop.

Create or update `src/gateway.rs` as shown.

<!-- file: src/gateway.rs -->
~~~rust
use std::{
    convert::Infallible,
    net::SocketAddr,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering::Relaxed},
    },
    time::{Duration, Instant as Clock},
};

use async_stream::stream;
use axum::{
    Json, Router,
    body::{Body, Bytes, to_bytes},
    extract::{Request, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde_json::json;
use subtle::ConstantTimeEq;
use tokio::{
    sync::{OwnedSemaphorePermit, Semaphore},
    time::{Instant, timeout_at},
};

use crate::{
    backend::{Backend, Failure},
    protocol::{Completion, Delivered, MAX_CONTEXT, MAX_INPUT, Request as Chat},
    quota::{Bucket, Refusal},
    sse::Decoder,
};

const MAX_WIRE: usize = 256 * 1024;

#[derive(Clone, Copy)]
pub struct Limits {
    pub slots: usize,
    pub tokens: u32,
    pub tokens_per_second: u32,
    pub total: Duration,
    pub idle: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            slots: 2,
            tokens: 4096,
            tokens_per_second: 64,
            total: Duration::from_secs(20),
            idle: Duration::from_secs(4),
        }
    }
}

pub struct Gateway {
    backend: Backend,
    slots: Arc<Semaphore>,
    credentials: [[u8; 48]; 2],
    buckets: [Mutex<Bucket>; 2],
    limits: Limits,
    metrics: Metrics,
}

#[derive(Default)]
struct Metrics {
    transport_first: AtomicU64,
    content_first: AtomicU64,
    complete: AtomicU64,
    incomplete: AtomicU64,
    abandoned: AtomicU64,
}

enum Outcome {
    Complete,
    Timeout,
    Protocol,
    Truncated,
}

struct Lease {
    _permit: OwnedSemaphorePermit,
    gateway: Arc<Gateway>,
    outcome: Option<Outcome>,
}

impl Drop for Lease {
    fn drop(&mut self) {
        let meters = &self.gateway.metrics;
        match self.outcome {
            Some(Outcome::Complete) => &meters.complete,
            Some(_) => &meters.incomplete,
            None => &meters.abandoned,
        }
        .fetch_add(1, Relaxed);
    }
}

impl Gateway {
    pub fn new(
        address: SocketAddr,
        secrets: [&str; 2],
        limits: Limits,
    ) -> Result<Arc<Self>, &'static str> {
        if !(1..=64).contains(&limits.slots)
            || limits.idle.is_zero()
            || limits.idle > limits.total
            || limits.total > Duration::from_secs(60)
        {
            return Err("invalid stream limits");
        }
        let mut credentials = [[0; 48]; 2];
        for (saved, input) in credentials.iter_mut().zip(secrets) {
            if input.len() != saved.len() || !input.bytes().all(|byte| byte.is_ascii_hexdigit()) {
                return Err("set two 48-character hex lab credentials");
            }
            saved.copy_from_slice(input.as_bytes());
        }
        if credentials[0].ct_eq(&credentials[1]).into() {
            return Err("lab credentials must be distinct");
        }
        let now = Clock::now();
        let make_bucket =
            || Bucket::new(limits.tokens, limits.tokens_per_second, now).map(Mutex::new);
        Ok(Arc::new(Self {
            backend: Backend::new(address)?,
            slots: Arc::new(Semaphore::new(limits.slots)),
            credentials,
            buckets: [make_bucket()?, make_bucket()?],
            limits,
            metrics: Metrics::default(),
        }))
    }

    fn tenant(&self, headers: &HeaderMap) -> Option<usize> {
        let authorization = headers.get(header::AUTHORIZATION)?.to_str().ok()?;
        let (scheme, token) = authorization.split_once(' ')?;
        if !scheme.eq_ignore_ascii_case("Bearer") || token.len() != 48 {
            return None;
        }
        self.credentials
            .iter()
            .position(|key| bool::from(key.ct_eq(token.as_bytes())))
    }
}

pub fn routes(gateway: Arc<Gateway>) -> Router {
    Router::new()
        .route("/v1/chat/completions", post(chat))
        .route("/metrics", get(metrics))
        .with_state(gateway)
}

struct Reject(StatusCode, &'static str, Option<u64>);

impl IntoResponse for Reject {
    fn into_response(self) -> Response {
        let mut reply = (self.0, Json(json!({"error": self.1}))).into_response();
        if let Some(delay) = self.2 {
            reply
                .headers_mut()
                .insert(header::RETRY_AFTER, HeaderValue::from(delay));
        }
        if self.0 == StatusCode::UNAUTHORIZED {
            reply
                .headers_mut()
                .insert(header::WWW_AUTHENTICATE, HeaderValue::from_static("Bearer"));
        }
        reply
    }
}

impl From<Failure> for Reject {
    fn from(value: Failure) -> Self {
        match value {
            Failure::Timeout => Self(StatusCode::GATEWAY_TIMEOUT, "model deadline", None),
            Failure::Unavailable => Self(StatusCode::BAD_GATEWAY, "model unavailable", None),
        }
    }
}

async fn chat(State(gateway): State<Arc<Gateway>>, request: Request) -> Result<Response, Reject> {
    let deadline = Instant::now() + gateway.limits.total;
    let tenant = gateway.tenant(request.headers()).ok_or(Reject(
        StatusCode::UNAUTHORIZED,
        "authentication required",
        None,
    ))?;
    let permit = gateway.slots.clone().try_acquire_owned().map_err(|_| {
        Reject(
            StatusCode::SERVICE_UNAVAILABLE,
            "all generation slots busy",
            Some(1),
        )
    })?;
    let body = timeout_at(deadline, to_bytes(request.into_body(), MAX_INPUT))
        .await
        .map_err(|_| Reject(StatusCode::REQUEST_TIMEOUT, "request body deadline", None))?
        .map_err(|_| {
            Reject(
                StatusCode::BAD_REQUEST,
                "request body unreadable or too large",
                None,
            )
        })?;
    let chat: Chat = serde_json::from_slice(&body)
        .map_err(|_| Reject(StatusCode::BAD_REQUEST, "invalid chat input", None))?;
    if !chat.valid() {
        return Err(Reject(
            StatusCode::BAD_REQUEST,
            "invalid chat profile",
            None,
        ));
    }
    let prompt = gateway.backend.tokens(&chat, deadline).await?;
    let reserved = prompt
        .checked_add(chat.max_tokens)
        .filter(|total| prompt > 0 && *total <= MAX_CONTEXT)
        .ok_or(Reject(
            StatusCode::UNPROCESSABLE_ENTITY,
            "context limit",
            None,
        ))?;
    {
        let mut bucket = gateway.buckets[tenant]
            .lock()
            .map_err(|_| Reject(StatusCode::SERVICE_UNAVAILABLE, "quota unavailable", None))?;
        match bucket.reserve(reserved, Clock::now()) {
            Ok(()) => {}
            Err(Refusal::NeverFits) => {
                return Err(Reject(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "request exceeds token capacity",
                    None,
                ));
            }
            Err(Refusal::RetryAfter(delay)) => {
                let seconds = delay.as_secs() + u64::from(delay.subsec_nanos() > 0);
                return Err(Reject(
                    StatusCode::TOO_MANY_REQUESTS,
                    "token bucket exhausted",
                    Some(seconds.max(1)),
                ));
            }
        }
    }
    let upstream = gateway.backend.chat(&chat, deadline).await?;
    let idle = gateway.limits.idle;
    let lease = Lease {
        _permit: permit,
        gateway,
        outcome: None,
    };
    let body = relay(upstream, deadline, idle, prompt, chat.max_tokens, lease);
    Ok((
        [
            (header::CONTENT_TYPE, "text/event-stream"),
            (header::CACHE_CONTROL, "no-store"),
        ],
        body,
    )
        .into_response())
}

fn relay(
    mut upstream: reqwest::Response,
    deadline: Instant,
    idle: Duration,
    prompt: u32,
    limit: u32,
    lease: Lease,
) -> Body {
    Body::from_stream(stream! {
        let mut lease = lease;
        let mut decoder = Decoder::default();
        let mut contract = Completion::new(prompt, limit);
        let mut observed_transport = false;
        let mut received = 0;
        let mut idle_until = Instant::now() + idle;
        let terminal = 'receive: loop {
            let chunk = match timeout_at(deadline.min(idle_until), upstream.chunk()).await {
                Ok(Ok(Some(chunk))) => chunk,
                Ok(Ok(None)) | Ok(Err(_)) => break Outcome::Truncated,
                Err(_) => break Outcome::Timeout,
            };
            if !observed_transport && !chunk.is_empty() {
                observed_transport = true;
                lease.gateway.metrics.transport_first.fetch_add(1, Relaxed);
            }
            if chunk.len() > MAX_WIRE - received {
                break Outcome::Protocol;
            }
            received += chunk.len();
            let mut input = chunk.as_ref();
            while !input.is_empty() {
                if Instant::now() >= deadline.min(idle_until) {
                    break 'receive Outcome::Timeout;
                }
                let frame = match decoder.next(&mut input) {
                    Ok(Some(frame)) => frame,
                    Ok(None) => break,
                    Err(_) => break 'receive Outcome::Protocol,
                };
                match contract.accept(frame) {
                    Ok(Delivered::Done) => break 'receive Outcome::Complete,
                    Ok(Delivered::Item { json, first_content }) => {
                        if first_content {
                            lease.gateway.metrics.content_first.fetch_add(1, Relaxed);
                        }
                        idle_until = Instant::now() + idle;
                        yield Ok::<_, Infallible>(Bytes::from(format!("data: {json}\n\n")));
                    }
                    Err(_) => break 'receive Outcome::Protocol,
                }
            }
        };
        drop(upstream);
        let end = match terminal {
            Outcome::Complete => "data: [DONE]\n\n",
            Outcome::Timeout => "event: error\ndata: {\"error\":\"model stream deadline\"}\n\n",
            Outcome::Truncated => "event: error\ndata: {\"error\":\"incomplete model stream\"}\n\n",
            Outcome::Protocol => "event: error\ndata: {\"error\":\"invalid model stream\"}\n\n",
        };
        lease.outcome = Some(terminal);
        yield Ok::<_, Infallible>(Bytes::from_static(end.as_bytes()));
    })
}

async fn metrics(State(gateway): State<Arc<Gateway>>) -> Json<serde_json::Value> {
    let meters = &gateway.metrics;
    Json(json!({
        "active": gateway.limits.slots - gateway.slots.available_permits(),
        "transport_first": meters.transport_first.load(Relaxed),
        "content_first": meters.content_first.load(Relaxed),
        "complete": meters.complete.load(Relaxed),
        "incomplete": meters.incomplete.load(Relaxed),
        "abandoned": meters.abandoned.load(Relaxed),
    }))
}
~~~

## Check it

~~~bash
cargo check --locked
~~~

<!-- run: cargo check --locked -->

No waiting queue is created for generation requests. A quota refusal can still have used the tokenizer, which is bounded by the same slot and deadline. The upstream usage frame is an accounting check. The model server enforces its own output token limit.
