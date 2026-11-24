# Exercise: profile Switchyard

Do this **on your own**, after the [checkpoint](README.md#checkpoint). `hotspot` was small, and its problems were planted. Switchyard's aren't: nobody knows what you'll find, including the author. That's the point.

There's no solution in this repository, because the answer depends on what you find. This page shows exactly what a finished investigation contains.

## What you're doing

Take the Switchyard API from [Core 03](../03-docker-and-postgres/README.md) and the Rust data plane from this module. Run a disposable local lab and find the first three things that limit its load.

## Requirements

**Set up.**
1. Add `net/http/pprof` to the API and the worker, on a separate port that's never exposed outside the Pod or the local machine, behind a flag that's off by default. Say in your report how you checked that it isn't reachable.
2. Load the API with `kload`, open loop, at rising rates. Find its knee: the rate at which p99 leaves your SLO.

**Investigate.** Work through the [checklist](lessons/08-the-method-end-to-end.md#the-checklist-this-box-is-slow), at a load just below the knee and just above it.

3. Apply USE to the machine, and to every container: which resources did you rule out, and how?
4. Find the bottleneck. Is it the API, a worker, PostgreSQL, the Rust data plane, or the network between them? Use a trace ([lesson 13](lessons/13-trace-and-profile-the-wire.md)) to narrow it down before you open a profiler.
5. Profile whatever you found, with at least two of: a CPU profile, a mutex or block profile, a heap profile, `perf stat`, and a `bpftrace` histogram.
6. Make **one** change, and measure again at the same rates. Repeat for three changes.

**Report.**
7. For each change: the symptom, the evidence, the tool, the change, and before-and-after numbers from at least three runs, with the spread.
8. At least one thing you **expected** to be a problem that wasn't, and the measurement that showed it.
9. Where the next limit is, and what you'd do about it.

## What finished looks like

A report in your repository, with a table like lesson 08's, and for each change a saved profile or flame graph. For example, the form of one entry (yours will differ):

~~~text
Change 2: workers polling for jobs

Symptom:   above 1,800/s, p99 jumps from 30 ms to 400 ms; API CPU 40%, database CPU 95%
Evidence:  pg_stat_statements: the workers' claim SELECT is 60% of database time
Tool:      trace shows requests waiting on the pool; block profile confirms
Change:    a partial index on queued rows
Result:    three runs at 2,500/s, p99 390/410/402 ms before, 41/38/44 ms after
~~~

That entry is an illustration of the shape. Your bottlenecks, numbers and fixes are your own result.

## How it will be checked

A reviewer (or you, honestly) reads the report and asks:
- Could I reproduce each number from your commands?
- Did each change come from evidence, not from a guess?
- Are run-to-run differences smaller than the effect you claim?
- Is the profiling port really unreachable from outside?

## Stretch goals

- If you've done Core 08, compare your SLO with what you found: would they have fired at the knee, and how early?
- Run a `bpftrace` run-queue histogram on a Kubernetes node with a CPU limit on the Pod, and show CFS throttling.
- Send one fix upstream, if you find a problem in a library.

## Separate build · Bounded frame relay

Write a new relay that listens on either TCP or a Unix socket and forwards complete records to one upstream reader. Choose a bounded message size and connection count. Return an explicit timeout or corrupt-frame error to the caller, and close connections whose frame position is uncertain.

- Send one fixture at every split in its header and payload. Check the same output and order.
- Make the upstream withhold a response. Measure when the relay times out and how many concurrent requests it admits.
- Run a clean and impaired link at the same offered rate. Save the p50, p99, error count, send lag, and qdisc statistics.
- Add one small CPU bottleneck, find it in a profile, fix it, and repeat the same workload. Keep the before and after profiles and explain what the timing can establish.

## Debug a Go service with Delve

Follow the [Delve build](deep-dives/debug-a-go-program.md) first. Then take these same steps on a disposable Switchyard copy with synthetic jobs. Make a deterministic failing test before opening the debugger so you can verify the fix without debugger intervention.

1. **Navigate and inspect.** Stop at the handler and step into the domain call. Switch goroutines and stack frames, then inspect the arguments, locals and the queued job. Change a scalar in the stopped process to test your hypothesis. Restart unchanged and reproduce the failure. Use a conditional breakpoint and a tracepoint to follow one synthetic job without stopping on every call.
2. **Investigate after exit.** Capture a core dump from the crashing lab process and reopen it with the matching executable. Identify the faulting goroutine, caller and relevant values. Compare what the dump preserves with what you learnt from function tracing and logs.
3. **Automate and replay.** Save a Delve command script that sets the breakpoint and prints the state that explains the failure. Repeat the inspection through a headless loopback session using Delve's JSON-RPC API. On a host supported by `rr`, record a failing run and replay backwards to the state change that led to the failure. Replay the original test against the fix. [Delve CLI reference](https://github.com/go-delve/delve/blob/master/Documentation/cli/README.md) · [Delve commands and replay](https://github.com/go-delve/delve/blob/master/Documentation/usage/README.md) · [Delve JSON-RPC](https://github.com/go-delve/delve/blob/master/Documentation/api/json-rpc/README.md)
4. **Debug a container and a Pod.** In Docker, compare the image, arguments and environment against the failing local run. After [Kubernetes and delivery](../../3-tracks/shared-units/kubernetes-and-delivery/README.md), start with Pod events, probe results, and current and previous container logs. Reproduce the failure in a disposable debug replica with matching source and symbols. If you attach remotely, keep the listener on a private lab connection and remove the replica after the session.
5. **Relate runtime behavior to evidence.** Use Delve to inspect a parked goroutine and its call stack. Compare that snapshot with a Go execution trace, CPU and block profiles, and a `perf` capture from an optimized build under the same load. Explain how symbol information and compiler inlining affect stepping and why a stopped goroutine alone cannot quantify a bottleneck. [Go profiling and execution traces](https://pkg.go.dev/net/http/pprof)
