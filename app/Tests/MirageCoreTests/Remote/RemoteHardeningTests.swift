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
        // 執行共用 3 秒、清理另給 1 秒；不使用注入的假時鐘計算測試 deadline。
        let deadline = ContinuousClock.now + .seconds(3)
        let diagnostics: @Sendable () -> String = {
            "requests=\(requests.current), throttled=\(server.stats().keyframeRequestsThrottled), state=\(server.sessionState)"
        }
        do {
            let port = try await RemoteTestWaits.boundedOperation("start", until: deadline, diagnostics: diagnostics) {
                try await server.start()
            }
            let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws/video?t=\(token.value)"))
            let video = URLSession.shared.webSocketTask(with: url)
            defer { video.cancel(with: .normalClosure, reason: nil) }
            video.resume()
            try await RemoteTestWaits.boundedOperation("send five keyframes", until: deadline, diagnostics: diagnostics,
                                                       cancel: { video.cancel(with: .goingAway, reason: nil) }) {
                for _ in 0..<5 { try await video.send(.string("keyframe")) }
            }
            // keyframe 文字沒有 ACK；直接觀察實際效果，不依賴 sendPing completion。
            try await waitForCounts(requests: requests, server: server, accepted: 2, throttled: 4, until: deadline)
            #expect(requests.current == 2) // 配對一次、明確請求一次。
            #expect(server.stats().keyframeRequestsThrottled == 4)
            clock.advance(.milliseconds(500))
            try await RemoteTestWaits.boundedOperation("send after 500 ms", until: deadline, diagnostics: diagnostics,
                                                       cancel: { video.cancel(with: .goingAway, reason: nil) }) {
                try await video.send(.string("keyframe"))
            }
            try await waitForCounts(requests: requests, server: server, accepted: 3, throttled: 4, until: deadline)
            #expect(requests.current == 3)
            #expect(server.stats().keyframeRequestsThrottled == 4)
        } catch {
            do { try await stop(server, diagnostics: diagnostics) } catch { Issue.record(error) }
            throw error
        }
        try await stop(server, diagnostics: diagnostics)
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

    @Test func missingCallbackFailsWithCountsWithoutWaitingForWorker() async throws {
        let callback = HardeningCallback()
        let cancellations = CountGate()
        defer { callback.finish() }
        // 若 helper 退化成等待不可取消的 worker，保底釋放並讓下方「應逾時」斷言失敗。
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { callback.finish() }
        do {
            try await RemoteTestWaits.boundedOperation(
                "missing callback", until: .now + .milliseconds(20),
                diagnostics: { "requests=2, throttled=4" }, cancel: { cancellations.increment() }
            ) {
                await withCheckedContinuation { callback.install($0) }
            }
            Issue.record("沒有 callback 時必須逾時，不能等 worker 結束")
        } catch let error as RemoteTestWaitError {
            #expect(error == .timedOut("missing callback requests=2, throttled=4"))
            #expect(cancellations.current == 1)
        }
    }

    @Test func expiredDeadlineDoesNotStartAnotherOperation() async throws {
        let started = CountGate()
        do {
            try await RemoteTestWaits.boundedOperation("expired", until: .now - .milliseconds(1), diagnostics: { "requests=0" }) {
                started.increment()
            }
            Issue.record("已到期的共用 deadline 必須拒絕下一個操作")
        } catch let error as RemoteTestWaitError {
            #expect(error == .timedOut("expired requests=0"))
            #expect(started.current == 0)
        }
    }

    @Test func countWaitFailsWithActualCountsInsteadOfWaitingForThrottledCallback() async throws {
        let token = try #require(PairingToken(value: "00112233445566778899aabbccddeeff"))
        let server = RemoteServer(configuration: .init(token: token, viewerPage: Data()), onTouches: { _ in })
        let requests = CountGate()
        do {
            try await waitForCounts(requests: requests, server: server, accepted: 3, throttled: 4,
                                    until: .now + .milliseconds(20))
            Issue.record("不足的計數必須在 deadline 失敗")
        } catch let error as RemoteTestWaitError {
            #expect(error == .timedOut("keyframe expected requests=3, throttled=4; actual requests=0, throttled=0"))
        }
    }

    private func waitForCounts(requests: CountGate, server: RemoteServer, accepted: Int, throttled: Int,
                               until deadline: ContinuousClock.Instant) async throws {
        while requests.current < accepted || server.stats().keyframeRequestsThrottled < throttled {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw RemoteTestWaitError.timedOut(
                    "keyframe expected requests=\(accepted), throttled=\(throttled); actual requests=\(requests.current), throttled=\(server.stats().keyframeRequestsThrottled)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func stop(_ server: RemoteServer, diagnostics: @escaping @Sendable () -> String) async throws {
        try await RemoteTestWaits.boundedOperation("stop", until: .now + .seconds(1), diagnostics: diagnostics) {
            await server.stop()
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

/// 可先釋放、後安裝；測試逾時／取消與 worker 啟動的競態也不會遺失 continuation。
private final class HardeningCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume()
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish() {
        lock.lock()
        finished = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}
