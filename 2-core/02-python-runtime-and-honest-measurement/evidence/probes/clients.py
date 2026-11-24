"""Why kload sends its load with its own client: httpx against kload's Pool.

    uv run python clients.py PORT       (inside the kload project, with the gate's
                                         target server on PORT and -delay 5ms)

Both clients run the same open loop (a dispatcher that starts each request when
it's due) against the same server; the only difference is the HTTP client.
Prints, per client and rate: p50 and p99 latency, the send lag's p99, and the
CPU time per request.
"""

import asyncio
import math
import sys
import time

import httpx

from kload.http1 import Pool


def pct(values, p):
    values = sorted(values)
    return values[math.ceil(p / 100 * len(values)) - 1]


async def open_loop(send, rate, seconds):
    lat, lags = [], []
    start = time.perf_counter()

    async def one(i, due):
        lags.append(time.perf_counter() - due)
        await send(i)
        lat.append((time.perf_counter() - due) * 1000)

    tasks = []
    for i in range(round(rate * seconds)):
        due = start + i / rate
        if (delay := due - time.perf_counter()) > 0:
            await asyncio.sleep(delay)
        tasks.append(asyncio.create_task(one(i, due)))
    await asyncio.gather(*tasks)
    return lat, lags


async def with_httpx(port, rate, seconds):
    limits = httpx.Limits(max_connections=500, max_keepalive_connections=500)
    async with httpx.AsyncClient(base_url=f"http://127.0.0.1:{port}", limits=limits) as c:
        await c.get("/warm-up")  # httpx imports parts of itself on the first request

        async def send(i):
            await c.post("/work", headers={"Idempotency-Key": f"k-{i}"})

        return await open_loop(send, rate, seconds)


async def with_pool(port, rate, seconds):
    pool = Pool(f"http://127.0.0.1:{port}")
    await pool.request("GET", "/warm-up")

    async def send(i):
        await pool.request("POST", "/work", {"Idempotency-Key": f"k-{i}"})

    try:
        return await open_loop(send, rate, seconds)
    finally:
        pool.close()


if __name__ == "__main__":
    port = int(sys.argv[1])
    print("client  rate/s   p50 ms   p99 ms  lag p99 ms  CPU per request")
    for name, run, rates in (("httpx", with_httpx, (200, 500)), ("Pool", with_pool, (200, 500, 2000))):
        for rate in rates:
            cpu, wall = time.process_time(), time.perf_counter()
            lat, lags = asyncio.run(run(port, rate, 5))
            cpu, wall = time.process_time() - cpu, time.perf_counter() - wall
            print(f"{name:<6} {rate:>7} {pct(lat, 50):8.2f} {pct(lat, 99):8.2f} {pct(lags, 99) * 1000:11.2f}"
                  f"  {cpu / len(lat) * 1e3:6.2f} ms  ({wall:.1f} s for a 5 s run)")
