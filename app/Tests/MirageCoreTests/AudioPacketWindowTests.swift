import Foundation
import Testing
@testable import MirageCore

@Suite struct AudioPacketWindowTests {
    private func feed(_ sizes: [Int], into ring: AudioRingBuffer) {
        for size in sizes {
            let chunk = AudioChunk.fromS16LE(Data(repeating: 0, count: size))
            ring.write(chunk.samples, rawByteCount: chunk.rawByteCount)
        }
    }

    @Test func knownPacketsAndConsecutiveWindows() {
        let ring = AudioRingBuffer(collectPacketSizes: true)
        feed([1920, 136, 1920, 0, 137, 1], into: ring)
        let first = ring.takePacketWindow()
        #expect(first.byteCounts == [0: 1, 1: 1, 136: 1, 137: 1, 1920: 2])
        #expect(first.logFields == "rxpkt=6 rxbytes=4114 pkt_bytes={0:1,1:1,136:1,137:1,1920:2}")
        #expect(first.stats.writes == 4)
        #expect(first.stats.writtenSamples == 2056)

        feed([136, 136, 8], into: ring)
        let second = ring.takePacketWindow()
        #expect(second.byteCounts == [8: 1, 136: 2])
        #expect(second.stats.writes - first.stats.writes == 3)
        #expect(second.stats.writtenSamples - first.stats.writtenSamples == 140)
        let idle = ring.takePacketWindow()
        #expect(idle.logFields == "rxpkt=0 rxbytes=0 pkt_bytes={}")
        #expect(idle.stats.writes == second.stats.writes)
        #expect(idle.stats.writtenSamples == second.stats.writtenSamples)
    }

    @Test func overflowStillCountsReceivedPacket() {
        let ring = AudioRingBuffer(capacitySamples: 4, collectPacketSizes: true)
        feed([8, 8, 0], into: ring)
        let window = ring.takePacketWindow()
        #expect(window.byteCounts == [0: 1, 8: 2])
        #expect(window.stats.writes == 1)
        #expect(window.stats.writtenSamples == 4)
        #expect(window.stats.overruns == 1)
    }

    @Test func disabledDoesNotCollect() {
        let ring = AudioRingBuffer()
        feed([8], into: ring)
        let window = ring.takePacketWindow()
        #expect(window.byteCounts.isEmpty)
        #expect(window.stats.writes == 1)
    }

    @Test func concurrentSnapshotsKeepPacketAndSampleBoundariesTogether() async {
        let ring = AudioRingBuffer(capacitySamples: 40_000, collectPacketSizes: true)
        let producer = Task.detached {
            for _ in 0..<10_000 {
                let chunk = AudioChunk.fromS16LE(Data(repeating: 0, count: 8))
                ring.write(chunk.samples, rawByteCount: chunk.rawByteCount)
            }
        }
        var previousWrites = 0
        var previousSamples = 0
        var totalPackets = 0
        for _ in 0..<100 {
            let window = ring.takePacketWindow()
            let count = window.byteCounts[8, default: 0]
            #expect(window.stats.writes - previousWrites == count)
            #expect(window.stats.writtenSamples - previousSamples == count * 4)
            totalPackets += count
            previousWrites = window.stats.writes
            previousSamples = window.stats.writtenSamples
            await Task.yield()
        }
        await producer.value
        let last = ring.takePacketWindow()
        let count = last.byteCounts[8, default: 0]
        #expect(last.stats.writes - previousWrites == count)
        #expect(last.stats.writtenSamples - previousSamples == count * 4)
        #expect(totalPackets + count == 10_000)
    }
}
