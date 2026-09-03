import Foundation
import MirageCore
import MiragePull
import Testing

private final class RecordingTransport: DisplayTransport, @unchecked Sendable {
    enum Behavior {
        case framesThenHang([Data])
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
}
