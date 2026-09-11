import Testing
@testable import MirageCore

@Suite struct TextCommitExecutorTests {
    @Test func unicodeUsesOneClipboardAndOneChordThenWaits() async throws {
        let fake = RecordingTextTransport()
        let time = AdvancingTextClock()
        let commit = TextCommit(text: "é e\u{301}👩‍💻中文", generation: 1)
        let result = await TextCommitExecutor(transport: fake, clock: time.clock)
            .execute(commit, policy: try TextSubmissionPolicy(settleMilliseconds: 137))
        let events = await fake.events
        #expect(events == ["write:\(commit.text)", "read", "key:Control:down", "key:v:down", "key:v:up", "key:Control:up"])
        #expect(time.now == .milliseconds(137))
        #expect(result.outcome == .submittedUnverified)
    }
    @Test func canonicalEquivalenceIsNotClipboardReadbackEquality() async throws {
        let fake = RecordingTextTransport(readOverride: "é")
        let time = AdvancingTextClock()
        let result = await TextCommitExecutor(transport: fake, clock: time.clock)
            .execute(TextCommit(text: "e\u{301}", generation: 1),
                     policy: try TextSubmissionPolicy(readbackTimeoutMilliseconds: 70))
        #expect(result.outcome == .failedBeforePaste(.readbackTimeout))
        let events = await fake.events
        #expect(events.filter { $0.hasPrefix("write:") }.count == 1)
        #expect(!events.contains { $0.hasPrefix("key:") })
        #expect(time.now == .milliseconds(70))
        let limits = await fake.timeouts
        #expect(limits.allSatisfy { $0 > .zero && $0 <= .seconds(2) })
    }
    @Test(arguments: ["write:A", "read", "key:Control:down", "key:v:down", "key:v:up", "key:Control:up"])
    func eachFailureIsClassifiedAndNeverRetriesPaste(_ event: String) async throws {
        let fake = RecordingTextTransport(failEvent: event)
        let result = await TextCommitExecutor(transport: fake, clock: AdvancingTextClock().clock)
            .execute(TextCommit(text: "A", generation: 1), policy: try TextSubmissionPolicy())
        let before = event == "write:A" || event == "read"
        #expect(result.outcome == (before ? .failedBeforePaste(.transport("injected")) : .indeterminateAfterDispatch(.transport("injected"))))
        let events = await fake.events
        #expect(events.filter { $0 == "key:v:down" }.count <= 1)
        if !before {
            #expect(events.suffix(2) == ["key:v:up", "key:Control:up"])
        }
    }
    @Test func staleBeforeClipboardProducesNoOperations() async throws {
        let fake = RecordingTextTransport()
        let result = await TextCommitExecutor(transport: fake, clock: AdvancingTextClock().clock)
            .execute(TextCommit(text: "A", generation: 1), policy: try TextSubmissionPolicy(), validity: { .staleSession })
        #expect(result.outcome == .cancelledBeforeDispatch(.staleSession))
        #expect(await fake.events.isEmpty)
    }
    @Test func cancellationAfterDispatchIsUnknown() async throws {
        let fake = RecordingTextTransport()
        let time = AdvancingTextClock()
        let clock = TextCommitClock(now: { time.now }, sleep: { _ in throw CancellationError() })
        let result = await TextCommitExecutor(transport: fake, clock: clock)
            .execute(TextCommit(text: "A", generation: 1), policy: try TextSubmissionPolicy())
        #expect(result.outcome == .indeterminateAfterDispatch(.cancelled))
        #expect(await fake.events.filter { $0 == "key:v:down" }.count == 1)
    }
    @Test func identicalStringsAreTwoIndependentCommits() async throws {
        let fake = RecordingTextTransport()
        let executor = TextCommitExecutor(transport: fake, clock: AdvancingTextClock().clock)
        for _ in 0..<2 {
            _ = await executor.execute(TextCommit(text: "你好", generation: 1), policy: try TextSubmissionPolicy())
        }
        #expect(await fake.events.filter { $0 == "key:v:down" }.count == 2)
    }
}
