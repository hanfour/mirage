import Foundation

public struct TextCommitExecutor: Sendable {
    private let transport: any TextCommitTransport
    public let clock: TextCommitClock
    public init(transport: any TextCommitTransport, clock: TextCommitClock = .continuous) {
        self.transport = transport; self.clock = clock
    }
    public func execute(_ commit: TextCommit, policy: TextSubmissionPolicy,
                        validity: @escaping @Sendable () -> TextCommitIssue? = { nil },
                        willWrite: @escaping @Sendable (String) -> Void = { _ in },
                        phaseChanged: @escaping @Sendable (TextCommitPhase) -> Void = { _ in }) async -> TextCommitResult {
        var state = TextCommitState(commit: commit, policy: policy)
        defer { phaseChanged(.finished) }
        func checkValidity() throws {
            try Task.checkCancellation()
            if let issue = validity() { throw issue }
        }
        do {
            try checkValidity()
            state = state.preparing()
            phaseChanged(state.phase)
            willWrite(commit.text)
            try await transport.writeTextClipboard(commit.text, timeout: policy.rpcTimeout)
            let readDeadline = clock.now() + policy.readbackTimeout
            while true {
                try checkValidity()
                let remaining = readDeadline - clock.now()
                guard remaining > .zero else { throw TextCommitIssue.readbackTimeout }
                let value = try await transport.readTextClipboard(timeout: min(policy.rpcTimeout, remaining))
                try checkValidity()
                guard clock.now() <= readDeadline else { throw TextCommitIssue.readbackTimeout }
                if TextContent.exactlyEqual(value, commit.text) { break }
                let pause = min(.milliseconds(25), readDeadline - clock.now())
                if pause > .zero { try await clock.sleep(pause) }
            }
            try checkValidity()
            state = state.dispatching()
            phaseChanged(state.phase)
            for (key, down) in [("Control", true), ("v", true), ("v", false), ("Control", false)] {
                try checkValidity()
                try await transport.sendTextKey(key, down: down, timeout: policy.rpcTimeout)
            }
            // 由最後 key-up 回覆起算，不由 setClipboard 或 v-down 起算。
            state = state.settling(at: clock.now())
            phaseChanged(state.phase)
            while let deadline = state.settleUntil, clock.now() < deadline {
                try checkValidity()
                // 取消／失焦可在一個短 tick 後退出，但 coordinator 仍須保留未知狀態的 gate。
                try await clock.sleep(min(.milliseconds(20), deadline - clock.now()))
            }
            try checkValidity()
            state = state.advanced(to: clock.now())
        } catch {
            if state.phase == .dispatchingPaste || state.phase == .settling {
                // 不繼承呼叫者的 cancellation；只有 key-up，絕不重新按下 Paste。
                let cleanup = Task { [transport] in
                    try? await transport.sendTextKey("v", down: false, timeout: policy.rpcTimeout)
                    try? await transport.sendTextKey("Control", down: false, timeout: policy.rpcTimeout)
                }
                await cleanup.value
            }
            let issue: TextCommitIssue
            if error is CancellationError { issue = .cancelled }
            else { issue = (error as? TextCommitIssue) ?? .transport(String(describing: error)) }
            if issue == .staleSession || issue == .cancelled {
                state = state.cancelling(issue)
            } else {
                state = state.failing(issue)
            }
        }
        // 每條退出路徑都產生具名結果；無 verified 或自動重播分支。
        return state.result ?? TextCommitResult(commit: commit, outcome: .failedBeforePaste(.transport("invalid-state")))
    }
}
