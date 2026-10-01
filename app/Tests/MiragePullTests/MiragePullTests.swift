import Foundation
import MirageCore
import MiragePull
import NIOCore
import NIOPosix
import Testing

private final class RecordingTransport: DisplayTransport, @unchecked Sendable {
    enum Behavior {
        case framesThenHang([Data])
        case frames([Data])
        case noFrames
        case error(TransportError)
    }

    private let lock = NSLock()
    private let behavior: Behavior
    private var continuation: AsyncThrowingStream<Frame, Error>.Continuation?
    private var _cancelCount = 0

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _cancelCount
    }

    func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error> {
        let (stream, continuation) = AsyncThrowingStream<Frame, Error>.makeStream()
        lock.lock()
        self.continuation = continuation
        lock.unlock()

        switch behavior {
        case .framesThenHang(let payloads):
            for payload in payloads {
                continuation.yield(Frame(width: width, height: height, rgba: payload))
            }
        case .frames(let payloads):
            for payload in payloads {
                continuation.yield(Frame(width: width, height: height, rgba: payload))
            }
            continuation.finish()
        case .noFrames:
            break
        case .error(let error):
            continuation.finish(throwing: error)
        }
        return stream
    }

    func cancelStream() {
        lock.lock()
        _cancelCount += 1
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}

private func closeListener(_ listener: Channel, group: EventLoopGroup) async {
    try? await listener.close()
    try? await group.shutdownGracefully()
}

@Suite(.timeLimit(.minutes(1))) struct MiragePullTests {
    @Test func measuredStatusUsesExitCodeZero() {
        let status = PullStatus.resolve(frames: 2, distinct: 2, error: nil)
        #expect(status == .measured)
        #expect(status.exitCode == 0)
    }

    @Test func errorStatusUsesExitCodeOneAndWinsOverCounters() {
        let status = PullStatus.resolve(frames: 2, distinct: 2, error: "UNAVAILABLE")
        #expect(status == .error)
        #expect(status.exitCode == 1)
    }

    @Test func staticStatusUsesExitCodeTwo() {
        let status = PullStatus.resolve(frames: 0, distinct: 0, error: nil)
        #expect(status == .staticResult)
        #expect(status.exitCode == 2)
    }

    @Test func staleStatusUsesExitCodeThree() {
        let status = PullStatus.resolve(frames: 3, distinct: 1, error: nil)
        #expect(status == .stale)
        #expect(status.exitCode == 3)
    }

    @Test func fingerprintDetectsAChangedRow() {
        let first = Data(repeating: 0, count: 128)
        var second = first
        second.replaceSubrange(64..<128, with: repeatElement(UInt8(1), count: 64))

        let fingerprints = [
            MiragePull.fingerprint(of: first),
            MiragePull.fingerprint(of: second),
        ]
        #expect(Set(fingerprints).count == 2)
    }

    @Test func fingerprintDetectsAChangedFirstByte() {
        let first = Data(repeating: 0, count: 128)
        var second = first
        second[0] = 1

        let fingerprints = [
            MiragePull.fingerprint(of: first),
            MiragePull.fingerprint(of: second),
        ]
        #expect(Set(fingerprints).count == 2)
    }

    @Test func fingerprintMatchesForIdenticalFrames() {
        let frame = Data(repeating: 7, count: 128)

        #expect(Set([
            MiragePull.fingerprint(of: frame),
            MiragePull.fingerprint(of: frame),
        ]).count == 1)
    }

    @Test func hangingTransportIsCancelledAfterDeadlineAndMeasured() async {
        let transport = RecordingTransport(.framesThenHang([
            Data([1, 0, 0, 255]),
            Data([2, 0, 0, 255]),
            Data([3, 0, 0, 255]),
        ]))

        let result = await MiragePull.measure(
            transport: transport,
            duration: .milliseconds(20),
            width: 1,
            height: 1
        )

        #expect(result.status == .measured)
        #expect(result.frames == 3)
        #expect(result.distinct == 3)
        #expect(transport.cancelCount >= 1)
    }

    @Test func noFramesAtDeadlineIsStatic() async {
        let transport = RecordingTransport(.noFrames)

        let result = await MiragePull.measure(
            transport: transport,
            duration: .milliseconds(20),
            width: 1,
            height: 1
        )

        #expect(result.status == .staticResult)
        #expect(result.frames == 0)
        #expect(result.fps == 0)
        #expect(transport.cancelCount >= 1)
    }

    @Test func unavailableTransportIsAnErrorWithContent() async {
        let transport = RecordingTransport(.error(.unavailable("連線拒絕")))

        let result = await MiragePull.measure(
            transport: transport,
            duration: .milliseconds(20),
            width: 1,
            height: 1
        )

        #expect(result.status == .error)
        #expect(result.exitCode == 1)
        #expect((result.error ?? "").count > 0)
    }

    @Test func mmapMeasurementReportsRgbaAfterFallback() async {
        let mmap = RecordingTransport(.error(.mmapUnusable("內容停止更新")))
        let raw = RecordingTransport(.frames([Data([1, 2, 3, 255])]))
        let fallback = FallbackTransport(primary: mmap, secondary: raw)

        let result = await MiragePull.measure(
            transport: fallback,
            duration: .seconds(1),
            width: 1,
            height: 1,
            transportName: "mmap"
        )

        #expect(result.transport == "rgba")
        #expect(result.frames == 1)
    }

    @Test func jsonContainsBaselineFieldsAndClient() throws {
        let result = PullResult(
            status: .measured,
            error: nil,
            fps: 58.5,
            frames: 117,
            elapsed: 2,
            width: 900,
            height: 2000,
            transport: "rgba",
            distinct: 2,
            client: "grpc-swift"
        )

        let jsonObject = try JSONSerialization.jsonObject(with: result.jsonData())
        let object = try #require(jsonObject as? [String: Any])
        #expect(Set(object.keys) == Set([
            "status", "error", "fps", "frames", "elapsed", "width", "height",
            "transport", "distinct", "client",
        ]))
        #expect(object["client"] as? String == "grpc-swift")
    }

    @Test func textMatchesBaselineAndAddsClientSuffix() {
        let result = PullResult(
            status: .measured,
            error: nil,
            fps: 58.5,
            frames: 117,
            elapsed: 2,
            width: 900,
            height: 2000,
            transport: "rgba",
            distinct: 2,
            client: "grpc-swift"
        )

        #expect(result.textLine == "fps=58.50 frames=117 elapsed=2.00 size=900x2000 "
            + "status=measured transport=rgba distinct=2 client=grpc-swift")
    }

    @Test func refusedEndpointIsUnavailableError() async throws {
        let endpoint = try PullEndpoint(host: "127.0.0.1", port: 1)

        let result = await MiragePull.run(
            endpoint: endpoint,
            duration: .milliseconds(20),
            width: 1,
            height: 1
        )

        let error = try #require(result.error)
        #expect(result.status == .error)
        #expect(error.contains("UNAVAILABLE"))
        #expect(result.exitCode == 1)
        #expect(result.frames == 0)
    }

    @Test func probePassesForTcpListener() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let listener: Channel
        do {
            listener = try await ServerBootstrap(group: group)
                .serverChannelOption(.backlog, value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeSucceededFuture(())
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }

        guard let port = listener.localAddress?.port,
              let endpoint = try? PullEndpoint(host: "127.0.0.1", port: port) else {
            await closeListener(listener, group: group)
            Issue.record("listener 沒有可用的 TCP port")
            return
        }

        let probeError = await MiragePull.probe(
            endpoint: endpoint,
            group: group,
            timeout: .seconds(5)
        )
        #expect(probeError == nil)

        await closeListener(listener, group: group)
    }
}
