# Mirage Phase 0 技術驗證 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用官方 prebuilt Android emulator（不 fork）在 macOS Apple Silicon 上驗證「headless 核心 + gRPC 串流/輸入」整條命脈，產出實測數據，做出 go/no-go 判定。

**Architecture:** 官方 emulator 以 `-no-window -grpc 8554` 跑 headless；Python 量測 harness（grpcio）負責串流幀率、輸入注入 RTT、端到端 input-to-photon 量測；Swift POC（grpc-swift + Metal blit）驗證原生殼的顯示與滑鼠直通可行性。全程不修改 emulator 本體。

**Tech Stack:** Android SDK cmdline-tools / emulator / AOSP arm64 映像（android-35 default）、Python 3.11+（grpcio、numpy、pytest）、Swift 5.9+（SwiftPM、grpc-swift 1.x、MetalKit）。

## Global Constraints

- 平台：macOS on Apple Silicon（M1+）。不支援 Intel、不考慮 Windows/Linux。
- **不 fork emulator**：只用官方 prebuilt 二進位（spec §7 Phase 0、R3）。
- gRPC 僅綁 localhost（`-grpc` 預設 loopback），不開遠端、不加 TLS——安全邊界是本機。
- 延遲預算（spec §4.2）：input-to-photon 目標 < 50ms、上限 80ms；串流須穩定 60fps。
- Go/No-go（spec §7）：延遲 < 80ms 且 60fps 穩定 → Go；否則依序驗備援 (a) WebRTC (b) fork + 共享記憶體。
- 程式風格（使用者全域規範）：不可變資料結構、系統邊界驗證輸入、fail fast、檔案小而聚焦。
- Commit 格式：conventional commits（`feat:`/`test:`/`chore:`/`docs:`），不加 attribution。
- AVD 名稱固定 `mirage-poc`；gRPC 埠固定 `8554`（環境變數 `GRPC_PORT` 可覆寫）。

## File Structure

```
mirage/
├── docs/plans/2026-07-22-phase0-validation.md   ← 本計畫
├── phase0/
│   ├── .gitignore
│   ├── README.md                    # 執行指南（Task 10）
│   ├── RESULTS.md                   # 實測數據與 go/no-go 判定（Task 10）
│   ├── scripts/
│   │   ├── 00_install_sdk.sh        # SDK/emulator/映像安裝
│   │   ├── 01_create_avd.sh         # 建立 mirage-poc AVD
│   │   ├── 02_boot_headless.sh      # headless + gRPC 啟動
│   │   └── 03_wait_boot.sh          # 等待開機完成
│   ├── harness/                     # Python 量測 harness
│   │   ├── requirements.txt
│   │   ├── protos/                  # 從 SDK 複製的 .proto
│   │   ├── gen/                     # protoc 產生的 stub（gitignore）
│   │   ├── lib/
│   │   │   ├── __init__.py
│   │   │   ├── stats.py             # 幀率/延遲統計（純函式）
│   │   │   └── detector.py          # 畫面區域變化偵測（純函式）
│   │   ├── tests/
│   │   │   ├── test_stats.py
│   │   │   └── test_detector.py
│   │   ├── smoke_grpc.py            # gRPC 連通煙霧測試
│   │   ├── stream_bench.py          # 串流幀率/頻寬基準
│   │   ├── input_latency.py         # 輸入注入 RTT
│   │   └── e2e_latency.py           # 端到端 input-to-photon
│   └── swift-poc/
│       ├── Package.swift
│       └── Sources/MiragePOC/
│           ├── Generated/           # protoc swift stub（commit 進 repo）
│           ├── main.swift           # App 進入點
│           ├── EmulatorClient.swift # gRPC 封裝
│           ├── MirrorView.swift     # MTKView + 滑鼠直通
│           └── Renderer.swift       # 畫格 → Metal blit
```

職責劃分：`lib/` 是純函式（可單元測試、不碰網路）；量測腳本只做 I/O 與組裝；Swift 端 `EmulatorClient` 是 gRPC 唯一封裝點（對齊 spec §4.1 的收窄原則）。

---

### Task 1: 環境安裝腳本與 phase0 骨架

**Files:**
- Create: `phase0/.gitignore`
- Create: `phase0/scripts/00_install_sdk.sh`

**Interfaces:**
- Produces: 可執行的 `$SDK/emulator/emulator`、`$SDK/platform-tools/adb`、系統映像 `system-images;android-35;default;arm64-v8a`。後續所有 task 以 `SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"` 取得路徑。

- [ ] **Step 1: 建立 .gitignore**

```gitignore
# phase0/.gitignore
harness/.venv/
harness/gen/
__pycache__/
swift-poc/.build/
*.log
```

- [ ] **Step 2: 寫安裝腳本**

```bash
#!/usr/bin/env bash
# phase0/scripts/00_install_sdk.sh
# 冪等：已有 Android Studio 的 SDK 就直接沿用，缺什麼裝什麼。
set -euo pipefail

SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"
IMAGE="system-images;android-35;default;arm64-v8a"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "錯誤：本專案僅支援 Apple Silicon（偵測到 $(uname -m)）" >&2
  exit 1
fi

if [[ ! -x "$SDKMANAGER" ]]; then
  echo "找不到 sdkmanager：$SDKMANAGER" >&2
  echo "請至 https://developer.android.com/studio#command-line-tools-only 下載 macOS zip，" >&2
  echo "解壓後將 zip 內的 cmdline-tools/ 放到 $SDK/cmdline-tools/latest/" >&2
  exit 1
fi

yes | "$SDKMANAGER" --licenses > /dev/null
"$SDKMANAGER" "platform-tools" "emulator" "$IMAGE"

"$SDK/emulator/emulator" -version | head -1
"$SDK/platform-tools/adb" --version | head -1
echo "OK: SDK ready at $SDK"
```

- [ ] **Step 3: 執行驗證**

Run: `chmod +x phase0/scripts/00_install_sdk.sh && phase0/scripts/00_install_sdk.sh`
Expected: 末三行印出 emulator 版本（如 `Android emulator version 36.x`）、adb 版本、`OK: SDK ready at ...`。

- [ ] **Step 4: Commit**

```bash
git add phase0/.gitignore phase0/scripts/00_install_sdk.sh
git commit -m "chore: phase0 SDK 安裝腳本與骨架"
```

---

### Task 2: AVD 建立與 headless 開機

**Files:**
- Create: `phase0/scripts/01_create_avd.sh`
- Create: `phase0/scripts/02_boot_headless.sh`
- Create: `phase0/scripts/03_wait_boot.sh`

**Interfaces:**
- Consumes: Task 1 安裝好的 SDK。
- Produces: 名為 `mirage-poc` 的 AVD；執行中的 headless emulator，gRPC 於 `localhost:8554`，adb 於預設埠。

- [ ] **Step 1: 建立 AVD 腳本**

```bash
#!/usr/bin/env bash
# phase0/scripts/01_create_avd.sh
set -euo pipefail
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"
NAME="mirage-poc"

if "$AVDMANAGER" list avd | grep -q "Name: $NAME"; then
  echo "OK: AVD $NAME 已存在"
  exit 0
fi
echo no | "$AVDMANAGER" create avd \
  -n "$NAME" \
  -k "system-images;android-35;default;arm64-v8a" \
  -d pixel_7
echo "OK: AVD $NAME created"
```

- [ ] **Step 2: 啟動腳本（headless + gRPC）**

```bash
#!/usr/bin/env bash
# phase0/scripts/02_boot_headless.sh
set -euo pipefail
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
GRPC_PORT="${GRPC_PORT:-8554}"
exec "$SDK/emulator/emulator" @mirage-poc \
  -no-window -no-audio -no-boot-anim \
  -gpu host \
  -grpc "$GRPC_PORT"
```

- [ ] **Step 3: 等待開機腳本**

```bash
#!/usr/bin/env bash
# phase0/scripts/03_wait_boot.sh
set -euo pipefail
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
"$ADB" wait-for-device
until [[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
  sleep 1
done
echo BOOTED
```

- [ ] **Step 4: 實測開機**

Run（終端 A）: `chmod +x phase0/scripts/0*.sh && phase0/scripts/01_create_avd.sh && phase0/scripts/02_boot_headless.sh`
Run（終端 B）: `phase0/scripts/03_wait_boot.sh && time true`
Expected: 終端 B 印出 `BOOTED`（首次冷開機 1–3 分鐘屬正常；此數字記入 RESULTS.md 但不算冷啟動 KPI——KPI 是快照喚醒後的 P1 指標）。
Troubleshooting: 若 emulator 啟動即退出，跑 `"$SDK/emulator/emulator" @mirage-poc -no-window -verbose 2>&1 | tail -30` 看 HVF 錯誤；確認「系統設定 → 隱私權與安全性」允許虛擬化。

- [ ] **Step 5: Commit**

```bash
git add phase0/scripts/01_create_avd.sh phase0/scripts/02_boot_headless.sh phase0/scripts/03_wait_boot.sh
git commit -m "feat: mirage-poc AVD 建立與 headless 開機腳本"
```

---

### Task 3: Python harness 與 gRPC 連通煙霧測試

**Files:**
- Create: `phase0/harness/requirements.txt`
- Create: `phase0/harness/protos/`（從 SDK 複製）
- Create: `phase0/harness/smoke_grpc.py`
- Create: `phase0/harness/lib/__init__.py`（空檔）

**Interfaces:**
- Consumes: Task 2 執行中的 emulator（gRPC :8554）。
- Produces: `gen/emulator_controller_pb2.py`、`gen/emulator_controller_pb2_grpc.py` stub；所有後續 Python 腳本以 `sys.path.insert(0, "gen")` 後 `import emulator_controller_pb2 as ec`、`import emulator_controller_pb2_grpc as ecg` 使用；連線慣例 `grpc.insecure_channel("localhost:8554")`。

- [ ] **Step 1: requirements.txt**

```
grpcio>=1.66,<2
grpcio-tools>=1.66,<2
numpy>=1.26
pytest>=8
```

- [ ] **Step 2: 建 venv、複製 proto、產 stub**

```bash
cd phase0/harness
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
mkdir -p protos gen lib tests
cp "$SDK/emulator/lib/emulator_controller.proto" protos/
python -m grpc_tools.protoc -I protos \
  --python_out=gen --grpc_python_out=gen \
  protos/emulator_controller.proto
touch gen/__init__.py lib/__init__.py
ls gen/
```

Expected: `gen/` 內出現 `emulator_controller_pb2.py` 與 `emulator_controller_pb2_grpc.py`。
Troubleshooting: 若 protoc 抱怨缺 import（如 `snapshot.proto`），把 `$SDK/emulator/lib/` 下被 import 的 .proto 一併 cp 進 `protos/` 再產一次。

- [ ] **Step 3: 確認 proto 的訊息欄位名（後續程式碼依此為準）**

Run: `grep -n -A 10 -E "^message (Touch|TouchEvent|ImageFormat) " protos/emulator_controller.proto`
Expected（欄位名應與下列一致；若你的 SDK 版本不同名，以 grep 結果為準修改後續程式碼）:

```
message Touch { int32 x; int32 y; int32 identifier; int32 pressure; int32 touch_major; int32 touch_minor; uint64 timestamp; ... }
message TouchEvent { repeated Touch touches; int32 display; }
message ImageFormat { ImgFormat format; Rotation rotation; uint32 width; uint32 height; int32 display; ... }
```

- [ ] **Step 4: 煙霧測試腳本**

```python
# phase0/harness/smoke_grpc.py
"""gRPC 連通煙霧測試：連上 emulator、印出狀態。"""
import sys

sys.path.insert(0, "gen")

import grpc
from google.protobuf import empty_pb2
import emulator_controller_pb2_grpc as ecg

TARGET = "localhost:8554"


def main() -> int:
    channel = grpc.insecure_channel(TARGET)
    stub = ecg.EmulatorControllerStub(channel)
    try:
        status = stub.getStatus(empty_pb2.Empty(), timeout=5)
    except grpc.RpcError as err:
        print(f"FAIL: gRPC {err.code().name}: {err.details()}", file=sys.stderr)
        return 1
    print(status)
    print("OK: gRPC reachable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 5: 執行驗證**

Run: `cd phase0/harness && source .venv/bin/activate && python smoke_grpc.py`
Expected: 印出 emulator 狀態（version/uptime/booted 等欄位）與 `OK: gRPC reachable`。
Troubleshooting: `UNAVAILABLE` → emulator 沒帶 `-grpc 8554` 重開；`UNAUTHENTICATED` → 該版本預設開了 token 驗證，啟動腳本改加 `-grpc 8554` 之外再確認未帶 `-grpc-use-token`。

- [ ] **Step 6: Commit**

```bash
git add phase0/harness/requirements.txt phase0/harness/protos phase0/harness/smoke_grpc.py phase0/harness/lib/__init__.py
git commit -m "feat: python harness 骨架與 gRPC 煙霧測試"
```

---

### Task 4: 統計函式（TDD）與串流基準

**Files:**
- Create: `phase0/harness/lib/stats.py`
- Create: `phase0/harness/tests/test_stats.py`
- Create: `phase0/harness/stream_bench.py`

**Interfaces:**
- Consumes: Task 3 的 stub 與連線慣例。
- Produces: `percentile(values: list[float], p: float) -> float`、`summarize(timestamps: list[float]) -> StreamStats`（frozen dataclass，欄位 `frames:int, duration_s:float, fps:float, p50_ms:float, p95_ms:float`）。Task 5、6 直接 import 使用。

- [ ] **Step 1: 寫失敗測試**

```python
# phase0/harness/tests/test_stats.py
import pytest

from lib.stats import StreamStats, percentile, summarize


def test_percentile_median():
    assert percentile([5, 1, 3, 2, 4], 50) == 3


def test_percentile_interpolates():
    assert percentile([0, 10], 95) == pytest.approx(9.5)


def test_percentile_rejects_empty():
    with pytest.raises(ValueError):
        percentile([], 50)


def test_percentile_rejects_out_of_range():
    with pytest.raises(ValueError):
        percentile([1.0], 101)


def test_summarize_uniform_60fps():
    ts = [i / 60 for i in range(61)]  # 61 個時戳、剛好 1 秒
    s = summarize(ts)
    assert s.frames == 61
    assert s.fps == pytest.approx(60, rel=1e-3)
    assert s.p50_ms == pytest.approx(16.67, rel=1e-2)
    assert s.p95_ms == pytest.approx(16.67, rel=1e-2)


def test_summarize_rejects_short_input():
    with pytest.raises(ValueError):
        summarize([0.0])


def test_summarize_is_immutable():
    s = summarize([0.0, 1.0])
    with pytest.raises(Exception):
        s.fps = 999  # frozen dataclass
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd phase0/harness && source .venv/bin/activate && python -m pytest tests/test_stats.py -v`
Expected: FAIL（`ModuleNotFoundError: No module named 'lib.stats'`）。

- [ ] **Step 3: 最小實作**

```python
# phase0/harness/lib/stats.py
"""幀時戳序列的統計摘要。純函式、不可變輸出。"""
from dataclasses import dataclass


@dataclass(frozen=True)
class StreamStats:
    frames: int
    duration_s: float
    fps: float
    p50_ms: float
    p95_ms: float


def percentile(values: list[float], p: float) -> float:
    if not values:
        raise ValueError("values 不可為空")
    if not 0 <= p <= 100:
        raise ValueError(f"p 必須在 0–100 之間，收到 {p}")
    ordered = sorted(values)
    k = (len(ordered) - 1) * p / 100
    lo = int(k)
    hi = min(lo + 1, len(ordered) - 1)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (k - lo)


def summarize(timestamps: list[float]) -> StreamStats:
    if len(timestamps) < 2:
        raise ValueError("至少需要 2 個時戳")
    deltas_ms = [
        (b - a) * 1000 for a, b in zip(timestamps, timestamps[1:])
    ]
    duration = timestamps[-1] - timestamps[0]
    return StreamStats(
        frames=len(timestamps),
        duration_s=duration,
        fps=(len(timestamps) - 1) / duration,
        p50_ms=percentile(deltas_ms, 50),
        p95_ms=percentile(deltas_ms, 95),
    )
```

- [ ] **Step 4: 跑測試確認通過**

Run: `python -m pytest tests/test_stats.py -v`
Expected: 7 passed。

- [ ] **Step 5: 串流基準腳本**

```python
# phase0/harness/stream_bench.py
"""streamScreenshot 基準：量幀率、幀間隔分佈、每幀位元組數。

用法：
  python stream_bench.py --format rgba --seconds 10
  python stream_bench.py --format png  --seconds 10
量測時請在另一終端跑動畫產生器（見 README / 本計畫 Step 6）。
"""
import argparse
import sys
import time

sys.path.insert(0, "gen")

import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.stats import summarize

TARGET = "localhost:8554"
FORMATS = {
    "rgba": ec.ImageFormat.RGBA8888,
    "png": ec.ImageFormat.PNG,
}


def bench(fmt_name: str, seconds: int) -> None:
    channel = grpc.insecure_channel(TARGET)
    stub = ecg.EmulatorControllerStub(channel)
    req = ec.ImageFormat(format=FORMATS[fmt_name])  # width/height 不給 = 原生解析度

    timestamps: list[float] = []
    total_bytes = 0
    deadline = time.monotonic() + seconds
    for frame in stub.streamScreenshot(req):
        now = time.monotonic()
        timestamps.append(now)
        total_bytes += len(frame.image)
        if now >= deadline:
            break

    stats = summarize(timestamps)
    avg_mb = total_bytes / stats.frames / 1_048_576
    print(f"format={fmt_name} frames={stats.frames} fps={stats.fps:.1f} "
          f"p50={stats.p50_ms:.1f}ms p95={stats.p95_ms:.1f}ms "
          f"avg_frame={avg_mb:.2f}MiB throughput={avg_mb * stats.fps:.0f}MiB/s")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=FORMATS, required=True)
    parser.add_argument("--seconds", type=int, default=10)
    args = parser.parse_args()
    if args.seconds < 3:
        parser.error("--seconds 至少 3 秒才有統計意義")
    bench(args.format, args.seconds)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 6: 實測（需 emulator 執行中）**

Run（終端 B，動畫產生器——讓 guest 持續出新幀）:

```bash
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
"$SDK/platform-tools/adb" shell 'while true; do input swipe 540 1800 540 600 300; input swipe 540 600 540 1800 300; done'
```

Run（終端 C）: `cd phase0/harness && source .venv/bin/activate && python stream_bench.py --format rgba --seconds 10 && python stream_bench.py --format png --seconds 10`
Expected: 兩行結果。判讀基準：rgba 的 `fps` 應 ≥ 55；png 通常較低（編碼成本）。兩組數字都抄進 RESULTS.md（Task 10）。若 rgba fps < 55，這就是第一個紅燈——先確認動畫產生器有在跑、`-gpu host` 有生效，再判定。

- [ ] **Step 7: Commit**

```bash
git add phase0/harness/lib/stats.py phase0/harness/tests/test_stats.py phase0/harness/stream_bench.py
git commit -m "feat: 串流基準與統計函式（TDD）"
```

---

### Task 5: 輸入注入 RTT 量測

**Files:**
- Create: `phase0/harness/input_latency.py`

**Interfaces:**
- Consumes: Task 3 stub、Task 4 的 `percentile`。
- Produces: `send_tap(stub, x: int, y: int, down: bool) -> None`（Task 6 重用同款注入寫法；欄位名以 Task 3 Step 3 的 grep 結果為準）。

- [ ] **Step 1: 量測腳本**

```python
# phase0/harness/input_latency.py
"""sendTouch 注入 RTT：量 gRPC 單次呼叫往返時間（對應預算表「gRPC 輸入注入 < 3ms」）。"""
import sys
import time

sys.path.insert(0, "gen")

import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.stats import percentile

TARGET = "localhost:8554"
N_TAPS = 200
TAP_X, TAP_Y = 540, 1200  # pixel_7 螢幕中央附近


def send_tap(stub, x: int, y: int, down: bool) -> None:
    touch = ec.Touch(x=x, y=y, identifier=0, pressure=1024 if down else 0)
    stub.sendTouch(ec.TouchEvent(touches=[touch]), timeout=2)


def main() -> int:
    stub = ecg.EmulatorControllerStub(grpc.insecure_channel(TARGET))
    rtts_ms: list[float] = []
    for _ in range(N_TAPS):
        t0 = time.monotonic()
        send_tap(stub, TAP_X, TAP_Y, down=True)
        rtts_ms.append((time.monotonic() - t0) * 1000)
        send_tap(stub, TAP_X, TAP_Y, down=False)
        time.sleep(0.02)
    print(f"n={len(rtts_ms)} p50={percentile(rtts_ms, 50):.2f}ms "
          f"p95={percentile(rtts_ms, 95):.2f}ms max={max(rtts_ms):.2f}ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: 實測（emulator 執行中；先停掉 Task 4 的動畫產生器）**

Run: `cd phase0/harness && source .venv/bin/activate && python input_latency.py`
Expected: 一行統計。判讀：p50 應 < 3ms（預算表），p95 < 5ms。同時肉眼驗證注入真的有效：先跑 `adb shell settings put system show_touches 1` 再執行一次，用 `adb exec-out screencap -p > /tmp/tap.png` 抓圖應可見觸控白點（或直接在 Task 6 驗證）。
Troubleshooting: 若 `sendTouch` 回 `INVALID_ARGUMENT`，用 Task 3 Step 3 的 grep 對欄位名（不同版本 `pressure`/`expiration` 有差異），修 `send_tap` 後重跑。

- [ ] **Step 3: Commit**

```bash
git add phase0/harness/input_latency.py
git commit -m "feat: sendTouch 注入 RTT 量測"
```

---

### Task 6: 畫面變化偵測（TDD）與端到端 input-to-photon 量測

**Files:**
- Create: `phase0/harness/lib/detector.py`
- Create: `phase0/harness/tests/test_detector.py`
- Create: `phase0/harness/e2e_latency.py`

**Interfaces:**
- Consumes: Task 4 `summarize`/`percentile`、Task 5 `send_tap` 的注入寫法。
- Produces: `region_mean(frame: bytes, width: int, height: int, cx: int, cy: int, radius: int) -> float`、`changed(now: float, baseline: float, threshold: float) -> bool`。E2E 數據是 go/no-go 的直接依據。

- [ ] **Step 1: 寫失敗測試**

```python
# phase0/harness/tests/test_detector.py
import numpy as np
import pytest

from lib.detector import changed, region_mean

W, H = 100, 80


def _frame(fill: int) -> bytes:
    return np.full((H, W, 4), fill, dtype=np.uint8).tobytes()


def test_region_mean_uniform():
    assert region_mean(_frame(200), W, H, cx=50, cy=40, radius=10) == 200.0


def test_region_mean_detects_local_patch():
    arr = np.zeros((H, W, 4), dtype=np.uint8)
    arr[30:50, 40:60, :3] = 255  # 中央白色方塊
    assert region_mean(arr.tobytes(), W, H, cx=50, cy=40, radius=10) > 200
    assert region_mean(arr.tobytes(), W, H, cx=10, cy=10, radius=5) == 0.0


def test_region_mean_clamps_at_edges():
    assert region_mean(_frame(7), W, H, cx=0, cy=0, radius=10) == 7.0


def test_region_mean_rejects_bad_size():
    with pytest.raises(ValueError):
        region_mean(b"\x00" * 10, W, H, cx=50, cy=40, radius=10)


def test_changed_threshold():
    assert changed(30.0, 10.0, threshold=8.0) is True
    assert changed(12.0, 10.0, threshold=8.0) is False
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `python -m pytest tests/test_detector.py -v`
Expected: FAIL（`ModuleNotFoundError: No module named 'lib.detector'`）。

- [ ] **Step 3: 最小實作**

```python
# phase0/harness/lib/detector.py
"""RGBA 畫格的區域亮度偵測。純函式，供 e2e 延遲量測辨識觸控指示出現。"""
import numpy as np


def region_mean(frame: bytes, width: int, height: int,
                cx: int, cy: int, radius: int) -> float:
    expected = width * height * 4
    if len(frame) != expected:
        raise ValueError(f"frame 長度 {len(frame)} != {expected}（{width}x{height} RGBA）")
    arr = np.frombuffer(frame, dtype=np.uint8).reshape(height, width, 4)
    x0, x1 = max(cx - radius, 0), min(cx + radius, width)
    y0, y1 = max(cy - radius, 0), min(cy + radius, height)
    if x0 >= x1 or y0 >= y1:
        raise ValueError("偵測區域完全在畫面外")
    return float(arr[y0:y1, x0:x1, :3].mean())


def changed(now: float, baseline: float, threshold: float) -> bool:
    return abs(now - baseline) > threshold
```

- [ ] **Step 4: 跑測試確認通過**

Run: `python -m pytest tests/ -v`
Expected: 12 passed（stats 7 + detector 5）。

- [ ] **Step 5: E2E 量測腳本**

原理：開啟 Android 內建「顯示觸控回饋」（show_touches，觸點處畫白色圓點——免裝任何 APK），
串流執行緒持續記錄 `(時戳, 觸點區域亮度)`；主執行緒注入 touch-down 記 `t0`，
找到第一個 `t > t0` 且亮度偏離基線的幀記 `t1`，`t1 - t0` 即為
「注入 → 該變化幀離開 emulator」的延遲。

```python
# phase0/harness/e2e_latency.py
"""端到端 input-to-photon 量測（不含 Mac 上屏，判讀時另加 8–17ms）。

前置：emulator 執行中，且已執行
  adb shell settings put system show_touches 1
"""
import collections
import sys
import threading
import time

sys.path.insert(0, "gen")

import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.detector import changed, region_mean
from lib.stats import percentile

TARGET = "localhost:8554"
N_SAMPLES = 50
TAP_X, TAP_Y = 540, 1200
RADIUS = 60          # show_touches 圓點半徑內
THRESHOLD = 8.0      # 亮度偏離基線的判定門檻
Sample = collections.namedtuple("Sample", ["t", "mean"])


def send_tap(stub, x: int, y: int, down: bool) -> None:
    touch = ec.Touch(x=x, y=y, identifier=0, pressure=1024 if down else 0)
    stub.sendTouch(ec.TouchEvent(touches=[touch]), timeout=2)


def stream_worker(stub, samples: collections.deque, stop: threading.Event) -> None:
    req = ec.ImageFormat(format=ec.ImageFormat.RGBA8888)
    for frame in stub.streamScreenshot(req):
        if stop.is_set():
            return
        mean = region_mean(bytes(frame.image),
                           frame.format.width, frame.format.height,
                           TAP_X, TAP_Y, RADIUS)
        samples.append(Sample(time.monotonic(), mean))


def wait_first_change(samples, t0: float, baseline: float, timeout_s: float = 2.0):
    deadline = time.monotonic() + timeout_s
    seen = 0
    while time.monotonic() < deadline:
        snapshot = list(samples)
        for s in snapshot[seen:]:
            if s.t > t0 and changed(s.mean, baseline, THRESHOLD):
                return s.t
        seen = len(snapshot)
        time.sleep(0.001)
    return None


def main() -> int:
    stub = ecg.EmulatorControllerStub(grpc.insecure_channel(TARGET))
    samples: collections.deque = collections.deque(maxlen=600)
    stop = threading.Event()
    threading.Thread(target=stream_worker, args=(stub, samples, stop),
                     daemon=True).start()

    time.sleep(2.0)  # 蒐集基線
    if len(samples) < 10:
        print("FAIL: 串流無幀，確認 emulator 與動畫來源", file=sys.stderr)
        return 1

    latencies_ms: list[float] = []
    misses = 0
    for _ in range(N_SAMPLES):
        baseline = percentile([s.mean for s in list(samples)[-30:]], 50)
        t0 = time.monotonic()
        send_tap(stub, TAP_X, TAP_Y, down=True)
        t1 = wait_first_change(samples, t0, baseline)
        send_tap(stub, TAP_X, TAP_Y, down=False)
        if t1 is None:
            misses += 1
        else:
            latencies_ms.append((t1 - t0) * 1000)
        time.sleep(0.5)  # 等圓點淡出、畫面回穩

    stop.set()
    if not latencies_ms:
        print("FAIL: 全部樣本未偵測到變化——確認 show_touches 已開", file=sys.stderr)
        return 1
    print(f"n={len(latencies_ms)} misses={misses} "
          f"p50={percentile(latencies_ms, 50):.1f}ms "
          f"p95={percentile(latencies_ms, 95):.1f}ms")
    print("註：此值不含 Mac 上屏與螢幕反應，對照 80ms 上限時請加 8–17ms。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 6: 實測**

Run:

```bash
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
"$SDK/platform-tools/adb" shell settings put system show_touches 1
cd phase0/harness && source .venv/bin/activate && python e2e_latency.py
```

Expected: `n=...  misses=0~3  p50=XX.Xms p95=XX.Xms`。判讀（對照 spec §4.2 與 §7）：p50 + 17ms < 80ms → **Go 區間**；p50 + 17ms 在 50ms 內 → 達成理想目標。數據記入 RESULTS.md。
Troubleshooting: 全 miss → 檢查 show_touches；`frame.format.width` 為 0 → 該版本把尺寸放在 `frame.width`，用 `python -c` 印一幀的欄位確認後修正。

- [ ] **Step 7: Commit**

```bash
git add phase0/harness/lib/detector.py phase0/harness/tests/test_detector.py phase0/harness/e2e_latency.py
git commit -m "feat: e2e input-to-photon 量測與畫面變化偵測（TDD）"
```

---

### Task 7: Swift POC — 專案骨架與 gRPC 連通

**Files:**
- Create: `phase0/swift-poc/Package.swift`
- Create: `phase0/swift-poc/Sources/MiragePOC/Generated/`（protoc 產生，commit 進 repo）
- Create: `phase0/swift-poc/Sources/MiragePOC/EmulatorClient.swift`
- Create: `phase0/swift-poc/Sources/MiragePOC/main.swift`

**Interfaces:**
- Consumes: Task 3 的 `protos/emulator_controller.proto`、執行中的 emulator。
- Produces: `EmulatorClient` class——`init(host: String, port: Int) throws`、`func status() async throws -> String`、`func frames() -> AsyncThrowingStream<Frame, Error>`（`Frame` 為 `(width: Int, height: Int, rgba: Data)`）、`func sendTap(x: Int, y: Int, down: Bool) async`。Task 8、9 只透過此類別碰 gRPC。

- [ ] **Step 1: 安裝 codegen 工具**

Run: `brew install protobuf swift-protobuf grpc-swift`
Expected: `protoc --version` 可執行、`which protoc-gen-swift protoc-gen-grpc-swift` 皆有路徑。

- [ ] **Step 2: Package.swift**

```swift
// swift-tools-version:5.9
// phase0/swift-poc/Package.swift
import PackageDescription

let package = Package(
    name: "MiragePOC",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "MiragePOC",
            dependencies: [.product(name: "GRPC", package: "grpc-swift")],
            path: "Sources/MiragePOC"
        ),
    ]
)
```

- [ ] **Step 3: 產生 Swift stub**

```bash
cd phase0/swift-poc
mkdir -p Sources/MiragePOC/Generated
protoc -I ../harness/protos \
  --swift_out=Sources/MiragePOC/Generated \
  --grpc-swift_out=Client=true,Server=false:Sources/MiragePOC/Generated \
  ../harness/protos/emulator_controller.proto
ls Sources/MiragePOC/Generated/
```

Expected: `emulator_controller.pb.swift` 與 `emulator_controller.grpc.swift`。

- [ ] **Step 4: EmulatorClient 封裝**

```swift
// phase0/swift-poc/Sources/MiragePOC/EmulatorClient.swift
// gRPC 唯一封裝點：殼內其他元件不得直接 import GRPC。
import Foundation
import GRPC
import NIOCore
import NIOPosix
import SwiftProtobuf

struct Frame {
    let width: Int
    let height: Int
    let rgba: Data
}

final class EmulatorClient {
    private let group: EventLoopGroup
    private let client: Android_Emulation_Control_EmulatorControllerAsyncClient

    init(host: String = "localhost", port: Int = 8554) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try GRPCChannelPool.with(
            target: .host(host, port: port),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        )
        client = Android_Emulation_Control_EmulatorControllerAsyncClient(channel: channel)
    }

    func status() async throws -> String {
        let status = try await client.getStatus(Google_Protobuf_Empty())
        return status.textFormatString()
    }

    func frames() -> AsyncThrowingStream<Frame, Error> {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        let call = client.streamScreenshot(format)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await img in call {
                        continuation.yield(Frame(
                            width: Int(img.format.width),
                            height: Int(img.format.height),
                            rgba: img.image
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func sendTap(x: Int, y: Int, down: Bool) async {
        var touch = Android_Emulation_Control_Touch()
        touch.x = Int32(x)
        touch.y = Int32(y)
        touch.identifier = 0
        touch.pressure = down ? 1024 : 0
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = [touch]
        _ = try? await client.sendTouch(event)
    }

    deinit { try? group.syncShutdownGracefully() }
}
```

註：型別前綴 `Android_Emulation_Control_` 由 proto 的 `package android.emulation.control` 而來；若產出前綴不同，以 `Generated/*.swift` 內實際名稱為準全域替換。

- [ ] **Step 5: CLI 煙霧測試 main**

```swift
// phase0/swift-poc/Sources/MiragePOC/main.swift
import Foundation

let client = try EmulatorClient()
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        print(try await client.status())
        print("OK: swift gRPC reachable")
    } catch {
        print("FAIL: \(error)")
        exit(1)
    }
    semaphore.signal()
}
semaphore.wait()
```

- [ ] **Step 6: 執行驗證**

Run: `cd phase0/swift-poc && swift run 2>&1 | tail -5`
Expected: emulator 狀態文字 + `OK: swift gRPC reachable`。

- [ ] **Step 7: Commit**

```bash
git add phase0/swift-poc/Package.swift phase0/swift-poc/Sources
git commit -m "feat: swift poc 骨架與 EmulatorClient gRPC 封裝"
```

---

### Task 8: Swift POC — Metal 鏡像視窗

**Files:**
- Create: `phase0/swift-poc/Sources/MiragePOC/Renderer.swift`
- Create: `phase0/swift-poc/Sources/MiragePOC/MirrorView.swift`
- Modify: `phase0/swift-poc/Sources/MiragePOC/main.swift`（改為 AppKit App）

**Interfaces:**
- Consumes: Task 7 `EmulatorClient.frames()`。
- Produces: `MirrorView: MTKView`——`func present(_ frame: Frame)`；`var onMouse: ((_ nx: Double, _ ny: Double, _ down: Bool) -> Void)?`（正規化座標 0–1，Task 9 接上）。

- [ ] **Step 1: Renderer（無 shader：texture 直接 blit 到 drawable）**

```swift
// phase0/swift-poc/Sources/MiragePOC/Renderer.swift
// 畫格上屏：CPU bytes → MTLTexture → blit 到 drawable。
// drawableSize 鎖定 guest 解析度，縮放交給 CAMetalLayer；免 shader。
import Foundation
import MetalKit

final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var texture: MTLTexture?

    init?(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        super.init()
        view.device = device
        view.colorPixelFormat = .rgba8Unorm
        view.framebufferOnly = false
        view.delegate = self
    }

    func upload(_ frame: Frame, into view: MTKView) {
        guard frame.width > 0, frame.height > 0,
              frame.rgba.count == frame.width * frame.height * 4 else { return }
        if texture?.width != frame.width || texture?.height != frame.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: frame.width, height: frame.height, mipmapped: false)
            desc.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: desc)
            DispatchQueue.main.async {
                view.drawableSize = CGSize(width: frame.width, height: frame.height)
                view.window?.contentAspectRatio = NSSize(width: frame.width, height: frame.height)
            }
        }
        frame.rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture?.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0, withBytes: base, bytesPerRow: frame.width * 4)
        }
    }

    func draw(in view: MTKView) {
        guard let texture,
              let drawable = view.currentDrawable,
              drawable.texture.width == texture.width,
              drawable.texture.height == texture.height,
              let cb = queue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture, to: drawable.texture)
        blit.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
```

- [ ] **Step 2: MirrorView（含滑鼠 hook，Task 9 才接線）**

```swift
// phase0/swift-poc/Sources/MiragePOC/MirrorView.swift
import AppKit
import MetalKit

final class MirrorView: MTKView {
    var renderer: Renderer?
    var onMouse: ((_ nx: Double, _ ny: Double, _ down: Bool) -> Void)?

    func present(_ frame: Frame) {
        renderer?.upload(frame, into: self)
    }

    private func normalized(_ event: NSEvent) -> (Double, Double)? {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let nx = p.x / bounds.width
        let ny = 1.0 - (p.y / bounds.height)  // AppKit y 朝上，guest y 朝下
        guard (0...1).contains(nx), (0...1).contains(ny) else { return nil }
        return (nx, ny)
    }

    override func mouseDown(with event: NSEvent) {
        if let (nx, ny) = normalized(event) { onMouse?(nx, ny, true) }
    }
    override func mouseDragged(with event: NSEvent) {
        if let (nx, ny) = normalized(event) { onMouse?(nx, ny, true) }
    }
    override func mouseUp(with event: NSEvent) {
        if let (nx, ny) = normalized(event) { onMouse?(nx, ny, false) }
    }
}
```

- [ ] **Step 3: main.swift 改為 AppKit App**

```swift
// phase0/swift-poc/Sources/MiragePOC/main.swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var client: EmulatorClient!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = MirrorView(frame: NSRect(x: 0, y: 0, width: 390, height: 844))
        view.renderer = Renderer(view: view)

        window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Mirage POC"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        do {
            client = try EmulatorClient()
        } catch {
            fatalError("無法連線 emulator gRPC：\(error)")
        }
        Task {
            do {
                for try await frame in client.frames() {
                    view.present(frame)
                }
            } catch {
                print("串流中斷：\(error)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
```

- [ ] **Step 4: 執行驗證（emulator 執行中）**

Run: `cd phase0/swift-poc && swift run`
Expected: 跳出「Mirage POC」視窗，即時顯示 Android 畫面；縮放視窗維持長寬比不變形。在終端 B 跑 `adb shell input swipe 540 1800 540 600 300` 應看到視窗內畫面滾動。

- [ ] **Step 5: Commit**

```bash
git add phase0/swift-poc/Sources
git commit -m "feat: metal 鏡像視窗——串流上屏與長寬比鎖定"
```

---

### Task 9: Swift POC — 滑鼠直通與體感驗證

**Files:**
- Modify: `phase0/swift-poc/Sources/MiragePOC/main.swift`（接上 `onMouse`）

**Interfaces:**
- Consumes: Task 7 `EmulatorClient.sendTap`、Task 8 `MirrorView.onMouse`。
- Produces: 可互動的鏡像視窗——本任務結束即為 spec §7 Phase 0 第 5 項的完成態。

- [ ] **Step 1: 接線（main.swift 的 applicationDidFinishLaunching 內、建立 client 之後加入）**

```swift
        // 滑鼠 → guest 觸控：正規化座標換算 guest 像素
        var guestSize = (w: 1080, h: 2400)  // 首幀後更新
        view.onMouse = { [weak self] nx, ny, down in
            guard let self else { return }
            let gx = Int(nx * Double(guestSize.w))
            let gy = Int(ny * Double(guestSize.h))
            Task { await self.client.sendTap(x: gx, y: gy, down: down) }
        }
```

並在串流迴圈內首幀時更新尺寸（`for try await frame in client.frames()` 迴圈開頭加）：

```swift
                    guestSize = (frame.width, frame.height)
```

- [ ] **Step 2: 執行體感驗證**

Run: `cd phase0/swift-poc && swift run`
Expected: 視窗內點擊 = guest 點擊（開 app、按按鈕）、按住拖曳 = 滑動。開著 `show_touches` 觀察白點是否貼合游標位置——偏移代表座標換算錯，回 Step 1 檢查 y 軸翻轉。
主觀判定並記錄：點擊回饋是否「跟手」。這是數據之外的品味檢查，寫進 RESULTS.md 的定性欄位。

- [ ] **Step 3: Commit**

```bash
git add phase0/swift-poc/Sources/MiragePOC/main.swift
git commit -m "feat: 滑鼠直通——鏡像視窗可互動"
```

---

### Task 10: RESULTS.md、README 與 go/no-go 判定

**Files:**
- Create: `phase0/RESULTS.md`
- Create: `phase0/README.md`

**Interfaces:**
- Consumes: Task 4/5/6 的實測輸出、Task 9 的定性觀察。
- Produces: go/no-go 判定紀錄——Phase 1 開工（或啟動備援路線）的依據。

- [ ] **Step 1: RESULTS.md 模板（跑完量測後填數字）**

```markdown
# Phase 0 實測結果（日期：____）

環境：Mac 機型 ____ / macOS ____ / emulator 版本 ____ / 映像 android-35 default arm64

| 量測項 | 預算（spec §4.2/§7） | 實測 | 判定 |
|---|---|---|---|
| 串流 fps（RGBA 原生） | ≥ 60fps 穩定 | ___ fps, p95 幀間隔 ___ ms | ⬜ |
| 串流每幀大小/吞吐 | （紀錄用） | ___ MiB/幀, ___ MiB/s | — |
| sendTouch 注入 RTT p50 | < 3ms | ___ ms | ⬜ |
| E2E input-to-photon p50（+17ms 上屏） | < 50ms 目標 / < 80ms 上限 | ___ + 17 = ___ ms | ⬜ |
| E2E p95（+17ms） | < 80ms | ___ ms | ⬜ |
| Swift 視窗體感（定性） | 「跟手」 | ____ | ⬜ |

## 判定

- [ ] **GO**：延遲 < 80ms 且 60fps 穩定 → 進 Phase 1
- [ ] **NO-GO**：不達標 → 啟動備援 (a) WebRTC（參考官方 container scripts）；
      (a) 再不達標 → (b) fork + 共享記憶體；備援驗證限時 2 週（spec §7）

## 觀察與備註

（幀率抖動、CPU/記憶體佔用、意外行為……）
```

- [ ] **Step 2: README.md（執行指南）**

```markdown
# Phase 0 技術驗證

目的：驗證「headless 官方 emulator + gRPC 串流/輸入」可達 spec §4.2 延遲預算。詳見
`../docs/plans/2026-07-22-phase0-validation.md`。

## 執行順序

1. `scripts/00_install_sdk.sh` — 安裝 SDK 與映像
2. `scripts/01_create_avd.sh` — 建立 mirage-poc AVD
3. `scripts/02_boot_headless.sh` — 啟動（保持前景）
4. `scripts/03_wait_boot.sh` — 等 BOOTED
5. harness 量測（`harness/` 內，先 `source .venv/bin/activate`）：
   - `python -m pytest tests/ -v` — 單元測試
   - `python smoke_grpc.py` — 連通
   - `python stream_bench.py --format rgba --seconds 10` — 幀率（另開終端跑動畫，見計畫 Task 4 Step 6）
   - `python input_latency.py` — 注入 RTT
   - `adb shell settings put system show_touches 1 && python e2e_latency.py` — 端到端
6. `cd swift-poc && swift run` — 鏡像視窗體感驗證
7. 數據填入 `RESULTS.md`，做 go/no-go 判定
```

- [ ] **Step 3: 填入實測數據並判定**

跑完 Task 4–9 的所有量測，把數字填進 RESULTS.md，勾選 GO 或 NO-GO。

- [ ] **Step 4: Commit**

```bash
git add phase0/RESULTS.md phase0/README.md
git commit -m "docs: phase0 實測結果與 go/no-go 判定"
```

---

## Self-Review 紀錄

- **Spec 覆蓋**：spec §7 Phase 0 五項 → (1) headless 啟動 = Task 2；(2) streamScreenshot 60fps 與格式成本 = Task 4；(3) 注入延遲 = Task 5；(4) 端到端量測 = Task 6；(5) Swift Metal POC = Task 7–9。判定與備援紀錄 = Task 10。無缺口。
- **佔位掃描**：無 TBD/TODO;所有程式碼步驟均附完整程式碼；proto 欄位名的版本差異以「grep 確認 + 對照修正」處理，非佔位。
- **型別一致性**：`send_tap` 簽名 Task 5 = Task 6;`StreamStats` 欄位、`percentile`/`summarize`/`region_mean`/`changed` 簽名跨任務一致；Swift `Frame`/`EmulatorClient`/`MirrorView.onMouse` 於 Task 7/8/9 一致。



