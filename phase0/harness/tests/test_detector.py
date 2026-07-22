import numpy as np
import pytest

from lib.detector import changed, region_mean

W, H = 100, 80


def _frame(fill: int) -> bytes:
    return np.full((H, W, 4), fill, dtype=np.uint8).tobytes()


def test_region_mean_uniform():
    assert region_mean(_frame(200), W, H, cx=50, cy=40, radius=10) == 200.0


def test_region_mean_detects_local_patch():
    arr = np.zeros((H, W, 4), dtype=np.uint8)
    arr[30:50, 40:60, :3] = 255  # 中央白色方塊
    assert region_mean(arr.tobytes(), W, H, cx=50, cy=40, radius=10) > 200
    assert region_mean(arr.tobytes(), W, H, cx=10, cy=10, radius=5) == 0.0


def test_region_mean_clamps_at_edges():
    assert region_mean(_frame(7), W, H, cx=0, cy=0, radius=10) == 7.0


def test_region_mean_rejects_bad_size():
    with pytest.raises(ValueError):
        region_mean(b"\x00" * 10, W, H, cx=50, cy=40, radius=10)


def test_changed_threshold():
    assert changed(30.0, 10.0, threshold=8.0) is True
    assert changed(12.0, 10.0, threshold=8.0) is False
