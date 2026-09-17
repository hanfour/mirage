import AppKit

/// 唯一的鏡像視窗（2026-09-17，規格 `docs/specs/2026-09-17-launch-without-window-design.md`）。
///
/// 原本是 SwiftUI `Window` 場景：SwiftUI 在啟動時一定建立並顯示它，之後才跑 `.task`，
/// 所以背景模式啟動時視窗會在畫面上停留 318 到 472 ms。改由這裡在第一次需要時建立。
///
/// D30 的「只能有一個鏡像視窗」改由這個型別保證：只有 `window()` 會建立 `NSWindow`，
/// 且只建立一次。`AppModel` 只有一份，重複建立視窗會讓同一份狀態被兩個畫面讀寫。
@MainActor
final class MirrorWindowController {
    static let defaultAutosaveName = "mirage-mirror"
    static let minimumContentSize = NSSize(width: 270, height: 600)
    /// 沒有存過位置時的初始大小，與 SwiftUI `Window` 時期實測的視窗一致。
    private static let initialContentSize = NSSize(width: 459, height: 992)

    private let autosaveName: String
    private let makeContentView: @MainActor () -> NSView
    private var created: NSWindow?
    private weak var delegate: NSWindowDelegate?

    init(autosaveName: String = MirrorWindowController.defaultAutosaveName,
         makeContentView: @escaping @MainActor () -> NSView) {
        self.autosaveName = autosaveName
        self.makeContentView = makeContentView
    }

    var existingWindow: NSWindow? { created }

    func window() -> NSWindow {
        if let created { return created }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Mirage"
        // 關視窗是隱藏（AppLifecycle.windowShouldClose 回傳 false），物件要留著。
        window.isReleasedWhenClosed = false
        window.contentView = makeContentView()
        window.contentMinSize = Self.minimumContentSize
        // SwiftUI 的 Window 會自動加；少了它無法全螢幕，gui_session.sh 的 AXFullScreen 會失敗。
        window.collectionBehavior.insert(.fullScreenPrimary)
        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
        window.delegate = delegate
        created = window
        return window
    }

    /// `AppLifecycle` 在 `startLifecycle()` 才建立，一般模式的視窗比它早建立，所以兩種順序都要能設定。
    func attach(delegate: NSWindowDelegate) {
        self.delegate = delegate
        created?.delegate = delegate
    }
}
