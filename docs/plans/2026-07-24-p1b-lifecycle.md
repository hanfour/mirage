# P1-b 生命週期與系統整合（核心 + 剪貼簿）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 依 `docs/specs/2026-07-24-p1b-lifecycle-design.md`，把 P1-a 的「能連能重連」升級為可信生命週期——真實健康探測（修 P1-a 終審缺口）、gRPC 層快照休眠/喚醒、選單列常駐、雙向剪貼簿。

**Architecture:** 純邏輯與膠水嚴格分離。MirageCore 新增 `Lifecycle/`：`HealthProbe`（getStatus 探測 protocol，可注入假探測）、`PowerState`（純狀態機）、`ClipboardBridge`（防回音純函式）、`SnapshotService`（save/load gRPC 封裝）。`EmulatorClient` 的重連由**遞迴改迴圈**、加健康探測 gate、斷線時 drop 舊 channel 再重建。MirageApp 新增 `Lifecycle/`：選單列、剪貼簿輪詢、視窗關閉→休眠/喚醒/Cmd+Q teardown 膠水。

**Tech Stack:** Swift 6 工具鏈（語言模式 v5）、grpc-swift **exact 1.27.5**、swift-testing、AppKit（NSStatusItem/NSPasteboard）；快照需先以 grpc-swift 內附 `protoc-gen-grpc-swift` 產生 `SnapshotService` stub。

## Global Constraints

- 平台 macOS 14+ Apple Silicon；`swift build -c release` 零警告（不含測試 target 的 swift-testing deprecation 噪音，見 P1-a 計畫修正案 A §4）。
- **MirageCore 不得 import AppKit/SwiftUI/Metal**；不 `fatalError`。錯誤一律回傳/記錄，App 層決定呈現。
- 所有 target 開 `-strict-concurrency=complete`；`.swiftLanguageMode(.v5)`（Generated stubs 為 v1 grpc 碼）。
- **測試語法用 swift-testing**（`@Suite struct` / `@Test func` / `#expect` / `#require`）——與既有 7 個測試檔一致，非 XCTest。async 測試用 `@Test func x() async throws`；等待條件用輪詢迴圈（`for _ in 0..<N { if 條件 { break }; try await Task.sleep(...) }` 後 `#expect(條件)`）。
- 每檔 <400 行；函式 <50 行；不可變優先（回傳新值，不原地改）。
- TDD：先寫失敗測試 → 確認失敗 → 最小實作 → 綠 → commit。Conventional commits、無 attribution。
- MirageCore 覆蓋 ≥80%（`swift test --enable-code-coverage`）；既有 28 tests 不回歸。
- 活體測試預設 skip、環境變數開啟（沿用 P1-a `LiveSmokeTests` 慣例：`guard ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1" else { return }`）。
- 模擬器 headless 啟動：`phase0/scripts/02_boot_headless.sh` + `03_wait_boot.sh`；目前版本 canary 37.2.1.0。
- **健康探測不可拖慢恢復**（spec §8）：探測 timeout ~1s；不取代 GRPCChannelPool 內部重連，只「確認就緒並正確標記」。恢復時間不得回歸 P1-a 的 ~1s（`verify_reconnect.sh` 含 1MB 門檻）。
- **快照語意**（spec §8）：MVP 對執行中模擬器操作，非行程級休眠；「省 CPU」僅省 app 端串流/渲染，qemu 仍在跑。

## 既有介面契約（P1-a 已交付，本件依賴）

- `EmulatorClient`（actor）現況：`init(host:port:makeTransport:backoff:sleeper:randomSource:)`、`start(box:width:height:)`、`setStreamSize(width:height:)`、`stop()`、`sendTap(x:y:down:)`、`nonisolated let states: AsyncStream<ConnState>`。私有：`state`、`channelBox: GrpcChannelBox?`、`transport: DisplayTransport?`、`pump: FramePump`、`running: Bool`、`apply(_:)`、`doConnect()`、`attachStream()`、`streamBroke()`。**現況 `doConnect` 在 `transport == nil` 時才重建、且建 channel 就 `.connectSucceeded`（無探測）——本件要修的正是這裡。**
- `ConnReducer.reduce(_ state: ConnState, _ event: ConnEvent) -> (ConnState, ConnEffect)`（純函式，本件不改語意）。`ConnState: .disconnected/.connecting/.connected/.reconnecting(attempt:)`。
- `GrpcChannelBox`（`@unchecked Sendable`，`GrpcStreamTransport.swift` 內）：`init(host:port:) throws`、`let group: EventLoopGroup`、`let client: Android_Emulation_Control_EmulatorControllerAsyncClient`；`deinit` 呼叫 `group.syncShutdownGracefully()`。
- `FramePump`（actor）：`attach(_:into:onEnd:)`、`detach()`。`LatestFrameBox`：`put/takeLatest/stats`。
- App 層現況（`MirageApp.swift`）：`@main struct MirageApp`、`AppModel`（`@MainActor @Observable`，持 `client`/`box`/`connState`）、`AppDelegate`（`applicationWillTerminate` + semaphore + `model.shutdown()`，P1-a 已加的 NIO teardown drain）。
- Generated 可用 RPC（`Android_Emulation_Control_EmulatorControllerAsyncClient`）：`getStatus(_:) -> EmulatorStatus`（含 `version/uptime/booted`）、`setClipboard(_ ClipData)`、`getClipboard(_ Empty) -> ClipData`、`streamClipboard(_ Empty) -> stream ClipData`、`sendTouch/sendKey`。

## File Structure

```
app/Sources/MirageCore/Generated/
├── snapshot_service.grpc.swift     # Task 1 產生（SnapshotService async client）
├── snapshot_service.pb.swift       # Task 1 產生（SnapshotPackage 等訊息）
└── snapshot.pb.swift               # Task 1 產生（snapshot.proto 依賴）
app/Sources/MirageCore/Lifecycle/
├── HealthProbe.swift               # Task 2：getStatus 探測 protocol + 逾時（純介面，可注入）
├── PowerState.swift                # Task 4：active/suspending/suspended/waking 純狀態機
├── SnapshotService.swift           # Task 4：save/load("mirage_suspend") gRPC 封裝
└── ClipboardBridge.swift           # Task 5：防回音純函式
app/Sources/MirageCore/
└── EmulatorClient.swift            # Task 3/4/5 修改：健康探測 gate、重連迴圈、snapshot/clipboard 方法、電源
app/Sources/MirageApp/Lifecycle/
├── MenuBarController.swift         # Task 6：NSStatusItem（狀態/喚醒/顯示視窗/退出）
├── ClipboardWatcher.swift          # Task 6：NSPasteboard changeCount 輪詢
└── AppLifecycle.swift              # Task 6：視窗關閉→休眠、喚醒→load、Cmd+Q teardown
app/Sources/MirageApp/
└── MirageApp.swift                 # Task 6 修改：注入生命週期、選單列、剪貼簿
app/Tests/MirageCoreTests/
├── HealthProbeTests.swift          # Task 2
├── EmulatorClientReconnectTests.swift # Task 3 擴充（健康探測 gate 後的重連/attempt/banner 誠實）
├── PowerStateTests.swift           # Task 4
└── ClipboardBridgeTests.swift      # Task 5
app/scripts/
└── verify_snapshot.sh              # Task 4：快照 round-trip 活體驗證
app/RESULTS-p1b.md                  # Task 7
```

---

### Task 1: SnapshotService gRPC stub 產生（基礎設施前置）

**背景**：spec §4.2 的快照休眠需要 `SnapshotService.SaveSnapshot/LoadSnapshot`，但 `app/Sources/MirageCore/Generated/` 目前只有 `emulator_controller`。`snapshot_service.proto` 存在於 `~/Library/Android/sdk/emulator/lib/`，`protoc` + `protoc-gen-swift` 已裝，`protoc-gen-grpc-swift` 需從 grpc-swift 1.27.5 checkout build（版本自動匹配，避免與 `emulator_controller.grpc.swift` 的執行期不合）。

**Files:**
- Create: `app/Sources/MirageCore/Generated/snapshot_service.grpc.swift`（產生）
- Create: `app/Sources/MirageCore/Generated/snapshot_service.pb.swift`（產生）
- Create: `app/Sources/MirageCore/Generated/snapshot.pb.swift`（產生）
- Create: `app/scripts/gen_snapshot_stub.sh`（可重跑的產生腳本）

**Interfaces:**
- Produces: `Android_Emulation_Control_SnapshotServiceAsyncClient`（可用既有 `GRPCChannel` 建立）；`Android_Emulation_Control_SnapshotPackage`（`snapshotID: String`、`success: Bool`、`err: Data`、`format: .directory`）。後續 Task 4 的 `SnapshotService.swift` 封裝這些。

- [ ] **Step 1: 產生腳本**

```bash
# app/scripts/gen_snapshot_stub.sh
#!/usr/bin/env bash
# 產生 SnapshotService 的 Swift gRPC + message stub。
# 前置：protoc、protoc-gen-swift（brew）已裝；protoc-gen-grpc-swift 由 grpc-swift 1.27.5 build。
set -euo pipefail
cd "$(dirname "$0")/.."                       # → app/
SDK_LIB="$HOME/Library/Android/sdk/emulator/lib"
GEN="Sources/MirageCore/Generated"
PLUGIN_SRC=".build/checkouts/grpc-swift"

# 1) build 版本匹配的 grpc-swift protoc plugin（首次 ~1-2 分鐘）
swift build --package-path "$PLUGIN_SRC" --product protoc-gen-grpc-swift -c release
PLUGIN_BIN="$PLUGIN_SRC/.build/release/protoc-gen-grpc-swift"
test -x "$PLUGIN_BIN" || { echo "FAIL: protoc-gen-grpc-swift 未 build 出"; exit 1; }

# 2) 產生 message（.pb.swift）與 service（.grpc.swift）
protoc \
  --proto_path="$SDK_LIB" \
  --plugin=protoc-gen-grpc-swift="$PLUGIN_BIN" \
  --swift_opt=Visibility=Public \
  --swift_out="$GEN" \
  --grpc-swift_opt=Visibility=Public,Client=true,Server=false \
  --grpc-swift_out="$GEN" \
  "$SDK_LIB/snapshot_service.proto" "$SDK_LIB/snapshot.proto"

echo "OK: 產生於 $GEN/"
ls -1 "$GEN"/snapshot*.swift
```

- [ ] **Step 2: 執行產生並驗證編譯**

```bash
chmod +x app/scripts/gen_snapshot_stub.sh
app/scripts/gen_snapshot_stub.sh
cd app && swift build 2>&1 | tail -3
```

Expected: 產生 `snapshot_service.grpc.swift`、`snapshot_service.pb.swift`、`snapshot.pb.swift`；`swift build` 成功。

**若 `protoc-gen-grpc-swift` build 失敗或版本不合（fallback）**：改用手寫最小 client——僅需 `SaveSnapshot`/`LoadSnapshot` 兩個 unary RPC。以既有 `emulator_controller.grpc.swift` 的 `getStatus`（unary）為樣板，複製其 `GRPCAsyncUnaryCall` 呼叫結構，path 用 `/android.emulation.control.SnapshotService/SaveSnapshot`（與 `LoadSnapshot`），request/response 皆 `Android_Emulation_Control_SnapshotPackage`（此訊息型別仍由 `protoc-gen-swift` 產生，只有 message 不需 grpc plugin）。把手寫版放 `snapshot_service.grpc.swift` 並在檔頭註記為手寫 fallback。

- [ ] **Step 3: 冒煙——型別存在性測試（swift-testing）**

```swift
// app/Tests/MirageCoreTests/SnapshotStubSmokeTests.swift
import Testing
@testable import MirageCore

@Suite struct SnapshotStubSmokeTests {
    @Test func snapshotPackageFieldsExist() {
        var pkg = Android_Emulation_Control_SnapshotPackage()
        pkg.snapshotID = "mirage_suspend"
        pkg.format = .directory
        #expect(pkg.snapshotID == "mirage_suspend")
        #expect(pkg.format == .directory)
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd app && swift test --filter SnapshotStubSmokeTests 2>&1 | tail -3`
Expected: 1 test passed（欄位名 `snapshotID`/`format` 以產生結果為準；不符時依實際欄位最小修正並記錄）。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Generated/snapshot*.swift app/scripts/gen_snapshot_stub.sh app/Tests/MirageCoreTests/SnapshotStubSmokeTests.swift
git commit -m "feat: 產生 SnapshotService gRPC stub（快照休眠基礎設施）"
```

---

### Task 2: HealthProbe（getStatus 探測 + 逾時，TDD）

**Files:**
- Create: `app/Sources/MirageCore/Lifecycle/HealthProbe.swift`
- Test: `app/Tests/MirageCoreTests/HealthProbeTests.swift`

**Interfaces:**
- Consumes: 無（純介面 + 一個 gRPC 實作）。
- Produces:
  - `protocol HealthProbe: Sendable { func probe(timeout: Duration) async -> HealthResult }`
  - `enum HealthResult: Equatable, Sendable { case healthy, timedOut, failed }`
  - `struct GrpcHealthProbe: HealthProbe`——`init(client: Android_Emulation_Control_EmulatorControllerAsyncClient)`；`probe` 內以 `getStatus` + `withTimeout` 判定（`booted == true` → `.healthy`；逾時 → `.timedOut`；擲錯 → `.failed`）。
  - 供 Task 3 的 `EmulatorClient` 以 protocol 注入；測試用假探測驅動重連迴圈。

- [ ] **Step 1: 失敗測試**

```swift
// app/Tests/MirageCoreTests/HealthProbeTests.swift
import Testing
@testable import MirageCore

/// 可腳本化假探測：照劇本回放結果，記錄呼叫次數。
final class ScriptedProbe: HealthProbe, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [HealthResult]
    private(set) var calls = 0
    init(_ results: [HealthResult]) { self.results = results }
    func probe(timeout: Duration) async -> HealthResult {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return results.isEmpty ? .healthy : results.removeFirst()
    }
}

@Suite struct HealthProbeTests {
    @Test func scriptedProbeReplaysResults() async {
        let p = ScriptedProbe([.failed, .timedOut, .healthy])
        #expect(await p.probe(timeout: .seconds(1)) == .failed)
        #expect(await p.probe(timeout: .seconds(1)) == .timedOut)
        #expect(await p.probe(timeout: .seconds(1)) == .healthy)
        #expect(p.calls == 3)
    }

    @Test func healthResultIsEquatable() {
        #expect(HealthResult.healthy == .healthy)
        #expect(HealthResult.healthy != .failed)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter HealthProbeTests 2>&1 | tail -3`
Expected: 編譯失敗（`HealthProbe`/`HealthResult` 不存在）。

- [ ] **Step 3: 實作**

```swift
// app/Sources/MirageCore/Lifecycle/HealthProbe.swift
import Foundation
import GRPC

/// 健康探測結果：驅動連線 reducer 的 connectSucceeded / connectFailed。
public enum HealthResult: Equatable, Sendable {
    case healthy    // getStatus 回覆且 booted
    case timedOut   // 逾時未回覆
    case failed     // 回覆錯誤或未 booted
}

/// 探測抽象：以 protocol 注入，單元測試用假探測，不碰網路。
public protocol HealthProbe: Sendable {
    func probe(timeout: Duration) async -> HealthResult
}

/// 生產實作：呼叫 getStatus，逾時以 Task race 實作（不改 gRPC deadline，避免影響 pool）。
public struct GrpcHealthProbe: HealthProbe {
    private let client: Android_Emulation_Control_EmulatorControllerAsyncClient

    public init(client: Android_Emulation_Control_EmulatorControllerAsyncClient) {
        self.client = client
    }

    public func probe(timeout: Duration) async -> HealthResult {
        await withTaskGroup(of: HealthResult.self) { group in
            group.addTask {
                do {
                    let status = try await client.getStatus(.init())
                    return status.booted ? .healthy : .failed
                } catch {
                    return .failed
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return .timedOut
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            return first
        }
    }
}
```

- [ ] **Step 4: 測試通過**

Run: `cd app && swift test --filter HealthProbeTests 2>&1 | tail -3`
Expected: 2 tests passed。

- [ ] **Step 5: Commit**

```bash
git add app/Sources/MirageCore/Lifecycle/HealthProbe.swift app/Tests/MirageCoreTests/HealthProbeTests.swift
git commit -m "feat: HealthProbe 探測抽象與 gRPC 實作（TDD）"
```

---

### Task 3: 健康探測 gate + 重連迴圈重構（修 P1-a 終審缺口，TDD）

**背景**：P1-a 終審 Minor #7——`doConnect` 建了 channel 就 `.connectSucceeded`，斷線期間 banner 恆「已連線」、attempt 恆 0、重連遞迴堆積 async frame。本件把驅動由**遞迴改迴圈**、加健康探測 gate、斷線時 drop 舊 channel 再重建。**reducer 語意不變**（P1-c 依賴此），只改 effect 的執行方式。這是 spec §7 驗收 2 的核心。

**Files:**
- Modify: `app/Sources/MirageCore/EmulatorClient.swift`（整檔改寫——驅動結構大改）
- Modify: `app/Tests/MirageCoreTests/EmulatorClientReconnectTests.swift`（既有 2 測試改注入假探測 + 新增 3 測試）

**Interfaces:**
- Consumes: Task 2 `HealthProbe`/`HealthResult`；既有 `ConnReducer`/`GrpcChannelBox`/`FramePump`/`BackoffPolicy`。
- Produces（`EmulatorClient` 新簽名，供 Task 4/5/6 依賴）：
  - `init` 新增參數 `makeHealthProbe: @escaping @Sendable (GrpcChannelBox) -> HealthProbe = { GrpcHealthProbe(client: $0.client) }` 與 `probeTimeout: Duration = .seconds(1)`（其餘參數不變）。
  - 對外方法簽名不變：`start/setStreamSize/stop/sendTap/states`。
  - 新私有結構：長駐 `loopTask`、`runConnectionLoop()`、`connectedRun()`、`dropChannel()`、`ensureChannel()`；`apply` 拆為純轉移 `step(_:) -> ConnEffect`（不再遞迴驅動 IO）。

- [ ] **Step 1: 改既有 2 測試（注入假探測）+ 新增重連測試**

在 `EmulatorClientReconnectTests.swift`：既有 `testStreamFailureResubscribesWithBackoff` 與 `testStatesPublishesTransitions` 的 `EmulatorClient(...)` 都加 `makeHealthProbe: { _ in ScriptedProbe([]) }`（永遠 `.healthy`，`ScriptedProbe` 由 Task 2 引入）。然後新增：

```swift
// 附加到 EmulatorClientReconnectTests.swift（同檔已有 MockTransport/SleepRecorder）
@Suite struct EmulatorClientHealthGateTests {
    @Test func unhealthyProbeIncrementsAttemptThenConnects() async throws {
        // 探測劇本：失敗、逾時、健康 → 應走 reconnecting(0) → reconnecting(1) → connected
        let probe = ScriptedProbe([.failed, .timedOut, .healthy])
        let mock = MockTransport([.yieldThenHang(9)])
        let recorder = SleepRecorder()
        let client = EmulatorClient(
            makeTransport: { _ in mock },
            makeHealthProbe: { _ in probe },
            sleeper: { d in await recorder.record(d) },
            randomSource: { 0.5 }
        )
        var seen: [ConnState] = []
        let watch = Task { for await s in client.states { seen.append(s); if s == .connected { break } } }
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        _ = await watch.value
        // 真實經過 reconnecting，attempt 隨失敗遞增
        #expect(seen.contains(.reconnecting(attempt: 0)))
        #expect(seen.contains(.reconnecting(attempt: 1)))
        #expect(seen.last == .connected)
        #expect(probe.calls == 3)                      // 探測 3 次才健康
        let sleeps = await recorder.all
        #expect(sleeps.count == 2)                     // 2 次失敗 → 2 次 backoff sleep
        #expect(sleeps.first == .milliseconds(500))    // attempt 0、random 0.5
        await client.stop()
    }

    @Test func bannerHonestWhileReconnecting() async throws {
        // 只給失敗劇本：狀態必須停在 reconnecting，絕不出現 connected（誠實 banner）
        let probe = ScriptedProbe([.failed, .failed, .failed])
        let client = EmulatorClient(
            makeTransport: { _ in MockTransport([]) },
            makeHealthProbe: { _ in probe },
            sleeper: { _ in },
            randomSource: { 0.5 }
        )
        var everConnected = false
        let watch = Task {
            var n = 0
            for await s in client.states { if s == .connected { everConnected = true }; n += 1; if n >= 4 { break } }
        }
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        _ = await watch.value
        #expect(everConnected == false)
        await client.stop()
    }

    @Test func loopNotRecursionUnderManyFailures() async throws {
        // 100 次失敗後健康：迴圈不堆積 async frame（能跑完且最終 connected 即證明）
        let probe = ScriptedProbe(Array(repeating: .failed, count: 100) + [.healthy])
        let client = EmulatorClient(
            makeTransport: { _ in MockTransport([.yieldThenHang(1)]) },
            makeHealthProbe: { _ in probe },
            sleeper: { _ in },              // 假時鐘：不真睡
            randomSource: { 0.5 }
        )
        let watch = Task { for await s in client.states { if s == .connected { break } } }
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        _ = await watch.value
        #expect(probe.calls == 101)
        await client.stop()
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter "EmulatorClientHealthGateTests" 2>&1 | tail -3`
Expected: 編譯失敗（`makeHealthProbe` 參數不存在）。

- [ ] **Step 3: 改寫 EmulatorClient（整檔取代）**

```swift
// app/Sources/MirageCore/EmulatorClient.swift
import Foundation

/// 門面 actor：連線生命週期（reducer + 健康探測迴圈驅動）、串流掛載、輸入注入、狀態發布。
public actor EmulatorClient {
    private let host: String
    private let port: Int
    private let makeTransport: @Sendable (GrpcChannelBox) -> DisplayTransport
    private let makeHealthProbe: @Sendable (GrpcChannelBox) -> HealthProbe
    private let backoff: BackoffPolicy
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let randomSource: @Sendable () -> Double
    private let probeTimeout: Duration

    private var state: ConnState = .disconnected
    private var channelBox: GrpcChannelBox?
    private var transport: DisplayTransport?
    private var probe: HealthProbe?
    private let pump = FramePump()
    private var box: LatestFrameBox?
    private var streamSize = (w: 540, h: 1200)
    private var running = false
    private var loopTask: Task<Void, Never>?
    private var breakCont: AsyncStream<Void>.Continuation?

    public nonisolated let states: AsyncStream<ConnState>
    private let stateCont: AsyncStream<ConnState>.Continuation

    public init(host: String = "localhost", port: Int = 8554,
                makeTransport: @escaping @Sendable (GrpcChannelBox) -> DisplayTransport
                    = { GrpcStreamTransport(channel: $0) },
                makeHealthProbe: @escaping @Sendable (GrpcChannelBox) -> HealthProbe
                    = { GrpcHealthProbe(client: $0.client) },
                backoff: BackoffPolicy = .init(),
                sleeper: @escaping @Sendable (Duration) async throws -> Void
                    = { try await Task.sleep(for: $0) },
                randomSource: @escaping @Sendable () -> Double
                    = { Double.random(in: 0..<1) },
                probeTimeout: Duration = .seconds(1)) {
        self.host = host
        self.port = port
        self.makeTransport = makeTransport
        self.makeHealthProbe = makeHealthProbe
        self.backoff = backoff
        self.sleeper = sleeper
        self.randomSource = randomSource
        self.probeTimeout = probeTimeout
        (states, stateCont) = AsyncStream.makeStream(of: ConnState.self)
    }

    public func start(box: LatestFrameBox, width: Int, height: Int) async {
        self.box = box
        streamSize = (width, height)
        running = true
        loopTask = Task { await self.runConnectionLoop() }
    }

    public func setStreamSize(width: Int, height: Int) async {
        streamSize = (width, height)
        if state == .connected { attachStream() }   // 換源，共用當前 breakCont
    }

    public func stop() async {
        running = false
        breakCont?.yield()          // 喚醒卡在 connectedRun 的迴圈
        loopTask?.cancel()          // 喚醒卡在 sleeper/probe 的迴圈
        await pump.detach()
        _ = step(.stopRequested)    // → .disconnected
        dropChannel()
        loopTask = nil
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

    // MARK: - 純轉移（reducer 語意不變，只發布狀態、回傳 effect）

    private func step(_ event: ConnEvent) -> ConnEffect {
        let (next, effect) = ConnReducer.reduce(state, event)
        state = next
        stateCont.yield(next)
        return effect
    }

    // MARK: - 重連迴圈（非遞迴：消除 P1-a 終審 Minor #7 的 async frame 堆積）

    private func runConnectionLoop() async {
        _ = step(.connectRequested)                 // → .connecting
        while running {
            let ready = ensureChannel()
            let result: HealthResult = ready ? await (probe?.probe(timeout: probeTimeout) ?? .failed) : .failed
            if !running { break }
            if result == .healthy {
                _ = step(.connectSucceeded)         // → .connected（gate：只有健康才連上）
                await connectedRun()                // 阻塞到串流斷或 stop
                guard running else { break }
                await pump.detach()
                dropChannel()                       // 斷線先 drop 舊 channel（spec §4.1）
                let effect = step(.streamBroken)    // → .reconnecting(0)
                await backoffDelay(effect)
            } else {
                await pump.detach()
                dropChannel()                       // 探測失敗也 drop，下一圈重建
                let effect = step(.connectFailed)   // → .reconnecting(n)（attempt 由 reducer 遞增）
                await backoffDelay(effect)
            }
        }
    }

    /// 確保 channel/transport/probe 存在；斷線後 channelBox 已被 dropChannel 清空，此處重建。
    private func ensureChannel() -> Bool {
        if channelBox == nil {
            do {
                let boxCh = try GrpcChannelBox(host: host, port: port)
                channelBox = boxCh
                transport = makeTransport(boxCh)
                probe = makeHealthProbe(boxCh)
            } catch {
                return false
            }
        }
        return transport != nil && probe != nil
    }

    /// connected 期間：掛串流並阻塞到第一個斷線訊號（或 stop）。setStreamSize 換源共用同一 breakCont。
    private func connectedRun() async {
        let (signal, cont) = AsyncStream<Void>.makeStream()
        breakCont = cont
        attachStream()
        for await _ in signal { break }
        breakCont = nil
    }

    private func attachStream() {
        guard let transport, let box else { return }
        let stream = transport.frames(width: streamSize.w, height: streamSize.h)
        Task {
            await pump.attach(stream, into: box) { [weak self] err in
                guard err != nil else { return }    // 換源正常結束不算斷
                Task { await self?.signalBreak() }
            }
        }
    }

    private func signalBreak() { breakCont?.yield() }

    private func backoffDelay(_ effect: ConnEffect) async {
        guard case .scheduleReconnect(let attempt) = effect, running else { return }
        let delay = backoff.delay(attempt: attempt, random: randomSource())
        try? await sleeper(delay)
    }

    private func dropChannel() {
        transport = nil
        probe = nil
        channelBox = nil            // deinit → group.syncShutdownGracefully()
    }
}
```

- [ ] **Step 4: 測試通過（單元全綠、無回歸）**

Run: `cd app && swift test 2>&1 | tail -4`
Expected: 全部通過（P1-a 既有 + Task 1-2 + 本 Task 新 3 測試）。若既有 `testStreamFailureResubscribesWithBackoff` 因迴圈語意調整需微調斷言（如 `subscribeCount` 時序），依語意等價最小修正並在 commit 訊息註記。

- [ ] **Step 5: 活體重連驗證（沿用 P1-a 腳本，證明恢復不變慢）**

Run（模擬器執行中）: `app/scripts/verify_reconnect.sh`
Expected: `PASS: 開機完成後 Ns 恢復出幀`（N ≤ 10，且 log 的 states 序列**真實出現 `.reconnecting(attempt: n)`**——關閉 P1-a 終審缺口的活體證據）。

- [ ] **Step 6: Commit**

```bash
git add app/Sources/MirageCore/EmulatorClient.swift app/Tests/MirageCoreTests/EmulatorClientReconnectTests.swift
git commit -m "fix: 健康探測 gate 與重連迴圈重構——修 P1-a 終審 async frame 堆積與假連線"
```

---

### Task 4: PowerState 狀態機 + SnapshotService 封裝 + 休眠/喚醒（TDD + 活體 round-trip）

**Files:**
- Create: `app/Sources/MirageCore/Lifecycle/PowerState.swift`
- Create: `app/Sources/MirageCore/Lifecycle/SnapshotService.swift`
- Modify: `app/Sources/MirageCore/EmulatorClient.swift`（加 `suspend()`/`wake()` + 電源狀態發布）
- Test: `app/Tests/MirageCoreTests/PowerStateTests.swift`
- Create: `app/scripts/verify_snapshot.sh`

**Interfaces:**
- Consumes: Task 1 `Android_Emulation_Control_SnapshotServiceAsyncClient`/`SnapshotPackage`；Task 3 的 `EmulatorClient` 內部（`channelBox`、`pump`）。
- Produces:
  - `enum PowerState: Equatable, Sendable { case active, suspending, suspended, waking }`；`enum PowerEvent { case suspendRequested, snapshotSaved, wakeRequested, snapshotLoaded }`；`PowerReducer.reduce(_:_:) -> PowerState`（純函式，非法轉移 no-op）。
  - `protocol SnapshotSaving: Sendable { func save(_ id: String) async -> Bool; func load(_ id: String) async -> Bool }`；`struct GrpcSnapshotService: SnapshotSaving`（`init(client: Android_Emulation_Control_SnapshotServiceAsyncClient)`，`format = .directory`，回傳 `resp.success`）。
  - `EmulatorClient.suspend()` / `wake()`（供 Task 6 的 AppLifecycle 呼叫）；`nonisolated let powerStates: AsyncStream<PowerState>`。

- [ ] **Step 1: 失敗測試（PowerState 純轉移）**

```swift
// app/Tests/MirageCoreTests/PowerStateTests.swift
import Testing
@testable import MirageCore

@Suite struct PowerStateTests {
    @Test func legalSuspendWakeCycle() {
        var s = PowerState.active
        s = PowerReducer.reduce(s, .suspendRequested); #expect(s == .suspending)
        s = PowerReducer.reduce(s, .snapshotSaved);    #expect(s == .suspended)
        s = PowerReducer.reduce(s, .wakeRequested);    #expect(s == .waking)
        s = PowerReducer.reduce(s, .snapshotLoaded);   #expect(s == .active)
    }

    @Test func illegalTransitionsAreNoOp() {
        // 已 active 再 wake：no-op
        #expect(PowerReducer.reduce(.active, .wakeRequested) == .active)
        // suspended 再 suspend：no-op
        #expect(PowerReducer.reduce(.suspended, .suspendRequested) == .suspended)
        // waking 中途又 suspend：no-op（不允許交錯）
        #expect(PowerReducer.reduce(.waking, .suspendRequested) == .waking)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter PowerStateTests 2>&1 | tail -3`
Expected: 編譯失敗（`PowerState`/`PowerReducer` 不存在）。

- [ ] **Step 3: 實作 PowerState + SnapshotService**

```swift
// app/Sources/MirageCore/Lifecycle/PowerState.swift
/// 電源純狀態機：凍結/喚醒轉移可窮舉測試，實際 gRPC 由 EmulatorClient 執行。
public enum PowerState: Equatable, Sendable {
    case active, suspending, suspended, waking
}

public enum PowerEvent: Equatable, Sendable {
    case suspendRequested, snapshotSaved, wakeRequested, snapshotLoaded
}

public enum PowerReducer {
    public static func reduce(_ state: PowerState, _ event: PowerEvent) -> PowerState {
        switch (state, event) {
        case (.active, .suspendRequested):    return .suspending
        case (.suspending, .snapshotSaved):   return .suspended
        case (.suspended, .wakeRequested):    return .waking
        case (.waking, .snapshotLoaded):      return .active
        default:                              return state   // 非法轉移 no-op
        }
    }
}
```

```swift
// app/Sources/MirageCore/Lifecycle/SnapshotService.swift
import Foundation
import GRPC

/// 快照存/載抽象：以 protocol 注入，單元測試用假實作。
public protocol SnapshotSaving: Sendable {
    func save(_ id: String) async -> Bool     // 成功回 true，失敗回 false（降級，不擲錯）
    func load(_ id: String) async -> Bool
}

/// 生產實作：SnapshotService.SaveSnapshot/LoadSnapshot，format=directory（原地存載，不 streaming payload）。
public struct GrpcSnapshotService: SnapshotSaving {
    private let client: Android_Emulation_Control_SnapshotServiceAsyncClient

    public init(client: Android_Emulation_Control_SnapshotServiceAsyncClient) {
        self.client = client
    }

    private func request(_ id: String) -> Android_Emulation_Control_SnapshotPackage {
        var pkg = Android_Emulation_Control_SnapshotPackage()
        pkg.snapshotID = id
        pkg.format = .directory
        return pkg
    }

    public func save(_ id: String) async -> Bool {
        do { return try await client.saveSnapshot(request(id)).success } catch { return false }
    }

    public func load(_ id: String) async -> Bool {
        do { return try await client.loadSnapshot(request(id)).success } catch { return false }
    }
}
```

- [ ] **Step 4: PowerState 測試通過**

Run: `cd app && swift test --filter PowerStateTests 2>&1 | tail -3`
Expected: 2 tests passed。

- [ ] **Step 5: EmulatorClient 加 suspend/wake（電源狀態機 + 快照 + 暫停拉幀）**

在 `EmulatorClient` 加下列成員與方法（其餘不動）。`makeSnapshot` 注入對稱於 `makeHealthProbe`：

```swift
// 加到 init 參數列（預設用 SnapshotService，需 channelBox 的 SnapshotService client）
//   makeSnapshot: @escaping @Sendable (GrpcChannelBox) -> SnapshotSaving
//       = { GrpcSnapshotService(client: .init(channel: $0.channel)) },
// 加到儲存屬性：
//   private let makeSnapshot: @Sendable (GrpcChannelBox) -> SnapshotSaving
//   private var power: PowerState = .active
//   public nonisolated let powerStates: AsyncStream<PowerState>
//   private let powerCont: AsyncStream<PowerState>.Continuation
// init 尾：(powerStates, powerCont) = AsyncStream.makeStream(of: PowerState.self)
// 註：GrpcChannelBox 需公開 `let channel: GRPCChannel`（見下方 Step 6 微調）。

public func suspend() async {
    guard power == .active, let boxCh = channelBox else { return }
    setPower(.suspending)
    let ok = await makeSnapshot(boxCh).save("mirage_suspend")
    await pump.detach()                 // 停止拉幀（省 app 端 CPU；qemu 仍在跑）
    setPower(.suspended)                // save 失敗也進 suspended（降級：仍凍結，spec §5）
    _ = ok
}

public func wake() async {
    guard power == .suspended, let boxCh = channelBox else { return }
    setPower(.waking)
    _ = await makeSnapshot(boxCh).load("mirage_suspend")  // 失敗則恢復當前串流畫面（降級）
    if state == .connected { attachStream() }             // 恢復拉幀
    setPower(.active)
}

private func setPower(_ p: PowerState) {
    power = p
    powerCont.yield(p)
}
```

- [ ] **Step 6: GrpcChannelBox 公開 channel（供 SnapshotService client 共用連線）**

`GrpcStreamTransport.swift` 的 `GrpcChannelBox` 目前只公開 `group`/`client`。加公開 `channel` 讓 SnapshotService 共用同一條：

```swift
// GrpcChannelBox：把 channel 存為屬性並公開
public let channel: GRPCChannel
// init 內：self.channel = channel（原本區域變數改存屬性）；client 用 self.channel 建。
```

- [ ] **Step 7: 建置 + 活體快照 round-trip 腳本**

```bash
# app/scripts/verify_snapshot.sh
#!/usr/bin/env bash
# 驗收 4：對執行中模擬器 save → 改變畫面 → load，畫面回到 save 當時。
# 前置：模擬器執行中。用 adb 擷圖比對（save 前 vs load 後應相近；中間改變後應不同）。
set -euo pipefail
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
OUT=/tmp/mirage_snap; mkdir -p "$OUT"
echo "[snap] 需搭配 MIRAGE_LIVE 整合測試 SnapshotRoundTripLiveTests 執行本 gRPC round-trip。"
echo "[snap] 擷圖佐證：save 前後畫面一致、中途變更後不同。"
"$ADB" exec-out screencap -p > "$OUT/before.png"
echo "[snap] before.png 已存；請執行 MIRAGE_LIVE=1 swift test --filter SnapshotRoundTripLiveTests"
```

活體整合測試（附加到測試檔，預設 skip）：

```swift
// app/Tests/MirageCoreTests/SnapshotRoundTripLiveTests.swift
import Testing
import GRPC
import NIOPosix
@testable import MirageCore

@Suite struct SnapshotRoundTripLiveTests {
    @Test func saveThenLoadRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1" else { return }
        let boxCh = try GrpcChannelBox(host: "localhost", port: 8554)
        let snap = GrpcSnapshotService(client: .init(channel: boxCh.channel))
        #expect(await snap.save("mirage_suspend") == true)
        #expect(await snap.load("mirage_suspend") == true)
    }
}
```

Run: `cd app && swift build 2>&1 | tail -2 && swift test --filter PowerStateTests 2>&1 | tail -3`
Expected: Build complete；PowerState 2 passed。活體（可選）：`MIRAGE_LIVE=1 swift test --filter SnapshotRoundTripLiveTests`。

- [ ] **Step 8: Commit**

```bash
git add app/Sources/MirageCore/Lifecycle/PowerState.swift app/Sources/MirageCore/Lifecycle/SnapshotService.swift app/Sources/MirageCore/EmulatorClient.swift app/Sources/MirageCore/GrpcStreamTransport.swift app/Tests/MirageCoreTests/PowerStateTests.swift app/Tests/MirageCoreTests/SnapshotRoundTripLiveTests.swift app/scripts/verify_snapshot.sh
git commit -m "feat: PowerState 狀態機、SnapshotService 封裝與 gRPC 層休眠/喚醒（TDD+活體）"
```

---

### Task 5: ClipboardBridge 防回音 + EmulatorClient 剪貼簿接線（TDD + 活體）

**Files:**
- Create: `app/Sources/MirageCore/Lifecycle/ClipboardBridge.swift`
- Modify: `app/Sources/MirageCore/EmulatorClient.swift`（加 `setGuestClipboard`、`guestClipboard` 串流、串流消費生命週期）
- Test: `app/Tests/MirageCoreTests/ClipboardBridgeTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `EmulatorClient`（`channelBox.client` 有 `setClipboard`/`streamClipboard`）。
- Produces:
  - `enum ClipDirection: Equatable, Sendable { case guestToHost, hostToGuest }`
  - `struct ClipboardBridge: Equatable, Sendable`——不可變；`shouldPropagate(value: String, direction: ClipDirection) -> (propagate: Bool, next: ClipboardBridge)`（同值即不傳播，涵蓋回音與去重；回傳新狀態，不原地改）。
  - `EmulatorClient.setGuestClipboard(_ text: String) async`（host→guest）；`nonisolated let guestClipboard: AsyncStream<String>`（guest→host 值流，供 Task 6 的 App 層訂閱）。

- [ ] **Step 1: 失敗測試（防回音純邏輯）**

```swift
// app/Tests/MirageCoreTests/ClipboardBridgeTests.swift
import Testing
@testable import MirageCore

@Suite struct ClipboardBridgeTests {
    @Test func firstValuePropagates() {
        let (ok, _) = ClipboardBridge().shouldPropagate(value: "hello", direction: .hostToGuest)
        #expect(ok == true)
    }

    @Test func echoBackDoesNotPropagate() {
        // host 設 "hello" 送 guest（傳播）；guest 串流回吐 "hello"（不回彈）→ 無限迴圈被切斷
        var bridge = ClipboardBridge()
        let (ok1, b1) = bridge.shouldPropagate(value: "hello", direction: .hostToGuest)
        bridge = b1
        #expect(ok1 == true)
        let (ok2, _) = bridge.shouldPropagate(value: "hello", direction: .guestToHost)
        #expect(ok2 == false)          // 回音不傳播
    }

    @Test func differentValuePropagatesBothDirections() {
        var bridge = ClipboardBridge()
        let (okA, b1) = bridge.shouldPropagate(value: "A", direction: .hostToGuest); bridge = b1
        let (okB, _) = bridge.shouldPropagate(value: "B", direction: .guestToHost)
        #expect(okA == true)
        #expect(okB == true)           // B ≠ A，雙向都傳播
    }

    @Test func duplicateValueDeduped() {
        var bridge = ClipboardBridge()
        let (_, b1) = bridge.shouldPropagate(value: "same", direction: .guestToHost); bridge = b1
        let (ok2, _) = bridge.shouldPropagate(value: "same", direction: .guestToHost)
        #expect(ok2 == false)          // 同值連續 → 去重
    }

    @Test func bridgeIsImmutable() {
        let original = ClipboardBridge()
        _ = original.shouldPropagate(value: "x", direction: .hostToGuest)
        // original 未被改動：再次以初始狀態判定，仍傳播
        let (ok, _) = original.shouldPropagate(value: "x", direction: .hostToGuest)
        #expect(ok == true)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd app && swift test --filter ClipboardBridgeTests 2>&1 | tail -3`
Expected: 編譯失敗（`ClipboardBridge` 不存在）。

- [ ] **Step 3: 實作 ClipboardBridge**

```swift
// app/Sources/MirageCore/Lifecycle/ClipboardBridge.swift
/// 剪貼簿方向。
public enum ClipDirection: Equatable, Sendable {
    case guestToHost, hostToGuest
}

/// 防回音純狀態：記錄最後一次傳播的值；同值再來即不傳播（切斷 A→B→A 迴圈，兼作去重）。
/// 不可變——shouldPropagate 回傳新狀態，不原地改。
public struct ClipboardBridge: Equatable, Sendable {
    private let lastValue: String?

    public init(lastValue: String? = nil) { self.lastValue = lastValue }

    public func shouldPropagate(value: String, direction: ClipDirection)
        -> (propagate: Bool, next: ClipboardBridge)
    {
        if value == lastValue {
            return (false, self)                 // 回音或重複 → 不傳播
        }
        return (true, ClipboardBridge(lastValue: value))
    }
}
```

- [ ] **Step 4: 測試通過**

Run: `cd app && swift test --filter ClipboardBridgeTests 2>&1 | tail -3`
Expected: 5 tests passed。

- [ ] **Step 5: EmulatorClient 剪貼簿接線（host→guest + guest→host 串流）**

在 `EmulatorClient` 加下列（其餘不動）。guest→host 串流隨連線生命週期啟停：

```swift
// 儲存屬性：
//   private var clipboardTask: Task<Void, Never>?
//   public nonisolated let guestClipboard: AsyncStream<String>
//   private let guestClipCont: AsyncStream<String>.Continuation
// init 尾：(guestClipboard, guestClipCont) = AsyncStream.makeStream(of: String.self)

public func setGuestClipboard(_ text: String) async {
    guard let client = channelBox?.client else { return }
    var clip = Android_Emulation_Control_ClipData()
    clip.text = text
    _ = try? await client.setClipboard(clip)
}

/// 於 step(.connectSucceeded) 後啟動（在 runConnectionLoop 的 .healthy 分支呼叫）；dropChannel 前取消。
private func startClipboardStream() {
    guard let client = channelBox?.client else { return }
    clipboardTask?.cancel()
    clipboardTask = Task { [guestClipCont] in
        do {
            for try await clip in client.streamClipboard(.init()) {
                if Task.isCancelled { return }
                guestClipCont.yield(clip.text)
            }
        } catch { /* 串流斷屬正常（連線斷）；由重連迴圈處理，不在此重連 */ }
    }
}
```

接線點：`runConnectionLoop` 的 `.healthy` 分支，`step(.connectSucceeded)` 之後、`connectedRun()` 之前加 `startClipboardStream()`；`dropChannel()` 內加 `clipboardTask?.cancel(); clipboardTask = nil`。

- [ ] **Step 6: 建置 + 活體剪貼簿煙霧（可選）**

```swift
// 附加到 ClipboardBridgeTests.swift 底部
@Suite struct ClipboardLiveTests {
    @Test func hostToGuestSetsClipboard() async throws {
        guard ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1" else { return }
        let client = EmulatorClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .seconds(2))
        await client.setGuestClipboard("mirage-test-\(42)")
        try await Task.sleep(for: .milliseconds(500))
        await client.stop()
        // 佐證：adb shell 讀 guest 剪貼簿或人工檢查（pending-human）
    }
}
```

Run: `cd app && swift build 2>&1 | tail -2 && swift test --filter ClipboardBridgeTests 2>&1 | tail -3`
Expected: Build complete；5 passed。

- [ ] **Step 7: Commit**

```bash
git add app/Sources/MirageCore/Lifecycle/ClipboardBridge.swift app/Sources/MirageCore/EmulatorClient.swift app/Tests/MirageCoreTests/ClipboardBridgeTests.swift
git commit -m "feat: ClipboardBridge 防回音純邏輯與雙向剪貼簿接線（TDD+活體）"
```

---

### Task 6: MirageApp 生命週期整合（選單列、剪貼簿輪詢、休眠/喚醒/teardown 膠水）

**背景**：AppKit 膠水，多屬 pending-human（需 GUI + 解鎖）。正確性以程式碼結構 + Core 層單元覆蓋保證；體感實測列 pending-human。

**Files:**
- Create: `app/Sources/MirageApp/Lifecycle/MenuBarController.swift`
- Create: `app/Sources/MirageApp/Lifecycle/ClipboardWatcher.swift`
- Create: `app/Sources/MirageApp/Lifecycle/AppLifecycle.swift`
- Modify: `app/Sources/MirageApp/MirageApp.swift`（注入生命週期、選單列、剪貼簿）

**Interfaces:**
- Consumes: `EmulatorClient`（`suspend/wake/setGuestClipboard/guestClipboard/powerStates/states/stop`）；Task 5 `ClipboardBridge`。
- Produces: 選單列常駐、視窗關閉→休眠、喚醒→load、Cmd+Q 乾淨 teardown、雙向剪貼簿實接。

- [ ] **Step 1: ClipboardWatcher（NSPasteboard changeCount 輪詢，僅純文字）**

```swift
// app/Sources/MirageApp/Lifecycle/ClipboardWatcher.swift
import AppKit

/// 輪詢 NSPasteboard.changeCount，變更且為純文字時回呼。非文字略過（spec §4.3）。
@MainActor
final class ClipboardWatcher {
    private let pasteboard = NSPasteboard.general
    private var lastCount: Int
    private var timer: Timer?
    private let onChange: (String) -> Void

    init(onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        self.lastCount = pasteboard.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// 供本地寫入後同步 changeCount，避免把自己剛寫入的值當成 host 變更回吐（App 層第一道防線）。
    func syncBaseline() { lastCount = pasteboard.changeCount }

    private func poll() {
        let c = pasteboard.changeCount
        guard c != lastCount else { return }
        lastCount = c
        guard let s = pasteboard.string(forType: .string) else { return }  // 非文字略過
        onChange(s)
    }
}
```

- [ ] **Step 2: MenuBarController（NSStatusItem：狀態、喚醒、顯示視窗、退出）**

```swift
// app/Sources/MirageApp/Lifecycle/MenuBarController.swift
import AppKit

/// 選單列常駐：顯示連線/電源狀態，提供喚醒、顯示視窗、退出。
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let onWake: () -> Void
    private let onShow: () -> Void
    private let statusMenuItem: NSMenuItem

    init(onWake: @escaping () -> Void, onShow: @escaping () -> Void) {
        self.onWake = onWake
        self.onShow = onShow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🪞"
        statusMenuItem = NSMenuItem(title: "狀態：—", action: nil, keyEquivalent: "")

        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "喚醒", action: #selector(wakeTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "顯示視窗", action: #selector(showTapped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Mirage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func updateStatus(_ text: String) { statusMenuItem.title = "狀態：\(text)" }

    @objc private func wakeTapped() { onWake() }
    @objc private func showTapped() { onShow() }
}

private extension NSMenu {
    @discardableResult
    func addItem(withTitle t: String, action: Selector, keyEquivalent k: String) -> NSMenuItem {
        let item = NSMenuItem(title: t, action: action, keyEquivalent: k)
        addItem(item)
        return item
    }
}
```

- [ ] **Step 3: AppLifecycle（視窗關閉→休眠、喚醒→load、Cmd+Q teardown）**

```swift
// app/Sources/MirageApp/Lifecycle/AppLifecycle.swift
import AppKit
import MirageCore

/// 生命週期協調：視窗關閉→休眠（不退出，選單列常駐）、喚醒→恢復、Cmd+Q→乾淨 teardown。
@MainActor
final class AppLifecycle: NSObject, NSWindowDelegate {
    private let client: EmulatorClient
    private var suspended = false

    init(client: EmulatorClient) { self.client = client }

    /// 視窗即將關閉 → 觸發休眠而非退出（回傳 false 阻止關閉，改為隱藏）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)                 // 隱藏視窗，app 續存（選單列常駐）
        suspended = true
        Task { await client.suspend() }
        return false
    }

    func wake(showing window: NSWindow?) {
        guard suspended else { window?.makeKeyAndOrderFront(nil); return }
        suspended = false
        window?.makeKeyAndOrderFront(nil)
        Task { await client.wake() }
    }
}
```

- [ ] **Step 4: MirageApp 接線（選單列 + 剪貼簿橋 + 生命週期）**

在 `MirageApp.swift` 的 `AppModel` 加入生命週期成員與剪貼簿橋接迴圈，`AppDelegate` 沿用既有 teardown（`applicationWillTerminate` + semaphore + `shutdown`，P1-a 已驗證，本件確認其正確——`client.stop()` 現已含迴圈取消與 pump.detach）。`AppModel` 增補：

```swift
// AppModel 增補（節錄）：
//   var menuBar: MenuBarController?
//   var lifecycle: AppLifecycle?
//   var watcher: ClipboardWatcher?
//   private var bridge = ClipboardBridge()

func startLifecycle() {
    lifecycle = AppLifecycle(client: client)
    menuBar = MenuBarController(
        onWake: { [weak self] in self?.wake() },
        onShow: { [weak self] in self?.wake() }
    )
    // 連線狀態 → 選單列
    Task { [weak self, client] in
        for await s in client.states {
            await MainActor.run { self?.menuBar?.updateStatus(Self.label(s)) }
        }
    }
    // guest→host 剪貼簿：經 bridge 防回音後寫 NSPasteboard
    Task { [weak self, client] in
        for await text in client.guestClipboard {
            await MainActor.run { self?.applyGuestClipboard(text) }
        }
    }
    // host→guest：watcher 輪詢 → 經 bridge → setGuestClipboard
    watcher = ClipboardWatcher { [weak self] text in self?.applyHostClipboard(text) }
    watcher?.start()
}

private func applyGuestClipboard(_ text: String) {
    let (ok, next) = bridge.shouldPropagate(value: text, direction: .guestToHost)
    bridge = next
    guard ok else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    watcher?.syncBaseline()          // 別把自己剛寫入的值當 host 變更
}

private func applyHostClipboard(_ text: String) {
    let (ok, next) = bridge.shouldPropagate(value: text, direction: .hostToGuest)
    bridge = next
    guard ok else { return }
    Task { await client.setGuestClipboard(text) }
}

private func wake() {
    let window = NSApp.windows.first
    lifecycle?.wake(showing: window)
}

static func label(_ s: ConnState) -> String {
    switch s {
    case .connected: return "已連線"
    case .connecting: return "連線中"
    case .reconnecting(let n): return "重連中（第 \(n + 1) 次）"
    case .disconnected: return "未連線"
    }
}
```

`MirageApp.body` 的 `.task` 內於 `await model.start()` 後加 `model.startLifecycle()`；視窗透過 `.onAppear` 或 `NSApp.windows.first?.delegate = model.lifecycle` 掛 `windowShouldClose`（於 `startLifecycle` 尾用 `Task { @MainActor in NSApp.windows.first?.delegate = self.lifecycle }`）。

- [ ] **Step 5: 建置 + 冒煙（app 起得來、選單列出現）**

Run: `cd app && swift build -c release 2>&1 | tail -2`
Expected: Build complete、零警告。冒煙（GUI）：`./.build/release/MirageApp &` → 選單列出現 🪞、關閉視窗 app 不退出、選單列「喚醒」重開。體感與跨 app 剪貼簿標記 **pending-human**。

- [ ] **Step 6: Commit**

```bash
git add app/Sources/MirageApp/Lifecycle app/Sources/MirageApp/MirageApp.swift
git commit -m "feat: 選單列常駐、剪貼簿橋接與視窗關閉→休眠/喚醒/teardown 膠水"
```

---

### Task 7: 驗收量測、覆蓋率與文件

**Files:**
- Create: `app/RESULTS-p1b.md`
- Modify: `app/README.md`（加 P1-b 章節）

**Interfaces:**
- Consumes: Task 1-6 全部交付物。
- Produces: P1-b 出貨判定（spec §7 逐條裁決）。

- [ ] **Step 1: 全測試 + 覆蓋率 + release 零警告**

```bash
cd app
swift build -c release 2>&1 | tail -2                       # 零警告
swift test --enable-code-coverage 2>&1 | tail -3            # 全綠、無回歸（≥28 + 新增）
xcrun llvm-cov report .build/debug/MiragePackageTests.xctest/Contents/MacOS/MiragePackageTests \
  -instr-profile .build/debug/codecov/default.profdata \
  -ignore-filename-regex "Generated|Tests" 2>/dev/null | tail -8   # MirageCore ≥80%
```

- [ ] **Step 2: 活體驗收（模擬器執行中）**

```bash
# 驗收 2：重連期間 states 真實 reconnecting（關閉 P1-a 終審缺口）
app/scripts/verify_reconnect.sh
# 驗收 4：快照 round-trip
MIRAGE_LIVE=1 swift test --filter SnapshotRoundTripLiveTests 2>&1 | tail -3
```

- [ ] **Step 3: RESULTS-p1b.md（照 spec §7 逐條填實測）**

```markdown
# P1-b 驗收結果（日期：____；host load：____；emulator：____）

| # | 驗收線（spec §7） | 實測 | 判定 |
|---|---|---|---|
| 1 | Lifecycle 單元全綠、覆蓋 ≥80%、release 零警告、既有 28 不回歸 | ___ tests / ___% / 警告 ___ | ⬜ |
| 2 | 殺模擬器→states 真實出現 reconnecting(n)→恢復 connected（單元+活體 log） | 單元 ___ / verify_reconnect ___s | ⬜ |
| 3 | 重連仍 ≤10s 恢復（不因健康探測變慢） | ___s | ⬜ |
| 4 | 快照 round-trip：save→改畫面→load 回到 save 當時 | ___（擷圖佐證） | ⬜ |
| 5 | 剪貼簿防回音：host→guest→不回彈不成無限迴圈（單元） | ___ | ⬜ |
| 6 | pending-human（解鎖後）：休眠/喚醒體感、選單列、Cmd+Q teardown、剪貼簿跨 app | ⬜ pending-unlock | ⬜ |

## 判定
- [ ] P1-b 出貨 → P1-c 整合（建於本件清乾淨的重連迴圈上）
- [ ] 未達標項與處置：____

## 觀察與備註
（健康探測 timeout 實測恢復時間、快照語意 deviation、剪貼簿 changeCount 行為……）
```

- [ ] **Step 4: app/README.md 加 P1-b 章節**

```markdown
## P1-b 生命週期

- 健康探測重連：斷線期 banner 誠實顯示 `reconnecting(n)`（修 P1-a 缺口）
- 休眠/喚醒（gRPC 層）：關閉視窗→save snapshot + 停止拉幀；選單列/重開→load + 恢復
- 選單列常駐（🪞）：狀態、喚醒、顯示視窗、退出
- 雙向剪貼簿（純文字，防回音）
- 快照 stub 產生：`scripts/gen_snapshot_stub.sh`（需 grpc-swift checkout build plugin）
- 活體：`MIRAGE_LIVE=1 swift test --filter "SnapshotRoundTripLiveTests|ClipboardLiveTests"`
- 驗收紀錄：`RESULTS-p1b.md`；快照驗證：`scripts/verify_snapshot.sh`

架構詳見 `../docs/specs/2026-07-24-p1b-lifecycle-design.md`。
```

- [ ] **Step 5: 填實數、判定、Commit**

```bash
git add app/RESULTS-p1b.md app/README.md
git commit -m "docs: p1b 驗收結果與使用文件"
```

---

## Self-Review 紀錄

- **Spec 覆蓋**：§3 結構=各 Task 檔案對應；§4.1 健康探測+重連迴圈=Task 2+3（修 P1-a 終審 Minor #7）；§4.2 SnapshotService+PowerState+休眠/喚醒=Task 4；§4.3 ClipboardBridge 防回音+雙向=Task 5；§4.4 MenuBarController+AppLifecycle+Cmd+Q teardown=Task 6；§5 錯誤處理=各實作（探測失敗→backoff、snapshot 失敗→降級 bool、剪貼簿失敗→try? 跳過）；§6 測試=Task 2-5 單元 + Task 4/5 活體；§7 驗收=Task 7 逐條。§2 NIO teardown=Task 3 的 stop() 含迴圈取消+pump.detach，Task 6 確認 AppDelegate drain 正確。
- **前置缺口處置**：spec 假設 `SnapshotService.saveSnapshot/loadSnapshot` 存在，實際 Generated 無此 stub → **新增 Task 1** 產生（proto 在 SDK、plugin 由 grpc-swift 1.27.5 build），並給手寫 fallback。此為 spec 未言明的必要前置。
- **佔位掃描**：無 TBD；RESULTS 的 `___` 為待填實測（專案慣例）；「欄位名以產生結果為準」為 codegen 版本防呆非佔位。
- **型別一致性**：`HealthProbe.probe(timeout:)→HealthResult`（Task 2 定義=3 注入）；`EmulatorClient.init` 新增 `makeHealthProbe/makeSnapshot/probeTimeout`（Task 3/4 一致）；`PowerReducer.reduce`、`PowerState`（Task 4）；`SnapshotSaving.save/load`（Task 4 定義=活體用）；`ClipboardBridge.shouldPropagate(value:direction:)→(propagate:next:)`（Task 5 定義=6 用）；`GrpcChannelBox.channel` 公開（Task 4 Step 6 加=SnapshotService/streamClipboard 用）；`guestClipboard`/`setGuestClipboard`（Task 5=6）；`suspend/wake/powerStates`（Task 4=6）。
- **併發紀律**：MirageCore 新增檔全不 import AppKit（HealthProbe/PowerState/SnapshotService/ClipboardBridge 純 + GRPC）；AppKit 僅在 MirageApp/Lifecycle。`-strict-concurrency=complete` 下 `@MainActor` 標註 App 層膠水。
- **恢復不變慢**（spec §8 風險）：健康探測 timeout 預設 1s、與 pool 內部重連協調；Task 3 Step 5 + Task 7 驗收 3 實測恢復時間不回歸。

