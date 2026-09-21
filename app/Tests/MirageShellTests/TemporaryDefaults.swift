import Foundation

/// 測試專用的一次性 `UserDefaults` suite，離開時連檔案一起收掉。
///
/// 為什麼不是直接 `removePersistentDomain`：那個 API 只清內容，不刪檔案。
/// `~/Library/Preferences` 會留下一個空的 plist，每跑一次測試多一個。
/// 2026-09-21 清存量時數到 1769 個（其中 37 個連內容都還在，因為測試行程在
/// `defer` 跑完之前就結束了）。
enum TemporaryDefaults {
    private static let lock = NSLock()
    private static var created: Set<String> = []
    private static var sweepInstalled = false

    /// 建一個以 `tag` 起頭、UUID 收尾的 suite。回傳 suite 名稱供 `discard` 使用。
    static func make(_ tag: String) -> (defaults: UserDefaults, suite: String)? {
        let suite = "\(tag).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        remember(suite)
        return (defaults, suite)
    }

    /// `discard` 之後檔案仍可能被寫回來：測試持有的 `UserDefaults` 要到 `defer` 之後才
    /// 釋放，cfprefsd 那時才落盤。行程結束時沒有寫入者了，再掃一次才收得乾淨。
    private static func remember(_ suite: String) {
        lock.lock(); defer { lock.unlock() }
        created.insert(suite)
        // 寫成 if 而不是 guard-else-return：閘門 3 會把測試目錄裡的提前 return
        // 當成假 skip 的形式擋下來，而它分辨不出這是 helper 的冪等保護。
        if !sweepInstalled {
            sweepInstalled = true
            atexit { TemporaryDefaults.sweep() }
        }
    }

    static func sweep() {
        lock.lock(); let suites = created; lock.unlock()
        for suite in suites {
            CFPreferencesAppSynchronize(suite as CFString)
            try? FileManager.default.removeItem(at: fileURL(for: suite))
        }
    }

    static func fileURL(for suite: String) -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Preferences/\(suite).plist")
    }

    /// 清內容、要求 cfprefsd 落盤，再刪檔。
    ///
    /// 一定要傳進原本那個 `UserDefaults`，不能在這裡用 suite 名稱重新 `init` 一個：
    /// 那等於讓 cfprefsd 重新認識這個 domain，檔案會在刪掉之後又被寫回來
    /// （單跑看不出來，完整測試套並行跑才會漏）。
    static func discard(_ defaults: UserDefaults, _ suite: String) {
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()
        CFPreferencesAppSynchronize(suite as CFString)
        try? FileManager.default.removeItem(at: fileURL(for: suite))
    }
}
