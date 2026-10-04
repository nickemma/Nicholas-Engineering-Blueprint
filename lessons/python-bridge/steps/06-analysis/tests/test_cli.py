import pytest

from kload.cli import main


def test_summarize_prints_each_statistic(tmp_path, capsys):
    data = tmp_path / "latencies.txt"
    data.write_text("12 15\n11 250\n14\n")

    assert main(["summarize", str(data)]) == 0

    out = capsys.readouterr().out
    assert "count: 5" in out
    assert "  p50: 14" in out
    assert "  max: 250" in out


def test_unknown_command_exits_with_usage_error(capsys):
    with pytest.raises(SystemExit) as caught:
        main(["fly"])
    assert caught.value.code == 2
    assert "invalid choice" in capsys.readouterr().err


def test_bad_number_in_file_raises(tmp_path):
    data = tmp_path / "latencies.txt"
    data.write_text("12 fast\n")
    with pytest.raises(ValueError):
        main(["summarize", str(data)])
