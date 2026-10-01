import AppKit
import QuartzCore

/// 唯一的鏡像視窗（2026-09-17，規格 `docs/specs/2026-09-17-launch-without-window-design.md`）。
///
/// 原本是 SwiftUI `Window` 場景：SwiftUI 在啟動時一定建立並顯示它，之後才跑 `.task`，
/// 所以背景模式啟動時視窗會在畫面上停留 318 到 472 ms。改由這裡在第一次需要時建立。
///
/// D30 的「只能有一個鏡像視窗」改由這個型別保證：只有 `window()` 會建立 `NSWindow`，
/// 且只建立一次。`AppModel` 只有一份，重複建立視窗會讓同一份狀態被兩個畫面讀寫。
@MainActor
final class MirrorWindowController {
    static let defaultAutosaveName = "mirage-mirror-v2"
    static let minimumContentSize = NSSize(width: 270, height: 600)
    /// 內容長寬比與 iPhone 鏡像輸出相同，標題列透明後內容延伸到整個視窗。
    static let initialContentSize = NSSize(width: 324, height: 720)

    private let autosaveName: String
    private let makeContentView: @MainActor () -> NSView
    private var created: NSWindow?
    private weak var delegate: NSWindowDelegate?
    private(set) var titlebarActions: MirrorTitlebarActionsController?
    private var titlebarBackdrop: MirrorTitlebarBackdropView?
    private var titlebarInteraction: MirrorTitlebarInteractionView?
    private var titlebarVisible = false
    private var androidActionsEnabled = false
    private nonisolated(unsafe) var windowObservers: [NSObjectProtocol] = []

    var onAndroidKey: ((String) -> Void)? {
        didSet { titlebarActions?.onAndroidKey = onAndroidKey }
    }

    deinit {
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    init(autosaveName: String = MirrorWindowController.defaultAutosaveName,
         makeContentView: @escaping @MainActor () -> NSView) {
        self.autosaveName = autosaveName
        self.makeContentView = makeContentView
    }

    var existingWindow: NSWindow? { created }

    func window() -> NSWindow {
        if let created { return created }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.initialContentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
        created = window
        window.title = "Mirage"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // 關視窗是隱藏（AppLifecycle.windowShouldClose 回傳 false），物件要留著。
        window.isReleasedWhenClosed = false
        let contentView = makeContentView()
        window.contentView = contentView
        window.contentMinSize = Self.minimumContentSize
        // SwiftUI 的 Window 會自動加；少了它無法全螢幕，gui_session.sh 的 AXFullScreen 會失敗。
        window.collectionBehavior.insert(.fullScreenPrimary)

        let actions = MirrorTitlebarActionsController(nibName: nil, bundle: nil)
        actions.onAndroidKey = onAndroidKey
        actions.setEnabled(androidActionsEnabled)
        window.addTitlebarAccessoryViewController(actions)
        titlebarActions = actions

        let backdrop = MirrorTitlebarBackdropView(frame: NSRect(
            x: 0, y: contentView.bounds.height - MirrorTitlebarBackdropView.height,
            width: contentView.bounds.width, height: MirrorTitlebarBackdropView.height))
        backdrop.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(backdrop, positioned: .above, relativeTo: nil)
        titlebarBackdrop = backdrop

        let interaction = MirrorTitlebarInteractionView(frame: contentView.bounds)
        interaction.autoresizingMask = [.width, .height]
        interaction.onHoverChanged = { [weak self] hovered in self?.setTitlebarVisible(hovered) }
        contentView.addSubview(interaction, positioned: .above, relativeTo: nil)
        titlebarInteraction = interaction
        setTitlebarViewsVisible(false, animated: false, in: window, actions: actions)
        observeWindow(window)

        if !window.setFrameUsingName(autosaveName) { window.center() }
        window.setFrameAutosaveName(autosaveName)
        window.delegate = delegate
        return window
    }

    /// `AppLifecycle` 在 `startLifecycle()` 才建立，一般模式的視窗比它早建立，所以兩種順序都要能設定。
    func attach(delegate: NSWindowDelegate) {
        self.delegate = delegate
        created?.delegate = delegate
    }

    func setAndroidActionsEnabled(_ enabled: Bool) {
        androidActionsEnabled = enabled
        titlebarActions?.setEnabled(enabled)
    }

    private func observeWindow(_ window: NSWindow) {
        for name in [NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self, weak window] notification in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    if notification.name == NSWindow.didEnterFullScreenNotification {
                        self.titlebarInteraction?.customBehaviorEnabled = false
                        self.titlebarVisible = true
                        self.titlebarInteraction?.titlebarVisible = true
                        if let actions = self.titlebarActions {
                            self.setTitlebarViewsVisible(true, animated: false, in: window, actions: actions)
                        }
                    } else if notification.name == NSWindow.didExitFullScreenNotification {
                        self.titlebarInteraction?.customBehaviorEnabled = true
                        self.titlebarVisible = false
                        self.titlebarInteraction?.titlebarVisible = false
                        if let actions = self.titlebarActions {
                            self.setTitlebarViewsVisible(false, animated: false, in: window, actions: actions)
                        }
                    } else if window.styleMask.contains(.fullScreen) {
                        self.titlebarInteraction?.customBehaviorEnabled = false
                        self.setTitlebarVisible(true, animated: false)
                    } else {
                        self.titlebarInteraction?.customBehaviorEnabled = true
                        self.setTitlebarVisible(false, animated: false)
                    }
                }
            }
            windowObservers.append(observer)
        }
    }

    private func setTitlebarVisible(_ visible: Bool, animated: Bool = true) {
        guard let window = created, let titlebarActions, let titlebarInteraction else { return }
        if window.styleMask.contains(.fullScreen) {
            titlebarInteraction.customBehaviorEnabled = false
            titlebarVisible = true
            titlebarInteraction.titlebarVisible = true
            setTitlebarViewsVisible(true, animated: false, in: window, actions: titlebarActions)
            return
        }

        titlebarInteraction.customBehaviorEnabled = true
        guard titlebarVisible != visible else { return }
        titlebarVisible = visible
        titlebarInteraction.titlebarVisible = visible
        setTitlebarViewsVisible(visible, animated: animated, in: window, actions: titlebarActions)
    }

    private func setTitlebarViewsVisible(_ visible: Bool, animated: Bool,
                                         in window: NSWindow,
                                         actions: MirrorTitlebarActionsController) {
        let buttons: [NSButton] = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        let views: [NSView] = buttons.map { $0 as NSView } + [actions.view]
            + [titlebarBackdrop].compactMap { $0 }
        if visible {
            views.forEach { $0.isHidden = false }
            buttons.forEach { $0.isEnabled = true }
            actions.setEnabled(androidActionsEnabled)
        } else {
            buttons.forEach { $0.isEnabled = false }
            actions.setEnabled(false)
        }

        let alpha: CGFloat = visible ? 1 : 0
        let finish: () -> Void = { [weak self] in
            guard let self, self.titlebarVisible == visible else { return }
            if !visible { views.forEach { $0.isHidden = true } }
        }
        guard animated else {
            views.forEach { $0.alphaValue = alpha }
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            views.forEach { $0.animator().alphaValue = alpha }
        } completionHandler: {
            MainActor.assumeIsolated { finish() }
        }
    }
}
