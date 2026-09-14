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

    /// Foundation/NIO 的 await 不一定回應 Task.cancel；不能直接放入 deadline task group。
    /// 以可取消的 stream 等結果，逾時取消 worker 與底層 socket，絕不再 await worker.value。
    /// 呼叫者仍須用獨立清理預算 stop server/controller，且所有操作共用同一個真實截止時間。
    static func boundedOperation<T: Sendable>(
        _ stage: String, until deadline: ContinuousClock.Instant,
        diagnostics: @escaping @Sendable () -> String,
        cancel: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { throw RemoteTestWaitError.timedOut("\(stage) \(diagnostics())") }
        let (results, continuation) = AsyncThrowingStream<T, any Error>.makeStream()
        let worker = Task {
            do {
                let value = try await operation()
                continuation.yield(value)
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        defer { worker.cancel(); continuation.finish() }
        do {
            return try await withDeadline(stage, timeout: remaining, diagnostics: diagnostics) {
                for try await value in results { return value }
                try Task.checkCancellation()
                throw RemoteTestWaitError.ended(stage)
            }
        } catch {
            cancel()
            throw error
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
