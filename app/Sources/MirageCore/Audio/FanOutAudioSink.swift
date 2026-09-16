import Foundation

/// 樣本陣列的值語意讓下游保留並修改自己的副本，不會影響其他接收者。
public final class FanOutAudioSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var downstreamSinks: [any AudioSink]

    public var sinks: [any AudioSink] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return downstreamSinks
        }
        set {
            lock.lock()
            let previous = downstreamSinks
            downstreamSinks = newValue
            lock.unlock()
            // 舊 sink 的解構可能重入，因此延後到解鎖後才釋放。
            withExtendedLifetime(previous) {}
        }
    }

    public init(sinks: [any AudioSink] = []) {
        self.downstreamSinks = sinks
    }

    public func write(_ samples: [Float], rawByteCount: Int? = nil) {
        // 快照保住本次接收者的所有權，解鎖後才呼叫下游以免重入死鎖。
        let sinks = self.sinks
        for sink in sinks {
            sink.write(samples, rawByteCount: rawByteCount)
        }
    }
}
