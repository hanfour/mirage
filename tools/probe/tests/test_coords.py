import pytest

from lib.coords import lerp_path, to_guest_pixel


def test_maps_center_to_physical_center():
    """本機 guest 是 1080x2400。若誤用串流尺寸 540x1200 換算會得到 (270,600)
    ——那正是 2026-07-28 §10 那個 bug：每次點擊都落在目標的左上一半處。"""
    assert to_guest_pixel(0.5, 0.5, 1080, 2400) == (540, 1200)


def test_maps_corners():
    assert to_guest_pixel(0.0, 0.0, 1080, 2400) == (0, 0)
    assert to_guest_pixel(1.0, 1.0, 1080, 2400) == (1080, 2400)


def test_rounds_rather_than_truncates():
    # 0.5001 * 1080 = 540.108 → 540；0.9999 * 1080 = 1079.892 → 1080
    assert to_guest_pixel(0.5001, 0.5, 1080, 2400)[0] == 540
    assert to_guest_pixel(0.9999, 0.5, 1080, 2400)[0] == 1080


@pytest.mark.parametrize("nx,ny", [(-0.1, 0.5), (1.1, 0.5), (0.5, -0.1), (0.5, 1.1)])
def test_rejects_out_of_range(nx, ny):
    with pytest.raises(ValueError):
        to_guest_pixel(nx, ny, 1080, 2400)


def test_lerp_path_includes_both_ends():
    path = lerp_path((0.0, 0.0), (1.0, 1.0), steps=5)
    assert len(path) == 5
    assert path[0] == (0.0, 0.0)
    assert path[-1] == (1.0, 1.0)


def test_lerp_path_is_monotonic():
    path = lerp_path((0.2, 0.8), (0.8, 0.2), steps=7)
    assert [p[0] for p in path] == sorted(p[0] for p in path)
    assert [p[1] for p in path] == sorted((p[1] for p in path), reverse=True)
