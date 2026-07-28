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


def test_lerp_path_end_is_exactly_end_not_interpolated():
    """浮點內插的終點不保證等於 end：`x1 + (x2-x1)*(steps-1)/(steps-1)` 在
    (0.23,0.23)→(1.0,1.0) steps=15 這組實際參數下算出 1.0000000000000002。

    這不是「反正之後會 round 掉」的無害誤差——`to_guest_pixel` 是**先驗證、
    後 round**，epsilon 溢出會直接撞上 0–1 的範圍檢查丟 ValueError，而錯誤
    訊息裡印的是一個使用者從來沒打過的座標。這組參數就是 `swipe 0.23 0.23
    1.0 1.0`（預設 300ms → steps=15），手打得出來。"""
    path = lerp_path((0.23, 0.23), (1.0, 1.0), steps=15)
    assert path[-1] == (1.0, 1.0)
    assert path[0] == (0.23, 0.23)


def test_lerp_path_never_escapes_unit_range():
    """窮舉審查者找到的那 16 組越界參數所在的整個空間：任何 0–1 的起訖點、
    任何合理的 steps，內插結果都必須能安全餵進 to_guest_pixel。這條測試把
    「路徑點恆在合法範圍內」這個性質釘死，而不只是釘住其中一個案例。"""
    grid = [i / 20 for i in range(21)]
    for steps in (2, 3, 7, 15, 25, 50):
        for a in grid:
            for b in grid:
                for point in lerp_path((a, a), (b, b), steps):
                    to_guest_pixel(point[0], point[1], 1080, 2400)   # 越界會 raise
