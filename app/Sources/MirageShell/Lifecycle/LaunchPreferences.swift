import AppKit
import Foundation

/// 跨啟動記住的使用者選擇（2026-09-17）。與 `PairingTokenStore` 同形：測試用獨立 suite，
/// 不碰使用者本機的設定。
///
/// - `backgroundMode`：下次啟動不開視窗、自動開手機遙控，只留選單列。打勾當下不影響目前狀態。
/// - `speechEnabled`：語音轉文字的開關。之前每次重開都要到選單列再開一次。
final class LaunchPreferences {
    static let backgroundModeKey = "mirage.launch.backgroundMode"
    static let speechEnabledKey = "mirage.launch.speechEnabled"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var backgroundMode: Bool {
        get { defaults.bool(forKey: Self.backgroundModeKey) }
        set { defaults.set(newValue, forKey: Self.backgroundModeKey) }
    }

    var speechEnabled: Bool {
        get { defaults.bool(forKey: Self.speechEnabledKey) }
        set { defaults.set(newValue, forKey: Self.speechEnabledKey) }
    }

    /// `start()` 完成之後視窗要怎麼處理。視窗在 `start()` 之前已經先藏起來（縮短露出時間），
    /// 這裡只決定之後要不要休眠或叫回來。
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

    /// 背景模式不在 Dock 與 ⌘Tab 出現。在 Dock 點圖示會讓 SwiftUI 把隱藏的視窗叫回來。
    static func launchActivationPolicy(backgroundMode: Bool) -> NSApplication.ActivationPolicy {
        backgroundMode ? .accessory : .regular
    }

    /// 關掉視窗後要切換的身分；nil 表示不切換（一般模式維持 regular，行為與以前相同）。
    /// 顯示視窗一律先切回 regular，那邊不需要判斷。
    static func policyAfterWindowHidden(backgroundMode: Bool) -> NSApplication.ActivationPolicy? {
        backgroundMode ? .accessory : nil
    }
}
