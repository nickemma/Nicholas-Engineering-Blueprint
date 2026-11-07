# Phase 8 self-test: AI infrastructure

Close the guide. Use your own diagrams, code and retained measurements.

1. Trace one request through JWT verification, token reservation, waiting, prefill, decode, streaming completion and settlement. Mark every deadline and capacity bound.
2. Estimate KV memory for a model of your choice using its actual KV-head count, then compare with observed allocation. Explain the difference.
3. A server sends a role event at 20 ms, first text at 2 s, then disconnects. Classify HTTP success, first-byte latency, TTFT and completion under your objective.
4. Design an open-loop experiment that can reveal overload without letting client scheduling or prefix caching determine the result.
5. Demonstrate cancellation, bounded admission, an unauthorised tenant and a concurrent budget attack. Prove backend capacity recovery, not just a released semaphore.
6. Refuse an unsigned image, a tampered model and an unauthorised older signed release. Explain which control catches each and where its trust root lives.
7. Defend a batching/precision configuration using quality, all-arrivals latency, completed output-token cost and uncertainty. An unmeasured configuration has no accepted performance claim.
8. Recreate full-batch SGD with two DDP ranks; then show tensor and pipeline forward/gradient parity. Name what is replicated, sharded and transmitted.
9. Kill one training rank. Explain timeout, checkpoint state and data replay. Identify what your local correctness test cannot establish about the shaped network.
10. Show a duplicated Ray task result causing no duplicate durable effect. Explain what is still lost with an in-memory actor.
11. On a GPU, show a partial-block kernel check and repeated transfer/matmul completion timings. Without a GPU, explain the method and mark the results not measured.
12. Present one supported, one inconclusive/contradicted and one unmeasured claim from the report. State what evidence would change each verdict.

Pass when you can predict each failure before running it, reproduce the relevant evidence, and explain every remaining limit. Return to the [phase](../../lessons/08-ai-infrastructure/README.md) for any step you cannot yet defend.
