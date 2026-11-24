# 01 Networking in depth

> Cloud and network track · Time 4 weeks at 12–15 hours a week · Status ready

## What you'll build

Build a repeatable network lab for the Cloud and network track. Measure what happens to transport throughput, request latency, and routing when a link is slow, congested, or reachable in only one direction. Use the resulting workload and report format as a baseline for the Rust edge proxy.

Build on the core’s TCP measurement method, Linux counters, and directed-link model. The live impairment experiments run inside disposable Linux network namespaces. The HTTP clients and the routing and partition models also run in an ordinary local workspace. [Linux, networking, and profiling](../../../2-core/06-linux-networking-and-profiling/README.md) · [Distributed-systems fundamentals](../../../2-core/07-distributed-systems-fundamentals/README.md)

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|
| 1 | 01 | [Calibrate a network you can break](lessons/01-calibrate-a-network-you-can-break.md) | Build the isolated path and check the direction, configured rate, idle RTT, and byte budget. |
| 1 | 02 | [Separate window limits from loss](lessons/02-separate-window-limits-from-loss.md) | Compare buffer, RTT, and loss changes using receiver goodput, retransmissions, and sender socket state. |
| 2 | 03 | [Compare congestion controllers on the same link](lessons/03-compare-congestion-controllers.md) | Compare Reno, CUBIC, and BBR where available, and measure concurrent flow shares. |
| 2 | 04 | [Measure a deep queue under load](lessons/04-measure-a-deep-queue-under-load.md) | Run paired FIFO and FQ-CoDel trials and compare idle RTT, loaded RTT, and goodput. |
| 2 | 05 | [Follow concurrent requests over HTTP/2 and HTTP/3](lessons/05-follow-http2-and-http3-streams.md) | Verify TLS and the negotiated protocols, then record per-object timings for matched warm and cold clients. |
| 3 | 06 | [Measure what an edge saves](lessons/06-measure-what-an-edge-saves.md) | Compare direct routing, proxying, and cache hits using response hashes and an origin counter. |
| 3 | 07 | [Withdraw an anycast site in a route simulator](lessons/07-withdraw-an-anycast-site.md) | Follow local preference and service withdrawal through bounded path-vector rounds. |
| 4 | 08 | [Diagnose a partial partition](lessons/08-diagnose-a-directed-partition.md) | Trace an asymmetric fault with directed UDP probes and a bounded job request through the proxy. |
| 4 | 09 | [Run the gate and defend the diagnosis](lessons/09-run-the-networking-gate.md) | Reconcile client observations with transport, origin, and route evidence. |

Lessons 01–08 cover the network experiments, including the operations game day’s asymmetric link and recovery check. [Core 08 game day](../../../2-core/08-shipping-safely/lessons/07-run-a-game-day-and-defend-the-decision.md)

## The gate

- Verify negotiated HTTP/2 and HTTP/3 against the same response hashes. Show that a warm edge hit returns the correct content while the origin request count stays fixed. Require a deliberately bypassed cache to fail that origin-count assertion.
- In the route and partition fixtures, check that a site withdrawal changes the selected route, that traffic can reach only one direction of the impaired link, and that healing restores the original connectivity checks. Require a check that treats reachability as symmetric to fail.
- In the live Linux lab, verify the offered rate and configured delay from observations, show retransmission evidence under loss, and compare idle and loaded RTT on deep and managed queues. Use repeat runs and record kernel features, measured counters, and spread. BBR results depend on kernel support. Report an unavailable controller explicitly.
- Run paired HTTP impairment trials with the same programmed link and request fixtures, saving negotiated protocols and per-object timings. The results describe the tested path and settings.

The routing experiments use a local model and send no route advertisements. Kernel queue and congestion-control measurements require permission to create disposable network namespaces. [Run the gate](gate/README.md) · [Reference captures](evidence/README.md)

## What good looks like

| Level | Here, you can… |
|---|---|
| Junior | Read a transfer trace, identify the negotiated HTTP protocol, and explain the path a cache hit avoids. |
| Intermediate | Diagnose a window limit, queueing, or one-way failure from independent observations. |
| Senior | Design matched measurements, explain the results and their variability, and defend what the failure trace tells an operator. |

## Practice

- Repeat the queue and path comparisons on a fixture you control. [Exercises](exercises.md)
- Predict the protocol, cache, and failure observations before reading the runs. [Self-check](self-check.md)

Continue to [A Rust edge proxy](../02-rust-edge-proxy/README.md).
