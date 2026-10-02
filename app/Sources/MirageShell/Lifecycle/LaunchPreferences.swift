import AppKit
import Foundation

/// 跨啟動記住的使用者選擇（2026-09-17）。與 `PairingTokenStore` 同形：測試用獨立 suite，
/// 不碰使用者本機的設定。
///
/// - `backgroundMode`：下次啟動不開視窗、自動開手機遙控，只留選單列。打勾當下不影響目前狀態。
/// - `speechEnabled`：語音轉文字的開關。之前每次重開都要到選單列再開一次。
/// - `smoothFrames`：降低卡頓，預設開啟；重新開啟 Mirage 後生效。
final class LaunchPreferences {
    static let backgroundModeKey = "mirage.launch.backgroundMode"
    static let speechEnabledKey = "mirage.launch.speechEnabled"
    static let smoothFramesKey = "mirage.display.smoothFrames"
    /// 驗證腳本用來指定這次啟動是否為背景模式（"1"／"0"），不寫回使用者的設定。
    static let backgroundModeOverrideKey = "MIRAGE_BACKGROUND_MODE"
    private let defaults: UserDefaults
    private let backgroundModeOverride: Bool?
    /// 覆寫值無效時的說明，由 `AppModel.start()` 印一次。
    let backgroundModeOverrideProblem: String?

    init(defaults: UserDefaults = .standard,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        let parsed = Self.backgroundModeOverride(environment)
        backgroundModeOverride = parsed.value
        backgroundModeOverrideProblem = parsed.problem
    }

    /// 儲存的設定。只給選單列的勾選與切換用；決定啟動行為一律讀 `effectiveBackgroundMode`，
    /// 否則切換時會把環境變數的值寫進使用者的設定。
    var backgroundMode: Bool {
        get { defaults.bool(forKey: Self.backgroundModeKey) }
        set { defaults.set(newValue, forKey: Self.backgroundModeKey) }
    }

    /// 這次啟動實際採用的背景模式：有環境變數覆寫就用它，否則即時讀儲存的設定。
    var effectiveBackgroundMode: Bool {
        backgroundModeOverride ?? backgroundMode
    }

    static func backgroundModeOverride(_ environment: [String: String]) -> (value: Bool?, problem: String?) {
        guard let raw = environment[backgroundModeOverrideKey] else { return (nil, nil) }
        switch raw {
        case "1": return (true, nil)
        case "0": return (false, nil)
        default: return (nil, "\(backgroundModeOverrideKey)=\(raw) 不是 0 或 1，改用儲存的設定")
        }
    }

    var speechEnabled: Bool {
        get { defaults.bool(forKey: Self.speechEnabledKey) }
        set { defaults.set(newValue, forKey: Self.speechEnabledKey) }
    }

    var smoothFrames: Bool {
        get {
            defaults.object(forKey: Self.smoothFramesKey) == nil
                ? true : defaults.bool(forKey: Self.smoothFramesKey)
        }
        set { defaults.set(newValue, forKey: Self.smoothFramesKey) }
    }

    /// `start()` 完成之後視窗要怎麼處理。背景模式根本不建立視窗，
    /// 這裡只決定之後要不要休眠或把視窗建立並顯示出來。
    enum WindowStep: Equatable {
        /// 一般模式：不動視窗。
        case keep
        /// 遙控已開：走關視窗的路徑進休眠，手機連上時由既有流程喚醒。
        case suspendHidden
        /// 遙控沒開起來：叫回視窗。沒有視窗、手機又連不上，使用者什麼都看不到。
        case reshow
    }

    static func windowStepAfterStart(backgroundMode: Bool, remoteStarted: Bool) -> WindowStep {
        guard backgroundMode else { return .keep }
        return remoteStarted ? .suspendHidden : .reshow
    }

    /// 背景模式（accessory）只讓圖示不出現在 Dock 與 ⌘Tab。點 Dock 圖示叫回視窗由
    /// `AppDelegate.applicationShouldHandleReopen` 負責。
    static func launchActivationPolicy(backgroundMode: Bool) -> NSApplication.ActivationPolicy {
        backgroundMode ? .accessory : .regular
    }

    /// 關掉視窗後要切換的身分；nil 表示不切換（一般模式維持 regular，行為與以前相同）。
    /// 顯示視窗一律先切回 regular，那邊不需要判斷。
    static func policyAfterWindowHidden(backgroundMode: Bool) -> NSApplication.ActivationPolicy? {
        backgroundMode ? .accessory : nil
    }
}
