"""lib.framebuffer：adb raw screencap 的標頭解析。

**為什麼這條重要**：標頭解錯不會炸，會**靜默給出錯位的整張圖**——然後
`compare` 會報告一堆假的像素差異，而人只會覺得「畫面怪怪的」。這個專案已經因為
同類問題（觸控座標乘錯尺寸）浪費過整整一輪，所以寧可明確報錯也不猜。

標頭格式是實測來的（2026-07-28，emulator-5554/5556/5558 三台一致）：
`<w:u32><h:u32><format:u32><colorSpace:u32>` 小端 + w*h*4 bytes RGBA。
colorSpace 是 Android 11 之後才加的欄位，所以長度驗證是唯一擋得住版本差異的東西。
"""
import struct

import pytest

from lib.framebuffer import HEADER_BYTES, RGBA_8888, parse_screencap_raw


def _raw(width: int, height: int, fmt: int = RGBA_8888,
         body: bytes | None = None, colorspace: int = 1) -> bytes:
    pixels = body if body is not None else b"\x01\x02\x03\xff" * (width * height)
    return struct.pack("<4I", width, height, fmt, colorspace) + pixels


def test_parses_dimensions_and_pixels():
    width, height, rgba = parse_screencap_raw(_raw(2, 3))
    assert (width, height) == (2, 3)
    assert rgba == b"\x01\x02\x03\xff" * 6


def test_header_is_exactly_16_bytes():
    """標頭多算或少算 4 bytes，圖就整張位移一個像素而不會報錯——這條把
    實測到的長度釘死。"""
    assert HEADER_BYTES == 16
    data = _raw(1, 1)
    assert len(data) == 16 + 4


def test_rejects_length_mismatch():
    """長度對不上就是標頭猜錯（Android 版本不同）。**必須報錯，不能硬解**。"""
    with pytest.raises(ValueError, match="長度不符"):
        parse_screencap_raw(_raw(2, 3, body=b"\x00" * 20))   # 應為 24


def test_rejects_non_rgba_format():
    """format 不是 RGBA_8888（例如 RGB_565）時，照 4 bytes/pixel 解會得到
    整張亂碼。不做猜測轉換。"""
    with pytest.raises(ValueError, match="RGBA_8888"):
        parse_screencap_raw(_raw(2, 3, fmt=4))


def test_rejects_truncated_output():
    with pytest.raises(ValueError, match="太短"):
        parse_screencap_raw(b"\x00" * 8)


def test_rejects_zero_dimensions():
    """0x0 的長度驗證會「剛好通過」（0 bytes body），得先擋下來。"""
    with pytest.raises(ValueError, match="不合理"):
        parse_screencap_raw(_raw(0, 0, body=b""))
