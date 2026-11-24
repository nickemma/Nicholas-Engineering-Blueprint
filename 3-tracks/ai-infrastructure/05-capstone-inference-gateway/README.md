# 05 Capstone · An inference gateway

> AI infrastructure track · Time 2 weeks at 12–15 hours a week · Builds on [A Rust inference gateway](../03-rust-inference-gateway/README.md) · Status ready

Ship a Rust gateway with an OpenAI-compatible streaming text-chat profile. Use authenticated model discovery, bounded admission, weighted per-tenant token reservations, and cancellation across both HTTP connections. Compare an eager JSON decoder and a typed decoder on the same CPU model. Use a fixed parser replay to locate CPU work and a whole-request benchmark to measure what callers see.

Start with [Before you start](lessons/00-before-you-start.md). The independent output is a source package with a design decision record, reproducible commands, raw samples, and before-and-after flame graphs.

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|
| 1 | 01 | [Publish a streaming chat contract](lessons/01-publish-a-streaming-chat-contract.md) | Add discovery, support both output-limit fields, and keep usage validation independent of caller visibility. |
| 1 | 02 | [Measure the client-observed stream](lessons/02-measure-the-client-observed-stream.md) | Record first content, TPOT, and completed output tokens. |
| 1 | 03 | [Profile the parser in isolation](lessons/03-profile-the-parser-in-isolation.md) | Build comparable release binaries, sample CPU stacks, and time a fixed replay. |
| 2 | 04 | [Run the pinned CPU model matrix](lessons/04-run-the-pinned-cpu-model-matrix.md) | Run matching requests at two concurrency levels against a verified Qwen model. |
| 2 | 05 | [Package the project and decision record](lessons/05-package-the-project-and-decision-record.md) | Produce a standalone project with a lockfile, reproducible commands, and evidence. |
| 2 | 06 | [Run the capstone gate](lessons/06-run-the-capstone-gate.md) | Verify both decoder builds and catch an invalid completed-token measurement. |

## The gate

The [gate](gate/README.md) checks the stream contract, per-tenant reservations, cancellation, and connection deadlines in both builds. The benchmark client must exclude an EOF response even when it received text and token usage. The reference also exercised the Python OpenAI SDK against the real model through the gateway.

In the reference, 64 measured requests completed across the paired model runs. The typed parser processed the fixed replay about 3.5× as fast on this host. The whole-request measurements were close in the short CPU experiment. [Benchmarks and flame graphs](evidence/README.md)

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Run the harness and distinguish first content, TPOT, and completed-token throughput. |
| Intermediate | Reproduce both decoder builds and prove that refusals and cancellation are visible in their counts. |
| Senior | Defend the experiment, explain what the flame graphs show, and state what more evidence a rollout needs. |

## Practice

- [Exercises](exercises.md). Extend the load study and exercise tenant isolation.
- [Self-check](self-check.md). Describe the benchmark and gateway decisions from memory.
- [Gate and source export](gate/README.md). Rebuild the module or package the capstone for review.
