"""pin 住的版本。**改這個檔案＝改測試環境**，所以它必然留下 commit。

為什麼要 pin：manifest 對每個 package path 只提供**當下最新的一個 revision**。
Google 一 bump，先前的版本就從清單上消失——我們原本在跑的 canary 37.2.1
就是這樣沒的（直連網址仍回 200，但已不在清單上、沒有官方 checksum）。

所以這裡記下期望的 (path, revision, sha1)，解析 manifest 後逐項比對，
不同就中止。**絕不默默採用新版**：那會讓同一份 commit 在不同日子跑出不同
環境，正是 D33 要消滅的病。

副作用是刻意的：Google 每次 bump 之後這支腳本會主動壞掉一次，逼一個人來看
一眼並決定要不要升。那是特性，不是 bug。
"""
from __future__ import annotations

from dataclasses import dataclass
from lib.sdk_spec import load_spec

from lib.manifest import PackageRef, find_ref

_SPEC = load_spec()
ANDROID_TARGET = _SPEC["androidTarget"]

_REPO_BASE = "https://dl.google.com/android/repository/"

# zip 的 <url> 是相對於**該 manifest 所在目錄**的，所以 base 要跟著 manifest 走。
MANIFEST_BASES = {
    "repo": _REPO_BASE,
    "sysimg_default": _REPO_BASE + "sys-img/android/",
    "sysimg_playstore": _REPO_BASE + "sys-img/google_apis_playstore/",
}

MANIFESTS = {key: base + name for key, base, name in (
    ("repo", MANIFEST_BASES["repo"], "repository2-3.xml"),
    ("sysimg_default", MANIFEST_BASES["sysimg_default"], "sys-img2-3.xml"),
    ("sysimg_playstore", MANIFEST_BASES["sysimg_playstore"], "sys-img2-3.xml"),
)}


@dataclass(frozen=True)
class Pin:
    manifest_key: str
    path: str
    channel: str
    revision: str
    sha1: str
    size: int
    install_path: str  # 相對 SDK root 的最終目錄
    url: str = ""


PINS = tuple(
    Pin(
        manifest_key=package["manifestKey"],
        path=package["path"],
        channel=package["channel"],
        revision=package["revision"],
        sha1=package["sha1"],
        size=package["size"],
        install_path=package["installPath"],
        url=package["url"],
    )
    for package in _SPEC["packages"]
)


class PinDriftError(Exception):
    """manifest 上的版本與 pin 的不同。

    這**不是**「重跑一次就會好」的錯誤，而是一個需要有人做決定並留下 commit
    的事件。訊息裡必須說清楚這一點，否則下一個人會直覺去改 pin 讓它過。
    """


def _drift(pin: Pin, detail: str) -> PinDriftError:
    return PinDriftError(
        f"{pin.path}：{detail}。\n"
        f"manifest 對每個 package 只提供當下最新的一個 revision，所以上游一 bump，"
        f"pin 的版本就會從清單上消失。\n"
        f"這需要一個決定：確認新版可用之後更新 app/Sources/MirageCore/Resources/"
        f"sdk-spec.json 並送出 commit——換環境必須留下紀錄。"
    )


def resolve_pins(
    refs_by_manifest: dict[str, list[PackageRef]]
) -> list[tuple[Pin, PackageRef]]:
    """逐項比對 pin 與 manifest；任一項不符即中止。"""
    resolved: list[tuple[Pin, PackageRef]] = []
    for pin in PINS:
        refs = refs_by_manifest.get(pin.manifest_key, [])
        ref = find_ref(refs, pin.path, pin.channel)
        if ref is None:
            raise _drift(pin, f"在 {pin.channel} channel 上找不到（pin 的是 {pin.revision}）")
        if ref.revision != pin.revision:
            raise _drift(pin, f"pin 的是 {pin.revision}，manifest 現在是 {ref.revision}")
        if ref.sha1 != pin.sha1:
            # 版本號相同但 sha1 變了＝上游重新打包過。比 revision 改變更危險，
            # 因為它不會反映在任何版本號上。
            raise _drift(
                pin, f"revision {ref.revision} 相同但 sha1 不同（pin {pin.sha1}，manifest {ref.sha1}）"
            )
        if ref.size != pin.size:
            raise _drift(pin, f"revision {ref.revision} 的 size 不同（pin {pin.size}，manifest {ref.size}）")
        resolved.append((pin, ref))
    return resolved


def validate_pinned_urls(resolved: list[tuple[Pin, PackageRef]]) -> None:
    """拒絕 manifest URL 變動，與版本、checksum 和大小漂移採相同錯誤契約。"""
    for pin, ref in resolved:
        if ref.url != pin.url:
            raise _drift(pin, f"revision {ref.revision} 的 url 不同（pin {pin.url}，manifest {ref.url}）")
