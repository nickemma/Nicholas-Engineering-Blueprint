# Phase 8: AI infrastructure

**Practice:** build the phase, complete the [independent exercise](exercises.md), explain it, and test it.

**Question:** what does it take to serve an open-weight language model reliably, train across workers, and keep GPUs busy?

**Time:** about 8 weeks. **Prerequisites:** Phases 0–7, the [Performance Bridge](../../../2-core/06-linux-networking-and-profiling/README.md), [Networking in depth](../../cloud-and-network/01-networking-in-depth/README.md), and the maths track's [queueing](../../../math/01-queueing/README.md) and [linear algebra](../../../math/03-linear-algebra/README.md). Most work uses CPUs. Deployment needs Docker/kind; the final GPU lab needs an NVIDIA GPU.

The [type-along guide](lessons/00-before-you-start.md) builds a serving lab and a bounded inference gateway for Switchyard, then develops training and GPU experiments. Code is inline and extracted by `scripts/replay_lessons.py`. The gateway mounts behind Phase 6's existing JWT middleware; it does not replace Switchyard's identity or tenant controls.

## Syllabus

| Step | Build and learn |
|---|---|
| 1 | Tiny transformer: tokens, prefill, decode, cached/uncached parity and KV memory |
| 2 | llama.cpp and GGUF; streaming content, authoritative usage, interrupted responses |
| 3 | Static versus continuous admission; open-loop arrivals, concurrency, saturation |
| 4 | Go gateway: verified identity, token reservations, bounded admission, cancellation |
| 5 | First-byte versus first-content latency; all-arrivals objectives; metrics and traces |
| 6 | Kubernetes startup/readiness, weight storage, cold starts and queue-based scaling |
| 7 | SBOMs, provenance, signed images and weight manifests; fail-closed deployment |
| 8 | Repeated performance/cost experiments with frozen quality checks and honest denominators |
| 9 | A game day: model exit, Redis outage, overload, cancellation, monitoring loss and out-of-memory, each run twice; recovery measured with real requests; sizing the queue from the deadline; the runbook |
| 10 | CPU DDP, global-batch parity, atomic checkpoints and the shaped-link experiment |
| 11 | Tensor and pipeline splits, forward/gradient parity in two processes, Megatron-LM |
| 12 | Ray tasks, references, actors, Train and Serve; idempotent commits |
| 13 | CUDA kernel, transfer timing, matmul parity and the vLLM GPU experiment |
| 14 | Evidence bundle, claims, intervals, negative results and explicit limits |

## Evidence and limits

The CPU replay checks transformer correctness, streaming contracts, batching schedules, gateway admission/cancellation, cost scoring and two-process distributed gradient parity. Historical CPU captures illustrate prefill and decode costs. Text chunks are not assumed to equal tokens, and contaminated knee measurements are not presented as accepted results.

The [2026-11-07 CPU report](evidence/2026-11-07/report.md) now retains **60 serving runs / 720 arrivals**, a frozen quality suite, real JWT/tokenizer/Redis integration across two gateway instances, and six signed-weight verification checks. The shared weighted reservation adapter uses Switchyard's existing Redis dependency and fails closed. The per-process fallback remains a lab-only default. No configuration establishes the chosen 99% first-content objective from this short experiment.

The evidence is kept per experiment: the [initial CPU bundle](evidence/2026-11-07/report.md), the [platform report](evidence/platform-validation/report.md) (the real JWT API, signed Kubernetes deployment and admission, Ray), and the type-along runs for [the game day](evidence/2026-11-13-game-day/), [Kubernetes start-up, replacement and scaling](evidence/2026-11-13-kubernetes/README.md) and [training across a shaped link](evidence/2026-11-13-training-network/README.md). **Step 13 (GPU, CUDA, vLLM) is learner-run:** its kernel compiles without a GPU, but none of its numbers are measured. The short load experiments don't establish a production SLO, tenant fairness or an accepted quality and cost configuration. The historical publisher revision of the model wasn't retained; its known weight digest and provenance limitation remain explicit.

## How to work through it

1. Follow [TEACHING.md](lessons/00-before-you-start.md) in a fresh lab directory beside your Switchyard checkout; integrate the Go package at step 4.
2. Run each check and deliberate break. Retain raw evidence for every manual experiment.
3. Answer [learned.md](self-check.md), then build **[modelgate](exercises.md)** independently.
4. Take the [self-test](self-check.md).
5. Continue to [Phase 9](../04-securing-the-ai-layer/README.md): build an operations assistant, attack it, and enforce its boundaries before choosing a capstone.

## Gaps practised

This module closes gaps in measurement, backpressure, observability, supply-chain security, GPUs, distributed training and model serving, and research writing. Supply-chain procedures are here; verified live enforcement is evidence you must supply. Linear algebra is a prerequisite for the GPU work, not an optional detour.
## Lessons

| # | Lesson |
|---|---|
| 00 | [Before you start](lessons/00-before-you-start.md) |
| 01 | [What a model server does](lessons/01-what-a-model-server-does.md) |
| 02 | [A real model, and honest streaming measurements](lessons/02-a-real-model-and-honest-streaming-measurements.md) |
| 03 | [Batching, concurrency and the knee](lessons/03-batching-concurrency-and-the-knee.md) |
| 04 | [Put an admission boundary on Switchyard](lessons/04-put-an-admission-boundary-on-switchyard.md) |
| 05 | [Observe the user contract](lessons/05-observe-the-user-contract.md) |
| 06 | [Deploy a slow-starting dependency](lessons/06-deploy-a-slow-starting-dependency.md) |
| 07 | [A supply chain for code and weights](lessons/07-a-supply-chain-for-code-and-weights.md) |
| 08 | [Benchmark performance, cost and quality together](lessons/08-benchmark-performance-cost-and-quality-together.md) |
| 09 | [Failure, recovery and the game day](lessons/09-failure-recovery-and-the-game-day.md) |
| 10 | [Data parallelism, with a reference you can check](lessons/10-data-parallelism-with-a-reference-you-can-check.md) |
| 11 | [Split the model, not just the examples](lessons/11-split-the-model-not-just-the-examples.md) |
| 12 | [Ray, and where distribution helps](lessons/12-ray-and-where-distribution-helps.md) |
| 13 | [CUDA, transfers, and vLLM](lessons/13-cuda-transfers-and-vllm.md) |
| 14 | [A report that preserves the limits](lessons/14-a-report-that-preserves-the-limits.md) |
