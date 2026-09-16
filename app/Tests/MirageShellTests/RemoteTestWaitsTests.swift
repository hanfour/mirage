import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

@Suite(.timeLimit(.minutes(1))) struct RemoteTestWaitsTests {
    @Test func missingStateThrowsDeadlineInsteadOfHanging() async throws {
        let (stream, continuation) = AsyncStream<RemoteSessionState>.makeStream()
        defer { continuation.finish() }
        do {
            _ = try await RemoteTestWaits.withDeadline("missing video", timeout: .milliseconds(20)) {
                for await state in stream { return state }
                try Task.checkCancellation()
                throw RemoteTestWaitError.ended("missing video")
            }
            Issue.record("沒有事件時必須逾時失敗")
        } catch let error as RemoteTestWaitError {
            #expect(error == .timedOut("missing video "))
        }
    }

    @Test func cancellationReleasesAnActiveStreamWait() async throws {
        let (stream, continuation) = AsyncStream<RemoteSessionState>.makeStream()
        defer { continuation.finish() }
        let entered = CountGate()
        let task = Task {
            try await RemoteTestWaits.withDeadline("cancelled wait") {
                entered.increment()
                for await state in stream { return state }
                try Task.checkCancellation()
                throw RemoteTestWaitError.ended("cancelled wait")
            }
        }
        await entered.wait(for: 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func bufferedConnectionAndDisconnectionAreBothObserved() async throws {
        let (stream, continuation) = AsyncStream<RemoteSessionState>.makeStream()
        continuation.yield(.initial)
        continuation.yield(RemoteSessionState(phase: .connected, hasVideo: true, hasInput: false, hasAudio: false))
        continuation.yield(RemoteSessionState(phase: .disconnected, hasVideo: false, hasInput: false, hasAudio: false))
        continuation.finish()
        let connected = try await RemoteTestWaits.state(in: stream, hasVideo: true, diagnostics: { "" })
        #expect(connected.hasVideo)
        let disconnected = try await RemoteTestWaits.state(in: stream, hasVideo: false, diagnostics: { "" })
        #expect(!disconnected.hasVideo)
    }

    @Test func closedStreamWithoutExpectedStateFails() async throws {
        let (stream, continuation) = AsyncStream<RemoteSessionState>.makeStream()
        continuation.finish()
        await #expect(throws: RemoteTestWaitError.ended("server hasVideo=true")) {
            _ = try await RemoteTestWaits.state(in: stream, hasVideo: true, diagnostics: { "" })
        }
    }

    @Test func handshakeFailureIsReportedWithoutWaitingForServerState() async throws {
        let probe = RemoteHandshakeProbe()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "ws://127.0.0.1:1/ws/video"))
        let task = session.webSocketTask(with: url)
        // 不啟動網路；直接模擬 Foundation 握手失敗的 delegate 回呼。
        probe.urlSession(session, task: task, didCompleteWithError: URLError(.cannotConnectToHost))
        do {
            try await probe.wait(diagnostics: { "" })
            Issue.record("握手失敗必須拋錯")
        } catch let error as RemoteTestWaitError {
            if case .handshake(let detail) = error {
                #expect(detail.contains("HTTP=nil"))
                #expect(detail.contains(String(URLError.cannotConnectToHost.rawValue)))
            } else { Issue.record("預期握手錯誤，實得 \(error)") }
        }
    }
}
