#!/usr/bin/env python3
"""D2 前置量測：KeyboardEvent 的三條路徑，哪一條真的把鍵送進 guest。

**儀器選擇**：用 `adb shell getevent -l` 直接讀 guest kernel 的 evdev 事件流，
而不是「開個文字框打字看看有沒有字」。理由是後者是**代理指標**——沒出現字可能是
鍵沒送到、可能是焦點不在輸入框、可能是輸入法沒起來，三種原因看起來一模一樣。
getevent 觀察的是「鍵有沒有到達 guest」這件事本身。

proto 對三條路徑的說明（emulator_controller.proto）：
  - `key`：W3C KeyboardEvent.key 字串。**只保證可列印 ASCII [32,127) 被正確翻譯**，
    且「Not all documented keys are understood by android」。
  - `keyCode` + `codeType`：送實體鍵碼，由 emulator 走 chromium 對照表翻成 evdev。
    codeType 支援 .mac（= macOS 虛擬鍵碼），設了 keyCode 就會忽略 key 與 text。
  - `text`：整串 utf8，忽略其他欄位。

輸出只講量到的東西：每個 (鍵, 路徑) 組合有沒有在 getevent 裡看到對應的 EV_KEY。
"""
import os
from pathlib import Path
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import _bootstrap  # noqa: F401

import emulator_controller_pb2 as pb
import emulator_controller_pb2_grpc as pbg
from lib.grpc_auth import open_channel

ADB = os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")
SERIAL = "emulator-5558"      # bench：三台裡最不寶貴的，poc 是共享實例不碰
PORT = 8558

# (標籤, W3C key, macOS 虛擬鍵碼, 期待在 getevent 看到的 evdev 名稱)
# mac 虛擬鍵碼來源：Carbon HIToolbox Events.h（kVK_*）
CASES = [
    ("a",         "a",         0,   "KEY_A"),
    ("Enter",     "Enter",     36,  "KEY_ENTER"),
    ("Backspace", "Backspace", 51,  "KEY_BACKSPACE"),
    ("Tab",       "Tab",       48,  "KEY_TAB"),
    ("Escape",    "Escape",    53,  "KEY_ESC"),
    ("ArrowUp",   "ArrowUp",   126, "KEY_UP"),
    ("Space",     " ",         49,  "KEY_SPACE"),
    # Android 專屬值：proto 明列，只有 key 路徑有意義（mac 鍵碼沒有對應物）
    ("GoBack",    "GoBack",    None, "KEY_BACK"),
    ("GoHome",    "GoHome",    None, "KEY_HOME"),
    ("AppSwitch", "AppSwitch", None, "KEY_APPSELECT"),
]


def send_via_key(stub, w3c: str) -> None:
    for et in (pb.KeyboardEvent.keydown, pb.KeyboardEvent.keyup):
        stub.sendKey(pb.KeyboardEvent(eventType=et, key=w3c))


def send_via_keycode(stub, code: int) -> None:
    for et in (pb.KeyboardEvent.keydown, pb.KeyboardEvent.keyup):
        stub.sendKey(pb.KeyboardEvent(eventType=et,
                                      codeType=pb.KeyboardEvent.KeyCodeType.Value("Mac"),
                                      keyCode=code))


def capture(fn, seconds: float = 1.5) -> str:
    """開 getevent、跑 fn、關掉，回傳這段期間的事件文字。"""
    proc = subprocess.Popen([ADB, "-s", SERIAL, "shell", "getevent", "-l"],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    time.sleep(0.8)                      # 讓 getevent 真的開始讀
    try:
        fn()
        time.sleep(seconds)
    finally:
        proc.kill()
    out, _ = proc.communicate(timeout=5)
    return out or ""


def main() -> int:
    if subprocess.run([ADB, "-s", SERIAL, "get-state"],
                      capture_output=True, text=True).stdout.strip() != "device":
        print(f"{SERIAL} 不在線，中止（不編造結果）")
        return 1

    rows = []
    with open_channel(PORT) as ch:
        stub = pbg.EmulatorControllerStub(ch)
        for label, w3c, mac, expect in CASES:
            got_key = expect in capture(lambda: send_via_key(stub, w3c))
            if mac is None:
                got_code = None
            else:
                got_code = expect in capture(lambda: send_via_keycode(stub, mac))
            rows.append((label, expect, got_key, got_code))
            print(f"  {label:<10} 完成", flush=True)

    def mark(v):
        return "—" if v is None else ("✅" if v else "❌")

    print()
    print(f"{'鍵':<10} {'期待的 evdev':<16} {'key 路徑':<10} {'keyCode+.mac'}")
    print("-" * 56)
    for label, expect, a, b in rows:
        print(f"{label:<10} {expect:<16} {mark(a):<10} {mark(b)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
