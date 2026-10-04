"""Save a run's raw results next to the settings that produced them."""

import csv
import json
from dataclasses import asdict, fields
from pathlib import Path
from typing import Any

from kload.load import Result


def write_results(results: list[Result], path: Path, settings: dict[str, Any]) -> Path:
    """Write results as CSV, plus a JSON file with the settings beside it.

    Raw results, not just a summary, let anyone recompute any statistic
    later. The settings file records how to reproduce the run. Returns the
    settings file's path.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[field.name for field in fields(Result)])
        writer.writeheader()
        for result in results:
            writer.writerow(asdict(result))

    settings_path = path.with_suffix(".json")
    settings_path.write_text(json.dumps(settings, indent=2, sort_keys=True) + "\n")
    return settings_path
