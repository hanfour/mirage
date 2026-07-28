#!/usr/bin/env python3
"""模擬器驗證探針。設計見 docs/specs/2026-07-28-emulator-probe-cli-design.md。

**永遠不會呼叫 screencapture** —— 畫面只從 adb 或 gRPC 取得。理由見設計文件 §4。
"""
import argparse
import sys

import _bootstrap  # noqa: F401  設定 sys.path 讓 lib/ 與 gen/ 可 import

from lib import adb, coords, emulator, launch, overlay_state, png
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


def cmd_tap(target, args) -> int:
    with emulator.connect(target.grpc_port) as emu:
        w, h = emu.display_size()
        x, y = coords.to_guest_pixel(args.nx, args.ny, w, h)
        emu.send_touch(x, y, down=True)
        emu.send_touch(x, y, down=False)
    print(f"tap ({args.nx}, {args.ny}) → guest ({x}, {y})  [{w}x{h}]")
    return 0


def cmd_swipe(target, args) -> int:
    with emulator.connect(target.grpc_port) as emu:
        w, h = emu.display_size()
        steps = max(2, args.ms // 20)
        norm = coords.lerp_path((args.nx1, args.ny1), (args.nx2, args.ny2), steps)
        path = [coords.to_guest_pixel(nx, ny, w, h) for nx, ny in norm]
        emu.send_swipe(path, step_ms=args.ms // steps)
    print(f"swipe ({args.nx1},{args.ny1}) → ({args.nx2},{args.ny2}) "
          f"guest {path[0]} → {path[-1]}  {steps} 點 / {args.ms}ms")
    return 0


def cmd_launch(target, args) -> int:
    """啟動並輪詢至前景確認。逾時 30 秒。

    **只確認 activity 到前景，不等遊戲載完。** Pixel Flow 在 game 機上光是過
    splash 就要好幾分鐘——2026-07-28 那輪 45 秒還在 splash，差點被當成卡死。

    輪詢／逾時／前綴比對的邏輯在 lib.launch.poll_until_foreground（測試見
    tests/test_launch.py）；這裡只負責組裝真正的 adb 呼叫與時鐘餵進去。
    """
    adb.ensure_online(target.serial)
    if not target.playable:
        print(f"warning: target {target.name!r} — {target.note}", file=sys.stderr)
    adb.start_package(target.serial, args.package)

    ok, fg, elapsed = launch.poll_until_foreground(
        check_fn=lambda: adb.foreground_activity(target.serial),
        match_prefix=args.package,
    )
    if ok:
        print(f"launched, foreground={fg} ({elapsed:.1f}s)")
        return 0

    print(f"error: {args.package} 未在 30s 內到前景；目前前景={fg or '(查不到)'}",
          file=sys.stderr)
    return 1


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

    p_tap = sub.add_parser("tap", help="normalized 座標點擊")
    p_tap.add_argument("nx", type=float)
    p_tap.add_argument("ny", type=float)

    p_swp = sub.add_parser("swipe", help="normalized 座標拖曳")
    for name in ("nx1", "ny1", "nx2", "ny2"):
        p_swp.add_argument(name, type=float)
    p_swp.add_argument("ms", type=int, nargs="?", default=300)

    p_launch = sub.add_parser("launch", help="啟動套件並等到前景確認")
    p_launch.add_argument("package")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    target = resolve_target(args.target)
    handlers = {"fg": cmd_fg, "shot": cmd_shot, "compare": cmd_compare,
                "overlay": cmd_overlay, "tap": cmd_tap, "swipe": cmd_swipe,
                "launch": cmd_launch}
    try:
        return handlers[args.command](target, args)
    except (adb.AdbError, emulator.EmulatorError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
