# 01 How Go runs your code

> Module: Go runtime and reliable services · Time: ~6 h · Builds on: Foundations 03

## The problem

In Go from zero you started 10,000 goroutines without a second thought, and Go never asked you to free memory. Both are paid for by the **runtime**: code that Go links into every program you build, which schedules goroutines onto threads and collects garbage while your code runs. Most of the time you can ignore it. Then a service's p99 doubles under load, or its memory climbs until the container is killed, or one goroutine seems to freeze the others, and the explanation is in the runtime. This lesson opens it up with small experiments, so that later, when Switchyard misbehaves, you know which knob exists and what it costs.

## The mental model

~~~text
  your goroutines (G): thousands, each with a small stack that grows
        G G G G G G G G G G G G
          │ queued on
          ▼
  processors (P): GOMAXPROCS of them, by default one per CPU; each has a run queue
        P0 [G G G]   P1 [G]   P2 [ ]   ...
          │ each P is run by
          ▼
  machine threads (M): real OS threads; more appear when one blocks in a system call
        M0          M1        M2

  the heap: values that outlive the function that made them
        ████░░░░████░░██     the garbage collector (GC) finds the unreachable ones
                              and frees them, mostly while your goroutines keep running
~~~

- A **G** is a goroutine: a function to run, plus its own stack. It starts at a few kilobytes.
- A **P** (processor) is a slot for running Go code. There are `GOMAXPROCS` of them, one per CPU by default, so at most that many goroutines run *at the same instant*.
- An **M** (machine) is an operating-system thread. A P needs an M to run; when a goroutine blocks in a system call, its M blocks with it, and the runtime hands the P to another M so the other goroutines carry on.
- The **scheduler** moves goroutines on and off Ps: when one waits (on a channel, a lock, the network), another runs. Every 10 ms or so it also **preempts** a goroutine that's been running too long, so none can hog a P.
- **Escape analysis** decides, at compile time, whether each value can live on the goroutine's stack (free to allocate, gone when the function returns) or must move to the **heap** (allocated, then later found and freed by the garbage collector).

## The pattern

**Measure the runtime, don't guess.** The runtime reports on itself: `GODEBUG=schedtrace` for the scheduler, `-gcflags=-m` for escape analysis, `-benchmem` for allocations, `GODEBUG=gctrace` for the collector. Every claim in this lesson is something you'll see printed.

## Build it

Switchyard lives in one Go module from now until the end of the core. Create it, with a folder for this lesson's experiments:

~~~bash
mkdir -p ~/blueprint/switchyard && cd ~/blueprint/switchyard
go mod init switchyard
~~~

<!-- run: go mod init switchyard -->

### Step 1: Ten thousand goroutines on a few threads

Create `drills/sched/main.go`:

<!-- file: drills/sched/main.go -->
~~~go
// Lesson 01: how many CPUs Go uses, and 10,000 goroutines on a few threads.
package main

import (
	"fmt"
	"runtime"
	"sync"
	"time"
)

func main() {
	fmt.Println("CPUs:", runtime.NumCPU(), "GOMAXPROCS:", runtime.GOMAXPROCS(0))
	var wg sync.WaitGroup
	for range 10_000 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			time.Sleep(2 * time.Second) // parked: costs memory, no thread
		}()
	}
	time.Sleep(500 * time.Millisecond)
	fmt.Println("goroutines:", runtime.NumGoroutine())
	wg.Wait()
	fmt.Println("goroutines after:", runtime.NumGoroutine())
}
~~~

<!-- run: go vet ./drills/sched -->

`runtime.GOMAXPROCS(0)` reads the setting without changing it. Build it, and run it with the scheduler's trace on. `GODEBUG=schedtrace=1000` makes the runtime print a summary of itself every 1,000 ms:

~~~bash
go build -o sched ./drills/sched && GODEBUG=schedtrace=1000 ./sched; rm sched
~~~

~~~text
SCHED 0ms: gomaxprocs=16 idleprocs=13 threads=4 spinningthreads=1 needspinning=0 idlethreads=0 runqueue=0 [ 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 ] schedticks=[ 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 ]
CPUs: 16 GOMAXPROCS: 16
goroutines: 10001
SCHED 1002ms: gomaxprocs=16 idleprocs=16 threads=18 spinningthreads=0 needspinning=0 idlethreads=16 runqueue=0 [ 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 ] schedticks=[ 1332 107 116 81 87 101 77 91 139 138 174 188 2088 2762 2691 535 ]
SCHED 2007ms: gomaxprocs=16 idleprocs=14 threads=18 spinningthreads=1 needspinning=0 idlethreads=14 runqueue=129 [ 0 0 0 0 0 0 0 0 0 0 0 0 0 0 179 0 ] schedticks=[ 1332 107 116 81 87 519 77 91 139 138 174 722 2088 2762 3660 1415 ]
goroutines after: 1
~~~

Read a `SCHED` line left to right:

- `gomaxprocs`: the number of Ps. `idleprocs`: how many have nothing to run.
- `threads`: Ms, the real OS threads. Ten thousand goroutines, and fewer than twenty threads.
- `runqueue` and the list in brackets: goroutines ready to run, waiting in the global queue and in each P's queue. At 1 second they're all zero: every goroutine is asleep in `time.Sleep`, which parks it without holding a thread. At 2 seconds the sleeps are ending, and the woken goroutines queue up for a P (129 in the global queue and 179 on one P in the run above; your numbers will differ). They drain in a few milliseconds, because each one only has to return.

The 10,001 goroutines (yours plus `main`) are cheap because a sleeping goroutine is just a small stack and a record in a timer; it costs no thread and no CPU. When they've all finished, only `main` is left.

### Step 2: Preemption

A goroutine gives up its P when it blocks. What about one that never blocks? Create `drills/spin/main.go`:

<!-- file: drills/spin/main.go -->
~~~go
// Lesson 01: a goroutine that never stops computing, on one P.
package main

import (
	"fmt"
	"runtime"
	"time"
)

func main() {
	runtime.GOMAXPROCS(1) // one P: one goroutine runs at a time
	go func() {
		n := 0
		for { // never calls a function, never blocks
			n++
		}
	}()
	start := time.Now()
	time.Sleep(10 * time.Millisecond)
	fmt.Printf("main woke after %v\n", time.Since(start).Round(time.Millisecond))
}
~~~

With one P, while the loop runs, `main` can't. Yet:

~~~bash
go run ./drills/spin
~~~

<!-- run: go vet ./drills/spin && go run ./drills/spin | grep -q "main woke after" -->

~~~text
main woke after 11ms
~~~

`main` woke on time. The runtime noticed the loop had run for 10 ms, sent its thread a signal, and interrupted it at the next safe point: **asynchronous preemption**. Turn it off, and the loop keeps the only P forever:

~~~bash
go build -o spin ./drills/spin && timeout 3 env GODEBUG=asyncpreemptoff=1 ./spin; echo "exit $?"; rm spin
~~~

<!-- run: go build -o spin ./drills/spin && ! timeout 3 env GODEBUG=asyncpreemptoff=1 ./spin; rm -f spin -->

~~~text
exit 124
~~~

Nothing printed; `timeout` killed it after 3 seconds (exit 124). Before Go 1.14, every Go program behaved like this: a tight loop with no function calls could freeze a P. Today the cost is small, and only shows as a little extra latency for the goroutines waiting behind a long computation.

### Step 3: What a goroutine costs

Create `drills/stacks/main.go`:

<!-- file: drills/stacks/main.go -->
~~~go
// Lesson 01: what a goroutine costs, and a stack that grows.
package main

import (
	"fmt"
	"runtime"
	"sync"
)

func stackInUse() uint64 {
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return m.StackInuse
}

// depth recurses n times; each call keeps a 1 KiB array on its stack.
func depth(n int) int {
	var pad [1024]byte
	pad[0] = byte(n)
	if n == 0 {
		return int(pad[0])
	}
	return depth(n-1) + int(pad[0])
}

func main() {
	before := stackInUse()
	done := make(chan uint64)
	go func() {
		depth(10_000) // about 10 MB of stack, grown on demand
		done <- stackInUse()
	}()
	fmt.Printf("one goroutine 10,000 calls deep: %d MiB of stack\n", (<-done-before)>>20)

	const n = 100_000
	before = stackInUse()
	var wg sync.WaitGroup
	release := make(chan struct{})
	for range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-release
		}()
	}
	fmt.Printf("%d parked goroutines: about %d bytes of stack each\n", n, (stackInUse()-before)/n)
	close(release)
	wg.Wait()
}
~~~

- `runtime.ReadMemStats` fills in the runtime's own accounts. `StackInuse` is the memory used by goroutine stacks.
- `depth` calls itself 10,000 times, and each call holds a 1 KiB array, so the goroutine needs about 10 MB of stack.

~~~bash
go run ./drills/stacks
~~~

<!-- run: go vet ./drills/stacks && go run ./drills/stacks | grep -q "parked goroutines" -->

~~~text
one goroutine 10,000 calls deep: 16 MiB of stack
100000 parked goroutines: about 2054 bytes of stack each
~~~

A parked goroutine costs about 2 KiB: a thread's stack is typically 8 MiB, which is why a Go server can hold a goroutine per connection where a thread per connection would run out of memory. The deep goroutine's stack started just as small and **grew**: when a function call would run past the end, the runtime allocates a stack twice the size, copies the old one into it, and carries on. Copying is why Go never lets you keep a pointer to a stack value that might move without the runtime knowing about it.

### Step 4: Stack or heap: escape analysis

Create `drills/escape/escape.go`:

<!-- file: drills/escape/escape.go -->
~~~go
// Package escape shows which values Go keeps on the stack and which move to the heap.
package escape

type point struct{ X, Y int }

// sum keeps p on the stack: it never leaves the function.
func sum() int {
	p := point{1, 2}
	return p.X + p.Y
}

// newPoint returns a pointer to p, so p must outlive the call: it moves to the heap.
//
//go:noinline
func newPoint() *point {
	p := point{1, 2}
	return &p
}

// newPointInlined is the same, but the compiler may copy its body into the caller.
func newPointInlined() *point {
	p := point{1, 2}
	return &p
}

// big makes 1 MiB: far too big for a goroutine's stack, so it goes on the heap.
func big() byte {
	buf := make([]byte, 1<<20)
	return buf[0]
}
~~~

`//go:noinline` is a **directive**: a comment the compiler reads. It stops the compiler from **inlining** `newPoint`, that is, copying its body into each caller instead of making a call. Ask the compiler what it decided:

~~~bash
go build -gcflags=-m ./drills/escape 2>&1 | grep -v "can inline"
~~~

<!-- run: go build -gcflags=-m ./drills/escape 2>&1 | grep -q "moved to heap: p" -->

~~~text
# switchyard/drills/escape
drills/escape/escape.go:16:2: moved to heap: p
drills/escape/escape.go:22:2: moved to heap: p
drills/escape/escape.go:28:13: make([]byte, 1048576) escapes to heap
~~~

`-gcflags=-m` asks the compiler to explain its escape analysis. `p` in both `newPoint` functions "moved to heap", because a pointer to it is returned; the 1 MiB buffer "escapes to heap" because it's too big for a stack. `sum`'s `p` isn't mentioned: it stays on the stack. Now measure what that costs, with benchmarks. Create `drills/escape/escape_test.go`:

<!-- file: drills/escape/escape_test.go -->
~~~go
package escape

import "testing"

var sink *point // a package-level variable, so the compiler can't drop the call

func BenchmarkSum(b *testing.B) {
	for b.Loop() {
		sum()
	}
}

func BenchmarkNewPoint(b *testing.B) {
	for b.Loop() {
		newPoint()
	}
}

func BenchmarkNewPointInlined(b *testing.B) {
	for b.Loop() {
		newPointInlined()
	}
}

func BenchmarkNewPointKept(b *testing.B) {
	for b.Loop() {
		sink = newPointInlined()
	}
}

func BenchmarkBig(b *testing.B) {
	for b.Loop() {
		big()
	}
}
~~~

A **benchmark** is a function named `BenchmarkXxx` taking `*testing.B`. `go test -bench` runs it: `b.Loop()` repeats the body until the timing is stable. `-benchmem` also reports the bytes and allocations per run.

~~~bash
go test -bench . -benchmem ./drills/escape | grep Benchmark
~~~

<!-- run: go test -bench . -benchtime 1000x -benchmem ./drills/escape | grep "BenchmarkNewPoint-" | grep -q "1 allocs/op" -->

~~~text
BenchmarkSum-16                	1000000000	         0.5888 ns/op	       0 B/op	       0 allocs/op
BenchmarkNewPoint-16           	79805106	        14.95 ns/op	      16 B/op	       1 allocs/op
BenchmarkNewPointInlined-16    	1000000000	         0.7606 ns/op	       0 B/op	       0 allocs/op
BenchmarkNewPointKept-16       	76830589	        15.28 ns/op	      16 B/op	       1 allocs/op
BenchmarkBig-16                	    6811	    250104 ns/op	 1048588 B/op	       1 allocs/op
~~~

- `Sum`: no allocation, a fraction of a nanosecond.
- `NewPoint`: one allocation of 16 bytes (two `int`s) and about 15 ns, most of it the allocation, plus the collector's work later.
- `NewPointInlined`: the same code, no allocation. Once inlined into the benchmark, the pointer never leaves the caller, so the compiler could keep `p` on the stack after all. Escape analysis runs after inlining, so small functions often cost less than `-m` suggests at first.
- `NewPointKept`: storing the result in a package-level variable makes it escape for real.
- `Big`: one allocation of a megabyte, 150 µs or so.

The habit this builds: when a hot path is slow, `-benchmem` tells you how many allocations it makes, `-gcflags=-m` tells you why, and fewer allocations means less work for the collector.

### Step 5: The garbage collector

Create `drills/gc/main.go`:

<!-- file: drills/gc/main.go -->
~~~go
// Lesson 01: garbage, and how often the collector runs to clear it.
package main

import (
	"fmt"
	"runtime"
	"time"
)

var keep [][]byte // a live set the program really uses: about 50 MiB

func main() {
	for range 50 {
		keep = append(keep, make([]byte, 1<<20))
	}
	start := time.Now()
	var sink []byte
	for range 20_000 {
		sink = make([]byte, 64<<10) // 64 KiB of garbage, every time
	}
	_ = sink
	took := time.Since(start)
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	fmt.Printf("allocated %d MiB in %v: %d collections, heap now %d MiB, %v paused in total\n",
		m.TotalAlloc>>20, took.Round(time.Millisecond), m.NumGC, m.HeapAlloc>>20,
		time.Duration(m.PauseTotalNs).Round(time.Microsecond))
}
~~~

<!-- run: go vet ./drills/gc && go run ./drills/gc | grep -q collections -->

The program keeps 50 MiB that it really uses (the **live heap**), then makes 20,000 short-lived 64 KiB buffers: 1.3 GB of garbage. Go's collector starts a cycle when the heap has grown by `GOGC` percent over the live heap left by the previous cycle: 100 by default, so at about twice the live heap. Run it with four settings:

~~~bash
go build -o gcdrill ./drills/gc
for g in 50 100 400 off; do echo "GOGC=$g"; GOGC=$g ./gcdrill; done
~~~

~~~text
GOGC=50
allocated 1300 MiB in 308ms: 59 collections, heap now 74 MiB, 20.4ms paused in total
GOGC=100
allocated 1300 MiB in 413ms: 29 collections, heap now 76 MiB, 12.377ms paused in total
GOGC=400
allocated 1300 MiB in 490ms: 7 collections, heap now 231 MiB, 2.661ms paused in total
GOGC=off
allocated 1300 MiB in 17ms: 0 collections, heap now 1300 MiB, 0s paused in total
~~~

- A lower `GOGC` collects more often: less memory, more CPU spent collecting and more total pause time.
- A higher one collects less often: more memory, less collecting.
- `off` never collects: fastest here, and the heap holds every byte ever allocated. In a long-running service, that ends with the process killed for running out of memory.

Look at the times again: `GOGC=50` ran 59 collections and still finished before `GOGC=400`. Wall-clock time hides where the time went, so ask the kernel. GNU `time`, which measured the log analyser's memory in Foundations 03, also reports CPU time spent in your code (`user`) and in the kernel on your behalf (`sys`):

~~~bash
for g in 50 400 off; do GOGC=$g /usr/bin/time -f "GOGC=$g: %e s wall, %U s user, %S s sys, %M KB max resident" ./gcdrill > /dev/null; done
~~~

~~~text
GOGC=50: 0.32 s wall, 0.30 s user, 0.08 s sys, 30712 KB max resident
GOGC=400: 0.35 s wall, 0.20 s user, 0.16 s sys, 228060 KB max resident
GOGC=off: 0.02 s wall, 0.01 s user, 0.00 s sys, 7388 KB max resident
~~~

- `GOGC=50` spent more `user` time, the collector's work, but the least `sys` time. Its small heap reuses the same pages of memory again and again.
- `GOGC=400` collected less but held 7 times the memory, and doubled the `sys` time: every page the heap touches for the first time is a **page fault** the kernel has to serve. A bigger heap isn't free; it moves the cost from the collector to the kernel.
- `off` claims 1300 MiB of heap, yet never held more than 7 MB. Memory fresh from the kernel is already zero, and this drill never writes to its garbage, so those pages were never touched. Real programs fill their buffers, so don't read `off` as free.

On macOS, `/usr/bin/time -l ./gcdrill` prints the same figures in its own format.

That's the whole trade-off: memory against CPU. Since Go 1.19 there's a second knob, `GOMEMLIMIT`: a soft memory ceiling. With `GOGC=off` and a limit, the collector does nothing until the heap nears the limit, then works as hard as it must to stay under it:

~~~bash
GOGC=off GOMEMLIMIT=200MiB ./gcdrill
~~~

~~~text
allocated 1300 MiB in 445ms: 9 collections, heap now 102 MiB, 4.852ms paused in total
~~~

A container with 512 MiB of memory might run its Go service with `GOMEMLIMIT` at about 450 MiB: the collector stays idle while there's room, and works hard instead of letting the container be killed.

To watch each collection as it happens, `GODEBUG=gctrace=1` prints a line per cycle:

~~~bash
GODEBUG=gctrace=1 ./gcdrill 2>&1 | head -3; rm gcdrill
~~~

~~~text
gc 1 @0.000s 11%: 0.39+0.30+0.065 ms clock, 6.3+0.067/0.41/0+1.0 ms cpu, 4->4->4 MB, 4 MB goal, 0 MB stacks, 0 MB globals, 16 P
gc 2 @0.002s 10%: 0.18+0.32+0.005 ms clock, 2.8+0/0.71/0.065+0.095 ms cpu, 9->9->9 MB, 9 MB goal, 0 MB stacks, 0 MB globals, 16 P
gc 3 @0.003s 10%: 0.11+0.30+0.074 ms clock, 1.7+0/0.16/0.023+1.1 ms cpu, 19->19->19 MB, 19 MB goal, 0 MB stacks, 0 MB globals, 16 P
~~~

Each line: the cycle number; when it started; the share of CPU spent on GC so far; the wall-clock time of its phases (the first and last are the short **stop-the-world** pauses, the middle is the **concurrent** marking that runs alongside your code); heap size at the start, at the end, and live after marking; the next **goal**; and the number of Ps. The pauses are fractions of a millisecond: Go's collector does almost all its work while your goroutines keep running, which is why it rarely shows in latency unless you allocate heavily.

### Step 6: A trace of everything

The runtime can also record every scheduling decision, every GC phase and every blocking event into a **trace**, which `go tool trace` shows as a timeline in a browser. Benchmarks can record one directly:

~~~bash
go test -bench NewPoint -benchtime 100000x -trace trace.out ./drills/escape > /dev/null && ls -l trace.out
go tool trace -http 127.0.0.1:0 trace.out
~~~

~~~text
-rw-r--r-- 1 ada ada 13970 Nov 20 02:26 trace.out
~~~

`go tool trace` starts a small web server on a free port and opens your browser (if it doesn't, open the address it prints). "View trace by proc" shows each P as a row, with goroutines as coloured blocks and GC cycles above them. Press Ctrl+C when you're done, and delete `trace.out`. You'll use traces and profiles properly in core 06.

## Break it

**Turn the collector off in a loop that never ends.** In `drills/gc/main.go`, change `for range 20_000` to `for i := 0; ; i++` (forever), then run it with `GOGC=off` and a hard memory limit from the shell, `ulimit -v` (in KiB), so it can't take your machine down with it:

~~~bash
go build -o gcdrill ./drills/gc && (ulimit -v 1000000; GOGC=off ./gcdrill 2>&1 | head -4)
~~~

~~~text
runtime: out of memory: cannot allocate 4194304-byte block (272302080 in use)
fatal error: out of memory

goroutine 1 gp=0xc474befa1e0 m=0 mp=0x53ff00 [running]:
runtime.throw({0x48529f?, 0x76ca5a268820?})
	/usr/local/go/src/runtime/panic.go:1245 +0x48 fp=0xc474bf8ed58 sp=0xc474bf8ed28 pc=0x476ce8
runtime.(*mcache).allocLarge(0xc474bf8edd8?, 0x10000, 0x1)
	/usr/local/go/src/runtime/mcache.go:259 +0x18b fp=0xc474bf8eda8 sp=0xc474bf8ed58 pc=0x42094b
runtime.mallocgcLarge(0x530713?, 0x529af0, 0x1)
	/usr/local/go/src/runtime/malloc.go:1709 +0x79 fp=0xc474bf8ee00 sp=0xc474bf8eda8 pc=0x41a4b9
runtime.mallocgc(0x10000, 0x529af0, 0x1)
	/usr/local/go/src/runtime/malloc.go:1137 +0x11a fp=0xc474bf8ee30 sp=0xc474bf8ee00 pc=0x475d5a
runtime.makeslice(0xc474bfa6008?, 0x44f11f?, 0x0?)
	/usr/local/go/src/runtime/slice.go:117 +0x49 fp=0xc474bf8ee58 sp=0xc474bf8ee30 pc=0x478089
main.main()
	/home/ada/blueprint/switchyard/drills/gc/main.go:19 +0x109 fp=0xc474bf8eeb8 sp=0xc474bf8ee58 pc=0x483489
runtime.main()
	/usr/local/go/src/runtime/proc.go:302 +0x427 fp=0xc474bf8efe0 sp=0xc474bf8eeb8 pc=0x445f27
runtime.goexit({})
	/usr/local/go/src/runtime/asm_amd64.s:1264 +0x1 fp=0xc474bf8efe8 sp=0xc474bf8efe0 pc=0x47bfe1

goroutine 2 gp=0xc474befa780 m=nil [force gc (idle)]:
runtime.gopark(0x0?, 0x0?, 0x0?, 0x0?, 0x0?)
	/usr/local/go/src/runtime/proc.go:474 +0xca fp=0xc474bf64fa8 sp=0xc474bf64f88 pc=0x476dca
runtime.goparkunlock(...)
	/usr/local/go/src/runtime/proc.go:480
runtime.forcegchelper()
	/usr/local/go/src/runtime/proc.go:387 +0xb3 fp=0xc474bf64fe0 sp=0xc474bf64fa8 pc=0x4461f3
runtime.goexit({})
	/usr/local/go/src/runtime/asm_amd64.s:1264 +0x1 fp=0xc474bf64fe8 sp=0xc474bf64fe0 pc=0x47bfe1
created by runtime.init.7 in goroutine 1
	/usr/local/go/src/runtime/proc.go:375 +0x1a

goroutine 3 gp=0xc474befad20 m=nil [GC sweep wait]:
runtime.gopark(0x0?, 0x0?, 0x0?, 0x0?, 0x0?)
	/usr/local/go/src/runtime/proc.go:474 +0xca fp=0xc474bf65788 sp=0xc474bf65768 pc=0x476dca
runtime.goparkunlock(...)
	/usr/local/go/src/runtime/proc.go:480
runtime.bgsweep(0xc474bf7c000)
	/usr/local/go/src/runtime/mgcsweep.go:279 +0x94 fp=0xc474bf657c8 sp=0xc474bf65788 pc=0x4321b4
runtime.gcenable.gowrap1()
	/usr/local/go/src/runtime/mgc.go:214 +0x17 fp=0xc474bf657e0 sp=0xc474bf657c8 pc=0x4706b7
runtime.goexit({})
	/usr/local/go/src/runtime/asm_amd64.s:1264 +0x1 fp=0xc474bf657e8 sp=0xc474bf657e0 pc=0x47bfe1
created by runtime.gcenable in goroutine 1
	/usr/local/go/src/runtime/mgc.go:214 +0x66

goroutine 4 gp=0xc474befaf00 m=nil [GC scavenge wait]:
runtime.gopark(0xc474bf7c000?, 0x48c9d0?, 0x1?, 0x0?, 0xc474befaf00?)
	/usr/local/go/src/runtime/proc.go:474 +0xca fp=0xc474bf65f78 sp=0xc474bf65f58 pc=0x476dca
runtime.goparkunlock(...)
	/usr/local/go/src/runtime/proc.go:480
runtime.(*scavengerState).park(0x53ef00)
	/usr/local/go/src/runtime/mgcscavenge.go:425 +0x49 fp=0xc474bf65fa8 sp=0xc474bf65f78 pc=0x42fd89
runtime.bgscavenge(0xc474bf7c000)
	/usr/local/go/src/runtime/mgcscavenge.go:653 +0x3c fp=0xc474bf65fc8 sp=0xc474bf65fa8 pc=0x4302dc
runtime.gcenable.gowrap2()
	/usr/local/go/src/runtime/mgc.go:215 +0x17 fp=0xc474bf65fe0 sp=0xc474bf65fc8 pc=0x470677
runtime.goexit({})
	/usr/local/go/src/runtime/asm_amd64.s:1264 +0x1 fp=0xc474bf65fe8 sp=0xc474bf65fe0 pc=0x47bfe1
created by runtime.gcenable in goroutine 1
	/usr/local/go/src/runtime/mgc.go:215 +0xa5

goroutine 5 gp=0xc474befb4a0 m=nil [GOMAXPROCS updater (idle)]:
runtime.gopark(0x0?, 0x0?, 0x0?, 0x0?, 0x0?)
	/usr/local/go/src/runtime/proc.go:474 +0xca fp=0xc474bf64788 sp=0xc474bf64768 pc=0x476dca
runtime.goparkunlock(...)
	/usr/local/go/src/runtime/proc.go:480
runtime.updateMaxProcsGoroutine()
	/usr/local/go/src/runtime/proc.go:7146 +0xe7 fp=0xc474bf647e0 sp=0xc474bf64788 pc=0x453567
runtime.goexit({})
	/usr/local/go/src/runtime/asm_amd64.s:1264 +0x1 fp=0xc474bf647e8 sp=0xc474bf647e0 pc=0x47bfe1
created by runtime.defaultGOMAXPROCSUpdateEnable in goroutine 1
	/usr/local/go/src/runtime/proc.go:7134 +0x37

goroutine 6 gp=0xc474befb680 m=nil [finalizer wait]:
runtime.gopark(0x0?, 0x0?, 0x0?, 0x0?, 0x0?)
	/usr/local/go/src/runtime/proc.go:474 +0xca fp=0xc474bf66620 sp=0xc474bf66600 pc=0x476dca
runtime.runFinalizers()
	/usr/local/go/src/runtime/mfinal.go:210 +0x107 fp=0xc474bf667e0 sp=0xc474bf66620 pc=0x423587
runtime.goexit({})
	/usr/local/go/src/runtime/asm_amd64.s:1264 +0x1 fp=0xc474bf667e8 sp=0xc474bf667e0 pc=0x47bfe1
created by runtime.createfing in goroutine 1
	/usr/local/go/src/runtime/mfinal.go:172 +0x3d
exit 2
~~~

`head -4` keeps the start: after it, the runtime prints every goroutine's stack. `ulimit -v` limits the process's virtual memory, which includes address space the runtime reserves ahead of time, so it dies well before 1 GB of heap. Now run it with `GOGC=off GOMEMLIMIT=200MiB` under the same limit: it runs until you press Ctrl+C, collecting only when it must. Put `for range 20_000` back, and delete `gcdrill`.

## Check it

~~~bash
gofmt -l . && go vet ./... && go test -bench . -benchmem ./drills/escape | grep Benchmark
~~~

Then, without looking back, answer from what you ran:

1. How many threads did 10,000 sleeping goroutines need? Why so few?
2. Why did `newPoint` allocate and `newPointInlined` not?
3. What do `GOGC` and `GOMEMLIMIT` each trade, and which would you set for a service in a 1 GiB container?

That proves you can see what the scheduler, escape analysis and the collector are doing. It doesn't tell you where *your* service spends its time: profiling and flame graphs come in core 06.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `schedtrace` prints nothing | `GODEBUG` set on `go run`, so it traced the `go` command and the program ran too briefly | Build first, then run the binary with `GODEBUG` |
| Benchmark numbers jump between runs | Other programs, CPU frequency, a laptop on battery | Run with `-count 5` and compare the middle values |
| `-gcflags=-m` prints nothing for your function | It isn't compiled because nothing uses it, or the output went to stderr | Build the package itself; add `2>&1` |
| `go tool trace` says it can't open a browser | No browser in WSL | Open the printed `http://127.0.0.1:...` address in Windows |
| `fatal error: out of memory` | The heap grew past what the system allowed | Expected in "Break it"; in a service, set `GOMEMLIMIT` and find what keeps memory alive |
