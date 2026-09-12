# 區域網路手機遙控（階段 A、B）實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `MirageCore` 建立手機遙控的純邏輯層（幀扇出、H.264 NAL 與 SPS 改寫、配對 token、觸控訊息、識別碼配置、連線 reducer）與 NIO 的 HTTP＋WebSocket 伺服器，含手機頁面，全部可在無模擬器、無手機的情況下用單元測試與 loopback 整合測試驗證。

**Architecture:** 幀在 `FrameSink` 層由 `BroadcastFrameSink` 扇出到 Renderer 與編碼器各自的 `LatestFrameBox`，既有 `FramePump`／`LatestFrameBox`／`Renderer`／`EmulatorClient` 一行不改。編碼器（階段 C）產出 Annex-B 存取單元後，由 `RemoteServer.send(accessUnit:keyframe:sequence:)` 經 `/ws/video` 二進位訊息送到手機；手機觸控經 `/ws/input` JSON 回來，`RemoteTouchMessageDecoder` 驗證、`RemoteTouchIdentifierAllocator` 配到 64 到 79 的識別碼，交給階段 D 的 controller 送進既有 `InputQueue.touches(_:)`。狀態轉移全部寫成純 reducer，I/O（亂數、時鐘、bundle、socket）一律注入或隔離到最薄的一層。

**Tech Stack:** Swift 6 toolchain、語言模式 v5、`-strict-concurrency=complete`（`app/Package.swift:4-7`）；Swift Testing；swift-nio 2.101.3（`NIOCore`、`NIOPosix`、`NIOHTTP1`、`NIOWebSocket`）；測試端的 WebSocket 用戶端用 Foundation `URLSessionWebSocketTask`（已實測：握手被 403／409 拒絕時 `task.response as? HTTPURLResponse` 帶正確狀態碼）。

**Spec:** `/Users/hanfourhuang/Projects/mirage/docs/specs/2026-09-12-lan-remote-control-design.md`（已核可）。本計畫只涵蓋第 9 節的階段 A 與 B。階段 C（`RemoteVideoEncoder`）與 D（`RemoteMirrorController`、`AppModel+Remote`、選單、生命週期 guard）不在此，但每個 task 的 Interfaces 區塊寫明 C、D 會呼叫的簽章。

## Global Constraints

- swift-nio 版本固定 `exact: "2.101.3"`，這是 `app/Package.resolved:104-110` 已解析的版本；改完 `Package.swift` 後 `Package.resolved` 不得有任何差異。
- 所有新程式碼放在 `app/Sources/MirageCore/`（`BroadcastFrameSink.swift` 在根目錄，其餘在 `Remote/`）。`MirageCore` 禁止 `import AppKit`／`SwiftUI`／`Metal`／`AVFoundation`／`VideoToolbox`（`app/README.md:329`）。
- 測試放 `app/Tests/MirageCoreTests/Remote/`（`BroadcastFrameSinkTests.swift` 放 `app/Tests/MirageCoreTests/`）。Swift Testing，`@testable import MirageCore`。
- 斷言規則（`app/scripts/ci.sh` 閘門 5）：Bool 不得寫 `#expect(x == true)`／`#expect(x == false)`，一律 `#expect(x)`／`#expect(!x)`；`Optional<Bool>` 用 `#expect(try #require(a).b)`。
- 測試裡不得用 `guard … else { return }` 當 skip（閘門 3）；環境條件一律 `@Test(.enabled(if:))`。本計畫的測試沒有任何環境條件，全部無條件執行。
- 每個檔案 200 到 400 行，上限 800；超過就拆。
- 純函式與 I/O 分開；亂數、時鐘、bundle 讀取、socket 全部可注入或隔離。
- 識別碼分帶：手機 pointerId 映射到 64 到 79 共 16 個；模擬器並發觸控上限 10，超過時拒絕新的 down。Mac 端 `sendTap` 用 0、keymap 從 1 起（`app/Sources/MirageCore/Keymap/KeymapEngine.swift:34-48`）。
- `BroadcastFrameSink` 不改 `FramePump`／`LatestFrameBox`／`Renderer`／`EmulatorClient` 任何一行。
- `RemoteServer`：只接受一條配對連線（`/ws/video` 與 `/ws/input` 各一條），同路徑第二條回 409；token 錯回 403；`GET /` 帶正確 token 回 viewer.html；`ping` 原封 echo；送出佇列超過 3 幀時丟整個 GOP 到下一個 keyframe 並計數。
- 協定（spec 第 4 節）：`/ws/video` 每則二進位訊息 = 8 bytes 送出時間（monotonic 奈秒，big-endian）＋ 4 bytes 幀序號 ＋ 1 byte keyframe 旗標 ＋ Annex-B；`/ws/input` JSON `{"t":1234.5,"id":7,"type":"down|move|up|cancel","x":0.49,"y":0.75}` 與 `{"type":"ping","t":1234.5}`。
- 真實素材（ffmpeg 7.1 h264_videotoolbox，1080×2400）：SPS baseline `27420032ab40220096f2e8`／PPS `28ce3c80`；SPS high `27640032ac568044012de5d0`／PPS `28ee3cb0`。改寫後的預期值已用 spike 的 `rewrite_sps` 算出，寫在 Task 5。
- 每個 task 最後一步 commit，訊息用繁體中文 conventional commits（`feat:`／`test:`／`chore:`），不加任何 attribution 行。
- 執行指令一律在 `app/` 目錄：`cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter <SuiteName>`。

---

## 檔案結構

| 檔案 | 職責 | Task |
|---|---|---|
| `app/Package.swift`（修改） | 宣告 swift-nio 依賴、`MirageCore` 加四個 NIO product、加 `Resources/remote` 資源 | 1、12 |
| `app/Sources/MirageCore/BroadcastFrameSink.swift` | `FrameSink` decorator：`put` 扇出、`takeLatest`／`stats` 代理主 sink | 2 |
| `app/Sources/MirageCore/Remote/PairingToken.swift` | 128-bit token 產生（亂數注入）、解析、常數時間比對 | 3 |
| `app/Sources/MirageCore/Remote/H264Nal.swift` | Annex-B 切分／合併、NAL 型別、存取單元與 SPS/PPS 快取打包 | 4 |
| `app/Sources/MirageCore/Remote/H264Rbsp.swift` | emulation prevention 往返、bit reader、Exp-Golomb writer | 5 |
| `app/Sources/MirageCore/Remote/H264SpsRewriter.swift` | SPS 解析與 VUI bitstream_restriction 注入，冪等 | 6 |
| `app/Sources/MirageCore/Remote/RemoteTouchMessage.swift` | `/ws/input` JSON → `RemoteInputMessage`，驗證型別、識別碼、座標 | 7 |
| `app/Sources/MirageCore/Remote/RemoteTouchIdentifierAllocator.swift` | pointerId → 64 到 79 配置／釋放、上限 10、斷線全放開 | 8 |
| `app/Sources/MirageCore/Remote/RemoteSessionState.swift` | 配對連線 reducer（等待配對 → 已連線 → 已斷線） | 9 |
| `app/Sources/MirageCore/Remote/RemoteVideoMessage.swift` | 13-byte 標頭編碼／解碼 | 10 |
| `app/Sources/MirageCore/Remote/RemoteVideoQueue.swift` | 送出佇列：滿了丟整個 GOP、等下一個 keyframe、計數 | 10 |
| `app/Sources/MirageCore/Remote/RemoteRequestRouter.swift` | 純路由：method、路徑、token、連線狀態 → 決定 | 11 |
| `app/Sources/MirageCore/Resources/remote/viewer.html` | 手機頁面 | 12 |
| `app/Sources/MirageCore/Remote/RemoteViewerPage.swift` | 從 `Bundle.module` 讀 viewer.html（唯一不可單元測試的薄層） | 12 |
| `app/Sources/MirageCore/Remote/RemoteServerCore.swift` | 鎖保護的可變狀態：session、佇列、allocator、統計、log 節流 | 13 |
| `app/Sources/MirageCore/Remote/RemoteServer.swift` | 公開 API、`ServerBootstrap`、accept 迴圈、start／stop | 13 |
| `app/Sources/MirageCore/Remote/RemoteServer+Connections.swift` | HTTP 回應、video 寫出迴圈、input 讀入迴圈 | 13 |

---

### Task 1: `Package.swift` 宣告 swift-nio

**Files:**
- Modify: `app/Package.swift:12-25`

**Interfaces:**
- Consumes: `app/Package.resolved:104-110`（swift-nio 2.101.3 已在解析圖裡）。
- Produces: `MirageCore` 可 `import NIOCore`、`NIOPosix`、`NIOHTTP1`、`NIOWebSocket`；Task 13 依賴。

- [ ] **Step 1: 先確認現在 import 不了（這是 spec 第 3 節的前提，先驗再改）**

在 `app/Sources/MirageCore/Remote/` 建暫時檔 `NIOImportProbe.swift`（此檔在 Step 4 刪除）：

```swift
import NIOWebSocket

enum NIOImportProbe {
    static let frameSize = WebSocketFrame(fin: true, opcode: .binary, data: .init()).length
}
```

Run: `cd /Users/hanfourhuang/Projects/mirage/app && mkdir -p Sources/MirageCore/Remote && swift build --target MirageCore 2>&1 | tail -5`
Expected: FAIL，錯誤含 `no such module 'NIOWebSocket'`。

- [ ] **Step 2: 補依賴宣告**

把 `app/Package.swift` 的 `dependencies` 與 `MirageCore` target 改成：

```swift
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift.git", exact: "1.27.5"),
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0"),
        // P1-e：SPSC 無鎖環形緩衝需要 atomic 讀寫索引。1.3.1 已存在於 Package.resolved
        // （grpc-swift 的傳遞依賴），此處只是宣告成可 import 的 product，不引入新的網路依賴。
        .package(url: "https://github.com/apple/swift-atomics.git", exact: "1.3.1"),
        // 手機遙控（2026-09-12）：RemoteServer 需要 NIOHTTP1 與 NIOWebSocket。2.101.3 已是
        // grpc-swift 的傳遞依賴（Package.resolved 解析圖裡），這裡只宣告成可 import 的 product，
        // 不引入新版本；Package.resolved 改完後必須零差異。
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
    ],
    targets: [
        .target(
            name: "MirageCore",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
            ],
```

其餘行（`resources:`、`swiftSettings:` 與其他 target）維持原樣。

- [ ] **Step 3: 建置並確認解析圖沒動**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift build --target MirageCore 2>&1 | tail -3 && git diff --exit-code Package.resolved && echo RESOLVED-UNCHANGED`
Expected: `Compiling`／`Build complete`，最後一行 `RESOLVED-UNCHANGED`。若 `Package.resolved` 有差異，代表版本寫錯，回頭對 `Package.resolved:109` 的 `"version" : "2.101.3"`。

- [ ] **Step 4: 刪掉探針檔，確認整包測試 target 仍能建**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && rm Sources/MirageCore/Remote/NIOImportProbe.swift && swift build --build-tests 2>&1 | tail -3`
Expected: `Build complete`。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Package.swift && git commit -m "chore: MirageCore 宣告 swift-nio 2.101.3 的 NIOCore/NIOPosix/NIOHTTP1/NIOWebSocket"
```

---

### Task 2: `BroadcastFrameSink`

**Files:**
- Create: `app/Sources/MirageCore/BroadcastFrameSink.swift`
- Test: `app/Tests/MirageCoreTests/BroadcastFrameSinkTests.swift`

**Interfaces:**
- Consumes: `FrameSink`（`app/Sources/MirageCore/FrameSink.swift:5-9`：`put(_:)`、`takeLatest() -> Frame?`、`stats() -> FrameCounterSnapshot`）；`LatestFrameBox`（`LatestFrameBox.swift:17-49`）；`Frame`（`Frame.swift:3-40`，`isValid` 要求 `rgba.count == width * height * 4`）；`FrameCounterSnapshot(arrived:dropped:rejected:)`（`LatestFrameBox.swift:3-13`）。
- Produces（階段 D 的 `AppModel+Remote` 用）：

```swift
public final class BroadcastFrameSink: FrameSink, @unchecked Sendable {
    public let primary: any FrameSink        // Renderer 用的既有 sink（AppModel.box，AppModel.swift:14）
    public let secondary: LatestFrameBox     // 編碼器用，階段 C 的 RemoteVideoEncoder 從這裡 takeLatest()
    public init(primary: any FrameSink, secondary: LatestFrameBox = LatestFrameBox())
    public func put(_ frame: Frame)          // 兩邊都收到同一個 Frame 值（Data 是 CoW，不多拷貝像素）
    public func takeLatest() -> Frame?       // 代理 primary
    public func stats() -> FrameCounterSnapshot  // 代理 primary
}
```

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageCoreTests/BroadcastFrameSinkTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

@Suite struct BroadcastFrameSinkTests {
    private func frame(_ tag: UInt8) -> Frame {
        Frame(width: 1, height: 1, rgba: Data([tag, 0, 0, 255]))
    }

    @Test func putFansOutToBothSinks() {
        let primary = LatestFrameBox()
        let secondary = LatestFrameBox()
        let sink = BroadcastFrameSink(primary: primary, secondary: secondary)
        sink.put(frame(1))
        sink.put(frame(2))
        #expect(primary.takeLatest() == frame(2))
        #expect(secondary.takeLatest() == frame(2))
        #expect(primary.stats().arrived == 2)
        #expect(secondary.stats().arrived == 2)
    }

    @Test func takeLatestDrainsOnlyPrimary() {
        let sink = BroadcastFrameSink(primary: LatestFrameBox())
        sink.put(frame(7))
        #expect(sink.takeLatest() == frame(7))
        #expect(sink.takeLatest() == nil)
        #expect(sink.secondary.takeLatest() == frame(7))
    }

    @Test func statsProxyPrimaryNotSecondary() {
        let primary = LatestFrameBox()
        let sink = BroadcastFrameSink(primary: primary)
        sink.put(frame(1))
        sink.put(frame(2))
        _ = sink.secondary.takeLatest()
        sink.put(frame(3))
        #expect(sink.stats() == primary.stats())
        #expect(sink.stats().dropped == 2)
        #expect(sink.secondary.stats().dropped == 1)
    }

    @Test func invalidFrameIsRejectedByBothSides() {
        let sink = BroadcastFrameSink(primary: LatestFrameBox())
        sink.put(Frame(width: 2, height: 2, rgba: Data(count: 3)))
        #expect(sink.takeLatest() == nil)
        #expect(sink.secondary.takeLatest() == nil)
        #expect(sink.stats().rejected == 1)
        #expect(sink.secondary.stats().rejected == 1)
    }

    @Test func worksWithFrameQueueAsPrimary() {
        let queue = FrameQueue(depth: 2)
        let sink = BroadcastFrameSink(primary: queue)
        sink.put(frame(1))
        sink.put(frame(2))
        #expect(sink.takeLatest() == frame(1))
        #expect(sink.takeLatest() == frame(2))
        #expect(sink.secondary.takeLatest() == frame(2))
    }

    @Test func concurrentPutAndTakeDoesNotCrash() async {
        let sink = BroadcastFrameSink(primary: LatestFrameBox())
        async let producer: () = {
            for i in 0..<5000 { sink.put(self.frame(UInt8(i % 256))) }
        }()
        async let consumer: () = {
            for _ in 0..<5000 { _ = sink.takeLatest(); _ = sink.secondary.takeLatest() }
        }()
        _ = await (producer, consumer)
        #expect(sink.stats().arrived == 5000)
        #expect(sink.secondary.stats().arrived == 5000)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter BroadcastFrameSinkTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'BroadcastFrameSink' in scope`。

- [ ] **Step 3: 實作**

`app/Sources/MirageCore/BroadcastFrameSink.swift`：

```swift
/// 幀扇出 decorator（手機遙控，spec 第 2 節設計決定 1）。
///
/// `put()` 把同一個 `Frame` 值交給 Renderer 用的 `primary` 與編碼器用的 `secondary`；
/// `takeLatest()`／`stats()` 只代理 `primary`，所以 `FramePump` 與 `Renderer` 看到的行為
/// 與直接用 `primary` 完全相同。遙控關閉時 `AppModel` 不建這個型別、直接用原本的 sink。
///
/// `Frame.rgba` 是 `Data`，兩邊持有同一份底層儲存，不多一次像素拷貝。
/// `secondary` 固定是 `LatestFrameBox`：編碼器依自己的節奏取最新幀，drop-late 是它要的語意。
/// 本型別自己沒有任何可變狀態，兩個子 sink 各自負責自己的鎖。
public final class BroadcastFrameSink: FrameSink, @unchecked Sendable {
    public let primary: any FrameSink
    public let secondary: LatestFrameBox

    public init(primary: any FrameSink, secondary: LatestFrameBox = LatestFrameBox()) {
        self.primary = primary
        self.secondary = secondary
    }

    public func put(_ frame: Frame) {
        primary.put(frame)
        secondary.put(frame)
    }

    public func takeLatest() -> Frame? {
        primary.takeLatest()
    }

    public func stats() -> FrameCounterSnapshot {
        primary.stats()
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter BroadcastFrameSinkTests 2>&1 | tail -5`
Expected: `Test run with 6 tests passed`。

- [ ] **Step 5: 確認沒動到禁止修改的檔案**

Run: `cd /Users/hanfourhuang/Projects/mirage && git status --porcelain app/Sources/MirageCore/FramePump.swift app/Sources/MirageCore/LatestFrameBox.swift app/Sources/MirageCore/EmulatorClient.swift app/Sources/MirageShell/Renderer.swift`
Expected: 無輸出。

- [ ] **Step 6: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageCore/BroadcastFrameSink.swift app/Tests/MirageCoreTests/BroadcastFrameSinkTests.swift && git commit -m "feat: BroadcastFrameSink 把幀扇出到 Renderer 與編碼器各自的 sink"
```

---

### Task 3: `PairingToken`

**Files:**
- Create: `app/Sources/MirageCore/Remote/PairingToken.swift`
- Test: `app/Tests/MirageCoreTests/Remote/PairingTokenTests.swift`

**Interfaces:**
- Consumes: 無既有型別。亂數注入比照 `EmulatorDiscovery.discoverToken(port:directory:isAlive:readFiles:)` 的預設參數寫法（`EmulatorDiscovery.swift:87-91`）。
- Produces（Task 11、13 與階段 D 的 `AppModel+Remote` 用）：

```swift
public struct PairingToken: Sendable, Equatable {
    public static let byteCount = 16                  // 128-bit
    public let value: String                          // 32 個小寫十六進位字元
    public init?(value: String)                       // 格式不合回 nil
    public static func generate(randomBytes: (Int) -> [UInt8] = systemRandomBytes) -> PairingToken
    public static func systemRandomBytes(_ count: Int) -> [UInt8]
    public func matches(_ candidate: String?) -> Bool // 常數時間，nil 一律 false
}
```

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageCoreTests/Remote/PairingTokenTests.swift`：

```swift
import Testing
@testable import MirageCore

@Suite struct PairingTokenTests {
    @Test func generateUsesSixteenInjectedBytesAsLowercaseHex() {
        var requested: [Int] = []
        let token = PairingToken.generate { count in
            requested.append(count)
            return Array(0..<UInt8(count)).map { $0 &* 17 }
        }
        #expect(requested == [16])
        #expect(token.value == "00112233445566778899aabbccddeeff")
        #expect(token.value.count == 32)
    }

    @Test func systemRandomProducesDistinctTokens() {
        let a = PairingToken.generate()
        let b = PairingToken.generate()
        #expect(a != b)
        #expect(PairingToken(value: a.value) == a)
    }

    @Test(arguments: [
        "", "0011", "00112233445566778899AABBCCDDEEFF",
        "00112233445566778899aabbccddeef", "00112233445566778899aabbccddeeffa",
        "0011223344556677889gaabbccddeeff", "00 12233445566778899aabbccddeeff",
    ])
    func initRejectsMalformedValues(_ raw: String) {
        #expect(PairingToken(value: raw) == nil)
    }

    @Test func matchesOnlyTheExactValue() throws {
        let token = try #require(PairingToken(value: "00112233445566778899aabbccddeeff"))
        #expect(token.matches("00112233445566778899aabbccddeeff"))
        #expect(!token.matches(nil))
        #expect(!token.matches(""))
        #expect(!token.matches("00112233445566778899aabbccddeef"))
        #expect(!token.matches("00112233445566778899aabbccddeeffa"))
        #expect(!token.matches("00112233445566778899aabbccddeefe"))
        #expect(!token.matches("00112233445566778899AABBCCDDEEFF"))
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter PairingTokenTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'PairingToken' in scope`。

- [ ] **Step 3: 實作**

`app/Sources/MirageCore/Remote/PairingToken.swift`：

```swift
import Foundation

/// 手機配對用的一次性 token（spec 第 5 節）。
///
/// 128-bit 亂數、32 個小寫十六進位字元，放在網址 `?t=` 上。伺服器只在 `GET /` 與兩條
/// WebSocket 升級時比對；比對是常數時間，不讓回應時間洩漏前綴長度。
/// 亂數來源可注入（`randomBytes`），讓測試能給固定位元組而不必 mock `SystemRandomNumberGenerator`。
public struct PairingToken: Sendable, Equatable {
    public static let byteCount = 16
    private static let hexLength = byteCount * 2
    private static let hexDigits = Set("0123456789abcdef")

    public let value: String

    /// 只接受 32 個小寫十六進位字元。大寫、長度不對、非十六進位都回 nil。
    public init?(value: String) {
        guard value.count == Self.hexLength, value.allSatisfy({ Self.hexDigits.contains($0) }) else {
            return nil
        }
        self.value = value
    }

    private init(bytes: [UInt8]) {
        value = bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func generate(randomBytes: (Int) -> [UInt8] = systemRandomBytes) -> PairingToken {
        let bytes = randomBytes(byteCount)
        precondition(bytes.count == byteCount, "randomBytes 必須回傳 \(byteCount) 個位元組")
        return PairingToken(bytes: bytes)
    }

    public static func systemRandomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// 常數時間比對：長度不同直接 false，長度相同時把全部位元組 XOR 後 OR 起來，
    /// 不在第一個不同的位元組提早返回。
    public func matches(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        let expected = Array(value.utf8)
        let actual = Array(candidate.utf8)
        guard expected.count == actual.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(expected, actual) { difference |= a ^ b }
        return difference == 0
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter PairingTokenTests 2>&1 | tail -5`
Expected: `Test run with 10 tests passed`（4 條具名 ＋ 7 條參數化算 1 條 test、10 個案例；Swift Testing 計數若顯示 4 tests 也算通過，重點是 0 failures）。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageCore/Remote/PairingToken.swift app/Tests/MirageCoreTests/Remote/PairingTokenTests.swift && git commit -m "feat: PairingToken 產生 128-bit 配對 token 並常數時間比對"
```

---

### Task 4: `H264Nal`：Annex-B 切分、NAL 型別、存取單元打包

**Files:**
- Create: `app/Sources/MirageCore/Remote/H264Nal.swift`
- Test: `app/Tests/MirageCoreTests/Remote/H264NalTests.swift`

**Interfaces:**
- Consumes: 無既有型別。演算法移植自 spike `relay.py` 的 `NALSplitter.feed`（切分）與 `AccessUnits.push/flush`（SPS/PPS 快取、IDR 前綴參數集）。VideoToolbox 一個 sample buffer 就是一幀，所以這裡的打包器一次收一幀的全部 NAL，不需要 spike 那種靠 AUD 分界的增量解析。
- Produces（階段 C 的 `RemoteVideoEncoder` 用 `H264AccessUnitPacker.pack`；Task 13 的測試用 `H264Nal.split`）：

```swift
public enum H264NalType: UInt8, Sendable {
    case nonIdrSlice = 1, idrSlice = 5, sei = 6, sps = 7, pps = 8, accessUnitDelimiter = 9
}
public enum H264Nal {
    public static let startCode = Data([0, 0, 0, 1])
    public static func rawType(of nal: Data) -> UInt8?          // nal[0] & 0x1f；空或 forbidden_zero_bit=1 回 nil
    public static func type(of nal: Data) -> H264NalType?        // 已知型別才回值
    public static func split(annexB: Data) -> [Data]             // 00 00 01 與 00 00 00 01 都當分界，丟掉空片段
    public static func join(_ nals: [Data]) -> Data              // 每個前綴 4-byte 起始碼
}
public struct H264AccessUnit: Sendable, Equatable {
    public let nals: [Data]            // 不含起始碼；keyframe 時前兩個是 SPS、PPS
    public let isKeyframe: Bool
    public var annexB: Data { H264Nal.join(nals) }
}
public struct H264AccessUnitPacker: Sendable, Equatable {
    public let sps: Data?
    public let pps: Data?
    public init(sps: Data? = nil, pps: Data? = nil)
    /// 一幀的全部 NAL 進來。SPS/PPS 會被記住（SPS 先經 rewriteSps，回 nil 時保留原樣）；
    /// 含 IDR 的幀輸出時前綴最近的 SPS＋PPS；沒有 VCL（型別 1 或 5）回 nil；
    /// IDR 但還沒有 SPS/PPS 也回 nil（丟這一幀，等下一個帶參數集的）。
    public func pack(_ nals: [Data], rewriteSps: (Data) -> Data?) -> (packer: H264AccessUnitPacker, unit: H264AccessUnit?)
}
```

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageCoreTests/Remote/H264NalTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

@Suite struct H264NalTests {
    private let start = H264Nal.startCode
    private let short = Data([0, 0, 1])

    @Test func splitHandlesBothStartCodeLengthsAndDropsEmptyPieces() {
        let expected = [Data([0x67, 0x61, 0x62, 0x63]), Data([0x68, 0x78, 0x79]),
                        Data([0x65, 0x00, 0x00, 0x03, 0x01, 0x7a]), Data([0x41, 0x65, 0x6e, 0x64])]
        let stream = start + expected[0] + short + expected[1] + start + expected[2] + short + expected[3]
        #expect(H264Nal.split(annexB: stream) == expected)
        #expect(H264Nal.split(annexB: Data()) == [])
        #expect(H264Nal.split(annexB: start) == [])
        #expect(H264Nal.split(annexB: start + start + expected[0]) == [expected[0]])
    }

    @Test func splitIgnoresBytesBeforeFirstStartCode() {
        #expect(H264Nal.split(annexB: Data([0xaa, 0xbb]) + start + Data([0x65, 0x01])) == [Data([0x65, 0x01])])
    }

    @Test func joinRoundTripsThroughSplit() {
        let nals = [Data([0x67, 0x42]), Data([0x68, 0xce]), Data([0x65, 0x88, 0x00, 0x00, 0x03, 0x00])]
        let joined = H264Nal.join(nals)
        #expect(joined.prefix(4) == start)
        #expect(H264Nal.split(annexB: joined) == nals)
    }

    @Test func nalTypeReadsLowFiveBitsAndRejectsForbiddenBit() {
        #expect(H264Nal.type(of: Data([0x67])) == .sps)
        #expect(H264Nal.type(of: Data([0x27])) == .sps)
        #expect(H264Nal.type(of: Data([0x68])) == .pps)
        #expect(H264Nal.type(of: Data([0x65])) == .idrSlice)
        #expect(H264Nal.type(of: Data([0x41])) == .nonIdrSlice)
        #expect(H264Nal.type(of: Data([0x06])) == .sei)
        #expect(H264Nal.type(of: Data([0x09])) == .accessUnitDelimiter)
        #expect(H264Nal.rawType(of: Data([0x0c])) == 12)
        #expect(H264Nal.type(of: Data([0x0c])) == nil)
        #expect(H264Nal.type(of: Data()) == nil)
        #expect(H264Nal.rawType(of: Data([0xe5])) == nil)
    }

    @Test func packerPrefixesCachedParameterSetsOnKeyframesOnly() {
        let sps = Data([0x67, 0x73, 0x70, 0x73]), pps = Data([0x68, 0x70, 0x70, 0x73])
        let sei = Data([0x06, 0x73]), idr1 = Data([0x65, 0x31]), idr2 = Data([0x65, 0x32])
        let p1 = Data([0x41, 0x31]), p2 = Data([0x41, 0x32])
        let identity: (Data) -> Data? = { $0 }

        let (afterKey, key) = H264AccessUnitPacker().pack([sps, pps, sei, idr1, idr2], rewriteSps: identity)
        #expect(key == H264AccessUnit(nals: [sps, pps, sei, idr1, idr2], isKeyframe: true))
        #expect(afterKey.sps == sps)
        #expect(afterKey.pps == pps)

        let (afterDelta, delta) = afterKey.pack([p1, p2], rewriteSps: identity)
        #expect(delta == H264AccessUnit(nals: [p1, p2], isKeyframe: false))
        #expect(afterDelta == afterKey)

        let (_, secondKey) = afterDelta.pack([idr1], rewriteSps: identity)
        #expect(secondKey == H264AccessUnit(nals: [sps, pps, idr1], isKeyframe: true))
    }

    @Test func packerRewritesSpsOnceAndKeepsOriginalWhenRewriteFails() {
        let sps = Data([0x67, 0x01]), pps = Data([0x68, 0x01]), idr = Data([0x65, 0x01])
        var seen: [Data] = []
        let (rewritten, unit) = H264AccessUnitPacker().pack([sps, pps, idr]) { input in
            seen.append(input)
            return Data([0x67, 0xff])
        }
        #expect(seen == [sps])
        #expect(rewritten.sps == Data([0x67, 0xff]))
        #expect(unit?.nals.first == Data([0x67, 0xff]))

        let (kept, _) = H264AccessUnitPacker().pack([sps, pps, idr], rewriteSps: { _ in nil })
        #expect(kept.sps == sps)
    }

    @Test func packerReturnsNilWithoutVclOrWithoutParameterSets() {
        let identity: (Data) -> Data? = { $0 }
        let (p, none) = H264AccessUnitPacker().pack([Data([0x06, 0x01]), Data([0x09, 0xf0])], rewriteSps: identity)
        #expect(none == nil)
        #expect(p == H264AccessUnitPacker())

        let (q, dropped) = H264AccessUnitPacker().pack([Data([0x65, 0x01])], rewriteSps: identity)
        #expect(dropped == nil)
        #expect(q == H264AccessUnitPacker())

        let (_, deltaOnly) = H264AccessUnitPacker().pack([Data([0x41, 0x01])], rewriteSps: identity)
        #expect(deltaOnly == H264AccessUnit(nals: [Data([0x41, 0x01])], isKeyframe: false))
    }

    @Test func packerUsesNewestParameterSetsAndDropsAudFromOutput() {
        let identity: (Data) -> Data? = { $0 }
        let old = [Data([0x67, 0x01]), Data([0x68, 0x01])], new = [Data([0x67, 0x02]), Data([0x68, 0x02])]
        let (p1, _) = H264AccessUnitPacker().pack(old, rewriteSps: identity)
        let (p2, unit) = p1.pack([Data([0x09, 0xf0])] + new + [Data([0x65, 0x09])], rewriteSps: identity)
        #expect(p2.sps == new[0])
        #expect(unit == H264AccessUnit(nals: new + [Data([0x65, 0x09])], isKeyframe: true))
    }

    @Test func realParameterSetsSplitAndJoin() {
        let sps = Data([0x27, 0x42, 0x00, 0x32, 0xab, 0x40, 0x22, 0x00, 0x96, 0xf2, 0xe8])
        let pps = Data([0x28, 0xce, 0x3c, 0x80])
        #expect(H264Nal.type(of: sps) == .sps)
        #expect(H264Nal.type(of: pps) == .pps)
        #expect(H264Nal.split(annexB: H264Nal.join([sps, pps])) == [sps, pps])
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter H264NalTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'H264Nal' in scope`。

- [ ] **Step 3: 實作**

`app/Sources/MirageCore/Remote/H264Nal.swift`：

```swift
import Foundation

/// 本專案會碰到的 NAL 型別（H.264 表 7-1 的子集）。
public enum H264NalType: UInt8, Sendable {
    case nonIdrSlice = 1
    case idrSlice = 5
    case sei = 6
    case sps = 7
    case pps = 8
    case accessUnitDelimiter = 9
}

/// Annex-B 位元組層的純函式：起始碼切分、合併、型別判斷。
public enum H264Nal {
    public static let startCode = Data([0, 0, 0, 1])
    private static let typeMask: UInt8 = 0x1f
    private static let forbiddenBit: UInt8 = 0x80

    /// `nal_unit_type`（低五位）。空資料或 forbidden_zero_bit 為 1 都回 nil。
    public static func rawType(of nal: Data) -> UInt8? {
        guard let header = nal.first, header & forbiddenBit == 0 else { return nil }
        return header & typeMask
    }

    public static func type(of nal: Data) -> H264NalType? {
        rawType(of: nal).flatMap(H264NalType.init(rawValue:))
    }

    /// 以 `00 00 01`（三或四位元組起始碼皆可）切分。第一個起始碼之前的位元組與空片段都丟掉。
    public static func split(annexB: Data) -> [Data] {
        let bytes = [UInt8](annexB)
        var boundaries: [(start: Int, end: Int)] = []   // 起始碼在 bytes 裡的 [start, end)
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let start = (i > 0 && bytes[i - 1] == 0) ? i - 1 : i
                boundaries.append((start, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var nals: [Data] = []
        for (index, boundary) in boundaries.enumerated() {
            let end = index + 1 < boundaries.count ? boundaries[index + 1].start : bytes.count
            if end > boundary.end { nals.append(Data(bytes[boundary.end..<end])) }
        }
        return nals
    }

    public static func join(_ nals: [Data]) -> Data {
        nals.reduce(into: Data()) { out, nal in
            out.append(startCode)
            out.append(nal)
        }
    }
}

/// 一幀的存取單元。`nals` 不含起始碼；keyframe 時前兩個是 SPS、PPS。
public struct H264AccessUnit: Sendable, Equatable {
    public let nals: [Data]
    public let isKeyframe: Bool

    public init(nals: [Data], isKeyframe: Bool) {
        self.nals = nals
        self.isKeyframe = isKeyframe
    }

    public var annexB: Data { H264Nal.join(nals) }
}

/// 把編碼器吐出的一幀 NAL 打包成存取單元，並快取最近的 SPS/PPS（spec 第 4 節：keyframe
/// 訊息必須含 SPS＋PPS＋IDR）。值型別：`pack` 回傳新的 packer，呼叫端持有最新那一份。
public struct H264AccessUnitPacker: Sendable, Equatable {
    public let sps: Data?
    public let pps: Data?

    public init(sps: Data? = nil, pps: Data? = nil) {
        self.sps = sps
        self.pps = pps
    }

    public func pack(_ nals: [Data], rewriteSps: (Data) -> Data?)
        -> (packer: H264AccessUnitPacker, unit: H264AccessUnit?)
    {
        var sps = self.sps
        var pps = self.pps
        var slices: [Data] = []
        var hasVcl = false
        var hasIdr = false
        for nal in nals {
            switch H264Nal.type(of: nal) {
            case .sps?: sps = rewriteSps(nal) ?? nal
            case .pps?: pps = nal
            case .accessUnitDelimiter?: continue
            case .idrSlice?: hasVcl = true; hasIdr = true; slices.append(nal)
            case .nonIdrSlice?: hasVcl = true; slices.append(nal)
            case .sei?, .none: slices.append(nal)
            }
        }
        let next = H264AccessUnitPacker(sps: sps, pps: pps)
        guard hasVcl else { return (next, nil) }
        guard hasIdr else { return (next, H264AccessUnit(nals: slices, isKeyframe: false)) }
        guard let sps, let pps else { return (next, nil) }
        return (next, H264AccessUnit(nals: [sps, pps] + slices, isKeyframe: true))
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter H264NalTests 2>&1 | tail -5`
Expected: `Test run with 9 tests passed`。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageCore/Remote/H264Nal.swift app/Tests/MirageCoreTests/Remote/H264NalTests.swift && git commit -m "feat: H264Nal 切分 Annex-B 並打包含 SPS/PPS 的存取單元"
```

---

### Task 5: `H264Rbsp`：emulation prevention 往返、bit reader、Exp-Golomb

**Files:**
- Create: `app/Sources/MirageCore/Remote/H264Rbsp.swift`
- Test: `app/Tests/MirageCoreTests/Remote/H264RbspTests.swift`

**Interfaces:**
- Consumes: 無既有型別。移植 spike `relay.py` 的 `_Bits`、`_ue`、`_unescape`、`_escape`、`_finish_rbsp`。
- Produces（Task 6 用）：

```swift
public enum H264SpsError: Error, Equatable {
    case notSps, truncated, oversizedExpGolomb, invalidEmulationPrevention
    case invalidField(String), invalidTrailingBits
}
public enum H264Rbsp {
    public static func unescape(_ data: Data) throws -> Data   // 移除 00 00 03；03 後不是 00..03 或在結尾 → invalidEmulationPrevention
    public static func escape(_ data: Data) -> Data            // 00 00 後接 00..03 時插入 03
    public static func bits(of data: Data) -> [Bool]           // MSB first
    public static func ueBits(_ value: UInt32) -> [Bool]       // Exp-Golomb 無號編碼
    public static func finishRbsp(_ bits: [Bool]) -> Data      // 補 stop bit 1 與 0 到位元組邊界
}
public struct H264BitReader {
    public init(bits: [Bool])
    public let bits: [Bool]
    public private(set) var position: Int
    public mutating func u(_ width: Int) throws -> UInt32      // width 0...32；不夠位元 → truncated
    public mutating func flag() throws -> Bool
    public mutating func ue() throws -> UInt32                 // 前導零超過 31 → oversizedExpGolomb
    public mutating func se() throws -> Int32
}
```

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageCoreTests/Remote/H264RbspTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

@Suite struct H264RbspTests {
    private func hex(_ s: String) -> Data {
        var out = Data()
        var chars = Array(s)
        while chars.count >= 2 {
            out.append(UInt8(String(chars[0...1]), radix: 16)!)
            chars.removeFirst(2)
        }
        return out
    }

    private func bitString(_ bits: [Bool]) -> String { bits.map { $0 ? "1" : "0" }.joined() }
    private func bits(_ s: String) -> [Bool] { s.map { $0 == "1" } }

    /// 預期值由 spike 的 `_escape` 算出（`python3`，四種 00 00 XX 尾巴各一）。
    @Test(arguments: [
        ("0000000000000001", "0000030000030000030001"),
        ("0000010000000001", "0000030100000300000301"),
        ("0000020000000001", "0000030200000300000301"),
        ("0000030000000001", "0000030300000300000301"),
    ])
    func escapeInsertsPreventionBytesAndUnescapeRemovesThem(raw: String, escaped: String) throws {
        #expect(H264Rbsp.escape(hex(raw)) == hex(escaped))
        #expect(try H264Rbsp.unescape(hex(escaped)) == hex(raw))
    }

    @Test func escapeLeavesDataWithoutZeroRunsAlone() throws {
        let plain = hex("420032ab40220096f2e8")
        #expect(H264Rbsp.escape(plain) == plain)
        #expect(try H264Rbsp.unescape(plain) == plain)
    }

    @Test(arguments: ["000003ff", "000003", "00000304"])
    func unescapeRejectsInvalidPreventionByte(raw: String) {
        #expect(throws: H264SpsError.invalidEmulationPrevention) { try H264Rbsp.unescape(hex(raw)) }
    }

    @Test func bitsAreMostSignificantFirst() {
        #expect(bitString(H264Rbsp.bits(of: hex("a1"))) == "10100001")
        #expect(H264Rbsp.bits(of: Data()).isEmpty)
    }

    @Test(arguments: [(0, "1"), (1, "010"), (2, "011"), (3, "00100"), (16, "000010001"), (255, "00000000100000000")])
    func ueBitsMatchExpGolomb(value: UInt32, expected: String) {
        #expect(bitString(H264Rbsp.ueBits(value)) == expected)
    }

    @Test func finishRbspAppendsStopBitAndPads() {
        #expect(H264Rbsp.finishRbsp(bits("101")) == hex("b0"))
        #expect(H264Rbsp.finishRbsp(bits("1111111")) == hex("ff"))
        #expect(H264Rbsp.finishRbsp(bits("11111111")) == hex("ff80"))
        #expect(H264Rbsp.finishRbsp([]) == hex("80"))
    }

    @Test func readerDecodesFixedExpGolombAndSigned() throws {
        var reader = H264BitReader(bits: bits("10100001" + "1" + "010" + "011" + "000010001" + "011" + "00100"))
        #expect(try reader.u(8) == 0xa1)
        #expect(try reader.ue() == 0)
        #expect(try reader.ue() == 1)
        #expect(try reader.ue() == 2)
        #expect(try reader.ue() == 16)
        #expect(try reader.se() == -1)
        #expect(try reader.se() == 2)
        #expect(reader.position == reader.bits.count)
        #expect(try reader.u(0) == 0)
    }

    @Test func readerFlagAndPositionAdvance() throws {
        var reader = H264BitReader(bits: bits("10"))
        #expect(try reader.flag())
        #expect(reader.position == 1)
        #expect(try !reader.flag())
        #expect(reader.position == 2)
    }

    @Test func readerThrowsOnTruncationAndOversizedCodes() {
        let shortBits = bits("101")
        #expect(throws: H264SpsError.truncated) {
            var reader = H264BitReader(bits: shortBits)
            _ = try reader.u(4)
        }
        #expect(throws: H264SpsError.truncated) {
            var reader = H264BitReader(bits: [])
            _ = try reader.ue()
        }
        let oversized = Array(repeating: false, count: 33) + [true]
        #expect(throws: H264SpsError.oversizedExpGolomb) {
            var reader = H264BitReader(bits: oversized)
            _ = try reader.ue()
        }
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter H264RbspTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'H264Rbsp' in scope`。

- [ ] **Step 3: 實作**

`app/Sources/MirageCore/Remote/H264Rbsp.swift`：

```swift
import Foundation

/// SPS 解析與改寫共用的錯誤。改寫失敗時呼叫端（`H264AccessUnitPacker`）保留原 SPS，
/// 手機仍能解碼，只是回到未改寫的 170 ms 延遲；不拋到編碼迴圈外。
public enum H264SpsError: Error, Equatable {
    case notSps
    case truncated
    case oversizedExpGolomb
    case invalidEmulationPrevention
    case invalidField(String)
    case invalidTrailingBits
}

/// RBSP 位元組層：emulation prevention（7.4.1）與 Exp-Golomb（9.1）的純函式。
public enum H264Rbsp {
    private static let preventionByte: UInt8 = 3

    /// `00 00 03` → `00 00`。`03` 之後必須還有一個位元組且 ≤ 3，否則這不是 prevention byte。
    public static func unescape(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for (i, b) in bytes.enumerated() {
            if zeros == 2, b == preventionByte {
                guard i + 1 < bytes.count, bytes[i + 1] <= preventionByte else {
                    throw H264SpsError.invalidEmulationPrevention
                }
                zeros = 0
                continue
            }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return Data(out)
    }

    /// `00 00` 後接 `00`…`03` 時插入 `03`。
    public static func escape(_ data: Data) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 64)
        var zeros = 0
        for b in data {
            if zeros == 2, b <= preventionByte {
                out.append(preventionByte)
                zeros = 0
            }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return Data(out)
    }

    public static func bits(of data: Data) -> [Bool] {
        data.flatMap { byte in (0..<8).map { (byte >> (7 - $0)) & 1 == 1 } }
    }

    /// Exp-Golomb 無號：`value + 1` 的二進位，前面補「位元數 − 1」個 0。
    public static func ueBits(_ value: UInt32) -> [Bool] {
        let code = value + 1
        let width = UInt32.bitWidth - code.leadingZeroBitCount
        let zeros = Array(repeating: false, count: width - 1)
        let digits = (0..<width).map { (code >> UInt32(width - 1 - $0)) & 1 == 1 }
        return zeros + digits
    }

    /// `rbsp_trailing_bits`：一個 1 之後補 0 到位元組邊界。
    public static func finishRbsp(_ bits: [Bool]) -> Data {
        var all = bits + [true]
        while all.count % 8 != 0 { all.append(false) }
        var out = Data(capacity: all.count / 8)
        for start in stride(from: 0, to: all.count, by: 8) {
            let byte = all[start..<start + 8].reduce(UInt8(0)) { ($0 << 1) | ($1 ? 1 : 0) }
            out.append(byte)
        }
        return out
    }
}

/// MSB-first 位元讀取器。值型別，`mutating` 只推進自己的游標，沒有共享狀態。
public struct H264BitReader {
    public let bits: [Bool]
    public private(set) var position: Int = 0
    private static let maxLeadingZeros = 31

    public init(bits: [Bool]) {
        self.bits = bits
    }

    public mutating func u(_ width: Int) throws -> UInt32 {
        precondition((0...32).contains(width), "u() 的寬度必須在 0…32")
        guard position + width <= bits.count else { throw H264SpsError.truncated }
        var value: UInt32 = 0
        for i in 0..<width where bits[position + i] { value |= 1 << UInt32(width - 1 - i) }
        position += width
        return value
    }

    public mutating func flag() throws -> Bool {
        try u(1) == 1
    }

    public mutating func ue() throws -> UInt32 {
        var zeros = 0
        while try u(1) == 0 {
            zeros += 1
            if zeros > Self.maxLeadingZeros { throw H264SpsError.oversizedExpGolomb }
        }
        let suffix = try u(zeros)
        return (1 << UInt32(zeros)) - 1 + suffix
    }

    public mutating func se() throws -> Int32 {
        let code = try ue()
        let magnitude = Int32((code + 1) / 2)
        return code & 1 == 1 ? magnitude : -magnitude
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter H264RbspTests 2>&1 | tail -5`
Expected: 全部通過、0 failures。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageCore/Remote/H264Rbsp.swift app/Tests/MirageCoreTests/Remote/H264RbspTests.swift && git commit -m "feat: H264Rbsp 提供 emulation prevention 往返與 Exp-Golomb 讀寫"
```

---

### Task 6: `H264SpsRewriter`：注入 VUI bitstream_restriction

**Files:**
- Create: `app/Sources/MirageCore/Remote/H264SpsRewriter.swift`
- Test: `app/Tests/MirageCoreTests/Remote/H264SpsRewriterTests.swift`

**Interfaces:**
- Consumes: Task 5 的 `H264Rbsp.unescape/escape/bits/ueBits/finishRbsp`、`H264BitReader`、`H264SpsError`；Task 4 的 `H264Nal.rawType(of:)`、`H264NalType.sps`。
- Produces（階段 C 的 `RemoteVideoEncoder` 把 `H264SpsRewriter.rewriteOrNil` 傳給 `H264AccessUnitPacker.pack(_:rewriteSps:)`）：

```swift
public struct H264SpsSummary: Sendable, Equatable {
    public let profileIdc: UInt8
    public let constraintFlags: UInt8
    public let levelIdc: UInt8
    public let numRefFrames: UInt32
    public let picOrderCntType: UInt32
    public let hasVui: Bool
    public let maxNumReorderFrames: UInt32?     // 沒有 bitstream_restriction 時 nil
    public let maxDecFrameBuffering: UInt32?
}
public enum H264SpsRewriter {
    public static func rewrite(_ sps: Data) throws -> Data   // 輸入輸出都含 NAL header、不含起始碼
    public static func rewriteOrNil(_ sps: Data) -> Data?    // 失敗回 nil，給 packer 用
    public static func summary(of sps: Data) throws -> H264SpsSummary
}
```

改寫規則（spec 第 3 節）：`vui_parameters_present_flag=1`、保留既有 VUI 前段、`bitstream_restriction_flag=1`、`motion_vectors_over_pic_boundaries_flag=1`、`max_bytes_per_pic_denom=0`、`max_bits_per_mb_denom=0`、`log2_max_mv_length_horizontal=16`、`log2_max_mv_length_vertical=16`、`max_num_reorder_frames=0`、`max_dec_frame_buffering=max(1, num_ref_frames)`。已有 restriction 的 SPS 會被整段替換，所以冪等。

- [ ] **Step 1: 寫失敗的測試**

預期輸出全部由 spike 的 `rewrite_sps` 用 `python3` 算出（2026-09-12），不是手算。

`app/Tests/MirageCoreTests/Remote/H264SpsRewriterTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

@Suite struct H264SpsRewriterTests {
    private func hex(_ s: String) -> Data {
        var out = Data()
        var chars = Array(s)
        while chars.count >= 2 {
            out.append(UInt8(String(chars[0...1]), radix: 16)!)
            chars.removeFirst(2)
        }
        return out
    }

    /// 真實素材：ffmpeg 7.1 h264_videotoolbox、1080×2400。
    static let realCases: [(name: String, input: String, output: String, profile: UInt8)] = [
        ("baseline", "27420032ab40220096f2e8", "27420032ab40220096f2f00f08846a", 66),
        ("high", "27640032ac568044012de5d0", "27640032ac568044012de5e01e1108d4", 100),
    ]

    @Test(arguments: realCases)
    func realVideoToolboxSpsGetsZeroReorderRestriction(_ c: (name: String, input: String, output: String, profile: UInt8)) throws {
        let input = hex(c.input)
        let before = try H264SpsRewriter.summary(of: input)
        #expect(before.profileIdc == c.profile)
        #expect(before.constraintFlags == 0)
        #expect(before.levelIdc == 50)
        #expect(before.numRefFrames == 1)
        #expect(before.picOrderCntType == 0)
        #expect(!before.hasVui)
        #expect(before.maxNumReorderFrames == nil)

        let output = try H264SpsRewriter.rewrite(input)
        #expect(output == hex(c.output))

        let after = try H264SpsRewriter.summary(of: output)
        #expect(after.profileIdc == before.profileIdc)
        #expect(after.constraintFlags == before.constraintFlags)
        #expect(after.levelIdc == before.levelIdc)
        #expect(after.numRefFrames == before.numRefFrames)
        #expect(after.picOrderCntType == before.picOrderCntType)
        #expect(after.hasVui)
        #expect(after.maxNumReorderFrames == 0)
        #expect(after.maxDecFrameBuffering == 1)
    }

    @Test(arguments: realCases)
    func rewriteIsIdempotent(_ c: (name: String, input: String, output: String, profile: UInt8)) throws {
        let once = try H264SpsRewriter.rewrite(hex(c.input))
        #expect(try H264SpsRewriter.rewrite(once) == once)
        #expect(H264SpsRewriter.rewriteOrNil(once) == once)
    }

    @Test func nalHeaderByteIsPreserved() throws {
        let output = try H264SpsRewriter.rewrite(hex("67420032ab40220096f2e8"))
        #expect(output == hex("67420032ab40220096f2f00f08846a"))
    }

    /// 合成 SPS（high profile、chroma 4:4:4、scaling list、POC type 1、完整 VUI 含 HRD），
    /// 且含 emulation prevention byte `00 00 03`。已有 restriction `[0,2,3,4,5,2,4]` 的版本
    /// 與沒有 restriction 的版本改寫後必須相同。
    @Test(arguments: [
        "2764003291b08ffffc00a14cd908022012dd3217ff00010001f7010203b240000003004000001e354a51528ad6b5ab990a6658",
        "2764003291b08ffffc00a14cd908022012dd3217ff00010001f7010203b240000003004000001e354a51528ad6b5ab40",
    ])
    func syntheticSpsWithVuiHrdAndEmulationPreventionRoundTrips(_ raw: String) throws {
        let expected = hex("2764003291b08ffffc00a14cd908022012dd3217ff00010001f7010203b240000003004000001e354a51528ad6b5abf0884648")
        let input = hex(raw)
        #expect(input.range(of: Data([0, 0, 3])) != nil)
        let before = try H264SpsRewriter.summary(of: input)
        #expect(before.profileIdc == 100)
        #expect(before.numRefFrames == 3)
        #expect(before.picOrderCntType == 1)
        #expect(before.hasVui)

        let output = try H264SpsRewriter.rewrite(input)
        #expect(output == expected)
        #expect(output.range(of: Data([0, 0, 3])) != nil)
        let after = try H264SpsRewriter.summary(of: output)
        #expect(after.maxNumReorderFrames == 0)
        #expect(after.maxDecFrameBuffering == 3)
        #expect(try H264SpsRewriter.rewrite(output) == output)
    }

    @Test func existingRestrictionIsReportedBeforeRewrite() throws {
        let before = try H264SpsRewriter.summary(of: hex("2764003291b08ffffc00a14cd908022012dd3217ff00010001f7010203b240000003004000001e354a51528ad6b5ab990a6658"))
        #expect(before.maxNumReorderFrames == 2)
        #expect(before.maxDecFrameBuffering == 4)
    }

    @Test func baselineWithoutVuiAndThreeRefsUsesRefsAsBuffering() throws {
        let output = try H264SpsRewriter.rewrite(hex("27420032ec8022012dd32150"))
        #expect(output == hex("27420032ec8022012dd321601e1108c9"))
        #expect(try H264SpsRewriter.summary(of: output).maxDecFrameBuffering == 3)
    }

    @Test(arguments: [
        ("", H264SpsError.notSps),
        ("68616263", H264SpsError.notSps),
        ("e7420032", H264SpsError.notSps),
        ("67", H264SpsError.truncated),
        ("67000003ff", H264SpsError.invalidEmulationPrevention),
    ])
    func invalidInputThrowsAndRewriteOrNilReturnsNil(raw: String, error: H264SpsError) {
        #expect(throws: error) { try H264SpsRewriter.rewrite(hex(raw)) }
        #expect(H264SpsRewriter.rewriteOrNil(hex(raw)) == nil)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter H264SpsRewriterTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'H264SpsRewriter' in scope`。

- [ ] **Step 3: 實作**

`app/Sources/MirageCore/Remote/H264SpsRewriter.swift`：

```swift
import Foundation

public struct H264SpsSummary: Sendable, Equatable {
    public let profileIdc: UInt8
    public let constraintFlags: UInt8
    public let levelIdc: UInt8
    public let numRefFrames: UInt32
    public let picOrderCntType: UInt32
    public let hasVui: Bool
    public let maxNumReorderFrames: UInt32?
    public let maxDecFrameBuffering: UInt32?
}

/// SPS 改寫：注入 VUI `bitstream_restriction`，讓手機的 `VideoDecoder` 不囤幀
/// （spec 第 1 節：未改寫 p50 172 ms、改寫後 4 ms）。
///
/// 只適用於本專案 `-bf 0`、無重排序的串流。演算法移植自 spike `relay.py` 的 `rewrite_sps`：
/// 走完 7.3.2.1.1 到 frame cropping，記住到此為止的位元；VUI 存在時再走 E.1.1 到
/// `bitstream_restriction_flag` 之前；然後丟掉舊 restriction 與 trailing bits，接上固定的
/// restriction 重新結尾。除了 restriction 那一段，其他位元逐一保留。
public enum H264SpsRewriter {
    static let maxNumReorderFrames: UInt32 = 0
    private static let log2MaxMvLength: UInt32 = 16
    private static let highProfiles: Set<UInt32> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
    private static let maxPocCycle: UInt32 = 255
    private static let maxHrdCount: UInt32 = 32
    private static let vuiOptionalFlagCount = 8   // VUI 不存在時補的零：五個 present flag、兩個 HRD flag、pic_struct

    private struct Header {
        let profileIdc: UInt8
        let constraintFlags: UInt8
        let levelIdc: UInt8
        let numRefFrames: UInt32
        let picOrderCntType: UInt32
    }

    private struct Parsed {
        let nalHeader: UInt8
        let header: Header
        let hasVui: Bool
        let prefix: [Bool]                  // 到 restriction 之前的所有位元（含 vui_present=1）
        let existingRestriction: [UInt32]?  // [mv_over_boundaries, bytes_denom, bits_denom, mv_h, mv_v, reorder, buffering]
    }

    public static func rewrite(_ sps: Data) throws -> Data {
        let parsed = try parse(sps)
        let restriction: [Bool] = [true, true]
            + H264Rbsp.ueBits(0) + H264Rbsp.ueBits(0)
            + H264Rbsp.ueBits(log2MaxMvLength) + H264Rbsp.ueBits(log2MaxMvLength)
            + H264Rbsp.ueBits(maxNumReorderFrames)
            + H264Rbsp.ueBits(max(1, parsed.header.numRefFrames))
        return Data([parsed.nalHeader]) + H264Rbsp.escape(H264Rbsp.finishRbsp(parsed.prefix + restriction))
    }

    public static func rewriteOrNil(_ sps: Data) -> Data? {
        try? rewrite(sps)
    }

    public static func summary(of sps: Data) throws -> H264SpsSummary {
        let parsed = try parse(sps)
        return H264SpsSummary(
            profileIdc: parsed.header.profileIdc, constraintFlags: parsed.header.constraintFlags,
            levelIdc: parsed.header.levelIdc, numRefFrames: parsed.header.numRefFrames,
            picOrderCntType: parsed.header.picOrderCntType, hasVui: parsed.hasVui,
            maxNumReorderFrames: parsed.existingRestriction?[5],
            maxDecFrameBuffering: parsed.existingRestriction?[6])
    }

    // MARK: - 解析

    private static func parse(_ sps: Data) throws -> Parsed {
        guard let type = H264Nal.rawType(of: sps), type == H264NalType.sps.rawValue else {
            throw H264SpsError.notSps
        }
        let payload = try H264Rbsp.unescape(sps.dropFirst())
        var r = H264BitReader(bits: H264Rbsp.bits(of: payload))
        let header = try readSeqParameterSet(&r)
        var prefix = Array(r.bits[0..<r.position]) + [true]
        let hasVui = try r.flag()
        var existing: [UInt32]?
        if hasVui {
            let start = r.position
            try skipVuiPrefix(&r)
            prefix += r.bits[start..<r.position]
            if try r.flag() {  // bitstream_restriction_flag
                let overBoundaries = try r.u(1)
                var values = [overBoundaries]
                for _ in 0..<6 {
                    let value = try r.ue()
                    values.append(value)
                }
                existing = values
            }
        } else {
            prefix += Array(repeating: false, count: vuiOptionalFlagCount)
        }
        let trailing = r.bits[r.position...]
        guard trailing.first == true, !trailing.dropFirst().contains(true) else {
            throw H264SpsError.invalidTrailingBits
        }
        return Parsed(nalHeader: sps[sps.startIndex], header: header, hasVui: hasVui,
                      prefix: prefix, existingRestriction: existing)
    }

    /// 7.3.2.1.1 從 profile_idc 走到 frame cropping。
    private static func readSeqParameterSet(_ r: inout H264BitReader) throws -> Header {
        let profile = try r.u(8)
        let constraints = try r.u(8)
        let level = try r.u(8)
        _ = try r.ue()  // seq_parameter_set_id
        if highProfiles.contains(profile) {
            let chroma = try r.ue()
            guard chroma <= 3 else { throw H264SpsError.invalidField("chroma_format_idc") }
            if chroma == 3 { _ = try r.flag() }  // separate_colour_plane_flag
            _ = try r.ue()   // bit_depth_luma_minus8
            _ = try r.ue()   // bit_depth_chroma_minus8
            _ = try r.flag() // qpprime_y_zero_transform_bypass_flag
            if try r.flag() {  // seq_scaling_matrix_present_flag
                let lists = chroma == 3 ? 12 : 8
                for i in 0..<lists {
                    if try r.flag() { try skipScalingList(&r, size: i < 6 ? 16 : 64) }
                }
            }
        }
        _ = try r.ue()  // log2_max_frame_num_minus4
        let poc = try r.ue()
        switch poc {
        case 0:
            _ = try r.ue()  // log2_max_pic_order_cnt_lsb_minus4
        case 1:
            _ = try r.flag()
            _ = try r.se()
            _ = try r.se()
            let cycle = try r.ue()
            guard cycle <= maxPocCycle else { throw H264SpsError.invalidField("num_ref_frames_in_pic_order_cnt_cycle") }
            for _ in 0..<cycle { _ = try r.se() }
        case 2:
            break
        default:
            throw H264SpsError.invalidField("pic_order_cnt_type")
        }
        let refs = try r.ue()
        _ = try r.flag()  // gaps_in_frame_num_value_allowed_flag
        _ = try r.ue()    // pic_width_in_mbs_minus1
        _ = try r.ue()    // pic_height_in_map_units_minus1
        let frameMbsOnly = try r.flag()
        if !frameMbsOnly { _ = try r.flag() }  // mb_adaptive_frame_field_flag
        _ = try r.flag()  // direct_8x8_inference_flag
        if try r.flag() {  // frame_cropping_flag
            for _ in 0..<4 { _ = try r.ue() }
        }
        return Header(profileIdc: UInt8(profile), constraintFlags: UInt8(constraints), levelIdc: UInt8(level),
                      numRefFrames: refs, picOrderCntType: poc)
    }

    private static func skipScalingList(_ r: inout H264BitReader, size: Int) throws {
        var last: Int32 = 8
        var next: Int32 = 8
        for _ in 0..<size {
            if next != 0 {
                let delta = try r.se()
                next = (last + delta + 256) % 256
            }
            last = next == 0 ? last : next
        }
    }

    /// E.1.1 走到 bitstream_restriction_flag 之前。
    private static func skipVuiPrefix(_ r: inout H264BitReader) throws {
        if try r.flag() {  // aspect_ratio_info_present_flag
            if try r.u(8) == 255 { _ = try r.u(32) }  // Extended_SAR：sar_width、sar_height
        }
        if try r.flag() { _ = try r.flag() }  // overscan_info_present → overscan_appropriate
        if try r.flag() {  // video_signal_type_present_flag
            _ = try r.u(4)  // video_format(3) + video_full_range_flag(1)
            if try r.flag() { _ = try r.u(24) }  // colour_primaries、transfer、matrix
        }
        if try r.flag() {  // chroma_loc_info_present_flag
            _ = try r.ue()
            _ = try r.ue()
        }
        if try r.flag() {  // timing_info_present_flag
            _ = try r.u(32)
            _ = try r.u(32)
            _ = try r.flag()
        }
        let nalHrd = try r.flag()
        if nalHrd { try skipHrd(&r) }
        let vclHrd = try r.flag()
        if vclHrd { try skipHrd(&r) }
        if nalHrd || vclHrd { _ = try r.flag() }  // low_delay_hrd_flag
        _ = try r.flag()  // pic_struct_present_flag
    }

    private static func skipHrd(_ r: inout H264BitReader) throws {
        let count = try r.ue() + 1
        guard count <= maxHrdCount else { throw H264SpsError.invalidField("cpb_cnt_minus1") }
        _ = try r.u(8)  // bit_rate_scale(4) + cpb_size_scale(4)
        for _ in 0..<count {
            _ = try r.ue()
            _ = try r.ue()
            _ = try r.flag()
        }
        _ = try r.u(20)  // 四個 length 欄位各 5 bits
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter H264SpsRewriterTests 2>&1 | tail -5`
Expected: 全部通過、0 failures。若 `realVideoToolboxSpsGetsZeroReorderRestriction` 的 `output == hex(c.output)` 紅，先印兩邊的 hex 比對從哪個位元組開始不同，再對照上方 `readSeqParameterSet`／`skipVuiPrefix` 的欄位順序；不要改預期值。

- [ ] **Step 5: 確認檔案長度在上限內**

Run: `wc -l /Users/hanfourhuang/Projects/mirage/app/Sources/MirageCore/Remote/H264SpsRewriter.swift`
Expected: 小於 400。

- [ ] **Step 6: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageCore/Remote/H264SpsRewriter.swift app/Tests/MirageCoreTests/Remote/H264SpsRewriterTests.swift && git commit -m "feat: H264SpsRewriter 注入 max_num_reorder_frames=0 的 VUI restriction"
```

---

### Task 7: `RemoteTouchMessage`：`/ws/input` JSON 解碼與驗證

**Files:**
- Create: `app/Sources/MirageCore/Remote/RemoteTouchMessage.swift`
- Test: `app/Tests/MirageCoreTests/Remote/RemoteTouchMessageTests.swift`

**Interfaces:**
- Consumes: `NormPoint`（`app/Sources/MirageCore/Keymap/NormPoint.swift:4-9`）與 `NormPoint.clamped(x:y:)`（`NormPoint.swift:29-31`）。
- Produces（Task 8 吃 `RemoteTouchMessage`；Task 13 的 `RemoteServerCore.handleInputText` 呼叫 `decode`）：

```swift
public enum RemoteTouchPhase: String, Sendable, Equatable, CaseIterable { case down, move, up, cancel }
public struct RemoteTouchMessage: Sendable, Equatable {
    public let pointerId: Int              // 手機的 pointerId，非負整數
    public let phase: RemoteTouchPhase
    public let point: NormPoint            // 已夾進 0…1
    public let time: Double                // 手機的 performance.now()，缺省 0
    public var isDown: Bool                // down／move 為 true；up／cancel 一律 false
}
public enum RemoteInputMessage: Sendable, Equatable { case ping, touch(RemoteTouchMessage) }
public enum RemoteInputDecodeError: Error, Equatable {
    case notJSON, missingField(String), unknownType(String), invalidPointerId, invalidCoordinate
}
public enum RemoteTouchMessageDecoder {
    public static func decode(_ text: String) -> Result<RemoteInputMessage, RemoteInputDecodeError>
}
```

驗證規則（spec 第 5 節）：任一不合法整則丟棄、回錯誤原因、不拋例外。座標非有限數是錯誤；有限但越界則夾取（同 `NormPoint.fromViewPoint` 的理由，`NormPoint.swift:38-46`：手機的手指停在邊緣是最接近的類比，送越界座標比不送更糟）。

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageCoreTests/Remote/RemoteTouchMessageTests.swift`：

```swift
import Testing
@testable import MirageCore

@Suite struct RemoteTouchMessageTests {
    private func touch(_ text: String) throws -> RemoteTouchMessage {
        guard case .touch(let message) = try RemoteTouchMessageDecoder.decode(text).get() else {
            throw RemoteInputDecodeError.unknownType("expected touch")
        }
        return message
    }

    @Test func decodesSpecExampleDown() throws {
        let m = try touch(#"{"t": 1234.5, "id": 7, "type": "down", "x": 0.49, "y": 0.75}"#)
        #expect(m == RemoteTouchMessage(pointerId: 7, phase: .down, point: NormPoint(x: 0.49, y: 0.75), time: 1234.5))
        #expect(m.isDown)
    }

    @Test(arguments: [("down", true), ("move", true), ("up", false), ("cancel", false)])
    func isDownFollowsPhase(type: String, expected: Bool) throws {
        let m = try touch(#"{"t": 1, "id": 0, "type": "\#(type)", "x": 0.5, "y": 0.5}"#)
        #expect(m.phase.rawValue == type)
        #expect(expected ? m.isDown : !m.isDown)
    }

    @Test func pingIsRecognisedWithOrWithoutTime() throws {
        #expect(try RemoteTouchMessageDecoder.decode(#"{"type": "ping", "t": 1234.5}"#).get() == .ping)
        #expect(try RemoteTouchMessageDecoder.decode(#"{"type":"ping"}"#).get() == .ping)
    }

    @Test func coordinatesAreClampedIntoUnitSquare() throws {
        let m = try touch(#"{"t": 1, "id": 3, "type": "move", "x": 1.2, "y": -0.3}"#)
        #expect(m.point == NormPoint(x: 1, y: 0))
        #expect(m.point.isValid)
    }

    @Test func missingTimeDefaultsToZeroAndExtraFieldsAreIgnored() throws {
        let m = try touch(#"{"id": 2, "type": "up", "x": 0.1, "y": 0.2, "pressure": 0.9}"#)
        #expect(m.time == 0)
        #expect(m.pointerId == 2)
    }

    @Test(arguments: [
        ("nope", RemoteInputDecodeError.notJSON),
        ("[]", RemoteInputDecodeError.notJSON),
        ("", RemoteInputDecodeError.notJSON),
        (#"{"id": 1, "x": 0.5, "y": 0.5}"#, RemoteInputDecodeError.missingField("type")),
        (#"{"type": 7}"#, RemoteInputDecodeError.missingField("type")),
        (#"{"type": "hover", "id": 1, "x": 0.5, "y": 0.5}"#, RemoteInputDecodeError.unknownType("hover")),
        (#"{"type": "down", "x": 0.5, "y": 0.5}"#, RemoteInputDecodeError.missingField("id")),
        (#"{"type": "down", "id": -1, "x": 0.5, "y": 0.5}"#, RemoteInputDecodeError.invalidPointerId),
        (#"{"type": "down", "id": 1.5, "x": 0.5, "y": 0.5}"#, RemoteInputDecodeError.invalidPointerId),
        (#"{"type": "down", "id": "7", "x": 0.5, "y": 0.5}"#, RemoteInputDecodeError.invalidPointerId),
        (#"{"type": "down", "id": 1, "y": 0.5}"#, RemoteInputDecodeError.missingField("x")),
        (#"{"type": "down", "id": 1, "x": 0.5}"#, RemoteInputDecodeError.missingField("y")),
        (#"{"type": "down", "id": 1, "x": "0.5", "y": 0.5}"#, RemoteInputDecodeError.invalidCoordinate),
        (#"{"type": "down", "id": 1, "x": 0.5, "y": null}"#, RemoteInputDecodeError.invalidCoordinate),
    ])
    func invalidMessagesAreRejectedWithReason(text: String, error: RemoteInputDecodeError) {
        switch RemoteTouchMessageDecoder.decode(text) {
        case .success(let message): Issue.record("應拒絕但解出 \(message)")
        case .failure(let actual): #expect(actual == error)
        }
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteTouchMessageTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'RemoteTouchMessageDecoder' in scope`。

- [ ] **Step 3: 實作**

`app/Sources/MirageCore/Remote/RemoteTouchMessage.swift`：

```swift
import Foundation

public enum RemoteTouchPhase: String, Sendable, Equatable, CaseIterable {
    case down, move, up, cancel
}

/// 手機一根手指的一則事件（spec 第 4 節 `/ws/input`）。座標相對於畫面內容區、左上原點、已夾進 0…1。
public struct RemoteTouchMessage: Sendable, Equatable {
    public let pointerId: Int
    public let phase: RemoteTouchPhase
    public let point: NormPoint
    public let time: Double

    public init(pointerId: Int, phase: RemoteTouchPhase, point: NormPoint, time: Double) {
        self.pointerId = pointerId
        self.phase = phase
        self.point = point
        self.time = time
    }

    /// 抬起與取消一律不是 down，不看手機送了什麼別的欄位。
    public var isDown: Bool { phase == .down || phase == .move }
}

public enum RemoteInputMessage: Sendable, Equatable {
    case ping
    case touch(RemoteTouchMessage)
}

public enum RemoteInputDecodeError: Error, Equatable {
    case notJSON
    case missingField(String)
    case unknownType(String)
    case invalidPointerId
    case invalidCoordinate
}

/// `/ws/input` 文字訊息 → `RemoteInputMessage`。純函式：不 log、不計數、不拋例外，
/// 由 `RemoteServerCore` 決定怎麼處理失敗（丟棄、計數、節流 log）。
public enum RemoteTouchMessageDecoder {
    private static let pingType = "ping"

    public static func decode(_ text: String) -> Result<RemoteInputMessage, RemoteInputDecodeError> {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any]
        else { return .failure(.notJSON) }
        guard let type = fields["type"] as? String else { return .failure(.missingField("type")) }
        if type == pingType { return .success(.ping) }
        guard let phase = RemoteTouchPhase(rawValue: type) else { return .failure(.unknownType(type)) }
        return pointerId(fields).flatMap { id in
            coordinate(fields, "x").flatMap { x in
                coordinate(fields, "y").map { y in
                    .touch(RemoteTouchMessage(pointerId: id, phase: phase,
                                              point: NormPoint.clamped(x: x, y: y),
                                              time: (fields["t"] as? Double) ?? 0))
                }
            }
        }
    }

    private static func pointerId(_ fields: [String: Any]) -> Result<Int, RemoteInputDecodeError> {
        guard let raw = fields["id"] else { return .failure(.missingField("id")) }
        guard let value = raw as? Double, value.isFinite, value >= 0,
              value == value.rounded(), value <= Double(Int32.max)
        else { return .failure(.invalidPointerId) }
        return .success(Int(value))
    }

    private static func coordinate(_ fields: [String: Any], _ key: String) -> Result<Double, RemoteInputDecodeError> {
        guard let raw = fields[key] else { return .failure(.missingField(key)) }
        guard let value = raw as? Double, value.isFinite else { return .failure(.invalidCoordinate) }
        return .success(value)
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteTouchMessageTests 2>&1 | tail -5`
Expected: 全部通過、0 failures。若 `"y": null` 那條紅：`JSONSerialization` 把 `null` 解成 `NSNull`，`fields["y"]` 非 nil 但 `as? Double` 失敗，應走 `invalidCoordinate`；確認 `coordinate` 的兩個 guard 順序如上。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageCore/Remote/RemoteTouchMessage.swift app/Tests/MirageCoreTests/Remote/RemoteTouchMessageTests.swift && git commit -m "feat: RemoteTouchMessageDecoder 驗證並解碼手機觸控 JSON"
```

---

### Task 8: `RemoteTouchIdentifierAllocator`：pointerId → 64 到 79

**Files:**
- Create: `app/Sources/MirageCore/Remote/RemoteTouchIdentifierAllocator.swift`
- Test: `app/Tests/MirageCoreTests/Remote/RemoteTouchIdentifierAllocatorTests.swift`

**Interfaces:**
- Consumes: Task 7 的 `RemoteTouchMessage`、`RemoteTouchPhase`；`TouchSpec(identifier:point:down:)`（`app/Sources/MirageCore/Keymap/KeymapEngine.swift:3-7`；沒有明寫 `public init`，memberwise init 是 internal，本型別在同一個 module 內可用）；`NormPoint`。
- Produces（Task 13 的 `RemoteServerCore` 持有一份；階段 D 只看到 `[TouchSpec]`，直接 `inputQueue.touches(_:)`，`InputQueue.swift:200-202`）：

```swift
public struct RemoteActiveTouch: Sendable, Equatable { public let identifier: Int; public let point: NormPoint }
public enum RemoteTouchRejection: Sendable, Equatable { case tooManyFingers, unknownPointer }
public enum RemoteTouchOutcome: Sendable, Equatable { case emit(TouchSpec), rejected(RemoteTouchRejection) }
public struct RemoteTouchIdentifierAllocator: Sendable, Equatable {
    public static let identifierRange = 64...79   // 16 個，與 sendTap(0)、keymap(1 起) 不重疊
    public static let maxActive = 10              // 模擬器並發觸控上限
    public let active: [Int: RemoteActiveTouch]   // pointerId → 配到的識別碼與最後座標
    public init()
    public func apply(_ message: RemoteTouchMessage) -> (allocator: RemoteTouchIdentifierAllocator, outcome: RemoteTouchOutcome)
    public func releaseAll() -> (allocator: RemoteTouchIdentifierAllocator, released: [TouchSpec])
}
```

規則：`down` 新 pointer 且已有 10 指 → `tooManyFingers`；否則配最小的空閒識別碼。`down` 已知 pointer 視同 `move`。`move`／`up`／`cancel` 未知 pointer → `unknownPointer`。`up`／`cancel` 發出 `down:false` 並釋放。`releaseAll` 把所有在按的手指依識別碼排序、在最後座標發 `down:false`（手機斷線時呼叫，避免 guest 留下永遠按著的手指，D6 同族）。

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageCoreTests/Remote/RemoteTouchIdentifierAllocatorTests.swift`：

```swift
import Testing
@testable import MirageCore

@Suite struct RemoteTouchIdentifierAllocatorTests {
    private func message(_ id: Int, _ phase: RemoteTouchPhase, x: Double = 0.5, y: Double = 0.5) -> RemoteTouchMessage {
        RemoteTouchMessage(pointerId: id, phase: phase, point: NormPoint(x: x, y: y), time: 0)
    }

    @Test func downAllocatesLowestFreeIdentifierAndUpReleasesIt() {
        let (a1, o1) = RemoteTouchIdentifierAllocator().apply(message(7, .down, x: 0.1, y: 0.2))
        #expect(o1 == .emit(TouchSpec(identifier: 64, point: NormPoint(x: 0.1, y: 0.2), down: true)))
        let (a2, o2) = a1.apply(message(9, .down))
        #expect(o2 == .emit(TouchSpec(identifier: 65, point: NormPoint(x: 0.5, y: 0.5), down: true)))
        let (a3, o3) = a2.apply(message(7, .move, x: 0.3, y: 0.4))
        #expect(o3 == .emit(TouchSpec(identifier: 64, point: NormPoint(x: 0.3, y: 0.4), down: true)))
        #expect(a3.active[7] == RemoteActiveTouch(identifier: 64, point: NormPoint(x: 0.3, y: 0.4)))
        let (a4, o4) = a3.apply(message(7, .up, x: 0.35, y: 0.45))
        #expect(o4 == .emit(TouchSpec(identifier: 64, point: NormPoint(x: 0.35, y: 0.45), down: false)))
        #expect(a4.active[7] == nil)
        let (_, o5) = a4.apply(message(11, .down))
        #expect(o5 == .emit(TouchSpec(identifier: 64, point: NormPoint(x: 0.5, y: 0.5), down: true)))
    }

    @Test(arguments: [RemoteTouchPhase.move, .up, .cancel])
    func unknownPointerIsRejectedAndStateUnchanged(phase: RemoteTouchPhase) {
        let empty = RemoteTouchIdentifierAllocator()
        let (after, outcome) = empty.apply(message(3, phase))
        #expect(outcome == .rejected(.unknownPointer))
        #expect(after == empty)
    }

    @Test func repeatedDownOnActivePointerBehavesLikeMove() {
        let (a1, _) = RemoteTouchIdentifierAllocator().apply(message(1, .down))
        let (a2, outcome) = a1.apply(message(1, .down, x: 0.9, y: 0.9))
        #expect(outcome == .emit(TouchSpec(identifier: 64, point: NormPoint(x: 0.9, y: 0.9), down: true)))
        #expect(a2.active.count == 1)
    }

    @Test func cancelReleasesLikeUp() {
        let (a1, _) = RemoteTouchIdentifierAllocator().apply(message(5, .down))
        let (a2, outcome) = a1.apply(message(5, .cancel))
        #expect(outcome == .emit(TouchSpec(identifier: 64, point: NormPoint(x: 0.5, y: 0.5), down: false)))
        #expect(a2.active.isEmpty)
    }

    @Test func eleventhFingerIsRejectedUntilOneLifts() {
        var allocator = RemoteTouchIdentifierAllocator()
        for id in 0..<10 {
            let (next, outcome) = allocator.apply(message(id, .down))
            #expect(outcome == .emit(TouchSpec(identifier: 64 + id, point: NormPoint(x: 0.5, y: 0.5), down: true)))
            allocator = next
        }
        let (unchanged, rejected) = allocator.apply(message(10, .down))
        #expect(rejected == .rejected(.tooManyFingers))
        #expect(unchanged == allocator)
        let (afterUp, _) = allocator.apply(message(4, .up))
        let (_, accepted) = afterUp.apply(message(10, .down))
        #expect(accepted == .emit(TouchSpec(identifier: 68, point: NormPoint(x: 0.5, y: 0.5), down: true)))
    }

    @Test func identifiersStayInsideReservedBandUnderChurn() {
        var allocator = RemoteTouchIdentifierAllocator()
        var seen: Set<Int> = []
        for round in 0..<100 {
            let (down, outcome) = allocator.apply(message(round, .down))
            if case .emit(let spec) = outcome { seen.insert(spec.identifier) }
            let (up, _) = down.apply(message(round, .up))
            allocator = up
        }
        #expect(seen == [64])
        #expect(seen.allSatisfy { RemoteTouchIdentifierAllocator.identifierRange.contains($0) })
        #expect(allocator.active.isEmpty)
    }

    @Test func releaseAllLiftsEveryActiveFingerAtItsLastPointSortedByIdentifier() {
        let (a1, _) = RemoteTouchIdentifierAllocator().apply(message(20, .down, x: 0.2, y: 0.2))
        let (a2, _) = a1.apply(message(30, .down, x: 0.3, y: 0.3))
        let (a3, _) = a2.apply(message(30, .move, x: 0.33, y: 0.33))
        let (after, released) = a3.releaseAll()
        #expect(released == [
            TouchSpec(identifier: 64, point: NormPoint(x: 0.2, y: 0.2), down: false),
            TouchSpec(identifier: 65, point: NormPoint(x: 0.33, y: 0.33), down: false),
        ])
        #expect(after == RemoteTouchIdentifierAllocator())
        #expect(RemoteTouchIdentifierAllocator().releaseAll().released.isEmpty)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteTouchIdentifierAllocatorTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'RemoteTouchIdentifierAllocator' in scope`。

- [ ] **Step 3: 實作**

`app/Sources/MirageCore/Remote/RemoteTouchIdentifierAllocator.swift`：

```swift
public struct RemoteActiveTouch: Sendable, Equatable {
    public let identifier: Int
    public let point: NormPoint

    public init(identifier: Int, point: NormPoint) {
        self.identifier = identifier
        self.point = point
    }
}

public enum RemoteTouchRejection: Sendable, Equatable {
    case tooManyFingers
    case unknownPointer
}

public enum RemoteTouchOutcome: Sendable, Equatable {
    case emit(TouchSpec)
    case rejected(RemoteTouchRejection)
}

/// 手機 pointerId → 模擬器觸控識別碼（spec 第 2 節設計決定 2）。
///
/// 識別碼固定在 64 到 79：Mac 端 `sendTap` 用 0、keymap 從 1 起（`KeymapEngine.init`），
/// 三方永不重疊。模擬器並發觸控上限 10，所以雖然有 16 個號碼，同時在按的最多 10 指。
/// 值型別：`apply` 回傳新的 allocator，持有者（`RemoteServerCore`）在鎖內替換。
public struct RemoteTouchIdentifierAllocator: Sendable, Equatable {
    public static let identifierRange = 64...79
    public static let maxActive = 10

    public let active: [Int: RemoteActiveTouch]

    public init() {
        active = [:]
    }

    private init(active: [Int: RemoteActiveTouch]) {
        self.active = active
    }

    public func apply(_ message: RemoteTouchMessage)
        -> (allocator: RemoteTouchIdentifierAllocator, outcome: RemoteTouchOutcome)
    {
        if let existing = active[message.pointerId] {
            return update(pointerId: message.pointerId, identifier: existing.identifier, message: message)
        }
        guard message.phase == .down else { return (self, .rejected(.unknownPointer)) }
        guard active.count < Self.maxActive, let identifier = lowestFreeIdentifier() else {
            return (self, .rejected(.tooManyFingers))
        }
        return update(pointerId: message.pointerId, identifier: identifier, message: message)
    }

    public func releaseAll() -> (allocator: RemoteTouchIdentifierAllocator, released: [TouchSpec]) {
        let released = active.values
            .sorted { $0.identifier < $1.identifier }
            .map { TouchSpec(identifier: $0.identifier, point: $0.point, down: false) }
        return (RemoteTouchIdentifierAllocator(), released)
    }

    private func update(pointerId: Int, identifier: Int, message: RemoteTouchMessage)
        -> (allocator: RemoteTouchIdentifierAllocator, outcome: RemoteTouchOutcome)
    {
        var next = active
        if message.isDown {
            next[pointerId] = RemoteActiveTouch(identifier: identifier, point: message.point)
        } else {
            next[pointerId] = nil
        }
        let spec = TouchSpec(identifier: identifier, point: message.point, down: message.isDown)
        return (RemoteTouchIdentifierAllocator(active: next), .emit(spec))
    }

    private func lowestFreeIdentifier() -> Int? {
        let used = Set(active.values.map(\.identifier))
        return Self.identifierRange.first { !used.contains($0) }
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteTouchIdentifierAllocatorTests 2>&1 | tail -5`
Expected: 全部通過、0 failures。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageCore/Remote/RemoteTouchIdentifierAllocator.swift app/Tests/MirageCoreTests/Remote/RemoteTouchIdentifierAllocatorTests.swift && git commit -m "feat: RemoteTouchIdentifierAllocator 把手機 pointerId 配到 64 到 79"
```

---

### Task 9: `RemoteSessionState`：配對連線 reducer

**Files:**
- Create: `app/Sources/MirageCore/Remote/RemoteSessionState.swift`
- Test: `app/Tests/MirageCoreTests/Remote/RemoteSessionStateTests.swift`

**Interfaces:**
- Consumes: 寫法比照 `ConnReducer.reduce(_:_:) -> (ConnState, ConnEffect)`（`app/Sources/MirageCore/ConnectionStateMachine.swift:23-45`）。
- Produces（Task 11 的 router 讀 `hasVideo`／`hasInput`；Task 13 在鎖內套用；階段 D 的 `AppModel+Remote` 用 `isViewerConnected` 決定 `hasActiveRemoteViewer` 與選單文字）：

```swift
public struct RemoteSessionState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case waitingForPairing, connected, disconnected }
    public let phase: Phase
    public let hasVideo: Bool
    public let hasInput: Bool
    public static let initial: RemoteSessionState      // waitingForPairing、兩者 false
    public var isViewerConnected: Bool                 // phase == .connected
}
public enum RemoteSessionEvent: Sendable, Equatable { case videoOpened, inputOpened, videoClosed, inputClosed, stopRequested }
public enum RemoteSessionEffect: Sendable, Equatable { case none, rejectBusy, requestKeyframe, releaseTouches }
public enum RemoteSessionReducer {
    public static func reduce(_ state: RemoteSessionState, _ event: RemoteSessionEvent) -> (RemoteSessionState, RemoteSessionEffect)
}
```

一條配對連線 = 一條 `/ws/video` ＋ 一條 `/ws/input`（同一支手機開兩條 socket）。同路徑第二條就是 `rejectBusy`。手機斷線後 token 保留、同一網址可重連（spec 第 6 節），所以 `disconnected` 收到 `videoOpened` 會回到 `connected`。

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageCoreTests/Remote/RemoteSessionStateTests.swift`：

```swift
import Testing
@testable import MirageCore

@Suite struct RemoteSessionStateTests {
    private func state(_ phase: RemoteSessionState.Phase, video: Bool, input: Bool) -> RemoteSessionState {
        RemoteSessionState(phase: phase, hasVideo: video, hasInput: input)
    }

    @Test func initialIsWaitingWithNothingAttached() {
        #expect(RemoteSessionState.initial == state(.waitingForPairing, video: false, input: false))
        #expect(!RemoteSessionState.initial.isViewerConnected)
    }

    @Test func videoThenInputConnectsAndAsksForKeyframeOnce() {
        let (s1, e1) = RemoteSessionReducer.reduce(.initial, .videoOpened)
        #expect(s1 == state(.connected, video: true, input: false))
        #expect(e1 == .requestKeyframe)
        #expect(s1.isViewerConnected)
        let (s2, e2) = RemoteSessionReducer.reduce(s1, .inputOpened)
        #expect(s2 == state(.connected, video: true, input: true))
        #expect(e2 == .none)
    }

    @Test func inputMayOpenBeforeVideo() {
        let (s, e) = RemoteSessionReducer.reduce(.initial, .inputOpened)
        #expect(s == state(.connected, video: false, input: true))
        #expect(e == .none)
    }

    @Test func secondSocketOnSamePathIsBusy() {
        let full = state(.connected, video: true, input: true)
        #expect(RemoteSessionReducer.reduce(full, .videoOpened) == (full, .rejectBusy))
        #expect(RemoteSessionReducer.reduce(full, .inputOpened) == (full, .rejectBusy))
    }

    @Test func closingVideoKeepsSessionWhileInputRemains() {
        let (s, e) = RemoteSessionReducer.reduce(state(.connected, video: true, input: true), .videoClosed)
        #expect(s == state(.connected, video: false, input: true))
        #expect(e == .none)
    }

    @Test func closingLastSocketDisconnects() {
        let (s1, e1) = RemoteSessionReducer.reduce(state(.connected, video: true, input: false), .videoClosed)
        #expect(s1 == state(.disconnected, video: false, input: false))
        #expect(e1 == .none)
        let (s2, e2) = RemoteSessionReducer.reduce(state(.connected, video: false, input: true), .inputClosed)
        #expect(s2 == state(.disconnected, video: false, input: false))
        #expect(e2 == .releaseTouches)
    }

    @Test func closingInputAlwaysReleasesTouches() {
        let (s, e) = RemoteSessionReducer.reduce(state(.connected, video: true, input: true), .inputClosed)
        #expect(s == state(.connected, video: true, input: false))
        #expect(e == .releaseTouches)
    }

    @Test func closingSomethingNotOpenIsNoOp() {
        for from in [RemoteSessionState.initial, state(.connected, video: true, input: false), state(.disconnected, video: false, input: false)] {
            #expect(RemoteSessionReducer.reduce(from, .inputClosed) == (from, .none))
        }
        let videoOnlyInput = state(.connected, video: false, input: true)
        #expect(RemoteSessionReducer.reduce(videoOnlyInput, .videoClosed) == (videoOnlyInput, .none))
    }

    @Test func reconnectAfterDisconnectIsAllowedWithKeyframe() {
        let (s, e) = RemoteSessionReducer.reduce(state(.disconnected, video: false, input: false), .videoOpened)
        #expect(s == state(.connected, video: true, input: false))
        #expect(e == .requestKeyframe)
    }

    @Test func stopDisconnectsAndReleasesTouchesOnlyIfInputWasOpen() {
        let (s1, e1) = RemoteSessionReducer.reduce(state(.connected, video: true, input: true), .stopRequested)
        #expect(s1 == state(.disconnected, video: false, input: false))
        #expect(e1 == .releaseTouches)
        let (s2, e2) = RemoteSessionReducer.reduce(.initial, .stopRequested)
        #expect(s2 == state(.disconnected, video: false, input: false))
        #expect(e2 == .none)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteSessionStateTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'RemoteSessionState' in scope`。

- [ ] **Step 3: 實作**

`app/Sources/MirageCore/Remote/RemoteSessionState.swift`：

```swift
/// 單一手機連線的純 reducer（spec 第 3 節），比照 `ConnReducer`：轉移可窮舉，效果由
/// `RemoteServerCore` 執行（`requestKeyframe` → 重置送出佇列並通知編碼器；`releaseTouches`
/// → allocator 全放開並送進 InputQueue；`rejectBusy` → 計數）。
public struct RemoteSessionState: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case waitingForPairing
        case connected
        case disconnected
    }

    public let phase: Phase
    public let hasVideo: Bool
    public let hasInput: Bool

    public init(phase: Phase, hasVideo: Bool, hasInput: Bool) {
        self.phase = phase
        self.hasVideo = hasVideo
        self.hasInput = hasInput
    }

    public static let initial = RemoteSessionState(phase: .waitingForPairing, hasVideo: false, hasInput: false)

    public var isViewerConnected: Bool { phase == .connected }

    /// 任一條 socket 在就是 connected；都不在就是 disconnected（從未連過的 waiting 只出現在 initial）。
    fileprivate func with(video: Bool, input: Bool) -> RemoteSessionState {
        RemoteSessionState(phase: video || input ? .connected : .disconnected, hasVideo: video, hasInput: input)
    }
}

public enum RemoteSessionEvent: Sendable, Equatable {
    case videoOpened
    case inputOpened
    case videoClosed
    case inputClosed
    case stopRequested
}

public enum RemoteSessionEffect: Sendable, Equatable {
    case none
    case rejectBusy
    case requestKeyframe
    case releaseTouches
}

public enum RemoteSessionReducer {
    public static func reduce(_ state: RemoteSessionState, _ event: RemoteSessionEvent)
        -> (RemoteSessionState, RemoteSessionEffect)
    {
        switch event {
        case .videoOpened:
            guard !state.hasVideo else { return (state, .rejectBusy) }
            return (state.with(video: true, input: state.hasInput), .requestKeyframe)
        case .inputOpened:
            guard !state.hasInput else { return (state, .rejectBusy) }
            return (state.with(video: state.hasVideo, input: true), .none)
        case .videoClosed:
            guard state.hasVideo else { return (state, .none) }
            return (state.with(video: false, input: state.hasInput), .none)
        case .inputClosed:
            guard state.hasInput else { return (state, .none) }
            return (state.with(video: state.hasVideo, input: false), .releaseTouches)
        case .stopRequested:
            return (state.with(video: false, input: false), state.hasInput ? .releaseTouches : .none)
        }
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteSessionStateTests 2>&1 | tail -5`
Expected: `Test run with 10 tests passed`。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageCore/Remote/RemoteSessionState.swift app/Tests/MirageCoreTests/Remote/RemoteSessionStateTests.swift && git commit -m "feat: RemoteSessionReducer 定義配對連線的狀態轉移"
```

---

### Task 10: `RemoteVideoMessage` 與 `RemoteVideoQueue`

**Files:**
- Create: `app/Sources/MirageCore/Remote/RemoteVideoMessage.swift`
- Create: `app/Sources/MirageCore/Remote/RemoteVideoQueue.swift`
- Test: `app/Tests/MirageCoreTests/Remote/RemoteVideoMessageTests.swift`
- Test: `app/Tests/MirageCoreTests/Remote/RemoteVideoQueueTests.swift`

**Interfaces:**
- Consumes: Task 4 的 `H264Nal.startCode`。演算法移植自 spike `relay.py` 的 `encode_message`／`decode_message`／`GOPQueue`。
- Produces（Task 13 用；Task 13 的整合測試與階段 D 的 `verify_remote_mirror.sh` 用 `decode` 驗訊息格式）：

```swift
public struct RemoteVideoMessage: Sendable, Equatable {
    public static let headerSize = 13
    public let sentAtNanoseconds: UInt64   // monotonic，big-endian
    public let sequence: UInt32
    public let isKeyframe: Bool
    public let accessUnit: Data            // Annex-B
    public init(sentAtNanoseconds: UInt64, sequence: UInt32, isKeyframe: Bool, accessUnit: Data)
    public func encoded() -> Data
    public static func decode(_ data: Data) -> RemoteVideoMessage?  // 標頭不足、旗標非 0/1、payload 不以起始碼開頭 → nil
}
public struct RemoteVideoQueue: Sendable, Equatable {
    public struct Entry: Sendable, Equatable { public let sequence: UInt32; public let isKeyframe: Bool; public let accessUnit: Data }
    public static let defaultLimit = 3
    public let limit: Int
    public let pending: [Entry]
    public let waitingForKeyframe: Bool
    public let dropped: Int
    public init(limit: Int = defaultLimit)          // precondition limit >= 1；初始 waitingForKeyframe = true
    public func offering(_ entry: Entry) -> (queue: RemoteVideoQueue, accepted: Bool)
    public func popping() -> (queue: RemoteVideoQueue, entry: Entry?)
}
```

佇列規則（spec 第 4 節）：`offering` 時若 `pending.count >= limit`，把 pending 全丟（計入 dropped）並回到等 keyframe；等 keyframe 期間的非 keyframe 也丟並計數；keyframe 立刻恢復。

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageCoreTests/Remote/RemoteVideoMessageTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

@Suite struct RemoteVideoMessageTests {
    private let payload = H264Nal.startCode + Data([0x65, 0x70, 0x61, 0x79, 0x6c, 0x6f, 0x61, 0x64])

    @Test func headerIsBigEndianTimeSequenceAndFlag() {
        let message = RemoteVideoMessage(sentAtNanoseconds: 0x0102030405060708, sequence: 0x11223344,
                                         isKeyframe: true, accessUnit: payload)
        let wire = message.encoded()
        #expect(wire.count == RemoteVideoMessage.headerSize + payload.count)
        #expect(wire.prefix(13) == Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x11, 0x22, 0x33, 0x44, 0x01]))
        #expect(wire.suffix(from: 13) == payload)
        #expect(RemoteVideoMessage.decode(wire) == message)
    }

    @Test func deltaFrameFlagIsZero() {
        let wire = RemoteVideoMessage(sentAtNanoseconds: 1, sequence: 2, isKeyframe: false, accessUnit: payload).encoded()
        #expect(wire[12] == 0)
        #expect(try !#require(RemoteVideoMessage.decode(wire)).isKeyframe)
    }

    @Test func decodeAcceptsThreeByteStartCode() {
        let short = Data([0, 0, 1, 0x41, 0x01])
        let message = RemoteVideoMessage(sentAtNanoseconds: 9, sequence: 9, isKeyframe: false, accessUnit: short)
        #expect(RemoteVideoMessage.decode(message.encoded()) == message)
    }

    @Test func decodeRejectsTruncatedBadFlagOrMissingStartCode() {
        let good = RemoteVideoMessage(sentAtNanoseconds: 1, sequence: 1, isKeyframe: true, accessUnit: payload).encoded()
        #expect(RemoteVideoMessage.decode(Data()) == nil)
        #expect(RemoteVideoMessage.decode(good.prefix(13)) == nil)
        var badFlag = good
        badFlag[12] = 2
        #expect(RemoteVideoMessage.decode(badFlag) == nil)
        let noStartCode = good.prefix(13) + Data([0x65, 0x01, 0x02, 0x03])
        #expect(RemoteVideoMessage.decode(noStartCode) == nil)
    }

    @Test func decodeWorksOnSlicesWithNonZeroStartIndex() {
        let wire = RemoteVideoMessage(sentAtNanoseconds: 5, sequence: 6, isKeyframe: true, accessUnit: payload).encoded()
        let padded = Data([0xff, 0xff]) + wire
        #expect(RemoteVideoMessage.decode(padded.dropFirst(2)) == RemoteVideoMessage.decode(wire))
    }
}
```

`app/Tests/MirageCoreTests/Remote/RemoteVideoQueueTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

@Suite struct RemoteVideoQueueTests {
    private func entry(_ seq: UInt32, key: Bool = false) -> RemoteVideoQueue.Entry {
        RemoteVideoQueue.Entry(sequence: seq, isKeyframe: key, accessUnit: Data([0, 0, 0, 1, key ? 0x65 : 0x41]))
    }

    @Test func startsWaitingForKeyframeAndDropsDeltas() {
        let q = RemoteVideoQueue(limit: 2)
        #expect(q.waitingForKeyframe)
        let (q1, accepted) = q.offering(entry(0))
        #expect(!accepted)
        #expect(q1.dropped == 1)
        #expect(q1.pending.isEmpty)
    }

    @Test func overflowDropsWholeGopAndWaitsForNextKeyframe() {
        var q = RemoteVideoQueue(limit: 2)
        var accepted: Bool
        (q, accepted) = q.offering(entry(0))
        #expect(!accepted)
        (q, accepted) = q.offering(entry(1, key: true))
        #expect(accepted)
        var popped: RemoteVideoQueue.Entry?
        (q, popped) = q.popping()
        #expect(popped?.sequence == 1)
        (q, _) = q.offering(entry(2))
        (q, _) = q.offering(entry(3))
        #expect(q.pending.map(\.sequence) == [2, 3])
        (q, accepted) = q.offering(entry(4))   // 清掉 2、3，丟 4
        #expect(!accepted)
        (q, popped) = q.popping()
        #expect(popped == nil)
        (q, accepted) = q.offering(entry(5))
        #expect(!accepted)
        (q, accepted) = q.offering(entry(6, key: true))
        #expect(accepted)
        (q, popped) = q.popping()
        #expect(popped?.sequence == 6)
        #expect(q.dropped == 5)
        #expect(!q.waitingForKeyframe)
    }

    @Test func overflowOnKeyframeResumesImmediately() {
        var q = RemoteVideoQueue(limit: 1)
        (q, _) = q.offering(entry(0, key: true))
        let (q2, accepted) = q.offering(entry(60, key: true))
        #expect(accepted)
        let (_, popped) = q2.popping()
        #expect(popped?.sequence == 60)
        #expect(q2.dropped == 1)
    }

    @Test func popReturnsOldestFirst() {
        var q = RemoteVideoQueue(limit: 3)
        (q, _) = q.offering(entry(1, key: true))
        (q, _) = q.offering(entry(2))
        (q, _) = q.offering(entry(3))
        let (q1, first) = q.popping()
        let (q2, second) = q1.popping()
        #expect(first?.sequence == 1)
        #expect(second?.sequence == 2)
        #expect(q2.pending.map(\.sequence) == [3])
    }

    @Test func defaultLimitIsThreeFramesPerSpec() {
        #expect(RemoteVideoQueue.defaultLimit == 3)
        #expect(RemoteVideoQueue().limit == 3)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter "RemoteVideoMessageTests|RemoteVideoQueueTests" 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'RemoteVideoMessage' in scope`。

- [ ] **Step 3: 實作**

`app/Sources/MirageCore/Remote/RemoteVideoMessage.swift`：

```swift
import Foundation

/// `/ws/video` 一則二進位訊息（spec 第 4 節）：8 bytes 送出時間、4 bytes 序號、1 byte keyframe、Annex-B。
/// 時間是 Mac 的 monotonic 奈秒，手機端只拿來算相對值，不與自己的時鐘相減。
public struct RemoteVideoMessage: Sendable, Equatable {
    public static let headerSize = 13
    private static let keyframeFlag: UInt8 = 1
    private static let threeByteStartCode = Data([0, 0, 1])

    public let sentAtNanoseconds: UInt64
    public let sequence: UInt32
    public let isKeyframe: Bool
    public let accessUnit: Data

    public init(sentAtNanoseconds: UInt64, sequence: UInt32, isKeyframe: Bool, accessUnit: Data) {
        self.sentAtNanoseconds = sentAtNanoseconds
        self.sequence = sequence
        self.isKeyframe = isKeyframe
        self.accessUnit = accessUnit
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + accessUnit.count)
        out.append(contentsOf: Self.bigEndianBytes(sentAtNanoseconds, count: 8))
        out.append(contentsOf: Self.bigEndianBytes(UInt64(sequence), count: 4))
        out.append(isKeyframe ? Self.keyframeFlag : 0)
        out.append(accessUnit)
        return out
    }

    public static func decode(_ data: Data) -> RemoteVideoMessage? {
        let bytes = [UInt8](data)   // 複製成 0 起始的陣列，避免 Data slice 的 startIndex 陷阱
        guard bytes.count > headerSize else { return nil }
        let flag = bytes[12]
        guard flag <= keyframeFlag else { return nil }
        let payload = Data(bytes[headerSize...])
        guard payload.starts(with: H264Nal.startCode) || payload.starts(with: threeByteStartCode) else { return nil }
        let time = bytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let sequence = bytes[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return RemoteVideoMessage(sentAtNanoseconds: time, sequence: sequence,
                                  isKeyframe: flag == keyframeFlag, accessUnit: payload)
    }

    private static func bigEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64(8 * (count - 1 - $0))) }
    }
}
```

`app/Sources/MirageCore/Remote/RemoteVideoQueue.swift`：

```swift
import Foundation

/// 單一 viewer 的送出佇列（spec 第 4 節背壓規則）。移植自 spike 的 `GOPQueue`。
///
/// 滿了就丟掉全部未送出的幀、回到等 keyframe：丟單一 P 幀會讓後面的 P 幀參考不到，
/// 手機端會花得更多。`dropped` 只計本佇列丟的幀；已交給 TCP 的那一幀收不回來，不算。
/// 值型別：`RemoteServerCore` 在鎖內以 `offering`／`popping` 的回傳值替換自己那一份。
public struct RemoteVideoQueue: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let sequence: UInt32
        public let isKeyframe: Bool
        public let accessUnit: Data

        public init(sequence: UInt32, isKeyframe: Bool, accessUnit: Data) {
            self.sequence = sequence
            self.isKeyframe = isKeyframe
            self.accessUnit = accessUnit
        }
    }

    public static let defaultLimit = 3

    public let limit: Int
    public let pending: [Entry]
    public let waitingForKeyframe: Bool
    public let dropped: Int

    public init(limit: Int = defaultLimit) {
        precondition(limit >= 1, "RemoteVideoQueue limit 必須至少為 1")
        self.init(limit: limit, pending: [], waitingForKeyframe: true, dropped: 0)
    }

    private init(limit: Int, pending: [Entry], waitingForKeyframe: Bool, dropped: Int) {
        self.limit = limit
        self.pending = pending
        self.waitingForKeyframe = waitingForKeyframe
        self.dropped = dropped
    }

    public func offering(_ entry: Entry) -> (queue: RemoteVideoQueue, accepted: Bool) {
        var pending = self.pending
        var waiting = waitingForKeyframe
        var dropped = self.dropped
        if pending.count >= limit {
            dropped += pending.count
            pending.removeAll()
            waiting = true
        }
        if waiting, !entry.isKeyframe {
            return (RemoteVideoQueue(limit: limit, pending: pending, waitingForKeyframe: true, dropped: dropped + 1), false)
        }
        pending.append(entry)
        return (RemoteVideoQueue(limit: limit, pending: pending, waitingForKeyframe: false, dropped: dropped), true)
    }

    public func popping() -> (queue: RemoteVideoQueue, entry: Entry?) {
        guard let first = pending.first else { return (self, nil) }
        let rest = Array(pending.dropFirst())
        return (RemoteVideoQueue(limit: limit, pending: rest, waitingForKeyframe: waitingForKeyframe, dropped: dropped), first)
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter "RemoteVideoMessageTests|RemoteVideoQueueTests" 2>&1 | tail -5`
Expected: 全部通過、0 failures。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageCore/Remote/RemoteVideoMessage.swift app/Sources/MirageCore/Remote/RemoteVideoQueue.swift app/Tests/MirageCoreTests/Remote/RemoteVideoMessageTests.swift app/Tests/MirageCoreTests/Remote/RemoteVideoQueueTests.swift && git commit -m "feat: RemoteVideoMessage 標頭編解碼與 RemoteVideoQueue 整 GOP 背壓佇列"
```

---

### Task 11: `RemoteRequestRouter`：純路由決定

**Files:**
- Create: `app/Sources/MirageCore/Remote/RemoteRequestRouter.swift`
- Test: `app/Tests/MirageCoreTests/Remote/RemoteRequestRouterTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `PairingToken.matches(_:)`；Task 9 的 `RemoteSessionState.hasVideo/hasInput`。
- Produces（Task 13 在 `shouldUpgrade` 與 HTTP 回應兩處呼叫同一個函式，保證 403／409 的判定只有一份）：

```swift
public enum RemoteRoute: Sendable, Equatable {
    case viewer, upgradeVideo, upgradeInput, forbidden, busy, notFound, methodNotAllowed
}
public enum RemoteRequestRouter {
    public static let viewerPath = "/"
    public static let videoPath = "/ws/video"
    public static let inputPath = "/ws/input"
    public static let tokenQueryName = "t"
    public static func path(fromURI uri: String) -> String        // 去掉 ? 與 # 之後的部分
    public static func token(fromURI uri: String) -> String?      // ?t= 的值
    public static func route(method: String, uri: String, token: PairingToken, state: RemoteSessionState) -> RemoteRoute
}
```

判定順序：非 GET → `methodNotAllowed`；token 不符 → `forbidden`（任何路徑，不透露路徑是否存在或是否有連線）；路徑不是三者之一 → `notFound`；`/ws/video` 已有 video → `busy`；`/ws/input` 已有 input → `busy`。

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageCoreTests/Remote/RemoteRequestRouterTests.swift`：

```swift
import Testing
@testable import MirageCore

@Suite struct RemoteRequestRouterTests {
    private let token = PairingToken(value: "00112233445566778899aabbccddeeff")!
    private let good = "?t=00112233445566778899aabbccddeeff"
    private let idle = RemoteSessionState.initial
    private let videoOnly = RemoteSessionState(phase: .connected, hasVideo: true, hasInput: false)
    private let full = RemoteSessionState(phase: .connected, hasVideo: true, hasInput: true)

    private func route(_ uri: String, method: String = "GET", state: RemoteSessionState? = nil) -> RemoteRoute {
        RemoteRequestRouter.route(method: method, uri: uri, token: token, state: state ?? idle)
    }

    @Test func tokenParsingHandlesPositionAndAbsence() {
        #expect(RemoteRequestRouter.token(fromURI: "/?t=abc") == "abc")
        #expect(RemoteRequestRouter.token(fromURI: "/ws/video?x=1&t=abc") == "abc")
        #expect(RemoteRequestRouter.token(fromURI: "/ws/video?t=abc&x=1") == "abc")
        #expect(RemoteRequestRouter.token(fromURI: "/ws/video") == nil)
        #expect(RemoteRequestRouter.token(fromURI: "/?token=abc") == nil)
        #expect(RemoteRequestRouter.path(fromURI: "/ws/video?t=abc#frag") == "/ws/video")
        #expect(RemoteRequestRouter.path(fromURI: "/") == "/")
    }

    @Test func viewerNeedsExactToken() {
        #expect(route("/" + good) == .viewer)
        #expect(route("/") == .forbidden)
        #expect(route("/?t=00112233445566778899aabbccddeefe") == .forbidden)
        #expect(route("/?t=") == .forbidden)
    }

    @Test func upgradesDependOnSessionState() {
        #expect(route("/ws/video" + good) == .upgradeVideo)
        #expect(route("/ws/input" + good) == .upgradeInput)
        #expect(route("/ws/video" + good, state: videoOnly) == .busy)
        #expect(route("/ws/input" + good, state: videoOnly) == .upgradeInput)
        #expect(route("/ws/video" + good, state: full) == .busy)
        #expect(route("/ws/input" + good, state: full) == .busy)
    }

    @Test func wrongTokenIsForbiddenEvenWhenBusyOrUnknownPath() {
        #expect(route("/ws/video?t=nope", state: full) == .forbidden)
        #expect(route("/ws/input", state: full) == .forbidden)
        #expect(route("/secret") == .forbidden)
    }

    @Test func unknownPathWithValidTokenIsNotFound() {
        #expect(route("/index.html" + good) == .notFound)
        #expect(route("/ws/audio" + good) == .notFound)
        #expect(route("/ws/video/" + good) == .notFound)
    }

    @Test(arguments: ["POST", "PUT", "HEAD", "OPTIONS"])
    func nonGetIsRejectedBeforeTokenCheck(method: String) {
        #expect(route("/" + good, method: method) == .methodNotAllowed)
        #expect(route("/ws/video?t=nope", method: method) == .methodNotAllowed)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteRequestRouterTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'RemoteRequestRouter' in scope`。

- [ ] **Step 3: 實作**

`app/Sources/MirageCore/Remote/RemoteRequestRouter.swift`：

```swift
import Foundation

public enum RemoteRoute: Sendable, Equatable {
    case viewer
    case upgradeVideo
    case upgradeInput
    case forbidden
    case busy
    case notFound
    case methodNotAllowed
}

/// `GET /`、`/ws/video`、`/ws/input` 的路由決定（spec 第 5 節）。純函式，NIO 的
/// `shouldUpgrade` 與 HTTP 回應路徑都呼叫它，403／409 的判定只寫在這一處。
public enum RemoteRequestRouter {
    public static let viewerPath = "/"
    public static let videoPath = "/ws/video"
    public static let inputPath = "/ws/input"
    public static let tokenQueryName = "t"
    private static let getMethod = "GET"

    public static func path(fromURI uri: String) -> String {
        String(uri.prefix { $0 != "?" && $0 != "#" })
    }

    public static func token(fromURI uri: String) -> String? {
        URLComponents(string: uri)?.queryItems?.first { $0.name == tokenQueryName }?.value
    }

    public static func route(method: String, uri: String, token: PairingToken, state: RemoteSessionState) -> RemoteRoute {
        guard method == getMethod else { return .methodNotAllowed }
        guard token.matches(Self.token(fromURI: uri)) else { return .forbidden }
        switch path(fromURI: uri) {
        case viewerPath: return .viewer
        case videoPath: return state.hasVideo ? .busy : .upgradeVideo
        case inputPath: return state.hasInput ? .busy : .upgradeInput
        default: return .notFound
        }
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteRequestRouterTests 2>&1 | tail -5`
Expected: 全部通過、0 failures。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageCore/Remote/RemoteRequestRouter.swift app/Tests/MirageCoreTests/Remote/RemoteRequestRouterTests.swift && git commit -m "feat: RemoteRequestRouter 決定 viewer、升級、403、409、404"
```

---

### Task 12: `viewer.html` 與 `RemoteViewerPage`

**Files:**
- Create: `app/Sources/MirageCore/Resources/remote/viewer.html`
- Create: `app/Sources/MirageCore/Remote/RemoteViewerPage.swift`
- Modify: `app/Package.swift:32`（`resources:`）
- Test: `app/Tests/MirageCoreTests/Remote/RemoteViewerPageTests.swift`

**Interfaces:**
- Consumes: `Bundle.module` 的用法與限制照 `BuiltInProfiles.bundledSources()`（`app/Sources/MirageCore/Keymap/BuiltInProfiles.swift:45-69`）：`.copy` 保留目錄層，查表要帶 `subdirectory`；找不到 bundle 是 `fatalError`，不是回 nil。
- Produces（Task 13 的 `RemoteServerConfiguration.viewerPage` 由階段 D 用 `RemoteViewerPage.bundled()` 填入；測試直接餵假頁面）：

```swift
public enum RemoteViewerPage {
    public static func bundled() -> Data?   // bundle 在但檔案缺才回 nil
}
```

頁面協定（spec 第 4 節）：從 `location.search` 取 `t` 接到兩條 WebSocket 網址；`?stats=0` 隱藏統計面板；codec 字串從 keyframe 裡的 SPS 算（`avc1.` ＋ profile_idc、constraint flags、level_idc 各兩位十六進位）；`VideoDecoder({codec, optimizeForLatency:true})`、output 回呼 `drawImage` 後立刻 `close()`；`decodeQueueSize > 8` 丟到下一個 keyframe 並計數；觸控只送 `down|move|up|cancel`、座標相對於 contain 之後的內容區；每秒送一則 `ping`；`touch-action:none` 等四條 CSS、攔 `gesturestart`／`gesturechange`、`wakeLock`；不用 Fullscreen API。與 spike 的差別：不再接受 `?codec=`／`?hw=`，伺服器不 echo 觸控（只 echo ping），configure 失敗顯示 codec 與錯誤、不重試。

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageCoreTests/Remote/RemoteViewerPageTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

@Suite struct RemoteViewerPageTests {
    @Test func bundledPageIsPackagedAndSpeaksTheProtocol() throws {
        let page = try #require(RemoteViewerPage.bundled())
        let html = try #require(String(data: page, encoding: .utf8))
        for needle in ["<!doctype html>", "VideoDecoder", "optimizeForLatency", "/ws/video", "/ws/input",
                       "params.get('t')", "params.get('stats')", "touch-action:none", "user-select:none",
                       "-webkit-touch-callout:none", "overscroll-behavior:none", "gesturestart", "gesturechange",
                       "wakeLock", "getBigUint64(0, false)", "getUint32(8, false)", "getUint8(12)",
                       "decodeQueueSize", "type:'ping'", "frame.close()"] {
            #expect(html.contains(needle), "viewer.html 缺 \(needle)")
        }
        #expect(!html.contains("requestFullscreen"))
        #expect(!html.contains("params.get('codec')"))
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteViewerPageTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'RemoteViewerPage' in scope`。

- [ ] **Step 3: 寫頁面**

`app/Sources/MirageCore/Resources/remote/viewer.html`：

```html
<!doctype html>
<html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Mirage 遙控</title>
<style>
*{box-sizing:border-box;touch-action:none;user-select:none;-webkit-user-select:none;-webkit-touch-callout:none;overscroll-behavior:none}
html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000;color:#fff;font:13px/1.4 monospace}
canvas{position:fixed;inset:0;width:100%;height:100%;object-fit:contain}
#panel{position:fixed;top:env(safe-area-inset-top,0px);left:0;max-width:96vw;background:#000b;padding:8px;pointer-events:none;white-space:pre-wrap}
#panel[hidden]{display:none}
</style>
<canvas id="canvas" width="1080" height="2400"></canvas>
<div id="panel">連線中…</div>
<script>
const canvas = document.querySelector('#canvas'), ctx = canvas.getContext('2d', {alpha:false});
const panel = document.querySelector('#panel');
const params = new URLSearchParams(location.search), token = params.get('t') || '';
const showStats = params.get('stats') !== '0';
panel.hidden = !showStats;
const base = `ws://${location.host}`, query = `?t=${encodeURIComponent(token)}`;
const HEADER = 13, MAX_DECODE_QUEUE = 8, MAX_INPUT_BUFFER = 65536, TIMESTAMP_STEP = 16667;
let decoder = null, codec = null, video = null, input = null, wake = null;
let decoded = 0, lastDecoded = 0, received = 0, gaps = 0, dropped = 0, lastSeq = null, waiting = true;
let rtt = NaN, samples = [], pending = new Map(), tick = performance.now(), status = '連線中', inputDrops = 0;

// 從 keyframe 存取單元裡第一個 SPS（nal_unit_type 7）算 avc1.PPCCLL；找不到回 null。
function codecFromAccessUnit(bytes) {
  for (let i = 0; i + 6 < bytes.length; i++) {
    if (bytes[i] === 0 && bytes[i + 1] === 0 && bytes[i + 2] === 1) {
      if ((bytes[i + 3] & 0x1f) === 7) {
        return 'avc1.' + [bytes[i + 4], bytes[i + 5], bytes[i + 6]].map(b => b.toString(16).padStart(2, '0').toUpperCase()).join('');
      }
      i += 2;
    }
  }
  return null;
}
function makeDecoder() {
  return new VideoDecoder({
    output(frame) {
      const now = performance.now(), arrived = pending.get(frame.timestamp);
      if (arrived !== undefined) { samples.push(now - arrived); pending.delete(frame.timestamp); }
      try {
        if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
          canvas.width = frame.displayWidth; canvas.height = frame.displayHeight;
        }
        ctx.drawImage(frame, 0, 0, canvas.width, canvas.height); decoded++;
      } finally { frame.close(); }
    },
    error(e) { status = `解碼錯誤（${codec}）：${e.message}`; discard(); }
  });
}
// configure 失敗：顯示 codec 與錯誤，不重試（spec 第 7 節）。
function configure(newCodec) {
  if (!decoder || decoder.state === 'closed') decoder = makeDecoder();
  if (decoder.state === 'configured') decoder.reset();
  decoder.configure({codec: newCodec, optimizeForLatency: true});
  codec = newCodec; status = '串流中 ' + codec;
}
// 丟掉手上未畫出的幀，等下一個 keyframe。
function discard() {
  dropped += pending.size; pending.clear(); waiting = true;
  if (decoder && decoder.state === 'configured') { decoder.reset(); decoder.configure({codec, optimizeForLatency: true}); }
}
function send(obj) {
  if (input && input.readyState === WebSocket.OPEN && input.bufferedAmount < MAX_INPUT_BUFFER) input.send(JSON.stringify(obj));
  else inputDrops++;
}
function start() {
  if (typeof VideoDecoder === 'undefined') { status = '這個瀏覽器沒有 VideoDecoder'; return; }
  input = new WebSocket(base + '/ws/input' + query);
  input.onclose = () => { status = '輸入連線已斷，重新整理可重連'; };
  input.onmessage = event => {
    try { const obj = JSON.parse(event.data); if (obj.type === 'ping') rtt = performance.now() - obj.t; } catch (e) { inputDrops++; }
  };
  video = new WebSocket(base + '/ws/video' + query); video.binaryType = 'arraybuffer';
  video.onopen = () => { status = '等待 keyframe'; };
  video.onclose = () => { status = '影像連線已斷，重新整理可重連'; };
  video.onmessage = event => {
    const arrival = performance.now();
    try {
      const data = event.data;
      if (data.byteLength <= HEADER) throw new Error('短訊息');
      const header = new DataView(data);
      const sentNs = header.getBigUint64(0, false); // 另一個時鐘域，只留著給診斷用，不與 performance.now() 相減。
      const seq = header.getUint32(8, false), flag = header.getUint8(12);
      if (flag > 1 || sentNs === 0n) throw new Error('壞標頭');
      const key = flag === 1, bytes = new Uint8Array(data, HEADER);
      received++;
      if (lastSeq !== null) { const missing = (seq - lastSeq - 1) >>> 0; if (missing) { gaps += missing; discard(); } }
      lastSeq = seq;
      if (key) { const found = codecFromAccessUnit(bytes); if (found && found !== codec) configure(found); }
      if (!decoder || decoder.state !== 'configured') { dropped++; return; }
      if (decoder.decodeQueueSize > MAX_DECODE_QUEUE) discard();
      if (waiting && !key) { dropped++; return; }
      waiting = false;
      const timestamp = received * TIMESTAMP_STEP; // 本地唯一時間戳，只用來對應 output 回呼。
      pending.set(timestamp, arrival);
      decoder.decode(new EncodedVideoChunk({type: key ? 'key' : 'delta', timestamp, data: bytes}));
    } catch (e) { status = `影像錯誤（${codec}）：${e.message}`; discard(); }
  };
}
function percentile(a, p) { return a.length ? a[Math.min(a.length - 1, Math.ceil(a.length * p) - 1)].toFixed(1) : '—'; }
setInterval(() => {
  const now = performance.now(), fps = (decoded - lastDecoded) * 1000 / (now - tick);
  lastDecoded = decoded; tick = now;
  const sorted = samples.sort((x, y) => x - y); samples = [];
  if (showStats) {
    panel.textContent = `${status}\ndecode fps=${fps.toFixed(1)} queue=${decoder ? decoder.decodeQueueSize : '—'} pending=${pending.size}\n抵達→畫出 p50/p95=${percentile(sorted, .5)}/${percentile(sorted, .95)} ms (n=${sorted.length})\n往返=${Number.isFinite(rtt) ? rtt.toFixed(1) : '—'} ms\n丟幀 seq=${gaps} local=${dropped} recv=${received}\n輸入未送=${inputDrops}`;
  }
  send({type:'ping', t: performance.now()});
}, 1000);
const active = new Set(), phases = {pointerdown:'down', pointermove:'move', pointerup:'up', pointercancel:'cancel'};
// 相對於 contain 之後的內容區（不含黑邊），左上原點，0 到 1。
function position(e) {
  const r = canvas.getBoundingClientRect(), scale = Math.min(r.width / canvas.width, r.height / canvas.height);
  const w = canvas.width * scale, h = canvas.height * scale;
  return {x: (e.clientX - r.left - (r.width - w) / 2) / w, y: (e.clientY - r.top - (r.height - h) / 2) / h};
}
for (const type of Object.keys(phases)) canvas.addEventListener(type, e => {
  e.preventDefault(); const p = position(e);
  if (type === 'pointerdown') {
    if (p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1) return;
    active.add(e.pointerId); canvas.setPointerCapture(e.pointerId); requestWake();
  }
  if (!active.has(e.pointerId)) return;
  send({t: performance.now(), id: e.pointerId, type: phases[type], x: Math.max(0, Math.min(1, p.x)), y: Math.max(0, Math.min(1, p.y))});
  if (type === 'pointerup' || type === 'pointercancel') active.delete(e.pointerId);
}, {passive:false});
for (const type of ['gesturestart', 'gesturechange']) document.addEventListener(type, e => e.preventDefault(), {passive:false});
async function requestWake() {
  if (!navigator.wakeLock || wake || document.visibilityState !== 'visible') return;
  try { wake = await navigator.wakeLock.request('screen'); wake.addEventListener('release', () => { wake = null; }); }
  catch (e) { status = 'wakeLock：' + e.message; }
}
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') requestWake(); });
start(); requestWake();
</script></html>
```

- [ ] **Step 4: 宣告資源與讀取器**

`app/Package.swift:32` 改成：

```swift
            resources: [.copy("Resources/profiles"), .copy("Resources/remote")],
```

`app/Sources/MirageCore/Remote/RemoteViewerPage.swift`：

```swift
import Foundation

/// 手機頁面的讀取器。這是手機遙控唯一碰 `Bundle.module` 的地方，比照
/// `BuiltInProfiles.bundledSources()`：`.copy("Resources/remote")` 保留目錄層，所以查表帶
/// `subdirectory: "remote"`。找不到 bundle 是 SwiftPM 產生的 accessor 直接 `fatalError`
/// （見 `BuiltInProfiles.swift:55-66` 與債務 D25），回 nil 只代表 bundle 在、檔案缺。
public enum RemoteViewerPage {
    static let resourceName = "viewer"
    static let resourceExtension = "html"
    static let subdirectory = "remote"

    public static func bundled() -> Data? {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: resourceExtension,
                                          subdirectory: subdirectory)
        else { return nil }
        return try? Data(contentsOf: url)
    }
}
```

- [ ] **Step 5: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteViewerPageTests 2>&1 | tail -5`
Expected: `Test run with 1 test passed`。若 `bundled()` 回 nil，先 `ls .build/debug/Mirage_MirageCore.bundle/remote/`，確認 `.copy("Resources/remote")` 有寫進 `Package.swift` 且路徑大小寫正確。

- [ ] **Step 6: 確認 `.app` 打包會帶到這個資源**

Run: `grep -n "Mirage_MirageCore.bundle" /Users/hanfourhuang/Projects/mirage/app/scripts/package_app.sh | head -3`
Expected: 至少一行（既有腳本已把整個 resource bundle 複製進 `.app`，`remote/viewer.html` 在同一個 bundle 裡，不需要改腳本）。若零行，讀該腳本找複製 profiles 的那段，改成複製整個 bundle。

- [ ] **Step 7: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Package.swift app/Sources/MirageCore/Resources/remote/viewer.html app/Sources/MirageCore/Remote/RemoteViewerPage.swift app/Tests/MirageCoreTests/Remote/RemoteViewerPageTests.swift && git commit -m "feat: 手機頁面 viewer.html 隨 MirageCore 資源打包並由 RemoteViewerPage 讀取"
```

---

### Task 13: `RemoteServer`：NIOHTTP1＋NIOWebSocket 與 loopback 整合測試

**Files:**
- Create: `app/Sources/MirageCore/Remote/RemoteServerCore.swift`
- Create: `app/Sources/MirageCore/Remote/RemoteServer.swift`
- Create: `app/Sources/MirageCore/Remote/RemoteServer+Connections.swift`
- Test: `app/Tests/MirageCoreTests/Remote/RemoteServerTests.swift`

**Interfaces:**
- Consumes: Task 3 `PairingToken`；Task 7 `RemoteTouchMessageDecoder.decode`、`RemoteInputMessage`；Task 8 `RemoteTouchIdentifierAllocator.apply/releaseAll`、`RemoteTouchOutcome`；Task 9 `RemoteSessionState`、`RemoteSessionReducer.reduce`、`RemoteSessionEffect`；Task 10 `RemoteVideoMessage`、`RemoteVideoQueue`；Task 11 `RemoteRequestRouter.route`、`RemoteRoute`；`TouchSpec`（`KeymapEngine.swift:3-7`）。NIO 2.101.3：`ServerBootstrap.bind(host:port:childChannelInitializer:)`（`.build/checkouts/swift-nio/Sources/NIOPosix/Bootstrap.swift:538`）、`NIOTypedWebSocketServerUpgrader`（`Sources/NIOWebSocket/NIOWebSocketServerUpgrader.swift:194-236`）、`NIOTypedHTTPServerUpgradeConfiguration`（`Sources/NIOHTTP1/NIOTypedHTTPServerUpgradeHandler.swift:50-65`）、`configureUpgradableHTTPServerPipeline(configuration:)`（`Sources/NIOHTTP1/HTTPTypedPipelineSetup.swift:63`）、`NIOAsyncChannel.executeThenClose`（`Sources/NIOCore/AsyncChannel/AsyncChannel.swift:288`）、`WebSocketFrame.unmaskedData`（`Sources/NIOWebSocket/WebSocketFrame.swift:272`）。結構照 `Sources/NIOWebSocketServer/Server.swift` 的範例，`HTTPByteBufferResponsePartHandler`（範例 `:274-291`）複製進來改名 `RemoteHTTPResponsePartHandler`。測試用的 `StateRecorder`、`CountGate` 在 `app/Tests/MirageCoreTests/TestGates.swift:13-82`。
- Produces（階段 C 的 `RemoteVideoEncoder` 產出後由階段 D 的 `RemoteMirrorController` 呼叫 `send`；`AppModel+Remote` 建構、`start`、`stop`、讀 `sessionState`／`boundPort`／`stats`）：

```swift
public struct RemoteServerConfiguration: Sendable {
    public static let defaultPort = 8765
    public static let allInterfaces = "0.0.0.0"     // spec 第 5 節：監聽所有介面，安全性靠 token
    public let host: String
    public let port: Int                            // 0 = 系統挑（測試用）
    public let token: PairingToken
    public let viewerPage: Data                     // 階段 D 傳 RemoteViewerPage.bundled()
    public let queueLimit: Int
    public init(host: String = allInterfaces, port: Int = defaultPort, token: PairingToken, viewerPage: Data,
                queueLimit: Int = RemoteVideoQueue.defaultLimit)
}
public struct RemoteServerStats: Sendable, Equatable {
    public let framesOffered: Int          // send() 被呼叫的次數（含沒有 viewer 時）
    public let framesSent: Int             // 實際寫進 WebSocket 的幀
    public let framesDropped: Int          // 佇列丟的（背壓、等 keyframe）
    public let rejectedForbidden: Int      // 403
    public let rejectedBusy: Int           // 409
    public let invalidInputMessages: Int   // 解碼失敗或 allocator 拒絕的觸控訊息
    public let touchesForwarded: Int       // 交給 onTouches 的次數
}
public enum RemoteServerError: Error, Equatable { case alreadyStarted, noLocalAddress, upgradeWithoutAdmission }
public final class RemoteServer: @unchecked Sendable {
    public init(configuration: RemoteServerConfiguration,
                onTouches: @escaping @Sendable ([TouchSpec]) -> Void,             // 階段 D：inputQueue.touches($0)
                onKeyframeRequested: @escaping @Sendable () -> Void = {},         // 階段 D：要求編碼器下一幀強制 IDR
                onStateChanged: @escaping @Sendable (RemoteSessionState) -> Void = { _ in },
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now })  // log 節流用的時鐘
    public func start() async throws -> Int     // 回綁定的埠；埠被佔用時拋 NIO 的 IOError；只能 start 一次
    public func stop() async                    // 關掉 listener 與所有連線；之後不可再 start（每次開啟功能建新的 server）
    public func send(accessUnit: Data, keyframe: Bool, sequence: UInt32)   // 不阻塞；沒有 viewer 時只計數
    public func stats() -> RemoteServerStats
    public var sessionState: RemoteSessionState { get }
    public var boundPort: Int? { get }
}
```

設計要點：
- 所有可變狀態在 `RemoteServerCore` 一把 `NSLock` 底下（比照 `LatestFrameBox`）；reducer 在鎖內套用，效果（回呼）在鎖外執行。
- 每條子 channel 在 initializer 裡 `core.track(channel)`，用 `channel.closeFuture` 觸發 `channelClosed`：video／input 的關閉一律走這條，寫出／讀入迴圈不各自套 reducer，於是「握手後立刻斷線」也不會漏掉釋放。
- `shouldUpgrade` 在鎖內做路由＋`videoOpened`／`inputOpened`（保留名額），回 nil 時 NIO 把請求交回 HTTP 路徑，由同一個 `route` 算出 403／409。
- 送出迴圈：`send()` 把幀交給 `RemoteVideoQueue`，用 `AsyncStream<Void>`（`bufferingNewest(1)`）叫醒寫出 task；`outbound.write` 會在 TCP 不可寫時等待，佇列因此累積、滿了丟 GOP，這就是 spec 的背壓規則。
- 事件迴圈用 `MultiThreadedEventLoopGroup.singleton`，不自建 group、不在 deinit shutdown（D1／D8 的教訓：阻塞式 `syncShutdownGracefully` 佔死 cooperative 執行緒）。

- [ ] **Step 1: 寫失敗的整合測試**

`app/Tests/MirageCoreTests/Remote/RemoteServerTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

/// 用 `127.0.0.1:0` 起真實 socket；用戶端是 Foundation 的 URLSession（握手被拒時
/// `task.response` 帶狀態碼，2026-09-12 實測 403／409 皆可讀）。`.serialized` 是因為
/// 每條測試都開 listener，並行只會把負載造成的逾時混進來。
@Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteServerTests {
    private static let token = PairingToken(value: "00112233445566778899aabbccddeeff")!
    private static let page = Data("<!doctype html><title>t</title>VideoDecoder".utf8)
    private static let keyframeUnit = H264Nal.join([
        Data([0x27, 0x42, 0x00, 0x32, 0xab, 0x40, 0x22, 0x00, 0x96, 0xf2, 0xe8]),
        Data([0x28, 0xce, 0x3c, 0x80]),
        Data([0x65, 0x88, 0x84, 0x00]),
    ])
    private static let deltaUnit = H264Nal.join([Data([0x41, 0x9a, 0x02])])
    private static let down = #"{"t":1,"id":7,"type":"down","x":0.25,"y":0.75}"#
    private static let ping = #"{"type":"ping","t":1234.5}"#

    private enum TestFailure: Error { case unexpectedMessageKind }

    private struct Harness {
        let server: RemoteServer
        let port: Int
        let touches: StateRecorder<[TouchSpec]>
        let states: StateRecorder<RemoteSessionState>
        let keyframes: CountGate
    }

    private func start() async throws -> Harness {
        let touches = StateRecorder<[TouchSpec]>()
        let states = StateRecorder<RemoteSessionState>()
        let keyframes = CountGate()
        let server = RemoteServer(
            configuration: RemoteServerConfiguration(host: "127.0.0.1", port: 0, token: Self.token, viewerPage: Self.page),
            onTouches: { specs in Task { await touches.record(specs) } },
            onKeyframeRequested: { keyframes.increment() },
            onStateChanged: { state in Task { await states.record(state) } })
        let port = try await server.start()
        return Harness(server: server, port: port, touches: touches, states: states, keyframes: keyframes)
    }

    private func url(_ port: Int, _ path: String, token: String? = RemoteServerTests.token.value, scheme: String = "http") -> URL {
        var c = URLComponents()
        c.scheme = scheme; c.host = "127.0.0.1"; c.port = port; c.path = path
        if let token { c.queryItems = [URLQueryItem(name: "t", value: token)] }
        return c.url!
    }

    private func get(_ port: Int, _ path: String, token: String? = RemoteServerTests.token.value) async throws -> (status: Int, body: Data) {
        let (data, response) = try await URLSession.shared.data(from: url(port, path, token: token))
        return (try #require(response as? HTTPURLResponse).statusCode, data)
    }

    private func webSocket(_ port: Int, _ path: String, token: String? = RemoteServerTests.token.value) -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(with: url(port, path, token: token, scheme: "ws"))
        task.resume()
        return task
    }

    /// 只給「預期被拒」的握手用：receive 會拋錯，狀態碼在 task.response。
    private func handshakeStatus(_ task: URLSessionWebSocketTask) async -> Int? {
        _ = try? await task.receive()
        return (task.response as? HTTPURLResponse)?.statusCode
    }

    private func receiveData(_ task: URLSessionWebSocketTask) async throws -> Data {
        guard case .data(let data) = try await task.receive() else { throw TestFailure.unexpectedMessageKind }
        return data
    }

    private func receiveText(_ task: URLSessionWebSocketTask) async throws -> String {
        guard case .string(let text) = try await task.receive() else { throw TestFailure.unexpectedMessageKind }
        return text
    }

    @Test func servesViewerOnlyWithCorrectToken() async throws {
        let h = try await start()
        #expect(h.port > 0)
        #expect(h.server.boundPort == h.port)
        let ok = try await get(h.port, "/")
        #expect(ok.status == 200)
        #expect(ok.body == Self.page)
        let wrongToken = try await get(h.port, "/", token: "00112233445566778899aabbccddeefe")
        #expect(wrongToken.status == 403)
        let noToken = try await get(h.port, "/", token: nil)
        #expect(noToken.status == 403)
        let unknownPath = try await get(h.port, "/nope")
        #expect(unknownPath.status == 404)
        #expect(h.server.stats().rejectedForbidden == 2)
        #expect(h.server.sessionState == .initial)
        await h.server.stop()
    }

    @Test func videoViewerGetsKeyframeFirstAndSequenceHeader() async throws {
        let h = try await start()
        let video = webSocket(h.port, "/ws/video")
        await h.states.wait { $0.contains { $0.hasVideo } }
        await h.keyframes.wait(for: 1)

        h.server.send(accessUnit: Self.deltaUnit, keyframe: false, sequence: 0)   // 等 keyframe 期間丟掉
        h.server.send(accessUnit: Self.keyframeUnit, keyframe: true, sequence: 1)
        let first = try #require(RemoteVideoMessage.decode(try await receiveData(video)))
        #expect(first.sequence == 1)
        #expect(first.isKeyframe)
        #expect(first.accessUnit == Self.keyframeUnit)
        #expect(first.sentAtNanoseconds > 0)

        h.server.send(accessUnit: Self.deltaUnit, keyframe: false, sequence: 2)
        let second = try #require(RemoteVideoMessage.decode(try await receiveData(video)))
        #expect(second.sequence == 2)
        #expect(!second.isKeyframe)

        let stats = h.server.stats()
        #expect(stats.framesOffered == 3)
        #expect(stats.framesSent == 2)
        #expect(stats.framesDropped == 1)
        #expect(h.server.sessionState.isViewerConnected)
        video.cancel(with: .normalClosure, reason: nil)
        await h.states.wait { $0.contains { $0.phase == .disconnected } }
        await h.server.stop()
    }

    @Test func secondVideoSocketIsRefusedWith409AndFirstKeepsWorking() async throws {
        let h = try await start()
        let first = webSocket(h.port, "/ws/video")
        await h.states.wait { $0.contains { $0.hasVideo } }
        let second = webSocket(h.port, "/ws/video")
        let secondStatus = await handshakeStatus(second)
        #expect(secondStatus == 409)
        #expect(h.server.stats().rejectedBusy == 1)
        h.server.send(accessUnit: Self.keyframeUnit, keyframe: true, sequence: 10)
        let data = try await receiveData(first)
        #expect(try #require(RemoteVideoMessage.decode(data)).sequence == 10)
        first.cancel(with: .normalClosure, reason: nil)
        await h.server.stop()
    }

    @Test func wrongTokenUpgradeIs403AndLeavesStateUntouched() async throws {
        let h = try await start()
        let video = webSocket(h.port, "/ws/video", token: "00112233445566778899aabbccddeefe")
        let videoStatus = await handshakeStatus(video)
        #expect(videoStatus == 403)
        let input = webSocket(h.port, "/ws/input", token: nil)
        let inputStatus = await handshakeStatus(input)
        #expect(inputStatus == 403)
        #expect(h.server.stats().rejectedForbidden == 2)
        #expect(h.server.sessionState == .initial)
        await h.server.stop()
    }

    @Test func inputEchoesPingVerbatimAndForwardsTouches() async throws {
        let h = try await start()
        let input = webSocket(h.port, "/ws/input")
        try await input.send(.string(Self.ping))
        let echo = try await receiveText(input)
        #expect(echo == Self.ping)

        try await input.send(.string(Self.down))
        await h.touches.wait { !$0.isEmpty }
        let forwarded = await h.touches.items
        #expect(forwarded == [[TouchSpec(identifier: 64, point: NormPoint(x: 0.25, y: 0.75), down: true)]])

        try await input.send(.string("nope"))
        try await input.send(.string(#"{"type":"move","id":99,"x":0.5,"y":0.5}"#))   // 未知 pointer
        try await input.send(.string(Self.ping))                                      // 同一條連線依序處理，echo 回來代表前兩則已處理
        let secondEcho = try await receiveText(input)
        #expect(secondEcho == Self.ping)
        let stats = h.server.stats()
        #expect(stats.invalidInputMessages == 2)
        #expect(stats.touchesForwarded == 1)
        input.cancel(with: .normalClosure, reason: nil)
        await h.server.stop()
    }

    @Test func closingInputReleasesActiveTouches() async throws {
        let h = try await start()
        let input = webSocket(h.port, "/ws/input")
        try await input.send(.string(Self.down))
        await h.touches.wait { $0.count == 1 }
        input.cancel(with: .normalClosure, reason: nil)
        await h.touches.wait { $0.count == 2 }
        let released = await h.touches.items[1]
        #expect(released == [TouchSpec(identifier: 64, point: NormPoint(x: 0.25, y: 0.75), down: false)])
        await h.states.wait { $0.contains { $0.phase == .disconnected } }
        #expect(h.server.stats().touchesForwarded == 2)
        await h.server.stop()
    }

    @Test func stopClosesViewerReleasesTouchesAndReportsDisconnected() async throws {
        let h = try await start()
        let video = webSocket(h.port, "/ws/video")
        let input = webSocket(h.port, "/ws/input")
        try await input.send(.string(Self.down))
        await h.touches.wait { $0.count == 1 }
        await h.states.wait { $0.contains { $0.hasVideo && $0.hasInput } }

        await h.server.stop()
        #expect(h.server.sessionState == RemoteSessionState(phase: .disconnected, hasVideo: false, hasInput: false))
        await h.touches.wait { $0.count == 2 }
        let released = await h.touches.items[1]
        #expect(released == [TouchSpec(identifier: 64, point: NormPoint(x: 0.25, y: 0.75), down: false)])
        await #expect(throws: (any Error).self) { _ = try await video.receive() }
        h.server.send(accessUnit: Self.keyframeUnit, keyframe: true, sequence: 1)   // 停止後不崩、只計數
        #expect(h.server.stats().framesOffered == 1)
        #expect(h.server.stats().framesSent == 0)
        input.cancel(with: .normalClosure, reason: nil)
    }

    @Test func startTwiceIsRejected() async throws {
        let h = try await start()
        await #expect(throws: RemoteServerError.alreadyStarted) { _ = try await h.server.start() }
        await h.server.stop()
    }

    @Test func portInUseFailsToStart() async throws {
        let h = try await start()
        let clash = RemoteServer(
            configuration: RemoteServerConfiguration(host: "127.0.0.1", port: h.port, token: Self.token, viewerPage: Self.page),
            onTouches: { _ in })
        await #expect(throws: (any Error).self) { _ = try await clash.start() }
        await h.server.stop()
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteServerTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'RemoteServer' in scope`。

- [ ] **Step 3: 實作 `RemoteServerCore`（鎖保護的狀態）**

`app/Sources/MirageCore/Remote/RemoteServerCore.swift`：

```swift
import Foundation
import NIOCore

public struct RemoteServerConfiguration: Sendable {
    public static let defaultPort = 8765
    public static let allInterfaces = "0.0.0.0"

    public let host: String
    public let port: Int
    public let token: PairingToken
    public let viewerPage: Data
    public let queueLimit: Int

    public init(host: String = allInterfaces, port: Int = defaultPort, token: PairingToken, viewerPage: Data,
                queueLimit: Int = RemoteVideoQueue.defaultLimit)
    {
        self.host = host
        self.port = port
        self.token = token
        self.viewerPage = viewerPage
        self.queueLimit = queueLimit
    }
}

public struct RemoteServerStats: Sendable, Equatable {
    public let framesOffered: Int
    public let framesSent: Int
    public let framesDropped: Int
    public let rejectedForbidden: Int
    public let rejectedBusy: Int
    public let invalidInputMessages: Int
    public let touchesForwarded: Int
}

enum RemoteUpgradeKind: Sendable {
    case video
    case input
}

/// `RemoteServer` 的全部可變狀態，一把鎖（比照 `LatestFrameBox`）。
///
/// reducer 在鎖內套用、效果（回呼）一律在鎖外執行，避免回呼再進來拿鎖。每條子 channel 都
/// 在 `track` 登記，`closeFuture` 觸發 `channelClosed`，所以 video／input 的關閉只有一條路徑。
final class RemoteServerCore: @unchecked Sendable {
    static let invalidLogInterval: Duration = .seconds(1)

    let configuration: RemoteServerConfiguration
    private let onTouches: @Sendable ([TouchSpec]) -> Void
    private let onKeyframeRequested: @Sendable () -> Void
    private let onStateChanged: @Sendable (RemoteSessionState) -> Void
    private let now: @Sendable () -> ContinuousClock.Instant

    private let lock = NSLock()
    private var session = RemoteSessionState.initial
    private var queue: RemoteVideoQueue
    private var allocator = RemoteTouchIdentifierAllocator()
    private var kinds: [ObjectIdentifier: RemoteUpgradeKind] = [:]
    private var channels: [ObjectIdentifier: any Channel] = [:]
    private var wakeup: AsyncStream<Void>.Continuation?
    private var framesOffered = 0
    private var framesSent = 0
    private var framesDroppedBeforeReset = 0   // 佇列被 requestKeyframe 重置前累積的丟幀
    private var rejectedForbidden = 0
    private var rejectedBusy = 0
    private var invalidInputMessages = 0
    private var touchesForwarded = 0
    private var lastInvalidLog: ContinuousClock.Instant?

    init(configuration: RemoteServerConfiguration,
         onTouches: @escaping @Sendable ([TouchSpec]) -> Void,
         onKeyframeRequested: @escaping @Sendable () -> Void,
         onStateChanged: @escaping @Sendable (RemoteSessionState) -> Void,
         now: @escaping @Sendable () -> ContinuousClock.Instant)
    {
        self.configuration = configuration
        self.onTouches = onTouches
        self.onKeyframeRequested = onKeyframeRequested
        self.onStateChanged = onStateChanged
        self.now = now
        queue = RemoteVideoQueue(limit: configuration.queueLimit)
    }

    // MARK: - 查詢

    var sessionState: RemoteSessionState {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    func snapshot() -> RemoteServerStats {
        lock.lock(); defer { lock.unlock() }
        return RemoteServerStats(framesOffered: framesOffered, framesSent: framesSent,
                                 framesDropped: framesDroppedBeforeReset + queue.dropped,
                                 rejectedForbidden: rejectedForbidden, rejectedBusy: rejectedBusy,
                                 invalidInputMessages: invalidInputMessages, touchesForwarded: touchesForwarded)
    }

    // MARK: - 連線生命週期

    func route(method: String, uri: String) -> RemoteRoute {
        lock.lock(); defer { lock.unlock() }
        return RemoteRequestRouter.route(method: method, uri: uri, token: configuration.token, state: session)
    }

    /// `shouldUpgrade` 呼叫：鎖內路由＋保留名額。回 nil 代表拒絕，NIO 會把請求交回 HTTP 路徑算狀態碼。
    func admitUpgrade(channel: any Channel, method: String, uri: String) -> RemoteUpgradeKind? {
        lock.lock()
        let route = RemoteRequestRouter.route(method: method, uri: uri, token: configuration.token, state: session)
        let kind: RemoteUpgradeKind?
        switch route {
        case .upgradeVideo: kind = .video
        case .upgradeInput: kind = .input
        default: kind = nil
        }
        guard let kind else { lock.unlock(); return nil }
        kinds[ObjectIdentifier(channel)] = kind
        let effects = applyLocked(kind == .video ? .videoOpened : .inputOpened)
        lock.unlock()
        perform(effects)
        return kind
    }

    func kind(of channel: any Channel) -> RemoteUpgradeKind? {
        lock.lock(); defer { lock.unlock() }
        return kinds[ObjectIdentifier(channel)]
    }

    func track(_ channel: any Channel) {
        let id = ObjectIdentifier(channel)
        lock.lock()
        channels[id] = channel
        lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in self?.channelClosed(id) }
    }

    func channelClosed(_ id: ObjectIdentifier) {
        lock.lock()
        channels[id] = nil
        guard let kind = kinds.removeValue(forKey: id) else { lock.unlock(); return }
        if kind == .video { wakeup?.finish(); wakeup = nil }
        let effects = applyLocked(kind == .video ? .videoClosed : .inputClosed)
        lock.unlock()
        perform(effects)
    }

    func recordHTTP(_ route: RemoteRoute) {
        lock.lock(); defer { lock.unlock() }
        switch route {
        case .forbidden: rejectedForbidden += 1
        case .busy: rejectedBusy += 1
        default: break
        }
    }

    func stop() {
        lock.lock()
        let open = Array(channels.values)
        channels.removeAll()
        kinds.removeAll()
        wakeup?.finish()
        wakeup = nil
        let effects = applyLocked(.stopRequested)
        lock.unlock()
        for channel in open { channel.close(promise: nil) }
        perform(effects)
    }

    // MARK: - 影像

    /// 沒有 viewer 時只計數。有 viewer 但寫出迴圈還沒 attach（升級回應還在路上）時照樣入列，
    /// `attachVideoWakeups()` 會立刻 yield 一次把它們送出去。
    func offer(accessUnit: Data, keyframe: Bool, sequence: UInt32) {
        lock.lock()
        framesOffered += 1
        guard session.hasVideo else { lock.unlock(); return }
        let entry = RemoteVideoQueue.Entry(sequence: sequence, isKeyframe: keyframe, accessUnit: accessUnit)
        let (next, accepted) = queue.offering(entry)
        queue = next
        let wakeup = self.wakeup
        lock.unlock()
        if accepted { wakeup?.yield(()) }
    }

    /// 寫出迴圈在連線建立後呼叫。回傳的 stream 每收到一個值代表「佇列有東西」；
    /// 立刻 yield 一次是為了把連線建立前就排進佇列的 keyframe 送出去。
    func attachVideoWakeups() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.lock()
        wakeup?.finish()
        wakeup = continuation
        lock.unlock()
        continuation.yield(())
        return stream
    }

    func popVideoEntry() -> RemoteVideoQueue.Entry? {
        lock.lock(); defer { lock.unlock() }
        let (next, entry) = queue.popping()
        queue = next
        return entry
    }

    func recordSent() {
        lock.lock(); framesSent += 1; lock.unlock()
    }

    // MARK: - 輸入

    /// 回傳值非 nil 代表要原封 echo 回去（只有 ping）。
    func handleInputText(_ text: String) -> String? {
        switch RemoteTouchMessageDecoder.decode(text) {
        case .success(.ping):
            return text
        case .success(.touch(let message)):
            lock.lock()
            let (next, outcome) = allocator.apply(message)
            allocator = next
            switch outcome {
            case .emit(let spec):
                touchesForwarded += 1
                lock.unlock()
                onTouches([spec])
            case .rejected(let reason):
                noteInvalidLocked("觸控被拒：\(reason)")
                lock.unlock()
            }
            return nil
        case .failure(let error):
            lock.lock()
            noteInvalidLocked("解碼失敗：\(error)")
            lock.unlock()
            return nil
        }
    }

    // MARK: - 私有

    /// 只在鎖內呼叫。回傳要在鎖外執行的效果（含狀態變更通知）。
    private func applyLocked(_ event: RemoteSessionEvent) -> [() -> Void] {
        let (next, effect) = RemoteSessionReducer.reduce(session, event)
        var effects: [() -> Void] = []
        if next != session {
            session = next
            let onStateChanged = self.onStateChanged
            effects.append { onStateChanged(next) }
        }
        switch effect {
        case .none:
            break
        case .rejectBusy:
            rejectedBusy += 1
        case .requestKeyframe:
            framesDroppedBeforeReset += queue.dropped
            queue = RemoteVideoQueue(limit: configuration.queueLimit)
            let onKeyframeRequested = self.onKeyframeRequested
            effects.append { onKeyframeRequested() }
        case .releaseTouches:
            let (cleared, released) = allocator.releaseAll()
            allocator = cleared
            if !released.isEmpty {
                touchesForwarded += 1
                let onTouches = self.onTouches
                effects.append { onTouches(released) }
            }
        }
        return effects
    }

    private func perform(_ effects: [() -> Void]) {
        for effect in effects { effect() }
    }

    /// 只在鎖內呼叫。計數每則都算，log 每秒最多一行（spec 第 7 節）。
    private func noteInvalidLocked(_ reason: String) {
        invalidInputMessages += 1
        let current = now()
        if let last = lastInvalidLog, current - last < Self.invalidLogInterval { return }
        lastInvalidLog = current
        print("[remote] 無效的觸控訊息：\(reason)（累計 \(invalidInputMessages)）")
    }
}
```

- [ ] **Step 4: 實作 `RemoteServer`（bootstrap 與 accept 迴圈）**

`app/Sources/MirageCore/Remote/RemoteServer.swift`：

```swift
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

public enum RemoteServerError: Error, Equatable {
    case alreadyStarted
    case noLocalAddress
    case upgradeWithoutAdmission
}

enum RemoteUpgradeResult: Sendable {
    case websocket(RemoteUpgradeKind, NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
    case http(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
}

/// 手機遙控的 HTTP＋WebSocket 伺服器（spec 第 3、4、5 節）。
///
/// 一個實例只能 `start()` 一次；`stop()` 之後要再開就建新的。事件迴圈用
/// `MultiThreadedEventLoopGroup.singleton`，不自建 group、不在 deinit shutdown（D1／D8）。
public final class RemoteServer: @unchecked Sendable {
    typealias Listener = NIOAsyncChannel<EventLoopFuture<RemoteUpgradeResult>, Never>
    private static let maxFrameSize = 1 << 16

    let core: RemoteServerCore
    private let configuration: RemoteServerConfiguration
    private let lock = NSLock()
    private var listener: Listener?
    private var acceptTask: Task<Void, Never>?
    private var port: Int?
    private var started = false

    public init(configuration: RemoteServerConfiguration,
                onTouches: @escaping @Sendable ([TouchSpec]) -> Void,
                onKeyframeRequested: @escaping @Sendable () -> Void = {},
                onStateChanged: @escaping @Sendable (RemoteSessionState) -> Void = { _ in },
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now })
    {
        self.configuration = configuration
        core = RemoteServerCore(configuration: configuration, onTouches: onTouches,
                                onKeyframeRequested: onKeyframeRequested, onStateChanged: onStateChanged, now: now)
    }

    public var sessionState: RemoteSessionState { core.sessionState }

    public var boundPort: Int? {
        lock.lock(); defer { lock.unlock() }
        return port
    }

    public func stats() -> RemoteServerStats { core.snapshot() }

    public func send(accessUnit: Data, keyframe: Bool, sequence: UInt32) {
        core.offer(accessUnit: accessUnit, keyframe: keyframe, sequence: sequence)
    }

    public func start() async throws -> Int {
        lock.lock()
        guard !started else { lock.unlock(); throw RemoteServerError.alreadyStarted }
        started = true
        lock.unlock()

        let core = self.core
        let listener: Listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .bind(host: configuration.host, port: configuration.port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try Self.configureChild(channel, core: core)
                }
            }
        guard let boundPort = listener.channel.localAddress?.port else {
            try? await listener.channel.close().get()
            throw RemoteServerError.noLocalAddress
        }
        let task = Task.detached { await Self.acceptLoop(listener, core: core) }
        lock.lock()
        self.listener = listener
        acceptTask = task
        port = boundPort
        lock.unlock()
        return boundPort
    }

    public func stop() async {
        lock.lock()
        let listener = self.listener
        let task = acceptTask
        self.listener = nil
        acceptTask = nil
        lock.unlock()
        core.stop()
        if let listener { try? await listener.channel.close().get() }
        task?.cancel()
        if let task { await task.value }
    }

    // MARK: - Pipeline

    private static func configureChild(_ channel: any Channel, core: RemoteServerCore) throws
        -> EventLoopFuture<RemoteUpgradeResult>
    {
        core.track(channel)
        let upgrader = NIOTypedWebSocketServerUpgrader<RemoteUpgradeResult>(
            maxFrameSize: maxFrameSize,
            shouldUpgrade: { channel, head in
                let admitted = core.admitUpgrade(channel: channel, method: head.method.rawValue, uri: head.uri)
                return channel.eventLoop.makeSucceededFuture(admitted == nil ? nil : HTTPHeaders())
            },
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    guard let kind = core.kind(of: channel) else { throw RemoteServerError.upgradeWithoutAdmission }
                    let websocket = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(wrappingChannelSynchronously: channel)
                    return RemoteUpgradeResult.websocket(kind, websocket)
                }
            })
        let upgradeConfiguration = NIOTypedHTTPServerUpgradeConfiguration(
            upgraders: [upgrader],
            notUpgradingCompletionHandler: { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(RemoteHTTPResponsePartHandler())
                    let http = try NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>(
                        wrappingChannelSynchronously: channel)
                    return RemoteUpgradeResult.http(http)
                }
            })
        return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
            configuration: .init(upgradeConfiguration: upgradeConfiguration))
    }

    // MARK: - Accept 迴圈

    private static func acceptLoop(_ listener: Listener, core: RemoteServerCore) async {
        do {
            try await withThrowingDiscardingTaskGroup { group in
                try await listener.executeThenClose { inbound in
                    for try await upgradeFuture in inbound {
                        group.addTask { await handle(upgradeFuture, core: core) }
                    }
                }
            }
        } catch {
            print("[remote] accept 迴圈結束：\(error)")
        }
    }

    private static func handle(_ future: EventLoopFuture<RemoteUpgradeResult>, core: RemoteServerCore) async {
        do {
            switch try await future.get() {
            case .websocket(.video, let channel): try await RemoteVideoConnection.run(channel, core: core)
            case .websocket(.input, let channel): try await RemoteInputConnection.run(channel, core: core)
            case .http(let channel): try await RemoteHTTPConnection.run(channel, core: core)
            }
        } catch {
            print("[remote] 連線結束：\(error)")
        }
    }
}

/// 從 NIO 範例 `NIOWebSocketServer/Server.swift:274-291` 複製：把 `HTTPPart<HTTPResponseHead, ByteBuffer>`
/// 轉成 `HTTPServerResponsePart`，讓 HTTP 路徑能用 `NIOAsyncChannel` 寫回應。
final class RemoteHTTPResponsePartHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch Self.unwrapOutboundIn(data) {
        case .head(let head):
            context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
        case .body(let buffer):
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end(let trailers):
            context.write(Self.wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}
```

- [ ] **Step 5: 實作三種連線的處理**

`app/Sources/MirageCore/Remote/RemoteServer+Connections.swift`：

```swift
import Foundation
import NIOCore
import NIOHTTP1
import NIOWebSocket

/// `GET /` 與被拒的升級請求：回一則 HTTP 回應後關閉。
enum RemoteHTTPConnection {
    typealias Channel = NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>
    private static let htmlType = "text/html; charset=utf-8"
    private static let textType = "text/plain; charset=utf-8"

    static func run(_ channel: Channel, core: RemoteServerCore) async throws {
        try await channel.executeThenClose { inbound, outbound in
            for try await part in inbound {
                guard case .head(let head) = part else { continue }
                let route = core.route(method: head.method.rawValue, uri: head.uri)
                core.recordHTTP(route)
                let response = response(for: route, viewerPage: core.configuration.viewerPage)
                var headers = HTTPHeaders()
                headers.add(name: "Content-Type", value: response.contentType)
                headers.add(name: "Content-Length", value: String(response.body.count))
                headers.add(name: "Cache-Control", value: "no-store")
                headers.add(name: "Connection", value: "close")
                try await outbound.write(contentsOf: [
                    .head(HTTPResponseHead(version: .http1_1, status: response.status, headers: headers)),
                    .body(ByteBuffer(bytes: response.body)),
                    .end(nil),
                ])
                return
            }
        }
    }

    static func response(for route: RemoteRoute, viewerPage: Data)
        -> (status: HTTPResponseStatus, body: Data, contentType: String)
    {
        switch route {
        case .viewer: return (.ok, viewerPage, htmlType)
        case .forbidden: return (.forbidden, Data("forbidden\n".utf8), textType)
        case .busy: return (.conflict, Data("a viewer is already connected\n".utf8), textType)
        case .notFound: return (.notFound, Data("not found\n".utf8), textType)
        case .methodNotAllowed: return (.methodNotAllowed, Data("method not allowed\n".utf8), textType)
        case .upgradeVideo, .upgradeInput: return (.upgradeRequired, Data("websocket upgrade required\n".utf8), textType)
        }
    }
}

/// `/ws/video`：只寫不讀（回 pong、收 close）。寫出迴圈由 `RemoteServerCore` 的 wakeup 驅動。
enum RemoteVideoConnection {
    static func run(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, core: RemoteServerCore) async throws {
        let wakeups = core.attachVideoWakeups()
        try await channel.executeThenClose { inbound, outbound in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await frame in inbound {
                        switch frame.opcode {
                        case .connectionClose: return
                        case .ping: try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData))
                        default: break
                        }
                    }
                }
                group.addTask {
                    for await _ in wakeups {
                        while let entry = core.popVideoEntry() {
                            let message = RemoteVideoMessage(sentAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                                             sequence: entry.sequence, isKeyframe: entry.isKeyframe,
                                                             accessUnit: entry.accessUnit)
                            try await outbound.write(WebSocketFrame(fin: true, opcode: .binary,
                                                                    data: ByteBuffer(bytes: message.encoded())))
                            core.recordSent()
                        }
                    }
                }
                try await group.next()
                group.cancelAll()
            }
        }
    }
}

/// `/ws/input`：文字訊息交給 core，ping 原封 echo。
enum RemoteInputConnection {
    static func run(_ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, core: RemoteServerCore) async throws {
        try await channel.executeThenClose { inbound, outbound in
            for try await frame in inbound {
                switch frame.opcode {
                case .connectionClose:
                    return
                case .ping:
                    try await outbound.write(WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData))
                case .text:
                    if let reply = core.handleInputText(String(buffer: frame.unmaskedData)) {
                        try await outbound.write(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: reply)))
                    }
                default:
                    break
                }
            }
        }
    }
}
```

- [ ] **Step 6: 跑整合測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteServerTests 2>&1 | tail -15`
Expected: `Test run with 9 tests passed`。常見紅燈與對應：
- `videoViewerGetsKeyframeFirstAndSequenceHeader` 卡住不回：`attachVideoWakeups()` 沒有立刻 `yield`，連線前就排進佇列的 keyframe 沒人送。
- `closingInputReleasesActiveTouches` 收不到第二筆：`track(_:)` 沒掛 `closeFuture`，或 `channelClosed` 在 `kinds` 找不到（`admitUpgrade` 沒寫 `kinds`）。
- 握手狀態碼是 nil：用戶端沒等到回應就被關；確認 HTTP 路徑有寫 `.end(nil)` 再 return。
- 編譯錯 `Channel` 不是 `Sendable`：NIO 2.101.3 的 `Channel` 是 `_NIOPreconcurrencySendable`；在 `RemoteServerCore` 的 `channels` 字典宣告上加 `nonisolated(unsafe)` 不對，改成把 `any Channel` 存在 `@unchecked Sendable` 的本類別即可（本類別已是）。

- [ ] **Step 7: 檔案長度與全套件**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && wc -l Sources/MirageCore/Remote/RemoteServer*.swift && swift test 2>&1 | tail -3`
Expected: 三個檔各小於 400 行；全套件 0 failures（活體測試顯示 skipped 是正常的）。

- [ ] **Step 8: 跑 ci.sh**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && ./scripts/ci.sh 2>&1 | tail -20; echo "exit=$?"`
Expected: 每道閘門 ok，最後 `exit=0`。閘門 3（假 skip）與閘門 5（Bool 對 true/false）若紅，回頭改測試而不是加例外。

- [ ] **Step 9: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageCore/Remote/RemoteServerCore.swift app/Sources/MirageCore/Remote/RemoteServer.swift app/Sources/MirageCore/Remote/RemoteServer+Connections.swift app/Tests/MirageCoreTests/Remote/RemoteServerTests.swift && git commit -m "feat: RemoteServer 以 NIOHTTP1 與 NIOWebSocket 提供配對頁、影像串流與觸控回傳"
```

---

## Self-Review

**1. Spec coverage（第 3、4、5、6、7、8、9 節對 A、B 的要求）**

| 要求 | Task |
|---|---|
| `Package.swift` 補 swift-nio `exact: "2.101.3"`、四個 product | 1 |
| `BroadcastFrameSink`：`put` 扇出、`takeLatest`／`stats` 代理、既有四個型別不改 | 2 |
| `PairingToken`：128-bit、`randomSource` 注入、常數時間比對 | 3 |
| `H264Nal`：起始碼切分、存取單元打包、型別判斷 | 4 |
| `H264SpsRewriter`：VUI 注入、emulation prevention 往返、冪等、真實 SPS 素材 | 5、6 |
| `RemoteTouchMessage`：驗型別／識別碼／座標、夾取、抬起強制 `down:false` | 7 |
| 識別碼 64 到 79、上限 10、斷線全放開 | 8 |
| `RemoteSessionState` reducer，比照 `ConnectionStateMachine` | 9 |
| 訊息格式 13-byte 標頭；背壓丟整 GOP 並計數；新連線從下一個 IDR 開始 | 10、13 |
| `GET /?t=` 回 viewer、升級驗 token、403 不透露連線、第二條 409 | 11、13 |
| viewer.html：`optimizeForLatency`、drawImage 後 close、四條 CSS、攔 gesture、wakeLock、不用 Fullscreen、`?stats=0`、codec 從 SPS 算、`decodeQueueSize > 8` 丟到 keyframe | 12 |
| 隨 `Mirage_MirageCore.bundle` 打包 | 12（`.copy("Resources/remote")`，`package_app.sh` 複製整個 bundle） |
| `ping` 原封 echo | 13 |
| 觸控訊息錯誤：丟棄、計數、每秒最多一行 log | 13（`noteInvalidLocked`） |
| 埠被佔用：`start()` 拋錯，功能維持關閉 | 13（`portInUseFailsToStart`；選單顯示是階段 D） |
| `RemoteServer` 用 `127.0.0.1:0` 真 socket 測配對、拒絕第二連線、訊息格式 | 13 |
| 手機斷線 token 保留、可重連 | 9（`reconnectAfterDisconnectIsAllowedWithKeyframe`）、13 的 server 不在斷線時作廢 token |

未涵蓋（刻意，屬 C／D／E）：`RemoteVideoEncoder`、`RemoteMirrorController`、`AppModel+Remote`、`AppLifecycle.windowShouldClose` guard、選單與 QR、`verify_remote_mirror.sh`、fps 對照、glass-to-glass。spec 第 4 節「新連線先送最近的 SPS/PPS」：keyframe 訊息本身含 SPS＋PPS（Task 4 的 packer 保證），`requestKeyframe` 效果讓階段 D 立刻要一個 IDR，不另送 config 訊息，與同節「不由伺服器另外送 config 訊息」一致。TCP 層真實背壓（寫出被卡住到佇列滿）在 loopback 上無法可靠重現，背壓規則由 Task 10 的純函式測試涵蓋，Task 13 只測「等 keyframe 期間丟 delta」這一半。

**2. Placeholder scan**：全文搜過 `TBD`、`TODO`、「之後補」、「類似 Task」、「參考 Task」、「適當的錯誤處理」，零命中。每個測試步驟都有完整程式碼；每個實作步驟都有完整檔案內容。

**3. Type consistency**：
- `FrameSink` 三個方法名與 `FrameSink.swift:6-8` 一致；`FrameCounterSnapshot` 用既有型別。
- `PairingToken.matches(_:)` 在 Task 3 定義、Task 11 `RemoteRequestRouter.route` 呼叫。
- `H264Rbsp.unescape/escape/bits/ueBits/finishRbsp`、`H264BitReader.u/flag/ue/se/position/bits`、`H264SpsError` 在 Task 5 定義、Task 6 使用。
- `H264Nal.rawType(of:)`、`H264NalType.sps.rawValue` 在 Task 4 定義、Task 6 使用；`H264Nal.startCode`／`join` 在 Task 10、13 使用。
- `H264AccessUnitPacker.pack(_:rewriteSps:)` 的閉包型別 `(Data) -> Data?` 與 `H264SpsRewriter.rewriteOrNil` 相符。
- `RemoteTouchMessage(pointerId:phase:point:time:)`、`isDown`、`RemoteInputMessage`、`RemoteTouchMessageDecoder.decode` 在 Task 7 定義，Task 8 與 Task 13 使用。
- `RemoteTouchIdentifierAllocator.apply/releaseAll` 的回傳 tuple 標籤 `(allocator:, outcome:)`／`(allocator:, released:)` 在 Task 8 與 Task 13 `applyLocked`／`handleInputText` 一致。
- `RemoteSessionState.initial/hasVideo/hasInput/isViewerConnected/phase`、`RemoteSessionReducer.reduce`、`RemoteSessionEffect` 四個 case 在 Task 9 定義，Task 11、13 使用。
- `RemoteVideoQueue.Entry(sequence:isKeyframe:accessUnit:)`、`offering`／`popping` 的標籤、`dropped`、`defaultLimit` 在 Task 10 定義，Task 13 使用。
- `RemoteVideoMessage(sentAtNanoseconds:sequence:isKeyframe:accessUnit:)`、`encoded()`、`decode` 在 Task 10 定義，Task 13 使用。
- `RemoteRoute` 七個 case 在 Task 11 定義，Task 13 的 `admitUpgrade`／`recordHTTP`／`response(for:)` 全部窮舉。
- `RemoteServerConfiguration`、`RemoteServerStats` 七個欄位、`RemoteServerError` 三個 case、`RemoteUpgradeKind` 在 Task 13 內部一致；測試用到的 `boundPort`、`sessionState`、`stats()`、`send(accessUnit:keyframe:sequence:)`、`start()`、`stop()` 都在 `RemoteServer` 上。
- 測試用的 `StateRecorder<T>.record/wait(until:)/items` 與 `CountGate.increment/wait(for:)` 與 `TestGates.swift:13-82` 一致。

