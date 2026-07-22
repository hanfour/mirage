import mmap as mmap_mod

import numpy as np
import pytest

from lib.mmap_source import frame_array, make_handle, open_frame_buffer

W, H = 4, 3  # 4x3x4 = 48 bytes，測試用小尺寸


def test_make_handle_absolute_path():
    assert make_handle("/tmp/frames.bin") == "file:///tmp/frames.bin"


def test_make_handle_rejects_relative():
    with pytest.raises(ValueError):
        make_handle("frames.bin")


def test_open_frame_buffer_creates_and_sizes(tmp_path):
    p = str(tmp_path / "buf.bin")
    buf = open_frame_buffer(p, W, H)
    assert len(buf) == W * H * 4
    buf.close()


def test_frame_array_roundtrip(tmp_path):
    p = str(tmp_path / "buf.bin")
    buf = open_frame_buffer(p, W, H)
    with open(p, "r+b") as f:
        f.write(bytes(range(48)))
    arr = frame_array(buf, W, H)
    assert arr.shape == (H, W, 4)
    assert arr[0, 0, 0] == 0 and arr[2, 3, 3] == 47
    del arr  # 釋放 zero-copy buffer export，否則 mmap.close() 會丟 BufferError
    buf.close()


def test_frame_array_rejects_size_mismatch(tmp_path):
    p = str(tmp_path / "buf.bin")
    buf = open_frame_buffer(p, W, H)
    with pytest.raises(ValueError):
        frame_array(buf, W + 1, H)
    buf.close()
