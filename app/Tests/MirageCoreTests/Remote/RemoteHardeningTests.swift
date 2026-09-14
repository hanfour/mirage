import Foundation
import Testing
@testable import MirageCore

@Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteHardeningTests {
    @Test func keyframeWindowAllowsOnlyOneOfFiveAndIncludesBoundary() {
        let start = ContinuousClock.now
        var last: ContinuousClock.Instant?
        var accepted = 0
        for _ in 0..<5 {
            if RemoteServerCore.allowsKeyframe(lastRequest: last, now: start) {
                accepted += 1
                last = start
            }
        }
        #expect(accepted == 1)
        #expect(!RemoteServerCore.allowsKeyframe(lastRequest: last, now: start + .milliseconds(499)))
        #expect(RemoteServerCore.allowsKeyframe(lastRequest: last, now: start + .milliseconds(500)))
        #expect(!RemoteServerCore.allowsKeyframe(lastRequest: last, now: start - .milliseconds(1)))
    }

    @Test func loopbackKeyframeFloodIsThrottledUsingInjectedClock() async throws {
        let clock = HardeningClock()
        let requests = CountGate()
        let token = try #require(PairingToken(value: "00112233445566778899aabbccddeeff"))
        let server = RemoteServer(
            configuration: .init(host: "127.0.0.1", port: 0, token: token, viewerPage: Data()),
            onTouches: { _ in }, onKeyframeRequested: { requests.increment() }, now: { clock.now })
        do {
            let port = try await server.start()
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws/video?t=\(token.value)"))
            let video = URLSession.shared.webSocketTask(with: url)
            defer { video.cancel(with: .normalClosure, reason: nil) }
            video.resume()
            for _ in 0..<5 { try await video.send(.string("keyframe")) }
            // 同一 socket 的 pong 是前面五則文字已處理的 barrier。
            try await ping(video)
            #expect(requests.current == 2) // 配對一次、明確請求一次。
            #expect(server.stats().keyframeRequestsThrottled == 4)
            clock.advance(.milliseconds(500))
            try await video.send(.string("keyframe"))
            try await ping(video)
            #expect(requests.current == 3)
            #expect(server.stats().keyframeRequestsThrottled == 4)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    @Test func decodesClientStatsWithoutTouchTimestamp() throws {
        let result = RemoteTouchMessageDecoder.decode(#"{"type":"client-stats","rtt":15.25,"dropped":2,"decodeFps":29.5}"#)
        let decoded = try result.get()
        #expect(decoded == .clientStats(.init(rtt: 15.25, dropped: 2, decodeFps: 29.5)))
        let zero = RemoteTouchMessageDecoder.decode(#"{"type":"client-stats","rtt":0,"dropped":0,"decodeFps":0}"#)
        #expect(zero == .success(.clientStats(.init(rtt: 0, dropped: 0, decodeFps: 0))))
    }

    @Test(arguments: [
        #"{"type":"client-stats"}"#,
        #"{"type":"client-stats","rtt":true,"dropped":0,"decodeFps":30}"#,
        #"{"type":"client-stats","rtt":null,"dropped":0,"decodeFps":30}"#,
        #"{"type":"client-stats","rtt":"15","dropped":0,"decodeFps":30}"#,
        #"{"type":"client-stats","rtt":-1,"dropped":0,"decodeFps":30}"#,
        #"{"type":"client-stats","rtt":15,"dropped":-1,"decodeFps":30}"#,
        #"{"type":"client-stats","rtt":15,"dropped":0.5,"decodeFps":30}"#,
        #"{"type":"client-stats","rtt":15,"dropped":true,"decodeFps":30}"#,
        #"{"type":"client-stats","rtt":15,"dropped":9007199254740992,"decodeFps":30}"#,
        #"{"type":"client-stats","rtt":15,"dropped":0,"decodeFps":-1}"#,
        #"{"type":"client-stats","rtt":15,"dropped":0,"decodeFps":false}"#,
        #"{"type":"client-stats","rtt":1e999,"dropped":0,"decodeFps":30}"#,
    ]) func rejectsInvalidClientStats(_ text: String) {
        let decoded = RemoteTouchMessageDecoder.decode(text)
        if case .failure = decoded { /* 預期：不產生任何輸入效果。 */ }
        else { Issue.record("非法品質回報被接受：\(text)") }
    }

    private func ping(_ socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

private final class HardeningClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant {
        lock.lock(); defer { lock.unlock() }
        return instant
    }
    func advance(_ duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        instant = instant + duration
    }
}
