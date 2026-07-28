import pytest

from lib.targets import TARGETS, resolve_target


def test_resolves_three_known_targets():
    assert resolve_target("game").serial == "emulator-5556"
    assert resolve_target("game").grpc_port == 8556
    assert resolve_target("bench").serial == "emulator-5558"
    assert resolve_target("bench").grpc_port == 8558
    assert resolve_target("poc").serial == "emulator-5554"
    assert resolve_target("poc").grpc_port == 8554


def test_only_game_is_playable():
    """bench 是 AOSP 無 Google 帳號，遊戲會卡在載入畫面；poc 是共享實例。
    這個旗標存在的唯一理由是 2026-07-28 那次在 bench 上測了整輪「能不能玩」。"""
    assert resolve_target("game").playable is True
    assert resolve_target("bench").playable is False
    assert resolve_target("poc").playable is False


def test_unknown_target_raises_with_valid_names():
    with pytest.raises(ValueError) as e:
        resolve_target("nope")
    for name in TARGETS:
        assert name in str(e.value)


def test_targets_are_immutable():
    from dataclasses import FrozenInstanceError
    with pytest.raises(FrozenInstanceError):
        resolve_target("game").serial = "x"
