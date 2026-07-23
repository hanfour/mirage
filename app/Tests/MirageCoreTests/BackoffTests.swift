import Testing
@testable import MirageCore

@Suite struct BackoffTests {
    let policy = BackoffPolicy()  // 0.5s base, 8s cap, 0.2 jitter

    @Test func attemptZeroAroundBase() {
        let d = policy.delay(attempt: 0, random: 0.5)  // jitter 中點 = 無偏移
        #expect(d == .milliseconds(500))
    }

    @Test func doublesPerAttempt() {
        #expect(policy.delay(attempt: 1, random: 0.5) == .milliseconds(1000))
        #expect(policy.delay(attempt: 2, random: 0.5) == .milliseconds(2000))
    }

    @Test func capsAtEight() {
        #expect(policy.delay(attempt: 10, random: 0.5) == .seconds(8))
    }

    @Test func jitterBounds() {
        let lo = policy.delay(attempt: 0, random: 0.0)   // -20%
        let hi = policy.delay(attempt: 0, random: 0.999) // ~+20%
        #expect(lo == .milliseconds(400))
        #expect(hi > .milliseconds(590))
        #expect(hi <= .milliseconds(600))
    }
}
