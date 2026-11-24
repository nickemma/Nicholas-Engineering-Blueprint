# 04 perf: the whole machine's view

## What this step teaches

- `perf`, Linux's profiler, which works on any program in any language.
- Hardware counters: instructions per cycle and cache misses.
- Why a measurement tool needs symbols, and permission.

`pprof` only sees Go, and only from inside the process. `perf` comes from the kernel, and sees anything.

## Why Big-O isn't enough, measured

[DSA guide 00](../../../dsa/00-complexity/README.md) found a surprise: at 4 million numbers, finding duplicates by **sorting** beat a **hash set**, though the set is O(*n*) and sorting is O(*n* log *n*). It blamed the CPU's caches, without proof. Now you can prove it. Add the experiment as a program:

<!-- file: cmd/dupes/main.go -->
~~~go
// Command dupes answers "does this list have a duplicate?" for n shuffled
// distinct numbers, by sorting or with a set: DSA guide 00's experiment, as
// a program perf can measure.
package main

import (
	"flag"
	"fmt"
	"math/rand/v2"
	"slices"
	"time"
)

func main() {
	n := flag.Int("n", 4_096_000, "how many numbers")
	how := flag.String("how", "sorted", "sorted or set")
	flag.Parse()
	nums := rand.New(rand.NewPCG(1, 2)).Perm(*n) // distinct: the worst case
	start := time.Now()
	var dup bool
	switch *how {
	case "sorted":
		s := slices.Clone(nums)
		slices.Sort(s)
		for i := 1; i < len(s); i++ {
			if s[i] == s[i-1] {
				dup = true
				break
			}
		}
	case "set":
		seen := make(map[int]struct{}, len(nums))
		for _, v := range nums {
			if _, ok := seen[v]; ok {
				dup = true
				break
			}
			seen[v] = struct{}{}
		}
	default:
		panic("-how must be sorted or set")
	}
	fmt.Printf("%s: duplicate=%v in %v\n", *how, dup, time.Since(start).Round(time.Millisecond))
}
~~~

<!-- run: test -z "$(gofmt -l .)" && go vet ./... && go build -o bin/ ./cmd/... -->

`perf stat` runs a program and reads the CPU's hardware counters:

~~~bash
go build -o bin/ ./cmd/...
perf stat -e task-clock,cycles,instructions,cache-references,cache-misses -- ./bin/dupes -how sorted
perf stat -e task-clock,cycles,instructions,cache-references,cache-misses -- ./bin/dupes -how set
~~~

~~~text
sorted: duplicate=false in 407ms
 Performance counter stats for './bin/dupes -how sorted':
         636527014      task-clock:u
        2019773985      cycles:u                         #    3.173 GHz
        1907458773      instructions:u                   #    0.94  insn per cycle
          30245417      cache-references:u               #   47.516 M/sec
           6926918      cache-misses:u                   #   22.90% of all cache refs
       0.625286946 seconds time elapsed
set: duplicate=false in 958ms
 Performance counter stats for './bin/dupes -how set':
        1098706220      task-clock:u
        3780622401      cycles:u                         #    3.441 GHz
        1337777842      instructions:u                   #    0.35  insn per cycle
          56593240      cache-references:u               #   51.509 M/sec
          25208752      cache-misses:u                   #   44.54% of all cache refs
       1.177910956 seconds time elapsed
~~~

Look at the two lines that matter:

| | sorted | set |
|---|---|---|
| Instructions | 1.91 billion | **1.34 billion** |
| Cycles | **2.02 billion** | 3.78 billion |
| Instructions per cycle | **0.94** | 0.35 |
| Cache misses | **6.9 million** | 25.2 million |

The set does **less work**: 30% fewer instructions, as Big-O promised. It takes nearly **twice as long**, because each instruction waits. With 3.6 times the cache misses (and 44% of cache lookups missing, against 23%), the CPU spends most of its cycles stalled, waiting for main memory. **Instructions per cycle (IPC)** is the number that shows it. A modern CPU can do several instructions a cycle; 0.35 means it's mostly waiting.

## perf on a running service

With `hotspot` at 3,000/s:

~~~bash
perf stat -e task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,cache-misses \
  -p $(pgrep -x hotspot) -- sleep 10
~~~

~~~text
 Performance counter stats for process id '1451965':
       23058926649      task-clock:u                     #    2.304 CPUs utilized
                 0      context-switches:u               #    0.000 /sec
                 0      cpu-migrations:u                 #    0.000 /sec
             45335      page-faults:u                    #    1.966 K/sec
       33998818411      cycles:u                         #    1.474 GHz
       45143344599      instructions:u                   #    1.33  insn per cycle
         578505817      cache-misses:u
~~~

2.3 CPUs, and an IPC of 1.33: reasonable for a service. But context switches read **0**, which we know is false, and notice the `:u` on every event: **user space only**.

That's permission. `perf_event_paranoid` controls what an ordinary user may see:

~~~bash
cat /proc/sys/kernel/perf_event_paranoid
~~~

At 2, the default on many systems, you can't see the kernel. For that, you need root, or a privileged container.

## Symbols, and the tools container

`perf record` samples stacks, like `pprof`. On the machine this guide was written on, it gave this:

~~~bash
perf record -F 499 -g -p $(pgrep -x hotspot) -- sleep 5
perf report --stdio --no-children --sort symbol -g none
~~~

~~~text
    13.09%  [.] 0x000000000000418c
     4.99%  [.] 0x000000000003491e
     4.35%  [.] 0x0000000000091e42
~~~

Addresses, not names. A profile is useless without **symbols**. `hotspot` has them (`nm bin/hotspot` lists thousands), so the problem is `perf` itself:

~~~bash
perf version --build-options | grep libelf
~~~

~~~text
                libelf: [ OFF ]  # HAVE_LIBELF_SUPPORT
~~~

This `perf`, from WSL, was built without the library that reads binaries. Your system's may be fine, but other tools will be missing somewhere. A small container with the full set solves both, and step 6 needs it too. It's built for any Linux host, and it's how you'd bring tools to a machine that doesn't have them.

<!-- file: tools/Dockerfile -->
~~~text
# Linux observability tools, for machines whose own perf or bpftrace is
# missing or incomplete (WSL's perf can't resolve symbols, for one).
FROM ubuntu:24.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends linux-tools-generic bpftrace sysstat procps \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s "$(ls -d /usr/lib/linux-tools/*/perf | head -1)" /usr/local/bin/perf
~~~

~~~bash
docker build -t perftools tools/
~~~

`--privileged` and `--pid=host` let the container see the host's processes and the kernel, so run it only on machines you own:

~~~bash
docker run --rm --privileged --pid=host perftools pidstat -u -w -p $(pgrep -x hotspot) 2 3
~~~

~~~text
Average:      UID       PID    %usr %system  %guest   %wait    %CPU   CPU  Command
Average:     1000   1475451  115.67   62.67    0.00    0.00  178.33     -  hotspot
Average:      UID       PID   cswch/s nvcswch/s  Command
Average:     1000   1475451    658.17      2.00  hotspot
~~~

`pidstat` splits the CPU time, and shows what `perf` couldn't from a normal user: **63% of a core in the kernel** (`%system`) against 116% in Go.

To record with kernel stacks, then read the result with a `perf` that has symbols, mount the project at the same path so that `perf` can find the binary:

~~~bash
docker run --rm --privileged --pid=host -v $PWD:$PWD -w $PWD perftools \
  sh -c "perf record -F 499 -g -o perf.data -p $(pgrep -x hotspot) -- sleep 5"
docker run --rm -v $PWD:$PWD -w $PWD perftools \
  sh -c "perf report -f -i perf.data --stdio --no-children --sort symbol -g none --percent-limit 1.5 | grep -v '^#'"
~~~

(`-f` allows reading a file owned by another user.)

~~~text
    11.82%  [.] runtime.tryDeferToSpanScan
     8.16%  [.] memeqbody
     4.90%  [.] runtime.memmove
     3.49%  [.] time.Time.appendFormat
     3.04%  [.] time.appendInt
     2.55%  [.] runtime.scanObject
     2.45%  [.] fmt.(*pp).doPrintf
     2.29%  [.] runtime.mallocgcSmallScanNoHeader
     1.97%  [.] hotspot.(*Store).List
     1.94%  [.] runtime.mallocgcTiny
~~~

~~~bash
docker run --rm -v $PWD:$PWD -w $PWD perftools \
  sh -c "perf report -f -i perf.data --stdio --no-children --sort dso -g none | grep -v '^#'"
~~~

~~~text
    75.11%  hotspot          
    24.58%  [kernel.kallsyms]
     0.31%  [vdso]           
~~~

Names now, and a quarter of all samples are in the kernel, which `pprof` can't look into. What is the kernel doing for us? That's the next step.

**Explain it:** What can `perf` see that `pprof` can't, and the reverse? What's IPC, and what does 0.35 tell you? How can the program with fewer instructions be slower? Why did context switches read 0? What is `perf_event_paranoid`? What do symbols do, and why did `perf` show addresses? What's the risk of `--privileged`?

**Read.** Brendan Gregg, [*perf Examples*](https://www.brendangregg.com/perf.html). Denis Bakhvalov, *Performance Analysis and Tuning on Modern CPUs*, the chapters on CPU counters.

---
