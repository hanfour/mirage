import Foundation
import Testing
@testable import MirageCore

@Suite struct MmapStallDetectorTests {
    @Test func oneHundredNineteenIdenticalNotificationsDoNotTriggerRawComparison() {
        var detector = MmapStallDetector()
        var compared = false

        for index in 0..<119 {
            let decision = detector.observe(fingerprint: 7, at: Double(index) / 60)
            if case .compareRaw = decision { compared = true }
        }

        let didNotCompare = !compared
        #expect(didNotCompare)
    }

    @Test func oneHundredTwentyIdenticalNotificationsTriggerRawComparison() {
        var detector = MmapStallDetector()
        var lastDecision = MmapStallDetector.Decision.deliver

        for index in 0..<120 {
            lastDecision = detector.observe(fingerprint: 7, at: Double(index) / 60)
        }

        #expect(lastDecision == .compareRaw(repeatedNotifications: 120))
    }

    @Test func differentRawContentMarksMmapUnusable() {
        var detector = detectorAtThreshold()

        let resolution = detector.resolve(.different, at: 2)

        #expect(resolution == .unusable(repeatedNotifications: 120))
    }

    @Test func matchingRawContentResetsCountAndEnforcesThirtySecondCooldown() {
        var detector = detectorAtThreshold()
        let resolution = detector.resolve(.same, at: 2)
        #expect(resolution == .continueMmap)

        var comparedDuringCooldown = false
        for index in 0..<120 {
            let decision = detector.observe(fingerprint: 7, at: 2.1 + Double(index) / 60)
            if case .compareRaw = decision { comparedDuringCooldown = true }
        }
        let cooldownPreventedComparison = !comparedDuringCooldown
        #expect(cooldownPreventedComparison)

        let beforeCooldownEnds = detector.observe(fingerprint: 7, at: 31.99)
        let atCooldownEnd = detector.observe(fingerprint: 7, at: 32)
        #expect(beforeCooldownEnds == .deliver)
        #expect(atCooldownEnd == .compareRaw(repeatedNotifications: 122))
    }

    @Test func failedRawComparisonDoesNotMarkMmapUnusableAndResetsCount() {
        var detector = detectorAtThreshold()

        let resolution = detector.resolve(.failed("RPC 失敗"), at: 2)
        #expect(resolution == .comparisonFailed("RPC 失敗"))

        var decision = MmapStallDetector.Decision.deliver
        for index in 0..<119 {
            decision = detector.observe(fingerprint: 7, at: 3 + Double(index) / 60)
        }
        #expect(decision == .deliver)
        decision = detector.observe(fingerprint: 7, at: 5)
        #expect(decision == .compareRaw(repeatedNotifications: 120))
    }

    @Test func incomparableRawDimensionsDoNotMarkMmapUnusable() {
        var detector = detectorAtThreshold()

        let resolution = detector.resolve(.incomparable(width: 897, height: 1996), at: 2)

        #expect(resolution == .incomparable(width: 897, height: 1996))
    }

    @Test func changedContentResetsTheConsecutiveNotificationCount() {
        var detector = MmapStallDetector()
        for index in 0..<119 {
            let decision = detector.observe(fingerprint: 7, at: Double(index) / 60)
            #expect(decision == .deliver)
        }

        let changedFrame = detector.observe(fingerprint: 8, at: 2)
        #expect(changedFrame == .deliver)

        var decision = MmapStallDetector.Decision.deliver
        for index in 0..<118 {
            decision = detector.observe(fingerprint: 8, at: 2 + Double(index) / 60)
        }
        #expect(decision == .deliver)
        decision = detector.observe(fingerprint: 8, at: 4)
        #expect(decision == .compareRaw(repeatedNotifications: 120))
    }

    private func detectorAtThreshold() -> MmapStallDetector {
        var detector = MmapStallDetector()
        for index in 0..<120 {
            _ = detector.observe(fingerprint: 7, at: Double(index) / 60)
        }
        return detector
    }
}
