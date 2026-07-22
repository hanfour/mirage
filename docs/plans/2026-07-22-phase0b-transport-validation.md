# Mirage Phase 0b 顯示傳輸備援驗證 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 對照驗證兩條顯示傳輸備援——(1) emulator 內建 `ImageTransport.MMAP` 共享記憶體通道、(2) 編碼串流路徑（guest H.264 編碼 + adb 傳輸，WebRTC 在 macOS 的等效架構）——與 Phase 0 的 gRPC 原始畫格基線比較，選出 Phase 1 的顯示路徑。

**Architecture:** 沿用 Phase 0 的量測 harness（animate.py 動畫源、stats/detector 純函式、show_touches e2e 方法論）。MMAP 軌：客戶端給 `file:///` handle，emulator 直寫共享記憶體，gRPC 只送通知——消滅每幀 10MiB 序列化；Python 先驗可行性與數據，Swift Release 出終裁 fps。編碼軌：`adb exec-out screenrecord` H.264 裸流 + PyAV 解碼量測。全程不 fork、不改 emulator。

**Tech Stack:** 既有 Phase 0 harness（Python 3.13 venv、grpcio、numpy、pytest）+ PyAV（`av`，內含 ffmpeg）；Swift POC（grpc-swift 1.27.5 已釘版）+ POSIX mmap。

## Global Constraints

- 背景：Phase 0 已判 gRPC 原始畫格 NO-GO（native ~29-30fps / 縮放 ~42fps 平台；數據見 `phase0/RESULTS.md`）。本驗證是 spec §7 的備援程序，**時限 2 週**（行事曆時間）。
- **不 fork emulator、不改 emulator 本體**；只用官方 prebuilt（36.6.11.0）既有介面。
- 閘門與 Phase 0 相同：串流穩定 ≥60fps；e2e p50+17ms < 80ms（上限）/ < 50ms（理想）。
- 量測紀律（Phase 0 教訓，違者數據作廢）：
  - 動畫源一律用 `harness/animate.py`（連續注入）；禁用 adb input swipe 迴圈。
  - Swift fps 數字一律用 **Release build**。
  - 吞吐佐證必須寫明量的是「容量」還是「達成值」。
  - 量測前確認 host load（`uptime`）；load 高於核心數時數據標記為 contaminated 並擇時重測。
- proto 事實（已於 2026-07-22 讀取本機 SDK 查證）：`ImageFormat.transport = 6`（`ImageTransport{channel: MMAP, handle: string}`，handle 為 `file:///` URL，客戶端建立並持有；proto 註明 mmap 可能 tearing）。macOS gRPC 面**無任何 WebRTC/JSEP 服務**。
- MMAP 軌若在 macOS prebuilt 上實測不可用（Task 1 的探測結果為準），編碼軌升為主選，RESULTS-0b 必記原因。
- 程式風格：沿用 harness 慣例（模組常數、小函式、邊界驗證、fail fast）；`lib/` 只放可單元測試的純邏輯。
- Commit：conventional commits，不加 attribution。AVD `mirage-poc`、gRPC `localhost:8554` 不變。

## File Structure

```
phase0/harness/
├── requirements.txt            # 修改：加 av>=12
├── lib/
│   └── mmap_source.py          # 新增：mmap handle/緩衝區純邏輯（TDD）
├── tests/
│   └── test_mmap_source.py     # 新增
├── probe_mmap.py               # 新增：MMAP 通道可用性探測（Task 1 的 go/no-go）
├── stream_bench.py             # 修改：加 --transport {grpc,mmap}
├── e2e_latency.py              # 修改：加 --transport {grpc,mmap}
└── encoded_bench.py            # 新增：screenrecord H.264 + PyAV（--mode fps|e2e）
phase0/swift-poc/Sources/MiragePOC/
├── EmulatorClient.swift        # 修改：加 framesMmap(path:width:height:)
└── main.swift                  # 修改：MIRAGE_TRANSPORT=mmap 切換
phase0/RESULTS-0b.md            # 新增：對照數據與 Phase 1 選型判定
phase0/README.md                # 修改：補 0b 執行步驟一節
```

---

### Task 1: MMAP 探測與 mmap_source（TDD）

**Files:**
- Create: `phase0/harness/lib/mmap_source.py`
- Create: `phase0/harness/tests/test_mmap_source.py`
- Create: `phase0/harness/probe_mmap.py`

**Interfaces:**
- Consumes: Phase 0 stub（`gen/`）、執行中的 emulator。
- Produces: `make_handle(path: str) -> str`（絕對路徑 → `file:///` URL，非絕對路徑丟 ValueError）；`open_frame_buffer(path: str, width: int, height: int) -> mmap.mmap`（建立/截斷檔案至 w*h*4 並回傳可讀 mmap）；`frame_array(buf, width, height) -> np.ndarray`（zero-copy 檢視 (h,w,4)，尺寸不符丟 ValueError）。Task 2/3 直接 import。**探測結論（Image 訊息 payload 是否為空、emulator 是否自建檔案、幀是否真的落在 mmap）寫入報告，Task 2-4 依探測事實微調。**

- [ ] **Step 1: 寫失敗測試**

```python
# phase0/harness/tests/test_mmap_source.py
import mmap as mmap_mod

import numpy as np
import pytest

from lib.mmap_source import frame_array, make_handle, open_frame_buffer

W, H = 4, 3  # 4x3x4 = 48 bytes，測試用小尺寸


def test_make_handle_absolute_path():
    assert make_handle("/tmp/frames.bin") == "file:///tmp/frames.bin"


def test_make_handle_rejects_relative():
    with pytest.raises(ValueError):
        make_handle("frames.bin")


def test_open_frame_buffer_creates_and_sizes(tmp_path):
    p = str(tmp_path / "buf.bin")
    buf = open_frame_buffer(p, W, H)
    assert len(buf) == W * H * 4
    buf.close()


def test_frame_array_roundtrip(tmp_path):
    p = str(tmp_path / "buf.bin")
    buf = open_frame_buffer(p, W, H)
    with open(p, "r+b") as f:
        f.write(bytes(range(48)))
    arr = frame_array(buf, W, H)
    assert arr.shape == (H, W, 4)
    assert arr[0, 0, 0] == 0 and arr[2, 3, 3] == 47
    buf.close()


def test_frame_array_rejects_size_mismatch(tmp_path):
    p = str(tmp_path / "buf.bin")
    buf = open_frame_buffer(p, W, H)
    with pytest.raises(ValueError):
        frame_array(buf, W + 1, H)
    buf.close()
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/phase0/harness && source .venv/bin/activate && python -m pytest tests/test_mmap_source.py -v`
Expected: FAIL（`ModuleNotFoundError: No module named 'lib.mmap_source'`）。

- [ ] **Step 3: 最小實作**

```python
# phase0/harness/lib/mmap_source.py
"""MMAP 畫格緩衝區的純邏輯：handle 產生、緩衝區建立、zero-copy 檢視。"""
import mmap
import os

import numpy as np


def make_handle(path: str) -> str:
    if not os.path.isabs(path):
        raise ValueError(f"handle 需要絕對路徑，收到 {path!r}")
    return f"file://{path}"


def open_frame_buffer(path: str, width: int, height: int) -> mmap.mmap:
    size = width * height * 4
    if size <= 0:
        raise ValueError(f"無效尺寸 {width}x{height}")
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        os.ftruncate(fd, size)
        return mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ)
    finally:
        os.close(fd)  # mmap 持有自己的參照，fd 可關


def frame_array(buf: mmap.mmap, width: int, height: int) -> np.ndarray:
    expected = width * height * 4
    if len(buf) != expected:
        raise ValueError(f"緩衝區 {len(buf)} bytes != {expected}（{width}x{height} RGBA）")
    return np.frombuffer(buf, dtype=np.uint8).reshape(height, width, 4)
```

- [ ] **Step 4: 跑測試確認通過**

Run: `python -m pytest tests/ -v`
Expected: 17 passed（Phase 0 的 12 + 本任務 5）。

- [ ] **Step 5: 探測腳本**

```python
# phase0/harness/probe_mmap.py
"""MMAP 通道可用性探測——本計畫的 go/no-go 閘門。

回答四個問題：
  1. streamScreenshot 帶 MMAP transport 會不會直接報錯？
  2. Image 訊息的 image payload 是否為空（資料走 mmap 而非 gRPC）？
  3. mmap 檔案內容是否隨畫面變化（動畫下連續三幀 hash 應不同）？
  4. 訊息裡 format.width/height 是否照常回報？
前置：emulator 執行中；另終端跑 `python animate.py --seconds 30` 供應動畫。
"""
import hashlib
import sys
import tempfile
import time

sys.path.insert(0, "gen")

import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.mmap_source import frame_array, make_handle, open_frame_buffer

TARGET = "localhost:8554"
GUEST_W, GUEST_H = 1080, 2400
N_PROBE_FRAMES = 5


def main() -> int:
    path = tempfile.mktemp(prefix="mirage_mmap_", suffix=".bin")
    buf = open_frame_buffer(path, GUEST_W, GUEST_H)
    channel = grpc.insecure_channel(
        TARGET, options=[("grpc.max_receive_message_length", -1)])
    stub = ecg.EmulatorControllerStub(channel)
    fmt = ec.ImageFormat(
        format=ec.ImageFormat.RGBA8888,
        transport=ec.ImageTransport(
            channel=ec.ImageTransport.MMAP, handle=make_handle(path)),
    )
    print(f"handle={make_handle(path)}")
    hashes = []
    try:
        for i, frame in enumerate(stub.streamScreenshot(fmt)):
            arr = frame_array(buf, GUEST_W, GUEST_H)
            digest = hashlib.md5(arr.tobytes()).hexdigest()[:12]
            hashes.append(digest)
            print(f"frame {i}: payload_bytes={len(frame.image)} "
                  f"reported={frame.format.width}x{frame.format.height} "
                  f"mmap_md5={digest} mmap_nonzero={bool(arr.any())}")
            if i + 1 >= N_PROBE_FRAMES:
                break
    except grpc.RpcError as err:
        print(f"PROBE FAIL: gRPC {err.code().name}: {err.details()}",
              file=sys.stderr)
        return 1
    finally:
        buf.close()

    distinct = len(set(hashes))
    verdict = "MMAP_OK" if distinct >= 2 else "MMAP_SUSPECT(內容未變化)"
    print(f"distinct_hashes={distinct}/{len(hashes)} -> {verdict}")
    return 0 if distinct >= 2 else 2


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 6: 實測探測（emulator 執行中 + animate.py 動畫供應）**

Run（終端 B）: `python animate.py --seconds 30`
Run（終端 A）: `python probe_mmap.py`
Expected: 5 行 frame 輸出 + `MMAP_OK`。關鍵判讀記入報告：
- `payload_bytes` ≈ 0 → 資料真的走 mmap（**預期**）；若仍 ~10MB → MMAP 未生效，檢查 handle 格式（`file://` vs `file:///`、權限），重試一次。
- 探測失敗（RpcError / hash 不變 / payload 仍滿載）且排除 handle 格式問題 → **MMAP 軌在 macOS prebuilt 不可用**：記錄證據，本計畫 Task 2-4 標記 SKIPPED，編碼軌（Task 5）升為主選。
- 若 `frame.format.width` 回報為 0，Task 2-4 的尺寸一律用探測時的已知值（1080x2400），記入報告。

- [ ] **Step 7: Commit**

```bash
git add phase0/harness/lib/mmap_source.py phase0/harness/tests/test_mmap_source.py phase0/harness/probe_mmap.py
git commit -m "feat: mmap 傳輸探測與緩衝區工具（TDD）"
```

---

### Task 2: stream_bench 加 mmap 傳輸模式

**Files:**
- Modify: `phase0/harness/stream_bench.py`

**Interfaces:**
- Consumes: Task 1 的 `make_handle`/`open_frame_buffer`/`frame_array` 與探測結論。
- Produces: `stream_bench.py --transport mmap [--width W --height H]`；輸出行尾加 ` transport=mmap`。Task 6 引用其輸出行。

- [ ] **Step 1: 修改 stream_bench.py**

在現有檔案上加 `--transport` 參數（預設 `grpc`，行為完全不變——向後相容是鐵律）。修改後的完整 `bench` 與 `main`：

```python
def bench(fmt_name: str, seconds: int, width: int, height: int,
          transport: str) -> None:
    channel = grpc.insecure_channel(
        TARGET, options=[("grpc.max_receive_message_length", -1)])
    stub = ecg.EmulatorControllerStub(channel)
    req = ec.ImageFormat(format=FORMATS[fmt_name])
    if width:
        req.width = width
    if height:
        req.height = height

    buf = None
    mmap_path = None
    if transport == "mmap":
        import tempfile
        from lib.mmap_source import frame_array, make_handle, open_frame_buffer
        w = width or 1080
        h = height or 2400
        mmap_path = tempfile.mktemp(prefix="mirage_bench_", suffix=".bin")
        buf = open_frame_buffer(mmap_path, w, h)
        req.transport.CopyFrom(ec.ImageTransport(
            channel=ec.ImageTransport.MMAP, handle=make_handle(mmap_path)))

    timestamps: list[float] = []
    total_bytes = 0
    deadline = time.monotonic() + seconds
    try:
        for frame in stub.streamScreenshot(req):
            now = time.monotonic()
            timestamps.append(now)
            if transport == "mmap":
                w = width or 1080
                h = height or 2400
                total_bytes += frame_array(buf, w, h).nbytes  # mmap 讀取量
            else:
                total_bytes += len(frame.image)
            if now >= deadline:
                break
    finally:
        if buf is not None:
            buf.close()

    stats = summarize(timestamps)
    avg_mb = total_bytes / stats.frames / 1_048_576
    size_note = f" size={width}x{height}" if width or height else ""
    print(f"format={fmt_name} frames={stats.frames} fps={stats.fps:.1f} "
          f"p50={stats.p50_ms:.1f}ms p95={stats.p95_ms:.1f}ms "
          f"avg_frame={avg_mb:.2f}MiB throughput={avg_mb * stats.fps:.0f}MiB/s"
          f"{size_note} transport={transport}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--format", choices=FORMATS, required=True)
    parser.add_argument("--seconds", type=int, default=10)
    parser.add_argument("--width", type=int, default=0)
    parser.add_argument("--height", type=int, default=0)
    parser.add_argument("--transport", choices=("grpc", "mmap"),
                        default="grpc")
    args = parser.parse_args()
    if args.seconds < 3:
        parser.error("--seconds 至少 3 秒才有統計意義")
    if args.width < 0 or args.height < 0:
        parser.error("--width/--height 不可為負")
    if (args.width > 0) != (args.height > 0):
        parser.error("--width 與 --height 需成對指定")
    if args.transport == "mmap" and args.format != "rgba":
        parser.error("mmap 傳輸僅支援 rgba 格式")
    bench(args.format, args.seconds, args.width, args.height, args.transport)
    return 0
```

註：探測（Task 1）若確認 `frame.format.width` 有回報，可把 mmap 尺寸改讀訊息欄位；預設用參數/1080x2400 是探測結論的保守解。既有 grpc 模式的輸出行**不得**出現 ` transport=grpc` 以外的變化——舊輸出格式已被 RESULTS.md 引用。

- [ ] **Step 2: 迴歸驗證（grpc 模式不變）**

Run（終端 B）: `python animate.py --seconds 40`
Run（終端 A）: `python stream_bench.py --format rgba --seconds 8`
Expected: 輸出行格式與 Phase 0 相同 + 行尾 ` transport=grpc`；fps 與歷史基準同量級（host load 正常前提下 ~25-35fps）。

- [ ] **Step 3: mmap 實測（同一動畫源session）**

Run: `python stream_bench.py --format rgba --seconds 8 --transport mmap && python stream_bench.py --format rgba --seconds 8 --width 720 --height 1600 --transport mmap`
Expected: 兩行結果，記錄 verbatim。判讀：native mmap fps 應顯著高於 grpc 的 ~30fps；若 ≥55fps 即進入綠區。低於 grpc 基準 → 檢查 payload 是否真的為空（回 Task 1 探測結論）。

- [ ] **Step 4: 單元測試迴歸**

Run: `python -m pytest tests/ -v`
Expected: 17 passed。

- [ ] **Step 5: Commit**

```bash
git add phase0/harness/stream_bench.py
git commit -m "feat: stream_bench 支援 mmap 傳輸模式"
```

---

### Task 3: e2e_latency 加 mmap 傳輸模式

**Files:**
- Modify: `phase0/harness/e2e_latency.py`

**Interfaces:**
- Consumes: Task 1 工具、Task 2 的 transport 參數慣例。
- Produces: `e2e_latency.py --transport mmap` 輸出行尾 ` transport=mmap`。Task 6 引用。

- [ ] **Step 1: 修改 e2e_latency.py**

加 `--transport` 參數（argparse，預設 `grpc`）。`stream_worker` 改為：

```python
def stream_worker(stub, samples: collections.deque, stop: threading.Event,
                  transport: str) -> None:
    req = ec.ImageFormat(format=ec.ImageFormat.RGBA8888)
    buf = None
    if transport == "mmap":
        import tempfile
        from lib.mmap_source import frame_array, make_handle, open_frame_buffer
        path = tempfile.mktemp(prefix="mirage_e2e_", suffix=".bin")
        buf = open_frame_buffer(path, GUEST_W, GUEST_H)
        req.transport.CopyFrom(ec.ImageTransport(
            channel=ec.ImageTransport.MMAP, handle=make_handle(path)))
    try:
        for frame in stub.streamScreenshot(req):
            if stop.is_set():
                return
            if transport == "mmap":
                arr = frame_array(buf, GUEST_W, GUEST_H)
                region = arr[TAP_Y - RADIUS:TAP_Y + RADIUS,
                             TAP_X - RADIUS:TAP_X + RADIUS, :3]
                mean = float(region.mean())
            else:
                mean = region_mean(bytes(frame.image),
                                   frame.format.width, frame.format.height,
                                   TAP_X, TAP_Y, RADIUS)
            samples.append(Sample(time.monotonic(), mean))
    finally:
        if buf is not None:
            buf.close()
```

檔案頂部加 `GUEST_W, GUEST_H = 1080, 2400` 常數；`main()` 開頭 argparse 讀 `--transport` 並傳給 worker thread args；輸出行改為 `print(f"n=... p50=...ms p95=...ms transport={transport}")`（grpc 模式行尾加 ` transport=grpc`，其餘不變）。mmap 模式的區域平均直接在 zero-copy 檢視上切片——這是 mmap 的延遲優勢來源之一（無 10MB 拷貝、無 protobuf 解析）。

- [ ] **Step 2: grpc 迴歸 + mmap 實測**

Run:

```bash
~/Library/Android/sdk/platform-tools/adb shell settings put system show_touches 1
python e2e_latency.py                      # grpc 迴歸
python e2e_latency.py --transport mmap     # mmap 實測
~/Library/Android/sdk/platform-tools/adb shell settings put system show_touches 0
```

Expected: 兩行結果 verbatim 記錄。判讀：mmap p50 應 ≤ grpc 的 51-57ms；p50+17 < 50ms 即達理想目標。（此量測自供動畫，毋需 animate.py。）

- [ ] **Step 3: 單元測試迴歸**

Run: `python -m pytest tests/ -v`
Expected: 17 passed。

- [ ] **Step 4: Commit**

```bash
git add phase0/harness/e2e_latency.py
git commit -m "feat: e2e_latency 支援 mmap 傳輸模式"
```

---

### Task 4: Swift MMAP 消費（產品路徑終裁數字）

**Files:**
- Modify: `phase0/swift-poc/Sources/MiragePOC/EmulatorClient.swift`
- Modify: `phase0/swift-poc/Sources/MiragePOC/main.swift`

**Interfaces:**
- Consumes: Task 1 探測結論（handle 格式、payload 空載）；既有 `Frame`/`frames(width:height:)`。
- Produces: `framesMmap(path: String, width: Int, height: Int) -> AsyncThrowingStream<Frame, Error>`；`MIRAGE_TRANSPORT=mmap` 環境變數切換。**此任務的 Release fps 是 MMAP 軌的 go/no-go 數字。**

- [ ] **Step 1: EmulatorClient 加 framesMmap**

在 `EmulatorClient` class 內、`frames(width:height:)` 之後加：

```swift
    // MMAP 傳輸：emulator 直寫共享記憶體，gRPC 只送畫格通知。
    // 每次通知從 mmap 區域拷貝一幀成 Data（POC 級；產品可 zero-copy 進 MTLBuffer）。
    func framesMmap(path: String, width: Int, height: Int)
        -> AsyncThrowingStream<Frame, Error>
    {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        var transport = Android_Emulation_Control_ImageTransport()
        transport.channel = .mmap
        transport.handle = "file://\(path)"
        format.transport = transport

        let size = width * height * 4
        let call = client.streamScreenshot(format)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let fd = open(path, O_RDONLY)
                guard fd >= 0 else {
                    continuation.finish(throwing: POSIXError(.ENOENT))
                    return
                }
                guard let base = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0),
                      base != MAP_FAILED else {
                    close(fd)
                    continuation.finish(throwing: POSIXError(.ENOMEM))
                    return
                }
                defer { munmap(base, size); close(fd) }
                do {
                    for try await _ in call {
                        let rgba = Data(bytes: base, count: size)
                        continuation.yield(Frame(width: width, height: height,
                                                 rgba: rgba))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
```

註：mmap 檔案由呼叫端先建好（main.swift Step 2 用 `FileManager` + `truncate`）；emulator 是否自建檔案以 Task 1 探測結論為準——若 emulator 自建，仍先建檔無害（冪等）。

- [ ] **Step 2: main.swift 加傳輸切換**

把串流啟動段改為（保留既有 fps counter，僅換 frame 來源；`// AUTHORIZED EXTENSION` 標註沿用）：

```swift
        let useMmap = ProcessInfo.processInfo.environment["MIRAGE_TRANSPORT"] == "mmap"
        Task {
            do {
                let stream: AsyncThrowingStream<Frame, Error>
                if useMmap {
                    let w = 1080, h = 2400
                    let path = NSTemporaryDirectory() + "mirage_swift_mmap.bin"
                    FileManager.default.createFile(atPath: path, contents: nil)
                    let fh = FileHandle(forWritingAtPath: path)
                    try fh?.truncate(atOffset: UInt64(w * h * 4))
                    try fh?.close()
                    print("[transport] mmap \(path)")
                    stream = client.framesMmap(path: path, width: w, height: h)
                } else {
                    print("[transport] grpc")
                    stream = client.frames()
                }
                for try await frame in stream {
                    guestSize = (frame.width, frame.height)
                    view.present(frame)
                    // ……既有 fps counter 保持不動……
                }
            } catch {
                print("串流中斷：\(error)")
            }
        }
```

（實作時以現檔為準融合——fps counter 與 guestSize 更新已存在於迴圈內，不得重複。）

- [ ] **Step 3: 建置與 Release 實測**

Run: `cd /Users/hanfourhuang/Projects/mirage/phase0/swift-poc && swift build && swift build -c release`
Expected: 兩者 Build complete。

Run（終端 B）: `cd ../harness && source .venv/bin/activate && python animate.py --seconds 30`
Run（終端 A）: `MIRAGE_TRANSPORT=mmap ./.build/release/MiragePOC > /tmp/mirage_mmap_fps.log 2>&1 &`，20 秒後 `kill %1; grep "\[stream\]" /tmp/mirage_mmap_fps.log | tail -15`
Expected: `[transport] mmap` + 連續 fps 行。**verbatim 記錄——這是 MMAP 軌終裁數字**（閘門 ≥60fps；對照 grpc 模式同法再量一次作 A/B）。

- [ ] **Step 4: Commit**

```bash
git add phase0/swift-poc/Sources/MiragePOC/EmulatorClient.swift phase0/swift-poc/Sources/MiragePOC/main.swift
git commit -m "feat: swift poc mmap 傳輸消費與切換"
```

---

### Task 5: 編碼串流路徑（WebRTC 等效）基準

**Files:**
- Modify: `phase0/harness/requirements.txt`（加 `av>=12`）
- Create: `phase0/harness/encoded_bench.py`

**Interfaces:**
- Consumes: `lib/stats.summarize`/`percentile`、`lib/detector.changed`、animate.py、adb。
- Produces: `encoded_bench.py --mode fps|e2e` 輸出行。Task 6 引用。**範圍聲明：macOS emulator 無內建 WebRTC；本任務量測其等效架構（guest H.264 編碼 → 傳輸 → 主機解碼），數字代表「編碼路徑」類方案（WebRTC/scrcpy 同族）的體感底線。**

- [ ] **Step 1: 裝 PyAV**

`requirements.txt` 加一行 `av>=12`；Run: `pip install -r requirements.txt && python -c "import av; print(av.__version__)"`
Expected: 版本號印出（av wheel 內含 ffmpeg，毋需另裝）。

- [ ] **Step 2: encoded_bench.py**

```python
# phase0/harness/encoded_bench.py
"""編碼串流路徑基準：guest H.264 編碼（screenrecord）→ adb 管線 → PyAV 解碼。

  python encoded_bench.py --mode fps --seconds 15   # 解碼幀率（配 animate.py）
  python encoded_bench.py --mode e2e --samples 30   # 端到端延遲（show_touches 需先開）
量測含 guest 編碼 + 傳輸 + 主機解碼——與 MMAP/gRPC 數字同一把尺（不含上屏）。
"""
import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, "gen")

import av
import grpc
import numpy as np
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.stats import percentile, summarize

ADB = os.path.expanduser(
    os.environ.get("ANDROID_SDK_ROOT", "~/Library/Android/sdk")
) + "/platform-tools/adb"
TARGET = "localhost:8554"
TAP_X, TAP_Y, RADIUS, THRESHOLD = 540, 1200, 60, 8.0


def open_decoder(seconds: int):
    proc = subprocess.Popen(
        [ADB, "exec-out", "screenrecord", "--output-format=h264",
         "--bit-rate", "8000000", "--time-limit", str(seconds), "-"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    container = av.open(proc.stdout, format="h264")
    return proc, container


def decoded_frames(container):
    for packet in container.demux(video=0):
        for frame in packet.decode():
            yield time.monotonic(), frame


def mode_fps(seconds: int) -> int:
    proc, container = open_decoder(seconds)
    timestamps = [t for t, _ in decoded_frames(container)]
    proc.wait()
    if len(timestamps) < 2:
        print("FAIL: 無解碼幀——確認 animate.py 供應動畫、guest 支援 screenrecord",
              file=sys.stderr)
        return 1
    s = summarize(timestamps[5:])  # 丟 5 幀 warm-up（Phase 0 慣例）
    print(f"mode=fps frames={s.frames} fps={s.fps:.1f} "
          f"p50={s.p50_ms:.1f}ms p95={s.p95_ms:.1f}ms transport=h264")
    return 0


def region_mean_rgb(frame: "av.VideoFrame") -> float:
    arr = frame.to_ndarray(format="rgb24")
    h, w = arr.shape[:2]
    sy, sx = h / 2400, w / 1080  # screenrecord 可能縮放輸出
    cy, cx = int(TAP_Y * sy), int(TAP_X * sx)
    r = max(int(RADIUS * sy), 8)
    return float(arr[max(cy - r, 0):cy + r, max(cx - r, 0):cx + r].mean())


def mode_e2e(samples_n: int) -> int:
    stub = ecg.EmulatorControllerStub(grpc.insecure_channel(TARGET))

    def tap(down: bool) -> None:
        touch = ec.Touch(x=TAP_X, y=TAP_Y, identifier=0,
                         pressure=1024 if down else 0)
        stub.sendTouch(ec.TouchEvent(touches=[touch]), timeout=2)

    proc, container = open_decoder(samples_n * 2 + 10)
    gen = decoded_frames(container)
    baseline_means = [region_mean_rgb(f) for _, f in
                      (next(gen) for _ in range(10))]
    baseline = percentile(baseline_means, 50)

    latencies, misses = [], 0
    for _ in range(samples_n):
        t0 = time.monotonic()
        tap(down=True)
        t1 = None
        for t, f in gen:
            if t - t0 > 2.0:
                break
            if abs(region_mean_rgb(f) - baseline) > THRESHOLD:
                t1 = t
                break
        tap(down=False)
        if t1 is None:
            misses += 1
        else:
            latencies.append((t1 - t0) * 1000)
        time.sleep(0.4)
    proc.kill()
    if not latencies:
        print("FAIL: 全 miss——確認 show_touches=1", file=sys.stderr)
        return 1
    print(f"mode=e2e n={len(latencies)} misses={misses} "
          f"p50={percentile(latencies, 50):.1f}ms "
          f"p95={percentile(latencies, 95):.1f}ms transport=h264")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("fps", "e2e"), required=True)
    parser.add_argument("--seconds", type=int, default=15)
    parser.add_argument("--samples", type=int, default=30)
    args = parser.parse_args()
    if args.seconds < 5 or args.samples < 5:
        parser.error("--seconds ≥5、--samples ≥5")
    return mode_fps(args.seconds) if args.mode == "fps" else mode_e2e(args.samples)


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 3: 實測**

Run（終端 B）: `python animate.py --seconds 40`
Run（終端 A）:

```bash
python encoded_bench.py --mode fps --seconds 15
~/Library/Android/sdk/platform-tools/adb shell settings put system show_touches 1
python encoded_bench.py --mode e2e --samples 30
~/Library/Android/sdk/platform-tools/adb shell settings put system show_touches 0
```

Expected: 兩行結果 verbatim 記錄。已知風險：AOSP default 映像的 guest 編碼器可能是軟體實作（fps 受限）或 screenrecord 不可用——失敗本身就是有效發現（「編碼路徑需 guest 硬編碼器支援」），照實記錄，不硬修。e2e 數字預期高於 MMAP（多了編碼+解碼延遲）——這正是要量化的差距。

- [ ] **Step 4: 單元測試迴歸 + Commit**

Run: `python -m pytest tests/ -v` → 17 passed。

```bash
git add phase0/harness/requirements.txt phase0/harness/encoded_bench.py
git commit -m "feat: 編碼串流路徑基準（screenrecord H.264 + PyAV）"
```

---

### Task 6: RESULTS-0b 對照判定與 README 更新

**Files:**
- Create: `phase0/RESULTS-0b.md`
- Modify: `phase0/README.md`（加「Phase 0b 傳輸驗證」一節）

**Interfaces:**
- Consumes: Task 1-5 的全部 verbatim 輸出行、Phase 0 基線（`phase0/RESULTS.md`）。
- Produces: Phase 1 顯示路徑選型判定——本計畫的最終交付物。

- [ ] **Step 1: RESULTS-0b.md（跑完量測後填實數）**

```markdown
# Phase 0b 顯示傳輸備援驗證結果（日期：____）

環境：____（與 Phase 0 相同則註明；host load 量測時值：____）
前情：Phase 0 判 gRPC 原始畫格 NO-GO（native ~29-30fps）。本驗證比較三條傳輸。

## 對照表（不含上屏；e2e 為 p50+17ms 換算）

| 傳輸 | fps（native, 持續動畫） | e2e p50+17ms | e2e p95+17ms | 客戶端 CPU | 備註 |
|---|---|---|---|---|---|
| gRPC 原始畫格（Phase 0 基線） | ~29-30fps ❌ | 68-74ms ✅ | ~82ms ❌ | Release ~15% | 每幀 10MiB 序列化 |
| **MMAP 共享記憶體**（Python） | ___ | ___ | ___ | ___ | |
| **MMAP 共享記憶體**（Swift Release） | ___ | —（沿用 Python e2e） | — | ___ | 終裁數字 |
| 編碼 H.264（screenrecord+PyAV） | ___ | ___ | ___ | ___ | WebRTC 等效架構 |

閘門：fps ≥60 穩定；e2e p50+17 < 80ms（上限）/ 50ms（理想）。

## MMAP 探測結論（Task 1）

- payload_bytes：___（0 = 資料走 mmap）
- emulator 是否自建/接受既有檔案：___
- tearing 觀察：___（方法與程度）

## 判定

- [ ] **MMAP 為 Phase 1 顯示路徑**：條件——fps ≥60 且 e2e 達標
- [ ] **編碼路徑為 Phase 1 顯示路徑**：條件——MMAP 不可用/不達標且 H.264 達標
- [ ] **兩者皆不達標** → 啟動計畫外備援（fork + 自訂傳輸），Phase 1 延後，回報決策者

## 觀察與備註

（tearing、guest 編碼器能力、穩定性事件、方法論註記……）
```

- [ ] **Step 2: README 加節**

在 `phase0/README.md` 執行順序之後加：

```markdown
## Phase 0b 傳輸驗證（備援）

Phase 0 判 gRPC 原始畫格 NO-GO 後的備援驗證，判定見 `RESULTS-0b.md`：

1. `python probe_mmap.py` — MMAP 通道探測（需 animate.py 供應動畫）
2. `python stream_bench.py --format rgba --seconds 8 --transport mmap` — mmap 幀率
3. `python e2e_latency.py --transport mmap` — mmap 端到端（先開 show_touches）
4. `MIRAGE_TRANSPORT=mmap ./.build/release/MiragePOC` — Swift mmap 終裁
5. `python encoded_bench.py --mode fps|e2e` — 編碼路徑對照（WebRTC 等效）
```

- [ ] **Step 3: 填實數、勾判定、Commit**

```bash
git add phase0/RESULTS-0b.md phase0/README.md
git commit -m "docs: phase0b 傳輸驗證結果與 Phase 1 顯示路徑選型"
```

---

## Self-Review 紀錄

- **範圍覆蓋**：使用者裁決「兩者都驗」→ MMAP 軌 = Task 1-4（探測→Python 幀率→Python e2e→Swift 終裁）；編碼軌 = Task 5（fps + e2e）；對照判定 = Task 6。macOS 無內建 WebRTC 的事實與等效架構聲明寫入 Global Constraints 與 Task 5。
- **佔位掃描**：無 TBD；RESULTS-0b 模板的 `___` 為待填實測值（同 Phase 0 慣例），各任務程式碼完整。
- **型別一致性**：`make_handle`/`open_frame_buffer`/`frame_array` 簽名 Task 1=2=3；`--transport {grpc,mmap}` 慣例 Task 2=3；`framesMmap(path:width:height:)` Task 4 定義即用；`Frame` 沿用 Phase 0。
- **經驗傳承**：Phase 0 四大教訓（動畫源、Release build、吞吐標示、host load）全部寫入 Global Constraints 成為紀律。



