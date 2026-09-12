import Foundation
import Testing
@testable import MirageCore

/// spec 第 2 節設計決定 2 的產品路徑：`/ws/input` → `RemoteServer` → `InputQueue.touches` →
/// `EmulatorClient.sendTouches` → 真模擬器。Swift 斷言只驗到 RPC 完成（`drained()` 回來）；
/// guest 是否真的收到由 `verify_remote_mirror.sh` 的 getevent 判定（比照 `KeymapReleaseLiveTests`）。
@Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteInputLiveTests {
    private static let token = PairingToken(value: "00112233445566778899aabbccddeeff")!

    @Test(.enabled(if: LiveGate.remote, "需 MIRAGE_LIVE=1 MIRAGE_LIVE_REMOTE=1，請跑 scripts/verify_remote_mirror.sh"))
    func remoteTouchReachesEmulatorThroughInputQueue() async throws {
        let client = EmulatorClient(host: "127.0.0.1", port: 8554)
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        let queue = InputQueue(injector: client)
        let (states, continuation) = AsyncStream<RemoteSessionState>.makeStream()
        defer { continuation.finish() }
        let server = RemoteServer(
            configuration: RemoteServerConfiguration(host: "127.0.0.1", port: 0, token: Self.token, viewerPage: Data()),
            onTouches: { queue.touches($0) },
            onStateChanged: { continuation.yield($0) })
        do {
            let port = try await server.start()
            // 健康探測填好 guestDisplay 前，sendTouches 會靜默略過注入（KeymapReleaseLiveTests 同一段）。
            try await Task.sleep(for: .seconds(2))

            var components = URLComponents()
            components.scheme = "ws"; components.host = "127.0.0.1"; components.port = port; components.path = "/ws/video"
            components.queryItems = [URLQueryItem(name: "t", value: Self.token.value)]
            // input 必須依附已配對的 video；保留 video 到觸控與 echo 全部完成。
            let video = URLSession.shared.webSocketTask(with: components.url!)
            defer { video.cancel(with: .normalClosure, reason: nil) }
            video.resume()
            _ = try await RemoteTestWaits.state(in: states, hasVideo: true, diagnostics: {
                "state=\(server.sessionState)，video response=\(String(describing: video.response))"
            })
            try #require(server.sessionState.hasVideo)
            components.path = "/ws/input"
            let input = URLSession.shared.webSocketTask(with: components.url!)
            defer { input.cancel(with: .normalClosure, reason: nil) }
            input.resume()
            try await input.send(.string(#"{"t":1,"id":1,"type":"down","x":0.5,"y":0.5}"#))
            try await Task.sleep(for: .milliseconds(150))
            try await input.send(.string(#"{"t":2,"id":1,"type":"up","x":0.5,"y":0.5}"#))
            try await input.send(.string(#"{"type":"ping","t":3}"#))
            _ = try await input.receive()            // echo 回來代表前兩則已進 InputQueue
            await queue.drained()                    // 同一 consumer 的 barrier：兩次 sendTouches 都已完成

            #expect(server.stats().touchesForwarded == 2)
            #expect(server.stats().invalidInputMessages == 0)
        } catch {
            await server.stop()
            await client.stop()
            throw error
        }
        await server.stop()
        await client.stop()
    }
}
