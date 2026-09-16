import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import MirageCore

@Suite(.serialized, .timeLimit(.minutes(1))) struct RemoteAudioServerTests {
    private func message(_ sequence: UInt32) -> RemoteAudioMessage {
        RemoteAudioMessage(sentAtNanoseconds: 123, sequence: sequence, samplingRate: 48_000,
                           channels: 2, samples: Data([1, 0, 2, 0]))
    }

    @Test func queueStatsAndPairingLifetime() async throws {
        let token = try #require(PairingToken(value: "00112233445566778899aabbccddeeff"))
        let server = RemoteServer(configuration: .init(token: token, viewerPage: Data()), onTouches: { _ in })
        let core = server.core
        let deadline = ContinuousClock.now + .seconds(5)
        let diagnostics: @Sendable () -> String = { "state=\(server.sessionState), stats=\(server.stats())" }
        var channels: [any Channel] = []
        do {
            // core 只依賴 channel 身分與關閉通知；不啟動 writer，才能確定性地製造背壓。
            for _ in 0..<6 {
                let channel = try await RemoteTestWaits.boundedOperation("bind", until: deadline, diagnostics: diagnostics) {
                    try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                        .bind(host: "127.0.0.1", port: 0).get()
                }
                channels.append(channel)
                #expect(core.track(channel))
            }
            let video = channels[0], audio = channels[1], replacement = channels[2], input = channels[3]
            let audioID = ObjectIdentifier(audio)
            let videoID = ObjectIdentifier(video)
            server.send(audio: message(99))
            #expect(core.admitUpgrade(channel: video, method: "GET", uri: "/ws/video?t=\(token.value)") == .video)
            #expect(core.admitUpgrade(channel: input, method: "GET", uri: "/ws/input?t=\(token.value)") == .input)
            #expect(core.admitUpgrade(channel: audio, method: "GET", uri: "/ws/audio?t=\(token.value)") == .audio)
            #expect(core.popAudioEntry(channelID: audioID) == nil)
            for sequence: UInt32 in 0..<13 { server.send(audio: message(sequence)) }
            #expect(server.stats().audioDropped == 3)
            server.sendStats(Data(#"{"type":"stats","newFrames":30}"#.utf8))
            let data = try #require(core.popStats(channelID: videoID))
            let stats = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(stats["audioDropped"] as? Int == 3)
            #expect(stats["newFrames"] as? Int == 30)
            for sequence: UInt32 in 3..<13 {
                #expect(core.popAudioEntry(channelID: audioID) == message(sequence))
            }
            #expect(core.popAudioEntry(channelID: audioID) == nil)
            server.send(audio: message(100))
            core.channelClosed(audioID)
            #expect(server.sessionState.hasVideo)
            #expect(server.sessionState.hasInput)
            #expect(!server.sessionState.hasAudio)
            #expect(server.stats().touchesForwarded == 0)
            server.send(audio: message(101))
            #expect(core.admitUpgrade(channel: replacement, method: "GET", uri: "/ws/audio?t=\(token.value)") == .audio)
            core.channelClosed(audioID)
            #expect(server.sessionState.hasAudio)
            #expect(core.popAudioEntry(channelID: ObjectIdentifier(replacement)) == nil)
            for sequence: UInt32 in 20..<32 { server.send(audio: message(sequence)) }
            #expect(server.stats().audioDropped == 5)
            core.channelClosed(videoID)
            #expect(!server.sessionState.hasAudio)
            #expect(!server.sessionState.hasInput)
            #expect(core.kind(of: replacement) == nil)
            #expect(core.popAudioEntry(channelID: ObjectIdentifier(replacement)) == nil)
            #expect(server.stats().audioDropped == 5)
            let nextVideo = channels[4], nextAudio = channels[5]
            #expect(core.admitUpgrade(channel: nextVideo, method: "GET", uri: "/ws/video?t=\(token.value)") == .video)
            #expect(core.admitUpgrade(channel: nextAudio, method: "GET", uri: "/ws/audio?t=\(token.value)") == .audio)
            #expect(core.popAudioEntry(channelID: ObjectIdentifier(nextAudio)) == nil)
            server.sendStats(Data(#"{"type":"stats"}"#.utf8))
            let cumulativeData = try #require(core.popStats(channelID: ObjectIdentifier(nextVideo)))
            let cumulative = try #require(JSONSerialization.jsonObject(with: cumulativeData) as? [String: Any])
            #expect(cumulative["audioDropped"] as? Int == 5)
            server.send(audio: message(200))
            core.stop()
            #expect(!server.sessionState.hasVideo)
            #expect(!server.sessionState.hasAudio)
            #expect(core.popAudioEntry(channelID: ObjectIdentifier(nextAudio)) == nil)
            #expect(server.stats().audioDropped == 5)
        } catch {
            core.stop()
            try await close(channels, diagnostics: diagnostics)
            throw error
        }
        core.stop()
        try await close(channels, diagnostics: diagnostics)
    }

    @Test func audioWebSocketSendsBinaryMessage() async throws {
        let token = try #require(PairingToken(value: "00112233445566778899aabbccddeeff"))
        let server = RemoteServer(configuration: .init(host: "127.0.0.1", port: 0, token: token, viewerPage: Data()),
                                  onTouches: { _ in })
        let deadline = ContinuousClock.now + .seconds(5)
        let diagnostics: @Sendable () -> String = { "state=\(server.sessionState)" }
        do {
            let port = try await RemoteTestWaits.boundedOperation("start", until: deadline, diagnostics: diagnostics) {
                try await server.start()
            }
            let videoURL = try #require(URL(string: "ws://127.0.0.1:\(port)/ws/video?t=\(token.value)"))
            let audioURL = try #require(URL(string: "ws://127.0.0.1:\(port)/ws/audio?t=\(token.value)"))
            let video = URLSession.shared.webSocketTask(with: videoURL)
            let audio = URLSession.shared.webSocketTask(with: audioURL)
            defer {
                video.cancel(with: .normalClosure, reason: nil)
                audio.cancel(with: .normalClosure, reason: nil)
            }
            video.resume()
            try await wait(until: deadline) { server.sessionState.hasVideo }
            audio.resume()
            try await wait(until: deadline) { server.sessionState.hasAudio }
            let expected = message(42)
            server.send(audio: expected)
            let received = try await RemoteTestWaits.boundedOperation(
                "receive audio", until: deadline, diagnostics: diagnostics,
                cancel: { audio.cancel(with: .goingAway, reason: nil) }
            ) { try await audio.receive() }
            switch received {
            case .data(let data): #expect(RemoteAudioMessage.decode(data) == expected)
            default: Issue.record("音訊必須使用二進位訊息")
            }
            video.cancel(with: .normalClosure, reason: nil)
            try await wait(until: deadline) { !server.sessionState.hasVideo && !server.sessionState.hasAudio }
        } catch {
            try await stop(server, diagnostics: diagnostics)
            throw error
        }
        try await stop(server, diagnostics: diagnostics)
    }

    private func wait(until deadline: ContinuousClock.Instant, condition: () -> Bool) async throws {
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RemoteTestWaitError.timedOut("audio state") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func close(_ channels: [any Channel], diagnostics: @escaping @Sendable () -> String) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        for channel in channels {
            channel.close(promise: nil)
            try await RemoteTestWaits.boundedOperation("close", until: deadline, diagnostics: diagnostics) {
                try await channel.closeFuture.get()
            }
        }
    }

    private func stop(_ server: RemoteServer, diagnostics: @escaping @Sendable () -> String) async throws {
        try await RemoteTestWaits.boundedOperation("stop", until: .now + .seconds(1), diagnostics: diagnostics) {
            await server.stop()
        }
    }
}
