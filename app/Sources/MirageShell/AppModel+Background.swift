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

    /// `startLifecycle()` 最後呼叫。背景模式沒有建立視窗，這裡決定要休眠還是把視窗叫出來。
    func applyBackgroundModeAfterStart() {
        guard !instanceManagerPresentation.setupVisible else { return }
        switch LaunchPreferences.windowStepAfterStart(backgroundMode: launchPreferences.effectiveBackgroundMode,
                                                      remoteStarted: remote != nil) {
        case .keep:
            return
        case .suspendHidden:
            // 與按紅色按鈕相同的狀態：手機還沒連上就休眠，連上後由 remoteViewerConnected 喚醒。
            lifecycle?.didHideWindow()
            print("[app] 背景模式：未建立視窗，手機遙控已開啟")
        case .reshow:
            lifecycle?.wake(showing: windowController.window())
            print("[app] 背景模式：手機遙控沒有開起來，改為顯示視窗")
        }
    }
}
