import AppKit
import MirageCore

/// 選單列常駐：顯示連線/電源狀態，提供喚醒、顯示視窗、退出。
/// P1-d Task 6：加「目前遊戲」狀態列 + 手動 keymap 覆蓋子選單（停用/恢復自動/套用指定 profile）。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let onWake: () -> Void
    private let onShow: () -> Void
    private let statusMenuItem: NSMenuItem
    private let gameItem: NSMenuItem
    private let audioHealthItem: NSMenuItem
    private let muteItem: NSMenuItem
    private let forceMenu: NSMenu
    /// 「切換模擬器」子選單。內容每次展開前由 `instanceEntries` 重算（探索檔隨模擬器起停而變）。
    private let instanceMenu: NSMenu

    /// Task 6：AppModel.startDetection() 綁定這三個回呼到 setOverride(.disabled/.auto/.force(profile))。
    var onDisable: (() -> Void)?
    var onAuto: (() -> Void)?
    var onForce: ((String) -> Void)?

    /// P1-e：AppModel.startLifecycle() 綁定 → NSApp.keyWindow?.toggleFullScreen(nil)。
    var onToggleFullScreen: (() -> Void)?

    /// 模擬器多開（2026-09-12）：AppModel.setupInstanceMenu() 綁定。前者在子選單展開前
    /// 被呼叫、回傳要顯示的列；後者在使用者選了某一台時被呼叫。
    var instanceEntries: (() -> [InstanceMenuEntry])?
    var onSwitchInstance: ((EmulatorInstance) -> Void)?

    /// P1-e：AppModel.startAudio() 綁定 → AudioPlayer.setMuted。
    var onToggleMute: (() -> Void)?

    /// D2：Android 實體鍵。參數是 W3C key 字串（"GoBack"／"GoHome"／"AppSwitch"）。
    ///
    /// 更正（2026-07-30，D6）：原本這裡寫「由 AppModel 綁定到 `client.sendKey`」。
    /// 改綁到 `AppModel.inputQueue` 之後那句已不成立——直接綁 client 正是要修掉的形狀，
    /// 照著它寫的下一個人會重新引入亂序。
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
        audioHealthItem = NSMenuItem(title: "音訊：無法取得（模擬器缺陷）", action: nil, keyEquivalent: "")
        audioHealthItem.isEnabled = false
        audioHealthItem.isHidden = true
        forceMenu = NSMenu()
        instanceMenu = NSMenu()
        instanceMenu.autoenablesItems = false   // 停用與否由 populate 決定，不讓 AppKit 依 action 猜
        super.init()
        forceMenu.delegate = self
        instanceMenu.delegate = self

        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        menu.addItem(audioHealthItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "喚醒", action: #selector(wakeTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "顯示視窗", action: #selector(showTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "遊戲模式（全螢幕）", action: #selector(fullScreenTapped),
                     keyEquivalent: "").target = self
        muteItem.action = #selector(muteTapped)
        muteItem.target = self
        menu.addItem(muteItem)
        let instanceParent = NSMenuItem(title: "切換模擬器", action: nil, keyEquivalent: "")
        instanceParent.submenu = instanceMenu   // 與「套用 profile」同形：AppKit 自己畫 ▸
        menu.addItem(instanceParent)
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

    /// 已知模擬器限制只放在選單內告知，避免打斷遊戲；正常或安靜時不佔版面。
    func updateAudioHealth(_ state: AudioSupplyMonitor.State) {
        audioHealthItem.isHidden = state != .degraded
    }

    /// 兩個子選單都在展開前重算：「套用 profile」掃 profile 目錄、「切換模擬器」掃探索檔。
    /// 兩者都是「選單即時反映磁碟狀態」，不在 init 建一次。
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === instanceMenu {
            Self.populate(instanceMenu: instanceMenu, entries: instanceEntries?() ?? [],
                          target: self, action: #selector(instanceTapped(_:)))
            return
        }
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

    @objc private func instanceTapped(_ sender: NSMenuItem) {
        guard let instance = sender.representedObject as? EmulatorInstance else { return }
        onSwitchInstance?(instance)
    }

    /// 純佈局：entries → NSMenuItem。抽成 static 是為了測試——建 `MenuBarController` 會在
    /// 開發機的選單列放一個狀態列圖示，測試只該碰一個裸的 NSMenu。
    static func populate(instanceMenu menu: NSMenu, entries: [InstanceMenuEntry],
                         target: AnyObject?, action: Selector?) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: entry.isEnabled ? action : nil,
                                  keyEquivalent: "")
            item.target = entry.isEnabled ? target : nil
            item.isEnabled = entry.isEnabled
            item.state = entry.isCurrent ? .on : .off
            item.representedObject = entry.instance
            menu.addItem(item)
        }
    }

    /// 列舉可用 profile 的 gameId：直接掃描 `ProfileStore.standardDirectory()` 指到的目錄
    /// （Application Support/Mirage/profiles/*.json）。
    ///
    /// 更正（2026-07-29，D4）：這裡原本自己重拼一次同一段相對路徑字串，理由是
    /// 「當時 ProfileStore 沒有公開的路徑 API，直接加會越權碰 Core」——D4 為了
    /// seeding（`BuiltInProfiles`）已經把 `ProfileStore.standardDirectory()` 公開，
    /// 前提已經不存在，於是這份複本變成單純的重複定義：兩處各自寫一次同樣的路徑
    /// 遲早會漂移，這個 repo 剛因為 `EmulatorEndpoint` 吃過一次同類型的虧（見
    /// AppModel.swift `client` 的註解）。改成呼叫共用定義，讓路徑只有一份。
    /// 找不到目錄或無檔案時退化為只列內建 gameId，維持「選單一定有至少一個可選項」的
    /// 簡單不變式，不必為空選單開特殊分支。
    private static func availableGameIds() -> [String] {
        let base = ProfileStore.standardDirectory()
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
