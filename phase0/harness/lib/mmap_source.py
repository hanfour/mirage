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
    expected = width * height * 4
    if len(buf) != expected:
        raise ValueError(f"緩衝區 {len(buf)} bytes != {expected}（{width}x{height} RGBA）")
    return np.frombuffer(buf, dtype=np.uint8).reshape(height, width, 4)
