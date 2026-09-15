import Foundation

/// 一秒區間的統計；nil 代表沒有有效樣本或未達門檻，不能當成零毫秒。
/// 計數點是提交編碼；encode/send 則只計成功產生 access unit 的回呼。
public struct RemoteLatencySummary: Codable, Sendable, Equatable {
    public struct Percentiles: Codable, Sendable, Equatable {
        public let p50: Double
        public let p95: Double
        public let count: Int
    }

    public let type: String
    public let intervalMs: Double
    public let age: Percentiles?
    public let encode: Percentiles?
    public let send: Percentiles?
    /// 新幀數至少 10 才提供有效 transit 樣本的 p50；heartbeat 不計入門檻。
    public let transitMs: Double?
    public let newFrames: Int
    public let heartbeatFrames: Int
    public var inputRPCsPerSecond: Double = 0
    public var inputCoalesced: Int = 0
}

/// 沿用 LatencyWindow 的 nearest-rank 百分位及 TransitWindow 的無效值過濾。
/// 呼叫端每秒 drain 一次；跨區間的編碼回呼歸入完成時的區間，不錯配前一幀。
public struct RemoteLatencyWindow: Sendable {
    private var age = LatencyWindow()
    private var encode = LatencyWindow()
    private var send = LatencyWindow()
    private var transit = TransitWindow()
    private var newFrames = 0
    private var heartbeatFrames = 0

    public init() {}

    public mutating func recordPull(age duration: Duration, transitMs: Double?, heartbeat: Bool) {
        if heartbeat {
            heartbeatFrames += 1
        } else {
            newFrames += 1
            age.record(duration)
            transit.record(transitMs)
        }
    }

    public mutating func recordCompletion(encode: Duration, send: Duration) {
        self.encode.record(encode)
        self.send.record(send)
    }

    public mutating func drain(interval: Duration) -> RemoteLatencySummary {
        let result = RemoteLatencySummary(
            type: "stats", intervalMs: Self.milliseconds(interval),
            age: Self.percentiles(age), encode: Self.percentiles(encode), send: Self.percentiles(send),
            transitMs: newFrames >= 10 ? transit.latency.summary()?.p50 : nil, newFrames: newFrames, heartbeatFrames: heartbeatFrames)
        self = RemoteLatencyWindow()
        return result
    }

    private static func percentiles(_ window: LatencyWindow) -> RemoteLatencySummary.Percentiles? {
        window.summary().map { .init(p50: $0.p50, p95: $0.p95, count: $0.count) }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
