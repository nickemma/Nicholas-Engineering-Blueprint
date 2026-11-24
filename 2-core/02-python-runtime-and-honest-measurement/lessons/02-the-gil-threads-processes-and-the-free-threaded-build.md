# 02 The GIL: threads, processes and the free-threaded build

> Module: Python runtime and honest measurement · Time: ~3 h · Builds on: 01

## The problem

A Go program with 8 goroutines doing arithmetic uses 8 CPUs. Write the same thing in Python with 8 threads and it uses one, and takes 8 times as long. Threads in Python still help with some work, though, and Python 3.14 ships a build where they help with all of it. Before `kload` uses threads, processes or neither, you need to know which work each one speeds up, and what a busy thread does to the others' timing, because a load generator's timing is its whole job.

## The mental model

~~~text
  standard CPython: one global interpreter lock (GIL)

  thread 1  ████████░░░░░░░░████████░░░░░░░░   █ holds the GIL, runs Python
  thread 2  ░░░░░░░░████████░░░░░░░░████████   ░ waits for it
            └ switch interval: 5 ms ┘

  thread 3  ──sleep / read a socket── (releases the GIL while it waits)

  processes: each has its own interpreter and its own GIL
  process 1 ████████████████   process 2 ████████████████   (truly in parallel)

  free-threaded CPython (3.14t): no GIL; threads run Python in parallel
~~~

- The **GIL** (global interpreter lock) lets only one thread run Python bytecode at a time. It protects the interpreter's own state, such as every object's reference count.
- A thread that waits (`time.sleep`, reading a socket, writing a file) **releases** the GIL while it waits, so waiting threads do overlap.
- A thread that computes keeps the GIL until the **switch interval** (5 ms) runs out; then the interpreter asks it to hand over.
- A **process** has its own interpreter and its own GIL. Processes run Python in parallel, at the cost of starting them and copying data between them.
- The **free-threaded build** (`python3.14t`) has no GIL. It's an official build since 3.14, but not yet the default.

## The pattern

**Match the tool to the work.** Waiting work (network, disk, timers): threads, or one thread with `asyncio`. Computing work: processes, or the free-threaded build. And never let computing work share an interpreter with something whose timing matters.

## Build it

### Step 1: Computing and waiting, in threads and processes

Create `drills/gil.py`:

<!-- file: drills/gil.py -->
~~~python
"""Lesson 02: the same work in threads and in processes, CPU-bound and waiting."""

import sys
import time
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor

WORK = 3_000_000  # loop iterations per task


def count(n: int) -> int:
    """CPU-bound: nothing but Python bytecode."""
    total = 0
    for i in range(n):
        total += i
    return total


def wait(seconds: float) -> float:
    """I/O-bound: the thread sleeps, as it would waiting for the network."""
    time.sleep(seconds)
    return seconds


def run(pool_class, workers: int, fn, arg) -> float:
    start = time.perf_counter()
    with pool_class(max_workers=workers) as pool:
        list(pool.map(fn, [arg] * workers))
    return time.perf_counter() - start


if __name__ == "__main__":
    gil = sys._is_gil_enabled() if hasattr(sys, "_is_gil_enabled") else True
    print(f"Python {sys.version.split()[0]}, GIL {'enabled' if gil else 'disabled'}")
    print("== CPU-bound: each task counts to 3 million; perfect scaling keeps the time flat")
    for workers in (1, 2, 4, 8):
        threads = run(ThreadPoolExecutor, workers, count, WORK)
        processes = run(ProcessPoolExecutor, workers, count, WORK)
        tasks = f"{workers} task" + "s" * (workers > 1)
        print(f"{tasks}: threads {threads:.2f} s   processes {processes:.2f} s")
    print("== I/O-bound: each task sleeps 0.2 s")
    for workers in (1, 8, 64):
        took = run(ThreadPoolExecutor, workers, wait, 0.2)
        print(f"{workers:>2} task{'s' * (workers > 1)} in threads: {took:.2f} s")
~~~

`ThreadPoolExecutor` and `ProcessPoolExecutor` share one interface: `pool.map(fn, args)` runs `fn` on each argument across the pool's workers and returns the results in order. The drill gives each worker the same task, so perfect parallelism keeps the time flat as the number of tasks grows.

~~~bash
uv run python drills/gil.py
~~~

~~~text
Python 3.14.7, GIL enabled
== CPU-bound: each task counts to 3 million; perfect scaling keeps the time flat
1 task: threads 0.11 s   processes 0.25 s
2 tasks: threads 0.20 s   processes 0.16 s
4 tasks: threads 0.43 s   processes 0.22 s
8 tasks: threads 0.85 s   processes 0.36 s
== I/O-bound: each task sleeps 0.2 s
 1 task in threads: 0.20 s
 8 tasks in threads: 0.20 s
64 tasks in threads: 0.22 s
~~~

- **CPU-bound, threads:** the time grows with the number of tasks. Eight threads did eight tasks one at a time, taking turns with the GIL. Threads bought nothing.
- **CPU-bound, processes:** nearly flat, because each process has its own GIL. But one task took longer in a process than in a thread: starting a process, and sending the task and its result between processes, costs about 0.15 s here.
- **Waiting, threads:** 64 threads each sleeping 0.2 s finished in about 0.2 s. Sleeping releases the GIL.

### Step 2: The same drill without a GIL

uv can install the free-threaded build next to the standard one:

~~~bash
uv python install 3.14t
uv run --no-project --python 3.14t drills/gil.py
~~~

`--no-project` runs the file on its own, so the project's `.venv` keeps the standard Python.

~~~text
Downloading cpython-3.14.7+freethreaded-linux-x86_64-gnu (download) (34.4MiB)
 Downloaded cpython-3.14.7+freethreaded-linux-x86_64-gnu (download)
Installed Python 3.14.7 in 2.99s
 + cpython-3.14.7+freethreaded-linux-x86_64-gnu (python3.14t)
Python 3.14.7, GIL disabled
== CPU-bound: each task counts to 3 million; perfect scaling keeps the time flat
1 task: threads 0.09 s   processes 0.25 s
2 tasks: threads 0.10 s   processes 0.12 s
4 tasks: threads 0.17 s   processes 0.16 s
8 tasks: threads 0.23 s   processes 0.29 s
== I/O-bound: each task sleeps 0.2 s
 1 task in threads: 0.20 s
 8 tasks in threads: 0.20 s
64 tasks in threads: 0.23 s
~~~

uv installed `python3.14t` beside the standard Python. The drill's first line now says `GIL disabled`, and eight threads take 0.23 s instead of 0.85 s, as fast as eight processes, without the cost of starting them. The waiting numbers are unchanged: they never needed the GIL's absence.

Why isn't this the default? Without the GIL, every object's reference count must be updated safely from many threads at once, which costs a little on every operation; and C extensions written for the GIL must be checked and rebuilt before they're safe without it. 3.14 makes the free-threaded build supported; the default may change once most extensions are ready.

### Step 3: What a busy thread does to a waiting one

`kload` will spend most of its time waiting, and it will care how late it wakes up. Create `drills/switch.py`:

<!-- file: drills/switch.py -->
~~~python
"""Lesson 02: how late a waiting thread wakes up while another thread computes."""

import sys
import threading
import time


def spin(stop: threading.Event) -> None:
    while not stop.is_set():
        pass  # pure Python bytecode: holds the GIL whenever it runs


def oversleep_ms(samples: int = 200) -> list[float]:
    """Sleep 1 ms, again and again, and record how much later than asked each wake-up was."""
    late = []
    for _ in range(samples):
        start = time.perf_counter()
        time.sleep(0.001)
        late.append((time.perf_counter() - start - 0.001) * 1000)
    return sorted(late)


def report(name: str, late: list[float]) -> None:
    print(f"{name:<34} median {late[len(late) // 2]:5.2f} ms late, worst {late[-1]:5.2f} ms")


if __name__ == "__main__":
    gil = sys._is_gil_enabled() if hasattr(sys, "_is_gil_enabled") else True
    interval_ms = sys.getswitchinterval() * 1000
    print(f"GIL {'enabled' if gil else 'disabled'}, switch interval {interval_ms:g} ms")
    report("alone", oversleep_ms())
    stop = threading.Event()
    spinner = threading.Thread(target=spin, args=(stop,))
    spinner.start()
    report("while another thread computes", oversleep_ms())
    stop.set()
    spinner.join()
~~~

It sleeps 1 ms, 200 times, and records how late each wake-up is: first alone, then while another thread spins in a Python loop.

~~~bash
uv run python drills/switch.py
uv run --no-project --python 3.14t drills/switch.py
~~~

~~~text
GIL enabled, switch interval 5 ms
alone                              median  0.10 ms late, worst  0.27 ms
while another thread computes      median  5.22 ms late, worst  5.35 ms
GIL disabled, switch interval 5 ms
alone                              median  0.10 ms late, worst  0.29 ms
while another thread computes      median  0.09 ms late, worst  0.14 ms
~~~

Alone, the thread woke a fraction of a millisecond late. With a computing thread beside it, it woke **5 ms** late every time: it had to wait for the switch interval to run out before it got the GIL back. Without the GIL, the computing thread made no difference.

That's the lesson for `kload`. A Python load generator that computes in one thread (parsing, sorting, plotting) while another thread sends requests adds up to 5 ms to every request it times, and reports it as the server's latency. `kload` will do its waiting in one thread with `asyncio` (lesson 03), keep its computing out of the way, and measure its own lateness (lesson 06).

<!-- run: uv run python drills/gil.py && uv run python drills/switch.py -->

## Break it

**Make the waiting compute.** In `drills/gil.py`, change `wait` to call `count(WORK)` instead of `time.sleep(seconds)`, and run `uv run python drills/gil.py | tail -4`:

~~~text
== I/O-bound: each task sleeps 0.2 s
 1 task in threads: 0.09 s
 8 tasks in threads: 0.70 s
64 tasks in threads: 5.87 s
~~~

The "I/O-bound" rows now grow with the number of threads, like the CPU-bound ones. What makes threads help is not the word "I/O" but whether the thread gives the GIL back. Change it back.

## Check it

~~~bash
uv run python drills/switch.py
~~~

Then, from memory: which work do threads speed up in standard Python, and why? What does a process cost that a thread doesn't? What does the free-threaded build change, and why isn't it the default? Why would a computing thread make a load generator report slower latencies?

This shows the GIL's effect on two small drills on your machine. It doesn't tell you how a real program will scale: that depends on how much of its time it spends waiting, which you measure in that program.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `uv python install 3.14t` fails or hangs | No network, or a slow download | Retry; the build is about 35 MB |
| `GIL enabled` under `--python 3.14t` | A `PYTHON_GIL=1` setting, or an extension that turned the GIL back on | `unset PYTHON_GIL`; the drill uses only the standard library |
| Processes are slower than threads for every count | Very few CPUs (a small VM or container) | `nproc`; with 2 CPUs, 4 and 8 processes queue up too |
| `AttributeError: _is_gil_enabled` | Python older than 3.13 | The drill handles it; `uv run python --version` should say 3.14 |
