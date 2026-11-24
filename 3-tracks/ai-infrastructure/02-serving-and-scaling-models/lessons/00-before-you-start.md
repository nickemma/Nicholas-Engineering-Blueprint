# 00 Before you start

In [ML for infrastructure](../../01-ml-for-infrastructure/README.md), a small model predicts how long Switchyard's jobs will take. It answers in a millisecond, and it fits on one CPU. This module is about the other kind, the ones AI products run on, where one request holds a slice of an expensive machine for many seconds, and the machine costs more per hour than everything else in Switchyard put together.

This module asks what it takes to run that infrastructure: serving models reliably and cheaply, training across many devices, and keeping GPUs busy.

**The goal:** an inference platform on Switchyard, for an open-weight language model, and a clear idea of how training splits a model across machines. Every claim comes with the experiment behind it, the way [Core 02](../../../../2-core/02-python-runtime-and-honest-measurement/README.md) taught.

**Time:** about 7 weeks for the required lessons; lessons 11 and 13 are optional. **Before you start:** finish the core (above all [Core 06](../../../../2-core/06-linux-networking-and-profiling/README.md)), [ML for infrastructure](../../01-ml-for-infrastructure/README.md), and the shared units [Kubernetes and delivery](../../../shared-units/kubernetes-and-delivery/README.md) and [Tenancy and abuse control](../../../shared-units/tenancy-and-abuse-control/README.md). Read the [maths track](../../../../math/README.md)'s [queueing](../../../../math/01-queueing/README.md) and [linear algebra](../../../../math/03-linear-algebra/README.md) guides too. [Networking in depth](../../../cloud-and-network/01-networking-in-depth/README.md), from the cloud and network track, helps with lesson 10's shaped link but isn't required.

## How this module works

Type everything, file by file, and run the checks at the end of each lesson. The Python work is in a new project called `serve`. Your numbers will differ from mine; compare the ratios and the shape.

**Hardware:** lessons 01–12 use CPUs; live deployment needs Docker and kind. Lesson 13 needs an NVIDIA GPU. Historical measurements below came from the earlier scratch experiments; the [platform report](../evidence/platform-validation/report.md) now retains live CPU API, Kubernetes, image/weight enforcement, game-day, network-recovery and Ray results. GPU commands remain learner-run procedures without measured outputs. The CPU correctness checks replay in CI. Start in a fresh lab directory beside your existing Switchyard checkout. The gateway package is integrated into Switchyard in lesson 04; the Python lab is independent. When you finish, run [the gate](../gate/README.md) on that lab directory.


| Lesson | What you add |
|---|---|
| 01 | What a model server does: tokens, prefill, decode and the KV cache |
| 02 | A real model, streaming, and where it saturates |
| 03 | Batching and concurrency |
| 04 | The gateway on Switchyard: auth, limits in tokens, an admission queue, cancellation |
| 05 | Observability, and SLOs on time to first token |
| 06 | Kubernetes: slow readiness, scaling on queue depth, cold starts |
| 07 | Supply chain: signed images and signed weights |
| 08 | A performance and cost benchmark, with quality checks |
| 09 | Failure and recovery |
| 10 | Data parallelism across a real network link |
| 11 | *Optional:* tensor and pipeline parallelism, and how Megatron-LM splits a model |
| 12 | Ray |
| 13 | *Optional, needs a GPU:* CUDA and vLLM |
| 14 | The report |

---
