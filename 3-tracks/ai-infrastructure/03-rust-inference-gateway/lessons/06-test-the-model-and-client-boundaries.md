# 06 Test the model and client boundaries

> A Rust inference gateway · Week 3

## The problem

A parser test can prove byte boundaries but cannot show whether a client disconnect actually closes the model's HTTP response. Exercise the full loopback path and observe both ends.

## The mental model

~~~text
client fixture → real HTTP/1 gateway → HTTP model fixture
     close client body ── verify upstream body drop ── reuse slot
~~~

## Build it

### Exercise cancellation, timeouts, and quotas

Hold a model response open while another request competes for the slot. Separately test early EOF, wrong usage, a non-streaming response, and both stream and connection timeouts.

Create or update `tests/loopback.rs` as shown.

<!-- file: tests/loopback.rs -->
~~~rust
use std::{
    convert::Infallible,
    net::SocketAddr,
    sync::{
        Arc,
        atomic::{AtomicU32, Ordering::Relaxed},
    },
    time::Duration,
};

use async_stream::stream;
use axum::{
    Json, Router,
    body::{Body, Bytes},
    extract::State,
    http::header,
    response::{IntoResponse, Response},
    routing::post,
};
use reqwest::{Client, StatusCode};
use serde_json::{Value, json};
use switchyard_inference::{
    gateway::{Gateway, Limits, routes},
    server::serve,
};
use tokio::{
    net::TcpListener,
    sync::Notify,
    task::JoinHandle,
    time::{sleep, timeout},
};

const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

#[derive(Default)]
struct Model {
    resume: Notify,
    dropped: Notify,
    generations: AtomicU32,
}

struct Watch(Arc<Model>);
impl Drop for Watch {
    fn drop(&mut self) {
        self.0.dropped.notify_one();
    }
}

async fn template(Json(value): Json<Value>) -> Json<Value> {
    assert_eq!(value["add_generation_prompt"], true);
    assert_eq!(value["messages"][0]["role"], "user");
    Json(json!({"prompt":"fixture/chat"}))
}

async fn tokenize(Json(value): Json<Value>) -> Json<Value> {
    assert_eq!(value["content"], "fixture/chat");
    assert_eq!(value["add_special"], true);
    Json(json!({"tokens":[10, 20, 30]}))
}

async fn generate(State(model): State<Arc<Model>>, Json(value): Json<Value>) -> Response {
    assert_eq!(value["stream_options"]["include_usage"], true);
    assert_eq!(value["stream"], true);
    assert_eq!(value["max_tokens"], 4);
    model.generations.fetch_add(1, Relaxed);
    let case = value["messages"][0]["content"].as_str().unwrap().to_owned();
    if case == "wrong-media" {
        return "plain text upstream".into_response();
    }
    let body = Body::from_stream(stream! {
        let _watch = (case == "hold").then(|| Watch(model.clone()));
        yield Ok::<_, Infallible>(Bytes::from_static(
            b": fixture heartbeat\r\ndata: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\r\n\r\n",
        ));
        if case == "gated" {
            model.resume.notified().await;
        }
        if case == "stall" {
            std::future::pending::<()>().await;
        }
        yield Ok(Bytes::from_static(b"data: {\"choices\":[{\"delta\":{\"content\":\"caf\xc3"));
        yield Ok(Bytes::from_static(b"\xa9\"}}]}\n\n"));
        if case == "hold" {
            std::future::pending::<()>().await;
        }
        if case == "eof" {
            return;
        }
        if case == "bad-usage" {
            yield Ok(Bytes::from_static(b"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":1}}\n\n"));
        } else {
            yield Ok(Bytes::from_static(b"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1}}\n\n"));
        }
        yield Ok(Bytes::from_static(b"data: [DONE]\n\n"));
    });
    (
        [(header::CONTENT_TYPE, "text/event-stream; charset=utf-8")],
        body,
    )
        .into_response()
}

struct Server(JoinHandle<()>);
impl Drop for Server {
    fn drop(&mut self) {
        self.0.abort();
    }
}

async fn lab(limits: Limits, lifetime: Duration) -> (Client, String, Arc<Model>, Server, Server) {
    let model = Arc::new(Model::default());
    let app = Router::new()
        .route("/apply-template", post(template))
        .route("/tokenize", post(tokenize))
        .route("/v1/chat/completions", post(generate))
        .with_state(model.clone());
    let backend = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address: SocketAddr = backend.local_addr().unwrap();
    let backend = Server(tokio::spawn(async move {
        axum::serve(backend, app).await.unwrap()
    }));
    let gateway = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", gateway.local_addr().unwrap());
    let router = routes(Gateway::new(address, [A, B], limits).unwrap());
    let gateway = Server(tokio::spawn(async move {
        serve(gateway, router, lifetime).await.unwrap();
    }));
    let client = Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(5))
        .build()
        .unwrap();
    (client, url, model, backend, gateway)
}

async fn chat(client: &Client, url: &str, credential: &str, case: &str) -> reqwest::Response {
    client
        .post(format!("{url}/v1/chat/completions"))
        .bearer_auth(credential)
        .json(&json!({"messages":[{"role":"user","content":case}],"max_tokens":4,"stream":true}))
        .send()
        .await
        .unwrap()
}

async fn metrics(client: &Client, url: &str) -> Value {
    client
        .get(format!("{url}/metrics"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap()
}

async fn idle(client: &Client, url: &str) -> Value {
    timeout(Duration::from_secs(1), async {
        loop {
            let sample = metrics(client, url).await;
            if sample["active"] == 0 {
                return sample;
            }
            sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("generation lease was not released")
}

#[tokio::test]
#[ignore = "requires loopback sockets"]
async fn streams_then_checks_usage_eof_and_timeout() {
    let limits = Limits {
        idle: Duration::from_millis(800),
        total: Duration::from_secs(3),
        ..Limits::default()
    };
    let (client, url, model, _backend, _gateway) =
        lab(limits, limits.total + Duration::from_secs(1)).await;
    let mut response = chat(&client, &url, A, "gated").await;
    assert_eq!(response.status(), StatusCode::OK);
    let role = response.chunk().await.unwrap().unwrap();
    assert!(String::from_utf8_lossy(&role).contains("assistant"));
    let first = metrics(&client, &url).await;
    assert_eq!(first["transport_first"], 1);
    assert_eq!(first["content_first"], 0);
    model.resume.notify_one();
    let rest = response.text().await.unwrap();
    assert!(rest.contains("café") && rest.contains("[DONE]"));
    let after = idle(&client, &url).await;
    assert_eq!(after["content_first"], 1);
    assert_eq!(after["complete"], 1);
    println!("streaming: first role data arrived before content; checked usage and terminal frame");

    for (mode, error) in [
        ("eof", "incomplete model stream"),
        ("bad-usage", "invalid model stream"),
        ("stall", "model stream deadline"),
    ] {
        let response = chat(&client, &url, A, mode).await;
        assert_eq!(response.status(), StatusCode::OK);
        let data = response.text().await.unwrap();
        assert!(data.contains("event: error") && data.contains(error));
        assert!(!data.contains("[DONE]"));
    }
    let after = idle(&client, &url).await;
    assert_eq!(after["complete"], 1);
    assert_eq!(after["incomplete"], 3);
    assert_eq!(
        chat(&client, &url, A, "wrong-media").await.status(),
        StatusCode::BAD_GATEWAY
    );
    println!(
        "failure paths: wrong media, premature EOF, mismatched usage, and idle timeout stayed distinct"
    );
}

#[tokio::test]
#[ignore = "requires loopback sockets"]
async fn drop_releases_capacity_but_keeps_the_token_charge() {
    let limits = Limits {
        slots: 1,
        tokens: 7,
        tokens_per_second: 1,
        idle: Duration::from_secs(8),
        total: Duration::from_secs(10),
    };
    let (client, url, model, _backend, _gateway) =
        lab(limits, limits.total + Duration::from_secs(1)).await;
    assert_eq!(
        chat(&client, &url, "unprovisioned", "unused")
            .await
            .status(),
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(model.generations.load(Relaxed), 0);

    let mut held = chat(&client, &url, A, "hold").await;
    assert_eq!(held.status(), StatusCode::OK);
    assert!(held.chunk().await.unwrap().is_some());
    let blocked = chat(&client, &url, B, "unused").await;
    assert_eq!(blocked.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(blocked.headers()["retry-after"], "1");
    assert_eq!(model.generations.load(Relaxed), 1);

    drop(held);
    timeout(Duration::from_secs(2), model.dropped.notified())
        .await
        .expect("upstream body stayed open");
    let after = idle(&client, &url).await;
    assert_eq!(after["abandoned"], 1);
    let limited = chat(&client, &url, A, "unused").await;
    assert_eq!(limited.status(), StatusCode::TOO_MANY_REQUESTS);
    assert!(
        limited.headers()["retry-after"]
            .to_str()
            .unwrap()
            .parse::<u64>()
            .unwrap()
            > 0
    );
    let allowed = chat(&client, &url, B, "normal").await;
    assert_eq!(allowed.status(), StatusCode::OK);
    assert!(allowed.text().await.unwrap().contains("[DONE]"));
    assert_eq!(model.generations.load(Relaxed), 2);
    println!(
        "cancellation: downstream closed, upstream dropped, slot reused, original reservation retained"
    );
    println!(
        "admission: saturated slot returned 503; exhausted tenant returned 429; second tenant completed"
    );
}

#[tokio::test]
#[ignore = "requires loopback sockets"]
async fn connection_deadline_reclaims_a_pending_body() {
    let limits = Limits {
        slots: 1,
        idle: Duration::from_secs(8),
        total: Duration::from_secs(10),
        ..Limits::default()
    };
    let (client, url, model, _backend, _gateway) = lab(limits, Duration::from_millis(800)).await;
    let mut held = chat(&client, &url, A, "hold").await;
    assert_eq!(held.status(), StatusCode::OK);
    assert!(held.chunk().await.unwrap().is_some());
    assert_eq!(metrics(&client, &url).await["active"], 1);
    timeout(Duration::from_secs(2), model.dropped.notified())
        .await
        .expect("connection deadline did not drop the upstream body");
    assert_eq!(idle(&client, &url).await["abandoned"], 1);
    drop(held);
    println!(
        "connection deadline: the pending response lost its upstream body and released its slot"
    );
}
~~~

## Check it

~~~bash
cargo test --locked
~~~

<!-- run: cargo test --locked -->

The network tests are marked ignored for build environments without sockets. On a host with loopback, run `cargo test --locked --test loopback -- --ignored --nocapture`. A successful disconnect check includes a signal from the model-side response body. It measures the fixture transport behavior.
