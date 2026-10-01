import Foundation

public enum GamepadButton: String, Codable, CaseIterable, Hashable, Sendable {
    case a
    case b
    case x
    case y
    case leftShoulder
    case rightShoulder
    case leftTrigger
    case rightTrigger
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight
    case leftThumbstickButton
    case rightThumbstickButton
    case menu
    case options

    public var displayName: String {
        switch self {
        case .a: "Ⓐ"
        case .b: "Ⓑ"
        case .x: "ⓧ"
        case .y: "Ⓨ"
        case .leftShoulder: "L1"
        case .rightShoulder: "R1"
        case .leftTrigger: "L2"
        case .rightTrigger: "R2"
        case .dpadUp: "↑"
        case .dpadDown: "↓"
        case .dpadLeft: "←"
        case .dpadRight: "→"
        case .leftThumbstickButton: "L3"
        case .rightThumbstickButton: "R3"
        case .menu: "≡"
        case .options: "⧉"
        }
    }
}

public struct GamepadVector: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = Self.unit(x)
        self.y = Self.unit(y)
    }

    public static let zero = GamepadVector(x: 0, y: 0)

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, -1), 1)
    }
}

public struct GamepadSnapshot: Codable, Equatable, Sendable {
    public let buttons: Set<GamepadButton>
    public let leftStick: GamepadVector
    public let rightStick: GamepadVector
    public let leftTrigger: Double
    public let rightTrigger: Double

    public init(buttons: Set<GamepadButton> = [], leftStick: GamepadVector = .zero,
                rightStick: GamepadVector = .zero, leftTrigger: Double = 0,
                rightTrigger: Double = 0) {
        self.buttons = buttons
        self.leftStick = leftStick
        self.rightStick = rightStick
        self.leftTrigger = Self.trigger(leftTrigger)
        self.rightTrigger = Self.trigger(rightTrigger)
    }

    public static let neutral = GamepadSnapshot()

    public var pressedButtons: Set<GamepadButton> {
        var result = buttons
        if leftTrigger > 0.5 { result.insert(.leftTrigger) }
        if rightTrigger > 0.5 { result.insert(.rightTrigger) }
        return result
    }

    private static func trigger(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public enum GamepadEvent: Equatable, Sendable {
    case buttonDown(GamepadButton)
    case buttonUp(GamepadButton)
    case leftStickChanged(GamepadVector)
    case rightStickChanged(GamepadVector)
}

/// 將兩份控制器快照轉成有固定順序的邊緣事件與搖桿變化。
public struct GamepadSnapshotDiffer: Sendable {
    private var previous = GamepadSnapshot.neutral

    public init() {}

    public mutating func update(_ snapshot: GamepadSnapshot) -> [GamepadEvent] {
        let oldButtons = previous.pressedButtons
        let newButtons = snapshot.pressedButtons
        var events: [GamepadEvent] = []

        for button in GamepadButton.allCases where oldButtons.contains(button) && !newButtons.contains(button) {
            events.append(.buttonUp(button))
        }
        for button in GamepadButton.allCases where !oldButtons.contains(button) && newButtons.contains(button) {
            events.append(.buttonDown(button))
        }
        if snapshot.leftStick != previous.leftStick {
            events.append(.leftStickChanged(snapshot.leftStick))
        }
        if snapshot.rightStick != previous.rightStick {
            events.append(.rightStickChanged(snapshot.rightStick))
        }
        previous = snapshot
        return events
    }

    public mutating func reset() {
        previous = .neutral
    }
}

public enum GamepadFallbackAction: Equatable, Sendable {
    case androidKey(String)
    case touchDown(NormPoint)
    case touchMove(NormPoint)
    case touchUp(NormPoint)
}

/// 無 profile 時的返回/主畫面/最近任務與持續拖曳捲動。
public struct GamepadFallbackMachine: Sendable {
    private var buttons: Set<GamepadButton> = []
    private var leftStick = GamepadVector.zero
    private var scrollPoint: NormPoint?
    private var scrollDirection = 0.0

    public init() {}

    public mutating func apply(_ event: GamepadEvent) -> [GamepadFallbackAction] {
        switch event {
        case .buttonDown(let button):
            buttons.insert(button)
            switch button {
            case .b: return [.androidKey("GoBack")]
            case .menu: return [.androidKey("GoHome")]
            case .options: return [.androidKey("AppSwitch")]
            default: break
            }
        case .buttonUp(let button):
            buttons.remove(button)
        case .leftStickChanged(let value):
            leftStick = value
        case .rightStickChanged:
            break
        }
        return updateScrollState()
    }

    public mutating func tick(dt: Double) -> [GamepadFallbackAction] {
        guard let point = scrollPoint, dt.isFinite, dt > 0 else { return [] }
        let nextY = point.y - scrollDirection * 0.6 * dt
        guard nextY < 0 || nextY > 1 else {
            let next = NormPoint.clamped(x: point.x, y: nextY)
            guard next != point else { return [] }
            scrollPoint = next
            return [.touchMove(next)]
        }

        // 長按持續捲動時，手指到達畫面邊緣後從中央開始下一段拖曳。
        scrollPoint = NormPoint(x: 0.5, y: 0.5)
        return [.touchUp(point), .touchDown(NormPoint(x: 0.5, y: 0.5))]
    }

    public mutating func cancel() -> [GamepadFallbackAction] {
        buttons.removeAll()
        leftStick = .zero
        scrollDirection = 0
        guard let point = scrollPoint else { return [] }
        scrollPoint = nil
        return [.touchUp(point)]
    }

    private mutating func updateScrollState() -> [GamepadFallbackAction] {
        let dpad = (buttons.contains(.dpadUp) ? 1.0 : 0.0)
            - (buttons.contains(.dpadDown) ? 1.0 : 0.0)
        let stickY = leftStick.magnitude > 0.15 ? leftStick.y : 0
        let direction = min(max(dpad + stickY, -1), 1)
        let active = direction != 0
        scrollDirection = direction

        if active, scrollPoint == nil {
            let center = NormPoint(x: 0.5, y: 0.5)
            scrollPoint = center
            return [.touchDown(center)]
        }
        if !active, let point = scrollPoint {
            scrollPoint = nil
            return [.touchUp(point)]
        }
        return []
    }
}

private extension GamepadVector {
    var magnitude: Double { (x * x + y * y).squareRoot() }
}
