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

# 曾經有一支 read_size()：adb 那條路徑回 adb 自己編的 PNG，要印尺寸就得從
# header 讀。改抓 raw framebuffer（見 lib/framebuffer.py）之後，兩條路徑都直接
# 拿到 (w, h, rgba)，沒有任何呼叫端需要它了，所以移除，不留死碼。
