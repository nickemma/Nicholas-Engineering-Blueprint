# Phase 5: operate it

**Question:** can you deploy Runway, see inside it while it runs, know when users are hurting, change it without dropping requests, and recover it when it breaks?

**Time:** about 9 weeks. **Prerequisites:** [Phase 4](../04-replicated-state/README.md); Docker, kind, kubectl, Helm and Terraform (the [guide](TEACHING.md#setup) lists versions). An AWS account is optional: only applying step 13's Terraform needs one, and it costs money while it runs.

## Syllabus

| Step | Topic | You'll learn |
|---|---|---|
| 1 | Containers are processes | Namespaces and cgroups; images, layers and multi-stage builds; distroless; OOM kills and exit 137; PID 1 and signals; why `127.0.0.1` fails in a container |
| 2 | Runway in Docker Compose | Twelve-factor config; service discovery by DNS; health checks that test what clients need; start order; advertised listeners |
| 3 | Kubernetes on kind | Desired state and control loops; Pods, Deployments, ReplicaSets, the scheduler and the kubelet; liveness vs readiness; requests and limits; rollouts that stall instead of failing; what a dead node costs and why |
| 4 | Services, DNS and load balancing | Virtual IPs and kube-proxy's iptables rules; EndpointSlices; cluster DNS and `ndots`; headless Services; layer 4 vs layer 7; why gRPC defeats per-connection balancing; the power of two choices; outlier ejection; a balancer of your own |
| 5 | All of Runway on Kubernetes | StatefulSets, PersistentVolumes and claims; ConfigMaps and Secrets; a migration Job; start order; what a StatefulSet keeps when a Pod dies |
| 6 | `metad` as a StatefulSet | Ordinals as identity; the `OrderedReady` deadlock; publishing addresses before readiness; PodDisruptionBudgets; anti-affinity; local storage pinning a Pod to a node |
| 7 | Helm and safe rollouts | Charts, values, templates and releases; hooks; config checksums; the shutdown race and the `preStop` sleep, measured; why a pooled client misses it; rollback; canaries |
| 8 | CI/CD | Build once, test the artifact, publish it; a smoke test on a throwaway cluster; tags, digests and image IDs; least-privilege pipelines |
| 9 | Tracing | Spans, traces and context propagation; `traceparent`; carrying a trace through an outbox and a broker; the OpenTelemetry SDK and collector; Jaeger; gateway vs sidecar |
| 10 | Metrics, SLOs and alerts | SLIs, SLOs and error budgets; multi-window burn-rate alerts; recording rules; testing alert rules with promtool; the USE method; service discovery and relabelling; Grafana provisioning |
| 11 | A controller of your own | Level-triggered reconciliation; the scale subresource; stabilization windows; client-go and its fake clientset; RBAC and least privilege; one owner per field |
| 12 | A game day | Hypotheses before experiments; netem and partial partitions; triggers and amplifiers; backpressure vs failure; why readiness shouldn't check a shared dependency; runbooks; blameless postmortems |
| 13 | Runway on AWS | Infrastructure as code; plans and state; VPCs, subnets and security groups; IAM roles for tasks; RDS, SQS, ECS on Fargate, load balancers, CloudWatch; cost as a design constraint; an SQS adapter |

## What you'll be able to do

- Package a service as a small, locked-down image, and explain what a container is to the kernel.
- Run a multi-service system on Kubernetes, choosing the right object for each part, and explain what each controller does when something fails.
- Explain and measure load balancing at layer 4 and layer 7, and write a balancer.
- Ship changes with Helm without dropping requests, roll back, and run a canary.
- Build a pipeline that tests the exact artifact it publishes.
- Trace one request across processes, a database outbox and a broker.
- Define SLOs, alert on burn rate with tested rules, and find causes with the USE method.
- Write a Kubernetes controller with least privilege.
- Run a game day, find an amplifier, fix it, and write the postmortem.
- Describe a cloud deployment in Terraform, review its plan, and say what it costs.

## How to work through it

1. Follow [TEACHING.md](TEACHING.md), typing every piece of code yourself, starting from your Phase 4 code.
2. Do every "Run it" and "Break it" on your own cluster. Your names and timings will differ; the shapes shouldn't. Write each game-day hypothesis down *before* running the experiment.
3. Answer [learned.md](learned.md).
4. Build the exercise project, **[beacon](exercises.md)**, a synthetic-monitoring service, on your own, and operate it the same way. The exercise page shows exactly what finished looks like.
5. Take the [self-test](../../notes/learned/05-constrained-operations.md).

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where | Evidence |
|---|---|---|
| Containers and Kubernetes (row 23) | Steps 1–7, 11 | Manifests, a Helm chart, a controller; the node-failure and deadlock experiments |
| Load balancing and service discovery (row 24) | Steps 4, 7 | kube-proxy's rules; L4 vs L7 and two-choices measurements; the rollout drop count |
| Cloud (AWS) and infrastructure as code (row 25) | Step 13 | A Terraform plan of 60 resources, checked in CI |
| Observability and SLOs (row 26) | Steps 9–10 | A 36-span trace; burn-rate alerts with promtool tests; the page during an outage |
| Incident response (row 27) | Step 12 | A game day, a runbook and a postmortem |
| Git, GitHub and CI (row 2) | Step 8 | A build-once pipeline with a smoke test and digests |
| Processes, signals, file descriptors (row 7) | Step 1 | Namespaces by hand; exit 137; PID 1 and `SIGTERM` |
| Sockets, TCP/UDP, DNS (row 11) | Steps 2, 4 | Compose and cluster DNS; per-connection balancing and gRPC |
| Failure models, clocks, consensus (row 20) | Steps 6, 12 | `metad` on Kubernetes; partial partitions on a real network |

## Patterns introduced

These link to the [patterns ledger](../../JOURNEY.md#6-patterns-ledger):
- reconciliation loop;
- liveness vs readiness;
- load balancing and service discovery;
- canary rollout;
- twelve-factor config;
- infrastructure as code;
- build once, deploy by digest;
- backpressure;
- crash-only design, revisited (every Pod is disposable).

## Next

Runway runs, scales, heals and tells you when it's hurting. But anyone who can reach it can use it, every tenant's jobs are mixed together, and its services trust each other completely. [Phase 6](../06-safe-shared-queries/README.md) secures it.
