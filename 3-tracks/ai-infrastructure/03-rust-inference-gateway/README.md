# 03 A Rust inference gateway

> AI infrastructure track · Time 3 weeks at 12–15 hours a week · Builds on [Core 05 Rust for systems](../../../2-core/05-rust-for-systems/README.md) and [Serving and scaling models](../02-serving-and-scaling-models/README.md) · Status ready

Build a Rust gateway for a small streaming chat profile. Parse upstream SSE across arbitrary byte boundaries, reserve prompt and output tokens per tenant, and own the model response and admission slot until the stream completes or is dropped. Make overload, quota refusals, invalid model output, and cancellation observable.

Start with [Before you start](lessons/00-before-you-start.md). The executable and gate run on loopback with a model fixture.

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [Frame SSE across byte boundaries](lessons/01-frame-sse-across-byte-boundaries.md) | Preserve UTF-8, mixed line endings, and multiline data with bounded parser state. |
| 1 | 02 | [Validate streaming chat and usage](lessons/02-validate-streaming-chat-and-usage.md) | Separate first transport data from first content and check model usage before accepting completion. |
| 1 | 03 | [Reserve weighted tokens](lessons/03-reserve-weighted-tokens.md) | Debit prompt and maximum output with exact refill and independent tenant budgets. |
| 2 | 04 | [Own admission through the response](lessons/04-own-admission-through-the-response.md) | Bound request preparation, reserve against the configured model's tokenizer, and move the permit into the streaming response. |
| 2 | 05 | [Bound the connection and run the CLI](lessons/05-bound-the-connection-and-run-the-cli.md) | Cap simultaneous connections and put a deadline around the entire HTTP/1 exchange. |
| 3 | 06 | [Test the model and client boundaries](lessons/06-test-the-model-and-client-boundaries.md) | Exercise the real loopback transport under disconnection, truncation, and delays. |
| 3 | 07 | [Run the streaming gate](lessons/07-run-the-streaming-gate.md) | Verify a clean build and catch an intentionally broken SSE join. |

## The gate

The [gate](gate/README.md) verifies framing and quota math, then streams through real client and upstream sockets. Closing the downstream body must close the fixture's upstream body and free the slot. The gateway must retain the reservation and allow another tenant to complete. A truncated or invalid upstream stream must lack a success marker. The negative control must fail when the parser changes a newline into a space.

The lab keeps quota and metrics in one process and uses generated bearer credentials on loopback. Its evidence covers the model fixture's transport contract. Measuring generation cancellation on a model host and benchmarking latency and throughput are separate workloads.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Explain how frames differ from transport reads and tell 429 from 503. |
| Intermediate | Prove the stream owns the permit across disconnect, error, and completion. |
| Senior | Trace reservation, cancellation, and timeout across both sockets, and identify the additional evidence needed for a model host. |

## Practice

- [Exercises](exercises.md). Build a gateway for streaming transcripts.
- [Build a Rust job-status service](../deep-dives/rust-as-a-service.md). Follow the standalone REST, OpenAPI, gRPC, WebSocket and Compose build.
- [Self-check](self-check.md). Draw byte, permit, and token boundaries from memory.
- [Evidence](evidence/README.md). Inspect the fixture results and negative control.

Continue to [Securing the AI layer](../04-securing-the-ai-layer/README.md), then apply these pieces in the [gateway capstone](../05-capstone-inference-gateway/README.md).
