import Foundation
import Testing
@testable import MirageCore

/// D2 活體：把一組固定的鍵送給 guest。
///
/// ⚠️ **本測試自己不做任何斷言，它的綠燈什麼都不證明。**
/// 它看不到 guest 收到什麼——判定在 `scripts/verify_keyboard.sh`，那支腳本一邊跑
/// `adb shell getevent -l` 一邊呼叫本測試，然後比對 evdev 事件。
/// **請跑 `./scripts/verify_keyboard.sh`，不要單獨跑這條測試。**
///
/// 之所以這樣切：Swift 這端沒有便宜的方法讀 guest 的 evdev 流，而
/// 「開個文字框打字看有沒有字」是代理指標——沒出現字可能是鍵沒送到、
/// 焦點不在輸入框、或輸入法沒起來，三種原因看起來一模一樣。
@Suite struct KeyboardLiveTests {
    /// 與 verify_keyboard.sh 的 `EXPECTED` 一一對應。改這裡要同步改那裡。
    ///
    /// `GoHome`／`AppSwitch` 是選單列「主畫面」「最近任務」兩個使用者可見功能的唯一
    /// 傳輸路徑（`MenuBarController` → `AppModel.onAndroidKey` → `sendKey`），先前既沒有
    /// 單元測試也不在這份活體清單裡——三個 Android 實體鍵只驗了 `GoBack` 一個。
    /// 兩者都已在設計文件 §2 的前置實測中送達（`KEY_HOME`／`KEY_APPSELECT`）。
    /// **擺在最後**是刻意的：它們會把 guest 帶離目前畫面，放前面會影響後續鍵的觀察環境。
    static let sequence: [KeyCode] = [
        .key("a"), .key("Enter"), .key("Backspace"),
        .key("GoBack"), .key("GoHome"), .key("AppSwitch"),
    ]

    @Test(.enabled(if: LiveGate.live,
                   "需 MIRAGE_LIVE=1 與真模擬器；**請跑 scripts/verify_keyboard.sh**——單獨跑本測試不會驗證任何事"))
    func sendsKeySequenceToGuest() async throws {
        let client = EmulatorClient()
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)
        try await Task.sleep(for: .seconds(2))          // 等連線與健康探測
        for code in Self.sequence {
            await client.sendKey(code, down: true)
            await client.sendKey(code, down: false)
            try await Task.sleep(for: .milliseconds(120))
        }
        try await Task.sleep(for: .milliseconds(300))
        await client.stop()
    }
}
