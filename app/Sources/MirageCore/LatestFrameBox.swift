import Foundation

public struct FrameCounterSnapshot: Sendable, Equatable {
    public let arrived: Int
    public let dropped: Int
    public let rejected: Int

    public init(arrived: Int, dropped: Int, rejected: Int) {
        self.arrived = arrived
        self.dropped = dropped
        self.rejected = rejected
    }
}

/// 單格最新幀信箱：收幀端 put、渲染端每 vsync 同步 takeLatest。
/// drop-late 語意天生成立——消費不及的幀被覆蓋並計數。
public final class LatestFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Frame?
    private var arrived = 0
    private var dropped = 0
    private var rejected = 0

    public init() {}

    public func put(_ frame: Frame) {
        guard frame.isValid else {
            lock.lock(); rejected += 1; lock.unlock()
            return
        }
        lock.lock()
        arrived += 1
        if latest != nil { dropped += 1 }
        latest = frame
        lock.unlock()
    }

    public func takeLatest() -> Frame? {
        lock.lock()
        defer { latest = nil; lock.unlock() }
        return latest
    }

    public func stats() -> FrameCounterSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return FrameCounterSnapshot(arrived: arrived, dropped: dropped, rejected: rejected)
    }
}
