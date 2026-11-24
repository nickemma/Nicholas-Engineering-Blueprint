# 02 A Rust edge proxy

> Cloud and network track · 4 weeks at 12–15 hours a week · Status ready

## What you'll build

Build a Rust edge proxy with two listener modes. The L4 listener forwards a TCP byte stream to a configured upstream. The L7 listener routes HTTP/1.1 requests to configured origins by path, reuses upstream connections, and limits the work a slow or failing origin can hold. Each instance selects its mode and addresses at startup. The HTTP load and measurements build on [Networking in depth](../01-networking-in-depth/README.md) and [Linux, networking, and profiling](../../../2-core/06-linux-networking-and-profiling/README.md).

Start with [Before you start](lessons/00-before-you-start.md).

## Lessons

| Week | # | Lesson | What you'll build and check |
|---|---|---|---|
| 1 | 01 | [Forward a TCP stream](lessons/01-forward-a-tcp-stream.md) | Build a bounded relay to a fixed upstream. Verify byte integrity in both directions and complete a response after the client half-closes its write side. |
| 1 | 02 | [Route an HTTP request](lessons/02-route-an-http-request.md) | Use an HTTP library to forward requests to two local origins. Check route selection, query and body preservation, and the status for an unmatched route. |
| 2 | 03 | [Reuse upstream connections](lessons/03-reuse-upstream-connections.md) | Keep one long-lived client and bound the idle pool per origin. Count accepted upstream sockets on serial requests over distinct downstream connections, then repeat with upstream reuse disabled. |
| 2 | 04 | [Put a deadline and a limit on upstream work](lessons/04-bound-upstream-work.md) | Bound request bodies, upstream time, and per-origin in-flight requests. Hold requests at one origin until its limit is reached, check that excess work is refused promptly, and verify that the other origin keeps serving. |
| 3 | 05 | [Break the circuit and recover](lessons/05-break-the-circuit-and-recover.md) | Add a per-origin breaker with closed, open, and half-open states. Use a controlled clock to test cooldown and single-probe admission, then observe reopening on probe failure and recovery on success. |
| 3 | 06 | [Compare the proxy with Envoy](lessons/06-compare-with-envoy.md) | Use the same HTTP/1.1 workload and instrumented origin directly, through the Rust proxy, and through a pinned Envoy release. Review response parity before comparing latency and throughput. |
| 4 | 07 | [Run the gate and explain the limits](lessons/07-run-the-edge-proxy-gate.md) | Replay the build, run the local fault fixtures, verify that the gate catches disabled reuse and breaker bypass, and write the benchmark report from the raw runs. |

These are new lessons. The benchmark reuses the direct-versus-proxy workload and origin measurements from [Networking in depth, lesson 06](../01-networking-in-depth/lessons/06-measure-what-an-edge-saves.md).

## The gate

- Verify exact bytes over the TCP relay and require a complete response after the client half-closes. Send requests to both HTTP routes and check the response status, body, and origin observations.
- Serve a serial sequence through separate downstream connections. Require all responses to match and the origin to accept fewer upstream sockets than requests. With reuse disabled at the proxy, the same assertion must fail.
- Stall one origin. Check that its concurrent requests stay within the configured limit, excess requests are refused, stalled work reaches its deadline, and the other origin continues serving. After the stall ends, verify that the application can admit work again.
- Trigger the breaker with upstream failures. Require open-circuit requests to leave the origin counter unchanged, permit exactly one recovery probe at a time after cooldown, and restore normal traffic after a successful probe. Bypassing breaker admission must fail the origin-count assertion. Use loopback fixtures and a controlled clock for the replay.

[Run the gate](gate/README.md)

## Benchmark evidence

Compare direct, Rust, and Envoy paths with matching HTTP/1.1 object requests and arrival schedules. Repeat a light run and a run under enough load to expose drops or increased latency. Record the exact configuration and versions, offered and completed requests per second, percentiles, errors, and upstream connection counts. Use the direct baseline and the driver's launch lag to interpret the results. [Reference report and raw runs](evidence/README.md)

## Practice

- Test a different pool budget, implement route precedence, and find the limits of your load generator. [Exercises](exercises.md)
- Trace a TCP half-close and a breaker recovery from memory. [Self-check](self-check.md)

Part 03 adds a Go control plane that can deliver and update the proxy's configuration. [The proxy's control plane](../03-proxy-control-plane/README.md)
