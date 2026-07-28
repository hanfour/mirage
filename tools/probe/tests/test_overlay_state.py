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
