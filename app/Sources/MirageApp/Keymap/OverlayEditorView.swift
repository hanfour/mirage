import MirageCore
import SwiftUI

/// 陽春編輯器（⌘E 進入）：目前 MVP 沿用 KeymapOverlay 的視覺當底，加「存檔」按鈕
/// （version+1，不可變、原子寫，見 ProfileStore.save）。拖放調整 binding 座標／
/// 滑桿調 radius、sensitivity 等互動細節列 pending-human（需 GUI 手感驗證）。
/// 「完成編輯」由父層（MirageApp 的 ⌘E monitor / AppModel.toggleEditing）驅動，
/// 這裡的按鈕只是視覺提示，不持有切換邏輯——避免兩處各自一份 editing 狀態。
struct OverlayEditorView: View {
    // 明確寫 SwiftUI.Binding：MirageCore 也有一個叫 Binding 的列舉（keymap 綁定），兩個
    // import 同時出現時裸寫 `@Binding` 會 ambiguous（見 KeymapOverlay.swift 同樣的處理）。
    @SwiftUI.Binding var profile: KeymapProfile
    let onSave: (KeymapProfile) -> Void

    var body: some View {
        VStack {
            KeymapOverlay(profile: profile)
            HStack {
                Button("存檔") { onSave(bumpVersion(profile)) }
                Text("完成編輯：⌘E").font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private func bumpVersion(_ p: KeymapProfile) -> KeymapProfile {
        KeymapProfile(gameId: p.gameId, version: p.version + 1, bindings: p.bindings)
    }
}
