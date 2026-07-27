import AppKit
import Foundation

/// P1-e fast-follow：視窗焦點恢復時重新判斷游標捕捉。
///
/// **修的是什麼**：`MouseCapture` 從 P1-c 就主動監聽 `didResignKeyNotification`，失去焦點
/// 立即 `release()`——那是「游標陷阱」的解藥。但一直缺對稱的另一半：焦點**回來**時沒有人
/// 重新捕捉。`updateCapture` 原本只在 `loadKeymap`／`toggleEditing`／`applyActivation`
/// 三處被呼叫，所以視窗一旦失焦（alt-tab、Mission Control、進出全螢幕的過場），捕捉就掉了
/// 且不會自動恢復，要等下一次偵測換遊戲才會回來——使用者的體感是「look 突然不動了」。
///
/// P1-e 終審點名這個既有缺口在全螢幕情境下更容易被踩到（進出全螢幕本身就會讓視窗短暫
/// resignKey），故在此補上對稱的另一半。
///
/// **為何放在 AppModel 而不是 MouseCapture**：重新捕捉的條件是 `shouldCapture`
/// （`hasProfile && !editing && keyWindow`），那是 AppModel 的狀態。讓 `MouseCapture`
/// 反向去問 AppModel 會把「機制」和「策略」攪在一起；維持既有分工——`MouseCapture` 只做
/// 捕捉/釋放這件事，何時該捕捉一律由 AppModel 決定。
extension AppModel {
    func setupFocusTracking() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // 與 MouseCapture 的 resign 觀察者同一招：`queue: .main` 保證這個 block 在
            // main run loop 執行（NSWindow 的 key 通知本來就只在主執行緒發送），所以用
            // `MainActor.assumeIsolated` 同步重新宣告隔離，不必 `Task { @MainActor in }`
            // 跳轉——跳轉會延後一個 runloop tick，游標會有一瞬間「還沒抓回來」的空窗。
            MainActor.assumeIsolated {
                guard let self else { return }
                self.mouseCapture.updateCapture(shouldCapture: self.shouldCapture)
            }
        }
    }
}
