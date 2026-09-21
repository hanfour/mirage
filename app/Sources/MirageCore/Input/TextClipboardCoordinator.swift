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
        let origin: TextCommitOrigin
        var issue: TextCommitIssue?
        var dispatched = false
    }
    private let lock = NSLock()
    private let clock: TextCommitClock
    private var policy: Result<TextSubmissionPolicy, TextCommitIssue>
    /// 每個來源一條工作階段計數。合成一條就等於讓 Mac 的視窗焦點作廢手機送來的文字。
    private var generations: [TextCommitOrigin: UInt64] = [.local: 0, .remote: 0]
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
        return TextSubmissionStatus(generation: generations[.local] ?? 0, pending: pending, paused: paused,
                                    lastResult: lastResult, unresolvedUncertainty: unresolvedUncertainty, latestExternalClipboard: externalClipboard)
    }
    public var configuredPolicy: Result<TextSubmissionPolicy, TextCommitIssue> {
        lock.lock(); defer { lock.unlock() }; return policy
    }
    public func setPolicy(_ value: Result<TextSubmissionPolicy, TextCommitIssue>) {
        lock.lock(); defer { lock.unlock() }; policy = value
    }
    /// 呼叫端建 `TextCommit` 時要帶自己來源的那條，否則會被當成舊工作階段擋下。
    public func generation(for origin: TextCommitOrigin) -> UInt64 {
        lock.lock(); defer { lock.unlock() }; return generations[origin] ?? 0
    }
    private func bumpLocked(_ origins: [TextCommitOrigin]) {
        for origin in origins { generations[origin] = (generations[origin] ?? 0) &+ 1 }
    }
    func reserve(_ commit: TextCommit) -> TextReservation {
        let now = clock.now()
        lock.lock(); defer { lock.unlock() }
        func reject(_ outcome: TextCommitOutcome) -> TextReservation {
            .rejected(TextCommitResult(commit: commit, outcome: outcome))
        }
        guard commit.generation == generations[commit.origin] else { return reject(.cancelledBeforeDispatch(.staleSession)) }
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
        if commit.generation != generations[commit.origin] { return TextCommitResult(commit: commit, outcome: .cancelledBeforeDispatch(.staleSession)) }
        if paused != nil { return TextCommitResult(commit: commit, outcome: .rejected(.paused)) }
        if now - admission.queuedAt >= admission.policy.queueTimeout { return TextCommitResult(commit: commit, outcome: .rejected(.queueExpired)) }
        guard active == nil else { return TextCommitResult(commit: commit, outcome: .failedBeforePaste(.transport("concurrent-text-transaction"))) }
        active = Active(id: commit.id, origin: commit.origin)
        return nil
    }
    /// 只看「這筆是不是當前作用中的交易」，不看 generation。
    ///
    /// generation 的職責在 admission（`reserve`／`begin`）：擋掉換 session 之前就排好、
    /// 還沒開始的舊 commit。一筆已經被接受並開始執行的交易再拿 generation 判一次，等於
    /// 讓任何一次 `invalidateSession()` 都能中途砍掉它；砍在 Paste 送出之後就是
    /// `indeterminateAfterDispatch` 加全域 `paused`（見 `invalidateSession`）。
    func validity(_ commit: TextCommit) -> TextCommitIssue? {
        lock.lock(); defer { lock.unlock() }
        guard active?.id == commit.id else { return .staleSession }
        if let issue = active?.issue { return issue }
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
            bumpLocked(TextCommitOrigin.allCases) // 外部改動影響共用的 guest 剪貼簿。
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
            paused = issue; bumpLocked([final.commit.origin])
        case .failedBeforePaste(let issue):
            paused = issue; bumpLocked([final.commit.origin])
        default: break
        }
        return final
    }
    /// 失焦／換 profile／換連線只作廢「還沒把 Paste 送出去」的交易。
    ///
    /// 已經 dispatch 的不能作廢：那一刻 Control+v 已經送給 guest，切不切視窗都改變不了
    /// 結果。硬把它取消，`TextCommitState.cancelling` 會因為 `hasDispatched` 判成
    /// `indeterminateAfterDispatch`，`finish()` 接著設 `paused`，整條文字通道就永久停在
    /// 「結果不明」，只剩鏡像視窗左下角那顆按鈕能解。Mac 視窗失焦是家常便飯，於是手機
    /// 遙控打字會在某一次焦點變動後整個失效（2026-09-20）。
    ///
    /// 界線取 `dispatched` 而不是別的，是為了與 executor 的 `hasDispatched` 對齊：
    /// 兩邊都以 `.dispatchingPaste` 為分界，不會出現一邊認為已送出、另一邊認為還沒。
    public func invalidateSession() {
        lock.lock(); defer { lock.unlock() }
        bumpLocked([.local])
        if let current = active, current.origin == .local, !current.dispatched {
            active?.issue = .staleSession
        }
    }
    /// viewer 換連線／重新配對時作廢遠端工作階段；Mac 的視窗焦點不走這條。
    public func invalidateRemoteSession() {
        lock.lock(); defer { lock.unlock() }
        bumpLocked([.remote])
        if let current = active, current.origin == .remote, !current.dispatched {
            active?.issue = .staleSession
        }
    }
    public func pause() {
        lock.lock(); defer { lock.unlock() }
        paused = .paused; bumpLocked(TextCommitOrigin.allCases)
        if active != nil { active?.issue = .cancelled }
    }
    func clipboardWriteFailed(_ issue: TextCommitIssue, revision: UInt64, value: String) {
        lock.lock(); defer { lock.unlock() }
        paused = issue; bumpLocked(TextCommitOrigin.allCases)
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
