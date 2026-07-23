import Foundation

public struct BackoffPolicy: Sendable {
    public let base: Duration
    public let cap: Duration
    public let jitterRatio: Double

    public init(base: Duration = .milliseconds(500),
                cap: Duration = .seconds(8),
                jitterRatio: Double = 0.2) {
        self.base = base
        self.cap = cap
        self.jitterRatio = jitterRatio
    }

    /// random ∈ [0,1) 由呼叫端注入（測試可決定論）。
    public func delay(attempt: Int, random: Double) -> Duration {
        let baseMs = Double(base.components.seconds) * 1000
            + Double(base.components.attoseconds) / 1e15
        let capMs = Double(cap.components.seconds) * 1000
            + Double(cap.components.attoseconds) / 1e15
        let raw = min(baseMs * pow(2, Double(max(attempt, 0))), capMs)
        let jitter = 1.0 + jitterRatio * (random * 2 - 1)
        return .milliseconds(Int64((raw * jitter).rounded()))
    }
}
