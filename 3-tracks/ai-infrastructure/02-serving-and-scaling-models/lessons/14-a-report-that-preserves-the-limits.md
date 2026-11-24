# 14 A report that preserves the limits

Build a release bundle with `git rev-parse HEAD`, runtime versions, image and weight digests, template/tokenizer hashes, workload seeds, raw per-arrival results, quality rubric and scores, price assumption or invoice, startup measurements and game-day transcripts. Do not commit weight blobs, private keys or bearer tokens.

For each claim, state the planned threshold, evidence path, interval and one of `supported`, `contradicted`, `inconclusive`, `not measured`. Keep correctness checks separate from performance evidence. A simulator matching its expected schedule supports its implementation, not a claim about an LLM server. A cancellation test supports upstream HTTP cancellation, not the claim that an arbitrary backend stops GPU work.

Use this starting evidence ledger:

| Claim | Evidence provided here | Limit |
|---|---|---|
| KV caching preserves greedy outputs | Tiny-model parity test; historical timing capture | Random untrained transformer, one CPU |
| SSE measurement retains usage and detects truncation | Fake-server contract test | Chunk gaps are not guaranteed token gaps |
| Admission stays bounded; reservations are shared across gateway instances | Go race checks, real JWT API/shared Redis, and actual backend slot release after disconnect | Tenant scheduling fairness and production isolation remain unestablished |
| DDP updates equal global-batch SGD after failure | CPU/Gloo ranks across shaped container links; killed rank/partition, checkpoint resume and serial reference | One host; not a physical-network, GPU or RDMA scaling benchmark |
| Tensor/pipeline decompositions preserve gradients | Single-process reference and two-rank send/recv checks | Sequential pipeline; no overlap benchmark |
| Signed weights and images accept/refuse the intended release | Signed-image admission, private-copy startup gate, revoked key, webhook outage and corrupt/missing-weight cases | Lab trust authority; publisher revision unknown; no production security clearance |
| Deployment, queue-based HPA and failure recovery work live | Actual custom metric, 1→2 replicas receiving work, repeated faults and ten-request recovery contract | One-node lab; overload run missed the chosen latency objective |
| Ray runtime works | Tasks, retries/actor loss, two-worker Train parity and Serve HTTP results | In-memory actor deduplication is not durable exactly-once accounting |
| GPU/CUDA and vLLM performance | Runnable/manual procedures and local hardware preflight | Not measured; no exposed NVIDIA host |
| A configuration meets latency, quality and cost targets | Scorer plus 60-run CPU grid and frozen toy quality results | No accepted production configuration established |

Rebuild the CPU evidence from the repository root:

~~~bash
python3 scripts/replay_lessons.py 3-tracks/ai-infrastructure/02-serving-and-scaling-models
~~~

The replay extracts the inline files into a fresh temporary directory. Docker, kind, signing services, the shaped link, Ray and a GPU are manual experiments, explicitly outside that command. Run the entire repository workflow when you have the earlier phases' broker/database services available. Never relabel syntax checking as a deployed result.

## Run the gate

The module's [gate](../gate/README.md) checks your lab: every test, two-process training parity, and four negative controls that remove a guarantee each and expect the matching test to fail. From your lab directory:

~~~bash
bash "$blueprint/3-tracks/ai-infrastructure/02-serving-and-scaling-models/gate/run.sh" .
~~~

<!-- run: bash "$BLUEPRINT_ROOT/3-tracks/ai-infrastructure/02-serving-and-scaling-models/gate/run.sh" . -->

It ends with `gate passed`. If a negative control isn't caught, the test it names no longer checks what it claims; fix the test, not the gate.

Finish [the questions](../self-check.md), build [the independent exercise](../exercises.md), and take [the self-test](../self-check.md). Then move to [Securing the AI layer](../../04-securing-the-ai-layer/README.md): put an operations assistant on the platform and attack its boundaries. The capstone follows that security assessment.
