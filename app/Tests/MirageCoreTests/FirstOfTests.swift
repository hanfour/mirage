import Foundation
import Testing
@testable import MirageCore

@Suite struct FirstOfTests {
    /// 這條測試要在 firstOf 退化成「等子任務結束」時變紅，而不是卡住：swift-testing 的
    /// `.timeLimit` 靠取消測試 task 生效，碰上不理會取消的子任務一樣等不到（實測 200 秒未觸發）。
    /// 所以用獨立實作的看門狗等 firstOf，2 秒內沒回來就判失敗。
    @Test func timeoutReturnsWithoutWaitingForCancellationIgnoringOperation() async {
        let gate = FirstOfTestGate()
        let startedAt = ContinuousClock.now
        let outcome = await awaitWithWatchdog(.seconds(2)) {
            await firstOf(timeout: .milliseconds(100)) {
                await gate.wait()
            }
        }
        let elapsed = startedAt.duration(to: .now)
        await gate.release(42)

        #expect(outcome == .finished(nil), "firstOf 應在逾時後回 nil；.watchdogFired 表示 2 秒內沒有返回")
        #expect(elapsed >= .milliseconds(100))
        #expect(elapsed <= .milliseconds(600))
    }

    @Test func operationResultWinsBeforeTimeout() async {
        let result = await firstOf(timeout: .seconds(1)) { 42 }
        #expect(result == 42)
    }
}

private actor FirstOfTestGate {
    private var continuation: CheckedContinuation<Int, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var didEnter = false
    private var releasedValue: Int?

    func wait() async -> Int {
        if let releasedValue { return releasedValue }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            didEnter = true
            enteredContinuation?.resume()
            enteredContinuation = nil
        }
    }

    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { enteredContinuation = $0 }
    }

    func release(_ value: Int) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: value)
        } else {
            releasedValue = value
        }
    }
}
