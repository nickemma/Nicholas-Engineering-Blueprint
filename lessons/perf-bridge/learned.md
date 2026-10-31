# Performance Bridge: what I learned

Fill this in as you go, with evidence: commands, outputs, profiles and flame graphs saved in your repository.

## Explain it

| Step | Question | My answer | Evidence |
|---|---|---|---|
| 1 | What's the difference between utilisation and saturation? Give a resource and a tool for each | | |
| 1 | What did 92% idle CPUs plus a throughput ceiling tell you? | | |
| 1 | What's a voluntary context switch, and what does a high count suggest? | | |
| 2 | Who does the mutex profile charge the delay to? And the block profile? | | |
| 2 | Why could throughput never exceed 1,000 creates a second, whatever the hardware? | | |
| 3 | What do `flat` and `cum` mean? | | |
| 3 | What do a flame graph's width and height mean? What doesn't its left-to-right order mean? | | |
| 3 | Why was the obvious O(*n*²) scan not the top item on the first profile? | | |
| 3 | How do you decide when to stop optimising? | | |
| 4 | How did the program with fewer instructions take longer? What number shows it? | | |
| 4 | Why did `perf` show addresses, and why did context switches read 0? | | |
| 5 | Why did `strace` wreck the service, and what are its results still good for? | | |
| 5 | Why was the one-write fix invisible at 3,000 requests a second? | | |
| 6 | How does eBPF differ from `strace`? Why is it safe on a production machine? | | |
| 6 | What does run-queue latency measure, and what would a long tail mean? | | |
| 7 | Read a `gctrace` line aloud: `46->47->24 MB, 48 MB goal` | | |
| 7 | What does `GOGC` trade? What does `GOMEMLIMIT` do when live data exceeds it? | | |
| 7 | What's the cost of the bounded ring? | | |
| 8 | Which fix moved the knee most? How do you know? | | |

## What surprised me

## What I'd do differently
