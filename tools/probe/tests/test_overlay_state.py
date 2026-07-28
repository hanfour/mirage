import pytest

from lib import overlay_state


def test_roundtrips_original_value(tmp_path, monkeypatch):
    monkeypatch.setattr(overlay_state, "STATE_DIR", str(tmp_path))
    assert overlay_state.load_original("game") is None
    overlay_state.save_original("game", "0")
    assert overlay_state.load_original("game") == "0"


def test_targets_do_not_share_state(tmp_path, monkeypatch):
    """2026-07-28 那輪同時開了兩台機器的疊層，狀態必須分開存。"""
    monkeypatch.setattr(overlay_state, "STATE_DIR", str(tmp_path))
    overlay_state.save_original("game", "0")
    overlay_state.save_original("bench", "1")
    assert overlay_state.load_original("game") == "0"
    assert overlay_state.load_original("bench") == "1"


def test_does_not_record_when_overlay_is_already_on():
    """`overlay on` 連按兩次：第二次讀到的原值是 "1"。若照記不誤，就把第一次
    存下的**真正**原值蓋掉，之後 `restore` 會把疊層設回 1——疊層永久留在裝置
    上，正是設計文件 §4.4 要防的那件事原封不動地回來。

    不是假想：2026-07-28 review 當下 `emulator-5554`（poc，共享實例）的
    pointer_location 就是遺留的 "1"，任何人對它跑一次 `overlay on` 就踩中。"""
    assert overlay_state.should_record("1") is False


@pytest.mark.parametrize("current", ["0", "", "null", " 0 "])
def test_records_every_value_that_is_not_on(current):
    """「已經開著」是唯一不該記錄的情況。未設定（""／"null"）與明確關閉（"0"）
    都是**有意義的原值**，漏記等於 restore 時無從還原。"""
    assert overlay_state.should_record(current) is True


def test_recording_survives_a_second_on(tmp_path, monkeypatch):
    """端到端釘住這條不變式：真正的原值在第二次 `on` 之後仍然讀得回來。"""
    monkeypatch.setattr(overlay_state, "STATE_DIR", str(tmp_path))
    for current in ("0", "1"):          # 第一次讀到 0，第二次讀到 1
        if overlay_state.should_record(current):
            overlay_state.save_original("bench", current)
    assert overlay_state.load_original("bench") == "0"


@pytest.mark.parametrize("original,expected", [
    ("0", "0"), ("1", "1"), ("", "0"), ("null", "0"), (" null ", "0"), ("2", "2"),
])
def test_restore_value_maps_unset_to_off(original, expected):
    """`settings get` 沒設定過時回字面上的 "null"；直接 `settings put null` 只會
    寫進一個字面字串 "null"，不是清除設定——所以未設定一律對應到關閉。"""
    assert overlay_state.restore_value(original) == expected
