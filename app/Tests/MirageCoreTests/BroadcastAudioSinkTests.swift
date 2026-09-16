import Testing
@testable import MirageCore

@Suite struct BroadcastAudioSinkTests {
    private func ring(capacity: Int = 32) -> AudioRingBuffer {
        AudioRingBuffer(capacitySamples: capacity, primeThresholdSamples: 0, collectPacketSizes: true)
    }

    private func read(_ ring: AudioRingBuffer, count: Int) -> [Float] {
        var samples = [Float](repeating: .nan, count: count)
        let received = samples.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, count: count)
        }
        #expect(received == count)
        return samples
    }

    @Test func primaryReceivesWithoutSecondary() {
        let primary = ring()
        let sink = BroadcastAudioSink(primary: primary)
        sink.write([0.5, -0.5], rawByteCount: 4)
        #expect(read(primary, count: 2) == [0.5, -0.5])
        #expect(primary.takePacketWindow().byteCounts == [4: 1])
    }

    @Test func bothReceiveIdenticalSamplesAndByteCount() {
        let primary = ring()
        let secondary = ring()
        let sink = BroadcastAudioSink(primary: primary, secondary: secondary)
        let samples: [Float] = [0.25, -0.75, 1, -1]
        sink.write(samples, rawByteCount: 8)
        #expect(read(primary, count: 4) == samples)
        #expect(read(secondary, count: 4) == samples)
        #expect(primary.takePacketWindow().byteCounts == [8: 1])
        #expect(secondary.takePacketWindow().byteCounts == [8: 1])
    }

    @Test func replacingSecondaryOnlyDeliversFutureWritesToReplacement() {
        let primary = ring()
        let old = ring()
        let replacement = ring()
        let sink = BroadcastAudioSink(primary: primary, secondary: old)
        sink.write([0.25], rawByteCount: 2)
        sink.secondary = replacement
        sink.write([0.75], rawByteCount: 2)
        #expect(read(primary, count: 2) == [0.25, 0.75])
        #expect(read(old, count: 1) == [0.25])
        #expect(read(replacement, count: 1) == [0.75])
        #expect(old.stats.writes == 1)
        #expect(replacement.stats.writes == 1)
    }

    @Test func removingSecondaryKeepsPrimaryReceivingAndPreservesNilByteCount() {
        let primary = ring()
        let secondary = ring()
        let sink = BroadcastAudioSink(primary: primary, secondary: secondary)
        sink.secondary = nil
        sink.write([0.5], rawByteCount: nil)
        #expect(read(primary, count: 1) == [0.5])
        #expect(primary.takePacketWindow().byteCounts.isEmpty)
        #expect(secondary.stats.writes == 0)
    }

    @Test func secondaryDroppingSamplesDoesNotAffectPrimary() {
        let primary = ring()
        let secondary = ring(capacity: 1)
        let sink = BroadcastAudioSink(primary: primary, secondary: secondary)
        sink.write([0.5, -0.5], rawByteCount: 4)
        #expect(secondary.stats.overruns == 1)
        #expect(read(primary, count: 2) == [0.5, -0.5])
        #expect(primary.stats.overruns == 0)
    }
}
