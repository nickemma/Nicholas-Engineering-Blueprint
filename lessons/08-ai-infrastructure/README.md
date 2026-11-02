# Phase 8: AI infrastructure

> **Status: in progress.** This phase is being written as a full type-along guide, like Phases 0–7. Until it's published, this page is its outline. The authoritative description is in [JOURNEY.md](../../JOURNEY.md#phase-8-ai-infrastructure).

## Question

What does it take to run the infrastructure underneath AI products: serving models reliably and cheaply, training across many devices, and keeping GPUs busy?

## What it will build, on Runway

A production-ready inference platform for an open-weight language model:

- an authenticated API with rate limits and request queues;
- automated deployment and health checks;
- scaling on workload and available resources;
- metrics for time to first token, inter-token latency, throughput, failures and resource use;
- a benchmark comparing performance and cost across serving configurations, with quality checks;
- a documented recovery strategy for failed deployments and overloaded services;
- a signed supply chain: SBOMs, signed images and model weights, verified at deploy.

## What it will teach

- **Distributed training** with PyTorch Distributed: data parallelism, then how Megatron-LM splits a model across devices (tensor and pipeline parallelism).
- **CUDA basics:** how data moves between CPU memory and GPU memory.
- **Ray**, to scale Python work across a cluster.
- KV caches, batching, prefill and decode, and what they do to latency and cost.

## Before you start

- Phases 0–7.
- The [Performance Bridge](../perf-bridge/README.md) and the [Networking Bridge](../network-bridge/README.md).
- The [maths track](../../math/README.md)'s linear algebra.

**Hardware:** most of the phase runs on a CPU. The CUDA steps need an NVIDIA GPU: a few hours of a rented one, or read those steps with their expected output.
