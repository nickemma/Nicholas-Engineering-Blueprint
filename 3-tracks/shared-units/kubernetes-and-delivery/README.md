# Kubernetes and delivery

> Shared unit · Time: 5 weeks at 12–15 hours a week · Builds on [Docker and Postgres](../../../2-core/03-docker-and-postgres/README.md), [Distributed-systems fundamentals](../../../2-core/07-distributed-systems-fundamentals/README.md), and [Shipping safely](../../../2-core/08-shipping-safely/README.md) · Used by all three tracks · Status: ready

## What you'll build

Deploy Switchyard on a local kind cluster. Put the jobs API and worker from Core 03 behind Kubernetes Services, with PostgreSQL on persistent storage. Run the Core 07 metadata peers as a StatefulSet with a claim per peer. Deploy the Core 08 gateway on the client path and carry inter-Pod Raft messages over a separate authenticated transport. Package the workloads in Helm, verify images by digest, and use client observations to decide whether a release can proceed.

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [Run Switchyard on kind](lessons/01-run-switchyard-on-kind.md) | Build the jobs API and worker into images. Run the API as a Deployment and compare startup, readiness, and liveness probes during a slow start and a restart. |
| 1 | 02 | [Reach a service by name](lessons/02-reach-a-service-by-name.md) | Use Services and DNS for stable discovery. Route requests through a layer-7 entry point and observe how endpoint membership changes when a replica loses readiness. |
| 2 | 03 | [Deploy the jobs path with persistent storage](lessons/03-deploy-the-jobs-path-with-persistent-storage.md) | Deploy the API, worker, and PostgreSQL with migrations, secrets, resource requests, and a persistent claim. Submit a job through the API and verify completion after a worker restart. |
| 2 | 04 | [Give each Raft peer a stable identity](lessons/04-give-each-raft-peer-a-stable-identity.md) | Add an authenticated network transport for Raft between Pods while retaining the Core 07 Unix-socket mode for local replay. Map StatefulSet ordinals to peer IDs and give each voter its own Rust log volume. Verify election and recovery after replacing a voter. |
| 3 | 05 | [Roll out a canary with Helm](lessons/05-roll-out-a-canary-with-helm.md) | Package the workload. Send a synthetic client to the canary, compare its result with the stable release, and make the promote-or-rollback decision explicit. |
| 3 | 06 | [Build once and promote by digest](lessons/06-build-once-and-promote-by-digest.md) | Build an image, publish it to the lab registry, attach an image SBOM, and sign the digest. Verify the expected signer and digest before deploying the same artifact to the canary and stable targets. |
| 4 | 07 | [Follow a request through the cluster](lessons/07-follow-a-request-through-the-cluster.md) | Send Core 06 traces to an OpenTelemetry Collector. Confirm that a single request retains its trace identity across the gateway and service boundary. |
| 4 | 08 | [Alert on budget burn](lessons/08-alert-on-budget-burn.md) | Use Prometheus and Grafana to compare request outcomes against the Core 08 SLO. Run short, explicitly scaled lab windows to verify that a sustained failure fires and recovery clears the alert. |
| 5 | 09 | [Reconcile worker replicas against backlog](lessons/09-reconcile-worker-replicas-against-backlog.md) | Use the Core 03 durable queue as the backlog source. Reconcile the worker Deployment within fixed bounds and give the controller permission to change only its scale subresource. |
| 5 | 10 | [Enforce the deployment boundary](lessons/10-enforce-the-deployment-boundary.md) | Apply restricted Pod Security, workload RBAC, and network policy. Use a policy-capable kind network and check both required connectivity and denied connectivity in the lab namespace. Run the release and recovery gate. |

The live lab uses a local cluster and registry. The offline gate covers chart rendering, Go behavior, and promotion checks. The live gate exercises the running workloads and records their client-visible outcomes.

## The gate

The [live gate](gate/README.md) deploys a digest whose signature and attached SBOM are verified. Record a completed job and a committed metadata value. Release a canary whose image starts but whose readiness check fails. Verify that the release procedure withholds promotion and that the stable client endpoint remains usable. Restore the last known good digest, replace a metadata voter, and check that it reuses its claim and catches up. Read the original job result and metadata value through their client entry points.

- The running workload uses the verified digest. An unsigned candidate fails the pre-deploy verification check.
- Stable service remains usable during the failed canary. The same readiness assertion must fail on a disposable rollout variant that skips the promotion check.
- Track canary and stable probe results separately so the failed canary raises its own alert while the stable endpoint stays healthy. Restoring a healthy candidate clears the canary alert within the lab window.
- The replaced voter reaches the committed prefix using its existing volume. The controller can scale the worker and lacks permission to edit the Deployment's other fields. The network checks show both permitted service traffic and denied traffic from a test workload.

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Read Pod events, locate a Service endpoint, and explain why a replacement Pod can reuse its storage. |
| Intermediate | Trace a failed rollout through checks, routing, alerts, and image identity. Demonstrate rollback without losing client state. |
| Senior | Defend the rollout and permission boundaries, choose a client signal for promotion, and explain the trade-offs in peer readiness and persistent identity. |

## Practice

- [Exercise](exercises.md). Package a separate service and practice a failed rollout.
- [Build the Kubernetes workload lab](deep-dives/workloads-and-rollouts.md). Follow a Deployment, DaemonSet and Job through a failed rollout and rollback.
- [Rebuild with Tilt and plan a remote cluster](deep-dives/development-and-provisioning.md). Verify a source change on kind and test an EKS plan with a mock provider.
- [Rotate a mounted Sealed Secret](deep-dives/rotate-a-sealed-secret.md). Verify live rotation and that a Secret copied to the wrong name cannot unseal.
- [Observe throttling, memory kills and preemption](deep-dives/requests-limits-and-priority.md). Follow each outcome to the runtime or scheduler.
- [Build a Kubebuilder operator](deep-dives/report-operator.md). Reconcile one Job and verify finalizer cleanup.
- [Recover Consul and PostgreSQL](deep-dives/stateful-recovery.md). Reuse a claim after leader loss, then verify a database writer moves and the former primary rejoins read-only.
- [Platform practice](exercises.md#kubernetes-platform-extensions). Extend the builds to a workload you own.
- [Self-check](self-check.md). Explain the rollout, data, and access boundaries from memory.
- [Evidence](evidence/README.md). Read the local build and cluster results.
