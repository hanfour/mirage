# APK 拖放安裝 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 拖 .apk 到鏡像視窗 → 非同步 `adb install -r` →「安裝中…」→ 成功/失敗回饋。

**Architecture:** MirageCore 加純解析器 `InstallResult.parse`（可窮舉單元測試）；App 層 `AdbClient` 抽出共用 `run(args:timeout:mergeStderr:)`（既有 dumpsys 行為位元等價）並新增 `install`；`AppModel` 加 `installState`/`installAPKs` 編排；`MirageApp.body` 用 `.dropDestination(for: URL.self)` 接拖放並疊 `InstallBanner`。

**Tech Stack:** Swift 6（language mode v5）、swift-testing、Foundation `Process`、SwiftUI `.dropDestination`、AppKit。

## Global Constraints

- 平台 macOS 14+ Apple Silicon；`swift build -c release` 零非-deprecation 警告。
- **MirageCore 不得 import AppKit/SwiftUI/Metal**；不 `fatalError`；錯誤回傳/記錄，App 決定呈現。
- 所有 target 開 `-strict-concurrency=complete`；`.swiftLanguageMode(.v5)`。
- 測試用 swift-testing（`@Suite`/`@Test`/`#expect`）；每檔 <400 行、函式 <50 行；純解析與 UI 膠水嚴格分離；不可變優先。
- TDD：先寫失敗測試→確認失敗→最小實作→綠→commit。Conventional commits、無 attribution。
- 既有測試（合併後 92）不得回歸；MirageCore 覆蓋 ≥80%。
- 活體測試預設 skip、`MIRAGE_LIVE=1` 開啟；adb 一律 `ANDROID_SERIAL=emulator-5554`（避開實體手機 `RFCN804073P`）。
- **dumpsys 行為必須位元等價**：`AdbClient` 重構後 `dumpsysForegroundPackage` 的 stdout/降級語意不變（P1-d 偵測依賴）。

---

### Task 1: InstallResult 純解析（MirageCore）

**Files:**
- Create: `app/Sources/MirageCore/Install/InstallResult.swift`
- Test: `app/Tests/MirageCoreTests/InstallResultTests.swift`

**Interfaces:**
- Produces: `enum InstallResult: Equatable, Sendable { case success; case failure(String) }`，`static func parse(_ output: String) -> InstallResult`。Task 2（AdbClient.install）與 Task 3（AppModel）消費。

- [ ] **Step 1: 寫失敗測試** `app/Tests/MirageCoreTests/InstallResultTests.swift`

```swift
import Testing
@testable import MirageCore

@Suite struct InstallResultTests {
    @Test func plainSuccess() {
        #expect(InstallResult.parse("Success") == .success)
    }
    @Test func streamedSuccess() {
        #expect(InstallResult.parse("Performing Streamed Install\nSuccess") == .success)
    }
    @Test func failureBracketReason() {
        #expect(InstallResult.parse("Failure [INSTALL_FAILED_ALREADY_EXISTS]")
            == .failure("INSTALL_FAILED_ALREADY_EXISTS"))
    }
    @Test func adbErrorPrefixWithBracket() {
        let out = "adb: failed to install x.apk: Failure [INSTALL_FAILED_INVALID_APK: Failed to parse]"
        #expect(InstallResult.parse(out) == .failure("INSTALL_FAILED_INVALID_APK: Failed to parse"))
    }
    @Test func failedNoBracket() {
        let out = "adb: failed to install x.apk: no devices/emulators found"
        #expect(InstallResult.parse(out)
            == .failure("adb: failed to install x.apk: no devices/emulators found"))
    }
    @Test func emptyIsUnknown() {
        #expect(InstallResult.parse("") == .failure("未知錯誤"))
        #expect(InstallResult.parse("   \n ") == .failure("未知錯誤"))
    }
    @Test func unknownFormatReturnsTrimmed() {
        #expect(InstallResult.parse("weird output") == .failure("weird output"))
    }
    // 串流進度 `[ 50%]` 不得誤判成 failure（只有 "Failure [" 才觸發括號抽取）
    @Test func progressBracketNotMistakenForFailure() {
        #expect(InstallResult.parse("[ 50%] /data/local/tmp/x.apk\nSuccess") == .success)
    }
    @Test func failureBracketEmptyReason() {
        #expect(InstallResult.parse("Failure []") == .failure("未知錯誤"))
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter InstallResultTests`
Expected: FAIL（`InstallResult` 未定義／編譯錯誤）

- [ ] **Step 3: 最小實作** `app/Sources/MirageCore/Install/InstallResult.swift`

```swift
import Foundation

/// `adb install -r` 輸出解析結果（純值，無 I/O）。App 層決定如何呈現。
public enum InstallResult: Equatable, Sendable {
    case success
    case failure(String)   // 原因（INSTALL_FAILED_… 或原始尾句）

    /// 解析 adb install（stdout+stderr 合流）輸出。
    /// - `Failure [X]` → `.failure(X)`（X 空 → "未知錯誤"）
    /// - 否則含 `Success` → `.success`
    /// - 否則非空且含 "fail" 的尾行 → `.failure(該行)`
    /// - 其他非空 → `.failure(裁修後全文)`；空 → `.failure("未知錯誤")`
    public static func parse(_ output: String) -> InstallResult {
        // 只認 "Failure [" 觸發括號抽取——避開串流進度 "[ 50%]" 誤判。
        if let r = output.range(of: "Failure [") {
            let after = output[r.upperBound...]
            if let close = after.firstIndex(of: "]") {
                let reason = after[..<close].trimmingCharacters(in: .whitespaces)
                return .failure(reason.isEmpty ? "未知錯誤" : reason)
            }
            return .failure("未知錯誤")
        }
        if output.contains("Success") { return .success }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure("未知錯誤") }
        if let line = trimmed.split(separator: "\n").reversed()
            .first(where: { $0.lowercased().contains("fail") }) {
            return .failure(String(line).trimmingCharacters(in: .whitespaces))
        }
        return .failure(trimmed)
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd app && swift test --filter InstallResultTests`
Expected: PASS（9 個 @Test 全綠）

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Install/InstallResult.swift app/Tests/MirageCoreTests/InstallResultTests.swift
git commit -m "feat: InstallResult 純解析 adb install 輸出（TDD）"
```

---

### Task 2: AdbClient 抽共用 run + install（App）

**Files:**
- Modify: `app/Sources/MirageApp/Detect/AdbClient.swift`（全檔重寫如下）

**Interfaces:**
- Consumes: `InstallResult.parse(_:)`（Task 1）；`AdbOutcome.packageOrNil(exitCode:stdout:)`（既有 MirageCore）。
- Produces: `func install(apkURL: URL, timeout: Duration = .seconds(120)) async -> InstallResult`（Task 3 消費）；`dumpsysForegroundPackage(timeout:) async -> String?` 簽名與語意不變（P1-d `GameDetector` 依賴）。

**背景（實作者必讀）：** 現行 `OutcomeBox` 回傳 `String?` 並把 `AdbOutcome.packageOrNil` 烘進 `drainAndFinish`。本任務把 `OutcomeBox` 泛化成回 `(exit: Int32, stdout: String)?`，抽出私有 `run`，讓 dumpsys 與 install 各自轉換。**`adb install` 的失敗原因印在 stderr**（`adb: failed to install …: Failure [...]`），故 install 需 `mergeStderr: true`（stdout/stderr 同一 pipe，等同 `2>&1`）；dumpsys 維持 `mergeStderr: false`（stderr→nullDevice），確保輸出位元等價。

- [ ] **Step 1: 全檔重寫** `app/Sources/MirageApp/Detect/AdbClient.swift`

```swift
import Foundation
import MirageCore

/// adb 子行程薄封裝：抽出共用 `run`（並發排空 pipe 避免大輸出死鎖、逾時砍行程），
/// dumpsys 前景偵測與 APK 安裝各自轉換結果。非 @MainActor——純執行。
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
    /// 語意/輸出與重構前位元等價（mergeStderr:false → stderr→nullDevice）。
    func dumpsysForegroundPackage(timeout: Duration = .seconds(2)) async -> String? {
        guard let r = await run(
            ["-s", serial, "shell", "dumpsys", "activity", "activities"], timeout: timeout
        ) else { return nil }
        return AdbOutcome.packageOrNil(exitCode: r.exit, stdout: r.stdout)
    }

    /// 安裝 APK：`adb -s <serial> install -r <path>`。失敗原因在 stderr，故合流。
    /// run 回 nil（adb 無法啟動/逾時砍）→ 降級為明確 failure，不崩。
    func install(apkURL: URL, timeout: Duration = .seconds(120)) async -> InstallResult {
        guard let r = await run(
            ["-s", serial, "install", "-r", apkURL.path], timeout: timeout, mergeStderr: true
        ) else { return .failure("adb 執行失敗或逾時") }
        return InstallResult.parse(r.stdout)
    }

    /// 跑 adb，背景並發排空 stdout（避免大輸出塞爆 pipe buffer 死鎖），逾時砍行程。
    /// launch 失敗/逾時 → nil。mergeStderr:true 時 stderr 併入同一 pipe（等同 2>&1）。
    private func run(
        _ args: [String], timeout: Duration, mergeStderr: Bool = false
    ) async -> (exit: Int32, stdout: String)? {
        let proc = Process()
        proc.executableURL = adbPath
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = mergeStderr ? pipe : FileHandle.nullDevice
        let box = OutcomeBox(process: proc)

        return await withCheckedContinuation {
            (cont: CheckedContinuation<(exit: Int32, stdout: String)?, Never>) in
            box.attach(cont)
            do {
                try proc.run()
            } catch {
                box.finish(nil)
                return
            }
            // 邊跑邊讀持續排空 pipe，子行程才不會卡在 write()（見 OutcomeBox 註解）。
            box.drainAndFinish(pipe: pipe)
            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                box.timeoutIfStillRunning()
            }
            box.attach(watchdog)
        }
    }
}

/// 確保 continuation 只 resume 一次（逾時 vs 正常結束競態），並在逾時時終止子行程。
/// 泛化為回 `(exit, stdout)?`，讓 dumpsys/install 各自轉換（原本烘死 AdbOutcome）。
///
/// 設計備註（strict concurrency 適配）：`Process` 不是 `Sendable`，直接在
/// `@Sendable` closure 捕捉會警告；改用單一 `@unchecked Sendable` box、內部用鎖
/// 保護所有可變狀態，對外只暴露「完成一次」與「逾時終止」兩個動作。
private final class OutcomeBox: @unchecked Sendable {
    typealias Output = (exit: Int32, stdout: String)
    private let lock = NSLock()
    private let process: Process
    private var continuation: CheckedContinuation<Output?, Never>?
    private var watchdog: Task<Void, Never>?
    private var done = false

    init(process: Process) { self.process = process }

    func attach(_ cont: CheckedContinuation<Output?, Never>) {
        lock.lock(); defer { lock.unlock() }
        continuation = cont
    }

    func attach(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if done { task.cancel() } else { watchdog = task }
    }

    /// 背景並發排空 pipe（取代只在 terminationHandler 裡讀的死鎖作法）。
    /// `readToEnd()` 阻塞到 EOF（子行程關閉自己的 stdout）；隨後 waitUntilExit()
    /// 拿真正的 terminationStatus。finish 走與 timeoutIfStillRunning 相同的鎖保護
    /// done 旗標，兩者哪個先到就贏——resume-once 保證未變。
    func drainAndFinish(pipe: Pipe) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            let out = String(data: data, encoding: .utf8) ?? ""
            finish((exit: process.terminationStatus, stdout: out))
        }
    }

    /// 逾時觸發：仍在跑就殺掉子行程並降級回 nil；已完成則忽略。
    func timeoutIfStillRunning() {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let cont = continuation
        continuation = nil
        let proc = process
        lock.unlock()
        if proc.isRunning { proc.terminate() }
        cont?.resume(returning: nil)
    }

    func finish(_ v: Output?) {
        lock.lock()
        guard !done else { lock.unlock(); return }
        done = true
        let cont = continuation
        continuation = nil
        let task = watchdog
        watchdog = nil
        lock.unlock()
        task?.cancel()
        cont?.resume(returning: v)
    }
}
```

- [ ] **Step 2: 建置（strict concurrency 零警告）**

Run: `cd app && swift build -c release 2>&1 | grep -E 'warning|error' | grep -v deprecat || echo "零警告"`
Expected: `零警告`

- [ ] **Step 3: 跑既有測試（回歸——dumpsys/AdbOutcome 不變）**

Run: `cd app && swift test 2>&1 | tail -3`
Expected: 既有測試全綠（含 `AdbOutcomeTests`、`ForegroundParserTests`、`ActivationDeciderTests`），總數不減。

- [ ] **Step 4: Commit**

```bash
git add app/Sources/MirageApp/Detect/AdbClient.swift
git commit -m "refactor: AdbClient 抽共用 run(args:timeout:mergeStderr:) 並新增 install"
```

**驗收 2 的活體回歸（P1-d 偵測不回歸）留待 Task 5 的 verify 腳本一併驗（dumpsys→package + install 同一次）。**

---

### Task 3: InstallState + AppModel.installAPKs 編排（App）

**Files:**
- Create: `app/Sources/MirageApp/Install/InstallState.swift`
- Modify: `app/Sources/MirageApp/MirageApp.swift`（AppModel 增補；body 的拖放/banner 留 Task 4）

**Interfaces:**
- Consumes: `InstallResult`（Task 1）、`AdbClient.standard()`/`install`（Task 2）。
- Produces: `InstallState`/`InstallItem`（Task 4 的 InstallBanner 消費）；`AppModel.installState`（讀）、`func installAPKs(_ urls: [URL]) async`（Task 4 拖放呼叫）。

**背景：** App 層狀態機。編排：adb guard → 逐個 install（更新 `installing(done,total)`）→ `finished([Item])` → ~4s 自動回 `idle`（用 generation 令牌避免舊的 dismiss 清掉新批次）。並發拖放：安裝中再拖入直接忽略（MVP）。AppModel 是 `@MainActor`，內部 `Task {}` 繼承 MainActor 隔離，讀寫 `installGeneration`/`installState` 無資料競爭。

- [ ] **Step 1: 建 InstallState** `app/Sources/MirageApp/Install/InstallState.swift`

```swift
import MirageCore

/// 單一 APK 的安裝結果項（名稱取自檔名，供 banner 呈現）。
struct InstallItem: Equatable, Sendable {
    let name: String
    let result: InstallResult
}

/// 安裝流程 UI 狀態。adb install 無逐步進度，只有 installing→finished 的批次狀態。
enum InstallState: Equatable, Sendable {
    case idle
    case installing(done: Int, total: Int)
    case finished([InstallItem])
}
```

- [ ] **Step 2: AppModel 增補屬性** `app/Sources/MirageApp/MirageApp.swift`

在 `AppModel` 內（P1-d 偵測屬性 `private let store = ProfileStore.standard()` 那段之後）新增：

```swift
    // APK 拖放安裝（Phase-1）：installState 供 InstallBanner 呈現；generation 令牌讓
    // 自動消失只清掉「產生它的那一批」，避免舊 dismiss 清掉使用者剛拖入的新批次。
    private(set) var installState: InstallState = .idle
    private var installGeneration = 0
```

- [ ] **Step 3: AppModel 新增 installAPKs 方法** `app/Sources/MirageApp/MirageApp.swift`

在 `saveProfile(_:)` 方法之後新增：

```swift
    /// 拖放安裝入口（Task 4 的 .dropDestination 呼叫，urls 已濾成 .apk）。
    /// adb 不可用 → 每個檔案記成明確 failure，不崩。安裝中再拖入直接忽略（MVP）。
    func installAPKs(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        if case .installing = installState { return }   // 一次一批
        guard let adb = AdbClient.standard() else {
            finish(urls.map { InstallItem(name: $0.lastPathComponent, result: .failure("adb 不可用")) })
            return
        }
        var items: [InstallItem] = []
        for (i, url) in urls.enumerated() {
            installState = .installing(done: i, total: urls.count)
            let r = await adb.install(apkURL: url)
            items.append(InstallItem(name: url.lastPathComponent, result: r))
        }
        finish(items)
    }

    /// 進 finished 並排程 ~4s 後自動回 idle（generation 令牌防舊 dismiss 清新批次）。
    private func finish(_ items: [InstallItem]) {
        installGeneration += 1
        let gen = installGeneration
        installState = .finished(items)
        Task {   // @MainActor 繼承：以下讀寫皆在 MainActor，無資料競爭。
            try? await Task.sleep(for: .seconds(4))
            if self.installGeneration == gen { self.installState = .idle }
        }
    }
```

- [ ] **Step 4: 建置**

Run: `cd app && swift build -c release 2>&1 | grep -E 'warning|error' | grep -v deprecat || echo "零警告"`
Expected: `零警告`

- [ ] **Step 5: 跑既有測試（不回歸）**

Run: `cd app && swift test 2>&1 | tail -3`
Expected: 全綠、總數不減。

- [ ] **Step 6: Commit**

```bash
git add app/Sources/MirageApp/Install/InstallState.swift app/Sources/MirageApp/MirageApp.swift
git commit -m "feat: AppModel 安裝狀態機與 installAPKs 編排（generation 自動消失）"
```

---

### Task 4: InstallBanner + 拖放接線（App）

**Files:**
- Create: `app/Sources/MirageApp/Install/InstallBanner.swift`
- Modify: `app/Sources/MirageApp/MirageApp.swift`（body 的 ZStack）

**Interfaces:**
- Consumes: `InstallState`/`InstallItem`（Task 3）、`AppModel.installState`/`installAPKs`（Task 3）。
- Produces: 使用者面拖放安裝 UI（無下游程式碼消費）。

**背景：** `InstallBanner` 仿既有 `ConnectionBanner.swift` 樣式；置於 ZStack 底部（`ConnectionBanner` 在頂部，避免重疊），`allowsHitTesting(false)` 不擋輸入。拖放用 SwiftUI `.dropDestination(for: URL.self)`（macOS 13+ 原生解 URL，比 NSItemProvider 乾淨）套在 body 的 `MirrorView()` 上——App 非 sandbox，`url.path` 可直接餵 adb。拖曳高亮（isTargeted）列 pending-human。

- [ ] **Step 1: 建 InstallBanner** `app/Sources/MirageApp/Install/InstallBanner.swift`

```swift
import MirageCore
import SwiftUI

/// 安裝進度/結果 banner。仿 ConnectionBanner 樣式；置於畫面底部，不擋輸入。
/// import MirageCore：resultLabel 需 pattern-match InstallResult 的 .success/.failure。
struct InstallBanner: View {
    let state: InstallState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case let .installing(done, total):
            row {
                ProgressView().controlSize(.small).tint(.white)
                Text("安裝中… (\(min(done + 1, total))/\(total))").font(.callout.bold())
            }
        case let .finished(items):
            VStack(spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    resultLabel(item)
                }
            }
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func resultLabel(_ item: InstallItem) -> some View {
        switch item.result {
        case .success:
            capsule("✓ \(item.name) 安裝成功", .green)
        case let .failure(reason):
            capsule("✗ \(item.name)：\(reason)", .red)
        }
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.black.opacity(0.7), in: Capsule())
            .foregroundStyle(.white)
            .padding(.bottom, 12)
    }

    private func capsule(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.callout.bold())
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(color.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
    }
}
```

- [ ] **Step 2: 接進 body 的 ZStack** `app/Sources/MirageApp/MirageApp.swift`

把 body 裡 `MirrorView(...)` 那行改成帶拖放，並在 ZStack 內（`Button("")` 之後、`.frame` 之前）加 `InstallBanner`：

```swift
                MirrorView(client: model.client, box: model.box, controller: model.keymap)
                    .dropDestination(for: URL.self) { urls, _ in
                        let apks = urls.filter { $0.pathExtension.lowercased() == "apk" }
                        guard !apks.isEmpty else { return false }
                        Task { await model.installAPKs(apks) }
                        return true
                    }
                ConnectionBanner(state: model.connState)
                keymapOverlayLayer
                Button("") { model.toggleEditing() }
                    .keyboardShortcut("e", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                InstallBanner(state: model.installState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .allowsHitTesting(false)
```

- [ ] **Step 3: 建置**

Run: `cd app && swift build -c release 2>&1 | grep -E 'warning|error' | grep -v deprecat || echo "零警告"`
Expected: `零警告`

- [ ] **Step 4: 跑既有測試（不回歸）**

Run: `cd app && swift test 2>&1 | tail -3`
Expected: 全綠、總數不減。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageApp/Install/InstallBanner.swift app/Sources/MirageApp/MirageApp.swift
git commit -m "feat: InstallBanner 安裝回饋與 .dropDestination 拖放接線"
```

---

### Task 5: 活體 verify 腳本與驗收文件

**Files:**
- Create: `app/scripts/verify_apk_install.sh`
- Create: `app/RESULTS-apk-install.md`
- Modify: `app/README.md`（新增「APK 拖放安裝」段）

**背景：** `AdbClient` 在不可 import 的 MirageApp **executable** target（同 P1-c `KeymapController`、P1-d 偵測），無法從 MirageCoreTests 直接活體測 install。故活體證據拆兩半並誠實標記：**(a) 機制**——腳本直接 `adb install -r` 印原始輸出（即 `InstallResult.parse` 的輸入）；**(b) 解析**——Task 1 單元窮舉。**完整 app-path**（拖放→dropDestination→installAPKs→banner）需真 GUI session，列 pending-human。腳本同時重跑 dumpsys 前景解析，佐證 Task 2 重構未回歸 P1-d（驗收 2）。

- [ ] **Step 1: 建 verify 腳本** `app/scripts/verify_apk_install.sh`

```bash
#!/usr/bin/env bash
# 驗收 2+3：Task 2 重構後 dumpsys 前景偵測不回歸；adb install -r 機制活體。
# 用法：verify_apk_install.sh [APK路徑]；未給則從裝置抓一個第三方 app 的 base.apk 重裝。
set -uo pipefail
export ANDROID_SERIAL=emulator-5554
ADB="$HOME/Library/Android/sdk/platform-tools/adb"

echo "=== 驗收 2：dumpsys 前景解析（P1-d 不回歸）==="
"$ADB" shell dumpsys activity activities 2>/dev/null \
  | grep -m1 ResumedActivity || echo "（無 ResumedActivity 行）"

echo ""
echo "=== 驗收 3：adb install -r 機制（InstallResult.parse 的輸入）==="
APK="${1:-}"
if [ -z "$APK" ]; then
  PKG="$("$ADB" shell pm list packages -3 2>/dev/null | head -1 | tr -d '\r' | cut -d: -f2)"
  if [ -n "$PKG" ]; then
    REMOTE="$("$ADB" shell pm path "$PKG" 2>/dev/null | head -1 | tr -d '\r' | cut -d: -f2)"
    APK="/tmp/mirage_verify_$PKG.apk"
    "$ADB" pull "$REMOTE" "$APK" >/dev/null 2>&1 && echo "抓到可重裝 APK：$PKG"
  fi
fi
if [ -z "$APK" ] || [ ! -f "$APK" ]; then
  echo "無可用 APK——請給路徑：verify_apk_install.sh /path/to/app.apk"; exit 1
fi
echo "--- adb install -r 原始輸出 ---"
"$ADB" install -r "$APK"
echo "--- 結束（Success → .success；Failure [X] → .failure(X)）---"
```

- [ ] **Step 2: 賦予執行權並活體跑一次**

Run:
```bash
cd app && chmod +x scripts/verify_apk_install.sh && ./scripts/verify_apk_install.sh
```
Expected: 印出 `ResumedActivity`（前景解析仍運作），以及 `adb install -r` 的 `Performing Streamed Install` / `Success`（或明確 `Failure [X]`）。**若模擬器未執行則本步跳過、記錄於 RESULTS。**

- [ ] **Step 3: 建驗收文件** `app/RESULTS-apk-install.md`

記錄：Task 1 單元結果（9 綠）、Task 2 建置零警告 + 既有測試不回歸總數、Step 2 活體輸出（dumpsys ResumedActivity 行 + install 原始輸出）、以及 pending-human 清單（拖放 UI 手感、拖曳高亮 isTargeted、大 APK banner 體感、完整 app-path GUI 驗證）。格式仿 `app/RESULTS-p1d.md`。

- [ ] **Step 4: README 新增段** `app/README.md`

在既有結構後新增「## APK 拖放安裝」段：說明拖 .apk 到視窗即 `adb install -r`；多檔逐個；成功/失敗底部 banner ~4s 自動消；`scripts/verify_apk_install.sh` 活體驗；真遊戲仍需自裝 GApps（母計畫 R1，本件只做 sideload 機制）。

- [ ] **Step 5: Commit**

```bash
git add app/scripts/verify_apk_install.sh app/RESULTS-apk-install.md app/README.md
git commit -m "docs: APK 安裝活體 verify 腳本與驗收文件"
```

---

## 驗收線對照（spec §7）

| # | 驗收線 | 由哪個 Task 覆蓋 |
|---|---|---|
| 1 | InstallResult 單元全綠、覆蓋 ≥80%、release 零警告、既有 92 不回歸 | Task 1（單元）+ Task 2/3/4（零警告+不回歸）|
| 2 | AdbClient run 重構後 P1-d 偵測不回歸 | Task 2（既有測試）+ Task 5（dumpsys 活體）|
| 3 | 拖/指定 .apk → adb install -r → InstallResult 正確 | Task 5（機制活體）+ Task 1（解析單元）|
| 4 | 拖非 .apk / adb 不可用 → 不崩、明確回饋 | Task 3（adb guard）+ Task 4（.apk 濾）|
| 5 | pending-human：拖放 UI、拖曳高亮、大 APK 體感、完整 app-path | Task 5（RESULTS 記錄）|
