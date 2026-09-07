/// 幀接收端的共同介面。
///
/// `takeLatest()` 在 `LatestFrameBox` 中代表取最新幀，在 `FrameQueue` 中代表依序取出
/// 最舊幀。名稱保留是為了讓收幀與渲染呼叫端不需要分支。
public protocol FrameSink: Sendable {
    func put(_ frame: Frame)
    func takeLatest() -> Frame?
    func stats() -> FrameCounterSnapshot
}

extension LatestFrameBox: FrameSink {}
