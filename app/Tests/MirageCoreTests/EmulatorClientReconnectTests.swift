import Foundation
import Testing
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

    @Test func statesPublishesTransitions() async throws {
        let mock = MockTransport([.yieldThenHang(1)])
        let client = EmulatorClient(
            makeTransport: { _ in mock },
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
        await client.sendTap(x: 540, y: 1200, down: true)
        await client.sendTap(x: 540, y: 1200, down: false)
        try await Task.sleep(for: .seconds(2))
        let frame = box.takeLatest()
        #expect(frame != nil, "5 秒內應收到至少一幀")
        #expect(frame?.width == 540)
        await client.stop()
    }
}
