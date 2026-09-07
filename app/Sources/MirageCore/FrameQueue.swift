import Foundation

/// 有限深度的 FIFO 幀佇列。
///
/// `takeLatest()` 在這個型別裡仍是呼叫端沿用的名稱，但實際語意是取出佇列中最舊的
/// 一幀。佇列滿時丟棄最舊幀，讓新抵達的幀可以入列。
public final class FrameQueue: FrameSink, @unchecked Sendable {
    public let depth: Int

    private let lock = NSLock()
    private var frames: [Frame] = []
    private var arrived = 0
    private var dropped = 0
    private var rejected = 0

    public init(depth: Int) {
        precondition(depth >= 1, "FrameQueue depth 必須至少為 1")
        self.depth = depth
    }

    /// 目前佇列內尚未取出的幀數。
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    public func put(_ frame: Frame) {
        lock.lock()
        defer { lock.unlock() }

        guard frame.isValid else {
            rejected += 1
            return
        }

        arrived += 1
        if frames.count == depth {
            frames.removeFirst()
            dropped += 1
        }
        frames.append(frame)
    }

    public func takeLatest() -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    public func stats() -> FrameCounterSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return FrameCounterSnapshot(arrived: arrived, dropped: dropped, rejected: rejected)
    }
}
