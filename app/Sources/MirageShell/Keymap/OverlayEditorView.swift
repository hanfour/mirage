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
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 階段 B Task 6 會把這裡換成可拖曳的 overlay；此刻先沿用唯讀標記，
            // 版面與座標基準（letterbox 內容矩形）在 Task 4 就已經正確。
            KeymapOverlay(profile: session.profile(), frameSize: frameSize)
            EditorDrawer(session: session, onSelect: onSelect, onSave: onSave) {
                AnyView(EmptyView())      // Task 6 填入半徑／靈敏度
            }
        }
    }
}
