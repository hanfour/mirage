import pytest

from lib.stats import StreamStats, percentile, summarize


def test_percentile_median():
    assert percentile([5, 1, 3, 2, 4], 50) == 3


def test_percentile_interpolates():
    assert percentile([0, 10], 95) == pytest.approx(9.5)


def test_percentile_rejects_empty():
    with pytest.raises(ValueError):
        percentile([], 50)


def test_percentile_rejects_out_of_range():
    with pytest.raises(ValueError):
        percentile([1.0], 101)


def test_summarize_uniform_60fps():
    ts = [i / 60 for i in range(61)]  # 61 個時戳、剛好 1 秒
    s = summarize(ts)
    assert s.frames == 61
    assert s.fps == pytest.approx(60, rel=1e-3)
    assert s.p50_ms == pytest.approx(16.67, rel=1e-2)
    assert s.p95_ms == pytest.approx(16.67, rel=1e-2)


def test_summarize_rejects_short_input():
    with pytest.raises(ValueError):
        summarize([0.0])


def test_summarize_is_immutable():
    s = summarize([0.0, 1.0])
    with pytest.raises(Exception):
        s.fps = 999  # frozen dataclass
