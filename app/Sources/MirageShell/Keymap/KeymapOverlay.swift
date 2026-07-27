import MirageCore
import SwiftUI

/// 非編輯模式：半透明 binding 提示（tap=圓點+鍵標、joystick=圓環、look=不顯示標記）。
/// `allowsHitTesting(false)`——純視覺提示，不可攔截底下 MirrorView 的滑鼠事件。
struct KeymapOverlay: View {
    let profile: KeymapProfile?

    var body: some View {
        GeometryReader { geo in
            if let profile {
                ForEach(Array(profile.bindings.enumerated()), id: \.offset) { _, b in
                    marker(for: b, in: geo.size)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // 明確寫模組名：MirageCore.Binding（keymap 綁定列舉）跟 SwiftUI.Binding（雙向繫結）
    // 撞名，兩個 import 同時出現時裸寫 `Binding` 會 ambiguous。
    @ViewBuilder
    private func marker(for b: MirageCore.Binding, in size: CGSize) -> some View {
        switch b {
        case .tap(let key, let at):
            Circle().stroke(.white.opacity(0.5)).frame(width: 44, height: 44)
                .position(x: at.x * size.width, y: at.y * size.height)
                .overlay(
                    Text(label(key)).font(.caption).foregroundStyle(.white)
                        .position(x: at.x * size.width, y: at.y * size.height)
                )
        case .joystick(_, _, _, _, let center, let radius):
            Circle().stroke(.white.opacity(0.4))
                .frame(width: radius * size.width * 2, height: radius * size.width * 2)
                .position(x: center.x * size.width, y: center.y * size.height)
        case .look:
            EmptyView()
        }
    }

    private func label(_ k: KeyCode) -> String {
        if case .key(let s) = k { return s } else { return "•" }
    }
}
