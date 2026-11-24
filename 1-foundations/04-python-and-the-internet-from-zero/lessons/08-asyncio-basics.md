# 08 `asyncio` basics

> Module: Python and the internet from zero · Time: ~5 h · Builds on: 04, 07

## The problem

To measure your echo server properly, you need many clients talking to it at once. In Go you'd start a goroutine per client. Python has threads, but a Python program runs Python code on one CPU at a time, and threads are an awkward way to juggle hundreds of connections. What a network client really does is *wait*: for a connection, for a reply. Python's answer is **`asyncio`**: one thread that runs many tasks, switching to another task whenever the current one has to wait. It's how most Python network tools work, from web servers to load generators.

## The mental model

~~~text
 one thread, one event loop, many coroutines

 task A: send ── await reply ...................... reply arrives ── send ── await ...
 task B:        send ── await reply ........ reply ── send ── await ...
 task C:               send ── await reply .................. reply ── ...
           ▲      ▲      ▲
           └──────┴──────┴── each await hands control back to the loop, which runs
                             whichever task can go on; nothing runs at the same instant
~~~

- A **coroutine** is a function defined with `async def`. Calling it doesn't run it: it returns a coroutine object, a paused piece of work.
- **`await`** runs a coroutine and waits for its result. While it waits (for the network, or a timer), the **event loop** runs other tasks.
- `asyncio.run(main())` starts the event loop, runs `main()` to the end, and stops.
- `asyncio.gather(a, b, c)` runs several coroutines at the same time, and returns all their results, in order.

It's like goroutines, with one big difference: a goroutine can be paused anywhere, but a coroutine only gives up control at an `await`. Code between two `await`s runs without interruption, which makes many races impossible, and makes one mistake fatal: anything slow that doesn't `await` stops *every* task.

## The pattern

**Never block the loop.** Inside `async` code, every wait must be an `await` on something `asyncio` understands: `asyncio.sleep`, a stream read, an `asyncio`-aware library. A plain blocking call, such as `time.sleep` or reading a big file, freezes all the tasks at once.

## Build it

### Step 1: Waiting one at a time, then all at once

Create `measure/drills/waits.py`:

<!-- file: measure/drills/waits.py -->
~~~python
"""Lesson 08: waiting one by one, then all at once."""

import asyncio
import time


async def fetch(name: str, seconds: float) -> str:
    """Pretend to fetch something that takes a while to answer."""
    await asyncio.sleep(seconds)
    return name


async def one_by_one() -> list[str]:
    return [await fetch("a", 0.5), await fetch("b", 0.5), await fetch("c", 0.5)]


async def all_at_once() -> list[str]:
    return await asyncio.gather(fetch("a", 0.5), fetch("b", 0.5), fetch("c", 0.5))


for job in (one_by_one, all_at_once):
    start = time.perf_counter()
    names = asyncio.run(job())
    print(f"{job.__name__}: {names} in {time.perf_counter() - start:.2f} s")
~~~

~~~bash
uv run python drills/waits.py
~~~

<!-- run: cd measure && uv run python drills/waits.py | tail -1 | grep -q "all_at_once: \['a', 'b', 'c'\] in 0.5" -->

~~~text
one_by_one: ['a', 'b', 'c'] in 1.50 s
all_at_once: ['a', 'b', 'c'] in 0.50 s
~~~

- `fetch` stands in for a network call: `asyncio.sleep` waits without blocking the loop.
- `one_by_one` awaits each fetch before starting the next: three waits of half a second, one after another.
- `all_at_once` hands all three to `gather`, which starts them together. The loop runs each until its `sleep`, and while all three wait, nothing else needs to run. Three half-second waits, overlapping: half a second in total.
- `time.perf_counter()` is a clock for measuring durations: precise, and never set back the way the wall clock can be. (Foundations 02 showed a wall clock jumping.)
- `for job in (one_by_one, all_at_once):` loops over two functions. Functions are values in Python, and `job.__name__` is each one's name.

### Step 2: Talk to the echo server

`asyncio` has **streams** for TCP: `asyncio.open_connection(host, port)` connects, and returns a **reader** and a **writer** for the connection. Create `measure/drills/talk.py`:

<!-- file: measure/drills/talk.py -->
~~~python
"""Lesson 08: talk to the echo server, then to many at once."""

import asyncio
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9000


async def talk(lines: list[str]) -> list[str]:
    """Open a connection, send each line, read each reply, close."""
    reader, writer = await asyncio.open_connection("127.0.0.1", PORT)
    replies = []
    for line in lines:
        writer.write(line.encode() + b"\n")
        await writer.drain()
        reply = await reader.readline()
        replies.append(reply.decode().rstrip("\n"))
    writer.close()
    await writer.wait_closed()
    return replies


async def main() -> None:
    print(await talk(["hello", "is anyone there?"]))
    start = time.perf_counter()
    clients = [talk([f"client {n} line {i}" for i in range(10)]) for n in range(100)]
    results = await asyncio.gather(*clients)
    took = time.perf_counter() - start
    print(f"{len(results)} clients, {sum(len(r) for r in results)} replies in {took:.3f} s")
    print(results[42][9])


asyncio.run(main())
~~~

- A socket carries **bytes**; Python text is `str`. `line.encode()` turns text into UTF-8 bytes, and `reply.decode()` turns bytes back into text. `b"\n"` is a bytes literal.
- `writer.write()` puts bytes in the writer's buffer, and `await writer.drain()` waits until the buffer has room again. Always pair them, or a fast writer piles up memory.
- `await reader.readline()` waits for a whole line, up to and including `\n`, however many pieces it arrives in. Step 3 shows why that matters.
- `writer.close()` and `await writer.wait_closed()` close the connection and wait until it's done: the `defer conn.Close()` of this side.
- `clients` is a list of 100 coroutine objects, none running yet. `gather(*clients)` runs them all at once; the `*` passes the list's items as separate arguments.
- `sys.argv` holds the command-line arguments, like Go's `os.Args`; this lets you pass a different port.

Start your echo server from lesson 04 in the background, then run it:

~~~bash
(cd ../echo && go build -o /tmp/echo .) && { /tmp/echo 2>/dev/null > /dev/null & sleep 0.5; uv run python drills/talk.py; kill %1; }
~~~

~~~text
['hello', 'is anyone there?']
100 clients, 1000 replies in 0.143 s
client 42 line 9
~~~

A hundred connections, ten lines each, a thousand round trips in a fraction of a second, from one Python thread. The Go server ran a goroutine for each connection; the Python client ran a coroutine for each.

### Step 3: A reply in pieces

On the loopback, a reply usually arrives in one piece. Across a real network, it may not: TCP is a stream (lesson 03), and your Go server's `Read` already showed pieces of arbitrary size (lesson 04). To see what that does to a client, make a server that sends each reply in two halves, a fifth of a second apart. Create `measure/drills/trickle.py`:

<!-- file: measure/drills/trickle.py -->
~~~python
"""Lesson 08: an echo server that sends each reply in two pieces, 0.2 s apart,
the way a slow network can deliver it."""

import asyncio


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    while line := await reader.readline():
        half = len(line) // 2
        writer.write(line[:half])
        await writer.drain()
        await asyncio.sleep(0.2)
        writer.write(line[half:])
        await writer.drain()
    writer.close()


async def main() -> None:
    server = await asyncio.start_server(handle, "127.0.0.1", 9001)
    print("trickling on 127.0.0.1:9001")
    async with server:
        await server.serve_forever()


asyncio.run(main())
~~~

- `asyncio.start_server(handle, host, port)` is the server side: for each connection, it runs `handle` as a new task, with that connection's reader and writer. It's your Go accept loop in one line.
- `while line := await reader.readline():` reads a line and loops while it isn't empty; `readline` returns `b""` when the client closes. `:=` assigns inside an expression (the "walrus" operator).
- `async with server:` closes the server when the block ends.

And a client that reads the reply two ways. Create `measure/drills/halves.py`:

<!-- file: measure/drills/halves.py -->
~~~python
"""Lesson 08: read(100) returns what has arrived so far; readline() waits for the whole line."""

import asyncio


async def main() -> None:
    reader, writer = await asyncio.open_connection("127.0.0.1", 9001)
    writer.write(b"a reply that comes in two pieces\n")
    await writer.drain()
    print("read(100):  ", await reader.read(100))
    print("readline(): ", await reader.readline())

    writer.write(b"a reply that comes in two pieces\n")
    await writer.drain()
    print("readline(): ", await reader.readline())
    writer.close()
    await writer.wait_closed()


asyncio.run(main())
~~~

<!-- run: cd measure && uv run ruff check drills && { uv run python drills/trickle.py > /dev/null & p=$!; sleep 2; out=$(uv run python drills/halves.py); kill $p; echo "$out" | tail -1 | grep -q "b'a reply that comes in two pieces\\\\n'"; } -->

~~~bash
uv run python drills/trickle.py & sleep 2; uv run python drills/halves.py; kill %1
~~~

~~~text
read(100):   b'a reply that com'
readline():  b'es in two pieces\n'
readline():  b'a reply that comes in two pieces\n'
~~~

- `read(100)` means "up to 100 bytes, whatever has arrived". It returned the first half as soon as it came, and the second half was still left in the stream, so the next `readline` picked it up as if it were a whole line. A client written with `read(n)` gets out of step with the server, and nothing tells it.
- `readline()` waited for the newline and returned the whole reply, after both pieces.

That's framing again, from the client's side: read by the protocol's rules (here, up to `\n`), never by "whatever arrived". Lesson 09's measurement depends on it, and the gate checks it with a server like this one.

## Break it

**A blocking wait.** In `waits.py`, change `fetch` to wait with `time.sleep(seconds)` instead of `await asyncio.sleep(seconds)`, and run it:

~~~bash
uv run python drills/waits.py
~~~

~~~text
one_by_one: ['a', 'b', 'c'] in 1.50 s
all_at_once: ['a', 'b', 'c'] in 1.50 s
~~~

`all_at_once` now takes as long as `one_by_one`. `time.sleep` doesn't hand control back to the loop; it stops the whole thread, so the other two tasks can't even start their wait until it's over. In a real program, the same happens with any blocking call inside `async` code: a slow file read, a CPU-heavy loop, a library that isn't `asyncio`-aware. Every connection stalls at once, and nothing reports an error. Put `await asyncio.sleep` back.

**A missing `await`.** In `one_by_one`, take out the three `await`s, so it returns `[fetch("a", 0.5), fetch("b", 0.5), fetch("c", 0.5)]`:

~~~bash
uv run python drills/waits.py
~~~

~~~text
/home/ada/blueprint/internet/measure/drills/waits.py:23: RuntimeWarning: coroutine 'fetch' was never awaited
  names = asyncio.run(job())
RuntimeWarning: Enable tracemalloc to get the object allocation traceback
one_by_one: [<coroutine object fetch at 0x74449e810e10>, <coroutine object fetch at 0x74449e435220>, <coroutine object fetch at 0x74449e435630>] in 0.00 s
all_at_once: ['a', 'b', 'c'] in 0.54 s
~~~

It finished instantly with a list of coroutine objects instead of names: calling an `async` function only creates the coroutine, and nothing ran it. Python noticed when they were thrown away unrun, and warned: `coroutine 'fetch' was never awaited`. A warning, not an error: the program carried on with wrong data. Put the `await`s back.

## Check it

~~~bash
uv run ruff format --check . && uv run ruff check . && uv run pytest -q
~~~

Then, without looking back: write a coroutine that connects to the echo server, sends one line, and returns the reply; run it 50 times at once with `gather`; and print how long it took.

That proves you can run many connections from one Python thread, and read a reply whole however it arrives. It doesn't measure anything yet: the next lesson times every request, saves the results and plots them.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `ConnectionRefusedError: [Errno 111] Connect call failed` | The echo server isn't running, or it's on another port | Start it (`/tmp/echo &`); pass the port to `talk.py` |
| `RuntimeWarning: coroutine '...' was never awaited` | Called an `async` function without `await` | `await` it, or pass it to `gather` |
| Everything runs one at a time | A blocking call (`time.sleep`, a plain socket, `requests`) inside `async` code | Use the `asyncio` version: `await asyncio.sleep`, streams, an async library |
| `RuntimeError: asyncio.run() cannot be called from a running event loop` | `asyncio.run` inside `async` code, or in a notebook | Call `asyncio.run` once, at the top; inside `async` code, use `await` |
| `OSError: [Errno 98] Address already in use` for `trickle.py` | An earlier copy is still running | `kill %1`, or find it with `ss -tlnp` |
| `ValueError: Separator is not found, and chunk exceed the limit` | A line longer than the reader's limit (64 KiB by default) | Pass `limit=` to `open_connection`, or keep lines short |
