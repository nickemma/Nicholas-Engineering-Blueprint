# Design: a multi-tenant LLM inference gateway

**Track:** ai-infrastructure · **Built in:** [Tenancy and abuse control](../../3-tracks/shared-units/tenancy-and-abuse-control/README.md) (tokens, rate limits), [Serving and scaling models](../../3-tracks/ai-infrastructure/02-serving-and-scaling-models/README.md) (model serving, the admission gateway), [A Rust inference gateway](../../3-tracks/ai-infrastructure/03-rust-inference-gateway/README.md) (streaming, token buckets), [the track's capstone](../../3-tracks/ai-infrastructure/05-capstone-inference-gateway/README.md) · **Time:** 45 minutes

This is a worked reference. Do the design yourself first, with a timer, then read this and note what you missed.

## 0. The crux

**GPU capacity is fixed, expensive and slow to add.** Loading a model's weights onto a new GPU takes minutes, not seconds. Under that constraint, the gateway must:
- keep the GPUs **full** (batching is where the throughput comes from);
- keep **time to first token** low for each request;
- stop one tenant taking everyone's capacity.

Routing decides the first two: which worker gets each request, considering what each worker already has in its KV cache. Admission control decides the third: what to do when there isn't room.

## 1. Requirements

**Functional**

1. An OpenAI-compatible API, with streaming, for three open-weight models (a small, a medium and a large one).
2. Authentication; per-tenant quotas in **tokens**, not requests.
3. Usage metering for billing.
4. Cancellation when the client disconnects.

**Non-functional**

| Property | Target |
|---|---|
| Peak load | 500 requests a second across models |
| A typical request | 1,000 prompt tokens in, 300 tokens out |
| Time to first token (TTFT) | p95 < 1 s |
| Inter-token latency | p95 < 60 ms (faster than people read) |
| Availability | 99.9% |
| Cost | Report cost per million output tokens; keep GPUs above 60% busy at peak |

**Out of scope:** training and fine-tuning, the models' quality, retrieval (a separate design).

## 2. Estimates

- **Output tokens at peak:** 500 requests/s × 300 = 150,000 tokens/s.
- **Prompt tokens at peak:** 500 × 1,000 = 500,000 tokens/s to prefill. Prefill is compute-bound but processes many tokens at once; shared prefixes cut it.
- **GPUs needed:**
  - Assume a medium model reaches about 3,000 output tokens/s per GPU at batch sizes that still meet the latency targets. **This number must be measured, not assumed**: it depends on the model, the GPU, the batching and the prompt lengths. (The [gateway capstone](../../3-tracks/ai-infrastructure/05-capstone-inference-gateway/README.md) and Serving and scaling models' benchmark measure it.)
  - Then 150,000 ÷ 3,000 = 50 GPUs at peak, before headroom; plan ~65.
- **Cost:** at an assumed $2–4 per GPU-hour, 65 GPUs cost $130–260 an hour.
  - Per million output tokens: 150,000 tokens/s × 3,600 = 540 million an hour, so $0.25–0.50 per million at full use.
  - Real utilisation is lower, which is why it matters.
- **Scaling time:** a new GPU node takes minutes to start, plus minutes to load the weights. **Autoscaling can't absorb a spike measured in seconds.** Queues and admission control must.

## 3. API

- `POST /v1/chat/completions {model, messages, max_tokens, stream}` returns server-sent events, token by token.
- **Errors:**
  - `429` with `Retry-After` when the tenant's tokens-per-minute budget is spent;
  - `503` when the model's queue is full.
- `GET /v1/usage?tenant=` returns token usage, from the metering store.

## 4. Core entities

- **Tenant:** quotas per model (tokens per minute, maximum concurrency), priority.
- **Worker:** model, GPU, health, queue depth, KV-cache use, the prefixes it holds.
- **Usage record:** tenant, model, prompt tokens, output tokens, time.

## 5. High-level design

~~~mermaid
flowchart LR
    C[Clients] --> GW[Gateway, Go: auth, quotas, admission]
    GW --> RL[(Redis: token budgets)]
    GW --> Q[Per-model queues, fair share by tenant]
    Q --> RT[Router: load + prefix affinity]
    RT --> W1[vLLM worker, GPU]
    RT --> W2[vLLM worker, GPU]
    W1 -.metrics: queue, KV cache.-> REG[Worker registry]
    W2 -.-> REG
    REG --> RT
    REG --> AS[Autoscaler, with warm pool]
    GW -->|usage events| K[Kafka] --> BILL[Metering and billing]
~~~

**A request's path:**
1. The gateway authenticates, checks the tenant's **token budget** (estimating the output from `max_tokens`, then settling the actual count afterwards), and queues the request for its model.
2. The router picks a worker.
3. Tokens stream back through the gateway without buffering.
4. On completion, the gateway emits a usage event.

## 6. Deep dives

### 6.1 Routing (the crux, part 1)

- **Workers batch continuously:** new requests join the running batch at every decoding step. A worker's throughput rises with its batch, until **KV-cache memory** runs out. Then requests wait, or get preempted.
- **Route on load, not round-robin.** Use queue depth and KV-cache use from each worker's metrics, refreshed every second. Pick the less loaded of two random workers (power of two choices), to avoid stampeding the single "least loaded" one.
- **Add prefix affinity.** Many requests share a long prefix (a system prompt, a document). A worker that already holds that prefix's KV cache skips most of the prefill, so TTFT drops sharply.
  - Hash the first blocks of the prompt, and prefer the worker that served that hash recently.
  - Bound it: if that worker is overloaded, fall back to load-based choice. Consistent hashing **with bounded loads** does both.
- **Measure, don't assume.** Whether affinity beats plain load-balancing depends on how much of the traffic shares prefixes.

### 6.2 Admission and fairness (the crux, part 2)

- **Budgets in tokens.** A request with 100,000 tokens of context costs a hundred times one with 1,000. Rate limits in requests would let one tenant hog the GPUs.
- **Queue per model, fair share between tenants:** take requests from tenants in proportion to their weights, so one tenant's burst waits in its own line.
- **Bounded queues:**
  - when a model's queue would make TTFT exceed the objective, answer `503` with `Retry-After` now, rather than time out later;
  - a request that can't start within its deadline is dropped from the queue, not run.
- **Priority:** interactive traffic ahead of batch traffic. A batch tier can use idle capacity at night.

### 6.3 Capacity that can't scale quickly

- **The autoscaler** works on queue depth and KV-cache use, not CPU.
- **A warm pool** keeps a few GPUs with weights already loaded, so scaling up takes seconds.
- **Load weights fast:** from local NVMe or a nearby cache, not object storage across a region.
- **Scale down slowly:** a GPU that was expensive to warm up shouldn't be released at the first quiet minute.

### 6.4 Streaming and failure

- **Pass tokens through as they arrive**; never buffer a whole response.
- **When a client disconnects,** cancel upstream, so the GPU stops generating tokens nobody will read.
- **Retry only before the first token.** After tokens have streamed, a retry would duplicate output and cost. Send an error event instead, and let the client decide.
- **A worker that dies mid-stream** breaks its streams. The registry drops it within seconds, and new requests route around it.

## 7. Trade-offs

| Decision | Chose | Instead of | Because | Revisit when |
|---|---|---|---|---|
| Quotas | Tokens per minute | Requests per minute | Cost is proportional to tokens | — |
| Routing | Load + bounded prefix affinity | Round-robin | Batching and KV-cache reuse decide throughput and TTFT | Measurements show no shared prefixes |
| Overload | Reject early with 503 | Queue without limit | A late answer is worse than a quick "retry later" | — |
| Scaling | Warm pool + slow scale-down | Pure reactive autoscaling | Loading weights takes minutes | Weights load in seconds |
| Gateway language | Go | Python | Concurrency and streaming for thousands of connections; Python stays in the workers | — |

## 8. Failure modes

| Failure | Effect | Detection | Mitigation |
|---|---|---|---|
| GPU worker dies | Its streams break; capacity drops | Missed heartbeats; stream errors | Route around it; warm pool replaces it |
| A traffic spike | Queues grow; TTFT rises | Queue depth; TTFT p95 | Admission control; batch tier pauses; warm pool |
| A tenant floods | Others' queues stall | Per-tenant queue share | Fair share; token budgets |
| A very long prompt | KV-cache exhausted; others preempted | KV-cache use near 100% | Cap context length per tier; route long prompts to workers set aside for them |
| One hot prefix | Its worker overloads under pure affinity | Load imbalance | Bounded-load affinity |
| Redis (budgets) down | Quotas can't be checked | Limiter errors | Fail closed with `503` (Tenancy and abuse control's choice), or open to local per-gateway limits if availability matters more: say which, and why |
| A model loads slowly or fails | Scale-up stalls | Readiness never passes | Warm pool; readiness probes that actually run a token |

## 9. With more time

- **Separate prefill and decode** onto different GPUs.
- **Speculative decoding.**
- **Multi-region:** route to the nearest region with capacity.
- **Per-tenant fine-tuned adapters** (LoRA) on shared base models.
- **A cost dashboard per tenant.**

## 10. Where you've built this

- [Core 01](../../2-core/01-go-runtime-and-reliable-services/README.md) and [Messaging and resilience](../../3-tracks/shared-units/messaging-and-resilience/README.md): queues, backpressure, retries and breakers.
- [Tenancy and abuse control](../../3-tracks/shared-units/tenancy-and-abuse-control/README.md): tokens, per-tenant rate limits shared through Redis, and tenant isolation.
- [ML for infrastructure](../../3-tracks/ai-infrastructure/01-ml-for-infrastructure/README.md): serving a model's active version over HTTP, and rolling it back.
- [Serving and scaling models](../../3-tracks/ai-infrastructure/02-serving-and-scaling-models/README.md): model serving with batching, KV caches and a cost benchmark.
- [The AI infrastructure track's capstone](../../3-tracks/ai-infrastructure/05-capstone-inference-gateway/README.md) builds an inference gateway you can run that routing experiment on.

## 11. What an interviewer will push on

- "Why tokens per minute and not requests per minute?"
- "Traffic doubles in 30 seconds. What happens, second by second?"
- "When is it safe to retry a streaming request?"
- "How did you get 3,000 tokens per second per GPU, and what would change it?"

## 12. Work the capstone evidence into your answer

The reference build serves a pinned CPU model with an OpenAI-compatible chat stream. It checks the stream lifecycle and accounts for output only when the terminal event confirms completion. Treat the earlier GPU fleet, routing policies, and scale figures as interview design assumptions. The capstone measures the gateway and one local model server. [Capstone contract and results](../../3-tracks/ai-infrastructure/05-capstone-inference-gateway/evidence/README.md)

**Failure timeline.** The upstream sends content and usage, then closes before the terminal marker. The client can have seen text, so a retry after delivery starts would risk duplicate output. The gateway and benchmark distinguish premature EOF from a complete response. In the gate, that stream contributed zero completed tokens to goodput. [Lifecycle checks](../../3-tracks/ai-infrastructure/05-capstone-inference-gateway/evidence/gate.txt)

**Tradeoff.** Increasing concurrency can raise throughput at the expense of client latency. For the typed decoder, concurrency one produced 21.95 output tokens/s and 288.04 ms median TTFT. Concurrency two produced 27.41 output tokens/s and 534.11 ms median TTFT. Both runs used the same small Qwen CPU model, with 16 requests per combination and a 16-token output limit. Choose an admission limit against a TTFT objective, then repeat with realistic prompt and output distributions before projecting fleet throughput. [Raw model runs](../../3-tracks/ai-infrastructure/05-capstone-inference-gateway/evidence/model-runs.json)

For a timed review, explain why the completed-token count and visible client output can differ. Score the failure explanation and the admission tradeoff with the [design scorecard](../scorecard.md).
