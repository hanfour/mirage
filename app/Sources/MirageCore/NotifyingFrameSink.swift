import Foundation

/// 在既有單格信箱上增加一個消費者通知，BroadcastFrameSink 仍可直接 put 到 box。
/// signal 只代表「可能有更新」；像素永遠由 takeLatest 取得，通知最多保留一筆。
/// 新 controller 建立新的訂閱；舊訂閱 finish 不會撤銷後來接手的 observer。
public final class NotifyingFrameSink: FrameSink, Sendable {
    public let box: LatestFrameBox
    public let signals: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    public init(box: LatestFrameBox = LatestFrameBox()) {
        self.box = box
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.signals = signals
        self.continuation = continuation
        box.notifyAfterPut { _ = continuation.yield(()) }
        // 包裝前已存在的幀也有一次取幀機會；空信箱通知是無害的。
        continuation.yield(())
    }

    public func put(_ frame: Frame) { box.put(frame) }
    public func takeLatest() -> Frame? { box.takeLatest() }
    public func stats() -> FrameCounterSnapshot { box.stats() }
    public func finish() { continuation.finish() }
}

/// 純限速決策：nil 表示尚未編碼，立即處理；同一截止時間內的新通知不延後截止時間。
/// 呼叫端等到可編碼時才 takeLatest，避免把過期像素保留到等待結束。
public enum RemoteEncodePacing {
    public static func delay(lastEncodedAt: ContinuousClock.Instant?, now: ContinuousClock.Instant,
                             minimumInterval: Duration) -> Duration {
        guard let lastEncodedAt else { return .zero }
        return max(.zero, minimumInterval - (now - lastEncodedAt))
    }
}
