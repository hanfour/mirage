#!/usr/bin/env python3
"""模擬器驗證探針。設計見 docs/specs/2026-07-28-emulator-probe-cli-design.md。

**永遠不會呼叫 screencapture** —— 畫面只從 adb 或 gRPC 取得。理由見設計文件 §4。
"""
import argparse
import sys

import _bootstrap  # noqa: F401  設定 sys.path 讓 lib/ 與 gen/ 可 import

from lib import adb
from lib.targets import TARGETS, resolve_target


def cmd_fg(target, args) -> int:
    adb.ensure_online(target.serial)
    fg = adb.foreground_activity(target.serial)
    print(fg if fg else "(查不到前景 activity)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="probe.py", description=__doc__)
    p.add_argument("--target", required=True, choices=sorted(TARGETS),
                   help="; ".join(f"{n}: {t.note}" for n, t in TARGETS.items()))
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("fg", help="印目前前景 activity")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    target = resolve_target(args.target)
    handlers = {"fg": cmd_fg}
    try:
        return handlers[args.command](target, args)
    except (adb.AdbError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
