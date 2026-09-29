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

private enum WatchdogOutcome<T: Equatable & Sendable>: Equatable, Sendable {
    case finished(T)
    case watchdogFired
}

/// 刻意不用 task group／async let：兩者離開時都會等子任務，正是要抓的那種卡住。
private func awaitWithWatchdog<T: Equatable & Sendable>(
    _ limit: Duration, _ operation: @escaping @Sendable () async -> T
) async -> WatchdogOutcome<T> {
    let once = WatchdogOnce<T>()
    return await withCheckedContinuation { continuation in
        once.set(continuation)
        Task { once.resume(.finished(await operation())) }
        Task {
            try? await Task.sleep(for: limit)
            once.resume(.watchdogFired)
        }
    }
}

private final class WatchdogOnce<T: Equatable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WatchdogOutcome<T>, Never>?
    private var first: WatchdogOutcome<T>?

    func set(_ continuation: CheckedContinuation<WatchdogOutcome<T>, Never>) {
        lock.lock()
        let early = first
        if early == nil { self.continuation = continuation }
        lock.unlock()
        if let early { continuation.resume(returning: early) }
    }

    func resume(_ outcome: WatchdogOutcome<T>) {
        lock.lock()
        let isFirst = first == nil
        if isFirst { first = outcome }
        let waiting = isFirst ? continuation : nil
        if isFirst { continuation = nil }
        lock.unlock()
        waiting?.resume(returning: outcome)
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
