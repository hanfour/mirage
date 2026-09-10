import Foundation
import MirageCore

/// 標記拖曳狀態，不依賴 SwiftUI 手勢或視窗。
struct EditorDragState {
    private(set) var grabOffset: CGSize?

    /// onChanged 可重複呼叫開始，偏移只在第一個事件記錄。
    /// 少了握把偏移，點在 44pt 圈緣會瞬移 22pt，搖桿最多瞬移一整個半徑。
    mutating func begin(at start: CGPoint, center: CGPoint) {
        guard grabOffset == nil else { return }
        grabOffset = CGSize(width: start.x - center.x, height: start.y - center.y)
    }

    /// 點擊只選取，不回寫浮點座標，避免同值守門失效而誤設 isDirty。
    func update(location: CGPoint, translation: CGSize, in rect: FitRect) -> NormPoint? {
        guard translation != .zero, let offset = grabOffset else { return nil }
        return EditorGeometry.normPoint(x: location.x - offset.width,
                                        y: location.y - offset.height, in: rect)
    }

    mutating func end() {
        grabOffset = nil
    }
}
