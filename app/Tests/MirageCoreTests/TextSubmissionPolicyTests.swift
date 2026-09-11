import Testing
@testable import MirageCore

@Suite struct TextSubmissionPolicyTests {
    @Test func configurationIsExplicitAndAdjustable() throws {
        #expect(try TextSubmissionPolicy.from(environment: [:]).settleDelay == .milliseconds(250))
        #expect(try TextSubmissionPolicy.from(environment: ["MIRAGE_TEXT_SETTLE_MS":"137"]).settleDelay == .milliseconds(137))
    }
    @Test(arguments: ["0", "-1", "bad", "", "1.5", "NaN", "Infinity", "9999999999999999999999999"])
    func rejectsInvalidSetting(_ value: String) {
        #expect(throws: (any Error).self) {
            try TextSubmissionPolicy.from(environment: ["MIRAGE_TEXT_SETTLE_MS":value])
        }
    }
    @Test func rejectsInvalidResourceLimits() {
        #expect(throws: (any Error).self) { try TextSubmissionPolicy(rpcTimeoutMilliseconds: 0) }
        #expect(throws: (any Error).self) { try TextSubmissionPolicy(readbackTimeoutMilliseconds: -1) }
        #expect(throws: (any Error).self) { try TextSubmissionPolicy(queueTimeoutMilliseconds: 0) }
        #expect(throws: (any Error).self) { try TextSubmissionPolicy(maxPending: 0) }
    }
}
