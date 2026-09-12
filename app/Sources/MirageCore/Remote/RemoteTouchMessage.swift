import CoreFoundation
import Foundation

public enum RemoteTouchPhase: String, Sendable, Equatable, CaseIterable {
    case down, move, up, cancel
}

/// 手機一根手指的一則事件（spec 第 4 節 `/ws/input`）。座標相對於畫面內容區、左上原點、已夾進 0…1。
public struct RemoteTouchMessage: Sendable, Equatable {
    public let pointerId: Int
    public let phase: RemoteTouchPhase
    public let point: NormPoint
    public let time: Double

    public init(pointerId: Int, phase: RemoteTouchPhase, point: NormPoint, time: Double) {
        self.pointerId = pointerId
        self.phase = phase
        self.point = point
        self.time = time
    }

    /// 抬起與取消一律不是 down，不看手機送了什麼別的欄位。
    public var isDown: Bool { phase == .down || phase == .move }
}

public enum RemoteInputMessage: Sendable, Equatable {
    case ping
    case key(KeyCode, time: Double)
    case touch(RemoteTouchMessage)
}

public enum RemoteInputDecodeError: Error, Equatable {
    case notJSON
    case missingField(String)
    case unknownType(String)
    case invalidPointerId
    case invalidCoordinate
    case invalidKey
    case invalidTime
}

/// `/ws/input` 文字訊息 → `RemoteInputMessage`。純函式：不 log、不計數、不拋例外，
/// 由 `RemoteServerCore` 決定怎麼處理失敗（丟棄、計數、節流 log）。
public enum RemoteTouchMessageDecoder {
    private static let pingType = "ping"

    public static func decode(_ text: String) -> Result<RemoteInputMessage, RemoteInputDecodeError> {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any]
        else { return .failure(.notJSON) }
        guard let type = fields["type"] as? String else { return .failure(.missingField("type")) }
        if type == pingType { return .success(.ping) }
        if type == "key" { return navigationKey(fields) }
        guard let phase = RemoteTouchPhase(rawValue: type) else { return .failure(.unknownType(type)) }
        return pointerId(fields).flatMap { id in
            coordinate(fields, "x").flatMap { x in
                coordinate(fields, "y").map { y in
                    .touch(RemoteTouchMessage(pointerId: id, phase: phase,
                                              point: NormPoint.clamped(x: x, y: y),
                                              time: number(fields["t"]) ?? 0))
                }
            }
        }
    }

    /// 按鍵只開放導覽三鍵；時間為必要的有限 JSON 數字，避免誤收布林或字串。
    private static func navigationKey(_ fields: [String: Any]) -> Result<RemoteInputMessage, RemoteInputDecodeError> {
        guard let raw = fields["key"] else { return .failure(.missingField("key")) }
        guard let key = raw as? String, ["GoBack", "GoHome", "AppSwitch"].contains(key)
        else { return .failure(.invalidKey) }
        guard let rawTime = fields["t"] else { return .failure(.missingField("t")) }
        guard let time = number(rawTime) else { return .failure(.invalidTime) }
        return .success(.key(.key(key), time: time))
    }

    private static func pointerId(_ fields: [String: Any]) -> Result<Int, RemoteInputDecodeError> {
        guard let raw = fields["id"] else { return .failure(.missingField("id")) }
        guard let value = number(raw), value.isFinite, value >= 0,
              value == value.rounded(), value <= Double(Int32.max)
        else { return .failure(.invalidPointerId) }
        return .success(Int(value))
    }

    private static func coordinate(_ fields: [String: Any], _ key: String) -> Result<Double, RemoteInputDecodeError> {
        guard let raw = fields[key] else { return .failure(.missingField(key)) }
        guard let value = number(raw), value.isFinite else { return .failure(.invalidCoordinate) }
        return .success(value)
    }

    /// JSON 布林也是 NSNumber；必須排除 CFBoolean，避免 true 被接受為 id=1 或 x=1。
    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite
        else { return nil }
        return value.doubleValue
    }

}
