import MirageCore
import SwiftUI

/// 底部抽屜：binding 清單 ＋ 選中項的參數區 ＋ 存檔。
///
/// **為什麼是底部抽屜不是側欄**（設計文件 §3）：Mirage 的視窗是 9:20 手機比例，側欄會吃掉
/// 超過一半寬度，鏡像被壓窄後拖出來的位置不準——**吃高度比吃寬度便宜**。而且 `.look`
/// 在畫面上沒有任何視覺標記（`KeymapOverlay` 對它畫 `EmptyView`），純直接操作碰不到它，
/// 清單是它唯一的棲身之處。
///
/// 階段 B **不含**「＋新增」「刪除」「改鍵」——那是階段 C。
struct EditorDrawer: View {
    let session: EditorSession
    let onSelect: (UUID?) -> Void
    let onSave: () -> Void
    /// 選中項的參數區。階段 B 由 Task 7 填入半徑／靈敏度滑桿；此刻先留空插槽，
    /// 讓清單與參數區的版面關係在這個 task 就定下來。
    ///
    /// **不加 `@ViewBuilder`**：這個屬性已經明確回傳 `AnyView`，加了只會讓讀的人
    /// 以為可以寫多語句的 view builder，實際上型別擋著。
    let inspector: () -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("BINDING · \(session.items.count)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("存檔", action: onSave)
                    .disabled(!session.isDirty)
                Text("完成 ⌘E").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            ForEach(session.items) { item in
                Button {
                    // 再點一次已選中的項目＝取消選取，讓使用者有辦法回到「沒選任何東西」。
                    onSelect(session.selectedID == item.id ? nil : item.id)
                } label: {
                    HStack {
                        Text(Self.rowLabel(item.binding)).font(.caption)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .background(session.selectedID == item.id
                            ? Color.accentColor.opacity(0.25) : Color.clear)
                .cornerRadius(3)
            }
            if session.selectedID != nil {
                Divider()
                inspector()
            }
        }
        .padding(8)
        .background(.black.opacity(0.85))
        .cornerRadius(8)
    }

    /// 清單每一列的文字。`.look` 在畫面上沒有標記，所以這裡是使用者唯一看得到它的地方
    /// ——標籤要說清楚它是什麼，不能只寫「binding 3」。
    static func rowLabel(_ b: MirageCore.Binding) -> String {
        switch b {
        case .joystick(let u, let d, let l, let r, _, _):
            return "◎ 搖桿　\(key(u)) \(key(l)) \(key(d)) \(key(r))"
        case .tap(let k, _):
            return "● 點擊　\(key(k))"
        case .look:
            return "↗ 視角　滑鼠"
        }
    }

    private static func key(_ k: KeyCode) -> String {
        if case .key(let s) = k { return s.uppercased() } else { return "•" }
    }
}
