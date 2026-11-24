# Track: AI infrastructure

> About 27 weeks: 19 of its own, plus 8 in shared units · Builds on: the end of the core · Status: ready

## Who it's for

You want to build and run the systems that serve, train and secure models: inference platforms, model gateways, GPU fleets.

## Roles it targets

AI Infrastructure Engineer; Inference Engineer; LLM Serving Engineer; GPU Platform Engineer; ML Infrastructure Engineer; ML Platform Engineer; MLOps Engineer. See [career.md](../../career.md).

## Shared units it needs

Skip any you've already done on another track.

- [Kubernetes and delivery](../shared-units/kubernetes-and-delivery/README.md) (5 weeks)
- [Tenancy and abuse control](../shared-units/tenancy-and-abuse-control/README.md) (3 weeks)

## Parts

| Part | What you learn and build |
|---|---|
| [01 ML for infrastructure](01-ml-for-infrastructure/README.md) | Data contract, pipeline to Parquet, training basics in PyTorch, MLOps, privacy |
| [02 Serving and scaling models](02-serving-and-scaling-models/README.md) | The serving platform, TTFT/TPOT, batching, KV caches, Ray, distributed training, CUDA memory, cost |
| [03 A Rust inference gateway](03-rust-inference-gateway/README.md) | Bounded SSE framing, weighted token buckets, and HTTP cancellation |
| [04 Securing the AI layer](04-securing-the-ai-layer/README.md) | The agent, prompt injection, tool authorization, tenant leaks, cost attacks, AI supply chain |
| [05 Capstone: an inference gateway](05-capstone-inference-gateway/README.md) | An OpenAI-compatible gateway, benchmarked for TTFT, TPOT and throughput |

**Optional deep dives:** MapReduce/Spark and COST, backprop by hand, gradient-boosted trees, AIOps, Megatron-style parallelism, the red-team exercise.

## Optional study

[AI infrastructure deep dives](deep-dives/README.md) cover distributed data processing, boosted trees, backpropagation, and operational anomaly detection.
