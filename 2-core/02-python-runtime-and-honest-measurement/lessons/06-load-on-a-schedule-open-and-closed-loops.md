# 06 Load on a schedule: open and closed loops

> Module: Python runtime and honest measurement · Time: ~4 h · Builds on: 03, 05; Core 01 lesson 02 (HTTP/1.1 by hand)

## The problem

Ask "how fast is Switchyard?" and the obvious answer is a loop: send a request, wait for the reply, record the time, repeat. That loop gets the answer wrong in a specific, well-known way. If Switchyard stalls for one second, the loop stalls with it, and doesn't send the hundred requests that real users would have sent during that second. The stall shows up as **one** slow sample out of thousands, and the p99 looks healthy.

There's a second trap: the tool itself. The first version of `kload` sent its requests with httpx, the library from lesson 05, and was measured against a server that takes exactly 5 ms. At 200 requests a second it reported a p50 of 8.1 ms and spent 2.2 ms of CPU on every request. At 500 a second its CPU per request more than doubled, and it fell seconds behind: a p50 of 4.4 *seconds*, all of it inside `kload`. A load generator that adds milliseconds of its own to every number can't tell you whether Switchyard got 1 ms slower.

## The mental model

~~~text
 closed loop (the same schedule, but one request at a time):
   wait until due AND for the last reply ─▶ send ─▶ ...   a stall: the loop waits too, sends
                                                          nothing, and records one slow request;
                                                          latency timed from when it was SENT

 open loop (a fixed schedule, like users arriving):
   due:   0 ms   10 ms   20 ms   30 ms   ...        request i is due at i / rate
          │      │       │       │
          ▼      ▼       ▼       ▼                  sent when due, whether or not earlier ones
        task   task    task    task                 have finished; latency timed from when it
                                                    was DUE, so time spent stuck inside kload
                                                    counts against kload
   send lag = sent − due: kload's own lateness. Large lag means the numbers can't be trusted.
~~~

- A **closed-loop** generator waits for each reply before sending the next request, and times each request from when it actually sent it. Many benchmarks work this way, some with a schedule like `kload`'s closed mode: a request waits for its due time **and** for the previous reply.
- **Coordinated omission** is the bias that results: the generator coordinates with the server's stall and omits the requests it should have sent during it. The term is Gil Tene's.
- An **open-loop** generator sends request *i* at *i* / rate seconds, regardless of replies, and times each request from when it was **due**. A stall then shows up in every request that should have gone out during it.
- **Send lag** is how late `kload` actually sent a request. If the event loop is busy, or too many requests are already waiting, requests go out late, and latencies grow for reasons that have nothing to do with the server. `kload` records the lag of every request, and refuses to vouch for a run whose lag is high.

## The pattern

**Measure from the schedule, and check the measurer.** Every latency starts at the moment the request was due. Every run reports how far behind schedule the tool fell, and how much CPU it used, so you know whether to believe it.

## Build it

### Step 1: HTTP/1.1 on asyncio streams

In core 01 lesson 02 you read and wrote HTTP/1.1 by hand on a Go `net.Conn`. `kload` does the same on `asyncio` streams: it writes the request's bytes, reads the status line and headers up to the blank line, then reads exactly as many body bytes as `Content-Length` says, or the chunks of a chunked body. Connections stay open between requests. Measured against the same 5 ms server, with the same schedule, this client reported a p50 of 6.7 ms instead of httpx's 8.1, spent 0.3 ms of CPU per request instead of 2.2, and stayed on schedule at 2,000 requests a second (the measurement is in this module's evidence, `probes/`).

Create `src/kload/http1.py`:

<!-- file: src/kload/http1.py -->
~~~python
"""A small HTTP/1.1 client on asyncio streams, with kept-alive connections.

kload measures latency, so its own cost per request has to be small. This
client does only what kload needs: plain HTTP (no TLS), one request at a
time per connection, bodies sized by Content-Length or sent in chunks.
"""

import asyncio
from dataclasses import dataclass
from urllib.parse import urlsplit

MAX_HEAD = 64 * 1024  # a response's status line and headers must fit in this


@dataclass(frozen=True)
class Response:
    status: int
    body: bytes


class ProtocolError(Exception):
    """The server's response wasn't HTTP/1.1 kload can read."""


class Connection:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.reader = reader
        self.writer = writer
        self.reusable = True

    async def exchange(self, request: bytes) -> Response:
        """Send one request and read the whole response."""
        self.writer.write(request)
        try:
            head = await self.reader.readuntil(b"\r\n\r\n")
        except asyncio.LimitOverrunError as err:
            raise ProtocolError(f"response head longer than {MAX_HEAD} bytes") from err
        status_line, *lines = head[:-4].decode("latin-1").split("\r\n")
        version, _, rest = status_line.partition(" ")
        if not version.startswith("HTTP/1.") or not rest[:3].isdigit():
            raise ProtocolError(f"not an HTTP/1.1 status line: {status_line[:40]!r}")
        headers = {}
        for line in lines:
            name, _, value = line.partition(":")
            headers[name.strip().lower()] = value.strip()
        if headers.get("connection", "").lower() == "close":
            self.reusable = False
        if "content-length" in headers:
            body = await self.reader.readexactly(int(headers["content-length"]))
        elif headers.get("transfer-encoding", "").lower() == "chunked":
            body = await self.read_chunks()
        else:
            raise ProtocolError("response has neither Content-Length nor chunked encoding")
        return Response(int(rest[:3]), body)

    async def read_chunks(self) -> bytes:
        """Read a chunked body: hex size, CRLF, that many bytes, CRLF; size 0 ends it."""
        parts = []
        while True:
            size = int((await self.reader.readuntil(b"\r\n")).split(b";")[0], 16)
            if size == 0:
                await self.reader.readuntil(b"\r\n")  # the empty line after the last chunk
                return b"".join(parts)
            parts.append(await self.reader.readexactly(size))
            await self.reader.readexactly(2)

    def close(self) -> None:
        self.writer.close()


class Pool:
    """Connections to one server, kept open and reused between requests.

    The pool opens as many connections as there are requests in flight at
    once; the caller decides how many that is.
    """

    def __init__(self, url: str) -> None:
        parts = urlsplit(url)
        if parts.scheme != "http" or not parts.hostname:
            raise ValueError(f"kload speaks plain HTTP only: {url!r}")
        self.host = parts.hostname
        self.port = parts.port or 80
        self.idle: list[Connection] = []
        self.opened = 0  # connections opened so far, for tests and reports

    def encode(self, method: str, path: str, headers: dict[str, str], body: bytes) -> bytes:
        lines = [f"{method} {path} HTTP/1.1", f"Host: {self.host}:{self.port}"]
        lines += [f"{name}: {value}" for name, value in headers.items()]
        if body or method in ("POST", "PUT"):
            lines.append(f"Content-Length: {len(body)}")
        return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + body

    async def request(
        self, method: str, path: str, headers: dict[str, str] | None = None, body: bytes = b""
    ) -> Response:
        """Send a request on an idle connection, or a new one if none is idle.

        A connection that failed, or that the server will close, isn't reused.
        """
        raw = self.encode(method, path, headers or {}, body)
        conn = self.idle.pop() if self.idle else await self.connect()
        try:
            response = await conn.exchange(raw)
        except BaseException:
            conn.close()  # half a response may still be on the way: never reuse it
            raise
        if conn.reusable:
            self.idle.append(conn)
        else:
            conn.close()
        return response

    async def connect(self) -> Connection:
        reader, writer = await asyncio.open_connection(self.host, self.port, limit=MAX_HEAD)
        self.opened += 1
        return Connection(reader, writer)

    def close(self) -> None:
        while self.idle:
            self.idle.pop().close()
~~~

- `readuntil(b"\r\n\r\n")` returns the head, blank line included. `limit=MAX_HEAD` on `open_connection` caps how much it will buffer looking for it, so a server that sends garbage forever can't fill `kload`'s memory.
- `readexactly(n)` returns exactly `n` bytes or raises `IncompleteReadError` if the connection closes first.
- A connection that failed mid-response is closed, never reused: the rest of that response might still arrive and be read as the answer to the next request. `except BaseException` catches cancellation and timeouts too, which ordinary `Exception` would miss.
- The pool opens a connection only when none is idle. How many requests run at once is the caller's decision.

The tests need servers that misbehave on demand. Create `tests/conftest.py`, where pytest looks for shared fixtures:

<!-- file: tests/conftest.py -->
~~~python
import asyncio
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest


class Health(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # keep connections open, as Switchyard does

    def do_GET(self) -> None:
        body = json.dumps({"status": "ok"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        pass  # keep test output quiet


@pytest.fixture
def server_url():
    """A real HTTP server on a free port, answering GET with {"status": "ok"}."""
    server = ThreadingHTTPServer(("127.0.0.1", 0), Health)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{server.server_address[1]}"
    server.shutdown()
    server.server_close()


class FakeServer:
    """An HTTP/1.1 server on asyncio, for tests that run inside an event loop.

    answer(method, path) is a coroutine returning (status, body, headers), so
    a test can make the server slow, stall, or misbehave. It counts the
    connections it accepted.
    """

    def __init__(self, answer) -> None:
        self.answer = answer
        self.connections = 0
        self.server = None

    async def __aenter__(self) -> FakeServer:
        self.server = await asyncio.start_server(self.handle, "127.0.0.1", 0)
        return self

    async def __aexit__(self, *exc) -> None:
        self.server.close()
        await self.server.wait_closed()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.sockets[0].getsockname()[1]}"

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.connections += 1
        try:
            while head := await reader.readuntil(b"\r\n\r\n"):
                method, path, _ = head.split(b"\r\n")[0].decode().split(" ")
                length = 0
                for line in head.split(b"\r\n")[1:]:
                    if line.lower().startswith(b"content-length:"):
                        length = int(line.split(b":")[1])
                await reader.readexactly(length)
                status, body, headers = await self.answer(method, path)
                if isinstance(body, str):
                    body = body.encode()
                head_lines = [f"HTTP/1.1 {status} X"] + [f"{k}: {v}" for k, v in headers.items()]
                if "Transfer-Encoding" not in headers:
                    head_lines.append(f"Content-Length: {len(body)}")
                writer.write(("\r\n".join(head_lines) + "\r\n\r\n").encode() + body)
                await writer.drain()
                if headers.get("Connection") == "close":
                    break
        except asyncio.IncompleteReadError, ConnectionError:
            pass
        finally:
            writer.close()


async def ok(method: str, path: str):
    return 200, '{"status":"ok"}', {"Content-Type": "application/json"}
~~~

`FakeServer` is a real HTTP server on `asyncio`, inside the test's own event loop, whose `answer` function decides each reply: slow, stalled, chunked or closing. `server_url` is a plain threaded server for the command-line tests in step 4. Create `tests/test_http1.py`:

<!-- file: tests/test_http1.py -->
~~~python
import asyncio

import pytest
from conftest import FakeServer, ok

from kload.http1 import Pool, ProtocolError


def run(coro):
    return asyncio.run(coro)


def test_a_get_and_its_body():
    async def scenario():
        async with FakeServer(ok) as server:
            pool = Pool(server.url)
            response = await pool.request("GET", "/health")
            pool.close()
            return response

    response = run(scenario())
    assert (response.status, response.body) == (200, b'{"status":"ok"}')


def test_one_connection_serves_requests_one_after_another():
    async def scenario():
        async with FakeServer(ok) as server:
            pool = Pool(server.url)
            for _ in range(10):
                await pool.request("GET", "/health")
            pool.close()
            return server.connections, pool.opened

    assert run(scenario()) == (1, 1)


def test_requests_at_once_get_a_connection_each():
    async def slow(method, path):
        await asyncio.sleep(0.05)
        return 200, "", {}

    async def scenario():
        async with FakeServer(slow) as server:
            pool = Pool(server.url)
            await asyncio.gather(*(pool.request("GET", "/") for _ in range(5)))
            await asyncio.gather(*(pool.request("GET", "/") for _ in range(5)))  # reused
            pool.close()
            return pool.opened

    assert run(scenario()) == 5


def test_a_post_sends_its_body_and_headers():
    seen = {}

    async def created(method, path):
        seen["request"] = (method, path)
        return 201, '{"id":1}', {}

    async def scenario():
        async with FakeServer(created) as server:
            pool = Pool(server.url)
            response = await pool.request("POST", "/jobs", {"Idempotency-Key": "k-1"}, b'{"a":1}')
            pool.close()
            return response.status

    assert run(scenario()) == 201
    assert seen["request"] == ("POST", "/jobs")


def test_a_chunked_body_is_read_whole():
    async def chunked(method, path):
        return 200, b"5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", {"Transfer-Encoding": "chunked"}

    async def scenario():
        async with FakeServer(chunked) as server:
            pool = Pool(server.url)
            response = await pool.request("GET", "/metrics")
            pool.close()
            return response.body

    assert run(scenario()) == b"hello world"


def test_connection_close_is_not_reused():
    async def closing(method, path):
        return 200, "", {"Connection": "close"}

    async def scenario():
        async with FakeServer(closing) as server:
            pool = Pool(server.url)
            await pool.request("GET", "/")
            await pool.request("GET", "/")
            pool.close()
            return pool.opened

    assert run(scenario()) == 2


def test_not_http_is_a_protocol_error():
    async def scenario():
        async def garbage(reader, writer):
            await reader.readuntil(b"\r\n\r\n")
            writer.write(b"hello there\r\n\r\n")
            await writer.drain()

        server = await asyncio.start_server(garbage, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        try:
            await Pool(f"http://127.0.0.1:{port}").request("GET", "/")
        finally:
            server.close()

    with pytest.raises(ProtocolError, match="not an HTTP/1.1 status line"):
        run(scenario())


@pytest.mark.parametrize("url", ["https://example.com", "ftp://x", "localhost:8080"])
def test_only_plain_http_urls(url):
    with pytest.raises(ValueError, match="plain HTTP only"):
        Pool(url)
~~~

~~~bash
uv run pytest -q tests/test_http1.py
~~~

~~~text
..........                                                               [100%]
10 passed in 0.14s
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_http1.py -->

### Step 2: The open loop and the closed loop

Create `src/kload/load.py`:

<!-- file: src/kload/load.py -->
~~~python
"""Load generation: an open loop (honest) and a closed loop (for comparison)."""

import asyncio
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

from kload.http1 import ProtocolError

# Sends request number i and returns its HTTP status.
Send = Callable[[int], Awaitable[int]]
Clock = Callable[[], float]

# What can go wrong between kload and the server. Anything else is a bug in kload.
FAILURES = (OSError, TimeoutError, asyncio.IncompleteReadError, ProtocolError)


@dataclass(frozen=True)
class Result:
    """How one request went. Times are seconds since the run began.

    scheduled_s is when the request was due; sent_s is when kload actually
    sent it. latency_s runs from scheduled_s to the end of the response, so
    any time the request spent waiting inside kload counts against kload's
    numbers, not in its favour. status is the HTTP status, or 0 if no
    response came back, and error then names what went wrong.
    """

    request: int
    scheduled_s: float
    sent_s: float
    latency_s: float
    status: int
    error: str = ""

    @property
    def lag_s(self) -> float:
        """How late kload was in sending this request."""
        return self.sent_s - self.scheduled_s

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300


async def _attempt(send: Send, i: int, timeout_s: float) -> tuple[int, str]:
    try:
        async with asyncio.timeout(timeout_s):
            return await send(i), ""
    except FAILURES as exc:
        return 0, type(exc).__name__


async def run_open_loop(
    send: Send,
    rate: float,
    duration_s: float,
    *,
    max_in_flight: int = 500,
    timeout_s: float = 10.0,
    clock: Clock = time.perf_counter,
) -> list[Result]:
    """Send `rate` requests a second for `duration_s` seconds, on a fixed schedule.

    Request i is due at i / rate seconds and goes out then, whether or not
    earlier ones have finished, the way real users arrive. Its latency is
    measured from when it was due, so if the server stalls, every request
    that should have been sent during the stall records the wait.

    The dispatcher starts each request's task when it falls due. Starting
    them all at the beginning would cost the event loop time while the
    first requests are due, and make them late.
    """
    if rate <= 0 or duration_s <= 0:
        raise ValueError("rate and duration must be positive")
    in_flight = asyncio.Semaphore(max_in_flight)
    start = clock()

    async def one(i: int, due: float) -> Result:
        async with in_flight:
            sent = clock()
            status, error = await _attempt(send, i, timeout_s)
        return Result(i, due - start, sent - start, clock() - due, status, error)

    tasks = []
    for i in range(round(rate * duration_s)):
        due = start + i / rate
        if (delay := due - clock()) > 0:
            await asyncio.sleep(delay)
        tasks.append(asyncio.create_task(one(i, due)))
    return list(await asyncio.gather(*tasks))


async def run_closed_loop(
    send: Send,
    rate: float,
    duration_s: float,
    *,
    timeout_s: float = 10.0,
    clock: Clock = time.perf_counter,
) -> list[Result]:
    """The same schedule, but one request at a time, timed from when it was sent.

    Each request waits for its due time and for the previous reply, as many
    benchmarks do. While the server is stalled the loop is stuck waiting too,
    so it doesn't send the requests real users would have sent: the stall
    shows up in one sample instead of many. This is coordinated omission. The
    requests it couldn't send on time show up only in their send lag.
    """
    if rate <= 0 or duration_s <= 0:
        raise ValueError("rate and duration must be positive")
    results = []
    start = clock()
    for i in range(round(rate * duration_s)):
        due = start + i / rate
        if (delay := due - clock()) > 0:
            await asyncio.sleep(delay)
        sent = clock()
        status, error = await _attempt(send, i, timeout_s)
        results.append(Result(i, due - start, sent - start, clock() - sent, status, error))
    return results
~~~

- A **`Send`** is any function that sends request number `i` and returns its status. `load.py` doesn't know about HTTP, so the tests can hand it anything.
- The **dispatcher** loop sleeps until each request is due, then starts its task with `create_task` and moves on without waiting for it. An earlier version made all the tasks at the start. At 3,000 requests a second for 5 seconds that's 15,000 tasks, and creating them all at once cost the loop enough time that requests went out late while the CPU was half idle (you'll measure it in Break it).
- `async with in_flight` caps requests in flight at `max_in_flight`. A request that waits here waits **inside kload**: its `sent` time is taken after the wait, so the lag shows it, and its latency still counts from `due`.
- `asyncio.timeout` gives every request a deadline, and `FAILURES` lists what can go wrong between `kload` and a server. Those are recorded, not raised: a run against a struggling server should finish and report the struggle. Anything else is a bug in `kload` and should crash.

Create `tests/test_load.py`:

<!-- file: tests/test_load.py -->
~~~python
import asyncio
import time

import pytest
from conftest import FakeServer, ok

from kload.http1 import Pool
from kload.load import Result, run_closed_loop, run_open_loop
from kload.stats import percentile


def get(pool: Pool):
    async def send(i: int) -> int:
        return (await pool.request("GET", "/health")).status

    return send


def open_loop(answer, **kwargs) -> list[Result]:
    async def scenario():
        async with FakeServer(answer) as server:
            pool = Pool(server.url)
            try:
                return await run_open_loop(get(pool), **kwargs)
            finally:
                pool.close()

    return asyncio.run(scenario())


def test_open_loop_sends_rate_times_duration_requests_on_schedule():
    results = open_loop(ok, rate=50, duration_s=0.4)
    assert [r.request for r in results] == list(range(20))
    assert all(r.status == 200 for r in results)
    assert [round(r.scheduled_s, 3) for r in results[:3]] == [0.0, 0.02, 0.04]
    assert max(r.lag_s for r in results) < 0.01


def test_connection_refused_is_recorded_not_raised():
    async def scenario():
        server = await asyncio.start_server(lambda r, w: None, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        server.close()
        await server.wait_closed()  # the port is free again: nothing listens there
        pool = Pool(f"http://127.0.0.1:{port}")
        return await run_open_loop(get(pool), rate=20, duration_s=0.1)

    results = asyncio.run(scenario())
    assert {(r.status, r.error, r.ok) for r in results} == {(0, "ConnectionRefusedError", False)}


def test_a_request_that_takes_too_long_times_out():
    async def never(method, path):
        await asyncio.sleep(1)  # far longer than the 0.1 s timeout
        return 200, "", {}

    results = open_loop(never, rate=10, duration_s=0.2, timeout_s=0.1)
    assert {(r.status, r.error) for r in results} == {(0, "TimeoutError")}


@pytest.mark.parametrize("loop", [run_open_loop, run_closed_loop])
@pytest.mark.parametrize(("rate", "duration"), [(0, 1), (10, 0), (-1, 1)])
def test_loops_reject_bad_arguments(loop, rate, duration):
    with pytest.raises(ValueError):
        asyncio.run(loop(None, rate=rate, duration_s=duration))


class StallingServer:
    """Answers at once, except that one request freezes the whole server.

    The lock stands in for anything that stops a server answering anyone, a
    garbage-collection pause or a SIGSTOP: requests that arrive during the
    stall wait for it to end.
    """

    def __init__(self, stall_on: int, stall_s: float) -> None:
        self.lock = asyncio.Lock()
        self.seen = 0
        self.stall_on = stall_on
        self.stall_s = stall_s

    async def __call__(self, method: str, path: str):
        async with self.lock:
            self.seen += 1
            if self.seen == self.stall_on:
                await asyncio.sleep(self.stall_s)
        return 200, "", {}


def p95_ms(results: list[Result]) -> float:
    # With 50 samples, p99 would be the maximum: the one slow sample.
    return percentile([r.latency_s * 1000 for r in results], 95)


def test_closed_loop_hides_a_stall_that_the_open_loop_reveals():
    """A 0.5 s stall in a 1 s run at 50 requests a second.

    Users would have sent about 25 requests during the stall, and each would
    have waited. The closed loop sends none of them, so only one sample is
    slow. The open loop sends them on schedule and records every wait.
    """

    async def closed():
        async with FakeServer(StallingServer(stall_on=10, stall_s=0.5)) as server:
            pool = Pool(server.url)
            try:
                return await run_closed_loop(get(pool), rate=50, duration_s=1.0)
            finally:
                pool.close()

    closed_results = asyncio.run(closed())
    open_results = open_loop(StallingServer(stall_on=10, stall_s=0.5), rate=50, duration_s=1.0)

    assert sum(r.latency_s > 0.25 for r in closed_results) == 1
    assert sum(r.latency_s > 0.25 for r in open_results) >= 10
    assert p95_ms(closed_results) < 50 < 200 < p95_ms(open_results)
    # The closed loop's lateness is where the missing requests went.
    assert max(r.lag_s for r in closed_results) > 0.4


def test_a_blocking_send_makes_kload_late_and_the_lag_shows_it():
    """Each send blocks the event loop for 20 ms, so kload manages 50 a second, not 100."""

    async def scenario():
        async with FakeServer(ok) as server:
            pool = Pool(server.url)

            async def blocking(i: int) -> int:
                time.sleep(0.02)  # the mistake: a blocking call on the loop
                return (await pool.request("GET", "/health")).status

            try:
                return await run_open_loop(blocking, rate=100, duration_s=0.5)
            finally:
                pool.close()

    results = asyncio.run(scenario())
    assert max(r.lag_s for r in results) > 0.2
    assert all(r.latency_s >= r.lag_s for r in results)  # the lag counts against the latency


def test_the_in_flight_limit_holds_requests_back_and_the_lag_shows_it():
    async def slow(method, path):
        await asyncio.sleep(0.1)
        return 200, "", {}

    results = open_loop(slow, rate=100, duration_s=0.3, max_in_flight=2)
    assert max(r.lag_s for r in results) > 0.5
~~~

`StallingServer` holds a lock that every request must pass through, and holds it for half a second on one request, like a garbage-collection pause or a `SIGSTOP`. `test_closed_loop_hides_a_stall_that_the_open_loop_reveals` is this lesson's problem as a test: the closed loop records **one** slow request; the open loop records every request that was due during the stall. The test's last line says where the closed loop's missing time went: into its send lag, the requests it should have sent and couldn't.

~~~bash
uv run pytest -q tests/test_load.py
~~~

~~~text
............                                                             [100%]
12 passed in 6.10s
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_load.py -->

### Step 3: Keep the raw results, and the settings

Create `src/kload/results.py`:

<!-- file: src/kload/results.py -->
~~~python
"""Save a run's raw results next to the settings that produced them."""

import csv
import json
from pathlib import Path
from typing import Any

from kload.load import Result

HEADER = ["request", "scheduled_s", "sent_s", "latency_s", "status", "error"]


def write_results(results: list[Result], path: Path, settings: dict[str, Any]) -> Path:
    """Write results as CSV, and the settings as JSON beside it; return the JSON's path.

    Raw results, not just a summary, let anyone recompute any statistic
    later. The settings record how to run the same experiment again.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(HEADER)
        for r in results:
            writer.writerow(
                [
                    r.request,
                    f"{r.scheduled_s:.6f}",
                    f"{r.sent_s:.6f}",
                    f"{r.latency_s:.6f}",
                    r.status,
                    r.error,
                ]
            )
    settings_path = path.with_suffix(".json")
    settings_path.write_text(json.dumps(settings, indent=2, sort_keys=True) + "\n")
    return settings_path


def read_results(path: Path) -> list[Result]:
    """Read results written by write_results. A bad row is an error naming its line."""
    with path.open(newline="") as f:
        rows = csv.reader(f)
        if next(rows, None) != HEADER:
            raise ValueError(f"{path}: the first line must be {','.join(HEADER)}")
        results = []
        for line, row in enumerate(rows, start=2):
            try:
                request, scheduled, sent, latency, status, error = row
                results.append(
                    Result(
                        int(request),
                        float(scheduled),
                        float(sent),
                        float(latency),
                        int(status),
                        error,
                    )
                )
            except ValueError as err:
                raise ValueError(f"{path}, line {line}: {err}") from err
    return results
~~~

Every request becomes one CSV row, with the times to the microsecond, and the settings of the run go into a JSON file beside it. A summary answers the question you thought of; the raw rows answer the ones you think of later, and let someone else check your numbers. Lesson 08 reruns an experiment from its JSON file.

Create `tests/test_results.py`:

<!-- file: tests/test_results.py -->
~~~python
import pytest

from kload.load import Result
from kload.results import read_results, write_results


def test_results_and_settings_round_trip(tmp_path):
    path = tmp_path / "out" / "run.csv"
    results = [Result(0, 0.0, 0.0001, 0.004, 200), Result(1, 0.01, 0.0102, 0.5, 0, "ConnectError")]

    settings_path = write_results(results, path, {"rate": 5, "path": "/health"})

    assert read_results(path) == results
    assert path.read_text().splitlines()[2] == "1,0.010000,0.010200,0.500000,0,ConnectError"
    assert settings_path.read_text() == '{\n  "path": "/health",\n  "rate": 5\n}\n'


def test_a_wrong_header_is_refused(tmp_path):
    path = tmp_path / "run.csv"
    path.write_text("request,latency_ms\n0,1.5\n")
    with pytest.raises(ValueError, match="the first line must be request,scheduled_s"):
        read_results(path)


def test_a_bad_row_names_its_line(tmp_path):
    path = tmp_path / "run.csv"
    path.write_text("request,scheduled_s,sent_s,latency_s,status,error\n0,0,0,fast,200,\n")
    with pytest.raises(ValueError, match="line 2"):
        read_results(path)
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q tests/test_results.py -->

### Step 4: `kload load`

Replace `src/kload/cli.py` with this version, which adds the `load` command:

<!-- file: src/kload/cli.py -->
~~~python
"""The kload command line."""

import argparse
import asyncio
import sys
import time
from collections import Counter
from pathlib import Path

import httpx

from kload.client import ApiError, SwitchyardClient
from kload.http1 import Pool
from kload.load import Result, Send, run_closed_loop, run_open_loop
from kload.results import write_results
from kload.stats import percentile, summarize

EXIT_FELL_BEHIND = 3
CPU_WARNING = 0.7  # above this share of one CPU, kload's own queueing creeps in


def cmd_summarize(args: argparse.Namespace) -> int:
    values = [float(word) for word in Path(args.file).read_text().split()]
    summary = summarize(values)
    for name in ("count", "mean", "p50", "p99", "max"):
        print(f"{name:>5}: {getattr(summary, name):g}")
    return 0


def cmd_smoke(args: argparse.Namespace) -> int:
    key = f"smoke-{time.time_ns()}"
    with httpx.Client(base_url=args.url, timeout=5) as http:
        client = SwitchyardClient(http)
        try:
            print(f"health: {client.health()}")
            job = client.create_job("smoke test", duration_ms=args.duration_ms, key=key)
            print(f"created job {job.id}: {job.state}")
            again = client.create_job("smoke test", duration_ms=args.duration_ms, key=key)
            print(
                f"same key again: job {again.id}"
                + (" (the same job)" if again.id == job.id else "")
            )
            job = client.cancel_job(job.id)
            print(f"cancelled job {job.id}: {job.state}")
        except (ApiError, httpx.HTTPError) as exc:
            print(f"kload: {exc}", file=sys.stderr)
            return 1
    return 0


def make_send(pool: Pool, method: str, path: str, body: str) -> Send:
    """Build the function that sends request number i through the pool.

    A POST carries an Idempotency-Key that is unique to this run and request,
    so Switchyard creates one job per request, and a retry wouldn't make two.
    """
    run = time.time_ns()
    content = body.encode()
    headers = {"Content-Type": "application/json"} if content else {}

    async def send(i: int) -> int:
        extra = {"Idempotency-Key": f"kload-{run}-{i}"} if method == "POST" else {}
        return (await pool.request(method, path, headers | extra, content)).status

    return send


def cmd_load(args: argparse.Namespace) -> int:
    async def go() -> list[Result]:
        pool = Pool(args.url)
        send = make_send(pool, args.method, args.path, args.body)
        try:
            if args.mode == "closed":
                return await run_closed_loop(send, args.rate, args.duration, timeout_s=args.timeout)
            return await run_open_loop(
                send,
                args.rate,
                args.duration,
                max_in_flight=args.max_in_flight,
                timeout_s=args.timeout,
            )
        finally:
            pool.close()

    wall, cpu = time.perf_counter(), time.process_time()
    results = asyncio.run(go())
    wall, cpu = time.perf_counter() - wall, time.process_time() - cpu

    settings = {k: v for k, v in vars(args).items() if k != "handler"}
    settings_path = write_results(results, Path(args.out), settings)
    fell_behind = report_run(results, args, wall, cpu)
    print(f"wrote {args.out} and {settings_path}")
    if all(r.status == 0 for r in results):
        print(
            f"kload: no request got a response: is anything listening at {args.url}?",
            file=sys.stderr,
        )
        return 1
    return EXIT_FELL_BEHIND if fell_behind else 0


def report_run(results: list[Result], args: argparse.Namespace, wall: float, cpu: float) -> bool:
    """Print what happened, and return True if kload fell behind its own schedule."""
    if args.mode == "closed":
        print(
            f"closed loop: {len(results)} requests at up to {args.rate:g}/s, one at a time,"
            f" in {wall:.2f} s (latency timed from sending: a stall is hidden)"
        )
    else:
        print(f"open loop: {len(results)} requests at {args.rate:g}/s over {args.duration:g} s")
    statuses = Counter(r.status or r.error for r in results)
    print("answers: " + ", ".join(f"{s} x{n}" for s, n in sorted(statuses.items(), key=str)))
    ok = [r.latency_s * 1000 for r in results if r.ok]
    if ok:
        print(
            f"latency (2xx): p50 {percentile(ok, 50):.2f} ms, p99 {percentile(ok, 99):.2f} ms,"
            f" max {max(ok):.2f} ms"
        )
    lags = [r.lag_s * 1000 for r in results]
    lag_p99 = percentile(lags, 99)
    print(
        f"kload itself: send lag p99 {lag_p99:.2f} ms, max {max(lags):.2f} ms;"
        f" CPU {cpu:.2f} s in {wall:.2f} s ({cpu / wall:.0%})"
    )
    if cpu / wall > CPU_WARNING:
        print(
            f"kload used {cpu / wall:.0%} of a CPU: close to its limit, so replies may have"
            " waited for it to read them. Lower the rate, or split it across processes.",
            file=sys.stderr,
        )
    if args.mode == "open" and lag_p99 > args.max_lag_ms:
        print(
            f"kload fell behind its schedule: send lag p99 {lag_p99:.1f} ms is over"
            f" --max-lag-ms {args.max_lag_ms:g}. These latencies include time spent"
            " waiting inside kload: don't trust them.",
            file=sys.stderr,
        )
        return True
    return False


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="kload", description=__doc__)
    sub = parser.add_subparsers(required=True)

    p = sub.add_parser("summarize", help="summarize the numbers in a file")
    p.add_argument("file")
    p.set_defaults(handler=cmd_summarize)

    p = sub.add_parser("smoke", help="check a running Switchyard end to end")
    p.add_argument("--url", default="http://127.0.0.1:8080")
    p.add_argument("--duration-ms", type=int, default=100)
    p.set_defaults(handler=cmd_smoke)

    p = sub.add_parser("load", help="send load on a schedule and save the raw results")
    p.add_argument("--url", default="http://127.0.0.1:8080")
    p.add_argument("--method", choices=["GET", "POST"], default="GET")
    p.add_argument("--path", default="/health")
    p.add_argument("--body", default="", help="JSON to send with each request")
    p.add_argument(
        "--mode",
        choices=["open", "closed"],
        default="open",
        help="closed waits for each reply before the next request, for comparison",
    )
    p.add_argument("--rate", type=float, help="requests per second")
    p.add_argument("--duration", type=float, help="seconds")
    p.add_argument("--max-in-flight", type=int, default=500)
    p.add_argument(
        "--max-lag-ms",
        type=float,
        default=10.0,
        help="fail the run if kload sends later than this (p99)",
    )
    p.add_argument("--timeout", type=float, default=10.0, help="seconds per request")
    p.add_argument("--out", default="results/run.csv")
    p.set_defaults(handler=cmd_load)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.handler is cmd_load:
        if not (args.rate and args.duration):
            parser.error("load needs --rate and --duration (or --settings)")
        if not args.url.startswith("http://"):
            parser.error(f"kload speaks plain HTTP only: --url {args.url}")
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())
~~~

- `make_send` builds the `Send` for one run. Every `POST` gets an `Idempotency-Key` that is unique to this run and request number, so Switchyard makes one job per request, and a retried request would never make two.
- `cmd_load` times the whole run twice: `perf_counter` for the wall clock, and `process_time` for the CPU time `kload` itself used.
- `report_run` prints the answers by status, the latency percentiles of the `2xx` answers, and `kload`'s own send lag and CPU use. If the lag's p99 is over `--max-lag-ms` (10 ms by default), it says the run can't be trusted, and `kload` exits with status **3**. Above 70% of a CPU it warns: at that point replies start waiting for `kload` to read them, which inflates latencies even before the lag shows it.

Replace `tests/test_cli.py`:

<!-- file: tests/test_cli.py -->
~~~python
import json
import socket

import pytest

from kload.cli import EXIT_FELL_BEHIND, main
from kload.results import read_results


def test_summarize_prints_each_statistic(tmp_path, capsys):
    data = tmp_path / "latencies.txt"
    data.write_text("12 15\n11 250\n14\n")
    assert main(["summarize", str(data)]) == 0
    out = capsys.readouterr().out
    assert "count: 5" in out
    assert "  p50: 14" in out
    assert "  max: 250" in out


def test_unknown_command_is_a_usage_error(capsys):
    with pytest.raises(SystemExit) as caught:
        main(["fly"])
    assert caught.value.code == 2
    assert "invalid choice" in capsys.readouterr().err


def test_load_needs_a_rate_and_a_duration(capsys):
    with pytest.raises(SystemExit) as caught:
        main(["load", "--rate", "10"])
    assert caught.value.code == 2
    assert "needs --rate and --duration" in capsys.readouterr().err


def test_load_writes_results_and_settings(server_url, tmp_path, capsys):
    out = tmp_path / "run.csv"
    code = main(
        ["load", "--url", server_url, "--rate", "50", "--duration", "0.4", "--out", str(out)]
    )
    assert code == 0
    results = read_results(out)
    assert len(results) == 20 and all(r.status == 200 for r in results)
    settings = json.loads(out.with_suffix(".json").read_text())
    assert (settings["rate"], settings["path"], settings["mode"]) == (50, "/health", "open")
    assert "answers: 200 x20" in capsys.readouterr().out


def test_a_run_that_falls_behind_exits_3(server_url, tmp_path, capsys):
    # A lag limit of 0 ms: no real run can meet it, so this one must fail.
    out = tmp_path / "run.csv"
    args = ["load", "--url", server_url, "--rate", "50", "--duration", "0.2", "--out", str(out)]
    assert main([*args, "--max-lag-ms", "0"]) == EXIT_FELL_BEHIND
    assert "kload fell behind its schedule" in capsys.readouterr().err
    assert out.exists()  # the raw results are kept, so you can see why


def test_nothing_listening_exits_1(tmp_path, capsys):
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]  # a port that was free a moment ago
    url = f"http://127.0.0.1:{port}"
    out = str(tmp_path / "run.csv")
    assert main(["load", "--url", url, "--rate", "20", "--duration", "0.1", "--out", out]) == 1
    assert "is anything listening" in capsys.readouterr().err
~~~

`test_a_run_that_falls_behind_exits_3` sets a lag limit of 0 ms, which no real run can meet, so the test checks the rule without needing a slow machine.

~~~bash
uv run ruff format --check . && uv run ruff check . && uv run pytest -q
~~~

~~~text
26 files already formatted
All checks passed!
.......................................................                  [100%]
55 passed in 7.63s
~~~

<!-- run: uv run ruff format --check . && uv run ruff check . && uv run pytest -q -->

### Step 5: Load Switchyard

Start Switchyard as in lesson 05, and send it 200 requests a second for 5 seconds:

~~~bash
uv run kload load --rate 200 --duration 5 --out results/health.csv
~~~

~~~text
open loop: 1000 requests at 200/s over 5 s
answers: 200 x1000
latency (2xx): p50 1.27 ms, p99 2.46 ms, max 12.24 ms
kload itself: send lag p99 1.33 ms, max 11.35 ms; CPU 0.42 s in 5.00 s (8%)
wrote results/health.csv and results/health.json
~~~

By `kload`'s clock, `GET /health` took 1.27 ms at the p50, and `kload` sent its requests within 1.33 ms of schedule (p99), using 8% of a CPU. Those two numbers are close for a reason. Latency is timed from when a request was due, so it includes the send lag, and at this rate most of the lag is the event loop's floor: on Linux, `asyncio` sleeps in `epoll_wait`, which counts in whole milliseconds, so a timer can fire up to 1 ms late. In the next run, at 4,000 a second, the loop is rarely asleep long enough to oversleep, and the p50 falls to 0.60 ms. So below about a millisecond, `kload`'s numbers aren't precise, and they get *better* as it gets busier, until it's too busy. No amount of care in Python removes that floor; knowing it's there is what matters.

Now find `kload`'s limit. Keep raising the rate until it gives up:

~~~bash
for r in 1000 4000 20000; do uv run kload load --rate $r --duration 2 --out results/rate$r.csv; echo "exit $?"; done
~~~

~~~text
open loop: 2000 requests at 1000/s over 2 s
answers: 200 x2000
latency (2xx): p50 0.92 ms, p99 6.79 ms, max 19.81 ms
kload itself: send lag p99 1.18 ms, max 9.77 ms; CPU 0.48 s in 2.00 s (24%)
wrote results/rate1000.csv and results/rate1000.json
exit 0
kload used 81% of a CPU: close to its limit, so replies may have waited for it to read them. Lower the rate, or split it across processes.
open loop: 8000 requests at 4000/s over 2 s
answers: 200 x8000
latency (2xx): p50 0.60 ms, p99 2.08 ms, max 10.64 ms
kload itself: send lag p99 1.07 ms, max 6.42 ms; CPU 1.62 s in 2.01 s (81%)
wrote results/rate4000.csv and results/rate4000.json
exit 0
kload used 100% of a CPU: close to its limit, so replies may have waited for it to read them. Lower the rate, or split it across processes.
kload fell behind its schedule: send lag p99 1974.5 ms is over --max-lag-ms 10. These latencies include time spent waiting inside kload: don't trust them.
open loop: 40000 requests at 20000/s over 2 s
answers: 200 x40000
latency (2xx): p50 1430.37 ms, p99 1997.69 ms, max 2003.93 ms
kload itself: send lag p99 1974.50 ms, max 1983.25 ms; CPU 4.02 s in 4.03 s (100%)
wrote results/rate20000.csv and results/rate20000.json
exit 3
~~~

At 20,000 requests a second, `kload` spent all of one CPU, fell behind its own schedule by seconds, said so, and exited with status 3. The latencies it printed were mostly time spent waiting inside `kload`, and it told you not to trust them. Note the middle run, too: at 4,000 a second `kload` stayed on schedule, but used 81% of a CPU, and warned you. Lesson 07 comes back to it.

## Break it

**Time from when it was sent.** In `load.py`, in `one`, change `clock() - due` to `clock() - sent` and run `uv run pytest -q tests/test_load.py`:

~~~text
tests/test_load.py:139: AssertionError
=========================== short test summary info ============================
FAILED tests/test_load.py::test_a_blocking_send_makes_kload_late_and_the_lag_shows_it
1 failed, 11 passed in 6.13s
~~~

`test_a_blocking_send_makes_kload_late_and_the_lag_shows_it` failed: requests that waited inside `kload` now report short latencies, and the wait disappears. That's coordinated omission again, hidden inside an "open" loop. Change it back.

**Start every task at once.** Replace the dispatcher's `for` loop with `tasks = [asyncio.create_task(one(i, start + i / rate)) for i in range(round(rate * duration_s))]`, add a `sleep` at the top of `one` until its due time, and run `uv run kload load --rate 3000 --duration 5 | grep itself` against Switchyard; then put the dispatcher back and run it again:

~~~text
kload fell behind its schedule: send lag p99 48.6 ms is over --max-lag-ms 10. These latencies include time spent waiting inside kload: don't trust them.
kload itself: send lag p99 48.62 ms, max 66.68 ms; CPU 2.31 s in 5.02 s (46%)
kload itself: send lag p99 1.17 ms, max 11.77 ms; CPU 2.24 s in 5.02 s (45%)
~~~

The first two lines are every task started at once, the last the dispatcher. The same requests and about the same CPU, but a send lag p99 of 48.6 ms against 1.17 ms: starting 15,000 tasks at the beginning made requests so late that `kload` refused the run.

## Check it

~~~bash
uv run kload load --rate 200 --duration 5 --out results/check.csv; echo "exit $?"
~~~

Then, from memory: what is coordinated omission, and which two places in a load generator can bring it back? Why is a request's latency timed from when it was due? What does `kload` do when its send lag is high, and why exit with a distinct status? Why did `kload` stop using httpx to send its load?

This proves `kload` sends on schedule and times honestly on your machine, at the rates you tried. It doesn't prove a server is fast or slow: that needs experiments with a baseline, which is lesson 07.

## If it goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `answers: ConnectionRefusedError x1000` and exit 1 | Switchyard isn't running, or `--url` is wrong | Start it; check the port |
| Exit 3 at a low rate | Something else is using the CPU, or `--max-in-flight` is too low for a slow server | Check `top`; raise `--max-in-flight` |
| `answers: 503 x...` on `POST /jobs` | Switchyard's queue is full: backpressure, as designed | That's lesson 07's saturation experiment |
| `ProtocolError: response has neither Content-Length nor chunked encoding` | A server that ends a response by closing the connection | `kload` doesn't support that; HTTP/1.1 servers that keep connections open don't do it |
| `kload speaks plain HTTP only` | An `https://` URL | `kload` has no TLS; measure TLS separately |
| Tests hang | A `FakeServer` answer that never returns, without a timeout | Give the run a `timeout_s`, as the timeout test does |
