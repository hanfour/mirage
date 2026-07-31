import AppKit
import Foundation

/// P1-e：全螢幕遊戲模式狀態追蹤與選單列控制。
///
/// 觀察 NSWindow 的 didEnterFullScreen / didExitFullScreen 通知，驅動 AppModel.isFullScreen
/// 屬性；同時綁定選單列「遊戲模式（全螢幕）」項目到系統全螢幕切換。
extension AppModel {
    /// 綁定選單列與系統通知：從選單列觸發全螢幕切換，並追蹤全螢幕狀態。
    /// 兩個通知都不帶我們需要的資訊，故忽略 Notification 本體（它非 Sendable，
    /// 捕捉進 @Sendable 閉包會觸發 strict-concurrency 警告）。
    func setupFullScreen() {
        menuBar?.onToggleFullScreen = { (NSApp as NSApplication?)?.keyWindow?.toggleFullScreen(nil) }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isFullScreen = true }
        }
        center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isFullScreen = false }
        }
    }
}
