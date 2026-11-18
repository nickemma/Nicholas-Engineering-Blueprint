# CPU serving experiment plan: 2026-11-07

Written before the grid. This is a short synthetic CPU capacity experiment, not a production acceptance test or GPU comparison.

- Freeze the historical llama.cpp image digest and Qwen2.5-0.5B-Instruct Q4_K_M/Q8_0 weight digests recorded in the guide.
- Compare 1 and 2 slots with 4 CPU threads and 4,096 context tokens per slot. Keep the output limit at 8 tokens for the load grid; quality uses a separate frozen set with up to 32 output tokens.
- Measure eight serial Q4/one-slot requests after three warmups to estimate mean service time S. Fix all configurations' offered rates at 0.4/S, 0.8/S and 1.2/S; do not retune rates after seeing comparative results.
- Use five repetitions, 12 Poisson arrivals per rate/configuration, and predeclared seeds. Shuffle configuration order within each repetition using seed 20261107. Keep prompt prefixes varied, prompt caching disabled and temperature zero.
- Record every offered arrival, dispatch lag, first-content latency, completion, chunk gaps and authoritative output-token usage. Missing usage is missing evidence, not a chunk-count estimate. Retain failed and incomplete streams.
- Warm up each configuration separately. Record run duration including scheduled idle time and drain. Compare system wall elapsed with monotonic elapsed; flag clock disagreement above 2% and material client dispatch lag above 50 ms.
- Report per-run summaries and intervals across the five independent repetitions. Twelve arrivals are too few for a reliable within-run p99. Five repetitions on one machine limit confidence and generalisation.
- The illustrative objective is completion plus TTFT ≤1 second for at least 99% of arrivals. This short experiment may fail or be inconclusive; do not claim the objective from success-only latency.
- Freeze twenty simple synthetic extraction/arithmetic/grounding prompts and their exact expected answers before running quality. Normalise case/outer whitespace/final punctuation only. Require at least 18/20 exact answers. This toy suite is not a general quality or safety evaluation.
- Use a declared hypothetical CPU allocation price of $0.10/hour only to exercise cost accounting. This is not a vendor price or an invoice. Include idle/drain time; no GPU cost inference.
- Stop the owned lab server after experiments. Do not modify unrelated Docker containers or start the existing Kubernetes cluster during the timing grid.
