import Foundation

/// 樣本陣列的值語意讓 secondary 保留或修改自己的副本時，不會影響 primary。
public final class BroadcastAudioSink: AudioSink, @unchecked Sendable {
    public let primary: any AudioSink
    private let lock = NSLock()
    private var secondarySink: (any AudioSink)?

    public var secondary: (any AudioSink)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return secondarySink
        }
        set {
            lock.lock()
            let previous = secondarySink
            secondarySink = newValue
            lock.unlock()
            // 舊 sink 的解構可能重入，因此延後到解鎖後才釋放。
            withExtendedLifetime(previous) {}
        }
    }

    public init(primary: any AudioSink, secondary: (any AudioSink)? = nil) {
        self.primary = primary
        self.secondarySink = secondary
    }

    public func write(_ samples: [Float], rawByteCount: Int? = nil) {
        // 快照持有本次的接收者，避免切換時失去所有權；呼叫外部 sink 不持鎖以免重入死鎖。
        let secondary = self.secondary
        primary.write(samples, rawByteCount: rawByteCount)
        secondary?.write(samples, rawByteCount: rawByteCount)
    }
}
