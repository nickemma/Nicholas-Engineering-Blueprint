# Stage 1 — How does a computer run your code?

**16 lessons · 3 hours each · ~5 weeks · Weeks 1–5**

Starting from zero. Nothing assumed. If something here is already obvious to you, say so at the start of the lesson and I'll test it in ten minutes rather than teach it in three hours.

---

## What you'll learn

By the end of this stage you'll be able to trace what happens from the moment you type `go run main.go` to the moment your code executes — through the compiler, the kernel, memory, the CPU, and the Go runtime — and you'll be able to write concurrent Go without creating the two bugs that kill most Go services.

## What it's for

Everything after this stage assumes it. A distributed system is many computers doing this. If the single-machine model is fuzzy, every distributed concept lands on sand — which is why "I know Go" is not the same thing as "I know what Go is doing."

## Prerequisites

A terminal, Go installed, git. That's it.

## You build

A long-running Linux service in Go: reads config, handles signals, logs in structured JSON, exposes metrics and a health endpoint, shuts down gracefully, and survives everything I throw at it in Lesson 16.

## Done when

- You can explain a stack trace without guessing
- You can find a goroutine leak in a heap profile
- You can say what a pointer *is*, not just what syntax uses one
- Your service survives Lesson 16's failure day

---

## The lessons

### Block A — What a computer is actually doing (L1–L4)

No Go yet. We're building the mental model everything else hangs on.

**L1 · What a program actually is** 🧠🔬
Text file → compiler → binary → the OS loads it → a process exists. What "running" means. What the OS handed your program before your first line executed.
*Experiment:* compile the same tiny program, look at the binary, watch the process appear and disappear.

**L2 · Memory — what your program is holding** 🧠🔬
Memory as a very long street of numbered houses. Addresses. Stack vs heap in plain English. Why "out of memory" happens to a program with plenty of RAM available.
*Experiment:* allocate 1GB and watch the numbers move.

**L3 · The CPU, and why some code is 100× slower** 🧠🔬
Instructions, cycles, and the cache hierarchy. Why *where* your data sits matters more than how clever your loop is.
*Experiment:* the same loop over the same data, two orderings, wildly different times. You'll measure it yourself.

**L4 · The kernel — the referee** 🧠🔬
User space vs kernel space. Why your program can't just talk to the disk. System calls as the only door between the two. What actually happens on `println`.
*Experiment:* `strace` a five-line program and read every line of it.

### Block B — Go from zero (L5–L9)

**L5 · Processes, signals, exit codes** 🔬💻
Starting things, stopping things, and what "stopping" means. SIGTERM vs SIGKILL and why one is catchable. Exit codes.
*Build:* a Go program that refuses to die badly.

**L6 · Files and file descriptors** 🧠💻
Everything is a file — including sockets, which is why this matters later. Open, read, write, close. What a descriptor number actually indexes.
*Build:* read and write files properly, including the error cases everyone skips.

**L7 · Go, the shape of a program** 💻
Packages, `func main`, types, variables, control flow, errors as values. Why Go has no exceptions and what that costs you.

**L8 · Go data — and what a pointer really is** 💻💥
Structs, slices, maps. Then pointers, tied straight back to L2's numbered houses. Value vs reference and the bugs that live in the gap.
*Break:* I give you code that mutates the wrong thing. You find out why.

**L9 · Go behaviour — interfaces and composition** 💻
Methods, interfaces, why Go composes instead of inheriting. The pattern that will structure every project you build after this.

### Block C — Concurrency (L10–L13)

The heart of the stage. Most Go engineers are shaky here and it shows in production.

**L10 · Goroutines and the scheduler** 🧠💻
What a goroutine actually is (not a thread). Why "cheap" is misleading. The scheduler in plain English.
*Build:* spawn many, watch them run, watch memory.

**L11 · Channels, select, context** 💻
Passing work between goroutines. `select` for waiting on several things at once. `context` for cancellation and deadlines — threaded properly, which almost nobody does.

**L12 · Mutexes, races, atomics** 💻💥
Shared state, and what happens when two goroutines touch it. What a data race *is* at the memory level.
*Break:* I hand you a race. You find it with `-race`, then explain it, then fix it three different ways and argue for one.

**L13 · Memory and garbage collection in Go** 🔬💥
Where the garbage collector helps and where it hurts. Escape analysis. Reading a heap profile.
*Experiment:* find a goroutine leak in a profile — the single most useful debugging skill in this stage.

### Block D — Making it real (L14–L16)

**L14 · Debugging** 💥
Stack traces read properly. `delve`. `strace`. `-race`. `pprof`. How to form a hypothesis instead of changing lines until it works.

**L15 · Stage project — a Linux service in Go** 💻
Everything so far, in one thing: config from environment, structured JSON logs, a `/healthz` endpoint, Prometheus metrics, bounded concurrency, `context` deadlines end to end, graceful shutdown on SIGTERM.
I give you the file layout and the order to build in. You write it.

**L16 · Failure day + assessment** 💥🧪
I break it: SIGKILL mid-work, memory limit exceeded, a slow client that never finishes, a config file that's garbage, disk full on log write, 10,000 connections at once.
Then the assessment — I ask, you explain. Then you write the reflection (`04-TEMPLATES.md`).

---

## Case study chain for this stage

```
Your service   →  processes, signals, cgroups  →  how Docker starts and stops containers
Your goroutines →  the Go scheduler            →  how Kubernetes' control plane stays responsive
Your profiling  →  pprof                       →  how real Go outages get diagnosed
```

---

## Stage exit assessment

You pass when you can answer these cold, in your own words:

1. What did the operating system do before your first line of Go ran?
2. Why is a goroutine not a thread, and when does that difference bite?
3. What is a data race, at the level of memory, not syntax?
4. Your service's memory climbs steadily and never drops. Name three causes and how you'd distinguish them.
5. A client connects and sends one byte per minute. What happens to your service, and what should happen?
6. Trace `go run main.go` to your first line executing.

If any answer is shaky, that lesson gets re-taught. That's not failure — it's the whole design.
