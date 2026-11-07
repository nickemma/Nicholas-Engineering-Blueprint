# Phase 8: AI infrastructure

**Assessment routes:** [junior, intermediate and senior assignments](assessment.md), with [review and ownership criteria](../ownership/README.md).

**Question:** what does it take to serve an open-weight language model reliably, train across workers, and keep GPUs busy?

**Time:** about 8 weeks. **Prerequisites:** Phases 0–7, the [Performance Bridge](../perf-bridge/README.md), [Networking Bridge](../network-bridge/README.md), and the maths track's [queueing](../../math/01-queueing/README.md) and [linear algebra](../../math/03-linear-algebra/README.md). Most work uses CPUs. Deployment needs Docker/kind; the final GPU lab needs an NVIDIA GPU.

The [type-along guide](TEACHING.md) builds a serving lab and a bounded inference gateway for Runway, then develops training and GPU experiments. Code is inline and extracted by `scripts/check_guides.py`. The gateway mounts behind Phase 6's existing JWT middleware; it does not replace Runway's identity or tenant controls.

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
| 9 | Overload, process failure, cancellation, corrupt artifacts and recovery runbook |
| 10 | CPU DDP, global-batch parity, atomic checkpoints and the shaped-link experiment |
| 11 | Tensor and pipeline splits, forward/gradient parity in two processes, Megatron-LM |
| 12 | Ray tasks, references, actors, Train and Serve; idempotent commits |
| 13 | CUDA kernel, transfer timing, matmul parity and the vLLM GPU experiment |
| 14 | Evidence bundle, claims, intervals, negative results and explicit limits |

## Evidence and limits

The CPU replay checks transformer correctness, streaming contracts, batching schedules, gateway admission/cancellation, cost scoring and two-process distributed gradient parity. Historical CPU captures illustrate prefill and decode costs. Text chunks are not assumed to equal tokens, and contaminated knee measurements are not presented as accepted results.

The [2026-11-07 CPU report](evidence/2026-11-07/report.md) now retains **60 serving runs / 720 arrivals**, a frozen quality suite, real JWT/tokenizer/Redis integration across two gateway instances, and six signed-weight verification checks. The shared weighted reservation adapter uses Runway's existing Redis dependency and fails closed. The per-process fallback remains a lab-only default. No configuration establishes the chosen 99% first-content objective from this short experiment.

**Live Kubernetes/image admission, full API observability and game day, shaped-link training, and GPU/vLLM results remain unmeasured.** The report distinguishes component integration and signed-weight verification from complete deployed enforcement. The historical publisher revision was not retained; its known weight digest is recorded. Bounded admission and a shared token budget do not establish tenant scheduling fairness. Ray runtime evidence is recorded separately if executed; source/lint checks alone are not runtime results.

## How to work through it

1. Follow [TEACHING.md](TEACHING.md) in a fresh lab directory beside your Runway checkout; integrate the Go package at step 4.
2. Run each check and deliberate break. Retain raw evidence for every manual experiment.
3. Answer [learned.md](learned.md), then build **[modelgate](exercises.md)** independently.
4. Take the [self-test](../../notes/learned/08-ai-infrastructure.md).
5. Choose a research question from the [capstone briefs](../../capstones/README.md).

## Gaps practised

The [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger) connects this phase to measurement (10), backpressure, observability, supply-chain security (33), GPUs (38), distributed training/model serving (39) and research writing. Supply-chain procedures are here; verified live enforcement is evidence you must supply. Linear algebra is a prerequisite for the GPU work, not an optional detour.
