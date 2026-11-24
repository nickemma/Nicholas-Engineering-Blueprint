# 04 Capstone: a programmable edge proxy

> Cloud and network track · 2 weeks at 12–15 hours a week · Status ready

## What you'll ship

Package the Rust proxy and Go control plane as a standalone project with operator commands to start the services, publish and read back a route generation, roll back, and reproduce the measurements. Use the authenticated management path to change routes while the HTTP data plane keeps serving. Publish your project in a public repository or use a workplace deployment, with raw benchmarks, paired CPU flame graphs, and a design document or architecture decision record. [Rust proxy](../02-rust-edge-proxy/README.md) · [Control plane](../03-proxy-control-plane/README.md)

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|
| 1 | 01 | [Define the reload contract](lessons/01-define-the-reload-contract.md) | Establish publication as the cutover. Verify that a held request keeps its origin and a post-acknowledgement request sees the new route. |
| 1 | 02 | [Reload and roll back under traffic](lessons/02-reload-under-traffic.md) | Keep a paced workload running through multiple route changes, rollback, and a rejected candidate. Save the request outcomes and read-back generations. |
| 2 | 03 | [Measure throughput, latency, and memory](lessons/03-measure-throughput-and-memory.md) | Repeat the matched steady-state HTTP/1.1 comparison with direct and Envoy baselines. Measure managed Rust throughput, latency, and sampled RSS with and without reloads. |
| 2 | 04 | [Profile and change one hot path](lessons/04-profile-the-origin-uri-path.md) | Compare CPU stacks and unprofiled timings for equivalent URI inputs before and after caching the parsed origin authority. Check response and reload behavior again. |
| 2 | 05 | [Run the gate and package the release](lessons/05-package-and-verify-the-release.md) | Export locked source, run and benchmark commands, profiles, and the design record. Rebuild and run the gate from the export. |

The integration and release harness are new. The benchmark builds on the [Part 02 comparison](../02-rust-edge-proxy/evidence/README.md), including its direct baseline and accounting for driver drops.

## The gate

- Hold a request at origin A, publish a route to origin B, and send a new request after the acknowledgement. Require the held request to finish at A and the new request to finish at B. Repeat in reverse on rollback. Apply a disposable gate control that interrupts the held request at publication and require the continuity assertion to fail.
- Put a bounded workload through repeated reloads and at least one rejected update. Choose a load that completes cleanly in a preliminary steady run. Require every scheduled request to return the expected payload and an origin allowed by the observed cutover, with zero timeouts, resets, unexpected HTTP statuses, or driver drops in the reload trial. Verify the live generation and origin after rejection.
- Retain per-request outcomes, update timings, and RSS samples. Report steady-state and reload trials with the exact settings and run-to-run spread. Compare the before-and-after CPU profiles on equivalent requests. The gate accepts measured results with a supported interpretation, including a change that yields no speedup.
- Rebuild and run the portable checks from the standalone export. Include the benchmark and profile commands, exact reference captures, and the design decision record with the release.

[Run the gate](gate/README.md) · [Reference results](evidence/README.md) · [Standalone release archive](evidence/switchyard-edge-capstone.tar.gz)

## Practice

- Narrow the cutover window, compare reloads at several loads, and have another operator rebuild the release. [Exercises](exercises.md)
- Explain the boundary between the continuity, memory, and CPU evidence. [Self-check](self-check.md)
