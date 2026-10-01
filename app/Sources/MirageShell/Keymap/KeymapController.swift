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
    private var textMode = false
    private var gamepadDiffer = GamepadSnapshotDiffer()
    private var fallbackGamepad = GamepadFallbackMachine()
    var onCaptureKeyboardKey: (@MainActor (KeyCode) -> Bool)?
    var onCaptureGamepadButton: (@MainActor (GamepadButton) -> Bool)?
    var onAndroidKey: (@MainActor (String) -> Void)?
    var onLoseFocus: (@MainActor () -> Void)?
    func setTextMode(_ on: Bool) {
        guard textMode != on else { return }
        queue.invalidateTextSession()
        releaseEverything()
        pressedModifiers.removeAll()
        textMode = on
    }
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

    /// true = 有作用中 profile。**不含編輯模式**（2026-07-30，D22）。
    ///
    /// 原本是 `engine != nil && !editing`，把兩個語意不同的判斷擠在一個述詞裡：
    /// 「該不該把滑鼠交給引擎」與「該不該把事件送出去」。呼叫端
    /// `MirrorView.Coordinator.sendMouse` 讀它來決定要不要退回直接 tap，於是編輯模式
    /// 反而讓滑鼠直接打進 guest。現在只表達前者，後者由 `Coordinator.isEditing` 負責。
    ///
    /// `AppModel.shouldCapture` 本來就自己寫了 `&& !editing`，游標捕捉行為不受影響。
    var hasProfile: Bool { engine != nil }

    /// 不再收 `guestSize`：`TouchFrame` 的觸點已經是正規化座標，換算成 guest 像素所需的
    /// 實體螢幕解析度由 `EmulatorClient` 從健康探測取得。原本這裡存的是**串流幀尺寸**，
    /// 而那與 guest 實體解析度在本機相差兩倍——P1-c 起所有觸點都偏在左上一半處。
    init(queue: InputQueue, profile: KeymapProfile?) {
        self.queue = queue
        if let profile, !profile.bindings.isEmpty { self.engine = KeymapEngine(profile: profile) }
    }

    /// 進編輯模式時，把所有還按著的直通鍵補送 up。
    ///
    /// 必然觸發路徑：按住 `k`（直通已送出 down）→ 按 ⌘E 進編輯模式
    /// （`MirageScene` 的 `.keyboardShortcut("e", modifiers: .command)`）→ 放開 `k`。
    /// 那個 keyUp 到達時已經在編輯模式，若編輯模式一律不送，guest 的 `k` 就永遠按著。
    /// 補送的位置刻意選在「切換的當下」而不是「keyUp 到達時才判斷」——因為使用者可能
    /// 根本不會在鏡像視窗裡放開（切走視窗、關掉 App），keyUp 未必還會來。
    func setEditing(_ on: Bool) {
        if editing != on { queue.invalidateTextSession() }
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
    /// 換掉或移除 engine 前，先用舊 engine 送出全放開快照，並替所有尚未放開的
    /// 直通鍵補送 up。即使後續 keyUp 沒有投遞，guest 也不會留下按住狀態（D23）。
    /// 編輯期間則略過釋放，避免每次拖動 binding 觸發 reload 都送出多餘快照。
    func reload(_ profile: KeymapProfile?) {
        queue.invalidateTextSession()
        releaseEverything()
        if let profile, !profile.bindings.isEmpty {
            engine = KeymapEngine(profile: profile)
        } else {
            engine = nil
        }
    }

    /// 實體手把與測試控制通道共用的快照入口。
    func handleGamepadSnapshot(_ snapshot: GamepadSnapshot) {
        let events = gamepadDiffer.update(snapshot)
        guard !events.isEmpty else { return }

        if let engine {
            var frame: TouchFrame?
            for event in events {
                if editing, case .buttonDown(let button) = event,
                   onCaptureGamepadButton?(button) == true {
                    continue
                }
                frame = engine.applyGamepad(event)
            }
            emit(frame)
        } else {
            for event in events { dispatchFallback(fallbackGamepad.apply(event)) }
        }
    }

    /// 以外層提供的經過時間推進右搖桿視角或無 profile 拖曳捲動。
    func tickGamepad(dt: Double) {
        guard !editing, !textMode else { return }
        if let engine {
            emit(engine.gamepadLookTick(dt: dt))
        } else {
            dispatchFallback(fallbackGamepad.tick(dt: dt))
        }
    }

    /// 失焦後 keyUp 未必會投遞，立即釋放 guest 端的觸點與直通鍵（D11）。
    func loseFocus() {
        onLoseFocus?()
        queue.invalidateTextSession()
        releaseEverything()
    }

    private func releaseEverything() {
        gamepadDiffer.reset()
        dispatchFallback(fallbackGamepad.cancel())
        // 進入編輯前的 reload 已釋放 guest 觸點；編輯期間 emit 全程被擋，route 也
        // 不接受新的直通 down，所以不會新增待釋放輸入。略過可避免 applyToSession
        // 每拖動一次就因 reload 送出一幀多餘的釋放快照。
        guard !editing else { return }
        // 直接走 queue.touches，不走有 !editing guard 的 emit：與 route 第一分支
        // 相同的不變式是「我們送過 down 的東西一定要送 up」，釋放不交給一般輸出判斷。
        if let engine { queue.touches(engine.releaseAll().touches) }
        for code in passthroughDown { sendKeyToGuest(code, down: false) }
        passthroughDown.removeAll()
    }

    /// 分流（D2）：profile 綁到的鍵走觸控，沒綁到的直通給 guest 鍵盤。
    ///
    /// **為什麼不是「有 profile 就全走觸控」**：指標遊戲幾乎都會有 profile，那樣使用者
    /// 就永遠不能在遊戲的聊天框打字。分流之後 WASD 仍走搖桿，其餘鍵照常送到 guest。
    func handleKeyDown(_ code: KeyCode) { route(code, down: true) }
    func handleKeyUp(_ code: KeyCode) { route(code, down: false) }
    func handleMouseMoved(dx: Double, dy: Double) { emit(engine?.apply(.mouseMove(dx: dx, dy: dy))) }

    private func route(_ code: KeyCode, down: Bool) {
        guard !textMode else { return }
        if down, editing, onCaptureKeyboardKey?(code) == true { return }
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
        guard !textMode else { return }
        for (flag, code) in Self.modifierKeys {
            let isDown = event.modifierFlags.contains(flag)
            let wasDown = pressedModifiers.contains(code)
            guard isDown != wasDown else { continue }
            if isDown {
                pressedModifiers.insert(code)
                if editing, code != .key("Meta"), onCaptureKeyboardKey?(code) == true { continue }
                emit(engine?.apply(.keyDown(code)))
            } else {
                pressedModifiers.remove(code)
                emit(engine?.apply(.keyUp(code)))
            }
        }
    }

    private func emit(_ frame: TouchFrame?) {
        guard let frame, !editing, !textMode else { return }
        queue.touches(frame.touches)
    }

    private func dispatchFallback(_ actions: [GamepadFallbackAction]) {
        for action in actions {
            switch action {
            case .androidKey(let key):
                if let onAndroidKey {
                    onAndroidKey(key)
                } else {
                    queue.key(.key(key), down: true)
                    queue.key(.key(key), down: false)
                }
            case .touchDown(let point), .touchMove(let point):
                queue.tap(nx: point.x, ny: point.y, down: true)
            case .touchUp(let point):
                queue.tap(nx: point.x, ny: point.y, down: false)
            }
        }
    }
}
