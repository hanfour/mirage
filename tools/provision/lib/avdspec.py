"""兩台 AVD 的規格。**純資料，沒有行為。**

只有兩台：`mirage-poc`（default image）與 `mirage-game`（playstore image），
非映像設定完全一致——兩台只差 system image，跨台的 fps 數字才可直接比較。

原本的第三台 `mirage-bench` 統一設定後會與 `mirage-poc` 完全重複，所以不再
產出。**腳本不認識它**：不產出、不報告、不動既有的那一台（量測記錄
`docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §13.2 引用了它）。
"""
from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class AvdSpec:
    name: str
    sysdir: str
    playstore: bool
    tag_id: str
    tag_display: str


SPECS = (
    AvdSpec(
        name="mirage-poc",
        sysdir="system-images/android-35/default/arm64-v8a/",
        playstore=False,
        tag_id="default",
        tag_display="Default Android System Image",
    ),
    AvdSpec(
        name="mirage-game",
        sysdir="system-images/android-35/google_apis_playstore/arm64-v8a/",
        playstore=True,
        tag_id="google_apis_playstore",
        tag_display="Google Play",
    ),
)
