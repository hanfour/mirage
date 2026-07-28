import struct
import zlib

from lib.png import encode_rgba, read_size


def _chunks(data: bytes):
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, out = 8, []
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        out.append((ctype, body))
        pos += 12 + length
    return out


def test_writes_valid_png_header_and_dimensions():
    png = encode_rgba(2, 3, b"\xff\x00\x00\xff" * 6)
    ctypes = [c for c, _ in _chunks(png)]
    assert ctypes[0] == b"IHDR"
    assert ctypes[-1] == b"IEND"
    ihdr = dict(_chunks(png))[b"IHDR"]
    width, height, depth, color = struct.unpack(">IIBB", ihdr[:10])
    assert (width, height, depth, color) == (2, 3, 8, 6)   # 8-bit RGBA


def test_roundtrips_pixels():
    """左上紅、右下藍，解回來要一模一樣——scanline filter byte 若漏掉會整張錯位。"""
    rgba = bytes([255, 0, 0, 255] + [0, 0, 255, 255])
    png = encode_rgba(2, 1, rgba)
    idat = b"".join(b for c, b in _chunks(png) if c == b"IDAT")
    raw = zlib.decompress(idat)
    assert raw[0] == 0          # 每列開頭的 filter type
    assert raw[1:] == rgba


def test_rejects_wrong_buffer_length():
    try:
        encode_rgba(2, 2, b"\x00" * 4)   # 應該要 2*2*4=16 bytes
    except ValueError as e:
        assert "16" in str(e)
    else:
        raise AssertionError("長度不符時必須 raise")


def test_read_size_roundtrips():
    """adb screencap 直接回 PNG，要印出尺寸就得從 header 讀。"""
    assert read_size(encode_rgba(7, 11, b"\x00" * (7 * 11 * 4))) == (7, 11)


def test_read_size_rejects_non_png():
    try:
        read_size(b"not a png at all")
    except ValueError:
        pass
    else:
        raise AssertionError("非 PNG 必須 raise")
