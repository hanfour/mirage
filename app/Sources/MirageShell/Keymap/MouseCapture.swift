import AppKit
import CoreGraphics

/// look 模式游標捕捉：隱藏游標 + 解除滑鼠與游標關聯（取 raw delta）。
/// 呼叫端負責在編輯模式開啟、或無 profile 時呼叫 release()；deinit 是最後防線，
/// 確保就算忘了呼叫，物件消失時游標狀態也不會卡在「已捕捉」。
///
/// Task 7 fast-follow（P1-c 終審 Important：游標陷阱）：P1-c 版本無視窗焦點 gating，
/// profile 一載入就 app-wide 捕捉，若 app 不在前景（alt-tab 切走）使用者會被鎖住游標、
/// 只剩 ⌘E/quit 能逃脫。修法：呼叫端改用 `updateCapture(shouldCapture:)`（見
/// `AppModel.swift`）依「視窗是否為 key window」等條件決定捕捉與否；本類另外主動監聽
/// `NSWindow.didResignKeyNotification`——失去 key window（alt-tab、其他 app 搶焦點）時
/// 立即 release()，不必等呼叫端下次呼叫，把「游標陷阱」的視窗補起來。
@MainActor
final class MouseCapture {
    private(set) var captured = false
    // ADAPTATION：型別是 `nonisolated(unsafe)` 而非單純 `private var`——deinit 在本專案
    // 的 Swift 5 語言模式下是 nonisolated（見下方 deinit 的說明），而 `NSObjectProtocol`
    // 不是 Sendable，編譯器會擋下「nonisolated deinit 讀取 MainActor-isolated 且非
    // Sendable 型別欄位」（`captured: Bool` 因為是 Sendable 型別所以豁免，不用加這個標註）。
    // 這顆權杖只在 init（MainActor）寫入一次、deinit（物件沒有其他持有者時）讀一次，
    // 不存在真正的資料競爭，`nonisolated(unsafe)` 如實反映「編譯器查不出來但實際安全」。
    private nonisolated(unsafe) var resignObserver: NSObjectProtocol?

    init() {
        // ADAPTATION：NotificationCenter 的 block-based observer 本身不是 MainActor-isolated
        // closure（block 型別是 @Sendable (Notification) -> Void），但 `release()` 是
        // MainActor-isolated 方法。跟 P1-b ClipboardWatcher.start() 的 Timer callback
        // 同一招：`queue: .main` 保證這個 block 一定排進 main run loop 執行（NSWindow
        // 的 didResignKeyNotification 本來就只會在主執行緒發送），所以用
        // `MainActor.assumeIsolated` 同步重新宣告隔離是安全的，不需要額外 `Task { @MainActor in }`
        // 跳轉（跳轉會讓 release() 延後一個 runloop tick，游標會有一瞬間的「還沒放開」空窗）。
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.release() }
        }
    }

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

    /// 取代呼叫端原本無條件的 `capture()`：`shouldCapture` 為 true 才捕捉，否則釋放。
    /// `capture()`/`release()` 本身已用 `captured` guard 冪等，這裡不必重複判斷，
    /// 呼叫端（AppModel）可以每次狀態變動就無腦呼叫，不必自己記上一次的捕捉狀態。
    func updateCapture(shouldCapture: Bool) {
        if shouldCapture { capture() } else { release() }
    }

    deinit {
        // ADAPTATION（沿用 P1-c 既有 deinit 寫法，Task 7 補上移除 observer）：本專案的
        // Swift 5 語言模式下，@MainActor 類別的 deinit 是 nonisolated——讀寫 `captured`
        // （Sendable 的 Bool）沒問題，但讀 `resignObserver`（非 Sendable 的
        // NSObjectProtocol）需要上面宣告時加 `nonisolated(unsafe)` 才編得過（見該欄位
        // 註解）。deinit 本身不需要跳到 MainActor：`removeObserver`/CG 函式/NSCursor
        // 這幾支呼叫都不會被其他執行緒同時搶著呼叫（deinit 執行時已經沒有其他持有者）。
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        if captured {
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
    }
}
