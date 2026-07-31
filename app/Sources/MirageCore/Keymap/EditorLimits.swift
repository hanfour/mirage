import Foundation

/// 編輯器的參數界線。
///
/// **是 UI 層的取捨，不是 schema 約束**——`KeymapProfile.validated()` 只要求 `radius > 0`／
/// `sensitivity > 0`，既有 profile 落在這個範圍外仍然合法可載入（Never break userspace）。
/// 這裡定的是「編輯器讓你調到哪」，不是「什麼才算合法」。
///
/// **為什麼住在 `MirageCore` 而不是某個 View 裡**（M2，D5 階段 B 終審）：原本 `radiusRange`
/// 是 `EditorInspector`（一個 SwiftUI View）的 static，而 `EditorOverlay`（另一個 View）
/// 反向引用它、又就地寫一次 `min(max(...))`。「合理的半徑範圍是多少」是領域知識，與
/// `validated()` 的 `radius > 0` 同一族，不是排版細節；夾取的算術更不該有第二份複本
/// ——這個 repo 已經因為 `EmulatorEndpoint` 解析有兩份而吃過虧。
///
/// 下限 0.02 是「再小就點不到」，上限 0.5 是「正規化基準是寬度，超過就一定出畫面」。
public enum EditorLimits {
    public static let radiusRange: ClosedRange<Double> = 0.02...0.5
    public static let sensitivityRange: ClosedRange<Double> = 0.1...5.0

    /// 把半徑夾進 `radiusRange`。
    ///
    /// **下限不能只擋負值**：`EditorGeometry.radius(fromPoints: 0, in:)` 回的是 `0.0` 而不是
    /// nil，往左拖過圓心就會餵出 `radius: 0`——那是 `validated()` 拒絕的值。
    public static func clampRadius(_ r: Double) -> Double {
        min(max(r, radiusRange.lowerBound), radiusRange.upperBound)
    }
}
