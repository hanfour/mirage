import Foundation
import Testing
@testable import MirageCore

@Suite struct FrameQueueTests {
    private func frame(_ tag: UInt8) -> Frame {
        Frame(width: 1, height: 1, rgba: Data([tag, 0, 0, 255]))
    }

    @Test func testDepthTwoDropsOldestAndTakesFifo() {
        let queue = FrameQueue(depth: 2)
        queue.put(frame(1))
        queue.put(frame(2))
        queue.put(frame(3))

        #expect(queue.takeLatest() == frame(2))
        #expect(queue.takeLatest() == frame(3))
        #expect(queue.takeLatest() == nil)
        #expect(queue.stats().arrived == 3)
        #expect(queue.stats().dropped == 1)
        #expect(queue.stats().rejected == 0)
    }

    @Test func testDepthOneMatchesLatestWins() {
        let queue = FrameQueue(depth: 1)
        queue.put(frame(1))
        queue.put(frame(2))
        queue.put(frame(3))

        #expect(queue.takeLatest() == frame(3))
        #expect(queue.takeLatest() == nil)
        #expect(queue.stats().arrived == 3)
        #expect(queue.stats().dropped == 2)
        #expect(queue.stats().rejected == 0)
    }

    @Test func testInvalidFrameIsRejectedAndNotQueued() {
        let queue = FrameQueue(depth: 2)
        queue.put(Frame(width: 2, height: 2, rgba: Data(count: 3)))

        #expect(queue.takeLatest() == nil)
        #expect(queue.stats().arrived == 0)
        #expect(queue.stats().dropped == 0)
        #expect(queue.stats().rejected == 1)
    }

    @Test func testTakingFromEmptyQueueReturnsNil() {
        let queue = FrameQueue(depth: 2)

        #expect(queue.takeLatest() == nil)
        #expect(queue.count == 0)
    }

    @Test func testStatsAndCountRemainConsistent() {
        let queue = FrameQueue(depth: 2)
        queue.put(frame(1))
        queue.put(frame(2))
        queue.put(frame(3))
        _ = queue.takeLatest()

        #expect(queue.depth == 2)
        #expect(queue.count == 1)
        #expect(queue.stats() == FrameCounterSnapshot(arrived: 3, dropped: 1, rejected: 0))
    }

    @Test func testConcurrentPutTakeDoesNotCrash() async {
        let queue = FrameQueue(depth: 2)

        async let putTask: () = {
            for i in 0..<5000 {
                queue.put(self.frame(UInt8(i % 256)))
            }
        }()

        async let takeTask: () = {
            for _ in 0..<5000 {
                _ = queue.takeLatest()
            }
        }()

        _ = await (putTask, takeTask)
    }
}
