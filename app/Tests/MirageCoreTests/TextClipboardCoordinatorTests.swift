import Testing
@testable import MirageCore

@Suite struct TextClipboardCoordinatorTests {
    @Test func ownAndLateEchoesDoNotWriteHostClipboard() throws {
        let c = TextClipboardCoordinator(policy: .success(try TextSubmissionPolicy()), clock: AdvancingTextClock().clock)
        c.rememberOwnWrite("A"); c.rememberOwnWrite("B")
        #expect(!c.observeGuestClipboard("A"))
        #expect(!c.observeGuestClipboard("A"))
        #expect(!c.observeGuestClipboard("B"))
        #expect(c.observeGuestClipboard("C"))
        c.rememberOwnWrite("é")
        #expect(c.observeGuestClipboard("e\u{301}"))
    }
    @Test func hostWriteIsUnavailableWhileTransactionOwnsClipboard() throws {
        let c = TextClipboardCoordinator(policy: .success(try TextSubmissionPolicy()), clock: AdvancingTextClock().clock)
        let a = TextCommit(text: "A", generation: 0)
        guard case .accepted(let admission) = c.reserve(a) else {
            Issue.record("admission failed")
            return
        }
        #expect(c.begin(a, admission: admission) == nil)
        let revision = c.hostClipboardChanged("C")
        #expect(c.hostValue(for: revision) == nil)
        _ = c.finish(TextCommitResult(commit: a, outcome: .submittedUnverified))
        #expect(c.hostValue(for: revision) == "C")
    }
    @Test func queuedPolicyIsASnapshotAndInvalidConfigDoesNotDropText() throws {
        let c = TextClipboardCoordinator(policy: .success(try TextSubmissionPolicy(settleMilliseconds: 713)), clock: AdvancingTextClock().clock)
        let a = TextCommit(text: "A", generation: 0)
        guard case .accepted(let admission) = c.reserve(a) else {
            Issue.record("admission failed")
            return
        }
        c.setPolicy(.success(try TextSubmissionPolicy(settleMilliseconds: 100)))
        #expect(admission.policy.settleDelay == .milliseconds(713))
        c.setPolicy(.failure(.invalidPolicy("bad")))
        let b = TextCommit(text: "B", generation: 0)
        guard case .rejected(let result) = c.reserve(b) else {
            Issue.record("invalid policy accepted")
            return
        }
        #expect(result.outcome == .rejected(.invalidPolicy("bad")))
        #expect(result.commit.text == "B")
    }
    @Test func repeatedOwnValueRefreshesBoundedEchoHistory() throws {
        let c = TextClipboardCoordinator(policy: .success(try TextSubmissionPolicy()), clock: AdvancingTextClock().clock)
        c.rememberOwnWrite("A")
        for i in 0..<63 { c.rememberOwnWrite("value-\(i)") }
        c.rememberOwnWrite("A")
        c.rememberOwnWrite("new-value")
        #expect(!c.observeGuestClipboard("A"))
    }

}
