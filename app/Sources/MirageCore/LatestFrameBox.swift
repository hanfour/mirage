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
    private var onPut: (@Sendable () -> Void)?
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
        let notify = onPut
        lock.unlock()
        notify?()
    }

    /// 單一通知消費者；鎖外回呼，允許通知端同步讀取同一個信箱。
    func notifyAfterPut(_ notify: @escaping @Sendable () -> Void) {
        lock.lock(); onPut = notify; lock.unlock()
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
