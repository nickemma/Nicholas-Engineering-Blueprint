# TESSERA — LLM Inference Platform

*Organization-grade project charter (24-point standard).*

*Part of [The Nicholas Emmanuel Engineering Blueprint](../../README.md) — v1.1*

---

# Chapter 45 · TESSERA — LLM Inference Platform

**Level IV · Weeks 24–32 · GCP · Consumes: EMBER (gateway), VEYRONIX patterns (operations) · Provides: the AI system SYNAPSE governs**

### 1–2 · Vision & problem

Serving LLMs efficiently is the defining infrastructure problem of the AI era: GPUs are scarce and expensive, and naive serving wastes both. TESSERA is a multi-tenant inference platform whose serving core — paged KV cache, continuous batching — is written from scratch and benchmarked honestly against vLLM.

### 3 · Functional requirements

- OpenAI-compatible completions/chat endpoints with streaming.
- Paged KV-cache allocator; continuous-batching scheduler; multi-tenant API keys, rate limits, usage metering.
- GPU autoscaling on GKE driven by queue depth; usage dashboard + playground.

### 4 · Non-functional requirements

- Tokens/sec and TTFT competitive with (benchmarked against) vLLM on identical hardware.
- Fair scheduling across tenants; no OOM under KV-cache pressure (admission control sheds load); cost/1M-tokens published.

### 5–6 · Constraints & trade-offs

- **Constraint:** GPU budget $150–300; serving core hand-written (not a vLLM wrapper) — the point is to build it.
- **Trade-off:** continuous batching (higher throughput, scheduler complexity) vs static batching (simple, wasteful) — chose throughput. Paged KV cache (memory efficiency, allocator complexity) vs contiguous — chose efficiency.
- **Trade-off:** one small open model well vs many models shallowly — chose depth; the benchmark story needs a controlled comparison.

### 7–9 · Architecture / sequence / component (described)

- **Architecture:** client → EMBER → gateway (auth, limits, metering) → scheduler → serving core (paged KV cache, model runtime) on GPU nodes; autoscaler watches queue depth; metrics to Grafana.
- **Sequence (request):** client → EMBER → gateway authn + rate check → enqueue → continuous-batch scheduler admits → core runs decode with paged KV → stream tokens back → meter usage.
- **Component:** core (kv_cache, scheduler, runtime) · gateway · autoscaler · dashboard · kernels.

### 10–11 · Schema & API

- **Postgres:** tenants · api_keys(hash,scopes) · models · deployments · usage_events(tenant,tokens_in/out,ms,cost) · rate_limits.
- **API:** POST /v1/completions, /v1/chat/completions (streaming) · GET /v1/models · GET /v1/usage · admin: POST /v1/tenants, /v1/keys; GET /v1/fleet.

### 14–20 · Threat model, security, testing, benchmarks

- Assets: the GPU fleet, tenant prompts/keys, usage/billing data. Adversaries: noisy-neighbor tenant, key theft, prompt-based resource exhaustion. Controls: hashed keys with scopes, per-tenant fair scheduling + limits, input caps, EMBER-fronted TLS.
- Testing: unit (cache allocator, scheduler); integration (full serving path); load (throughput vs vLLM); chaos (GPU node kill mid-stream, KV exhaustion, spot preemption). Published: tokens/sec + TTFT vs vLLM, cost/1M tokens, autoscaler reaction time.

### 22–24 · Scale, future, lessons

- **Scale:** multi-GPU model sharding, prefix caching, speculative decoding, multi-region. **Future:** quantization options, LoRA hot-swap, batched embeddings. **Lessons:** the “losing to vLLM honestly” post — where hand-built lost, and why that’s the most credible thing on the portfolio.
