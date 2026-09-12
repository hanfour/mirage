import Foundation
import Testing
@testable import MirageCore

/// 用 `127.0.0.1:0` 起真實 socket；用戶端是 Foundation 的 URLSession（握手被拒時
/// `task.response` 帶狀態碼，2026-09-12 實測 403／409 皆可讀）。`.serialized` 是因為
/// 每條測試都開 listener，並行只會把負載造成的逾時混進來。
@Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteServerTests {
    private static let token = PairingToken(value: "00112233445566778899aabbccddeeff")!
    private static let page = Data("<!doctype html><title>t</title>VideoDecoder".utf8)
    private static let keyframeUnit = H264Nal.join([
        Data([0x27, 0x42, 0x00, 0x32, 0xab, 0x40, 0x22, 0x00, 0x96, 0xf2, 0xe8]),
        Data([0x28, 0xce, 0x3c, 0x80]),
        Data([0x65, 0x88, 0x84, 0x00]),
    ])
    private static let deltaUnit = H264Nal.join([Data([0x41, 0x9a, 0x02])])
    private static let down = #"{"t":1,"id":7,"type":"down","x":0.25,"y":0.75}"#
    private static let ping = #"{"type":"ping","t":1234.5}"#

    private enum TestFailure: Error { case unexpectedMessageKind }

    private struct Harness: Sendable {
        let server: RemoteServer
        let port: Int
        let touches: StateRecorder<[TouchSpec]>
        let keys: StateRecorder<KeyCode>
        let texts: StateRecorder<String>
        let touchCalls: CountGate
        let states: StateRecorder<RemoteSessionState>
        let keyframes: CountGate
    }

    private func start() async throws -> Harness {
        let touches = StateRecorder<[TouchSpec]>()
        let keys = StateRecorder<KeyCode>()
        let texts = StateRecorder<String>()
        let touchCalls = CountGate()
        let states = StateRecorder<RemoteSessionState>()
        let keyframes = CountGate()
        let server = RemoteServer(
            configuration: RemoteServerConfiguration(host: "127.0.0.1", port: 0, token: Self.token, viewerPage: Self.page),
            onTouches: { specs in
                touchCalls.increment()
                Task { await touches.record(specs) }
            },
            onText: { text in Task { await texts.record(text) } },
            onKey: { code in Task { await keys.record(code) } },
            onKeyframeRequested: { keyframes.increment() },
            onStateChanged: { state in Task { await states.record(state) } })
        let port = try await server.start()
        return Harness(server: server, port: port, touches: touches, keys: keys, texts: texts, touchCalls: touchCalls,
                       states: states, keyframes: keyframes)
    }

    private func url(_ port: Int, _ path: String, token: String? = RemoteServerTests.token.value, scheme: String = "http") -> URL {
        var c = URLComponents()
        c.scheme = scheme; c.host = "127.0.0.1"; c.port = port; c.path = path
        if let token { c.queryItems = [URLQueryItem(name: "t", value: token)] }
        return c.url!
    }

    private func get(_ port: Int, _ path: String, token: String? = RemoteServerTests.token.value) async throws -> (status: Int, body: Data) {
        let (data, response) = try await URLSession.shared.data(from: url(port, path, token: token))
        return (try #require(response as? HTTPURLResponse).statusCode, data)
    }

    private func webSocket(_ port: Int, _ path: String, token: String? = RemoteServerTests.token.value) -> URLSessionWebSocketTask {
        let task = URLSession.shared.webSocketTask(with: url(port, path, token: token, scheme: "ws"))
        task.resume()
        return task
    }

    /// 只給「預期被拒」的握手用：receive 會拋錯，狀態碼在 task.response。
    private func handshakeStatus(_ task: URLSessionWebSocketTask) async -> Int? {
        _ = try? await task.receive()
        return (task.response as? HTTPURLResponse)?.statusCode
    }

    private func receiveData(_ task: URLSessionWebSocketTask) async throws -> Data {
        guard case .data(let data) = try await task.receive() else { throw TestFailure.unexpectedMessageKind }
        return data
    }

    private func receiveText(_ task: URLSessionWebSocketTask) async throws -> String {
        guard case .string(let text) = try await task.receive() else { throw TestFailure.unexpectedMessageKind }
        return text
    }

    /// 網路操作拋錯也完成清理，不以 unstructured Task 延後到下一條測試。
    private func withServer(_ body: (Harness) async throws -> Void) async throws {
        let harness = try await start()
        do {
            try await body(harness)
        } catch {
            await harness.server.stop()
            throw error
        }
        await harness.server.stop()
    }

    @Test func statsTextBypassesWaitingForKeyframe() async throws {
        try await withServer { h in
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            await h.keyframes.wait(for: 1)
            h.server.send(accessUnit: Self.deltaUnit, keyframe: false, sequence: 0)
            let json = #"{"type":"stats","newFrames":30,"heartbeatFrames":0}"#
            h.server.sendStats(Data(json.utf8))
            let text = try await receiveText(video)
            #expect(text == json)
            #expect(h.server.stats().framesOffered == 1)
            #expect(h.server.stats().framesSent == 0)
            #expect(h.server.stats().framesDropped == 1)
            h.server.send(accessUnit: Self.keyframeUnit, keyframe: true, sequence: 1)
            let data = try await receiveData(video)
            #expect(RemoteVideoMessage.decode(data)?.sequence == 1)
        }
    }

    @Test func servesViewerOnlyWithCorrectToken() async throws {
        try await withServer { h in
            #expect(h.port > 0)
            #expect(h.server.boundPort == h.port)
            let ok = try await get(h.port, "/")
            #expect(ok.status == 200)
            #expect(ok.body == Self.page)
            let wrongToken = try await get(h.port, "/", token: "00112233445566778899aabbccddeefe")
            #expect(wrongToken.status == 403)
            let noToken = try await get(h.port, "/", token: nil)
            #expect(noToken.status == 403)
            let unknownPath = try await get(h.port, "/nope")
            #expect(unknownPath.status == 404)
            #expect(h.server.stats().rejectedForbidden == 2)
            #expect(h.server.sessionState == .initial)
            await h.server.stop()
        }
    }

    @Test func videoViewerGetsKeyframeFirstAndSequenceHeader() async throws {
        try await withServer { h in
            let video = webSocket(h.port, "/ws/video")
            await h.states.wait { $0.contains { $0.hasVideo } }
            await h.keyframes.wait(for: 1)

            h.server.send(accessUnit: Self.deltaUnit, keyframe: false, sequence: 0)   // 等 keyframe 期間丟掉
            h.server.send(accessUnit: Self.keyframeUnit, keyframe: true, sequence: 1)
            let firstData = try await receiveData(video)
            let first = try #require(RemoteVideoMessage.decode(firstData))
            #expect(first.sequence == 1)
            #expect(first.isKeyframe)
            #expect(first.accessUnit == Self.keyframeUnit)
            #expect(first.sentAtNanoseconds > 0)

            h.server.send(accessUnit: Self.deltaUnit, keyframe: false, sequence: 2)
            let secondData = try await receiveData(video)
            let second = try #require(RemoteVideoMessage.decode(secondData))
            #expect(second.sequence == 2)
            #expect(!second.isKeyframe)

            #expect(h.server.sessionState.isViewerConnected)
            video.cancel(with: .normalClosure, reason: nil)
            await h.states.wait { $0.contains { $0.phase == .disconnected } }
            await h.server.stop()
            let stats = h.server.stats()
            #expect(stats.framesOffered == 3)
            #expect(stats.framesSent == 2)
            #expect(stats.framesDropped == 1)
        }
    }

    @Test func secondVideoSocketIsRefusedWith409AndFirstKeepsWorking() async throws {
        try await withServer { h in
            let first = webSocket(h.port, "/ws/video")
            await h.states.wait { $0.contains { $0.hasVideo } }
            let second = webSocket(h.port, "/ws/video")
            let secondStatus = await handshakeStatus(second)
            #expect(secondStatus == 409)
            #expect(h.server.stats().rejectedBusy == 1)
            h.server.send(accessUnit: Self.keyframeUnit, keyframe: true, sequence: 10)
            let data = try await receiveData(first)
            let message = try #require(RemoteVideoMessage.decode(data))
            #expect(message.sequence == 10)
            first.cancel(with: .normalClosure, reason: nil)
            await h.states.wait { $0.contains { $0.phase == .disconnected } }
            let reconnected = webSocket(h.port, "/ws/video")
            await h.keyframes.wait(for: 2)
            h.server.send(accessUnit: Self.deltaUnit, keyframe: false, sequence: 11)
            h.server.send(accessUnit: Self.keyframeUnit, keyframe: true, sequence: 12)
            let nextData = try await receiveData(reconnected)
            let nextMessage = try #require(RemoteVideoMessage.decode(nextData))
            #expect(nextMessage.sequence == 12)
            #expect(nextMessage.isKeyframe)
            reconnected.cancel(with: .normalClosure, reason: nil)
            await h.server.stop()
        }
    }

    @Test func wrongTokenUpgradeIs403AndLeavesStateUntouched() async throws {
        try await withServer { h in
            let video = webSocket(h.port, "/ws/video", token: "00112233445566778899aabbccddeefe")
            let videoStatus = await handshakeStatus(video)
            #expect(videoStatus == 403)
            let input = webSocket(h.port, "/ws/input", token: nil)
            let inputStatus = await handshakeStatus(input)
            #expect(inputStatus == 403)
            #expect(h.server.stats().rejectedForbidden == 2)
            #expect(h.server.sessionState == .initial)
            await h.server.stop()
        }
    }

    @Test func inputEchoesPingVerbatimAndForwardsTouches() async throws {
        try await withServer { h in
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            await h.keyframes.wait(for: 1)
            let input = webSocket(h.port, "/ws/input")
            try await input.send(.string(Self.ping))
            let echo = try await receiveText(input)
            #expect(echo == Self.ping)
            let secondInput = webSocket(h.port, "/ws/input")
            let secondStatus = await handshakeStatus(secondInput)
            #expect(secondStatus == 409)
            #expect(h.server.stats().rejectedBusy == 1)


            try await input.send(.string(Self.down))
            await h.touches.wait { !$0.isEmpty }
            let forwarded = await h.touches.items
            #expect(forwarded == [[TouchSpec(identifier: 64, point: NormPoint(x: 0.25, y: 0.75), down: true)]])

            try await input.send(.string(#"{"type":"touches","t":2,"points":[{"id":7,"phase":"up","x":0.2,"y":0.3},{"id":9,"phase":"move","x":0.4,"y":0.5}]}"#))
            try await input.send(.string(#"{"type":"touches","t":3,"points":[{"id":8,"phase":"down","x":0.2,"y":0.3},{"id":9,"phase":"down","x":0.4,"y":0.5}]}"#))
            await h.touches.wait { $0.count == 2 }
            let batches = await h.touches.items
            #expect(batches[1].map(\.identifier) == [65, 66])
            #expect(batches.count == 2)
            try await input.send(.string("nope"))
            try await input.send(.string(#"{"type":"move","id":99,"x":0.5,"y":0.5}"#))   // 未知 pointer
            try await input.send(.string(Self.ping))                                      // 同一條連線依序處理，echo 回來代表前兩則已處理
            let secondEcho = try await receiveText(input)
            #expect(secondEcho == Self.ping)
            let stats = h.server.stats()
            #expect(stats.invalidInputMessages == 3)
            #expect(stats.touchesForwarded == 2)
            input.cancel(with: .normalClosure, reason: nil)
            await h.server.stop()
        }
    }

    @Test func inputForwardsHomeAndCountsRejectedKeys() async throws {
        try await withServer { h in
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            await h.keyframes.wait(for: 1)
            let input = webSocket(h.port, "/ws/input")
            defer { input.cancel(with: .normalClosure, reason: nil) }
            for text in [
                #"{"type":"key","key":"GoHome","t":1}"#,
                #"{"type":"key","key":"gohome","t":2}"#,
                #"{"type":"key","key":"Power","t":3}"#,
                #"{"type":"key","t":4}"#,
            ] {
                try await input.send(.string(text))
            }
            try await input.send(.string(Self.ping))
            let echo = try await receiveText(input)
            #expect(echo == Self.ping)
            await h.keys.wait { !$0.isEmpty }
            let keys = await h.keys.items
            #expect(keys == [.key("GoHome")])
            #expect(h.server.stats().invalidInputMessages == 3)
            #expect(h.server.stats().touchesForwarded == 0)
        }
    }

    @Test func inputForwardsTextAndCountsInvalidText() async throws {
        try await withServer { h in
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            await h.keyframes.wait(for: 1)
            let input = webSocket(h.port, "/ws/input")
            defer { input.cancel(with: .normalClosure, reason: nil) }
            try await input.send(.string(#"{"type":"text","text":"中文🙂","t":1}"#))
            try await input.send(.string(#"{"type":"text","text":"","t":2}"#))
            let oversized = String(repeating: "a", count: 4097)
            try await input.send(.string(#"{"type":"text","text":"\#(oversized)","t":3}"#))
            try await input.send(.string(Self.ping))
            let echo = try await receiveText(input)
            #expect(echo == Self.ping)
            await h.texts.wait { !$0.isEmpty }
            let texts = await h.texts.items
            #expect(texts == ["中文🙂"])
            #expect(h.server.stats().invalidInputMessages == 2)
        }
    }

    @Test func closingInputReleasesActiveTouches() async throws {
        try await withServer { h in
            let video = webSocket(h.port, "/ws/video")
            defer { video.cancel(with: .normalClosure, reason: nil) }
            await h.keyframes.wait(for: 1)
            let input = webSocket(h.port, "/ws/input")
            try await input.send(.string(Self.down))
            await h.touches.wait { $0.count == 1 }
            input.cancel(with: .normalClosure, reason: nil)
            await h.touches.wait { $0.count == 2 }
            let released = await h.touches.items[1]
            #expect(released == [TouchSpec(identifier: 64, point: NormPoint(x: 0.25, y: 0.75), down: false)])
            #expect(h.server.sessionState == RemoteSessionState(phase: .connected, hasVideo: true, hasInput: false))
            #expect(h.server.stats().touchesForwarded == 2)
            await h.server.stop()
        }
    }

    @Test func stopClosesViewerReleasesTouchesAndReportsDisconnected() async throws {
        try await withServer { h in
            let video = webSocket(h.port, "/ws/video")
            await h.keyframes.wait(for: 1)
            let input = webSocket(h.port, "/ws/input")
            try await input.send(.string(Self.down))
            await h.touches.wait { $0.count == 1 }
            await h.states.wait { $0.contains { $0.hasVideo && $0.hasInput } }

            await h.server.stop()
            #expect(h.server.sessionState == RemoteSessionState(phase: .disconnected, hasVideo: false, hasInput: false))
            await h.touches.wait { $0.count == 2 }
            let released = await h.touches.items[1]
            #expect(released == [TouchSpec(identifier: 64, point: NormPoint(x: 0.25, y: 0.75), down: false)])
            await #expect(throws: (any Error).self) { _ = try await video.receive() }
            h.server.send(accessUnit: Self.keyframeUnit, keyframe: true, sequence: 1)   // 停止後不崩、只計數
            #expect(h.server.stats().framesOffered == 1)
            #expect(h.server.stats().framesSent == 0)
            input.cancel(with: .normalClosure, reason: nil)
        }
    }

    @Test func inputWithoutVideoIs409AndCannotForwardTouches() async throws {
        try await withServer { h in
            let input = webSocket(h.port, "/ws/input")
            _ = try? await input.send(.string(Self.down))
            let status = await handshakeStatus(input)
            #expect(status == 409)
            #expect(h.server.sessionState == .initial)
            let stats = h.server.stats()
            #expect(stats.rejectedBusy == 1)
            #expect(stats.rejectedForbidden == 0)
            #expect(stats.touchesForwarded == 0)
            #expect(stats.invalidInputMessages == 0)
            #expect(h.touchCalls.current == 0)
            #expect(h.keyframes.current == 0)
            let forwarded = await h.touches.items
            #expect(forwarded.isEmpty)
        }
    }

    @Test func closingVideoClosesInputAndReleasesActiveTouches() async throws {
        try await withServer { h in
            let video = webSocket(h.port, "/ws/video")
            await h.keyframes.wait(for: 1)
            let input = webSocket(h.port, "/ws/input")
            try await input.send(.string(Self.down))
            await h.touches.wait { $0.count == 1 }

            video.cancel(with: .normalClosure, reason: nil)
            await #expect(throws: (any Error).self) { _ = try await input.receive() }
            await h.touches.wait { $0.count == 2 }
            #expect(h.server.sessionState == RemoteSessionState(phase: .disconnected, hasVideo: false, hasInput: false))
            let released = await h.touches.items[1]
            #expect(released == [TouchSpec(identifier: 64, point: NormPoint(x: 0.25, y: 0.75), down: false)])
            await h.server.stop()
            #expect(h.server.stats().touchesForwarded == 2)
            #expect(h.touchCalls.current == 2)
        }
    }

    @Test func startTwiceIsRejected() async throws {
        try await withServer { h in
            await #expect(throws: RemoteServerError.alreadyStarted) { _ = try await h.server.start() }
            await h.server.stop()
            await #expect(throws: RemoteServerError.alreadyStarted) { _ = try await h.server.start() }
        }
    }

    @Test func portInUseFailsToStart() async throws {
        try await withServer { h in
            let clash = RemoteServer(
                configuration: RemoteServerConfiguration(host: "127.0.0.1", port: h.port, token: Self.token, viewerPage: Self.page),
                onTouches: { _ in })
            await #expect(throws: (any Error).self) { _ = try await clash.start() }
            await h.server.stop()
        }
    }
}
