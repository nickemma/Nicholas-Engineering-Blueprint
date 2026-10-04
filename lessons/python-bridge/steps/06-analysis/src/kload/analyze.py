"""Turn raw results into a report and plots."""

from pathlib import Path

import matplotlib

matplotlib.use("Agg")  # draw to files; no window needed

import matplotlib.pyplot as plt  # noqa: E402
import pandas as pd  # noqa: E402

from kload.stats import percentile  # noqa: E402


def load_results(path: Path) -> pd.DataFrame:
    df = pd.read_csv(path, keep_default_na=False)
    df["latency_ms"] = df["latency_s"] * 1000
    df["ok"] = df["status"].between(200, 399)
    return df


def report(df: pd.DataFrame) -> dict[str, float]:
    """Headline numbers. Percentiles cover successful requests only."""
    if df.empty:
        raise ValueError("no results to report")
    ok = df.loc[df["ok"], "latency_ms"].tolist()
    span = df["scheduled_s"].max() - df["scheduled_s"].min()
    return {
        "requests": len(df),
        "error_rate": round(1 - df["ok"].mean(), 4),
        "throughput_rps": round(len(df) / span, 1) if span > 0 else float(len(df)),
        "p50_ms": round(percentile(ok, 50), 2) if ok else float("nan"),
        "p95_ms": round(percentile(ok, 95), 2) if ok else float("nan"),
        "p99_ms": round(percentile(ok, 99), 2) if ok else float("nan"),
        "max_ms": round(max(ok), 2) if ok else float("nan"),
    }


def per_second(df: pd.DataFrame) -> pd.DataFrame:
    """Requests, errors and p95 latency for each second of the run."""
    second = df["scheduled_s"].astype(int).rename("second")
    grouped = df.groupby(second)
    return pd.DataFrame(
        {
            "requests": grouped.size(),
            "errors": grouped["ok"].apply(lambda ok: int((~ok).sum())),
            "p95_ms": grouped["latency_ms"].apply(lambda s: round(percentile(s.tolist(), 95), 2)),
        }
    )


def plot(df: pd.DataFrame, path: Path) -> None:
    """Latency over time (spot stalls) and a histogram (see the shape of the tail)."""
    fig, (timeline, histogram) = plt.subplots(1, 2, figsize=(11, 4))
    timeline.scatter(df["scheduled_s"], df["latency_ms"], s=4, c=~df["ok"], cmap="coolwarm")
    timeline.set(xlabel="scheduled time (s)", ylabel="latency (ms)", title="Latency over time")
    histogram.hist(df["latency_ms"], bins=50)
    histogram.set(xlabel="latency (ms)", ylabel="requests", title="Latency distribution")
    histogram.set_yscale("log")
    fig.tight_layout()
    fig.savefig(path, dpi=120)
    plt.close(fig)
