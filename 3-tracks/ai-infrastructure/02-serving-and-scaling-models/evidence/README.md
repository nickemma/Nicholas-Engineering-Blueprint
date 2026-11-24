# Evidence: Serving and scaling models

The raw runs behind this module's outputs. You don't need them to follow the lessons.

## The gate

[gate/](gate/) holds the gate's runs on the reference lab, rebuilt from the lessons: [a pass](gate/pass.txt), [a gateway that never releases its slot](gate/broken-slot-never-released.txt), and [a stream test weakened so it no longer checks truncation](gate/broken-truncation-assert-deleted.txt). Paths are shortened to `~/lab`.

## The experiments

- [The initial CPU bundle](2026-11-07/report.md): 60 serving runs and 720 arrivals, a frozen quality suite, real JWT, tokenizer and Redis integration across two gateway instances, and six signed-weight checks. The shared weighted reservation adapter uses Switchyard's Redis and fails closed; the per-process fallback is a lab-only default. No configuration establishes the chosen 99% first-content objective from this short experiment.
- [The platform report](platform-validation/report.md): the real JWT API, signed Kubernetes deployment and admission, and Ray.
- [The game day](2026-11-13-game-day/) (lesson 09).
- [Kubernetes start-up, replacement and scaling](2026-11-24-kubernetes/README.md) (lesson 06), and an [earlier run](2026-11-13-kubernetes/README.md) on another cluster.
- [Training across a shaped link](2026-11-13-training-network/README.md) (lesson 10).

## Limits

- Lesson 13 (GPU, CUDA, vLLM) is learner-run: its kernel compiles without a GPU, but none of its numbers are measured.
- The short load experiments don't establish a production SLO, tenant fairness, or an accepted quality and cost configuration.
- The historical publisher revision of the model wasn't retained; its known weight digest and that provenance limit stay explicit.
