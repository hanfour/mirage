import Foundation

public struct TouchSpec: Sendable, Equatable {
    public let identifier: Int
    public let point: NormPoint
    public let down: Bool
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
    private struct TapSlot { let id: Int; let key: KeyCode; let at: NormPoint }
    private struct LookSlot { let id: Int; let activation: KeyCode?; let sensitivity: Double }

    private let joystick: JoystickSlot?
    private let taps: [TapSlot]
    private let look: LookSlot?

    private var pressed: Set<KeyCode> = []
    private var lookPoint = NormPoint(x: 0.5, y: 0.5)
    private var lookDown = false
    public private(set) var unmappedCount = 0

    public init(profile: KeymapProfile) {
        var next = 1
        var js: JoystickSlot?
        var tapSlots: [TapSlot] = []
        var lk: LookSlot?
        for b in profile.bindings {
            switch b {
            case .joystick(let u, let d, let l, let r, let c, let rad):
                js = JoystickSlot(id: next, up: u, down: d, left: l, right: r, center: c, radius: rad); next += 1
            case .tap(let key, let at):
                tapSlots.append(TapSlot(id: next, key: key, at: at)); next += 1
            case .look(let act, let sens):
                lk = LookSlot(id: next, activation: act, sensitivity: sens); next += 1
            }
        }
        joystick = js; taps = tapSlots; look = lk
    }

    public func apply(_ event: InputEvent) -> TouchFrame {
        switch event {
        case .keyDown(let k):
            if isMapped(k) { pressed.insert(k) } else { unmappedCount += 1 }
        case .keyUp(let k):
            pressed.remove(k)
            releaseLookIfGateClosed(for: k)
        case .mouseMove(let dx, let dy):
            if let look, isLookGateOpen(look) {
                lookPoint = clamp(NormPoint(x: lookPoint.x + dx * look.sensitivity / 1000,
                                            y: lookPoint.y + dy * look.sensitivity / 1000))
                lookDown = true
            }
        }
        return snapshot()
    }

    // MARK: - 私有

    private func isMapped(_ k: KeyCode) -> Bool {
        if let j = joystick, [j.up, j.down, j.left, j.right].contains(k) { return true }
        if taps.contains(where: { $0.key == k }) { return true }
        if let look, look.activation == k { return true }
        return false
    }

    /// look 是否允許套用滑鼠位移：activation=nil 表 always-on，否則需啟動鍵被按住。
    private func isLookGateOpen(_ look: LookSlot) -> Bool {
        look.activation.map { pressed.contains($0) } ?? true
    }

    /// 放開啟動鍵時若 gate 因此關閉，收回 look 觸點——避免殘留 down=true 的幽靈觸點。
    private func releaseLookIfGateClosed(for releasedKey: KeyCode) {
        guard let look, let activation = look.activation, activation == releasedKey else { return }
        lookDown = false
    }

    private func snapshot() -> TouchFrame {
        var out: [TouchSpec] = []
        if let j = joystick {
            let v = JoystickMath.vector(up: pressed.contains(j.up), down: pressed.contains(j.down),
                                        left: pressed.contains(j.left), right: pressed.contains(j.right))
            let active = v.dx != 0 || v.dy != 0
            let p = NormPoint(x: j.center.x + v.dx * j.radius, y: j.center.y + v.dy * j.radius)
            out.append(TouchSpec(identifier: j.id, point: active ? p : j.center, down: active))
        }
        for t in taps {
            out.append(TouchSpec(identifier: t.id, point: t.at, down: pressed.contains(t.key)))
        }
        if let look {
            out.append(TouchSpec(identifier: look.id, point: lookPoint, down: lookDown))
        }
        return TouchFrame(touches: out)
    }

    private func clamp(_ p: NormPoint) -> NormPoint {
        NormPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }
}
