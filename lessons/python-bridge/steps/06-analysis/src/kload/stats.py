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
    p95: float
    p99: float
    max: float


def percentile(values: Sequence[float], p: float) -> float:
    """Return the p-th percentile of values using the nearest-rank method.

    The nearest-rank percentile is always one of the observed values: the
    smallest value that at least p percent of all values are less than or
    equal to.
    """
    if not values:
        raise ValueError("percentile of an empty sequence is undefined")
    if not 0 < p <= 100:
        raise ValueError(f"p must be in (0, 100], got {p}")
    ordered = sorted(values)
    rank = math.ceil(p / 100 * len(ordered))
    return ordered[rank - 1]


def summarize(values: Sequence[float]) -> Summary:
    """Describe values with their count, mean, tail percentiles and maximum."""
    if not values:
        raise ValueError("cannot summarize an empty sequence")
    return Summary(
        count=len(values),
        mean=sum(values) / len(values),
        p50=percentile(values, 50),
        p95=percentile(values, 95),
        p99=percentile(values, 99),
        max=max(values),
    )
