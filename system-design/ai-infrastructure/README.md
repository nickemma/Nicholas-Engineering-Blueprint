# AI infrastructure

For AI infrastructure, inference, ML platform and MLOps roles. These designs are about the systems underneath AI products: serving models, scheduling GPUs, training at scale, and data and monitoring for models. They lean on [Phase 7](../../lessons/07-utility-evaluation/README.md), [Phase 8](../../JOURNEY.md#phase-8-ai-infrastructure) and capstones [4–7](../../capstones/README.md).

Use the [systems template](../_template.md) for the infrastructure designs, and the [ML template](../_template-ml.md) when the model's behaviour is the question.

**Worked design:** [a multi-tenant LLM inference gateway](llm-inference-gateway.md). Do it yourself first, then compare.

**How to use the prompts:**
1. Set a 45-minute timer and design with the template.
2. Open **the crux** only if you haven't named one by minute 10.
3. Open **what a strong answer covers** only after the timer, then score yourself with the [scorecard](../scorecard.md).

## 1. A GPU cluster scheduler

Schedule training, fine-tuning, batch inference and online serving on a shared cluster of 2,000 GPUs used by 30 teams. Keep utilisation high, protect serving latency, respect team quotas, and handle GPU failures.

<details><summary>The crux</summary>GPUs are scarce, indivisible-ish and expensive. Placement must account for memory, interconnect topology (a multi-GPU job wants GPUs on the same node or switch), gang scheduling (all of a training job's GPUs start together, or none) and fragmentation. Fairness and preemption between teams must keep serving safe.</details>

<details><summary>What a strong answer covers</summary>

- Job types and their needs: gang scheduling for training, latency for serving, best effort for batch.
- Placement by GPU memory and topology; bin packing against fragmentation.
- Quotas with borrowing; preemption of lower priorities, with checkpointing so preempted work isn't lost.
- Health: GPUs fail often; detect (ECC errors, stragglers), drain and replace.
- Utilisation measured as busy, not just allocated.
- A simulator to evaluate policies before changing production.
</details>

**Built in:** [Phase 5](../../lessons/05-constrained-operations/README.md) (Kubernetes, a controller), [Phase 7, step 9](../../lessons/07-utility-evaluation/TEACHING.md#step-9-using-the-predictions) (scheduling with predictions), [capstone 5](../../capstones/05-gpu-scheduler.md).

## 2. A distributed training platform

Let researchers train models from 1 to 512 GPUs with one command: data loading, distributed training, checkpointing, experiment tracking, and recovery from failures, which at 512 GPUs happen daily.

<details><summary>The crux</summary>Failures at scale: with hundreds of GPUs, one fails every few hours, and a synchronous job stops for all of them. Checkpoint frequency against overhead, fast restart, and spare capacity decide how much training time is lost.</details>

<details><summary>What a strong answer covers</summary>

- Parallelism: data, tensor and pipeline, and when each is needed (Megatron-LM style).
- Collective communication (all-reduce) and the network it needs.
- Data loading that keeps GPUs fed: sharded datasets, prefetching, caching.
- **Checkpointing:** asynchronous, sharded; the interval chosen from the failure rate (Young/Daly).
- Elastic restart: replace the failed node from spares, reload the last checkpoint.
- Experiment tracking and reproducibility (seeds, data versions, code versions).
</details>

**Built in:** [Phase 7](../../lessons/07-utility-evaluation/README.md) (training, MLflow), [Phase 8](../../JOURNEY.md#phase-8-ai-infrastructure) (PyTorch Distributed, Ray), capstones [6](../../capstones/06-checkpoint-store.md) and [7](../../capstones/07-training-traffic-priority.md).

## 3. A model-serving platform

Serve 300 models (from small tabular models to medium language models) for 40 teams: deploy a new version safely, autoscale, keep p99 latency per model, and share hardware efficiently.

<details><summary>The crux</summary>Heterogeneity: tiny CPU models and large GPU models need different serving paths. Packing many models onto shared hardware (multi-model servers, loading and unloading) trades cost against cold-start latency.</details>

<details><summary>What a strong answer covers</summary>

- A registry as the source of versions; promotion through stages; a shadow, then a canary.
- Serving runtimes per model class; batching for GPU models.
- Multi-model servers with load and evict, and the cold-start cost.
- Autoscaling on queue depth and latency, not CPU.
- Fallbacks when a model is down (a previous version, a rule, no prediction).
- Monitoring per model: latency, errors, input drift.
</details>

**Built in:** [Phase 7, steps 8 and 10](../../lessons/07-utility-evaluation/TEACHING.md#step-8-serving-predictions) (serving, MLflow registry, the gate, promotion and rollback).

## 4. A feature store

Features for training and serving across 50 models: point-in-time-correct training data, online lookups under 5 ms, streaming features fresh within seconds, and the same definitions for both.

<details><summary>The crux</summary>Train/serve parity and point-in-time correctness: a training row must only see feature values that existed at that moment, and serving must compute exactly the same thing. Most production ML bugs live in this gap.</details>

<details><summary>What a strong answer covers</summary>

- Feature definitions written once; materialised offline (warehouse) and online (key-value store).
- **Point-in-time joins** for training (as-of joins by timestamp).
- Streaming features from an event stream; backfills.
- Freshness and parity monitoring between online and offline values.
- Ownership, discovery, reuse across teams.
</details>

**Built in:** [Phase 7, steps 5 and 8](../../lessons/07-utility-evaluation/TEACHING.md#step-5-the-dataset-and-the-baselines-to-beat) (point-in-time features, a parity test that found a real leak).

## 5. Retrieval-augmented generation and vector search

Answer questions over a company's 50 million documents with an LLM: retrieve the relevant passages, generate an answer with citations, respect each user's document permissions, under 3 seconds.

<details><summary>The crux</summary>Retrieval quality and permissions: the answer is only as good as the passages found, and a passage the user isn't allowed to see must never reach the model.</details>

<details><summary>What a strong answer covers</summary>

- Ingestion: chunking, embedding, updates and deletions.
- Hybrid retrieval: keyword plus vectors (approximate nearest neighbour, HNSW), fused, then a re-ranker.
- **Permissions filtered at retrieval time**, with the same consistency concerns as the security track's authorization design.
- The latency budget: retrieval, re-ranking, generation.
- Evaluation: retrieval recall on labelled questions; answer faithfulness to the sources.
- Caching; cost per answer.
</details>

**Built in:** the [security track's authorization design](../security/authorization-service.md), [Phase 7](../../lessons/07-utility-evaluation/README.md) (evaluation).

## 6. Model monitoring

Monitor 300 production models: detect input drift, prediction drift and quality drops, with labels that arrive late, and without paging people for noise.

<details><summary>The crux</summary>Most models get their true labels late or never, so quality must be inferred from proxies (input and prediction drift) whose alarms are noisy. Turning drift statistics into actionable, low-noise alerts is the problem.</details>

<details><summary>What a strong answer covers</summary>

- Logging inputs and predictions, sampled, with model versions.
- Drift statistics (PSI, KS) per feature and prediction, against a reference window.
- Performance by slice when labels arrive.
- Alert design: thresholds validated against past incidents; tickets for slow drift, pages only for breakage.
- Automatic retraining triggers gated by evaluation beyond noise.
</details>

**Built in:** [Phase 7, steps 11–12](../../lessons/07-utility-evaluation/TEACHING.md#step-11-watching-a-model-in-production) (drift, a shadow, anomaly detection scored against incidents).
