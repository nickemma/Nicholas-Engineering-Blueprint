# 00 Before you start

At the end of Phase 7, Switchyard measures itself, and a model runs inside it, predicting how long jobs will take. That model is small: it answers in a millisecond, and it fits on one CPU. This phase is about the other kind, the ones that AI products run on, where one request holds a slice of an expensive machine for many seconds, and the machine costs more per hour than everything else in Switchyard put together.

This phase asks what it takes to run that infrastructure: serving models reliably and cheaply, training across many devices, and keeping GPUs busy.

**The goal:** an inference platform on Switchyard, for an open-weight language model, and a clear idea of how training splits a model across machines. Every claim comes with the experiment behind it, in the way Phase 7 taught.

**Time:** about 8 weeks. **Before you start:** finish Phases 0–7, the [Performance Bridge](../../../../2-core/06-linux-networking-and-profiling/README.md), the [Networking in depth](../../../cloud-and-network/01-networking-in-depth/README.md), and the [maths track](../../../../math/README.md)'s [queueing](../../../../math/01-queueing/README.md) and [linear algebra](../../../../math/03-linear-algebra/README.md) guides. This phase leans on all of them.

## How this guide works

The same as Phase 7: type everything, file by file, and run the checks at the end of each step. The Python work is in a new project called `serve`, next to `lab`. Your numbers will differ from mine; compare the ratios and the shape.

**Hardware:** steps 1–12 use CPUs; live deployment needs Docker and kind. Step 13 needs an NVIDIA GPU. Historical measurements below came from the earlier scratch experiments; the [platform report](../evidence/platform-validation/report.md) now retains live CPU API, Kubernetes, image/weight enforcement, game-day, network-recovery and Ray results. GPU commands remain learner-run procedures without measured outputs. The CPU correctness checks replay in CI. Start in a fresh directory for this phase, beside your existing Switchyard checkout. The gateway package is integrated into Switchyard in step 4; the Python lab is independent.

| Step | What you add |
|---|---|
| 1 | What a model server does: tokens, prefill, decode and the KV cache |
| 2 | A real model, streaming, and where it saturates |
| 3 | Batching and concurrency |
| 4 | The gateway on Switchyard: auth, limits in tokens, an admission queue, cancellation |
| 5 | Observability, and SLOs on time to first token |
| 6 | Kubernetes: slow readiness, scaling on queue depth, cold starts |
| 7 | Supply chain: signed images and signed weights |
| 8 | A performance and cost benchmark, with quality checks |
| 9 | Failure and recovery |
| 10 | Data parallelism across a real network link |
| 11 | Tensor and pipeline parallelism, and how Megatron-LM splits a model |
| 12 | Ray |
| 13 | CUDA and vLLM on a GPU |
| 14 | The report |

---
