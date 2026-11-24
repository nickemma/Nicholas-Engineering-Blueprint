"""Lesson 08: waiting one by one, then all at once."""

import asyncio
import time


async def fetch(name: str, seconds: float) -> str:
    """Pretend to fetch something that takes a while to answer."""
    time.sleep(seconds)  # a blocking wait
    return name


async def one_by_one() -> list[str]:
    return [await fetch("a", 0.5), await fetch("b", 0.5), await fetch("c", 0.5)]


async def all_at_once() -> list[str]:
    return await asyncio.gather(fetch("a", 0.5), fetch("b", 0.5), fetch("c", 0.5))


for job in (one_by_one, all_at_once):
    start = time.perf_counter()
    names = asyncio.run(job())
    print(f"{job.__name__}: {names} in {time.perf_counter() - start:.2f} s")
