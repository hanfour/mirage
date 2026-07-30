import AppKit
import MirageCore

/// 橋接鍵鼠事件到 KeymapEngine，輸出多指觸控。無 profile 時退回直接 tap
/// （呼叫端負責——見 MirrorView.Coordinator.sendMouse 的 `hasProfile != true` guard）。
@MainActor
final class KeymapController {
    /// **不是** `any InputInjecting`：直接持有注入器就會回到「每個事件各開一個
    /// unstructured Task」，而那正是 D6——down/up 對調＝guest 永久卡鍵。順序保證由
    /// `InputQueue` 在結構上提供，這裡只負責決定送什麼。
    private let queue: InputQueue
    private var engine: KeymapEngine?
    private var editing = false
    private var pressedModifiers: Set<KeyCode> = []

    /// 已經送出 keyDown、還沒送出對應 keyUp 的直通鍵。
    ///
    /// 存在的理由是一條不變式：**只對「我們曾經送過 down 且尚未送 up」的鍵送 up**。
    /// 沒有這個集合，就只能靠「這顆鍵現在綁不綁」「現在是不是編輯模式」去反推該不該
    /// 送 up——而這兩個條件都會在按住期間改變（⌘E 進編輯、存檔 reload 換 profile），
    /// 一改就 down/up 不成對：down 送了、up 沒送，guest 那顆鍵永遠按著。
    private var passthroughDown: Set<KeyCode> = []

    /// 修飾鍵不會有 keyDown/keyUp（只有 flagsChanged），W3C 對照表見 handleFlagsChanged。
    private static let modifierKeys: [(NSEvent.ModifierFlags, KeyCode)] = [
        (.shift, .key("Shift")), (.control, .key("Control")),
        (.option, .key("Alt")), (.command, .key("Meta")),
    ]

    /// true = 有作用中 profile 且不在編輯模式。呼叫端（MirrorView.Coordinator.sendMouse）
    /// 用它判斷滑鼠點擊要不要退回直接 tap（spec §7 驗收 4：無 profile 不回歸 P1-a 行為）。
    var hasProfile: Bool { engine != nil && !editing }

    /// 不再收 `guestSize`：`TouchFrame` 的觸點已經是正規化座標，換算成 guest 像素所需的
    /// 實體螢幕解析度由 `EmulatorClient` 從健康探測取得。原本這裡存的是**串流幀尺寸**，
    /// 而那與 guest 實體解析度在本機相差兩倍——P1-c 起所有觸點都偏在左上一半處。
    init(queue: InputQueue, profile: KeymapProfile?) {
        self.queue = queue
        if let profile { self.engine = KeymapEngine(profile: profile) }
    }

    /// 進編輯模式時，把所有還按著的直通鍵補送 up。
    ///
    /// 必然觸發路徑：按住 `k`（直通已送出 down）→ 按 ⌘E 進編輯模式
    /// （`MirageScene` 的 `.keyboardShortcut("e", modifiers: .command)`）→ 放開 `k`。
    /// 那個 keyUp 到達時已經在編輯模式，若編輯模式一律不送，guest 的 `k` 就永遠按著。
    /// 補送的位置刻意選在「切換的當下」而不是「keyUp 到達時才判斷」——因為使用者可能
    /// 根本不會在鏡像視窗裡放開（切走視窗、關掉 App），keyUp 未必還會來。
    func setEditing(_ on: Bool) {
        editing = on
        guard on else { return }
        for code in passthroughDown { sendKeyToGuest(code, down: false) }
        passthroughDown.removeAll()
    }

    /// 編輯器存檔後即時生效，不必重啟 app 才套用新 binding；P1-d 啟用接線
    /// （AppModel.applyActivation）也共用同一入口——nil 清空 engine（→ hasProfile==false）。
    /// ADAPTATION（P1-d task-5 brief）：參數改為無 label（`reload(_:)`），對齊 brief 簽名
    /// 與 ActivationDecider 呼叫慣例；唯一既有呼叫端（saveProfile）已同步更新，未新增重複方法。
    ///
    /// **按住期間換 profile，不需要為直通鍵在這裡補償**：`route()` 是先查
    /// `passthroughDown` 再查 `engine.handles`，所以「按住 k 時 k 從未綁變成已綁」的
    /// keyUp 仍然走直通送出 up，不會因為換了 profile 就被引擎吃掉。反向翻轉
    /// （已綁變未綁）也不會冒出一個沒有對應 down 的 up——那顆鍵從來不在
    /// `passthroughDown` 裡。
    ///
    /// **觸點（bound 鍵）這一半沒有對應的補償，是已知缺口（債務表 D23）**：按住 `w`
    /// （綁在搖桿）時呼叫這個函式，舊 engine 連同它的 `pressed={w}` 被整顆丟棄，
    /// guest 端留著一個 `down:true` 的搖桿觸點；之後放開 `w`，新 engine 不認得
    /// （或是 nil）、`w` 也從來不在 `passthroughDown` 裡——`route()` 三段判斷全部
    /// 跳過，連 `emit` 都不會被呼叫，沒有自癒路徑。這不是假設情境：真實觸發路徑是
    /// `AppModel.applyActivation()` 的 `.inactive` 分支（`AppModel.swift:202`，
    /// 遊戲偵測到前景遊戲消失時呼叫 `reload(nil)`）。
    func reload(_ profile: KeymapProfile?) {
        engine = profile.map(KeymapEngine.init(profile:))
    }

    /// 分流（D2）：profile 綁到的鍵走觸控，沒綁到的直通給 guest 鍵盤。
    ///
    /// **為什麼不是「有 profile 就全走觸控」**：指標遊戲幾乎都會有 profile，那樣使用者
    /// 就永遠不能在遊戲的聊天框打字。分流之後 WASD 仍走搖桿，其餘鍵照常送到 guest。
    func handleKeyDown(_ code: KeyCode) { route(code, down: true) }
    func handleKeyUp(_ code: KeyCode) { route(code, down: false) }
    func handleMouseMoved(dx: Double, dy: Double) { emit(engine?.apply(.mouseMove(dx: dx, dy: dy))) }

    private func route(_ code: KeyCode, down: Bool) {
        // 第一順位：已經送出 down 的直通鍵，它的 up 一定要送。
        // 不受編輯模式影響、也不受「這顆鍵現在綁不綁」影響——按住期間使用者可能按了
        // ⌘E，也可能存檔換了 profile 讓這顆鍵變成綁定鍵。任何一種情況下漏掉這個 up，
        // guest 的那顆鍵就永遠按著（比幽靈觸點更糟：整個鍵盤輸入從此都帶著它）。
        if !down, passthroughDown.remove(code) != nil {
            sendKeyToGuest(code, down: false)
            return
        }
        if engine?.handles(code) == true {
            // 引擎一律要跑，編輯模式也不例外：`pressed` 集合必須追得上實體鍵狀態。
            // 若在這裡提早 return，編輯模式期間放開的鍵在引擎裡仍是 pressed，離開
            // 編輯模式後第一個事件就會吐出一個使用者沒按的搖桿方向。送不送得出去
            // 交給 emit 既有的 editing guard——那才是唯一該擋的地方。
            emit(engine?.apply(down ? .keyDown(code) : .keyUp(code)))
            return
        }
        // 直通：編輯模式只擋**新的** down（使用者正在改鍵位，不是在玩）。
        // 對應的 up 由上面第一個分支負責，不會因為這道 guard 而漏掉。
        guard down, !editing else { return }
        passthroughDown.insert(code)
        sendKeyToGuest(code, down: true)
    }

    private func sendKeyToGuest(_ code: KeyCode, down: Bool) {
        queue.key(code, down: down)
    }

    /// 對照前次旗標算出「這次哪個修飾鍵被按下/放開」，換算成 W3C key 名稱後**直接餵引擎**。
    ///
    /// **為什麼修飾鍵刻意不走 `route()`**：`route()` 的職責是把引擎沒綁到的鍵直通給
    /// guest 鍵盤，而修飾鍵單獨送給 guest 沒有意義——Shift/Control/Alt 自己不是字元，
    /// 組字用的 Shift 已經由 `charactersIgnoringModifiers` 反映在字元上（設計 §4.3 明文
    /// 要求修飾鍵維持現狀只餵引擎）。⌘ 更是不能送：Android 的 Meta 是搜尋鍵、長按會叫出
    /// 快速鍵浮層，使用者按 ⌘Tab／⌘Q／⌘E 都會讓 guest 吃到一組 META down/up，直接推翻
    /// `KeyTranslate` 與 README 宣稱的「帶 ⌘ 的組合一律不直通」——`KeyTranslate` 擋住的是
    /// 字元那半邊，⌘ 鍵本身只有這條旁路能擋。
    ///
    /// 引擎仍然要餵：profile 可以把修飾鍵綁成搖桿/tap 鍵，那條路徑照舊有效。
    func handleFlagsChanged(_ event: NSEvent) {
        for (flag, code) in Self.modifierKeys {
            let isDown = event.modifierFlags.contains(flag)
            let wasDown = pressedModifiers.contains(code)
            guard isDown != wasDown else { continue }
            if isDown {
                pressedModifiers.insert(code)
                emit(engine?.apply(.keyDown(code)))
            } else {
                pressedModifiers.remove(code)
                emit(engine?.apply(.keyUp(code)))
            }
        }
    }

    private func emit(_ frame: TouchFrame?) {
        guard let frame, !editing else { return }
        queue.touches(frame.touches)
    }
}
