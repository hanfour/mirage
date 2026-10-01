import Foundation

public struct TouchSpec: Sendable, Equatable {
    public let identifier: Int
    public let point: NormPoint
    public let down: Bool
    /// 僅遠端批次的 move 設定；本機快照沒有 phase，不能推測為 move。
    public let isRemoteMove: Bool

    public init(identifier: Int, point: NormPoint, down: Bool, isRemoteMove: Bool = false) {
        self.identifier = identifier
        self.point = point
        self.down = down
        self.isRemoteMove = isRemoteMove
    }
}

public struct TouchFrame: Sendable, Equatable {
    public let touches: [TouchSpec]
}

public enum InputEvent: Sendable, Equatable {
    case keyDown(KeyCode)
    case keyUp(KeyCode)
    case mouseMove(dx: Double, dy: Double)
}

/// 鍵位映射引擎：離散事件 → 當前多指觸點快照。純轉移（無 IO），可窮舉測試。
public final class KeymapEngine {
    private struct JoystickSlot { let id: Int; let up, down, left, right: KeyCode; let center: NormPoint; let radius: Double }
    private struct TapSlot { let id: Int; let key: KeyCode; let at: NormPoint; let gamepad: GamepadButton? }
    private struct LookSlot { let id: Int; let activation: KeyCode?; let sensitivity: Double }

    private let joystick: JoystickSlot?
    private let taps: [TapSlot]
    private let look: LookSlot?

    private var pressed: Set<KeyCode> = []
    private var pressedGamepad: Set<GamepadButton> = []
    private var leftStick = GamepadVector.zero
    private var rightStick = GamepadVector.zero
    private var lookPoint = NormPoint(x: 0.5, y: 0.5)
    private var mouseLookDown = false

    public init(profile: KeymapProfile) {
        var next = 1
        var js: JoystickSlot?
        var tapSlots: [TapSlot] = []
        var lk: LookSlot?
        for b in profile.bindings {
            switch b {
            case .joystick(let u, let d, let l, let r, let c, let rad):
                js = JoystickSlot(id: next, up: u, down: d, left: l, right: r, center: c, radius: rad); next += 1
            case .tap(let key, let at, let gamepad):
                tapSlots.append(TapSlot(id: next, key: key, at: at, gamepad: gamepad)); next += 1
            case .look(let act, let sens):
                lk = LookSlot(id: next, activation: act, sensitivity: sens); next += 1
            }
        }
        joystick = js; taps = tapSlots; look = lk
    }

    public func apply(_ event: InputEvent) -> TouchFrame {
        switch event {
        case .keyDown(let k):
            // 沒綁到的鍵在這裡什麼都不做：呼叫端（KeymapController.route）負責把它
            // 直通給 guest 鍵盤（D2）。這裡原本有一個 `unmappedCount` 計數器，
            // 但全庫沒有任何生產碼讀它，而且它的增量由修飾鍵主導——profile 通常不綁
            // Shift／Control／Alt／Meta，而 handleFlagsChanged 每按一次就餵進來一次，
            // 所以它數的其實是「按了幾次修飾鍵」。沒有消費端又沒有意義，已於 D20 移除。
            if handles(k) { pressed.insert(k) }
        case .keyUp(let k):
            pressed.remove(k)
            releaseLookIfGateClosed(for: k)
        case .mouseMove(let dx, let dy):
            if let look, isLookGateOpen(look) {
                lookPoint = NormPoint.clamped(x: lookPoint.x + dx * look.sensitivity / 1000,
                                              y: lookPoint.y + dy * look.sensitivity / 1000)
                mouseLookDown = true
            }
        }
        return snapshot()
    }

    /// 套用一個由兩份快照差異產生的手把事件。
    public func applyGamepad(_ event: GamepadEvent) -> TouchFrame {
        switch event {
        case .buttonDown(let button): pressedGamepad.insert(button)
        case .buttonUp(let button): pressedGamepad.remove(button)
        case .leftStickChanged(let value): leftStick = value
        case .rightStickChanged(let value): rightStick = value
        }
        return snapshot()
    }

    /// 右搖桿視角每一個外層計時週期呼叫一次。右搖桿不受 look.activation 限制。
    public func gamepadLookTick(dt: Double) -> TouchFrame? {
        guard let look, rightStick.magnitude > 0.15, dt.isFinite, dt > 0 else { return nil }
        // 以既有滑鼠 sensitivity 換算合成像素位移，讓滿偏的正規化速度約為半個畫面/秒。
        let pixelsPerSecond = 500 / look.sensitivity
        let dx = rightStick.x * pixelsPerSecond * dt
        let dy = -rightStick.y * pixelsPerSecond * dt
        lookPoint = NormPoint.clamped(x: lookPoint.x + dx * look.sensitivity / 1000,
                                      y: lookPoint.y + dy * look.sensitivity / 1000)
        return snapshot()
    }

    /// 清空所有按鍵狀態，回傳對應的「全放開」快照。
    /// lookPoint 是視角的當前位置，不是按鍵狀態，因此刻意保留，避免重新取得焦點
    /// 或切換 profile 的釋放過程讓視角瞬間跳回畫面正中。
    public func releaseAll() -> TouchFrame {
        pressed.removeAll()
        pressedGamepad.removeAll()
        leftStick = .zero
        rightStick = .zero
        mouseLookDown = false
        return snapshot()
    }

    // MARK: - 公開述詞

    /// 這顆鍵有沒有被 profile 綁住。
    ///
    /// 公開是為了讓 `KeymapController` 能分流：綁到的走觸控，沒綁到的直通給 guest
    /// 鍵盤（D2）。刻意**不改 `apply` 的簽章**去回傳「有沒有吃掉」——那會動到所有既有
    /// 引擎測試，而這裡要的只是一個布林值，述詞本來就已經存在。
    ///
    /// 命名從 `isMapped` 改為 `handles`：呼叫端讀起來是問句
    /// （`engine.handles(code)`），比 `isMapped` 更貼近它在分流點的角色。
    public func handles(_ k: KeyCode) -> Bool {
        if let j = joystick, [j.up, j.down, j.left, j.right].contains(k) { return true }
        if taps.contains(where: { $0.key == k }) { return true }
        if let look, look.activation == k { return true }
        return false
    }

    // MARK: - 私有

    /// look 是否允許套用滑鼠位移：activation=nil 表 always-on，否則需啟動鍵被按住。
    private func isLookGateOpen(_ look: LookSlot) -> Bool {
        look.activation.map { pressed.contains($0) } ?? true
    }

    /// 放開啟動鍵時若 gate 因此關閉，收回 look 觸點——避免殘留 down=true 的幽靈觸點。
    private func releaseLookIfGateClosed(for releasedKey: KeyCode) {
        guard let look, let activation = look.activation, activation == releasedKey else { return }
        mouseLookDown = false
    }

    private func snapshot() -> TouchFrame {
        var out: [TouchSpec] = []
        if let j = joystick {
            let stickActive = leftStick.magnitude > 0.15
            let keyboard = JoystickMath.vector(up: pressed.contains(j.up), down: pressed.contains(j.down),
                                               left: pressed.contains(j.left), right: pressed.contains(j.right))
            let dx = stickActive ? leftStick.x : keyboard.dx
            let dy = stickActive ? -leftStick.y : keyboard.dy
            let active = stickActive || keyboard.dx != 0 || keyboard.dy != 0
            // D12：`center ± radius` 會越界（圓心貼邊 + 大半徑）。夾取放在這裡而不是
            // `validated()`：載入期拒絕會讓使用者既有的 profile 突然消失（見計畫的偏離說明）。
            let p = NormPoint.clamped(x: j.center.x + dx * j.radius,
                                      y: j.center.y + dy * j.radius)
            out.append(TouchSpec(identifier: j.id, point: active ? p : j.center, down: active))
        }
        for t in taps {
            let keyDown = pressed.contains(t.key)
            let gamepadDown = t.gamepad.map(pressedGamepad.contains) ?? false
            out.append(TouchSpec(identifier: t.id, point: t.at, down: keyDown || gamepadDown))
        }
        if let look {
            let stickDown = rightStick.magnitude > 0.15
            out.append(TouchSpec(identifier: look.id, point: lookPoint,
                                 down: mouseLookDown || stickDown))
        }
        return TouchFrame(touches: out)
    }
}

private extension GamepadVector {
    var magnitude: Double { (x * x + y * y).squareRoot() }
}
