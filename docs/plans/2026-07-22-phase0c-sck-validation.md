# Mirage Phase 0c — 上游回報 + ScreenCaptureKit 顯示路徑驗證 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) 產出可直接提交 Google Issue Tracker 的 MMAP bug 報告草稿；(2) 驗證「有視窗 emulator + ScreenCaptureKit 視窗擷取」能否達到 60fps 與延遲閘門——RESULTS-0b 決策選項 3 的可行性裁決。

**Architecture:** emulator 以有視窗模式執行（放棄 -no-window，Qt 視窗以主機 GPU 全速渲染）；新增 Swift CLI `SCKProbe` 用 ScreenCaptureKit 的 desktopIndependentWindow 過濾器擷取該視窗，量測各情境 fps（可見/被遮蔽/縮小化等——**遮蔽情境是產品姿態**，因為產品要把 emulator 視窗藏在自己的鏡像視窗後面）；e2e 延遲沿用 show_touches 方法論，由 Python 協調器（gRPC 注入 + 讀 SCKProbe stdout 行到達時刻）量測，迴避跨行程時鐘對齊問題。

**Tech Stack:** ScreenCaptureKit（macOS 12.3+，本機 26.3.1）、既有 SwiftPM package（新增 executable target）、既有 Python harness（animate.py、stats、gRPC 注入）。

## Global Constraints

- **絕不可觸碰 MMAP**：任何帶 `ImageTransport.MMAP` 的請求都禁止（canary 上是 no-op，穩定版會崩潰 emulator）。
- 現行 emulator 為 **canary 37.2.1.0**（0b 遺留的環境 drift，RESULTS-0c 必記版本）。
- **螢幕錄製權限（TCC）**：SCKProbe 首次執行會觸發系統權限對話框，需使用者在「系統設定 → 隱私權與安全性 → 螢幕錄製」核可執行 shell 的終端機 App——這是使用者動作，實作者遇到 denied 就 BLOCKED 回報，不得繞過。
- 視窗模式：emulator 視窗會出現在使用者桌面上——正常且必要，驗證期間不得關閉它。
- 閘門（對齊 spec §4.2/§7）：SCK 擷取 fps ≥60 穩定，**且被遮蔽情境下也必須 ≥60**（產品姿態）；e2e p50 + 17ms 上屏 < 80ms 上限 / < 50ms 理想。
- 量測紀律（0/0b 教訓）：動畫源用 `harness/animate.py`；量測附記 host load（`uptime`）；SCK 也是變化驅動（靜止內容不出幀），fps 量測必須配動畫源；吞吐/延遲數字標明量的是什麼（含不含管線緩衝）。
- e2e 方法論註記：SCK 擷取到的是 emulator 視窗合成後的畫面，量到的延遲已含 emulator 上屏；產品端還要再畫一次（+8–17ms），對照 80ms 時仍沿用 +17ms 慣例，RESULTS-0c 寫明。
- 程式風格與 commit 慣例同前（conventional commits、無 attribution、Swift 檔案小而聚焦）。

## File Structure

```
docs/upstream/2026-07-22-emulator-mmap-macos.md   # 新增：上游 issue 草稿（英文）
phase0/scripts/04_boot_windowed.sh                # 新增：有視窗模式啟動
phase0/swift-poc/Package.swift                    # 修改：加 SCKProbe target
phase0/swift-poc/Sources/SCKProbe/main.swift      # 新增：list/capture/e2e 三模式
phase0/harness/e2e_sck.py                         # 新增：SCK e2e 協調器
phase0/RESULTS-0c.md                              # 新增：情境矩陣與判定
phase0/README.md                                  # 修改：加 0c 一節
```

---

### Task 1: 上游 MMAP bug 報告草稿

**Files:**
- Create: `docs/upstream/2026-07-22-emulator-mmap-macos.md`

**Interfaces:**
- Consumes: `phase0/RESULTS-0b.md` 附錄、`.superpowers/sdd/mmap-canary-diagnostic.md` 的證據鏈。
- Produces: 使用者可直接貼上 Google Issue Tracker（component: Android Studio > Emulator）的英文 issue 全文。

- [ ] **Step 1: 撰寫 issue 草稿**

以下為完整內容（實作時逐字建立，數字與 RESULTS-0b 附錄核對）：

```markdown
# [Draft] Issue Tracker submission — Emulator MMAP ImageTransport broken on macOS

**提交網址**: https://issuetracker.google.com/issues/new?component=192727 (Android Studio > Emulator)
**提交前確認**: 版本號與重現輸出對照 phase0/RESULTS-0b.md 附錄；以下為貼上用全文。

---

**Title:** macOS (Apple Silicon): gRPC streamScreenshot with ImageTransport MMAP crashes emulator engine (36.6.11.0) / silently never writes frames (37.2.1.0 canary)

**Component:** Android Studio > Emulator

**Build/version info:**
- Host: MacBook Air (M1, 16 GB), macOS 26.3.1 (arm64)
- Emulator (stable): 36.6.11.0 (build_id 15507667)
- Emulator (canary): 37.2.1.0 (build_id 15875889)
- AVD: pixel_7, system-images;android-35;default;arm64-v8a, cold boot
- Launch: `emulator @avd -no-window -no-audio -no-boot-anim -gpu host -grpc 8554`

**Steps to reproduce:**
1. Boot the AVD headless with gRPC enabled (flags above), wait for sys.boot_completed=1.
2. Create a client-owned frame buffer file sized width*height*4 (e.g. 1080*2400*4 = 10,368,000 bytes).
3. Call `EmulatorController.streamScreenshot` with:
   `ImageFormat{ format: RGBA8888, transport: ImageTransport{ channel: MMAP, handle: "file:///abs/path/to/buffer.bin" } }`
4. Observe.

**Observed — stable 36.6.11.0:** the qemu engine process terminates immediately
(SIGSEGV, exit 139; crashpad handler fires). Deterministic: 2/2 with the
`file:///` handle across independent cold boots; a POSIX-shm-style handle
(`/name`) also kills the engine (SIGABRT, exit 134). Client sees
`UNAVAILABLE: Stream removed (Socket closed)` with zero frames delivered.

**Observed — canary 37.2.1.0:** no crash. The stream delivers Image messages
at a plausible frame cadence with `image` payload EMPTY (0 bytes, as expected
for MMAP transport) and correct `format.width/height` (1080x2400). However the
client's buffer is never written: content stays all-zero across frames
(identical md5 per frame), the file's inode never changes (rules out
recreate-behind semantics), and — decisively — `lsof -p <qemu_pid>` during an
active MMAP stream shows the engine has NOT opened the handle path at all, and
no PSXSHM objects exist. Tried three handle variants (long `file:///` temp
path, short `file:///tmp/x.bin`, bare shm-style name): same result (inference:
none was rejected — notifications flowed for all three). So on macOS the MMAP
transport's host write side appears to be a silent no-op while the
notification side works.

**Expected:** either (a) frames are written into the client-provided
mmap/shm handle as documented in emulator_controller.proto (ImageTransport:
"Write images to the a file/shared memory handle. The client sets and owns
this handle."), or (b) the request is rejected cleanly with
INVALID_ARGUMENT/UNIMPLEMENTED on platforms where MMAP transport is
unsupported — never an engine crash, never empty notifications with no data.

**Impact:** MMAP is the only built-in path that avoids the ~10 MiB/frame
protobuf serialization cost of raw RGBA streaming, which caps
streamScreenshot at roughly 30 fps at native resolution on Apple Silicon
hosts (measured; gRPC transport, continuous screen updates). With MMAP broken
there is no built-in 60 fps display-out path on macOS.

**Happy to provide:** crashpad dumps, full client repro script (Python,
~60 lines, grpcio only), lsof captures, measurement logs.
```

- [ ] **Step 2: 核對數字**

Run: `grep -n "10,368,000\|36.6.11.0\|37.2.1.0\|SIGSEGV\|SIGABRT" phase0/RESULTS-0b.md | head -12`
Expected: 草稿中的版本號、位元組數、訊號名稱與 RESULTS-0b 完全一致（不一致以 RESULTS-0b 為準修草稿）。

- [ ] **Step 3: Commit**

```bash
git add docs/upstream/2026-07-22-emulator-mmap-macos.md
git commit -m "docs: 上游 MMAP bug 報告草稿（issue tracker 用）"
```

---

### Task 2: 有視窗模式啟動腳本與驗證

**Files:**
- Create: `phase0/scripts/04_boot_windowed.sh`

**Interfaces:**
- Consumes: 既有 AVD `mirage-poc`、canary emulator。
- Produces: 執行中的**有視窗** emulator（桌面可見 Qt 視窗 + gRPC :8554）。Task 3-5 依賴此狀態。

- [ ] **Step 1: 啟動腳本**

```bash
#!/usr/bin/env bash
# phase0/scripts/04_boot_windowed.sh
# 有視窗模式：Qt 視窗以主機 GPU 全速渲染，供 ScreenCaptureKit 擷取（Phase 0c）。
# 注意：視窗會出現在桌面上；驗證期間請勿關閉。
set -euo pipefail
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
GRPC_PORT="${GRPC_PORT:-8554}"
exec "$SDK/emulator/emulator" @mirage-poc \
  -no-audio -no-boot-anim \
  -gpu host \
  -grpc "$GRPC_PORT"
```

- [ ] **Step 2: 實測開機（背景執行 + 等 BOOTED）**

Run（背景）: `chmod +x phase0/scripts/04_boot_windowed.sh && phase0/scripts/04_boot_windowed.sh`（背景行程）
Run（前景）: `phase0/scripts/03_wait_boot.sh && nc -z localhost 8554 && echo GRPC_OPEN`
Expected: `BOOTED` + `GRPC_OPEN`，且桌面出現「Android Emulator - mirage-poc:5554」視窗。
驗證注入仍通: `cd phase0/harness && source .venv/bin/activate && python input_latency.py` → p50 應仍在 ~1ms 級。

- [ ] **Step 3: Commit**

```bash
git add phase0/scripts/04_boot_windowed.sh
git commit -m "feat: 有視窗模式啟動腳本（SCK 驗證用）"
```

---

### Task 3: SCKProbe——list 與 capture 模式

**Files:**
- Modify: `phase0/swift-poc/Package.swift`（加 target）
- Create: `phase0/swift-poc/Sources/SCKProbe/main.swift`

**Interfaces:**
- Consumes: 執行中的有視窗 emulator（Task 2）。
- Produces: `SCKProbe list`（列出可擷取視窗）；`SCKProbe capture --window <子字串> [--seconds N] [--occlude]`（每秒印 `[sck] fps=N`）；`SCKProbe e2e --window <子字串> --region-norm <nx> <ny> <nr>`（每幀印 `mean m=<val>`，Task 5 用）。Task 4/5 依賴這些輸出格式。

- [ ] **Step 1: Package.swift 加 target**

在 `targets:` 陣列加：

```swift
        .executableTarget(
            name: "SCKProbe",
            path: "Sources/SCKProbe"
        ),
```

- [ ] **Step 2: SCKProbe main.swift（完整實作）**

```swift
// phase0/swift-poc/Sources/SCKProbe/main.swift
// ScreenCaptureKit 視窗擷取探測：Phase 0c 顯示路徑驗證工具。
// 模式：list / capture（fps 量測，--occlude 自建遮蔽視窗）/ e2e（區域亮度行輸出）。
// 需「螢幕錄製」權限；被拒時印出指引並以 exit 3 結束。
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

setvbuf(stdout, nil, _IOLBF, 0)  // 行緩衝：協調器靠 stdout 行到達時刻計時

enum Mode { case list, capture, e2e }

struct Args {
    var mode: Mode
    var windowQuery = "mirage-poc"
    var seconds = 15
    var occlude = false
    var regionNorm: (nx: Double, ny: Double, nr: Double) = (0.5, 0.5, 0.05)
}

func parseArgs() -> Args {
    var argv = Array(CommandLine.arguments.dropFirst())
    guard let modeStr = argv.first else { fail("用法: SCKProbe list|capture|e2e [選項]") }
    argv.removeFirst()
    let mode: Mode
    switch modeStr {
    case "list": mode = .list
    case "capture": mode = .capture
    case "e2e": mode = .e2e
    default: fail("未知模式 \(modeStr)")
    }
    var a = Args(mode: mode)
    var i = 0
    while i < argv.count {
        switch argv[i] {
        case "--window":
            a.windowQuery = argv[i + 1]; i += 2
        case "--seconds":
            guard let s = Int(argv[i + 1]), s >= 3 else { fail("--seconds 需 ≥3") }
            a.seconds = s; i += 2
        case "--occlude":
            a.occlude = true; i += 1
        case "--region-norm":
            guard let nx = Double(argv[i + 1]), let ny = Double(argv[i + 2]),
                  let nr = Double(argv[i + 3]),
                  (0...1).contains(nx), (0...1).contains(ny), nr > 0 else {
                fail("--region-norm 需三個數值 nx ny nr（0–1）")
            }
            a.regionNorm = (nx, ny, nr); i += 4
        default:
            fail("未知參數 \(argv[i])")
        }
    }
    return a
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

func shareableWindows() async -> [SCWindow] {
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
        FileHandle.standardError.write("""
        PERMISSION_DENIED: 需要「螢幕錄製」權限。
        請開啟 系統設定 → 隱私權與安全性 → 螢幕錄製，核可執行本指令的終端機 App 後重跑。
        \n
        """.data(using: .utf8)!)
        exit(3)
    }
    do {
        let content = try await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.windows
    } catch {
        fail("SCShareableContent 失敗：\(error)")
    }
}

func findWindow(_ windows: [SCWindow], query: String) -> SCWindow {
    let hits = windows.filter {
        (($0.title ?? "") + ($0.owningApplication?.applicationName ?? ""))
            .localizedCaseInsensitiveContains(query)
    }
    guard let w = hits.max(by: { $0.frame.width * $0.frame.height
                                < $1.frame.width * $1.frame.height }) else {
        fail("找不到符合 '\(query)' 的視窗（先跑 SCKProbe list 確認）")
    }
    return w
}

final class FrameCounter: NSObject, SCStreamOutput {
    private var count = 0
    private var windowStart = CFAbsoluteTimeGetCurrent()
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        count += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - windowStart >= 1.0 {
            print("[sck] fps=\(count)")
            count = 0
            windowStart = now
        }
    }
}

final class RegionMeanEmitter: NSObject, SCStreamOutput {
    let norm: (nx: Double, ny: Double, nr: Double)
    init(norm: (nx: Double, ny: Double, nr: Double)) { self.norm = norm }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let cx = Int(norm.nx * Double(w)), cy = Int(norm.ny * Double(h))
        let r = max(Int(norm.nr * Double(min(w, h))), 4)
        let x0 = max(cx - r, 0), x1 = min(cx + r, w)
        let y0 = max(cy - r, 0), y1 = min(cy + r, h)
        guard x0 < x1, y0 < y1 else { return }
        var sum = 0
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in y0..<y1 {
            let row = y * stride
            for x in x0..<x1 {
                let o = row + x * 4          // BGRA
                sum += Int(p[o]) + Int(p[o + 1]) + Int(p[o + 2])
            }
        }
        let mean = Double(sum) / Double((x1 - x0) * (y1 - y0) * 3)
        print("mean m=\(String(format: "%.2f", mean))")
    }
}

func makeCoverWindow(over frame: CGRect) -> NSWindow {
    let win = NSWindow(contentRect: frame, styleMask: .borderless,
                       backing: .buffered, defer: false)
    win.level = .floating
    win.backgroundColor = .black
    win.orderFrontRegardless()
    return win
}

let args = parseArgs()
let sema = DispatchSemaphore(value: 0)

Task {
    let windows = await shareableWindows()
    switch args.mode {
    case .list:
        for w in windows where w.frame.width > 50 {
            let app = w.owningApplication?.applicationName ?? "?"
            print("id=\(w.windowID) app=\(app) title=\(w.title ?? "") "
                  + "frame=\(Int(w.frame.width))x\(Int(w.frame.height))")
        }
        sema.signal()
    case .capture, .e2e:
        let target = findWindow(windows, query: args.windowQuery)
        print("target id=\(target.windowID) title=\(target.title ?? "") "
              + "frame=\(Int(target.frame.width))x\(Int(target.frame.height))")
        var cover: NSWindow?
        if args.occlude {
            DispatchQueue.main.async {
                cover = makeCoverWindow(over: target.frame)
                _ = cover  // 保活
                print("[sck] cover window up")
            }
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let config = SCStreamConfiguration()
        config.width = Int(target.frame.width) * 2    // Retina backing
        config.height = Int(target.frame.height) * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 8
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let output: SCStreamOutput = args.mode == .capture
            ? FrameCounter() : RegionMeanEmitter(norm: args.regionNorm)
        try stream.addStreamOutput(output, type: .screen,
                                   sampleHandlerQueue: DispatchQueue(label: "sck.out"))
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(args.seconds) * 1_000_000_000)
        try await stream.stopCapture()
        sema.signal()
    }
}

// AppKit runloop（--occlude 的遮蔽視窗需要）
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
while sema.wait(timeout: .now()) == .timedOut {
    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
}
```

- [ ] **Step 3: 建置**

Run: `cd phase0/swift-poc && swift build 2>&1 | tail -2`
Expected: `Build complete!`（API 不合處最小修正並在報告記錄——SCK API 在不同 SDK 間有小差異）。

- [ ] **Step 4: 權限預檢與 list**

Run: `.build/debug/SCKProbe list | head -20`
Expected: 視窗清單，其中一行含 `Android Emulator`/`mirage-poc`。若印 `PERMISSION_DENIED`（exit 3）→ **BLOCKED 回報**，等使用者到系統設定核可後重試。

- [ ] **Step 5: 可見情境 fps 煙霧測試**

Run（終端 B）: `cd ../harness && source .venv/bin/activate && python animate.py --seconds 25`
Run（終端 A）: `swift build -c release && .build/release/SCKProbe capture --window mirage-poc --seconds 15`
Expected: 每秒一行 `[sck] fps=N`；verbatim 記錄（此為可見情境數字；閘門判讀在 Task 4 統整）。

- [ ] **Step 6: Commit**

```bash
git add phase0/swift-poc/Package.swift phase0/swift-poc/Sources/SCKProbe/main.swift
git commit -m "feat: SCKProbe——sck 視窗擷取探測工具（list/capture/e2e）"
```

---

### Task 4: fps 情境矩陣

**Files:**
- （無新檔——量測任務，數據進報告與 Task 6 的 RESULTS-0c）

**Interfaces:**
- Consumes: Task 3 的 `SCKProbe capture`、animate.py。
- Produces: 四情境 fps 數據（verbatim）。**遮蔽情境是閘門**。

- [ ] **Step 1: 可見情境（若 Task 3 Step 5 已測可沿用）**

Run（B）: `python animate.py --seconds 25`；Run（A）: `.build/release/SCKProbe capture --window mirage-poc --seconds 15`
記錄全部 `[sck] fps=` 行 + `uptime`。

- [ ] **Step 2: 自動遮蔽情境（產品姿態，閘門）**

Run（B）: `python animate.py --seconds 25`；Run（A）: `.build/release/SCKProbe capture --window mirage-poc --seconds 15 --occlude`
Expected: `[sck] cover window up` 後 fps 行持續出現。判讀重點：**遮蔽後 fps 是否掉**——macOS 對完全被遮蔽的視窗可能節流渲染（Qt 讀 occlusionState 暫停繪製），這正是本情境要抓的風險。若 fps 歸零/大掉，嘗試把 cover 視窗縮小 2px（留一條可見邊）再測一次，記錄兩種結果。

- [ ] **Step 3: 人工情境（pending-human，不自動化）**

在報告中列出待使用者手動確認的三情境與操作方法，不假造結果：
- 縮小化（Cmd-M）後 fps 是否持續
- 移到另一個 Space 後 fps 是否持續
- App 隱藏（Cmd-H）後 fps 是否持續

- [ ] **Step 4: 記錄與 commit（若 Task 3 已 commit 工具，本任務僅報告，無 commit）**

數據全部 verbatim 進 `.superpowers/sdd/task-4-report.md`。

---

### Task 5: SCK e2e 延遲

**Files:**
- Create: `phase0/harness/e2e_sck.py`

**Interfaces:**
- Consumes: Task 3 的 `SCKProbe e2e`（stdout 行格式 `mean m=<val>`）、既有 gRPC 注入寫法、`lib/stats.percentile`。
- Produces: `e2e_sck.py` 輸出行 `n=.. misses=.. p50=..ms p95=..ms transport=sck`。

- [ ] **Step 1: 協調器實作**

```python
# phase0/harness/e2e_sck.py
"""SCK e2e 延遲：gRPC 注入 tap → SCKProbe 偵測到區域亮度變化的 stdout 行「到達時刻」。

跨行程不比時鐘：延遲 = 行到達（Python 收到）− t0（Python 送出 tap），
內含 SCK 管線 + stdout 行緩衝/管道（~1–2ms），判讀時註記。
前置：有視窗 emulator 執行中、show_touches=1、SCKProbe 已建置（release）。
"""
import subprocess
import sys
import threading
import time
from collections import deque

sys.path.insert(0, "gen")

import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.stats import percentile

TARGET = "localhost:8554"
PROBE = "../swift-poc/.build/release/SCKProbe"
N_SAMPLES = 30
TAP_X, TAP_Y = 540, 1200
GUEST_W, GUEST_H = 1080, 2400
THRESHOLD = 8.0
Sample = tuple  # (arrival_t, mean)


def send_tap(stub, down: bool) -> None:
    touch = ec.Touch(x=TAP_X, y=TAP_Y, identifier=0,
                     pressure=1024 if down else 0)
    stub.sendTouch(ec.TouchEvent(touches=[touch]), timeout=2)


def reader(proc, samples: deque, stop: threading.Event) -> None:
    for line in proc.stdout:
        if stop.is_set():
            return
        if line.startswith("mean m="):
            try:
                samples.append((time.monotonic(), float(line[7:])))
            except ValueError:
                continue


def main() -> int:
    nx, ny = TAP_X / GUEST_W, TAP_Y / GUEST_H
    proc = subprocess.Popen(
        [PROBE, "e2e", "--window", "mirage-poc", "--seconds", "600",
         "--region-norm", f"{nx:.4f}", f"{ny:.4f}", "0.05"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    samples: deque = deque(maxlen=600)
    stop = threading.Event()
    threading.Thread(target=reader, args=(proc, samples, stop),
                     daemon=True).start()
    stub = ecg.EmulatorControllerStub(grpc.insecure_channel(TARGET))

    # 基線攪動：偵測區外 3 tap 讓 SCK 出幀（SCK 也是變化驅動）
    for _ in range(3):
        t = ec.Touch(x=150, y=300, identifier=0, pressure=1024)
        stub.sendTouch(ec.TouchEvent(touches=[t]), timeout=2)
        time.sleep(0.05)
        t = ec.Touch(x=150, y=300, identifier=0, pressure=0)
        stub.sendTouch(ec.TouchEvent(touches=[t]), timeout=2)
        time.sleep(0.15)
    time.sleep(1.4)
    if len(samples) < 3:
        print("FAIL: SCKProbe 無輸出——確認視窗存在與螢幕錄製權限", file=sys.stderr)
        proc.kill()
        return 1

    latencies, misses = [], 0
    for _ in range(N_SAMPLES):
        recent = [m for _, m in list(samples)[-20:]]
        baseline = percentile(recent, 50)
        t0 = time.monotonic()
        send_tap(stub, down=True)
        t1 = None
        deadline = time.monotonic() + 2.0
        seen = 0
        while time.monotonic() < deadline:
            snap = list(samples)
            for at, m in snap[seen:]:
                if at > t0 and abs(m - baseline) > THRESHOLD:
                    t1 = at
                    break
            if t1 is not None:
                break
            seen = len(snap)
            time.sleep(0.001)
        send_tap(stub, down=False)
        if t1 is None:
            misses += 1
        else:
            latencies.append((t1 - t0) * 1000)
        time.sleep(0.5)

    stop.set()
    proc.kill()
    if not latencies:
        print("FAIL: 全 miss——確認 show_touches=1 與偵測區對位", file=sys.stderr)
        return 1
    print(f"n={len(latencies)} misses={misses} "
          f"p50={percentile(latencies, 50):.1f}ms "
          f"p95={percentile(latencies, 95):.1f}ms transport=sck")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: 實測**

Run:

```bash
~/Library/Android/sdk/platform-tools/adb shell settings put system show_touches 1
python e2e_sck.py
~/Library/Android/sdk/platform-tools/adb shell settings put system show_touches 0
```

Expected: 一行結果 verbatim。判讀：p50 + 17ms（產品端再上屏）對照 80ms 上限 / 50ms 理想；此數字已含 emulator 自身上屏（SCK 擷取的是合成後視窗），與 0/0b 的數字語意差異在 RESULTS-0c 說明。

- [ ] **Step 3: 單元測試迴歸 + Commit**

Run: `python -m pytest tests/ -q` → 17 passed。

```bash
git add phase0/harness/e2e_sck.py
git commit -m "feat: sck e2e 延遲協調器"
```

---

### Task 6: RESULTS-0c 判定與 README

**Files:**
- Create: `phase0/RESULTS-0c.md`
- Modify: `phase0/README.md`（加 0c 一節）

**Interfaces:**
- Consumes: Task 3-5 全部 verbatim 數據、`phase0/RESULTS-0b.md` 的決策選項 3。
- Produces: 選項 3 的可行性裁決——SCK 是否成為 Phase 1 顯示路徑。

- [ ] **Step 1: RESULTS-0c.md 模板（實測後填）**

```markdown
# Phase 0c — ScreenCaptureKit 顯示路徑驗證（日期：____）

環境：____ / emulator canary 37.2.1.0（有視窗模式）/ host load 量測時值：____
對應決策：RESULTS-0b 選項 3。上游回報草稿：docs/upstream/2026-07-22-emulator-mmap-macos.md（已/未提交：____）

## fps 情境矩陣（動畫源 animate.py；SCK 亦為變化驅動）

| 情境 | fps（verbatim 摘要） | 判定（≥60） |
|---|---|---|
| 視窗可見（前景） | ___ | ⬜ |
| **完全遮蔽（產品姿態，閘門）** | ___ | ⬜ |
| 遮蔽留 2px 邊（若完全遮蔽掉幀） | ___ | ⬜ |
| 縮小化 / 另一 Space / Cmd-H（人工） | ___ | ⬜ |

## e2e 延遲（含 emulator 上屏與 SCK 管線；+17ms 為產品端再上屏）

| 指標 | 值 | 對照 |
|---|---|---|
| p50 (+17ms) | ___ | < 80ms 上限 / < 50ms 理想 |
| p95 (+17ms) | ___ | < 80ms |

## 判定

- [ ] **SCK 為 Phase 1 顯示路徑**：條件——遮蔽情境 ≥60fps 且 e2e 達標
- [ ] **SCK 不可行** → 決策選項收斂為 (1) fork 補 MMAP 寫入端 或 (4) 接受 42fps
- 附帶條件與待辦（如：需要留邊 workaround、人工情境結果、視窗管理策略）：____

## 觀察與備註
（遮蔽節流行為、Retina 縮放、SCK 幀到達特性、方法論註記……）
```

- [ ] **Step 2: README 加節**

```markdown
## Phase 0c SCK 驗證（決策選項 3）

1. `scripts/04_boot_windowed.sh` — 有視窗模式啟動（桌面會出現 emulator 視窗）
2. `swift-poc/.build/release/SCKProbe list` — 找視窗（需螢幕錄製權限）
3. `SCKProbe capture --window mirage-poc --seconds 15 [--occlude]` — fps 情境（配 animate.py）
4. `python e2e_sck.py` — e2e 延遲（先開 show_touches）
判定見 `RESULTS-0c.md`；上游 bug 草稿在 `docs/upstream/`。
```

- [ ] **Step 3: 填數據、勾判定、Commit**

```bash
git add phase0/RESULTS-0c.md phase0/README.md
git commit -m "docs: phase0c sck 驗證結果與判定"
```

---

## Self-Review 紀錄

- **範圍覆蓋**：使用者裁決「2+3 並行」→ 選項 2 的上游回報 = Task 1（草稿，提交由使用者執行）；選項 3 的 SCK 驗證 = Task 2-6（工具→情境矩陣→e2e→判定）。選項 2 的「過渡期用 42fps 開發殼層」屬 Phase 1 本體，不在本計畫範圍（RESULTS-0c 判定後另立計畫）。
- **佔位掃描**：RESULTS-0c 模板 `___` 為待填實測值（慣例）；SCKProbe 程式碼完整；SCK API 細節容許最小修正（Task 3 Step 3 註明），非佔位。
- **型別一致性**：`SCKProbe capture/e2e` 的輸出行格式（`[sck] fps=N`、`mean m=<val>`）Task 3 定義、Task 4/5 引用一致；`--region-norm` 正規化座標與 e2e_sck.py 的 `TAP_X/GUEST_W` 換算一致；`percentile` 沿用既有簽名。
- **風險前置**：TCC 權限（BLOCKED 流程）、遮蔽節流（留邊 fallback）、SCK 變化驅動（基線攪動）皆已寫入對應任務。


