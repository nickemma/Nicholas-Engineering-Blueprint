"""Load generation: open-loop (correct) and closed-loop (misleading)."""

import asyncio
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass

import httpx

RequestFn = Callable[[httpx.AsyncClient], Awaitable[httpx.Response]]
Clock = Callable[[], float]


@dataclass(frozen=True)
class Result:
    """One request's outcome.

    scheduled_s is when the request was due, in seconds after the run began.
    latency_s is measured from that moment until the response arrived.
    status is the HTTP status, or 0 if no response came back.
    """

    scheduled_s: float
    latency_s: float
    status: int
    error: str = ""


async def _send(client: httpx.AsyncClient, request: RequestFn) -> tuple[int, str]:
    try:
        response = await request(client)
        return response.status_code, ""
    except httpx.HTTPError as exc:
        return 0, type(exc).__name__


async def run_open_loop(
    client: httpx.AsyncClient,
    request: RequestFn,
    rate: float,
    duration_s: float,
    *,
    max_in_flight: int = 1000,
    clock: Clock = time.perf_counter,
) -> list[Result]:
    """Send `rate` requests per second for `duration_s` seconds on a fixed schedule.

    Requests go out when they are due, whether or not earlier ones have
    finished, the way real users arrive. Latency is measured from the scheduled
    time, so if the server stalls, every request that should have been sent
    during the stall records the wait.
    """
    if rate <= 0 or duration_s <= 0:
        raise ValueError("rate and duration must be positive")
    interval = 1 / rate
    total = round(rate * duration_s)
    in_flight = asyncio.Semaphore(max_in_flight)
    start = clock()

    async def one(i: int) -> Result:
        scheduled = start + i * interval
        delay = scheduled - clock()
        if delay > 0:
            await asyncio.sleep(delay)
        async with in_flight:
            status, error = await _send(client, request)
        return Result(scheduled - start, clock() - scheduled, status, error)

    return list(await asyncio.gather(*(one(i) for i in range(total))))


async def run_closed_loop(
    client: httpx.AsyncClient,
    request: RequestFn,
    count: int,
    *,
    clock: Clock = time.perf_counter,
) -> list[Result]:
    """Send `count` requests one after another, each when the previous one returns.

    This is how many simple benchmarks work. While the server is stalled the
    loop is stuck waiting too, so it doesn't send the requests real users
    would have sent. The stall shows up in one sample instead of many: this is
    called coordinated omission.
    """
    results = []
    start = clock()
    for _ in range(count):
        sent = clock()
        status, error = await _send(client, request)
        results.append(Result(sent - start, clock() - sent, status, error))
    return results
