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


def _resolve() -> list[tuple[versions.Pin, manifest.PackageRef]]:
    host_os = _HOST_OS.get(platform.system(), platform.system().lower())
    host_arch = _HOST_ARCH.get(platform.machine(), platform.machine())
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
        exists = os.path.isfile(config_path)
        current = {}
        if exists:
            with open(config_path, encoding="utf-8") as handle:
                current = config_ini.parse_config(handle.read())
        diffs = drift.config_drift(current, config_ini.expected_config(spec))
        if not diffs:
            rows.append(report.Row(spec.name, True, "符合", ""))
            continue
        if not exists or apply_changes:
            os.makedirs(avd_dir, exist_ok=True)
            with open(config_path, "w", encoding="utf-8") as handle:
                handle.write(config_ini.render_config(spec))
            pointer = os.path.join(avd_home, spec.name + ".ini")
            with open(pointer, "w", encoding="utf-8") as handle:
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
    except (fetch.FetchError, manifest.ManifestError, versions.PinDriftError) as error:
        print(f"錯誤：{error}", file=sys.stderr)
        return 2

    cache = os.path.join(tempfile.gettempdir(), "mirage-provision-cache")
    os.makedirs(cache, exist_ok=True)
    try:
        sdk_rows = _sdk_rows(sdk_root, resolved, args.upgrade, cache)
        avd_rows = _avd_rows(avd_home, args.apply)
    except fetch.FetchError as error:
        print(f"錯誤：{error}", file=sys.stderr)
        return 2

    print(report.format_report(f"SDK: {sdk_root}", sdk_rows), end="")
    print(report.format_report(f"AVD: {avd_home}", avd_rows), end="")
    return report.exit_code(sdk_rows + avd_rows)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
