# TESSERA — the journey

The system lives at **https://github.com/nickemma/tessera**.
Its architecture, API, threat model, runbook, and benchmark results live there, current
as of `main`. This directory holds what the code cannot: intent, prediction, surprise,
and judgment.

- Charter (frozen intent) — [/docs/part-6-flagships/tessera.md](../../docs/part-6-flagships/tessera.md)
- Repository standard — [Chapter 40b](../../docs/part-6-flagships/repo-standard.md)
- [calibration.md](calibration.md) — every prediction, predicted beside actual
- [as-built.md](as-built.md) — written at level exit, never before
- Detours triggered by this build — [/detours](../../detours)

**Status:** ○ not started — predictions need numbers before freezing (Chapter 40b §8)

## Behavior ladder (Module 4)

Charter point 3 decomposed into shippable increments. Written at kickoff; see
[Chapter 40b §5](../../docs/part-6-flagships/repo-standard.md).

| | Behavior | Satisfies charter point 3 |
|---|---|---|
| B1 | a net you wrote trains; backprop derived by hand | — (foundation) |
| B2 | a small transformer trains; you can read the loss curve | — (foundation) |
| B3 | a CUDA tiled matmul you wrote; Nsight explains occupancy | serving core hand-written (constraint) |
| B4 | fused softmax in Triton beats naive PyTorch, by a known margin | kernels component |
| B5 | paged KV allocator; budget computed before it was written | paged KV-cache allocator |
| B6 | continuous batching: throughput climbs, TTFT stays flat | continuous-batching scheduler |
| B7 | streaming works; a GPU dying mid-stream corrupts nothing | streaming endpoints · chaos |
| B8 | tenants have keys, quotas, metering; autoscale on queue depth | multi-tenant keys · GPU autoscaling |
| B9 | numbers beside vLLM's on identical hardware, losses explained | non-functional 4 · cost/1M tokens |


## Session log

| # | Date | Shipped | Tag | Detours | Loose end |
|---|---|---|---|---|---|
