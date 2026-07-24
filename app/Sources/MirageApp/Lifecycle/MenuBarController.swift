import AppKit

/// 選單列常駐：顯示連線/電源狀態，提供喚醒、顯示視窗、退出。
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let onWake: () -> Void
    private let onShow: () -> Void
    private let statusMenuItem: NSMenuItem

    init(onWake: @escaping () -> Void, onShow: @escaping () -> Void) {
        self.onWake = onWake
        self.onShow = onShow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🪞"
        statusMenuItem = NSMenuItem(title: "狀態：—", action: nil, keyEquivalent: "")

        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "喚醒", action: #selector(wakeTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "顯示視窗", action: #selector(showTapped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Mirage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func updateStatus(_ text: String) { statusMenuItem.title = "狀態：\(text)" }

    @objc private func wakeTapped() { onWake() }
    @objc private func showTapped() { onShow() }
}

private extension NSMenu {
    @discardableResult
    func addItem(withTitle t: String, action: Selector, keyEquivalent k: String) -> NSMenuItem {
        let item = NSMenuItem(title: t, action: action, keyEquivalent: k)
        addItem(item)
        return item
    }
}
