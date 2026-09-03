import Foundation
import Testing
@testable import MirageCore

@Suite struct LatestFrameBoxTests {
    private func frame(_ tag: UInt8) -> Frame {
        Frame(width: 1, height: 1, rgba: Data([tag, 0, 0, 255]))
    }

    @Test func testTakeReturnsLatestAndCountsDropped() {
        let box = LatestFrameBox()
        box.put(frame(1))
        box.put(frame(2))
        box.put(frame(3))
        #expect(box.takeLatest() == frame(3))
        #expect(box.stats().arrived == 3)
        #expect(box.stats().dropped == 2)
    }

    @Test func testTakeEmptiesBox() {
        let box = LatestFrameBox()
        box.put(frame(1))
        #expect(box.takeLatest() != nil)
        #expect(box.takeLatest() == nil)
    }

    @Test func testInvalidFrameRejectedNotStored() {
        let box = LatestFrameBox()
        box.put(Frame(width: 2, height: 2, rgba: Data(count: 3)))
        #expect(box.takeLatest() == nil)
        #expect(box.stats().arrived == 0)
        #expect(box.stats().rejected == 1)
        #expect(box.stats().dropped == 0)
    }

    @Test func testTakingLatestDoesNotChangeArrived() {
        let box = LatestFrameBox()
        box.put(frame(1))
        box.put(frame(2))

        let beforeTake = box.stats()
        _ = box.takeLatest()
        let afterTake = box.stats()

        #expect(beforeTake.arrived == 2)
        #expect(afterTake.arrived == 2)
        #expect(afterTake.dropped == 1)
    }

    @Test func testConcurrentPutTakeDoesNotCrash() async {
        let box = LatestFrameBox()

        async let putTask: () = {
            for i in 0..<5000 {
                box.put(self.frame(UInt8(i % 256)))
            }
        }()

        async let takeTask: () = {
            for _ in 0..<5000 {
                _ = box.takeLatest()
            }
        }()

        _ = await (putTask, takeTask)
    }
}
