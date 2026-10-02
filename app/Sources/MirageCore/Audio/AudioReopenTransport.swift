import Foundation

/// 診斷專用：取消後可等待底層 response task 結束，才准許下一個 RPC。
public protocol AwaitableAudioTransport: AudioTransport {
    func cancelStreamAndWait() async
}

/// 保留同一 transport/channel，僅以 10s on / 5s off 切換音訊 RPC。
/// 不重新建立播放器、ring 或畫面串流。預設產品路徑不使用此 wrapper。
public final class AudioReopenTransport: AudioTransport, @unchecked Sendable {
    private let base: any AwaitableAudioTransport
    private let on: Duration
    private let off: Duration
    private let rounds: Int
    private let startEpoch: Double?
    /// 排程晚多久就放棄（fail closed）。診斷用途預設 500 ms；測試驗的是順序與取消，給寬鬆值，
    /// 避免系統一慢就被這道防線中止而與受測行為無關。
    private let lateTolerance: Duration
    private let event: @Sendable (String, Int) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(base: any AwaitableAudioTransport, on: Duration = .seconds(10),
                off: Duration = .seconds(5), rounds: Int = 40, startEpoch: Double? = nil,
                lateTolerance: Duration = .milliseconds(500),
                event: @escaping @Sendable (String, Int) -> Void = { name, round in
                    print(String(format: "[audio-rpc] event=%@ round=%d epoch=%.6f", name, round, Date().timeIntervalSince1970))
                }) {
        self.base = base
        self.on = on
        self.off = off
        self.rounds = rounds
        self.startEpoch = startEpoch
        self.lateTolerance = lateTolerance
        self.event = event
    }

    private func replaceTask(_ newTask: Task<Void, Never>?) -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        let previous = task
        task = newTask
        return previous
    }

    public func packets(format: AudioStreamFormat) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [base, on, off, rounds, startEpoch, lateTolerance, event] in
                defer { continuation.finish() }
                let clock = ContinuousClock()
                do {
                    if let startEpoch {
                        let wait = startEpoch - Date().timeIntervalSince1970
                        guard wait > 0 else { event("late-start-abort", 0); return }
                        try await Task.sleep(for: .seconds(wait))
                    }
                    let origin = clock.now
                    for round in 0..<rounds {
                        try Task.checkCancellation()
                        let planned = origin.advanced(by: (on + off) * round)
                        try await clock.sleep(until: planned)
                        // Fail closed if cancellation or scheduling missed the next planned slot.
                        guard clock.now < planned.advanced(by: lateTolerance) else {
                            event("schedule-late-abort", round + 1); return
                        }
                        event("open", round + 1)
                        let stream = base.packets(format: format)
                        let consumer = Task {
                            do {
                                for try await chunk in stream {
                                    if Task.isCancelled { return }
                                    continuation.yield(chunk)
                                }
                                event("response-ended", round + 1)
                            } catch {
                                event("response-ended", round + 1)
                            }
                        }
                        do {
                            try await clock.sleep(until: planned.advanced(by: on))
                        } catch {
                            base.cancelStream()
                            await base.cancelStreamAndWait()
                            consumer.cancel()
                            await consumer.value
                            throw error
                        }
                        event("cancel", round + 1)
                        await base.cancelStreamAndWait()
                        await consumer.value
                        event("closed", round + 1)
                    }
                    try await clock.sleep(until: origin.advanced(by: (on + off) * rounds))
                    event("complete", rounds)
                } catch {
                    event("aborted", 0)
                }
            }
            replaceTask(task)?.cancel()
            continuation.onTermination = { [weak self] _ in self?.cancelStream() }
        }
    }

    public func cancelStream() {
        replaceTask(nil)?.cancel()
        base.cancelStream()
    }
}
