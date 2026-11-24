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
    count(WORK)
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
