/// 將無法量測與時鐘無效的樣本分開計數，只有有效值進入延遲統計。
public struct TransitWindow: Sendable {
    public private(set) var latency = LatencyWindow()
    public private(set) var invalid = 0
    public private(set) var unavailable = 0

    public init() {}

    public mutating func record(_ milliseconds: Double?) {
        guard let milliseconds else { unavailable += 1; return }
        guard milliseconds.isFinite, milliseconds >= 0 else { invalid += 1; return }
        latency.record(milliseconds)
    }

    public mutating func reset() {
        latency.reset()
        invalid = 0
        unavailable = 0
    }
}
