import Foundation

public enum TextCommitIssue: Error, Sendable, Equatable {
    case invalidPolicy(String), queueLimit, queueExpired, duplicateID, paused
    case staleSession, clipboardConflict, readbackTimeout, transport(String), cancelled
}

public enum TextCommitOutcome: Sendable, Equatable {
    case submittedUnverified
    case failedBeforePaste(TextCommitIssue)
    case indeterminateAfterDispatch(TextCommitIssue)
    case cancelledBeforeDispatch(TextCommitIssue)
    case rejected(TextCommitIssue)
}

/// 提交來源。兩者共用 guest 剪貼簿，所以 `paused` 仍是全域的；分開的只有工作階段：
/// 本機由 Mac 的視窗焦點與輸入法狀態決定，遠端由 viewer 的連線決定。
public enum TextCommitOrigin: String, Sendable, Equatable, CaseIterable {
    case local, remote
}

public struct TextCommit: Sendable {
    public let id: UUID
    public let text: String
    public let generation: UInt64
    public let origin: TextCommitOrigin
    public let createdAt: Date
    public init(id: UUID = UUID(), text: String, generation: UInt64,
                origin: TextCommitOrigin = .local, createdAt: Date = Date()) {
        self.id = id; self.text = text; self.generation = generation
        self.origin = origin; self.createdAt = createdAt
    }
}

public struct TextCommitResult: Sendable {
    public let commit: TextCommit
    public let outcome: TextCommitOutcome
    public init(commit: TextCommit, outcome: TextCommitOutcome) {
        self.commit = commit; self.outcome = outcome
    }
}

public enum TextCommitPhase: Sendable, Equatable {
    case queued, preparingClipboard, dispatchingPaste, settling, finished
}

/// 純狀態。RPC 回覆不可能產生 verified/inserted 狀態。
public struct TextCommitState: Sendable {
    public let commit: TextCommit
    public let policy: TextSubmissionPolicy
    public private(set) var phase: TextCommitPhase = .queued
    public private(set) var settleUntil: Duration?
    public private(set) var result: TextCommitResult?
    public init(commit: TextCommit, policy: TextSubmissionPolicy) {
        self.commit = commit; self.policy = policy
    }
    public func preparing() -> Self { guard phase == .queued else { return self }; var s = self; s.phase = .preparingClipboard; return s }
    public func dispatching() -> Self { guard phase == .queued || phase == .preparingClipboard else { return self }; var s = self; s.phase = .dispatchingPaste; return s }
    public func settling(at now: Duration) -> Self {
        guard phase == .dispatchingPaste else { return self }
        var s = self; s.phase = .settling; s.settleUntil = now + policy.settleDelay; return s
    }
    public func advanced(to now: Duration) -> Self {
        guard phase == .settling, let settleUntil, now >= settleUntil else { return self }
        return finishing(.submittedUnverified)
    }
    public func failing(_ issue: TextCommitIssue) -> Self {
        finishing(hasDispatched ? .indeterminateAfterDispatch(issue) : .failedBeforePaste(issue))
    }
    public func cancelling(_ issue: TextCommitIssue = .cancelled) -> Self {
        finishing(hasDispatched ? .indeterminateAfterDispatch(issue) : .cancelledBeforeDispatch(issue))
    }
    private var hasDispatched: Bool { phase == .dispatchingPaste || phase == .settling }
    private func finishing(_ outcome: TextCommitOutcome) -> Self {
        guard phase != .finished else { return self }
        var s = self; s.phase = .finished; s.result = TextCommitResult(commit: commit, outcome: outcome); return s
    }
}

public enum TextContent {
    public static func exactlyEqual(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
}

/// 每個 session 的 admission ledger；不同字串／同字串都按 ID，不按內容。
public struct TextCommitLedger: Sendable {
    private var ids = Set<UUID>()
    public init() {}
    public func admitting(_ commit: TextCommit) -> (accepted: Bool, ledger: Self) {
        var next = self
        let inserted = next.ids.insert(commit.id).inserted
        return (inserted, next)
    }
}
