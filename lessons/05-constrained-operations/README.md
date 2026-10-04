# Phase 5: operate and measure under network constraints

> **Status: being rebuilt.** This phase is being rewritten to the [Phase 0](../00-request-service/TEACHING.md) standard: full code in `steps/`, real expected output, and CI checks. Until then, this page and TEACHING.md are an outline, and the authoritative plan for this phase is in [JOURNEY.md](../../JOURNEY.md#4-the-route).

This page previews the concepts, tools, readings, and exit evidence. Follow the full [self-study teaching guide](TEACHING.md) and record your work in [learned.md](learned.md).

The ordered reading list is embedded at the end of [TEACHING.md](TEACHING.md), beside the deployment and operations work.

## Question and build

Can an operator deploy the API slice, observe it on a constrained link, and recover from failure?

Containerize and deploy the Phase 1 API slice to a local Kubernetes cluster. Its job map is deliberately in memory; the deployment does not include the Phase 2 broker, Phase 3 database, or Phase 4 lab cluster. Learn Terraform by validating and planning a small configuration; a paid cloud deployment is not required. The deployment and fault setup must be reproducible.

## Teach in this order

1. **Understand the process boundary.** Start with a small container and inspect namespaces, cgroups, images, and resource limits. Explain that a container is isolated processes, not a tiny virtual machine.
2. **Run the local cluster.** Teach Kubernetes objects and control loops by deploying one API replica. Delete its Pod and observe that Kubernetes replaces the process while the in-memory jobs disappear.
3. **Describe deployment.** Add HCL/Terraform for a small cloud environment; explain VPC, IAM, managed services, and state before applying it.
4. **Make this API slice observable.** Add request logs, request counters, a latency histogram, and an in-memory job-count gauge. Use Docker stats for container CPU/memory; do not imply database or worker metrics exist in this deployment.
5. **Measure constrained links.** Teach IP/subnets and network paths with an isolated veth pair. Apply delay, loss, and bandwidth limits only to that pair and measure health-request behavior.
6. **Write a bounded SLO.** Define a request-availability/latency objective for a stated workload. Freshness and queue age require the later integrated data/worker path.
7. **Operate a game day.** Delete the API Pod or inject link delay, follow the runbook, diagnose from telemetry, recover, and write a postmortem.

## Foundations closed

Namespaces/cgroups, container and local Kubernetes operations, Terraform/HCL planning, cloud VPC/IAM concepts, request telemetry, SLOs, runbooks, incident exercises, and isolated constrained-network measurements. This develops platform/operations evidence; it does not include production on-call, cloud deployment, or full-stack capacity testing.

## Reading placement

Read OSTEP virtualization/scheduling before containers; CSAPP linking while building images; Kubernetes in Action while deploying each object; Kurose & Ross DNS/IP/data-center networking during network labs; SRE chapters while writing SLOs and operating dashboards; OSTEP paging and Systems Performance while profiling. Read Borg when operating the cluster-management layer.

## Exit evidence and career signal

Recreate the API-slice deployment from configuration, inject a documented fault, diagnose it with dashboards/logs/runbooks, and publish availability, latency, bandwidth, resource, and recovery measurements. Freshness requires the integrated data/worker path. Write a postmortem.

This makes SRE, Platform, DevOps, and Infrastructure applications more evidence-based. It does not supply real production on-call experience.
