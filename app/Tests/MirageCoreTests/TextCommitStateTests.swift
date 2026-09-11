import Testing
@testable import MirageCore

@Suite struct TextCommitStateTests {
    @Test(arguments: [100, 250, 713]) func holdUsesPolicySnapshot(_ milliseconds: Int) throws {
        let commit = TextCommit(text: "你好🙂", generation: 4)
        let policy = try TextSubmissionPolicy(settleMilliseconds: milliseconds)
        let queued = TextCommitState(commit: commit, policy: policy)
        #expect(queued.advanced(to: .seconds(20)).result == nil)
        let waiting = queued.preparing().dispatching().settling(at: .seconds(1))
        #expect(waiting.advanced(to: .seconds(1) + .milliseconds(milliseconds - 1)).result == nil)
        #expect(waiting.advanced(to: .seconds(1) + .milliseconds(milliseconds)).result?.outcome == .submittedUnverified)
    }
    @Test func outcomeDependsOnDispatchBoundaryAndRetainsText() throws {
        let commit = TextCommit(text: "e\u{301}👩‍💻", generation: 9)
        let state = TextCommitState(commit: commit, policy: try TextSubmissionPolicy())
        #expect(state.failing(.readbackTimeout).result?.outcome == .failedBeforePaste(.readbackTimeout))
        #expect(state.cancelling(.staleSession).result?.outcome == .cancelledBeforeDispatch(.staleSession))
        let sent = state.dispatching()
        #expect(sent.failing(.transport("timeout")).result?.outcome == .indeterminateAfterDispatch(.transport("timeout")))
        #expect(sent.cancelling(.staleSession).result?.outcome == .indeterminateAfterDispatch(.staleSession))
        #expect(sent.cancelling().result?.commit.id == commit.id)
        #expect(TextContent.exactlyEqual(sent.cancelling().result!.commit.text, commit.text))
    }
    @Test func duplicateIDsDifferFromDuplicateStrings() {
        let a = TextCommit(text: "你好", generation: 1)
        let b = TextCommit(text: "你好", generation: 1)
        let first = TextCommitLedger().admitting(a)
        #expect(first.accepted)
        #expect(!first.ledger.admitting(a).accepted)
        #expect(first.ledger.admitting(b).accepted)
        #expect(!TextContent.exactlyEqual("é", "e\u{301}"))
    }
    @Test func deferredConsumerShowsTheRealRaceAndPolicyPreventsEarlyOverwrite() throws {
        var unsafe = DeferredPasteConsumer()
        unsafe.setClipboard("A"); unsafe.pasteRPC()
        unsafe.setClipboard("B"); unsafe.pasteRPC()
        unsafe.consumeOne(); unsafe.consumeOne()
        #expect(unsafe.inserted == ["B", "B"])
        var controlled = DeferredPasteConsumer()
        controlled.setClipboard("A"); controlled.pasteRPC()
        let state = TextCommitState(commit: TextCommit(text: "A", generation: 1),
                                    policy: try TextSubmissionPolicy(settleMilliseconds: 250))
            .dispatching().settling(at: .zero)
        if state.advanced(to: .milliseconds(249)).result != nil { controlled.setClipboard("B") }
        controlled.consumeOne()
        #expect(controlled.inserted == ["A"])
        #expect(state.advanced(to: .milliseconds(250)).result?.outcome == .submittedUnverified)
        controlled.setClipboard("B"); controlled.pasteRPC(); controlled.consumeOne()
        #expect(controlled.inserted == ["A", "B"])
    }
}
