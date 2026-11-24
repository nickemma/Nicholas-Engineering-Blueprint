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
        return Result(i, due - start, sent - start, clock() - sent, status, error)

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
