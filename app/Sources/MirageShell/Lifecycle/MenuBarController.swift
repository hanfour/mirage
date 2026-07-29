import AppKit

/// 選單列常駐：顯示連線/電源狀態，提供喚醒、顯示視窗、退出。
/// P1-d Task 6：加「目前遊戲」狀態列 + 手動 keymap 覆蓋子選單（停用/恢復自動/套用指定 profile）。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onWake: () -> Void
    private let onShow: () -> Void
    private let statusMenuItem: NSMenuItem
    private let gameItem: NSMenuItem
    private let muteItem: NSMenuItem
    private let forceMenu: NSMenu

    /// Task 6：AppModel.startDetection() 綁定這三個回呼到 setOverride(.disabled/.auto/.force(profile))。
    var onDisable: (() -> Void)?
    var onAuto: (() -> Void)?
    var onForce: ((String) -> Void)?

    /// P1-e：AppModel.startLifecycle() 綁定 → NSApp.keyWindow?.toggleFullScreen(nil)。
    var onToggleFullScreen: (() -> Void)?

    /// P1-e：AppModel.startAudio() 綁定 → AudioPlayer.setMuted。
    var onToggleMute: (() -> Void)?

    /// D2：Android 實體鍵。參數是 W3C key 字串（"GoBack"／"GoHome"／"AppSwitch"），
    /// 由 AppModel 綁定到 `client.sendKey`。
    ///
    /// 走選單列而不綁快速鍵是刻意的：⌘ 組合一律不直通給 guest（見 KeyTranslate），
    /// F1–F3 在 macOS 預設是亮度／音量，⌃A／⌃E 在文字欄位有既有語意——每個候選鍵
    /// 都有衝突。選單列零衝突且可被發現。Esc→GoBack 另外由 KeyTranslate 直接處理。
    var onAndroidKey: ((String) -> Void)?

    init(onWake: @escaping () -> Void, onShow: @escaping () -> Void) {
        self.onWake = onWake
        self.onShow = onShow
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🪞"
        statusMenuItem = NSMenuItem(title: "狀態：—", action: nil, keyEquivalent: "")
        gameItem = NSMenuItem(title: "遊戲：—", action: nil, keyEquivalent: "")
        muteItem = NSMenuItem(title: "靜音", action: nil, keyEquivalent: "")
        forceMenu = NSMenu()
        super.init()
        forceMenu.delegate = self

        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "喚醒", action: #selector(wakeTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "顯示視窗", action: #selector(showTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "遊戲模式（全螢幕）", action: #selector(fullScreenTapped),
                     keyEquivalent: "").target = self
        muteItem.action = #selector(muteTapped)
        muteItem.target = self
        menu.addItem(muteItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "返回", action: #selector(backTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "主畫面", action: #selector(homeTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "最近任務", action: #selector(recentsTapped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(gameItem)
        menu.addItem(withTitle: "停用 keymap", action: #selector(disableTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "恢復自動偵測", action: #selector(autoTapped), keyEquivalent: "").target = self
        let forceParent = NSMenuItem(title: "套用 profile", action: nil, keyEquivalent: "")
        forceParent.submenu = forceMenu   // AppKit 自動畫子選單的 ▸ 指示，標題不重複加符號
        menu.addItem(forceParent)
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Mirage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    func updateStatus(_ text: String) { statusMenuItem.title = "狀態：\(text)" }

    /// Task 6：依目前偵測到的 package 與 keymap 是否啟用更新選單列文字。
    func updateGame(package: String?, active: Bool) {
        let pkg = package ?? "—"
        gameItem.title = "遊戲：\(pkg)　\(active ? "[keymap ✓]" : "[直接 tap]")"
    }

    /// 勾選狀態反映目前是否靜音（AppKit 自動畫 ✓）。
    func updateMute(_ muted: Bool) { muteItem.state = muted ? .on : .off }

    /// 每次「套用 profile」子選單要顯示前重新掃描，讓 saveProfile 新存的 profile
    /// 不需重開 App 就會出現——比起只在 init 建一次更貼近「選單即時反映磁碟狀態」。
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === forceMenu else { return }
        forceMenu.removeAllItems()
        for gameId in Self.availableGameIds() {
            let item = NSMenuItem(title: gameId, action: #selector(forceTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = gameId
            forceMenu.addItem(item)
        }
    }

    @objc private func wakeTapped() { onWake() }
    @objc private func showTapped() { onShow() }
    @objc private func fullScreenTapped() { onToggleFullScreen?() }
    @objc private func muteTapped() { onToggleMute?() }
    @objc private func backTapped() { onAndroidKey?("GoBack") }
    @objc private func homeTapped() { onAndroidKey?("GoHome") }
    @objc private func recentsTapped() { onAndroidKey?("AppSwitch") }
    @objc private func disableTapped() { onDisable?() }
    @objc private func autoTapped() { onAuto?() }
    @objc private func forceTapped(_ sender: NSMenuItem) {
        guard let gameId = sender.representedObject as? String else { return }
        onForce?(gameId)
    }

    /// 列舉可用 profile 的 gameId：直接掃描 ProfileStore.standard() 用的目錄
    /// （Application Support/Mirage/profiles/*.json）。刻意不在 ProfileStore 上新增公開
    /// 列舉 API——Task 6 範圍只改本檔，且掃描目錄字串已經是 ProfileStore.standard() 的公開
    /// 行為（同一個 FileManager 位置），不算越權碰 Core。找不到目錄或無檔案時退化為只列
    /// 內建 gameId，維持「選單一定有至少一個可選項」的簡單不變式，不必為空選單開特殊分支。
    private static func availableGameIds() -> [String] {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mirage/profiles", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        let ids = names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        return ids.isEmpty ? ["com.example.game"] : ids
    }
}

private extension NSMenu {
    @discardableResult
    func addItem(withTitle t: String, action: Selector, keyEquivalent k: String) -> NSMenuItem {
        let item = NSMenuItem(title: t, action: action, keyEquivalent: k)
        addItem(item)
        return item
    }
}
