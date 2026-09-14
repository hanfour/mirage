import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

/// 真實 loopback 覆蓋解碼、非法計數、controller 最新值與 input 生命週期。
@Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteClientStatsTests {
    @Test func storesLatestReportRejectsInvalidAndClearsOnDisconnect() async throws {
        let token = try #require(PairingToken(value: "00112233445566778899aabbccddeeff"))
        var config = RemoteMirrorConfiguration(token: token, viewerPage: Data())
        config.host = "127.0.0.1"
        config.port = 0
        let controller = RemoteMirrorController(
            configuration: config, secondary: LatestFrameBox(),
            inputQueue: InputQueue(injector: RemoteMirrorRecordingInjector()),
            makeEncoder: { RemoteMirrorFakeEncoder() })
        let deadline = ContinuousClock.now + .seconds(3)
        let diagnostics: @Sendable () -> String = {
            "state=\(controller.sessionState), invalid=\(controller.stats().server.invalidInputMessages), latest=\(String(describing: controller.latestClientStats))"
        }
        do {
            let port = try await RemoteTestWaits.boundedOperation("start", until: deadline, diagnostics: diagnostics) {
                try await controller.start()
            }
            let video = try socket(port, "video", token)
            defer { video.cancel(with: .normalClosure, reason: nil) }
            try await waitUntil("video admission", until: deadline, diagnostics: diagnostics) { controller.sessionState.hasVideo }
            #expect(controller.latestClientStats == nil)
            let input = try socket(port, "input", token)
            defer { input.cancel(with: .normalClosure, reason: nil) }
            try await send(#"{"type":"client-stats","rtt":15,"dropped":0,"decodeFps":30}"#, to: input, until: deadline, diagnostics: diagnostics)
            try await barrier(input, until: deadline, diagnostics: diagnostics)
            #expect(controller.latestClientStats == .init(rtt: 15, dropped: 0, decodeFps: 30))
            try await send(#"{"type":"client-stats","rtt":42,"dropped":3,"decodeFps":20}"#, to: input, until: deadline, diagnostics: diagnostics)
            try await send(#"{"type":"client-stats","rtt":false,"dropped":0,"decodeFps":30}"#, to: input, until: deadline, diagnostics: diagnostics)
            try await send(#"{"type":"client-stats","rtt":15,"dropped":-1,"decodeFps":30}"#, to: input, until: deadline, diagnostics: diagnostics)
            try await barrier(input, until: deadline, diagnostics: diagnostics)
            #expect(controller.latestClientStats == .init(rtt: 42, dropped: 3, decodeFps: 20))
            #expect(controller.stats().server.invalidInputMessages == 2)
            #expect(controller.stats().server.touchesForwarded == 0)
            input.cancel(with: .normalClosure, reason: nil)
            try await waitUntil("input closed", until: deadline, diagnostics: diagnostics) {
                !controller.sessionState.hasInput && controller.latestClientStats == nil
            }
            #expect(controller.latestClientStats == nil)
            #expect(controller.sessionState.hasVideo)
            let replacement = try socket(port, "input", token)
            defer { replacement.cancel(with: .normalClosure, reason: nil) }
            try await barrier(replacement, until: deadline, diagnostics: diagnostics)
            #expect(controller.latestClientStats == nil)
            try await send(#"{"type":"client-stats","rtt":1,"dropped":0,"decodeFps":0}"#, to: replacement, until: deadline, diagnostics: diagnostics)
            try await barrier(replacement, until: deadline, diagnostics: diagnostics)
            #expect(controller.latestClientStats == .init(rtt: 1, dropped: 0, decodeFps: 0))
        } catch {
            do { try await stop(controller, diagnostics: diagnostics) } catch { Issue.record(error) }
            throw error
        }
        try await stop(controller, diagnostics: diagnostics)
        #expect(controller.latestClientStats == nil)
    }

    private func socket(_ port: Int, _ kind: String, _ token: PairingToken) throws -> URLSessionWebSocketTask {
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws/\(kind)?t=\(token.value)"))
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        return socket
    }

    private func send(_ text: String, to socket: URLSessionWebSocketTask, until deadline: ContinuousClock.Instant,
                      diagnostics: @escaping @Sendable () -> String) async throws {
        try await RemoteTestWaits.boundedOperation("send input", until: deadline, diagnostics: diagnostics,
                                                   cancel: { socket.cancel(with: .goingAway, reason: nil) }) {
            try await socket.send(.string(text))
        }
    }

    private func barrier(_ socket: URLSessionWebSocketTask, until deadline: ContinuousClock.Instant,
                         diagnostics: @escaping @Sendable () -> String) async throws {
        let ping = #"{"type":"ping","t":1}"#
        try await send(ping, to: socket, until: deadline, diagnostics: diagnostics)
        let echo = try await RemoteTestWaits.boundedOperation("receive input echo", until: deadline, diagnostics: diagnostics,
                                                              cancel: { socket.cancel(with: .goingAway, reason: nil) }) {
            try await socket.receive()
        }
        guard case .string(let text) = echo else { throw RemoteMirrorTestFailure.unexpectedMessageKind }
        #expect(text == ping)
    }

    private func waitUntil(_ stage: String, until deadline: ContinuousClock.Instant,
                           diagnostics: @Sendable () -> String, condition: @Sendable () -> Bool) async throws {
        while !condition() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw RemoteTestWaitError.timedOut("\(stage) \(diagnostics())") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func stop(_ controller: RemoteMirrorController, diagnostics: @escaping @Sendable () -> String) async throws {
        try await RemoteTestWaits.boundedOperation("stop", until: .now + .seconds(1), diagnostics: diagnostics) {
            await controller.stop()
        }
    }
}
