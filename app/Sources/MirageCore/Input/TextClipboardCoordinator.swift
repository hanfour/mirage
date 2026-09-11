import Foundation

public struct TextSubmissionStatus: Sendable {
    public let generation: UInt64
    public let pending: Int
    public let paused: TextCommitIssue?
    public let lastResult: TextCommitResult?
    public let unresolvedUncertainty: TextCommitResult?
    public let latestExternalClipboard: String?
}

struct TextAdmission: Sendable {
    let policy: TextSubmissionPolicy
    let queuedAt: Duration
}
enum TextReservation: Sendable {
    case accepted(TextAdmission)
    case rejected(TextCommitResult)
}

/// 同步 admission／失焦訊號；不持鎖 await。真正的傳輸只由 InputQueue 單一 consumer 執行。
public final class TextClipboardCoordinator: @unchecked Sendable {
    private struct Active {
        let id: UUID
        var issue: TextCommitIssue?
        var dispatched = false
    }
    private let lock = NSLock()
    private let clock: TextCommitClock
    private var policy: Result<TextSubmissionPolicy, TextCommitIssue>
    private var generation: UInt64 = 0
    private var ledger = TextCommitLedger()
    private var pending = 0
    private var active: Active?
    private var paused: TextCommitIssue?
    private var lastResult: TextCommitResult?
    private var unresolvedUncertainty: TextCommitResult?
    private var ownEchoes: [String] = []
    private var clipboardRevision: UInt64 = 0
    private var pendingHost: (revision: UInt64, text: String)?
    private var externalClipboard: String?

    public init(policy: Result<TextSubmissionPolicy, TextCommitIssue>, clock: TextCommitClock) {
        self.policy = policy; self.clock = clock
    }
    public var status: TextSubmissionStatus {
        lock.lock(); defer { lock.unlock() }
        return TextSubmissionStatus(generation: generation, pending: pending, paused: paused,
                                    lastResult: lastResult, unresolvedUncertainty: unresolvedUncertainty, latestExternalClipboard: externalClipboard)
    }
    public var configuredPolicy: Result<TextSubmissionPolicy, TextCommitIssue> {
        lock.lock(); defer { lock.unlock() }; return policy
    }
    public func setPolicy(_ value: Result<TextSubmissionPolicy, TextCommitIssue>) {
        lock.lock(); defer { lock.unlock() }; policy = value
    }
    func reserve(_ commit: TextCommit) -> TextReservation {
        let now = clock.now()
        lock.lock(); defer { lock.unlock() }
        func reject(_ outcome: TextCommitOutcome) -> TextReservation {
            .rejected(TextCommitResult(commit: commit, outcome: outcome))
        }
        guard commit.generation == generation else { return reject(.cancelledBeforeDispatch(.staleSession)) }
        let admission = ledger.admitting(commit)
        guard admission.accepted else { return reject(.rejected(.duplicateID)) }
        guard paused == nil else { return reject(.rejected(.paused)) }
        let selected: TextSubmissionPolicy
        switch policy {
        case .success(let value): selected = value
        case .failure(let issue): return reject(.rejected(issue))
        }
        guard pending < selected.maxPending else { return reject(.rejected(.queueLimit)) }
        pending += 1; ledger = admission.ledger
        return .accepted(TextAdmission(policy: selected, queuedAt: now))
    }
    func begin(_ commit: TextCommit, admission: TextAdmission) -> TextCommitResult? {
        let now = clock.now()
        lock.lock(); defer { lock.unlock() }
        if commit.generation != generation { return TextCommitResult(commit: commit, outcome: .cancelledBeforeDispatch(.staleSession)) }
        if paused != nil { return TextCommitResult(commit: commit, outcome: .rejected(.paused)) }
        if now - admission.queuedAt >= admission.policy.queueTimeout { return TextCommitResult(commit: commit, outcome: .rejected(.queueExpired)) }
        guard active == nil else { return TextCommitResult(commit: commit, outcome: .failedBeforePaste(.transport("concurrent-text-transaction"))) }
        active = Active(id: commit.id)
        return nil
    }
    func validity(_ commit: TextCommit) -> TextCommitIssue? {
        lock.lock(); defer { lock.unlock() }
        if active?.id == commit.id, let issue = active?.issue { return issue }
        if commit.generation != generation || active?.id != commit.id { return .staleSession }
        return paused
    }
    func phase(_ phase: TextCommitPhase, for commit: TextCommit) {
        lock.lock(); defer { lock.unlock() }
        if active?.id == commit.id, phase == .dispatchingPaste { active?.dispatched = true }
    }
    func rememberOwnWrite(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        // proto 無 origin ID；有界近期內容只作 echo 抑制，不假裝能辨識同值外部複製。
        ownEchoes.removeAll { TextContent.exactlyEqual($0, text) }
        ownEchoes.append(text)
        if ownEchoes.count > 64 { ownEchoes.removeFirst(ownEchoes.count - 64) }
    }
    public func observeGuestClipboard(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if ownEchoes.contains(where: { TextContent.exactlyEqual($0, text) }) { return false }
        externalClipboard = text
        clipboardRevision &+= 1
        pendingHost = nil // guest 的更新較新，舊 host 同步不可稍後蓋回來。
        if active != nil {
            active?.issue = .clipboardConflict
            paused = .clipboardConflict
            generation &+= 1
        }
        return true
    }
    func hostClipboardChanged(_ text: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        clipboardRevision &+= 1
        pendingHost = (clipboardRevision, text); externalClipboard = text
        return clipboardRevision
    }
    func hostValue(for revision: UInt64) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard paused == nil, active == nil, pendingHost?.revision == revision else { return nil }
        let value = pendingHost?.text
        pendingHost = nil
        return value
    }
    func finish(_ result: TextCommitResult) -> TextCommitResult {
        lock.lock(); defer { lock.unlock() }
        var final = result
        if active?.id == result.commit.id {
            if let issue = active?.issue, result.outcome == .submittedUnverified {
                final = TextCommitResult(commit: result.commit, outcome: .indeterminateAfterDispatch(issue))
            }
            active = nil
        }
        pending -= 1
        lastResult = final
        switch final.outcome {
        case .indeterminateAfterDispatch(let issue):
            unresolvedUncertainty = final
            paused = issue; generation &+= 1
        case .failedBeforePaste(let issue):
            paused = issue; generation &+= 1
        default: break
        }
        return final
    }
    public func invalidateSession() {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        if active != nil { active?.issue = .staleSession }
    }
    public func pause() {
        lock.lock(); defer { lock.unlock() }
        paused = .paused; generation &+= 1
        if active != nil { active?.issue = .cancelled }
    }
    func clipboardWriteFailed(_ issue: TextCommitIssue, revision: UInt64, value: String) {
        lock.lock(); defer { lock.unlock() }
        paused = issue; generation &+= 1
        if clipboardRevision == revision, pendingHost == nil { pendingHost = (revision, value) }
    }
    /// 不重播任何舊 commit。未知結果需要明確承認不確定性，且 active 必須已結束。
    func resume(acknowledgingUncertainty: Bool) -> (resumed: Bool, hostRevision: UInt64?) {
        lock.lock(); defer { lock.unlock() }
        guard active == nil else { return (false, nil) }
        if unresolvedUncertainty != nil, !acknowledgingUncertainty { return (false, nil) }
        paused = nil
        unresolvedUncertainty = nil
        return (true, pendingHost?.revision)
    }
}
