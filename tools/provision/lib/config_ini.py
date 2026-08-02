"""`AvdSpec` 與 `config.ini` 文字之間的轉換。純函式，不碰磁碟。

**兩種格式，刻意不統一**（皆為實地確認）：
- `config.ini` 是 `key = value`（等號兩側有空格）——emulator 自己寫出來就長這樣
- 頂層的 `<name>.ini` 指標檔是 `key=value`（**沒有空格**）

改格式不會讓 emulator 讀不懂，但會讓每個欄位都出現在 diff 裡，把真正的差異埋掉。
"""
from __future__ import annotations

from lib.avdspec import AvdSpec
from lib.config_base import BASE


def expected_config(spec: AvdSpec) -> dict[str, str]:
    """共用的 BASE 疊上這台的 8 個 overlay 欄位。"""
    config = dict(BASE)
    config.update(
        {
            "avd.id": spec.name,
            "avd.name": spec.name,
            "image.sysdir.1": spec.sysdir,
            "PlayStore.enabled": "yes" if spec.playstore else "no",
            "tag.id": spec.tag_id,
            "tag.ids": spec.tag_id,
            "tag.display": spec.tag_display,
            "tag.displaynames": spec.tag_display,
        }
    )
    return config


def render_config(spec: AvdSpec) -> str:
    """key 排序後輸出。**排序是為了輸出穩定**——不穩定的話每次跑都會報成漂移。"""
    config = expected_config(spec)
    return "".join(f"{key} = {config[key]}\n" for key in sorted(config))


def parse_config(text: str) -> dict[str, str]:
    """容忍有無空格兩種寫法：手寫的 config.ini 未必照 emulator 的格式。"""
    result: dict[str, str] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        result[key.strip()] = value.strip()
    return result


def render_pointer_ini(spec: AvdSpec, avd_home: str) -> str:
    """頂層的 `<name>.ini`。

    `path` 是**絕對路徑**，所以這個檔一定要產生、不能複製——這也是為什麼
    provisioning 天生就得是腳本，而不是「把目錄壓起來給別人」。
    """
    return (
        "avd.ini.encoding=UTF-8\n"
        f"path={avd_home}/{spec.name}.avd\n"
        f"path.rel=avd/{spec.name}.avd\n"
        f"target={BASE['target']}\n"
    )
