import Testing
@testable import MirageCore

@Suite struct DrawTimingWindowTests {
    @Test func countsLongGapsAndKeepsTheLargestGap() {
        var window = DrawTimingWindow()

        window.record(interval: nil, duration: 1.0, outcome: .presented)
        window.record(interval: 16.0, duration: 1.0, outcome: .presented)
        window.record(interval: 20.0, duration: 1.0, outcome: .presented)
        window.record(interval: 21.0, duration: 1.0, outcome: .presented)
        window.record(interval: 41.0, duration: 1.0, outcome: .presented)

        #expect(window.calls == 5)
        #expect(window.gapOver20ms == 2)
        #expect(window.maxGapMs == 41)
    }

    @Test func p95UsesNearestRankForTwentySamples() {
        var window = DrawTimingWindow()

        for milliseconds in 1...20 {
            window.record(interval: 16.7,
                         duration: Double(milliseconds),
                         outcome: .presented)
        }

        #expect(window.inP95Ms == 19.0)
    }

    @Test func oneSampleIsTheP95() {
        var window = DrawTimingWindow()
        window.record(interval: nil, duration: 7.5, outcome: .presented)

        #expect(window.inP95Ms == 7.5)
    }

    @Test func noDrawableAndNoFrameAreIndependentCounters() {
        var window = DrawTimingWindow()

        window.record(interval: nil, duration: nil, outcome: .noDrawable)
        window.record(interval: 21.0, duration: nil, outcome: .noFrame)
        window.record(interval: 22.0,
                     duration: nil,
                     outcome: [.noDrawable, .noFrame])

        #expect(window.calls == 3)
        #expect(window.noDrawable == 2)
        #expect(window.noFrame == 2)
        #expect(window.inP95Ms == 0.0)
    }

    @Test func resetClearsCountsAndDurationSamples() {
        var window = DrawTimingWindow()
        window.record(interval: 41.0, duration: 9.0, outcome: .noFrame)

        window.reset()

        #expect(window.calls == 0)
        #expect(window.gapOver20ms == 0)
        #expect(window.maxGapMs == 0)
        #expect(window.inP95Ms == 0.0)
        #expect(window.noDrawable == 0)
        #expect(window.noFrame == 0)
    }
}
