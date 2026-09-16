import Foundation
import Testing
@testable import MirageCore

@Suite struct RemoteAudioQueueTests {
    private func entry(_ sequence: UInt32) -> RemoteAudioMessage {
        RemoteAudioMessage(sentAtNanoseconds: 123, sequence: sequence, samplingRate: 48_000,
                           channels: 2, samples: Data([1, 0, 2, 0]))
    }

    @Test func defaultLimitIsTenMessages() {
        #expect(RemoteAudioQueue.defaultLimit == 10)
        #expect(RemoteAudioQueue().limit == 10)
    }

    @Test func offersBelowCapacityDoNotDropAndPreserveValueSemantics() {
        let empty = RemoteAudioQueue(limit: 2)
        let one = empty.offering(entry(1))
        let two = one.offering(entry(2))
        #expect(empty.pending.isEmpty)
        #expect(one.pending == [entry(1)])
        #expect(two.pending == [entry(1), entry(2)])
        #expect(two.dropped == 0)
    }

    @Test func overflowDropsOnlyOldestAndAccumulatesCount() {
        var queue = RemoteAudioQueue(limit: 2)
        for sequence: UInt32 in 1...5 { queue = queue.offering(entry(sequence)) }
        #expect(queue.pending == [entry(4), entry(5)])
        #expect(queue.dropped == 3)
        let (next, first) = queue.popping()
        let (empty, second) = next.popping()
        #expect(first == entry(4))
        #expect(second == entry(5))
        #expect(empty.pending.isEmpty)
        #expect(empty.dropped == 3)
        let (stillEmpty, absent) = empty.popping()
        #expect(absent == nil)
        #expect(stillEmpty == empty)
        let resumed = empty.offering(entry(6))
        #expect(resumed.pending == [entry(6)])
        #expect(resumed.dropped == 3)
    }

    @Test func capacityOneKeepsLatest() {
        let queue = RemoteAudioQueue(limit: 1).offering(entry(1)).offering(entry(2))
        #expect(queue.pending == [entry(2)])
        #expect(queue.dropped == 1)
    }
}
