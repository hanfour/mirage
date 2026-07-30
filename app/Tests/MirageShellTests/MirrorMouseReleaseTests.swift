import AppKit
import Testing
@testable import MirageCore
@testable import MirageShell

/// D7：拖到鏡像區域外放開，`mouseUp` 不得被吞掉。
///
/// **為什麼這是必然發生而不是邊角情況**：`mouseDown` 一定落在 MTKView 界內（黑邊屬於
/// `MirrorContainerView` 的背景，它沒有覆寫滑鼠處理），但 drag 一旦開始，AppKit 會把後續
/// 的 `mouseDragged`／`mouseUp` **繼續投遞給同一個 view**，即使游標已經離開它。於是放開時
/// 的座標落在 0…1 之外。而黑邊在非同比視窗下**必定存在**（`ViewportFit` 就是為此而生），
/// 使用者只要拖過一次邊界就會踩到。
///
/// 後果與 D6 同一族：guest 端留著一根永遠按著的手指，而且不會自癒。
@MainActor
@Suite struct MirrorMouseReleaseTests {
    /// 把 view 裝進真視窗——`convert(_:from: nil)` 是「從視窗座標換算」，沒有視窗就沒有
    /// 可信的換算基準。視窗用 `.borderless` 且不 `makeKeyAndOrderFront`，headless 下不顯示。
    private func makeView(width: CGFloat, height: CGFloat) -> (MirrorMTKView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = MirrorMTKView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = view
        return (view, window)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint,
                            in window: NSWindow) throws -> NSEvent
    {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 0))
    }

    /// 界內按下、**界外**放開：up 一定要送出去。
    @Test func releaseOutsideBoundsStillSendsMouseUp() throws {
        let (view, window) = makeView(width: 100, height: 200)
        var events: [(Double, Double, Bool)] = []
        view.onMouse = { nx, ny, down in events.append((nx, ny, down)) }

        try view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 50, y: 100), in: window))
        // 往上拖出視窗頂端（AppKit 左下原點，y=300 > 高度 200）——模擬拖到黑邊／視窗外。
        try view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 50, y: 300), in: window))

        #expect(events.map(\.2) == [true, false])   // 少了 false 就是永久卡住的手指
    }

    /// 界外的座標要**夾住**而不是丟棄：夾出來的點必須仍是合法的正規化座標，
    /// 否則送出去的是越界座標，比不送更糟（畫面有反應但點在錯的地方）。
    @Test func releaseOutsideBoundsIsClampedIntoRange() throws {
        let (view, window) = makeView(width: 100, height: 200)
        var events: [(Double, Double, Bool)] = []
        view.onMouse = { nx, ny, down in events.append((nx, ny, down)) }

        try view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 50, y: 100), in: window))
        try view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: 300, y: 300), in: window))

        let up = try #require(events.last)
        #expect(up.2 == false)
        #expect(up.0 == 1.0)   // x 超出右緣 → 夾到 1
        #expect(up.1 == 0.0)   // y 超出頂端 → 夾到 0（左上原點）
    }

    /// 拖曳途中離開界外不該讓觸點「消失」——真實觸控螢幕上手指不會離開螢幕，
    /// 夾在邊緣是最接近的類比。丟棄的話 guest 端會停在最後一個界內位置。
    @Test func dragOutsideBoundsKeepsTrackingAtTheEdge() throws {
        let (view, window) = makeView(width: 100, height: 200)
        var events: [(Double, Double, Bool)] = []
        view.onMouse = { nx, ny, down in events.append((nx, ny, down)) }

        try view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: 50, y: 100), in: window))
        try view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: -40, y: 100), in: window))

        #expect(events.count == 2)
        #expect(events.last?.0 == 0.0)    // x 超出左緣 → 夾到 0
        #expect(events.last?.2 == true)
    }
}
