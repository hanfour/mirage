import Testing
@testable import MirageCore

/// M2（Minor，D5 階段 B 終審）：半徑界線從 SwiftUI View 搬進 `MirageCore` 之後，
/// 夾取邏輯終於測得到——它先前是 `EditorOverlay` 裡的一行就地算術，只有 GUI 才驅動得了。
@Suite struct EditorLimitsTests {
    /// 低於下限夾到下限。**下限不是 0**：`EditorGeometry.radius(fromPoints: 0, in:)` 回的
    /// 是 `0.0` 而不是 nil，而 `radius: 0` 會被 `validated()` 拒絕。
    @Test func clampsBelowLowerBound() {
        #expect(EditorLimits.clampRadius(0) == EditorLimits.radiusRange.lowerBound)
        #expect(EditorLimits.clampRadius(-1) == EditorLimits.radiusRange.lowerBound)
        #expect(EditorLimits.clampRadius(0.019) == EditorLimits.radiusRange.lowerBound)
    }

    /// 高於上限夾到上限——往右拖半徑把手會產生 `radius > 1.0`，不違反 schema 但一定出畫面。
    @Test func clampsAboveUpperBound() {
        #expect(EditorLimits.clampRadius(0.51) == EditorLimits.radiusRange.upperBound)
        #expect(EditorLimits.clampRadius(12.5) == EditorLimits.radiusRange.upperBound)
    }

    /// 範圍內原封不動，含兩個端點本身。
    @Test func leavesInRangeValuesUntouched() {
        #expect(EditorLimits.clampRadius(0.02) == 0.02)
        #expect(EditorLimits.clampRadius(0.12) == 0.12)
        #expect(EditorLimits.clampRadius(0.5) == 0.5)
    }

    /// 夾出來的值一定通過 schema 驗證——這才是這組界線存在的理由（壞檔不落地）。
    @Test func clampedRadiusAlwaysPassesValidation() throws {
        for raw in [-5.0, 0.0, 0.001, 0.3, 9.9] {
            let p = KeymapProfile(gameId: "com.game.clamp", version: 1, bindings: [
                .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                          center: NormPoint(x: 0.5, y: 0.5),
                          radius: EditorLimits.clampRadius(raw)),
            ])
            #expect(try p.validated() == p)
        }
    }

    /// 靈敏度範圍也一起釘住——滑桿是它唯一的入口，數字改掉沒人會發現。
    @Test func sensitivityRangeIsPositive() {
        #expect(EditorLimits.sensitivityRange.lowerBound > 0)
        #expect(EditorLimits.sensitivityRange == 0.1...5.0)
    }
}
