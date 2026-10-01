#!/usr/bin/env python3
"""透過 Mirage 的測試控制 Unix socket 傳送滑鼠、捲動與鍵盤事件。"""
import argparse
import json
import socket
import sys
from pathlib import Path


def encode_request(command):
    """把一個命令編成 UTF-8 JSON 行。"""
    if not isinstance(command, dict):
        raise ValueError("命令必須是 JSON 物件")
    return (json.dumps(command, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


class MirageControlClient:
    """可在同一連線上依序交換多個 JSON 行。"""

    def __init__(self, connection):
        self.connection = connection
        self.pending = bytearray()

    def request(self, command):
        self.connection.sendall(encode_request(command))
        while b"\n" not in self.pending:
            chunk = self.connection.recv(4096)
            if not chunk:
                raise ConnectionError("控制通道在回應前關閉")
            self.pending.extend(chunk)
        line, _, remainder = self.pending.partition(b"\n")
        self.pending = bytearray(remainder)
        try:
            response = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError(f"控制通道回應不是有效 JSON：{error}") from error
        if not isinstance(response, dict) or not isinstance(response.get("ok"), bool):
            raise ValueError("控制通道回應缺少布林 ok 欄位")
        return response


def send_command(path, command, timeout=90):
    """連線、送出單一命令並解析回應。"""
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        connection.connect(str(path))
        return MirageControlClient(connection).request(command)


def _boolean(value):
    if value == "true":
        return True
    if value == "false":
        return False
    raise argparse.ArgumentTypeError("請使用 true 或 false")


def parser():
    root = argparse.ArgumentParser(description="Mirage 測試控制通道用戶端")
    root.add_argument("socket", type=Path, help="MIRAGE_TEST_CONTROL socket 路徑")
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("state", help="讀取鏡像視窗狀態")

    mouse = commands.add_parser("mouse", help="送出左鍵事件")
    mouse.add_argument("action", choices=("down", "drag", "up", "click"))
    mouse.add_argument("--x", type=float, required=True)
    mouse.add_argument("--y", type=float, required=True)
    mouse.add_argument("--unit", choices=("pt", "norm"), default="pt")

    drag = commands.add_parser("drag", help="送出滑鼠拖曳")
    drag.add_argument("--from", dest="start", nargs=2, type=float, required=True, metavar=("X", "Y"))
    drag.add_argument("--to", nargs=2, type=float, required=True, metavar=("X", "Y"))
    drag.add_argument("--steps", type=int, default=20)
    drag.add_argument("--interval-ms", type=int, default=16)
    drag.add_argument("--unit", choices=("pt", "norm"), default="pt")

    scroll = commands.add_parser("scroll", help="送出觸控板捲動手勢")
    scroll.add_argument("--x", type=float, required=True)
    scroll.add_argument("--y", type=float, required=True)
    scroll.add_argument("--dx", type=float, default=0)
    scroll.add_argument("--dy", type=float, required=True)
    scroll.add_argument("--steps", type=int, default=20)
    scroll.add_argument("--interval-ms", type=int, default=16)
    scroll.add_argument("--unit", choices=("pt", "norm"), default="pt")
    scroll.add_argument("--momentum", type=int, default=0)

    key = commands.add_parser("key", help="送出鍵盤事件")
    key.add_argument("--key-code", type=int, required=True)
    key.add_argument("--modifiers", nargs="*", choices=("cmd", "shift", "option", "control"), default=[])
    key.add_argument("--action", choices=("press", "down", "up"), default="press")

    titlebar = commands.add_parser("titlebar", help="設定標題列顯示狀態")
    titlebar.add_argument("--visible", type=_boolean, required=True)

    fullscreen = commands.add_parser("fullscreen", help="切換全螢幕")
    fullscreen.add_argument("--on", type=_boolean, required=True)
    return root


def command_from_args(args):
    if args.command == "state":
        return {"cmd": "state"}
    if args.command == "mouse":
        return {"cmd": "mouse", "action": args.action, "x": args.x, "y": args.y, "unit": args.unit}
    if args.command == "drag":
        return {"cmd": "drag", "from": {"x": args.start[0], "y": args.start[1]},
                "to": {"x": args.to[0], "y": args.to[1]}, "steps": args.steps,
                "interval_ms": args.interval_ms, "unit": args.unit}
    if args.command == "scroll":
        return {"cmd": "scroll", "x": args.x, "y": args.y, "dx": args.dx, "dy": args.dy,
                "steps": args.steps, "interval_ms": args.interval_ms,
                "unit": args.unit, "momentum": args.momentum}
    if args.command == "key":
        return {"cmd": "key", "keyCode": args.key_code, "modifiers": args.modifiers,
                "action": args.action}
    if args.command == "titlebar":
        return {"cmd": "titlebar", "visible": args.visible}
    if args.command == "fullscreen":
        return {"cmd": "fullscreen", "on": args.on}
    raise ValueError(f"未知命令：{args.command}")


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        response = send_command(args.socket, command_from_args(args))
    except (OSError, ValueError, ConnectionError) as error:
        print(f"錯誤：{error}", file=sys.stderr)
        return 2
    print(json.dumps(response, ensure_ascii=False, separators=(",", ":")))
    if not response["ok"]:
        print(response.get("error", "控制命令失敗"), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
