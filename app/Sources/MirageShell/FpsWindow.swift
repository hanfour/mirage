import MirageCore

/// 只在新幀 present 時結算窗口。時間由呼叫端傳入，不自行讀時鐘。
struct FpsWindow {
    struct Report {
        let elapsed: Double
        let presented: Int
        let fps: Int
        let frames: FrameCounterWindow
        let draw: DrawTimingWindow
    }

    private var startedAt: Double
    private var count = 0
    private var counters: FrameCounterSnapshot
    private var draw = DrawTimingWindow()

    init(startedAt: Double, counters: FrameCounterSnapshot) {
        self.startedAt = startedAt
        self.counters = counters
    }

    mutating func recordDraw(interval: Double?, duration: Double?, outcome: DrawTimingWindow.Outcome) {
        draw.record(interval: interval, duration: duration, outcome: outcome)
    }

    /// 沒有 present 時即使已超過一秒也不輸出，保留 D47 的凍結時行為。
    mutating func record(presented: Bool, at now: Double,
                         counters snapshot: () -> FrameCounterSnapshot) -> Report? {
        guard presented else { return nil }
        count += 1
        let elapsed = now - startedAt
        guard elapsed >= 1.0 else { return nil }
        // 到界才擷取計數，維持原本每窗口一次的 stats 讀取。
        let end = snapshot()
        let report = Report(elapsed: elapsed, presented: count,
                            fps: Int((Double(count) / elapsed).rounded()),
                            frames: FrameCounterWindow(before: counters, after: end, presented: count),
                            draw: draw)
        count = 0
        counters = end
        draw.reset()
        // 從本次事件重新起算，不保留超過一秒的餘量。
        startedAt = now
        return report
    }
}
