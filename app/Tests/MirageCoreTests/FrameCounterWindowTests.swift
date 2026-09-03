import Testing
@testable import MirageCore

@Suite struct FrameCounterWindowTests {
    @Test func computesDeltasFromTwoSnapshots() {
        let before = FrameCounterSnapshot(arrived: 100, dropped: 12, rejected: 3)
        let after = FrameCounterSnapshot(arrived: 158, dropped: 19, rejected: 4)

        let window = FrameCounterWindow(before: before, after: after, presented: 55)

        #expect(window.arrived == 58)
        #expect(window.dropped == 7)
        #expect(window.presented == 55)
    }

    @Test func clampsBackwardsSnapshotsAndPresentedCountToZero() {
        let before = FrameCounterSnapshot(arrived: 20, dropped: 8, rejected: 2)
        let after = FrameCounterSnapshot(arrived: 19, dropped: 7, rejected: 1)

        let window = FrameCounterWindow(before: before, after: after, presented: -1)

        #expect(window.arrived == 0)
        #expect(window.dropped == 0)
        #expect(window.presented == 0)
    }
}
