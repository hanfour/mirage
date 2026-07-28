"""RGBA bytes → PNG bytes。純函式、無依賴（不引入 Pillow）。

只需要寫出「能被看圖工具與 Claude 讀取」的 PNG，用不著完整的影像函式庫。
"""
import struct
import zlib


def encode_rgba(width: int, height: int, rgba: bytes) -> bytes:
    expected = width * height * 4
    if len(rgba) != expected:
        raise ValueError(f"RGBA 長度不符：預期 {expected}，實得 {len(rgba)}")

    stride = width * 4
    raw = b"".join(b"\x00" + rgba[y * stride:(y + 1) * stride] for y in range(height))

    def chunk(ctype: bytes, body: bytes) -> bytes:
        payload = ctype + body
        return (struct.pack(">I", len(body)) + payload
                + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6))
            + chunk(b"IEND", b""))


def read_size(data: bytes) -> tuple[int, int]:
    """從 PNG header 讀寬高。adb screencap 直接回 PNG，印尺寸需要它。"""
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("不是有效的 PNG（缺少 signature 或 IHDR）")
    width, height = struct.unpack(">II", data[16:24])
    return width, height
