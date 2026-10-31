# Performance Bridge exercise: profile Runway

Do this **on your own**, after the [checkpoint](TEACHING.md#checkpoint). `hotspot` was small, and its problems were planted. Runway's aren't: nobody knows what you'll find, including the author. That's the point.

There's no solution in this repository, because the answer depends on what you find. This page shows exactly what a finished investigation contains.

## What you're doing

Take your Runway from [Phase 5](../05-constrained-operations/README.md), running in Docker Compose or on kind, and find the first three things that limit it.

## Requirements

**Set up.**
1. Add `net/http/pprof` to the API and the worker, on a separate port that's never exposed outside the Pod or the local machine, behind a flag that's off by default. Say in your report how you checked that it isn't reachable.
2. Load the API with `kload`, open loop, at rising rates. Find its knee: the rate at which p99 leaves your SLO.

**Investigate.** Work through the [checklist](TEACHING.md#the-checklist-this-box-is-slow), at a load just below the knee and just above it.

3. Apply USE to the machine, and to every container: which resources did you rule out, and how?
4. Find the bottleneck. Is it the API, a worker, PostgreSQL, RabbitMQ, the outbox relay, Redis, or the network between them? Use a trace (Phase 5) to narrow it down before you open a profiler.
5. Profile whatever you found, with at least two of: a CPU profile, a mutex or block profile, a heap profile, `perf stat`, and a `bpftrace` histogram.
6. Make **one** change, and measure again at the same rates. Repeat for three changes.

**Report.**
7. For each change: the symptom, the evidence, the tool, the change, and before-and-after numbers from at least three runs, with the spread.
8. At least one thing you **expected** to be a problem that wasn't, and the measurement that showed it.
9. Where the next limit is, and what you'd do about it.

## What finished looks like

A report in your repository, with a table like step 8's, and for each change a saved profile or flame graph. For example, the form of one entry (yours will differ):

~~~text
Change 2: outbox relay polling

Symptom:   above 1,800/s, p99 jumps from 30 ms to 400 ms; API CPU 40%, database CPU 95%
Evidence:  pg_stat_statements: the relay's SELECT is 60% of database time
Tool:      trace shows requests waiting on the pool; block profile confirms
Change:    a partial index on unsent rows
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

- Compare your Phase 5 SLO alerts with what you found: would they have fired at the knee, and how early?
- Run a `bpftrace` run-queue histogram on a Kubernetes node with a CPU limit on the Pod, and show CFS throttling.
- Send one fix upstream, if you find a problem in a library ([open-source track](../../open-source/README.md)).
