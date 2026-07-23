# P1-a 顯示管線與產品骨架 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 依 `docs/specs/2026-07-23-p1a-display-shell-design.md` 建立 `app/` 產品包：MirageCore（FramePump、連線狀態機、DisplayTransport、EmulatorClient）+ MirageApp（MTKView vsync 拉取），達成 540p 穩定 60fps 與 10 秒內斷線自動重連。

**Architecture:** 收幀與渲染徹底解耦——背景 task 消費 transport 串流寫入單格 `LatestFrameBox`（鎖保護、同步存取），MTKView 每 vsync 同步拉最新幀上傳；drop-late 由單格信箱天生保證。連線由純函式 reducer 狀態機驅動，退避策略與時鐘全部可注入、可單元測試。

**Tech Stack:** Swift 5.9+ / SwiftPM、grpc-swift **exact 1.27.5**（沿用 phase0 已驗證版本與既有 Generated stubs）、SwiftUI + MetalKit、XCTest；整合量測沿用 `phase0/harness`（animate.py、e2e）。

## Global Constraints

- 平台 macOS 14+ Apple Silicon；`swift build -c release` 零警告；每檔 <400 行。
- **MirageCore 不得 import AppKit/SwiftUI/Metal**（無 UI 依賴、全單元可測）；不 fatalError。
- 所有 target 開 `-strict-concurrency=complete`（spec §8 併發正確性）。
- **MMAP 安全鐵則**：`UnaryMmapTransport` 啟用前必須確認 emulator 版本 ≥37；穩定版（36.x）碰 MMAP 即崩（phase0/RESULTS-0b.md）。預設 transport 是 gRPC 串流，MMAP 僅 `MIRAGE_TRANSPORT=unary-mmap` 實驗旗標。
- 量測紀律：fps/延遲數字一律 Release build、量測前 `uptime` 檢查 load < 8、動畫源用 `phase0/harness/animate.py`。
- 測試覆蓋 MirageCore ≥80%（`swift test --enable-code-coverage`）。
- Commit：conventional commits、無 attribution。TDD 順序：測試先行、先紅後綠。
- 模擬器操作：headless 啟動用 `phase0/scripts/02_boot_headless.sh` + `03_wait_boot.sh`；目前安裝版本為 canary 37.2.1.0。

## 修正案 A（2026-07-23，執行期環境事實）

本機僅有 CommandLineTools（無 Xcode），**XCTest 模組不存在**；磁碟 10GB 裝不下 Xcode。
經最小實驗驗證：swift-testing 以 SPM 相依方式在 CLT 的 `swift test` 原生可跑。因此：

1. `Package.swift` 改為 canonical 修正版：`swift-tools-version:6.0`、加相依
   `.package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0")`、
   test target 依賴 `.product(name: "Testing", package: "swift-testing")`、
   **每個 target 加 `.swiftLanguageMode(.v5)`**（Generated stubs 為 v1 grpc 程式碼，
   不承受 v6 語言模式）並保留 `-strict-concurrency=complete`。
2. 本計畫所有測試程式碼區塊維持 XCTest 語法**作為語意規格**，實作時依下表機械轉換
   為 swift-testing；審查者以「語意等價」裁決：

| XCTest | swift-testing |
|---|---|
| `final class XTests: XCTestCase` + `func testX()` | `@Suite struct XTests` + `@Test func x()` |
| `XCTAssertEqual(a, b)` / `XCTAssertTrue/False/Nil/NotNil` | `#expect(a == b)` / `#expect(x)` / `#expect(!x)` / `#expect(x == nil)` / `#expect(x != nil)` |
| `XCTAssertGreaterThan(a, b)` 等比較 | `#expect(a > b)` 等 |
| async 測試 | `@Test func x() async throws` 原生支援 |
| `expectation` + `fulfillment(of:timeout:)` | `confirmation { }` 或 deadline 輪詢（`for _ in 0..<N { if 條件 { break }; try await Task.sleep(...) }` 後 `#expect(條件)`） |
| `XCTSkipUnless(cond, msg)` | `try #require(cond)` 之前用 `@Test(.enabled(if: cond))` 或函式開頭 `guard cond else { return }`（記 skip 註解） |
| `swift test --filter XTests` | 同指令，過濾字串改 suite/測試名 |

3. 各任務「Expected: N tests passed」的數字不變；輸出格式為 swift-testing 樣式
   （`✔ Test run with N tests passed`）。
4. **勿移除 swift-testing 相依**：編譯器會警告「toolchain 已內建、請移除相依」——
   已實證（scratchpad st-probe）CLT 環境拿掉相依後 `import Testing` 直接失敗，
   該警告在無 Xcode 環境是誤導。測試 target 的 deprecation 警告為預期噪音；
   驗收的「零警告」僅指 `swift build -c release`（不含測試 target）。

## File Structure

```
app/
├── Package.swift
├── Sources/MirageCore/
│   ├── Frame.swift                  # Frame 值型別 + isValid
│   ├── LatestFrameBox.swift         # 單格信箱（NSLock，同步 take）
│   ├── FramePump.swift              # actor：串流消費生命週期，寫入 box
│   ├── Backoff.swift                # BackoffPolicy 純函式
│   ├── ConnectionStateMachine.swift # ConnState/ConnEvent/ConnEffect/ConnReducer 純 reducer
│   ├── DisplayTransport.swift       # protocol + TransportError 分類
│   ├── GrpcStreamTransport.swift    # 主選實作
│   ├── UnaryMmapTransport.swift     # 實驗旗標實作 + 版本閘（版本閘為純函式）
│   ├── EmulatorClient.swift         # 門面：連線/重連驅動、輸入注入、狀態發布
│   └── Generated/                   # 自 phase0/swift-poc 複製的 proto stubs
├── Sources/MirageApp/
│   ├── MirageApp.swift              # @main WindowGroup
│   ├── MirrorView.swift             # NSViewRepresentable + Coordinator（resize debounce）
│   ├── Renderer.swift               # MTKViewDelegate：vsync 拉取→replaceRegion→blit
│   └── ConnectionBanner.swift       # 連線狀態 overlay
└── Tests/MirageCoreTests/
    ├── FrameTests.swift
    ├── LatestFrameBoxTests.swift
    ├── FramePumpTests.swift
    ├── BackoffTests.swift
    ├── ConnectionStateMachineTests.swift
    ├── MmapVersionGateTests.swift
    └── EmulatorClientReconnectTests.swift  # MockTransport 注入
```

---

### Task 1: app/ 包骨架與 stubs 遷移

**Files:**
- Create: `app/Package.swift`
- Create: `app/Sources/MirageCore/Frame.swift`
- Create: `app/Sources/MirageCore/Generated/`（複製）
- Create: `app/Sources/MirageApp/MirageApp.swift`（暫時最小）
- Test: `app/Tests/MirageCoreTests/FrameTests.swift`

**Interfaces:**
- Produces: `Frame(width: Int, height: Int, rgba: Data)`（`Sendable`、`isValid: Bool`）；可建置的三 target 包。後續全部 task 在此包內工作。

- [ ] **Step 1: Package.swift**

```swift
// swift-tools-version:5.9
import PackageDescription

let strict = [SwiftSetting.unsafeFlags(["-strict-concurrency=complete"])]

let package = Package(
    name: "Mirage",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.27.5"),
    ],
    targets: [
        .target(
            name: "MirageCore",
            dependencies: [.product(name: "GRPC", package: "grpc-swift")],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "MirageApp",
            dependencies: ["MirageCore"],
            swiftSettings: strict
        ),
        .testTarget(
            name: "MirageCoreTests",
            dependencies: ["MirageCore"],
            swiftSettings: strict
        ),
    ]
)
```

- [ ] **Step 2: 失敗測試（Frame）**

```swift
// app/Tests/MirageCoreTests/FrameTests.swift
import XCTest
@testable import MirageCore

final class FrameTests: XCTestCase {
    func testValidFrame() {
        let f = Frame(width: 2, height: 3, rgba: Data(count: 24))
        XCTAssertTrue(f.isValid)
    }

    func testInvalidSizeMismatch() {
        XCTAssertFalse(Frame(width: 2, height: 3, rgba: Data(count: 23)).isValid)
    }

    func testInvalidZeroDimensions() {
        XCTAssertFalse(Frame(width: 0, height: 3, rgba: Data()).isValid)
    }
}
```

- [ ] **Step 3: 跑測試確認失敗**

Run: `cd app && swift test 2>&1 | tail -5`
Expected: 編譯失敗（`Frame` 不存在）。

- [ ] **Step 4: 實作 Frame + 遷移 stubs + 最小 App**

```swift
// app/Sources/MirageCore/Frame.swift
import Foundation

public struct Frame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let rgba: Data

    public init(width: Int, height: Int, rgba: Data) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    public var isValid: Bool {
        width > 0 && height > 0 && rgba.count == width * height * 4
    }
}
```

```bash
cp phase0/swift-poc/Sources/MiragePOC/Generated/*.swift app/Sources/MirageCore/Generated/
```

```swift
// app/Sources/MirageApp/MirageApp.swift（Task 6 前的暫時版）
import SwiftUI

@main
struct MirageApp: App {
    var body: some Scene {
        WindowGroup("Mirage") {
            Text("Mirage P1-a bootstrap")
        }
    }
}
```

- [ ] **Step 5: 測試通過 + 建置**

Run: `swift test 2>&1 | tail -3 && swift build 2>&1 | tail -2`
Expected: 3 tests passed；Build complete（Generated 檔案量大，首建 2-3 分鐘屬正常）。

- [ ] **Step 6: Commit**

```bash
git add app
git commit -m "feat: app 包骨架——MirageCore/MirageApp/Tests 三 target 與 Frame 型別"
```

---

### Task 2: LatestFrameBox 與 FramePump（TDD）

**Files:**
- Create: `app/Sources/MirageCore/LatestFrameBox.swift`
- Create: `app/Sources/MirageCore/FramePump.swift`
- Test: `app/Tests/MirageCoreTests/LatestFrameBoxTests.swift`
- Test: `app/Tests/MirageCoreTests/FramePumpTests.swift`

**Interfaces:**
- Consumes: `Frame`。
- Produces: `LatestFrameBox`——`put(_ frame: Frame)`、`takeLatest() -> Frame?`、`stats() -> (dropped: Int, rejected: Int)`（全部同步、執行緒安全）。`FramePump` actor——`attach(_ stream: AsyncThrowingStream<Frame, Error>, into box: LatestFrameBox, onEnd: @escaping @Sendable (Error?) -> Void)`、`detach()`。Task 6 的 Renderer 在 draw 內呼叫 `box.takeLatest()`；Task 4 的 EmulatorClient 在重連後重新 `attach`。

- [ ] **Step 1: 失敗測試**

```swift
// app/Tests/MirageCoreTests/LatestFrameBoxTests.swift
import XCTest
@testable import MirageCore

final class LatestFrameBoxTests: XCTestCase {
    private func frame(_ tag: UInt8) -> Frame {
        Frame(width: 1, height: 1, rgba: Data([tag, 0, 0, 255]))
    }

    func testTakeReturnsLatestAndCountsDropped() {
        let box = LatestFrameBox()
        box.put(frame(1)); box.put(frame(2)); box.put(frame(3))
        XCTAssertEqual(box.takeLatest(), frame(3))
        XCTAssertEqual(box.stats().dropped, 2)
    }

    func testTakeEmptiesBox() {
        let box = LatestFrameBox()
        box.put(frame(1))
        XCTAssertNotNil(box.takeLatest())
        XCTAssertNil(box.takeLatest())
    }

    func testInvalidFrameRejectedNotStored() {
        let box = LatestFrameBox()
        box.put(Frame(width: 2, height: 2, rgba: Data(count: 3)))
        XCTAssertNil(box.takeLatest())
        XCTAssertEqual(box.stats().rejected, 1)
        XCTAssertEqual(box.stats().dropped, 0)
    }

    func testConcurrentPutTakeDoesNotCrash() {
        let box = LatestFrameBox()
        let exp = expectation(description: "done")
        exp.expectedFulfillmentCount = 2
        DispatchQueue.global().async {
            for i in 0..<5000 { box.put(self.frame(UInt8(i % 256))) }
            exp.fulfill()
        }
        DispatchQueue.global().async {
            for _ in 0..<5000 { _ = box.takeLatest() }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }
}
```

```swift
// app/Tests/MirageCoreTests/FramePumpTests.swift
import XCTest
@testable import MirageCore

final class FramePumpTests: XCTestCase {
    private func frame(_ tag: UInt8) -> Frame {
        Frame(width: 1, height: 1, rgba: Data([tag, 0, 0, 255]))
    }

    func testPumpConsumesStreamIntoBox() async throws {
        let box = LatestFrameBox()
        let pump = FramePump()
        let (stream, cont) = AsyncThrowingStream<Frame, Error>.makeStream()
        await pump.attach(stream, into: box, onEnd: { _ in })
        cont.yield(frame(7))
        cont.finish()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.takeLatest(), frame(7))
    }

    func testOnEndReceivesStreamError() async throws {
        struct Boom: Error {}
        let box = LatestFrameBox()
        let pump = FramePump()
        let (stream, cont) = AsyncThrowingStream<Frame, Error>.makeStream()
        let ended = expectation(description: "ended")
        let holder = ErrorHolder()
        await pump.attach(stream, into: box, onEnd: { err in
            Task { await holder.set(err); ended.fulfill() }
        })
        cont.finish(throwing: Boom())
        await fulfillment(of: [ended], timeout: 5)
        let got = await holder.value
        XCTAssertTrue(got is Boom)
    }

    func testReattachCancelsPreviousConsumer() async throws {
        let box = LatestFrameBox()
        let pump = FramePump()
        let (s1, c1) = AsyncThrowingStream<Frame, Error>.makeStream()
        let (s2, c2) = AsyncThrowingStream<Frame, Error>.makeStream()
        await pump.attach(s1, into: box, onEnd: { _ in })
        await pump.attach(s2, into: box, onEnd: { _ in })  // 換源
        c1.yield(frame(1))   // 舊源已取消，不應進 box
        c2.yield(frame(2))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(box.takeLatest(), frame(2))
    }
}

actor ErrorHolder {
    var value: Error?
    func set(_ e: Error?) { value = e }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `swift test --filter LatestFrameBoxTests 2>&1 | tail -3`
Expected: 編譯失敗（型別不存在）。

- [ ] **Step 3: 實作**

```swift
// app/Sources/MirageCore/LatestFrameBox.swift
import Foundation

/// 單格最新幀信箱：收幀端 put、渲染端每 vsync 同步 takeLatest。
/// drop-late 語意天生成立——消費不及的幀被覆蓋並計數。
public final class LatestFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Frame?
    private var dropped = 0
    private var rejected = 0

    public init() {}

    public func put(_ frame: Frame) {
        guard frame.isValid else {
            lock.lock(); rejected += 1; lock.unlock()
            return
        }
        lock.lock()
        if latest != nil { dropped += 1 }
        latest = frame
        lock.unlock()
    }

    public func takeLatest() -> Frame? {
        lock.lock()
        defer { latest = nil; lock.unlock() }
        return latest
    }

    public func stats() -> (dropped: Int, rejected: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (dropped, rejected)
    }
}
```

```swift
// app/Sources/MirageCore/FramePump.swift
import Foundation

/// 串流消費生命週期：attach 換源時自動取消舊消費 task。
public actor FramePump {
    private var task: Task<Void, Never>?

    public init() {}

    public func attach(_ stream: AsyncThrowingStream<Frame, Error>,
                       into box: LatestFrameBox,
                       onEnd: @escaping @Sendable (Error?) -> Void) {
        task?.cancel()
        task = Task {
            do {
                for try await frame in stream {
                    if Task.isCancelled { return }
                    box.put(frame)
                }
                onEnd(nil)
            } catch {
                if !Task.isCancelled { onEnd(error) }
            }
        }
    }

    public func detach() {
        task?.cancel()
        task = nil
    }
}
```

- [ ] **Step 4: 測試通過**

Run: `swift test --filter "LatestFrameBoxTests|FramePumpTests" 2>&1 | tail -3`
Expected: 7 tests passed。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/LatestFrameBox.swift app/Sources/MirageCore/FramePump.swift app/Tests/MirageCoreTests/LatestFrameBoxTests.swift app/Tests/MirageCoreTests/FramePumpTests.swift
git commit -m "feat: 單格幀信箱與消費泵（TDD）——drop-late 語意"
```

---

### Task 3: BackoffPolicy 與連線 reducer（TDD）

**Files:**
- Create: `app/Sources/MirageCore/Backoff.swift`
- Create: `app/Sources/MirageCore/ConnectionStateMachine.swift`
- Test: `app/Tests/MirageCoreTests/BackoffTests.swift`
- Test: `app/Tests/MirageCoreTests/ConnectionStateMachineTests.swift`

**Interfaces:**
- Produces: `BackoffPolicy(base: Duration = .milliseconds(500), cap: Duration = .seconds(8), jitterRatio: Double = 0.2)`——`delay(attempt: Int, random: Double) -> Duration`（random ∈ [0,1) 注入）。`ConnState`（`.disconnected/.connecting/.connected/.reconnecting(attempt: Int)`）、`ConnEvent`（`.connectRequested/.connectSucceeded/.connectFailed/.streamBroken/.stopRequested`）、`ConnEffect`（`.startConnect/.scheduleReconnect(attempt: Int)/.none`）、`ConnReducer.reduce(_ s: ConnState, _ e: ConnEvent) -> (ConnState, ConnEffect)`（純函式）。Task 4 的 EmulatorClient 驅動。

- [ ] **Step 1: 失敗測試**

```swift
// app/Tests/MirageCoreTests/BackoffTests.swift
import XCTest
@testable import MirageCore

final class BackoffTests: XCTestCase {
    let policy = BackoffPolicy()  // 0.5s base, 8s cap, 0.2 jitter

    func testAttemptZeroAroundBase() {
        let d = policy.delay(attempt: 0, random: 0.5)  // jitter 中點 = 無偏移
        XCTAssertEqual(d, .milliseconds(500))
    }

    func testDoublesPerAttempt() {
        XCTAssertEqual(policy.delay(attempt: 1, random: 0.5), .milliseconds(1000))
        XCTAssertEqual(policy.delay(attempt: 2, random: 0.5), .milliseconds(2000))
    }

    func testCapsAtEight() {
        XCTAssertEqual(policy.delay(attempt: 10, random: 0.5), .seconds(8))
    }

    func testJitterBounds() {
        let lo = policy.delay(attempt: 0, random: 0.0)   // -20%
        let hi = policy.delay(attempt: 0, random: 0.999) // ~+20%
        XCTAssertEqual(lo, .milliseconds(400))
        XCTAssertGreaterThan(hi, .milliseconds(590))
        XCTAssertLessThanOrEqual(hi, .milliseconds(600))
    }
}
```

```swift
// app/Tests/MirageCoreTests/ConnectionStateMachineTests.swift
import XCTest
@testable import MirageCore

final class ConnectionStateMachineTests: XCTestCase {
    func testHappyPath() {
        var (s, e) = ConnReducer.reduce(.disconnected, .connectRequested)
        XCTAssertEqual(s, .connecting); XCTAssertEqual(e, .startConnect)
        (s, e) = ConnReducer.reduce(s, .connectSucceeded)
        XCTAssertEqual(s, .connected); XCTAssertEqual(e, .none)
    }

    func testStreamBrokenTriggersReconnectWithAttemptZero() {
        let (s, e) = ConnReducer.reduce(.connected, .streamBroken)
        XCTAssertEqual(s, .reconnecting(attempt: 0))
        XCTAssertEqual(e, .scheduleReconnect(attempt: 0))
    }

    func testReconnectFailureIncrementsAttempt() {
        let (s, e) = ConnReducer.reduce(.reconnecting(attempt: 2), .connectFailed)
        XCTAssertEqual(s, .reconnecting(attempt: 3))
        XCTAssertEqual(e, .scheduleReconnect(attempt: 3))
    }

    func testReconnectSuccessResets() {
        let (s, e) = ConnReducer.reduce(.reconnecting(attempt: 5), .connectSucceeded)
        XCTAssertEqual(s, .connected); XCTAssertEqual(e, .none)
    }

    func testInitialConnectFailureGoesToReconnecting() {
        let (s, e) = ConnReducer.reduce(.connecting, .connectFailed)
        XCTAssertEqual(s, .reconnecting(attempt: 0))
        XCTAssertEqual(e, .scheduleReconnect(attempt: 0))
    }

    func testStopFromAnyStateDisconnects() {
        for from: ConnState in [.connecting, .connected, .reconnecting(attempt: 3)] {
            let (s, e) = ConnReducer.reduce(from, .stopRequested)
            XCTAssertEqual(s, .disconnected); XCTAssertEqual(e, .none)
        }
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `swift test --filter "BackoffTests|ConnectionStateMachineTests" 2>&1 | tail -3`
Expected: 編譯失敗。

- [ ] **Step 3: 實作**

```swift
// app/Sources/MirageCore/Backoff.swift
import Foundation

public struct BackoffPolicy: Sendable {
    public let base: Duration
    public let cap: Duration
    public let jitterRatio: Double

    public init(base: Duration = .milliseconds(500),
                cap: Duration = .seconds(8),
                jitterRatio: Double = 0.2) {
        self.base = base
        self.cap = cap
        self.jitterRatio = jitterRatio
    }

    /// random ∈ [0,1) 由呼叫端注入（測試可決定論）。
    public func delay(attempt: Int, random: Double) -> Duration {
        let baseMs = Double(base.components.seconds) * 1000
            + Double(base.components.attoseconds) / 1e15
        let capMs = Double(cap.components.seconds) * 1000
            + Double(cap.components.attoseconds) / 1e15
        let raw = min(baseMs * pow(2, Double(max(attempt, 0))), capMs)
        let jitter = 1.0 + jitterRatio * (random * 2 - 1)
        return .milliseconds(Int64((raw * jitter).rounded()))
    }
}
```

```swift
// app/Sources/MirageCore/ConnectionStateMachine.swift
/// 連線狀態的純 reducer——所有轉移可窮舉測試，效果由 EmulatorClient 執行。
public enum ConnState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
}

public enum ConnEvent: Equatable, Sendable {
    case connectRequested
    case connectSucceeded
    case connectFailed
    case streamBroken
    case stopRequested
}

public enum ConnEffect: Equatable, Sendable {
    case startConnect
    case scheduleReconnect(attempt: Int)
    case none
}

public enum ConnReducer {
    public static func reduce(_ state: ConnState, _ event: ConnEvent)
        -> (ConnState, ConnEffect)
    {
        switch (state, event) {
        case (.disconnected, .connectRequested):
            return (.connecting, .startConnect)
        case (.connecting, .connectSucceeded),
             (.reconnecting, .connectSucceeded):
            return (.connected, .none)
        case (.connecting, .connectFailed):
            return (.reconnecting(attempt: 0), .scheduleReconnect(attempt: 0))
        case (.reconnecting(let n), .connectFailed):
            return (.reconnecting(attempt: n + 1), .scheduleReconnect(attempt: n + 1))
        case (.connected, .streamBroken):
            return (.reconnecting(attempt: 0), .scheduleReconnect(attempt: 0))
        case (_, .stopRequested):
            return (.disconnected, .none)
        default:
            return (state, .none)  // 其餘組合為 no-op（冪等）
        }
    }
}
```

- [ ] **Step 4: 測試通過**

Run: `swift test --filter "BackoffTests|ConnectionStateMachineTests" 2>&1 | tail -3`
Expected: 10 tests passed。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Backoff.swift app/Sources/MirageCore/ConnectionStateMachine.swift app/Tests/MirageCoreTests/BackoffTests.swift app/Tests/MirageCoreTests/ConnectionStateMachineTests.swift
git commit -m "feat: 退避策略與連線純 reducer（TDD）"
```

---

### Task 4: DisplayTransport、GrpcStreamTransport 與 EmulatorClient（TDD + 活體煙霧）

**Files:**
- Create: `app/Sources/MirageCore/DisplayTransport.swift`
- Create: `app/Sources/MirageCore/GrpcStreamTransport.swift`
- Create: `app/Sources/MirageCore/EmulatorClient.swift`
- Test: `app/Tests/MirageCoreTests/EmulatorClientReconnectTests.swift`

**Interfaces:**
- Consumes: Task 2 `FramePump`/`LatestFrameBox`、Task 3 reducer/backoff、Generated stubs。
- Produces:
  - `protocol DisplayTransport: Sendable { func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> }`
  - `EmulatorClient`（actor）——`init(host: String = "localhost", port: Int = 8554, makeTransport: @escaping @Sendable (GrpcChannelBox) -> DisplayTransport = { GrpcStreamTransport(channel: $0) }, backoff: BackoffPolicy = .init(), sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }, randomSource: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) })`
  - `func start(box: LatestFrameBox, width: Int, height: Int) async`（連線→掛串流→斷線自動退避重連，直到 `stop()`）
  - `func setStreamSize(width: Int, height: Int) async`（重開串流）
  - `func stop() async`
  - `func sendTap(x: Int, y: Int, down: Bool) async`
  - `nonisolated let states: AsyncStream<ConnState>`（UI 訂閱）
  - `GrpcChannelBox`：包 `GRPCChannel` + `EmulatorControllerAsyncClient` 的薄容器（讓 transport 與輸入共用連線；測試不需真連線即可注入 makeTransport）。
- 註：型別前綴 `Android_Emulation_Control_` 以 Generated 內實際為準。

- [ ] **Step 1: 失敗測試（MockTransport 注入重連行為）**

```swift
// app/Tests/MirageCoreTests/EmulatorClientReconnectTests.swift
import XCTest
@testable import MirageCore

/// 可腳本化的假 transport：第 n 次訂閱時照劇本回放（幀 / 錯誤 / 永掛）。
final class MockTransport: DisplayTransport, @unchecked Sendable {
    enum Script { case yieldThenFail(UInt8), yieldThenHang(UInt8) }
    private let lock = NSLock()
    private var scripts: [Script]
    private(set) var subscribeCount = 0

    init(_ scripts: [Script]) { self.scripts = scripts }

    func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        lock.lock()
        subscribeCount += 1
        let script = scripts.isEmpty ? .yieldThenHang(99) : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { cont in
            let f = Frame(width: 1, height: 1, rgba: Data([0, 0, 0, 0]))
            switch script {
            case .yieldThenFail(let tag):
                cont.yield(Frame(width: 1, height: 1, rgba: Data([tag, 0, 0, 0])))
                struct StreamDied: Error {}
                cont.finish(throwing: StreamDied())
            case .yieldThenHang(let tag):
                cont.yield(Frame(width: 1, height: 1, rgba: Data([tag, 0, 0, 0])))
                _ = f  // 不 finish：模擬健康串流持續中
            }
        }
    }
}

final class EmulatorClientReconnectTests: XCTestCase {
    func testStreamFailureResubscribesWithBackoff() async throws {
        let mock = MockTransport([.yieldThenFail(1), .yieldThenHang(2)])
        let box = LatestFrameBox()
        var sleeps: [Duration] = []
        let sleepRecorder = SleepRecorder()
        let client = EmulatorClient(
            makeTransport: { _ in mock },
            sleeper: { d in await sleepRecorder.record(d) },  // 假時鐘：不真睡
            randomSource: { 0.5 }
        )
        await client.start(box: box, width: 540, height: 1200)
        try await Task.sleep(for: .milliseconds(500))  // 讓重連迴圈跑完
        XCTAssertEqual(mock.subscribeCount, 2)          // 失敗後重掛了
        sleeps = await sleepRecorder.all
        XCTAssertEqual(sleeps.first, .milliseconds(500)) // attempt 0、random 0.5
        XCTAssertEqual(box.takeLatest()?.rgba.first, 2)  // 第二源的幀進了 box
        await client.stop()
    }

    func testStatesPublishesTransitions() async throws {
        let mock = MockTransport([.yieldThenHang(1)])
        let client = EmulatorClient(
            makeTransport: { _ in mock },
            sleeper: { _ in },
            randomSource: { 0.5 }
        )
        var seen: [ConnState] = []
        let statesTask = Task {
            for await s in client.states { seen.append(s); if s == .connected { break } }
        }
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        _ = await statesTask.value
        XCTAssertEqual(seen.suffix(2), [.connecting, .connected])
        await client.stop()
    }
}

actor SleepRecorder {
    var all: [Duration] = []
    func record(_ d: Duration) { all.append(d) }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `swift test --filter EmulatorClientReconnectTests 2>&1 | tail -3`
Expected: 編譯失敗。

- [ ] **Step 3: 實作三檔**

```swift
// app/Sources/MirageCore/DisplayTransport.swift
import Foundation

public protocol DisplayTransport: Sendable {
    func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error>
}

public enum TransportError: Error, Equatable {
    case unavailable(String)      // 可重連（UNAVAILABLE 等）
    case invalidRequest(String)   // fail fast，不重連
}
```

```swift
// app/Sources/MirageCore/GrpcStreamTransport.swift
import Foundation
import GRPC
import NIOCore
import NIOPosix

/// 共用 gRPC 連線容器：transport 與輸入注入共用一條 channel。
public final class GrpcChannelBox: @unchecked Sendable {
    public let group: EventLoopGroup
    public let client: Android_Emulation_Control_EmulatorControllerAsyncClient

    public init(host: String, port: Int) throws {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try GRPCChannelPool.with(
            target: .host(host, port: port),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        ) {
            $0.maximumReceiveMessageLength = 16 * 1024 * 1024
        }
        client = Android_Emulation_Control_EmulatorControllerAsyncClient(channel: channel)
    }

    deinit { try? group.syncShutdownGracefully() }
}

public struct GrpcStreamTransport: DisplayTransport {
    private let channel: GrpcChannelBox

    public init(channel: GrpcChannelBox) { self.channel = channel }

    public func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        format.width = UInt32(width)
        format.height = UInt32(height)
        let call = channel.client.streamScreenshot(format)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await img in call {
                        continuation.yield(Frame(
                            width: Int(img.format.width),
                            height: Int(img.format.height),
                            rgba: img.image))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

```swift
// app/Sources/MirageCore/EmulatorClient.swift
import Foundation

/// 門面 actor：連線生命週期（reducer 驅動）、串流掛載、輸入注入、狀態發布。
public actor EmulatorClient {
    private let host: String
    private let port: Int
    private let makeTransport: @Sendable (GrpcChannelBox) -> DisplayTransport
    private let backoff: BackoffPolicy
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let randomSource: @Sendable () -> Double

    private var state: ConnState = .disconnected
    private var channelBox: GrpcChannelBox?
    private var transport: DisplayTransport?
    private let pump = FramePump()
    private var box: LatestFrameBox?
    private var streamSize = (w: 540, h: 1200)
    private var running = false

    public nonisolated let states: AsyncStream<ConnState>
    private let stateCont: AsyncStream<ConnState>.Continuation

    public init(host: String = "localhost", port: Int = 8554,
                makeTransport: @escaping @Sendable (GrpcChannelBox) -> DisplayTransport
                    = { GrpcStreamTransport(channel: $0) },
                backoff: BackoffPolicy = .init(),
                sleeper: @escaping @Sendable (Duration) async throws -> Void
                    = { try await Task.sleep(for: $0) },
                randomSource: @escaping @Sendable () -> Double
                    = { Double.random(in: 0..<1) }) {
        self.host = host
        self.port = port
        self.makeTransport = makeTransport
        self.backoff = backoff
        self.sleeper = sleeper
        self.randomSource = randomSource
        (states, stateCont) = AsyncStream.makeStream(of: ConnState.self)
    }

    public func start(box: LatestFrameBox, width: Int, height: Int) async {
        self.box = box
        streamSize = (width, height)
        running = true
        await apply(.connectRequested)
    }

    public func setStreamSize(width: Int, height: Int) async {
        streamSize = (width, height)
        if state == .connected { attachStream() }
    }

    public func stop() async {
        running = false
        await pump.detach()
        await apply(.stopRequested)
    }

    public func sendTap(x: Int, y: Int, down: Bool) async {
        guard let client = channelBox?.client else { return }
        var touch = Android_Emulation_Control_Touch()
        touch.x = Int32(x); touch.y = Int32(y)
        touch.identifier = 0
        touch.pressure = down ? 1024 : 0
        var event = Android_Emulation_Control_TouchEvent()
        event.touches = [touch]
        _ = try? await client.sendTouch(event)
    }

    // MARK: - reducer 驅動

    private func apply(_ event: ConnEvent) async {
        let (next, effect) = ConnReducer.reduce(state, event)
        state = next
        stateCont.yield(next)
        switch effect {
        case .startConnect:
            await doConnect()
        case .scheduleReconnect(let attempt):
            guard running else { return }
            let delay = backoff.delay(attempt: attempt, random: randomSource())
            try? await sleeper(delay)
            guard running else { return }
            await doConnect()
        case .none:
            break
        }
    }

    private func doConnect() async {
        do {
            if transport == nil {
                // 測試路徑：makeTransport 可完全忽略 channelBox；
                // 生產路徑：建 channel 供 transport 與輸入共用。
                let boxCh = try GrpcChannelBox(host: host, port: port)
                channelBox = boxCh
                transport = makeTransport(boxCh)
            }
            await apply(.connectSucceeded)
            attachStream()
        } catch {
            await apply(.connectFailed)
        }
    }

    private func attachStream() {
        guard let transport, let box else { return }
        let stream = transport.frames(width: streamSize.w, height: streamSize.h)
        Task {
            await pump.attach(stream, into: box) { [weak self] err in
                guard err != nil else { return }  // 正常結束（換源）不觸發重連
                Task { await self?.streamBroke() }
            }
        }
    }

    private func streamBroke() async {
        guard running else { return }
        await apply(.streamBroken)
    }
}
```

註：測試用 `makeTransport` 注入 mock 時，`GrpcChannelBox` 仍會嘗試真連線——測試環境
localhost:8554 無服務也能成功建 channel（gRPC 連線是惰性的，首次 RPC 才失敗），
所以 mock 測試不需要模擬器。若實測發現 channel 建立即失敗，把 `doConnect` 的
channel 建立包在 `transport == nil` 且 makeTransport 非預設時跳過（實作者依實況
最小調整並記錄）。

- [ ] **Step 4: 單元測試通過**

Run: `swift test 2>&1 | tail -3`
Expected: 全部通過（累計 19 tests）。

- [ ] **Step 5: 活體煙霧（模擬器執行中）**

前置：`phase0/scripts/02_boot_headless.sh`（背景）+ `03_wait_boot.sh`。

臨時把 `app/Sources/MirageApp/MirageApp.swift` 的 body 換成煙霧腳本不划算——
直接寫一個 XCTest 整合測試（預設 skip，環境變數開啟）：

```swift
// 附加到 EmulatorClientReconnectTests.swift 底部
final class LiveSmokeTests: XCTestCase {
    func testLiveStreamDeliversFrames() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1",
                          "需要活模擬器：MIRAGE_LIVE=1 swift test --filter LiveSmokeTests")
        let box = LatestFrameBox()
        let client = EmulatorClient()
        await client.start(box: box, width: 540, height: 1200)
        try await Task.sleep(for: .seconds(3))
        // 戳一下讓 change-driven 串流出幀
        await client.sendTap(x: 540, y: 1200, down: true)
        await client.sendTap(x: 540, y: 1200, down: false)
        try await Task.sleep(for: .seconds(2))
        let frame = box.takeLatest()
        XCTAssertNotNil(frame, "5 秒內應收到至少一幀")
        XCTAssertEqual(frame?.width, 540)
        await client.stop()
    }
}
```

Run: `MIRAGE_LIVE=1 swift test --filter LiveSmokeTests 2>&1 | tail -3`
Expected: 1 test passed（幀尺寸 540 寬）。

- [ ] **Step 6: Commit**

```bash
git add app/Sources/MirageCore/DisplayTransport.swift app/Sources/MirageCore/GrpcStreamTransport.swift app/Sources/MirageCore/EmulatorClient.swift app/Tests/MirageCoreTests/EmulatorClientReconnectTests.swift
git commit -m "feat: transport 抽象、gRPC 串流實作與重連門面（TDD+活體煙霧）"
```

---

### Task 5: UnaryMmapTransport 與版本閘（TDD）

**Files:**
- Create: `app/Sources/MirageCore/UnaryMmapTransport.swift`
- Test: `app/Tests/MirageCoreTests/MmapVersionGateTests.swift`

**Interfaces:**
- Consumes: `DisplayTransport`、`Frame`、`GrpcChannelBox`。
- Produces: `MmapVersionGate.allows(versionString: String) -> Bool`（純函式：主版號 ≥37 才 true）；`UnaryMmapTransport(channel: GrpcChannelBox, versionString: String, pollHz: Int = 60)`——`frames()` 在版本閘不過時立即 finish(throwing: TransportError.invalidRequest)。**安全鐵則**：任何路徑不得在版本 <37 時送出帶 MMAP 的請求（穩定版 emulator 會 SIGSEGV，phase0/RESULTS-0b.md）。

- [ ] **Step 1: 失敗測試**

```swift
// app/Tests/MirageCoreTests/MmapVersionGateTests.swift
import XCTest
@testable import MirageCore

final class MmapVersionGateTests: XCTestCase {
    func testRejectsStable36() {
        XCTAssertFalse(MmapVersionGate.allows(versionString: "36.6.11.0"))
    }

    func testAcceptsCanary37() {
        XCTAssertTrue(MmapVersionGate.allows(versionString: "37.2.1.0"))
    }

    func testAcceptsFuture38() {
        XCTAssertTrue(MmapVersionGate.allows(versionString: "38.0.0"))
    }

    func testRejectsGarbage() {
        XCTAssertFalse(MmapVersionGate.allows(versionString: ""))
        XCTAssertFalse(MmapVersionGate.allows(versionString: "abc"))
        XCTAssertFalse(MmapVersionGate.allows(versionString: "unknown.1"))
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `swift test --filter MmapVersionGateTests 2>&1 | tail -3`
Expected: 編譯失敗。

- [ ] **Step 3: 實作**

```swift
// app/Sources/MirageCore/UnaryMmapTransport.swift
import Foundation

/// MMAP 版本安全閘：穩定版 emulator（36.x）收到 MMAP 請求會 SIGSEGV
/// （phase0/RESULTS-0b.md），主版號 ≥37 才允許。解析失敗一律拒絕。
public enum MmapVersionGate {
    public static func allows(versionString: String) -> Bool {
        guard let major = versionString.split(separator: ".").first,
              let n = Int(major) else { return false }
        return n >= 37
    }
}

/// 實驗性傳輸：輪詢 unary getScreenshot + MMAP 檔案（零拷貝資料面）。
/// 僅 MIRAGE_TRANSPORT=unary-mmap 時由 App 層選用；預設不啟用。
public struct UnaryMmapTransport: DisplayTransport {
    private let channel: GrpcChannelBox
    private let versionString: String
    private let pollHz: Int

    public init(channel: GrpcChannelBox, versionString: String, pollHz: Int = 60) {
        self.channel = channel
        self.versionString = versionString
        self.pollHz = pollHz
    }

    public func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        guard MmapVersionGate.allows(versionString: versionString) else {
            return AsyncThrowingStream { cont in
                cont.finish(throwing: TransportError.invalidRequest(
                    "emulator \(versionString) 不支援 MMAP（<37 會崩潰），拒絕啟用"))
            }
        }
        let size = width * height * 4
        let path = NSTemporaryDirectory() + "mirage_mmap_\(width)x\(height).bin"
        let intervalNs = UInt64(1_000_000_000 / max(pollHz, 1))
        let client = channel.client
        return AsyncThrowingStream { continuation in
            let task = Task {
                FileManager.default.createFile(atPath: path, contents: Data(count: size))
                var format = Android_Emulation_Control_ImageFormat()
                format.format = .rgba8888
                format.width = UInt32(width)
                format.height = UInt32(height)
                var transport = Android_Emulation_Control_ImageTransport()
                transport.channel = .mmap
                transport.handle = "file://\(path)"
                format.transport = transport
                do {
                    while !Task.isCancelled {
                        _ = try await client.getScreenshot(format)
                        guard let data = FileManager.default.contents(atPath: path),
                              data.count == size else {
                            throw TransportError.unavailable("mmap 檔讀取失敗")
                        }
                        continuation.yield(Frame(width: width, height: height, rgba: data))
                        try await Task.sleep(nanoseconds: intervalNs)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

- [ ] **Step 4: 測試通過 + 活體煙霧（canary 環境，選跑）**

Run: `swift test --filter MmapVersionGateTests 2>&1 | tail -3` → 4 passed。
活體（模擬器為 canary 37.2.1.0 時才跑）：在 `LiveSmokeTests` 加：

```swift
    func testLiveUnaryMmapDeliversFrames() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIRAGE_LIVE_MMAP"] == "1",
                          "需要 canary 模擬器：MIRAGE_LIVE_MMAP=1")
        let chBox = try GrpcChannelBox(host: "localhost", port: 8554)
        let status = try await chBox.client.getStatus(Google_Protobuf_Empty())
        let transport = UnaryMmapTransport(channel: chBox,
                                           versionString: status.version)
        let box = LatestFrameBox()
        let pump = FramePump()
        await pump.attach(transport.frames(width: 540, height: 1200),
                          into: box, onEnd: { _ in })
        try await Task.sleep(for: .seconds(2))
        XCTAssertNotNil(box.takeLatest())
        await pump.detach()
    }
```

Run: `MIRAGE_LIVE_MMAP=1 swift test --filter LiveSmokeTests/testLiveUnaryMmapDeliversFrames 2>&1 | tail -3`
Expected: passed（`status.version` 欄位名以 Generated 為準，不符時最小修正並記錄）。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/UnaryMmapTransport.swift app/Tests/MirageCoreTests/MmapVersionGateTests.swift app/Tests/MirageCoreTests/EmulatorClientReconnectTests.swift
git commit -m "feat: unary-mmap 實驗傳輸與版本安全閘（TDD）"
```

---

### Task 6: MirageApp——SwiftUI 殼、MTKView vsync 拉取渲染

**Files:**
- Modify: `app/Sources/MirageApp/MirageApp.swift`（換正式版）
- Create: `app/Sources/MirageApp/MirrorView.swift`
- Create: `app/Sources/MirageApp/Renderer.swift`
- Create: `app/Sources/MirageApp/ConnectionBanner.swift`

**Interfaces:**
- Consumes: `EmulatorClient`（start/stop/setStreamSize/sendTap/states）、`LatestFrameBox.takeLatest()`。
- Produces: 可執行的 Mirage App——540p 串流視窗、滑鼠直通、連線狀態 banner、resize debounce 重開串流、`MIRAGE_FPS_LOG=1` 時每秒印 `[app] fps=N`（驗收量測用）。

- [ ] **Step 1: Renderer**

```swift
// app/Sources/MirageApp/Renderer.swift
import Foundation
import MetalKit
import MirageCore

/// vsync 拉取渲染：每次 draw 從 box 同步拉最新幀，replaceRegion 上傳後 blit。
final class Renderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let box: LatestFrameBox
    private var texture: MTLTexture?
    private var fpsCount = 0
    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()
    private let fpsLog = ProcessInfo.processInfo.environment["MIRAGE_FPS_LOG"] == "1"

    init?(view: MTKView, box: LatestFrameBox) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.box = box
        super.init()
        view.device = device
        view.colorPixelFormat = .rgba8Unorm
        view.framebufferOnly = false
        view.isPaused = false                  // 內建 display link 驅動
        view.enableSetNeedsDisplay = false     // 每 vsync 呼叫 draw（勿走 needsDisplay 路徑）
        view.preferredFramesPerSecond = 60
        view.delegate = self
    }

    func draw(in view: MTKView) {
        if let frame = box.takeLatest() { upload(frame, into: view) }
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

    private func upload(_ frame: Frame, into view: MTKView) {
        if texture?.width != frame.width || texture?.height != frame.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: frame.width, height: frame.height, mipmapped: false)
            desc.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: desc)
            let size = CGSize(width: frame.width, height: frame.height)
            view.drawableSize = size
            view.window?.contentAspectRatio = NSSize(width: frame.width,
                                                     height: frame.height)
        }
        frame.rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture?.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                             mipmapLevel: 0, withBytes: base,
                             bytesPerRow: frame.width * 4)
        }
        if fpsLog {
            fpsCount += 1
            let now = CFAbsoluteTimeGetCurrent()
            if now - fpsWindowStart >= 1.0 {
                print("[app] fps=\(fpsCount)")
                fpsCount = 0
                fpsWindowStart = now
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
```

- [ ] **Step 2: MirrorView（Representable + 滑鼠直通 + resize debounce）**

```swift
// app/Sources/MirageApp/MirrorView.swift
import AppKit
import MetalKit
import MirageCore
import SwiftUI

/// MTKView 子類：滑鼠事件 → 正規化座標 → guest 觸控。
final class MirrorMTKView: MTKView {
    var onMouse: ((_ nx: Double, _ ny: Double, _ down: Bool) -> Void)?
    var onResize: ((_ pixelSize: CGSize) -> Void)?

    override func layout() {
        super.layout()
        onResize?(convertToBacking(bounds).size)
    }

    private func normalized(_ event: NSEvent) -> (Double, Double)? {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let nx = Double(p.x / bounds.width)
        let ny = 1.0 - Double(p.y / bounds.height)
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

struct MirrorView: NSViewRepresentable {
    let client: EmulatorClient
    let box: LatestFrameBox

    func makeCoordinator() -> Coordinator { Coordinator(client: client) }

    func makeNSView(context: Context) -> MirrorMTKView {
        let view = MirrorMTKView(frame: .zero)
        context.coordinator.renderer = Renderer(view: view, box: box)
        view.onMouse = { nx, ny, down in
            context.coordinator.sendMouse(nx: nx, ny: ny, down: down)
        }
        view.onResize = { pixelSize in
            context.coordinator.resizeDebounced(to: pixelSize)
        }
        return view
    }

    func updateNSView(_ view: MirrorMTKView, context: Context) {}

    @MainActor
    final class Coordinator {
        let client: EmulatorClient
        var renderer: Renderer?
        private var resizeTask: Task<Void, Never>?
        private var guestSize = (w: 540, h: 1200)

        init(client: EmulatorClient) { self.client = client }

        func sendMouse(nx: Double, ny: Double, down: Bool) {
            let gx = Int(nx * Double(guestSize.w))
            let gy = Int(ny * Double(guestSize.h))
            Task { await client.sendTap(x: gx, y: gy, down: down) }
        }

        func resizeDebounced(to pixelSize: CGSize) {
            resizeTask?.cancel()
            resizeTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                // guest 長寬比 9:20 固定；以視窗像素寬換算串流尺寸（偶數對齊）
                let w = max(Int(pixelSize.width) & ~1, 270)
                let h = w * 20 / 9
                guestSize = (w, h)
                await client.setStreamSize(width: w, height: h)
            }
        }
    }
}
```

- [ ] **Step 3: App 進入點與 banner**

```swift
// app/Sources/MirageApp/ConnectionBanner.swift
import MirageCore
import SwiftUI

struct ConnectionBanner: View {
    let state: ConnState

    var body: some View {
        switch state {
        case .connected:
            EmptyView()
        case .connecting:
            label("連線中…", .yellow)
        case .reconnecting(let n):
            label("重新連線中（第 \(n + 1) 次）…", .orange)
        case .disconnected:
            label("未連線", .red)
        }
    }

    private func label(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.callout.bold())
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(color.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
            .padding(.top, 8)
    }
}
```

```swift
// app/Sources/MirageApp/MirageApp.swift（正式版，整檔取代）
import MirageCore
import SwiftUI

@main
struct MirageApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Mirage") {
            ZStack(alignment: .top) {
                MirrorView(client: model.client, box: model.box)
                ConnectionBanner(state: model.connState)
            }
            .frame(minWidth: 270, minHeight: 600)
            .task { await model.start() }
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let client = EmulatorClient()
    let box = LatestFrameBox()
    var connState: ConnState = .disconnected

    func start() async {
        Task { [client] in
            for await s in client.states {
                await MainActor.run { self.connState = s }
            }
        }
        await client.start(box: box, width: 540, height: 1200)
    }
}
```

- [ ] **Step 4: 建置與活體驗證**

Run: `swift build -c release 2>&1 | tail -2` → Build complete、零警告。
活體（模擬器執行中 + `cd ../phase0/harness && python animate.py --seconds 30` 背景）：

```bash
MIRAGE_FPS_LOG=1 ./.build/release/MirageApp > /tmp/mirage_app_fps.log 2>&1 &
sleep 20 && pkill -f release/MirageApp
grep "\[app\] fps=" /tmp/mirage_app_fps.log | tail -10
```

Expected: 持續的 `[app] fps=N` 行，N 在 540p 下 ≥50（驗收量測在 Task 8 正式做；此處為煙霧）。視窗會出現在桌面。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageApp
git commit -m "feat: mirage app 殼——vsync 拉取渲染、滑鼠直通、狀態 banner、resize debounce"
```

---

### Task 7: 斷線重連與 resize 整合驗證

**Files:**
- （無新產品碼——整合驗證任務；證據進報告）
- Create: `app/scripts/verify_reconnect.sh`（可重複執行的驗證腳本）

**Interfaces:**
- Consumes: Task 6 的 App、phase0 腳本。
- Produces: 重連驗收證據（spec §7 驗收 2）。

- [ ] **Step 1: 驗證腳本**

```bash
#!/usr/bin/env bash
# app/scripts/verify_reconnect.sh
# 驗收 2：殺掉模擬器後重啟，App 10 秒內自動恢復畫面。
# 前置：模擬器執行中、App 未執行。輸出 PASS/FAIL 與時間線。
set -euo pipefail
cd "$(dirname "$0")/../.."
LOG=/tmp/mirage_reconnect_test.log

MIRAGE_FPS_LOG=1 ./app/.build/release/MirageApp > "$LOG" 2>&1 &
APP_PID=$!
sleep 8
echo "[test] baseline: $(grep -c 'fps=' "$LOG" || true) fps lines"

echo "[test] killing emulator..."
pkill -f qemu-system || true
sleep 3

echo "[test] rebooting emulator..."
phase0/scripts/02_boot_headless.sh > /tmp/mirage_reboot.log 2>&1 &
phase0/scripts/03_wait_boot.sh
BOOT_DONE=$(date +%s)

# 開機完成後量測 10 秒內是否恢復出幀
BEFORE=$(grep -c 'fps=' "$LOG" || true)
RECOVERED=""
for i in $(seq 1 10); do
  sleep 1
  NOW=$(grep -c 'fps=' "$LOG" || true)
  if [ "$NOW" -gt "$BEFORE" ]; then
    RECOVERED=$((​$(date +%s) - BOOT_DONE))
    break
  fi
done
kill "$APP_PID" 2>/dev/null || true

if [ -n "$RECOVERED" ]; then
  echo "[test] PASS: 開機完成後 ${RECOVERED}s 恢復出幀"
else
  echo "[test] FAIL: 10 秒內未恢復"
  exit 1
fi
```

註：腳本中 `$((​...))` 若有排版問題以 `RECOVERED=$(( $(date +%s) - BOOT_DONE ))` 為準。

- [ ] **Step 2: 執行驗證（配 animate 動畫源讓恢復可觀察）**

Run:

```bash
chmod +x app/scripts/verify_reconnect.sh
# 終端 B（開機後）: cd phase0/harness && source .venv/bin/activate && python animate.py --seconds 90
app/scripts/verify_reconnect.sh
```

Expected: `[test] PASS: 開機完成後 Ns 恢復出幀`（N ≤ 10）。若 FAIL：檢查 App log 的
狀態轉移（應見 reconnecting 序列），依 systematic-debugging 找根因，禁止調大門檻。

- [ ] **Step 3: resize 行為手動腳本化驗證**

Run（App 執行中）: 用 AppleScript 改視窗尺寸觸發 debounce：

```bash
osascript -e 'tell application "System Events" to tell process "MirageApp" to set size of front window to {360, 800}' 2>/dev/null || echo "（無 Accessibility 權限時：人工拖拉視窗，觀察 log）"
sleep 2 && grep "fps=" /tmp/mirage_app_fps.log | tail -3
```

Expected: resize 後串流以新尺寸重開（fps 行持續；若加了尺寸 log 則見新尺寸）。無權限時記 pending-human。

- [ ] **Step 4: Commit**

```bash
git add app/scripts/verify_reconnect.sh
git commit -m "feat: 重連驗收腳本與整合驗證"
```

---

### Task 8: 驗收量測、覆蓋率與文件

**Files:**
- Create: `app/RESULTS-p1a.md`
- Modify: `phase0/README.md`（尾部加一行指向 app/）
- Create: `app/README.md`

**Interfaces:**
- Consumes: Task 1-7 全部交付物。
- Produces: P1-a 出貨判定（spec §7 五條驗收線逐條裁決）。

- [ ] **Step 1: 驗收量測（乾淨主機紀律：先 `uptime`，load < 8 才量）**

```bash
# 1) fps 驗收：540p、Release、animate 源、量 30 秒
uptime
phase0/scripts/02_boot_headless.sh &  # 若未在跑
phase0/scripts/03_wait_boot.sh
cd phase0/harness && source .venv/bin/activate && (python animate.py --seconds 45 &) && cd ../..
MIRAGE_FPS_LOG=1 ./app/.build/release/MirageApp > /tmp/mirage_acceptance_fps.log 2>&1 &
sleep 35 && pkill -f release/MirageApp
# p5 計算：取 30 個 fps 樣本排序後第 2 個（≈p5）
grep -o 'fps=[0-9]*' /tmp/mirage_acceptance_fps.log | cut -d= -f2 | sort -n | head -3

# 2) e2e 迴歸（harness 既有工具）
cd phase0/harness && ~/Library/Android/sdk/platform-tools/adb shell settings put system show_touches 1 && python e2e_latency.py && ~/Library/Android/sdk/platform-tools/adb shell settings put system show_touches 0 && cd ../..

# 3) CPU 佔用（App 執行中量 10 秒平均）
MIRAGE_FPS_LOG=1 ./app/.build/release/MirageApp > /dev/null 2>&1 &
sleep 5 && ps -o %cpu= -p $(pgrep -f release/MirageApp) && sleep 5 && ps -o %cpu= -p $(pgrep -f release/MirageApp) && pkill -f release/MirageApp

# 4) 覆蓋率
cd app && swift test --enable-code-coverage 2>&1 | tail -2
xcrun llvm-cov report .build/debug/MiragePackageTests.xctest/Contents/MacOS/MiragePackageTests -instr-profile .build/debug/codecov/default.profdata -ignore-filename-regex "Generated|Tests" 2>/dev/null | tail -5
```

- [ ] **Step 2: RESULTS-p1a.md（照 spec §7 五條逐條填實測）**

```markdown
# P1-a 驗收結果（日期：____；host load：____；emulator：____）

| # | 驗收線（spec §7） | 實測 | 判定 |
|---|---|---|---|
| 1 | 540p 30s p5 幀率 ≥55 | fps 樣本 p5 = ___ | ⬜ |
| 2 | 殺模擬器→重啟→10s 內恢復 | verify_reconnect.sh: ___s | ⬜ |
| 3 | e2e p50 ≤ 基線(40.7ms)+10% | ___ms | ⬜ |
| 4 | 測試全綠、覆蓋 ≥80%、release 零警告 | ___ tests / ___% / 警告 ___ | ⬜ |
| 5 | CPU 佔用記錄（目標 <50% 單核當量） | ___% / ___%（兩次取樣） | ⬜ |

## 判定
- [ ] P1-a 出貨 → 開 P1-b/P1-c
- [ ] 未達標項與處置：____

## 觀察與備註
（drop/rejected 計數、resize 行為、任何 deviation……）
```

- [ ] **Step 3: app/README.md**

```markdown
# Mirage App（P1-a）

產品殼與顯示管線。建置：`cd app && swift build -c release`。
執行：先啟動模擬器（`phase0/scripts/02_boot_headless.sh` + `03_wait_boot.sh`），
再 `./.build/release/MirageApp`。

- `MIRAGE_FPS_LOG=1`：每秒印 `[app] fps=N`（量測用）
- `MIRAGE_TRANSPORT=unary-mmap`：實驗傳輸（僅 canary emulator ≥37；穩定版會被版本閘拒絕）
- 測試：`swift test`；活體整合：`MIRAGE_LIVE=1 swift test --filter LiveSmokeTests`
- 驗收紀錄：`RESULTS-p1a.md`；重連驗證：`scripts/verify_reconnect.sh`

架構詳見 `../docs/specs/2026-07-23-p1a-display-shell-design.md`。
```

`phase0/README.md` 尾部加：

```markdown
## 後續
Phase 1 產品程式碼在 `../app/`（P1-a 起）；本目錄保留為量測 harness 與歷史紀錄。
```

- [ ] **Step 4: 填實數、判定、Commit**

```bash
git add app/RESULTS-p1a.md app/README.md phase0/README.md
git commit -m "docs: p1a 驗收結果與使用文件"
```

---

## Self-Review 紀錄

- **Spec 覆蓋**：§3 結構=Task 1/6；§4.1 FramePump/信箱=Task 2（實作細化：actor 管生命週期+鎖保護單格信箱供同步 vsync 拉取，對應 spec §8 預留的整合細節）；§4.2 transport+resize+版本閘=Task 4/5/6；§4.3 狀態機=Task 3/4；§5 錯誤處理=各實作（TransportError 分類、box 計數、renderer 跳幀）；§6 測試=Task 2-5 單元+Task 4/7 整合；§7 驗收五條=Task 8 逐條。§4.2 全螢幕切原生解析度：**併入 Task 6 resize 機制的自然結果**（全螢幕即最大視窗尺寸），原生解析度特化與 120fps 留待 P3——記為有意識的範圍決定，非遺漏。
- **佔位掃描**：無 TBD；RESULTS-p1a 的 `___` 為待填實測值（專案慣例）；「欄位名以 Generated 為準」為版本差異防呆非佔位。
- **型別一致性**：`Frame(width:height:rgba:)`/`isValid` 貫穿；`LatestFrameBox.put/takeLatest/stats` Task 2 定義、4/6 使用；`FramePump.attach(_:into:onEnd:)/detach` Task 2=4=5；`ConnState/.reconnecting(attempt:)`、`ConnReducer.reduce` Task 3=4=6（banner）；`DisplayTransport.frames(width:height:)` Task 4=5=Mock；`EmulatorClient.start(box:width:height:)/setStreamSize/stop/sendTap/states` Task 4=6=7。
- **教訓內建**：POC 的 MainActor 收幀瓶頸（收幀完全脫離 UI）、斷線凍結（狀態機+驗收 2）、MMAP 崩潰（版本閘+測試）、量測紀律（Task 8 步驟自帶 uptime/Release/animate）。




