"""lib.imgdiff：兩張 RGBA 影像差在哪些列。

**為什麼這條重要**：`compare` 先前印的是設計文件**相信**的東西——
「adb 不含 pointer_location 疊層、gRPC 含」。2026-07-28 實測推翻了那個前提：
在 bench 上做對照（`overlay off` → 抓圖 → `overlay on` → 抓圖），差異正好落在
row 136–167，那條 HUD 在 adb 抓的圖裡清清楚楚。工具在輸出上蓋了一個從來沒被
觀察過、而且是假的斷言，還讓下一個人照著它做出錯誤結論。

修法是讓工具只講它剛剛量到的東西。所以這裡測的不是「差異應該長什麼樣」，
而是「量出來的差異有沒有被如實報告」——列範圍的合併與呈現要正確，否則
報告本身又會變成新的錯誤來源。
"""
import pytest

from lib.imgdiff import compare_rows, describe


def _rows(*colors: int, width: int = 2) -> bytes:
    """每個 color 產生一整列相同像素，方便指定「第幾列不同」。"""
    return b"".join(bytes([c, c, c, 255]) * width for c in colors)


def test_identical_images_report_no_difference():
    a = _rows(1, 2, 3)
    diff = compare_rows(a, a, width=2, height=3)
    assert diff.identical
    assert diff.differing_rows == 0
    assert diff.ranges == ()


def test_reports_the_rows_that_differ():
    a = _rows(0, 0, 0, 0, 0)
    b = _rows(0, 9, 9, 0, 0)
    diff = compare_rows(a, b, width=2, height=5)
    assert diff.differing_rows == 2
    assert diff.ranges == ((1, 2),)


def test_merges_only_contiguous_rows():
    """連續的列併成一段、不連續的分開——這正是「疊層 HUD 在 row 136–167」與
    「gRPC 的挖孔遮罩在 row 34–101」這兩個發現的表達形式。合併錯了，
    報告就會把兩個不同的東西講成一個。"""
    a = _rows(0, 0, 0, 0, 0, 0)
    b = _rows(9, 9, 0, 0, 9, 0)
    diff = compare_rows(a, b, width=2, height=6)
    assert diff.ranges == ((0, 1), (4, 4))
    assert diff.differing_rows == 3


def test_detects_a_single_differing_byte():
    """整列只差一個位元組也要算差異——半透明疊層的邊緣就是這種等級的差別，
    漏掉會得到「兩張一樣」這個假結論。"""
    a = bytearray(_rows(0, 0))
    b = bytearray(a)
    b[9] = 1                     # stride = width*4 = 8，所以第 9 個位元組落在 row 1
    diff = compare_rows(bytes(a), bytes(b), width=2, height=2)
    assert diff.ranges == ((1, 1),)


def test_rejects_buffers_that_do_not_match_the_declared_size():
    """尺寸對不上還硬比會逐列錯位，報出一整片假差異。"""
    with pytest.raises(ValueError, match="長度不符"):
        compare_rows(_rows(0, 0), _rows(0, 0, 0), width=2, height=3)


def test_describe_states_only_measured_facts():
    diff = compare_rows(_rows(0, 0, 0, 0), _rows(0, 9, 9, 0), width=2, height=4)
    text = describe(diff)
    assert "2/4 列有像素差異" in text
    assert "row 1–2" in text
    assert "overlay" not in text          # 不再宣稱任何關於疊層的事


def test_describe_collapses_single_row_ranges():
    diff = compare_rows(_rows(0, 0), _rows(0, 9), width=2, height=2)
    assert "row 1" in describe(diff)
    assert "1–1" not in describe(diff)


def test_describe_caps_the_number_of_ranges_shown():
    """畫面在動時可能有幾百段差異。全印出來會把輸出淹掉——這支工具的輸出是給
    Claude session 讀的，總段數比每一段的細節重要。"""
    height = 40
    a = _rows(*([0] * height))
    b = _rows(*[9 if y % 2 else 0 for y in range(height)])
    diff = compare_rows(a, b, width=2, height=height)
    text = describe(diff, max_ranges=3)
    assert "共 20 段" in text
    assert text.count("–") == 0          # 都是單列，不該有區間符號


def test_describe_says_identical_when_nothing_differs():
    a = _rows(1, 2, 3)
    assert "完全相同" in describe(compare_rows(a, a, width=2, height=3))
