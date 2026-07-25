import AppKit
import MirageCore

/// 橋接鍵鼠事件到 KeymapEngine，輸出多指觸控。無 profile 時退回直接 tap
/// （呼叫端負責——見 MirrorView.Coordinator.sendMouse 的 `hasProfile != true` guard）。
@MainActor
final class KeymapController {
    private let client: EmulatorClient
    private var engine: KeymapEngine?
    private var editing = false
    private var guestSize: (w: Int, h: Int)
    private var pressedModifiers: Set<KeyCode> = []

    /// AUTHORIZED FIX（Task 7 終審 Important：觸點座標應採「解碼後的實際幀尺寸」，對齊
    /// MirrorView.Coordinator.sendMouse 的 P1-a AUTHORIZED FIX ——proto 縮放合約 can-be-less，
    /// emulator 實際回傳的幀可能小於請求的串流尺寸）。由呼叫端（Coordinator）注入，讀取
    /// renderer.lastFrameSize；未設定或回傳 nil 時退回 guestSize，語意等同
    /// sendMouse 的 `renderer?.lastFrameSize ?? guestSize`。
    var frameSizeProvider: (@MainActor () -> (w: Int, h: Int))?

    /// 修飾鍵不會有 keyDown/keyUp（只有 flagsChanged），W3C 對照表見 handleFlagsChanged。
    private static let modifierKeys: [(NSEvent.ModifierFlags, KeyCode)] = [
        (.shift, .key("Shift")), (.control, .key("Control")),
        (.option, .key("Alt")), (.command, .key("Meta")),
    ]

    /// true = 有作用中 profile 且不在編輯模式。呼叫端（MirrorView.Coordinator.sendMouse）
    /// 用它判斷滑鼠點擊要不要退回直接 tap（spec §7 驗收 4：無 profile 不回歸 P1-a 行為）。
    var hasProfile: Bool { engine != nil && !editing }

    init(client: EmulatorClient, profile: KeymapProfile?, guestSize: (w: Int, h: Int)) {
        self.client = client
        self.guestSize = guestSize
        if let profile { self.engine = KeymapEngine(profile: profile) }
    }

    func setGuestSize(_ size: (w: Int, h: Int)) { guestSize = size }
    func setEditing(_ on: Bool) { editing = on }

    /// 編輯器存檔後即時生效，不必重啟 app 才套用新 binding；P1-d 啟用接線
    /// （AppModel.applyActivation）也共用同一入口——nil 清空 engine（→ hasProfile==false）。
    /// ADAPTATION（P1-d task-5 brief）：參數改為無 label（`reload(_:)`），對齊 brief 簽名
    /// 與 ActivationDecider 呼叫慣例；唯一既有呼叫端（saveProfile）已同步更新，未新增重複方法。
    func reload(_ profile: KeymapProfile?) {
        engine = profile.map(KeymapEngine.init(profile:))
    }

    func handleKeyDown(_ code: KeyCode) { emit(engine?.apply(.keyDown(code))) }
    func handleKeyUp(_ code: KeyCode) { emit(engine?.apply(.keyUp(code))) }
    func handleMouseMoved(dx: Double, dy: Double) { emit(engine?.apply(.mouseMove(dx: dx, dy: dy))) }

    /// 對照前次旗標算出「這次哪個修飾鍵被按下/放開」，換算成 W3C key 名稱後併入既有
    /// handleKeyDown/handleKeyUp 路徑——同一顆鍵只有一條轉移邏輯，不在這裡分岔複製。
    func handleFlagsChanged(_ event: NSEvent) {
        for (flag, code) in Self.modifierKeys {
            let isDown = event.modifierFlags.contains(flag)
            let wasDown = pressedModifiers.contains(code)
            guard isDown != wasDown else { continue }
            if isDown {
                pressedModifiers.insert(code)
                handleKeyDown(code)
            } else {
                pressedModifiers.remove(code)
                handleKeyUp(code)
            }
        }
    }

    private func emit(_ frame: TouchFrame?) {
        guard let frame, !editing else { return }
        let touches = frame.touches
        // AUTHORIZED FIX（Task 7 終審 Important）：優先用解碼後的實際幀尺寸，退回 guestSize。
        let size = frameSizeProvider?() ?? guestSize
        Task { await client.sendTouches(touches, width: size.w, height: size.h) }
    }
}
