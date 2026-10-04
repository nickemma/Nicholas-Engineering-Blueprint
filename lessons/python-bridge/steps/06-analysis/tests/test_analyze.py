from kload.analyze import load_results, per_second, plot, report
from kload.load import Result
from kload.results import write_results


def sample(tmp_path):
    results = [Result(i * 0.01, 0.005, 200) for i in range(150)]
    results[120] = Result(1.2, 0.0, 0, "ConnectError")
    results[130] = Result(1.3, 0.9, 200)
    path = tmp_path / "run.csv"
    write_results(results, path, {"rate": 100})
    return load_results(path)


def test_report(tmp_path):
    numbers = report(sample(tmp_path))
    assert numbers["requests"] == 150
    assert numbers["error_rate"] == round(1 / 150, 4)
    assert numbers["p50_ms"] == 5.0
    assert numbers["max_ms"] == 900.0


def test_per_second(tmp_path):
    table = per_second(sample(tmp_path))
    assert table["requests"].tolist() == [100, 50]
    assert table["errors"].tolist() == [0, 1]


def test_plot_writes_a_png(tmp_path):
    out = tmp_path / "plot.png"
    plot(sample(tmp_path), out)
    assert out.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
