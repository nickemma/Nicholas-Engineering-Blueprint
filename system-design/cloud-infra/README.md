# Cloud and infrastructure

For cloud, infrastructure, DevOps and SRE roles. These designs are about running things reliably and cheaply: regions, storage, networks, delivery and monitoring.

**Worked design:** [a metrics and alerting system](metrics-alerting.md). Do it yourself first, then compare.

**How to use the prompts:**
1. Set a 45-minute timer and design with the [template](../_template.md).
2. Open **the crux** only if you haven't named one by minute 10.
3. Open **what a strong answer covers** only after the timer, then score yourself with the [scorecard](../scorecard.md).

## 1. A multi-region web service

Take a single-region service (an API, a PostgreSQL database, a cache, a queue) to three regions. Users get p99 under 200 ms from anywhere. The service survives a whole region failing, with less than 1 minute of lost writes and under 15 minutes to recover.

<details><summary>The crux</summary>Where writes go. Reads are easy to replicate; writes need a home. The choice is between one primary region (simple, but slow for far-away writers, and a failover to manage) and data partitioned by user's home region, or multi-leader with conflicts. And the failover itself must be decided and rehearsed, not hoped for.</details>

<details><summary>What a strong answer covers</summary>

- RPO (data loss allowed) and RTO (time to recover) stated and designed for.
- Routing: DNS or anycast with health checks; latency-based routing.
- Data: one primary plus cross-region replicas (async replication, so writes since the last shipped change can be lost); or home regions per user; or a globally consistent database and its write latency.
- Stateless tiers everywhere; caches per region; queues per region with a story for in-flight messages.
- **Failover:** who decides (automated with a human, or fully manual), fencing the old primary, and a rehearsed runbook (a game day).
- Cost: cross-region traffic is billed. Estimate it.
</details>

**Built in:** [Phase 5](../../lessons/05-constrained-operations/README.md) (AWS with Terraform, game day), [Phase 4](../../lessons/04-replicated-state/README.md) (replication, fencing).

## 2. Object storage, like S3

Store objects from bytes to terabytes; 100 billion objects; 11 nines of durability; 100,000 GET requests a second; strong read-after-write consistency.

<details><summary>The crux</summary>Two separate systems with different shapes: a **metadata** service (a huge, strongly consistent key-value index of names to locations), and a **data** layer storing blobs durably and cheaply, with erasure coding instead of three full copies.</details>

<details><summary>What a strong answer covers</summary>

- Separate metadata and data paths; the metadata store is partitioned and replicated with consensus.
- Durability arithmetic: erasure coding (for example 6 data + 3 parity fragments) across failure domains is 1.5× storage, against 3× for replicas.
- Large objects in multipart chunks; uploads committed by writing the metadata last (atomic visibility).
- Background scrubbing (checksums) and repair.
- Read-after-write consistency comes from the metadata write.
- Listing by prefix needs ordered metadata (ranges, not hashes).
- Garbage collection of orphaned chunks.
</details>

**Built in:** [the Rust Bridge](../../lessons/rust-bridge/README.md) (checksums), [Phase 4](../../lessons/04-replicated-state/README.md) (consensus, ranges), [capstone 6](../../capstones/06-checkpoint-store.md) (a chunk store with a commit protocol).

## 3. A DNS service

Authoritative DNS for 10 million domains; 1 million queries a second worldwide; answers in under 10 ms from the nearest location; record changes visible within 60 seconds; survives DDoS.

<details><summary>The crux</summary>Serving a read-mostly dataset from many locations with tiny latency, and pushing changes out quickly and safely, while absorbing attacks with anycast and capacity.</details>

<details><summary>What a strong answer covers</summary>

- Anycast: many locations announce the same IP; the network routes to the nearest one.
- Every location holds the full zone data in memory (10 million domains is a few GB): no remote lookups.
- Changes: a control plane validates and versions zones, then distributes them (push with acknowledgement, plus periodic full sync).
- TTLs and their effect on change propagation.
- DDoS: anycast spreads load; rate limits per source; response rate limiting.
- Health-checked records for failover.
</details>

**Built in:** [Phase 5, step 4](../../lessons/05-constrained-operations/TEACHING.md#step-4-services-dns-and-load-balancing) (DNS inside Kubernetes), [Phase 2, step 7](../../lessons/02-connected-services/TEACHING.md#step-7-look-at-the-wire).

## 4. A CI/CD system

Build, test and deploy for 1,000 engineers: 5,000 builds a day, builds under 10 minutes, artifacts reproducible and signed, deploys traceable from commit to production.

<details><summary>The crux</summary>Fast, reliable builds at scale (caching and sandboxed workers), and a chain of trust from source to production: build once, sign, deploy by digest, verify at the cluster.</details>

<details><summary>What a strong answer covers</summary>

- Queue of build jobs; autoscaled, ephemeral, isolated workers.
- Caching: dependency caches, remote build caches keyed by input hashes.
- Flaky-test handling: quarantine, retries with tracking.
- **Build once, deploy by digest:** the same artifact promoted through environments.
- Supply chain: SBOMs, signatures (cosign), provenance (SLSA levels), admission control that verifies signatures.
- Secrets for builds: short-lived, scoped credentials.
- Failure: a compromised build worker. What can it sign?
</details>

**Built in:** [Phase 0](../../lessons/00-request-service/README.md) (CI), [Phase 5, step 8](../../lessons/05-constrained-operations/TEACHING.md#step-8-cicd-build-once-test-it-publish-it-by-digest), [the capstone's hardening stage](../../capstones/README.md).
