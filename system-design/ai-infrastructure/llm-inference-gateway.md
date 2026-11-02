# Design: a multi-tenant LLM inference gateway

**Track:** ai-infrastructure · **Built in:** [Phase 6](../../lessons/06-safe-shared-queries/README.md) (tokens, rate limits), [Phase 7](../../lessons/07-utility-evaluation/README.md) (serving with a fallback), [Phase 8](../../JOURNEY.md#phase-8-ai-infrastructure) (model serving), [capstone 4](../../capstones/04-inference-gateway.md) · **Time:** 45 minutes

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
  - Assume a medium model reaches about 3,000 output tokens/s per GPU at batch sizes that still meet the latency targets. **This number must be measured, not assumed**: it depends on the model, the GPU, the batching and the prompt lengths. (Capstone 9 and Phase 8's benchmark measure it.)
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
- **Measure, don't assume.** Whether affinity beats plain load-balancing depends on how much of the traffic shares prefixes ([capstone 4](../../capstones/04-inference-gateway.md) is exactly that experiment).

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
| Redis (budgets) down | Quotas can't be checked | Limiter errors | Fail open to local per-gateway limits (Phase 6's fallback) |
| A model loads slowly or fails | Scale-up stalls | Readiness never passes | Warm pool; readiness probes that actually run a token |

## 9. With more time

- **Separate prefill and decode** onto different GPUs.
- **Speculative decoding.**
- **Multi-region:** route to the nearest region with capacity.
- **Per-tenant fine-tuned adapters** (LoRA) on shared base models.
- **A cost dashboard per tenant.**

## 10. Where you've built this

- [Phase 2](../../lessons/02-connected-services/README.md): queues, backpressure, retries and breakers.
- [Phase 6](../../lessons/06-safe-shared-queries/README.md): tokens, per-tenant rate limits through Redis with a fallback, and tenant isolation.
- [Phase 7](../../lessons/07-utility-evaluation/README.md): serving a model behind the Go API with a timeout, a breaker and a fallback.
- [Phase 8](../../JOURNEY.md#phase-8-ai-infrastructure): model serving with batching, KV caches and a cost benchmark.
- [Capstone 4](../../capstones/04-inference-gateway.md) turns the routing question into an experiment.

## 11. What an interviewer will push on

- "Why tokens per minute and not requests per minute?"
- "Traffic doubles in 30 seconds. What happens, second by second?"
- "When is it safe to retry a streaming request?"
- "How did you get 3,000 tokens per second per GPU, and what would change it?"
