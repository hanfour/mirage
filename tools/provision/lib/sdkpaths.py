"""SDK 與 AVD 目錄的解析優先序。

**環境以參數傳入，不讀 os.environ**：`lib/` 底下不得有副作用，否則測試得去
monkey-patch 全域狀態，而那正是測試互相污染的來源。
"""
from __future__ import annotations

import posixpath


def _first_non_empty(env: dict[str, str], *names: str) -> str | None:
    """空字串視同未設定。

    `export ANDROID_SDK_ROOT=` 在 shell 裡很常見（例如被別的腳本清掉），
    照用會得到相對路徑，把整個 SDK 裝進當下的工作目錄。
    """
    for name in names:
        value = env.get(name, "").strip()
        if value:
            return value
    return None


def sdk_root(env: dict[str, str], home: str) -> str:
    """優先序：ANDROID_SDK_ROOT → ANDROID_HOME → ~/Library/Android/sdk。

    預設值必須與 `app/scripts/lib/verify_common.sh` 及
    `app/Sources/MirageShell/Detect/AdbClient.swift` 一致——不一致的話，
    這支腳本裝到 A、驗證腳本去 B 找，會以「adb 不存在」的形式現形。
    """
    explicit = _first_non_empty(env, "ANDROID_SDK_ROOT", "ANDROID_HOME")
    if explicit:
        return explicit
    return posixpath.join(home, "Library", "Android", "sdk")


def avd_home(env: dict[str, str], home: str) -> str:
    """優先序：ANDROID_AVD_HOME → ~/.android/avd。"""
    explicit = _first_non_empty(env, "ANDROID_AVD_HOME")
    if explicit:
        return explicit
    return posixpath.join(home, ".android", "avd")
