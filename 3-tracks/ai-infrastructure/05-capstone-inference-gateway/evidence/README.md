# Inference gateway capstone · Evidence

## Whole-request benchmark

The model was Qwen2.5-0.5B-Instruct Q4_K_M served by llama.cpp on an AMD Ryzen 7 PRO 5850U host under Linux x86-64. The server used four CPU threads and two slots. Each combination had 16 measured requests at a fixed output limit of 16, with warmups excluded. All 64 measured requests completed, producing 1,024 output tokens.

| Concurrency | Decoder | Completed | TTFT p50 / p95 | TPOT p50 / p95 | Completed output tokens/s |
|---:|---|---:|---:|---:|---:|
| 1 | Eager | 16/16 | 289.64 / 326.75 ms | 28.61 / 32.03 ms | 21.84 |
| 1 | Typed | 16/16 | 288.04 / 333.38 ms | 28.78 / 34.07 ms | 21.95 |
| 2 | Eager | 16/16 | 548.65 / 657.78 ms | 40.19 / 61.84 ms | 27.07 |
| 2 | Typed | 16/16 | 534.11 / 626.28 ms | 40.42 / 58.53 ms | 27.41 |

TTFT measures until the first nonempty content event. TPOT measures the remaining time to the terminal event divided by output tokens minus one. Quantiles use nearest rank. At 16 samples, p95 is the largest observed sample. Goodput divides successful output tokens by the summed active block durations for that combination. The differences between decoder builds are small relative to the measured block-to-block variation.

[Raw requests](model-requests.jsonl) · [Block summaries and binary hashes](model-runs.json) · [Model and server settings](model.json)

## Parser CPU profiles

The release driver processed the same 180,000 synthetic streams with 16 content updates per stream and 137-byte fragments. The CPU sampler recorded 2,196 stacks for the eager path and 831 for the typed path. The eager graph includes the JSON writer at 600 samples. The typed path reuses validated single-line JSON.

- [Before · eager CPU flame graph](flame-before.svg) · [Profile summary](profile-before.json)
- [After · typed CPU flame graph](flame-after.svg) · [Profile summary](profile-after.json)

Two unprofiled 50,000-stream blocks per build averaged 3.95 s for eager and 1.12 s for typed. This measures the parser replay, which is about 3.5× faster on this host. [Unprofiled parser timings](parser-timing.jsonl)

## Contract evidence

- [Loopback gate](gate.txt). The two builds passed the same streaming and lifecycle checks. The benchmark excluded an EOF stream even after it received text and usage.
- [SDK smoke test](sdk.txt). Python OpenAI SDK 3.57.0 discovered the model and consumed streamed text and usage from the real model through the typed gateway.
- [Clean lesson replay](replay.txt). Rebuilt the Rust gateway prerequisite and capstone with both live gates.
