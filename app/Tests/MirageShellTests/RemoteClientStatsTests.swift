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
        let (states, continuation) = AsyncStream<RemoteSessionState>.makeStream()
        defer { continuation.finish() }
        let controller = RemoteMirrorController(
            configuration: config, secondary: LatestFrameBox(),
            inputQueue: InputQueue(injector: RemoteMirrorRecordingInjector()),
            makeEncoder: { RemoteMirrorFakeEncoder() },
            onStateChanged: { continuation.yield($0) })
        do {
            let port = try await controller.start()
            let video = try socket(port, "video", token)
            defer { video.cancel(with: .normalClosure, reason: nil) }
            _ = try await RemoteTestWaits.state(in: states, hasVideo: true, diagnostics: { "video admission" })
            #expect(controller.latestClientStats == nil)
            let input = try socket(port, "input", token)
            defer { input.cancel(with: .normalClosure, reason: nil) }
            try await input.send(.string(#"{"type":"client-stats","rtt":15,"dropped":0,"decodeFps":30}"#))
            try await barrier(input)
            #expect(controller.latestClientStats == .init(rtt: 15, dropped: 0, decodeFps: 30))
            try await input.send(.string(#"{"type":"client-stats","rtt":42,"dropped":3,"decodeFps":20}"#))
            try await input.send(.string(#"{"type":"client-stats","rtt":false,"dropped":0,"decodeFps":30}"#))
            try await input.send(.string(#"{"type":"client-stats","rtt":15,"dropped":-1,"decodeFps":30}"#))
            try await barrier(input)
            #expect(controller.latestClientStats == .init(rtt: 42, dropped: 3, decodeFps: 20))
            #expect(controller.stats().server.invalidInputMessages == 2)
            #expect(controller.stats().server.touchesForwarded == 0)
            input.cancel(with: .normalClosure, reason: nil)
            try await RemoteTestWaits.withDeadline("input closed") {
                var opened = false
                for await state in states {
                    if state.hasInput { opened = true }
                    if opened && !state.hasInput { return }
                }
                throw RemoteTestWaitError.ended("input closed")
            }
            #expect(controller.latestClientStats == nil)
            #expect(controller.sessionState.hasVideo)
            let replacement = try socket(port, "input", token)
            defer { replacement.cancel(with: .normalClosure, reason: nil) }
            try await barrier(replacement)
            #expect(controller.latestClientStats == nil)
            try await replacement.send(.string(#"{"type":"client-stats","rtt":1,"dropped":0,"decodeFps":0}"#))
            try await barrier(replacement)
            #expect(controller.latestClientStats == .init(rtt: 1, dropped: 0, decodeFps: 0))
        } catch {
            await controller.stop()
            throw error
        }
        await controller.stop()
        #expect(controller.latestClientStats == nil)
    }

    private func socket(_ port: Int, _ kind: String, _ token: PairingToken) throws -> URLSessionWebSocketTask {
        let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws/\(kind)?t=\(token.value)"))
        let socket = URLSession.shared.webSocketTask(with: url)
        socket.resume()
        return socket
    }

    private func barrier(_ socket: URLSessionWebSocketTask) async throws {
        let ping = #"{"type":"ping","t":1}"#
        try await socket.send(.string(ping))
        let echo = try await socket.receive()
        guard case .string(let text) = echo else { throw RemoteMirrorTestFailure.unexpectedMessageKind }
        #expect(text == ping)
    }
}
