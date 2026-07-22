"""RGBA 畫格的區域亮度偵測。純函式，供 e2e 延遲量測辨識觸控指示出現。"""
import numpy as np


def region_mean(frame: bytes, width: int, height: int,
                 cx: int, cy: int, radius: int) -> float:
    expected = width * height * 4
    if len(frame) != expected:
        raise ValueError(f"frame 長度 {len(frame)} != {expected}（{width}x{height} RGBA）")
    arr = np.frombuffer(frame, dtype=np.uint8).reshape(height, width, 4)
    x0, x1 = max(cx - radius, 0), min(cx + radius, width)
    y0, y1 = max(cy - radius, 0), min(cy + radius, height)
    if x0 >= x1 or y0 >= y1:
        raise ValueError("偵測區域完全在畫面外")
    return float(arr[y0:y1, x0:x1, :3].mean())


def changed(now: float, baseline: float, threshold: float) -> bool:
    return abs(now - baseline) > threshold
