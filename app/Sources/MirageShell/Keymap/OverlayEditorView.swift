import MirageCore
import SwiftUI

/// 編輯模式的組合層：上半是可互動的 overlay（Task 6 加把手），下半是抽屜。
///
/// 這個型別本身**不持有狀態**——`EditorSession` 由 `AppModel` 持有，因為 overlay 與抽屜
/// 要共用同一份選取，而且 ⌘E 離開時的未存變更檢查發生在 `AppModel` 那一層。
struct OverlayEditorView: View {
    let session: EditorSession
    let frameSize: (w: Int, h: Int)
    let onSelect: (UUID?) -> Void
    let onMove: (NormPoint) -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            EditorOverlay(session: session, frameSize: frameSize,
                          onSelect: onSelect, onMove: onMove)
            EditorDrawer(session: session, onSelect: onSelect, onSave: onSave) {
                AnyView(EmptyView())      // Task 7 填入半徑／靈敏度
            }
        }
    }
}
