import MirageCore
import SwiftUI

/// 抽屜下半的參數區：依選中的 binding 型別顯示對應滑桿。
///
/// 階段 B 只有半徑與靈敏度；改鍵與刪除是階段 C。選中的是 tap 時沒有可調參數，
/// 顯示一行說明而不是留白——留白會讓人以為壞掉了。
struct EditorInspector: View {
    let binding: MirageCore.Binding
    let onRadius: (Double) -> Void
    let onSensitivity: (Double) -> Void

    // 界線已搬到 `MirageCore.EditorLimits`（M2，D5 階段 B 終審）：兩個 View
    // （這裡的滑桿與 `EditorOverlay` 的拖曳把手）共用同一組數字，而「合理的半徑範圍
    // 是多少」是領域知識，不是排版細節——住在 View 裡的話另一個 View 得反向引用它。

    var body: some View {
        switch binding {
        case .joystick(_, _, _, _, _, let radius):
            HStack {
                Text("半徑").font(.caption2).foregroundStyle(.secondary)
                // `set: { onRadius($0) }` 而不是直接傳 `onRadius`（B-Task 7 review Important
                // 修正）：`Binding.init(get:set:)` 的 setter 在目前工具鏈下要求
                // `@Sendable`，直接傳一個**已儲存**的閉包值（`onRadius`）編譯器無法證明
                // 只會用一次，會警告「converting non-Sendable function value」；在呼叫點
                // 寫一個**新的閉包字面值**滿足 `sending` 語意，警告消失，行為與公開介面
                // （`let onRadius: (Double) -> Void`）完全不變。
                Slider(value: Binding(get: { radius }, set: { onRadius($0) }),
                       in: EditorLimits.radiusRange)
                Text(String(format: "%.2f", radius))
                    .font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
        case .look(_, let sensitivity):
            HStack {
                Text("靈敏度").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { sensitivity }, set: { onSensitivity($0) }),
                       in: EditorLimits.sensitivityRange)
                Text(String(format: "%.1f", sensitivity))
                    .font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
        case .tap:
            Text("點擊鍵只有位置可調——直接在畫面上拖它。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
