// 本檔的 mutating 呼叫一律先存區域變數再進 #expect／#require：
// 巨集會把運算元捕捉成不可變的，直接寫會編不過。
import Foundation
import Testing
import MirageCore
@testable import MirageShell

@Suite struct EditorDragStateTests {
    private let rect = FitRect(x: 10, y: 20, width: 200, height: 400)

    @Test func offsetIsReusedWhenMarkerCenterChanges() throws {
        var state = EditorDragState()
        state.begin(at: CGPoint(x: 130, y: 190), center: CGPoint(x: 110, y: 220))
        let firstOptional = state.update(location: CGPoint(x: 150, y: 230),
                                         translation: CGSize(width: 20, height: 40), in: rect)
        let first = try #require(firstOptional)
        #expect(first.x == 0.6)
        #expect(first.y == 0.6)
        state.begin(at: CGPoint(x: 130, y: 190), center: CGPoint(x: 130, y: 260))
        let secondOptional = state.update(location: CGPoint(x: 170, y: 270),
                                          translation: CGSize(width: 40, height: 80), in: rect)
        let second = try #require(secondOptional)
        #expect(second.x == 0.7)
        #expect(second.y == 0.7)
    }

    @Test func clickStoresOffsetButNeverReportsMovement() throws {
        var state = EditorDragState()
        state.begin(at: CGPoint(x: 132.125, y: 219.75), center: CGPoint(x: 110, y: 220))
        let clickMovement = state.update(location: CGPoint(x: 132.125, y: 219.75),
                                         translation: .zero, in: rect)
        #expect(clickMovement == nil)
        #expect(state.grabOffset == CGSize(width: 22.125, height: -0.25))
        // 即使點擊後視圖中心更新，開始時記錄的偏移仍須沿用。
        state.begin(at: CGPoint(x: 132.125, y: 219.75), center: CGPoint(x: 120, y: 230))
        let movedOptional = state.update(location: CGPoint(x: 152.125, y: 219.75),
                                         translation: CGSize(width: 20, height: 0), in: rect)
        let moved = try #require(movedOptional)
        #expect(moved.x == 0.6)
        #expect(moved.y == 0.5)
    }

    @Test func endClearsOffsetAndNextGestureRecomputesIt() throws {
        var state = EditorDragState()
        state.begin(at: CGPoint(x: 130, y: 190), center: CGPoint(x: 110, y: 220))
        state.end()
        #expect(state.grabOffset == nil)
        let movementAfterEnd = state.update(location: CGPoint(x: 150, y: 230),
                                            translation: CGSize(width: 20, height: 40), in: rect)
        #expect(movementAfterEnd == nil)
        state.begin(at: CGPoint(x: 80, y: 240), center: CGPoint(x: 110, y: 220))
        #expect(state.grabOffset == CGSize(width: -30, height: 20))
        let movedOptional = state.update(location: CGPoint(x: 80, y: 280),
                                         translation: CGSize(width: 0, height: 40), in: rect)
        let moved = try #require(movedOptional)
        #expect(moved.x == 0.5)
        #expect(moved.y == 0.6)
    }
}
