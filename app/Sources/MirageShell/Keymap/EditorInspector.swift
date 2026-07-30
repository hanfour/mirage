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

    /// 滑桿範圍是 **UI 層的取捨，不是 schema 約束**：`validated()` 只要求
    /// `radius > 0`／`sensitivity > 0`，既有 profile 落在範圍外仍然合法可載入
    /// （Never break userspace）。下限 0.02 是「再小就點不到」，上限 0.5 是
    /// 「正規化基準是寬度，超過就一定出畫面」。
    ///
    /// **非 `private`**（B-Task 7 review Critical 修正）：`EditorOverlay` 的半徑拖曳
    /// 把手要夾在同一組界線裡，兩處各寫一份字面值遲早漂移（這個 repo 已經因為
    /// `EmulatorEndpoint` 與 clamp 邏輯各吃過一次虧）。這裡是唯一的家，`EditorOverlay`
    /// 引用 `EditorInspector.radiusRange`。
    static let radiusRange: ClosedRange<Double> = 0.02...0.5
    static let sensitivityRange: ClosedRange<Double> = 0.1...5.0

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
                       in: Self.radiusRange)
                Text(String(format: "%.2f", radius))
                    .font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
        case .look(_, let sensitivity):
            HStack {
                Text("靈敏度").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(get: { sensitivity }, set: { onSensitivity($0) }),
                       in: Self.sensitivityRange)
                Text(String(format: "%.1f", sensitivity))
                    .font(.caption2).monospacedDigit().frame(width: 34, alignment: .trailing)
            }
        case .tap:
            Text("點擊鍵只有位置可調——直接在畫面上拖它。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
