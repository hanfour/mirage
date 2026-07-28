"""`adb exec-out screencap`（**不帶 `-p`**）的 raw framebuffer 標頭解析。純函式。

**為什麼 adb 這條路徑改抓 raw 而不是 PNG**：`compare` 的價值在於讓兩條路徑的
差異變成可觀測的事實，而不是印一句沒被觀察過的宣稱。若 adb 回的是它自己編碼的
PNG，要比對像素就得再寫一支 PNG 解碼器（外部 PNG 的 filter type 未必每列都是
0，寫半套只會製造新的錯誤結論）。改抓 raw 之後兩條路徑一律得到 (w, h, RGBA)、
一律用 `png.encode_rgba` 寫檔——像素差異成為唯一的變因，檔案大小也才可比。
（先前設計文件 §9 拿 19.2% 的檔案大小差當「內容不同」的證據，那其實是編碼器
差異：疊層全關時 grpc 132KB < adb 162KB，差異連正負號都不固定。）

標頭格式實測（2026-07-28，emulator-5554/5556/5558 三台一致）：
`<width:u32><height:u32><format:u32><colorSpace:u32>` 小端，之後緊接
`width*height*4` bytes 的 RGBA。format=1 是 RGBA_8888。
colorSpace 欄位是 Android 11 之後才有的，所以標頭長度**綁死驗證**：長度對不上
就明確報錯，不猜第二種標頭長度——猜錯會讓整張圖錯位而看起來「只是畫面怪怪的」。
"""
import struct

HEADER_BYTES = 16
RGBA_8888 = 1


def parse_screencap_raw(data: bytes) -> tuple[int, int, bytes]:
    """raw screencap 位元組 → (width, height, rgba)。"""
    if len(data) < HEADER_BYTES:
        raise ValueError(f"screencap raw 輸出太短：{len(data)} bytes（標頭就要 {HEADER_BYTES}）")
    width, height, fmt, _colorspace = struct.unpack("<4I", data[:HEADER_BYTES])
    if width <= 0 or height <= 0:
        raise ValueError(f"screencap raw 標頭尺寸不合理：{width}x{height}")
    if fmt != RGBA_8888:
        raise ValueError(f"screencap 回傳格式碼 {fmt}，不是 RGBA_8888({RGBA_8888})；不做猜測轉換")
    body = data[HEADER_BYTES:]
    expected = width * height * 4
    if len(body) != expected:
        raise ValueError(
            f"screencap raw 長度不符：{width}x{height} 應為 {expected} bytes，"
            f"實得 {len(body)}（標頭長度可能隨 Android 版本不同）")
    return width, height, body
