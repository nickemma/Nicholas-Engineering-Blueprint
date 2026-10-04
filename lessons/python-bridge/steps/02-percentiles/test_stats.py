import pytest

from stats import Summary, percentile, summarize


@pytest.mark.parametrize(
    ("p", "expected"),
    [
        (50, 5),
        (90, 9),
        (95, 10),
        (100, 10),
        (10, 1),
        (1, 1),
    ],
)
def test_percentile_nearest_rank(p, expected):
    values = [3, 1, 4, 10, 5, 9, 2, 6, 8, 7]
    assert percentile(values, p) == expected


def test_percentile_does_not_change_the_input():
    values = [3, 1, 2]
    percentile(values, 50)
    assert values == [3, 1, 2]


def test_percentile_of_one_value():
    assert percentile([42.0], 99) == 42.0


@pytest.mark.parametrize("p", [0, -1, 101])
def test_percentile_rejects_p_out_of_range(p):
    with pytest.raises(ValueError, match="p must be in"):
        percentile([1, 2, 3], p)


def test_percentile_rejects_empty_input():
    with pytest.raises(ValueError, match="empty"):
        percentile([], 50)


def test_summarize():
    values = [float(v) for v in range(1, 101)]
    assert summarize(values) == Summary(count=100, mean=50.5, p50=50, p95=95, p99=99, max=100)


def test_one_slow_request_moves_the_tail_not_the_median():
    values = [10.0] * 99 + [5000.0]
    summary = summarize(values)
    assert summary.p50 == 10.0
    assert summary.p99 == 10.0
    assert summary.max == 5000.0
    assert summary.mean == pytest.approx(59.9)


def test_summarize_rejects_empty_input():
    with pytest.raises(ValueError):
        summarize([])
