// 本檔的 mutating 呼叫一律先存區域變數再進 #expect／#require：
// 巨集會把運算元捕捉成不可變的，直接寫會編不過。
import Testing
import MirageCore
@testable import MirageShell

@Suite struct FpsWindowTests {
    private func counters(_ arrived: Int = 0, _ dropped: Int = 0) -> FrameCounterSnapshot {
        FrameCounterSnapshot(arrived: arrived, dropped: dropped, rejected: 0)
    }

    @Test func beforeBoundaryDoesNotReportOrReadCounters() {
        var window = FpsWindow(startedAt: 10, counters: counters())
        var reads = 0
        let report = window.record(presented: true, at: 10.999) {
            reads += 1
            return counters(1)
        }
        #expect(report == nil)
        #expect(reads == 0)
    }

    @Test func exactBoundaryReportsOnceAndResets() throws {
        var window = FpsWindow(startedAt: 10, counters: counters())
        let earlyReport = window.record(presented: true, at: 10.5, counters: { counters(1) })
        #expect(earlyReport == nil)
        let firstOptional = window.record(presented: true, at: 11, counters: { counters(2) })
        let first = try #require(firstOptional)
        #expect(first.elapsed == 1)
        #expect(first.presented == 2)
        #expect(first.fps == 2)
        let sameTimeReport = window.record(presented: true, at: 11, counters: { counters(3) })
        #expect(sameTimeReport == nil)
        let secondOptional = window.record(presented: true, at: 12, counters: { counters(4) })
        let second = try #require(secondOptional)
        #expect(second.presented == 2)
        #expect(second.frames.arrived == 2)
    }

    @Test func overshootStartsFreshAtEventTime() throws {
        var window = FpsWindow(startedAt: 10, counters: counters())
        let firstOptional = window.record(presented: true, at: 11.5, counters: { counters(1) })
        let first = try #require(firstOptional)
        #expect(first.elapsed == 1.5)
        let earlyReport = window.record(presented: true, at: 12, counters: { counters(2) })
        #expect(earlyReport == nil)
        let secondOptional = window.record(presented: true, at: 12.5, counters: { counters(3) })
        let second = try #require(secondOptional)
        #expect(second.elapsed == 1)
        #expect(second.presented == 2)
    }

    @Test func consecutiveWindowsKeepFramesAndDrawsSeparate() throws {
        var window = FpsWindow(startedAt: 0, counters: counters(10, 2))
        window.recordDraw(interval: 30, duration: nil, outcome: [.noFrame, .noDrawable])
        window.recordDraw(interval: 10, duration: 4, outcome: [])
        let earlyReport = window.record(presented: true, at: 0.5, counters: { counters(12, 3) })
        #expect(earlyReport == nil)
        window.recordDraw(interval: 15, duration: 2, outcome: [])
        let firstOptional = window.record(presented: true, at: 1, counters: { counters(15, 5) })
        let first = try #require(firstOptional)
        #expect(first.frames.arrived == 5)
        #expect(first.frames.dropped == 3)
        #expect(first.frames.presented == 2)
        #expect(first.draw.calls == 3)
        #expect(first.draw.gapOver20ms == 1)
        #expect(first.draw.maxGapMs == 30)
        #expect(first.draw.inP95Ms == 4)
        #expect(first.draw.noFrame == 1)
        #expect(first.draw.noDrawable == 1)

        window.recordDraw(interval: 16, duration: 1, outcome: [])
        let secondOptional = window.record(presented: true, at: 2, counters: { counters(16, 5) })
        let second = try #require(secondOptional)
        #expect(second.presented == 1)
        #expect(second.frames.arrived == 1)
        #expect(second.frames.dropped == 0)
        #expect(second.frames.presented == 1)
        #expect(second.draw.calls == 1)
        #expect(second.draw.gapOver20ms == 0)
        #expect(second.draw.maxGapMs == 16)
        #expect(second.draw.inP95Ms == 1)
        #expect(second.draw.noFrame == 0)
        #expect(second.draw.noDrawable == 0)
        #expect(first.draw.calls == 3)
    }

    @Test func noPresentDoesNotReportEvenAfterDeadline() throws {
        var window = FpsWindow(startedAt: 0, counters: counters())
        var reads = 0
        for now in [0.5, 1.0, 3.0] {
            window.recordDraw(interval: nil, duration: nil, outcome: .noFrame)
            let report = window.record(presented: false, at: now) {
                reads += 1
                return counters(50)
            }
            #expect(report == nil)
        }
        #expect(reads == 0)
        let resumedOptional = window.record(presented: true, at: 4, counters: { counters(1) })
        let resumed = try #require(resumedOptional)
        #expect(resumed.elapsed == 4)
        #expect(resumed.presented == 1)
        #expect(resumed.frames.arrived == 1)
        #expect(resumed.draw.noFrame == 3)
    }

    @Test func stalledWindowReportsActualElapsedAndRoundedRate() throws {
        var window = FpsWindow(startedAt: 10, counters: counters())
        let earlyReport = window.record(presented: true, at: 10.25, counters: { counters(1) })
        #expect(earlyReport == nil)
        let reportOptional = window.record(presented: true, at: 13.25, counters: { counters(20, 18) })
        let report = try #require(reportOptional)
        #expect(report.elapsed == 3.25)
        #expect(report.presented == 2)
        #expect(report.fps == 1)
        #expect(report.frames.arrived == 20)
        #expect(report.frames.dropped == 18)
        var frozen = FpsWindow(startedAt: 0, counters: counters())
        let singleOptional = frozen.record(presented: true, at: 3, counters: { counters(1) })
        let single = try #require(singleOptional)
        #expect(single.elapsed == 3)
        #expect(single.presented == 1)
        #expect(single.fps == 0)
    }
}
