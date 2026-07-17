# Level IV — AI Infrastructure

*A full mini-course: theory → labs → production flagship → exit criteria.*

*Part of [The Nicholas Emmanuel Engineering Blueprint](../../README.md) — v1.1*

---

# Chapter 22 · Level IV — AI Infrastructure

**Weeks 24–32 · Flagship: TESSERA · Cloud: GCP · Formalized by electives: CIS 5690, ESE 5460**

### Overview & why it matters

Serving a model is a distributed-systems problem wearing a lab coat — you already speak the language; this level teaches the dialect. It is the steepest new-material climb in the blueprint (deep-learning math + GPU programming + inference systems), given the most weeks after Level II so it can be honest rather than superficial. It is also the pillar that upgrades your identity from “distributed infrastructure” to “distributed infrastructure **and AI systems**.”

### Objectives / Learning outcomes

- Derive backprop once by hand; build a transformer from scratch; train small models honestly.
- Program GPUs: CUDA fundamentals, the memory hierarchy, occupancy, profiling; one non-trivial fused kernel.
- Build an LLM inference platform: paged KV cache, continuous batching — and benchmark it against vLLM in public.
- Operate a GPU fleet: autoscaling on queue depth, spot-instance discipline, per-tenant metering.

### Prerequisites

Levels I–III (TESSERA is fronted by EMBER, operated with VEYRONIX’s platform patterns). Linear algebra and calculus refresher (Wk24 covers what’s needed just-in-time). GPU cloud budget: $150–300, mirroring CIS 5690.

### Timeline

Nine weeks: neural nets from zero (24) → transformers (25) → training at scale, concepts (26) → GPU architecture (27) → ML kernels (28) → inference systems (29) → build the serving core (30) → build the platform layer (31) → benchmark & ship (32).

### Theory

- Neural nets: autograd, backprop, optimization (SGD→Adam), loss landscapes.
- Transformers: self-attention math, KV projections, positional encoding, scaling-law awareness.
- Training at scale (concepts): data/tensor/pipeline parallelism, ZeRO, mixed precision, checkpointing.
- GPU architecture: SIMT, warps, memory hierarchy, occupancy; the CUDA programming model.
- ML kernels: fusion, softmax numerics, FlashAttention’s tiling; Triton as the pragmatic path.
- Inference systems: KV cache, continuous batching, PagedAttention, speculative decoding, quantization.

### Architecture concepts

- Inference scheduling as queueing theory: batching vs latency, TTFT vs throughput, cross-tenant fairness.
- Memory as the real constraint: KV-cache growth, paging, prefix sharing — your LSM instincts transfer directly.
- GPU fleet operations: bin-packing models onto devices, warm pools, autoscaling on queue depth not CPU.

### Hands-on labs & assignments

- Labs: Karpathy micrograd + makemore (backprop derived on paper once); a nanoGPT-scale transformer trained on a small corpus; PMPP kernels (vector add → tiled matmul → reduction) profiled with Nsight; a fused softmax in Triton vs naive PyTorch.
- Assignments: profile a training run, add gradient accumulation + AMP; design-doc TESSERA’s serving core against vLLM’s architecture; build the paged-KV-cache + continuous-batching server; add the multi-tenant platform layer.

### Production project — TESSERA

A multi-tenant, OpenAI-compatible LLM inference platform whose serving core — paged KV-cache allocator, continuous-batching scheduler, streaming output — you wrote, wrapped in a Go platform layer (API keys, tenants, rate limits, usage metering) with GPU autoscaling on GKE, all behind EMBER. The pitch metric: **cost per million tokens, published, against vLLM on the same GPU.** Full charter in Part VI.

### Reading — tiered

- **Required:** Designing Machine Learning Systems (Huyen) · AI Engineering (Huyen) · Karpathy’s Zero-to-Hero (video spine).
- **Recommended:** Programming Massively Parallel Processors (Kirk & Hwu) ch. 1–10 · d2l.ai (free math reference).
- **Papers:** “Attention Is All You Need” · Megatron-LM · ZeRO · Mixed Precision Training · FlashAttention · Orca · vLLM/PagedAttention · GPipe.
- **Blogs/essays:** Horace He, “Making Deep Learning Go Brrrr From First Principles”; the vLLM and Modal engineering blogs. **Repos:** read vLLM’s scheduler and nanoGPT.

### Open source tasks

Ladder Stage 8 (design discussions) begins — in your existing org, or open a well-scoped issue in an inference project (vLLM, Triton) if AI-infra pulls you. Sustain the etcd cadence; don’t abandon the subsystem you built trust in.

### Deliverables

- **GitHub:** the from-scratch GPT repo (with derivation notes) public Wk25; kernels repo Wk28; TESSERA design doc Wk29.
- **Portfolio:** TESSERA with the vLLM head-to-head and a live playground showing TTFT + tokens/sec.
- **Blog:** post #4 — “I Wrote an Inference Engine, Then Benchmarked It Against vLLM: Where It Lost, and Why” + the package.

### Interview topics unlocked

Why batching helps; what’s in a KV cache; continuous batching vs static; TTFT vs throughput tradeoffs; GPU memory hierarchy; “design an inference serving system / a model-serving platform / rate limiting for a shared GPU pool.”

### Weekly schedule

Chapter 14 default; **full interview season opens Week 24** — 3–5 LeetCode/week, one system design, one mock, one behavioral story polished. Build weeks (30–31) merge morning blocks into the core/platform build.

### Exit criteria

- TESSERA serving a 1–3B model multi-tenant, benchmarked against vLLM on identical hardware, cost/1M-tokens published.
- GPU node killed mid-stream handled gracefully; from-scratch GPT repo public with derivations.
- Meridian-Standard docs; interview cadence established.

### Reflection questions

What did deriving backprop change about how you read ML papers? Where did your distributed-systems instincts transfer to inference — and where did they mislead you? What did losing to vLLM teach?
