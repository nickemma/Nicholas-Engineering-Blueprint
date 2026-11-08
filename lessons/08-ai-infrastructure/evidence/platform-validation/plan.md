# Live platform validation plan and completion ledger

This increment extends the [initial CPU bundle](../2026-11-07/report.md). The [report](report.md) records the passing, failed and inconclusive observations. A checked item means its stated local lab scope has evidence; Phase 8 overall remains open. These runs extend Steps4–7,9–10,12 and the Step14 report. Step13 is hardware-blocked, and production serving acceptance in Steps2–3/8 remains open.

- [x] Isolated single-node kind cluster/kubeconfig; leave the original cluster untouched. Compatible kind0.33 is recorded after the old version failed bootstrap.
- [x] Integrate streamed generation into the actual Phase7 API composition root, using synthetic issuer JWT roles/tenant claims and real shared Redis reservations. Verify existing job routes.
- [x] Real Prometheus scrape/query and OTLP queue/tokenizer/reservation/stream spans; no bearer tokens or prompt literal in captured telemetry. Demonstrate immediate role events and HTTP200 truncation cannot count as fast completed content.
- [x] Signed model deployment with read-only source PVC and verified private copy; cold/warm readiness; actual API-visible replacement completion; insufficient startup allowance/restart and ten-request restoration.
- [x] Official Prometheus adapter exposes the actual waiting metric. HPA scales1→2 under queue pressure; both backend replicas process generation; preserve every arrival and ten subsequent completions. This stress workload misses the99% objective.
- [x] Distinguishing unsigned/wrong-key refusal and trusted-signature acceptance, public keyed SPDX attestation verification, revoked-key rejection and fully stopped webhook fail-closed case. Restrict image digest, command/env, mounts and ephemeral-container updates so the startup gate cannot be overridden through those pod settings.
- [x] Actual corrupted/missing-weight startup refusal; restored authorized artifacts become ready. Corruption/rollback repeated twice.
- [x] Six API faults twice: model crash, bounded overload, client reset with actual backend slot release, Redis outage, scraper loss and model OOM. Recovery is ten completed nonempty streams, not readiness alone.
- [x] Two CPU/Gloo ranks on isolated shaped container links: baseline,20ms per-egress/100Mbit, rank exit and100%loss. Verify bounded failure, real packet drops, checkpoint resume and serial model/update parity.
- [x] Pinned Ray tasks, actor deduplication/loss, worker-loss retry, two-worker Train parity and real Serve HTTP replies. Pin Protobuf6.33.5 after the retained7.36.2 incompatibility.
- [x] Public report, raw failures/recoveries, methods, tool/source digests and inventory/signature artifacts. No weights, kubeconfigs, model checkpoints, bearer tokens or private keys are published.
- [ ] CUDA kernel correctness/sanitizer, transfers/matmul timing and vLLM frozen-quality/performance grid. Local preflight and an actual capture invocation report no exposed NVIDIA device; no numerical GPU result exists.
- [ ] Production acceptance and extended ownership: longer/context-diverse serving, queue analysis, realistic quality/cost acceptance, scheduling fairness, physical multi-host/RDMA/overlap evidence, full trust-key replacement rollout, vulnerability clearance and months of operation. These are outside the passing local CPU mechanism checks.

The original Lessons and Site runs on `cfd5134` are green. The publication commit triggers fresh workflows; track those separately from local evidence and the earlier green head.
