"""MMAP 畫格緩衝區的純邏輯：handle 產生、緩衝區建立、zero-copy 檢視。"""
import mmap
import os

import numpy as np


def make_handle(path: str) -> str:
    if not os.path.isabs(path):
        raise ValueError(f"handle 需要絕對路徑，收到 {path!r}")
    return f"file://{path}"


def open_frame_buffer(path: str, width: int, height: int) -> mmap.mmap:
    size = width * height * 4
    if size <= 0:
        raise ValueError(f"無效尺寸 {width}x{height}")
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        os.ftruncate(fd, size)
        return mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ)
    finally:
        os.close(fd)  # mmap 持有自己的參照，fd 可關


def frame_array(buf: mmap.mmap, width: int, height: int) -> np.ndarray:
    """把映射區當成 (height, width, 4) 的 RGBA 陣列。

    **不翻轉**：資料由上而下排列，第 0 列就是畫面最上面那一列。proto 的 `Image` 註解
    說 "bottom up"，那是錯的（D68），照它翻會取樣到鏡射位置。目前的呼叫端
    （`bench_mmap_vs_rgba.py`）只量吞吐與相異幀數，方向不影響結果，但要拿它取像素時
    這件事就要緊。
    """
    expected = width * height * 4
    if len(buf) != expected:
        raise ValueError(f"緩衝區 {len(buf)} bytes != {expected}（{width}x{height} RGBA）")
    return np.frombuffer(buf, dtype=np.uint8).reshape(height, width, 4)
