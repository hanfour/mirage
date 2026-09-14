import Foundation
import MirageCore
@testable import MirageShell

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

    /// AppModel 的 teardown 同時修改 remote、sink 與 transition flag；等完整完成。
    /// sleep 真正暫停 MainActor、支援取消，並有獨立 deadline，沒有 yield 忙等。
    @MainActor
    static func teardown(of model: AppModel, timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout
        while model.remote != nil || model.remoteTransitionInProgress {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw RemoteTestWaitError.timedOut(
                    "AppModel teardown：menu=\(model.remoteMenuState)，transition=\(model.remoteTransitionInProgress)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
    }
}

/// Foundation 握手另有成功／失敗事件，不能只 resume 後等 server 狀態。
/// delegateQueue 明確用背景 OperationQueue，避免測試的 MainActor/RunLoop 成為依賴。
final class RemoteHandshakeProbe: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let opened: AsyncThrowingStream<Void, any Error>
    private let continuation: AsyncThrowingStream<Void, any Error>.Continuation

    override init() {
        let (stream, continuation) = AsyncThrowingStream<Void, any Error>.makeStream()
        self.opened = stream
        self.continuation = continuation
        super.init()
    }

    func wait(diagnostics: @escaping @Sendable () -> String) async throws {
        try await RemoteTestWaits.withDeadline("WebSocket didOpen", diagnostics: diagnostics) { [opened] in
            for try await _ in opened { return }
            try Task.checkCancellation()
            throw RemoteTestWaitError.ended("WebSocket didOpen")
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        continuation.yield(())
        continuation.finish()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        continuation.finish(throwing: RemoteTestWaitError.handshake("開啟前關閉，closeCode=\(closeCode.rawValue)"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        continuation.finish(throwing: RemoteTestWaitError.handshake(
            "HTTP=\(status.map { String($0) } ?? "nil")，error=\(String(describing: error))"))
    }
}
