import pytest

from stats import summarize


def test_summarize():
    assert summarize([12, 15, 11, 250, 14]) == {
        "count": 5,
        "mean": 60.4,
        "min": 11,
        "max": 250,
    }


def test_one_value():
    assert summarize([7.5]) == {"count": 1, "mean": 7.5, "min": 7.5, "max": 7.5}


def test_empty_list_is_an_error():
    with pytest.raises(ValueError, match="empty"):
        summarize([])
