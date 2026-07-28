#!/usr/bin/env python3
"""模擬器驗證探針。設計見 docs/specs/2026-07-28-emulator-probe-cli-design.md。

**永遠不會呼叫 screencapture** —— 畫面只從 adb 或 gRPC 取得。理由見設計文件 §4。
"""
import argparse
import sys
import time

import _bootstrap  # noqa: F401  設定 sys.path 讓 lib/ 與 gen/ 可 import

from lib import adb, coords, emulator, gesture, imgdiff, launch, overlay_state, png
from lib.targets import TARGETS, resolve_target

# 標籤描述**取得畫面的路徑**，不宣稱畫面內容有什麼差別。
# 先前這裡印的是「(含系統 overlay)」/「(不含 overlay)」——2026-07-28 實測推翻：
# adb screencap 一樣含 pointer_location 疊層（見 lib/imgdiff.py 的說明）。
# 工具只講它剛剛量到的東西；內容差異交給 compare 真的比一次再報告。
GRPC_LABEL = "grpc: getScreenshot"
ADB_LABEL = "adb: exec-out screencap"


def _write_png(path: str, width: int, height: int, rgba: bytes) -> int:
    """寫檔並回傳實際位元組數。兩條路徑共用同一支 encoder，檔案大小才可比。"""
    data = png.encode_rgba(width, height, rgba)
    with open(path, "wb") as f:
        f.write(data)
    return len(data)


def cmd_fg(target, args) -> int:
    fg = adb.foreground_activity(target.serial)
    print(fg if fg else "(查不到前景 activity)")
    return 0


def cmd_shot(target, args) -> int:
    if args.via == "adb":
        label = ADB_LABEL
        w, h, rgba = adb.screencap_rgba(target.serial)
    else:
        label = GRPC_LABEL
        with emulator.connect(target.grpc_port) as emu:
            w, h, rgba = emu.screenshot()
    size = _write_png(args.out, w, h, rgba)
    print(f"{label} → {args.out}  {w}x{h}  {size} bytes")
    return 0


def cmd_compare(target, args) -> int:
    """兩條路徑各抓一張，並**實際比對**兩者的像素。

    這不是便利包裝——2026-07-28 三個關鍵突破都來自兩條路徑的對照。但它的價值
    不在設計文件原本宣稱的地方（「adb 不含疊層、gRPC 含」，已被實測推翻），
    所以這裡不再印任何關於內容差異的信念，改成量一次再說：尺寸是否相同、
    有沒有像素差異、差在哪些列。
    """
    grpc_out, adb_out = f"{args.prefix}-grpc.png", f"{args.prefix}-adb.png"
    started = time.monotonic()
    with emulator.connect(target.grpc_port) as emu:
        gw, gh, grpc_rgba = emu.screenshot()
    aw, ah, adb_rgba = adb.screencap_rgba(target.serial)
    span = time.monotonic() - started

    grpc_size = _write_png(grpc_out, gw, gh, grpc_rgba)
    adb_size = _write_png(adb_out, aw, ah, adb_rgba)
    print(f"{GRPC_LABEL} → {grpc_out}  {gw}x{gh}  {grpc_size} bytes")
    print(f"{ADB_LABEL} → {adb_out}  {aw}x{ah}  {adb_size} bytes")
    if (gw, gh) != (aw, ah):
        print(f"diff: 尺寸不同（{gw}x{gh} vs {aw}x{ah}），不比對像素")
    else:
        print(f"diff: {imgdiff.describe(imgdiff.compare_rows(grpc_rgba, adb_rgba, gw, gh))}")
    print(f"note: 兩張圖非同時抓取（前後相隔 {span:.1f}s 內），畫面在動時內容本來就會不同")
    return 0


def cmd_overlay(target, args) -> int:
    key = "pointer_location"
    if args.action == "on":
        current = adb.get_setting(target.serial, key)
        if overlay_state.should_record(current):
            overlay_state.save_original(target.name, current)
            print(f"overlay on (已記錄原值 {current!r}，restore 會設回 "
                  f"{overlay_state.restore_value(current)})")
        else:
            print("overlay on (疊層本來就開著，不覆寫先前記錄的原值)")
        adb.put_setting(target.serial, key, overlay_state.ON)
    elif args.action == "off":
        adb.put_setting(target.serial, key, overlay_state.OFF)
        print("overlay off")
    else:
        original = overlay_state.load_original(target.name)
        if original is None:
            print("no saved state — no-op")
            return 0
        value = overlay_state.restore_value(original)
        adb.put_setting(target.serial, key, value)
        print(f"overlay restored to {value}")
    return 0


def cmd_tap(target, args) -> int:
    with emulator.connect(target.grpc_port) as emu:
        w, h = emu.display_size()
        x, y = coords.to_guest_pixel(args.nx, args.ny, w, h)
        emu.send_tap(x, y)
    print(f"tap ({args.nx}, {args.ny}) → guest ({x}, {y})  [{w}x{h}]")
    return 0


def cmd_swipe(target, args) -> int:
    # 換算與內插都在連線之前做完：參數不合法時不必先開一條 gRPC channel，
    # 也不會有「已經送出 down 才發現 ms 是負的」這種局面。
    steps, step_ms = gesture.swipe_plan(args.ms)
    norm = coords.lerp_path((args.nx1, args.ny1), (args.nx2, args.ny2), steps)
    with emulator.connect(target.grpc_port) as emu:
        w, h = emu.display_size()
        path = [coords.to_guest_pixel(nx, ny, w, h) for nx, ny in norm]
        emu.send_swipe(path, step_ms=step_ms)
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
        # 每一條指令都需要裝置在線（gRPC 那幾條也是——模擬器沒起來時 gRPC 只會
        # 給出 UNAVAILABLE，看不出是「裝置沒開」還是「port 錯了」）。統一在這裡
        # 檢查一次，取代先前散在 5 個 handler 裡、而且漏了 3 個的重複呼叫。
        adb.ensure_online(target.serial)
        return handlers[args.command](target, args)
    except (adb.AdbError, emulator.EmulatorError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
