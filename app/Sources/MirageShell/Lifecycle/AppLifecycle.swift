import AppKit
import MirageCore
import ObjectiveC

/// 生命週期協調：視窗關閉→休眠（不退出，選單列常駐）、喚醒→恢復、Cmd+Q→乾淨 teardown。
@MainActor
final class AppLifecycle: NSObject, NSWindowDelegate {
    private let client: EmulatorClient
    private var policy = LifecyclePolicy()

    init(client: EmulatorClient) {
        self.client = client
        super.init()
        if ProcessInfo.processInfo.environment["MIRAGE_CONN_LOG"] == "1" {
            NotificationCenter.default.addObserver(
                self, selector: #selector(diagnoseWillClose(_:)),
                name: NSWindow.willCloseNotification, object: nil)
            NotificationCenter.default.addObserver(
                self, selector: #selector(diagnoseDidBecomeActive(_:)),
                name: NSApplication.didBecomeActiveNotification, object: nil)
        }
    }

    // Observe actual closure separately from a request to hide the window.
    @objc private func diagnoseWillClose(_ notification: Notification) {
        Self.diagnose("willClose", window: notification.object as? NSWindow)
    }

    @objc private func diagnoseDidBecomeActive(_ notification: Notification) {
        Self.diagnose("didBecomeActive", window: NSApp.keyWindow)
    }

    static func diagnose(_ event: String, window: NSWindow?, receiver: String = "nil",
                         result: String = "nil", action: String = "nil") {
        guard ProcessInfo.processInfo.environment["MIRAGE_CONN_LOG"] == "1" else { return }
        let app = NSApp as NSApplication?
        let appDelegate = app?.delegate
        let appDelegateType = typeName(appDelegate)
        let hasClosePolicy = appDelegate?.responds(to: NSSelectorFromString("applicationShouldTerminateAfterLastWindowClosed:")) ?? false
        func containsMirror(_ view: NSView) -> Bool {
            view is MirrorMTKView || view.subviews.contains { containsMirror($0) }
        }
        func typeName(_ object: AnyObject?) -> String {
            guard let object, let runtimeClass = object_getClass(object) else { return "nil" }
            return NSStringFromClass(runtimeClass)
        }
        func token(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.:"))) ?? "nil"
        }
        let fields: [(String, String)] = [
            ("event", event), ("appDelegate", appDelegateType),
            ("respondsToLastWindowPolicy", String(hasClosePolicy)),
            ("isActive", app.map { String($0.isActive) } ?? "nil"),
            ("mainMenuNil", String(app?.mainMenu == nil)),
            ("mainMenuItems", app?.mainMenu.map { String($0.numberOfItems) } ?? "nil"),
            ("activationPolicy", app.map { String($0.activationPolicy().rawValue) } ?? "nil"),
            ("receiver", receiver), ("return", result), ("action", action),
            ("windowCount", String((NSApp as NSApplication?)?.windows.count ?? 0)),
            ("window", window.map { String(describing: ObjectIdentifier($0)) } ?? "nil"),
            ("windowClass", typeName(window)), ("number", window.map { String($0.windowNumber) } ?? "nil"),
            ("identifier", window?.identifier?.rawValue ?? "nil"),
            ("mirror", String(window?.contentView.map { containsMirror($0) } ?? false)),
            ("key", String(window?.isKeyWindow ?? false)), ("visible", String(window?.isVisible ?? false)),
            ("delegate", typeName(window?.delegate)), ("lifecycle", String(window?.delegate is AppLifecycle)),
            ("contentView", typeName(window?.contentView)), ("controller", typeName(window?.windowController)),
            ("level", window.map { String($0.level.rawValue) } ?? "nil"),
            ("styleMask", window.map { String($0.styleMask.rawValue) } ?? "nil"),
            ("width", window.map { String(format: "%.0f", $0.frame.width) } ?? "nil"),
            ("height", window.map { String(format: "%.0f", $0.frame.height) } ?? "nil"),
            ("excludedFromWindowsMenu", String(window?.isExcludedFromWindowsMenu ?? false))
        ]
        print("[wake-diag] " + fields.map { "\($0.0)=\(token($0.1))" }.joined(separator: " "))
    }

    /// 視窗即將關閉 → 觸發休眠而非退出（回傳 false 阻止關閉，改為隱藏）。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Self.diagnose("windowShouldClose", window: sender, result: "false", action: "suspend")
        sender.orderOut(nil)                 // 隱藏視窗，app 續存（選單列常駐）
        policy.didHide()
        Task { await client.suspend() }
        return false
    }

    func wake(showing window: NSWindow?) {
        Self.diagnose("wake", window: window, action: policy.suspended ? "resume" : "show")
        let shouldResume = policy.consumeResume()
        window?.makeKeyAndOrderFront(nil)
        Self.diagnose("wake-before-activate", window: window)
        // L：顯示視窗後明確啟用 app，嘗試恢復主選單快捷鍵；仍需活體驗證 ⌘Q。
        NSApp.activate(ignoringOtherApps: true)
        Self.diagnose("wake-after-activate", window: window)
        guard shouldResume else { return }
        Task { await client.wake() }
    }
}
