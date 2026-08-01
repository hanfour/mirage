#!/usr/bin/env python3
"""Mirage 的 AVD provisioning。

用法：
    python3 provision.py              # 只報告，一行都不寫
    python3 provision.py --apply      # 另外寫 AVD 的 .ini 與 config.ini
    python3 provision.py --upgrade    # 另外覆蓋 SDK 裡的 package

缺失的東西一律直接裝（無破壞風險）；**已存在但不符**才需要旗標。
兩個旗標分開的理由：改 config.ini 的 RAM 會讓既有快照失效，換 emulator 則
影響整台機器上所有已量測的數字——後果不同級，不該由同一個旗標決定。
"""
from __future__ import annotations

import argparse
import os
import platform
import sys
import tempfile

import fetch
from lib import config_ini, drift, manifest, report, sdkpaths, versions
from lib.avdspec import SPECS

_HOST_OS = {"Darwin": "macosx", "Linux": "linux"}
_HOST_ARCH = {"arm64": "aarch64", "aarch64": "aarch64", "x86_64": "x64"}

# `_HOST_OS`／`_HOST_ARCH` 讓這支工具看起來與 host 無關，但 versions.PINS 的
# sha1 全部是 macOS ARM 的——manifest 上其他平台的封包內容不同，checksum
# 自然對不上。只涵蓋這一個平台。
SUPPORTED_HOST = ("macosx", "aarch64")


class UnsupportedHostError(Exception):
    """pin 表只涵蓋一個平台。

    不擋的話，resolve_pins 會因為 sha1 對不上而拋 PinDriftError，訊息說
    「上游重新打包過，請更新 PINS 並 commit」——照做就把 macOS 那台的 pin
    改壞了。真正的原因是「這張表不涵蓋你的平台」，訊息必須直說。
    """


def _resolve() -> list[tuple[versions.Pin, manifest.PackageRef]]:
    host_os = _HOST_OS.get(platform.system(), platform.system().lower())
    host_arch = _HOST_ARCH.get(platform.machine(), platform.machine())
    if (host_os, host_arch) != SUPPORTED_HOST:
        raise UnsupportedHostError(
            f"偵測到的平台是 {host_os}/{host_arch}，"
            f"但 tools/provision/lib/versions.py 的 PINS 只涵蓋 "
            f"{SUPPORTED_HOST[0]}/{SUPPORTED_HOST[1]}（macOS ARM）的 sha1。"
            "在其他平台上跑，resolve_pins 只會因為 checksum 對不上而報成"
            "「上游重新打包過」，照那個訊息去更新 PINS 會把 macOS 那台的"
            "pin 改壞——真正原因是這張表還沒涵蓋你的平台。"
        )
    refs = {}
    for key, url in versions.MANIFESTS.items():
        refs[key] = manifest.parse_manifest(
            fetch.fetch_text(url),
            versions.MANIFEST_BASES[key],
            host_os=host_os,
            host_arch=host_arch,
        )
    return versions.resolve_pins(refs)


def _sdk_rows(sdk_root: str, resolved, upgrade: bool, cache: str) -> list[report.Row]:
    rows = []
    for pin, ref in resolved:
        installed = fetch.installed_revision(sdk_root, pin.install_path)
        difference = drift.package_drift(pin.path, installed, pin.revision)
        if difference is None:
            rows.append(report.Row(pin.path, True, pin.revision, ""))
            continue
        # 沒裝＝直接裝，無破壞風險；已裝但不符＝需要 --upgrade。
        may_write = installed is None or upgrade
        if may_write:
            zip_path = os.path.join(cache, os.path.basename(ref.url))
            if not os.path.exists(zip_path):
                fetch.download(ref.url, zip_path, ref.sha1, ref.size)
            fetch.extract_into(zip_path, os.path.join(sdk_root, pin.install_path))
            # 記下我們裝的版本：Google 的原始 zip 不含 package.xml，沒有這一步
            # installed_revision 對這個 package 永遠回「無從追溯」，下一次跑
            # 會把剛裝好的東西誤判成漂移（2026-08-02 真下載驗證時發現）。
            fetch.record_installed(sdk_root, pin.install_path, pin.revision)
            rows.append(report.Row(pin.path, True, f"已安裝 {pin.revision}", ""))
        else:
            shown = "版本無從追溯" if installed == "" else installed
            rows.append(
                report.Row(pin.path, False, f"{shown} ≠ {pin.revision}", "--upgrade 可更新")
            )
    return rows


def _avd_rows(avd_home: str, apply_changes: bool) -> list[report.Row]:
    rows = []
    for spec in SPECS:
        avd_dir = os.path.join(avd_home, spec.name + ".avd")
        config_path = os.path.join(avd_dir, "config.ini")
        pointer_path = os.path.join(avd_home, spec.name + ".ini")

        # `exists`（是否需要 --apply 才能改）刻意只看 config.ini，不是兩者
        # AND：config.ini 帶著 RAM 之類會讓既有快照失效的設定，「已存在但
        # 不符才需要旗標」保護的正是它。若改成兩者都要存在才算 exists，
        # 使用者只是不小心少了指標檔、config.ini 本身還帶著手動調過的合法
        # 差異，也會被當成「全新 AVD」直接覆寫，繞過那道保護。指標檔本身
        # 沒有這個風險（覆寫它不會讓快照失效），但它的缺失/錯誤仍要算進
        # 漂移清單，只是走「需要 --apply」那條路，不是無條件自動建立。
        config_exists = os.path.isfile(config_path)
        pointer_exists = os.path.isfile(pointer_path)
        exists = config_exists

        current_config = {}
        if config_exists:
            with open(config_path, encoding="utf-8") as handle:
                current_config = config_ini.parse_config(handle.read())
        config_diffs = drift.config_drift(current_config, config_ini.expected_config(spec))

        current_pointer = {}
        if pointer_exists:
            with open(pointer_path, encoding="utf-8") as handle:
                # 指標檔沒有空格，但 parse_config 兩種形式都容忍，可以共用。
                current_pointer = config_ini.parse_config(handle.read())
        expected_pointer = config_ini.parse_config(
            config_ini.render_pointer_ini(spec, avd_home)
        )
        # key 前綴避免跟 config.ini 撞名（兩邊都有 avd.ini.encoding／target）：
        # 合併後的漂移清單要讓人一眼看出哪個 key 屬於哪個檔案。
        pointer_diffs = [
            drift.Diff(key=f"{spec.name}.ini:{d.key}", current=d.current, expected=d.expected)
            for d in drift.config_drift(current_pointer, expected_pointer)
        ]

        diffs = config_diffs + pointer_diffs
        if not diffs:
            rows.append(report.Row(spec.name, True, "符合", ""))
            continue
        if not exists or apply_changes:
            os.makedirs(avd_dir, exist_ok=True)
            with open(config_path, "w", encoding="utf-8") as handle:
                handle.write(config_ini.render_config(spec))
            with open(pointer_path, "w", encoding="utf-8") as handle:
                handle.write(config_ini.render_pointer_ini(spec, avd_home))
            rows.append(report.Row(spec.name, True, "已建立" if not exists else "已修正", ""))
            continue
        head = "；".join(
            f"{d.key} {d.current!r}→{d.expected!r}" for d in diffs[:3]
        )
        more = f"（共 {len(diffs)} 項）" if len(diffs) > 3 else ""
        rows.append(report.Row(spec.name, False, head + more, "--apply 可修正"))
    return rows


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="建立 Mirage 的 Android SDK 與兩台 AVD")
    parser.add_argument("--apply", action="store_true", help="覆寫已存在但不符的 AVD 設定")
    parser.add_argument("--upgrade", action="store_true", help="覆蓋已安裝但版本不符的 SDK package")
    parser.add_argument("--sdk-root", default=None)
    parser.add_argument("--avd-home", default=None)
    args = parser.parse_args(argv)

    home = os.path.expanduser("~")
    sdk_root = args.sdk_root or sdkpaths.sdk_root(dict(os.environ), home)
    avd_home = args.avd_home or sdkpaths.avd_home(dict(os.environ), home)

    try:
        resolved = _resolve()
    except (
        fetch.FetchError,
        manifest.ManifestError,
        versions.PinDriftError,
        UnsupportedHostError,
    ) as error:
        print(f"錯誤：{error}", file=sys.stderr)
        return 2

    cache = os.path.join(tempfile.gettempdir(), "mirage-provision-cache")
    try:
        os.makedirs(cache, exist_ok=True)
        sdk_rows = _sdk_rows(sdk_root, resolved, args.upgrade, cache)
        avd_rows = _avd_rows(avd_home, args.apply)
    except (fetch.FetchError, OSError) as error:
        # 連 OSError 一起接，是為了讓退出碼契約真的成立。_avd_rows 完全不碰
        # fetch，它寫 config.ini 時的 PermissionError（唯讀家目錄、CI sandbox）
        # 原本沒有任何 except 接得到，會以 raw traceback + exit 1 結束——而 1 在
        # 契約裡的意思是「有漂移」，且那時一份報表都還沒印出來。只看退出碼的
        # 自動化會把「權限炸掉」讀成「有漂移」。
        print(f"錯誤：{error}", file=sys.stderr)
        return 2

    print(report.format_report(f"SDK: {sdk_root}", sdk_rows), end="")
    print(report.format_report(f"AVD: {avd_home}", avd_rows), end="")
    return report.exit_code(sdk_rows + avd_rows)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
