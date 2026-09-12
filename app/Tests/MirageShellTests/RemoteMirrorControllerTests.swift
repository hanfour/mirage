import Foundation
import Testing
@testable import MirageCore
@testable import MirageShell

@Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteMirrorControllerTests {
    private static let token = PairingToken(value: "00112233445566778899aabbccddeeff")!
    private static let page = Data("<!doctype html>viewer".utf8)

    private struct Harness {
        let controller: RemoteMirrorController
        let port: Int
        let encoder: RemoteMirrorFakeEncoder
        let injector: RemoteMirrorRecordingInjector
        let queue: InputQueue
        let errors: StateRecorder<String>
        let states: StateRecorder<RemoteSessionState>
    }

    private func start(failEncoding: Bool = false,
                       pullInterval: Duration = .milliseconds(5),
                       heartbeatInterval: Duration = .milliseconds(250)) async throws -> Harness {
        var configuration = RemoteMirrorConfiguration(token: Self.token, viewerPage: Self.page)
        configuration.host = "127.0.0.1"
        configuration.port = 0
        configuration.pullInterval = pullInterval
        configuration.heartbeatInterval = heartbeatInterval
        let injector = RemoteMirrorRecordingInjector()
        let queue = InputQueue(injector: injector)
        let states = StateRecorder<RemoteSessionState>()
        let errors = StateRecorder<String>()
        let box = RemoteMirrorFakeEncoderBox()
        let controller = RemoteMirrorController(
            configuration: configuration, secondary: LatestFrameBox(), inputQueue: queue,
            makeEncoder: {
                let encoder = RemoteMirrorFakeEncoder(failEncoding: failEncoding)
                box.encoder = encoder
                return encoder
            },
            onError: { message in Task { await errors.record(message) } },
            onStateChanged: { state in Task { await states.record(state) } })
        let port = try await controller.start()
        return Harness(controller: controller, port: port, encoder: box.encoder!, injector: injector,
                       queue: queue, errors: errors, states: states)
    }

    /// `makeEncoder` 是非逃逸閉包，用一個盒子把建好的假件帶出來。
    private final class RemoteMirrorFakeEncoderBox: @unchecked Sendable { var encoder: RemoteMirrorFakeEncoder? }

    private func webSocket(_ port: Int, _ path: String) -> URLSessionWebSocketTask {
        var c = URLComponents()
        c.scheme = "ws"; c.host = "127.0.0.1"; c.port = port; c.path = path
        c.queryItems = [URLQueryItem(name: "t", value: Self.token.value)]
        let task = URLSession.shared.webSocketTask(with: c.url!)
        task.resume()
        return task
    }

    private func receiveData(_ task: URLSessionWebSocketTask) async throws -> Data {
        while true {
            switch try await task.receive() {
            case .data(let data): return data
            case .string(let text):
                let summary = try JSONDecoder().decode(RemoteLatencySummary.self, from: Data(text.utf8))
                #expect(summary.type == "stats")
            @unknown default: throw RemoteMirrorTestFailure.unexpectedMessageKind
            }
        }
    }

    private func frame(_ width: Int) -> Frame {
        Frame(width: width, height: 1, rgba: Data(count: width * 4))
    }

    private func withController(pullInterval: Duration = .milliseconds(5),
                                heartbeatInterval: Duration = .milliseconds(250),
                                _ body: (Harness) async throws -> Void) async throws {
        let h = try await start(pullInterval: pullInterval, heartbeatInterval: heartbeatInterval)
        do { try await body(h) } catch { await h.controller.stop(); throw error }
        await h.controller.stop()
    }

    /// 沒有 viewer 時不拉幀、不編碼（spec 第 6 節）。
    @Test func sendsAgeAndHeartbeatStatsOnVideoSocket() async throws {
        try await withController { h in
            let source = Frame(width: 8, height: 1, rgba: Data(count: 32),
                               receivedAt: .now - .milliseconds(50), transitMs: 7)
            h.controller.secondary.put(source)
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            var summary: RemoteLatencySummary?
            while summary == nil {
                if case .string(let text) = try await video.receive() {
                    summary = try JSONDecoder().decode(RemoteLatencySummary.self, from: Data(text.utf8))
                }
            }
            let stats = try #require(summary)
            #expect(stats.newFrames == 1)
            #expect(stats.heartbeatFrames > 0)
            #expect(stats.age?.count == 1)
            #expect((stats.age?.p50 ?? 0) >= 50)
            #expect(stats.transitMs == 7)
            #expect((stats.encode?.count ?? 0) > 0)
            #expect(stats.send?.count == stats.encode?.count)
        }
    }

    @Test func publishesEmptyWindowWithoutEncoderCallbacks() async throws {
        try await withController { h in
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            let message = try await video.receive()
            guard case .string(let text) = message else { throw RemoteMirrorTestFailure.unexpectedMessageKind }
            let stats = try JSONDecoder().decode(RemoteLatencySummary.self, from: Data(text.utf8))
            #expect(stats.newFrames == 0)
            #expect(stats.heartbeatFrames == 0)
            #expect(stats.age == nil)
            #expect(stats.encode == nil)
            #expect(stats.send == nil)
            #expect(h.encoder.calls == 0)
        }
    }

    @Test func doesNotEncodeWithoutViewer() async throws {
        try await withController { h in
            #expect(h.port > 0)
            #expect(h.controller.boundPort == h.port)
            h.controller.secondary.put(frame(8))
            try await Task.sleep(for: .seconds(1))     // 四個心跳週期也不能消耗 sink
            #expect(h.encoder.calls == 0)
            #expect(h.controller.stats().framesPulled == 0)
            #expect(h.controller.secondary.stats().arrived == 1)
        }
    }

    /// viewer 連上 → 要求 keyframe → 拉幀編碼 → 序號從 1 起遞增送到 WebSocket。
    @Test func viewerGetsSequencedAccessUnitsStartingWithKeyframe() async throws {
        try await withController { h in
            let video = webSocket(h.port, "/ws/video")
            await h.states.wait { $0.contains { $0.hasVideo } }
            while h.encoder.requests < 1 { await Task.yield() }

            h.controller.secondary.put(frame(8))
            let firstData = try await receiveData(video)          // `try` 不放進 #require 的括號
            let first = try #require(RemoteVideoMessage.decode(firstData))
            #expect(first.sequence == 1)
            #expect(first.isKeyframe)
            #expect(first.accessUnit == H264Nal.join([RemoteMirrorFakeEncoder.sps, RemoteMirrorFakeEncoder.pps, Data([0x65, 8])]))

            h.controller.secondary.put(frame(9))
            let secondData = try await receiveData(video)
            let second = try #require(RemoteVideoMessage.decode(secondData))
            #expect(second.sequence == 2)
            #expect(!second.isKeyframe)

            while h.controller.stats().framesEncoded < 2 || h.controller.stats().server.framesSent < 2 {
                await Task.yield()
            }
            let stats = h.controller.stats()
            #expect(stats.framesPulled == 2)
            #expect(stats.framesEncoded == 2)
            #expect(stats.server.framesSent == 2)
            video.cancel(with: .normalClosure, reason: nil)
            await h.states.wait { $0.contains { $0.phase == .disconnected } }
        }
    }

    @Test func staticFrameIsRepeatedAtHeartbeatIntervalWithIncreasingPTS() async throws {
        try await withController { h in
            h.controller.secondary.put(frame(8))
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            _ = try await receiveData(video)
            let initialRequests = h.encoder.requests
            #expect(initialRequests == 1) // 初連只要求一次 IDR
            let started = ContinuousClock.now
            for _ in 0..<4 { _ = try await receiveData(video) }
            #expect(h.encoder.calls == 5) // 初幀一次，250/500/750/1000 ms 各一次心跳
            #expect(ContinuousClock.now - started < .seconds(2))
            #expect(h.encoder.requests - initialRequests == 0) // 心跳不另要求 keyframe
            #expect(h.controller.stats().framesPulled == 1)
            let times = h.encoder.presentationTimes
            #expect(zip(times, times.dropFirst()).allSatisfy { pair in pair.0 < pair.1 })
            video.cancel(with: .normalClosure, reason: nil)
            while h.controller.sessionState.hasVideo { await Task.yield() }
            let stoppedCalls = h.encoder.calls
            try await Task.sleep(for: .milliseconds(600))
            #expect(h.encoder.calls == stoppedCalls) // 有快取、有截止計時器也不得再送心跳
        }
    }

    @Test func threeFramesWithinRateLimitEncodeOnlyLatest() async throws {
        try await withController(pullInterval: .nanoseconds(1_000_000_000 / 30),
                                 heartbeatInterval: .seconds(10)) { h in
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            h.controller.secondary.put(frame(8))
            await h.encoder.encoded.wait(for: 1)
            // 限速區間內三幀相隔 1 ms；沒有先前編碼時第一幀應立即送，不能 debounce。
            for width in 9...11 {
                h.controller.secondary.put(frame(width))
                try await Task.sleep(for: .milliseconds(1))
            }
            _ = try await receiveData(video)
            let data = try await receiveData(video)
            let message = try #require(RemoteVideoMessage.decode(data))
            #expect(message.accessUnit == H264Nal.join([Data([0x41, 11])]))
            try await Task.sleep(for: .milliseconds(40))
            #expect(h.encoder.calls == 2) // 初幀 + 三幀合併成一次
            #expect(h.controller.stats().framesPulled == 2)
            let times = h.encoder.encodingStarts
            #expect(times[1] - times[0] >= h.controller.pullInterval)
        }
    }

    @Test func firstFrameAfterSubscriptionDoesNotWaitForRatePeriod() async throws {
        try await withController(pullInterval: .seconds(1), heartbeatInterval: .seconds(10)) { h in
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            while h.encoder.requests < 1 { await Task.yield() }
            try await Task.sleep(for: .milliseconds(50)) // 連線請求已處理，但當時沒有幀
            #expect(h.encoder.calls == 0)
            let arrived = ContinuousClock.now
            h.controller.secondary.put(frame(8))
            _ = try await receiveData(video)
            #expect(ContinuousClock.now - arrived < .milliseconds(200))
            #expect(h.encoder.calls == 1)
        }
    }

    @Test func framesFortyMillisecondsApartEachEncodeImmediately() async throws {
        try await withController(pullInterval: .nanoseconds(1_000_000_000 / 30),
                                 heartbeatInterval: .seconds(10)) { h in
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            for width in 8...10 {
                h.controller.secondary.put(frame(width))
                _ = try await receiveData(video)
                #expect(h.encoder.calls == width - 7)
                try await Task.sleep(for: .milliseconds(40))
            }
            #expect(h.controller.stats().framesPulled == 3)
        }
    }

    @Test func freshFrameAfterIdleGapDoesNotRequestKeyframe() async throws {
        try await withController(heartbeatInterval: .seconds(10)) { h in
            h.controller.secondary.put(frame(8))
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            _ = try await receiveData(video)
            try await Task.sleep(for: .milliseconds(150))
            h.controller.secondary.put(frame(8))
            let data = try await receiveData(video)
            let resumed = try #require(RemoteVideoMessage.decode(data))
            #expect(!resumed.isKeyframe)
            #expect(h.encoder.requests == 1)
            #expect(h.controller.stats().framesPulled == 2)
        }
    }

    @Test func heartbeatIntervalIsConfigurable() async throws {
        try await withController(heartbeatInterval: .seconds(10)) { h in
            h.controller.secondary.put(frame(8))
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            _ = try await receiveData(video)
            try await Task.sleep(for: .milliseconds(600))
            #expect(h.encoder.calls == 1)
        }
    }

    /// 不依賴新幀通知：連線時直接取信箱或最後快取，立即要求 keyframe。
    @Test func viewerImmediatelyGetsCachedKeyframeAndDisconnectStopsHeartbeats() async throws {
        try await withController(pullInterval: .nanoseconds(1_000_000_000 / 30), heartbeatInterval: .seconds(10)) { h in
            h.controller.secondary.put(frame(8))
            let firstViewer = webSocket(h.port, "/ws/video")
            _ = try await receiveData(firstViewer)
            #expect(h.encoder.requests == 1)
            firstViewer.cancel(with: .normalClosure, reason: nil)
            while h.controller.sessionState.hasVideo { await Task.yield() }
            let calls = h.encoder.calls
            try await Task.sleep(for: .milliseconds(600))
            #expect(h.encoder.calls == calls)
            #expect(h.controller.stats().framesPulled == 1)

            let connectedAt = ContinuousClock.now
            let nextViewer = webSocket(h.port, "/ws/video")
            defer { nextViewer.cancel(with: .normalClosure, reason: nil) }
            let nextData = try await receiveData(nextViewer)
            let next = try #require(RemoteVideoMessage.decode(nextData))
            #expect(ContinuousClock.now - connectedAt < .seconds(1))
            #expect(next.isKeyframe)
            #expect(next.sequence == 2)
            #expect(h.encoder.requests == 2) // 新 viewer 各要求一次
            #expect(h.controller.stats().framesPulled == 1) // 唯一一幀已取走，只能靠快取
        }
    }

    @Test func pendingKeyframeWaitsForFirstFrameAndViewerCanRequestAnother() async throws {
        try await withController(heartbeatInterval: .seconds(10)) { h in
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            while h.encoder.requests < 1 { await Task.yield() }
            #expect(h.encoder.calls == 0)
            h.controller.secondary.put(frame(8))
            _ = try await receiveData(video)
            try await video.send(.string("keyframe"))
            let requestedData = try await receiveData(video)
            let requested = try #require(RemoteVideoMessage.decode(requestedData))
            #expect(requested.isKeyframe)
            #expect(requested.sequence == 2)
            #expect(h.encoder.requests == 2) // 初連一次、明確請求一次
            #expect(h.controller.stats().framesPulled == 1)
        }
    }

    /// 手機觸控只經 `InputQueue.touches`：注入器收到的是 allocator 配好的識別碼 64。
    @Test func touchesReachInjectorThroughInputQueue() async throws {
        try await withController { h in
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            await h.states.wait { $0.contains { $0.hasVideo } }
            let input = webSocket(h.port, "/ws/input")
            try await input.send(.string(#"{"t":1,"id":3,"type":"down","x":0.25,"y":0.75}"#))
            await h.injector.gate.wait(for: 1)
            await h.queue.drained()
            #expect(h.injector.touches == [[TouchSpec(identifier: 64, point: NormPoint(x: 0.25, y: 0.75), down: true)]])
            input.cancel(with: .normalClosure, reason: nil)
            await h.injector.gate.wait(for: 2)           // 斷線 → allocator 全放開 → up
            #expect(h.injector.touches[1] == [TouchSpec(identifier: 64, point: NormPoint(x: 0.25, y: 0.75), down: false)])
        }
    }

    @Test func navigationKeysReachQueueAsOrderedDownUpPairs() async throws {
        try await withController { h in
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            await h.states.wait { $0.contains { $0.hasVideo } }
            let input = webSocket(h.port, "/ws/input")
            defer { input.cancel(with: .normalClosure, reason: nil) }
            let names = ["GoBack", "GoHome", "AppSwitch"]
            for name in names {
                try await input.send(.string(#"{"type":"key","key":"\#(name)","t":1}"#))
            }
            let ping = #"{"type":"ping","t":2}"#
            try await input.send(.string(ping))
            let echo = try await input.receive()
            guard case .string(let text) = echo else { throw RemoteMirrorTestFailure.unexpectedMessageKind }
            #expect(text == ping)
            await h.injector.keyGate.wait(for: 6)
            await h.queue.drained()
            let keys = h.injector.keys
            #expect(keys.map { $0.0 } == names.flatMap { [KeyCode.key($0), .key($0)] })
            #expect(keys.map { $0.1 } == [true, false, true, false, true, false])
        }
    }

    /// stop：拉取停止、編碼器 invalidate、server 關閉。
    @Test func stopInvalidatesEncoderAndClosesServer() async throws {
        let h = try await start()
        await h.controller.stop()
        #expect(h.encoder.wasInvalidated)
        #expect(h.controller.sessionState == RemoteSessionState(phase: .disconnected, hasVideo: false, hasInput: false))
        h.controller.secondary.put(frame(8))
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.encoder.calls == 0)
    }
    @Test func encodingFailureReportsOnceAndStopsPulling() async throws {
        let h = try await start(failEncoding: true)
        let video = webSocket(h.port, "/ws/video")
        defer { video.cancel(with: .normalClosure, reason: nil) }
        await h.states.wait { $0.contains { $0.hasVideo } }
        h.controller.secondary.put(frame(8))
        await h.errors.wait { !$0.isEmpty }
        h.controller.secondary.put(frame(9))
        await h.controller.stop()
        let errors = await h.errors.items
        #expect(errors.count == 1)
        #expect(h.controller.stats().encodeFailures == 1)
        #expect(h.controller.stats().framesPulled == 1)
        #expect(h.encoder.wasInvalidated)
    }

}
