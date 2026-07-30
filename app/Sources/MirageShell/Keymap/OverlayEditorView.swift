import MirageCore
import SwiftUI

/// 編輯模式的組合層：上半是可互動的 overlay（Task 6 加移動把手、Task 7 加半徑把手），
/// 下半是抽屜（Task 7 填入半徑／靈敏度 inspector）。
///
/// 這個型別本身**不持有狀態**——`EditorSession` 由 `AppModel` 持有，因為 overlay 與抽屜
/// 要共用同一份選取，而且 ⌘E 離開時的未存變更檢查發生在 `AppModel` 那一層。
struct OverlayEditorView: View {
    let session: EditorSession
    let frameSize: (w: Int, h: Int)
    let onSelect: (UUID?) -> Void
    let onMove: (NormPoint) -> Void
    let onSave: () -> Void
    let onRadius: (Double) -> Void
    let onSensitivity: (Double) -> Void

    var body: some View {
        VStack(spacing: 0) {
            EditorOverlay(session: session, frameSize: frameSize,
                          onSelect: onSelect, onMove: onMove, onRadius: onRadius)
            EditorDrawer(session: session, onSelect: onSelect, onSave: onSave) {
                if let id = session.selectedID,
                   let item = session.items.first(where: { $0.id == id }) {
                    AnyView(EditorInspector(binding: item.binding,
                                            onRadius: onRadius,
                                            onSensitivity: onSensitivity))
                } else {
                    AnyView(EmptyView())
                }
            }
        }
    }
}
