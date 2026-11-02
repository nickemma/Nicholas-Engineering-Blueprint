# Performance Bridge: find out why it's slow

**Question:** something is slow, and an alert has told you so. Which resource is the limit, which line of code is responsible, and how do you prove it?

**Time:** about 2 weeks. **Prerequisites:** [Phase 5](../05-constrained-operations/README.md), Docker, and the [Python Bridge](../python-bridge/README.md)'s idea of coordinated omission.

## Syllabus

You build `hotspot`, a small Go jobs service with five problems planted in it, and find each one with the right tool.

| Step | Topic | You'll learn |
|---|---|---|
| 1 | A slow service, and the USE method | Utilisation, saturation and errors; `vmstat`, `top`, `/proc`; voluntary context switches; an open-loop load generator; finding the knee |
| 2 | Waiting | Go's mutex and block profiles; critical sections; why a CPU profile can't see a lock |
| 3 | Computing | CPU profiles, `flat` and `cum`, flame graphs; profile, fix, profile again; when to stop |
| 4 | `perf` | Hardware counters, instructions per cycle, cache misses (proving DSA guide 00's surprise); symbols; `perf_event_paranoid`; a tools container |
| 5 | `strace` | System calls; counting them; the observer effect; `ptrace_scope`; why a fix can be invisible below the knee |
| 6 | The kernel's view with eBPF | `bpftrace`; counts and histograms at full load; run-queue latency |
| 7 | Memory and the garbage collector | Heap profiles, `gctrace`, `GOGC`, `GOMEMLIMIT`; a death spiral; bounding what you keep |
| 8 | The method, end to end | Before and after for every fix; a checklist for "this box is slow" |

## What you'll be able to do

- Apply the USE method to an unfamiliar machine, and say what you ruled out.
- Tell a service that's computing from one that's waiting.
- Take and read Go's CPU, heap, mutex and block profiles, and flame graphs.
- Use `perf`, `strace` and `bpftrace`, and know what each one costs and when it's safe.
- Tune a Go service's memory with `GOGC` and `GOMEMLIMIT`, and know what they can't fix.
- Work through a live "this box is slow" problem in an interview, out loud.

## How to work through it

1. Follow [TEACHING.md](TEACHING.md), typing every piece of code yourself.
2. Answer [learned.md](learned.md).
3. Do the exercise, **[profile Runway](exercises.md)**: the same tools, on the real system.
4. Take the [self-test](../../notes/learned/perf-bridge.md).

## Gaps this phase closes

These rows link to the [foundation-gap ledger](../../JOURNEY.md#5-foundation-gap-ledger).

| Gap | Where | Evidence |
|---|---|---|
| Linux performance and debugging (row 40) | Every step | A before-and-after table for five fixes, each found with a named tool |
| Processes, signals, file descriptors (row 7) | Steps 1, 5 | Context switches, system calls and signals read from a live process |
| Memory and ownership (row 14) | Step 7 | A heap profile, a `gctrace` line explained, a bounded store |

## Patterns introduced

- **Measure, fix the top item, measure again.**
- **Keep critical sections short:** no slow calls under a lock.
- **Bound everything that grows.**
- **Build, then write once:** batch work before a system call.
