# emulator probe CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一支 CLI，讓 Claude session 能自行完成「開遊戲 → 操作 → 抓畫面 → 判斷」的驗證迴圈，取代目前「等使用者親自點一次並回報」的來回。

**Architecture:** Python CLI，純邏輯放 `lib/`（可單元測試）、I/O 放各自的 adapter。畫面有兩條取得路徑（gRPC 與 adb），刻意都保留——兩者的差異本身就是診斷資訊。重用 `phase0/harness` 已生成的 pb2 與 venv，不重新生成。

**Tech Stack:** Python 3.13、grpcio、pytest。全部沿用 `phase0/harness/.venv`。

## Global Constraints

以下全部來自 `docs/specs/2026-07-28-emulator-probe-cli-design.md`，每個 Task 都適用：

- **永不呼叫 `screencapture`**。畫面只能從 adb 或 gRPC 取得。
- **`--target` 無預設值**，未指定即報錯退出。
- **不提供 `getevent`** 相關功能。
- **座標一律 normalized（0–1，左上原點）**，與 `EmulatorClient.sendTap(nx:ny:)` 同語意。
- **`shot` 一律抓 guest 實體解析度**，不提供 `--width/--height`。
- 純邏輯模組放 `tools/probe/lib/`，測試放 `tools/probe/tests/`，比照 `phase0/harness` 既有慣例（pytest、`@dataclass(frozen=True)`、中文 docstring）。
- 所有指令一律用 `phase0/harness/.venv/bin/python` 執行。

## 檔案結構

| 檔案 | 責任 |
|---|---|
| `tools/probe/probe.py` | CLI 進入點：argparse + dispatch。不含業務邏輯。 |
| `tools/probe/_bootstrap.py` | 設定 `sys.path` 指向 `phase0/harness/gen`，讓 pb2 可 import。 |
| `tools/probe/lib/targets.py` | **純**：target 名稱 → device/port。 |
| `tools/probe/lib/coords.py` | **純**：normalized → guest 像素。 |
| `tools/probe/lib/png.py` | **純**：RGBA bytes → PNG bytes。 |
| `tools/probe/lib/adb.py` | adb 操作（前景、screencap、settings、啟動）。 |
| `tools/probe/lib/emulator.py` | gRPC 操作（getStatus、getScreenshot、sendTouch）。 |
| `tools/probe/lib/overlay_state.py` | 疊層原值的狀態檔讀寫。 |
| `tools/probe/tests/test_*.py` | 對應的單元測試。 |

---

### Task 1: CLI 骨架 + target 解析 + `fg`

**Files:**
- Create: `tools/probe/lib/targets.py`
- Create: `tools/probe/lib/adb.py`
- Create: `tools/probe/probe.py`
- Test: `tools/probe/tests/test_targets.py`

**Interfaces:**
- Produces: `Target(name: str, serial: str, grpc_port: int, playable: bool)`；`resolve_target(name: str) -> Target`（未知名稱 raise `ValueError`）；`TARGETS: dict[str, Target]`
- Produces: `adb_path() -> str`；`foreground_activity(serial: str) -> str | None`；`AdbError`

- [ ] **Step 1: 寫會紅的測試**

`tools/probe/tests/test_targets.py`：

```python
import pytest

from lib.targets import TARGETS, resolve_target


def test_resolves_three_known_targets():
    assert resolve_target("game").serial == "emulator-5556"
    assert resolve_target("game").grpc_port == 8556
    assert resolve_target("bench").serial == "emulator-5558"
    assert resolve_target("bench").grpc_port == 8558
    assert resolve_target("poc").serial == "emulator-5554"
    assert resolve_target("poc").grpc_port == 8554


def test_only_game_is_playable():
    """bench 是 AOSP 無 Google 帳號，遊戲會卡在載入畫面；poc 是共享實例。
    這個旗標存在的唯一理由是 2026-07-28 那次在 bench 上測了整輪「能不能玩」。"""
    assert resolve_target("game").playable is True
    assert resolve_target("bench").playable is False
    assert resolve_target("poc").playable is False


def test_unknown_target_raises_with_valid_names():
    with pytest.raises(ValueError) as e:
        resolve_target("nope")
    for name in TARGETS:
        assert name in str(e.value)


def test_targets_are_immutable():
    with pytest.raises(Exception):
        resolve_target("game").serial = "x"
```

- [ ] **Step 2: 執行測試確認失敗**

```bash
cd /Users/hanfourhuang/Projects/mirage/tools/probe && \
  /Users/hanfourhuang/Projects/mirage/phase0/harness/.venv/bin/python -m pytest tests/test_targets.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'lib'`

- [ ] **Step 3: 實作 `lib/targets.py`**

```python
"""模擬器 target 的解析。純資料、無 I/O。

三台機器用途完全不同，混用會得到錯誤結論——2026-07-28 那輪照
verify_game_fps.sh 的預設用了 bench 機測「能不能玩」，測完整輪才發現那台
沒有 Google 帳號、遊戲根本進不去。所以 CLI 不給預設值，一律顯式指定。
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class Target:
    name: str
    serial: str
    grpc_port: int
    playable: bool
    note: str


TARGETS: dict[str, Target] = {
    "game": Target("game", "emulator-5556", 8556, True,
                   "Play Store 已登入 — 唯一能實際玩遊戲的機器"),
    "bench": Target("bench", "emulator-5558", 8558, False,
                    "AOSP 無 Google 帳號 — 只能量效能，遊戲會卡在載入畫面"),
    "poc": Target("poc", "emulator-5554", 8554, False,
                  "共享實例 — 不得殺／重啟"),
}


def resolve_target(name: str) -> Target:
    try:
        return TARGETS[name]
    except KeyError:
        valid = ", ".join(f"{n} ({t.note})" for n, t in TARGETS.items())
        raise ValueError(f"未知的 target {name!r}。可用：{valid}") from None
```

- [ ] **Step 4: 執行測試確認通過**

```bash
cd /Users/hanfourhuang/Projects/mirage/tools/probe && \
  /Users/hanfourhuang/Projects/mirage/phase0/harness/.venv/bin/python -m pytest tests/test_targets.py -v
```

Expected: PASS（4 passed）

- [ ] **Step 5: 實作 `lib/adb.py`**

```python
"""adb 操作封裝。所有需要 guest 端狀態或系統設定的動作走這裡。"""
import os
import subprocess


class AdbError(RuntimeError):
    pass


def adb_path() -> str:
    """與 AdbClient.standard() 相同的推導順序。"""
    sdk = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME") \
        or os.path.expanduser("~/Library/Android/sdk")
    path = os.path.join(sdk, "platform-tools", "adb")
    if not os.access(path, os.X_OK):
        raise AdbError(f"找不到可執行的 adb：{path}")
    return path


def run(serial: str, args: list[str], timeout: float = 20.0) -> str:
    proc = subprocess.run([adb_path(), "-s", serial, *args],
                          capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise AdbError(f"adb {' '.join(args)} 失敗：{proc.stderr.strip()}")
    return proc.stdout


def ensure_online(serial: str) -> None:
    proc = subprocess.run([adb_path(), "-s", serial, "get-state"],
                          capture_output=True, text=True, timeout=10)
    if proc.returncode != 0 or proc.stdout.strip() != "device":
        raise AdbError(f"device {serial} offline (adb devices 看看)")


def foreground_activity(serial: str) -> str | None:
    out = run(serial, ["shell", "dumpsys", "activity", "activities"], timeout=25)
    for line in out.splitlines():
        if "topResumedActivity" in line:
            parts = line.strip().split()
            for p in parts:
                if "/" in p:
                    return p
    return None
```

- [ ] **Step 6: 實作 `probe.py`（只含 `fg`）**

```python
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
```

`tools/probe/_bootstrap.py`：

```python
"""讓 lib/ 與 phase0/harness/gen/ 可以被 import。

⚠️ 刻意接受的暫時耦合：phase0/harness 實質上已經是本專案的 gRPC 工具箱，
`phase0` 只是歷史名稱。它哪天搬家，這個檔案要跟著改。
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_HARNESS = os.path.abspath(os.path.join(_HERE, "..", "..", "phase0", "harness"))

for path in (_HERE, os.path.join(_HARNESS, "gen"), _HARNESS):
    if path not in sys.path:
        sys.path.insert(0, path)
```

- [ ] **Step 7: 活體驗證**

```bash
cd /Users/hanfourhuang/Projects/mirage/tools/probe
PY=/Users/hanfourhuang/Projects/mirage/phase0/harness/.venv/bin/python
$PY probe.py --target game fg
$PY probe.py --target nope fg   # 應報錯退出，且列出三個可用名稱
$PY probe.py fg                 # 應報錯：--target 為必填
```

Expected: 第一行印出前景 activity；第二、三行非零退出並給出可讀訊息。

- [ ] **Step 8: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add tools/probe
git commit -m "feat(probe): CLI 骨架與 target 解析

三台模擬器用途不同且混用會得到錯誤結論（2026-07-28 那輪在 bench 機上測了
整輪「能不能玩」才發現那台沒 Google 帳號），故 --target 無預設值、必填。"
```

---

### Task 2: 抓幀（`shot` / `compare`）與疊層（`overlay`）

**Files:**
- Create: `tools/probe/lib/png.py`
- Create: `tools/probe/lib/emulator.py`
- Create: `tools/probe/lib/overlay_state.py`
- Modify: `tools/probe/lib/adb.py`（新增 `screencap_png`、`get_setting`、`put_setting`）
- Modify: `tools/probe/probe.py`（新增三個子指令）
- Test: `tools/probe/tests/test_png.py`
- Test: `tools/probe/tests/test_overlay_state.py`

**Interfaces:**
- Consumes: `lib.targets.Target`、`lib.adb.run/ensure_online/AdbError`
- Produces: `lib.png.encode_rgba(width: int, height: int, rgba: bytes) -> bytes`；`lib.png.read_size(data: bytes) -> tuple[int, int]`
- Produces: `lib.emulator.connect(port: int)`（context manager，yield `Emulator`）；`Emulator.display_size() -> tuple[int, int]`；`Emulator.screenshot() -> tuple[int, int, bytes]`；`EmulatorError`
- Produces: `lib.overlay_state.state_path(target_name: str) -> str`；`save_original(target_name, value) -> None`；`load_original(target_name) -> str | None`

- [ ] **Step 1: 寫會紅的測試（PNG 編碼）**

`tools/probe/tests/test_png.py`：

```python
import struct
import zlib

from lib.png import encode_rgba


def _chunks(data: bytes):
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, out = 8, []
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        out.append((ctype, body))
        pos += 12 + length
    return out


def test_writes_valid_png_header_and_dimensions():
    png = encode_rgba(2, 3, b"\xff\x00\x00\xff" * 6)
    ctypes = [c for c, _ in _chunks(png)]
    assert ctypes[0] == b"IHDR"
    assert ctypes[-1] == b"IEND"
    ihdr = dict(_chunks(png))[b"IHDR"]
    width, height, depth, color = struct.unpack(">IIBB", ihdr[:10])
    assert (width, height, depth, color) == (2, 3, 8, 6)   # 8-bit RGBA


def test_roundtrips_pixels():
    """左上紅、右下藍，解回來要一模一樣——scanline filter byte 若漏掉會整張錯位。"""
    rgba = bytes([255, 0, 0, 255] + [0, 0, 255, 255])
    png = encode_rgba(2, 1, rgba)
    idat = b"".join(b for c, b in _chunks(png) if c == b"IDAT")
    raw = zlib.decompress(idat)
    assert raw[0] == 0          # 每列開頭的 filter type
    assert raw[1:] == rgba


def test_rejects_wrong_buffer_length():
    try:
        encode_rgba(2, 2, b"\x00" * 4)   # 應該要 2*2*4=16 bytes
    except ValueError as e:
        assert "16" in str(e)
    else:
        raise AssertionError("長度不符時必須 raise")


def test_read_size_roundtrips():
    """adb screencap 直接回 PNG，要印出尺寸就得從 header 讀。"""
    from lib.png import read_size
    assert read_size(encode_rgba(7, 11, b"\x00" * (7 * 11 * 4))) == (7, 11)


def test_read_size_rejects_non_png():
    from lib.png import read_size
    try:
        read_size(b"not a png at all")
    except ValueError:
        pass
    else:
        raise AssertionError("非 PNG 必須 raise")
```

- [ ] **Step 2: 執行測試確認失敗**

```bash
cd /Users/hanfourhuang/Projects/mirage/tools/probe && \
  /Users/hanfourhuang/Projects/mirage/phase0/harness/.venv/bin/python -m pytest tests/test_png.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'lib.png'`

- [ ] **Step 3: 實作 `lib/png.py`**

```python
"""RGBA bytes → PNG bytes。純函式、無依賴（不引入 Pillow）。

只需要寫出「能被看圖工具與 Claude 讀取」的 PNG，用不著完整的影像函式庫。
"""
import struct
import zlib


def encode_rgba(width: int, height: int, rgba: bytes) -> bytes:
    expected = width * height * 4
    if len(rgba) != expected:
        raise ValueError(f"RGBA 長度不符：預期 {expected}，實得 {len(rgba)}")

    stride = width * 4
    raw = b"".join(b"\x00" + rgba[y * stride:(y + 1) * stride] for y in range(height))

    def chunk(ctype: bytes, body: bytes) -> bytes:
        payload = ctype + body
        return (struct.pack(">I", len(body)) + payload
                + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6))
            + chunk(b"IEND", b""))


def read_size(data: bytes) -> tuple[int, int]:
    """從 PNG header 讀寬高。adb screencap 直接回 PNG，印尺寸需要它。"""
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("不是有效的 PNG（缺少 signature 或 IHDR）")
    width, height = struct.unpack(">II", data[16:24])
    return width, height
```

- [ ] **Step 4: 執行測試確認通過**

```bash
cd /Users/hanfourhuang/Projects/mirage/tools/probe && \
  /Users/hanfourhuang/Projects/mirage/phase0/harness/.venv/bin/python -m pytest tests/test_png.py -v
```

Expected: PASS（5 passed）

- [ ] **Step 5: 寫疊層狀態檔的測試**

`tools/probe/tests/test_overlay_state.py`：

```python
from lib import overlay_state


def test_roundtrips_original_value(tmp_path, monkeypatch):
    monkeypatch.setattr(overlay_state, "STATE_DIR", str(tmp_path))
    assert overlay_state.load_original("game") is None
    overlay_state.save_original("game", "0")
    assert overlay_state.load_original("game") == "0"


def test_targets_do_not_share_state(tmp_path, monkeypatch):
    """2026-07-28 那輪同時開了兩台機器的疊層，狀態必須分開存。"""
    monkeypatch.setattr(overlay_state, "STATE_DIR", str(tmp_path))
    overlay_state.save_original("game", "0")
    overlay_state.save_original("bench", "1")
    assert overlay_state.load_original("game") == "0"
    assert overlay_state.load_original("bench") == "1"
```

- [ ] **Step 6: 執行測試確認失敗，然後實作 `lib/overlay_state.py`**

Run: `... -m pytest tests/test_overlay_state.py -v` → Expected: FAIL（No module named 'lib.overlay_state'）

```python
"""pointer_location 疊層的原值狀態檔。

疊層是為了量測而開的，不還原會一直留在使用者的裝置上——2026-07-28 那輪開了
兩台機器的疊層，全靠自己記得關。`on` 存原值、`restore` 讀回來。
"""
import os

STATE_DIR = os.path.expanduser("~/.mirage-probe")


def state_path(target_name: str) -> str:
    return os.path.join(STATE_DIR, f"{target_name}-overlay")


def save_original(target_name: str, value: str) -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(state_path(target_name), "w") as f:
        f.write(value.strip())


def load_original(target_name: str) -> str | None:
    try:
        with open(state_path(target_name)) as f:
            return f.read().strip()
    except FileNotFoundError:
        return None
```

Run 測試 → Expected: PASS（2 passed）

- [ ] **Step 7: 實作 `lib/emulator.py`**

```python
"""gRPC 操作。畫面與輸入都走這條——也就是 Mirage 產品走的同一條路徑。"""
import contextlib

import grpc

import emulator_controller_pb2 as pb
import emulator_controller_pb2_grpc as pbg
from google.protobuf import empty_pb2

# 1080x2400 RGBA = 10.4 MB，遠超 gRPC 預設的 4 MB 上限。
_MAX_MESSAGE = 64 * 1024 * 1024


class EmulatorError(RuntimeError):
    pass


class Emulator:
    def __init__(self, stub, port: int):
        self._stub = stub
        self._port = port

    def display_size(self) -> tuple[int, int]:
        """guest 實體螢幕解析度，與 EmulatorClient 取的是同一個來源（hw.lcd.*）。"""
        try:
            status = self._stub.getStatus(empty_pb2.Empty(), timeout=10)
        except grpc.RpcError as e:
            raise EmulatorError(f"grpc localhost:{self._port} unreachable ({e.code().name})") from None
        cfg = {e.key: e.value for e in status.hardwareConfig.entry}
        try:
            w, h = int(cfg["hw.lcd.width"]), int(cfg["hw.lcd.height"])
        except (KeyError, ValueError):
            raise EmulatorError("getStatus 沒有可用的 hw.lcd.width/height") from None
        if w <= 0 or h <= 0:
            raise EmulatorError(f"hw.lcd 尺寸不合理：{w}x{h}")
        return w, h

    def screenshot(self) -> tuple[int, int, bytes]:
        w, h = self.display_size()
        fmt = pb.ImageFormat(format=pb.ImageFormat.RGBA8888, width=w, height=h)
        try:
            img = self._stub.getScreenshot(fmt, timeout=15)
        except grpc.RpcError as e:
            raise EmulatorError(
                f"connected but no frame in 15s — streamScreenshot 是變化驅動的，"
                f"畫面靜止時不出幀（{e.code().name}）") from None
        return img.format.width, img.format.height, img.image

    def send_touch(self, x: int, y: int, down: bool) -> None:
        touch = pb.Touch(x=x, y=y, identifier=0, pressure=1024 if down else 0)
        try:
            self._stub.sendTouch(pb.TouchEvent(touches=[touch]), timeout=10)
        except grpc.RpcError as e:
            raise EmulatorError(f"sendTouch 失敗：{e.code().name}") from None


@contextlib.contextmanager
def connect(port: int):
    options = [("grpc.max_receive_message_length", _MAX_MESSAGE)]
    with grpc.insecure_channel(f"localhost:{port}", options=options) as channel:
        yield Emulator(pbg.EmulatorControllerStub(channel), port)
```

- [ ] **Step 8: 在 `lib/adb.py` 新增三個函式**

追加到檔案末尾：

```python
def screencap_png(serial: str) -> bytes:
    """guest 畫面。注意：**不含** pointer_location 這類系統 overlay。"""
    proc = subprocess.run([adb_path(), "-s", serial, "exec-out", "screencap", "-p"],
                          capture_output=True, timeout=30)
    if proc.returncode != 0 or not proc.stdout:
        raise AdbError(f"screencap 失敗：{proc.stderr.decode(errors='replace').strip()}")
    return proc.stdout


def get_setting(serial: str, key: str) -> str:
    return run(serial, ["shell", "settings", "get", "system", key]).strip()


def put_setting(serial: str, key: str, value: str) -> None:
    run(serial, ["shell", "settings", "put", "system", key, value])
```

- [ ] **Step 9: 在 `probe.py` 加入三個子指令**

在 `cmd_fg` 之後加入：

```python
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
```

補上 import 與 parser 設定：

```python
from lib import adb, emulator, overlay_state, png
```

在 `build_parser()` 的 `sub.add_parser("fg", ...)` 之後：

```python
    p_shot = sub.add_parser("shot", help="抓畫面（預設 grpc）")
    p_shot.add_argument("out")
    p_shot.add_argument("--via", choices=("grpc", "adb"), default="grpc")

    p_cmp = sub.add_parser("compare", help="同時抓 grpc 與 adb 兩條路徑")
    p_cmp.add_argument("prefix")

    p_ovl = sub.add_parser("overlay", help="pointer_location 疊層")
    p_ovl.add_argument("action", choices=("on", "off", "restore"))
```

在 `main()` 的 `handlers` 加入：

```python
    handlers = {"fg": cmd_fg, "shot": cmd_shot, "compare": cmd_compare,
                "overlay": cmd_overlay}
```

並把例外攔截加上 `emulator.EmulatorError`：

```python
    except (adb.AdbError, emulator.EmulatorError, ValueError) as e:
```

- [ ] **Step 10: 活體驗證**

```bash
cd /Users/hanfourhuang/Projects/mirage/tools/probe
PY=/Users/hanfourhuang/Projects/mirage/phase0/harness/.venv/bin/python
$PY probe.py --target game overlay on
$PY probe.py --target game compare /tmp/probe-check
$PY probe.py --target game overlay restore
```

Expected: `compare` 產出兩個檔案。**用 Read 開這兩張圖**，`-grpc.png` 應看得到頂端的
`pointer_location` 疊層數值列，`-adb.png` 沒有。這個差異就是本指令存在的理由。

- [ ] **Step 11: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add tools/probe
git commit -m "feat(probe): 抓幀（shot/compare）與疊層（overlay）

compare 同時抓 grpc 與 adb 兩條路徑並明講含不含 overlay——2026-07-28 三個
關鍵突破都來自這個對照（guest 卡在 splash 而非 Mirage 的問題、驗證觸控座標
的方法、排除 Mirage 是效能瓶頸）。

overlay on 會先記錄原值供 restore 還原，各 target 狀態分開存。"
```

---

### Task 3: 輸入（`tap` / `swipe`）

**Files:**
- Create: `tools/probe/lib/coords.py`
- Modify: `tools/probe/lib/emulator.py`（新增 `send_swipe`）
- Modify: `tools/probe/probe.py`（新增兩個子指令）
- Test: `tools/probe/tests/test_coords.py`

**Interfaces:**
- Consumes: `lib.emulator.Emulator.display_size/send_touch`
- Produces: `lib.coords.to_guest_pixel(nx: float, ny: float, width: int, height: int) -> tuple[int, int]`（越界 raise `ValueError`）；`lib.coords.lerp_path(n1, n2, steps) -> list[tuple[float, float]]`
- Produces: `lib.emulator.Emulator.send_swipe(path: list[tuple[int, int]], step_ms: int) -> None`

- [ ] **Step 1: 寫會紅的測試**

`tools/probe/tests/test_coords.py`：

```python
import pytest

from lib.coords import lerp_path, to_guest_pixel


def test_maps_center_to_physical_center():
    """本機 guest 是 1080x2400。若誤用串流尺寸 540x1200 換算會得到 (270,600)
    ——那正是 2026-07-28 §10 那個 bug：每次點擊都落在目標的左上一半處。"""
    assert to_guest_pixel(0.5, 0.5, 1080, 2400) == (540, 1200)


def test_maps_corners():
    assert to_guest_pixel(0.0, 0.0, 1080, 2400) == (0, 0)
    assert to_guest_pixel(1.0, 1.0, 1080, 2400) == (1080, 2400)


def test_rounds_rather_than_truncates():
    # 0.5001 * 1080 = 540.108 → 540；0.9999 * 1080 = 1079.892 → 1080
    assert to_guest_pixel(0.5001, 0.5, 1080, 2400)[0] == 540
    assert to_guest_pixel(0.9999, 0.5, 1080, 2400)[0] == 1080


@pytest.mark.parametrize("nx,ny", [(-0.1, 0.5), (1.1, 0.5), (0.5, -0.1), (0.5, 1.1)])
def test_rejects_out_of_range(nx, ny):
    with pytest.raises(ValueError):
        to_guest_pixel(nx, ny, 1080, 2400)


def test_lerp_path_includes_both_ends():
    path = lerp_path((0.0, 0.0), (1.0, 1.0), steps=5)
    assert len(path) == 5
    assert path[0] == (0.0, 0.0)
    assert path[-1] == (1.0, 1.0)


def test_lerp_path_is_monotonic():
    path = lerp_path((0.2, 0.8), (0.8, 0.2), steps=7)
    assert [p[0] for p in path] == sorted(p[0] for p in path)
    assert [p[1] for p in path] == sorted((p[1] for p in path), reverse=True)
```

- [ ] **Step 2: 執行測試確認失敗**

```bash
cd /Users/hanfourhuang/Projects/mirage/tools/probe && \
  /Users/hanfourhuang/Projects/mirage/phase0/harness/.venv/bin/python -m pytest tests/test_coords.py -v
```

Expected: FAIL — `ModuleNotFoundError: No module named 'lib.coords'`

- [ ] **Step 3: 實作 `lib/coords.py`**

```python
"""normalized 座標 → guest 實體像素。純函式。

**乘的必須是 guest 實體解析度，不是串流幀尺寸。** proto 明載 Touch.x/y 是
"physical location on the screen"；2026-07-28 之前整條路徑乘的是串流尺寸
（540x1200 對 guest 1080x2400），每次點擊都落在目標的左上一半處。
"""


def to_guest_pixel(nx: float, ny: float, width: int, height: int) -> tuple[int, int]:
    if not (0.0 <= nx <= 1.0 and 0.0 <= ny <= 1.0):
        raise ValueError(f"normalized 座標須在 0–1：({nx}, {ny})")
    return (round(nx * width), round(ny * height))


def lerp_path(start: tuple[float, float], end: tuple[float, float],
              steps: int) -> list[tuple[float, float]]:
    """在兩個 normalized 點之間線性內插，含頭尾。

    swipe 必須是連續的多個觸點——只送起點與終點，guest 會當成瞬移，
    多數遊戲的拖曳手勢不會被辨識。
    """
    if steps < 2:
        raise ValueError(f"steps 至少為 2，實得 {steps}")
    (x1, y1), (x2, y2) = start, end
    return [(x1 + (x2 - x1) * i / (steps - 1), y1 + (y2 - y1) * i / (steps - 1))
            for i in range(steps)]
```

- [ ] **Step 4: 執行測試確認通過**

```bash
cd /Users/hanfourhuang/Projects/mirage/tools/probe && \
  /Users/hanfourhuang/Projects/mirage/phase0/harness/.venv/bin/python -m pytest tests/test_coords.py -v
```

Expected: PASS（9 passed，含 parametrize 展開）

- [ ] **Step 5: 在 `lib/emulator.py` 新增 `send_swipe`**

加在 `send_touch` 之後：

```python
    def send_swipe(self, path: list[tuple[int, int]], step_ms: int) -> None:
        """連續觸點構成的拖曳。頭尾分別是 down 與 up。"""
        import time
        if len(path) < 2:
            raise EmulatorError(f"swipe 至少需要 2 個點，實得 {len(path)}")
        for i, (x, y) in enumerate(path):
            self.send_touch(x, y, down=True)
            if i < len(path) - 1:
                time.sleep(step_ms / 1000.0)
        last_x, last_y = path[-1]
        self.send_touch(last_x, last_y, down=False)
```

- [ ] **Step 6: 在 `probe.py` 加入兩個子指令**

```python
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
```

import 改為 `from lib import adb, coords, emulator, overlay_state, png`，parser 加：

```python
    p_tap = sub.add_parser("tap", help="normalized 座標點擊")
    p_tap.add_argument("nx", type=float)
    p_tap.add_argument("ny", type=float)

    p_swp = sub.add_parser("swipe", help="normalized 座標拖曳")
    for name in ("nx1", "ny1", "nx2", "ny2"):
        p_swp.add_argument(name, type=float)
    p_swp.add_argument("ms", type=int, nargs="?", default=300)
```

`handlers` 加入 `"tap": cmd_tap, "swipe": cmd_swipe`。

- [ ] **Step 7: 活體驗證座標正確性**

```bash
cd /Users/hanfourhuang/Projects/mirage/tools/probe
PY=/Users/hanfourhuang/Projects/mirage/phase0/harness/.venv/bin/python
$PY probe.py --target game overlay on
$PY probe.py --target game tap 0.25 0.25
$PY probe.py --target game shot /tmp/probe-tap.png
$PY probe.py --target game overlay restore
```

Expected: `tap` 印出 `guest (270, 600)`。**用 Read 開 `/tmp/probe-tap.png`**，
疊層的十字線應落在畫面寬 25%、高 25% 處（即 x≈270、y≈600）。若落在 (135, 300)
附近，表示又乘到串流尺寸了。

- [ ] **Step 8: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add tools/probe
git commit -m "feat(probe): normalized 座標輸入（tap/swipe）

換算一律乘 guest 實體解析度（getStatus 的 hw.lcd.*），與 EmulatorClient
同一個來源。單元測試明確釘住 (0.5,0.5)@1080x2400 → (540,1200)，那正是
2026-07-28 §10 那個 bug 會算成 (270,600) 的地方。

swipe 送連續內插觸點而非只送頭尾——只送兩點 guest 會當成瞬移，多數遊戲的
拖曳手勢不會被辨識。"
```

---

### Task 4: `launch`

**Files:**
- Modify: `tools/probe/lib/adb.py`（新增 `start_package`）
- Modify: `tools/probe/probe.py`（新增子指令）

**Interfaces:**
- Consumes: `lib.adb.foreground_activity`、`lib.targets.Target.playable`
- Produces: `lib.adb.start_package(serial: str, package: str) -> None`

- [ ] **Step 1: 在 `lib/adb.py` 新增 `start_package`**

```python
def start_package(serial: str, package: str) -> None:
    run(serial, ["shell", "monkey", "-p", package,
                 "-c", "android.intent.category.LAUNCHER", "1"], timeout=30)
```

- [ ] **Step 2: 在 `probe.py` 加入 `cmd_launch`**

```python
def cmd_launch(target, args) -> int:
    """啟動並輪詢至前景確認。逾時 30 秒。

    **只確認 activity 到前景，不等遊戲載完。** Pixel Flow 在 game 機上光是過
    splash 就要好幾分鐘——2026-07-28 那輪 45 秒還在 splash，差點被當成卡死。
    """
    adb.ensure_online(target.serial)
    if not target.playable:
        print(f"warning: target {target.name!r} — {target.note}", file=sys.stderr)
    adb.start_package(target.serial, args.package)

    deadline = time.monotonic() + 30.0
    while time.monotonic() < deadline:
        fg = adb.foreground_activity(target.serial)
        if fg and fg.startswith(args.package + "/"):
            print(f"launched, foreground={fg} ({30.0 - (deadline - time.monotonic()):.1f}s)")
            return 0
        time.sleep(1.0)

    fg = adb.foreground_activity(target.serial)
    print(f"error: {args.package} 未在 30s 內到前景；目前前景={fg or '(查不到)'}",
          file=sys.stderr)
    return 1
```

檔案頂端 import 加 `import time`。parser 加：

```python
    p_launch = sub.add_parser("launch", help="啟動套件並等到前景確認")
    p_launch.add_argument("package")
```

`handlers` 加入 `"launch": cmd_launch`。

- [ ] **Step 3: 活體驗證（含 bench 機的警告路徑）**

```bash
cd /Users/hanfourhuang/Projects/mirage/tools/probe
PY=/Users/hanfourhuang/Projects/mirage/phase0/harness/.venv/bin/python
$PY probe.py --target game launch com.loomgames.pixelflow
$PY probe.py --target bench launch com.loomgames.pixelflow   # 應先印 warning
$PY probe.py --target game launch com.nonexistent.app        # 應逾時並印出目前前景
```

Expected: 第一行成功並印出耗時；第二行成功但 stderr 先出現 `warning: target 'bench' — AOSP 無 Google 帳號…`；第三行 30 秒後非零退出。

- [ ] **Step 4: 跑完整測試套件**

```bash
cd /Users/hanfourhuang/Projects/mirage/tools/probe && \
  /Users/hanfourhuang/Projects/mirage/phase0/harness/.venv/bin/python -m pytest tests/ -v
```

Expected: 全部 PASS（test_targets 4、test_png 5、test_overlay_state 2、test_coords 9）

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage
git add tools/probe
git commit -m "feat(probe): launch 指令

只確認 activity 到前景、不等遊戲載完——Pixel Flow 光是過 splash 就要好幾
分鐘，2026-07-28 那輪 45 秒還在 splash 差點被當成卡死。

對 playable=False 的 target 先印 warning：在 bench 機上啟動遊戲會卡在載入
畫面，那不是 bug。"
```

---

## 完成後的第一件事

用這支工具把 Pixel Flow 帶進**關卡內**，量該處的 fps，與主選單的 30 fps 對照。

這個數字決定「會玩遊戲的 agent」那個子專案值不值得做（設計文件 §8）：若關卡內與主選單
相當，則瓶頸已確定在 guest 端、與怎麼玩無關，那個子專案對「量 fps」這個目的就不必做。
