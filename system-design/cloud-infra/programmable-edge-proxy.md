# Design a programmable edge proxy

## The crux

Publish a new route while accepted requests keep the origin they selected. Define which requests can observe the new route, what the acknowledgement proves, and how an operator safely rolls back.

## Requirements and interfaces

1. Proxy HTTP/1.1 requests to two configured origin slots. Keep upstream pool and breaker state per physical origin.
2. Accept management updates from the authenticated controller. Check candidate health, apply a newer generation, and expose the active generation and digest.
3. Preserve responses already in flight. Require requests sent after an acknowledgement to use the new route until another publication can overlap.
4. Verify a bounded reload workload at 120 offered req/s and provide measured throughput, tail latency and proxy RSS. Treat these as lab validation targets.

| Interface | Responsibility |
|---|---|
| Client HTTP listener | Select an origin from the current mapping once per request and forward within the upstream budget. |
| Controller and mTLS sidecar | Check candidate health and both peer identities. Relay a bounded administrative message over the private Unix socket. |
| Rust admin endpoint | Validate mapping, generation and digest before publishing. Acknowledge an identical retry and reject stale or conflicting content. |

~~~mermaid
flowchart LR
    Client --> Proxy[Rust HTTP proxy]
    Proxy --> A[Origin A]
    Proxy --> B[Origin B]
    Controller -->|mTLS| Sidecar[Go sidecar]
    Sidecar -->|Unix socket| Proxy
~~~

## Failure timeline

Hold a request at A. Publish generation one to B and observe its acknowledgement. Send a fresh request and verify B before releasing A. The held request returns A's bytes. Publish the original order as generation two and repeat in reverse. Next, an unhealthy candidate for generation three fails preflight. Status still reads generation two and requests keep following its mapping. A test that invalidates held work when the route changes returns 503 and fails the continuity assertion. [Reload history](../../3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy/evidence/reference/managed/Reload-1.json) · [Gate transcript](../../3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy/evidence/reference/portable.txt)

## Tradeoff and capacity

Publishing a snapshot keeps a route change local to a short state update. Restarting proxy workers for each route change would require listener handoff and draining, and reselecting an origin before replying would let a new route invalidate accepted work. The lab keeps the active generation in memory. An operator must retain and reconcile desired state after restart. A health check is a sample and can become stale before use. Per-origin timeouts and limits still bound that failure. [Decision record](../../3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy/evidence/ADR.md)

The local reload trials served all 720 requests at 120 offered req/s. Separate steady-state runs compared direct, Rust and Envoy paths at 200 and 2,500 req/s with one 4 KiB object. The reload result establishes continuity for the tested schedule. Use the steady runs to discuss workload latency and RSS, and run a new saturation experiment before setting fleet capacity. [Benchmark and profiles](../../3-tracks/cloud-and-network/04-capstone-programmable-edge-proxy/evidence/README.md)

For a timed review, explain how to handle a lost acknowledgement and sketch how a second proxy would converge on the desired generation. Score the tradeoff and failure timeline with the [design scorecard](../scorecard.md).
