import MirageCore

/// guest 的 Android 實體鍵（W3C key 名稱）。選單列與鏡像視窗快捷鍵都用這裡的值，
/// 只寫一份：兩處各寫字串時，改到一處另一處就會送出不同的鍵，而測試只看得到其中一邊。
/// 模擬器接受這兩個名稱已實測（guest getevent 收到 KEY_VOLUMEUP／KEY_VOLUMEDOWN）。
enum AndroidKey {
    static let volumeUp = "AudioVolumeUp"
    static let volumeDown = "AudioVolumeDown"
}

extension AppModel {
    func setupGuestActions() {
        menuBar?.onAndroidKey = { [weak self] key in self?.sendAndroidKey(key) }
        menuBar?.onTakeScreenshot = { [weak self] in
            Task { @MainActor in await self?.takeScreenshot() }
        }
    }

    func sendAndroidKey(_ w3c: String) {
        inputQueue.key(.key(w3c), down: true)
        inputQueue.key(.key(w3c), down: false)
    }
}
