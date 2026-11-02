# 4. An inference gateway that knows what its workers have cached

**Field:** AI infrastructure · networking · distributed systems · **Difficulty:** high · **Language:** Go

## Problem

Serving an open-weight language model means running a pool of inference workers behind a gateway. Each request runs in two phases:

- **Prefill:** the worker reads the whole prompt and builds its key-value (KV) cache. This decides the time to first token (TTFT).
- **Decode:** it generates tokens one at a time. This decides the inter-token latency.

Workers keep the KV caches of recent prompts. A request whose beginning (a system prompt, a shared document, a conversation so far) is already cached on a worker skips most of its prefill.

A load balancer that spreads requests evenly (round-robin, least connections) ignores this. It scatters requests that share a prefix across workers, and each worker recomputes the same prefix. The opposite mistake is just as bad: sending every request with a popular prefix to one worker creates a hot spot. Getting the balance right, under bursts and while workers fail, decides the p99 that users feel.

## Who

Teams that self-host open-weight models: chat assistants with long system prompts, retrieval-augmented generation over shared documents, and agents with long conversation histories. Also the platform engineers who run the gateway and are paged when it's slow.

## Gap

- Within one worker, the problem is well studied:
  - continuous batching (Orca: Yu et al., OSDI 2022);
  - paged KV-cache memory (vLLM: Kwon et al., SOSP 2023);
  - prefix reuse (SGLang's RadixAttention: Zheng et al., 2024).
- **Across** workers, cache-aware routing is newer. Open-source projects around Kubernetes have started adding prefix-aware scoring to gateways.
- How much prefix affinity helps compared with plain load-aware routing, and when hot prefixes make it worse, is not well characterised. In particular, under bursty and mixed workloads, with workers failing, on hardware a small team can afford.

## Research question

> Under bursty, mixed workloads where many requests share long prefixes, does routing on prefix affinity, queue depth and measured latency cut p99 time to first token compared with round-robin and least-outstanding-requests, without raising p99 inter-token latency or overloading hot workers? Where does it stop helping?

## Hypothesis and baseline

- **Baselines:**
  - round-robin;
  - least outstanding requests;
  - power of two choices (pick two workers at random and send to the less loaded).
- **Hypothesis:** prefix affinity cuts TTFT most when shared prefixes are long and spread over many distinct prefixes. With one dominant prefix, pure affinity overloads one worker. Consistent hashing with bounded loads (Mirrokni, Thorup and Zadimoghaddam, SODA 2018) caps any worker's share and recovers the loss.

## System

- **The gateway (Go):**
  - an OpenAI-compatible HTTP API that streams tokens through as server-sent events, without buffering the whole generation;
  - authentication, per-tenant token budgets and rate limits (Phase 6);
  - bounded queues with backpressure that answer `429` with `Retry-After` when every worker is saturated (Phase 2).
- **A worker registry:** health, queue depth and KV-cache use, scraped from each worker's metrics. Workers that miss heartbeats are drained.
- **Pluggable routing policies.** A request's prefix is identified by hashing its first blocks of tokens, the way the workers' caches do.
- **Failure handling:**
  - timeouts;
  - cancellation that reaches the worker when the client disconnects;
  - a circuit breaker per worker;
  - **retries only before the first token**: after that, a retry duplicates work and output.
- **Workers:**
  - [vLLM](https://docs.vllm.ai/) on a GPU;
  - or, with no GPU, vLLM's CPU backend or [llama.cpp](https://github.com/ggml-org/llama.cpp)'s server with a small quantised model;
  - plus a **mock worker** in Go that emulates prefill cost per uncached token, decode cost per token, and an LRU prefix cache. Calibrate it against a real small model, then use it to scale to many workers.
- **Observability:** OpenTelemetry traces from the gateway to the worker; Prometheus histograms of TTFT, inter-token latency and queue time (Phase 5).

## Suggested stack

| Part | Choice | Why |
|---|---|---|
| Gateway, registry, routing | Go | Concurrency, streaming and control-plane logic; Runway's patterns carry over |
| Load generator | Go, or Rust if the Go one can't keep its schedule | It must be open-loop and record every token's arrival time |
| Workers | vLLM (GPU or CPU), llama.cpp server, or the mock | An OpenAI-compatible API for each, so the gateway doesn't care which |
| Shared limits | Redis (Phase 6) | Rate limits shared by several gateway replicas |
| Deployment | Docker, kind, Helm (Phase 5) | The same chart for the mock fleet and the real one |
| Observability | OpenTelemetry, Prometheus, Grafana | TTFT and inter-token latency as first-class metrics |

## Features to implement

1. Routing on worker health, queue depth and measured latency.
2. Prefix-affinity routing, with a bounded-load variant.
3. Streaming responses passed through token by token.
4. Bounded queues and backpressure when workers are saturated.
5. Timeouts, worker crashes, client cancellation and partial failures handled explicitly.
6. Retries that can't create duplicate work or a retry storm: before the first token only, with a retry budget.
7. Authentication, per-tenant rate limits and token budgets.
8. Metrics for TTFT, inter-token latency, throughput, errors and resource use.

## Experiment

| Variable | Values |
|---|---|
| Routing policy | Round-robin; least outstanding; power of two choices; prefix affinity; affinity with bounded load |
| Shared-prefix share | 0%, 50%, 90% of requests |
| Prefix length | 256, 1,024, 4,096 tokens |
| Distinct prefixes | 1, 10, 1,000 (popularity Zipf-distributed) |
| Arrivals | Poisson; on/off bursts |
| Workers | 2, 4, 8 (mock workers to 32) |
| Failures | Kill a worker mid-run; throttle one worker's CPU (a slow worker, not a dead one) |

## Measures

- TTFT p50, p95 and p99.
- Inter-token latency p99.
- Output tokens per second.
- **Goodput:** requests per second that meet the TTFT objective.
- Prefix-cache hit rate: the share of prompt tokens reused.
- Load imbalance: the busiest worker's load divided by the mean.
- Error rate and p99 during a worker failure.
- The gateway's own cost: added latency, and CPU per thousand requests.

## Benchmark your work

- **Gateway overhead:** [wrk2](https://github.com/giltene/wrk2) at fixed request rates against a non-streaming echo worker, with and without the gateway in the path. wrk2 keeps a constant rate and corrects for coordinated omission (the Python Bridge's lesson).
- **Streaming:** wrk2 can't see tokens, so write the load generator: open-loop arrivals, a timestamp for every token, TTFT and inter-token latency per request.
- **Throughput versus latency:** raise the offered load step by step until TTFT p99 breaks the objective. Report each policy's knee and its goodput there.
- **During failures:** TTFT p99 in 10-second windows before, during and after a worker is killed, and how long until the gateway stops sending it work.
- **GPU utilisation**, if you have a GPU: `nvidia-smi` or NVIDIA's DCGM exporter. Report whether the GPU or the queue was the bottleneck.
- **Rigour:** policies interleaved, at least 5 repeats, warm-up discarded, bootstrap intervals (Phase 7, step 1). Record the model, quantisation, worker version and flags, and the hardware.

## What you might find

Affinity may help a lot at moderate load and long prefixes, and hurt under one hot prefix. Bounded load may recover most of that. Least-outstanding-requests may come close to the clever policies when prefixes are short. Each of these is a result worth reporting.

## Limitations to expect

- A mock worker is a model of a real one; check its predictions against a real worker at a few points.
- Small models on CPU have different prefill-to-decode ratios from large models on GPUs.
- Synthetic prompt mixes may not match real traffic.

## Skills used

Phases 2 (queues, backpressure, retries, circuit breakers), 5 (Kubernetes, load balancing, SLOs), 6 (authentication, rate limiting), 7 (experimental method, serving) and 8 (model serving, KV caches).

## Read first

- Kwon et al., *Efficient Memory Management for Large Language Model Serving with PagedAttention*, SOSP 2023
- Yu et al., *Orca: A Distributed Serving System for Transformer-Based Generative Models*, OSDI 2022
- Zheng et al., *SGLang: Efficient Execution of Structured Language Model Programs*, 2024 (RadixAttention)
- Mirrokni, Thorup and Zadimoghaddam, *Consistent Hashing with Bounded Loads*, SODA 2018
- Dean and Barroso, *The Tail at Scale*, Communications of the ACM, 2013
