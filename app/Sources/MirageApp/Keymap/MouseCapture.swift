import AppKit
import CoreGraphics

/// look 模式游標捕捉：隱藏游標 + 解除滑鼠與游標關聯（取 raw delta）。
/// 呼叫端負責在編輯模式開啟、或無 profile 時呼叫 release()；deinit 是最後防線，
/// 確保就算忘了呼叫，物件消失時游標狀態也不會卡在「已捕捉」。
/// pending-human：視窗失焦（resignKey）時的自動 release 需要 GUI 驗證手感，本任務先以
/// 明確的 capture()/release() 呼叫點（見 MirageApp.AppModel）涵蓋主要情境。
@MainActor
final class MouseCapture {
    private(set) var captured = false

    func capture() {
        guard !captured else { return }
        CGAssociateMouseAndMouseCursorPosition(0)   // 解除關聯 → mouseMoved 給 raw delta
        NSCursor.hide()
        captured = true
    }

    func release() {
        guard captured else { return }
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        captured = false
    }

    deinit {
        // ADAPTATION（見下方建置驗證）：deinit 是否能直接呼叫 NSCursor 視實際 SDK
        // 的 actor-isolation 標註而定；若編譯器回報 isolation 錯誤，退回只呼叫
        // CGAssociateMouseAndMouseCursorPosition（nonisolated C 函式），詳見 task-7-report.md。
        if captured {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
    }
}
