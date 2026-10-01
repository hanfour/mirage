import CoreFoundation
import Foundation

enum TestControlUnit: String, Equatable {
    case points = "pt"
    case normalized = "norm"
}

struct TestControlPoint: Equatable {
    let x: Double
    let y: Double
}

enum TestControlMouseAction: String, Equatable {
    case down
    case drag
    case up
    case click
}

enum TestControlKeyAction: String, Equatable {
    case press
    case down
    case up
}

enum TestControlScrollPhase: Equatable {
    case began
    case changed
    case ended
    case momentumChanged
    case momentumEnded
}

enum TestControlCommand {
    case state
    case mouse(action: TestControlMouseAction, point: TestControlPoint, unit: TestControlUnit)
    case drag(from: TestControlPoint, to: TestControlPoint, steps: Int,
              intervalMilliseconds: Int, unit: TestControlUnit)
    case scroll(point: TestControlPoint, dx: Double, dy: Double, steps: Int,
                intervalMilliseconds: Int, momentum: Int, unit: TestControlUnit)
    case key(keyCode: UInt16, modifiers: [String], action: TestControlKeyAction)
    case titlebar(visible: Bool)
    case fullscreen(on: Bool)
}

enum TestControlProtocolError: Error, LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

enum TestControlProtocol {
    static func decode(_ data: Data) throws -> TestControlCommand {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TestControlProtocolError.invalid("JSON 格式錯誤")
        }
        guard let object = value as? [String: Any] else {
            throw TestControlProtocolError.invalid("請求必須是 JSON 物件")
        }
        let command = try string("cmd", in: object)

        switch command {
        case "state":
            return .state
        case "mouse":
            guard let action = TestControlMouseAction(rawValue: try string("action", in: object)) else {
                throw TestControlProtocolError.invalid("mouse action 必須是 down、drag、up 或 click")
            }
            return .mouse(action: action, point: try point(in: object), unit: try unit(in: object))
        case "drag":
            let steps = try integer("steps", in: object, range: 1...500)
            let interval = try integer("interval_ms", in: object, range: 0...2000)
            guard steps * interval <= 60_000 else {
                throw TestControlProtocolError.invalid("drag 總時間不可超過 60 秒")
            }
            return .drag(from: try nestedPoint("from", in: object),
                         to: try nestedPoint("to", in: object),
                         steps: steps,
                         intervalMilliseconds: interval,
                         unit: try unit(in: object))
        case "scroll":
            let steps = try integer("steps", in: object, range: 1...500)
            let interval = try integer("interval_ms", in: object, range: 0...2000)
            let momentum = object["momentum"] == nil
                ? 0 : try integer("momentum", in: object, range: 0...100)
            guard (steps + momentum + 2) * interval <= 60_000 else {
                throw TestControlProtocolError.invalid("scroll 總時間不可超過 60 秒")
            }
            return .scroll(point: try point(in: object),
                           dx: try number("dx", in: object, range: -10_000...10_000),
                           dy: try number("dy", in: object, range: -10_000...10_000),
                           steps: steps,
                           intervalMilliseconds: interval,
                           momentum: momentum, unit: try unit(in: object))
        case "key":
            let rawCode = try integer("keyCode", in: object, range: 0...127)
            let rawAction = try string("action", in: object)
            guard let action = TestControlKeyAction(rawValue: rawAction) else {
                throw TestControlProtocolError.invalid("key action 必須是 press、down 或 up")
            }
            return .key(keyCode: UInt16(rawCode), modifiers: try modifiers(in: object), action: action)
        case "titlebar":
            return .titlebar(visible: try boolean("visible", in: object))
        case "fullscreen":
            return .fullscreen(on: try boolean("on", in: object))
        default:
            throw TestControlProtocolError.invalid("未知的 cmd：\(command)")
        }
    }

    static func point(_ point: TestControlPoint, unit: TestControlUnit,
                      width: Double, height: Double) throws -> TestControlPoint {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw TestControlProtocolError.invalid("鏡像視窗內容區大小無效")
        }
        let x: Double
        let y: Double
        switch unit {
        case .points:
            x = point.x
            y = point.y
        case .normalized:
            guard (0...1).contains(point.x), (0...1).contains(point.y) else {
                throw TestControlProtocolError.invalid("norm 座標必須介於 0 到 1")
            }
            x = point.x * width
            y = point.y * height
        }
        guard x.isFinite, y.isFinite, (0...width).contains(x), (0...height).contains(y) else {
            throw TestControlProtocolError.invalid("座標超出鏡像視窗內容區")
        }
        return TestControlPoint(x: x, y: y)
    }

    static func successResponse(_ fields: [String: Any] = [:]) -> Data {
        var object = fields
        object["ok"] = true
        return encoded(object)
    }

    static func failureResponse(_ error: String) -> Data {
        encoded(["ok": false, "error": error])
    }

    static func failureResponse(for error: Error) -> Data {
        failureResponse(error.localizedDescription)
    }

    private static func encoded(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    private static func point(in object: [String: Any]) throws -> TestControlPoint {
        let value = TestControlPoint(x: try number("x", in: object, range: 0...100_000),
                                     y: try number("y", in: object, range: 0...100_000))
        let coordinateUnit = try unit(in: object)
        if coordinateUnit == .normalized,
           (!(0...1).contains(value.x) || !(0...1).contains(value.y)) {
            throw TestControlProtocolError.invalid("norm 座標必須介於 0 到 1")
        }
        return value
    }

    private static func nestedPoint(_ key: String, in object: [String: Any]) throws -> TestControlPoint {
        guard let value = object[key] as? [String: Any] else {
            throw TestControlProtocolError.invalid("缺少有效欄位：\(key)")
        }
        let point = TestControlPoint(x: try number("x", in: value, range: 0...100_000),
                                     y: try number("y", in: value, range: 0...100_000))
        return point
    }

    private static func unit(in object: [String: Any]) throws -> TestControlUnit {
        guard let raw = object["unit"] else { return .points }
        guard let value = raw as? String, let unit = TestControlUnit(rawValue: value) else {
            throw TestControlProtocolError.invalid("unit 必須是 pt 或 norm")
        }
        return unit
    }

    private static func modifiers(in object: [String: Any]) throws -> [String] {
        guard let raw = object["modifiers"] else { return [] }
        guard let values = raw as? [String] else {
            throw TestControlProtocolError.invalid("modifiers 必須是字串陣列")
        }
        let allowed: Set<String> = ["cmd", "shift", "option", "control"]
        guard Set(values).count == values.count, values.allSatisfy(allowed.contains) else {
            throw TestControlProtocolError.invalid("modifiers 只接受 cmd、shift、option、control，且不可重複")
        }
        return values
    }

    private static func string(_ key: String, in object: [String: Any]) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else {
            throw TestControlProtocolError.invalid("缺少有效欄位：\(key)")
        }
        return value
    }

    private static func boolean(_ key: String, in object: [String: Any]) throws -> Bool {
        guard let value = object[key] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            throw TestControlProtocolError.invalid("缺少布林欄位：\(key)")
        }
        return value.boolValue
    }

    private static func integer(_ key: String, in object: [String: Any],
                                range: ClosedRange<Int>) throws -> Int {
        let value = try number(key, in: object, range: Double(range.lowerBound)...Double(range.upperBound))
        guard value.rounded(.towardZero) == value else {
            throw TestControlProtocolError.invalid("欄位 \(key) 必須是整數")
        }
        return Int(value)
    }

    private static func number(_ key: String, in object: [String: Any],
                               range: ClosedRange<Double>) throws -> Double {
        guard let value = object[key] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else {
            throw TestControlProtocolError.invalid("缺少數值欄位：\(key)")
        }
        let number = value.doubleValue
        guard number.isFinite, range.contains(number) else {
            throw TestControlProtocolError.invalid("欄位 \(key) 超出範圍")
        }
        return number
    }
}
