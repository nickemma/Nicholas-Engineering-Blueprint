# 03 How the event loop works

> Module: Python runtime and honest measurement · Time: ~4 h · Builds on: 02; Foundations 04 lesson 08 (`asyncio` basics)

## The problem

In Foundations 04 you used `async def` and `await` to keep many connections busy from one thread, and it worked. But `await` was a word you typed, not something you could explain. `kload` will schedule thousands of requests on one event loop and time each to the millisecond, so you need to know exactly when a coroutine runs, when it waits, and what makes every other coroutine late. You'll find out by building a small event loop yourself, then checking that `asyncio`'s behaves the same way.

## The mental model

~~~text
                       ┌──────────────── the event loop (one thread) ────────────────┐
  ready queue:         │  task A   task C                                             │
                       │    │ run until it yields "I'm waiting for X"                 │
                       │    ▼                                                         │
  waiting for a socket │  task B ─▶ selector (epoll on Linux, kqueue on macOS)         │
  waiting for a timer  │  task D ─▶ timer heap, soonest first                         │
                       │                                                              │
  nothing ready? ask the kernel: "wake me when a socket is ready, or at the next timer"│
                       └──────────────────────────────────────────────────────────────┘
~~~

- A **task** is a paused computation: a generator or a coroutine. It runs until it says what it's waiting for, then hands control back. That's **cooperative** multitasking: nothing interrupts a task.
- The **selector** asks the kernel which sockets are ready (`epoll` on Linux, `kqueue` on macOS), and can sleep until one is.
- The **timer heap** keeps sleeping tasks in order of when they're due.
- The **loop** runs every ready task, then sleeps in the kernel until a socket is ready or the next timer is due, then moves those tasks to the ready queue. One thread, many tasks.
- The cost of cooperation: a task that **doesn't** hand control back (a blocking call, a long computation) stops every other task.

## The pattern

**One thread, cooperative tasks, and a rule: never block the loop.** Waiting goes through the loop (`await`), so other tasks run meanwhile. Blocking work goes to another thread (`asyncio.to_thread`) or another process.

## Build it

### Step 1: An event loop by hand

Create `drills/byhand.py`. It's the longest drill in the module, and it's the whole idea of `asyncio` in about a hundred lines:

<!-- file: drills/byhand.py -->
~~~python
"""Lesson 03: an event loop by hand, from generators and selectors.

One thread runs an echo server and three clients at once. Each task is a
generator that yields what it is waiting for; the loop resumes it when that
has happened.
"""

import heapq
import selectors
import socket
import time
from collections import deque

START = time.monotonic()


def log(message: str) -> None:
    print(f"{time.monotonic() - START:5.2f} s  {message}")


class Loop:
    def __init__(self) -> None:
        self.ready: deque = deque()  # tasks that can run now
        self.timers: list = []  # (when, number, task), soonest first
        self.selector = selectors.DefaultSelector()
        self.number = 0

    def spawn(self, task) -> None:
        self.ready.append(task)

    def run(self) -> None:
        while self.ready or self.timers or self.selector.get_map():
            if not self.ready:
                self.wait()
                continue
            task = self.ready.popleft()
            try:
                what, arg = next(task)  # run the task until it yields
            except StopIteration:
                continue  # the task has finished
            if what == "sleep":
                self.number += 1
                heapq.heappush(self.timers, (time.monotonic() + arg, self.number, task))
            elif what == "read":
                self.selector.register(arg, selectors.EVENT_READ, task)
            elif what == "write":
                self.selector.register(arg, selectors.EVENT_WRITE, task)

    def wait(self) -> None:
        """Nothing can run: sleep in the kernel until a socket is ready or a timer is due."""
        timeout = None
        if self.timers:
            timeout = max(0.0, self.timers[0][0] - time.monotonic())
        for key, _ in self.selector.select(timeout):
            self.selector.unregister(key.fileobj)
            self.ready.append(key.data)
        while self.timers and self.timers[0][0] <= time.monotonic():
            self.ready.append(heapq.heappop(self.timers)[2])


def server(loop: Loop, listener: socket.socket, connections: int):
    for _ in range(connections):
        yield "read", listener  # wait for a connection
        conn, _ = listener.accept()
        conn.setblocking(False)
        loop.spawn(echo(conn))
    listener.close()


def echo(conn: socket.socket):
    while True:
        yield "read", conn
        data = conn.recv(65536)
        if not data:
            conn.close()
            return
        yield "write", conn
        conn.send(data)  # small replies: one send is enough here


def client(name: str, port: int, lines: int, pause: float):
    sock = socket.socket()
    sock.setblocking(False)
    sock.connect_ex(("127.0.0.1", port))  # returns at once; the connection completes later
    yield "write", sock  # writable means connected
    for i in range(lines):
        sock.send(f"{name} {i}\n".encode())
        reply = b""
        while not reply.endswith(b"\n"):
            yield "read", sock
            reply += sock.recv(65536)
        log(f"{name} got back {reply!r}")
        yield "sleep", pause
    sock.close()


if __name__ == "__main__":
    listener = socket.create_server(("127.0.0.1", 0))
    listener.setblocking(False)
    port = listener.getsockname()[1]
    loop = Loop()
    loop.spawn(server(loop, listener, connections=3))
    for name in ("a", "b", "c"):
        loop.spawn(client(name, port, lines=3, pause=0.1))
    loop.run()
    log("all tasks finished, in one thread")
~~~

Read it in three parts:

- `server`, `echo` and `client` are **generators**: each `yield` hands the loop a request, `("read", sock)`, `("write", sock)` or `("sleep", seconds)`, and pauses the generator right there. Every socket is non-blocking, so no call can stall the thread.
- `Loop.run` takes the next ready task and runs it with `next(task)` until its next `yield`, then files it under what it's waiting for: a timer in the heap, or a socket registered with the selector.
- `Loop.wait` runs when nothing is ready. `selector.select(timeout)` sleeps **in the kernel** until a socket is ready or the next timer is due, so the loop uses no CPU while it waits.

~~~bash
uv run python drills/byhand.py
~~~

~~~text
 0.00 s  a got back b'a 0\n'
 0.00 s  b got back b'b 0\n'
 0.00 s  c got back b'c 0\n'
 0.10 s  a got back b'a 1\n'
 0.10 s  b got back b'b 1\n'
 0.10 s  c got back b'c 1\n'
 0.20 s  a got back b'a 2\n'
 0.20 s  b got back b'b 2\n'
 0.20 s  c got back b'c 2\n'
 0.30 s  all tasks finished, in one thread
~~~

An echo server and three clients, each sending a line every 0.1 s, all in one thread, all interleaved. Each round of three replies arrives within a millisecond, and the whole thing takes 0.3 s, not 0.9: while one client sleeps, the others run.

### Step 2: What `await` really does

A coroutine (`async def`) is a generator underneath. Create `drills/await.py`:

<!-- file: drills/await.py -->
~~~python
"""Lesson 03: what await does, with no event loop at all."""

import types


@types.coroutine
def pause(reason: str):
    """The lowest level: a generator that hands `reason` to whoever runs us."""
    reply = yield reason
    return reply


async def task() -> str:
    first = await pause("waiting for a socket")
    second = await pause("waiting for a timer")
    return f"done with {first!r} and {second!r}"


if __name__ == "__main__":
    coro = task()
    print(f"task() returned {type(coro).__name__}; nothing has run yet")
    print(f"send(None)      -> the task yields {coro.send(None)!r}")
    print(f"send('data')    -> the task yields {coro.send('data')!r}")
    try:
        coro.send("tick")
    except StopIteration as stop:
        print(f"send('tick')    -> StopIteration: the task returned {stop.value!r}")
~~~

~~~bash
uv run python drills/await.py
~~~

~~~text
task() returned coroutine; nothing has run yet
send(None)      -> the task yields 'waiting for a socket'
send('data')    -> the task yields 'waiting for a timer'
send('tick')    -> StopIteration: the task returned "done with 'data' and 'tick'"
~~~

Calling `task()` ran nothing: it made a coroutine object. Each `send` ran it until the next `await` reached a `yield` deep inside, and the yielded value came out to whoever called `send`: here, the drill; in real code, the event loop. The value sent in came back out of the `await`. When the coroutine returned, `StopIteration` carried its return value.

That's all `await` is: a pause that passes a message to the loop, and the loop's reply back in. `asyncio`'s futures yield in exactly this way when they aren't done yet.

### Step 3: The same program on `asyncio`

Create `drills/withasyncio.py`:

<!-- file: drills/withasyncio.py -->
~~~python
"""Lesson 03: byhand.py again, with asyncio's event loop instead of ours."""

import asyncio
import time

START = time.monotonic()


def log(message: str) -> None:
    print(f"{time.monotonic() - START:5.2f} s  {message}")


async def echo(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    while data := await reader.read(65536):
        writer.write(data)
        await writer.drain()
    writer.close()


async def client(name: str, port: int, lines: int, pause: float) -> None:
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    for i in range(lines):
        writer.write(f"{name} {i}\n".encode())
        reply = await reader.readline()
        log(f"{name} got back {reply!r}")
        await asyncio.sleep(pause)
    writer.close()
    await writer.wait_closed()


async def main() -> None:
    server = await asyncio.start_server(echo, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    async with server:
        await asyncio.gather(*(client(name, port, 3, 0.1) for name in ("a", "b", "c")))
    log("all tasks finished, in one thread")


if __name__ == "__main__":
    asyncio.run(main())
~~~

~~~bash
uv run python drills/withasyncio.py
~~~

~~~text
 0.00 s  a got back b'a 0\n'
 0.00 s  b got back b'b 0\n'
 0.00 s  c got back b'c 0\n'
 0.10 s  a got back b'a 1\n'
 0.10 s  b got back b'b 1\n'
 0.10 s  c got back b'c 1\n'
 0.20 s  a got back b'a 2\n'
 0.20 s  b got back b'b 2\n'
 0.20 s  c got back b'c 2\n'
 0.30 s  all tasks finished, in one thread
~~~

The same interleaving and the same 0.3 s, in 40 lines instead of 106. `asyncio.open_connection` and `start_server` do the non-blocking sockets and the selector registration; `reader.readline()` loops until a whole line has arrived; `asyncio.sleep` pushes a timer. Under it all is a loop like yours.

### Step 4: Block the loop, and measure the damage

Create `drills/blocked.py`:

<!-- file: drills/blocked.py -->
~~~python
"""Lesson 03: what one blocking call does to everything else on the loop."""

import argparse
import asyncio
import time

TICK = 0.01  # the monitor asks to wake every 10 ms


async def monitor(seconds: float) -> float:
    """Sleep in 10 ms steps and return the worst lateness of any wake-up, in ms."""
    worst = 0.0
    loop = asyncio.get_running_loop()
    end = loop.time() + seconds
    while loop.time() < end:
        due = loop.time() + TICK
        await asyncio.sleep(TICK)
        worst = max(worst, loop.time() - due)
    return worst * 1000


def count(n: int) -> int:
    total = 0
    for i in range(n):
        total += i
    return total


async def polite() -> None:
    await asyncio.sleep(0.2)  # gives the loop back while it waits


async def sleeps() -> None:
    time.sleep(0.2)  # blocks the only thread: nothing else runs


async def computes() -> None:
    count(10_000_000)  # CPU work blocks it the same way


async def offloaded() -> None:
    await asyncio.to_thread(time.sleep, 0.2)  # the wait happens in another thread


async def scenario(name: str, work) -> None:
    monitor_task = asyncio.create_task(monitor(0.5))
    await asyncio.sleep(0.1)
    await work()
    print(f"{name:<42} worst wake-up lateness {await monitor_task:6.1f} ms")


async def main() -> None:
    await scenario("await asyncio.sleep(0.2)", polite)
    await scenario("time.sleep(0.2) inside a coroutine", sleeps)
    await scenario("counting to 10 million", computes)
    await scenario("await asyncio.to_thread(time.sleep, 0.2)", offloaded)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--debug", action="store_true", help="asyncio's debug mode")
    asyncio.run(main(), debug=parser.parse_args().debug)
~~~

`monitor` asks to wake every 10 ms for half a second and records how late its worst wake-up was. Each scenario runs one piece of work next to it.

~~~bash
uv run python drills/blocked.py
~~~

~~~text
await asyncio.sleep(0.2)                   worst wake-up lateness    1.4 ms
time.sleep(0.2) inside a coroutine         worst wake-up lateness  200.7 ms
counting to 10 million                     worst wake-up lateness  235.7 ms
await asyncio.to_thread(time.sleep, 0.2)   worst wake-up lateness    1.1 ms
~~~

- `await asyncio.sleep(0.2)` handed the loop back: the monitor woke on time, give or take a millisecond.
- `time.sleep(0.2)` inside a coroutine held the only thread for 0.2 s, and the monitor woke about 200 ms late. Every other task on the loop would have, too.
- Counting to ten million is no different: computation doesn't yield.
- `asyncio.to_thread(time.sleep, 0.2)` ran the blocking call in a worker thread, and the loop stayed free.

Notice that the monitor's best case is already about a millisecond late. On Linux, the loop's sleep in the kernel (`epoll_wait`) counts in whole milliseconds, so a timer can fire up to 1 ms after it was due. That's the floor on how precisely `kload` can send a request on time, and lesson 06 measures it.

### Step 5: Let `asyncio` tell you

`asyncio` has a debug mode that reports any step that holds the loop for more than 100 ms:

~~~bash
uv run python drills/blocked.py --debug 2>&1 | grep -o "Executing <Task.*took [0-9.]* seconds" | sed "s/coro=.* took/... took/"
~~~

~~~text
Executing <Task pending name='Task-1' ... took 0.201 seconds
Executing <Task pending name='Task-1' ... took 0.257 seconds
~~~

It named the two scenarios that blocked, and how long each held the loop. (The full message is long: it lists the task and where each waiting future was created. The `grep` and `sed` trim it.) Debug mode slows everything down, so use it to find a blocking call, not to measure.

<!-- run: uv run python drills/byhand.py && uv run python drills/await.py && uv run python drills/withasyncio.py && uv run python drills/blocked.py -->

## Break it

**Block inside the hand-made loop.** In `drills/byhand.py`, in `client`, replace `yield "sleep", pause` with `time.sleep(pause)`. Run `uv run python drills/byhand.py | tail -2`:

~~~text
 0.80 s  c got back b'c 2\n'
 0.90 s  all tasks finished, in one thread
~~~

The three clients now take turns, and the run takes 0.9 s instead of 0.3 s, because a task that never yields keeps the loop to itself. Put the `yield` back.

## Check it

~~~bash
uv run python drills/blocked.py
~~~

Then, from memory: what does a task do at a `yield` or an `await`, and what does the loop do next? Where does an idle loop sleep? Why is `time.sleep` inside a coroutine a bug, and what do you use instead? What's the smallest lateness a timer on this loop can have, and why?

This shows how an event loop schedules tasks, and what blocking costs in a drill. It doesn't find blocking calls in your own code: debug mode does that, and lesson 06 makes `kload` measure its own lateness on every run.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `byhand.py` hangs | A task waits on a socket that never becomes ready (for example, `"read"` where it meant `"write"`) | Compare with the drill; press Ctrl-C and read which `yield` it was on |
| `BlockingIOError` | A socket call ran before the loop said the socket was ready | Every `send`/`recv`/`accept` must follow its `yield` |
| `RuntimeError: asyncio.run() cannot be called from a running event loop` | `asyncio.run` inside a coroutine | Call it once, at the top; use `await` inside |
| `RuntimeWarning: coroutine '...' was never awaited` | Called an `async def` without `await` | Add `await`, or wrap it in `asyncio.create_task` |
| The debug run prints nothing | Python buffered the output and `grep` matched nothing, or the scenario took under 100 ms | Run without the pipe and read the warnings |
