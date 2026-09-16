import Foundation
import MirageCore

final class FanOutTestAudioSink: AudioSink, @unchecked Sendable {
    private let lock = NSLock()
    private var retained: [[Float]] = []
    private var byteCounts: [Int?] = []
    private let replacementSample: Float?
    private let onWrite: (@Sendable () -> Void)?

    init(replacementSample: Float? = nil, onWrite: (@Sendable () -> Void)? = nil) {
        self.replacementSample = replacementSample
        self.onWrite = onWrite
    }

    var samples: [[Float]] {
        lock.lock()
        defer { lock.unlock() }
        return retained
    }

    var rawByteCounts: [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return byteCounts
    }

    func write(_ samples: [Float], rawByteCount: Int?) {
        lock.lock()
        retained.append(samples)
        byteCounts.append(rawByteCount)
        if let replacementSample, !samples.isEmpty {
            retained[retained.count - 1][0] = replacementSample
        }
        lock.unlock()
        onWrite?()
    }
}
