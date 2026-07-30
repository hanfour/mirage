import MirageCore
import SwiftUI

/// 編輯模式的 overlay：可點選、可拖曳。
///
/// **為什麼與 `KeymapOverlay` 分成兩個型別**：唯讀 overlay 的硬性條件是
/// `allowsHitTesting(false)`——它絕不能攔截底下 `MirrorView` 的滑鼠事件；而這個 overlay
/// 的存在理由**正是**要攔截。用一個旗標讓同一個型別切換兩種相反的命中測試行為，就是把
/// 兩件事塞進一個名字裡，而階段 A 的 D22 正是那樣長出來的（`hasProfile` 一個述詞兩種語意）。
///
/// 編輯時 guest 收不到滑鼠已由階段 A 保證（`MirrorView.Coordinator.isEditing` 一律不送），
/// 所以這裡可以放心吃掉手勢。
struct EditorOverlay: View {
    let session: EditorSession
    let frameSize: (w: Int, h: Int)
    let onSelect: (UUID?) -> Void
    let onMove: (NormPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let rect = ViewportFit.fit(frame: frameSize,
                                       in: (w: Int(geo.size.width), h: Int(geo.size.height)))
            if rect.width > 0, rect.height > 0 {
                ForEach(session.items) { item in
                    marker(for: item, in: rect)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: EditorSession.Item, in rect: FitRect) -> some View {
        let selected = session.selectedID == item.id
        switch item.binding {
        case .tap(let key, let at):
            let p = EditorGeometry.viewPoint(for: at, in: rect)
            Circle()
                .stroke(selected ? Color.accentColor : .white.opacity(0.5), lineWidth: selected ? 2 : 1)
                .frame(width: 44, height: 44)
                .overlay(Text(Self.label(key)).font(.caption).foregroundStyle(.white))
                .position(x: p.x, y: p.y)
                .opacity(selected ? 1 : 0.6)
                .gesture(dragGesture(item: item, rect: rect))

        case .joystick(_, _, _, _, let center, let radius):
            let p = EditorGeometry.viewPoint(for: center, in: rect)
            let d = EditorGeometry.radiusInPoints(radius, in: rect) * 2
            Circle()
                .stroke(selected ? Color.accentColor : .white.opacity(0.4), lineWidth: selected ? 2 : 1)
                .frame(width: d, height: d)
                .contentShape(Circle())
                .position(x: p.x, y: p.y)
                .opacity(selected ? 1 : 0.6)
                .gesture(dragGesture(item: item, rect: rect))

        case .look:
            // 視角不是螢幕上的一個點——它只活在抽屜清單裡（設計文件 §4.3）。
            EmptyView()
        }
    }

    /// 點一下＝選取；拖曳＝選取並移動。用同一個 `DragGesture(minimumDistance: 0)` 兼顧兩者，
    /// 不必再疊一個 `TapGesture` 去跟它搶手勢。
    private func dragGesture(item: EditorSession.Item, rect: FitRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if session.selectedID != item.id { onSelect(item.id) }
                if let p = EditorGeometry.normPoint(x: value.location.x, y: value.location.y, in: rect) {
                    onMove(p)
                }
            }
    }

    private static func label(_ k: KeyCode) -> String {
        if case .key(let s) = k { return s } else { return "•" }
    }
}
