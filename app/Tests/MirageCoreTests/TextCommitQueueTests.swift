import Testing
@testable import MirageCore

actor ConsumingTextTransport: TextCommitTransport, InputInjecting {
    let time: AdvancingTextClock
    let consumptionDelay: Duration
    var clipboard = ""
    var writes: [String] = []
    var inserted: [String] = []
    var keys: [String] = []
    var due: [Duration] = []
    var onFirstPaste: (@Sendable () -> Void)?
    var onFirstTick: (@Sendable () -> Void)?
    var externalAtTick: String?
    var blockTicks = false
    var tickWaiter: CheckedContinuation<Void, Never>?
    var tickObserver: CheckedContinuation<Void, Never>?
    var shouldBlockRead: Bool
    var readWaiter: CheckedContinuation<Void, Never>?
    var blockedObserver: CheckedContinuation<Void, Never>?
    init(time: AdvancingTextClock, consumptionDelay: Duration = .milliseconds(100), blockRead: Bool = false) {
        self.time = time; self.consumptionDelay = consumptionDelay; shouldBlockRead = blockRead
    }
    func armPaste(_ action: @escaping @Sendable () -> Void) { onFirstPaste = action }
    func armExternal(value: String, action: @escaping @Sendable () -> Void) { externalAtTick = value; onFirstTick = action }
    func writeTextClipboard(_ text: String, timeout: Duration) async throws { clipboard = text; writes.append(text) }
    func readTextClipboard(timeout: Duration) async throws -> String {
        if shouldBlockRead {
            shouldBlockRead = false
            await withCheckedContinuation { readWaiter = $0; blockedObserver?.resume(); blockedObserver = nil }
        }
        return clipboard
    }
    func waitForBlockedRead() async {
        if readWaiter != nil { return }
        await withCheckedContinuation { blockedObserver = $0 }
    }
    func unblockRead() { readWaiter?.resume(); readWaiter = nil }
    func sendTextKey(_ key: String, down: Bool, timeout: Duration) async throws {
        keys.append("\(key):\(down)")
        if key == "v", down {
            due.append(time.now + consumptionDelay)
            let action = onFirstPaste; onFirstPaste = nil; action?()
        }
    }
    func holdConsumption() { blockTicks = true }
    func waitForBlockedTick() async {
        if tickWaiter != nil { return }
        await withCheckedContinuation { tickObserver = $0 }
    }
    func releaseConsumption() { blockTicks = false; tickWaiter?.resume(); tickWaiter = nil }
    func tick() async {
        if blockTicks {
            if tickWaiter != nil { return }
            await withCheckedContinuation { tickWaiter = $0; tickObserver?.resume(); tickObserver = nil }
        }
        if let value = externalAtTick { clipboard = value; externalAtTick = nil }
        let action = onFirstTick; onFirstTick = nil; action?()
        while let first = due.first, first <= time.now {
            inserted.append(clipboard) // 不在 RPC 時快照，真的到消費時才讀。
            due.removeFirst()
        }
    }
    func sendTouches(_ touches: [TouchSpec]) async {}
    func sendTap(nx: Double, ny: Double, down: Bool) async {}
    func sendKey(_ code: KeyCode, down: Bool) async { keys.append("ordinary:\(down)") }
}

func receipt(_ stream: AsyncStream<TextCommitResult>) async throws -> TextCommitResult {
    var iterator = stream.makeAsyncIterator()
    return try #require(await iterator.next())
}

@Suite struct TextCommitQueueTests {
    private func setup(policy: TextSubmissionPolicy, delay: Duration = .milliseconds(100), blockRead: Bool = false)
        -> (InputQueue, ConsumingTextTransport, AdvancingTextClock) {
        let time = AdvancingTextClock()
        let fake = ConsumingTextTransport(time: time, consumptionDelay: delay, blockRead: blockRead)
        let clock = TextCommitClock(now: { time.now }, sleep: { step in time.advance(step); await fake.tick() })
        return (InputQueue(injector: fake, textTransport: fake, textPolicy: .success(policy), textClock: clock), fake, time)
    }
    @Test func twoDifferentCommitsUseConsumptionGate() async throws {
        let (queue, fake, _) = setup(policy: try TextSubmissionPolicy())
        await fake.holdConsumption()
        let a = queue.commitText(TextCommit(text: "A", generation: 0))
        await fake.waitForBlockedTick()
        let b = queue.commitText(TextCommit(text: "B", generation: 0))
        // 僅讓其他 task 得到執行機會；業務 deadline 仍由虛擬時鐘控制。
        try await Task.sleep(for: .milliseconds(20))
        let heldWrites = await fake.writes
        #expect(heldWrites == ["A"])
        await fake.releaseConsumption()
        #expect(try await receipt(a).outcome == .submittedUnverified)
        #expect(try await receipt(b).outcome == .submittedUnverified)
        await queue.drained()
        let inserted = await fake.inserted
        #expect(inserted == ["A", "B"])
    }
    @Test func watcherCannotOverwriteAnInFlightPaste() async throws {
        let (queue, fake, _) = setup(policy: try TextSubmissionPolicy())
        await fake.holdConsumption()
        let a = queue.commitText(TextCommit(text: "A", generation: 0))
        await fake.waitForBlockedTick()
        let b = queue.commitText(TextCommit(text: "B", generation: 0))
        queue.hostClipboardChanged("watcher-C")
        try await Task.sleep(for: .milliseconds(20))
        let heldWrites = await fake.writes
        #expect(heldWrites == ["A"])
        await fake.releaseConsumption()
        _ = try await receipt(a); _ = try await receipt(b); await queue.drained()
        let inserted = await fake.inserted
        let writes = await fake.writes
        #expect(inserted == ["A", "B"])
        #expect(writes == ["A", "B", "watcher-C"])
    }
    @Test func delayDoesNotPretendToAcknowledgeArbitrarilyLateConsumption() async throws {
        let (queue, fake, time) = setup(policy: try TextSubmissionPolicy(settleMilliseconds: 50), delay: .seconds(1))
        let a = queue.commitText(TextCommit(text: "A", generation: 0))
        let b = queue.commitText(TextCommit(text: "B", generation: 0))
        #expect(try await receipt(a).outcome == .submittedUnverified)
        #expect(try await receipt(b).outcome == .submittedUnverified)
        time.advance(.seconds(2)); await fake.tick()
        #expect(await fake.inserted == ["B", "B"]) // 故意更慢的 guest 仍可失敗，不能做假 ACK。
    }
    @Test func sameTextTwiceButSameIDNeverReplays() async throws {
        let (queue, fake, _) = setup(policy: try TextSubmissionPolicy())
        let commit = TextCommit(text: "你好", generation: 0)
        let a = queue.commitText(commit)
        let duplicate = queue.commitText(commit)
        let b = queue.commitText(TextCommit(text: "你好", generation: 0))
        #expect(try await receipt(duplicate).outcome == .rejected(.duplicateID))
        _ = try await receipt(a); _ = try await receipt(b)
        #expect(await fake.inserted == ["你好", "你好"])
    }
    @Test func capacityAndExpiryReturnRecoverableResults() async throws {
        let (queue, fake, _) = setup(policy: try TextSubmissionPolicy(maxPending: 1), blockRead: true)
        let a = queue.commitText(TextCommit(text: "A", generation: 0))
        let b = queue.commitText(TextCommit(text: "B", generation: 0))
        let rejected = try await receipt(b)
        #expect(rejected.outcome == .rejected(.queueLimit)); #expect(rejected.commit.text == "B")
        await fake.waitForBlockedRead(); await fake.unblockRead(); _ = try await receipt(a)
        let (expiredQueue, _, _) = setup(policy: try TextSubmissionPolicy(queueTimeoutMilliseconds: 100))
        let first = expiredQueue.commitText(TextCommit(text: "first", generation: 0))
        let late = expiredQueue.commitText(TextCommit(text: "late", generation: 0))
        _ = try await receipt(first)
        #expect(try await receipt(late).outcome == .rejected(.queueExpired))
    }
    @Test func staleAfterReadNeverPastesIntoNewSession() async throws {
        let (queue, fake, _) = setup(policy: try TextSubmissionPolicy(), blockRead: true)
        let a = queue.commitText(TextCommit(text: "A", generation: 0))
        await fake.waitForBlockedRead()
        queue.invalidateTextSession()
        await fake.unblockRead()
        #expect(try await receipt(a).outcome == .cancelledBeforeDispatch(.staleSession))
        #expect(await fake.keys.isEmpty)
    }
    @Test func externalConflictPausesWritesButStillReleasesKeysAndNeverReplaysUnknown() async throws {
        let (queue, fake, _) = setup(policy: try TextSubmissionPolicy())
        await fake.armExternal(value: "guest-new") { [weak queue] in _ = queue?.observeGuestClipboard("guest-new") }
        let a = queue.commitText(TextCommit(text: "A", generation: 0))
        let b = queue.commitText(TextCommit(text: "B", generation: 0))
        #expect(try await receipt(a).outcome == .indeterminateAfterDispatch(.clipboardConflict))
        _ = try await receipt(b)
        queue.hostClipboardChanged("host-new")
        queue.key(.key("Control"), down: false)
        await queue.drained()
        #expect(await fake.clipboard == "guest-new")
        #expect(await fake.keys.contains("ordinary:false"))
        #expect(!queue.resumeTextSubmissions())
        #expect(queue.resumeTextSubmissions(acknowledgingUncertainty: true))
        await queue.drained()
        #expect(await fake.clipboard == "host-new")
        #expect(await fake.keys.filter { $0 == "v:true" }.count == 1)
    }
}
