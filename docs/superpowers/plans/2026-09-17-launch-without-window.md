# 啟動流程與鏡像視窗脫鉤實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 背景模式啟動時完全不建立鏡像視窗；一般模式行為不變。

**Architecture:** SwiftUI App 只留空的 `Settings` 場景提供主選單；`AppDelegate` 持有 `AppModel` 並在 `applicationDidFinishLaunching` 呼叫 `model.launch()`（原 `.task` 內容）；鏡像視窗改由 `MirrorWindowController` 以 AppKit `NSWindow` 加 `NSHostingView(MirrorRootView)` 在第一次需要時建立。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Swift Testing。

**Spec:** `docs/specs/2026-09-17-launch-without-window-design.md`

## Global Constraints

- 最低支援 macOS 14（`app/Package.swift` 的 `.macOS(.v14)`），不使用 macOS 15 以上的 API。
- 畫面內容（`MirrorView`、疊層、兩個 `.alert`）只搬位置，不改內容。
- 視窗 autosave 名稱維持 `mirage-mirror`（`verify_fps_fullscreen.sh:415`、`:697` 刪這個 key）。
- 視窗必須有 `.fullScreenPrimary`（`scripts/lib/gui_session.sh:109` 以 AX 設 `AXFullScreen`）。
- 單一鏡像視窗（D30）：只有 `MirrorWindowController.window()` 會建立 `NSWindow`，且只建立一次。
- 啟動順序不變：`start` → `startLifecycle` → `seedBuiltInProfiles` → `loadKeymap` → `startDetection`。
- 一般模式：啟動時看得到視窗、`policy=regular`，與現在相同。
- `MIRAGE_SPEECH`、`MIRAGE_REMOTE` 等環境變數行為不變。
- Swift Testing：Bool 用 `#expect(x)`／`#expect(!x)`，不可 `== true`／`== false`（`ci.sh` 閘門 5）；不可用 `guard … else { return }` 當 skip（閘門 3）。
- 測試行程裡 `NSApp` 是 nil，一律寫 `(NSApp as NSApplication?)?`。
- 建置加 `-j 2`（模擬器開著時記憶體不足會砍背景工作）。
- commit 訊息用繁體中文 conventional commits，結尾加 `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`。

## 檔案

| 檔案 | 動作 | 負責 |
| --- | --- | --- |
| `app/Sources/MirageShell/Lifecycle/MirrorWindowController.swift` | 新增 | 建立並持有唯一的鏡像視窗、設定委派 |
| `app/Tests/MirageShellTests/MirrorWindowControllerTests.swift` | 新增 | 上者的單元測試 |
| `app/Sources/MirageShell/MirrorRootView.swift` | 新增 | 原 `Window { }` 內的 SwiftUI 內容 |
| `app/Sources/MirageShell/AppModel+Window.swift` | 新增 | `launch()`、建立 `windowController`、顯示視窗 |
| `app/Sources/MirageShell/MirageScene.swift` | 修改 | 只剩 `Settings` 場景 |
| `app/Sources/MirageShell/AppDelegate.swift` | 修改 | 持有 `AppModel`、呼叫 `launch()` |
| `app/Sources/MirageShell/AppModel.swift` | 修改 | 移除 run loop 讓出與 `NSApp.windows.first` |
| `app/Sources/MirageShell/AppModel+Background.swift` | 修改 | 改用 `windowController`，移除提前隱藏 |

---

### Task 1: MirrorWindowController

**Files:**
- Create: `app/Sources/MirageShell/Lifecycle/MirrorWindowController.swift`
- Test: `app/Tests/MirageShellTests/MirrorWindowControllerTests.swift`

**Interfaces:**
- Consumes: 無
- Produces:
  - `@MainActor final class MirrorWindowController`
  - `static let defaultAutosaveName = "mirage-mirror"`
  - `static let minimumContentSize = NSSize(width: 270, height: 600)`
  - `init(autosaveName: String = MirrorWindowController.defaultAutosaveName, makeContentView: @escaping @MainActor () -> NSView)`
  - `var existingWindow: NSWindow? { get }`：尚未建立時為 nil，不會觸發建立
  - `func window() -> NSWindow`：第一次呼叫建立，之後回傳同一個
  - `func attach(delegate: NSWindowDelegate)`：建立前後呼叫都有效

- [ ] **Step 1: 寫失敗的測試**

autosave 名稱每個測試用不同值：同一個名稱被兩個活著的視窗使用時，`setFrameAutosaveName` 會回傳 false 且不生效。

```swift
import AppKit
import Foundation
import Testing
@testable import MirageShell

@MainActor
@Suite struct MirrorWindowControllerTests {
    private final class Delegate: NSObject, NSWindowDelegate {}

    private func makeController(contentBuilds: @escaping () -> Void = {}) -> MirrorWindowController {
        MirrorWindowController(autosaveName: "MirrorWindowControllerTests.\(UUID().uuidString)") {
            contentBuilds()
            return NSView()
        }
    }

    @Test func windowIsCreatedOnceAndOnlyWhenAsked() {
        var builds = 0
        let controller = makeController { builds += 1 }
        #expect(controller.existingWindow == nil)
        #expect(builds == 0)
        let first = controller.window()
        let second = controller.window()
        #expect(first === second)
        #expect(controller.existingWindow === first)
        #expect(builds == 1)
    }

    @Test func windowIsConfiguredForMirroring() {
        let name = "MirrorWindowControllerTests.\(UUID().uuidString)"
        let window = MirrorWindowController(autosaveName: name) { NSView() }.window()
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        #expect(window.frameAutosaveName == name)
        #expect(!window.isReleasedWhenClosed)
        #expect(window.title == "Mirage")
        #expect(window.contentMinSize == MirrorWindowController.minimumContentSize)
        #expect(window.styleMask.contains(.closable))
        #expect(window.styleMask.contains(.resizable))
    }

    @Test func delegateAttachedBeforeCreationIsApplied() {
        let controller = makeController()
        let delegate = Delegate()
        controller.attach(delegate: delegate)
        #expect(controller.existingWindow == nil)
        #expect(controller.window().delegate === delegate)
    }

    @Test func delegateAttachedAfterCreationIsApplied() {
        let controller = makeController()
        let window = controller.window()
        let delegate = Delegate()
        controller.attach(delegate: delegate)
        #expect(window.delegate === delegate)
    }
}
```

- [ ] **Step 2: 確認測試失敗**

Run: `cd app && swift build --build-tests -j 2 2>&1 | grep error: | head -3`
Expected: `cannot find 'MirrorWindowController' in scope`

- [ ] **Step 3: 實作**

```swift
import AppKit

/// 唯一的鏡像視窗（2026-09-17，規格 `docs/specs/2026-09-17-launch-without-window-design.md`）。
///
/// 原本是 SwiftUI `Window` 場景：SwiftUI 在啟動時一定建立並顯示它，之後才跑 `.task`，
/// 所以背景模式啟動時視窗會在畫面上停留 318 到 472 ms。改由這裡在第一次需要時建立。
///
/// D30 的「只能有一個鏡像視窗」改由這個型別保證：只有 `window()` 會建立 `NSWindow`，
/// 且只建立一次。`AppModel` 只有一份，重複建立視窗會讓同一份狀態被兩個畫面讀寫。
@MainActor
final class MirrorWindowController {
    static let defaultAutosaveName = "mirage-mirror"
    static let minimumContentSize = NSSize(width: 270, height: 600)
    /// 沒有存過位置時的初始大小，與 SwiftUI `Window` 時期實測的視窗一致。
    private static let initialContentSize = NSSize(width: 459, height: 992)

    private let autosaveName: String
    private let makeContentView: @MainActor () -> NSView
    private var created: NSWindow?
    private weak var delegate: NSWindowDelegate?

    init(autosaveName: String = MirrorWindowController.defaultAutosaveName,
         makeContentView: @escaping @MainActor () -> NSView) {
        self.autosaveName = autosaveName
        self.makeContentView = makeContentView
    }

    var existingWindow: NSWindow? { created }

    func window() -> NSWindow {
        if let created { return created }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Mirage"
        // 關視窗是隱藏（AppLifecycle.windowShouldClose 回傳 false），物件要留著。
        window.isReleasedWhenClosed = false
        window.contentView = makeContentView()
        window.contentMinSize = Self.minimumContentSize
        // SwiftUI 的 Window 會自動加；少了它無法全螢幕，gui_session.sh 的 AXFullScreen 會失敗。
        window.collectionBehavior.insert(.fullScreenPrimary)
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
        window.delegate = delegate
        created = window
        return window
    }

    /// `AppLifecycle` 在 `startLifecycle()` 才建立，一般模式的視窗比它早建立，所以兩種順序都要能設定。
    func attach(delegate: NSWindowDelegate) {
        self.delegate = delegate
        created?.delegate = delegate
    }
}
```

- [ ] **Step 4: 確認測試通過**

Run: `cd app && swift test -j 2 --filter MirrorWindowControllerTests 2>&1 | grep -E "✘|Test run"`
Expected: `Test run with 4 tests passed`

- [ ] **Step 5: 突變檢查**

把 `if let created { return created }` 改成註解，執行 Step 4 的指令，Expected: `windowIsCreatedOnceAndOnlyWhenAsked` 失敗。改回後再跑一次確認通過。

- [ ] **Step 6: Commit**

```bash
git add app/Sources/MirageShell/Lifecycle/MirrorWindowController.swift app/Tests/MirageShellTests/MirrorWindowControllerTests.swift
git commit -m "feat: MirrorWindowController 以 AppKit 建立唯一的鏡像視窗

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: 把視窗內容抽成 MirrorRootView（行為不變）

**Files:**
- Create: `app/Sources/MirageShell/MirrorRootView.swift`
- Modify: `app/Sources/MirageShell/MirageScene.swift:42-146`

**Interfaces:**
- Consumes: 無
- Produces: `struct MirrorRootView: View { let model: AppModel }`

這個 task 仍使用 SwiftUI `Window` 場景，只是把內容換成 `MirrorRootView(model: model)`，行為完全不變。拆成獨立 task 是為了讓搬移本身可以單獨審查。

- [ ] **Step 1: 建立 MirrorRootView.swift**

內容是把 `MirageScene.swift` 第 43 行 `ZStack(alignment: .top) {` 到第 111 行 `.frame(minWidth: 270, minHeight: 600)` 整段（含中間兩個 `.alert` 與所有註解）原封不動搬進 `body`，並把第 124 到 146 行的 `keymapOverlayLayer`（含上方註解）搬進來。兩段都直接引用 `model`，不需要改名。

```swift
import SwiftUI

/// 鏡像視窗的內容。原本寫在 `MirageScene` 的 `Window { }` 裡，2026-09-17 抽出來，
/// 讓 `MirrorWindowController` 可以放進 `NSHostingView`（規格
/// `docs/specs/2026-09-17-launch-without-window-design.md`）。內容沒有改。
struct MirrorRootView: View {
    let model: AppModel

    var body: some View {
        // ← MirageScene.swift:43-111 原文貼在這裡（ZStack 到 .frame(minWidth:minHeight:)）
    }

    // ← MirageScene.swift:124-146 原文貼在這裡（keymapOverlayLayer 與其註解）
}
```

上面兩行 `←` 是貼上位置的標記，貼完要刪掉。貼上後檢查：檔案裡沒有 `appDelegate`、`.task`。

- [ ] **Step 2: MirageScene 改用 MirrorRootView**

`MirageScene.swift` 的 `body` 改成下面這樣（D30 的註解保留在 `Window` 上方），並刪除第 124 到 146 行：

```swift
    var body: some Scene {
        // D30 註解（原第 26-41 行）保留不動
        Window("Mirage", id: "mirage-mirror") {
            MirrorRootView(model: model)
                .task {
                    appDelegate.model = model   // 供 applicationWillTerminate 使用
                    model.hideWindowEarlyForBackgroundMode()   // 在連線之前藏，縮短視窗露出的時間
                    await model.start()
                    model.startLifecycle()
                    model.seedBuiltInProfiles()   // 必須在 startDetection 之前：偵測命中就會讀那個目錄
                    model.loadKeymap()
                    model.startDetection()
                }
        }
    }
```

- [ ] **Step 3: 建置**

Run: `cd app && swift build -j 2 2>&1 | grep -E "error:|Build complete"`
Expected: `Build complete!`

- [ ] **Step 4: 確認沒有多搬或漏搬**

Run: `cd app && git diff --stat && grep -c "OverlayEditorView\|SpeechOverlay\|ConnectionBanner\|InstallBanner\|TextInputControls\|dropDestination\|有未存的鍵位變更\|鍵位設定無法存檔" Sources/MirageShell/MirrorRootView.swift Sources/MirageShell/MirageScene.swift`
Expected: `MirrorRootView.swift` 為 8 以上，`MirageScene.swift` 為 0。

- [ ] **Step 5: 實機確認一般模式畫面不變**

```bash
S=$(mktemp -d)
defaults write com.mirage.app mirage.launch.backgroundMode -bool false
scripts/package_app.sh "$S" | tail -1
open -n --stdout "$S/out.log" --stderr "$S/out.log" "$S/Mirage.app"; sleep 8
screencapture -x "$S/shot.png"; grep -E "\[remote\]|error" "$S/out.log"
```

用 Read 看 `$S/shot.png`：Mirage 視窗顯示模擬器畫面。看完結束 Mirage：`osascript -e 'tell application id "com.mirage.app" to quit'`。

- [ ] **Step 6: Commit**

```bash
git add app/Sources/MirageShell/MirrorRootView.swift app/Sources/MirageShell/MirageScene.swift
git commit -m "refactor: 鏡像視窗內容抽成 MirrorRootView，行為不變

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: 啟動流程移到 AppDelegate，視窗改由 MirrorWindowController 建立

**Files:**
- Create: `app/Sources/MirageShell/AppModel+Window.swift`
- Modify: `app/Sources/MirageShell/MirageScene.swift`（body 與 `@State model`）
- Modify: `app/Sources/MirageShell/AppDelegate.swift`（`applicationWillFinishLaunching`、新增 `applicationDidFinishLaunching`、`applicationWillTerminate` 診斷）
- Modify: `app/Sources/MirageShell/AppModel.swift:209-260`（`startLifecycle`）、`:277-280`（`wake`）、init
- Modify: `app/Sources/MirageShell/AppModel+Background.swift`

**Interfaces:**
- Consumes: Task 1 的 `MirrorWindowController(makeContentView:)`、`window()`、`existingWindow`、`attach(delegate:)`；Task 2 的 `MirrorRootView(model:)`
- Produces:
  - `AppModel.windowController: MirrorWindowController!`（`@ObservationIgnored`，init 最後設定）
  - `AppModel.launch() async`
  - `AppModel.applyBackgroundModeAfterStart()`（不再帶參數）

- [ ] **Step 1: 新增 AppModel+Window.swift**

```swift
import AppKit
import SwiftUI

/// 啟動流程與鏡像視窗（2026-09-17，規格 `docs/specs/2026-09-17-launch-without-window-design.md`）。
///
/// 原本整段啟動流程寫在 SwiftUI `Window` 的 `.task` 裡，視窗一定先顯示才開始啟動，
/// 背景模式因此會閃一下。現在由 `AppDelegate.applicationDidFinishLaunching` 呼叫 `launch()`，
/// 視窗只在需要時由 `windowController` 建立。
extension AppModel {
    static func makeWindowController(for model: AppModel) -> MirrorWindowController {
        MirrorWindowController { [weak model] in
            guard let model else { return NSView() }
            return NSHostingView(rootView: MirrorRootView(model: model))
        }
    }

    /// 順序與原本的 `.task` 相同，不要調換：`seedBuiltInProfiles` 必須在 `startDetection` 之前，
    /// 偵測命中就會讀那個目錄。
    func launch() async {
        if !launchPreferences.backgroundMode {
            windowController.window().makeKeyAndOrderFront(nil)
            (NSApp as NSApplication?)?.activate(ignoringOtherApps: true)
        }
        await start()
        startLifecycle()
        seedBuiltInProfiles()
        loadKeymap()
        startDetection()
    }
}
```

- [ ] **Step 2: AppModel 建立 windowController**

`AppModel.swift` 在 `let launchPreferences: LaunchPreferences` 下一行加：

```swift
    /// 鏡像視窗。init 最後才能設定（需要 self），所以是 IUO；建立它不會建立視窗。
    @ObservationIgnored var windowController: MirrorWindowController!
```

init 最後一行（`if ProcessInfo...MIRAGE_CONN_LOG` 區塊之後）加：

```swift
        windowController = Self.makeWindowController(for: self)
```

- [ ] **Step 3: startLifecycle 移除 run loop 讓出**

`AppModel.swift` 的 `startLifecycle()`：在建立 `lifecycle = AppLifecycle(...)` 的敘述之後加一行

```swift
        if let lifecycle { windowController.attach(delegate: lifecycle) }
```

並把函式結尾「視窗關閉→休眠、喚醒→load 交由 AppLifecycle 當 NSWindowDelegate」註解與其下整個 `Task { [weak self] in await MainActor.run { ... } }` 區塊（原第 244-259 行）換成：

```swift
        // 背景模式的休眠或叫回視窗要用到 AppLifecycle，所以放在它建立之後。
        applyBackgroundModeAfterStart()
```

- [ ] **Step 4: wake 改用 windowController**

`AppModel.swift` 的 `wake()` 改成：

```swift
    private func wake() {
        lifecycle?.wake(showing: windowController.window())
    }
```

- [ ] **Step 5: AppModel+Background 改寫**

刪除 `hideWindowEarlyForBackgroundMode()` 整個函式與它的文件註解，`applyBackgroundModeAfterStart` 改成：

```swift
    /// `startLifecycle()` 最後呼叫。背景模式沒有建立視窗，這裡決定要休眠還是把視窗叫出來。
    func applyBackgroundModeAfterStart() {
        switch LaunchPreferences.windowStepAfterStart(backgroundMode: launchPreferences.backgroundMode,
                                                      remoteStarted: remote != nil) {
        case .keep:
            return
        case .suspendHidden:
            // 與按紅色按鈕相同的狀態：手機還沒連上就休眠，連上後由 remoteViewerConnected 喚醒。
            lifecycle?.didHideWindow()
            print("[app] 背景模式：未建立視窗，手機遙控已開啟")
        case .reshow:
            lifecycle?.wake(showing: windowController.window())
            print("[app] 背景模式：手機遙控沒有開起來，改為顯示視窗")
        }
    }
```

檔案開頭的型別註解中「這裡負責選單項與啟動時的視窗處理」維持不變。

- [ ] **Step 6: MirageScene 只留 Settings**

`MirageScene.swift` 整個 `struct MirageScene` 改成下面這樣（`init()` 的 setvbuf 與其註解、`@NSApplicationDelegateAdaptor` 與其註解保留；刪除 `@State private var model`、`Window` 與 D30 註解，D30 的說明已寫在 `MirrorWindowController`）：

```swift
struct MirageScene: App {
    // AUTHORIZED ADDITION（Task 4 review: NIO teardown race）— see AppDelegate.swift.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // （原 init 與 setvbuf 註解保留不動）
    init() {
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    /// 鏡像視窗改由 `MirrorWindowController`（AppKit）建立，這裡只留空的 `Settings` 場景，
    /// 讓 SwiftUI 繼續提供主選單（⌘Q、編輯選單）。「設定…」項目沒有內容，拿掉。
    var body: some Scene {
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}
```

- [ ] **Step 7: AppDelegate 持有並啟動 AppModel**

`AppDelegate.swift` 的 `applicationWillFinishLaunching` 改成：

```swift
    /// AppModel 在這裡建立：SwiftUI 不再有持有它的場景。背景模式在最早的時間點換成 accessory，
    /// Dock 圖示從頭就不出現。
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if model == nil { model = AppModel() }
            guard LaunchPreferences().backgroundMode else { return }
            (NSApp as NSApplication?)?.setActivationPolicy(LaunchPreferences.launchActivationPolicy(backgroundMode: true))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard let model else { return }
            Task { @MainActor in await model.launch() }
        }
    }
```

`applicationWillTerminate` 的診斷迴圈不需要改（它列出 `NSApp.windows` 全部，不假設第一個是鏡像視窗）。

- [ ] **Step 8: 建置並跑相關測試**

Run: `cd app && swift build --build-tests -j 2 2>&1 | grep -E "error:|Build complete" ; swift test -j 2 --filter "MirrorWindowControllerTests|LaunchPreferencesTests|LifecyclePolicyTests|AppModel" 2>&1 | grep -E "✘|Test run"`
Expected: `Build complete!`，測試全部通過。

- [ ] **Step 9: 確認沒有殘留**

Run: `cd app && git grep -n "windows.first\|hideWindowEarlyForBackgroundMode\|Window(\"Mirage\"" -- Sources`
Expected: 沒有輸出。

- [ ] **Step 10: Commit**

```bash
git add app/Sources/MirageShell/AppModel+Window.swift app/Sources/MirageShell/MirageScene.swift app/Sources/MirageShell/AppDelegate.swift app/Sources/MirageShell/AppModel.swift app/Sources/MirageShell/AppModel+Background.swift
git commit -m "feat: 啟動流程移到 AppDelegate，背景模式不建立鏡像視窗

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: 實機驗證與 CI

**Files:** 不修改 repo 檔案。取樣工具放在暫存目錄。

**Interfaces:**
- Consumes: Task 3 完成後的 app
- Produces: 驗證結果（貼在最後回報裡）

前置：模擬器開著（`app/scripts/emu.sh status` 顯示開機完成），螢幕沒有鎖定。

- [ ] **Step 1: 建立 20 ms 取樣工具**

```bash
P=$(mktemp -d); cat > "$P/main.swift" <<'EOF'
import AppKit
import CoreGraphics
// 每 20ms 取樣 MirageApp 在畫面上的一般層級視窗數與 activationPolicy，只在變化時印一行。
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "12") ?? 12
let start = Date()
var last = ""
while Date().timeIntervalSince(start) < seconds {
    var line = "no-process"
    if let app = NSWorkspace.shared.runningApplications.first(where: { $0.executableURL?.lastPathComponent == "MirageApp" }) {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let count = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }.count
        let policy = ["regular", "accessory", "prohibited"][app.activationPolicy.rawValue]
        line = "policy=\(policy) onscreenWindows=\(count)"
    }
    if line != last { print(String(format: "t=%.3f ", Date().timeIntervalSince(start)) + line); fflush(stdout); last = line }
    // runningApplications 靠 run loop 更新，不能用 usleep。
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
}
EOF
swiftc -O "$P/main.swift" -o "$P/winprobe" && echo "PROBE=$P/winprobe"
```

- [ ] **Step 2: 背景模式啟動（兩次）**

```bash
S=$(mktemp -d); cd app && scripts/package_app.sh "$S" | tail -1
defaults write com.mirage.app mirage.launch.backgroundMode -bool true
for r in 1 2; do
  osascript -e 'tell application id "com.mirage.app" to quit' 2>/dev/null; sleep 3
  "$PROBE" 12 > "$S/probe$r.out" & PR=$!
  sleep 0.3; open -n --stdout "$S/out$r.log" --stderr "$S/out$r.log" "$S/Mirage.app"; wait $PR
  echo "=== 第 $r 次"; cat "$S/probe$r.out"; grep "背景模式" "$S/out$r.log"
done
```

Expected: 兩次都沒有任何一行 `onscreenWindows=1`，最後是 `policy=accessory onscreenWindows=0`，日誌有「背景模式：未建立視窗，手機遙控已開啟」。

- [ ] **Step 3: 顯示、關閉、手機連線**

```bash
NP=$(pgrep -f Contents/MacOS/MirageApp)
osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$NP"') to perform action "AXPress" of menu item "顯示視窗" of menu 1 of menu bar item 1 of menu bar 2'; sleep 1.5
"$PROBE" 0.3 | tail -1; osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$NP"') to get frontmost'
osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$NP"') to click (first button of window 1 whose subrole is "AXCloseButton")'; sleep 1.5
"$PROBE" 0.3 | tail -1
bash -c 'source scripts/lib/remote_venv.sh && PY=$(remote_venv_python) && "$PY" scripts/lib/remote_client.py --host 127.0.0.1 --port 8765 --token "$(defaults read com.mirage.app mirage.remote.pairingToken)" --wait-keyframe 30 --seconds 5' 2>&1 | grep -E "KEYFRAME_SECONDS|^FRAMES|SEQ_GAPS|emulatorConnected\":true" | head -4
```

Expected：顯示後 `policy=regular onscreenWindows=1`、frontmost 為 true；關閉後 `policy=accessory onscreenWindows=0`；手機端有 `KEYFRAME_SECONDS`、`SEQ_GAPS=0`、`"emulatorConnected":true`。

- [ ] **Step 4: 8765 埠被佔用**

```bash
osascript -e 'tell application id "com.mirage.app" to quit'; sleep 3
python3 -c 'import socket,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("0.0.0.0",8765)); s.listen(); time.sleep(25)' & OCC=$!; sleep 1
"$PROBE" 10 > "$S/probe-occ.out" & PR=$!; sleep 0.3
open -n --stdout "$S/occ.log" --stderr "$S/occ.log" "$S/Mirage.app"; wait $PR; kill $OCC
tail -1 "$S/probe-occ.out"; grep "背景模式" "$S/occ.log"
```

Expected: 最後一行 `policy=regular onscreenWindows=1`，日誌有「手機遙控沒有開起來，改為顯示視窗」。

- [ ] **Step 5: 一般模式、⌘E、按鍵、主選單**

```bash
osascript -e 'tell application id "com.mirage.app" to quit'; sleep 3
defaults write com.mirage.app mirage.launch.backgroundMode -bool false
"$PROBE" 10 > "$S/probe-normal.out" & PR=$!; sleep 0.3
open -n --stdout "$S/normal.log" --stderr "$S/normal.log" "$S/Mirage.app"; wait $PR
tail -1 "$S/probe-normal.out"
NP=$(pgrep -f Contents/MacOS/MirageApp)
osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$NP"') to get name of every menu bar item of menu bar 1'
osascript -e 'tell application "System Events" to set frontmost of (first process whose unix id is '"$NP"') to true'; sleep 1
ADB=~/Library/Android/sdk/platform-tools/adb
$ADB -s emulator-5554 shell getevent -l > "$S/getevent.log" 2>&1 < /dev/null & GE=$!; sleep 1
osascript -l JavaScript scripts/lib/cgkey.js 0 0; sleep 1   # 虛擬鍵碼 0 = A，不帶修飾鍵
kill $GE; grep -c "KEY_A" "$S/getevent.log"
osascript -l JavaScript scripts/lib/cgkey.js 14 1048576; sleep 1   # ⌘E
screencapture -x "$S/edit.png"
osascript -l JavaScript scripts/lib/cgkey.js 14 1048576   # 再按一次離開編輯模式
```

Expected：`policy=regular onscreenWindows=1`；主選單列出 `MirageApp` 與編輯等項目（記下來，與 Task 2 的版本比對，差異寫進回報）；`KEY_A` 次數大於 0；`edit.png` 顯示編輯器（用 Read 檢查）。若當前 app 沒有 keymap profile，⌘E 不會進編輯模式，這時改看日誌或畫面是否有編輯提示，並在回報中註明。

- [ ] **Step 6: 全螢幕**

```bash
osascript -e 'tell application "System Events" to tell process "MirageApp" to set value of attribute "AXFullScreen" of window 1 to true'; sleep 3
osascript -e 'tell application "System Events" to tell process "MirageApp" to get value of attribute "AXFullScreen" of window 1'
osascript -e 'tell application "System Events" to tell process "MirageApp" to set value of attribute "AXFullScreen" of window 1 to false'; sleep 3
```

Expected: 讀回 `true`。

- [ ] **Step 7: 腳本與 CI**

Run: `cd app && scripts/verify_remote_mirror.sh 2>&1 | tail -5; scripts/ci.sh > "$S/ci.log" 2>&1; echo "ci exit=$?"; tail -2 "$S/ci.log"`
Expected: `verify_remote_mirror.sh` 通過，`ci exit=0`。

- [ ] **Step 8: 還原使用者設定**

```bash
defaults write com.mirage.app mirage.launch.backgroundMode -bool true
osascript -e 'tell application id "com.mirage.app" to quit'
```

使用者的設定是背景模式開啟，驗證完要改回來。
