"""兩張 RGBA 影像的客觀差異，以「差在哪些列」表示。純函式。

`compare` 先前印的是設計文件**相信**的東西——「adb 不含 overlay、gRPC 含」。
2026-07-28 實測推翻：`adb screencap` 一樣含 `pointer_location` 疊層（對照
`overlay off` / `overlay on` 兩張 adb 圖，差異正好落在 row 136–167，那條 HUD
在 adb 圖裡清清楚楚）。兩條路徑真正的差異在別的地方：gRPC 幀在頂端中央
row 34–101 有一個黑色圓形（螢幕挖孔遮罩），adb 那張沒有。

所以工具改成只講它**剛剛量到**的東西：真的比一次，報告差在哪些列。
以列為單位而不是逐像素，是因為列範圍剛好就是上面那兩個發現的表達形式，
而且 1080x2400 只要 2400 次 bytes 比較（C 層），比逐像素快上兩個數量級。
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class RowDiff:
    """height 列之中有 differing_rows 列不同，合併成 ranges（閉區間）。"""
    height: int
    differing_rows: int
    ranges: tuple[tuple[int, int], ...]

    @property
    def identical(self) -> bool:
        return self.differing_rows == 0


def compare_rows(a: bytes, b: bytes, width: int, height: int) -> RowDiff:
    """逐列比對兩張同尺寸 RGBA 影像。"""
    expected = width * height * 4
    if len(a) != expected or len(b) != expected:
        raise ValueError(
            f"RGBA 長度不符：{width}x{height} 應為 {expected} bytes，"
            f"實得 {len(a)} 與 {len(b)}")
    stride = width * 4
    rows = [y for y in range(height)
            if a[y * stride:(y + 1) * stride] != b[y * stride:(y + 1) * stride]]
    return RowDiff(height=height, differing_rows=len(rows), ranges=_merge(rows))


def _merge(rows: list[int]) -> tuple[tuple[int, int], ...]:
    """連續列號併成閉區間：[3,4,5,9] → ((3,5),(9,9))。"""
    merged: list[tuple[int, int]] = []
    for row in rows:
        if merged and row == merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], row)
        else:
            merged.append((row, row))
    return tuple(merged)


def describe(diff: RowDiff, max_ranges: int = 6) -> str:
    """給 Claude session 讀的一行摘要。只陳述量到的事實，不推論成因。"""
    if diff.identical:
        return f"兩張圖的 {diff.height} 列像素完全相同"
    shown = ", ".join(f"{s}" if s == e else f"{s}–{e}" for s, e in diff.ranges[:max_ranges])
    if len(diff.ranges) > max_ranges:
        shown += f", …（共 {len(diff.ranges)} 段）"
    return f"{diff.differing_rows}/{diff.height} 列有像素差異，落在 row {shown}"
