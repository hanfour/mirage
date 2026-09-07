import Testing
@testable import MirageCore

@Suite struct FrameSinkFactoryTests {
    @Test func testMissingAndInvalidValuesUseLatestFrameBox() {
        let environments: [[String: String]] = [
            [:],
            ["MIRAGE_FRAME_QUEUE": ""],
            ["MIRAGE_FRAME_QUEUE": "0"],
            ["MIRAGE_FRAME_QUEUE": "1"],
            ["MIRAGE_FRAME_QUEUE": "abc"],
        ]

        for environment in environments {
            let sink = FrameSinkFactory.make(from: environment)
            #expect(sink is LatestFrameBox)
        }
    }

    @Test func testValidDepthUsesFrameQueue() {
        let depthTwo = FrameSinkFactory.make(from: ["MIRAGE_FRAME_QUEUE": "2"])
        let depthThree = FrameSinkFactory.make(from: ["MIRAGE_FRAME_QUEUE": "3"])

        #expect((depthTwo as? FrameQueue)?.depth == 2)
        #expect((depthThree as? FrameQueue)?.depth == 3)
    }
}
