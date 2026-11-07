# Phase 8: explain what you built

Answer from your own code and evidence. A term's definition is not enough: predict an outcome and identify the check that could disprove your prediction.

## Serving and measurement

1. Why can earlier keys and values be cached without changing a causal transformer's answer? What bug does cached/uncached parity catch?
2. Derive KV bytes from layers, KV heads, head dimension, tokens, batch size and element size. How does grouped-query attention change the result?
3. Why do long prompts mostly change prefill, while long answers repeatedly incur decode work? What else contributes to TTFT?
4. Why is a streamed text delta not necessarily one token? Which record gives authoritative output usage? What does EOF without `[DONE]` mean?
5. Static batching, continuous batching and request concurrency: describe the different scheduling decisions. Where does the tick model stop predicting reality?
6. Why does a closed-loop client hide overload? How can an open-loop client still become the bottleneck?
7. Explain the distinction between arrival-order warmup and completion-order warmup. Why retain failed arrivals in an SLO denominator?
8. Which of the historical captures can support a prefill trend? Why does this guide refuse to publish the old knee as established capacity?

## Gateway and operation

9. Where does Runway establish tenant identity? Why cannot the gateway trust a tenant header or raw token count from the caller?
10. Why must the chat template match the server when reserving tokens? Predict the effect of omitting role markers.
11. Explain reservation on cancellation and retry. What does a fixed-minute window permit near its boundary? Why does a per-process limit fail when replicated?
12. What bounds waiting, generation and tokenization? What does the semaphore not guarantee about fairness?
13. Which context propagates disconnect upstream? Why does that not prove a GPU kernel stops? Why is a downstream write deadline also needed?
14. Why does a successful HTTP status not prove a successful generation? Why is first-byte latency only a diagnostic here?
15. Distinguish startup, readiness and liveness. What evidence decides their thresholds?
16. Why might queue-depth autoscaling react too late? What components are needed before an HPA can consume an application metric?
17. What happens to a ReadWriteOnce model volume during multi-node scaling? Where should model download/load time appear in the benchmark?
18. Which failure can an automatic retry make worse? Show your recovery definition and measured recovery evidence.

## Trust, cost and quality

19. What does a digest prove, and what does a signature add? What do neither prove about model training data?
20. Why must image admission and weight verification be separate? How can a PVC change after an init container verifies it?
21. Why is a valid signature for an older model insufficient authorisation for today's release? How is the authorised manifest bound to deployment?
22. What does each SBOM cover? What provenance is missing unless you write it explicitly?
23. Derive cost per million completed output tokens. How do idle time, cold starts and missing usage change the comparison?
24. Why freeze a quality rubric before comparing quantisation? What does a faster but lower-quality configuration establish?
25. Why can a point estimate of 100% on ten requests not establish a 99% objective? When is a Wilson bound the wrong uncertainty model?

## Distributed work and the GPU

26. Why do equal-shard, mean-loss DDP gradients match full-batch SGD? What changes for unequal shards or summed losses?
27. What crosses the network in data, tensor and pipeline parallelism? Which one replicates the full weights?
28. Why compare gradients as well as forward outputs? What does the microbatch loss divisor preserve?
29. What does the two-process pipeline exercise prove? What would be needed to demonstrate overlap and speedup?
30. Derive the simple pipeline bubble fraction. Which assumptions would a slow stage violate?
31. What makes a checkpoint atomic? Which additional state is needed to resume training without silently changing the experiment?
32. Why can a retry-safe Ray task still double-write external effects? What does the ledger lose when its actor dies?
33. Why can four remote sums lose to one local sum? Where do object references and bounded pending tasks help?
34. Why does Ray Train own process-group setup? What does the Serve example load once per replica?
35. Explain blocks, threads and the partial final CUDA block. Why check both launch errors and completion?
36. Why does an asynchronous transfer timer need synchronisation? What costs does a CUDA-event matmul timer exclude?
37. How do pinning and arithmetic intensity relate to your measured transfer/matmul results? Which results remain unmeasured without a GPU?
38. Why is Q4 llama.cpp versus FP16 vLLM not a pure serving-engine comparison?
39. Pick one report claim and identify its threshold, evidence, uncertainty, verdict and strongest threat to validity.
