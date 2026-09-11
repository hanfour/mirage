import AppKit
import MirageCore

@MainActor @Observable
final class TextInputPresentation {
    enum Mode: String, CaseIterable { case automatic, text, keymap }
    var mode: Mode = .automatic
    var settle: String
    private(set) var policyError: String?
    private(set) var results: [TextCommitResult] = []
    private(set) var paused = false
    var localDraft = ""
    var localIssue: String?
    let queue: InputQueue
    init(queue: InputQueue) {
        self.queue = queue
        settle = ProcessInfo.processInfo.environment["MIRAGE_TEXT_SETTLE_MS"] ?? String(TextSubmissionPolicy.candidateSettleMilliseconds)
    }
    func usesText(hasProfile: Bool) -> Bool { mode == .text || (mode == .automatic && !hasProfile) }
    func applyPolicy() {
        let policy = TextSubmissionPolicy.configured(environment: ["MIRAGE_TEXT_SETTLE_MS": settle])
        queue.textCoordinator.setPolicy(policy)
        if case .failure(let error) = policy { policyError = String(describing: error) }
        else { policyError = nil }
    }
    func submit(_ text: String) {
        let commit = TextCommit(text: text, generation: queue.textCoordinator.status.generation)
        let stream = queue.commitText(commit)
        Task { [weak self] in
            for await result in stream { self?.record(result) }
        }
    }
    func record(_ result: TextCommitResult) {
        results.append(result)
        // Keep failed/uncertain drafts. Only bounded history of ordinary unverified submissions.
        let normal = results.indices.filter { results[$0].outcome == .submittedUnverified }
        if normal.count > 32 { results.remove(at: normal[0]) }
        refresh()
    }
    func refresh() { paused = queue.textCoordinator.status.paused != nil }
    func pause() { queue.pauseTextSubmissions(); refresh() }
    func resume(acknowledgingUncertainty: Bool) {
        _ = queue.resumeTextSubmissions(acknowledgingUncertainty: acknowledgingUncertainty)
        refresh()
    }
    static func label(_ outcome: TextCommitOutcome) -> String {
        switch outcome {
        case .submittedUnverified: return "已排程提交；欄位未驗證"
        case .failedBeforePaste: return "貼上前失敗（未送）"
        case .indeterminateAfterDispatch: return "可能已送出，結果不確定；請先核對欄位"
        case .cancelledBeforeDispatch: return "送出前取消（未送）"
        case .rejected: return "未收件；請檢查設定或佇列"
        }
    }
    func copyDraft(_ text: String) {
        // Pause BEFORE writing NSPasteboard so the watcher cannot paste this recovery copy.
        pause()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
