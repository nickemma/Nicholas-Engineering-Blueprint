"""Turn raw results into a report, a per-second table and plots."""

from pathlib import Path

import pandas as pd

from kload.stats import percentile


def load_frame(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, keep_default_na=False)
    df["latency_ms"] = df["latency_s"] * 1000
    df["lag_ms"] = (df["sent_s"] - df["scheduled_s"]) * 1000
    df["ok"] = df["status"].between(200, 299)
    return df


def report(df: pd.DataFrame) -> dict[str, float]:
    """Headline numbers. Latency percentiles cover 2xx responses only."""
    if df.empty:
        raise ValueError("no results to report")
    ok = df.loc[df["ok"], "latency_ms"].tolist()
    span = df["scheduled_s"].max() - df["scheduled_s"].min()

    def pct(p: float) -> float:
        return round(percentile(ok, p), 2) if ok else float("nan")

    return {
        "requests": len(df),
        "error_rate": round(1 - df["ok"].mean(), 4),
        "rate_per_s": round(len(df) / span, 1) if span > 0 else float(len(df)),
        "p50_ms": pct(50),
        "p99_ms": pct(99),
        "max_ms": round(max(ok), 2) if ok else float("nan"),
        "mean_ms": round(df["latency_ms"].mean(), 2),
        "lag_p99_ms": round(percentile(df["lag_ms"].tolist(), 99), 2),
    }


def per_second(df: pd.DataFrame) -> pd.DataFrame:
    """Requests, errors, and p50 and p99 latency for each second of the run."""
    second = df["scheduled_s"].astype(int).rename("second")
    grouped = df.groupby(second)

    def pct(p: float):
        return lambda s: round(percentile(s.tolist(), p), 1)

    return pd.DataFrame(
        {
            "requests": grouped.size(),
            "errors": grouped["ok"].apply(lambda ok: int((~ok).sum())),
            "p50_ms": grouped["latency_ms"].apply(pct(50)),
            "p99_ms": grouped["latency_ms"].apply(pct(99)),
        }
    )


def plot(df: pd.DataFrame, path: Path) -> None:
    """Latency over time (to spot stalls), and its distribution (to see the tail)."""
    import matplotlib

    matplotlib.use("Agg")  # draw to a file; no window needed
    import matplotlib.pyplot as plt

    fig, (timeline, histogram) = plt.subplots(1, 2, figsize=(11, 4))
    ok, failed = df[df["ok"]], df[~df["ok"]]
    timeline.scatter(ok["scheduled_s"], ok["latency_ms"], s=4, label="2xx")
    if not failed.empty:
        timeline.scatter(failed["scheduled_s"], failed["latency_ms"], s=4, c="red", label="other")
    timeline.set(xlabel="when the request was due (s)", ylabel="latency (ms)")
    timeline.set_title("Latency over time")
    timeline.legend()
    histogram.hist(df["latency_ms"], bins=50)
    histogram.set(xlabel="latency (ms)", ylabel="requests", yscale="log")
    histogram.set_title("Latency distribution")
    fig.tight_layout()
    fig.savefig(path, dpi=100)
    plt.close(fig)
