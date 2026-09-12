import Foundation
import Testing
@testable import MirageCore

@Suite struct RemoteVideoQueueTests {
    private func entry(_ seq: UInt32, key: Bool = false) -> RemoteVideoQueue.Entry {
        RemoteVideoQueue.Entry(sequence: seq, isKeyframe: key, accessUnit: Data([0, 0, 0, 1, key ? 0x65 : 0x41]))
    }

    @Test func startsWaitingForKeyframeAndDropsDeltas() {
        let q = RemoteVideoQueue(limit: 2)
        #expect(q.waitingForKeyframe)
        let (q1, accepted) = q.offering(entry(0))
        #expect(!accepted)
        #expect(q1.dropped == 1)
        #expect(q1.pending.isEmpty)
    }

    @Test func overflowDropsWholeGopAndWaitsForNextKeyframe() {
        var q = RemoteVideoQueue(limit: 2)
        var accepted: Bool
        (q, accepted) = q.offering(entry(0))
        #expect(!accepted)
        (q, accepted) = q.offering(entry(1, key: true))
        #expect(accepted)
        var popped: RemoteVideoQueue.Entry?
        (q, popped) = q.popping()
        #expect(popped?.sequence == 1)
        (q, _) = q.offering(entry(2))
        (q, _) = q.offering(entry(3))
        #expect(q.pending.map(\.sequence) == [2, 3])
        (q, accepted) = q.offering(entry(4))   // 清掉 2、3，丟 4
        #expect(!accepted)
        (q, popped) = q.popping()
        #expect(popped == nil)
        (q, accepted) = q.offering(entry(5))
        #expect(!accepted)
        (q, accepted) = q.offering(entry(6, key: true))
        #expect(accepted)
        (q, popped) = q.popping()
        #expect(popped?.sequence == 6)
        #expect(q.dropped == 5)
        #expect(!q.waitingForKeyframe)
    }

    @Test func overflowOnKeyframeResumesImmediately() {
        var q = RemoteVideoQueue(limit: 1)
        (q, _) = q.offering(entry(0, key: true))
        let (q2, accepted) = q.offering(entry(60, key: true))
        #expect(accepted)
        let (_, popped) = q2.popping()
        #expect(popped?.sequence == 60)
        #expect(q2.dropped == 1)
    }

    @Test func popReturnsOldestFirst() {
        var q = RemoteVideoQueue(limit: 3)
        (q, _) = q.offering(entry(1, key: true))
        (q, _) = q.offering(entry(2))
        (q, _) = q.offering(entry(3))
        let (q1, first) = q.popping()
        let (q2, second) = q1.popping()
        #expect(first?.sequence == 1)
        #expect(second?.sequence == 2)
        #expect(q2.pending.map(\.sequence) == [3])
    }

    @Test func defaultLimitIsThreeFramesPerSpec() {
        #expect(RemoteVideoQueue.defaultLimit == 3)
        #expect(RemoteVideoQueue().limit == 3)
    }
}
