import Foundation
import Testing
import MirageCore
@testable import MirageShell

@Suite(.timeLimit(.minutes(1))) struct RemoteAudioForwarderTests {
    @Test func zeroAndEmpty() {
        #expect(RemoteAudioForwarder.s16LittleEndian([0]) == Data([0, 0]))
        #expect(RemoteAudioForwarder.s16LittleEndian([]) == Data())
    }

    @Test func clampsEndpointsAndOvershoot() {
        #expect(RemoteAudioForwarder.s16LittleEndian([1, -1, 1.5, -1.5])
                == Data([0xff, 0x7f, 0x00, 0x80, 0xff, 0x7f, 0x00, 0x80]))
    }

    @Test func roundsAndWritesLittleEndian() {
        #expect(RemoteAudioForwarder.s16LittleEndian([4660.0 / 32768, -4660.0 / 32768,
                                                   0.5 / 32768, -0.5 / 32768])
                == Data([0x34, 0x12, 0xcc, 0xed, 0x01, 0x00, 0xff, 0xff]))
    }

    @Test func forwardsOnlyToViewerWithSequenceFormatAndComparableClock() async throws {
        let token = PairingToken.generate()
        var configuration = RemoteMirrorConfiguration(token: token, viewerPage: Data())
        configuration.host = "127.0.0.1"
        configuration.port = 0
        let controller = RemoteMirrorController(
            configuration: configuration, secondary: LatestFrameBox(),
            inputQueue: InputQueue(injector: RemoteMirrorRecordingInjector()),
            makeEncoder: { RemoteMirrorFakeEncoder() })
        let forwarder = RemoteAudioForwarder(controller: controller)
        let deadline = ContinuousClock.now + .seconds(10)
        let diagnostics: @Sendable () -> String = { "\(controller.sessionState)" }
        var sockets: [URLSessionWebSocketTask] = []
        do {
            let port = try await RemoteTestWaits.boundedOperation(
                "start", until: deadline, diagnostics: diagnostics) { try await controller.start() }
            forwarder.write([1, -1])
            #expect(controller.stats().audioMessagesSent == 0)
            for path in ["video", "audio"] {
                let url = try #require(URL(string: "ws://127.0.0.1:\(port)/ws/\(path)?t=\(token.value)"))
                let socket = URLSession.shared.webSocketTask(with: url)
                sockets.append(socket)
                socket.resume()
                while path == "video" ? !controller.sessionState.hasVideo : !controller.sessionState.hasAudio {
                    guard ContinuousClock.now < deadline else {
                        throw RemoteTestWaitError.timedOut("\(path) pairing")
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            let audio = try #require(sockets.last)
            forwarder.write([])
            forwarder.write([1])
            #expect(controller.stats().audioMessagesSent == 0)
            for sequence: UInt32 in 0..<2 {
                let before = DispatchTime.now().uptimeNanoseconds
                forwarder.write([1, -1])
                let received = try await RemoteTestWaits.boundedOperation(
                    "audio receive", until: deadline, diagnostics: diagnostics,
                    cancel: { audio.cancel(with: .goingAway, reason: nil) }) { try await audio.receive() }
                guard case .data(let data) = received else {
                    throw RemoteMirrorTestFailure.unexpectedMessageKind
                }
                let message = try #require(RemoteAudioMessage.decode(data))
                #expect(message.sequence == sequence)
                #expect(message.samplingRate == UInt32(AudioStreamFormat.standard.samplingRate))
                #expect(message.channels == UInt8(AudioStreamFormat.standard.channels))
                #expect(message.samples == Data([0xff, 0x7f, 0, 0x80]))
                #expect(message.sentAtNanoseconds >= before)
                #expect(message.sentAtNanoseconds <= DispatchTime.now().uptimeNanoseconds)
            }
            #expect(controller.stats().audioMessagesSent == 2)
        } catch {
            for socket in sockets { socket.cancel(with: .goingAway, reason: nil) }
            try await RemoteTestWaits.boundedOperation(
                "cleanup", until: .now + .seconds(3), diagnostics: diagnostics) { await controller.stop() }
            throw error
        }
        for socket in sockets { socket.cancel(with: .normalClosure, reason: nil) }
        try await RemoteTestWaits.boundedOperation(
            "stop", until: .now + .seconds(3), diagnostics: diagnostics) { await controller.stop() }
        forwarder.write([1, -1])
        #expect(controller.stats().audioMessagesSent == 2)
    }

}
