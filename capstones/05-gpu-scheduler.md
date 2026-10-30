# 5. Scheduling GPU work on Kubernetes: memory, fragmentation and SLOs

**Field:** AI infrastructure · cloud · scheduling · **Difficulty:** very high · **Language:** Go

## Problem

GPUs are the most expensive resource in a cluster, and Kubernetes's default scheduler sees them as whole, countable devices (`nvidia.com/gpu: 1`). It doesn't know:

- how much GPU memory a job needs;
- whether two jobs could share one partitioned GPU;
- that small jobs scattered across GPUs leave none free for a large one (**fragmentation**);
- that a serving deployment is about to miss its latency objective.

The result is idle GPUs next to queued jobs, large jobs that starve, and missed deadlines, on hardware that costs dollars per GPU-hour.

## Who

ML platform teams sharing one GPU cluster between training, batch inference, embedding jobs and online serving, across several teams with quotas.

## Gap

- Research schedulers showed large gains from scheduling built for deep learning:
  - Gandiva (Xiao et al., OSDI 2018);
  - Tiresias (Gu et al., NSDI 2019);
  - Themis (Mahajan et al., NSDI 2020);
  - Gavel (Narayanan et al., OSDI 2020).
- Traces of production clusters show low GPU utilisation and fragmentation: Microsoft's (Jeon et al., USENIX ATC 2019) and Alibaba's (Weng et al., NSDI 2022, with a public trace).
- Kubernetes now has pieces:
  - [Kueue](https://kueue.sigs.k8s.io/) for quotas and queueing;
  - [Volcano](https://volcano.sh/) for gang scheduling;
  - NVIDIA's device plugin and GPU partitioning (MIG);
  - dynamic resource allocation.
- How a small, transparent operator compares with these, on a **mixed** serving-plus-batch workload, is rarely measured. Such an operator would combine memory-aware placement, fair share and SLO-driven preemption.

## Research question

> On a mixed workload of online serving with latency objectives and batch jobs with deadlines, does a scheduler that places work by GPU memory and fragmentation, and preempts batch work when a serving objective's error budget burns, raise GPU utilisation and cut deadline misses compared with first-come-first-served, best-fit and priority-only policies, without starving any tenant?

## Hypothesis and baseline

- **Baselines:**
  - first-come-first-served with whole GPUs (what the default scheduler effectively does);
  - best-fit by memory;
  - strict priority.
- **Hypothesis:**
  - memory- and fragmentation-aware placement raises utilisation;
  - SLO-driven preemption protects serving at a measurable cost to batch completion times;
  - without a fair-share term, large jobs from small tenants starve.

## System

- **Custom resources:**
  - `GPUJob`: GPU memory, GPU count, priority, deadline, tenant, and whether it can be preempted;
  - `ModelDeployment`: model memory, replicas, and a time-to-first-token objective.
- **An operator in Go** with controller-runtime, built like Phase 5's reconciler. It owns the job state machine:

  queued → admitted → placed → running → done | failed | preempted

- **The scheduler:** holds Pods with scheduling gates until the operator picks a node and a GPU slice, so the placement policy is the operator's and is easy to swap.
- **Simulated GPUs:**
  - nodes advertise fake GPUs as extended resources;
  - a node agent reports per-GPU memory and utilisation;
  - job runners burn time according to a runtime model.
- **Heartbeats and reconciliation:** when an agent stops reporting, its GPUs are marked lost and their jobs requeued.
- **Durable state:** jobs and decisions in PostgreSQL (Phase 3), so the operator can crash and resume.
- **A simulation mode:** the same policy code, driven by a discrete-event simulator, replays thousands of jobs from the Alibaba trace in minutes. **Check the simulator against kind** on a small workload before trusting its large-scale numbers. That fidelity check is part of the result.

A crucial detail: free GPU memory doesn't tell you everything. Model residency (whether the weights are already loaded), fragmentation, interference between jobs sharing a GPU, and hardware topology also matter. Model what you can, and state what you left out.

## Suggested stack

| Part | Choice | Why |
|---|---|---|
| Operator, scheduler, node agent, API | Go, controller-runtime | Reconciliation loops and Kubernetes' own libraries |
| Job state | PostgreSQL | Durable decisions, and an audit of why each job went where |
| Simulator | Go, sharing the policy package | One implementation of each policy, two drivers |
| Placement optimiser | Rust, **only** if profiling shows the Go solver is too slow at 10,000 pending jobs | Measure before adding a language |
| Messaging | None at first. NATS or RabbitMQ only if asynchronous delivery becomes necessary | Kubernetes' watch already delivers events |
| GPUs | Simulated; then, optionally, the NVIDIA device plugin and DCGM on a rented GPU node | The scheduler's behaviour must be testable without hardware |

## Features to implement

1. Resource-aware placement on GPU memory, capacity and job requirements.
2. Fair scheduling across tenants (dominant-resource or weighted fair share).
3. Priority queues with aging, so nothing starves.
4. Cancellation, deadlines and retry policies.
5. Worker heartbeats, and reconciliation after crashes.
6. Admission control when the cluster can't take more work.
7. SLO-driven preemption or migration of batch work when a serving deployment's error budget burns (Phase 5's burn rates).
8. A simulation mode for hundreds or thousands of jobs without renting a cluster.

## Experiment

| Variable | Values |
|---|---|
| Policy | First-come-first-served; best-fit; priority; fragmentation-aware + fair share; the same + SLO-driven preemption |
| Workload | Alibaba GPU trace segments; synthetic mixes of serving, batch and training |
| Load | 50%, 80%, 100%, 120% of capacity |
| Cluster | 8, 64 and 512 simulated GPUs; 8 on kind |
| Failures | Node loss mid-run; a node agent that stops reporting but keeps running jobs |

## Measures

- Job completion time and queueing delay (p50, p99).
- GPU utilisation: allocated, and actually busy.
- Deadline misses.
- Serving objective attainment.
- Fairness: Jain's index across tenants, and the worst tenant's slowdown.
- Failed placements and preemptions.
- Scheduler decision latency at 1,000 and 10,000 pending jobs.

## Benchmark your work

- **Scale:** decision latency as pending jobs grow; Go benchmarks for the placement function.
- **Throughput versus latency:** jobs per hour against queueing delay p99 as load rises; where each policy's queue explodes.
- **Failures:** time from node loss to every job being rescheduled, and jobs lost or duplicated (there should be none).
- **Fidelity:** simulator against kind on the same 200-job workload; report the gap.
- **GPU utilisation** on real hardware, if you rent it: DCGM's utilisation and memory metrics next to the scheduler's own accounting.
- **Rigour:** at least 5 seeds per condition, intervals on every difference, and the trace segment and policy parameters recorded.

## What you might find

Packing by memory may raise utilisation sharply at high load and barely matter at low load. Preemption may protect serving but cost batch jobs more than expected because of restart overhead. The simulator may disagree with kind about where queues explode, and explaining why is a finding in itself.

## Limitations to expect

- Simulated GPUs don't interfere with each other the way real ones do.
- Trace runtimes are taken as given, though real runtimes depend on placement.
- MIG partitioning needs specific GPUs, so it's modelled, not run.

## Skills used

Phases 3 (durable state), 4 (failure models, leases), 5 (Kubernetes, controllers, SLOs, burn rates), 7 (experimental method, scheduling with predictions) and 8 (GPU resources, serving).

## Read first

- Xiao et al., *Gandiva: Introspective Cluster Scheduling for Deep Learning*, OSDI 2018
- Gu et al., *Tiresias: A GPU Cluster Manager for Distributed Deep Learning*, NSDI 2019
- Narayanan et al., *Heterogeneity-Aware Cluster Scheduling Policies for Deep Learning Workloads*, OSDI 2020
- Jeon et al., *Analysis of Large-Scale Multi-Tenant GPU Clusters for DNN Training Workloads*, USENIX ATC 2019
- Weng et al., *MLaaS in the Wild: Workload Analysis and Scheduling in Large-Scale Heterogeneous GPU Clusters*, NSDI 2022
- Ghodsi et al., *Dominant Resource Fairness: Fair Allocation of Multiple Resource Types*, NSDI 2011
