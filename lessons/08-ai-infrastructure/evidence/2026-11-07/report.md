# Phase 8 CPU evidence: 2026-11-07

This report records a short synthetic CPU experiment and component-level integration/security checks. It does not certify the complete Phase 8 platform as production-ready.

## Plan and reproducibility

The [plan](plan.md) was written before the grid. The [environment](environment.json) records the pinned server image, Q4/Q8 model digests, four CPU threads, 4,096 context tokens per slot and the execution-runner/client hashes. The guide contains the capture and report builders. The baseline mean service time was **0.504 seconds**, giving fixed offered rates of **0.793, 1.587 and 2.380 requests/second** for every configuration.

Each of four configurations ran five repetitions at each rate, twelve Poisson arrivals per run: **60 runs and 720 offered requests**. Configuration order was shuffled within repetitions; rate order was fixed, so within-configuration order effects remain a limitation. Prompts were synthetic and prefix caching was disabled. Warmup was separate. The host was a shared development machine, with light frontend checks/tool setup during parts of capture; it was not a dedicated performance host. No Kubernetes workload was started during the timing grid.

Raw evidence: [baseline](baseline.json), [arrivals](arrivals.jsonl), [run blocks](runs.jsonl), [summary](summary.json), [frozen quality set](quality-set.json). Summary intervals are exploratory 95% Student-t intervals across five run-level means. They do not establish a production p99 or a 99% acceptance bound, and they do not correct for multiple comparisons.

## Serving results

All **720 requests completed**, with authoritative output-token usage retained. Maximum client dispatch lag was **2.79 ms**, below the predeclared 50 ms check. Maximum wall/monotonic elapsed disagreement was below **0.00004%**, below the predeclared 2% threshold. These checks do not remove other shared-host noise.

“Good” below means completed with first nonempty content within one second, divided by all offered requests. Each row has sixty offered requests. TTFT is the mean of five per-run means; the interval describes those run means, not individual requests.

| Weights | Slots | Offered requests/s | Good / offered | Mean TTFT, seconds (95% interval) | Hypothetical $ / million completed output tokens |
|---|---|---|---|---|---|
| q4_k_m | 1 | 0.793 | 55/60 | 0.575 (0.429–0.720) | 5.70 |
| q4_k_m | 1 | 1.587 | 33/60 | 1.073 (0.691–1.454) | 2.70 |
| q4_k_m | 1 | 2.380 | 23/60 | 1.536 (0.642–2.430) | 2.33 |
| q4_k_m | 2 | 0.793 | 58/60 | 0.544 (0.474–0.614) | 5.71 |
| q4_k_m | 2 | 1.587 | 40/60 | 0.897 (0.566–1.229) | 2.58 |
| q4_k_m | 2 | 2.380 | 30/60 | 1.286 (0.518–2.055) | 2.18 |
| q8_0 | 1 | 0.793 | 57/60 | 0.502 (0.432–0.572) | 5.71 |
| q8_0 | 1 | 1.587 | 36/60 | 0.983 (0.543–1.424) | 2.69 |
| q8_0 | 1 | 2.380 | 22/60 | 1.457 (0.689–2.225) | 2.29 |
| q8_0 | 2 | 0.793 | 60/60 | 0.439 (0.378–0.501) | 5.70 |
| q8_0 | 2 | 1.587 | 44/60 | 0.763 (0.356–1.169) | 2.53 |
| q8_0 | 2 | 2.380 | 33/60 | 1.104 (0.500–1.708) | 2.11 |

The cost column uses a **hypothetical $0.10/hour CPU allocation**, including scheduled idle and drain time. It is not a vendor quote or invoice and does not predict GPU cost. Full run-level cost intervals are in the JSON summary. The short eight-token output cap is central to interpreting every number.

Every configuration scored **19/20** against the predeclared 18/20 toy quality threshold. The shared failure was answering `[garden]` instead of the requested bare word `garden`; it remains a failure under the frozen exact-match rubric. There is no post-hoc relaxation. See the [Q4 one-slot](quality-q4_k_m-slots1.json), [Q4 two-slot](quality-q4_k_m-slots2.json), [Q8 one-slot](quality-q8_0-slots1.json) and [Q8 two-slot](quality-q8_0-slots2.json) results. This set cannot establish general quality or safety.

**Verdicts:** increasing offered load raises mean first-content latency in this capture. Two slots have lower observed mean TTFT at each rate/precision here, with substantial uncertainty; no universal engine, quantisation or hardware advantage follows. No configuration establishes the chosen **99% all-arrivals objective**: most conditions miss it even at the point estimate, and sixty successes in a low-load condition would still not establish a 99% population guarantee. The correct release verdict is **not established**, not “production-ready.” Longer prompts/outputs, sustained load, additional thread counts, more independent runs and a stronger held-out quality suite remain necessary for production selection.

## Real Runway authentication and shared token reservations

The [passing race-enabled test](integration-pass.txt) uses the existing Runway EdDSA JWT verifier, the pinned real model server and Redis 8. It proves unauthenticated rejection, streamed completion, a prompt reservation matching the server's **36-token** prompt usage, a shared tenant budget across two gateway handler instances, separate budgets for another tenant and exactly eight successful unit reservations among twenty concurrent attempts against a budget of eight.

The [first attempt](integration-first-attempt.txt) failed because Redis was unavailable; it is retained rather than presented as an application success. The corrected environment and strengthened token-parity test passed. The integration source is inline in the guide and reuses the existing Runway module's Redis/JWT packages. This is component integration, not proof that the complete API process, ingress, traces or cluster rollout has been exercised. A unit test also checks that shared-ledger failure returns 503 without local fallback. Fixed-minute budgets remain conservative reservations, not durable billing or tenant scheduling fairness.

## Signed model manifest checks

[Six checks](weight-verification.json) passed against a temporary copy of the real Q4 model: authorised bytes accepted; a changed model byte refused; a missing signature bundle refused; another public key refused; a valid signature with a nonmatching authorised manifest digest refused; restored authorised bytes accepted. The guide's verifier checks both the signature and `EXPECTED_MANIFEST_SHA256`, then hashes the model, inventory and provenance.

Public verification material: [manifest](manifest.json), [Sigstore bundle](manifest.sigstore.json), [test public key](signing-test.pub), [weight file inventory](weights.spdx.json), [provenance](provenance.json) and [tool versions](signing-tools.json). No private signing key or model weights are committed. Cosign **3.1.4** and Syft **1.57.0** were checked against their official release checksums before use. Syft's initial explicit-cataloger-name invocation was rejected; the working invocation uses the `file-metadata,digest` tags and writes output outside the scanned directory.

The signature belongs to a temporary **local test key**, not the model publisher. The historical publisher revision was not retained, and provenance states that limit explicitly. A file inventory cannot attest training data or establish parser safety. These checks do **not** establish signed container-image admission, immutable volume handling or key-rotation enforcement on Kubernetes; those remain separate live work.

## Remaining Phase 8 evidence

- Full Runway API startup integration, per-tenant scheduling behaviour, live scraping/tracing and the user-facing objective.
- Kubernetes cold/warm starts, the custom-metric adapter/HPA path, safe rollout and recovery.
- Signed container images, fail-closed admission, immutable weight distribution and trust-key rotation.
- Repeated full game day, including actual backend cancellation/slot recovery and resource exhaustion.
- Training across netlab's shaped link, killed-rank/checkpoint resume and network performance.
- Ray runtime/failure evidence beyond any local smoke checks separately recorded.
- NVIDIA GPU kernel/sanitizer, transfer/matmul and vLLM performance/quality/cost results. No GPU is available in this checkout.
- The final consolidated experimental report after those checks. This CPU report is an evidence increment, not completion of the entire phase.
