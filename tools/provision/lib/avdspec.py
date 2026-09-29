"""兩台 AVD 的規格。映像路徑取自版本 pin。

只有兩台：`mirage-poc`（default image）與 `mirage-game`（playstore image），
非映像設定完全一致——兩台只差 system image，跨台的 fps 數字才可直接比較。

原本的第三台 `mirage-bench` 統一設定後會與 `mirage-poc` 完全重複，所以不再
產出。**腳本不認識它**：不產出、不報告、不動既有的那一台（量測記錄
`docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §13.2 引用了它）。
"""
from __future__ import annotations

from dataclasses import dataclass

from lib import versions
from lib.sdk_spec import load_spec


@dataclass(frozen=True)
class AvdSpec:
    name: str
    image_manifest: str
    playstore: bool
    tag_id: str
    tag_display: str

    @property
    def sysdir(self) -> str:
        return next(pin.install_path for pin in versions.PINS
                    if pin.manifest_key == self.image_manifest) + "/"


SPECS = tuple(
    AvdSpec(
        name=spec["name"],
        image_manifest=spec["imageManifest"],
        playstore=spec["playstore"],
        tag_id=spec["tagId"],
        tag_display=spec["tagDisplay"],
    )
    for spec in load_spec()["avds"]
)
