import Testing
@testable import MirageCore

/// 延遲統計視窗。存在的理由：`MIRAGE_FPS_LOG` 只回答「畫面多久換一次」，
/// 回答不了「按下去到看到反應要多久」——而後者是母計畫 §7 Phase-1 的驗收線之一
/// （<80ms），到 2026-07-29 為止**從未在 Mirage 這條路徑上量過**。
///
/// 2026-07-29 用 Python harness 量到 gRPC 路徑 p50=78.1ms，但那條路徑完全不經過
/// Mirage，所以是下界。要知道 Mirage 這一段貢獻多少，才知道該優化傳輸還是渲染。
@Suite struct LatencyWindowTests {
    @Test func summaryIsNilBeforeAnySample() {
        var w = LatencyWindow()
        #expect(w.summary() == nil)
        w.record(1.0)
        #expect(w.summary() != nil)
    }

    /// p50 取中位數。奇數個樣本時是正中間那個。
    @Test func p50IsTheMedian() {
        var w = LatencyWindow()
        for ms in [30.0, 10.0, 20.0] { w.record(ms) }
        #expect(w.summary()?.p50 == 20.0)
    }

    /// p95 必須是「高延遲那一端」的代表值。這條比 p50 重要——
    /// 使用者感覺到的「頓」來自長尾，不是平均（見調查記錄 §11：同一條串流
    /// p50=28.8ms 但 p95=78.2ms）。
    @Test func p95ReflectsTheTail() {
        var w = LatencyWindow()
        for ms in stride(from: 1.0, through: 100.0, by: 1.0) { w.record(ms) }
        let s = w.summary()
        #expect(s?.count == 100)
        #expect(s!.p95 >= 95.0, "p95 應落在高端，實得 \(s!.p95)")
        #expect(s!.p95 <= 100.0)
        #expect(s!.p50 >= 50.0 && s!.p50 <= 51.0)
    }

    @Test func singleSampleIsBothP50AndP95() {
        var w = LatencyWindow()
        w.record(42.0)
        #expect(w.summary()?.p50 == 42.0)
        #expect(w.summary()?.p95 == 42.0)
    }

    /// reset 之後重新開始——每秒一窗，不讓舊樣本污染新的統計。
    @Test func resetClearsSamples() {
        var w = LatencyWindow()
        w.record(10.0)
        w.reset()
        #expect(w.summary() == nil)
        w.record(99.0)
        #expect(w.summary()?.p50 == 99.0)
    }

    /// 記錄順序不影響結果——百分位是對排序後的樣本取的。
    @Test func orderDoesNotMatter() {
        var ascending = LatencyWindow()
        var descending = LatencyWindow()
        for ms in [5.0, 15.0, 25.0, 35.0] { ascending.record(ms) }
        for ms in [35.0, 25.0, 15.0, 5.0] { descending.record(ms) }
        #expect(ascending.summary()?.p50 == descending.summary()?.p50)
        #expect(ascending.summary()?.p95 == descending.summary()?.p95)
    }

    /// `Duration` → 毫秒的換算。錯了不會崩，只會讓所有延遲數字靜默偏掉——
    /// 而這個專案已經在「乘錯尺寸」上付過一次同樣的學費（見調查記錄 §10）。
    @Test func convertsDurationToMilliseconds() {
        var w = LatencyWindow()
        w.record(Duration.milliseconds(250))
        #expect(w.summary()?.p50 == 250.0)

        w.reset()
        w.record(Duration.seconds(2))
        #expect(w.summary()?.p50 == 2000.0)

        w.reset()
        w.record(Duration.microseconds(1500))   // 1.5ms
        #expect(w.summary()?.p50 == 1.5)
    }

    /// 秒與次秒的部分都要算進去——只取其中一半是很自然的寫錯方式。
    @Test func convertsMixedSecondsAndSubsecond() {
        var w = LatencyWindow()
        w.record(Duration.seconds(1) + Duration.milliseconds(500))
        #expect(w.summary()?.p50 == 1500.0)
    }
}
