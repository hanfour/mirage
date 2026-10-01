import MirageCore
import SwiftUI

/// 編輯模式的組合層：可互動的 overlay（Task 6 加移動把手、Task 7 加半徑把手）＋
/// 疊在底部的抽屜（Task 7 填入半徑／靈敏度 inspector）。
///
/// 這個型別本身**不持有狀態**——`EditorSession` 由 `AppModel` 持有，因為 overlay 與抽屜
/// 要共用同一份選取，而且 ⌘E 離開時的未存變更檢查發生在 `AppModel` 那一層。
struct OverlayEditorView: View {
    let session: EditorSession
    let frameSize: (w: Int, h: Int)
    let onSelect: (UUID?) -> Void
    let onMove: (NormPoint) -> Void
    let onSave: () -> Void
    let onAddTap: () -> Void
    let onDeleteSelected: () -> Void
    let onRebindSelected: () -> Void
    let onClearGamepad: () -> Void
    let onRadius: (Double) -> Void
    let onSensitivity: (Double) -> Void

    var body: some View {
        // **必須是 ZStack 不是 VStack**（C1，D5 階段 B 終審）：`EditorOverlay` 的
        // `GeometryReader` 要拿到與 `MirrorContainerView`（Scene 那個 ZStack 的同層兄弟，
        // 用完整 `bounds` 算 `ViewportFit.fit`）**完全相同**的尺寸，兩邊算出的內容矩形
        // 才會一致。用 VStack 的話抽屜不可壓縮、`GeometryReader` 貪婪，overlay 只拿得到
        // 扣掉抽屜高度後的殘量——同一個 `ViewportFit.fit` 餵不同的 bounds，於是標記畫的
        // 位置與真正的 guest 位置錯開（視窗 270×600、幀 1080×2400、抽屜約 100pt 時，
        // y 方向差到幀上 329px）。
        //
        // 視覺上零損失：抽屜本來就是浮動面板（自帶 `.background(.black.opacity(0.85))`
        // ＋ `.cornerRadius(8)`）、本來就蓋住鏡像底部——鏡像從來沒有跟著縮。
        ZStack(alignment: .bottom) {
            EditorOverlay(session: session, frameSize: frameSize,
                          onSelect: onSelect, onMove: onMove, onRadius: onRadius)
            EditorDrawer(session: session, onSelect: onSelect, onSave: onSave,
                         onAddTap: onAddTap, onDeleteSelected: onDeleteSelected,
                         onRebindSelected: onRebindSelected, onClearGamepad: onClearGamepad) {
                if let id = session.selectedID,
                   let item = session.items.first(where: { $0.id == id }) {
                    AnyView(EditorInspector(binding: item.binding,
                                            isRebinding: session.rebindingID == id,
                                            onRadius: onRadius,
                                            onSensitivity: onSensitivity,
                                            onDelete: onDeleteSelected,
                                            onRebind: onRebindSelected,
                                            onClearGamepad: onClearGamepad))
                } else {
                    AnyView(EmptyView())
                }
            }
        }
    }
}
