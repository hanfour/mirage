import Foundation
import Testing
@testable import MirageCore

@Suite struct BroadcastFrameSinkTests {
    private func frame(_ tag: UInt8) -> Frame {
        Frame(width: 1, height: 1, rgba: Data([tag, 0, 0, 255]))
    }

    @Test func putFansOutToBothSinks() {
        let primary = LatestFrameBox()
        let secondary = LatestFrameBox()
        let sink = BroadcastFrameSink(primary: primary, secondary: secondary)
        sink.put(frame(1))
        sink.put(frame(2))
        #expect(primary.takeLatest() == frame(2))
        #expect(secondary.takeLatest() == frame(2))
        #expect(primary.stats().arrived == 2)
        #expect(secondary.stats().arrived == 2)
    }

    @Test func takeLatestDrainsOnlyPrimary() {
        let sink = BroadcastFrameSink(primary: LatestFrameBox())
        sink.put(frame(7))
        #expect(sink.takeLatest() == frame(7))
        #expect(sink.takeLatest() == nil)
        #expect(sink.secondary.takeLatest() == frame(7))
    }

    @Test func statsProxyPrimaryNotSecondary() {
        let primary = LatestFrameBox()
        let sink = BroadcastFrameSink(primary: primary)
        sink.put(frame(1))
        sink.put(frame(2))
        _ = sink.secondary.takeLatest()
        sink.put(frame(3))
        #expect(sink.stats() == primary.stats())
        #expect(sink.stats().dropped == 2)
        #expect(sink.secondary.stats().dropped == 1)
    }

    @Test func invalidFrameIsRejectedByBothSides() {
        let sink = BroadcastFrameSink(primary: LatestFrameBox())
        sink.put(Frame(width: 2, height: 2, rgba: Data(count: 3)))
        #expect(sink.takeLatest() == nil)
        #expect(sink.secondary.takeLatest() == nil)
        #expect(sink.stats().rejected == 1)
        #expect(sink.secondary.stats().rejected == 1)
    }

    @Test func worksWithFrameQueueAsPrimary() {
        let queue = FrameQueue(depth: 2)
        let sink = BroadcastFrameSink(primary: queue)
        sink.put(frame(1))
        sink.put(frame(2))
        #expect(sink.takeLatest() == frame(1))
        #expect(sink.takeLatest() == frame(2))
        #expect(sink.secondary.takeLatest() == frame(2))
    }

    @Test func concurrentPutAndTakeDoesNotCrash() async {
        let sink = BroadcastFrameSink(primary: LatestFrameBox())
        async let producer: () = {
            for i in 0..<5000 { sink.put(self.frame(UInt8(i % 256))) }
        }()
        async let consumer: () = {
            for _ in 0..<5000 { _ = sink.takeLatest(); _ = sink.secondary.takeLatest() }
        }()
        _ = await (producer, consumer)
        #expect(sink.stats().arrived == 5000)
        #expect(sink.secondary.stats().arrived == 5000)
    }
}
