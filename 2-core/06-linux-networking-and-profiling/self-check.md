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

## Self-test


Answer from memory, then check yourself against [the lesson](lessons/00-before-you-start.md). Write each "predict" answer before running anything.

### A. Method

1. Say the USE method's three checks. Name a tool for each, for CPU and for memory.
2. A service's latency has doubled. CPU is at 10%. What do you do first, and what do you not do?
3. Name four things you'd rule out in the first two minutes on an unfamiliar machine, and the command for each.
4. Why is "fix the top item, then measure again" better than fixing the top three at once?
5. Why measure at the load you care about, and not at a lower one?

### B. Go's profiles

6. What's the difference between a CPU profile and a block profile? Which would find a lock held across a network call?
7. What's the difference between `flat` and `cum`?
8. What's `inuse_space`? What's `alloc_space`? Which one explains GC pressure?
9. Why must the profiler's port never be public?
10. Predict: a handler with `out += line` in a loop over 5,000 lines of 25 bytes. Roughly how much is copied?
11. In a flame graph, what's the meaning of a wide box at the top, and of a wide box at the bottom?

### C. perf and system calls

12. What's IPC? What does 0.35 mean? What does it suggest about the code?
13. Explain how one program can execute fewer instructions than another and take longer.
14. What does `perf_event_paranoid=2` stop you seeing?
15. Why might `perf` show addresses, and how do you fix it?
16. What's a system call? Why does it cost more than a function call?
17. Why is `strace` dangerous on a busy production process? What's it still good for?
18. What does `ptrace_scope=1` mean?

### D. eBPF

19. How does eBPF differ from `strace`? Why is it cheaper?
20. What stops an eBPF program from crashing the kernel?
21. Write, from memory, a `bpftrace` one-liner counting system calls by name for one process.
22. What is run-queue latency, and which tail would make you add CPUs?
23. Why might `pid == N` match nothing inside a container or WSL?

### E. Memory and the collector

24. Read this line: `gc 344 @40.913s 0%: ... 46->47->24 MB, 48 MB goal`.
25. What does `GOGC=400` trade? And `GOGC=25`?
26. Why is `GOGC=off` with a generous `GOMEMLIMIT` a reasonable setup?
27. Predict: `GOMEMLIMIT=20MiB`, with live data growing past it. Why does latency collapse, and why doesn't the process stop at 20 MiB?
28. Why can't a memory limit fix a leak?
29. In the bounded store, what breaks if `evict` forgets to delete from `byKey`?

### F. Interview

30. Out loud, in five minutes: "The API's p99 went from 50 ms to 2 s at 14:00. CPU looks normal. Walk me through it."

## Linux and the wire

| Lesson | Question |
|---|---|
| 09 | Why can the first and second passes over the same memory mapping produce different page-fault counts? Which syscall synchronizes the mapping? |
| 10 | Trace the three handshake packets. Convert a rate and RTT to in-flight bytes. Which qdisc counter proves the traffic crossed the impairment? |
| 11 | What distinguishes a clean EOF, a partial frame, and complete corruption? Which check happens before Rust resizes the payload buffer? |
| 12 | Why can only one exchange use a connection at a time? How does a cancellation interrupt the active read? |
| 13 | How does an inbound trace ID relate to the Go client span? Which CPU profile showed the work the optimizer removed? |
| 14 | What evidence confirms the contender ran and the link dropped packets? What would an interval including zero mean for the p99 claim? |

Close the lessons. Draw the request path from `kload` through Go and into Rust. Label the buffer owners, framing checks, deadlines, span boundary, and impaired interface. Then design a matched run that would falsify your preferred performance explanation.
