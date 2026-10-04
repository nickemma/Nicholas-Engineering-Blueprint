import asyncio

import httpx
import pytest

from kload.load import Result, run_closed_loop, run_open_loop
from kload.stats import percentile


def get_health(client: httpx.AsyncClient):
    return client.get("/health")


def async_client(handler) -> httpx.AsyncClient:
    return httpx.AsyncClient(base_url="http://kestrel.test", transport=httpx.MockTransport(handler))


async def ok(request: httpx.Request) -> httpx.Response:
    return httpx.Response(200, json={"status": "ok"})


def test_open_loop_sends_rate_times_duration_requests():
    async def scenario():
        async with async_client(ok) as client:
            return await run_open_loop(client, get_health, rate=50, duration_s=0.4)

    results = asyncio.run(scenario())
    assert len(results) == 20
    assert all(r.status == 200 for r in results)
    assert [round(r.scheduled_s, 3) for r in results[:3]] == [0.0, 0.02, 0.04]


def test_transport_errors_are_recorded_not_raised():
    async def refuse(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    async def scenario():
        async with async_client(refuse) as client:
            return await run_open_loop(client, get_health, rate=20, duration_s=0.1)

    results = asyncio.run(scenario())
    assert {(r.status, r.error) for r in results} == {(0, "ConnectError")}


@pytest.mark.parametrize(("rate", "duration"), [(0, 1), (10, 0), (-1, 1)])
def test_open_loop_rejects_bad_arguments(rate, duration):
    with pytest.raises(ValueError):
        asyncio.run(run_open_loop(None, get_health, rate=rate, duration_s=duration))


class StallingServer:
    """Answers instantly, except for one request that freezes the whole server.

    The lock stands in for anything that stops a server answering anyone,
    such as a garbage-collection pause or a blocked event loop: requests
    that arrive during the stall wait for it to end.
    """

    def __init__(self, stall_on: int, stall_s: float) -> None:
        self.lock = asyncio.Lock()
        self.seen = 0
        self.stall_on = stall_on
        self.stall_s = stall_s

    async def __call__(self, request: httpx.Request) -> httpx.Response:
        async with self.lock:
            self.seen += 1
            if self.seen == self.stall_on:
                await asyncio.sleep(self.stall_s)
        return httpx.Response(200)


def p95_ms(results: list[Result]) -> float:
    return percentile([r.latency_s * 1000 for r in results], 95)


def test_closed_loop_hides_a_stall_that_open_loop_reveals():
    """A 0.5 s stall during a 1 s run at 50 requests per second.

    Real users would have sent about 25 requests during the stall, and every
    one of them would have waited. The closed loop sends none of them, so
    its p95 stays small. The open loop sends them on schedule and records the
    wait.
    """

    async def closed():
        async with async_client(StallingServer(stall_on=10, stall_s=0.5)) as client:
            return await run_closed_loop(client, get_health, count=50)

    async def open_():
        async with async_client(StallingServer(stall_on=10, stall_s=0.5)) as client:
            return await run_open_loop(client, get_health, rate=50, duration_s=1.0)

    closed_p95 = p95_ms(asyncio.run(closed()))
    open_p95 = p95_ms(asyncio.run(open_()))

    assert closed_p95 < 50, f"closed-loop p95 = {closed_p95:.1f} ms"
    assert open_p95 > 200, f"open-loop p95 = {open_p95:.1f} ms"
