import Testing
@testable import MirageCore

@Suite struct FrameSinkFactoryTests {
    @Test func selectsSinkFromEnvironmentOrSetting() {
        let cases: [(environment: [String: String], smoothFrames: Bool, depth: Int?,
                     source: FrameSinkSource, warning: String?)] = [
            ([:], true, 2, .setting, nil),
            ([:], false, nil, .setting, nil),
            (["MIRAGE_FRAME_QUEUE": "0"], true, nil, .environment, nil),
            (["MIRAGE_FRAME_QUEUE": "1"], true, nil, .environment, nil),
            (["MIRAGE_FRAME_QUEUE": "2"], false, 2, .environment, nil),
            (["MIRAGE_FRAME_QUEUE": "3"], false, 3, .environment, nil),
            (["MIRAGE_FRAME_QUEUE": ""], true, 2, .setting,
             "MIRAGE_FRAME_QUEUE= 不是整數，改用設定"),
            (["MIRAGE_FRAME_QUEUE": "abc"], false, nil, .setting,
             "MIRAGE_FRAME_QUEUE=abc 不是整數，改用設定"),
            (["MIRAGE_FRAME_QUEUE": ""], false, nil, .setting,
             "MIRAGE_FRAME_QUEUE= 不是整數，改用設定"),
            (["MIRAGE_FRAME_QUEUE": "abc"], true, 2, .setting,
             "MIRAGE_FRAME_QUEUE=abc 不是整數，改用設定"),
            (["MIRAGE_FRAME_QUEUE": "-1"], true, nil, .environment, nil),
        ]

        for testCase in cases {
            let result = FrameSinkFactory.make(
                environment: testCase.environment, smoothFrames: testCase.smoothFrames)
            #expect(result.source == testCase.source)
            #expect(result.warning == testCase.warning)
            if let depth = testCase.depth {
                let isQueue = result.sink is FrameQueue
                #expect(isQueue)
                #expect((result.sink as? FrameQueue)?.depth == depth)
                #expect(FrameSinkFactory.label(for: result.sink) == "queue depth=\(depth)")
            } else {
                let isLatest = result.sink is LatestFrameBox
                #expect(isLatest)
                #expect(FrameSinkFactory.label(for: result.sink) == "latest")
            }
        }
    }
}
