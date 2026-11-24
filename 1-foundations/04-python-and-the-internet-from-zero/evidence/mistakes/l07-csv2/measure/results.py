"""One result per request, saved to and loaded from a CSV file."""

import csv
from dataclasses import dataclass
from pathlib import Path

HEADER = ["request", "connection", "bytes", "latency_ms"]


@dataclass(frozen=True)
class Result:
    """How one request went."""

    request: int
    connection: int
    size: int
    latency_ms: float


def write_csv(path: Path, results: list[Result]) -> None:
    """Write results to path, one row per request, after a header row."""
    with path.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(HEADER)
        for r in results:
            writer.writerow([r.request, r.connection, r.size, f"{r.latency_ms:.2f}"])


def read_csv(path: Path) -> list[Result]:
    """Read results written by write_csv. A bad row is an error naming its line."""
    with path.open(newline="") as f:
        rows = csv.reader(f)
        if next(rows, None) != HEADER:
            raise ValueError(f"{path}: the first line must be {','.join(HEADER)}")
        results = []
        for line, row in enumerate(rows, start=2):
            try:
                request, connection, size, latency_ms = row
                results.append(Result(int(request), int(connection), int(size), float(latency_ms)))
            except ValueError as err:
                raise ValueError(f"{path}, line {line}: {err}") from err
    return results
