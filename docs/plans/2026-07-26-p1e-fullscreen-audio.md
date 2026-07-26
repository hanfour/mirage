# P1-e 全螢幕遊戲模式與音訊 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 補齊母計畫 Phase-1 鏡像視窗尚缺的兩項——macOS 原生全螢幕遊戲模式（aspect-fit letterbox）與 guest 音訊輸出到 Mac 喇叭。

**Architecture:** 全螢幕不寫 shader——新增一層黑底容器 `MirrorContainerView`，用純函式 `ViewportFit.fit` 算出置中內容矩形並設為 `MirrorMTKView` 的 frame；黑邊是父 view 背景色，`MirrorMTKView.bounds` 永遠等於內容矩形，因此既有座標路徑（`normalized()`／`KeymapController`）一行都不用改。音訊走 `streamAudio` → SPSC 無鎖環形緩衝 → `AVAudioSourceNode`，掛在既有連線／電源狀態機上（關視窗即靜音），不新增第二條生命週期。

**Tech Stack:** Swift 6 toolchain（`.swiftLanguageMode(.v5)`）、SwiftUI + AppKit + MetalKit、AVFoundation（`AVAudioEngine`/`AVAudioSourceNode`）、grpc-swift 1.27.5、swift-atomics 1.3.1、swift-testing。

**設計依據：** `docs/specs/2026-07-26-p1e-fullscreen-audio-design.md`（authoritative）。

## Global Constraints

- 平台 macOS 14+ Apple Silicon；`swift build -c release` 零非-deprecation 警告。
- **MirageCore 不得 import AppKit / SwiftUI / Metal / AVFoundation**；不 `fatalError`；錯誤回傳或記錄，由 App 層決定呈現。
- 所有 target 開 `-strict-concurrency=complete`；`.swiftLanguageMode(.v5)`。
- 測試語法用 swift-testing（`@Suite` / `@Test` / `#expect`）；每檔 <400 行、函式 <50 行。
- 不可變優先——**唯一明文破例是 `AudioRingBuffer`**（Task 5），理由見該任務。
- TDD：先寫失敗測試 → 執行確認失敗 → 最小實作 → 綠 → commit。
- Conventional commits（`feat:`/`fix:`/`docs:`/`test:`/`refactor:`），**無 attribution**。
- MirageCore 覆蓋 ≥80%；既有 101 個 `@Test` 不回歸。
- 活體測試預設 skip，`MIRAGE_LIVE=1` 開啟；所有 adb 一律 `ANDROID_SERIAL=emulator-5554`（本機常同時掛實體手機 `RFCN804073P`，不指定會誤命中）。
- 工作目錄一律 `app/`（`swift build` / `swift test` 都在此執行）。
- **零 proto 遷移**：`streamAudio` / `AudioFormat` / `AudioPacket` 已存在於 `Sources/MirageCore/Generated/`，不重新產生。

## 與 spec 的兩處偏離（實作時採用本計畫版本）

1. **`FitRect` 的單位**：spec §4.1 註為 backing pixel。改為**單位無關**——`fit` 只用比例運算，呼叫端餵 point 就得到 point。省掉一次 `backingScaleFactor` 來回換算，也消除「兩種單位混用」這個 bug 溫床。
2. **spec §10 說「`Renderer` 程式碼不動」**：實際需要兩處極小改動——(a) 新增一個 optional callback 讓容器知道幀尺寸變了；(b) 移除 `upload()` 裡設 `window?.contentAspectRatio` 那兩行，把長寬比的唯一權威收斂到容器。渲染邏輯本身不動。
3. **spec §5 說音訊串流錯誤「走既有 `TransportError` 分類」**：不做這層映射。音訊錯誤**不得**觸發重連（guest 靜音、串流被 cancel 都會走到 catch，映射成 `unavailable` 會讓音訊反過來驅動連線狀態機）。實作是吞掉錯誤並記錄，重連完全交給畫面串流那條路徑——這正是 spec 同句所要求的「音訊不自行重連」，只是不經過 `TransportError`。

---

## File Structure

新增：

| 檔案 | 職責 |
|---|---|
| `Sources/MirageCore/Viewport/ViewportFit.swift` | 純函式：幀長寬比 aspect-fit 進 bounds，回置中矩形 |
| `Sources/MirageCore/Audio/AudioTransport.swift` | `AudioTransport` 協定 + `AudioStreamFormat` / `AudioChunk` 值型別 |
| `Sources/MirageCore/Audio/AudioRingBuffer.swift` | SPSC 無鎖環形緩衝（唯一可變破例）+ `AudioStats` |
| `Sources/MirageCore/Audio/GrpcAudioTransport.swift` | `streamAudio` 封裝，持有真 call 供顯式 cancel |
| `Sources/MirageApp/MirrorContainerView.swift` | 黑底容器，letterbox 佈局與視窗長寬比唯一權威 |
| `Sources/MirageApp/Audio/AudioPlayer.swift` | `AVAudioEngine` + `AVAudioSourceNode` 接線、靜音 |
| `Tests/MirageCoreTests/ViewportFitTests.swift` | Task 1 |
| `Tests/MirageCoreTests/AudioChunkTests.swift` | Task 4 |
| `Tests/MirageCoreTests/AudioRingBufferTests.swift` | Task 5 |
| `Tests/MirageCoreTests/EmulatorClientAudioTests.swift` | Task 7（假 transport 注入） |
| `Tests/MirageCoreTests/AudioLiveTests.swift` | Task 9（`MIRAGE_LIVE`） |
| `scripts/verify_audio.sh` | Task 9 活體驗證腳本 |
| `RESULTS-p1e.md` | Task 10 驗收紀錄 |

修改：

| 檔案 | 改動 |
|---|---|
| `Package.swift` | + swift-atomics（exact 1.3.1） |
| `Sources/MirageApp/MirrorView.swift` | `makeNSView` 回傳容器；移除 `viewDidMoveToWindow` 的 9:20 鎖定；`resizeDebounced` 改用實際幀比 + 上限 |
| `Sources/MirageApp/Renderer.swift` | + `onFrameSize` callback；− `contentAspectRatio` 兩行 |
| `Sources/MirageApp/MirageApp.swift` | `isFullScreen` 狀態、overlay 隱藏、audio 接線、選單列回呼 |
| `Sources/MirageApp/Lifecycle/MenuBarController.swift` | +「遊戲模式（全螢幕）」與「靜音」項目 |
| `Sources/MirageCore/EmulatorClient.swift` | `makeAudioTransport` 注入、`setAudioSink`、`attachAudio`/`detachAudio` |
| `app/README.md` | P1-e 章節 |

---

# Part A — 全螢幕遊戲模式（Task 1–3）

## Task 1: ViewportFit（純函式，逐行 100%）

**Files:**
- Create: `app/Sources/MirageCore/Viewport/ViewportFit.swift`
- Test: `app/Tests/MirageCoreTests/ViewportFitTests.swift`

**Interfaces:**
- Consumes: 無（本階段第一個任務）
- Produces:
  - `public struct FitRect: Equatable, Sendable { public let x: Int, y: Int, width: Int, height: Int; public static let zero: FitRect; public init(x:y:width:height:) }`
  - `public enum ViewportFit { public static func fit(frame: (w: Int, h: Int), in bounds: (w: Int, h: Int)) -> FitRect }`

- [ ] **Step 1: 寫失敗測試**

建立 `app/Tests/MirageCoreTests/ViewportFitTests.swift`：

```swift
import Testing
@testable import MirageCore

@Suite struct ViewportFitTests {
    /// 這條是「視窗模式零回歸」的形式化保證：長寬比一致 → 黑邊為 0、退化成滿版。
    @Test func sameAspectFillsCompletely() {
        let r = ViewportFit.fit(frame: (w: 9, h: 20), in: (w: 270, h: 600))
        #expect(r == FitRect(x: 0, y: 0, width: 270, height: 600))
    }

    @Test func landscapeFrameInSquareBoundsGetsTopBottomBars() {
        let r = ViewportFit.fit(frame: (w: 1920, h: 1080), in: (w: 1000, h: 1000))
        #expect(r.width == 1000)
        #expect(r.height == 562)          // 1080 * 1000 / 1920 = 562（整數截斷）
        #expect(r.x == 0)
        #expect(r.y == 219)               // (1000 - 562) / 2
    }

    @Test func portraitFrameInWideBoundsGetsLeftRightBars() {
        let r = ViewportFit.fit(frame: (w: 1080, h: 1920), in: (w: 1600, h: 1000))
        #expect(r.height == 1000)
        #expect(r.width == 562)           // 1080 * 1000 / 1920 = 562
        #expect(r.y == 0)
        #expect(r.x == 519)               // (1600 - 562) / 2
    }

    @Test func squareFrameInSquareBoundsFills() {
        let r = ViewportFit.fit(frame: (w: 512, h: 512), in: (w: 300, h: 300))
        #expect(r == FitRect(x: 0, y: 0, width: 300, height: 300))
    }

    @Test func extremeRatioNeverExceedsBounds() {
        let r = ViewportFit.fit(frame: (w: 1, h: 1000), in: (w: 1920, h: 1080))
        #expect(r.width <= 1920)
        #expect(r.height <= 1080)
        #expect(r.x >= 0)
        #expect(r.y >= 0)
    }

    @Test(arguments: [
        (0, 100, 100, 100), (100, 0, 100, 100),
        (100, 100, 0, 100), (100, 100, 100, 0),
        (-9, 20, 270, 600), (9, 20, -270, 600),
    ])
    func degenerateInputReturnsZero(fw: Int, fh: Int, bw: Int, bh: Int) {
        #expect(ViewportFit.fit(frame: (w: fw, h: fh), in: (w: bw, h: bh)) == .zero)
    }
}
```

- [ ] **Step 2: 執行確認失敗**

Run: `cd app && swift test --filter ViewportFitTests`
Expected: 編譯失敗，`cannot find 'ViewportFit' in scope`。

- [ ] **Step 3: 最小實作**

建立 `app/Sources/MirageCore/Viewport/ViewportFit.swift`：

```swift
/// 幀與可視區域的幾何換算。單位無關——呼叫端餵 point 就得到 point，餵 pixel 就得到 pixel
/// （只做比例運算）。MirageCore 不得 import AppKit，故不用 CGRect。
public struct FitRect: Equatable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public static let zero = FitRect(x: 0, y: 0, width: 0, height: 0)
}

public enum ViewportFit {
    /// 把 frame 的長寬比 aspect-fit 進 bounds，回傳置中的內容矩形。
    ///
    /// 長寬比相同時黑邊為 0（退化成滿版）——這條性質保證視窗模式行為零回歸，
    /// 全螢幕與視窗因此走同一條路徑，沒有「全螢幕模式」分支。
    ///
    /// 任一維度 <= 0 → `.zero`，呼叫端據此不佈局（不崩、不畫）。
    public static func fit(frame: (w: Int, h: Int), in bounds: (w: Int, h: Int)) -> FitRect {
        guard frame.w > 0, frame.h > 0, bounds.w > 0, bounds.h > 0 else { return .zero }
        // 交叉相乘比較長寬比，避免浮點誤差讓「比例相同」判成不同、多出 1px 黑邊。
        if frame.w * bounds.h >= bounds.w * frame.h {
            let h = frame.h * bounds.w / frame.w          // 寬受限：左右填滿，上下黑邊
            return FitRect(x: 0, y: (bounds.h - h) / 2, width: bounds.w, height: h)
        }
        let w = frame.w * bounds.h / frame.h              // 高受限：上下填滿，左右黑邊
        return FitRect(x: (bounds.w - w) / 2, y: 0, width: w, height: bounds.h)
    }
}
```

- [ ] **Step 4: 執行確認通過**

Run: `cd app && swift test --filter ViewportFitTests`
Expected: PASS，10 個測項（6 個具名 + `arguments` 展開）全綠。

- [ ] **Step 5: 確認逐行 100% 覆蓋**

Run: `cd app && swift test --filter ViewportFitTests --enable-code-coverage && xcrun llvm-cov report .build/debug/MiragePackageTests.xctest/Contents/MacOS/MiragePackageTests -instr-profile .build/debug/codecov/default.profdata 2>/dev/null | grep ViewportFit`
Expected: `ViewportFit.swift` 的 line coverage 為 `100.00%`。若未達，補測試而非改實作。

- [ ] **Step 6: Commit**

```bash
cd app && git add Sources/MirageCore/Viewport/ViewportFit.swift Tests/MirageCoreTests/ViewportFitTests.swift
git commit -m "feat: ViewportFit 純函式 aspect-fit 幾何（TDD，逐行 100%）"
```

---

## Task 2: MirrorContainerView 與 letterbox 接線

**Files:**
- Create: `app/Sources/MirageApp/MirrorContainerView.swift`
- Modify: `app/Sources/MirageApp/MirrorView.swift`（`MirrorMTKView.viewDidMoveToWindow`、`makeNSView`/`updateNSView`、`Coordinator.resizeDebounced`）
- Modify: `app/Sources/MirageApp/Renderer.swift`（+ `onFrameSize`、− `contentAspectRatio` 兩行）

**Interfaces:**
- Consumes: `ViewportFit.fit(frame:in:) -> FitRect`（Task 1）
- Produces:
  - `final class MirrorContainerView: NSView`，屬性 `let mirror: MirrorMTKView`、`var frameSize: (w: Int, h: Int)`
  - `Renderer.onFrameSize: ((Int, Int) -> Void)?`
  - `MirrorView.Coordinator.maxStreamWidth`（`private static let` = 1080）

> **為什麼是容器而不是 shader**：直覺解法是寫 Metal render pass 把 texture 畫到置中 quad，但那會逼著 `normalized()` 處理黑邊偏移、`KeymapController` 座標路徑跟著動——為了加一個功能污染三條既有路徑。容器方案讓 `MirrorMTKView.bounds` 永遠等於內容矩形，既有座標數學一行都不用改；黑邊上的點擊被 AppKit hit-test 天然擋在容器上，不是加 `if` 擋掉，是幾何上不會發生。

- [ ] **Step 1: 建立容器**

建立 `app/Sources/MirageApp/MirrorContainerView.swift`：

```swift
import AppKit
import MirageCore

/// 黑底容器：把 MirrorMTKView 佈局成 ViewportFit 算出的置中內容矩形，黑邊即本 view 的背景色。
///
/// 同時是**視窗長寬比的唯一權威**（原本散在 MirrorMTKView.viewDidMoveToWindow 與
/// Renderer.upload 兩處，且都硬編碼 9:20）。全螢幕時 macOS 忽略 contentAspectRatio，
/// 由本 view 的 letterbox 佈局接手——視窗模式黑邊為 0，兩者同一份程式碼。
final class MirrorContainerView: NSView {
    let mirror = MirrorMTKView(frame: .zero)

    /// 目前解碼幀尺寸。由 Renderer.onFrameSize 推入；(0, 0) 代表尚未收到任何幀。
    var frameSize: (w: Int, h: Int) = (0, 0) {
        didSet {
            guard frameSize != oldValue else { return }
            needsLayout = true
            applyWindowAspect()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(mirror)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let rect = ViewportFit.fit(frame: frameSize,
                                   in: (w: Int(bounds.width), h: Int(bounds.height)))
        // 尚未收到幀（或視窗尺寸為 0）：先鋪滿，避免第一幀前出現 0×0 的 drawable。
        guard rect.width > 0, rect.height > 0 else {
            mirror.frame = bounds
            return
        }
        mirror.frame = NSRect(x: CGFloat(rect.x), y: CGFloat(rect.y),
                              width: CGFloat(rect.width), height: CGFloat(rect.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowAspect()
    }

    /// 用**實際幀長寬比**鎖定視窗（取代原本硬編碼的 9:20）。尚無幀時用 9:20 當初始值，
    /// 收到第一幀（含之後遊戲轉向）會立即改寫。全螢幕期間不碰視窗尺寸——macOS 全螢幕
    /// 下視窗就是整片螢幕，設 contentAspectRatio 無效且會擾動退出全螢幕後的尺寸。
    private func applyWindowAspect() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        let aspect = frameSize.w > 0 && frameSize.h > 0 ? frameSize : (w: 9, h: 20)
        window.contentAspectRatio = NSSize(width: aspect.w, height: aspect.h)
        let w = max(window.frame.width, 270)
        window.setContentSize(NSSize(width: w, height: w * CGFloat(aspect.h) / CGFloat(aspect.w)))
    }
}
```

- [ ] **Step 2: 從 MirrorMTKView 移除長寬比職責**

修改 `app/Sources/MirageApp/MirrorView.swift` 的 `viewDidMoveToWindow`——**刪掉**長寬比鎖定與 `setContentSize`（含其上方那段 AUTHORIZED FIX 註解，職責已移交容器），只留焦點與 mouseMoved 兩行：

```swift
    /// 長寬比鎖定已移交 MirrorContainerView（P1-e：全螢幕下 macOS 忽略 contentAspectRatio，
    /// 需要 letterbox 容器統一負責；順帶移除原本硬編碼的 9:20）。此處只保留輸入前置條件。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // P1-c：keyDown/keyUp 需要 first responder；mouseMoved（look）需要視窗開啟
        // acceptsMouseMovedEvents——AppKit 預設不投遞 mouseMoved，兩者缺一都會讓
        // KeymapController 完全收不到輸入。
        window.acceptsMouseMovedEvents = true
        window.makeFirstResponder(self)
    }
```

- [ ] **Step 3: Renderer 交出長寬比、改推播幀尺寸**

修改 `app/Sources/MirageApp/Renderer.swift`：

在屬性區（`private(set) var lastFrameSize` 下方）新增：

```swift
    /// P1-e：幀尺寸變動時通知容器重算 letterbox（含遊戲轉向時的長寬比翻轉）。
    var onFrameSize: ((Int, Int) -> Void)?
```

在 `upload(_:into:)` 的 `if texture?.width != frame.width || texture?.height != frame.height {` 區塊內，**刪除**這兩行與其上方的 AUTHORIZED FIX 註解：

```swift
            view.window?.contentAspectRatio = NSSize(width: frame.width,
                                                     height: frame.height)
```

改為在同一區塊末尾加：

```swift
            // P1-e：長寬比的唯一權威改為 MirrorContainerView（原本此處與
            // MirrorMTKView.viewDidMoveToWindow 兩邊各設一次，且後者硬編碼 9:20）。
            onFrameSize?(frame.width, frame.height)
```

- [ ] **Step 4: MirrorView 改回傳容器**

修改 `app/Sources/MirageApp/MirrorView.swift` 的 `MirrorView`——`makeNSView`/`updateNSView` 的型別由 `MirrorMTKView` 改為 `MirrorContainerView`，事件接線目標改為 `container.mirror`：

```swift
    func makeNSView(context: Context) -> MirrorContainerView {
        let container = MirrorContainerView(frame: .zero)
        let view = container.mirror
        let renderer = Renderer(view: view, box: box)
        renderer?.onFrameSize = { [weak container] w, h in
            container?.frameSize = (w: w, h: h)
        }
        context.coordinator.renderer = renderer
        context.coordinator.controller = controller
        view.onMouse = { nx, ny, down in
            context.coordinator.sendMouse(nx: nx, ny: ny, down: down)
        }
        view.onResize = { pixelSize in
            context.coordinator.resizeDebounced(to: pixelSize)
        }
        view.onKey = { code, down in
            if down { context.coordinator.controller?.handleKeyDown(code) }
            else { context.coordinator.controller?.handleKeyUp(code) }
        }
        view.onMouseMovedDelta = { dx, dy in
            context.coordinator.controller?.handleMouseMoved(dx: dx, dy: dy)
        }
        view.onFlagsChanged = { event in
            context.coordinator.controller?.handleFlagsChanged(event)
        }
        return container
    }

    func updateNSView(_ view: MirrorContainerView, context: Context) {
        context.coordinator.controller = controller
    }
```

- [ ] **Step 5: 串流尺寸改用實際幀比 + 上限**

修改 `app/Sources/MirageApp/MirrorView.swift` 的 `Coordinator`——新增上限常數並改寫 `resizeDebounced`（`onResize` 傳來的 `pixelSize` 現在就是**內容矩形**的 backing 尺寸，因為 `MirrorMTKView.bounds` 已等於內容矩形）：

```swift
        /// 全螢幕會把內容矩形放大到螢幕高度，4K 螢幕上直向遊戲可算出 ~880×1960；
        /// 再往上會有掉 fps 風險（spec R4）。上限值可調，調整依據是 MIRAGE_FPS_LOG 實測。
        private static let maxStreamWidth = 1080

        func resizeDebounced(to pixelSize: CGSize) {
            resizeTask?.cancel()
            resizeTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                // P1-e：長寬比改用實際解碼幀（原本硬編碼 h = w * 20 / 9，遊戲轉橫向就錯）。
                let aspect = renderer?.lastFrameSize ?? Self.defaultGuestSize
                let clamped = min(max(Int(pixelSize.width), 270), Self.maxStreamWidth)
                let w = clamped & ~1                                   // 偶數對齊
                let h = max(aspect.h * w / aspect.w, 2) & ~1
                guestSize = (w, h)
                await client.setStreamSize(width: w, height: h)
                controller?.setGuestSize((w, h))   // 引擎觸控座標跟著新串流尺寸換算
            }
        }
```

- [ ] **Step 6: 建置並跑全套測試（確認零回歸）**

Run: `cd app && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -20`
Expected: 建置成功、無新警告；既有 101 個 `@Test` 全綠（本任務只改 App 層，Core 測試不受影響）。

- [ ] **Step 7: release 建置零警告**

Run: `cd app && swift build -c release 2>&1 | grep -i "warning" | grep -v deprecat | head`
Expected: 無輸出。

- [ ] **Step 8: Commit**

```bash
cd app && git add Sources/MirageApp/MirrorContainerView.swift Sources/MirageApp/MirrorView.swift Sources/MirageApp/Renderer.swift
git commit -m "feat: MirrorContainerView letterbox 佈局與長寬比權威收斂

黑邊改由容器背景色提供，MirrorMTKView.bounds 恆等於內容矩形，既有座標路徑
零改動。順手清掉散在兩處的 9:20 硬編碼，改由實際解碼幀長寬比驅動（遊戲轉
橫向自動支援）；串流尺寸加 maxStreamWidth 上限防全螢幕掉 fps。"
```

---

## Task 3: 全螢幕狀態、遊戲模式 chrome 隱藏、選單列入口

**Files:**
- Modify: `app/Sources/MirageApp/MirageApp.swift`（`AppModel.isFullScreen`、`keymapOverlayLayer` gating、觀察者）
- Modify: `app/Sources/MirageApp/Lifecycle/MenuBarController.swift`（+「遊戲模式（全螢幕）」）

**Interfaces:**
- Consumes: `MenuBarController.init(onWake:onShow:)`（既有）
- Produces:
  - `AppModel.isFullScreen: Bool`
  - `AppModel.startFullScreenObserver()`
  - `MenuBarController.onToggleFullScreen: (() -> Void)?`

- [ ] **Step 1: 選單列加入口**

修改 `app/Sources/MirageApp/Lifecycle/MenuBarController.swift`：

在 `var onForce: ((String) -> Void)?` 下方新增：

```swift
    /// P1-e：AppModel.startLifecycle() 綁定 → NSApp.keyWindow?.toggleFullScreen(nil)。
    var onToggleFullScreen: (() -> Void)?
```

在 `init` 的選單建構中，「顯示視窗」那行之後插入：

```swift
        menu.addItem(withTitle: "遊戲模式（全螢幕）", action: #selector(fullScreenTapped),
                     keyEquivalent: "").target = self
```

在 `@objc private func showTapped()` 下方新增：

```swift
    @objc private func fullScreenTapped() { onToggleFullScreen?() }
```

- [ ] **Step 2: AppModel 追蹤全螢幕狀態**

修改 `app/Sources/MirageApp/MirageApp.swift`——在 `var editing = false` 附近新增屬性：

```swift
    /// P1-e：全螢幕（遊戲模式）狀態。**由系統通知驅動，不自行推測**——使用者可能用綠燈、
    /// ⌃⌘F、Mission Control 或選單列任一途徑進出，只有 NSWindow 通知涵蓋全部。
    var isFullScreen = false
```

在 `startLifecycle()` 內、`menuBar?.updateStatus(...)` 之後加入觀察者綁定與選單列回呼：

```swift
        menuBar?.onToggleFullScreen = { NSApp.keyWindow?.toggleFullScreen(nil) }
        startFullScreenObserver()
```

並在 `startLifecycle()` 下方新增：

```swift
    /// 兩個通知都不帶我們需要的資訊，故忽略 Notification 本體（它非 Sendable，
    /// 捕捉進 @Sendable 閉包會觸發 strict-concurrency 警告）。
    private func startFullScreenObserver() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isFullScreen = true }
        }
        center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isFullScreen = false }
        }
    }
```

- [ ] **Step 3: 全螢幕隱藏 keymap overlay**

修改 `app/Sources/MirageApp/MirageApp.swift` 的 `keymapOverlayLayer`——加上全螢幕 gating（**編輯模式例外**：使用者若在全螢幕下按 ⌘E，仍必須看得到編輯器，否則會卡在看不見的編輯模式裡）：

```swift
    @MainActor
    @ViewBuilder
    private var keymapOverlayLayer: some View {
        if model.editing, let profile = model.profile {
            OverlayEditorView(
                profile: SwiftUI.Binding(get: { profile }, set: { model.profile = $0 }),
                onSave: { model.saveProfile($0) }
            )
        } else if !model.isFullScreen {
            // P1-e 遊戲模式：全螢幕時隱藏唯讀提示標記（純視覺噪音）。ConnectionBanner
            // 與 InstallBanner 刻意保留——前者是必須知道的異常，後者是使用者主動觸發的回饋。
            KeymapOverlay(profile: model.profile)
        }
    }
```

- [ ] **Step 4: 建置並跑全套測試**

Run: `cd app && swift build 2>&1 | tail -20 && swift test 2>&1 | tail -5`
Expected: 建置成功無新警告；既有測試全綠。

- [ ] **Step 5: Commit**

```bash
cd app && git add Sources/MirageApp/MirageApp.swift Sources/MirageApp/Lifecycle/MenuBarController.swift
git commit -m "feat: 全螢幕遊戲模式狀態、overlay 隱藏與選單列入口

isFullScreen 由 NSWindow.didEnter/didExitFullScreen 通知驅動（涵蓋綠燈/⌃⌘F/
Mission Control 全部途徑）；全螢幕隱藏 keymap 提示標記，編輯模式例外，
ConnectionBanner/InstallBanner 保留。不綁 Esc——Esc 在 guest 是返回鍵。"
```

---

# Part B — 音訊輸出（Task 4–9）

## Task 4: AudioStreamFormat / AudioChunk 與 S16→Float32 轉換

**Files:**
- Create: `app/Sources/MirageCore/Audio/AudioTransport.swift`
- Test: `app/Tests/MirageCoreTests/AudioChunkTests.swift`

**Interfaces:**
- Consumes: 無
- Produces:
  - `public struct AudioStreamFormat: Equatable, Sendable { public let samplingRate: Int; public let channels: Int; public static let standard: AudioStreamFormat; public init(samplingRate:channels:) }`
  - `public struct AudioChunk: Equatable, Sendable { public let samples: [Float]; public init(samples:); public static func fromS16LE(_ data: Data) -> AudioChunk }`
  - `public protocol AudioTransport: Sendable { func packets(format: AudioStreamFormat) -> AsyncThrowingStream<AudioChunk, Error>; func cancelStream() }`

> **轉換為何在生產者端**：即時執行緒（`AVAudioSourceNode` 的 render block）不得配置記憶體。把 S16→Float32 的轉換與陣列配置全部壓在 gRPC 消費 task 上，render block 就只剩一次 memcpy。

- [ ] **Step 1: 寫失敗測試**

建立 `app/Tests/MirageCoreTests/AudioChunkTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

@Suite struct AudioChunkTests {
    @Test func emptyDataYieldsNoSamples() {
        #expect(AudioChunk.fromS16LE(Data()).samples.isEmpty)
    }

    @Test func silenceDecodesToZero() {
        let chunk = AudioChunk.fromS16LE(Data([0x00, 0x00, 0x00, 0x00]))
        #expect(chunk.samples == [0.0, 0.0])
    }

    /// S16 最小值 -32768 → -1.0（除以 32768，非 32767：避免正負不對稱與 clipping）。
    @Test func minimumSampleMapsToNegativeOne() {
        let chunk = AudioChunk.fromS16LE(Data([0x00, 0x80]))   // little-endian 0x8000
        #expect(chunk.samples == [-1.0])
    }

    /// S16 最大值 32767 → 略小於 1.0。
    @Test func maximumSampleMapsJustBelowOne() {
        let chunk = AudioChunk.fromS16LE(Data([0xFF, 0x7F]))   // little-endian 0x7FFF
        #expect(chunk.samples.count == 1)
        #expect(abs(chunk.samples[0] - 0.999969) < 0.000_01)
    }

    @Test func littleEndianByteOrderIsRespected() {
        // 0x0100 little-endian = 256 → 256 / 32768 = 0.0078125
        let chunk = AudioChunk.fromS16LE(Data([0x00, 0x01]))
        #expect(chunk.samples == [0.0078125])
    }

    /// 防禦：位元組數為奇數（截斷的封包）不得崩潰，尾端半個 sample 直接丟棄。
    @Test func oddByteCountTruncatesInsteadOfCrashing() {
        let chunk = AudioChunk.fromS16LE(Data([0x00, 0x00, 0x7F]))
        #expect(chunk.samples == [0.0])
    }

    @Test func standardFormatIs48kStereo() {
        #expect(AudioStreamFormat.standard == AudioStreamFormat(samplingRate: 48_000, channels: 2))
    }
}
```

- [ ] **Step 2: 執行確認失敗**

Run: `cd app && swift test --filter AudioChunkTests`
Expected: 編譯失敗，`cannot find 'AudioChunk' in scope`。

- [ ] **Step 3: 最小實作**

建立 `app/Sources/MirageCore/Audio/AudioTransport.swift`：

```swift
import Foundation

/// 向 emulator 請求的音訊串流格式。取樣格式固定 S16（proto 只有 U8/S16 兩種，
/// S16 是品質較好的那個），故不參數化。
public struct AudioStreamFormat: Equatable, Sendable {
    public let samplingRate: Int
    public let channels: Int

    public init(samplingRate: Int, channels: Int) {
        self.samplingRate = samplingRate
        self.channels = channels
    }

    /// proto 註明取樣率上限 48kHz、Android 裝置典型即 48k——固定用它就不需要重採樣。
    public static let standard = AudioStreamFormat(samplingRate: 48_000, channels: 2)
}

/// 一包已解碼的音訊：interleaved Float32，範圍 [-1, 1)。
public struct AudioChunk: Equatable, Sendable {
    public let samples: [Float]

    public init(samples: [Float]) { self.samples = samples }

    /// S16 little-endian 位元組 → interleaved Float32。
    ///
    /// 在生產者執行緒呼叫——配置與轉換都不得發生在即時執行緒上。
    /// 位元組數為奇數時尾端半個 sample 直接丟棄（防禦性，不崩）。
    public static func fromS16LE(_ data: Data) -> AudioChunk {
        let count = data.count / 2
        guard count > 0 else { return AudioChunk(samples: []) }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let lo = UInt16(raw[i * 2])
                let hi = UInt16(raw[i * 2 + 1])
                let s = Int16(bitPattern: lo | (hi << 8))
                out[i] = Float(s) / 32_768.0
            }
        }
        return AudioChunk(samples: out)
    }
}

/// 音訊來源的注入點——對齊既有 `DisplayTransport` 的慣例，讓 EmulatorClient 的
/// attach/detach 編排可以用假件測試（見 EmulatorClientAudioTests）。
public protocol AudioTransport: Sendable {
    func packets(format: AudioStreamFormat) -> AsyncThrowingStream<AudioChunk, Error>

    /// 顯式取消底層 RPC。
    ///
    /// **不可省略**：`AsyncThrowingStream` 的 `onTermination` + `Task.cancel()`
    /// 不足以中斷已 in-flight 的 `next()`——這是 P1-b 剪貼簿串流實證過的坑
    /// （見 `EmulatorClient.startClipboardStream` 的 ADAPTATION 註解）。而 proto 明載
    /// 「The stream may block indefinitely if the emulator ceases to produce audio」，
    /// guest 靜音時就是這個情境，沒有真 cancel 會卡住並在 channel 拆除時觸發
    /// NIO "leaking promise" 致命錯誤。
    func cancelStream()
}
```

- [ ] **Step 4: 執行確認通過**

Run: `cd app && swift test --filter AudioChunkTests`
Expected: PASS，7 個測項全綠。

- [ ] **Step 5: Commit**

```bash
cd app && git add Sources/MirageCore/Audio/AudioTransport.swift Tests/MirageCoreTests/AudioChunkTests.swift
git commit -m "feat: AudioChunk/AudioStreamFormat 與 S16→Float32 轉換（TDD）"
```

---

## Task 5: AudioRingBuffer（SPSC 無鎖環形緩衝）

**Files:**
- Modify: `app/Package.swift`（+ swift-atomics）
- Create: `app/Sources/MirageCore/Audio/AudioRingBuffer.swift`
- Test: `app/Tests/MirageCoreTests/AudioRingBufferTests.swift`

**Interfaces:**
- Consumes: 無
- Produces:
  - `public struct AudioStats: Equatable, Sendable { public let underruns: Int, overruns: Int, depthSamples: Int, writes: Int }`
  - `public final class AudioRingBuffer: @unchecked Sendable`
    - `public init(capacitySamples: Int = 19_200)`
    - `public func write(_ samples: [Float])`
    - `public func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int`
    - `public var stats: AudioStats { get }`

> **本專案唯一允許 mutate 的資料結構**。全域約束是「不可變優先」，這裡明文破例：即時音訊的 render callback **不得配置記憶體、不得加鎖、不得 log**，每包造新陣列會在即時執行緒觸發配置，結果是週期性爆音。破例範圍嚴格限縮在這一個 type 內——對外只暴露不可變的 `AudioChunk` 與 `AudioStats` 快照。
>
> **溢位丟新不丟舊**：緩衝滿時丟掉**新進**封包。丟舊需要生產者移動讀索引，會破壞 SPSC 的單一擁有者不變式。穩態下生產與消費都是 48k 不會持續溢位，只有瞬時卡頓才觸發。

- [ ] **Step 1: 加入 swift-atomics 依賴**

修改 `app/Package.swift`——在 `dependencies` 陣列加一行，並讓 `MirageCore` 依賴它：

```swift
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.27.5"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0"),
        // P1-e：SPSC 無鎖環形緩衝需要 atomic 讀寫索引。1.3.1 已存在於 Package.resolved
        // （grpc-swift 的傳遞依賴），此處只是宣告成可 import 的 product，不引入新的網路依賴。
        .package(url: "https://github.com/apple/swift-atomics.git", exact: "1.3.1"),
    ],
```

`MirageCore` target 的 dependencies 改為：

```swift
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
```

- [ ] **Step 2: 確認依賴解析未擾動既有版本**

Run: `cd app && swift package resolve && git diff --stat Package.resolved`
Expected: `Package.resolved` **無變更**（swift-atomics 1.3.1 早已在其中）。若有變更，停下來檢查——不得因本任務升降任何既有套件版本。

- [ ] **Step 3: 寫失敗測試**

建立 `app/Tests/MirageCoreTests/AudioRingBufferTests.swift`：

```swift
import Testing
@testable import MirageCore

/// 測試用讀取輔助：包一層讓每個測項不必各自管 UnsafeMutablePointer 生命週期。
private func readSamples(_ ring: AudioRingBuffer, count: Int) -> (got: Int, values: [Float]) {
    var out = [Float](repeating: .nan, count: count)
    let got = out.withUnsafeMutableBufferPointer { buf in
        ring.read(into: buf.baseAddress!, count: count)
    }
    return (got, out)
}

@Suite struct AudioRingBufferTests {
    @Test func writeThenReadRoundTripsValues() {
        let ring = AudioRingBuffer(capacitySamples: 16)
        ring.write([1, 2, 3, 4])
        let (got, values) = readSamples(ring, count: 4)
        #expect(got == 4)
        #expect(Array(values.prefix(4)) == [1, 2, 3, 4])
    }

    @Test func readOnEmptyReturnsZeroAndCountsUnderrun() {
        let ring = AudioRingBuffer(capacitySamples: 16)
        let (got, _) = readSamples(ring, count: 8)
        #expect(got == 0)
        #expect(ring.stats.underruns == 1)
    }

    @Test func partialReadCountsUnderrunAndReturnsWhatExists() {
        let ring = AudioRingBuffer(capacitySamples: 16)
        ring.write([1, 2])
        let (got, values) = readSamples(ring, count: 5)
        #expect(got == 2)
        #expect(Array(values.prefix(2)) == [1, 2])
        #expect(ring.stats.underruns == 1)
    }

    @Test func writeExceedingFreeSpaceIsDroppedWholeAndCountsOverrun() {
        let ring = AudioRingBuffer(capacitySamples: 4)
        ring.write([1, 2, 3])
        ring.write([4, 5])                       // 只剩 1 格 → 整包丟棄
        #expect(ring.stats.overruns == 1)
        #expect(ring.stats.depthSamples == 3)    // 原本的 3 個仍在
        let (got, values) = readSamples(ring, count: 3)
        #expect(got == 3)
        #expect(Array(values.prefix(3)) == [1, 2, 3])
    }

    /// 寫入超過容量本身的單包也只是丟棄，不得寫壞記憶體。
    @Test func writeLargerThanCapacityIsDropped() {
        let ring = AudioRingBuffer(capacitySamples: 4)
        ring.write([1, 2, 3, 4, 5, 6])
        #expect(ring.stats.overruns == 1)
        #expect(ring.stats.depthSamples == 0)
    }

    /// 環繞：寫滿→讀空→再寫，資料必須跨越實體陣列尾端仍然正確。
    @Test func wrapAroundPreservesOrder() {
        let ring = AudioRingBuffer(capacitySamples: 4)
        ring.write([1, 2, 3])
        _ = readSamples(ring, count: 3)
        ring.write([4, 5, 6])                    // 寫入位置跨過陣列尾端
        let (got, values) = readSamples(ring, count: 3)
        #expect(got == 3)
        #expect(Array(values.prefix(3)) == [4, 5, 6])
    }

    @Test func statsTracksWriteCountAndDepth() {
        let ring = AudioRingBuffer(capacitySamples: 16)
        ring.write([1, 2])
        ring.write([3, 4, 5])
        #expect(ring.stats.writes == 2)
        #expect(ring.stats.depthSamples == 5)
    }

    /// 生產者/消費者併發：不得崩潰、不得讀到損毀值（每個 sample 都是遞增序列的一員）。
    @Test func concurrentProducerConsumerKeepsDataIntact() async {
        let ring = AudioRingBuffer(capacitySamples: 4_096)
        let total = 200 * 64
        let producer = Task.detached {
            for chunk in 0..<200 {
                ring.write((0..<64).map { Float(chunk * 64 + $0) })
                await Task.yield()
            }
        }
        let consumer = Task.detached { () -> [Float] in
            var collected: [Float] = []
            while collected.count < total {
                let (got, values) = readSamples(ring, count: 128)
                if got == 0 { await Task.yield(); continue }
                collected.append(contentsOf: values.prefix(got))
                if ring.stats.overruns > 0 { break }   // 消費端落後時提早結束，不無限等
            }
            return collected
        }
        await producer.value
        let collected = await consumer.value
        // 讀到的值必須嚴格遞增——任何撕裂或索引錯亂都會破壞這個性質。
        #expect(collected == collected.sorted())
        #expect(Set(collected).count == collected.count)
    }
}
```

- [ ] **Step 4: 執行確認失敗**

Run: `cd app && swift test --filter AudioRingBufferTests`
Expected: 編譯失敗，`cannot find 'AudioRingBuffer' in scope`。

- [ ] **Step 5: 最小實作**

建立 `app/Sources/MirageCore/Audio/AudioRingBuffer.swift`：

```swift
import Atomics

/// 環形緩衝的可觀測快照（不可變）。`MIRAGE_AUDIO_LOG=1` 每秒印它。
public struct AudioStats: Equatable, Sendable {
    public let underruns: Int
    public let overruns: Int
    public let depthSamples: Int
    public let writes: Int

    public init(underruns: Int, overruns: Int, depthSamples: Int, writes: Int) {
        self.underruns = underruns
        self.overruns = overruns
        self.depthSamples = depthSamples
        self.writes = writes
    }
}

/// 單生產者單消費者（SPSC）無鎖環形緩衝。
///
/// **本專案唯一允許 mutate 的資料結構**——全域約束是「不可變優先」，此處明文破例：
/// CoreAudio 的 render callback 跑在即時執行緒，不得配置記憶體、不得加鎖、不得 log。
/// 每包造新陣列會在即時執行緒觸發配置，結果是週期性爆音。破例範圍嚴格限縮在本 type 內，
/// 對外只暴露不可變的 `AudioStats` 快照。
///
/// 生產者只碰 `writeIndex`，消費者只碰 `readIndex`；索引單調遞增（不對容量取模），
/// 讀寫位置才用 `% capacity` 算——這樣 `write - read` 直接就是可用量，不需要「滿 vs 空」
/// 的歧義判斷，消除一個經典的環形緩衝特殊情況。
public final class AudioRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let writeIndex = ManagedAtomic<Int>(0)
    private let readIndex = ManagedAtomic<Int>(0)
    private let underrunCount = ManagedAtomic<Int>(0)
    private let overrunCount = ManagedAtomic<Int>(0)
    private let writeCount = ManagedAtomic<Int>(0)

    /// 預設 19200 = 48kHz × 2ch × 200ms。這是**溢位前的天花板**，不是目標深度；
    /// 穩態深度由生產端節奏自然決定（~100ms），不另設節流。
    public init(capacitySamples: Int = 19_200) {
        capacity = max(capacitySamples, 1)
        storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0)
    }

    deinit { storage.deallocate() }

    public var stats: AudioStats {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .acquiring)
        return AudioStats(underruns: underrunCount.load(ordering: .relaxed),
                          overruns: overrunCount.load(ordering: .relaxed),
                          depthSamples: w - r,
                          writes: writeCount.load(ordering: .relaxed))
    }

    /// 生產者執行緒（gRPC 消費 task）呼叫。空間不足 → **整包丟棄** + overruns += 1。
    public func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let w = writeIndex.load(ordering: .relaxed)
        let r = readIndex.load(ordering: .acquiring)
        guard capacity - (w - r) >= samples.count else {
            overrunCount.wrappingIncrement(ordering: .relaxed)
            return
        }
        for (i, sample) in samples.enumerated() {
            storage[(w + i) % capacity] = sample
        }
        writeIndex.store(w + samples.count, ordering: .releasing)
        writeCount.wrappingIncrement(ordering: .relaxed)
    }

    /// 即時執行緒（AVAudioSourceNode render block）呼叫。
    /// 回傳實際寫入 `dst` 的樣本數；不足 `count` 時 underruns += 1，餘下由呼叫端補靜音。
    /// 不配置、不加鎖、不 log。
    public func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let r = readIndex.load(ordering: .relaxed)
        let w = writeIndex.load(ordering: .acquiring)
        let n = min(count, w - r)
        guard n > 0 else {
            underrunCount.wrappingIncrement(ordering: .relaxed)
            return 0
        }
        for i in 0..<n {
            dst[i] = storage[(r + i) % capacity]
        }
        readIndex.store(r + n, ordering: .releasing)
        if n < count { underrunCount.wrappingIncrement(ordering: .relaxed) }
        return n
    }
}
```

- [ ] **Step 6: 執行確認通過**

Run: `cd app && swift test --filter AudioRingBufferTests`
Expected: PASS，8 個測項全綠。

- [ ] **Step 7: 確認逐行 100% 覆蓋**

Run: `cd app && swift test --filter "AudioRingBufferTests|AudioChunkTests" --enable-code-coverage && xcrun llvm-cov report .build/debug/MiragePackageTests.xctest/Contents/MacOS/MiragePackageTests -instr-profile .build/debug/codecov/default.profdata 2>/dev/null | grep -E "AudioRingBuffer|AudioTransport"`
Expected: `AudioRingBuffer.swift` line coverage 為 `100.00%`。未達則補測試。

- [ ] **Step 8: Commit**

```bash
cd app && git add Package.swift Sources/MirageCore/Audio/AudioRingBuffer.swift Tests/MirageCoreTests/AudioRingBufferTests.swift
git commit -m "feat: AudioRingBuffer SPSC 無鎖環形緩衝（TDD，逐行 100%）

即時執行緒禁配置/禁鎖，故明文破例採可變資料結構，範圍限縮在此 type 內。
索引單調遞增不取模，消除「滿 vs 空」歧義；溢位丟新不丟舊以維持 SPSC 不變式。
swift-atomics 1.3.1 早在 Package.resolved（grpc-swift 傳遞依賴），僅宣告為 product。"
```

---

## Task 6: GrpcAudioTransport（streamAudio 封裝）

**Files:**
- Create: `app/Sources/MirageCore/Audio/GrpcAudioTransport.swift`

**Interfaces:**
- Consumes: `AudioTransport`、`AudioStreamFormat`、`AudioChunk.fromS16LE`（Task 4）；`GrpcChannelBox`（既有，`GrpcStreamTransport.swift`）
- Produces: `public final class GrpcAudioTransport: AudioTransport, @unchecked Sendable { public init(channel: GrpcChannelBox) }`

> **本任務沒有單元測試，這是刻意的。** 與既有 `GrpcStreamTransport` 同處境——它需要真 channel，寫假 channel 的成本遠高於價值。正確性由 Task 7 的編排測試（假 `AudioTransport`）+ Task 9 的活體驗證共同覆蓋。

> **必須用 `makeStreamAudioCall` 而非 `streamAudio` 便利方法**：後者只回傳 `GRPCAsyncResponseStream`，丟棄底層 call，`cancel()` 無從呼叫。P1-b 的剪貼簿串流踩過完全一樣的坑（見 `EmulatorClient.startClipboardStream` 的 ADAPTATION 註解）：`GRPCAsyncResponseStream.next()` 只在每次呼叫開始時同步檢查 `Task.isCancelled`，**不會**中斷已 in-flight 的 await，也不會解決 NIO 的 pending promise。

- [ ] **Step 1: 實作**

建立 `app/Sources/MirageCore/Audio/GrpcAudioTransport.swift`：

```swift
import Foundation
import GRPC

/// `streamAudio` 的 gRPC 封裝。持有真正的 call 物件，讓 `cancelStream()` 能中斷
/// 一條「guest 靜音時會無限阻塞」的串流（proto 明載此行為）。
public final class GrpcAudioTransport: AudioTransport, @unchecked Sendable {
    private let channel: GrpcChannelBox
    // call 型別非 Sendable，用鎖保護；@unchecked Sendable 的理由與既有 GrpcChannelBox 相同。
    private let lock = NSLock()
    private var call: GRPCAsyncServerStreamingCall<
        Android_Emulation_Control_AudioFormat,
        Android_Emulation_Control_AudioPacket
    >?

    public init(channel: GrpcChannelBox) { self.channel = channel }

    public func packets(format: AudioStreamFormat) -> AsyncThrowingStream<AudioChunk, Error> {
        var fmt = Android_Emulation_Control_AudioFormat()
        fmt.samplingRate = UInt64(format.samplingRate)
        fmt.channels = format.channels >= 2 ? .stereo : .mono
        fmt.format = .audFmtS16
        // modeRealTime：落後時由 emulator 覆寫佇列而非阻塞累積延遲。proto 把 mode 標為
        // [Input Only]，對 streamAudio 是否生效未經證實——不論生效與否都安全，我們自己的
        // 環形緩衝溢位丟包已經守住延遲上限。
        fmt.mode = .modeRealTime

        let call = channel.client.makeStreamAudioCall(fmt)
        lock.lock(); self.call = call; lock.unlock()

        // 只捕捉 responseStream（grpc-swift 明確標 Sendable），不捕捉 call 本身，
        // 否則 Task 閉包跨隔離傳遞會觸發 strict-concurrency 資料競爭警告。
        let responses = call.responseStream
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await packet in responses {
                        if Task.isCancelled { return }
                        cont.yield(AudioChunk.fromS16LE(packet.audio))
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// 必須在 channel 拆除**之前**呼叫（見 EmulatorClient.dropChannel 的順序）：
    /// 先解決 in-flight promise，NIO 的 group 才不會帶著未解決的 promise 關閉而致命。
    public func cancelStream() {
        lock.lock()
        let current = call
        call = nil
        lock.unlock()
        current?.cancel()
    }
}
```

- [ ] **Step 2: 建置確認型別對得上**

Run: `cd app && swift build 2>&1 | tail -20`
Expected: 建置成功。若 `makeStreamAudioCall` 的泛型參數不符，以 `Sources/MirageCore/Generated/emulator_controller.grpc.swift` 中該方法的實際簽章為準修正（**不要**改用 `streamAudio` 便利方法繞過——理由見本任務開頭）。

- [ ] **Step 3: 確認 release 零警告**

Run: `cd app && swift build -c release 2>&1 | grep -i warning | grep -v deprecat | head`
Expected: 無輸出。

- [ ] **Step 4: Commit**

```bash
cd app && git add Sources/MirageCore/Audio/GrpcAudioTransport.swift
git commit -m "feat: GrpcAudioTransport 封裝 streamAudio（持有真 call 供顯式 cancel）

用 makeStreamAudioCall 而非便利方法——後者丟棄底層 call，無法中斷 in-flight
next()，正是 P1-b 剪貼簿串流踩過的坑；guest 靜音時 streamAudio 會無限阻塞。"
```

---

## Task 7: EmulatorClient 音訊掛載編排（含假 transport 測試）

**Files:**
- Modify: `app/Sources/MirageCore/EmulatorClient.swift`
- Test: `app/Tests/MirageCoreTests/EmulatorClientAudioTests.swift`

**Interfaces:**
- Consumes: `AudioTransport`、`AudioStreamFormat.standard`、`AudioChunk`（Task 4）；`AudioRingBuffer`（Task 5）；`GrpcAudioTransport`（Task 6）
- Produces:
  - `EmulatorClient.init` 新增參數 `makeAudioTransport: @escaping @Sendable (GrpcChannelBox) -> AudioTransport = { GrpcAudioTransport(channel: $0) }`
  - `public func setAudioSink(_ ring: AudioRingBuffer?)`

> **為何用 `setAudioSink` 而不是改 `start(box:width:height:)` 的簽章**：改簽章會動到既有所有呼叫端與測試，憑空製造回歸風險。新增一個 setter 的成本是零。
>
> **`dropChannel()` 的順序是安全關鍵**：必須在 `channelBox = nil` **之前** `detachAudio()`。P1-b 實證過反向順序會讓 NIO 的 EventLoopGroup 帶著未解決的 promise 同步關閉，約 1/8 機率觸發 "leaking promise created" 致命錯誤。

- [ ] **Step 1: 寫失敗測試**

建立 `app/Tests/MirageCoreTests/EmulatorClientAudioTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

/// 可腳本化的假音訊 transport：記錄訂閱與 cancel 次數，依劇本送樣本或永掛。
final class MockAudioTransport: AudioTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _subscribeCount = 0
    private var _cancelCount = 0
    private let samplesPerPacket: [Float]

    init(samplesPerPacket: [Float] = [0.5, -0.5]) {
        self.samplesPerPacket = samplesPerPacket
    }

    var subscribeCount: Int { lock.lock(); defer { lock.unlock() }; return _subscribeCount }
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return _cancelCount }

    func packets(format: AudioStreamFormat) -> AsyncThrowingStream<AudioChunk, Error> {
        lock.lock(); _subscribeCount += 1; lock.unlock()
        let samples = samplesPerPacket
        return AsyncThrowingStream { cont in
            cont.yield(AudioChunk(samples: samples))
            // 不 finish：模擬持續中的健康串流（也正是 proto 描述的「可能無限阻塞」）。
        }
    }

    func cancelStream() {
        lock.lock(); _cancelCount += 1; lock.unlock()
    }
}

@Suite struct EmulatorClientAudioTests {
    /// 連上後音訊封包必須流進 sink。用既有 MockTransport 讓連線走到 .connected。
    @Test func connectedClientWritesAudioIntoSink() async throws {
        let audio = MockAudioTransport()
        let ring = AudioRingBuffer(capacitySamples: 64)
        let client = EmulatorClient(
            makeTransport: { _ in MockTransport([.yieldThenHang(1)]) },
            makeHealthProbe: { _ in ScriptedProbe([]) },
            makeAudioTransport: { _ in audio }
        )
        await client.setAudioSink(ring)
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .milliseconds(300))
        await client.stop()
        #expect(audio.subscribeCount >= 1)
        #expect(ring.stats.writes >= 1)
        #expect(ring.stats.depthSamples >= 2)
    }

    /// stop() 必須顯式 cancel 底層 RPC——否則 guest 靜音時串流永不結束。
    @Test func stopCancelsAudioStream() async throws {
        let audio = MockAudioTransport()
        let client = EmulatorClient(
            makeTransport: { _ in MockTransport([.yieldThenHang(1)]) },
            makeHealthProbe: { _ in ScriptedProbe([]) },
            makeAudioTransport: { _ in audio }
        )
        await client.setAudioSink(AudioRingBuffer(capacitySamples: 64))
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .milliseconds(300))
        await client.stop()
        #expect(audio.cancelCount >= 1)
    }

    /// 休眠即靜音、喚醒即恢復（spec 的「音訊跟畫面走」）。
    @Test func suspendStopsAudioAndWakeResumesIt() async throws {
        let audio = MockAudioTransport()
        let ring = AudioRingBuffer(capacitySamples: 1_024)
        let client = EmulatorClient(
            makeTransport: { _ in MockTransport([.yieldThenHang(1)]) },
            makeHealthProbe: { _ in ScriptedProbe([]) },
            makeAudioTransport: { _ in audio }
        )
        await client.setAudioSink(ring)
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .milliseconds(300))
        let subscribesBeforeSuspend = audio.subscribeCount
        await client.suspend()
        #expect(audio.cancelCount >= 1)
        await client.wake()
        try await Task.sleep(for: .milliseconds(300))
        #expect(audio.subscribeCount > subscribesBeforeSuspend)
        await client.stop()
    }

    /// 沒有 sink（App 尚未接上 AudioPlayer）時不得掛載、不得崩。
    @Test func noSinkMeansNoSubscription() async throws {
        let audio = MockAudioTransport()
        let client = EmulatorClient(
            makeTransport: { _ in MockTransport([.yieldThenHang(1)]) },
            makeHealthProbe: { _ in ScriptedProbe([]) },
            makeAudioTransport: { _ in audio }
        )
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .milliseconds(300))
        await client.stop()
        #expect(audio.subscribeCount == 0)
    }
}
```

**注意**：`ScriptedProbe` 與 `MockTransport` 都是**既有假件**，分別定義在 `Tests/MirageCoreTests/HealthProbeTests.swift:6` 與 `Tests/MirageCoreTests/EmulatorClientReconnectTests.swift:7`。同一測試 target 內直接沿用——**不要**重新宣告，會撞名編譯失敗。`ScriptedProbe([])` 是空劇本＝永遠回 `.healthy`（既有測試已這樣用，見該檔 line 46）。

- [ ] **Step 2: 執行確認失敗**

Run: `cd app && swift test --filter EmulatorClientAudioTests`
Expected: 編譯失敗，`extra argument 'makeAudioTransport' in call` 與 `value of type 'EmulatorClient' has no member 'setAudioSink'`。

- [ ] **Step 3: EmulatorClient 加入注入點與狀態**

修改 `app/Sources/MirageCore/EmulatorClient.swift`：

屬性區（`private let makeHealthProbe` 之後）新增：

```swift
    private let makeAudioTransport: @Sendable (GrpcChannelBox) -> AudioTransport
```

狀態區（`private var probe: HealthProbe?` 之後）新增：

```swift
    // P1-e 音訊：與 transport/pump 對稱——audioTransport 隨 channel 建立與拆除，
    // audioTask 是消費 task，audioRing 是 App 端提供的 sink（nil = 不掛載）。
    private var audioTransport: AudioTransport?
    private var audioTask: Task<Void, Never>?
    private var audioRing: AudioRingBuffer?
```

`init` 參數列在 `makeHealthProbe:` 之後新增（**放在有預設值的參數之間，不影響既有呼叫端**）：

```swift
                makeAudioTransport: @escaping @Sendable (GrpcChannelBox) -> AudioTransport
                    = { GrpcAudioTransport(channel: $0) },
```

`init` 主體對應新增：

```swift
        self.makeAudioTransport = makeAudioTransport
```

- [ ] **Step 4: 新增 sink setter 與 attach/detach**

在 `EmulatorClient` 內、`setStreamSize` 之後新增：

```swift
    /// App 層（AudioPlayer）提供的音訊 sink。刻意用 setter 而非改 `start` 的簽章——
    /// 改簽章會動到所有既有呼叫端與測試，憑空製造回歸風險。
    public func setAudioSink(_ ring: AudioRingBuffer?) {
        audioRing = ring
        if state == .connected { attachAudio() }
    }
```

在 `attachStream()` 之後新增：

```swift
    /// 與 attachStream 對稱：休眠期間不掛載；無 sink（App 未接 AudioPlayer）時靜默不掛。
    private func attachAudio() {
        guard power != .suspended, power != .suspending else { return }
        guard let audioTransport, let audioRing else { return }
        audioTask?.cancel()
        let stream = audioTransport.packets(format: .standard)
        audioTask = Task { [audioRing] in
            do {
                for try await chunk in stream {
                    if Task.isCancelled { return }
                    audioRing.write(chunk.samples)
                }
            } catch {
                // 串流斷屬正常（連線斷）；重連由既有連線迴圈負責，此處不自行重連。
                // 注意：**無封包 ≠ 斷線**——guest 靜音時本來就沒有封包，
                // 健康探測仍由 HealthProbe 獨佔負責。
            }
        }
    }

    /// 先取消 Swift Task，再顯式取消底層 RPC。後者不可省略：guest 靜音時
    /// streamAudio 會無限阻塞，Task.cancel() 中斷不了已 in-flight 的 next()。
    private func detachAudio() {
        audioTask?.cancel()
        audioTask = nil
        audioTransport?.cancelStream()
    }
```

- [ ] **Step 5: 接上既有生命週期的六個點**

同檔案，逐一加入（**只加行，不改既有語句**）：

1. `ensureChannel()` 內，`probe = makeHealthProbe(boxCh)` 之後：
   ```swift
                audioTransport = makeAudioTransport(boxCh)
   ```
2. `connectedRun()` 內，`attachStream()` 之後：
   ```swift
        attachAudio()
   ```
3. `runConnectionLoop()` 內**兩處** `await pump.detach()` 之後各加一行：
   ```swift
                detachAudio()
   ```
4. `stop()` 內，`await pump.detach()` 之後：
   ```swift
        detachAudio()
   ```
5. `suspend()` 內，`await pump.detach()` 之後：
   ```swift
        detachAudio()                       // 關視窗即靜音（音訊跟畫面走）
   ```
6. `wake()` 內，`if state == .connected { attachStream() }` 改為：
   ```swift
        if state == .connected { attachStream(); attachAudio() }
   ```
7. `dropChannel()` 內——**順序是安全關鍵**，加在最前面（`clipboardCall?.cancel()` 之前），並在 `transport = nil` 旁清掉 audioTransport：
   ```swift
    private func dropChannel() {
        detachAudio()               // 必須在 channelBox = nil 之前：先解決 in-flight
                                    // promise，NIO group 才不會帶著未解決 promise 關閉
                                    // （P1-b 實證約 1/8 機率觸發 leaking promise 致命錯誤）
        audioTransport = nil
        clipboardCall?.cancel()
        // …既有內容不動…
    }
   ```

- [ ] **Step 6: 執行確認通過**

Run: `cd app && swift test --filter EmulatorClientAudioTests`
Expected: PASS，4 個測項全綠。

- [ ] **Step 7: 跑全套測試確認零回歸**

Run: `cd app && swift test 2>&1 | tail -10`
Expected: 既有 101 個 `@Test` 加上本階段新增者全綠，無既有測試轉紅。

- [ ] **Step 8: Commit**

```bash
cd app && git add Sources/MirageCore/EmulatorClient.swift Tests/MirageCoreTests/EmulatorClientAudioTests.swift
git commit -m "feat: EmulatorClient 音訊掛載編排（假 transport 注入測試）

與 FramePump 完全對稱掛在既有連線/電源狀態機上，不新增第二條生命週期：
連上掛載、斷線/停止/休眠卸載、重連與喚醒重掛。dropChannel 先 detachAudio
再拆 channel——順序反了會重演 P1-b 的 NIO leaking promise 致命錯誤。"
```

---

## Task 8: AudioPlayer、AppModel 接線、靜音與觀測性

**Files:**
- Create: `app/Sources/MirageApp/Audio/AudioPlayer.swift`
- Modify: `app/Sources/MirageApp/MirageApp.swift`
- Modify: `app/Sources/MirageApp/Lifecycle/MenuBarController.swift`

**Interfaces:**
- Consumes: `AudioRingBuffer`（Task 5）、`EmulatorClient.setAudioSink`（Task 7）
- Produces:
  - `@MainActor final class AudioPlayer { init(ring: AudioRingBuffer); func start(); func setMuted(_:); var isMuted: Bool }`
  - `AppModel.audioRing: AudioRingBuffer`、`AppModel.audioPlayer: AudioPlayer?`、`AppModel.startAudio()`、`AppModel.toggleMute()`
  - `MenuBarController.onToggleMute: (() -> Void)?`、`MenuBarController.updateMute(_ muted: Bool)`

- [ ] **Step 1: 實作 AudioPlayer**

建立 `app/Sources/MirageApp/Audio/AudioPlayer.swift`：

```swift
import AVFoundation
import Foundation
import MirageCore

/// CoreAudio 出口：AVAudioEngine + AVAudioSourceNode，從環形緩衝拉樣本。
///
/// render block 跑在即時執行緒——**只做一次 memcpy 與補零**，不配置、不加鎖、不 log。
/// 所有轉換與配置都已在生產者端（AudioChunk.fromS16LE）完成。
@MainActor
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let ring: AudioRingBuffer
    private var node: AVAudioSourceNode?
    private(set) var isMuted = false

    init(ring: AudioRingBuffer) { self.ring = ring }

    /// 啟動失敗一律降級為「無音訊」——音訊絕不可拖垮鏡像主功能（畫面與輸入不受影響）。
    func start() {
        guard node == nil else { return }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48_000, channels: 2, interleaved: true) else {
            print("[audio] 無法建立 48k/stereo/Float32 格式，降級為無音訊")
            return
        }
        let ring = self.ring   // 只捕捉 sink（@unchecked Sendable），不捕捉 self
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let first = buffers.first,
                  let dst = first.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let wanted = Int(frameCount) * 2                 // interleaved stereo
            let got = ring.read(into: dst, count: wanted)
            if got < wanted {
                dst.advanced(by: got).update(repeating: 0, count: wanted - got)
            }
            return noErr
        }
        self.node = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            print("[audio] engine 啟動失敗，降級為無音訊：\(error)")
            self.node = nil
        }
    }

    /// macOS 沒有原生 per-app 音量——不給靜音等於玩家只能把整台 Mac 靜音。
    func setMuted(_ muted: Bool) {
        isMuted = muted
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    func stop() {
        engine.stop()
        node = nil
    }
}
```

- [ ] **Step 2: 選單列加靜音項**

修改 `app/Sources/MirageApp/Lifecycle/MenuBarController.swift`：

屬性區（`private let gameItem: NSMenuItem` 之後）新增：

```swift
    private let muteItem: NSMenuItem
```

`var onToggleFullScreen` 之後新增：

```swift
    /// P1-e：AppModel.startAudio() 綁定 → AudioPlayer.setMuted。
    var onToggleMute: (() -> Void)?
```

`init` 內，`gameItem = NSMenuItem(...)` 之後新增：

```swift
        muteItem = NSMenuItem(title: "靜音", action: nil, keyEquivalent: "")
```

`init` 的選單建構中，「遊戲模式（全螢幕）」那行之後插入：

```swift
        muteItem.action = #selector(muteTapped)
        muteItem.target = self
        menu.addItem(muteItem)
```

`@objc private func fullScreenTapped()` 之後新增：

```swift
    @objc private func muteTapped() { onToggleMute?() }
```

`func updateGame(...)` 之後新增：

```swift
    /// 勾選狀態反映目前是否靜音（AppKit 自動畫 ✓）。
    func updateMute(_ muted: Bool) { muteItem.state = muted ? .on : .off }
```

- [ ] **Step 3: AppModel 接線**

修改 `app/Sources/MirageApp/MirageApp.swift`：

屬性區（`let mouseCapture = MouseCapture()` 附近）新增：

```swift
    // P1-e 音訊：ring 是 Core 與 CoreAudio 的交會點——EmulatorClient 寫、AudioPlayer 讀。
    let audioRing = AudioRingBuffer()
    var audioPlayer: AudioPlayer?
```

在 `startLifecycle()` 內、`startFullScreenObserver()` 之後新增：

```swift
        startAudio()
```

在 `startFullScreenObserver()` 之後新增三個方法：

```swift
    /// 建立播放器 → 掛上 sink → 綁選單列。啟動失敗只降級為無音訊，不影響畫面與輸入。
    private func startAudio() {
        let player = AudioPlayer(ring: audioRing)
        player.start()
        audioPlayer = player
        menuBar?.onToggleMute = { [weak self] in self?.toggleMute() }
        menuBar?.updateMute(player.isMuted)
        Task { [client, audioRing] in await client.setAudioSink(audioRing) }
        startAudioLogIfRequested()
    }

    func toggleMute() {
        guard let audioPlayer else { return }
        audioPlayer.setMuted(!audioPlayer.isMuted)
        menuBar?.updateMute(audioPlayer.isMuted)
    }

    /// MIRAGE_AUDIO_LOG=1：每秒一行健康摘要。這是**唯一能無頭驗證音訊的訊號**，
    /// verify_audio.sh 的斷言建立在它之上。格式沿用 MIRAGE_FPS_LOG 的單行可 grep 風格。
    private func startAudioLogIfRequested() {
        guard ProcessInfo.processInfo.environment["MIRAGE_AUDIO_LOG"] == "1" else { return }
        Task { [audioRing] in
            var lastWrites = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let s = audioRing.stats
                let depthMs = s.depthSamples * 1000 / (48_000 * 2)
                print("[audio] pkt=\(s.writes - lastWrites) sr=48000 ch=2 " +
                      "under=\(s.underruns) over=\(s.overruns) depth=\(depthMs)ms")
                lastWrites = s.writes
            }
        }
    }
```

- [ ] **Step 4: 建置**

Run: `cd app && swift build 2>&1 | tail -20`
Expected: 建置成功。若 `AVAudioSourceNode` 的 render block 出現 strict-concurrency 警告，確認閉包只捕捉 `ring`（`@unchecked Sendable`），不得捕捉 `self` 或任何 `@MainActor` 屬性。

- [ ] **Step 5: 全套測試 + release 零警告**

Run: `cd app && swift test 2>&1 | tail -5 && swift build -c release 2>&1 | grep -i warning | grep -v deprecat | head`
Expected: 測試全綠；warning grep 無輸出。

- [ ] **Step 6: Commit**

```bash
cd app && git add Sources/MirageApp/Audio/AudioPlayer.swift Sources/MirageApp/MirageApp.swift Sources/MirageApp/Lifecycle/MenuBarController.swift
git commit -m "feat: AudioPlayer CoreAudio 出口、選單列靜音與 MIRAGE_AUDIO_LOG

render block 只做 memcpy 與補零，轉換與配置全在生產者端完成。engine 啟動
失敗降級為無音訊，畫面與輸入不受影響。"
```

---

## Task 9: 活體驗證（AudioLiveTests + verify_audio.sh）

**Files:**
- Create: `app/Tests/MirageCoreTests/AudioLiveTests.swift`
- Create: `app/scripts/verify_audio.sh`

**Interfaces:**
- Consumes: `EmulatorClient.setAudioSink`（Task 7）、`AudioRingBuffer.stats`（Task 5）
- Produces: 無（本任務產出的是驗收證據）

> **本任務有一個 spec 明列的未解問題必須先解決**：guest 不發聲就沒有封包。Step 1 就是去把它弄清楚，**不要**跳過直接寫測試。

- [ ] **Step 1: 先探測 guest 的發聲手段**

Run:
```bash
export ANDROID_SERIAL=emulator-5554
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
"$ADB" shell ls /system/media/audio/ringtones/ /system/media/audio/notifications/ 2>&1 | head -20
```
Expected: 列出可用音檔（AOSP 映像通常有 `Ring_Synth_04.ogg`、`Argon.ogg` 之類）。

把找到的檔名記下來，Step 3 的腳本要用。若兩個目錄都是空的，改用備案：`adb shell cmd media_session volume --show`（會發出系統音效），再不行則 sideload 一顆會發聲的 APK。**把實際採用的手段寫進 `RESULTS-p1e.md`**（Task 10）。

- [ ] **Step 2: 寫活體測試**

建立 `app/Tests/MirageCoreTests/AudioLiveTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

/// 活體：真模擬器 → streamAudio → 環形緩衝。預設 skip，MIRAGE_LIVE=1 開啟。
/// guest 必須正在發聲才會有封包——由 scripts/verify_audio.sh 負責先觸發發聲。
@Suite struct AudioLiveTests {
    @Test func realEmulatorDeliversAudioPackets() async throws {
        guard ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1" else { return }
        let ring = AudioRingBuffer()
        let client = EmulatorClient()
        await client.setAudioSink(ring)
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .seconds(5))
        let stats = ring.stats
        await client.stop()

        print("[audio-live] writes=\(stats.writes) depth=\(stats.depthSamples) " +
              "under=\(stats.underruns) over=\(stats.overruns)")
        // 每 20–30ms 一包（proto）→ 5 秒至少 150 包。門檻取一半留裕度。
        #expect(stats.writes >= 75, "guest 是否正在發聲？先跑 scripts/verify_audio.sh")
    }
}
```

- [ ] **Step 3: 寫驗證腳本**

建立 `app/scripts/verify_audio.sh`（**把 Step 1 找到的實際音檔路徑填進 `SOUND` 變數**）：

```bash
#!/usr/bin/env bash
# P1-e 音訊活體驗證：把媒體音量開到最大 → 觸發 guest 發聲 → 量測封包率與緩衝健康。
# 用法：verify_audio.sh    （需 emulator-5554 正在跑）
set -uo pipefail
export ANDROID_SERIAL=emulator-5554
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
SOUND="/system/media/audio/ringtones/Ring_Synth_04.ogg"   # ← 依 Step 1 實測結果調整

echo "=== 前置：模擬器是否在跑 ==="
nc -z localhost 8554 && echo "gRPC 8554 ALIVE" || { echo "模擬器未啟動"; exit 1; }

echo ""
echo "=== 觸發 guest 發聲（媒體音量開最大 → 播放內建音檔）==="
"$ADB" shell media volume --stream 3 --set 15 2>&1 | tail -2
"$ADB" shell am start -a android.intent.action.VIEW -d "file://$SOUND" -t audio/ogg 2>&1 | tail -3

echo ""
echo "=== 量測：streamAudio → AudioRingBuffer（5 秒）==="
cd "$(dirname "$0")/.." || exit 1
MIRAGE_LIVE=1 swift test --filter AudioLiveTests 2>&1 | grep -E "\[audio-live\]|Test.*(passed|failed)"

echo ""
echo "=== 判讀 ==="
echo "writes >= 75  → 驗收線 5 通過（5 秒 ≥ 150 包的一半裕度；proto 稱 20–30ms/包）"
echo "under == 0    → 驗收線 6 的必要條件（完整 60 秒版本需在 GUI App 下用 MIRAGE_AUDIO_LOG=1 觀察）"
```

- [ ] **Step 4: 賦予執行權限並跑腳本**

Run: `cd app && chmod +x scripts/verify_audio.sh && ./scripts/verify_audio.sh`
Expected: 印出 `[audio-live] writes=N …`，且 `writes >= 75`。

**若 writes == 0**：guest 沒發聲。回 Step 1 換發聲手段（別改門檻掩蓋問題）。若確認 emulator 的 `streamAudio` 在本機 canary 37.2.1 上完全不供包，**如實記錄為阻塞項**寫進 `RESULTS-p1e.md`，不要偽造通過。

- [ ] **Step 5: Commit**

```bash
cd app && git add Tests/MirageCoreTests/AudioLiveTests.swift scripts/verify_audio.sh
git commit -m "test: 音訊活體驗證（AudioLiveTests + verify_audio.sh）

腳本先把媒體音量開滿並播放 guest 內建音檔再量測——streamAudio 在 guest
靜音時不供包，沒有這一步量到的 0 是假陰性。"
```

---

## Task 10: 文件與驗收紀錄

**Files:**
- Create: `app/RESULTS-p1e.md`
- Modify: `app/README.md`

**Interfaces:**
- Consumes: Task 1–9 的全部產出與量測數字
- Produces: 無（文件）

- [ ] **Step 1: 蒐集驗收數字**

依序執行並保留輸出（**貼真實數字，不得憑印象填**）：

```bash
cd app
swift test 2>&1 | tail -5                                            # 驗收線 1
swift test --enable-code-coverage 2>&1 | tail -3
xcrun llvm-cov report .build/debug/MiragePackageTests.xctest/Contents/MacOS/MiragePackageTests \
  -instr-profile .build/debug/codecov/default.profdata 2>/dev/null \
  | grep -E "ViewportFit|AudioRingBuffer|TOTAL"                      # 驗收線 2、3
swift build -c release 2>&1 | grep -i warning | grep -v deprecat     # 驗收線 4
./scripts/verify_audio.sh                                            # 驗收線 5、6
```

**注意**：完整覆蓋率須用 `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --enable-code-coverage` 量測——只跑預設 `swift test` 會因活體測試提早 return 而漏掉大段覆蓋率（見 `RESULTS-p1a.md` 驗收 4 節）。

- [ ] **Step 2: 寫 RESULTS-p1e.md**

建立 `app/RESULTS-p1e.md`，逐條列出 spec §8 的 7 條驗收線，每條註明 **PASS / FAIL / pending-human / pending-unlock** 與**實際輸出**。必含以下三節：

1. **驗收線逐條**：7 條，附真實數字。fps（驗收線 7）需要 GUI，如未取得請標 pending-human，**不要**拿 transport 層數字冒充 App 合成層。
2. **Task 9 Step 1 的發聲手段結論**：實際採用哪個音檔／指令，以及是否可靠重現。
3. **pending-human 清單**（spec §9 五項）：真的聽得到聲音且無爆音、letterbox 目視、橫向遊戲全螢幕、遊戲模式 chrome 隱藏手感、全螢幕下 keymap/mouse capture 手感。註明原因：本機 GUI App headless 不驅動 SwiftUI `WindowGroup` 的 `.task`，需真 GUI session。

- [ ] **Step 3: 更新 README**

在 `app/README.md` 末尾新增 `# P1-e 全螢幕與音訊` 章節，比照既有各階段的寫法涵蓋：

- **全螢幕**：⌃⌘F／綠燈／選單列「遊戲模式（全螢幕）」三種入口；letterbox 由 `MirrorContainerView` + `ViewportFit` 負責；**不綁 Esc**（Esc 在 guest 是返回鍵）；全螢幕隱藏 keymap 提示但保留 ConnectionBanner／InstallBanner；串流寬度上限 `maxStreamWidth = 1080`。
- **橫向**：`ImageFormat.rotation` 為 `[Output Only]`，emulator 已把幀轉好；長寬比一律由實際解碼幀驅動，原本三處 9:20 硬編碼已移除。
- **音訊**：`streamAudio`（48k/stereo/S16/realTime）→ `AudioRingBuffer` → `AVAudioSourceNode`；關視窗即靜音（跟畫面走）；選單列「靜音」；`MIRAGE_AUDIO_LOG=1` 每秒一行健康摘要；活體 `./scripts/verify_audio.sh`。
- **已知限制／移交**：`RESULTS-p1e.md` 的 pending-human 清單；`AudioRingBuffer` 是專案唯一可變資料結構（即時執行緒要求）。
- 指向 `../docs/specs/2026-07-26-p1e-fullscreen-audio-design.md`。

- [ ] **Step 4: Commit**

```bash
cd app && git add RESULTS-p1e.md README.md
git commit -m "docs: P1-e 驗收結果與使用文件"
```

---

## 驗收線對照表（spec §8）

| # | 驗收線 | 由哪個 Task 產生證據 |
|---|---|---|
| 1 | `swift test` 全綠，既有 101 個 `@Test` 不回歸 | Task 7 Step 7、Task 10 Step 1 |
| 2 | `ViewportFit`、`AudioRingBuffer` 逐行 100% | Task 1 Step 5、Task 5 Step 7 |
| 3 | MirageCore 整體覆蓋率不低於現況（~94%） | Task 10 Step 1 |
| 4 | release 建置零非-deprecation 警告 | Task 2 Step 7、Task 6 Step 3、Task 8 Step 5 |
| 5 | 活體 packet 率 ≥ 30 pkt/s、48k/stereo/S16 | Task 9 Step 4 |
| 6 | 活體連續 60 秒 `underruns == 0` | Task 9 Step 4（部分）+ Task 10 pending-human（完整 60 秒需 GUI） |
| 7 | fps 不回歸（`MIRAGE_FPS_LOG` ≥ 55） | Task 10 Step 1（無 GUI 時標 pending-human） |
