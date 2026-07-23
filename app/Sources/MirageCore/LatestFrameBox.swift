import Foundation

/// 單格最新幀信箱：收幀端 put、渲染端每 vsync 同步 takeLatest。
/// drop-late 語意天生成立——消費不及的幀被覆蓋並計數。
public final class LatestFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Frame?
    private var dropped = 0
    private var rejected = 0

    public init() {}

    public func put(_ frame: Frame) {
        guard frame.isValid else {
            lock.lock(); rejected += 1; lock.unlock()
            return
        }
        lock.lock()
        if latest != nil { dropped += 1 }
        latest = frame
        lock.unlock()
    }

    public func takeLatest() -> Frame? {
        lock.lock()
        defer { latest = nil; lock.unlock() }
        return latest
    }

    public func stats() -> (dropped: Int, rejected: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (dropped, rejected)
    }
}
