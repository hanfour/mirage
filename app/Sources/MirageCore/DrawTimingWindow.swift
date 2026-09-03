/// 一秒窗口內的 draw 時序統計。
///
/// `interval` 與 `duration` 都以毫秒傳入。窗口只保留耗時樣本，因為 p95
/// 需要排序，而 draw 每秒最多只有幾百次。
public struct DrawTimingWindow: Sendable {
    /// 一次 draw 可以同時沒有新幀與 drawable，故用旗標而不是互斥列舉。
    public struct Outcome: OptionSet, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let presented = Outcome(rawValue: 1 << 0)
        public static let noDrawable = Outcome(rawValue: 1 << 1)
        public static let noFrame = Outcome(rawValue: 1 << 2)
    }

    public private(set) var calls = 0
    public private(set) var gapOver20ms = 0
    public private(set) var maxGapMs = 0
    public private(set) var noDrawable = 0
    public private(set) var noFrame = 0

    private var durations: [Double] = []

    public init() {}

    /// 記錄一次 draw。沒有 interval 代表這是窗口或程序的第一個 draw。
    ///
    /// 沒有成功 commit 的早退路徑應傳入 nil duration，避免把早退時間算進
    /// `inP95Ms`。`noFrame` 與 `noDrawable` 可在同一個 outcome 中並存。
    public mutating func record(interval: Double?,
                                duration: Double?,
                                outcome: Outcome) {
        calls += 1

        if let interval, interval.isFinite {
            let milliseconds = max(0.0, interval)
            if milliseconds > 20.0 { gapOver20ms += 1 }
            maxGapMs = max(maxGapMs, Int(milliseconds.rounded()))
        }

        if outcome.contains(.noDrawable) { noDrawable += 1 }
        if outcome.contains(.noFrame) { noFrame += 1 }

        if let duration, duration.isFinite, !outcome.contains(.noDrawable) {
            durations.append(max(0.0, duration))
        }
    }

    /// 窗口內 commit 耗時的 nearest-rank p95，沒有成功 commit 樣本時為 0。
    public var inP95Ms: Double {
        guard !durations.isEmpty else { return 0.0 }
        let sorted = durations.sorted()
        let rank = max(1, Int((0.95 * Double(sorted.count)).rounded(.up)))
        let value = sorted[rank - 1]
        return (value * 10.0).rounded() / 10.0
    }

    public mutating func reset() {
        calls = 0
        gapOver20ms = 0
        maxGapMs = 0
        noDrawable = 0
        noFrame = 0
        durations.removeAll(keepingCapacity: true)
    }
}
