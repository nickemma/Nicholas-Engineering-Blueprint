# Phase 8 live platform validation

Recorded 2026-11-07 Pacific time (some Kubernetes timestamps are 2026-11-08 UTC). This extends the [initial CPU report](../2026-11-07/report.md). **This increment validates the CPU platform path; Phase 8 remains incomplete because CUDA/vLLM has not run.** It does not establish production readiness, scheduling fairness, an accepted quality/cost configuration or a 99% SLO.

## What ran

| Area | Observed result | Evidence |
|---|---|---|
| Real Runway API | Actual Phase 7 composition root; synthetic issuer JWTs; 401 without token, 403 for reader, tenant-isolated jobs and completed generation for two tenants | [API checks](api-checks.json), [probes](api-probes.json) |
| Metrics and traces | Prometheus scrape/query and OTLP queue, tokenizer, reservation and stream spans; no bearer tokens or prompt literal in captured telemetry | [metrics](api-metrics.txt), [query](prometheus-query.json), [trace excerpt](collector-traces.txt), [complete collector log](collector-traces.txt.gz) |
| First content versus first byte | Immediate role event was received within one second; content arrived after two seconds. Completed slow response and truncated HTTP-200 response both contributed zero good requests; truncation counted incomplete | [fault check](observability-faults.json), [metrics](observability-fault-metrics.txt) |
| Kubernetes startup | Signed, nonroot, read-only-root model deployment; private verified weight copy. Creation-to-Ready was 28 s with first image pull and 4 s on cached replacement; container-start-to-Ready was 4 s and 3 s. Timestamps have one-second precision | [startup records](kubernetes-checks.json), [deployment](model-deployment.json) |
| Image admission | Unsigned image refused for no signatures; wrong key refused for signature mismatch; trusted signature accepted. TLS errors were corrected before counting these results | [admission](admission-checks.json), [public test key](image-signing-test.pub) |
| Verification and enforcement | Two corrupt-weight startups refused; missing bundle refused; restored artifacts became ready. Revoked key refused; a fully stopped webhook failed closed. Command/env/image and ephemeral-container overrides were denied | [Kubernetes faults](kubernetes-faults.json), [override cases](kubernetes-checks.json), [ephemeral-container refusal](ephemeral-override-check.json) |
| Queue scaling and routing | Official adapter exposed the actual waiting gauge (peak 5). HPA requested 1→2 replicas about 13.2 s after load began; both replicas logged generation work; ten completed requests followed | [HPA raw samples/arrivals](hpa-checks.json), [in-cluster API route](cluster-api-route.json) |
| CPU training network | Baseline and 20 ms per-egress/100 Mbit shaping matched serial SGD. Worker exit and 100% packet loss both failed boundedly, then resumed step 3→6 from checkpoint and matched the uninterrupted model/optimizer updates | [network checks](network-checks.json), [rank transcripts](network-transcripts.txt) |
| Ray | Pinned tasks/actor example, worker-loss retry, actor-loss boundary, two-worker CPU Train serial parity, and five real Serve HTTP replies passed | [Ray checks](ray-checks.json), [runtime transcript](ray-runtime.txt), [resolved lock](ray-uv.lock) |
| GPU | No NVIDIA device/driver interface or CUDA tools exposed; CPU-only Torch. CUDA sanitizer, transfer/matmul timing and vLLM remain **not measured** | [preflight](gpu-preflight.json), [actual capture refusal](gpu-capture-attempt.json) |

The full guide replay passed locally (54 extracted actions). Runtime evidence uses the current guide's API/gateway adapter with an existing Phase 7 scratch module. The repository parent is `cfd5134`; source digests and tool versions are recorded in [environment.json](environment.json). The existing Lessons and Site workflows on that base commit both passed. New publication CI is a separate run, not inferred from those results.

## Game day

Recovery means ten consecutive nonempty streams ending in `[DONE]`, not merely a green health endpoint. Times include mitigation and those ten requests. These are two local repetitions, not population estimates or a promised recovery SLA.

| Fault | Repetition 1 | Repetition 2 | Observed boundary |
|---|---:|---:|---|
| Kill model process | 6.385 s | 4.127 s | 502 while unavailable; restore known image |
| Redis unavailable | 4.127 s | 3.652 s | Shared reservations fail closed with 503 |
| Bounded overload | 32.734 s | 34.259 s | Every one of 18 simultaneous arrivals retained; 10/12 failed respectively, including admission/deadline failures |
| Client disconnect | 3.048 s | 4.245 s | Actual model slot active before reset, then returned idle |
| Metrics scraper lost | 3.803 s | 4.320 s | Scraper unavailable while synthetic generation still completed |
| Model memory exhaustion | 4.577 s | 5.691 s | 32 MiB cgroup cap plus decode produced actual OOMKilled; restoring 2 GiB recovered |

[Raw fault/recovery rows](game-day.json) include failures and monotonic timestamps. Corrupt-model refusal/rollback was also repeated twice in [Kubernetes](kubernetes-faults.json). The startup follow-up measured the first API-visible completed request 4.641 s after replacement began, a deliberately insufficient startup allowance causing a restart, and restoration of the ten-request contract in [startup checks](startup-checks.json).

The scale experiment deliberately offered long responses with eight concurrent producers for roughly 65 seconds. Of 26 arrivals, four failed and only one completed with client first content within one second. It demonstrates the scaling/routing mechanism under pressure; it **contradicts achieving the chosen 99% objective for this workload**. It is not an open-loop capacity or quality acceptance benchmark. No engine speedup, tenant fairness or multi-node availability claim follows from adding a replica.

## Corrections and limits

- The old system kind 0.23 could not bootstrap Kubernetes 1.37; compatible kind 0.33 created a separate cluster. The original user cluster and default kubeconfig were not changed.
- A mis-shaped registry CA chart value first caused all admission attempts to fail at TLS. That was not signature evidence. A ConfigMap-based CA mount and a new unsigned repository produced the retained discriminating negative/positive cases.
- Scaling the webhook to zero did not immediately stop the terminating pod; it could still answer during its grace period. The passing fail-closed test stopped that owned pod before checking refusal. This is a control-plane outage exercise, not a measured revocation propagation SLA.
- The first HPA assertion expected HTTP access-log text this server does not emit. [Retained logs](hpa-log-probe.json) already showed generation slot work on both replicas. The corrected run used slot launch/timing evidence and retained every arrival and HPA sample.
- A 128 MiB cap on the already loaded mmap model did not produce an OOM; [that attempt is preserved](game-day-memory-attempt.json). A later restart with that cap was also insufficient to load. The passing fault used 32 MiB plus decode and checked the actual OOMKilled flag.
- Ray 2.49.2 Train worked with Protobuf 7.36.2, but Serve failed because `FieldDescriptor.label` was removed. Pinning 6.33.5 fixed Serve. Actor deduplication remains in memory; recreating the actor loses it. A retry does not establish durable exactly-once writes.
- This is one 16-CPU/~8-GiB host, CPU model serving, one-node kind, and host-backed read-only PVC storage. API/issuer/Redis/Prometheus/collector run as separate owned Docker processes. Jobs used in-memory development storage; SQL, Kafka, mTLS, multi-node failure and production NetworkPolicy enforcement were not revalidated by these runs.
- The local image signer establishes the chosen lab trust authority, not the publisher's identity. Image signatures used pinned-key legacy mode without image transparency-log publication; the model manifest's existing Sigstore bundle was separately verified against public trust roots. The historical model publisher revision remains unknown. The [image SBOM](model-image.spdx.json.gz) is an inventory, not a vulnerability clearance; [summary](model-sbom-summary.json). Its SPDX attestation was signed and verified against the same lab key ([verification summary](model-attestation-summary.json), [retained DSSE](model-sbom-attestation.dsse.json.gz)); transparency-log verification was explicitly outside this local-key exercise.
- Longer/context-diverse serving, independent queue/Little's-law analysis, production quality/cost acceptance, multi-host/RDMA and distributed-overlap performance, a complete trust-key replacement rollout, and months of ownership evidence remain future work. GPU hardware is required for Step 13; no paid GPU was provisioned.

## Reproduction and ownership

[Methods and final harnesses](methods.md) retain the assertions and exact resource scope. The [plan](plan.md) distinguishes planned work from measured results. Secrets, private keys, kubeconfigs, weight blobs and model checkpoints stay out of Git. The image/model public digests, refusal outputs, raw arrivals and public signer are reviewable here. Long-running service ownership and external review criteria in the assessment track still require a learner/operator to perform them.
