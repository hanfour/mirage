# Streaming MMAP Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓 `streamScreenshot` 走共享記憶體（MMAP `ImageTransport`）取代 raw RGBA protobuf payload，消滅每幀約 8 ms 的 client CPU 與 220–272 MiB/s 的序列化流量。

**Architecture:** 版本字串由既有 `HealthProbe`（已在打 `getStatus`）帶出，不新增 RPC。`MmapVersionGate` 過關就用 `FallbackTransport(primary: MmapStreamTransport, secondary: GrpcStreamTransport)`。降級判定必須在**串流路徑**上——前 3 幀全零即丟 `.mmapUnusable`，由組合器無縫換到 raw RGBA。只對 `.mmapUnusable` 降級，`.unavailable` 是斷線必須照常傳播。

**Tech Stack:** Swift 6 toolchain（`.swiftLanguageMode(.v5)`）、grpc-swift 1.27.5、swift-atomics 1.3.1、Darwin `mmap`/`munmap`/`unlink`、swift-testing。

**設計依據：** `docs/specs/2026-07-27-mmap-stream-transport-design.md`（authoritative）。

## Global Constraints

- 平台 macOS 14+ Apple Silicon；`swift build -c release` 零非-deprecation 警告
- **MirageCore 不得 import AppKit / SwiftUI / Metal / AVFoundation**（本階段需 `Darwin` 的 `mmap`/`munmap`/`unlink`，屬系統層非 UI 層，允許）；不 `fatalError`
- `-strict-concurrency=complete`；`.swiftLanguageMode(.v5)`
- 測試語法用 swift-testing（`@Suite` / `@Test` / `#expect`），非 XCTest
- 每檔 <400 行、函式 <50 行；不可變優先
- TDD：先寫失敗測試 → 執行確認失敗 → 最小實作 → 綠 → commit
- Conventional commits，**不得含任何 attribution / Co-Authored-By**
- 既有 **137 個 `@Test`** 不得回歸
- 活體測試預設 skip；所有 adb 一律 `ANDROID_SERIAL=emulator-5554`
- 工作目錄一律 `app/`（`swift build` / `swift test` 都在此執行）
- **不改既有 `GrpcStreamTransport`**（它成為 fallback 的 secondary）
- **不改 `Frame` / `LatestFrameBox` / `Renderer`**
- **不放寬版本閘**（維持 ≥37）

## 環境地雷（動手前必讀）

- `localhost:8554` 的模擬器是**共享資源**且正在跑（canary 37.2.1.0）。**不要殺它、不要重啟、絕對不要 `loadSnapshot`**（實測會使其崩潰）。
- 活體測試需要 guest 畫面在**變動**才會出幀（`streamScreenshot` 是變化驅動）。`phase0/harness/animate.py` 可供應動畫，但它需要 `phase0/harness/requirements.txt` 的 Python 環境（本機系統 python 的 protobuf 版本過舊，需另建 venv）。
- **模擬器剛重開後**跑完整 live 套件有機率死鎖（既有 NIO teardown 架構債，見 `RESULTS-p1e.md`）。本計畫的測試設計刻意避開強制 `dropChannel` 的路徑。

---

## File Structure

新增（全部放 `Sources/MirageCore/` 根目錄——既有 `DisplayTransport.swift`／`GrpcStreamTransport.swift`／`UnaryMmapTransport.swift` 都在那裡，不另開子目錄以免與既有配置不一致）：

| 檔案 | 職責 |
|---|---|
| `Sources/MirageCore/MmapSupport.swift` | 純函式：唯一 handle 路徑產生、`file://` URL 組裝、全零判定 |
| `Sources/MirageCore/MmapBuffer.swift` | `mmap` 生命週期包裝：建檔→映射→讀取→`munmap`/`close`/`unlink` |
| `Sources/MirageCore/MmapStreamTransport.swift` | `streamScreenshot` + MMAP 的 `DisplayTransport` 實作 |
| `Sources/MirageCore/FallbackTransport.swift` | 組合器：primary 丟 `.mmapUnusable` 時無縫換 secondary |
| `Tests/MirageCoreTests/MmapSupportTests.swift` | Task 1 |
| `Tests/MirageCoreTests/MmapBufferTests.swift` | Task 2 |
| `Tests/MirageCoreTests/FallbackTransportTests.swift` | Task 3 |
| `Tests/MirageCoreTests/MmapStreamLiveTests.swift` | Task 8（`MIRAGE_LIVE_MMAP`） |
| `app/RESULTS-mmap.md` | Task 9 驗收紀錄 |

修改：

| 檔案 | 改動 |
|---|---|
| `Sources/MirageCore/DisplayTransport.swift` | `TransportError` 新增 `.mmapUnusable(String)` |
| `Sources/MirageCore/Lifecycle/HealthProbe.swift` | `HealthResult.healthy` → `.healthy(version: String)` |
| `Sources/MirageCore/EmulatorClient.swift` | 解構 `.healthy(version:)`、快取版本、`ensureChannel()` 依版本選 transport、一次性觀測訊息 |
| `Tests/MirageCoreTests/HealthProbeTests.swift` | `ScriptedProbe` 與 3 處斷言跟著 enum 改 |
| `Tests/MirageCoreTests/EmulatorClientReconnectTests.swift` | 2 處 `.healthy` 字面量 |
| `Tests/MirageCoreTests/EmulatorClientAudioTests.swift` | `SlowFirstProbe` 的回傳值 |
| `app/README.md` | transport 選擇邏輯與觀測訊息 |

刪除：

| 檔案 | 理由 |
|---|---|
| `Sources/MirageCore/UnaryMmapTransport.swift` | 被 `MmapStreamTransport` 完全取代（`MmapVersionGate` 移到 `MmapSupport.swift` 保留） |

---

## Task 1: MmapSupport（純函式）

**Files:**
- Create: `app/Sources/MirageCore/MmapSupport.swift`
- Test: `app/Tests/MirageCoreTests/MmapSupportTests.swift`

**Interfaces:**
- Consumes: 無
- Produces:
  - `public enum MmapSupport { public static func handlePath(tempDir: String, pid: Int32, seq: Int, width: Int, height: Int) -> String; public static func handleURL(path: String) -> String; public static func isBlank(_ data: Data) -> Bool; public static func byteCount(width: Int, height: Int) -> Int }`
  - `public enum MmapVersionGate { public static func allows(versionString: String) -> Bool }`（**從 `UnaryMmapTransport.swift` 原樣搬過來**，Task 7 才刪原檔）

- [ ] **Step 1: 寫失敗測試**

建立 `app/Tests/MirageCoreTests/MmapSupportTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

@Suite struct MmapSupportTests {
    @Test func handlePathIsUniquePerSeq() {
        let a = MmapSupport.handlePath(tempDir: "/tmp/", pid: 42, seq: 1, width: 900, height: 2000)
        let b = MmapSupport.handlePath(tempDir: "/tmp/", pid: 42, seq: 2, width: 900, height: 2000)
        #expect(a != b)
    }

    /// 多開時不同行程不得撞路徑。
    @Test func handlePathIsUniquePerProcess() {
        let a = MmapSupport.handlePath(tempDir: "/tmp/", pid: 1, seq: 1, width: 900, height: 2000)
        let b = MmapSupport.handlePath(tempDir: "/tmp/", pid: 2, seq: 1, width: 900, height: 2000)
        #expect(a != b)
    }

    /// 路徑必須含 mirage_mmap_ 前綴——驗收線 6 靠這個前綴檢查 /tmp 殘留。
    @Test func handlePathCarriesRecognisablePrefix() {
        let p = MmapSupport.handlePath(tempDir: "/tmp/", pid: 42, seq: 1, width: 900, height: 2000)
        #expect(p.hasPrefix("/tmp/mirage_mmap_"))
        #expect(p.hasSuffix(".bin"))
    }

    @Test func tempDirWithoutTrailingSlashStillProducesValidPath() {
        let p = MmapSupport.handlePath(tempDir: "/tmp", pid: 42, seq: 1, width: 900, height: 2000)
        #expect(p.hasPrefix("/tmp/mirage_mmap_"))
        #expect(!p.contains("//"))
    }

    @Test func handleURLPrefixesFileScheme() {
        #expect(MmapSupport.handleURL(path: "/tmp/x.bin") == "file:///tmp/x.bin")
    }

    @Test func byteCountIsRGBA8888() {
        #expect(MmapSupport.byteCount(width: 900, height: 2000) == 900 * 2000 * 4)
        #expect(MmapSupport.byteCount(width: 0, height: 100) == 0)
        #expect(MmapSupport.byteCount(width: -1, height: 100) == 0)
    }

    @Test func isBlankDetectsAllZero() {
        #expect(MmapSupport.isBlank(Data(count: 1024)))
    }

    @Test func isBlankIsFalseWhenAnyByteIsNonZero() {
        var d = Data(count: 1024)
        d[1023] = 1                      // 最後一個 byte——確認掃描是完整的、不是只看開頭
        #expect(!MmapSupport.isBlank(d))
    }

    @Test func emptyDataIsBlank() {
        #expect(MmapSupport.isBlank(Data()))
    }

    @Test(arguments: ["36.6.11.0", "", "abc", "unknown.1"])
    func versionGateRejects(version: String) {
        #expect(!MmapVersionGate.allows(versionString: version))
    }

    @Test(arguments: ["37.2.1.0", "38.0.0", "40.1"])
    func versionGateAllows(version: String) {
        #expect(MmapVersionGate.allows(versionString: version))
    }
}
```

- [ ] **Step 2: 執行確認失敗**

Run: `cd app && swift test --filter MmapSupportTests`
Expected: 編譯失敗，`cannot find 'MmapSupport' in scope`。

- [ ] **Step 3: 最小實作**

建立 `app/Sources/MirageCore/MmapSupport.swift`：

```swift
import Foundation

/// MMAP 傳輸的純函式支援：路徑產生、handle 組裝、全零判定。
/// 全部無副作用、無 I/O，故可完整單元測試。
public enum MmapSupport {
    /// RGBA8888 的緩衝區位元組數。任一維度 <= 0 → 0（呼叫端據此拒絕掛載）。
    public static func byteCount(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        return width * height * 4
    }

    /// 每次掛載都用**唯一**路徑。
    ///
    /// 理由（上游 b/537802959）：伺服器端的 pre-borrow 會依 handle 快取共享記憶體區塊，
    /// 而該 bug 正是「用 0 大小 borrow 並毒化 cache」。換新路徑就沒有任何殘留狀態的疑慮，
    /// 同時避免舊檔殘留，多開時也天然不衝突。
    public static func handlePath(tempDir: String, pid: Int32, seq: Int,
                                  width: Int, height: Int) -> String {
        let base = tempDir.hasSuffix("/") ? String(tempDir.dropLast()) : tempDir
        return "\(base)/mirage_mmap_\(pid)_\(seq)_\(width)x\(height).bin"
    }

    /// proto 的 `ImageTransport.handle` 需要 `file://` scheme。
    public static func handleURL(path: String) -> String { "file://\(path)" }

    /// 全零判定——降級決策的依據（前 3 幀皆 blank 即判定 MMAP 不可用）。
    ///
    /// **完整掃描，不取樣**：一次 7.2 MB、最多做 3 次，是一次性成本，換取判定不會因
    /// 取樣點恰好落在畫面的黑色區域而誤判。判定完成後這條檢查不再執行，穩態零開銷。
    public static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0 }
    }
}

/// MMAP 版本安全閘：穩定版 emulator（36.x）收到 MMAP 請求會 SIGSEGV
/// （phase0/RESULTS-0b.md，2/2 確定性重現），主版號 ≥37 才允許。解析失敗一律拒絕。
///
/// 上游根因（b/537802959）揭露 36.x 的崩潰**可能**也只是同一個 0×0 pre-borrow、送明確
/// 尺寸就不會炸——但我們沒有證據，而驗證代價是故意炸掉一台使用者的 VM。維持 ≥37。
public enum MmapVersionGate {
    public static func allows(versionString: String) -> Bool {
        guard let major = versionString.split(separator: ".").first,
              let n = Int(major) else { return false }
        return n >= 37
    }
}
```

- [ ] **Step 4: 處理與既有 `MmapVersionGate` 的重複宣告**

`MmapVersionGate` 此刻同時存在於新檔與 `Sources/MirageCore/UnaryMmapTransport.swift`，會編譯失敗（invalid redeclaration）。

**從 `UnaryMmapTransport.swift` 刪除 `MmapVersionGate` 那一段**（該檔的 `enum MmapVersionGate { ... }` 整塊，連同其上方註解），保留 `UnaryMmapTransport` 本體不動——整檔的刪除留到 Task 7。

- [ ] **Step 5: 執行確認通過**

Run: `cd app && swift test --filter "MmapSupportTests|MmapVersionGateTests"`
Expected: PASS。既有的 `MmapVersionGateTests` 也必須仍然全綠（它測的是同一個型別，只是換了檔案位置）。

- [ ] **Step 6: 確認逐行 100% 覆蓋**

Run: `cd app && swift test --filter MmapSupportTests --enable-code-coverage && xcrun llvm-cov report .build/debug/MiragePackageTests.xctest/Contents/MacOS/MiragePackageTests -instr-profile .build/debug/codecov/default.profdata 2>/dev/null | grep MmapSupport`
Expected: `MmapSupport.swift` line coverage `100.00%`。未達則補測試，不改實作。

- [ ] **Step 7: Commit**

```bash
cd app && git add Sources/MirageCore/MmapSupport.swift Sources/MirageCore/UnaryMmapTransport.swift Tests/MirageCoreTests/MmapSupportTests.swift
git commit -m "feat: MmapSupport 純函式（路徑/handle/全零判定）與 MmapVersionGate 搬遷"
```

---

## Task 2: MmapBuffer（mmap 生命週期包裝）

**Files:**
- Create: `app/Sources/MirageCore/MmapBuffer.swift`
- Test: `app/Tests/MirageCoreTests/MmapBufferTests.swift`

**Interfaces:**
- Consumes: `MmapSupport.byteCount(width:height:)`、`MmapSupport.handlePath(...)`（Task 1）
- Produces:
  - `public final class MmapBuffer: @unchecked Sendable`
    - `public init?(path: String, byteCount: Int)`（建檔＋映射，任一步失敗回 nil）
    - `public let path: String`
    - `public func snapshot() -> Data`（**複製**出當前內容）
    - `public func close()`（`munmap` + `close(fd)` + `unlink`，冪等）

> **這個 type 是可以單元測試的**——`mmap` 一個臨時檔不需要模擬器。測試從外部寫檔、經映射讀回，即可驗證整條路徑。

- [ ] **Step 1: 寫失敗測試**

建立 `app/Tests/MirageCoreTests/MmapBufferTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

@Suite struct MmapBufferTests {
    private func tempPath(_ tag: String) -> String {
        MmapSupport.handlePath(tempDir: NSTemporaryDirectory(), pid: getpid(),
                               seq: abs(tag.hashValue % 100_000), width: 4, height: 2)
    }

    @Test func createsFileOfRequestedSize() throws {
        let path = tempPath("size")
        let buf = try #require(MmapBuffer(path: path, byteCount: 32))
        defer { buf.close() }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.size] as? Int) == 32)
    }

    @Test func snapshotStartsAllZero() throws {
        let buf = try #require(MmapBuffer(path: tempPath("zero"), byteCount: 64))
        defer { buf.close() }
        #expect(MmapSupport.isBlank(buf.snapshot()))
    }

    /// 核心行為：外部（模擬 emulator）寫入檔案後，經映射讀得到新內容。
    @Test func snapshotSeesExternalWrites() throws {
        let path = tempPath("write")
        let buf = try #require(MmapBuffer(path: path, byteCount: 8))
        defer { buf.close() }
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.write(contentsOf: Data([1, 2, 3, 4, 5, 6, 7, 8]))
        try fh.close()
        #expect(Array(buf.snapshot()) == [1, 2, 3, 4, 5, 6, 7, 8])
    }

    /// snapshot 必須是**複製**——回傳後即使映射區再被改寫，先前拿到的 Data 不得跟著變。
    /// 這正是「複製是正確性所必需」的形式化：Renderer 在 vsync 讀舊幀時不能被覆寫。
    @Test func snapshotIsACopyNotAView() throws {
        let path = tempPath("copy")
        let buf = try #require(MmapBuffer(path: path, byteCount: 4))
        defer { buf.close() }
        let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try fh.write(contentsOf: Data([9, 9, 9, 9]))
        let first = buf.snapshot()
        try fh.seek(toOffset: 0)
        try fh.write(contentsOf: Data([1, 1, 1, 1]))
        try fh.close()
        #expect(Array(first) == [9, 9, 9, 9])       // 舊快照不受影響
        #expect(Array(buf.snapshot()) == [1, 1, 1, 1])
    }

    @Test func closeUnlinksTheFile() throws {
        let path = tempPath("unlink")
        let buf = try #require(MmapBuffer(path: path, byteCount: 16))
        #expect(FileManager.default.fileExists(atPath: path))
        buf.close()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func closeIsIdempotent() throws {
        let buf = try #require(MmapBuffer(path: tempPath("idem"), byteCount: 16))
        buf.close()
        buf.close()                                  // 不得崩潰
    }

    @Test func zeroByteCountIsRejected() {
        #expect(MmapBuffer(path: tempPath("zerolen"), byteCount: 0) == nil)
    }

    @Test func unwritablePathIsRejected() {
        #expect(MmapBuffer(path: "/this/does/not/exist/x.bin", byteCount: 16) == nil)
    }
}
```

- [ ] **Step 2: 執行確認失敗**

Run: `cd app && swift test --filter MmapBufferTests`
Expected: 編譯失敗，`cannot find 'MmapBuffer' in scope`。

- [ ] **Step 3: 最小實作**

建立 `app/Sources/MirageCore/MmapBuffer.swift`：

```swift
import Darwin
import Foundation

/// 一塊由 emulator 寫入、由我們唯讀映射的共享緩衝區。
///
/// `@unchecked Sendable`：內部持有裸指標與 fd，以 `NSLock` 保護（比照既有
/// `GrpcChannelBox`／`GrpcAudioTransport` 的慣例）。不使用 `nonisolated(unsafe)`。
public final class MmapBuffer: @unchecked Sendable {
    public let path: String
    private let byteCount: Int
    private let lock = NSLock()
    private var fd: Int32
    private var base: UnsafeMutableRawPointer?

    /// 建檔（截成指定大小）→ 唯讀映射。任一步失敗回 nil，呼叫端據此降級，不崩。
    public init?(path: String, byteCount: Int) {
        guard byteCount > 0 else { return nil }
        let opened = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard opened >= 0 else { return nil }
        guard ftruncate(opened, off_t(byteCount)) == 0 else {
            close(opened); unlink(path); return nil
        }
        guard let mapped = mmap(nil, byteCount, PROT_READ, MAP_SHARED, opened, 0),
              mapped != MAP_FAILED else {
            close(opened); unlink(path); return nil
        }
        self.path = path
        self.byteCount = byteCount
        self.fd = opened
        self.base = mapped
    }

    deinit { close() }

    /// 把當前映射內容**複製**出來。
    ///
    /// **複製是正確性所必需，不是可以優化掉的浪費**：emulator 會原地覆寫這塊區域來寫
    /// 下一幀，而 `LatestFrameBox` 持有最新幀、`Renderer` 要到 vsync 才讀。若回傳指向
    /// 映射區的 view（`Data(bytesNoCopy:)`），渲染器會讀到正在被覆寫的記憶體 → 撕裂畫面。
    /// 已量化：複製只值 0.2 ms/幀（見 spec §1.1），拿它換正確性極為划算。
    public func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let base else { return Data() }
        return Data(bytes: base, count: byteCount)
    }

    /// `munmap` + `close(fd)` + `unlink`。冪等——重複呼叫不得崩潰。
    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let base {
            munmap(base, byteCount)
            self.base = nil
        }
        if fd >= 0 {
            Darwin.close(fd)
            unlink(path)          // 不檢查回傳值：檔案殘留可容忍，中斷流程不可
            fd = -1
        }
    }
}
```

- [ ] **Step 4: 執行確認通過**

Run: `cd app && swift test --filter MmapBufferTests`
Expected: PASS，9 個測項全綠。

- [ ] **Step 5: 確認無 /tmp 殘留**

Run: `ls /tmp/mirage_mmap_* 2>/dev/null | wc -l`
Expected: `0`。若非 0，代表 `close()` 的 `unlink` 沒生效或某條測試路徑漏了 `defer { buf.close() }`——修正後重跑。

- [ ] **Step 6: Commit**

```bash
cd app && git add Sources/MirageCore/MmapBuffer.swift Tests/MirageCoreTests/MmapBufferTests.swift
git commit -m "feat: MmapBuffer——mmap 建立/唯讀映射/快照複製/close 時 unlink

snapshot() 刻意回傳複製而非 view：emulator 原地覆寫同一塊區域寫下一幀，
Renderer 在 vsync 才讀，直接指向映射區會讀到撕裂畫面。已量化複製只值
0.2ms/幀，換正確性划算。順帶修掉 UnaryMmapTransport 從不 unlink 的缺陷。"
```

---

## Task 3: TransportError.mmapUnusable 與 FallbackTransport

**Files:**
- Modify: `app/Sources/MirageCore/DisplayTransport.swift`
- Create: `app/Sources/MirageCore/FallbackTransport.swift`
- Test: `app/Tests/MirageCoreTests/FallbackTransportTests.swift`

**Interfaces:**
- Consumes: `DisplayTransport`（既有協定：`func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error>`）
- Produces:
  - `TransportError.mmapUnusable(String)`
  - `public final class FallbackTransport: DisplayTransport, @unchecked Sendable { public init(primary: DisplayTransport, secondary: DisplayTransport) }`

> **本任務完全不碰 gRPC**——用兩個假 transport 測完所有行為，因此完全避開既有的 NIO teardown 架構債。

- [ ] **Step 1: 寫失敗測試**

建立 `app/Tests/MirageCoreTests/FallbackTransportTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

/// 可腳本化的假 transport：記錄訂閱次數，依劇本送幀或丟指定錯誤。
private final class ScriptedTransport: DisplayTransport, @unchecked Sendable {
    enum Script {
        case frames([UInt8])            // 依序送出這些 tag 的幀後結束
        case framesThenError([UInt8], Error)
        case error(Error)               // 立刻丟錯，不送幀
        case framesThenHang([UInt8])    // 送完幀後不結束（模擬健康串流）
    }
    private let lock = NSLock()
    private var scripts: [Script]
    private var _subscribeCount = 0

    init(_ scripts: [Script]) { self.scripts = scripts }
    var subscribeCount: Int { lock.lock(); defer { lock.unlock() }; return _subscribeCount }

    func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        lock.lock()
        _subscribeCount += 1
        let script = scripts.isEmpty ? .framesThenHang([]) : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { cont in
            func emit(_ tags: [UInt8]) {
                for t in tags { cont.yield(Frame(width: 1, height: 1, rgba: Data([t, 0, 0, 0]))) }
            }
            switch script {
            case .frames(let tags): emit(tags); cont.finish()
            case .framesThenError(let tags, let err): emit(tags); cont.finish(throwing: err)
            case .error(let err): cont.finish(throwing: err)
            case .framesThenHang(let tags): emit(tags)      // 不 finish
            }
        }
    }
}

private func collect(_ stream: AsyncThrowingStream<Frame, Error>,
                     max: Int) async -> (tags: [UInt8], error: Error?) {
    var tags: [UInt8] = []
    do {
        for try await f in stream {
            tags.append(f.rgba.first ?? 0)
            if tags.count >= max { break }
        }
        return (tags, nil)
    } catch {
        return (tags, error)
    }
}

@Suite struct FallbackTransportTests {
    /// 1. primary 正常 → 全程不切換，secondary 從未被訂閱。
    @Test func healthyPrimaryNeverTouchesSecondary() async {
        let primary = ScriptedTransport([.frames([1, 2, 3])])
        let secondary = ScriptedTransport([.frames([9])])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        let (tags, err) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [1, 2, 3])
        #expect(err == nil)
        #expect(secondary.subscribeCount == 0)
    }

    /// 2. primary 丟 .mmapUnusable → 無縫接上 secondary，消費端看到連續串流。
    @Test func mmapUnusableSwitchesSeamlessly() async {
        let primary = ScriptedTransport([.error(TransportError.mmapUnusable("全零"))])
        let secondary = ScriptedTransport([.frames([7, 8])])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        let (tags, err) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [7, 8])          // 消費端只看到 secondary 的幀，沒有錯誤
        #expect(err == nil)
        #expect(secondary.subscribeCount == 1)
    }

    /// 3. 切換後不再嘗試 primary（同一 instance 內的後續掛載直接走 secondary）。
    @Test func afterFallbackPrimaryIsNeverRetried() async {
        let primary = ScriptedTransport([.error(TransportError.mmapUnusable("全零"))])
        let secondary = ScriptedTransport([.frames([1]), .frames([2])])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        _ = await collect(fb.frames(width: 4, height: 4), max: 10)
        let countAfterFirst = primary.subscribeCount
        let (tags, _) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [2])
        #expect(primary.subscribeCount == countAfterFirst)   // primary 沒有被再次訂閱
        #expect(secondary.subscribeCount == 2)
    }

    /// 4. **最關鍵的一條**：.unavailable 是斷線，必須照常傳播、**不得**降級。
    /// 誤判的後果是「使用者斷線一次就永遠回不到 MMAP」——而那種 bug 不會有人回報。
    @Test func unavailableIsPropagatedNotFallenBackOn() async {
        let primary = ScriptedTransport([.framesThenError([5], TransportError.unavailable("斷線"))])
        let secondary = ScriptedTransport([.frames([9])])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        let (tags, err) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [5])
        #expect(err as? TransportError == TransportError.unavailable("斷線"))
        #expect(secondary.subscribeCount == 0)               // 沒有降級
    }

    /// primary 已送出有效幀後才丟 .mmapUnusable —— 仍然降級，且已送的幀不重送。
    @Test func lateMmapUnusableStillFallsBackWithoutDuplicatingFrames() async {
        let primary = ScriptedTransport([.framesThenError([1], TransportError.mmapUnusable("轉為全零"))])
        let secondary = ScriptedTransport([.frames([2, 3])])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        let (tags, err) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [1, 2, 3])
        #expect(err == nil)
    }

    /// primary 正常結束（非錯誤）→ 不降級，串流照常結束。
    @Test func primaryFinishingCleanlyDoesNotFallBack() async {
        let primary = ScriptedTransport([.frames([4])])
        let secondary = ScriptedTransport([.frames([9])])
        let fb = FallbackTransport(primary: primary, secondary: secondary)
        let (tags, err) = await collect(fb.frames(width: 4, height: 4), max: 10)
        #expect(tags == [4])
        #expect(err == nil)
        #expect(secondary.subscribeCount == 0)
    }
}
```

- [ ] **Step 2: 執行確認失敗**

Run: `cd app && swift test --filter FallbackTransportTests`
Expected: 編譯失敗，`cannot find 'FallbackTransport' in scope` 與 `type 'TransportError' has no member 'mmapUnusable'`。

- [ ] **Step 3: 新增錯誤 case**

修改 `app/Sources/MirageCore/DisplayTransport.swift`：

```swift
public enum TransportError: Error, Equatable {
    case unavailable(String)      // 可重連（UNAVAILABLE 等）
    case invalidRequest(String)   // fail fast，不重連
    /// MMAP 掛載成功但 host 寫入端無作用（前 3 幀全零）→ 換一條 transport。
    /// 與上面兩者語意正交：既不重連也不 fail fast，而是降級。
    case mmapUnusable(String)
}
```

- [ ] **Step 4: 實作 FallbackTransport**

建立 `app/Sources/MirageCore/FallbackTransport.swift`：

```swift
import Foundation

/// 組合器：primary 判定不可用時無縫換到 secondary。本身不碰 gRPC。
///
/// **只對 `TransportError.mmapUnusable` 降級。** primary 若因模擬器被殺而丟
/// `.unavailable`，那是斷線，必須照常往上傳播交給既有重連迴圈處理——絕不能被誤判成
/// 「MMAP 壞了」而永久降級，否則使用者斷線一次就永遠回不到 MMAP，而那種退化不會有人
/// 回報，只會默默吃掉整個優化。
///
/// **決定的有效範圍是一個 instance = 一條 channel**：`EmulatorClient.dropChannel()` 會重建
/// transport，決定隨之消失，重連後重新探測。自癒，且符合「模擬器可能在重連之間被換掉」。
public final class FallbackTransport: DisplayTransport, @unchecked Sendable {
    private let primary: DisplayTransport
    private let secondary: DisplayTransport
    private let lock = NSLock()
    private var fellBack = false

    public init(primary: DisplayTransport, secondary: DisplayTransport) {
        self.primary = primary
        self.secondary = secondary
    }

    private var hasFallenBack: Bool {
        lock.lock(); defer { lock.unlock() }; return fellBack
    }

    private func markFallenBack() {
        lock.lock(); fellBack = true; lock.unlock()
    }

    public func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        if hasFallenBack { return secondary.frames(width: width, height: height) }
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await frame in self.primary.frames(width: width, height: height) {
                        if Task.isCancelled { return }
                        cont.yield(frame)
                    }
                    cont.finish()                       // primary 正常結束，不降級
                } catch let err as TransportError {
                    guard case .mmapUnusable = err else {
                        cont.finish(throwing: err)      // 斷線等其他錯誤照常傳播
                        return
                    }
                    self.markFallenBack()
                    await self.drainSecondary(into: cont, width: width, height: height)
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// 降級後把 secondary 的幀灌進**同一條** continuation——消費端看到的是一條不中斷的串流。
    private func drainSecondary(into cont: AsyncThrowingStream<Frame, Error>.Continuation,
                                width: Int, height: Int) async {
        do {
            for try await frame in secondary.frames(width: width, height: height) {
                if Task.isCancelled { return }
                cont.yield(frame)
            }
            cont.finish()
        } catch {
            cont.finish(throwing: error)
        }
    }
}
```

- [ ] **Step 5: 執行確認通過**

Run: `cd app && swift test --filter FallbackTransportTests`
Expected: PASS，6 個測項全綠。

- [ ] **Step 6: 確認逐行 100% 覆蓋**

Run: `cd app && swift test --filter FallbackTransportTests --enable-code-coverage && xcrun llvm-cov report .build/debug/MiragePackageTests.xctest/Contents/MacOS/MiragePackageTests -instr-profile .build/debug/codecov/default.profdata 2>/dev/null | grep FallbackTransport`
Expected: `FallbackTransport.swift` line coverage `100.00%`。

- [ ] **Step 7: 跑全套測試確認零回歸**

Run: `cd app && swift test 2>&1 | tail -3`
Expected: 既有 137 個加上本階段新增者全綠。

- [ ] **Step 8: Commit**

```bash
cd app && git add Sources/MirageCore/DisplayTransport.swift Sources/MirageCore/FallbackTransport.swift Tests/MirageCoreTests/FallbackTransportTests.swift
git commit -m "feat: FallbackTransport 與 TransportError.mmapUnusable

只對 .mmapUnusable 降級；.unavailable 是斷線必須照常傳播——誤判會讓使用者
斷線一次就永遠回不到 MMAP，且那種退化不會有人回報。降級後把 secondary 的幀
灌進同一條 continuation，消費端看到不中斷的串流。全程用假 transport 測試，
不碰 gRPC，故完全避開既有 NIO teardown 架構債。"
```

---

## Task 4: HealthResult 帶出版本字串

**Files:**
- Modify: `app/Sources/MirageCore/Lifecycle/HealthProbe.swift`
- Modify: `app/Sources/MirageCore/EmulatorClient.swift:167-169`
- Modify: `app/Tests/MirageCoreTests/HealthProbeTests.swift`
- Modify: `app/Tests/MirageCoreTests/EmulatorClientReconnectTests.swift:96,162`
- Modify: `app/Tests/MirageCoreTests/EmulatorClientAudioTests.swift:51`

**Interfaces:**
- Consumes: 無
- Produces: `HealthResult.healthy(version: String)`（取代原本無關聯值的 `case healthy`）

> **為什麼這樣做**：`GrpcHealthProbe.probe()` 已經在打 `getStatus` 並拿到含 `version` 的完整 `EmulatorStatus`，卻只回傳 `.healthy` 就丟棄。改由它帶出來，比另外加一次 RPC 好——每次連線少一次往返，而且「我們連上的是什麼」本來就屬於連線層的知識。

- [ ] **Step 1: 改 enum 與生產實作**

修改 `app/Sources/MirageCore/Lifecycle/HealthProbe.swift`：

```swift
/// 健康探測結果：驅動連線 reducer 的 connectSucceeded / connectFailed。
///
/// `.healthy` 帶出 emulator 版本字串——`getStatus` 本來就回傳它，之前被丟棄。
/// 由連線層決定要建哪種 transport（MMAP 需 ≥37，見 MmapVersionGate）需要這個資訊，
/// 讓探測順手帶出比另外打一次 RPC 便宜。
public enum HealthResult: Equatable, Sendable {
    case healthy(version: String)
    case timedOut   // 逾時未回覆
    case failed     // 回覆錯誤或未 booted
}
```

同檔 `GrpcHealthProbe.probe()` 內：

```swift
                    let status = try await client.getStatus(.init())
                    return status.booted ? .healthy(version: status.version) : .failed
```

- [ ] **Step 2: 改連線迴圈的解構**

修改 `app/Sources/MirageCore/EmulatorClient.swift` 的 `runConnectionLoop()`——原本第 169 行的 `if result == .healthy {` 改為：

```swift
            if case .healthy(let version) = result {
                emulatorVersion = version           // Task 6 會用到；此刻先存起來
```

並在 `EmulatorClient` 的狀態區（`private var probe: HealthProbe?` 附近）新增：

```swift
    /// 最近一次健康探測回報的 emulator 版本字串；決定要建哪種 display transport。
    /// 空字串代表未知 → MmapVersionGate 會拒絕 → 走 raw RGBA（保守）。
    private var emulatorVersion = ""
```

- [ ] **Step 3: 修測試假件與斷言（共 8 處）**

`app/Tests/MirageCoreTests/HealthProbeTests.swift`：

- 第 14 行 `return results.isEmpty ? .healthy : results.removeFirst()`
  → `return results.isEmpty ? .healthy(version: "37.2.1.0") : results.removeFirst()`
- 第 20 行 `ScriptedProbe([.failed, .timedOut, .healthy])`
  → `ScriptedProbe([.failed, .timedOut, .healthy(version: "37.2.1.0")])`
- 第 23 行 `#expect(await p.probe(timeout: .seconds(1)) == .healthy)`
  → `#expect(await p.probe(timeout: .seconds(1)) == .healthy(version: "37.2.1.0"))`
- 第 28–29 行的等值測試
  → `#expect(HealthResult.healthy(version: "1") == .healthy(version: "1"))`
  　`#expect(HealthResult.healthy(version: "1") != .healthy(version: "2"))`
  　`#expect(HealthResult.healthy(version: "1") != .failed)`

`app/Tests/MirageCoreTests/EmulatorClientReconnectTests.swift`：

- 第 96 行 `ScriptedProbe([.failed, .timedOut, .healthy])`
  → `ScriptedProbe([.failed, .timedOut, .healthy(version: "37.2.1.0")])`
- 第 162 行 `ScriptedProbe(Array(repeating: .failed, count: 100) + [.healthy])`
  → `ScriptedProbe(Array(repeating: .failed, count: 100) + [.healthy(version: "37.2.1.0")])`

`app/Tests/MirageCoreTests/EmulatorClientAudioTests.swift`：

- 第 51 行 `return .healthy`（在 `SlowFirstProbe.probe` 內）
  → `return .healthy(version: "37.2.1.0")`

**注意**：`ScriptedProbe([])`（空劇本＝永遠 healthy）的呼叫端不需要改——空陣列走的是第 14 行那條路徑。

- [ ] **Step 4: 執行確認全綠**

Run: `cd app && swift test 2>&1 | tail -3`
Expected: 既有 137 個 `@Test` 加上前三個 Task 新增者**全綠**。若有紅，是漏改的站點——用 `grep -rn "\.healthy" Sources/ Tests/ | grep -v "healthy(version" ` 找出來。

- [ ] **Step 5: 確認沒有遺漏站點**

Run: `cd app && grep -rn "\.healthy" Sources/ Tests/ | grep -v "healthy(version" | grep -v "^.*://" | grep -v "永遠 .healthy"`
Expected: 無輸出（註解中的 `.healthy` 字樣可保留，故過濾掉註解行）。

- [ ] **Step 6: Commit**

```bash
cd app && git add Sources/MirageCore/Lifecycle/HealthProbe.swift Sources/MirageCore/EmulatorClient.swift Tests/MirageCoreTests/
git commit -m "refactor: HealthResult.healthy 帶出 emulator 版本字串

GrpcHealthProbe 本來就在打 getStatus 並拿到含 version 的 EmulatorStatus，
卻只回傳 .healthy 就丟棄。改由它帶出來，讓連線層能決定要建哪種 transport
（MMAP 需 >=37），比另外加一次 RPC 少一次往返。"
```

---

## Task 5: MmapStreamTransport

**Files:**
- Create: `app/Sources/MirageCore/MmapStreamTransport.swift`

**Interfaces:**
- Consumes: `MmapSupport`（Task 1）、`MmapBuffer`（Task 2）、`TransportError.mmapUnusable`（Task 3）、`GrpcChannelBox`（既有，`GrpcStreamTransport.swift`）
- Produces: `public struct MmapStreamTransport: DisplayTransport { public init(channel: GrpcChannelBox) }`

> **本任務刻意沒有單元測試**，與既有 `GrpcStreamTransport` 同處境——需要真 channel，寫假 channel 的成本遠高於價值。正確性由 Task 3 的組合器測試（降級行為）+ Task 8 的活體驗證共同覆蓋。**不要**為了湊測試而造假 channel。

- [ ] **Step 1: 實作**

建立 `app/Sources/MirageCore/MmapStreamTransport.swift`：

```swift
import Darwin
import Foundation
import GRPC

/// `streamScreenshot` + MMAP 共享記憶體的 DisplayTransport。
///
/// 相對於 `GrpcStreamTransport`（raw RGBA payload 走 protobuf），本實作讓 emulator 直接把
/// 像素寫進我們提供的映射區，通知訊息的 payload 為空。實測收益（900×2000，spec §1.1）：
/// client 每幀 CPU 8.0 → 0.7 ms、經 gRPC 的位元組 272 → 0 MiB/s。
public struct MmapStreamTransport: DisplayTransport {
    /// 前幾幀若映射區全零就判定 host 寫入端無作用 → 丟 .mmapUnusable 讓上層降級。
    /// 偏誤方向刻意：寧可誤降級（只是多花 CPU、畫面正確）也不要誤啟用（黑畫面）。
    static let blankProbeFrames = 3

    private let channel: GrpcChannelBox
    private let seq = MmapSequence()

    public init(channel: GrpcChannelBox) { self.channel = channel }

    public func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        let size = MmapSupport.byteCount(width: width, height: height)
        let path = MmapSupport.handlePath(tempDir: NSTemporaryDirectory(), pid: getpid(),
                                          seq: seq.next(), width: width, height: height)
        guard size > 0, let buffer = MmapBuffer(path: path, byteCount: size) else {
            return AsyncThrowingStream { cont in
                cont.finish(throwing: TransportError.mmapUnusable(
                    "無法建立 \(size) 位元組的映射（\(path)）"))
            }
        }

        var format = Android_Emulation_Control_ImageFormat()
        format.format = .rgba8888
        // **必須帶明確尺寸**：上游 b/537802959 的根因就是「請求裝置原生尺寸時
        // width*height 為 0，pre-borrow 用 0 大小並毒化 cache」。
        format.width = UInt32(width)
        format.height = UInt32(height)
        var transport = Android_Emulation_Control_ImageTransport()
        transport.channel = .mmap
        transport.handle = MmapSupport.handleURL(path: buffer.path)
        format.transport = transport

        // 用 makeStreamScreenshotCall 而非便利方法 client.streamScreenshot(_:)——後者丟棄
        // 底層 GRPCAsyncServerStreamingCall，無法顯式取消。那正是 P1-b 剪貼簿串流實證過、
        // 且架構債記錄點名為 crash 元兇的同一個坑。
        let call = channel.client.makeStreamScreenshotCall(format)
        let responses = call.responseStream

        return AsyncThrowingStream { continuation in
            let task = Task {
                var seen = 0
                var sawContent = false
                do {
                    for try await _ in responses {
                        if Task.isCancelled { return }
                        let data = buffer.snapshot()
                        if !sawContent {
                            seen += 1
                            if !MmapSupport.isBlank(data) {
                                sawContent = true
                            } else if seen >= Self.blankProbeFrames {
                                continuation.finish(throwing: TransportError.mmapUnusable(
                                    "前 \(Self.blankProbeFrames) 幀映射區皆全零"))
                                return
                            } else {
                                continue        // 還在探測窗口內且全零：不送出黑幀
                            }
                        }
                        continuation.yield(Frame(width: width, height: height, rgba: data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: TransportError.unavailable("\(error)"))
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                call.cancel()       // 顯式取消底層 RPC——Task.cancel() 中斷不了 in-flight next()
                buffer.close()      // munmap + close + unlink
            }
        }
    }
}

/// 掛載序號：確保每次 frames() 用不同的映射檔路徑（見 MmapSupport.handlePath 的說明）。
final class MmapSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
```

- [ ] **Step 2: 建置確認型別對得上**

Run: `cd app && swift build 2>&1 | tail -5`
Expected: 建置成功。若 `makeStreamScreenshotCall` 的泛型參數不符，以 `Sources/MirageCore/Generated/emulator_controller.grpc.swift:2129` 的實際簽章為準修正型別標註——但**不要**改用便利方法繞過（理由見程式碼註解）。

- [ ] **Step 3: release 零警告**

Run: `cd app && swift build -c release 2>&1 | grep -i warning | grep -v deprecat`
Expected: 無輸出。

- [ ] **Step 4: 跑全套測試確認零回歸**

Run: `cd app && swift test 2>&1 | tail -3`
Expected: 全綠。

- [ ] **Step 5: Commit**

```bash
cd app && git add Sources/MirageCore/MmapStreamTransport.swift
git commit -m "feat: MmapStreamTransport——streamScreenshot 走共享記憶體

必須帶明確 width/height（上游 b/537802959 的根因正是請求裝置原生尺寸時
width*height 為 0、pre-borrow 用 0 大小毒化 cache）。用 makeStreamScreenshotCall
而非便利方法以保有顯式 cancel。前 3 幀全零即丟 .mmapUnusable 讓上層降級，
探測窗口內的全零幀不送出（避免使用者看到黑畫面閃爍）。"
```

---

## Task 6: EmulatorClient 接線與觀測訊息

**Files:**
- Modify: `app/Sources/MirageCore/EmulatorClient.swift`

**Interfaces:**
- Consumes: `MmapVersionGate.allows(versionString:)`（Task 1）、`MmapStreamTransport(channel:)`（Task 5）、`FallbackTransport(primary:secondary:)`（Task 3）、`emulatorVersion` 私有屬性（Task 4）
- Produces: 無新公開介面（行為改變：連上 ≥37 的 emulator 時自動走 MMAP）

> **關鍵時序**：`ensureChannel()` 目前在**探測之前**就建好 transport，但版本要探測完才知道。所以 transport 的建立必須**延後到探測成功之後**。

- [ ] **Step 1: 讀懂目前的時序**

Run: `cd app && sed -n '160,200p' Sources/MirageCore/EmulatorClient.swift`

確認現況：`runConnectionLoop()` 先 `ensureChannel()`（建 channel + transport + probe）→ 再 `probe.probe()` → 健康才 `step(.connectSucceeded)` → `connectedRun()` → `attachStream()`。

- [ ] **Step 2: 把 transport 的建立延後到探測之後**

修改 `ensureChannel()`——**移除**其中建立 `transport` 的那一行（`transport = makeTransport(boxCh)`），只保留 channel 與 probe 的建立；回傳條件也跟著改成不再要求 `transport != nil`：

```swift
    /// 確保 channel/probe 存在；斷線後 channelBox 已被 dropChannel 清空，此處重建。
    ///
    /// **transport 刻意不在這裡建立**：要建哪種（MMAP 或 raw RGBA）取決於 emulator 版本，
    /// 而版本要等健康探測回報才知道。改由 makeDisplayTransport() 在探測成功後建立。
    private func ensureChannel() -> Bool {
        if channelBox == nil {
            do {
                let boxCh = try GrpcChannelBox(host: host, port: port)
                channelBox = boxCh
                probe = makeHealthProbe(boxCh)
                audioTransport = makeAudioTransport(boxCh)
            } catch {
                return false
            }
        }
        return probe != nil
    }
```

- [ ] **Step 3: 新增依版本選 transport 的方法**

在 `ensureChannel()` 之後新增：

```swift
    /// 依探測回報的 emulator 版本決定 display transport，並印一次性觀測訊息。
    ///
    /// MMAP 需要 ≥37（36.x 收到 MMAP 請求會 SIGSEGV 弄死使用者的 VM，見 MmapVersionGate）。
    /// 過關就用 FallbackTransport 包起來——MMAP 若實際不寫入（前 3 幀全零）會自動無縫
    /// 降級到 raw RGBA，使用者不會看到黑畫面。
    private func makeDisplayTransport() {
        guard let boxCh = channelBox else { return }
        if MmapVersionGate.allows(versionString: emulatorVersion) {
            transport = FallbackTransport(primary: MmapStreamTransport(channel: boxCh),
                                          secondary: makeTransport(boxCh))
            print("[transport] mmap enabled (emulator \(emulatorVersion))")
        } else {
            transport = makeTransport(boxCh)
            let v = emulatorVersion.isEmpty ? "unknown" : emulatorVersion
            print("[transport] raw rgba (emulator \(v) < 37)")
        }
    }
```

- [ ] **Step 4: 在探測成功後呼叫它**

修改 `runConnectionLoop()` 的健康分支——Task 4 已把它改成 `if case .healthy(let version) = result {`，在 `emulatorVersion = version` 之後、`step(.connectSucceeded)` **之前**插入：

```swift
                makeDisplayTransport()
```

- [ ] **Step 5: 降級訊息**

`FallbackTransport` 降級時也該印一行，但它在 `MirageCore` 且不該知道 print 的格式慣例。最小改法：在 `FallbackTransport.markFallenBack()` 內加一行——修改 `app/Sources/MirageCore/FallbackTransport.swift`：

```swift
    private func markFallenBack() {
        lock.lock()
        let first = !fellBack
        fellBack = true
        lock.unlock()
        if first { print("[transport] mmap unusable, falling back to raw rgba") }
    }
```

只在第一次降級時印，不重複洗版。

- [ ] **Step 6: 建置並跑全套測試**

Run: `cd app && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: 建置成功；全套測試全綠（既有 137 + 新增）。

**若 `EmulatorClientReconnectTests` 出現紅燈**：可能是 transport 建立時機改變導致假件的訂閱次數期望不符。**先讀失敗訊息判斷是測試的期望需要更新、還是產品行為真的錯了**——若是前者，更新期望並在 commit 訊息說明；若是後者，停下來回報。

- [ ] **Step 7: release 零警告**

Run: `cd app && swift build -c release 2>&1 | grep -i warning | grep -v deprecat`
Expected: 無輸出。

- [ ] **Step 8: Commit**

```bash
cd app && git add Sources/MirageCore/EmulatorClient.swift Sources/MirageCore/FallbackTransport.swift
git commit -m "feat: 依 emulator 版本自動選用 MMAP transport

transport 的建立從 ensureChannel() 延後到健康探測之後——要建哪種取決於版本，
而版本要等探測回報才知道。>=37 用 FallbackTransport(MMAP, raw RGBA) 包起來，
MMAP 實際不寫入時自動無縫降級。三種情形各印一次觀測訊息。"
```

---

## Task 7: 刪除 UnaryMmapTransport

**Files:**
- Delete: `app/Sources/MirageCore/UnaryMmapTransport.swift`
- Modify: `app/Tests/MirageCoreTests/EmulatorClientReconnectTests.swift`（約 195–215 行的活體測試）
- Delete: `app/Tests/MirageCoreTests/MmapVersionGateTests.swift`（其內容已被 Task 1 的 `MmapSupportTests` 涵蓋）

**Interfaces:**
- Consumes: `MmapStreamTransport`（Task 5）
- Produces: 無

> `UnaryMmapTransport` 是 Phase-0 為「MMAP 串流在 macOS 壞掉」這個**錯誤結論**建的 workaround（實際上 Mirage 從來不會踩到那個 bug，見 spec §1）。它 108 行、有版本閘、從未接上 App 執行期，且長期拖低 MirageCore 覆蓋率。被 `MmapStreamTransport` 完全取代，故刪除。

- [ ] **Step 1: 確認唯一使用者**

Run: `cd app && grep -rn "UnaryMmapTransport" Sources/ Tests/ scripts/ ../docs 2>/dev/null`
Expected: 只有 `Sources/MirageCore/UnaryMmapTransport.swift` 自身與 `Tests/MirageCoreTests/EmulatorClientReconnectTests.swift` 的活體測試。若有其他使用者，停下來回報。

- [ ] **Step 2: 刪除舊的活體測試（由 Task 8 的新測試取代）**

`Tests/MirageCoreTests/EmulatorClientReconnectTests.swift` 裡有一個 `liveUnaryMmapDeliversFrames`，它只驗「收到至少一幀非 nil」——**比 Task 8 的 `MmapStreamLiveTests` 弱**（後者還驗非全零與逐幀變動）。與其改寫，直接刪除整個測項：

```swift
    @Test func liveUnaryMmapDeliversFrames() async throws {
        // 修正案 A 對應：XCTSkipUnless → guard 提前 return（需要 canary 模擬器）。
        // 執行：MIRAGE_LIVE_MMAP=1 swift test --filter LiveSmokeTests/liveUnaryMmapDeliversFrames
        guard ProcessInfo.processInfo.environment["MIRAGE_LIVE_MMAP"] == "1" else { return }
        let chBox = try GrpcChannelBox(host: "localhost", port: 8554)
        let status = try await chBox.client.getStatus(Google_Protobuf_Empty())
        let transport = UnaryMmapTransport(channel: chBox,
                                           versionString: status.version)
        let box = LatestFrameBox()
        let pump = FramePump()
        await pump.attach(transport.frames(width: 540, height: 1200),
                          into: box, onEnd: { _ in })
        try await Task.sleep(for: .seconds(2))
        #expect(box.takeLatest() != nil)
        await pump.detach()
    }
```

把上面整段（含 `@Test` 那行到對應的 `}`）從檔案中刪除。

**`MIRAGE_LIVE_MMAP` 這個環境變數名稱由 Task 8 的新測試承接**，腳本與文件不受影響。

刪除後檢查該檔是否還需要 `Google_Protobuf_Empty` 的 import（若這是唯一使用處，`import SwiftProtobuf` 可能變成未使用——建置警告會告訴你）。

- [ ] **Step 3: 刪除檔案**

```bash
cd app && git rm Sources/MirageCore/UnaryMmapTransport.swift Tests/MirageCoreTests/MmapVersionGateTests.swift
```

- [ ] **Step 4: 建置並跑全套測試**

Run: `cd app && swift build 2>&1 | tail -3 && swift test 2>&1 | tail -3`
Expected: 建置成功；測試全綠。測試總數會**減少 6 個**（`MmapVersionGateTests` 的 6 個測項），但那 6 條的等價涵蓋已在 `MmapSupportTests` 的兩個參數化測項裡——在 commit 訊息記錄這個數字變化，避免日後被誤讀成回歸。

- [ ] **Step 5: Commit**

```bash
cd app && git add -A
git commit -m "refactor: 刪除 UnaryMmapTransport，活體測試改指向 MmapStreamTransport

它是 Phase-0 為「MMAP 串流在 macOS 壞掉」這個錯誤結論建的 workaround——
實際上 Mirage 一直都帶明確尺寸、從來不會踩到那個 bug。108 行、從未接上 App
執行期、長期拖低 MirageCore 覆蓋率，已被 MmapStreamTransport 完全取代。

MmapVersionGateTests 一併刪除（6 個測項），其涵蓋已由 MmapSupportTests 的
參數化測項承接——測試總數的減少是預期的，非回歸。"
```

---

## Task 8: 活體驗證與收益複驗

**Files:**
- Create: `app/Tests/MirageCoreTests/MmapStreamLiveTests.swift`
- Create: `app/scripts/verify_mmap.sh`

**Interfaces:**
- Consumes: `MmapStreamTransport`（Task 5）、`EmulatorClient`（既有）
- Produces: 無（產出的是驗收證據）

> **前置**：`streamScreenshot` 是變化驅動的——guest 畫面靜止時不出幀。驗證腳本必須先讓畫面動起來。`phase0/harness/animate.py` 可供應動畫，但需要獨立的 Python 環境（系統 python 的 protobuf 版本過舊）。腳本要能在沒有該環境時**清楚報錯並退出**，而不是量到 0 幀然後讓人以為 MMAP 壞了。

- [ ] **Step 1: 寫活體測試**

建立 `app/Tests/MirageCoreTests/MmapStreamLiveTests.swift`：

```swift
import Foundation
import Testing
@testable import MirageCore

/// 活體：真模擬器 → streamScreenshot + MMAP → 非零且逐幀變動的 Frame。
/// 需 `MIRAGE_LIVE=1` 且 `MIRAGE_LIVE_MMAP=1`（沿用既有環境變數名稱），
/// 並且 guest 畫面必須正在變動——由 scripts/verify_mmap.sh 負責。
@Suite struct MmapStreamLiveTests {
    @Test func realEmulatorWritesIntoMappedBuffer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MIRAGE_LIVE"] == "1", env["MIRAGE_LIVE_MMAP"] == "1" else {
            print("[mmap-live] skipped: 需 MIRAGE_LIVE=1 且 MIRAGE_LIVE_MMAP=1；請跑 scripts/verify_mmap.sh")
            return
        }
        let box = try GrpcChannelBox(host: "localhost", port: 8554)
        let transport = MmapStreamTransport(channel: box)
        var digests: [Int] = []
        for try await frame in transport.frames(width: 540, height: 1200) {
            #expect(frame.isValid)
            #expect(!MmapSupport.isBlank(frame.rgba))
            digests.append(frame.rgba.hashValue)
            if digests.count >= 3 { break }
        }
        print("[mmap-live] frames=\(digests.count) distinct=\(Set(digests).count)")
        #expect(digests.count == 3, "未收到 3 幀——guest 畫面是否在變動？")
        #expect(Set(digests).count >= 2, "幀內容未變化——映射區可能沒被寫入")
    }
}
```

- [ ] **Step 2: 寫驗證腳本**

建立 `app/scripts/verify_mmap.sh`：

```bash
#!/usr/bin/env bash
# P1 MMAP transport 活體驗證：確認 streamScreenshot + 共享記憶體真的寫入資料。
# 用法：verify_mmap.sh    （需 emulator-5554 正在跑）
set -uo pipefail
export ANDROID_SERIAL=emulator-5554
HARNESS="$(cd "$(dirname "$0")/../../phase0/harness" && pwd)"

echo "=== 前置：模擬器是否在跑 ==="
nc -z localhost 8554 && echo "gRPC 8554 ALIVE" || { echo "模擬器未啟動"; exit 1; }

echo ""
echo "=== 前置：動畫供應器（streamScreenshot 是變化驅動，靜止畫面不出幀）==="
PY=""
for cand in "$HARNESS/.venv/bin/python" "$(command -v python3)"; do
  [ -x "$cand" ] && "$cand" -c "import grpc, google.protobuf" 2>/dev/null && { PY="$cand"; break; }
done
if [ -z "$PY" ]; then
  echo "找不到具備 grpc+protobuf 的 python。請先建立環境："
  echo "  python3 -m venv $HARNESS/.venv && $HARNESS/.venv/bin/pip install -r $HARNESS/requirements.txt"
  echo "（系統 python 的 protobuf 版本過舊，會讓 animate.py 匯入失敗）"
  exit 1
fi
( cd "$HARNESS" && "$PY" animate.py --seconds 40 >/tmp/mirage_anim.log 2>&1 & )
sleep 4

echo ""
echo "=== 量測：MmapStreamTransport 活體 ==="
cd "$(dirname "$0")/.." || exit 1
MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --filter MmapStreamLiveTests 2>&1 \
  | grep -E "\[mmap-live\]|Test run with|✘"

echo ""
echo "=== 驗收線 6：/tmp 不得有映射檔殘留 ==="
LEFT=$(ls /tmp/mirage_mmap_* 2>/dev/null | wc -l | tr -d ' ')
echo "殘留檔案數：$LEFT"
[ "$LEFT" = "0" ] && echo "PASS" || { echo "FAIL：close() 的 unlink 沒生效"; ls /tmp/mirage_mmap_*; }
```

- [ ] **Step 3: 賦予執行權限並實跑**

Run: `cd app && chmod +x scripts/verify_mmap.sh && ./scripts/verify_mmap.sh`
Expected: `[mmap-live] frames=3 distinct=3`（或 distinct≥2）、測試通過、殘留檔案數 0。

**若收到 0 幀**：先確認 animate.py 真的在跑（`head /tmp/mirage_anim.log`）。**不要調低斷言門檻**——量到 0 就是 0，如實回報。

**若幀全零（`isBlank` 斷言失敗）**：代表 MMAP 在這台模擬器上真的沒寫入。這是重大發現，**停下來回報**，不要繞過斷言。

- [ ] **Step 4: 複驗收益仍成立**

Run:
```bash
cd /Users/hanfourhuang/Projects/mirage/phase0/harness
python3 -m venv .venv 2>/dev/null; .venv/bin/pip install -q -r requirements.txt
.venv/bin/python bench_mmap_vs_rgba.py --seconds 10 --width 900 --height 2000
```
Expected: `mmap-copy` 的 client CPU/幀相對 `rgba` 降幅 **≥80%**（spec 驗收線 7）。把真實輸出貼進報告。

- [ ] **Step 5: Commit**

```bash
cd app && git add Tests/MirageCoreTests/MmapStreamLiveTests.swift scripts/verify_mmap.sh
git commit -m "test: MMAP transport 活體驗證（MmapStreamLiveTests + verify_mmap.sh）

腳本先確認動畫供應器可用再量測——streamScreenshot 是變化驅動，靜止畫面不出幀，
沒有這一步量到的 0 幀是假陰性。找不到具備 grpc+protobuf 的 python 時清楚報錯
並退出，而非讓人誤以為 MMAP 壞了。一併檢查 /tmp 無映射檔殘留（驗收線 6）。"
```

---

## Task 9: 文件與驗收紀錄

**Files:**
- Create: `app/RESULTS-mmap.md`
- Modify: `app/README.md`

**Interfaces:**
- Consumes: Task 1–8 的全部產出與量測數字
- Produces: 無（文件）

- [ ] **Step 1: 蒐集驗收數字**

依序執行並保留**真實輸出**：

```bash
cd app
swift test 2>&1 | tail -3                                            # 驗收線 1
swift build -c release 2>&1 | grep -ci warning                       # 驗收線 3
./scripts/coverage.sh 2>&1 | tail -25                                # 驗收線 4
./scripts/verify_mmap.sh                                             # 驗收線 5、6
```
加上 Task 8 Step 4 的基準輸出（驗收線 7）。

**注意**：測試總數會因 Task 7 刪除 `MmapVersionGateTests`（−6）與本階段新增而變動。報告要寫清楚「既有 137 → 現在 N，其中 −6 是刪除的重複測項、+M 是新增」，避免被誤讀成回歸。

- [ ] **Step 2: 寫 RESULTS-mmap.md**

比照 `app/RESULTS-p1e.md` 的格式與誠實度標準。必含：

1. **驗收線逐條**（spec §8 的 7 條），每條標 PASS / FAIL / pending-human 與**實際輸出**
2. **收益複驗數字**，以及與 spec §1.1 原始量測的對照
3. **測試數變動的解釋**（見 Step 1 的注意事項）
4. **pending-human 清單**（spec §9 三項），原因統一為「本機 `CGSSessionScreenIsLocked = true`，螢幕鎖定時 WindowServer 不合成畫面，`WindowGroup` 的 `.task` 不觸發」——這是 P1-e fast-follow 已收斂的診斷，**不要**再寫成「headless 不驅動」
5. **已知限制**：撕裂幀（proto 無同步原語，「未觀察到」≠「不會發生」）、版本閘不放寬的理由

**誠實標準**：本專案有 `RESULTS-p1a.md` 曾把繞過產品碼的 Python harness 數字當證據、後被撤回的前車之鑑。量不到就寫 pending-human，不得用相近但不同的數字冒充。特別是：**`bench_mmap_vs_rgba.py` 是 Python client 的傳輸層數字，不得冒充 Swift App 的合成層效能**。

- [ ] **Step 3: 更新 README**

在 `app/README.md` 新增或補充 transport 說明，涵蓋：

- 連上 emulator 後依 `getStatus` 回報的版本決定 transport：≥37 走 `FallbackTransport(MmapStreamTransport, GrpcStreamTransport)`，否則 raw RGBA
- 三種一次性觀測訊息的意義（`mmap enabled` / `mmap unusable, falling back` / `raw rgba`）
- 為什麼版本閘不放寬（36.x 收 MMAP 會 SIGSEGV 弄死 VM）
- 為什麼 `Frame` 是複製而非映射區的 view（Renderer 在 vsync 才讀，原地覆寫會撕裂）
- 活體驗證方式：`./scripts/verify_mmap.sh`（需動畫供應器）
- 指向 `RESULTS-mmap.md` 與 `../docs/specs/2026-07-27-mmap-stream-transport-design.md`

- [ ] **Step 4: Commit**

```bash
cd app && git add RESULTS-mmap.md README.md
git commit -m "docs: MMAP transport 驗收結果與使用文件"
```

---

## 驗收線對照表（spec §8）

| # | 驗收線 | 由哪個 Task 產生證據 |
|---|---|---|
| 1 | `swift test` 全綠，既有 137 個不回歸（Task 7 的 −6 需說明） | Task 3/4/6 各自的全套測試步驟、Task 9 Step 1 |
| 2 | 新增純函式與 `FallbackTransport` 測試通過；純函式逐行 100% | Task 1 Step 6、Task 3 Step 6 |
| 3 | `swift build -c release` 零非-deprecation 警告 | Task 5 Step 3、Task 6 Step 7、Task 9 Step 1 |
| 4 | `coverage.sh` 的 `MirageCore` 段不低於 ~94% 基準 | Task 9 Step 1 |
| 5 | 活體收到 ≥3 個非零且互異的幀 | Task 8 Step 3 |
| 6 | 跑完 `/tmp` 無 `mirage_mmap_*` 殘留 | Task 2 Step 5、Task 8 Step 3 |
| 7 | 收益複驗：client CPU/幀降幅 ≥80% | Task 8 Step 4 |
