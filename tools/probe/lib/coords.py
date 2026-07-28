"""normalized 座標 → guest 實體像素。純函式。

**乘的必須是 guest 實體解析度，不是串流幀尺寸。** proto 明載 Touch.x/y 是
"physical location on the screen"；2026-07-28 之前整條路徑乘的是串流尺寸
（540x1200 對 guest 1080x2400），每次點擊都落在目標的左上一半處。
"""


def to_guest_pixel(nx: float, ny: float, width: int, height: int) -> tuple[int, int]:
    if not (0.0 <= nx <= 1.0 and 0.0 <= ny <= 1.0):
        raise ValueError(f"normalized 座標須在 0–1：({nx}, {ny})")
    return (round(nx * width), round(ny * height))


def lerp_path(start: tuple[float, float], end: tuple[float, float],
              steps: int) -> list[tuple[float, float]]:
    """在兩個 normalized 點之間線性內插，含頭尾。

    swipe 必須是連續的多個觸點——只送起點與終點，guest 會當成瞬移，
    多數遊戲的拖曳手勢不會被辨識。
    """
    if steps < 2:
        raise ValueError(f"steps 至少為 2，實得 {steps}")
    (x1, y1), (x2, y2) = start, end
    return [(x1 + (x2 - x1) * i / (steps - 1), y1 + (y2 - y1) * i / (steps - 1))
            for i in range(steps)]
