import MirageCore
import SwiftUI

/// 非編輯模式：半透明 binding 提示（tap=圓點+鍵標、joystick=圓環、look=不顯示標記）。
/// `allowsHitTesting(false)`——純視覺提示，不可攔截底下 MirrorView 的滑鼠事件。
///
/// **座標基準是 letterbox 後的內容矩形，不是整個視窗**（2026-07-30，階段 B Task 2/4）。
/// 原本用 `GeometryReader` 的整個視窗尺寸換算（`at.x * geo.size.width`），但 guest 畫面被
/// `MirrorContainerView` 依 `ViewportFit.fit(...)` 置中進內容矩形——黑邊不屬於 guest。
/// 視窗模式下 `contentAspectRatio` 把黑邊壓到接近 0 所以看不太出來，**全螢幕時 macOS
/// 忽略那個設定、黑邊是真的**，標記就會整體偏移。
struct KeymapOverlay: View {
    let profile: KeymapProfile?
    /// 目前解碼幀尺寸，用來算內容矩形。`(0, 0)`＝尚未收到幀 → `fit` 回 `.zero` → 不畫。
    let frameSize: (w: Int, h: Int)

    var body: some View {
        GeometryReader { geo in
            let rect = ViewportFit.fit(frame: frameSize,
                                       in: (w: Int(geo.size.width), h: Int(geo.size.height)))
            if let profile, rect.width > 0, rect.height > 0 {
                ForEach(Array(profile.bindings.enumerated()), id: \.offset) { _, b in
                    marker(for: b, in: rect)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // 明確寫模組名：MirageCore.Binding（keymap 綁定列舉）跟 SwiftUI.Binding（雙向繫結）
    // 撞名，兩個 import 同時出現時裸寫 `Binding` 會 ambiguous。
    @ViewBuilder
    private func marker(for b: MirageCore.Binding, in rect: FitRect) -> some View {
        switch b {
        case .tap(let key, let at):
            let p = EditorGeometry.viewPoint(for: at, in: rect)
            Circle().stroke(.white.opacity(0.5)).frame(width: 44, height: 44)
                .position(x: p.x, y: p.y)
                .overlay(
                    Text(label(key)).font(.caption).foregroundStyle(.white)
                        .position(x: p.x, y: p.y)
                )
        case .joystick(_, _, _, _, let center, let radius):
            let p = EditorGeometry.viewPoint(for: center, in: rect)
            let d = EditorGeometry.radiusInPoints(radius, in: rect) * 2
            Circle().stroke(.white.opacity(0.4))
                .frame(width: d, height: d)
                .position(x: p.x, y: p.y)
        case .look:
            // 視角不是螢幕上的一個點——硬畫一個圈只會讓人以為那裡有東西可按。
            // 它只活在編輯器的抽屜清單裡（設計文件 §4.3）。
            EmptyView()
        }
    }

    private func label(_ k: KeyCode) -> String {
        if case .key(let s) = k { return s } else { return "•" }
    }
}
