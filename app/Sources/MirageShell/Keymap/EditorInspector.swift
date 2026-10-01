import MirageCore
import SwiftUI

/// 抽屜下半依綁定型別顯示參數與操作。
struct EditorInspector: View {
    let binding: MirageCore.Binding
    let isRebinding: Bool
    let onRadius: (Double) -> Void
    let onSensitivity: (Double) -> Void
    let onDelete: () -> Void
    let onRebind: () -> Void
    let onClearGamepad: () -> Void

    // 界線已搬到 `MirageCore.EditorLimits`（M2，D5 階段 B 終審）：兩個 View
    // （這裡的滑桿與 `EditorOverlay` 的拖曳把手）共用同一組數字，而「合理的半徑範圍
    // 是多少」是領域知識，不是排版細節——住在 View 裡的話另一個 View 得反向引用它。

    var body: some View {
        switch binding {
        case .joystick(_, _, _, _, _, let radius):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("半徑").font(.caption2).foregroundStyle(.secondary)
                    // 用新的閉包字面值符合 SwiftUI setter 的 sending 語意。
                    Slider(value: Binding(get: { radius }, set: { onRadius($0) }),
                           in: EditorLimits.radiusRange)
                    Text(String(format: "%.2f", radius))
                        .font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
                }
                Button("刪除", role: .destructive, action: onDelete)
            }
        case .look(_, let sensitivity):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("靈敏度").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { sensitivity }, set: { onSensitivity($0) }),
                           in: EditorLimits.sensitivityRange)
                    Text(String(format: "%.1f", sensitivity))
                        .font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
                }
                Button("刪除", role: .destructive, action: onDelete)
            }
        case .tap(_, _, let gamepad):
            VStack(alignment: .leading, spacing: 6) {
                if isRebinding {
                    Text("按下鍵盤鍵或手把鍵…（Esc 取消）")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("改鍵", action: onRebind)
                }
                Button("清除手把鍵", action: onClearGamepad)
                    .disabled(gamepad == nil || isRebinding)
                Button("刪除", role: .destructive, action: onDelete)
            }
        }
    }
}
