# 區域網路手機遙控（階段 C、D 與活體驗證）實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `MirageShell` 接上手機遙控的系統框架層：VideoToolbox 硬體編碼器、拉幀與送封包的 controller、`AppModel` 的開關與生命週期、選單列子選單（含 QR），並用活體腳本驗證「手機端 60 秒內收到 keyframe、幀序連續、觸控到達 guest」與「驗收線 7 不劣化」。

**Architecture:** 幀由 `BroadcastFrameSink` 扇出到編碼器專用的 `LatestFrameBox`；`RemoteMirrorController` 以固定節奏 `takeLatest()`，交給 `RemoteVideoEncoder`（`VTCompressionSession`，RGBA → BGRA `CVPixelBuffer` → AVCC → NAL 清單 → `H264AccessUnitPacker` 打包並改寫 SPS），產出的存取單元交 `RemoteServer.send`；手機觸控由 `RemoteServer` 解碼後經 `onTouches` 回呼進 `InputQueue.touches(_:)`。遙控關閉時 `AppModel` 用原本的 `FrameSinkFactory.make` 產物，開啟時才把它包進 `BroadcastFrameSink` 並重新 `client.start`。UI 層只有純決策（`RemoteMenu.entries`）與最薄的 AppKit 佈局（`MenuBarController.populate`），都可 headless 測試。

**Tech Stack:** Swift 6.2.3 toolchain、語言模式 v5、`-strict-concurrency=complete`（`app/Package.swift:4-7`）；Swift Testing；VideoToolbox／CoreMedia／CoreVideo／Accelerate（vImage）／CoreImage（`CIQRCodeGenerator`、`CIDetector`）；swift-nio 2.101.3 的 `RemoteServer`（已在 `feat/remote-core`）；活體腳本用 bash 與系統 `python3` 的 venv（`websockets`）。

**Spec:** `/Users/hanfourhuang/Projects/mirage/docs/specs/2026-09-12-lan-remote-control-design.md`（已核可）。本計畫涵蓋第 9 節的階段 C、D 與第 8 節的活體驗證（`verify_remote_mirror.sh`、驗收線 7 對照）。階段 E（人工 glass-to-glass）不在此。

## 前提：階段 A、B 的實際程式碼

本計畫的介面以 worktree `/Users/hanfourhuang/Projects/mirage-remote`（分支 `feat/remote-core`）的**實際檔案**為準，不是以 A、B 的計畫為準。`RemoteServer` 三個檔案（`RemoteServer.swift`、`RemoteServerCore.swift`、`RemoteServer+Connections.swift`）在 2026-09-12 14:24 已存在於該 worktree 但**尚未 commit**（`git status` 顯示 `??`）；下面引用的簽章抄自那份檔案。**開始執行前先確認 `feat/remote-core` 已合併進 main、且下列簽章與合併後的檔案一致**（`grep -n "public func\|public init\|public var" app/Sources/MirageCore/Remote/RemoteServer.swift`）：

```swift
// app/Sources/MirageCore/Remote/RemoteServerCore.swift:4-23
public struct RemoteServerConfiguration: Sendable {
    public static let defaultPort = 8765
    public static let allInterfaces = "0.0.0.0"
    public init(host: String = allInterfaces, port: Int = defaultPort, token: PairingToken, viewerPage: Data,
                queueLimit: Int = RemoteVideoQueue.defaultLimit)
}
// app/Sources/MirageCore/Remote/RemoteServerCore.swift:25-33
public struct RemoteServerStats: Sendable, Equatable {
    public let framesOffered, framesSent, framesDropped, rejectedForbidden, rejectedBusy, invalidInputMessages, touchesForwarded: Int
}
// app/Sources/MirageCore/Remote/RemoteServer.swift:22-91
public final class RemoteServer: @unchecked Sendable {
    public init(configuration: RemoteServerConfiguration,
                onTouches: @escaping @Sendable ([TouchSpec]) -> Void,
                onKeyframeRequested: @escaping @Sendable () -> Void = {},
                onStateChanged: @escaping @Sendable (RemoteSessionState) -> Void = { _ in },
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now })
    public var sessionState: RemoteSessionState { get }
    public var boundPort: Int? { get }
    public func stats() -> RemoteServerStats
    public func send(accessUnit: Data, keyframe: Bool, sequence: UInt32)
    public func start() async throws -> Int      // 埠被佔用時拋 NIO 的錯（IOError）
    public func stop() async                      // 之後不可再 start；每次開啟建新的 server
}
```

其他會用到的 A、B 型別（同一 worktree）：

- `BroadcastFrameSink(primary: any FrameSink, secondary: LatestFrameBox = LatestFrameBox())`，`put` 扇出、`takeLatest`／`stats` 代理 `primary`（`app/Sources/MirageCore/BroadcastFrameSink.swift:10-31`）。
- `H264AccessUnitPacker(sps:pps:)`、`pack(_ nals: [Data], rewriteSps: (Data) -> Data?) -> (packer:, unit: H264AccessUnit?)`；`H264AccessUnit(nals:isKeyframe:)`，`annexB: Data`（`Remote/H264Nal.swift:59-107`）。
- `H264SpsRewriter.rewriteOrNil(_:) -> Data?`、`H264SpsRewriter.summary(of:) throws -> H264SpsSummary`（`hasVui`、`maxNumReorderFrames`、`profileIdc`；`Remote/H264SpsRewriter.swift:3-67`）。
- `PairingToken.generate()`、`PairingToken(value:)`（32 個小寫十六進位）、`.value`（`Remote/PairingToken.swift`）。
- `RemoteSessionState`：`phase`（`.waitingForPairing`／`.connected`／`.disconnected`）、`hasVideo`、`hasInput`、`isViewerConnected`、`.initial`（`Remote/RemoteSessionState.swift:4-29`）。
- `RemoteVideoMessage.decode(_:) -> RemoteVideoMessage?`（`sequence`、`isKeyframe`、`accessUnit`；`Remote/RemoteVideoMessage.swift`）。
- `RemoteViewerPage.bundled() -> Data?`（`Remote/RemoteViewerPage.swift:7-18`）。
- 手機頁面 `viewer.html` 連 `/ws/video?t=` 與 `/ws/input?t=`，觸控 JSON `{"t","id","type","x","y"}`、`{"type":"ping","t"}`（`Resources/remote/viewer.html:96-102,118,196`）。

## Global Constraints

- 新程式碼放 `app/Sources/MirageShell/Remote/`（編碼器、controller、QR、主機位址、啟動選項）與 `app/Sources/MirageShell/Lifecycle/`（選單）；修改 `AppModel.swift`、`AppModel+Instances.swift`、`Lifecycle/AppLifecycle.swift`、`Lifecycle/LifecyclePolicy.swift`、`Lifecycle/MenuBarController.swift`、`Tests/MirageCoreTests/LiveGate.swift`、`scripts/verify_fps_fullscreen.sh`、`scripts/ci.sh`、`README.md`。`MirageCore` 只加 `LiveGate.remote` 與一條活體測試，**不加任何 import**（`MirageCore` 禁止 AppKit／SwiftUI／Metal／AVFoundation／VideoToolbox，`app/README.md:329`）。
- `MirageShell` 新程式碼一律 `internal`，不加 `public`（`app/README.md:375-380`）；測試用 `@testable import MirageShell`。
- Swift Testing。Bool 不得寫 `#expect(x == true)`／`#expect(x == false)`（`ci.sh` 閘門 5），一律 `#expect(x)`／`#expect(!x)`；`Optional<Bool>` 用 `#expect(try #require(a).b)`。`#expect(...)` 的括號裡不放 `try`——先 `let v = try …` 再斷言。`#expect(list.allSatisfy(\.flag))` 編不過，寫閉包 `#expect(list.allSatisfy { $0.flag })`。
- 測試裡不得用 `guard … else { return }` 當 skip（閘門 3）；環境條件一律 `@Test(.enabled(if:))`。活體測試用 `LiveGate.remote`（`MIRAGE_LIVE=1` 且 `MIRAGE_LIVE_REMOTE=1`）；`MirageShellTests` 沒有共用檔機制，比照 `KeymapReleaseLiveTests.swift:7-11` 在測試檔內用 `private enum` 讀同兩個變數。
- 每個檔案 200 到 400 行，上限 800。
- 編碼器**只用硬體**：`kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder = true`；`VTCompressionSessionCreate` 失敗就拋錯，`AppModel` 收到錯誤後關閉功能並在選單顯示錯誤碼，不退回軟體編碼（spec 第 7 節）。
- 低延遲設定（spec 第 3 節）：`RealTime=true`、`AllowFrameReordering=false`、`MaxFrameDelayCount=0`、`PrioritizeEncodingSpeedOverQuality=true`、`ProfileLevel=kVTProfileLevel_H264_Baseline_AutoLevel`、`MaxKeyFrameInterval=120`、`AverageBitRate=12_000_000`、`ExpectedFrameRate=30`。
- 遙控關閉時 `AppModel.activeSink` **就是** `box`（`FrameSinkFactory.make` 的產物，同一個物件），`client.start(box: activeSink, …)`；只有開啟時 `activeSink` 才是 `BroadcastFrameSink(primary: box, secondary:)`。
- 遠端觸控只經 `InputQueue.touches(_:)`（`app/Sources/MirageCore/Input/InputQueue.swift:200-202`），不直接呼叫 `EmulatorClient.sendTouches`。
- `AppLifecycle.windowShouldClose` 的 guard 預設閉包 `{ false }`，功能關閉時行為零改變（spec 第 3 節）。
- QR 用 CoreImage `CIQRCodeGenerator` 產 `NSImage`，放在子選單的 `NSMenuItem.view`（理由見「設計決定」）。不引入新依賴。
- 活體腳本：`verify_remote_mirror.sh` 用 Python WebSocket 用戶端；venv 在 `app/scripts/.venv-remote`，用系統 `/usr/bin/python3 -m venv` 建（spike 實測防火牆只放行系統 Python）；根目錄 `.gitignore:6` 的 `.venv*/` 已涵蓋它（`git check-ignore -v app/scripts/.venv-remote/x` → `.gitignore:6:.venv*/`），不重複加行。
- 每個 task 最後一步 commit，訊息用繁體中文 conventional commits（`feat:`／`test:`／`chore:`），不加任何 attribution 行。
- 執行指令一律在 `app/` 目錄：`cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter <SuiteName>`。

---

## 設計決定（執行前先讀）

### 1. 「開啟遙控」是重新 `client.start`，不是一開始就包 `BroadcastFrameSink`

`client.start(box:width:height:)` 在 `AppModel.start()` 啟動時就傳入 box（`AppModel.swift:161`），`EmulatorClient` 沒有換 sink 的 API（`EmulatorClient.swift:147-156`），而 spec 第 2 節要求 `EmulatorClient` 一行不改、關閉時行為零改變。兩個選項：

| 選項 | 關閉時的行為 | 開啟時的成本 |
|---|---|---|
| (a) 一開始就包 `BroadcastFrameSink`，secondary 平常沒人拉 | **不是零改變**：每幀多一次 `secondary.put`（一把鎖＋一次 `Data` retain），而且 `BroadcastFrameSink.secondary` 是固定的 `LatestFrameBox`（`BroadcastFrameSink.swift:12`），沒有「空陣列」可言 | 零 |
| (b) 開啟時 stop → 換 sink → start | 零改變（同一個 `box` 物件，路徑上沒有任何新程式碼） | 一次重連（驗收線 1 實測 1 秒內恢復出幀，`app/README.md:21`），`ConnectionBanner` 會閃一下 |

選 (b)。切換模擬器已經用同一條 stop／start 路徑（`AppModel+Instances.swift:48-62`），沒有第二種生命週期。對 fps 的影響：關閉時零；開啟時每幀多一次 `put`，加上編碼器 30 fps 的拉取（BGRA 置換一次拷貝約 7 MB／幀＋硬體編碼），由驗收線 7 對照量化（本計畫最後一個 task）。

### 2. `activeSink` 由 `AppModel` 持有，`start()` 與 `performInstanceSwitch` 都用它

`AppModel.box` 維持 `let`（Renderer 直接拿它，`MirrorView.swift:180`），另加 `activeSink`。遙控開啟時切換模擬器若仍傳 `box`，扇出就靜默消失——所以 `performInstanceSwitch` 改傳 `activeSink`。關閉時 `activeSink === box`，那一行等價於原本的程式碼。

### 3. 「中斷連線」＝停掉 server、換 token、保留同一個 secondary box

spec 第 5 節：關閉功能或中斷連線時 token 作廢。`RemoteServer` 一個實例只能 `start` 一次（`RemoteServer.swift:19-20`），所以中斷連線＝建新的 `RemoteMirrorController`，但把**同一個** `LatestFrameBox` 傳進去，`activeSink` 不變、`client` 不重啟。只有開啟／關閉才重啟 client。

### 4. QR 放 `NSMenuItem.view`，不開視窗

`MirageScene` 用單一實例的 `Window`，`AppLifecycle` 掛在 `NSApp.windows.first` 上（`AppModel.swift:199-205`），註解明寫「讓 `NSApp.windows.first` 不再有歧義」（`MirageScene.swift:38`）。多開一個 QR 視窗就把這個不變式打破，而且要處理它的關閉、焦點、與 `MouseCapture` 的 key window 判斷。子選單的 `NSMenuItem.view` 沒有這些：使用者打開選單、手機掃描、放開就消失。代價是選單開著時才看得到，這正是配對的使用情境。

### 5. 編碼器接受的像素格式

`Frame.rgba` 是 RGBA8。硬體 H.264 編碼器原生吃 `kCVPixelFormatType_32BGRA`；本機（2026-09-12，Swift 6.2.3，CommandLineTools SDK）已用最小探針實測：`RequireHardwareAcceleratedVideoEncoder=true` 建立成功、`32BGRA` 餵三幀三次回呼、第一幀帶 SPS `2742001fab40501ec8`（baseline）＋PPS，之後兩幀 `NotSync`。通道置換用 `vImagePermuteChannels_ARGB8888`（SIMD），不用逐位元組迴圈。

### 6. 環境變數（只供腳本，不是使用者介面）

| 變數 | 用途 |
|---|---|
| `MIRAGE_REMOTE=1` | 啟動時自動開啟遙控（活體腳本用；使用者用選單） |
| `MIRAGE_REMOTE_PORT` | 埠，預設 8765 |
| `MIRAGE_REMOTE_TOKEN` | 固定 token（32 個小寫十六進位），讓腳本的用戶端知道網址；不合法就忽略並產生亂數 |

開啟時印一行 `[remote] listening port=<埠> url=<第一個網址>`，腳本靠它取得網址。

---

## 檔案結構

| 檔案 | 職責 |
|---|---|
| `app/Sources/MirageShell/Remote/H264AvccSplitter.swift` | AVCC 長度前綴 → NAL 清單（純函式） |
| `app/Sources/MirageShell/Remote/RemoteEncoderClock.swift` | `Frame.receivedAt` → `CMTime`（純函式） |
| `app/Sources/MirageShell/Remote/RGBAPixelBuffer.swift` | `Frame` → BGRA `CVPixelBuffer`（vImage） |
| `app/Sources/MirageShell/Remote/RemoteVideoEncoder.swift` | `RemoteFrameEncoding` 協定、`VTCompressionSession` 封裝、尺寸變更重建、SPS 改寫 |
| `app/Sources/MirageShell/Remote/RemoteMirrorController.swift` | server＋encoder＋拉取迴圈＋序號＋觸控轉 `InputQueue` |
| `app/Sources/MirageShell/Remote/HostAddresses.swift` | `getifaddrs` 列 IPv4、排序（en* → utun* → 其他） |
| `app/Sources/MirageShell/Remote/RemoteURL.swift` | 網址字串（純函式） |
| `app/Sources/MirageShell/Remote/QRCodeImage.swift` | CoreImage QR → `NSImage` |
| `app/Sources/MirageShell/Remote/RemoteLaunchOptions.swift` | 環境變數解析（純函式） |
| `app/Sources/MirageShell/Lifecycle/RemoteMenu.swift` | 子選單內容的純決策 |
| `app/Sources/MirageShell/Lifecycle/MenuBarController.swift`（修改） | 「手機遙控」子選單與 `populate(remoteMenu:)` |
| `app/Sources/MirageShell/Lifecycle/LifecyclePolicy.swift`（修改） | `didHide(remoteViewerActive:)` |
| `app/Sources/MirageShell/Lifecycle/AppLifecycle.swift`（修改） | `hasActiveRemoteViewer` guard |
| `app/Sources/MirageShell/AppModel+Remote.swift` | 開關、中斷、狀態鏡像、選單綁定 |
| `app/Sources/MirageShell/AppModel.swift`（修改） | `activeSink`、`remote`、`remoteMenuState` 儲存屬性；`start()` 用 `activeSink`；lifecycle guard 接線 |
| `app/Sources/MirageShell/AppModel+Instances.swift`（修改） | `performInstanceSwitch` 用 `activeSink` |
| `app/Tests/MirageCoreTests/LiveGate.swift`（修改） | `LiveGate.remote` |
| `app/Tests/MirageCoreTests/Remote/RemoteInputLiveTests.swift` | server → `InputQueue` → 真模擬器的觸控路徑 |
| `app/Tests/MirageShellTests/Remote*Tests.swift` | 各 task 的測試 |
| `app/scripts/lib/remote_client.py` | Python WebSocket 用戶端（可 `--loop`） |
| `app/scripts/lib/remote_client_selftest.py` | 純函式自我測試（stdlib unittest） |
| `app/scripts/lib/remote_venv.sh` | 建 `.venv-remote` 並裝 `websockets` |
| `app/scripts/verify_remote_mirror.sh` | 活體：keyframe、幀序、觸控到 guest |
| `app/scripts/verify_fps_fullscreen.sh`（修改） | `-E KEY=VAL` 額外環境變數 |
| `app/scripts/verify_remote_fps.sh` | 驗收線 7 對照：遙控關／開各兩次 |
| `app/scripts/ci.sh`（修改） | 閘門 8 加 `remote_client_selftest.py` |
| `app/README.md`（修改） | 「手機遙控」段落 |

---

### Task 1: 編碼器的三個純函式層：AVCC 切分、PTS、BGRA 像素緩衝

**Files:**
- Create: `app/Sources/MirageShell/Remote/H264AvccSplitter.swift`
- Create: `app/Sources/MirageShell/Remote/RemoteEncoderClock.swift`
- Create: `app/Sources/MirageShell/Remote/RGBAPixelBuffer.swift`
- Test: `app/Tests/MirageShellTests/RemoteEncoderHelpersTests.swift`

**Interfaces:**
- Consumes: `Frame`（`app/Sources/MirageCore/Frame.swift:3-40`，`width`／`height`／`rgba`／`receivedAt`／`isValid`）。
- Produces:

```swift
enum H264AvccSplitter {
    static func split(_ avcc: Data, headerLength: Int) -> [Data]   // headerLength 1…4；截斷的尾巴丟掉
}
enum RemoteEncoderClock {
    static let timescale: CMTimeScale   // 1_000_000_000
    static func presentationTime(of instant: ContinuousClock.Instant, since epoch: ContinuousClock.Instant) -> CMTime
}
enum RGBAPixelBufferError: Error, Equatable { case invalidFrame, create(CVReturn), noBaseAddress, permute(vImage_Error) }
enum RGBAPixelBuffer {
    static func makeBGRA(from frame: Frame) throws -> CVPixelBuffer   // kCVPixelFormatType_32BGRA
}
```

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageShellTests/RemoteEncoderHelpersTests.swift`：

```swift
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

/// 三個純函式層不需要 VideoToolbox session，headless 可跑。
@Suite struct RemoteEncoderHelpersTests {
    // MARK: AVCC

    @Test func splitsFourByteLengthPrefixedNals() {
        let avcc = Data([0, 0, 0, 3, 0x65, 0x88, 0x84, 0, 0, 0, 2, 0x41, 0x9a])
        #expect(H264AvccSplitter.split(avcc, headerLength: 4) == [Data([0x65, 0x88, 0x84]), Data([0x41, 0x9a])])
    }

    @Test func splitsTwoByteLengthPrefix() {
        let avcc = Data([0, 1, 0x67, 0, 2, 0x68, 0xce])
        #expect(H264AvccSplitter.split(avcc, headerLength: 2) == [Data([0x67]), Data([0x68, 0xce])])
    }

    /// 長度前綴指到緩衝區外：那個 NAL 與之後的全部丟掉，前面完整的保留。
    @Test func truncatedTailIsDropped() {
        let avcc = Data([0, 0, 0, 1, 0x65, 0, 0, 0, 9, 0x41])
        #expect(H264AvccSplitter.split(avcc, headerLength: 4) == [Data([0x65])])
        #expect(H264AvccSplitter.split(Data(), headerLength: 4).isEmpty)
        #expect(H264AvccSplitter.split(Data([0, 0, 0, 0, 0x65]), headerLength: 4).isEmpty)   // 長度 0 不是 NAL
    }

    // MARK: PTS

    @Test func presentationTimeIsNanosecondsSinceEpoch() {
        let epoch = ContinuousClock.now
        let later = epoch + .milliseconds(1_500) + .nanoseconds(7)
        let pts = RemoteEncoderClock.presentationTime(of: later, since: epoch)
        #expect(pts.timescale == 1_000_000_000)
        #expect(pts.value == 1_500_000_007)
        #expect(RemoteEncoderClock.presentationTime(of: epoch, since: epoch).value == 0)
    }

    // MARK: 像素緩衝

    @Test func rgbaBecomesBGRAWithSameGeometry() throws {
        let frame = Frame(width: 2, height: 1, rgba: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        let buffer = try RGBAPixelBuffer.makeBGRA(from: frame)
        #expect(CVPixelBufferGetWidth(buffer) == 2)
        #expect(CVPixelBufferGetHeight(buffer) == 1)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddress(buffer))
        let bytes = [UInt8](Data(bytes: base, count: 8))
        #expect(bytes == [3, 2, 1, 4, 7, 6, 5, 8])
    }

    /// 尺寸與位元組數不符的幀不得進編碼器：`LatestFrameBox.put` 已擋掉（`rejected`），
    /// 這裡是第二道，因為 `takeLatest` 的來源未來可能換。
    @Test func invalidFrameIsRejected() {
        let frame = Frame(width: 2, height: 2, rgba: Data([0, 0, 0, 0]))
        #expect(throws: RGBAPixelBufferError.invalidFrame) { _ = try RGBAPixelBuffer.makeBGRA(from: frame) }
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteEncoderHelpersTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'H264AvccSplitter' in scope`。

- [ ] **Step 3: 實作三個檔案**

`app/Sources/MirageShell/Remote/H264AvccSplitter.swift`：

```swift
import Foundation

/// VideoToolbox 的 `CMBlockBuffer` 是 AVCC 格式：每個 NAL 前面是 big-endian 長度前綴
/// （長度由 format description 的 `nalUnitHeaderLength` 決定，實測 4）。手機端要的是
/// Annex-B，所以先切成不含前綴的 NAL 清單，交給 `H264AccessUnitPacker` 加起始碼。
enum H264AvccSplitter {
    /// 長度前綴指到緩衝區外時停止，回傳到此為止完整的 NAL。不拋錯：半截 NAL 對手機端
    /// 沒有用，丟掉比送出去更好。長度 0 不是 NAL，同樣視為結束。
    static func split(_ avcc: Data, headerLength: Int) -> [Data] {
        precondition((1...4).contains(headerLength), "AVCC 長度前綴只有 1 到 4 位元組")
        let bytes = [UInt8](avcc)
        var nals: [Data] = []
        var index = 0
        while index + headerLength <= bytes.count {
            let length = bytes[index..<index + headerLength].reduce(0) { ($0 << 8) | Int($1) }
            let start = index + headerLength
            guard length > 0, start + length <= bytes.count else { break }
            nals.append(Data(bytes[start..<start + length]))
            index = start + length
        }
        return nals
    }
}
```

`app/Sources/MirageShell/Remote/RemoteEncoderClock.swift`：

```swift
import CoreMedia
import Foundation

/// PTS 用 `Frame.receivedAt`（spec 第 3 節）：以 session 建立時那一幀為零點，奈秒精度。
/// `ContinuousClock.Instant` 是單調時鐘，跨幀遞增，正是編碼器要的 PTS 性質。
enum RemoteEncoderClock {
    static let timescale: CMTimeScale = 1_000_000_000

    static func presentationTime(of instant: ContinuousClock.Instant,
                                 since epoch: ContinuousClock.Instant) -> CMTime {
        let elapsed = instant - epoch
        let nanoseconds = elapsed.components.seconds * 1_000_000_000
            + elapsed.components.attoseconds / 1_000_000_000
        return CMTime(value: CMTimeValue(nanoseconds), timescale: timescale)
    }
}
```

`app/Sources/MirageShell/Remote/RGBAPixelBuffer.swift`：

```swift
import Accelerate
import CoreVideo
import Foundation
import MirageCore

enum RGBAPixelBufferError: Error, Equatable {
    case invalidFrame
    case create(CVReturn)
    case noBaseAddress
    case permute(vImage_Error)
}

/// `Frame.rgba`（RGBA8）→ `kCVPixelFormatType_32BGRA` 的 `CVPixelBuffer`。
/// 硬體 H.264 編碼器原生吃 BGRA（2026-09-12 本機探針實測），通道置換用 vImage（SIMD），
/// 每幀一次拷貝。`CVPixelBuffer` 的每列可能有對齊填充，所以目的 `rowBytes` 要問它。
enum RGBAPixelBuffer {
    private static let rgbaToBGRA: [UInt8] = [2, 1, 0, 3]

    static func makeBGRA(from frame: Frame) throws -> CVPixelBuffer {
        guard frame.isValid else { throw RGBAPixelBufferError.invalidFrame }
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, frame.width, frame.height,
                                         kCVPixelFormatType_32BGRA, nil, &created)
        guard status == kCVReturnSuccess, let pixelBuffer = created else {
            throw RGBAPixelBufferError.create(status)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw RGBAPixelBufferError.noBaseAddress
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let error: vImage_Error = frame.rgba.withUnsafeBytes { raw in
            guard let source = raw.baseAddress else { return vImage_Error(kvImageNullPointerArgument) }
            var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source),
                                    height: vImagePixelCount(frame.height),
                                    width: vImagePixelCount(frame.width),
                                    rowBytes: frame.width * 4)
            var dst = vImage_Buffer(data: base, height: vImagePixelCount(frame.height),
                                    width: vImagePixelCount(frame.width), rowBytes: rowBytes)
            return vImagePermuteChannels_ARGB8888(&src, &dst, rgbaToBGRA, vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError else { throw RGBAPixelBufferError.permute(error) }
        return pixelBuffer
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteEncoderHelpersTests 2>&1 | tail -5`
Expected: `6 tests passed`。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageShell/Remote/H264AvccSplitter.swift app/Sources/MirageShell/Remote/RemoteEncoderClock.swift app/Sources/MirageShell/Remote/RGBAPixelBuffer.swift app/Tests/MirageShellTests/RemoteEncoderHelpersTests.swift && git commit -m "feat: 手機遙控編碼器的 AVCC 切分、PTS 換算與 BGRA 像素緩衝"
```

---

### Task 2: `RemoteVideoEncoder`：`VTCompressionSession` 封裝與活體測試

**Files:**
- Create: `app/Sources/MirageShell/Remote/RemoteVideoEncoder.swift`
- Test: `app/Tests/MirageShellTests/RemoteVideoEncoderLiveTests.swift`

**Interfaces:**
- Consumes: `H264AvccSplitter.split(_:headerLength:)`、`RemoteEncoderClock.presentationTime(of:since:)`、`RGBAPixelBuffer.makeBGRA(from:)`（同目錄）；`H264AccessUnitPacker.pack(_:rewriteSps:)`、`H264AccessUnit`（`MirageCore/Remote/H264Nal.swift:59-107`）；`H264SpsRewriter.rewriteOrNil`（`MirageCore/Remote/H264SpsRewriter.swift:55`）。VideoToolbox 簽章已於 2026-09-12 在本機以 `swiftc -typecheck -swift-version 5 -strict-concurrency=complete` 驗過：`VTCompressionSessionCreate(allocator:width:height:codecType:encoderSpecification:imageBufferAttributes:compressedDataAllocator:outputCallback:refcon:compressionSessionOut:)`、`VTSessionSetProperty(_:key:value:)`、`VTCompressionSessionPrepareToEncodeFrames(_:)`、`VTCompressionSessionEncodeFrame(_:imageBuffer:presentationTimeStamp:duration:frameProperties:infoFlagsOut:outputHandler:)`（C 的 `…WithOutputHandler`，Swift 匯入後同名多載，尾隨閉包 `(OSStatus, VTEncodeInfoFlags, CMSampleBuffer?) -> Void`）、`VTCompressionSessionInvalidate(_:)`、`CMVideoFormatDescriptionGetH264ParameterSetAtIndex(_:parameterSetIndex:parameterSetPointerOut:parameterSetSizeOut:parameterSetCountOut:nalUnitHeaderLengthOut:)`、`CMSampleBufferGetSampleAttachmentsArray(_:createIfNecessary:)`、`CMBlockBufferCopyDataBytes(_:atOffset:dataLength:destination:)`。
- Produces（`RemoteMirrorController` 用協定，`AppModel+Remote` 建具體型別）：

```swift
protocol RemoteFrameEncoding: AnyObject, Sendable {
    func encode(_ frame: Frame) throws     // 尺寸變更時自行銷毀重建 session
    func requestKeyframe()                 // 下一幀強制 IDR
    func invalidate()                      // 收掉 session；之後 encode 會重建
}
struct RemoteVideoEncoderSettings: Sendable, Equatable {
    var expectedFrameRate = 30; var averageBitRate = 12_000_000; var maxKeyFrameInterval = 120
}
enum RemoteVideoEncoderError: Error, Equatable {
    case sessionCreation(OSStatus), prepare(OSStatus), encode(OSStatus), pixelBuffer(RGBAPixelBufferError)
}
struct RemoteVideoEncoderStats: Sendable, Equatable {
    let framesSubmitted, accessUnitsEmitted, sessionsCreated, framesDroppedByEncoder, spsRewriteFailures: Int
}
final class RemoteVideoEncoder: RemoteFrameEncoding, @unchecked Sendable {
    init(settings: RemoteVideoEncoderSettings = .init(), onAccessUnit: @escaping @Sendable (H264AccessUnit) -> Void)
    func stats() -> RemoteVideoEncoderStats
}
```

設計要點：
- 所有可變狀態一把 `NSLock`（比照 `LatestFrameBox`）。`encode` 在鎖外建像素緩衝、在鎖內決定要不要重建 session 與讀 epoch，再鎖外呼叫 VT。輸出回呼在 VT 的執行緒上跑，只在鎖內更新 packer 與計數，`onAccessUnit` 在鎖外呼叫。
- epoch 是重建 session 那一幀的 `receivedAt`，之後每幀的 PTS 是與它的差。
- keyframe 判定：`kCMSampleAttachmentKey_NotSync` 不存在或為 false 就是 sync sample（CoreMedia 慣例）。keyframe 時把 format description 的參數集（SPS、PPS）放在 slice 前面交給 packer，packer 會用 `rewriteSps` 改寫並快取。
- 每幀只送一個存取單元：VT 一次回呼一個 sample，packer 對一個 sample 回一個 unit（非 VCL 的 sample 回 nil）。

- [ ] **Step 1: 寫活體測試（需硬體編碼器，`LiveGate.remote`）**

`app/Tests/MirageShellTests/RemoteVideoEncoderLiveTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

/// 與 `MirageCoreTests/LiveGate.swift` 的 `LiveGate.remote` 讀同兩個變數；兩個 test target
/// 之間沒有共用檔的機制（比照 `KeymapReleaseLiveTests.swift:7-11`）。真正防止打錯變數名的是
/// `verify_remote_mirror.sh` 會斷言這條測試「passed」而不是「skipped」。
private enum RemoteLiveGate {
    static let remote = ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1"
        && ProcessInfo.processInfo.environment["MIRAGE_LIVE_REMOTE"] == "1"
}

/// 收集回呼的存取單元。`CountGate` 只計數，這裡還要保留內容。
private final class AccessUnitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [H264AccessUnit] = []
    let gate = CountGate()

    func record(_ unit: H264AccessUnit) {
        lock.lock(); stored.append(unit); lock.unlock()
        gate.increment()
    }

    var units: [H264AccessUnit] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// 餵合成幀，斷言輸出 SPS 已含 VUI、每幀一個存取單元、尺寸變更會重建（spec 第 9 節階段 C）。
/// 需要硬體編碼器：spike 記載沙箱裡 VT 回 -12903，所以只在 `MIRAGE_LIVE_REMOTE=1` 下跑。
@Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteVideoEncoderLiveTests {
    private static func frame(width: Int, height: Int, seed: UInt8) -> Frame {
        var rgba = Data(count: width * height * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = UInt8(truncatingIfNeeded: i / 4 &+ Int(seed))   // 有梯度，不是純色
            rgba[i + 1] = seed
            rgba[i + 2] = UInt8(truncatingIfNeeded: i / 640)
            rgba[i + 3] = 255
        }
        return Frame(width: width, height: height, rgba: rgba)
    }

    @Test(.enabled(if: RemoteLiveGate.remote, "需 MIRAGE_LIVE=1 MIRAGE_LIVE_REMOTE=1，請跑 scripts/verify_remote_mirror.sh"))
    func emitsOneRewrittenAccessUnitPerFrameAndRecreatesOnResize() async throws {
        let recorder = AccessUnitRecorder()
        let encoder = RemoteVideoEncoder { recorder.record($0) }
        defer { encoder.invalidate() }

        for seed in 0..<5 {
            try encoder.encode(Self.frame(width: 320, height: 240, seed: UInt8(seed)))
            try await Task.sleep(for: .milliseconds(33))
        }
        await recorder.gate.wait(for: 5)
        for seed in 0..<3 {
            try encoder.encode(Self.frame(width: 480, height: 320, seed: UInt8(10 + seed)))
            try await Task.sleep(for: .milliseconds(33))
        }
        await recorder.gate.wait(for: 8)
        encoder.requestKeyframe()
        try encoder.encode(Self.frame(width: 480, height: 320, seed: 99))
        await recorder.gate.wait(for: 9)

        let units = recorder.units
        #expect(units.count == 9)                                   // 每幀一個存取單元
        #expect(units[0].isKeyframe)
        #expect(units[1...4].allSatisfy { !$0.isKeyframe })
        #expect(units[5].isKeyframe)                                // 新 session 第一幀
        #expect(units[8].isKeyframe)                                // requestKeyframe
        let sps = try H264SpsRewriter.summary(of: units[0].nals[0])
        #expect(sps.profileIdc == 66)                               // baseline
        #expect(sps.hasVui)
        #expect(sps.maxNumReorderFrames == 0)
        #expect(H264Nal.type(of: units[0].nals[1]) == .pps)
        #expect(units[0].nals.contains { H264Nal.type(of: $0) == .idrSlice })
        let stats = encoder.stats()
        #expect(stats.sessionsCreated == 2)
        #expect(stats.framesSubmitted == 9)
        #expect(stats.accessUnitsEmitted == 9)
        #expect(stats.spsRewriteFailures == 0)
    }

    /// 尺寸不合法的幀不得進 VT，也不得建立 session。
    @Test(.enabled(if: RemoteLiveGate.remote, "需 MIRAGE_LIVE=1 MIRAGE_LIVE_REMOTE=1"))
    func invalidFrameThrowsBeforeCreatingSession() {
        let encoder = RemoteVideoEncoder { _ in }
        #expect(throws: RemoteVideoEncoderError.pixelBuffer(.invalidFrame)) {
            try encoder.encode(Frame(width: 4, height: 4, rgba: Data([0])))
        }
        #expect(encoder.stats().sessionsCreated == 0)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && MIRAGE_LIVE=1 MIRAGE_LIVE_REMOTE=1 swift test --filter RemoteVideoEncoderLiveTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'RemoteVideoEncoder' in scope`。

- [ ] **Step 3: 實作編碼器**

`app/Sources/MirageShell/Remote/RemoteVideoEncoder.swift`：

```swift
import CoreMedia
import CoreVideo
import Foundation
import MirageCore
import VideoToolbox

/// 編碼器抽象：`RemoteMirrorController` 只透過它餵幀、要求 keyframe、收掉 session，
/// 測試用假件取代真的 VideoToolbox（硬體編碼器在沙箱裡不一定有）。
protocol RemoteFrameEncoding: AnyObject, Sendable {
    func encode(_ frame: Frame) throws
    func requestKeyframe()
    func invalidate()
}

struct RemoteVideoEncoderSettings: Sendable, Equatable {
    var expectedFrameRate = 30
    var averageBitRate = 12_000_000
    var maxKeyFrameInterval = 120

    init() {}
}

enum RemoteVideoEncoderError: Error, Equatable {
    case sessionCreation(OSStatus)
    case prepare(OSStatus)
    case encode(OSStatus)
    case pixelBuffer(RGBAPixelBufferError)
}

struct RemoteVideoEncoderStats: Sendable, Equatable {
    let framesSubmitted: Int
    let accessUnitsEmitted: Int
    let sessionsCreated: Int
    let framesDroppedByEncoder: Int
    let spsRewriteFailures: Int
}

/// `VTCompressionSession` 封裝（spec 第 3 節）：`Frame`（RGBA）→ BGRA `CVPixelBuffer` → AVCC →
/// NAL 清單 → `H264AccessUnitPacker`（改寫 SPS、keyframe 前置 SPS/PPS）→ `onAccessUnit`。
/// 尺寸變更時銷毀重建，新 session 的第一幀自然是 IDR、帶新的參數集。
///
/// 只用硬體編碼器：主機 CPU 是這台機器的瓶頸（`app/RESULTS-multi-instance.md`），
/// 建立失敗直接拋錯讓上層關閉功能，不退回軟體編碼（spec 第 7 節）。
final class RemoteVideoEncoder: RemoteFrameEncoding, @unchecked Sendable {
    private let settings: RemoteVideoEncoderSettings
    private let onAccessUnit: @Sendable (H264AccessUnit) -> Void
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var sessionSize = (0, 0)   // 不加標籤：要與 `(frame.width, frame.height)` 直接比較
    private var epoch = ContinuousClock.now
    private var packer = H264AccessUnitPacker()
    private var keyframeRequested = false
    private var framesSubmitted = 0
    private var accessUnitsEmitted = 0
    private var sessionsCreated = 0
    private var framesDroppedByEncoder = 0
    private var spsRewriteFailures = 0

    init(settings: RemoteVideoEncoderSettings = .init(),
         onAccessUnit: @escaping @Sendable (H264AccessUnit) -> Void)
    {
        self.settings = settings
        self.onAccessUnit = onAccessUnit
    }

    func stats() -> RemoteVideoEncoderStats {
        lock.lock(); defer { lock.unlock() }
        return RemoteVideoEncoderStats(framesSubmitted: framesSubmitted, accessUnitsEmitted: accessUnitsEmitted,
                                       sessionsCreated: sessionsCreated, framesDroppedByEncoder: framesDroppedByEncoder,
                                       spsRewriteFailures: spsRewriteFailures)
    }

    func requestKeyframe() {
        lock.lock(); keyframeRequested = true; lock.unlock()
    }

    func invalidate() {
        lock.lock()
        let old = session
        session = nil
        sessionSize = (0, 0)
        lock.unlock()
        if let old { VTCompressionSessionInvalidate(old) }
    }

    func encode(_ frame: Frame) throws {
        let pixelBuffer: CVPixelBuffer
        do {
            pixelBuffer = try RGBAPixelBuffer.makeBGRA(from: frame)
        } catch let error as RGBAPixelBufferError {
            throw RemoteVideoEncoderError.pixelBuffer(error)
        }
        lock.lock()
        let current: VTCompressionSession
        do {
            if let existing = session, sessionSize == (frame.width, frame.height) {
                current = existing
            } else {
                current = try replaceSessionLocked(width: frame.width, height: frame.height, epoch: frame.receivedAt)
            }
        } catch {
            lock.unlock()
            throw error
        }
        let pts = RemoteEncoderClock.presentationTime(of: frame.receivedAt, since: epoch)
        let force = keyframeRequested
        keyframeRequested = false
        framesSubmitted += 1
        lock.unlock()

        let properties: CFDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            current, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil) { [self] status, flags, sample in
                handleOutput(status: status, flags: flags, sample: sample)
            }
        guard status == noErr else { throw RemoteVideoEncoderError.encode(status) }
    }

    // MARK: - Session

    /// 只在鎖內呼叫。舊 session 先 invalidate 再建新的；packer 重置，讓新 session 的
    /// SPS/PPS 從第一個 keyframe 重新快取，不會把舊尺寸的參數集送給手機。
    private func replaceSessionLocked(width: Int, height: Int, epoch: ContinuousClock.Instant) throws
        -> VTCompressionSession
    {
        if let old = session { VTCompressionSessionInvalidate(old) }
        session = nil
        var created: VTCompressionSession?
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue as Any,
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let new = created else { throw RemoteVideoEncoderError.sessionCreation(status) }
        // spec 第 3 節的低延遲設定。
        VTSessionSetProperty(new, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(new, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(new, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
        VTSessionSetProperty(new, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTSessionSetProperty(new, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(new, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: settings.maxKeyFrameInterval as CFNumber)
        VTSessionSetProperty(new, key: kVTCompressionPropertyKey_AverageBitRate, value: settings.averageBitRate as CFNumber)
        VTSessionSetProperty(new, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: settings.expectedFrameRate as CFNumber)
        let prepared = VTCompressionSessionPrepareToEncodeFrames(new)
        guard prepared == noErr else {
            VTCompressionSessionInvalidate(new)
            throw RemoteVideoEncoderError.prepare(prepared)
        }
        session = new
        sessionSize = (width, height)
        self.epoch = epoch
        packer = H264AccessUnitPacker()
        keyframeRequested = false
        sessionsCreated += 1
        return new
    }

    // MARK: - 輸出

    /// VT 的執行緒上跑。`CMSampleBuffer` 不跨執行緒：在這裡就轉成 `[Data]`。
    private func handleOutput(status: OSStatus, flags: VTEncodeInfoFlags, sample: CMSampleBuffer?) {
        guard status == noErr, let sample, !flags.contains(.frameDropped) else {
            lock.lock(); framesDroppedByEncoder += 1; lock.unlock()
            return
        }
        let nals = Self.nalUnits(of: sample)
        lock.lock()
        var failures = 0
        let (next, unit) = packer.pack(nals) { sps in
            let rewritten = H264SpsRewriter.rewriteOrNil(sps)
            if rewritten == nil { failures += 1 }
            return rewritten
        }
        packer = next
        spsRewriteFailures += failures
        if unit != nil { accessUnitsEmitted += 1 }
        lock.unlock()
        if let unit { onAccessUnit(unit) }
    }

    /// keyframe 時先放 format description 裡的參數集（SPS、PPS，已含 emulation prevention），
    /// 再放 AVCC 切出來的 slice。長度前綴寬度由 format description 告知。
    static func nalUnits(of sample: CMSampleBuffer) -> [Data] {
        var nals: [Data] = []
        var headerLength: Int32 = 4
        if let description = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            if isKeyframe(sample) {
                for index in 0..<count {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    if status == noErr, let pointer { nals.append(Data(bytes: pointer, count: size)) }
                }
            }
        }
        if let block = CMSampleBufferGetDataBuffer(sample), let avcc = copyBytes(of: block) {
            nals += H264AvccSplitter.split(avcc, headerLength: Int(headerLength))
        }
        return nals
    }

    /// 沒有附件＝sync sample（CoreMedia 慣例）；有附件看 `NotSync`。
    static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first,
              let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool
        else { return true }
        return !notSync
    }

    /// `CMBlockBuffer` 不保證連續，用 copy 而不是 `GetDataPointer`。
    private static func copyBytes(of block: CMBlockBuffer) -> Data? {
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }
}
```

- [ ] **Step 4: 跑活體測試確認通過，再確認不設環境變數時是 skipped**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && MIRAGE_LIVE=1 MIRAGE_LIVE_REMOTE=1 swift test --filter RemoteVideoEncoderLiveTests 2>&1 | grep -E "passed|failed|skipped" | tail -4`
Expected: 兩條 `passed`，無 `failed`。

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteVideoEncoderLiveTests 2>&1 | grep -c skipped`
Expected: `2`（或以上；重點是沒有 `failed`）。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageShell/Remote/RemoteVideoEncoder.swift app/Tests/MirageShellTests/RemoteVideoEncoderLiveTests.swift && git commit -m "feat: RemoteVideoEncoder 用 VideoToolbox 硬體編碼並改寫 SPS，尺寸變更重建 session"
```

---

### Task 3: `RemoteMirrorController`：拉取迴圈、序號、封包送 server、觸控轉 `InputQueue`

**Files:**
- Create: `app/Sources/MirageShell/Remote/RemoteMirrorController.swift`
- Test: `app/Tests/MirageShellTests/RemoteMirrorControllerTests.swift`

**Interfaces:**
- Consumes: `RemoteFrameEncoding`（`Remote/RemoteVideoEncoder.swift`）；`RemoteServer`、`RemoteServerConfiguration`、`RemoteServerStats`、`RemoteSessionState`、`PairingToken`、`H264AccessUnit`、`LatestFrameBox`、`InputQueue.touches(_:)`、`TouchSpec`（皆 `MirageCore`）。
- Produces（`AppModel+Remote` 建構與啟停）：

```swift
struct RemoteMirrorConfiguration: Sendable {
    var host = RemoteServerConfiguration.allInterfaces
    var port = RemoteServerConfiguration.defaultPort
    var pullInterval: Duration = .milliseconds(33)      // 30 fps
    let token: PairingToken
    let viewerPage: Data
    init(token: PairingToken, viewerPage: Data)
}
struct RemoteMirrorStats: Sendable, Equatable {
    let server: RemoteServerStats; let framesPulled: Int; let framesEncoded: Int; let encodeFailures: Int
}
final class RemoteMirrorController: @unchecked Sendable {
    let secondary: LatestFrameBox
    let token: PairingToken
    init(configuration: RemoteMirrorConfiguration,
         secondary: LatestFrameBox,
         inputQueue: InputQueue,
         makeEncoder: (@escaping @Sendable (H264AccessUnit) -> Void) -> any RemoteFrameEncoding,
         onError: @escaping @Sendable (String) -> Void = { _ in },
         onStateChanged: @escaping @Sendable (RemoteSessionState) -> Void = { _ in })
    func start() async throws -> Int      // server.start()，成功後啟動拉取迴圈；回綁定的埠
    func stop() async                     // 停拉取、invalidate 編碼器、server.stop()
    var sessionState: RemoteSessionState { get }
    var boundPort: Int? { get }
    func stats() -> RemoteMirrorStats
}
```

設計要點：
- 建構順序解掉循環依賴（server 需要 `onKeyframeRequested` → 編碼器；編碼器需要 `onAccessUnit` → server）：先建 `RemoteKeyframeRelay`（鎖保護的弱目標），server 的回呼打它；再建 server；再用 server 建 `RemoteAccessUnitSequencer`（序號＋`server.send`）；最後 `makeEncoder { sequencer.deliver($0) }`，把編碼器塞進 relay。全部 `let`，沒有 IUO。
- 拉取迴圈 `Task.detached`：每 `pullInterval` 醒一次；**沒有 viewer 就不拉**（`server.sessionState.hasVideo == false`，spec 第 6 節「手機斷線：編碼器停止拉取」）；有就 `secondary.takeLatest()`，nil 代表沒有新幀（畫面靜止）。`encode` 拋錯 → `onError` 一次、迴圈結束，由 `AppModel` 關閉功能。
- 觸控：`onTouches: { inputQueue.touches($0) }`，一行，沒有別的路。

- [ ] **Step 1: 寫失敗的 loopback 測試（不需要 VT、不需要模擬器）**

`app/Tests/MirageShellTests/RemoteMirrorControllerTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

/// 假編碼器：每次 `encode` 同步吐一個存取單元；第一幀或被要求時是 keyframe。
private final class FakeEncoder: RemoteFrameEncoding, @unchecked Sendable {
    static let sps = Data([0x27, 0x42, 0x00, 0x32, 0xab, 0x40, 0x22, 0x00, 0x96, 0xf2, 0xe8])
    static let pps = Data([0x28, 0xce, 0x3c, 0x80])
    private let lock = NSLock()
    private let onAccessUnit: @Sendable (H264AccessUnit) -> Void
    private var forceKeyframe = true
    private(set) var encodeCalls = 0
    private(set) var keyframeRequests = 0
    private(set) var invalidated = false

    init(onAccessUnit: @escaping @Sendable (H264AccessUnit) -> Void) { self.onAccessUnit = onAccessUnit }

    func encode(_ frame: Frame) throws {
        lock.lock()
        encodeCalls += 1
        let key = forceKeyframe
        forceKeyframe = false
        lock.unlock()
        let slice = Data([key ? 0x65 : 0x41, UInt8(truncatingIfNeeded: frame.width)])
        onAccessUnit(H264AccessUnit(nals: key ? [Self.sps, Self.pps, slice] : [slice], isKeyframe: key))
    }

    func requestKeyframe() { lock.lock(); keyframeRequests += 1; forceKeyframe = true; lock.unlock() }
    func invalidate() { lock.lock(); invalidated = true; lock.unlock() }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return encodeCalls }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return keyframeRequests }
    var wasInvalidated: Bool { lock.lock(); defer { lock.unlock() }; return invalidated }
}

/// 記錄 `InputQueue` 送出的觸控；證明遠端觸控走的是 `inputQueue.touches`，不是別條路。
private final class RecordingInjector: InputInjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[TouchSpec]] = []
    let gate = CountGate()
    func sendTouches(_ touches: [TouchSpec]) async { lock.lock(); stored.append(touches); lock.unlock(); gate.increment() }
    func sendKey(_ code: KeyCode, down: Bool) async {}
    func sendTap(nx: Double, ny: Double, down: Bool) async {}
    var touches: [[TouchSpec]] { lock.lock(); defer { lock.unlock() }; return stored }
}

private enum TestFailure: Error { case unexpectedMessageKind }

@Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteMirrorControllerTests {
    private static let token = PairingToken(value: "00112233445566778899aabbccddeeff")!
    private static let page = Data("<!doctype html>viewer".utf8)

    private struct Harness {
        let controller: RemoteMirrorController
        let port: Int
        let encoder: FakeEncoder
        let injector: RecordingInjector
        let queue: InputQueue
        let states: StateRecorder<RemoteSessionState>
    }

    private func start() async throws -> Harness {
        var configuration = RemoteMirrorConfiguration(token: Self.token, viewerPage: Self.page)
        configuration.host = "127.0.0.1"
        configuration.port = 0
        configuration.pullInterval = .milliseconds(5)
        let injector = RecordingInjector()
        let queue = InputQueue(injector: injector)
        let states = StateRecorder<RemoteSessionState>()
        let box = FakeEncoderBox()
        let controller = RemoteMirrorController(
            configuration: configuration, secondary: LatestFrameBox(), inputQueue: queue,
            makeEncoder: { deliver in
                let encoder = FakeEncoder(onAccessUnit: deliver)
                box.encoder = encoder
                return encoder
            },
            onStateChanged: { state in Task { await states.record(state) } })
        let port = try await controller.start()
        return Harness(controller: controller, port: port, encoder: box.encoder!, injector: injector,
                       queue: queue, states: states)
    }

    /// `makeEncoder` 是非逃逸閉包，用一個盒子把建好的假件帶出來。
    private final class FakeEncoderBox: @unchecked Sendable { var encoder: FakeEncoder? }

    private func webSocket(_ port: Int, _ path: String) -> URLSessionWebSocketTask {
        var c = URLComponents()
        c.scheme = "ws"; c.host = "127.0.0.1"; c.port = port; c.path = path
        c.queryItems = [URLQueryItem(name: "t", value: Self.token.value)]
        let task = URLSession.shared.webSocketTask(with: c.url!)
        task.resume()
        return task
    }

    private func receiveData(_ task: URLSessionWebSocketTask) async throws -> Data {
        guard case .data(let data) = try await task.receive() else { throw TestFailure.unexpectedMessageKind }
        return data
    }

    private func frame(_ width: Int) -> Frame {
        Frame(width: width, height: 1, rgba: Data(count: width * 4))
    }

    private func withController(_ body: (Harness) async throws -> Void) async throws {
        let h = try await start()
        do { try await body(h) } catch { await h.controller.stop(); throw error }
        await h.controller.stop()
    }

    /// 沒有 viewer 時不拉幀、不編碼（spec 第 6 節）。
    @Test func doesNotEncodeWithoutViewer() async throws {
        try await withController { h in
            #expect(h.port > 0)
            #expect(h.controller.boundPort == h.port)
            h.controller.secondary.put(frame(8))
            try await Task.sleep(for: .milliseconds(60))     // 十幾個拉取週期
            #expect(h.encoder.calls == 0)
            #expect(h.controller.stats().framesPulled == 0)
            #expect(h.controller.secondary.stats().arrived == 1)
        }
    }

    /// viewer 連上 → 要求 keyframe → 拉幀編碼 → 序號從 1 起遞增送到 WebSocket。
    @Test func viewerGetsSequencedAccessUnitsStartingWithKeyframe() async throws {
        try await withController { h in
            let video = webSocket(h.port, "/ws/video")
            await h.states.wait { $0.contains { $0.hasVideo } }
            while h.encoder.requests < 1 { await Task.yield() }

            h.controller.secondary.put(frame(8))
            let firstData = try await receiveData(video)          // `try` 不放進 #require 的括號
            let first = try #require(RemoteVideoMessage.decode(firstData))
            #expect(first.sequence == 1)
            #expect(first.isKeyframe)
            #expect(first.accessUnit == H264Nal.join([FakeEncoder.sps, FakeEncoder.pps, Data([0x65, 8])]))

            h.controller.secondary.put(frame(9))
            let secondData = try await receiveData(video)
            let second = try #require(RemoteVideoMessage.decode(secondData))
            #expect(second.sequence == 2)
            #expect(!second.isKeyframe)

            let stats = h.controller.stats()
            #expect(stats.framesPulled == 2)
            #expect(stats.framesEncoded == 2)
            #expect(stats.server.framesSent == 2)
            video.cancel(with: .normalClosure, reason: nil)
            await h.states.wait { $0.contains { $0.phase == .disconnected } }
        }
    }

    /// 手機觸控只經 `InputQueue.touches`：注入器收到的是 allocator 配好的識別碼 64。
    @Test func touchesReachInjectorThroughInputQueue() async throws {
        try await withController { h in
            let input = webSocket(h.port, "/ws/input")
            try await input.send(.string(#"{"t":1,"id":3,"type":"down","x":0.25,"y":0.75}"#))
            await h.injector.gate.wait(for: 1)
            await h.queue.drained()
            #expect(h.injector.touches == [[TouchSpec(identifier: 64, point: NormPoint(x: 0.25, y: 0.75), down: true)]])
            input.cancel(with: .normalClosure, reason: nil)
            await h.injector.gate.wait(for: 2)           // 斷線 → allocator 全放開 → up
            #expect(h.injector.touches[1] == [TouchSpec(identifier: 64, point: NormPoint(x: 0.25, y: 0.75), down: false)])
        }
    }

    /// stop：拉取停止、編碼器 invalidate、server 關閉。
    @Test func stopInvalidatesEncoderAndClosesServer() async throws {
        let h = try await start()
        await h.controller.stop()
        #expect(h.encoder.wasInvalidated)
        #expect(h.controller.sessionState == RemoteSessionState(phase: .disconnected, hasVideo: false, hasInput: false))
        h.controller.secondary.put(frame(8))
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.encoder.calls == 0)
    }
}
```

`StateRecorder` 只在 `MirageCoreTests/TestGates.swift` 有；`MirageShellTests` 沒有。在同一個測試檔頂端加一份最小複本（跨 test target 不能共用，比照 `CountGate.swift:20-21` 的慣例）：

```swift
/// `MirageCoreTests/TestGates.swift:50-79` 的複本；跨 test target 不能共用。
actor StateRecorder<T: Sendable> {
    private(set) var items: [T] = []
    private var waiters: [(predicate: @Sendable ([T]) -> Bool, cont: CheckedContinuation<Void, Never>)] = []

    func record(_ value: T) {
        items.append(value)
        let snapshot = items
        var pending: [(predicate: @Sendable ([T]) -> Bool, cont: CheckedContinuation<Void, Never>)] = []
        var ready: [CheckedContinuation<Void, Never>] = []
        for waiter in waiters {
            if waiter.predicate(snapshot) { ready.append(waiter.cont) } else { pending.append(waiter) }
        }
        waiters = pending
        for cont in ready { cont.resume() }
    }

    func wait(until predicate: @escaping @Sendable ([T]) -> Bool) async {
        if predicate(items) { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append((predicate, cont))
        }
    }
}
```

放在 `app/Tests/MirageShellTests/StateRecorder.swift`（獨立檔，後面的 `AppModelRemoteTests` 也用）。

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteMirrorControllerTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'RemoteMirrorController' in scope`。

- [ ] **Step 3: 實作 controller**

`app/Sources/MirageShell/Remote/RemoteMirrorController.swift`：

```swift
import Foundation
import MirageCore

struct RemoteMirrorConfiguration: Sendable {
    var host = RemoteServerConfiguration.allInterfaces
    var port = RemoteServerConfiguration.defaultPort
    /// 預設 30 fps（spec 第 3 節）。60 fps 是 `.milliseconds(16)`，由呼叫端決定。
    var pullInterval: Duration = .milliseconds(33)
    let token: PairingToken
    let viewerPage: Data

    init(token: PairingToken, viewerPage: Data) {
        self.token = token
        self.viewerPage = viewerPage
    }
}

struct RemoteMirrorStats: Sendable, Equatable {
    let server: RemoteServerStats
    let framesPulled: Int
    let framesEncoded: Int
    let encodeFailures: Int
}

/// server 的 `onKeyframeRequested` 在編碼器存在之前就要綁；用這個盒子晚一步指過去。
private final class RemoteKeyframeRelay: @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: (any RemoteFrameEncoding)?

    func attach(_ encoder: any RemoteFrameEncoding) { lock.lock(); target = encoder; lock.unlock() }

    func request() {
        lock.lock(); let encoder = target; lock.unlock()
        encoder?.requestKeyframe()
    }
}

/// 存取單元 → 幀序號 → `RemoteServer.send`。序號從 1 起，每個 controller 一條。
private final class RemoteAccessUnitSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private let server: RemoteServer
    private var sequence: UInt32 = 0

    init(server: RemoteServer) { self.server = server }

    func deliver(_ unit: H264AccessUnit) {
        lock.lock()
        sequence &+= 1
        let number = sequence
        lock.unlock()
        server.send(accessUnit: unit.annexB, keyframe: unit.isKeyframe, sequence: number)
    }
}

/// 手機遙控的執行期：`LatestFrameBox`（`BroadcastFrameSink.secondary`）→ 拉取迴圈 → 編碼器 →
/// `RemoteServer`；手機觸控 → `InputQueue.touches`（spec 第 2 節設計決定 2：不直接呼叫
/// `EmulatorClient`，兩個並發 Task 各自送會在網路上超車，見 D6）。
///
/// 一個實例對應一個 server 生命週期：`RemoteServer` 只能 `start` 一次，所以「中斷連線／換
/// token」是建新的 controller、沿用同一個 `secondary`。
final class RemoteMirrorController: @unchecked Sendable {
    let secondary: LatestFrameBox
    let token: PairingToken
    private let configuration: RemoteMirrorConfiguration
    private let server: RemoteServer
    private let encoder: any RemoteFrameEncoding
    private let onError: @Sendable (String) -> Void
    private let lock = NSLock()
    private var pullTask: Task<Void, Never>?
    private var framesPulled = 0
    private var framesEncoded = 0
    private var encodeFailures = 0

    init(configuration: RemoteMirrorConfiguration,
         secondary: LatestFrameBox,
         inputQueue: InputQueue,
         makeEncoder: (@escaping @Sendable (H264AccessUnit) -> Void) -> any RemoteFrameEncoding,
         onError: @escaping @Sendable (String) -> Void = { _ in },
         onStateChanged: @escaping @Sendable (RemoteSessionState) -> Void = { _ in })
    {
        self.configuration = configuration
        self.secondary = secondary
        self.token = configuration.token
        self.onError = onError
        let relay = RemoteKeyframeRelay()
        let server = RemoteServer(
            configuration: RemoteServerConfiguration(host: configuration.host, port: configuration.port,
                                                     token: configuration.token, viewerPage: configuration.viewerPage),
            onTouches: { inputQueue.touches($0) },
            onKeyframeRequested: { relay.request() },
            onStateChanged: onStateChanged)
        self.server = server
        let sequencer = RemoteAccessUnitSequencer(server: server)
        let encoder = makeEncoder { sequencer.deliver($0) }
        self.encoder = encoder
        relay.attach(encoder)
    }

    var sessionState: RemoteSessionState { server.sessionState }
    var boundPort: Int? { server.boundPort }

    func stats() -> RemoteMirrorStats {
        lock.lock(); defer { lock.unlock() }
        return RemoteMirrorStats(server: server.stats(), framesPulled: framesPulled,
                                 framesEncoded: framesEncoded, encodeFailures: encodeFailures)
    }

    /// 埠被佔用時 `server.start()` 拋錯，這裡原樣往上丟，拉取迴圈不啟動。
    func start() async throws -> Int {
        let port = try await server.start()
        lock.lock()
        pullTask = Task.detached { [weak self] in await self?.pullLoop() }
        lock.unlock()
        return port
    }

    func stop() async {
        lock.lock()
        let task = pullTask
        pullTask = nil
        lock.unlock()
        task?.cancel()
        if let task { await task.value }
        encoder.invalidate()
        await server.stop()
    }

    // MARK: - 拉取迴圈

    /// `Task.detached`：不綁任何 actor（比照 `InputQueue` 的幫浦）。沒有 viewer 時只睡覺，
    /// 不 `takeLatest`——`LatestFrameBox` 覆蓋舊幀零成本，而拉了不編碼只是白拷貝。
    private func pullLoop() async {
        let interval = configuration.pullInterval
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { return }
            guard server.sessionState.hasVideo, let frame = secondary.takeLatest() else { continue }
            lock.lock(); framesPulled += 1; lock.unlock()
            do {
                try encoder.encode(frame)
                lock.lock(); framesEncoded += 1; lock.unlock()
            } catch {
                lock.lock(); encodeFailures += 1; lock.unlock()
                onError("編碼失敗：\(error)")
                return
            }
        }
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteMirrorControllerTests 2>&1 | tail -5`
Expected: `4 tests passed`。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageShell/Remote/RemoteMirrorController.swift app/Tests/MirageShellTests/RemoteMirrorControllerTests.swift app/Tests/MirageShellTests/StateRecorder.swift && git commit -m "feat: RemoteMirrorController 拉幀餵編碼器、送封包並把手機觸控轉進 InputQueue"
```

---

### Task 4: 生命週期 guard：有手機連著時關視窗不 suspend

**Files:**
- Modify: `app/Sources/MirageShell/Lifecycle/LifecyclePolicy.swift:1-13`
- Modify: `app/Sources/MirageShell/Lifecycle/AppLifecycle.swift:7-12,68-75`
- Test: `app/Tests/MirageShellTests/LifecyclePolicyTests.swift`（加測試）

**Interfaces:**
- Consumes: `LifecyclePolicy.didHide()`、`consumeResume()`、`suspended`（`LifecyclePolicy.swift:1-13`）；`AppLifecycle.init(client:)`、`windowShouldClose(_:)`（`AppLifecycle.swift:11-21,69-75`）。
- Produces:

```swift
struct LifecyclePolicy {
    /// 回傳「要不要 suspend」。有手機連著：只隱藏視窗、不記 suspended、回 false。
    mutating func didHide(remoteViewerActive: Bool) -> Bool
    mutating func didHide()          // 既有簽章保留 = didHide(remoteViewerActive: false)
}
final class AppLifecycle {
    init(client: EmulatorClient, hasActiveRemoteViewer: @escaping () -> Bool = { false })
}
```

決策放進純值型別 `LifecyclePolicy`，`AppLifecycle.windowShouldClose` 只負責把結果接到 `client.suspend()`——`windowShouldClose` 需要 `NSWindow`，headless 測不到，所以可測的判斷不能留在它身上。

- [ ] **Step 1: 寫失敗的測試**

在 `app/Tests/MirageShellTests/LifecyclePolicyTests.swift` 的 `struct LifecyclePolicyTests` 內加：

```swift
    /// spec 第 6 節：手機連著時關 Mac 視窗不 suspend，畫面繼續串流；之後喚醒也不該
    /// 呼叫 `client.wake()`（沒有東西要恢復）。
    @Test func hidingWithRemoteViewerDoesNotSuspend() {
        var policy = LifecyclePolicy()
        var suspend = policy.didHide(remoteViewerActive: true)
        #expect(!suspend)
        #expect(!policy.suspended)
        var resumed = policy.consumeResume()
        #expect(!resumed)

        suspend = policy.didHide(remoteViewerActive: false)
        #expect(suspend)
        #expect(policy.suspended)
        resumed = policy.consumeResume()
        #expect(resumed)
    }

    /// 既有無參數版本的行為不變：等於 `remoteViewerActive: false`。
    @Test func legacyDidHideStillSuspends() {
        var policy = LifecyclePolicy()
        policy.didHide()
        #expect(policy.suspended)
    }
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter LifecyclePolicyTests 2>&1 | tail -5`
Expected: 編譯失敗，`extra argument 'remoteViewerActive' in call`。

- [ ] **Step 3: 改 `LifecyclePolicy` 與 `AppLifecycle`**

`app/Sources/MirageShell/Lifecycle/LifecyclePolicy.swift` 整檔：

```swift
struct LifecyclePolicy {
    static let terminateAfterLastWindowClosed = false
    private(set) var suspended = false

    /// 關視窗要不要 suspend。手機遙控有 viewer 連著時不 suspend（spec 第 6 節）：視窗只是
    /// 隱藏，串流照常，所以也不記成 suspended——否則下次喚醒會多呼叫一次 `client.wake()`。
    /// 回傳值讓呼叫端不必再讀 `suspended` 猜這次有沒有變。
    @discardableResult
    mutating func didHide(remoteViewerActive: Bool) -> Bool {
        guard !remoteViewerActive else { return false }
        suspended = true
        return true
    }

    mutating func didHide() { didHide(remoteViewerActive: false) }

    mutating func consumeResume() -> Bool {
        let resume = suspended
        suspended = false
        return resume
    }
}
```

`app/Sources/MirageShell/Lifecycle/AppLifecycle.swift`：把 `AppLifecycle.swift:8-12` 的屬性與 init 改成

```swift
    private let client: EmulatorClient
    /// 手機遙控（spec 第 3 節）：有 viewer 連著時關視窗不 suspend。預設 `{ false }`，功能
    /// 關閉時這個型別的行為一行都沒變。
    private let hasActiveRemoteViewer: () -> Bool
    private var policy = LifecyclePolicy()

    init(client: EmulatorClient, hasActiveRemoteViewer: @escaping () -> Bool = { false }) {
        self.client = client
        self.hasActiveRemoteViewer = hasActiveRemoteViewer
        super.init()
```

並把 `windowShouldClose`（`AppLifecycle.swift:69-75`）改成：

```swift
    /// 視窗即將關閉 → 觸發休眠而非退出（回傳 false 阻止關閉，改為隱藏）。
    /// 手機連著時只隱藏不休眠：畫面要繼續送到手機（spec 第 6 節）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let remoteActive = hasActiveRemoteViewer()
        Self.diagnose("windowShouldClose", window: sender, result: "false",
                      action: remoteActive ? "hide-only(remote)" : "suspend")
        sender.orderOut(nil)                 // 隱藏視窗，app 續存（選單列常駐）
        if policy.didHide(remoteViewerActive: remoteActive) {
            Task { await client.suspend() }
        }
        return false
    }
```

- [ ] **Step 4: 跑測試確認通過（含既有兩條）**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter LifecyclePolicyTests 2>&1 | tail -5`
Expected: `4 tests passed`。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageShell/Lifecycle/LifecyclePolicy.swift app/Sources/MirageShell/Lifecycle/AppLifecycle.swift app/Tests/MirageShellTests/LifecyclePolicyTests.swift && git commit -m "feat: 有手機遙控 viewer 連著時關視窗只隱藏不 suspend"
```

---

### Task 5: 連線網址：主機位址、URL 字串、QR 圖片

**Files:**
- Create: `app/Sources/MirageShell/Remote/HostAddresses.swift`
- Create: `app/Sources/MirageShell/Remote/RemoteURL.swift`
- Create: `app/Sources/MirageShell/Remote/QRCodeImage.swift`
- Test: `app/Tests/MirageShellTests/RemoteURLTests.swift`

**Interfaces:**
- Consumes: `PairingToken.value`（`MirageCore/Remote/PairingToken.swift:13`）。`getifaddrs`／`getnameinfo` 迴圈已於 2026-09-12 在本機 typecheck 並執行（列出 `en0`、`utun8`（Tailscale 100.x）、`bridge100`、`bridge101`）。`CIFilter.qrCodeGenerator()` 需要 `import CoreImage.CIFilterBuiltins`（只 `import CoreImage` 找不到成員，已實測）；`CIDetector(ofType: CIDetectorTypeQRCode, …)` headless 可解回 `messageString`（已實測）。
- Produces:

```swift
struct HostAddress: Equatable, Sendable { let interface: String; let ip: String }
enum HostAddresses {
    static func current() -> [HostAddress]                   // IPv4、UP、非 loopback
    static func ordered(_ list: [HostAddress]) -> [HostAddress]   // en* → utun* → 其他；同類保持原順序
}
enum RemoteURL {
    static func build(host: String, port: Int, token: PairingToken) -> String   // "http://\(host):\(port)/?t=\(token.value)"
    static func all(addresses: [HostAddress], port: Int, token: PairingToken) -> [String]
}
enum QRCodeImage {
    static func ciImage(_ text: String, side: CGFloat) -> CIImage?   // 最近鄰放大到 side
    static func make(_ text: String, side: CGFloat) -> NSImage?
}
```

- [ ] **Step 1: 寫失敗的測試**

`app/Tests/MirageShellTests/RemoteURLTests.swift`：

```swift
import CoreImage
import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

@Suite struct RemoteURLTests {
    private let token = PairingToken(value: "00112233445566778899aabbccddeeff")!

    @Test func buildsHttpURLWithTokenQuery() {
        #expect(RemoteURL.build(host: "192.168.1.61", port: 8765, token: token)
                == "http://192.168.1.61:8765/?t=00112233445566778899aabbccddeeff")
    }

    /// Wi-Fi（en*）排最前面，Tailscale（utun*）其次，虛擬橋接最後；同類保持原順序。
    @Test func ordersWifiThenTailscaleThenOthers() {
        let list = [
            HostAddress(interface: "bridge100", ip: "192.168.139.3"),
            HostAddress(interface: "utun8", ip: "100.119.248.33"),
            HostAddress(interface: "en1", ip: "10.0.0.5"),
            HostAddress(interface: "en0", ip: "192.168.1.61"),
        ]
        #expect(HostAddresses.ordered(list).map(\.interface) == ["en1", "en0", "utun8", "bridge100"])
        #expect(HostAddresses.ordered([]).isEmpty)
    }

    @Test func allURLsFollowAddressOrder() {
        let list = [HostAddress(interface: "utun8", ip: "100.1.1.1"), HostAddress(interface: "en0", ip: "192.168.1.61")]
        #expect(RemoteURL.all(addresses: list, port: 9000, token: token) == [
            "http://192.168.1.61:9000/?t=00112233445566778899aabbccddeeff",
            "http://100.1.1.1:9000/?t=00112233445566778899aabbccddeeff",
        ])
    }

    /// `current()` 讀真實介面：只能斷言結構（IPv4 點分、非 127.*），不能斷言內容。
    @Test func currentAddressesAreIPv4NonLoopback() {
        let list = HostAddresses.current()
        #expect(list.allSatisfy { $0.ip.split(separator: ".").count == 4 })
        #expect(list.allSatisfy { !$0.ip.hasPrefix("127.") })
        #expect(list.allSatisfy { !$0.interface.isEmpty })
    }

    /// 產出的 QR 用 CoreImage 自己的偵測器解回來，內容一字不差。
    @Test func qrRoundTripsThroughCIDetector() throws {
        let url = RemoteURL.build(host: "192.168.1.61", port: 8765, token: token)
        let image = try #require(QRCodeImage.ciImage(url, side: 200))
        #expect(image.extent.width == 200)
        #expect(image.extent.height == 200)
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let decoded = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        #expect(decoded == [url])
        let nsImage = try #require(QRCodeImage.make(url, side: 200))
        #expect(nsImage.size.width == 200)
    }
}
```

- [ ] **Step 2: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteURLTests 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'RemoteURL' in scope`。

- [ ] **Step 3: 實作三個檔案**

`app/Sources/MirageShell/Remote/HostAddresses.swift`：

```swift
import Darwin
import Foundation

struct HostAddress: Equatable, Sendable {
    let interface: String
    let ip: String
}

/// 主機的 IPv4 位址，供選單顯示連線網址（spec 第 5 節：伺服器綁所有介面，網址要給使用者
/// 實際會走的那個位址——Wi-Fi 或 Tailscale）。
enum HostAddresses {
    /// `getifaddrs`：IPv4、介面 UP、非 loopback。排序交給 `ordered`。
    static func current() -> [HostAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [HostAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            out.append(HostAddress(interface: String(cString: entry.pointee.ifa_name), ip: String(cString: buffer)))
        }
        return ordered(out)
    }

    /// en*（Wi-Fi／有線）→ utun*（Tailscale）→ 其他（bridge、vmnet）。穩定排序，同類保持原順序。
    static func ordered(_ list: [HostAddress]) -> [HostAddress] {
        func rank(_ name: String) -> Int {
            if name.hasPrefix("en") { return 0 }
            if name.hasPrefix("utun") { return 1 }
            return 2
        }
        return list.enumerated()
            .sorted { (rank($0.element.interface), $0.offset) < (rank($1.element.interface), $1.offset) }
            .map(\.element)
    }
}
```

`app/Sources/MirageShell/Remote/RemoteURL.swift`：

```swift
import MirageCore

/// 配對網址（spec 第 5 節）：`http://<主機位址>:<埠>/?t=<token>`。不做 HTTPS，理由見 spec 第 1 節。
enum RemoteURL {
    static func build(host: String, port: Int, token: PairingToken) -> String {
        "http://\(host):\(port)/?t=\(token.value)"
    }

    static func all(addresses: [HostAddress], port: Int, token: PairingToken) -> [String] {
        addresses.map { build(host: $0.ip, port: port, token: token) }
    }
}
```

`app/Sources/MirageShell/Remote/QRCodeImage.swift`：

```swift
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// CoreImage 的 `CIQRCodeGenerator` → `NSImage`，給選單列的 `NSMenuItem.view` 用。
/// 不引入任何第三方 QR 函式庫（spec 不做的事之外的隱含約束：零新依賴）。
enum QRCodeImage {
    private static let correctionLevel = "M"

    /// 原始輸出每個模組 1 pt，用仿射縮放放大；`CIImage.transformed` 對整數倍縮放是最近鄰，
    /// 邊緣不會糊掉，手機相機才掃得到。
    static func ciImage(_ text: String, side: CGFloat) -> CIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correctionLevel
        guard let image = filter.outputImage, image.extent.width > 0 else { return nil }
        let scale = side / image.extent.width
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    static func make(_ text: String, side: CGFloat) -> NSImage? {
        guard let image = ciImage(text, side: side) else { return nil }
        let representation = NSCIImageRep(ciImage: image)
        let result = NSImage(size: NSSize(width: side, height: side))
        result.addRepresentation(representation)
        return result
    }
}
```

- [ ] **Step 4: 跑測試確認通過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter RemoteURLTests 2>&1 | tail -5`
Expected: `5 tests passed`。

- [ ] **Step 5: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageShell/Remote/HostAddresses.swift app/Sources/MirageShell/Remote/RemoteURL.swift app/Sources/MirageShell/Remote/QRCodeImage.swift app/Tests/MirageShellTests/RemoteURLTests.swift && git commit -m "feat: 手機遙控的連線網址、主機位址排序與 CoreImage QR 圖片"
```

---

### Task 6: 選單列「手機遙控」子選單：純決策 `RemoteMenu` 與 `MenuBarController.populate(remoteMenu:)`

**Files:**
- Create: `app/Sources/MirageShell/Lifecycle/RemoteMenu.swift`
- Modify: `app/Sources/MirageShell/Lifecycle/MenuBarController.swift:7-17,27-30,57-62,75-78,110-126,142-162`
- Test: `app/Tests/MirageShellTests/RemoteMenuTests.swift`
- Test: `app/Tests/MirageShellTests/MenuBarRemoteMenuTests.swift`

**Interfaces:**
- Consumes: `RemoteSessionState`（`phase`、`isViewerConnected`）；`QRCodeImage.make(_:side:)`；`MenuBarController` 既有的 `instanceMenu`／`menuNeedsUpdate`／`populate(instanceMenu:)` 寫法（`MenuBarController.swift:110-126,147-162`）。
- Produces（`AppModel+Remote` 綁定）：

```swift
enum RemoteMenuState: Equatable {
    case off
    case failed(String)                                   // 錯誤訊息；功能維持關閉
    case on(urls: [String], session: RemoteSessionState)
}
enum RemoteMenuEntry: Equatable {
    case toggle(title: String)      // 「開啟手機遙控」／「關閉手機遙控」
    case status(String)             // 停用項
    case url(String)                // 可點：複製到剪貼簿；representedObject 是網址
    case qr(String)                 // NSMenuItem.view = NSImageView(QR)
    case disconnect(enabled: Bool)  // 「中斷連線」
}
enum RemoteMenu {
    static let enableTitle = "開啟手機遙控"
    static let disableTitle = "關閉手機遙控"
    static let disconnectTitle = "中斷連線"
    static let qrSide: CGFloat = 176
    static func entries(_ state: RemoteMenuState) -> [RemoteMenuEntry]
    static func statusText(_ session: RemoteSessionState) -> String
}
final class MenuBarController {
    var remoteEntries: (() -> [RemoteMenuEntry])?
    var onToggleRemote: (() -> Void)?
    var onDisconnectRemote: (() -> Void)?
    var onCopyRemoteURL: ((String) -> Void)?
    static func populate(remoteMenu menu: NSMenu, entries: [RemoteMenuEntry], target: AnyObject?,
                         toggleAction: Selector?, copyAction: Selector?, disconnectAction: Selector?,
                         qrImage: (String) -> NSImage?)
}
```

- [ ] **Step 1: 寫失敗的純決策測試**

`app/Tests/MirageShellTests/RemoteMenuTests.swift`：

```swift
import Testing
@testable import MirageCore
@testable import MirageShell

@Suite struct RemoteMenuTests {
    private let urls = ["http://192.168.1.61:8765/?t=aa", "http://100.1.1.1:8765/?t=aa"]

    @Test func offShowsEnableAndStatus() {
        #expect(RemoteMenu.entries(.off) == [.toggle(title: RemoteMenu.enableTitle), .status("狀態：未開啟")])
    }

    /// 錯誤時功能是關閉的（spec 第 7 節），所以仍是「開啟」，錯誤訊息當停用項顯示。
    @Test func failedShowsEnableAndError() {
        #expect(RemoteMenu.entries(.failed("埠 8765 被佔用")) == [
            .toggle(title: RemoteMenu.enableTitle), .status("錯誤：埠 8765 被佔用"),
        ])
    }

    /// 開啟中：關閉、狀態、每個網址一列、第一個網址的 QR、中斷連線（有 viewer 才可點）。
    @Test func onListsEveryURLAndQRForTheFirst() {
        let waiting = RemoteMenu.entries(.on(urls: urls, session: .initial))
        #expect(waiting == [
            .toggle(title: RemoteMenu.disableTitle),
            .status("狀態：等待配對"),
            .url(urls[0]), .url(urls[1]),
            .qr(urls[0]),
            .disconnect(enabled: false),
        ])
        let connected = RemoteSessionState(phase: .connected, hasVideo: true, hasInput: true)
        #expect(RemoteMenu.entries(.on(urls: urls, session: connected)).last == .disconnect(enabled: true))
        #expect(RemoteMenu.entries(.on(urls: urls, session: connected))[1] == .status("狀態：已連線"))
        let dropped = RemoteSessionState(phase: .disconnected, hasVideo: false, hasInput: false)
        #expect(RemoteMenu.entries(.on(urls: urls, session: dropped))[1] == .status("狀態：已斷線（同一網址可重連）"))
    }

    /// 沒有任何介面位址（沒接網路）：沒有 url、沒有 qr，狀態說明原因。
    @Test func onWithoutAddressesExplains() {
        #expect(RemoteMenu.entries(.on(urls: [], session: .initial)) == [
            .toggle(title: RemoteMenu.disableTitle),
            .status("狀態：等待配對"),
            .status("找不到本機 IPv4 位址，請確認 Wi-Fi 或 Tailscale"),
            .disconnect(enabled: false),
        ])
    }
}
```

- [ ] **Step 2: 寫失敗的 AppKit 佈局測試（headless，只碰裸 `NSMenu`）**

`app/Tests/MirageShellTests/MenuBarRemoteMenuTests.swift`：

```swift
import AppKit
import Testing
@testable import MirageCore
@testable import MirageShell

/// 只測 `populate(remoteMenu:)`：建 `MenuBarController` 本身會在開發機的選單列放狀態列圖示
/// （比照 `MenuBarInstanceMenuTests`）。
@MainActor
@Suite struct MenuBarRemoteMenuTests {
    private let toggle = NSSelectorFromString("remoteToggleTapped")
    private let copy = NSSelectorFromString("remoteCopyTapped:")
    private let disconnect = NSSelectorFromString("remoteDisconnectTapped")
    private let url = "http://192.168.1.61:8765/?t=00112233445566778899aabbccddeeff"

    private func populate(_ menu: NSMenu, _ entries: [RemoteMenuEntry], target: AnyObject) {
        MenuBarController.populate(remoteMenu: menu, entries: entries, target: target,
                                   toggleAction: toggle, copyAction: copy, disconnectAction: disconnect,
                                   qrImage: { QRCodeImage.make($0, side: RemoteMenu.qrSide) })
    }

    @Test func buildsOneItemPerEntryWithActionsAndQRView() throws {
        let menu = NSMenu()
        let target = NSObject()
        let session = RemoteSessionState(phase: .connected, hasVideo: true, hasInput: true)
        populate(menu, RemoteMenu.entries(.on(urls: [url], session: session)), target: target)

        #expect(menu.items.count == 5)
        #expect(menu.items[0].title == RemoteMenu.disableTitle)
        #expect(menu.items[0].action == toggle)
        #expect(menu.items[0].target === target)
        #expect(menu.items[1].title == "狀態：已連線")
        #expect(!menu.items[1].isEnabled)
        #expect(menu.items[2].title == "網址：\(url)（點一下複製）")
        #expect(menu.items[2].action == copy)
        let represented = try #require(menu.items[2].representedObject as? String)
        #expect(represented == url)
        let view = try #require(menu.items[3].view as? NSImageView)
        #expect(view.frame.size == NSSize(width: RemoteMenu.qrSide, height: RemoteMenu.qrSide))
        #expect(view.image != nil)
        #expect(menu.items[4].title == RemoteMenu.disconnectTitle)
        #expect(menu.items[4].isEnabled)
        #expect(menu.items[4].action == disconnect)
    }

    @Test func disabledDisconnectHasNoActionAndOffMenuHasTwoItems() {
        let menu = NSMenu()
        populate(menu, RemoteMenu.entries(.on(urls: [url], session: .initial)), target: NSObject())
        let last = menu.items[menu.items.count - 1]
        #expect(!last.isEnabled)
        #expect(last.action == nil)

        populate(menu, RemoteMenu.entries(.off), target: NSObject())   // 每次展開重建，舊項目不殘留
        #expect(menu.items.map(\.title) == [RemoteMenu.enableTitle, "狀態：未開啟"])
    }
}
```

- [ ] **Step 3: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter "RemoteMenuTests|MenuBarRemoteMenuTests" 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'RemoteMenu' in scope`。

- [ ] **Step 4: 實作 `RemoteMenu`**

`app/Sources/MirageShell/Lifecycle/RemoteMenu.swift`：

```swift
import Foundation
import MirageCore

/// 「手機遙控」子選單顯示的狀態。由 `AppModel` 在 MainActor 上維護，選單展開前讀一次。
enum RemoteMenuState: Equatable {
    case off
    case failed(String)
    case on(urls: [String], session: RemoteSessionState)
}

/// 子選單的一列。`qr` 與 `url` 分開：QR 只畫第一個網址，網址每個都列。
enum RemoteMenuEntry: Equatable {
    case toggle(title: String)
    case status(String)
    case url(String)
    case qr(String)
    case disconnect(enabled: Bool)
}

/// 子選單內容的純決策：狀態 → 列表。無 AppKit、無 I/O，逐條單元測試（比照 `InstanceMenu`）。
enum RemoteMenu {
    static let enableTitle = "開啟手機遙控"
    static let disableTitle = "關閉手機遙控"
    static let disconnectTitle = "中斷連線"
    static let noAddressText = "找不到本機 IPv4 位址，請確認 Wi-Fi 或 Tailscale"
    static let qrSide: CGFloat = 176

    static func entries(_ state: RemoteMenuState) -> [RemoteMenuEntry] {
        switch state {
        case .off:
            return [.toggle(title: enableTitle), .status("狀態：未開啟")]
        case .failed(let message):
            return [.toggle(title: enableTitle), .status("錯誤：\(message)")]
        case .on(let urls, let session):
            let addresses: [RemoteMenuEntry] = urls.isEmpty
                ? [.status(noAddressText)]
                : urls.map { .url($0) } + [.qr(urls[0])]
            return [.toggle(title: disableTitle), .status(statusText(session))]
                + addresses
                + [.disconnect(enabled: session.isViewerConnected)]
        }
    }

    static func statusText(_ session: RemoteSessionState) -> String {
        switch session.phase {
        case .waitingForPairing: return "狀態：等待配對"
        case .connected: return "狀態：已連線"
        case .disconnected: return "狀態：已斷線（同一網址可重連）"
        }
    }
}
```

- [ ] **Step 5: 改 `MenuBarController`**

在 `MenuBarController.swift:17`（`instanceMenu` 宣告後）加：

```swift
    /// 「手機遙控」子選單。內容每次展開前由 `remoteEntries` 重算（狀態隨連線而變）。
    private let remoteMenu: NSMenu
```

在 `MenuBarController.swift:30`（`onSwitchInstance` 後）加：

```swift
    /// 手機遙控（2026-09-12）：AppModel.setupRemoteMenu() 綁定。`remoteEntries` 在子選單展開前
    /// 被呼叫；三個動作分別對應「開啟／關閉」「網址列（複製）」「中斷連線」。
    var remoteEntries: (() -> [RemoteMenuEntry])?
    var onToggleRemote: (() -> Void)?
    var onDisconnectRemote: (() -> Void)?
    var onCopyRemoteURL: ((String) -> Void)?
```

在 `init` 裡，`instanceMenu.autoenablesItems = false`（`:59`）之後加 `remoteMenu = NSMenu()`、`remoteMenu.autoenablesItems = false`；`super.init()` 之後加 `remoteMenu.delegate = self`；在 `menu.addItem(instanceParent)`（`:77`）之後加：

```swift
        let remoteParent = NSMenuItem(title: "手機遙控", action: nil, keyEquivalent: "")
        remoteParent.submenu = remoteMenu   // 與「切換模擬器」同形
        menu.addItem(remoteParent)
```

`menuNeedsUpdate`（`:112-126`）開頭加一段：

```swift
        if menu === remoteMenu {
            Self.populate(remoteMenu: remoteMenu, entries: remoteEntries?() ?? RemoteMenu.entries(.off),
                          target: self, toggleAction: #selector(remoteToggleTapped),
                          copyAction: #selector(remoteCopyTapped(_:)),
                          disconnectAction: #selector(remoteDisconnectTapped),
                          qrImage: { QRCodeImage.make($0, side: RemoteMenu.qrSide) })
            return
        }
```

在 `instanceTapped(_:)`（`:142-145`）之後加三個 selector 與 `populate`：

```swift
    @objc private func remoteToggleTapped() { onToggleRemote?() }
    @objc private func remoteDisconnectTapped() { onDisconnectRemote?() }
    @objc private func remoteCopyTapped(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        onCopyRemoteURL?(url)
    }

    /// 純佈局：entries → NSMenuItem。static 是為了測試（同 `populate(instanceMenu:)` 的理由）。
    /// QR 放 `NSMenuItem.view`（一個 `NSImageView`），不開視窗：`MirageScene` 是單一 `Window`、
    /// `AppLifecycle` 掛在 `NSApp.windows.first`，多一個視窗會打破那個不變式。
    static func populate(remoteMenu menu: NSMenu, entries: [RemoteMenuEntry], target: AnyObject?,
                         toggleAction: Selector?, copyAction: Selector?, disconnectAction: Selector?,
                         qrImage: (String) -> NSImage?)
    {
        menu.autoenablesItems = false
        menu.removeAllItems()
        for entry in entries {
            let item: NSMenuItem
            switch entry {
            case .toggle(let title):
                item = NSMenuItem(title: title, action: toggleAction, keyEquivalent: "")
                item.target = target
            case .status(let text):
                item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
            case .url(let url):
                item = NSMenuItem(title: "網址：\(url)（點一下複製）", action: copyAction, keyEquivalent: "")
                item.target = target
                item.representedObject = url
            case .qr(let url):
                item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                let view = NSImageView(frame: NSRect(x: 0, y: 0, width: RemoteMenu.qrSide, height: RemoteMenu.qrSide))
                view.image = qrImage(url)
                view.imageScaling = .scaleNone
                item.view = view
            case .disconnect(let enabled):
                item = NSMenuItem(title: RemoteMenu.disconnectTitle, action: enabled ? disconnectAction : nil,
                                  keyEquivalent: "")
                item.target = enabled ? target : nil
                item.isEnabled = enabled
            }
            menu.addItem(item)
        }
    }
```

`MenuBarController.swift` 改完約 250 行，仍在 400 以內。

- [ ] **Step 6: 跑測試確認通過（含既有的 `MenuBarInstanceMenuTests`）**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter "RemoteMenuTests|MenuBarRemoteMenuTests|MenuBarInstanceMenuTests" 2>&1 | tail -5`
Expected: `9 tests passed`。

- [ ] **Step 7: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageShell/Lifecycle/RemoteMenu.swift app/Sources/MirageShell/Lifecycle/MenuBarController.swift app/Tests/MirageShellTests/RemoteMenuTests.swift app/Tests/MirageShellTests/MenuBarRemoteMenuTests.swift && git commit -m "feat: 選單列「手機遙控」子選單：開關、網址、QR 與中斷連線"
```

---

### Task 7: `AppModel+Remote`：開關、中斷、`activeSink`、啟動選項、選單與生命週期接線

**Files:**
- Create: `app/Sources/MirageShell/Remote/RemoteLaunchOptions.swift`
- Create: `app/Sources/MirageShell/AppModel+Remote.swift`
- Modify: `app/Sources/MirageShell/AppModel.swift:13-15,39-49,152-161,164-181`
- Modify: `app/Sources/MirageShell/AppModel+Instances.swift:61`
- Test: `app/Tests/MirageShellTests/RemoteLaunchOptionsTests.swift`
- Test: `app/Tests/MirageShellTests/AppModelRemoteTests.swift`

**Interfaces:**
- Consumes: `RemoteMirrorController`（`init(configuration:secondary:inputQueue:makeEncoder:onError:onStateChanged:)`、`start()`、`stop()`、`sessionState`、`boundPort`、`secondary`、`token`）；`RemoteVideoEncoder.init(settings:onAccessUnit:)`；`RemoteMenu`／`RemoteMenuState`；`RemoteURL.all`、`HostAddresses.current()`；`AppLifecycle.init(client:hasActiveRemoteViewer:)`；`MenuBarController.remoteEntries`／`onToggleRemote`／`onDisconnectRemote`／`onCopyRemoteURL`；`BroadcastFrameSink`、`RemoteViewerPage.bundled()`、`PairingToken.generate()`、`EmulatorClient.isRunning`／`requestedStreamSize`／`stop()`／`start(box:width:height:)`（`EmulatorClient.swift:147-179,233-237`）；`AppModel.instanceSwitchTask`（`AppModel.swift:24`）。
- Produces：

```swift
struct RemoteLaunchOptions: Equatable, Sendable {
    static let enableKey = "MIRAGE_REMOTE"; static let portKey = "MIRAGE_REMOTE_PORT"; static let tokenKey = "MIRAGE_REMOTE_TOKEN"
    let port: Int; let token: PairingToken?; let problems: [String]
    static func parse(_ environment: [String: String]) -> RemoteLaunchOptions?   // 未設 MIRAGE_REMOTE=1 → nil
}
// AppModel.swift 新增儲存屬性
@ObservationIgnored var activeSink: any FrameSink        // 關閉時 === box
var remote: RemoteMirrorController?
var remoteMenuState: RemoteMenuState = .off
@ObservationIgnored var remoteTransitionInProgress = false
// AppModel+Remote.swift
extension AppModel {
    var hasActiveRemoteViewer: Bool { get }
    func setupRemoteMenu()
    func toggleRemote() async
    func enableRemote(host: String = RemoteServerConfiguration.allInterfaces,
                      port: Int = RemoteServerConfiguration.defaultPort, token: PairingToken? = nil) async
    func disableRemote() async
    func disconnectRemoteViewer() async
}
```

- [ ] **Step 1: 寫失敗的啟動選項測試**

`app/Tests/MirageShellTests/RemoteLaunchOptionsTests.swift`：

```swift
import Testing
@testable import MirageCore
@testable import MirageShell

@Suite struct RemoteLaunchOptionsTests {
    private let token = "00112233445566778899aabbccddeeff"

    @Test func absentOrNotOneMeansNil() {
        #expect(RemoteLaunchOptions.parse([:]) == nil)
        #expect(RemoteLaunchOptions.parse(["MIRAGE_REMOTE": "0"]) == nil)
        #expect(RemoteLaunchOptions.parse(["MIRAGE_REMOTE": "yes"]) == nil)
    }

    @Test func defaultsToPort8765WithoutToken() throws {
        let options = try #require(RemoteLaunchOptions.parse(["MIRAGE_REMOTE": "1"]))
        #expect(options.port == 8765)
        #expect(options.token == nil)
        #expect(options.problems.isEmpty)
    }

    @Test func readsPortAndToken() throws {
        let options = try #require(RemoteLaunchOptions.parse([
            "MIRAGE_REMOTE": "1", "MIRAGE_REMOTE_PORT": "9000", "MIRAGE_REMOTE_TOKEN": token,
        ]))
        #expect(options.port == 9000)
        #expect(options.token == PairingToken(value: token))
    }

    /// 壞值不讓功能整個不開：退回預設並記下問題，`AppModel.start()` 會印出來。
    @Test func invalidPortOrTokenFallBackAndReportProblems() throws {
        let options = try #require(RemoteLaunchOptions.parse([
            "MIRAGE_REMOTE": "1", "MIRAGE_REMOTE_PORT": "70000", "MIRAGE_REMOTE_TOKEN": "ABC",
        ]))
        #expect(options.port == 8765)
        #expect(options.token == nil)
        #expect(options.problems.count == 2)
        #expect(options.problems[0].contains("MIRAGE_REMOTE_PORT"))
        #expect(options.problems[1].contains("MIRAGE_REMOTE_TOKEN"))
    }
}
```

- [ ] **Step 2: 寫失敗的 `AppModel` 測試**

`app/Tests/MirageShellTests/AppModelRemoteTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

/// 端點指向沒人監聽的埠（CI 的 `MIRAGE_PORT`）：`client.start()` 會真的跑連線迴圈並退避重連，
/// 測試結尾一律 `client.stop()`（比照 `AppModelInstanceTests`）。遙控 server 用 `127.0.0.1:0`。
/// 沒有幀進來，所以 `RemoteVideoEncoder` 不會建 VT session——這組測試不需要硬體編碼器。
@MainActor
@Suite(.timeLimit(.minutes(1))) struct AppModelRemoteTests {
    private static func makeModel(_ tag: String) -> (AppModel, URL) {
        let (store, dir) = AppModelEditingTests.tempStore(tag)
        return (AppModel(store: store, starterBindings: { [] }), dir)
    }

    private func isOriginalSink(_ model: AppModel) -> Bool {
        (model.activeSink as AnyObject) === (model.box as AnyObject)
    }

    /// 硬性規則：關閉時 `activeSink` 就是 `FrameSinkFactory.make` 的產物，行為零改變。
    @Test func remoteOffUsesTheOriginalSink() {
        let (model, dir) = Self.makeModel("remote-off")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(isOriginalSink(model))
        #expect(model.remote == nil)
        #expect(model.remoteMenuState == .off)
        #expect(!model.hasActiveRemoteViewer)
    }

    /// 開啟：box 包進 BroadcastFrameSink、client 以同尺寸重啟；關閉：回到原 sink、client 仍在跑。
    @Test func enableWrapsBoxAndRestartsClientWithSameStreamSize() async throws {
        let (model, dir) = Self.makeModel("remote-enable")
        defer { try? FileManager.default.removeItem(at: dir) }
        await model.client.start(box: model.box, width: 900, height: 2000)

        await model.enableRemote(host: "127.0.0.1", port: 0)

        let sink = try #require(model.activeSink as? BroadcastFrameSink)
        #expect((sink.primary as AnyObject) === (model.box as AnyObject))
        let controller = try #require(model.remote)
        #expect(controller.secondary === sink.secondary)
        let port = try #require(controller.boundPort)
        #expect(port > 0)
        if case .on(let urls, let session) = model.remoteMenuState {
            #expect(session == .initial)
            #expect(urls.allSatisfy { $0.hasPrefix("http://") && $0.hasSuffix("/?t=\(controller.token.value)") })
        } else {
            Issue.record("預期 .on，實得 \(model.remoteMenuState)")
        }
        #expect(await model.client.isRunning)
        let size = await model.client.requestedStreamSize
        #expect(size.w == 900)
        #expect(size.h == 2000)

        await model.disableRemote()
        #expect(isOriginalSink(model))
        #expect(model.remote == nil)
        #expect(model.remoteMenuState == .off)
        #expect(await model.client.isRunning)
        await model.client.stop()
    }

    /// `start()` 之前開啟（`MIRAGE_REMOTE=1` 的路徑）：只換 sink，不啟動 client。
    @Test func enableBeforeStartOnlySwapsSink() async {
        let (model, dir) = Self.makeModel("remote-before-start")
        defer { try? FileManager.default.removeItem(at: dir) }
        await model.enableRemote(host: "127.0.0.1", port: 0)
        #expect(model.activeSink is BroadcastFrameSink)
        #expect(!(await model.client.isRunning))
        await model.disableRemote()
        #expect(isOriginalSink(model))
    }

    /// 中斷連線 = 新 controller、新 token，沿用同一個 secondary 與 activeSink（不重啟 client）。
    @Test func disconnectRotatesTokenKeepingTheSink() async throws {
        let (model, dir) = Self.makeModel("remote-disconnect")
        defer { try? FileManager.default.removeItem(at: dir) }
        await model.enableRemote(host: "127.0.0.1", port: 0)
        let before = try #require(model.remote)
        let sinkBefore = model.activeSink as AnyObject

        await model.disconnectRemoteViewer()

        let after = try #require(model.remote)
        #expect(after !== before)
        #expect(after.token != before.token)
        #expect(after.secondary === before.secondary)
        #expect((model.activeSink as AnyObject) === sinkBefore)
        await model.disableRemote()
    }

    /// spec 第 7 節：埠被佔用 → 選單顯示錯誤與埠號，功能維持關閉、sink 不變。
    @Test func portInUseReportsFailureAndKeepsOriginalSink() async throws {
        let (model, dir) = Self.makeModel("remote-port-clash")
        defer { try? FileManager.default.removeItem(at: dir) }
        let occupant = RemoteServer(
            configuration: RemoteServerConfiguration(host: "127.0.0.1", port: 0, token: PairingToken.generate(),
                                                     viewerPage: Data()),
            onTouches: { _ in })
        let port = try await occupant.start()

        await model.enableRemote(host: "127.0.0.1", port: port)

        #expect(model.remote == nil)
        #expect(isOriginalSink(model))
        if case .failed(let message) = model.remoteMenuState {
            #expect(message.contains(String(port)))
        } else {
            Issue.record("預期 .failed，實得 \(model.remoteMenuState)")
        }
        await occupant.stop()
    }
}
```

- [ ] **Step 3: 跑測試確認失敗**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter "RemoteLaunchOptionsTests|AppModelRemoteTests" 2>&1 | tail -5`
Expected: 編譯失敗，`cannot find 'RemoteLaunchOptions' in scope`。

- [ ] **Step 4: 實作 `RemoteLaunchOptions`**

`app/Sources/MirageShell/Remote/RemoteLaunchOptions.swift`：

```swift
import MirageCore

/// 啟動時自動開啟遙控的環境變數。**只給活體腳本用**（腳本驅動不了選單），使用者走選單列。
/// 壞值退回預設並記在 `problems`，比照 `EmulatorEndpoint.overrideProblem` 的做法：靜默退回
/// 會讓人盯著錯的埠卻毫無線索。
struct RemoteLaunchOptions: Equatable, Sendable {
    static let enableKey = "MIRAGE_REMOTE"
    static let portKey = "MIRAGE_REMOTE_PORT"
    static let tokenKey = "MIRAGE_REMOTE_TOKEN"
    private static let portRange = 1...65535

    let port: Int
    let token: PairingToken?
    let problems: [String]

    static func parse(_ environment: [String: String]) -> RemoteLaunchOptions? {
        guard environment[enableKey] == "1" else { return nil }
        var problems: [String] = []
        var port = RemoteServerConfiguration.defaultPort
        if let raw = environment[portKey] {
            if let value = Int(raw), portRange.contains(value) {
                port = value
            } else {
                problems.append("\(portKey)=\(raw) 不是 1 到 65535 的整數，改用 \(port)")
            }
        }
        var token: PairingToken?
        if let raw = environment[tokenKey] {
            token = PairingToken(value: raw)
            if token == nil { problems.append("\(tokenKey) 不是 32 個小寫十六進位字元，改用亂數 token") }
        }
        return RemoteLaunchOptions(port: port, token: token, problems: problems)
    }
}
```

- [ ] **Step 5: 改 `AppModel.swift`**

`AppModel.swift:14-15` 的 `box` 改成沒有 inline 初始值，並加三個儲存屬性：

```swift
    let client = EmulatorClient()
    let box: any FrameSink
    /// `client.start` 實際拿到的 sink。遙控關閉時**就是** `box`（同一個物件，行為零改變）；
    /// 開啟時是 `BroadcastFrameSink(primary: box, secondary:)`。Renderer 一直拿 `box`
    /// （`MirageScene.swift:46`），扇出的 `takeLatest` 代理到它，所以 Renderer 不必知道這件事。
    /// 切換模擬器也傳它（`AppModel+Instances.swift`），否則遙控開著時切台會讓扇出靜默消失。
    @ObservationIgnored var activeSink: any FrameSink
    /// 手機遙控的執行期；nil = 功能關閉。
    var remote: RemoteMirrorController?
    var remoteMenuState: RemoteMenuState = .off
    /// enable／disable／disconnect 都會 await，MainActor 期間會重入；進行中就忽略新要求。
    @ObservationIgnored var remoteTransitionInProgress = false
```

`init`（`AppModel.swift:39-49`）開頭改成：

```swift
        self.store = store
        self.starterBindings = starterBindings
        let sink = FrameSinkFactory.make(from: ProcessInfo.processInfo.environment)
        box = sink
        activeSink = sink
        inputQueue = InputQueue(injector: client)
```

`start()`（`AppModel.swift:152-161`）：在 `Task { [client] in for await s in client.states …}` 之前插入

```swift
        // 活體腳本用 MIRAGE_REMOTE=1 讓 App 一啟動就開遙控。client 還沒 start，所以這裡只換
        // activeSink，不會多一次重啟。
        if let options = RemoteLaunchOptions.parse(ProcessInfo.processInfo.environment) {
            for problem in options.problems { print("[remote] 環境變數覆寫無效：\(problem)") }
            await enableRemote(port: options.port, token: options.token)
        }
```

並把 `await client.start(box: box, width: …)` 改成 `await client.start(box: activeSink, width: Self.defaultStreamSize.w, height: Self.defaultStreamSize.h)`。

`startLifecycle()`（`AppModel.swift:164-181`）：`lifecycle = AppLifecycle(client: client)` 改成

```swift
        lifecycle = AppLifecycle(client: client, hasActiveRemoteViewer: { [weak self] in
            self?.hasActiveRemoteViewer ?? false
        })
```

並在 `setupInstanceMenu()` 之後加一行 `setupRemoteMenu()`。

`AppModel+Instances.swift:61` 的 `await client.start(box: box, width: size.w, height: size.h)` 改成 `await client.start(box: activeSink, width: size.w, height: size.h)`。

- [ ] **Step 6: 實作 `AppModel+Remote.swift`**

```swift
import AppKit
import MirageCore

/// 手機遙控（docs/specs/2026-09-12-lan-remote-control-design.md）：依選單或環境變數建
/// `RemoteMirrorController`、把 `box` 包進 `BroadcastFrameSink`、提供連線網址與配對狀態。
///
/// 獨立成 extension 檔（比照 AppModel+Instances.swift）：AppModel.swift 本體已滿，儲存屬性
/// （activeSink／remote／remoteMenuState）留在本體，行為在這裡。
extension AppModel {
    var hasActiveRemoteViewer: Bool { remote?.sessionState.isViewerConnected ?? false }

    func setupRemoteMenu() {
        menuBar?.remoteEntries = { [weak self] in RemoteMenu.entries(self?.remoteMenuState ?? .off) }
        menuBar?.onToggleRemote = { [weak self] in Task { @MainActor in await self?.toggleRemote() } }
        menuBar?.onDisconnectRemote = { [weak self] in Task { @MainActor in await self?.disconnectRemoteViewer() } }
        menuBar?.onCopyRemoteURL = { url in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
        }
    }

    func toggleRemote() async {
        if remote == nil { await enableRemote() } else { await disableRemote() }
    }

    /// 開啟：起 server → 記狀態 → 把 box 包進 BroadcastFrameSink 並重啟 client（設計決定 1）。
    /// server 起不來（埠被佔用）就停在 `.failed`，sink 一個位元組都不動（spec 第 7 節）。
    /// `activeSink` 已經是 Broadcast（中斷連線後重開）時沿用它的 secondary，不重啟 client。
    func enableRemote(host: String = RemoteServerConfiguration.allInterfaces,
                      port: Int = RemoteServerConfiguration.defaultPort,
                      token: PairingToken? = nil) async
    {
        guard remote == nil, !remoteTransitionInProgress else { return }
        remoteTransitionInProgress = true
        defer { remoteTransitionInProgress = false }
        guard let page = RemoteViewerPage.bundled() else {
            remoteMenuState = .failed("找不到 viewer.html（bundle 缺資源，見 RemoteViewerPage）")
            return
        }
        let secondary = (activeSink as? BroadcastFrameSink)?.secondary ?? LatestFrameBox()
        let controller = makeRemoteController(host: host, port: port, token: token ?? PairingToken.generate(),
                                              page: page, secondary: secondary)
        do {
            let bound = try await controller.start()
            remote = controller
            let urls = RemoteURL.all(addresses: HostAddresses.current(), port: bound, token: controller.token)
            remoteMenuState = .on(urls: urls, session: controller.sessionState)
            print("[remote] listening port=\(bound) url=\(urls.first ?? "（找不到本機 IPv4 位址）")")
        } catch {
            remoteMenuState = .failed("埠 \(port) 無法監聽：\(error)")
            print("[remote] 啟動失敗 port=\(port)：\(error)")
            return
        }
        if !(activeSink is BroadcastFrameSink) {
            await switchSink(to: BroadcastFrameSink(primary: box, secondary: secondary))
        }
    }

    /// 關閉：停 controller → 回到原本的 sink 並重啟 client。token 隨 controller 作廢。
    func disableRemote() async {
        guard let controller = remote, !remoteTransitionInProgress else { return }
        remoteTransitionInProgress = true
        defer { remoteTransitionInProgress = false }
        remote = nil
        await controller.stop()
        remoteMenuState = .off
        await switchSink(to: box)
    }

    /// 中斷連線 = token 作廢、重新開啟產生新的（spec 第 5 節）。沿用同一個 secondary 與
    /// activeSink，所以 client 不重啟，Mac 視窗不閃。
    func disconnectRemoteViewer() async {
        guard let controller = remote, !remoteTransitionInProgress else { return }
        let port = controller.boundPort ?? RemoteServerConfiguration.defaultPort
        remoteTransitionInProgress = true
        remote = nil
        await controller.stop()
        remoteTransitionInProgress = false
        await enableRemote(port: port)
    }

    // MARK: - 私有

    private func makeRemoteController(host: String, port: Int, token: PairingToken, page: Data,
                                      secondary: LatestFrameBox) -> RemoteMirrorController
    {
        var configuration = RemoteMirrorConfiguration(token: token, viewerPage: page)
        configuration.host = host
        configuration.port = port
        return RemoteMirrorController(
            configuration: configuration, secondary: secondary, inputQueue: inputQueue,
            makeEncoder: { deliver in RemoteVideoEncoder(onAccessUnit: deliver) },
            onError: { [weak self] message in Task { @MainActor in await self?.failRemote(message) } },
            onStateChanged: { [weak self] state in Task { @MainActor in self?.remoteSessionChanged(state) } })
    }

    /// 編碼器出錯（含 `VTCompressionSessionCreate` 失敗）：關閉功能、選單顯示錯誤碼（spec 第 7 節）。
    private func failRemote(_ message: String) async {
        print("[remote] \(message)，功能關閉")
        await disableRemote()
        remoteMenuState = .failed(message)
    }

    private func remoteSessionChanged(_ state: RemoteSessionState) {
        guard case .on(let urls, _) = remoteMenuState else { return }
        remoteMenuState = .on(urls: urls, session: state)
    }

    /// 換 sink 並重啟 client。與 `switchInstance` 共用 `instanceSwitchTask` 串列化：兩者都是
    /// stop → start，交錯會讓 client 停在錯的 box 或錯的端點。client 沒在跑（`start()` 之前）
    /// 就只記下 sink，`start()` 會用它。
    private func switchSink(to sink: any FrameSink) async {
        activeSink = sink
        guard await client.isRunning else { return }
        let previous = instanceSwitchTask
        let task = Task { @MainActor in
            await previous?.value
            let size = await self.client.requestedStreamSize
            await self.client.stop()
            await self.client.start(box: sink, width: size.w, height: size.h)
        }
        instanceSwitchTask = task
        await task.value
    }
}
```

- [ ] **Step 7: 跑測試確認通過（含既有 `AppModelInstanceTests`、`AppModelEditingTests`）**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift test --filter "RemoteLaunchOptionsTests|AppModelRemoteTests|AppModelInstanceTests|AppModelEditingTests" 2>&1 | grep -E "tests? passed|failed" | tail -3`
Expected: 全部 passed、無 failed。

- [ ] **Step 8: 建置 release 確認 App target 也過**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift build -c release 2>&1 | tail -3`
Expected: `Build complete!`。

- [ ] **Step 9: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Sources/MirageShell/Remote/RemoteLaunchOptions.swift app/Sources/MirageShell/AppModel+Remote.swift app/Sources/MirageShell/AppModel.swift app/Sources/MirageShell/AppModel+Instances.swift app/Tests/MirageShellTests/RemoteLaunchOptionsTests.swift app/Tests/MirageShellTests/AppModelRemoteTests.swift && git commit -m "feat: AppModel 接上手機遙控開關、中斷連線與 BroadcastFrameSink 切換"
```

---

### Task 8: 活體驗證：`LiveGate.remote`、觸控路徑活體測試、Python 用戶端、`verify_remote_mirror.sh`

**Files:**
- Modify: `app/Tests/MirageCoreTests/LiveGate.swift:28-32`
- Create: `app/Tests/MirageCoreTests/Remote/RemoteInputLiveTests.swift`
- Create: `app/scripts/lib/remote_client.py`
- Create: `app/scripts/lib/remote_client_selftest.py`
- Create: `app/scripts/lib/remote_venv.sh`
- Create: `app/scripts/verify_remote_mirror.sh`
- Modify: `app/scripts/ci.sh:409-415`

**Interfaces:**
- Consumes: `RemoteServer`、`InputQueue(injector:)`、`InputQueue.drained()`（`InputQueue.swift:188-192`）、`EmulatorClient.start(box:width:height:)`；`lib/verify_common.sh`（`require_device`、`require_grpc`、`assert_ok`、`assert_at_least`、`assert_at_most`、`assert_equals`）、`lib/gui_session.sh`（`gui_session_start`、`gui_session_cleanup`）、`lib/getevent_touch.sh`（`touch_stuck_slots`、`touch_transition_count`）、`lib/load_sentinel.sh`（`disk_preflight`）；`verify_keymap_release.sh:16-39` 的 getevent 擷取寫法；`AppModel` 印的 `[remote] listening port=<埠> url=<網址>`。
- Produces：`LiveGate.remote`；`remote_client.py` 的 CLI（`--host --port --token --wait-keyframe --seconds --touch --loop`）與 stdout `KEY=VAL`；`remote_venv.sh` 印出 venv 的 python 路徑；`verify_remote_mirror.sh` 退出碼 0＝三條斷言通過。

- [ ] **Step 1: `LiveGate.remote`**

`app/Tests/MirageCoreTests/LiveGate.swift` 在 `audio` 之後加：

```swift
    /// 手機遙控活體：需要真模擬器（觸控路徑）與硬體編碼器（`MirageShellTests` 的編碼器測試
    /// 讀同兩個變數）。獨立閘門的理由同 `audio`：只設 `MIRAGE_LIVE` 的覆蓋率量測不該因為
    /// 沙箱沒有硬體編碼器而紅。唯一正確的執行方式是 `scripts/verify_remote_mirror.sh`。
    static let remote = live && ProcessInfo.processInfo.environment["MIRAGE_LIVE_REMOTE"] == "1"
```

- [ ] **Step 2: 寫觸控路徑的活體測試**

`app/Tests/MirageCoreTests/Remote/RemoteInputLiveTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

/// spec 第 2 節設計決定 2 的產品路徑：`/ws/input` → `RemoteServer` → `InputQueue.touches` →
/// `EmulatorClient.sendTouches` → 真模擬器。Swift 斷言只驗到 RPC 完成（`drained()` 回來）；
/// guest 是否真的收到由 `verify_remote_mirror.sh` 的 getevent 判定（比照 `KeymapReleaseLiveTests`）。
@Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteInputLiveTests {
    private static let token = PairingToken(value: "00112233445566778899aabbccddeeff")!

    @Test(.enabled(if: LiveGate.remote, "需 MIRAGE_LIVE=1 MIRAGE_LIVE_REMOTE=1，請跑 scripts/verify_remote_mirror.sh"))
    func remoteTouchReachesEmulatorThroughInputQueue() async throws {
        let client = EmulatorClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        let queue = InputQueue(injector: client)
        let server = RemoteServer(
            configuration: RemoteServerConfiguration(host: "127.0.0.1", port: 0, token: Self.token, viewerPage: Data()),
            onTouches: { queue.touches($0) })
        let port = try await server.start()
        // 健康探測填好 guestDisplay 前，sendTouches 會靜默略過注入（KeymapReleaseLiveTests 同一段）。
        try await Task.sleep(for: .seconds(2))

        var components = URLComponents()
        components.scheme = "ws"; components.host = "127.0.0.1"; components.port = port; components.path = "/ws/input"
        components.queryItems = [URLQueryItem(name: "t", value: Self.token.value)]
        let input = URLSession.shared.webSocketTask(with: components.url!)
        input.resume()
        try await input.send(.string(#"{"t":1,"id":1,"type":"down","x":0.5,"y":0.5}"#))
        try await Task.sleep(for: .milliseconds(150))
        try await input.send(.string(#"{"t":2,"id":1,"type":"up","x":0.5,"y":0.5}"#))
        try await input.send(.string(#"{"type":"ping","t":3}"#))
        _ = try await input.receive()            // echo 回來代表前兩則已進 InputQueue
        await queue.drained()                    // 同一 consumer 的 barrier：兩次 sendTouches 都已完成

        #expect(server.stats().touchesForwarded == 2)
        #expect(server.stats().invalidInputMessages == 0)
        input.cancel(with: .normalClosure, reason: nil)
        await server.stop()
        await client.stop()
    }
}
```

Run: `cd /Users/hanfourhuang/Projects/mirage/app && swift build --build-tests 2>&1 | tail -3`
Expected: `Build complete!`（活體測試本身在 Step 8 由腳本跑）。

- [ ] **Step 3: Python 用戶端與自我測試**

`app/scripts/lib/remote_client.py`：

```python
#!/usr/bin/env python3
"""手機遙控的 WebSocket 用戶端（活體腳本用，不進產品）。

模仿 viewer.html：連 /ws/video 等第一個 keyframe、追幀序；--touch 時連 /ws/input 送
一組 down/move/up 並量 ping 往返。輸出 KEY=VAL 供 bash 斷言。
--loop：反覆重連、丟掉收到的幀，只為了讓編碼器有 viewer（驗收線 7 對照用）。

退出碼：0 通過、2 連不上（403／409／refused）、3 等不到 keyframe。
純函式（parse_header、SequenceTracker、touch_messages、video_url、input_url）不依賴
websockets，remote_client_selftest.py 用系統 python3 直接測。
"""
import argparse
import asyncio
import json
import struct
import sys
import time

HEADER = struct.Struct(">QIB")   # 8 bytes monotonic ns、4 bytes seq、1 byte keyframe（spec 第 4 節）


def parse_header(data: bytes):
    """回 (sent_ns, seq, is_keyframe, access_unit)。短於標頭或旗標不是 0/1 就 ValueError。"""
    if len(data) <= HEADER.size:
        raise ValueError(f"short video message: {len(data)} bytes")
    sent_ns, seq, key = HEADER.unpack_from(data, 0)
    if key > 1:
        raise ValueError(f"bad keyframe flag: {key}")
    return sent_ns, seq, key == 1, data[HEADER.size:]


class SequenceTracker:
    """幀序連續性：與 viewer.html 同一個算法（32 位元回繞）。"""

    def __init__(self):
        self.last = None
        self.frames = 0
        self.keyframes = 0
        self.gaps = 0

    def observe(self, seq: int, keyframe: bool):
        if self.last is not None:
            self.gaps += (seq - self.last - 1) & 0xFFFFFFFF
        self.last = seq
        self.frames += 1
        self.keyframes += 1 if keyframe else 0


def touch_messages(x: float, y: float, pointer_id: int = 1, now_ms: float = 0.0):
    """一組 down/move/up 的 JSON 文字，格式同 viewer.html:196。"""
    return [
        json.dumps({"t": now_ms, "id": pointer_id, "type": "down", "x": x, "y": y}),
        json.dumps({"t": now_ms + 40, "id": pointer_id, "type": "move", "x": min(1.0, x + 0.05), "y": y}),
        json.dumps({"t": now_ms + 80, "id": pointer_id, "type": "up", "x": min(1.0, x + 0.05), "y": y}),
    ]


def video_url(host: str, port: int, token: str) -> str:
    return f"ws://{host}:{port}/ws/video?t={token}"


def input_url(host: str, port: int, token: str) -> str:
    return f"ws://{host}:{port}/ws/input?t={token}"


async def receive_video(args, results):
    from websockets.asyncio.client import connect

    tracker = SequenceTracker()
    started = time.monotonic()
    keyframe_at = None
    async with connect(video_url(args.host, args.port, args.token), max_size=None) as video:
        while True:
            elapsed = time.monotonic() - started
            budget = args.wait_keyframe if keyframe_at is None else args.seconds - (elapsed - keyframe_at)
            if budget <= 0:
                break
            try:
                message = await asyncio.wait_for(video.recv(), timeout=budget)
            except asyncio.TimeoutError:
                break
            if not isinstance(message, bytes):
                continue
            _, seq, keyframe, _ = parse_header(message)
            if keyframe_at is None and not keyframe:
                continue                      # 伺服器從 IDR 起送，這裡再守一次
            if keyframe_at is None:
                keyframe_at = time.monotonic() - started
            tracker.observe(seq, keyframe)
    results["KEYFRAME_SECONDS"] = f"{keyframe_at:.2f}" if keyframe_at is not None else ""
    results["FRAMES"] = tracker.frames
    results["KEYFRAMES"] = tracker.keyframes
    results["SEQ_GAPS"] = tracker.gaps
    return keyframe_at is not None


async def send_touch(args, results):
    from websockets.asyncio.client import connect

    async with connect(input_url(args.host, args.port, args.token)) as inbound:
        for text in touch_messages(0.5, 0.5, now_ms=time.monotonic() * 1000):
            await inbound.send(text)
            await asyncio.sleep(0.08)
        sent = time.monotonic()
        await inbound.send(json.dumps({"type": "ping", "t": sent * 1000}))
        echo = await asyncio.wait_for(inbound.recv(), timeout=5)
        results["PING_RTT_MS"] = f"{(time.monotonic() - sent) * 1000:.1f}"
        results["PING_ECHO_OK"] = 1 if json.loads(echo).get("type") == "ping" else 0
        results["TOUCH_SENT"] = 3


async def loop_forever(args):
    from websockets.asyncio.client import connect

    while True:
        try:
            async with connect(video_url(args.host, args.port, args.token), max_size=None) as video:
                async for _ in video:
                    pass
        except Exception:                      # App 重啟中：等一下再連
            await asyncio.sleep(0.5)


async def main(args) -> int:
    if args.loop:
        await loop_forever(args)
        return 0
    results = {}
    try:
        keyframe = await receive_video(args, results)
        if args.touch:
            await send_touch(args, results)
    except (OSError, ConnectionError) as error:
        print(f"CONNECT_ERROR={error}")
        return 2
    except Exception as error:                 # websockets 的 InvalidStatus（403／409）等
        print(f"CONNECT_ERROR={type(error).__name__}: {error}")
        return 2
    for key, value in results.items():
        print(f"{key}={value}")
    return 0 if keyframe else 3


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token", required=True)
    parser.add_argument("--wait-keyframe", type=float, default=60.0, help="等第一個 keyframe 的秒數")
    parser.add_argument("--seconds", type=float, default=10.0, help="keyframe 之後再收幾秒")
    parser.add_argument("--touch", action="store_true")
    parser.add_argument("--loop", action="store_true")
    sys.exit(asyncio.run(main(parser.parse_args())))
```

`app/scripts/lib/remote_client_selftest.py`：

```python
#!/usr/bin/env python3
"""remote_client.py 純函式的自我測試：不需要 websockets、不需要模擬器（ci.sh 閘門 8）。"""
import json
import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import remote_client as rc  # noqa: E402


class HeaderTests(unittest.TestCase):
    def test_parses_thirteen_byte_header(self):
        data = struct.pack(">QIB", 123456789, 7, 1) + b"\x00\x00\x00\x01\x65"
        sent, seq, key, unit = rc.parse_header(data)
        self.assertEqual((sent, seq, key, unit), (123456789, 7, True, b"\x00\x00\x00\x01\x65"))

    def test_rejects_short_or_bad_flag(self):
        with self.assertRaises(ValueError):
            rc.parse_header(struct.pack(">QIB", 1, 1, 0))          # 只有標頭沒有 payload
        with self.assertRaises(ValueError):
            rc.parse_header(struct.pack(">QIB", 1, 1, 2) + b"\x00")


class SequenceTests(unittest.TestCase):
    def test_counts_gaps_and_keyframes(self):
        tracker = rc.SequenceTracker()
        for seq, key in [(1, True), (2, False), (5, False), (6, True)]:
            tracker.observe(seq, key)
        self.assertEqual((tracker.frames, tracker.keyframes, tracker.gaps), (4, 2, 2))

    def test_wraparound_is_not_a_gap(self):
        tracker = rc.SequenceTracker()
        tracker.observe(0xFFFFFFFF, True)
        tracker.observe(0, False)
        self.assertEqual(tracker.gaps, 0)


class TouchMessageTests(unittest.TestCase):
    def test_down_move_up_have_viewer_shape(self):
        messages = [json.loads(m) for m in rc.touch_messages(0.98, 0.5, pointer_id=3, now_ms=100.0)]
        self.assertEqual([m["type"] for m in messages], ["down", "move", "up"])
        self.assertTrue(all(m["id"] == 3 for m in messages))
        self.assertTrue(all(0 <= m["x"] <= 1 and 0 <= m["y"] <= 1 for m in messages))   # 夾住
        self.assertEqual([m["t"] for m in messages], [100.0, 140.0, 180.0])

    def test_urls(self):
        self.assertEqual(rc.video_url("127.0.0.1", 8765, "ab"), "ws://127.0.0.1:8765/ws/video?t=ab")
        self.assertEqual(rc.input_url("10.0.0.2", 9000, "cd"), "ws://10.0.0.2:9000/ws/input?t=cd")


if __name__ == "__main__":
    unittest.main(verbosity=1)
```

Run: `cd /Users/hanfourhuang/Projects/mirage/app && python3 scripts/lib/remote_client_selftest.py 2>&1 | tail -3`
Expected: `Ran 6 tests` … `OK`。

- [ ] **Step 4: venv 建置腳本**

`app/scripts/lib/remote_venv.sh`（可 source 也可直接執行，印出 python 路徑）：

```bash
#!/usr/bin/env bash
# 手機遙控活體腳本的 Python venv：只裝 websockets。
#
# **一律用系統 /usr/bin/python3 建**：spike 實測本機防火牆只放行 Apple 的 Python，pyenv 的
# Python 連 127.0.0.1 也會被擋（scratchpad/phone-spike/README.md 「啟動與 A/B」）。
# 目錄 app/scripts/.venv-remote 已被根目錄 .gitignore:6 的 `.venv*/` 涵蓋。
# 用法：PY=$(bash lib/remote_venv.sh) || exit 1
set -uo pipefail
REMOTE_VENV="${REMOTE_VENV:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.venv-remote}"
SYSTEM_PYTHON="${SYSTEM_PYTHON:-/usr/bin/python3}"
WEBSOCKETS_SPEC="${WEBSOCKETS_SPEC:-websockets>=13,<16}"

remote_venv_python() {
    local py="${REMOTE_VENV}/bin/python"
    if [ ! -x "$py" ]; then
        [ -x "$SYSTEM_PYTHON" ] || { echo "❌ 找不到系統 python3：${SYSTEM_PYTHON}" >&2; return 1; }
        "$SYSTEM_PYTHON" -m venv "$REMOTE_VENV" >&2 || { echo "❌ 建 venv 失敗：${REMOTE_VENV}" >&2; return 1; }
    fi
    if ! "$py" -c "import websockets" > /dev/null 2>&1; then
        "$py" -m pip install --quiet "$WEBSOCKETS_SPEC" >&2 || { echo "❌ pip install websockets 失敗" >&2; return 1; }
    fi
    # 版本要印出來：websockets 13 才有 websockets.asyncio.client，舊版會在連線時才炸。
    "$py" -c "import websockets, sys; print('websockets', websockets.__version__, file=sys.stderr)"
    echo "$py"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    remote_venv_python
fi
```

Run: `cd /Users/hanfourhuang/Projects/mirage/app && chmod +x scripts/lib/remote_venv.sh && PY=$(scripts/lib/remote_venv.sh) && "$PY" -c "from websockets.asyncio.client import connect; print('ok')" && git check-ignore -v scripts/.venv-remote/bin/python`
Expected: stderr 印 `websockets 15.x`，stdout `ok`，最後一行 `.gitignore:6:.venv*/	scripts/.venv-remote/bin/python`。

- [ ] **Step 5: `verify_remote_mirror.sh`**

`app/scripts/verify_remote_mirror.sh`：

```bash
#!/usr/bin/env bash
# 手機遙控活體驗證（spec 第 8 節）：三條斷言
#   R1 手機端（Python 用戶端）60 秒內收到 keyframe
#   R2 幀序連續（SEQ_GAPS == 0）
#   R3 送一組 down/move/up 後 guest 的 getevent 出現 ABS_MT_TRACKING_ID，且沒有 slot 卡在 down
# 之前先跑兩條 Swift 活體測試：RemoteVideoEncoderLiveTests（硬體編碼器＋SPS 改寫）與
# RemoteInputLiveTests（server → InputQueue → 真模擬器），並斷言它們是 passed 不是 skipped。
#
# 用法：
#   ./scripts/verify_remote_mirror.sh                      # 預設 5556 / 8556 / Pixel Flow / 遙控埠 8765
#   ./scripts/verify_remote_mirror.sh -s emulator-5554 -p 8554 -P 8770 -w 60 -d 10
#
# 前置：模擬器在跑、遊戲能停在**會持續變化**的畫面（streamScreenshot 是變化驅動的，畫面靜止
# 時編碼器根本沒有幀可拉，R1 會紅——那是環境的紅燈，不是產品的）；遙控埠沒被佔用。
set -uo pipefail

source "$(dirname "$0")/lib/load_sentinel.sh"
disk_preflight "$(dirname "$0")" || exit 1
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/verify_common.sh"
source "${SCRIPT_DIR}/lib/gui_session.sh"
source "${SCRIPT_DIR}/lib/getevent_touch.sh"
source "${SCRIPT_DIR}/lib/remote_venv.sh"

SERIAL="emulator-5556"
GRPC_PORT="8556"
PACKAGE="com.loomgames.pixelflow"
REMOTE_PORT=8765
WAIT_KEYFRAME=60
DURATION=10

while getopts "s:p:g:P:w:d:h" opt; do
  case "$opt" in
    s) SERIAL="$OPTARG" ;;
    p) GRPC_PORT="$OPTARG" ;;
    g) PACKAGE="$OPTARG" ;;
    P) REMOTE_PORT="$OPTARG" ;;
    w) WAIT_KEYFRAME="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    h) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "用法：$0 [-s serial] [-p grpc_port] [-g package] [-P remote_port] [-w keyframe_wait] [-d seconds]" >&2; exit 2 ;;
  esac
done
for v in REMOTE_PORT WAIT_KEYFRAME DURATION; do
  eval "val=\$${v}"
  case "$val" in ''|*[!0-9]*) echo "❌ ${v} 只接受正整數：實測 '${val}'。" >&2; exit 2 ;; esac
done
[ -z "$PACKAGE" ] && { echo "❌ -g 不接受空字串：需要會變化的畫面來源。" >&2; exit 2; }

PY=$(remote_venv_python) || exit 1
require_device "$SERIAL"
require_grpc "$GRPC_PORT"
if nc -z localhost "$REMOTE_PORT" 2>/dev/null; then
    echo "❌ 遙控埠 ${REMOTE_PORT} 已有人監聽；換一個埠：-P <埠>。" >&2
    exit 1
fi

EVENT_LOG=$(mktemp -t mirage_remote_events) || exit 1
TEST_LOG=$(mktemp -t mirage_remote_tests) || exit 1
CLIENT_LOG=$(mktemp -t mirage_remote_client) || exit 1
LOG=$(mktemp -t mirage_remote_app)
BUNDLE=$(mktemp -d -t mirage_remote_bundle)
CAPTURE_PID=''
start_capture() {
    : > "$EVENT_LOG"
    "$ADB" shell getevent -lt /dev/input/event1 > "$EVENT_LOG" 2>&1 &
    CAPTURE_PID=$!
    sleep 1
}
stop_capture() {
    if [ -n "$CAPTURE_PID" ]; then
        "$ADB" shell pkill getevent > /dev/null 2>&1 || true
        pkill -P "$$" -f 'adb.*shell getevent -lt /dev/input/event1' > /dev/null 2>&1 || true
        kill "$CAPTURE_PID" > /dev/null 2>&1 || true
        wait "$CAPTURE_PID" 2>/dev/null || true
        CAPTURE_PID=''
    fi
}
cleanup() {
    stop_capture
    gui_session_cleanup "${BUNDLE:-}"
    echo "getevent 紀錄：${EVENT_LOG}　Swift 測試紀錄：${TEST_LOG}　用戶端輸出：${CLIENT_LOG}　App log：${LOG}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo ""
echo "=== 第一段：Swift 活體測試（編碼器＋觸控路徑；觸控路徑期間擷取 getevent）==="
cd "${SCRIPT_DIR}/.." || exit 1
start_capture
MIRAGE_LIVE=1 MIRAGE_LIVE_REMOTE=1 MIRAGE_PORT="$GRPC_PORT" ANDROID_SERIAL="$SERIAL" \
    swift test --filter "RemoteVideoEncoderLiveTests|RemoteInputLiveTests" 2>&1 | tee "$TEST_LOG" | tail -5
assert_ok 'Swift 活體測試' "${PIPESTATUS[0]}"
stop_capture
# 必須看見各測試的 passed 完成行；零測試、skip 或名稱不符都要紅（打錯 env 名會變成永遠 skip）。
for test_name in emitsOneRewrittenAccessUnitPerFrameAndRecreatesOnResize invalidFrameThrowsBeforeCreatingSession remoteTouchReachesEmulatorThroughInputQueue; do
    grep -Eq "Test ${test_name}\\(\\) passed([[:space:]]|$)" "$TEST_LOG"
    assert_ok "${test_name} 確實 passed（不能 skip）" "$?"
done
read -r swift_downs swift_ups < <(touch_transition_count < "$EVENT_LOG")
assert_equals "S1 Swift 觸控路徑：沒有 slot 卡在 down" "$(touch_stuck_slots < "$EVENT_LOG" | tr '\n' ' ')" ""
assert_at_least "S2 Swift 觸控路徑：guest 收到按下" "$swift_downs" 1
assert_at_least "S2 Swift 觸控路徑：guest 收到放開" "$swift_ups" 1

echo ""
echo "=== 第二段：啟動遊戲：$PACKAGE ==="
"$ADB" -s "$SERIAL" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
sleep 8
FG=$("$ADB" -s "$SERIAL" shell dumpsys activity activities 2>/dev/null | grep topResumedActivity | tr -d '\r' | head -1)
case "$FG" in
  *"$PACKAGE"*) echo "✅ $PACKAGE 在前景" ;;
  *) echo "❌ $PACKAGE 不在前景——沒有會變化的畫面來源，R1 沒有意義。"; exit 1 ;;
esac

echo ""
echo "=== 第三段：以 .app bundle 啟動 Mirage，遙控自動開啟（埠 ${REMOTE_PORT}）==="
TOKEN=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
if ! gui_session_start "$LOG" "$BUNDLE" "" \
        "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_CONN_LOG=1" \
        "MIRAGE_REMOTE=1" "MIRAGE_REMOTE_PORT=$REMOTE_PORT" "MIRAGE_REMOTE_TOKEN=$TOKEN"; then
    exit 1
fi
LISTEN_LINE=""
for _ in $(seq 1 40); do
    LISTEN_LINE=$(grep '^\[remote\] listening port=' "$LOG" | tail -1)
    [ -n "$LISTEN_LINE" ] && break
    sleep 0.5
done
if [ -z "$LISTEN_LINE" ]; then
    echo "❌ 20 秒內 App 沒印 [remote] listening——遙控沒開起來。App log 前 20 行："
    head -20 "$LOG"
    grep '^\[remote\]' "$LOG" || true
    exit 1
fi
echo "   $LISTEN_LINE"
assert_equals "App 綁到指定的遙控埠" "$(printf '%s' "$LISTEN_LINE" | sed -n 's/.*port=\([0-9]*\).*/\1/p')" "$REMOTE_PORT"

echo ""
echo "=== 第四段：Python 用戶端連線，等 keyframe（上限 ${WAIT_KEYFRAME}s）、收 ${DURATION}s、送觸控 ==="
start_capture
"$PY" "${SCRIPT_DIR}/lib/remote_client.py" --host 127.0.0.1 --port "$REMOTE_PORT" --token "$TOKEN" \
    --wait-keyframe "$WAIT_KEYFRAME" --seconds "$DURATION" --touch 2>&1 | tee "$CLIENT_LOG"
CLIENT_RC=${PIPESTATUS[0]}
sleep 1
stop_capture
case "$CLIENT_RC" in
    0) ;;
    2) echo "❌ 用戶端連不上（見上方 CONNECT_ERROR）。token 或埠不對、或 server 拒絕。"; exit 1 ;;
    3) echo "❌ ${WAIT_KEYFRAME} 秒內沒有 keyframe。先分辨：App log 有沒有「幀 #」（畫面在動嗎）？"
       echo "   沒有 → 畫面靜止，環境的紅燈；有 → 編碼器或 server 沒送，看 App log 的 [remote] 行。"
       grep -c '幀 #' "$LOG" || true
       grep '^\[remote\]' "$LOG" || true
       exit 1 ;;
    *) echo "❌ 用戶端異常結束（退出碼 ${CLIENT_RC}）"; exit 1 ;;
esac
eval "$(grep -E '^[A-Z_]+=[0-9.]*$' "$CLIENT_LOG")"

echo ""
echo "===== 判定 ====="
# R1：`assert_at_most` 對空值視為 0 通過，所以先確認 KEYFRAME_SECONDS 有值（退出碼 0 已保證，再守一次）。
[ -n "${KEYFRAME_SECONDS:-}" ] || { echo "❌ R1 用戶端沒回報 KEYFRAME_SECONDS"; exit 1; }
assert_at_most "R1 第一個 keyframe 的秒數" "${KEYFRAME_SECONDS%%.*}" "$WAIT_KEYFRAME"
assert_at_least "R2 前置：收到的幀數" "${FRAMES:-0}" 2
assert_at_most "R2 幀序缺口" "${SEQ_GAPS:-0}" 0
assert_equals "R3 前置：三則觸控都送出" "${TOUCH_SENT:-0}" 3
assert_equals "R3 前置：ping 原封 echo" "${PING_ECHO_OK:-0}" 1
# R3 的兩條順序不能對調：觸點卡住會吃掉後續按下，先判卡住（guest-touch-state-via-getevent）。
assert_equals "R3 沒有 slot 卡在 down" "$(touch_stuck_slots < "$EVENT_LOG" | tr '\n' ' ')" ""
read -r downs ups < <(touch_transition_count < "$EVENT_LOG")
assert_at_least "R3 guest 收到按下（ABS_MT_TRACKING_ID）" "$downs" 1
assert_at_least "R3 guest 收到放開" "$ups" 1
echo "ping 往返：${PING_RTT_MS:-?} ms（loopback，只是工具健康度，不是手機的數字）"
echo "全部通過"
```

`chmod +x app/scripts/verify_remote_mirror.sh`。閘門 4 的 lint 會掃它：所有 `$var` 後接全形標點處都已用 `${var}`。

- [ ] **Step 6: `ci.sh` 閘門 8 加自我測試**

在 `app/scripts/ci.sh:415`（`host_ime_acceptance_test.py` 那段的 `fi` 之後）加：

```bash
# remote_client_selftest.py（2026-09-12，手機遙控）：標頭解析與幀序缺口算法決定 R1／R2 紅不紅，
# 純函式不需要 websockets 也不需要模擬器，用系統 python3 直接跑。
if python3 ./scripts/lib/remote_client_selftest.py > /dev/null 2>&1; then
    ok "remote_client.py 純函式自我測試通過"
else
    fail "remote_client.py 純函式自我測試失敗（重跑 python3 ./scripts/lib/remote_client_selftest.py 看細節）"
fi
```

Run: `cd /Users/hanfourhuang/Projects/mirage/app && bash -n scripts/verify_remote_mirror.sh scripts/lib/remote_venv.sh && python3 - <<'EOF'
import re, pathlib
pat = re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F\s]')
for p in ["scripts/verify_remote_mirror.sh", "scripts/lib/remote_venv.sh"]:
    for i, line in enumerate(pathlib.Path(p).read_text().splitlines(), 1):
        if not line.lstrip().startswith("#") and pat.search(line): print(p, i, line)
print("lint done")
EOF`
Expected: 沒有語法錯誤、lint 只印 `lint done`。

- [ ] **Step 7: 跑活體腳本**

前置：模擬器 `./scripts/emu.sh -n mirage-poc start`（console 5556／gRPC 8556），Pixel Flow 停在遊玩中畫面，螢幕未鎖定。

Run: `cd /Users/hanfourhuang/Projects/mirage/app && ./scripts/verify_remote_mirror.sh 2>&1 | tail -25`
Expected: 最後一行 `全部通過`，退出碼 0；S1／S2／R1／R2／R3 各行 ✅。

Run: `cd /Users/hanfourhuang/Projects/mirage/app && ./scripts/verify_remote_mirror.sh 2>&1 | tail -3`
Expected: 第二次也 `全部通過`（一跑是假設不是結論）。

- [ ] **Step 8: 故障注入——確認斷言會紅**

暫時把 `AppModel+Remote.swift` 的 `onTouches` 路徑弄壞是 `RemoteMirrorController` 的事，這裡注入更便宜的：把 `remote_client.py` 的 `touch_messages` 改成只回 `[down]`（拿掉 move／up）。

Run: `cd /Users/hanfourhuang/Projects/mirage/app && ./scripts/verify_remote_mirror.sh 2>&1 | grep -E "R3|❌" | head -5`
Expected: `❌ R3 前置：三則觸控都送出：實測 '1'，期待 '3'`，退出碼非 0。改回來之後再跑一次到 `全部通過`。

- [ ] **Step 9: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/Tests/MirageCoreTests/LiveGate.swift app/Tests/MirageCoreTests/Remote/RemoteInputLiveTests.swift app/scripts/lib/remote_client.py app/scripts/lib/remote_client_selftest.py app/scripts/lib/remote_venv.sh app/scripts/verify_remote_mirror.sh app/scripts/ci.sh && git commit -m "test: 手機遙控活體驗證：LiveGate.remote、觸控路徑活體測試、Python 用戶端與 verify_remote_mirror.sh"
```

---

### Task 9: 驗收線 7 對照（遙控開／關各兩次）與 README

**Files:**
- Modify: `app/scripts/verify_fps_fullscreen.sh:90-107,412-425,693-704`
- Create: `app/scripts/verify_remote_fps.sh`
- Modify: `app/README.md`（檔尾加一節）

**Interfaces:**
- Consumes: `verify_fps_fullscreen.sh` 的輸出行 `MIRAGE_MEDIAN=`、`MIRAGE_SPREAD=`、`ROUNDS=`（`:900-925`）與 `gui_session_start` 的環境變數參數；`remote_client.py --loop`；`RemoteLaunchOptions` 的三個環境變數。
- Produces：`verify_fps_fullscreen.sh -E KEY=VAL`（可重複）；`verify_remote_fps.sh` 退出碼 0＝「開的中位數 ≥ 關的中位數 − 3」且兩臂各有 ≥ 2 有效輪次。

判準（spec 第 8 節）：「開的時候中位數不低於關的時候 3 fps 以上」＝ `ON_MEDIAN ≥ OFF_MEDIAN − 3`。**兩臂交錯跑**（關、開、關、開）而不是先跑完一臂：主機負載隨時間漂移，交錯讓兩臂吃到同樣的漂移。每臂兩次呼叫的中位數取較低者（兩個值的中位數 = 較低者），並印值域；兩臂值域重疊超過 3 fps 時額外印警告——變異大於效應時單次量測沒有鑑別力，那不是通過也不是失敗。開的那一臂必須有 viewer 連著（沒有 viewer 編碼器不拉幀，量到的就是關的數字），由 `remote_client.py --loop` 在背景反覆重連。

- [ ] **Step 1: `verify_fps_fullscreen.sh` 加 `-E`**

`verify_fps_fullscreen.sh:90-91` 的 `QUEUE_DEPTH=""` 之後加：

```bash
# 額外傳給 App 的環境變數（可重複）。用途是對照量測：例如 -E MIRAGE_REMOTE=1 讓遙控開著量。
# bash 3.2 對空陣列的 "${EXTRA_ENV[@]}" 在 set -u 下會炸，展開一律用 ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}。
EXTRA_ENV=()
```

getopts（`:93`）的字串 `"s:p:g:r:d:l:F:hq:A"` 改成 `"s:p:g:r:d:l:F:hq:AE:"`，case 加一行 `E) EXTRA_ENV+=("$OPTARG") ;;`，用法字串加 `[-E KEY=VAL]`。

四處 `gui_session_start "$log" "$bundle" "" …`／`gui_session_start "$LOG" "$BUNDLE" "" …`（`:414-416`、`:420-422`、`:694-696`、`:700-701`）的參數尾端各加 `${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}`，例如 `:700-701` 變成：

```bash
            if ! gui_session_start "$LOG" "$BUNDLE" "" \
                    "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1" \
                    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}; then
```

Run: `cd /Users/hanfourhuang/Projects/mirage/app && bash -n scripts/verify_fps_fullscreen.sh && ./scripts/verify_fps_fullscreen.sh -h | head -3 && grep -c 'EXTRA_ENV\[@\]+' scripts/verify_fps_fullscreen.sh`
Expected: 無語法錯誤、用法印出、最後印 `4`。

- [ ] **Step 2: `verify_remote_fps.sh`**

```bash
#!/usr/bin/env bash
# 驗收線 7 對照（spec 第 8 節）：verify_fps_fullscreen.sh 在遙控關與開各跑兩次（交錯：關、開、關、開），
# 斷言「開的中位數 ≥ 關的中位數 − 3」。開的那一臂用 remote_client.py --loop 當 viewer，否則
# 編碼器不拉幀，量到的是關的數字。
#
# 用法：./scripts/verify_remote_fps.sh [-s serial] [-p grpc_port] [-g package] [-P remote_port] [-r rounds] [-d seconds]
# 前置同 verify_fps_fullscreen.sh（phase0/harness/.venv-d45、螢幕邏輯解析度、遊戲在會動的畫面）。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/verify_common.sh"
source "${SCRIPT_DIR}/lib/remote_venv.sh"

SERIAL="emulator-5556"
GRPC_PORT="8556"
PACKAGE="com.loomgames.pixelflow"
REMOTE_PORT=8765
ROUNDS=2
DURATION=20
TOLERANCE=3

while getopts "s:p:g:P:r:d:h" opt; do
  case "$opt" in
    s) SERIAL="$OPTARG" ;;
    p) GRPC_PORT="$OPTARG" ;;
    g) PACKAGE="$OPTARG" ;;
    P) REMOTE_PORT="$OPTARG" ;;
    r) ROUNDS="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    h) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "用法：$0 [-s serial] [-p grpc_port] [-g package] [-P remote_port] [-r rounds] [-d seconds]" >&2; exit 2 ;;
  esac
done
for v in REMOTE_PORT ROUNDS DURATION; do
  eval "val=\$${v}"
  case "$val" in ''|*[!0-9]*) echo "❌ ${v} 只接受正整數：實測 '${val}'。" >&2; exit 2 ;; esac
done

PY=$(remote_venv_python) || exit 1
TOKEN=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 32)
VIEWER_PID=''
stop_viewer() {
    if [ -n "$VIEWER_PID" ]; then
        kill "$VIEWER_PID" > /dev/null 2>&1 || true
        wait "$VIEWER_PID" 2>/dev/null || true
        VIEWER_PID=''
    fi
}
trap stop_viewer EXIT

# 每臂一次呼叫；輸出存檔，只抓 MIRAGE_MEDIAN／MIRAGE_SPREAD／ROUNDS。
# 底下那支腳本的 ≥55 判定與本對照無關（它會紅是既有事實），這裡不看它的退出碼，只看有無有效輪數。
run_arm() {
    local arm="$1" out
    out=$(mktemp -t mirage_remote_fps_"$arm")
    if [ "$arm" = "on" ]; then
        "$SCRIPT_DIR/verify_fps_fullscreen.sh" -s "$SERIAL" -p "$GRPC_PORT" -g "$PACKAGE" -r "$ROUNDS" -d "$DURATION" \
            -E "MIRAGE_REMOTE=1" -E "MIRAGE_REMOTE_PORT=$REMOTE_PORT" -E "MIRAGE_REMOTE_TOKEN=$TOKEN" > "$out" 2>&1
    else
        "$SCRIPT_DIR/verify_fps_fullscreen.sh" -s "$SERIAL" -p "$GRPC_PORT" -g "$PACKAGE" -r "$ROUNDS" -d "$DURATION" > "$out" 2>&1
    fi
    local rc=$?
    local median rounds spread
    median=$(sed -n 's/^MIRAGE_MEDIAN=\([0-9]*\)$/\1/p' "$out" | tail -1)
    rounds=$(sed -n 's/^ROUNDS=\([0-9]*\)$/\1/p' "$out" | tail -1)
    spread=$(sed -n 's/^MIRAGE_SPREAD=//p' "$out" | tail -1)
    echo "[arm=${arm}] median=${median:-無資料} rounds=${rounds:-0} spread=${spread:-無資料} fps_script_rc=${rc} log=${out}"
    ARM_MEDIAN="$median"
    ARM_ROUNDS="${rounds:-0}"
}

OFF_VALS=""
ON_VALS=""
OFF_ROUNDS=0
ON_ROUNDS=0
for pass in 1 2; do
    echo ""
    echo "=== 第 ${pass}/2 對：遙控關 ==="
    run_arm off
    [ -n "$ARM_MEDIAN" ] && OFF_VALS="${OFF_VALS}${ARM_MEDIAN}\n"
    OFF_ROUNDS=$((OFF_ROUNDS + ARM_ROUNDS))

    echo ""
    echo "=== 第 ${pass}/2 對：遙控開（背景 viewer 反覆重連 127.0.0.1:${REMOTE_PORT}）==="
    "$PY" "${SCRIPT_DIR}/lib/remote_client.py" --host 127.0.0.1 --port "$REMOTE_PORT" --token "$TOKEN" --loop &
    VIEWER_PID=$!
    run_arm on
    stop_viewer
    [ -n "$ARM_MEDIAN" ] && ON_VALS="${ON_VALS}${ARM_MEDIAN}\n"
    ON_ROUNDS=$((ON_ROUNDS + ARM_ROUNDS))
done

# 兩個值的中位數 = 較低者；沒有樣本時印空字串，不印 0（0 是合法的量測值）。
median_of() { printf "%b" "$1" | grep -v '^$' | sort -n | awk '{ v[NR]=$1 } END { if (NR) printf "%d\n", v[int((NR+1)/2)] }'; }
list_of()   { printf "%b" "$1" | grep -v '^$' | sort -n | tr '\n' ' ' | sed 's/ $//'; }
min_of()    { printf "%b" "$1" | grep -v '^$' | sort -n | head -1; }
max_of()    { printf "%b" "$1" | grep -v '^$' | sort -n | tail -1; }

OFF_MEDIAN=$(median_of "$OFF_VALS")
ON_MEDIAN=$(median_of "$ON_VALS")
echo ""
echo "===== 解析結果 ====="
echo "OFF_VALUES=$(list_of "$OFF_VALS")"
echo "ON_VALUES=$(list_of "$ON_VALS")"
echo "OFF_MEDIAN=${OFF_MEDIAN:-無資料}"
echo "ON_MEDIAN=${ON_MEDIAN:-無資料}"
echo "OFF_ROUNDS=${OFF_ROUNDS}"
echo "ON_ROUNDS=${ON_ROUNDS}"

echo ""
echo "===== 判定 ====="
assert_at_least "前置：遙控關的有效輪數" "$OFF_ROUNDS" 2
assert_at_least "前置：遙控開的有效輪數" "$ON_ROUNDS" 2
[ -n "$OFF_MEDIAN" ] && [ -n "$ON_MEDIAN" ] || { echo "❌ 有一臂沒有中位數，無法比較"; exit 1; }
if [ -n "$(min_of "$ON_VALS")" ] && [ "$(max_of "$ON_VALS")" -ge $(( $(min_of "$OFF_VALS") - TOLERANCE )) ] \
        && [ "$(min_of "$ON_VALS")" -lt $(( $(max_of "$OFF_VALS") - TOLERANCE )) ]; then
    echo "⚠️ 兩臂值域重疊超過 ${TOLERANCE} fps（關 $(list_of "$OFF_VALS")／開 $(list_of "$ON_VALS")）："
    echo "   變異大於效應，這次量測分不出遙控有沒有拖慢；下面的判定只代表這次抽樣，加輪數重跑（-r 4）。"
fi
assert_at_least "驗收線 7 對照：遙控開的中位數 ≥ 關的中位數 − ${TOLERANCE}" "$ON_MEDIAN" $((OFF_MEDIAN - TOLERANCE))
echo "全部通過"
```

`chmod +x app/scripts/verify_remote_fps.sh`。

Run: `cd /Users/hanfourhuang/Projects/mirage/app && bash -n scripts/verify_remote_fps.sh && ./scripts/verify_remote_fps.sh -h`
Expected: 無語法錯誤、印出用法。

- [ ] **Step 3: 跑對照（機器安靜時；約 8 到 12 分鐘）**

前置：`load_sentinel` 與外來 CPU 閘門會自己擋；先關聊天 app（記憶「主機背景工作會擋住量測」）。

Run: `cd /Users/hanfourhuang/Projects/mirage/app && ./scripts/verify_remote_fps.sh 2>&1 | tail -15`
Expected：`OFF_VALUES`／`ON_VALUES` 各兩個數字、`全部通過`。若印 ⚠️ 值域重疊，加 `-r 4` 重跑一次再下結論；若 `❌ 驗收線 7 對照`，把四個數字與兩臂 log 路徑原樣記進 commit 訊息與 README——這是產品的紅燈，不是腳本的。

- [ ] **Step 4: README**

`app/README.md` 檔尾加：

```markdown
## 手機遙控（區域網路）

iPhone Safari 當 Mirage 的觸控第二螢幕：Mac 端 VideoToolbox 硬體編碼 H.264、WebSocket 送到手機的
`VideoDecoder`，手機觸控走既有的 `InputQueue`。設計見
[設計文件](../docs/specs/2026-09-12-lan-remote-control-design.md)；第一版只支援 iPhone（Android Chrome 要 HTTPS）。

- **開啟**：選單列 🪞 →「手機遙控 ▸」→「開啟手機遙控」。子選單顯示狀態、每個本機 IPv4 的網址
  （點一下複製）與第一個網址的 QR；手機掃 QR 或輸入網址。「中斷連線」會作廢 token 並產生新網址；
  「關閉手機遙控」回到原本的幀路徑（關閉時 `AppModel.activeSink` 就是 `box`，行為零改變）。
  開啟與關閉各重啟一次 emulator 連線（約 1 秒的橫幅），中斷連線不會。
- **有手機連著時關 Mac 視窗**：只隱藏、不 suspend，串流繼續（`AppLifecycle.windowShouldClose` 的
  `hasActiveRemoteViewer` guard，預設 `{ false }`）。
- **錯誤**：埠被佔用或 `VTCompressionSession` 建不起來（本機沒有硬體編碼器）時子選單顯示
  「錯誤：…」，功能維持關閉，不退回軟體編碼。
- **環境變數（只給腳本）**：`MIRAGE_REMOTE=1` 啟動即開、`MIRAGE_REMOTE_PORT`（預設 8765）、
  `MIRAGE_REMOTE_TOKEN`（32 個小寫十六進位；不合法就忽略）。開啟時印
  `[remote] listening port=<埠> url=<網址>`。
- **活體驗證**：`./scripts/verify_remote_mirror.sh`（`-P` 換埠）——先跑兩條 Swift 活體測試
  （`MIRAGE_LIVE=1 MIRAGE_LIVE_REMOTE=1`：硬體編碼器＋SPS 改寫、server → InputQueue → 模擬器），
  再以 `.app` 啟動、用 `scripts/lib/remote_client.py`（venv `scripts/.venv-remote`，腳本自建）
  斷言 60 秒內收到 keyframe、幀序連續、一組 down/move/up 後 guest 的 getevent 出現
  `ABS_MT_TRACKING_ID` 且沒有 slot 卡住。畫面靜止時 R1 會紅，那是環境不是產品。
- **驗收線 7 對照**：`./scripts/verify_remote_fps.sh`——`verify_fps_fullscreen.sh` 遙控關／開交錯各兩次
  （開的那臂由 `remote_client.py --loop` 當 viewer），斷言開的中位數 ≥ 關的中位數 − 3；兩臂值域重疊時
  印警告要求加輪數。實測數字：（執行 Step 3 後填入 OFF_VALUES／ON_VALUES 與日期）。
- **人工（階段 E，未做）**：iPhone 實機的 glass-to-glass 量測，門檻 50 ms，敏感度往兩側試。
```

把 Step 3 的實測數字填進「實測數字」那一行（四個值、日期、有無警告）。

- [ ] **Step 5: 全套閘門**

Run: `cd /Users/hanfourhuang/Projects/mirage/app && ./scripts/ci.sh 2>&1 | tail -6`
Expected: `全部通過（…）`，退出碼 0。

- [ ] **Step 6: Commit**

```bash
cd /Users/hanfourhuang/Projects/mirage && git add app/scripts/verify_fps_fullscreen.sh app/scripts/verify_remote_fps.sh app/README.md && git commit -m "test: 驗收線 7 對照腳本（遙控關／開各兩次）與手機遙控 README"
```

---

## Self-Review

**1. Spec coverage（第 3、5、6、7、8、9 節對本計畫的要求）**

| spec | 落點 |
|---|---|
| 第 3 節 `RemoteVideoEncoder`：VT 封裝、RGBA→CVPixelBuffer→Annex-B、尺寸變更重建並重送 SPS/PPS、PTS 用 `receivedAt`、低延遲設定 | Task 1、2（`replaceSessionLocked` 重置 packer，新 session 第一幀是 IDR 帶新參數集） |
| 第 3 節 `RemoteMirrorController`：30 fps 拉取、餵編碼器、封包送 server、觸控轉 `inputQueue.touches` | Task 3 |
| 第 3 節 `AppModel+Remote`：建 `BroadcastFrameSink`、啟停 server 與 controller、網址與配對狀態 | Task 7 |
| 第 3 節 `AppLifecycle` guard，預設 `{ false }` | Task 4 |
| 第 3 節選單：開啟／關閉、網址與 QR、中斷連線 | Task 5、6、7 |
| 第 5 節：關閉或中斷時 token 作廢、重開產生新的；監聽所有介面 | Task 7（`disableRemote` 隨 controller 作廢；`disconnectRemoteViewer` 換新 controller／新 token；`RemoteMirrorConfiguration.host` 預設 `allInterfaces`） |
| 第 6 節：手機連著關視窗不 suspend；手機斷線編碼器停止拉取、token 保留可重連；尺寸隨 Mac 視窗變動、重建 session | Task 4；Task 3 的 `hasVideo` guard；Task 2 |
| 第 7 節：埠被佔用顯示錯誤與埠號、功能關閉；VT 建立失敗顯示錯誤碼、不退軟體編碼 | Task 7（`.failed("埠 N 無法監聽：…")`、`failRemote` 經 `onError` 帶 `RemoteVideoEncoderError.sessionCreation(OSStatus)` 的描述） |
| 第 8 節活體：`verify_remote_mirror.sh`（`MIRAGE_LIVE=1 MIRAGE_LIVE_REMOTE=1`）三條斷言、`getevent_touch.sh` | Task 8 |
| 第 8 節驗收線 7 不劣化：開／關各兩次、開 ≥ 關 − 3 | Task 9 |
| 第 9 節階段 C 驗證：餵合成幀、SPS 含 VUI、每幀一個存取單元 | Task 2 的 `RemoteVideoEncoderLiveTests` |
| 任務簡報：QR 不引入依賴、放選單或小視窗擇一並寫理由 | 設計決定 4、Task 5、6 |
| 任務簡報：venv 自建於 `app/scripts/.venv-remote` 並在 `.gitignore` | Task 8（既有 `.venv*/` 涵蓋，用 `git check-ignore` 驗證而非重複加行） |

沒有找到缺口。spec 第 4 節手機端頁面、第 5 節 403／409 是階段 B 已完成的部分。

**2. Placeholder scan**：全文搜過 TBD／TODO／「稍後」／「適當的錯誤處理」／「參考 Task」——只有 README 的「（執行 Step 3 後填入…）」是刻意留給量測結果的位置，Step 4 已寫明填法。每個程式碼步驟都有完整程式碼。

**3. Type consistency**：
- `RemoteFrameEncoding`（Task 2 定義）的三個方法與 Task 3 的 `FakeEncoder`、`RemoteMirrorController` 呼叫一致。
- `RemoteMirrorController.init(configuration:secondary:inputQueue:makeEncoder:onError:onStateChanged:)` 與 Task 7 `makeRemoteController` 的呼叫一致；`secondary`／`token`／`boundPort`／`sessionState` 在 Task 7 測試中使用。
- `RemoteMenuState`／`RemoteMenuEntry`／`RemoteMenu.entries` 在 Task 6 定義、Task 7 `setupRemoteMenu` 與 `remoteMenuState` 使用；`MenuBarController.populate(remoteMenu:entries:target:toggleAction:copyAction:disconnectAction:qrImage:)` 在 Task 6 測試與 `menuNeedsUpdate` 兩處簽章相同。
- `LifecyclePolicy.didHide(remoteViewerActive:) -> Bool` 與 `AppLifecycle.windowShouldClose` 的 `if policy.didHide(remoteViewerActive:)` 一致。
- `RemoteLaunchOptions.parse` 回 `port`／`token`／`problems`，`AppModel.start()` 讀的是這三個。
- `RGBAPixelBufferError.invalidFrame` 在 Task 1 測試與 Task 2 `invalidFrameThrowsBeforeCreatingSession` 的 `.pixelBuffer(.invalidFrame)` 一致。
- 修正過的一處：`RemoteVideoEncoder.sessionSize` 原本是有標籤的 tuple，與 `(frame.width, frame.height)` 比較會有標籤不符的風險，已改成無標籤。
