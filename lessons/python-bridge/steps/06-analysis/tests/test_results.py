import csv

from kload.load import Result
from kload.results import write_results


def test_write_results_saves_rows_and_settings(tmp_path):
    path = tmp_path / "out" / "run.csv"
    results = [Result(0.0, 0.004, 200), Result(0.01, 0.0, 0, "ConnectError")]

    settings_path = write_results(results, path, {"rate": 5, "target": "health"})

    with path.open() as f:
        rows = list(csv.DictReader(f))
    assert rows[1] == {
        "scheduled_s": "0.01",
        "latency_s": "0.0",
        "status": "0",
        "error": "ConnectError",
    }
    assert settings_path.read_text() == '{\n  "rate": 5,\n  "target": "health"\n}\n'
