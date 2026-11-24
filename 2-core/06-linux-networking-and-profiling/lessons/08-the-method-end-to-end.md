# 08 The method, end to end

## What this step teaches

- Before and after, for every fix.
- A checklist for "this box is slow".

Every version of `hotspot`, at every rate, for 10 seconds, on a fresh process. Each cell is the **p99** in milliseconds, or **fail** if requests errored or it couldn't keep the rate:

| Version | 500/s | 800/s | 1,500/s | 3,000/s | 5,000/s | 8,000/s |
|---|---|---|---|---|---|---|
| Step 1: as planted | 4.69 | fail | fail | fail | fail | fail |
| Step 2: lock fixed | 3.16 | 5.08 | 82 | fail | fail | fail |
| Step 3: quadratic loops fixed | 3.41 | 3.32 | 3.6 | 4.94 | 29.6 | fail |
| Step 5: one write per job | 2.86 | 3.11 | 3.04 | 5.86 | 15.4 | fail |
| Step 7: bounded store | 2.76 | 3.1 | 3.3 | 26.1 | 7.75 | 27.5 |

From a collapse at 800 requests a second to 8,000 with a p99 of 27 ms: **more than ten times the load, on the same hardware, in about 110 changed lines, most of them the bounded store.** The last row wasn't pushed further, so its limit is unknown.

Each cell is **one run**, so treat small differences as noise. The last row's 26 ms at 3,000/s, worse than its 8 ms at 5,000/s, is a good example: a stray pause, not a real effect. To claim a small improvement, you'd repeat and interleave the runs, as [Core 02, lesson 08](../../02-python-runtime-and-honest-measurement/lessons/08-repeat-runs-and-confidence-intervals.md) does.

Each fix moved the knee, and each used a different tool, because each problem was a different kind of problem:

| Problem | How it looked | Tool that found it | Fix |
|---|---|---|---|
| A lock held across a slow call | Idle CPUs, a throughput ceiling, voluntary context switches | USE, then block and mutex profiles | Move the call outside the lock |
| Quadratic string building | 8.5 cores busy, `memmove`, the garbage collector | CPU profile, flame graph | Write each line straight out |
| A linear scan | `memeqbody` under `Create` | CPU profile, `-list` | A map |
| Six writes per job | Kernel time; `Syscall6` on top | `pidstat`, `strace -c` | Build the line, write once |
| Unbounded memory | RSS that only grows; a death spiral under a limit | `gctrace`, heap profiles | A fixed-size ring |

## The checklist: "this box is slow"

On a machine you've never seen, in this order. It takes minutes, and each step narrows the next:

1. **What does "slow" mean?** Which request, how slow, since when? Find the metric (an SLO, if the service has one). What changed?
2. **Is anything saturated?** `uptime`, `vmstat 1`, `free -m`. CPU? Run queue? Swapping?
3. **Which process?** `top`, `pidstat 1`.
4. **Is it running or waiting?** Voluntary context switches, `%usr` against `%system`.
   - **Running:** a CPU profile, then a flame graph.
   - **Waiting:** mutex and block profiles. Traces ([lesson 13](13-trace-and-profile-the-wire.md)) show which dependency.
   - **In the kernel:** count the system calls with `bpftrace`, not `strace`, if it's busy.
5. **Is memory growing?** RSS over time, `gctrace`, heap profiles.
6. **Disk and network?** `iostat -x 1` (from `sysstat`), `ss -s`, retransmits.
7. **Fix the top item only, then measure again** at the load you care about. Stop at the target.

Also write down what you ruled out, and how. "It isn't the CPU: 92% idle, and the run queue is empty" is half of a good answer in an interview.

**Explain it:** Without looking, walk through the checklist for: "API latency doubled at 14:00, and CPU looks normal". Which tools are safe on a busy production machine, and which aren't? Which of this bridge's problems would an average latency have hidden?

---
