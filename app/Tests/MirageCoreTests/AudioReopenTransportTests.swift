import Foundation
import Testing
@testable import MirageCore

private final class ReopenFake: AwaitableAudioTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<AudioChunk, Error>.Continuation?
    private var opens = 0
    private var overlap = false
    private var events: [(String, Int)] = []

    func record(_ name: String, _ round: Int) {
        lock.lock(); defer { lock.unlock() }
        events.append((name, round))
    }
    var snapshot: (Int, Bool, [String]) {
        lock.lock(); defer { lock.unlock() }
        return (opens, overlap, events.map { "\($0.0):\($0.1)" })
    }
    func packets(format: AudioStreamFormat) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { cont in
            lock.lock(); defer { lock.unlock() }
            overlap = overlap || continuation != nil
            opens += 1
            continuation = cont
            cont.yield(AudioChunk.fromS16LE(Data(repeating: 0, count: 16)))
        }
    }
    // Cancel request deliberately does not end the response immediately.
    func cancelStream() {}
    private func finish() {
        lock.lock(); defer { lock.unlock() }
        continuation?.finish()
        continuation = nil
    }
    func cancelStreamAndWait() async {
        try? await Task.sleep(for: .milliseconds(20))
        finish()
    }
}

@Suite struct AudioReopenTransportTests {
    @Test func waitsForCancellationBeforeReopeningAndForwardsPackets() async throws {
        let fake = ReopenFake()
        let transport = AudioReopenTransport(base: fake, on: .milliseconds(30),
            off: .milliseconds(50), rounds: 3, lateTolerance: .seconds(30),
            event: { fake.record($0, $1) })
        var bytes: [Int] = []
        for try await chunk in transport.packets(format: .standard) {
            bytes.append(chunk.rawByteCount!)
        }
        #expect(bytes == [16, 16, 16])
        let (opens, overlap, events) = fake.snapshot
        #expect(opens == 3)
        #expect(!overlap)
        for round in 1...3 {
            let opened = try #require(events.firstIndex(of: "open:\(round)"))
            let cancel = try #require(events.firstIndex(of: "cancel:\(round)"))
            let ended = try #require(events.firstIndex(of: "response-ended:\(round)"))
            let closed = try #require(events.firstIndex(of: "closed:\(round)"))
            #expect(opened < cancel && cancel < ended && ended < closed)
            if round < 3 {
                let next = try #require(events.firstIndex(of: "open:\(round + 1)"))
                #expect(closed < next)
            }
        }
        #expect(events.contains("complete:3"))
    }

    @Test func cancellingDuringOnPreventsFurtherRPCs() async throws {
        let fake = ReopenFake()
        let transport = AudioReopenTransport(base: fake, on: .seconds(2),
            off: .milliseconds(20), rounds: 3, lateTolerance: .seconds(30),
            event: { fake.record($0, $1) })
        for try await _ in transport.packets(format: .standard) {
            transport.cancelStream()
        }
        #expect(fake.snapshot.0 == 1)
        #expect(!fake.snapshot.1)
        #expect(fake.snapshot.2.contains("aborted:0"))
    }

    @Test func expiredScheduledStartDoesNotOpenRPC() async throws {
        let fake = ReopenFake()
        let transport = AudioReopenTransport(base: fake, startEpoch: 1,
            event: { fake.record($0, $1) })
        for try await _ in transport.packets(format: .standard) {
            Issue.record("late run must not deliver packets")
        }
        #expect(fake.snapshot.0 == 0)
        #expect(fake.snapshot.2 == ["late-start-abort:0"])
    }
}
