/// 剪貼簿方向。
public enum ClipDirection: Equatable, Sendable {
    case guestToHost, hostToGuest
}

/// 防回音純狀態：記錄最後一次傳播的值；同值再來即不傳播（切斷 A→B→A 迴圈，兼作去重）。
/// 不可變——shouldPropagate 回傳新狀態，不原地改。
public struct ClipboardBridge: Equatable, Sendable {
    private let lastValue: String?

    public init(lastValue: String? = nil) { self.lastValue = lastValue }

    public func shouldPropagate(value: String, direction: ClipDirection)
        -> (propagate: Bool, next: ClipboardBridge)
    {
        if value == lastValue {
            return (false, self)                 // 回音或重複 → 不傳播
        }
        return (true, ClipboardBridge(lastValue: value))
    }
}
