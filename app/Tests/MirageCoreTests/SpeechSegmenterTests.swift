import Testing
import MirageCore

@Suite struct SpeechSegmenterTests {
    @Test func beginsContinuesAndLeavesOriginalUnchanged() {
        let initial = SpeechSegmenter()
        let (begun, first) = initial.observing(packets: 1)
        let (_, second) = begun.observing(packets: 88)
        #expect(first == .began)
        #expect(second == .continued)
        #expect(initial == SpeechSegmenter())
        #expect(initial.observing(packets: 0).1 == .idle)
        #expect(initial.observing(packets: 1).1 == .began)
        #expect(begun != initial)
    }

    @Test func idleWindowsDoNotConsumeSegmentLimit() {
        let initial = SpeechSegmenter(maxWindows: 3)
        let (idle, event) = initial.observing(packets: 0)
        #expect(event == .idle)
        #expect(idle == initial)
        #expect(idle.observing(packets: 0).1 == .idle)
        #expect(idle.observing(packets: 1).1 == .began)
    }

    @Test func defaultSilenceEndsAndNextPacketBeginsAgain() {
        let (begun, _) = SpeechSegmenter().observing(packets: 1)
        let (ended, event) = begun.observing(packets: 0)
        #expect(event == .ended)
        #expect(ended == SpeechSegmenter())
        #expect(ended.observing(packets: 0).1 == .idle)
        #expect(ended.observing(packets: 1).1 == .began)
    }

    @Test func silenceBoundaryRequiresConsecutiveWindows() {
        let (begun, _) = SpeechSegmenter(silenceWindows: 2).observing(packets: 1)
        let (gap, gapEvent) = begun.observing(packets: 0)
        #expect(gapEvent == .continued)
        let (resumed, resumedEvent) = gap.observing(packets: 1)
        #expect(resumedEvent == .continued)
        let (nextGap, nextGapEvent) = resumed.observing(packets: 0)
        #expect(nextGapEvent == .continued)
        let (ended, endEvent) = nextGap.observing(packets: 0)
        #expect(endEvent == .ended)
        #expect(ended == SpeechSegmenter(silenceWindows: 2))
        #expect(ended.observing(packets: 1).1 == .began)
        #expect(gap.observing(packets: 0).1 == .ended)
    }

    @Test func maximumBoundaryEndsDespiteContinuousPackets() {
        let initial = SpeechSegmenter(maxWindows: 3)
        let (first, firstEvent) = initial.observing(packets: 1)
        let (second, secondEvent) = first.observing(packets: 1)
        let (third, thirdEvent) = second.observing(packets: 1)
        #expect(firstEvent == .began)
        #expect(secondEvent == .continued)
        #expect(thirdEvent == .ended)
        #expect(third == initial)
        let (restarted, restartEvent) = third.observing(packets: 1)
        #expect(restartEvent == .began)
        #expect(restarted == first)
    }

    @Test func silentGapsAlsoCountTowardMaximum() {
        let (first, _) = SpeechSegmenter(silenceWindows: 5, maxWindows: 3)
            .observing(packets: 1)
        let (second, secondEvent) = first.observing(packets: 0)
        let (third, thirdEvent) = second.observing(packets: 0)
        #expect(secondEvent == .continued)
        #expect(thirdEvent == .ended)
        #expect(third.observing(packets: 1).1 == .began)
    }

    @Test func defaultMaximumEndsOnSixtiethWindow() {
        var segmenter = SpeechSegmenter().observing(packets: 1).0
        for _ in 2...59 {
            let (next, event) = segmenter.observing(packets: 1)
            #expect(event == .continued)
            segmenter = next
        }
        let (ended, event) = segmenter.observing(packets: 1)
        #expect(event == .ended)
        #expect(ended.observing(packets: 1).1 == .began)
    }
}
