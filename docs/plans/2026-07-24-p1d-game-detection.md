# P1-d 遊戲偵測與 keymap 啟用 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 依 `docs/specs/2026-07-24-p1d-game-detection-design.md`，把 P1-c 的休眠預設 keymap 升級為自動生效——偵測前景遊戲 package → 載對應 profile → keymap 引擎接管；無 profile 退回 P1-a tap。並吸收 P1-c 交接的 MouseCapture 游標陷阱修與 app-path 活體驗（誠實切分）。

**Architecture:** 純決策與 App 膠水嚴格分離。MirageCore 新增 `Keymap/ForegroundParser`（dumpsys→package 純解析）、`Keymap/ActivationDecider`（偵測+profile+手動鎖定→啟用決策 純 reducer）。MirageApp 新增 `Detect/AdbClient`（adb 子行程薄封裝）、`Detect/GameDetector`（@MainActor 輪詢），並在 AppModel 接線、MenuBarController 加覆蓋、MouseCapture 加焦點 gating。

**Tech Stack:** Swift 6（語言模式 v5）、grpc-swift exact 1.27.5、swift-testing、AppKit（NSStatusItem/NSWindow 通知）、Foundation `Process`（adb）。**零 proto 遷移**（偵測走 adb，非 gRPC）。

## Global Constraints

- 平台 macOS 14+ Apple Silicon；`swift build -c release` 零非-deprecation 警告。
- **MirageCore 不得 import AppKit/SwiftUI/Metal**；不 `fatalError`；錯誤回傳/記錄，App 層決定呈現。
- 所有 target 開 `-strict-concurrency=complete`；`.swiftLanguageMode(.v5)`。
- 測試語法用 swift-testing（`@Suite struct`/`@Test func`/`#expect`）；每檔 <400 行、函式 <50 行；純邏輯與 UI 膠水嚴格分離；不可變優先。
- TDD：先寫失敗測試 → 確認失敗 → 最小實作 → 綠 → commit。Conventional commits、無 attribution。
- MirageCore 覆蓋 ≥80%；既有測試（合併後 79 個）不回歸。
- 活體測試預設 skip、`MIRAGE_LIVE` 開啟；adb 一律 `ANDROID_SERIAL=emulator-5554`（避開實體手機）。
- **不新建 MirageApp 測試 target**：可測邏輯（ForegroundParser/ActivationDecider）皆 MirageCore 純型別，於 `MirageCoreTests` 測；App 層 GameDetector/AdbClient/選單列/MouseCapture 為薄膠水，正確性靠 Core 決策覆蓋 + 活體 + pending-human。

## 既有介面契約（P1-c 已交付，本件依賴）

- `KeymapProfile`（`Sendable, Codable, Equatable`；`gameId/version/bindings`）、`ProfileStore.standard() -> ProfileStore`、`ProfileStore.load(gameId:) throws -> KeymapProfile`（`StoreError.notFound`/`.corrupted`/`ProfileError`）。
- `KeymapController`（`@MainActor`）：`var hasProfile: Bool`、`func reload(_ profile: KeymapProfile?)`（本件確認 `reload(nil)` = deactivate；若 P1-c 尚無此簽名，Task 5 補）、`frameSizeProvider`。
- `MenuBarController`（`@MainActor`，P1-b）：`NSStatusItem` + `updateStatus(_:)`；`AppModel`（`@MainActor @Observable`，持 `client/keymap/profile/editing/menuBar` 等）。
- `MouseCapture`（`@MainActor`，P1-c）：`capture()`/`release()`/`captured`/`deinit` 還原。

---

### Task 1: ForegroundParser（MirageCore 純解析，TDD）

**Files:**
- Create: `app/Sources/MirageCore/Keymap/ForegroundParser.swift`
- Test: `app/Tests/MirageCoreTests/ForegroundParserTests.swift`

**Interfaces:**
- Consumes: 無。
- Produces: `enum ForegroundParser { static func foregroundPackage(fromDumpsys output: String) -> String? }`——供 Task 4 `GameDetector` 解析、Task 5 啟用協調取 gameId。

- [ ] **Step 1: 失敗測試**

```swift
// app/Tests/MirageCoreTests/ForegroundParserTests.swift
import Testing
@testable import MirageCore

@Suite struct ForegroundParserTests {
    @Test func parsesTopResumedActivity() {
        let out = """
            mResumedActivity: ActivityRecord{a u0 com.example.game/.MainActivity t9}
            topResumedActivity=ActivityRecord{b u0 com.example.game/.MainActivity t9}
            """
        #expect(ForegroundParser.foregroundPackage(fromDumpsys: out) == "com.example.game")
    }

    @Test func parsesLauncherPackage() {
        let out = "  topResumedActivity=ActivityRecord{39cc710 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t16}"
        #expect(ForegroundParser.foregroundPackage(fromDumpsys: out) == "com.android.launcher3")
    }

    @Test func emptyOutputIsNil() {
        #expect(ForegroundParser.foregroundPackage(fromDumpsys: "") == nil)
    }

    @Test func noResumedActivityIsNil() {
        #expect(ForegroundParser.foregroundPackage(fromDumpsys: "Foo: bar\nBaz: qux") == nil)
    }

    @Test func resumedLineWithoutPackageIsNil() {
        #expect(ForegroundParser.foregroundPackage(fromDumpsys: "ResumedActivity: <null>") == nil)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter ForegroundParserTests 2>&1 | tail -3`
Expected: 編譯失敗（`ForegroundParser` 不存在）。

- [ ] **Step 3: 實作**

```swift
// app/Sources/MirageCore/Keymap/ForegroundParser.swift
import Foundation

/// 從 `adb shell dumpsys activity activities` 輸出解析前景 package。
/// 取第一個含 "ResumedActivity" 的行內 `<pkg>/<activity>` token 的 package 段。
public enum ForegroundParser {
    public static func foregroundPackage(fromDumpsys output: String) -> String? {
        for rawLine in output.split(separator: "\n") {
            guard rawLine.contains("ResumedActivity") else { continue }
            if let pkg = package(inLine: String(rawLine)) { return pkg }
        }
        return nil
    }

    /// 從一行抽 `pkg/.activity` 的 package：以空白/大括號切 token，取第一個含 "/" 且 "/" 前含 "." 的。
    private static func package(inLine line: String) -> String? {
        for token in line.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "}" }) {
            guard let slash = token.firstIndex(of: "/") else { continue }
            let pkg = String(token[token.startIndex..<slash])
            if pkg.contains("."), !pkg.hasPrefix("/") { return pkg }
        }
        return nil
    }
}
```

- [ ] **Step 4: 測試通過**

Run: `cd app && swift test --filter ForegroundParserTests 2>&1 | tail -3`
Expected: 5 tests passed。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Keymap/ForegroundParser.swift app/Tests/MirageCoreTests/ForegroundParserTests.swift
git commit -m "feat: ForegroundParser dumpsys 前景 package 解析（TDD）"
```

---

### Task 2: ActivationDecider（MirageCore 純 reducer，TDD）

**Files:**
- Create: `app/Sources/MirageCore/Keymap/ActivationDecider.swift`
- Test: `app/Tests/MirageCoreTests/ActivationDeciderTests.swift`

**Interfaces:**
- Consumes: Task（P1-c）`KeymapProfile`。
- Produces:
  - `enum ManualOverride: Equatable, Sendable { case auto, force(KeymapProfile), disabled }`
  - `enum Activation: Equatable, Sendable { case active(KeymapProfile), inactive }`
  - `enum ActivationDecider { static func decide(loadedProfile: KeymapProfile?, override: ManualOverride) -> Activation }`
  - 供 Task 5 啟用協調：App 載 profile（I/O）後以此決策 active/inactive。

- [ ] **Step 1: 失敗測試**

```swift
// app/Tests/MirageCoreTests/ActivationDeciderTests.swift
import Testing
@testable import MirageCore

@Suite struct ActivationDeciderTests {
    private func profile(_ id: String) -> KeymapProfile {
        KeymapProfile(gameId: id, version: 1, bindings: [.tap(key: .key("j"), at: NormPoint(x: 0.5, y: 0.5))])
    }

    @Test func autoWithProfileActivates() {
        let p = profile("g")
        #expect(ActivationDecider.decide(loadedProfile: p, override: .auto) == .active(p))
    }

    @Test func autoWithoutProfileInactive() {
        #expect(ActivationDecider.decide(loadedProfile: nil, override: .auto) == .inactive)
    }

    @Test func forceOverridesDetection() {
        let forced = profile("forced")
        // 即使無偵測 profile，force 仍啟用被強制者
        #expect(ActivationDecider.decide(loadedProfile: nil, override: .force(forced)) == .active(forced))
    }

    @Test func disabledIsInactiveEvenWithProfile() {
        #expect(ActivationDecider.decide(loadedProfile: profile("g"), override: .disabled) == .inactive)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter ActivationDeciderTests 2>&1 | tail -3`
Expected: 編譯失敗（`ActivationDecider`/`ManualOverride`/`Activation` 不存在）。

- [ ] **Step 3: 實作**

```swift
// app/Sources/MirageCore/Keymap/ActivationDecider.swift
import Foundation

/// 手動覆蓋狀態：auto=跟隨偵測；force=強制某 profile；disabled=停用 keymap。
public enum ManualOverride: Equatable, Sendable {
    case auto
    case force(KeymapProfile)
    case disabled
}

/// keymap 啟用結果。
public enum Activation: Equatable, Sendable {
    case active(KeymapProfile)
    case inactive
}

/// 純決策：把「該不該啟用、用哪個 profile」與 I/O 分離。App 先對偵測到的 package
/// 做 ProfileStore.load（I/O），把結果與手動覆蓋餵進來。
public enum ActivationDecider {
    public static func decide(loadedProfile: KeymapProfile?, override: ManualOverride) -> Activation {
        switch override {
        case .force(let p): return .active(p)
        case .disabled:     return .inactive
        case .auto:         return loadedProfile.map { .active($0) } ?? .inactive
        }
    }
}
```

- [ ] **Step 4: 測試通過**

Run: `cd app && swift test --filter ActivationDeciderTests 2>&1 | tail -3`
Expected: 4 tests passed。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Keymap/ActivationDecider.swift app/Tests/MirageCoreTests/ActivationDeciderTests.swift
git commit -m "feat: ActivationDecider 啟用決策純 reducer（TDD）"
```

---

### Task 3: AdbClient（App，adb 子行程薄封裝 + 降級注入測試）

**背景**：偵測走 adb（gRPC 無前景-app RPC）。`AdbClient` 封裝 `adb -s <serial> shell dumpsys activity activities`，逾時/失敗降級回 nil。用可注入的 runner closure 讓「降級」邏輯可測，不需真 adb。

**Files:**
- Create: `app/Sources/MirageApp/Detect/AdbClient.swift`
- Test: `app/Tests/MirageCoreTests/AdbClientLogicTests.swift`（測純降級邏輯——見下方為何可放 MirageCoreTests：把 runner 抽象放 App，但降級判斷用注入假 runner；此測試 import MirageApp 不可行→改測 App 內 struct 需 App target。**採替代**：降級判斷抽為 MirageCore 純函式 `AdbOutcome`。見 Interfaces。）

**Interfaces:**
- Produces（MirageCore 純）：`enum AdbOutcome { static func packageOrNil(exitCode: Int32, stdout: String) -> String? }`——`exitCode == 0` 且 `ForegroundParser` 解析成功才回 package，否則 nil（降級）。供 Task 4 與單元測試共用。
- Produces（App）：`struct AdbClient { init(adbPath: URL, serial: String); func dumpsysForegroundPackage(timeout: Duration) async -> String? }`——執行 adb、套 `AdbOutcome`。

- [ ] **Step 1: 失敗測試（MirageCore `AdbOutcome` 純降級邏輯）**

```swift
// app/Tests/MirageCoreTests/AdbOutcomeTests.swift
import Testing
@testable import MirageCore

@Suite struct AdbOutcomeTests {
    @Test func zeroExitWithForegroundReturnsPackage() {
        let out = "topResumedActivity=ActivityRecord{a u0 com.example.game/.M t1}"
        #expect(AdbOutcome.packageOrNil(exitCode: 0, stdout: out) == "com.example.game")
    }
    @Test func nonZeroExitDegradesToNil() {
        let out = "topResumedActivity=ActivityRecord{a u0 com.example.game/.M t1}"
        #expect(AdbOutcome.packageOrNil(exitCode: 1, stdout: out) == nil)   // adb 失敗→降級
    }
    @Test func zeroExitNoForegroundIsNil() {
        #expect(AdbOutcome.packageOrNil(exitCode: 0, stdout: "nothing") == nil)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter AdbOutcomeTests 2>&1 | tail -3`
Expected: 編譯失敗（`AdbOutcome` 不存在）。

- [ ] **Step 3: 實作 `AdbOutcome`（MirageCore）+ `AdbClient`（App）**

```swift
// app/Sources/MirageCore/Keymap/AdbOutcome.swift
import Foundation

/// adb 執行結果 → 前景 package 的純降級判斷（exitCode 非 0 或無前景 → nil）。
public enum AdbOutcome {
    public static func packageOrNil(exitCode: Int32, stdout: String) -> String? {
        guard exitCode == 0 else { return nil }
        return ForegroundParser.foregroundPackage(fromDumpsys: stdout)
    }
}
```

```swift
// app/Sources/MirageApp/Detect/AdbClient.swift
import Foundation
import MirageCore

/// adb 子行程薄封裝：跑 `adb -s <serial> shell dumpsys activity activities`，
/// 逾時/失敗降級回 nil（AdbOutcome）。非 @MainActor——純執行。
struct AdbClient: Sendable {
    let adbPath: URL
    let serial: String

    /// 由 ANDROID_SDK_ROOT/ANDROID_HOME 推導 adb；serial 預設 emulator-5554。
    static func standard(serial: String = "emulator-5554") -> AdbClient? {
        let env = ProcessInfo.processInfo.environment
        let sdk = env["ANDROID_SDK_ROOT"] ?? env["ANDROID_HOME"]
            ?? (NSHomeDirectory() + "/Library/Android/sdk")
        let adb = URL(fileURLWithPath: sdk).appendingPathComponent("platform-tools/adb")
        guard FileManager.default.isExecutableFile(atPath: adb.path) else { return nil }
        return AdbClient(adbPath: adb, serial: serial)
    }

    /// 回前景 package 或 nil（降級）。逾時內未完成 → 殺行程回 nil。
    func dumpsysForegroundPackage(timeout: Duration = .seconds(2)) async -> String? {
        await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = adbPath
            proc.arguments = ["-s", serial, "shell", "dumpsys", "activity", "activities"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            let box = OutcomeBox(cont: cont)
            let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() }; box.finish(nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.seconds, execute: watchdog)
            proc.terminationHandler = { p in
                watchdog.cancel()
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                let out = String(data: data ?? Data(), encoding: .utf8) ?? ""
                box.finish(AdbOutcome.packageOrNil(exitCode: p.terminationStatus, stdout: out))
            }
            do { try proc.run() } catch { watchdog.cancel(); box.finish(nil) }
        }
    }
}

/// 確保 continuation 只 resume 一次（逾時 vs 正常結束競態）。
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let cont: CheckedContinuation<String?, Never>
    init(cont: CheckedContinuation<String?, Never>) { self.cont = cont }
    func finish(_ v: String?) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }; done = true; cont.resume(returning: v)
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
```

- [ ] **Step 4: 測試通過**

Run: `cd app && swift test --filter AdbOutcomeTests 2>&1 | tail -3`
Expected: 3 tests passed。`swift build 2>&1 | tail -2` Build complete（AdbClient 編譯）。

- [ ] **Step 5: 活體冒煙（可選，模擬器執行中）**

```bash
cd app && ANDROID_SERIAL=emulator-5554 "$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5554 shell dumpsys activity activities | grep -m1 ResumedActivity
```
Expected: 見 `ResumedActivity: ActivityRecord{... <pkg>/...}`（確認 adb 路徑與解析對得上）。

- [ ] **Step 6: Commit**

```bash
git add app/Sources/MirageCore/Keymap/AdbOutcome.swift app/Sources/MirageApp/Detect/AdbClient.swift app/Tests/MirageCoreTests/AdbOutcomeTests.swift
git commit -m "feat: AdbClient dumpsys 前景 package 取得與降級（TDD+活體）"
```

---

### Task 4: GameDetector（App @MainActor 輪詢）

**背景**：仿 P1-b `ClipboardWatcher` 的 Timer 輪詢。每 tick 取前景 package，**變動才**回呼。薄膠水——變動偵測邏輯簡單，正確性靠 Task 5 啟用協調的 Core 決策覆蓋 + 活體。

**Files:**
- Create: `app/Sources/MirageApp/Detect/GameDetector.swift`

**Interfaces:**
- Consumes: Task 3 `AdbClient`。
- Produces: `@MainActor final class GameDetector`——`init(adb: AdbClient, interval: Duration, onChange: @escaping (String?) -> Void)`、`start()`、`stop()`。package（含 nil）變動才 `onChange`。供 Task 5 AppModel 驅動。

- [ ] **Step 1: 實作（無單元測試——Timer+adb 屬活體/膠水；變動語意由 Task 5 Core 決策覆蓋）**

```swift
// app/Sources/MirageApp/Detect/GameDetector.swift
import AppKit

/// 前景遊戲偵測：Timer 輪詢 adb，package 變動時回呼（nil=無前景/adb 失敗）。
@MainActor
final class GameDetector {
    private let adb: AdbClient
    private let interval: TimeInterval
    private let onChange: (String?) -> Void
    private var timer: Timer?
    private var last: String??            // 尚未偵測=nil；已偵測=Optional(package/nil)
    private var polling = false

    init(adb: AdbClient, interval: Duration = .milliseconds(1500),
         onChange: @escaping (String?) -> Void) {
        self.adb = adb
        self.interval = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        self.onChange = onChange
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = interval * 0.3
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard !polling else { return }    // 上一輪未回，跳過（adb 慢時不堆疊）
        polling = true
        let adb = self.adb
        Task { @MainActor [weak self] in
            let pkg = await adb.dumpsysForegroundPackage()
            defer { self?.polling = false }
            guard let self else { return }
            if self.last == nil || self.last! != pkg {   // 首次或變動
                self.last = pkg
                self.onChange(pkg)
            }
        }
    }
}
```

- [ ] **Step 2: 建置驗證**

Run: `cd app && swift build 2>&1 | tail -2`
Expected: Build complete、零新警告（`MainActor.assumeIsolated` Timer 樣式同 P1-b `ClipboardWatcher`）。

- [ ] **Step 3: Commit**

```bash
git add app/Sources/MirageApp/Detect/GameDetector.swift
git commit -m "feat: GameDetector 前景遊戲輪詢偵測（App 膠水）"
```

---

### Task 5: AppModel 啟用接線（App，GameDetector→載 profile→ActivationDecider→KeymapController）

**背景**：把偵測接到啟用。**先讀** `app/Sources/MirageApp/MirageApp.swift` 現況（P1-b lifecycle + P1-c keymap 成員），additive 加入，不動既有。若 `KeymapController` 尚無 `reload(_:)`，先加（P1-c report 有提及；確認簽名 `func reload(_ profile: KeymapProfile?)`：`profile==nil` 時清 engine → `hasProfile==false`）。

**Files:**
- Modify: `app/Sources/MirageApp/MirageApp.swift`（AppModel 加偵測/覆蓋成員 + 接線）
- Modify: `app/Sources/MirageApp/Keymap/KeymapController.swift`（確認/補 `reload(_:)`）

**Interfaces:**
- Consumes: Task 3 `AdbClient`、Task 4 `GameDetector`、Task 2 `ActivationDecider`/`ManualOverride`/`Activation`、`ProfileStore`（P1-c）、`KeymapController`（P1-c）。
- Produces: `AppModel.startDetection()`、`AppModel.setOverride(_ ManualOverride)`（Task 6 選單列用）、`AppModel.currentPackage: String?`、`AppModel.override: ManualOverride`。

- [ ] **Step 1: 確認/補 `KeymapController.reload`**

讀 `KeymapController.swift`。若無 `reload`，加：

```swift
// KeymapController.swift 增補（若 P1-c 已有則跳過）
func reload(_ profile: KeymapProfile?) {
    engine = profile.map { KeymapEngine(profile: $0) }   // nil → 清空 → hasProfile==false
}
```

- [ ] **Step 2: AppModel 接偵測（讀現況後 additive）**

```swift
// AppModel 增補（節錄；成員與現有 P1-b/P1-c 成員並列，不動既有）：
//   private var detector: GameDetector?
//   private(set) var currentPackage: String?
//   private(set) var override: ManualOverride = .auto
//   private let store = ProfileStore.standard()

func startDetection() {
    guard let adb = AdbClient.standard() else { return }   // 無 adb → 靜默不偵測（保守）
    detector = GameDetector(adb: adb) { [weak self] pkg in
        self?.onForeground(pkg)
    }
    detector?.start()
}

private func onForeground(_ pkg: String?) {
    currentPackage = pkg
    applyActivation()
}

func setOverride(_ o: ManualOverride) { override = o; applyActivation() }

private func applyActivation() {
    let loaded: KeymapProfile? = currentPackage.flatMap { try? store.load(gameId: $0) }
    switch ActivationDecider.decide(loadedProfile: loaded, override: override) {
    case .active(let p): keymap?.reload(p)
    case .inactive:      keymap?.reload(nil)
    }
    menuBar?.updateGame(package: currentPackage, active: keymap?.hasProfile == true)  // Task 6
}
```

`MirageApp.body` 的 `.task` 於 `startLifecycle()`（P1-b）後加 `model.startDetection()`。

- [ ] **Step 3: 建置 + 全套不回歸**

Run: `cd app && swift build 2>&1 | tail -2 && swift test 2>&1 | tail -3`
Expected: Build complete；既有測試不回歸（Task 1-2 新增後全綠）。`menuBar?.updateGame` 於 Task 6 加，本步先以 `menuBar?.updateStatus(...)` 佔位或註記待 Task 6（若編譯需要，先 stub `updateGame` 空實作）。

- [ ] **Step 4: Commit**

```bash
git add app/Sources/MirageApp/MirageApp.swift app/Sources/MirageApp/Keymap/KeymapController.swift
git commit -m "feat: AppModel 遊戲偵測→ActivationDecider→keymap 啟用接線"
```

---

### Task 6: 選單列覆蓋（MenuBarController，App）

**背景**：P1-b `MenuBarController` 已有 NSStatusItem。加「目前遊戲 + 手動覆蓋」。**先讀** `MenuBarController.swift` 與 `MirrorView`/`AppModel` 對它的呼叫。

**Files:**
- Modify: `app/Sources/MirageApp/Lifecycle/MenuBarController.swift`

**Interfaces:**
- Consumes: Task 2 `ManualOverride`、Task 5 `AppModel.setOverride`、`ProfileStore`（列可用 gameId）。
- Produces: `MenuBarController.updateGame(package: String?, active: Bool)`；選單項回呼 `onForceProfile/(gameId)`、`onDisable`、`onAuto`（由 AppModel 綁到 `setOverride`）。

- [ ] **Step 1: 加遊戲區塊 + 覆蓋選單**

```swift
// MenuBarController 增補（節錄）：
//   private let gameItem = NSMenuItem(title: "遊戲：—", action: nil, keyEquivalent: "")
//   var onDisable: (() -> Void)?; var onAuto: (() -> Void)?
//   var onForce: ((String) -> Void)?   // gameId
// 於 menu 組裝時 insert gameItem + 分隔線 + 「停用 keymap」「恢復自動偵測」+「套用 profile ▸」子選單(列 ProfileStore 可用 gameId)

func updateGame(package: String?, active: Bool) {
    let pkg = package ?? "—"
    gameItem.title = "遊戲：\(pkg)　\(active ? "[keymap ✓]" : "[直接 tap]")"
}
```

`AppModel.startDetection()` 尾綁：`menuBar?.onDisable = { [weak self] in self?.setOverride(.disabled) }`、`menuBar?.onAuto = { [weak self] in self?.setOverride(.auto) }`、`menuBar?.onForce = { [weak self] gid in if let p = try? self?.store.load(gameId: gid) { self?.setOverride(.force(p)) } }`。

- [ ] **Step 2: 建置 + 冒煙（release 零警告）**

Run: `cd app && swift build -c release 2>&1 | tail -2`
Expected: Build complete、零非-deprecation 警告。GUI 冒煙（選單列見「遊戲：<pkg>」、切換覆蓋）**pending-human**。

- [ ] **Step 3: Commit**

```bash
git add app/Sources/MirageApp/Lifecycle/MenuBarController.swift app/Sources/MirageApp/MirageApp.swift
git commit -m "feat: 選單列顯示目前遊戲與手動 keymap 覆蓋"
```

---

### Task 7: MouseCapture 修正（App，P1-c fast-follow：焦點 gating + resignKey release）

**背景**：P1-c `MouseCapture` 於 profile 載入即 app-wide 捕捉游標、無失焦釋放（游標陷阱）。收緊條件 + 監聽 resignKey。**先讀** `MouseCapture.swift` 與其呼叫點（AppModel loadKeymap/toggleEditing）。

**Files:**
- Modify: `app/Sources/MirageApp/Keymap/MouseCapture.swift`
- Modify: `app/Sources/MirageApp/MirageApp.swift`（捕捉條件 gate）

**Interfaces:**
- Produces: `MouseCapture.updateCapture(shouldCapture: Bool)`（依條件捕捉/釋放，取代無條件 `capture()`）；內部監聽 `NSWindow.didResignKeyNotification`→release。

- [ ] **Step 1: 收緊捕捉條件 + resignKey 監聽**

```swift
// MouseCapture 增補/改（節錄）：
//   init 時 NotificationCenter observe .didResignKeyNotification → release()
//   deinit remove observer + 還原（P1-c 已有還原）
/// 僅在 shouldCapture（window key + look binding active + 非編輯）為真時捕捉，否則釋放。
func updateCapture(shouldCapture: Bool) {
    if shouldCapture { capture() } else { release() }
}
```

AppModel 決定 `shouldCapture`：`keymap?.hasProfile == true && !editing && (NSApp.keyWindow != nil) && profileHasLook`，於 `applyActivation()`（Task 5）與 `didBecomeKey`/`toggleEditing` 時呼 `mouseCapture?.updateCapture(shouldCapture:)`。`profileHasLook` = 當前 profile.bindings 含 `.look`。

- [ ] **Step 2: 建置 + 全套不回歸**

Run: `cd app && swift build -c release 2>&1 | tail -2 && swift test 2>&1 | tail -3`
Expected: Build complete 零警告；測試不回歸。游標行為（非 key window 不捕捉、resignKey 還原）**pending-human**。

- [ ] **Step 3: Commit**

```bash
git add app/Sources/MirageApp/Keymap/MouseCapture.swift app/Sources/MirageApp/MirageApp.swift
git commit -m "fix: MouseCapture 焦點 gating 與 resignKey 釋放（P1-c 交接）"
```

---

### Task 8: App-path 活體 harness + 驗收、覆蓋率、文件

**Files:**
- Create: `app/Tests/MirageCoreTests/KeymapInjectLiveTests.swift`（引擎→注入活體，MIRAGE_LIVE gated）
- Create: `app/scripts/verify_keymap_inject.sh`
- Create: `app/RESULTS-p1d.md`
- Modify: `app/README.md`（加 P1-d 章節）

**Interfaces:**
- Consumes: Task 1-7 全部。

- [ ] **Step 1: 引擎→注入活體測試（Core 範圍，§4.7）**

```swift
// app/Tests/MirageCoreTests/KeymapInjectLiveTests.swift
import Foundation
import Testing
@testable import MirageCore

@Suite struct KeymapInjectLiveTests {
    @Test func engineDrivenMultiTouchInjects() async throws {
        guard ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1" else { return }
        let profile = KeymapProfile(gameId: "com.example.game", version: 1, bindings: [
            .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                      center: NormPoint(x: 0.25, y: 0.7), radius: 0.12),
            .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.8)),
        ])
        let engine = KeymapEngine(profile: profile)
        let client = EmulatorClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .seconds(2))
        _ = engine.apply(.keyDown(.key("w")))                 // joystick
        let frame = engine.apply(.keyDown(.key("j")))         // + 技能 → 兩觸點
        await client.sendTouches(frame.touches, width: 540, height: 1200)
        try await Task.sleep(for: .seconds(1))
        await client.sendTouches(engine.apply(.keyUp(.key("j"))).touches, width: 540, height: 1200)
        await client.stop()
        #expect(frame.touches.filter { $0.down }.count == 2)  // 引擎產兩 down 觸點
    }
}
```

- [ ] **Step 2: harness 腳本**

```bash
# app/scripts/verify_keymap_inject.sh
#!/usr/bin/env bash
# 驗收 3：引擎→sendTouches 活體注入，show_touches 佐證。需模擬器執行中。
set -uo pipefail
export ANDROID_SERIAL=emulator-5554
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
"$ADB" shell settings put system show_touches 1
cd "$(dirname "$0")/.."
MIRAGE_LIVE=1 swift test --filter KeymapInjectLiveTests 2>&1 | tail -4
"$ADB" exec-out screencap -p > /tmp/mirage_keymap_inject.png && echo "擷圖 /tmp/mirage_keymap_inject.png"
"$ADB" shell settings put system show_touches 0
```

- [ ] **Step 3: 全測試 + 覆蓋率 + release 零警告**

```bash
cd app
swift build -c release 2>&1 | tail -2
swift test --enable-code-coverage 2>&1 | tail -3
XCTEST=$(find .build -name MiragePackageTests -path "*xctest*" -type f | head -1)
PROF=$(find .build -name default.profdata | head -1)
xcrun llvm-cov report "$XCTEST" -instr-profile "$PROF" -ignore-filename-regex "Generated|Tests" 2>/dev/null | grep -E "ForegroundParser|ActivationDecider|AdbOutcome"
```

- [ ] **Step 4: RESULTS-p1d.md（照 spec §7 逐條填實測）**

```markdown
# P1-d 遊戲偵測與 keymap 啟用 驗收結果（日期：____；模擬器：____）

| # | 驗收線（spec §7） | 實測 | 判定 |
|---|---|---|---|
| 1 | ForegroundParser+ActivationDecider 單元全綠、覆蓋 ≥80%、release 零警告、既有 79 不回歸 | ___ | ⬜ |
| 2 | 活體：前景切換→GameDetector 回報正確 package、啟用正確 active/deactivate | ___ | ⬜ |
| 3 | harness：合成 InputEvent→sendTouches→show_touches 見觸點 | ___（擷圖） | ⬜ |
| 4 | MouseCapture：非 key window 不捕捉、resignKey 還原 | ⬜ pending-human | ⬜ |
| 5 | 無 profile / adb 失敗 → 退 P1-a tap（不回歸不崩） | ___ | ⬜ |
| 6 | pending-human：真 GUI NSEvent 抽取、KeymapController GUI、真遊戲手感 | ⬜ pending-human | ⬜ |

## 判定
- [ ] P1-d 出貨；未達標項與處置：____
```

- [ ] **Step 5: README P1-d 章節**

```markdown
## P1-d 遊戲偵測與 keymap 啟用

- 前景遊戲偵測（adb dumpsys 輪詢）→ 自動載 profile → keymap 生效；無 profile 退回 P1-a tap
- 選單列：目前遊戲 + 手動強制/停用/恢復自動
- MouseCapture 焦點 gating（消 P1-c 游標陷阱）
- 活體：`scripts/verify_keymap_inject.sh`（引擎→注入 show_touches 佐證）
- 已知限制：完整 app-path（KeymapController+NSEvent）與真遊戲手感 pending-human；gameId==package
- 驗收：`RESULTS-p1d.md`；架構詳見 `../docs/specs/2026-07-24-p1d-game-detection-design.md`
```

- [ ] **Step 6: 填實數、判定、Commit**

```bash
git add app/Tests/MirageCoreTests/KeymapInjectLiveTests.swift app/scripts/verify_keymap_inject.sh app/RESULTS-p1d.md app/README.md
git commit -m "docs: p1d 驗收結果與使用文件"
```

---

## Self-Review 紀錄

- **Spec 覆蓋**：§4.1 ForegroundParser=Task 1；§4.4 ActivationDecider+啟用協調=Task 2+5；§4.2 AdbClient=Task 3；§4.3 GameDetector=Task 4；§4.5 選單列覆蓋=Task 6；§4.6 MouseCapture 修正=Task 7；§4.7 harness=Task 8；§5 錯誤處理=AdbOutcome 降級(3)/ForegroundParser nil(1)/ProfileStore try?(5)/MouseCapture 安全預設(7)；§6 測試=Task 1-3 單元+8 活體；§7 驗收=Task 8 逐條。
- **佔位掃描**：無 TBD；RESULTS `___` 為待填實測（專案慣例）。
- **型別一致性**：`ForegroundParser.foregroundPackage(fromDumpsys:)`（1=3/4）；`AdbOutcome.packageOrNil(exitCode:stdout:)`（3=測試）；`ActivationDecider.decide(loadedProfile:override:)`/`ManualOverride`/`Activation`（2=5/6）；`AdbClient.standard()/dumpsysForegroundPackage`（3=4/5）；`GameDetector.init(adb:interval:onChange:)`（4=5）；`KeymapController.reload(_:)`/`hasProfile`（P1-c/5=7）；`MenuBarController.updateGame(package:active:)`/`onForce/onDisable/onAuto`（6=5）；`MouseCapture.updateCapture(shouldCapture:)`（7=5）。
- **並發紀律**：MirageCore 新增（ForegroundParser/ActivationDecider/AdbOutcome）全純、不 import AppKit；AppKit 僅 App（AdbClient 用 Foundation Process，非 @MainActor；GameDetector/MouseCapture @MainActor）。
- **與 P1-a/b/c 整合**：改 MirageApp/MenuBarController/MouseCapture/KeymapController 皆 additive；MirageCore 僅新增純型別。GameDetector 輪詢 CPU 待活體量測（風險 §8）。

