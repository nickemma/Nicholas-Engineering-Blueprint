# 06 The kernel's view, with eBPF

## What this step teaches

- eBPF: small, verified programs running inside the kernel.
- `bpftrace`: histograms and counts, cheaply, on live systems.
- Tracing without the cost of `strace`.

`strace` stops the program for each event. **eBPF** does the opposite: it loads a small program **into the kernel**, attached to an event. The kernel verifies that the program can't crash it or loop forever, then runs it at each event, keeping counts in kernel memory. Nothing stops. That's why it's safe on production machines, and it's what modern observability and networking tools are built on.

`bpftrace` is a small language for it: `probe /filter/ { action }`. It needs root, so use the tools container. Mounting `debugfs` gives it the kernel's list of tracepoints:

~~~bash
BT="docker run --rm --privileged --pid=host -v /sys/kernel/debug:/sys/kernel/debug:rw perftools"
~~~

## Counting, at full load

With `hotspot` running, count every system call it makes, for as long as the load runs:

~~~bash
$BT timeout -s INT 22 bpftrace -e '
  tracepoint:syscalls:sys_enter_* /comm == "hotspot"/ { @calls[probe] = count(); }'
~~~

~~~text
@calls[futex]: 128170
@calls[read]: 94321
@calls[epoll_pwait]: 70911
@calls[write]: 61818
@calls[nanosleep]: 33866
@calls[sched_yield]: 16720
@calls[rt_sigreturn]: 10517
@calls[tgkill]: 10517
@calls[getpid]: 10516
@calls[madvise]: 1899
~~~

- **`@calls`** is a map, kept in the kernel and printed when the program stops.
- **`comm == "hotspot"`** filters by process name. On WSL, filtering by `pid == <the number your shell shows>` matched nothing. The most likely reason is that WSL runs the distribution in its own PID namespace, so the kernel knows the process by a different number. Process names don't have that problem.

The surprise is `futex`: the kernel's sleep-and-wake primitive, under Go's scheduler and locks. Notice `tgkill`, `getpid` and `rt_sigreturn`, at almost exactly the same count (10,517, 10,516 and 10,517). They're one thing: the Go runtime sending a signal to a thread to preempt a goroutine, usually for the garbage collector.

Now the point of this step. The same run, the same 3,000/s, with and without it:

~~~text
no tracing
sent 30000 in 10.0s (2998/s), errors 0
latency p50 2.16ms  p90 3.01ms  p99 4.26ms  max 8.77ms
bpftrace counting every system call
sent 30000 in 10.0s (2998/s), errors 0
latency p50 2.12ms  p90 3.18ms  p99 5.3ms  max 9.23ms
~~~

About **440,000 events counted, and the latency barely moved** (p99 5.3 ms against 4.3 ms, in one run of each). `strace` at half that rate destroyed the service.

## Histograms

Averages hide the tail, so `bpftrace` keeps **histograms**. How long does `write` take? Record the time at entry, and at exit add the difference to a histogram:

~~~bash
$BT timeout -s INT 14 bpftrace -e '
  tracepoint:syscalls:sys_enter_write /comm == "hotspot"/ { @start[tid] = nsecs; }
  tracepoint:syscalls:sys_exit_write  /@start[tid]/ {
    @write_us = hist((nsecs - @start[tid]) / 1000);
    delete(@start[tid]);
  }'
~~~

~~~text
@write_us:
[2, 4)               117 |                                                    |
[4, 8)               711 |@                                                   |
[8, 16)             8986 |@@@@@@@@@@@@@@@@@@                                  |
[16, 32)           24685 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
[32, 64)           24206 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@  |
[64, 128)           3179 |@@@@@@                                              |
[128, 256)            83 |                                                    |
[256, 512)             5 |                                                    |
~~~

`[16, 32)` means 16 up to 32 microseconds. Most writes take 16–64 µs, a few take over 100, and none takes more than a millisecond. So writes aren't the tail. (`strace -T` reported 60–130 µs for these writes, because it measures its own stops as well.)

Is the **CPU scheduler** delaying us? Run-queue latency is the time a thread spends ready to run, but waiting for a CPU. It's the true measure of CPU saturation:

~~~bash
$BT timeout -s INT 14 bpftrace -e '
  tracepoint:sched:sched_wakeup { @queued[args.pid] = nsecs; }
  tracepoint:sched:sched_switch {
    if (args.prev_state == 0) { @queued[args.prev_pid] = nsecs; }
    $t = @queued[args.next_pid];
    if ($t != 0) {
      if (args.next_comm == "hotspot") { @runq_us = hist((nsecs - $t) / 1000); }
      delete(@queued[args.next_pid]);
    }
  }
  END { clear(@queued); }'
~~~

~~~text
@runq_us:
[1]                   17 |                                                    |
[2, 4)              2278 |@                                                   |
[4, 8)             72648 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
[8, 16)            30091 |@@@@@@@@@@@@@@@@@@@@@                               |
[16, 32)            2031 |@                                                   |
[32, 64)            2048 |@                                                   |
[64, 128)            208 |                                                    |
[128, 256)            51 |                                                    |
[256, 512)            15 |                                                    |
[512, 1K)              3 |                                                    |
~~~

Almost every wake-up gets a CPU within 16 µs, and the worst is under a millisecond. At 3,000/s, this machine has CPUs to spare. If this histogram had a tail in the tens of milliseconds, adding threads wouldn't help; you'd need more CPUs, or fewer busy neighbours.

These one-liners are small on purpose. The container also has ready-made tools in `/usr/sbin/*.bt`, such as `runqlat.bt`, `syscount.bt` and `biolatency.bt`.

**Explain it:** How does eBPF differ from `strace`, and why is it cheaper? What stops a bad eBPF program from crashing the kernel? What's a tracepoint? What does `@start[tid]` do, and why key it by thread? What is run-queue latency, and what does a long tail in it mean? Why did `tgkill` and `rt_sigreturn` have the same count?

**Read.** Brendan Gregg, *BPF Performance Tools* (Addison-Wesley), chapters 1–5. The [bpftrace one-liner tutorial](https://bpftrace.org/tutorial-one-liners).

---
