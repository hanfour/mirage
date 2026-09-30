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
    private let screenshotItem: NSMenuItem
    private let speechItem: NSMenuItem
    private let backgroundModeItem: NSMenuItem
    private let restartSimulatorItem: NSMenuItem
    private let forceMenu: NSMenu
    /// 「切換模擬器」子選單。內容每次展開前由 `instanceEntries` 重算（探索檔隨模擬器起停而變）。
    private let instanceMenu: NSMenu
    /// 「手機遙控」子選單。內容每次展開前由 `remoteEntries` 重算（狀態隨連線而變）。
    private let remoteMenu: NSMenu
    /// 手機遙控（2026-09-12）：AppModel.setupRemoteMenu() 綁定。`remoteEntries` 在子選單展開前
    /// 被呼叫；三個動作分別對應「開啟／關閉」「網址列（複製）」「中斷連線」。
    var remoteEntries: (() -> [RemoteMenuEntry])?
    var onToggleRemote: (() -> Void)?
    var onRotateRemoteToken: (() -> Void)?
    var onDisconnectRemote: (() -> Void)?
    var onCopyRemoteURL: ((String) -> Void)?


    /// Task 6：AppModel.startDetection() 綁定這三個回呼到 setOverride(.disabled/.auto/.force(profile))。
    var onDisable: (() -> Void)?
    var onAuto: (() -> Void)?
    var onForce: ((String) -> Void)?

    /// P1-e：AppModel.startLifecycle() 綁定 → NSApp.keyWindow?.toggleFullScreen(nil)。
    var onToggleFullScreen: (() -> Void)?

    /// 模擬器多開（2026-09-12）：AppModel.setupInstanceMenu() 綁定。前者在子選單展開前
    /// 被呼叫、回傳要顯示的列；後者在使用者選了某一台時被呼叫。
    var instanceEntries: (() -> [InstanceMenuEntry])?
    var onSwitchInstance: ((InstanceEntry) -> Void)?
    var onRestartSimulator: (() -> Void)?
    var onTakeScreenshot: (() -> Void)?
    var canRestartSimulator: (@MainActor () -> Bool)?

    /// P1-e：AppModel.startAudio() 綁定 → AudioPlayer.setMuted。
    var onToggleMute: (() -> Void)?
    var onToggleSpeech: (() -> Void)?
    /// 背景模式（2026-09-17）：記住的設定，下次啟動才生效。
    var onToggleBackgroundMode: (() -> Void)?

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
        screenshotItem = NSMenuItem(title: "截圖（存到桌面）", action: nil, keyEquivalent: "")
        speechItem = NSMenuItem(title: "語音轉文字", action: nil, keyEquivalent: "")
        restartSimulatorItem = NSMenuItem(title: "重新啟動模擬器", action: nil, keyEquivalent: "")
        // 標題寫明「下次啟動」：打勾當下視窗不會消失，不寫清楚會以為沒反應。
        backgroundModeItem = NSMenuItem(title: "背景模式（下次啟動不開視窗、自動開手機遙控）",
                                        action: nil, keyEquivalent: "")
        // 只寫「模擬器缺陷」等於要使用者自己想辦法。D44 的閂鎖已量出唯一的解法：
        // guest 全域音訊停止數秒（實測停 3 秒開始回復、停 8 秒回到 100%）。
        // 換 audio 元素、重載頁面、重開 RPC、換訂閱格式都無效，Mirage 這端做不到。
        audioHealthItem = NSMenuItem(title: "音訊：模擬器停止供應（把出聲的 app 關掉約 8 秒可回復）",
                                     action: nil, keyEquivalent: "")
        audioHealthItem.isEnabled = false
        audioHealthItem.isHidden = true
        forceMenu = NSMenu()
        instanceMenu = NSMenu()
        instanceMenu.autoenablesItems = false
        remoteMenu = NSMenu()
        remoteMenu.autoenablesItems = false   // 停用與否由 populate 決定，不讓 AppKit 依 action 猜
        super.init()
        remoteMenu.delegate = self
        forceMenu.delegate = self
        instanceMenu.delegate = self

        let menu = NSMenu()
        menu.delegate = self
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
        speechItem.action = #selector(speechTapped)
        speechItem.target = self
        menu.addItem(speechItem)
        backgroundModeItem.action = #selector(backgroundModeTapped)
        backgroundModeItem.target = self
        menu.addItem(backgroundModeItem)
        let instanceParent = NSMenuItem(title: "切換模擬器", action: nil, keyEquivalent: "")
        instanceParent.submenu = instanceMenu   // 與「套用 profile」同形：AppKit 自己畫 ▸
        menu.addItem(instanceParent)
        restartSimulatorItem.action = #selector(restartSimulatorTapped)
        restartSimulatorItem.target = self
        restartSimulatorItem.isEnabled = false
        menu.addItem(restartSimulatorItem)
        let remoteParent = NSMenuItem(title: "手機遙控", action: nil, keyEquivalent: "")
        remoteParent.submenu = remoteMenu   // 與「切換模擬器」同形
        menu.addItem(remoteParent)

        menu.addItem(.separator())
        menu.addItem(withTitle: "返回", action: #selector(backTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "主畫面", action: #selector(homeTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "最近任務", action: #selector(recentsTapped), keyEquivalent: "").target = self
        Self.addVolumeItems(to: menu, target: self, action: #selector(volumeTapped(_:)))
        screenshotItem.action = #selector(screenshotTapped)
        screenshotItem.target = self
        menu.addItem(screenshotItem)
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

    /// 不可用時把原因寫進標題並停用，不要只是打勾不會動——使用者要知道為什麼。
    func updateSpeech(on: Bool, unavailableReason: String?) {
        speechItem.state = on ? .on : .off
        speechItem.isEnabled = unavailableReason == nil
        speechItem.title = unavailableReason.map { "語音轉文字：\($0)" } ?? "語音轉文字"
    }

    func updateBackgroundMode(_ on: Bool) { backgroundModeItem.state = on ? .on : .off }

    /// 已知模擬器限制只放在選單內告知，避免打斷遊戲；正常或安靜時不佔版面。
    func updateAudioHealth(_ state: AudioSupplyMonitor.State) {
        audioHealthItem.isHidden = state != .degraded
    }

    /// 子選單展開前重算：profile／模擬器讀磁碟，手機遙控讀目前狀態與最新品質回報。
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let rootMenu = statusItem.menu, menu === rootMenu {
            restartSimulatorItem.isEnabled = canRestartSimulator?() ?? false
        }
        if menu === remoteMenu {
            Self.populate(remoteMenu: remoteMenu, entries: remoteEntries?() ?? RemoteMenu.entries(.off),
                          target: self, toggleAction: #selector(remoteToggleTapped),
                          copyAction: #selector(remoteCopyTapped(_:)),
                          disconnectAction: #selector(remoteDisconnectTapped),
                          rotateAction: #selector(remoteRotateTapped),
                          qrImage: { QRCodeImage.make($0, side: RemoteMenu.qrSide) })
            return
        }

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

    @objc private func speechTapped() { onToggleSpeech?() }
    @objc private func backgroundModeTapped() { onToggleBackgroundMode?() }
    @objc private func backTapped() { onAndroidKey?("GoBack") }
    @objc private func homeTapped() { onAndroidKey?("GoHome") }
    @objc private func recentsTapped() { onAndroidKey?("AppSwitch") }
    @objc private func volumeTapped(_ sender: NSMenuItem) {
        Self.dispatchAndroidKey(sender) { [weak self] key in self?.onAndroidKey?(key) }
    }
    @objc private func screenshotTapped() { onTakeScreenshot?() }
    @objc private func disableTapped() { onDisable?() }
    @objc private func autoTapped() { onAuto?() }
    @objc private func forceTapped(_ sender: NSMenuItem) {
        guard let gameId = sender.representedObject as? String else { return }
        onForce?(gameId)
    }

    @objc private func remoteToggleTapped() { onToggleRemote?() }
    @objc private func remoteRotateTapped() { onRotateRemoteToken?() }
    @objc private func remoteDisconnectTapped() { onDisconnectRemote?() }
    @objc private func remoteCopyTapped(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        onCopyRemoteURL?(url)
    }

    /// 純佈局：entries → NSMenuItem。static 是為了測試（同 `populate(instanceMenu:)` 的理由）。
    /// QR 放 `NSMenuItem.view`（一個 `NSImageView`），不另開視窗：唯一的鏡像視窗由
    /// `MirrorWindowController` 保證，QR 不需要自己的視窗。
    static func populate(remoteMenu menu: NSMenu, entries: [RemoteMenuEntry], target: AnyObject?,
                         toggleAction: Selector?, copyAction: Selector?, disconnectAction: Selector?,
                         rotateAction: Selector? = nil,
                         qrImage: (String) -> NSImage?)
    {
        menu.autoenablesItems = false
        menu.removeAllItems()
        for entry in entries {
            let item: NSMenuItem
            switch entry {
            case .toggle(let title):
                item = NSMenuItem(title: title, action: toggleAction, keyEquivalent: "")
                item.target = target
            case .status(let text):
                item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
            case .url(let url):
                item = NSMenuItem(title: "網址：\(url)（點一下複製）", action: copyAction, keyEquivalent: "")
                item.target = target
                item.representedObject = url
            case .qr(let url):
                item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                let view = NSImageView(frame: NSRect(x: 0, y: 0, width: RemoteMenu.qrSide, height: RemoteMenu.qrSide))
                view.image = qrImage(url)
                view.imageScaling = .scaleNone
                item.view = view
            case .rotateToken(let enabled):
                item = NSMenuItem(title: enabled ? RemoteMenu.rotateTokenTitle : RemoteMenu.overriddenTokenTitle,
                                 action: enabled ? rotateAction : nil, keyEquivalent: "")
                item.target = enabled ? target : nil
                item.isEnabled = enabled
            case .disconnect(let enabled):
                item = NSMenuItem(title: RemoteMenu.disconnectTitle, action: enabled ? disconnectAction : nil,
                                  keyEquivalent: "")
                item.target = enabled ? target : nil
                item.isEnabled = enabled
            }
            menu.addItem(item)
        }
    }

    @objc private func instanceTapped(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? InstanceEntry else { return }
        onSwitchInstance?(entry)
    }

    @objc private func restartSimulatorTapped() {
        onRestartSimulator?()
    }

    static func addVolumeItems(to menu: NSMenu, target: AnyObject?, action: Selector?) {
        for (title, key) in [("音量調高", AndroidKey.volumeUp), ("音量調低", AndroidKey.volumeDown)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = key
            menu.addItem(item)
        }
    }

    static func dispatchAndroidKey(_ sender: NSMenuItem, onAndroidKey: (String) -> Void) {
        guard let key = sender.representedObject as? String else { return }
        onAndroidKey(key)
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
            item.representedObject = entry.entry
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
