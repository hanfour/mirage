#!/usr/bin/env python3
"""模擬器驗證探針。設計見 docs/specs/2026-07-28-emulator-probe-cli-design.md。

**永遠不會呼叫 screencapture** —— 畫面只從 adb 或 gRPC 取得。理由見設計文件 §4。
"""
import argparse
import sys

import _bootstrap  # noqa: F401  設定 sys.path 讓 lib/ 與 gen/ 可 import

from lib import adb, emulator, overlay_state, png
from lib.targets import TARGETS, resolve_target


def cmd_fg(target, args) -> int:
    adb.ensure_online(target.serial)
    fg = adb.foreground_activity(target.serial)
    print(fg if fg else "(查不到前景 activity)")
    return 0


def cmd_shot(target, args) -> int:
    if args.via == "adb":
        adb.ensure_online(target.serial)
        data = adb.screencap_png(target.serial)
        with open(args.out, "wb") as f:
            f.write(data)
        aw, ah = png.read_size(data)
        print(f"adb → {args.out}  {aw}x{ah}  (不含 overlay)")
    else:
        with emulator.connect(target.grpc_port) as emu:
            w, h, rgba = emu.screenshot()
        with open(args.out, "wb") as f:
            f.write(png.encode_rgba(w, h, rgba))
        print(f"grpc → {args.out}  {w}x{h}  (含系統 overlay)")
    return 0


def cmd_compare(target, args) -> int:
    """同時抓兩條路徑。這不是便利包裝——2026-07-28 三個關鍵突破都來自兩者對照。"""
    adb.ensure_online(target.serial)
    grpc_out, adb_out = f"{args.prefix}-grpc.png", f"{args.prefix}-adb.png"
    with emulator.connect(target.grpc_port) as emu:
        w, h, rgba = emu.screenshot()
    with open(grpc_out, "wb") as f:
        f.write(png.encode_rgba(w, h, rgba))
    adb_png = adb.screencap_png(target.serial)
    with open(adb_out, "wb") as f:
        f.write(adb_png)
    aw, ah = png.read_size(adb_png)
    print(f"grpc → {grpc_out}  {w}x{h}  (含系統 overlay)")
    print(f"adb  → {adb_out}   {aw}x{ah}  (不含 overlay)")
    return 0


def cmd_overlay(target, args) -> int:
    adb.ensure_online(target.serial)
    key = "pointer_location"
    if args.action == "on":
        original = adb.get_setting(target.serial, key)
        overlay_state.save_original(target.name, original)
        adb.put_setting(target.serial, key, "1")
        print(f"overlay on (原值 {original or 'null'} 已記錄)")
    elif args.action == "off":
        adb.put_setting(target.serial, key, "0")
        print("overlay off")
    else:
        original = overlay_state.load_original(target.name)
        if original is None:
            print("no saved state — no-op")
            return 0
        value = "0" if original in ("", "null") else original
        adb.put_setting(target.serial, key, value)
        print(f"overlay restored to {value}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="probe.py", description=__doc__)
    p.add_argument("--target", required=True, choices=sorted(TARGETS),
                   help="; ".join(f"{n}: {t.note}" for n, t in TARGETS.items()))
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("fg", help="印目前前景 activity")

    p_shot = sub.add_parser("shot", help="抓畫面（預設 grpc）")
    p_shot.add_argument("out")
    p_shot.add_argument("--via", choices=("grpc", "adb"), default="grpc")

    p_cmp = sub.add_parser("compare", help="同時抓 grpc 與 adb 兩條路徑")
    p_cmp.add_argument("prefix")

    p_ovl = sub.add_parser("overlay", help="pointer_location 疊層")
    p_ovl.add_argument("action", choices=("on", "off", "restore"))
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    target = resolve_target(args.target)
    handlers = {"fg": cmd_fg, "shot": cmd_shot, "compare": cmd_compare,
                "overlay": cmd_overlay}
    try:
        return handlers[args.command](target, args)
    except (adb.AdbError, emulator.EmulatorError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
