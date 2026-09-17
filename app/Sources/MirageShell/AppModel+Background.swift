import AppKit
import Foundation

/// 背景模式（2026-09-17）：只留選單列、手機遙控。設定由 `LaunchPreferences` 記住，
/// Dock 身分在 `AppDelegate.applicationWillFinishLaunching` 設定，遙控在 `start()` 依設定開啟；
/// 這裡負責選單項與啟動時的視窗處理。
extension AppModel {
    func setupBackgroundModeMenu() {
        menuBar?.updateBackgroundMode(launchPreferences.backgroundMode)
        menuBar?.onToggleBackgroundMode = { [weak self] in
            guard let self else { return }
            let on = !self.launchPreferences.backgroundMode
            self.launchPreferences.backgroundMode = on
            self.menuBar?.updateBackgroundMode(on)
        }
    }

    /// `start()` 之前呼叫，只做畫面上的隱藏。生命週期狀態等 `applyBackgroundModeAfterStart` 決定，
    /// 因為這時還不知道遙控開不開得起來，`AppLifecycle` 也還沒建立。
    func hideWindowEarlyForBackgroundMode() {
        guard launchPreferences.backgroundMode else { return }
        (NSApp as NSApplication?)?.windows.first?.orderOut(nil)
    }

    func applyBackgroundModeAfterStart(_ window: NSWindow?) {
        switch LaunchPreferences.windowStepAfterStart(backgroundMode: launchPreferences.backgroundMode,
                                                      remoteStarted: remote != nil) {
        case .keep:
            return
        case .suspendHidden:
            // 走與按紅色按鈕相同的狀態：手機還沒連上就休眠，連上後由 remoteViewerConnected 喚醒。
            window?.orderOut(nil)
            lifecycle?.didHideWindow()
            print("[app] 背景模式：視窗已隱藏，手機遙控已開啟")
        case .reshow:
            lifecycle?.wake(showing: window)
            print("[app] 背景模式：手機遙控沒有開起來，改為顯示視窗")
        }
    }
}
