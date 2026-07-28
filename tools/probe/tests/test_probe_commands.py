"""probe.py 這一層的輸出契約——用假的 adb / 假的 emulator 測。

**不建立任何真 gRPC channel**：`emulator.connect` 整支被換掉。這個專案有一筆
已知架構債，讓測試建立真 channel 會讓套件機率性卡死（實測基準：四次跑有兩次
卡住），所以 tests/test_emulator.py 刻意不測 connect()，這裡也一樣。

這裡釘的是兩件先前只存在於「相信」而非「量測」裡的事：

1. 輸出的標籤描述**取得畫面的路徑**，不宣稱畫面內容有什麼差異。先前印的
   「(含系統 overlay)」/「(不含 overlay)」是假的——2026-07-28 實測：兩條路徑
   都含 pointer_location 疊層（同一條路徑切換疊層，grpc 與 adb 都在 row
   136–167 出現差異）；真正穩定的差異是 gRPC 幀在 row 34–101 有螢幕挖孔的
   黑色圓形遮罩，adb 那張沒有。
2. `overlay on` 連按兩次不會把疊層永久留在裝置上。
"""
import contextlib

import pytest

import _bootstrap  # noqa: F401

import probe
from lib import overlay_state


class _FakeEmulator:
    def __init__(self, width: int, height: int, fill: int = 0):
        self._size = (width, height)
        self._rgba = bytes([fill, fill, fill, 255]) * (width * height)

    def display_size(self):
        return self._size

    def screenshot(self):
        return (*self._size, self._rgba)


@pytest.fixture
def fake_paths(monkeypatch):
    """讓兩條抓圖路徑都回可控的影像；grpc 那條完全不碰 grpc 套件。"""
    state = {"grpc": _FakeEmulator(2, 4, fill=0), "adb": (2, 4, bytes([0, 0, 0, 255]) * 8)}

    @contextlib.contextmanager
    def fake_connect(port):
        yield state["grpc"]

    monkeypatch.setattr(probe.emulator, "connect", fake_connect)
    monkeypatch.setattr(probe.adb, "screencap_rgba", lambda serial: state["adb"])
    return state


def _args(**kwargs):
    return type("Args", (), kwargs)()


def test_compare_labels_name_the_path_not_the_content(fake_paths, tmp_path, capsys):
    probe.cmd_compare(probe.resolve_target("bench"), _args(prefix=str(tmp_path / "x")))
    out = capsys.readouterr().out
    assert "grpc: getScreenshot" in out
    assert "adb: exec-out screencap" in out


@pytest.mark.parametrize("banned", ["含系統 overlay", "不含 overlay", "不含疊層"])
def test_compare_makes_no_claim_about_overlay(fake_paths, tmp_path, capsys, banned):
    """先前這裡印的是設計文件相信的東西，而那個前提是錯的。工具只能講它剛剛
    量到的東西——這條測試在有人把宣稱加回來時變紅。"""
    probe.cmd_compare(probe.resolve_target("bench"), _args(prefix=str(tmp_path / "x")))
    assert banned not in capsys.readouterr().out


def test_compare_reports_the_measured_pixel_difference(fake_paths, tmp_path, capsys):
    """兩張圖真的不一樣時，要報出差在哪些列——這正是「gRPC 有挖孔遮罩、adb
    沒有」那個發現的表達形式。"""
    fake_paths["adb"] = (2, 4, bytes([0, 0, 0, 255]) * 4 + bytes([9, 9, 9, 255]) * 4)
    probe.cmd_compare(probe.resolve_target("bench"), _args(prefix=str(tmp_path / "x")))
    out = capsys.readouterr().out
    assert "2/4 列有像素差異" in out
    assert "row 2–3" in out


def test_compare_warns_that_the_two_shots_are_not_simultaneous(fake_paths, tmp_path, capsys):
    """兩張圖相隔 1–6 秒才抓完（adb raw 要搬 10.4 MB），畫面在動時內容本來就
    會不同。少了這句，使用者會把時間差造成的差異當成路徑差異——實測踩過：
    `overlay on` 之後立刻 compare，疊層在兩次抓取之間才畫上去，row 136–167
    就多出一段假的「路徑差異」。"""
    probe.cmd_compare(probe.resolve_target("bench"), _args(prefix=str(tmp_path / "x")))
    assert "非同時抓取" in capsys.readouterr().out


def test_compare_does_not_diff_images_of_different_sizes(fake_paths, tmp_path, capsys):
    """尺寸不同還硬比會逐列錯位，報出一整片假差異。"""
    fake_paths["adb"] = (2, 2, bytes([0, 0, 0, 255]) * 4)
    probe.cmd_compare(probe.resolve_target("bench"), _args(prefix=str(tmp_path / "x")))
    out = capsys.readouterr().out
    assert "尺寸不同" in out
    assert "列有像素差異" not in out


def test_shot_label_names_the_path(fake_paths, tmp_path, capsys):
    for via, expected in (("grpc", "grpc: getScreenshot"), ("adb", "adb: exec-out screencap")):
        probe.cmd_shot(probe.resolve_target("bench"),
                       _args(out=str(tmp_path / f"{via}.png"), via=via))
        assert expected in capsys.readouterr().out


# ---------------------------------------------------------------------------
# overlay：連按兩次 on 不得把疊層永久留在裝置上
# ---------------------------------------------------------------------------

class _FakeSettings:
    """記著 settings 的值，並記錄每一次寫入——用來確認 restore 真的寫回原值。"""

    def __init__(self, initial: str = "0"):
        self.value = initial
        self.writes: list[str] = []

    def get(self, serial, key):
        return self.value

    def put(self, serial, key, value):
        self.value = value
        self.writes.append(value)


@pytest.fixture
def fake_settings(monkeypatch, tmp_path):
    settings = _FakeSettings()
    monkeypatch.setattr(probe.adb, "get_setting", settings.get)
    monkeypatch.setattr(probe.adb, "put_setting", settings.put)
    monkeypatch.setattr(overlay_state, "STATE_DIR", str(tmp_path))
    return settings


def _overlay(action):
    return probe.cmd_overlay(probe.resolve_target("bench"), _args(action=action))


def test_overlay_on_twice_then_restore_turns_it_off(fake_settings, capsys):
    """設計文件 §4.4 要防的那件事：第二次 `on` 讀到的原值是 "1"，照記不誤就會
    蓋掉真正的原值，restore 於是把疊層設回 1，永久留在裝置上。

    2026-07-28 review 當下 `emulator-5554`（poc，共享實例）的 pointer_location
    正是這樣遺留下來的 "1"。"""
    _overlay("on")
    _overlay("on")
    _overlay("restore")
    assert fake_settings.value == "0"


def test_overlay_on_twice_keeps_the_first_recorded_original(fake_settings, capsys):
    fake_settings.value = "1"          # 疊層本來就開著（poc 現在的狀態）
    _overlay("on")
    assert overlay_state.load_original("bench") is None   # 沒有記錄的意義，不寫


def test_overlay_restore_puts_back_a_genuinely_on_original(fake_settings, capsys):
    """反向確認：使用者本來就開著疊層而**沒有**經過 `on` 記錄時，restore 是
    no-op；不能自作主張把別人開的疊層關掉。"""
    fake_settings.value = "1"
    _overlay("restore")
    assert fake_settings.writes == []
    assert "no-op" in capsys.readouterr().out


def test_overlay_on_reports_the_value_it_actually_stored(fake_settings, capsys):
    """先前 `on` 印「原值 null」但存檔存的是空字串，顯示與實際內容對不上。
    現在印出來的就是存進去的東西，外加 restore 會寫回什麼。"""
    fake_settings.value = ""
    _overlay("on")
    out = capsys.readouterr().out
    assert repr("") in out            # 存的是空字串，就印空字串
    assert "restore 會設回 0" in out
