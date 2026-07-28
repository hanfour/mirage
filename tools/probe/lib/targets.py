"""模擬器 target 的解析。純資料、無 I/O。

三台機器用途完全不同，混用會得到錯誤結論——2026-07-28 那輪照
verify_game_fps.sh 的預設用了 bench 機測「能不能玩」，測完整輪才發現那台
沒有 Google 帳號、遊戲根本進不去。所以 CLI 不給預設值，一律顯式指定。
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class Target:
    name: str
    serial: str
    grpc_port: int
    playable: bool
    note: str


TARGETS: dict[str, Target] = {
    "game": Target("game", "emulator-5556", 8556, True,
                   "Play Store 已登入 — 唯一能實際玩遊戲的機器"),
    "bench": Target("bench", "emulator-5558", 8558, False,
                    "AOSP 無 Google 帳號 — 只能量效能，遊戲會卡在載入畫面"),
    "poc": Target("poc", "emulator-5554", 8554, False,
                  "共享實例 — 不得殺／重啟"),
}


def resolve_target(name: str) -> Target:
    try:
        return TARGETS[name]
    except KeyError:
        valid = ", ".join(f"{n} ({t.note})" for n, t in TARGETS.items())
        raise ValueError(f"未知的 target {name!r}。可用：{valid}") from None
