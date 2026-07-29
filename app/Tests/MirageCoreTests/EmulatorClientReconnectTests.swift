import Foundation
import Testing
@testable import MirageCore

/// 可腳本化的假 transport：第 n 次訂閱時照劇本回放（幀 / 錯誤 / 永掛）。
final class MockTransport: DisplayTransport, @unchecked Sendable {
    enum Script { case yieldThenFail(UInt8), yieldThenHang(UInt8) }
    private let lock = NSLock()
    private var scripts: [Script]
    private(set) var subscribeCount = 0
    private var _cancelCount = 0
    /// 比照 `MockAudioTransport.cancelCount`：驗 `dropChannel()` 有沒有顯式取消底層 RPC。
    var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return _cancelCount }

    init(_ scripts: [Script]) { self.scripts = scripts }

    func cancelStream() { lock.lock(); _cancelCount += 1; lock.unlock() }

    func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        lock.lock()
        subscribeCount += 1
        let script = scripts.isEmpty ? .yieldThenHang(99) : scripts.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { cont in
            switch script {
            case .yieldThenFail(let tag):
                cont.yield(Frame(width: 1, height: 1, rgba: Data([tag, 0, 0, 0])))
                struct StreamDied: Error {}
                cont.finish(throwing: StreamDied())
            case .yieldThenHang(let tag):
                cont.yield(Frame(width: 1, height: 1, rgba: Data([tag, 0, 0, 0])))
                // 不 finish：模擬健康串流持續中
            }
        }
    }
}

actor SleepRecorder {
    var all: [Duration] = []
    func record(_ d: Duration) { all.append(d) }
}

@Suite struct EmulatorClientReconnectTests {
    @Test func streamFailureResubscribesWithBackoff() async throws {
        let mock = MockTransport([.yieldThenFail(1), .yieldThenHang(2)])
        let box = LatestFrameBox()
        let sleepRecorder = SleepRecorder()
        let client = EmulatorClient(
            makeTransport: { _ in mock },
            makeHealthProbe: { _ in ScriptedProbe([]) },      // 永遠 .healthy
            sleeper: { d in await sleepRecorder.record(d) },  // 假時鐘：不真睡
            randomSource: { 0.5 }
        )
        await client.start(box: box, width: 540, height: 1200)
        try await Task.sleep(for: .milliseconds(500))  // 讓重連迴圈跑完
        #expect(mock.subscribeCount == 2)               // 失敗後重掛了
        let sleeps = await sleepRecorder.all
        #expect(sleeps.first == .milliseconds(500))      // attempt 0、random 0.5
        #expect(box.takeLatest()?.rgba.first == 2)        // 第二源的幀進了 box
        await client.stop()
    }

    /// `stop()` 必須顯式取消顯示串流的底層 RPC——與 `stopCancelsAudioStream` 同一個理由，
    /// 只是這條路徑漏了。`streamScreenshot` 是變化驅動的：guest 畫面靜止時就沒有下一幀，
    /// `next()` 會無限期停住，而 `Task.cancel()` 中斷不了已 in-flight 的 `next()`。
    /// 沒有這一步，`dropChannel()` 會帶著未解決的 NIO promise 去拆 EventLoopGroup。
    @Test func stopCancelsDisplayStream() async throws {
        let mock = MockTransport([.yieldThenHang(1)])
        let client = EmulatorClient(
            makeTransport: { _ in mock },
            makeHealthProbe: { _ in ScriptedProbe([]) },  // 永遠 .healthy
            sleeper: { _ in }
        )
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .milliseconds(300))
        await client.stop()
        #expect(mock.cancelCount >= 1)
    }

    @Test func statesPublishesTransitions() async throws {
        let mock = MockTransport([.yieldThenHang(1)])
        let client = EmulatorClient(
            makeTransport: { _ in mock },
            makeHealthProbe: { _ in ScriptedProbe([]) },  // 永遠 .healthy
            sleeper: { _ in },
            randomSource: { 0.5 }
        )
        // ADAPTATION (compile-forced warning, see task-4-report.md): the brief
        // captures a local `var seen` and mutates it from inside a `Task { }`
        // closure. Under our project's `-strict-concurrency=complete` (Swift
        // language mode v5) this compiles but emits "sending value of
        // non-Sendable type '() async -> ()' risks causing data races; this is
        // an error in the Swift 6 language mode" — i.e. it is a real hazard the
        // compiler will hard-fail on once the toolchain moves past v5. Building
        // the array inside the task and returning it via `.value` removes the
        // shared mutable capture entirely (no captured var at all) while
        // preserving identical observable behaviour, and compiles with zero
        // warnings.
        let statesTask = Task { () -> [ConnState] in
            var seen: [ConnState] = []
            for await s in client.states {
                seen.append(s)
                if s == .connected { break }
            }
            return seen
        }
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        let seen = await statesTask.value
        #expect(seen.suffix(2) == [.connecting, .connected])
        await client.stop()
    }
}

@Suite struct EmulatorClientHealthGateTests {
    @Test func unhealthyProbeIncrementsAttemptThenConnects() async throws {
        // 探測劇本：失敗、逾時、健康 → 應走 reconnecting(0) → reconnecting(1) → connected
        // 版本用 <37（見 ScriptedProbe 說明）：本測試驗證重連狀態機，不是 MMAP 選路，
        // 用 <37 讓 display transport 走 makeTransport(boxCh) 的假件，避免真實 gRPC 連線。
        let probe = ScriptedProbe([.failed, .timedOut, .healthy(version: "36.6.11.0")])
        let mock = MockTransport([.yieldThenHang(9)])
        let recorder = SleepRecorder()
        let client = EmulatorClient(
            makeTransport: { _ in mock },
            makeHealthProbe: { _ in probe },
            sleeper: { d in await recorder.record(d) },
            randomSource: { 0.5 }
        )
        // ADAPTATION (compile-forced warning, same as statesPublishesTransitions
        // above): the brief captures a local `var seen` and mutates it from inside
        // a `Task { }` closure, which under -strict-concurrency=complete emits
        // "sending value of non-Sendable type '() async -> ()' risks causing data
        // races". Building the array inside the task and returning via `.value`
        // removes the shared mutable capture entirely while preserving identical
        // observable behaviour, and compiles with zero warnings.
        let watch = Task { () -> [ConnState] in
            var seen: [ConnState] = []
            for await s in client.states {
                seen.append(s)
                if s == .connected { break }
            }
            return seen
        }
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        let seen = await watch.value
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
        // ADAPTATION (same compile-forced warning as above): build the result
        // inside the task and return it, instead of mutating a captured `var`.
        let watch = Task { () -> Bool in
            var everConnected = false
            var n = 0
            for await s in client.states {
                if s == .connected { everConnected = true }
                n += 1
                if n >= 4 { break }
            }
            return everConnected
        }
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        let everConnected = await watch.value
        #expect(everConnected == false)
        await client.stop()
    }

    @Test func loopNotRecursionUnderManyFailures() async throws {
        // 100 次失敗後健康：迴圈不堆積 async frame（能跑完且最終 connected 即證明）
        // 版本用 <37（見 ScriptedProbe 說明）：避免 makeDisplayTransport() 建立真實
        // MmapStreamTransport 對著無 emulator 監聽的測試 channel 發真實 gRPC 呼叫。
        let probe = ScriptedProbe(Array(repeating: .failed, count: 100) + [.healthy(version: "36.6.11.0")])
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

// 「makeDisplayTransport() 該選哪一種」的窮舉測試已搬到
// DisplayTransportSelectorTests.swift（純函式 DisplayTransportSelector.choose，
// 不碰 channel）。這裡曾經有兩個用真 GrpcChannelBox + 假 transport 驗證選路的
// 測試（Task 6 審查 Important 1 的第一版修法），但把「選哪一種」跟「真 channel
// 的建構」綁在一起測，讓完整套件並行執行時把既有 NIO teardown 競態的命中率從
// 0% 推到約 75%（4 次跑 3 次卡死，實測數據見 task-6-report.md）。移除後，
// 「選哪一種」由純函式測試窮舉覆蓋，「選出來後怎麼建構」在 makeDisplayTransport()
// 裡退化成一個四行 switch，肉眼可驗證；端到端「真的走 MMAP」由 Task 8 活體驗證負責。

@Suite struct LiveSmokeTests {
    @Test func liveStreamDeliversFrames() async throws {
        // 修正案 A 對應：XCTSkipUnless → guard 提前 return（需要活模擬器）。
        // 執行：MIRAGE_LIVE=1 swift test --filter LiveSmokeTests
        guard ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1" else { return }
        let box = LatestFrameBox()
        let client = EmulatorClient()
        await client.start(box: box, width: 540, height: 1200)
        try await Task.sleep(for: .seconds(3))
        // 戳一下讓 change-driven 串流出幀
        await client.sendTap(nx: 0.5, ny: 0.5, down: true)
        await client.sendTap(nx: 0.5, ny: 0.5, down: false)
        try await Task.sleep(for: .seconds(2))
        let frame = box.takeLatest()
        #expect(frame != nil, "5 秒內應收到至少一幀")
        #expect(frame?.width == 540)
        await client.stop()
    }

    /// 觸控座標換算的前提：健康探測必須帶回 guest 的**實體螢幕解析度**，而它與我們請求的
    /// 串流尺寸是兩回事（本機 1080x2400 vs 540x1200，差兩倍）。
    ///
    /// 這條守的是整個 §10 bug 的根：`Touch.x/y` 是 "physical location on the screen"，
    /// 拿串流尺寸換算會讓每次點擊都落在目標的左上一半處。換算本身是純函式
    /// （`NormPoint.guestPixel`，已有單元測試），這裡驗的是「乘數來源正確」。
    ///
    /// 刻意斷言「解析度與串流尺寸不同」而非寫死 1080x2400——後者會綁死在特定 AVD 上。
    @Test func liveHealthProbeCarriesGuestPhysicalResolution() async throws {
        guard ProcessInfo.processInfo.environment["MIRAGE_LIVE"] == "1" else { return }
        let client = EmulatorClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .seconds(3))
        let display = await client.displaySize
        #expect(display != nil, "健康探測必須帶回 hw.lcd.* —— 否則觸控注入會靜默放棄")
        if let display {
            #expect(display.w > 0 && display.h > 0)
            #expect(display.w != 540 || display.h != 1200,
                    "解析度看起來等於串流尺寸(540x1200)，很可能又拿錯了來源")
        }
        await client.stop()
    }
}

// MARK: - suspend()/wake() 不變式回歸測試（Task 4 補審）

actor ConnStateRecorder {
    private(set) var items: [ConnState] = []
    func record(_ s: ConnState) { items.append(s) }
}

actor PowerStateRecorder {
    private(set) var items: [PowerState] = []
    func record(_ p: PowerState) { items.append(p) }
}

/// 輪詢直到條件成立或逾時（比照 FramePumpTests 的 deadline polling 慣例），
/// 回傳是否在期限內達成；逾時回傳 false，呼叫端用 #expect 斷言。
private func waitUntil(
    attempts: Int = 100,
    interval: Duration = .milliseconds(20),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return false
}

@Suite struct EmulatorClientSuspendTests {
    @Test func suspendPreservesConnectionAndDoesNotReconnect() async throws {
        let mock = MockTransport([.yieldThenHang(1)])
        let client = EmulatorClient(
            makeTransport: { _ in mock },
            makeHealthProbe: { _ in ScriptedProbe([]) },      // 永遠 .healthy
            sleeper: { _ in },
            randomSource: { 0.5 }
        )

        // 在 start 之前訂閱，避免漏收任何轉移；單一 consumer 各自佔一條 stream。
        let connRecorder = ConnStateRecorder()
        let powerRecorder = PowerStateRecorder()
        let statesTask = Task { for await s in client.states { await connRecorder.record(s) } }
        let powerTask = Task { for await p in client.powerStates { await powerRecorder.record(p) } }

        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        let reachedConnected = await waitUntil { await connRecorder.items.last == .connected }
        #expect(reachedConnected)
        #expect(mock.subscribeCount == 1)   // connectedRun() 的唯一一次 attach

        await client.suspend()
        let reachedSuspended = await waitUntil { await powerRecorder.items.last == .suspended }
        #expect(reachedSuspended)

        // 核心不變式：suspend 不觸發重連、channel 原封不動保留給 wake() 沿用。
        let powerSeen = await powerRecorder.items
        #expect(powerSeen == [.suspending, .suspended])

        let connSeen = await connRecorder.items
        let sawReconnecting = connSeen.contains { if case .reconnecting = $0 { return true }; return false }
        #expect(!sawReconnecting)
        #expect(connSeen.last == .connected)          // 連線狀態全程停在 .connected
        #expect(mock.subscribeCount == 1)              // 沒有重新訂閱／重建串流

        statesTask.cancel(); powerTask.cancel()
        _ = await statesTask.value; _ = await powerTask.value
        await client.stop()
    }

    @Test func wakeResumesStreamingAfterSuspend() async throws {
        // 兩筆劇本：第一筆供初始連線消耗，第二筆供 wake() 重新 attach 消耗。
        let mock = MockTransport([.yieldThenHang(1), .yieldThenHang(2)])
        let client = EmulatorClient(
            makeTransport: { _ in mock },
            makeHealthProbe: { _ in ScriptedProbe([]) },      // 永遠 .healthy
            sleeper: { _ in },
            randomSource: { 0.5 }
        )

        let connRecorder = ConnStateRecorder()
        let powerRecorder = PowerStateRecorder()
        let statesTask = Task { for await s in client.states { await connRecorder.record(s) } }
        let powerTask = Task { for await p in client.powerStates { await powerRecorder.record(p) } }

        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        #expect(await waitUntil { await connRecorder.items.last == .connected })

        await client.suspend()
        #expect(await waitUntil { await powerRecorder.items.last == .suspended })
        #expect(mock.subscribeCount == 1)

        await client.wake()
        #expect(await waitUntil { await powerRecorder.items.last == .active })

        let powerSeen = await powerRecorder.items
        #expect(powerSeen == [.suspending, .suspended, .waking, .active])
        #expect(mock.subscribeCount == 2)              // wake() 恢復拉幀，重新 attach
        // 連線狀態全程仍停在 .connected（wake 期間同樣不曾重連）。
        let connSeen = await connRecorder.items
        let sawReconnecting = connSeen.contains { if case .reconnecting = $0 { return true }; return false }
        #expect(!sawReconnecting)
        #expect(connSeen.last == .connected)

        statesTask.cancel(); powerTask.cancel()
        _ = await statesTask.value; _ = await powerTask.value
        await client.stop()
    }
}
