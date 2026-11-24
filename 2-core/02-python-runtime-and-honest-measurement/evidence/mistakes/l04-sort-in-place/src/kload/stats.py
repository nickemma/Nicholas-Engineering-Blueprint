"""Summary statistics for request latencies."""

import math
from collections.abc import Sequence
from dataclasses import dataclass


@dataclass(frozen=True)
class Summary:
    """The numbers that describe a batch of latencies."""

    count: int
    mean: float
    p50: float
    p99: float
    max: float


def percentile(values: Sequence[float], p: float) -> float:
    """Return the p-th percentile of values, by the nearest-rank method.

    Sort the values and take the one at position ceil(p/100 * n), counting
    from 1. The answer is always a value that really occurred.
    """
    if not values:
        raise ValueError("cannot take a percentile of an empty list")
    if not 0 < p <= 100:
        raise ValueError(f"p must be above 0 and at most 100, not {p}")
    values.sort()
    ordered = values
    rank = math.ceil(p / 100 * len(ordered))
    return ordered[rank - 1]


def summarize(values: Sequence[float]) -> Summary:
    """Describe values by their count, mean, p50, p99 and maximum."""
    if not values:
        raise ValueError("cannot summarize an empty list")
    return Summary(
        count=len(values),
        mean=sum(values) / len(values),
        p50=percentile(values, 50),
        p99=percentile(values, 99),
        max=max(values),
    )
