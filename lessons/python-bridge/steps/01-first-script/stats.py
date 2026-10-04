"""Summary statistics for request latencies."""


def summarize(values: list[float]) -> dict[str, float]:
    """Return the count, mean, minimum and maximum of values."""
    if not values:
        raise ValueError("cannot summarize an empty list")
    return {
        "count": len(values),
        "mean": sum(values) / len(values),
        "min": min(values),
        "max": max(values),
    }
