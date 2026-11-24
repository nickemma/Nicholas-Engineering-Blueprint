# ADR 001 · Publish route generations without disrupting requests

## Decision

The Go controller publishes a validated route snapshot through the authenticated sidecar. The Rust process checks ordering and the digest, then publishes the slot mapping while holding its short routes lock. Each request selects its origin once and holds that reference through the exchange. Pool and breaker state remain attached to the physical origin slots. An identical retry returns the current generation, and rollback reapplies a previous route order at a newer generation.

Cache the parsed HTTP authority at origin setup. The per-request URI still gets its original path and query. The old authority construction remains available in the instrumented profile command for comparison.

## Alternatives considered

Restarting the worker on each config change would require a separate listener handoff and drain protocol. Making the route decision again when the upstream responds would let a newer configuration invalidate work already accepted. A snapshot with a request-local origin selection directly covers the live route change used in this release.

## Operational boundaries

- The proxy keeps two origin addresses and its active generation in memory. Keep the desired snapshot in the operator's deployment record and reconcile it after restart. Query status before applying a change or deciding how to retry.
- Health probes observe the configured origins at a point in time. They can reject a candidate before it is sent, and each request still uses the data plane's timeout, capacity limit, and breaker.
- The gate holds a request on each side of the swap and exercises ongoing HTTP/1.1 traffic at 120 offered requests per second. This establishes continuity for the reference update schedule. The deployment model starts the control plane and proxy on one host.
- Steady throughput and latency include the driver and same-host origin. The sampled RSS is for the Rust process. The CPU profiles isolate origin URI construction. Each metric answers a different question about the tested workload.

## Evidence

The capture directory includes request timestamps, outcomes and origin identities, update windows, memory samples, direct and Envoy baseline results, and paired CPU profiles and timings.
