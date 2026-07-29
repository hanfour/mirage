import Foundation

/// 一段時間內的延遲樣本，用來回答「按下去到看到反應要多久」。
///
/// **為什麼需要它**：`MIRAGE_FPS_LOG` 的 `fps=` 只回答「畫面多久換一次」，
/// 回答不了延遲——而輸入延遲 <80ms 是母計畫 §7 Phase-1 的驗收線之一，
/// 到 2026-07-29 為止從未在 Mirage 這條路徑上量過。
///
/// **為什麼要 p95 而不只是平均**：使用者感覺到的「頓」來自長尾。實測同一條串流
/// p50=28.8ms 但 p95=78.2ms（見 `docs/specs/2026-07-28-mirror-never-rendered-investigation.md`
/// §11）——只看平均會得出「很順」的錯誤結論。
///
/// 純值語意、無 I/O，故可完整單元測試。取樣與輸出的時機由呼叫端決定。
public struct LatencyWindow: Sendable {
    private var samples: [Double] = []

    public init() {}

    public mutating func record(_ milliseconds: Double) {
        samples.append(milliseconds)
    }

    /// 直接收 `Duration`，換算在這裡做一次就好。
    ///
    /// `Duration.components` 是 `(seconds, attoseconds)`；1 毫秒 = 1e15 attoseconds。
    /// 這個換算寫在呼叫端就會有第二份、第三份，而它錯了不會崩、只會讓所有延遲
    /// 數字靜默偏掉——這個專案已經在「乘錯尺寸」上付過一次同樣的學費。
    public mutating func record(_ duration: Duration) {
        let c = duration.components
        samples.append(Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15)
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// nil = 這一窗還沒有任何樣本。**刻意不回傳 0**——「沒有樣本」與「延遲為 0」
    /// 是完全不同的兩件事，用同一個值表示會讓讀 log 的人分不出來，
    /// 那正是本專案在 `fps=` 上已經踩過的坑（見 §8：計數點錯位讓 0 與「沒畫」混淆）。
    public func summary() -> (p50: Double, p95: Double, count: Int)? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return (percentile(sorted, 0.50), percentile(sorted, 0.95), sorted.count)
    }

    /// 最近鄰百分位（nearest-rank）。刻意不做線性內插——樣本數少時內插出來的值
    /// 不對應任何真實觀測，而這裡的每一個樣本都是一次真實的幀。
    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
