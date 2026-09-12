import Foundation
@testable import MirageCore

/// 對應 MirageShellTests/RemoteTestWaits.swift 的 state／deadline helper。
/// 跨 test target 不共用來源，比照 TestGates.swift；此處不依賴 MirageShell。
/// 等待一定可取消。不能把不支援取消的 CheckedContinuation 丟入 task group：
/// timeout 子 task 雖拋錯，group 仍會等那個 continuation，最後照樣掛住。
enum RemoteTestWaitError: Error, Equatable, CustomStringConvertible {
    case timedOut(String)
    case ended(String)
    case handshake(String)

    var description: String {
        switch self {
        case .timedOut(let stage): return "等待逾時：\(stage)"
        case .ended(let stage): return "事件串流提前結束：\(stage)"
        case .handshake(let detail): return "WebSocket 握手失敗：\(detail)"
        }
    }
}

enum RemoteTestWaits {
    /// operation 必須支援取消（本檔只傳入 AsyncStream/AsyncThrowingStream 等待）。
    static func withDeadline<T: Sendable>(
        _ stage: String, timeout: Duration = .seconds(10),
        diagnostics: @escaping @Sendable () -> String = { "" },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RemoteTestWaitError.timedOut("\(stage) \(diagnostics())")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw RemoteTestWaitError.ended(stage) }
            return result
        }
    }

    static func state(in states: AsyncStream<RemoteSessionState>, hasVideo: Bool,
                      diagnostics: @escaping @Sendable () -> String) async throws -> RemoteSessionState {
        try await withDeadline("server hasVideo=\(hasVideo)", diagnostics: diagnostics) {
            for await state in states {
                try Task.checkCancellation()
                if state.hasVideo == hasVideo { return state }
            }
            try Task.checkCancellation()
            throw RemoteTestWaitError.ended("server hasVideo=\(hasVideo)")
        }
    }

}
