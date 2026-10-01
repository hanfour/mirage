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
    let onRadius: (Double) -> Void

    /// 這一段拖曳手勢的「握把偏移」＝按下點與標記中心的差，`onChanged` 全程沿用。
    /// 由 `onEnded` 結束手勢並清除偏移。
    ///
    /// **一份就夠**：macOS 上同時只會有一個滑鼠拖曳在進行，標記之間不會有兩段手勢重疊。
    @State private var dragState = EditorDragState()

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
        // 具名座標空間，供 `dragGesture` 用——見該函式註解。
        .coordinateSpace(name: Self.coordinateSpaceName)
    }

    @ViewBuilder
    private func marker(for item: EditorSession.Item, in rect: FitRect) -> some View {
        let selected = session.selectedID == item.id
        switch item.binding {
        case .tap(let key, let at, _):
            let p = EditorGeometry.viewPoint(for: at, in: rect)
            Circle()
                .stroke(selected ? Color.accentColor : .white.opacity(0.5), lineWidth: selected ? 2 : 1)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .overlay(Text(Self.label(key)).font(.caption).foregroundStyle(.white))
                .position(x: p.x, y: p.y)
                .opacity(selected ? 1 : 0.6)
                .gesture(dragGesture(item: item, at: p, rect: rect))

        case .joystick(_, _, _, _, let center, let radius):
            let p = EditorGeometry.viewPoint(for: center, in: rect)
            let d = EditorGeometry.radiusInPoints(radius, in: rect) * 2
            Circle()
                .stroke(selected ? Color.accentColor : .white.opacity(0.4), lineWidth: selected ? 2 : 1)
                .frame(width: d, height: d)
                .contentShape(Circle())
                .position(x: p.x, y: p.y)
                .opacity(selected ? 1 : 0.6)
                .gesture(dragGesture(item: item, at: p, rect: rect))

            if selected {
                // 橘方塊：拖它改半徑。放在圓的右緣——半徑就是圓心到它的水平距離，
                // 所見即所得，不必解釋。
                //
                // **具名座標空間，不是 `.local`**（同 `dragGesture` 的理由）：`p` 是
                // `EditorGeometry.viewPoint` 算出來、相對於 `GeometryReader` 空間的座標。
                // 這個把手經過 `.position(x:y:)` 之後，`.local` 回報的 `value.location`
                // 會是相對於把手自己那個 11×11 的框，跟 `p.x` 不同基準——一按就把半徑
                // 崩成負值附近的極小值，手勢一啟動把手就跳位。
                let handleX = p.x + EditorGeometry.radiusInPoints(radius, in: rect)
                Rectangle()
                    .fill(Color.orange)
                    .frame(width: 11, height: 11)
                    .position(x: handleX, y: p.y)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                            .onChanged { value in
                                // 按下瞬間 `translation` 為 0，那是「點一下」不是拖曳
                                // （C2，D5 階段 B 終審）。少了這道守門，點一下橘方塊就會
                                // 把半徑寫成「圓心到按下點的距離」——那個值幾乎不可能剛好
                                // 等於原值，於是 `mutatingSelected` 的同值守門擋不住，
                                // 一次點擊就設 `isDirty = true`，離開時跳出假的未存變更提示。
                                //
                                // **這個把手刻意不做握把偏移**（與標記的拖曳不同）：它的
                                // 語意就是「圓心到游標的水平距離＝半徑」，所見即所得，
                                // 加了偏移反而讓拖出來的半徑與游標位置對不上。
                                guard value.translation != .zero else { return }
                                let d = value.location.x - p.x
                                // **必須夾，而且下限不能只擋負值**（B-Task 7 review Critical
                                // 修正）：`radius(fromPoints: 0, in:)` 回的是 `0.0`，不是
                                // nil——那個 guard 只在 `rect.width <= 0` 時才失敗，而把手
                                // 只在 `rect.width > 0` 的分支裡才畫得出來。往左拖過圓心
                                // （`d <= 0`）就會餵出 `radius: 0`：`ProfileStore.save` 不呼叫
                                // `validated()` 照樣寫進磁碟，但下次 `load` 的 `validated()`
                                // 會拒絕它——那個錯誤又被 `AppModel.applyActivation` 的
                                // `try?` 吞掉，使用者只會看到「keymap 就是不生效」，壞檔
                                // 永久留在磁碟，且沒有 UI 路徑回得去（⌘E 開的是新 starter，
                                // 不是那個壞檔）。上限同理：往右拖會產生 `radius > 1.0`，
                                // 不違反 schema 但一定超出畫面。與滑桿共用同一組界線
                                // （`EditorLimits`），不重複字面值。
                                //
                                // 更正（2026-07-30，I2）：`ProfileStore.save` 現在會
                                // `validated()`，`radius: 0` 已經寫不進磁碟了。但這裡的夾取
                                // 仍然必要——沒有它，使用者會看到「拖到底之後按存檔沒反應」，
                                // 而不是「半徑停在下限」。夾取是防它發生，驗證是防它落地。
                                if let r = EditorGeometry.radius(fromPoints: max(d, 0), in: rect) {
                                    onRadius(EditorLimits.clampRadius(r))
                                }
                            }
                    )
            }

        case .look:
            // 視角不是螢幕上的一個點——它只活在抽屜清單裡（設計文件 §4.3）。
            EmptyView()
        }
    }

    /// 點一下＝選取；拖曳＝選取並移動。用同一個 `DragGesture(minimumDistance: 0)` 兼顧兩者，
    /// 不必再疊一個 `TapGesture` 去跟它搶手勢。
    ///
    /// **必須用具名座標空間，不能用 `.local`**（Task 6 review 抓到，Critical）：這個手勢
    /// 掛在經過 `.position(x:y:)` 之後的標記上。`.position()` 只改變父層把它擺在哪，
    /// 不改變該 view 自己的手勢辨識器眼中的「local」是什麼——`.local` 回報的
    /// `value.location` 仍是相對於標記**自己那個框**（tap 是 44×44、搖桿是直徑 d×d），
    /// 不是 `GeometryReader` 的空間。而 `EditorGeometry.normPoint` 期待的 `rect` 是
    /// `GeometryReader` 那個空間裡的矩形。餵進 0…44 的值算出來的正規化座標會夾在接近 0，
    /// 加上 `minimumDistance: 0` 讓 `onChanged` 在按下瞬間就觸發——後果是「點一下想選取」
    /// 就把標記彈到內容矩形左上角。改用 `body` 裡宣告的具名座標空間，讓 `value.location`
    /// 與 `rect` 同一個基準。
    /// `at` 是標記中心的**視圖座標**（`EditorGeometry.viewPoint(for:in:)` 的結果，與
    /// `rect` 同一個基準）。握把偏移要它才算得出來。
    private func dragGesture(item: EditorSession.Item, at p: (x: Double, y: Double),
                             rect: FitRect) -> some Gesture
    {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                if session.selectedID != item.id { onSelect(item.id) }
                dragState.begin(at: value.startLocation, center: CGPoint(x: p.x, y: p.y))
                if let np = dragState.update(location: value.location,
                                             translation: value.translation, in: rect) {
                    onMove(np)
                }
            }
            // 手勢結束才歸零。放在 `onChanged` 裡判斷「是不是第一次」是行不通的——
            // `DragGesture` 不會告訴你這件事，偏移必須跨整段手勢活著。
            .onEnded { _ in dragState.end() }
    }

    private static let coordinateSpaceName = "editorOverlay"

    private static func label(_ k: KeyCode) -> String {
        if case .key(let s) = k { return s } else { return "•" }
    }
}
