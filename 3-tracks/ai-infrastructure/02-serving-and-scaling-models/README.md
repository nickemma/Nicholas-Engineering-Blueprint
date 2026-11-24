# 02 Serving and scaling models

> AI infrastructure track · Time 7 weeks at 12–15 hours a week, plus two optional lessons · Builds on [ML for infrastructure](../01-ml-for-infrastructure/README.md), [Core 06 Linux, networking and profiling](../../../2-core/06-linux-networking-and-profiling/README.md), [Kubernetes and delivery](../../shared-units/kubernetes-and-delivery/README.md) and [Tenancy and abuse control](../../shared-units/tenancy-and-abuse-control/README.md) · Status ready

Serve an open-weight language model behind Switchyard, and find out what that costs. Build a tiny transformer to see prefill, decode and the KV cache. Then put a real model behind a Go gateway that verifies identity, reserves tokens per tenant, bounds admission and cancels upstream work. Measure time to first content, deploy the model to Kubernetes, sign its weights, benchmark cost against quality, and run a game day. Finish with data parallelism across a shaped link and Ray, and a report that keeps every limit.

Start with [Before you start](lessons/00-before-you-start.md). Lessons 01–12 run on CPUs; live deployment needs Docker and kind. Lesson 13 needs an NVIDIA GPU and is optional, as is lesson 11.

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [What a model server does](lessons/01-what-a-model-server-does.md) | A tiny transformer with tokens, prefill and decode. Check that cached and uncached generation give the same answer, and that KV memory matches the real tensors. |
| 1 | 02 | [A real model, and honest streaming measurements](lessons/02-a-real-model-and-honest-streaming-measurements.md) | llama.cpp with a GGUF model. Count authoritative usage, not text chunks, and treat a stream without `[DONE]` as a failure. |
| 1 | 03 | [Batching, concurrency and the knee](lessons/03-batching-concurrency-and-the-knee.md) | Static and continuous admission, simulated and measured with open-loop arrivals up to saturation. |
| 2 | 04 | [Put an admission boundary on Switchyard](lessons/04-put-an-admission-boundary-on-switchyard.md) | A Go gateway: verified identity, token reservations, bounded admission, and cancellation that reaches the upstream request. |
| 3 | 05 | [Observe the user contract](lessons/05-observe-the-user-contract.md) | First-byte versus first-content latency, all-arrivals objectives, metrics and traces through the gateway. |
| 4 | 06 | [Deploy a slow-starting dependency](lessons/06-deploy-a-slow-starting-dependency.md) | The model on Kubernetes: verified weights, startup and readiness, cold starts, and scaling on queue depth. |
| 5 | 07 | [A supply chain for code and weights](lessons/07-a-supply-chain-for-code-and-weights.md) | SBOMs, provenance, signed images and weight manifests, and a deployment that fails closed. |
| 5 | 08 | [Benchmark performance, cost and quality together](lessons/08-benchmark-performance-cost-and-quality-together.md) | Repeated experiments with a frozen quality suite, failed requests kept in the denominator, and cost per completed token. |
| 6 | 09 | [Failure, recovery and the game day](lessons/09-failure-recovery-and-the-game-day.md) | Model exit, Redis outage, overload, cancellation, monitoring loss and out-of-memory, each run twice; recovery measured with real requests; a runbook. |
| 7 | 10 | [Data parallelism, with a reference you can check](lessons/10-data-parallelism-with-a-reference-you-can-check.md) | Two-process DDP that matches a serial reference, atomic checkpoints, and training across a shaped link. |
| Optional | 11 | [Split the model, not just the examples](lessons/11-split-the-model-not-just-the-examples.md) | Tensor and pipeline splits with forward and gradient parity in two processes; how Megatron-LM splits a model. |
| 7 | 12 | [Ray, and where distribution helps](lessons/12-ray-and-where-distribution-helps.md) | Ray tasks, references, actors, Train and Serve, with idempotent commits. |
| Optional | 13 | [CUDA, transfers, and vLLM](lessons/13-cuda-transfers-and-vllm.md) | A CUDA kernel, transfer timing, matmul parity and a vLLM experiment, on a GPU you rent. |
| 7 | 14 | [A report that preserves the limits](lessons/14-a-report-that-preserves-the-limits.md) | An evidence bundle: claims, intervals, negative results and explicit limits. |

## The gate

The [gate](gate/README.md) runs your Python lab's formatting, lint and tests, and the gateway's race tests. It trains with two processes and requires parity with the serial reference. Then it removes one guarantee at a time, in a disposable copy: the causal mask, the check for a truncated stream, failed requests in the denominator, and the release of an admission slot. Each removal must be caught by the test that claims to cover it. You haven't finished the module until it passes.

The CPU replay checks transformer correctness, streaming contracts, batching schedules, gateway admission and cancellation, cost scoring and two-process gradient parity. Kubernetes, signing services, the shaped link, Ray clusters and the GPU are experiments you run yourself, and their recorded results are evidence, not gate checks. The short load experiments don't establish a production SLO, tenant fairness, or an accepted quality and cost configuration.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Explain prefill, decode and the KV cache, and tell a stream that finished from one that stopped. |
| Intermediate | Prove the gateway releases capacity on disconnect while the tenant still pays for the attempt, and measure time to first content for every arrival. |
| Senior | Defend a serving configuration with quality, all-arrivals latency, cost per completed token and their uncertainty, and say which claims your evidence can't support. |

## Practice

- [Exercises](exercises.md). Build modelgate, an inference service for a shared documentation assistant.
- [Self-check](self-check.md). Explain each result from your own evidence, then answer from memory.

Continue to [Securing the AI layer](../04-securing-the-ai-layer/README.md), which works in this lab and attacks this gateway.

---

<sub>The raw runs behind this module's outputs and its gate are in [evidence/](evidence/README.md). You don't need them to follow the lessons.</sub>
