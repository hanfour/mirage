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

/// viewer 每秒回報的連線品質；RTT 為毫秒，丟幀為此頁面累積的 seq＋local。
public struct RemoteClientStats: Sendable, Equatable {
    public let rtt: Double
    public let dropped: Int
    public let decodeFps: Double

    public init(rtt: Double, dropped: Int, decodeFps: Double) {
        self.rtt = rtt
        self.dropped = dropped
        self.decodeFps = decodeFps
    }
}

/// 手機頁面可顯示畫面的區域（CSS 像素）與像素密度，Mac 端依此決定串流解析度。
public struct RemoteViewport: Sendable, Equatable {
    public let width: Double
    public let height: Double
    public let scale: Double

    public init(width: Double, height: Double, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
    }
}

public enum RemoteInputMessage: Sendable, Equatable {
    case ping
    case clientStats(RemoteClientStats)
    case key(KeyCode, time: Double)
    case text(String, time: Double)
    case touch(RemoteTouchMessage)
    case touches([RemoteTouchMessage])
    case viewport(RemoteViewport)
}

public enum RemoteInputDecodeError: Error, Equatable {
    case notJSON
    case missingField(String)
    case unknownType(String)
    case invalidPointerId
    case invalidCoordinate
    case invalidKey
    case invalidText
    case invalidTime
    case invalidPoints
    case invalidClientStats
    case invalidViewport
}

/// `/ws/input` 文字訊息 → `RemoteInputMessage`。純函式：不 log、不計數、不拋例外，
/// 由 `RemoteServerCore` 決定怎麼處理失敗（丟棄、計數、節流 log）。
public enum RemoteTouchMessageDecoder {
    public static let maximumTextUTF16Length = 4096
    private static let pingType = "ping"

    public static func decode(_ text: String) -> Result<RemoteInputMessage, RemoteInputDecodeError> {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any]
        else { return .failure(.notJSON) }
        guard let type = fields["type"] as? String else { return .failure(.missingField("type")) }
        if type == "client-stats" { return clientStats(fields) }
        if type == pingType { return .success(.ping) }
        if type == "viewport" { return viewport(fields) }
        if type == "text" { return textCommit(fields) }
        if type == "key" { return navigationKey(fields) }
        if type == "touches" { return batch(fields) }
        let phaseName = type == "touch" ? (fields["phase"] as? String ?? "") : type
        guard let phase = RemoteTouchPhase(rawValue: phaseName) else { return .failure(.unknownType(type)) }
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

    /// 排除 bool、字串、負值與非有限數；丟幀須為 JavaScript 安全整數，轉 Int 不溢位。
    private static func clientStats(_ fields: [String: Any]) -> Result<RemoteInputMessage, RemoteInputDecodeError> {
        guard let rtt = number(fields["rtt"]), rtt >= 0,
              let dropped = number(fields["dropped"]), dropped >= 0,
              dropped <= 9_007_199_254_740_991, dropped == dropped.rounded(),
              let fps = number(fields["decodeFps"]), fps >= 0
        else { return .failure(.invalidClientStats) }
        return .success(.clientStats(RemoteClientStats(rtt: rtt, dropped: Int(dropped), decodeFps: fps)))
    }

    /// 尺寸上限 10000pt、密度上限 8：超出的值只會讓請求撞上像素上限，不如直接當成壞訊息。
    private static func viewport(_ fields: [String: Any]) -> Result<RemoteInputMessage, RemoteInputDecodeError> {
        guard let width = number(fields["width"]), width > 0, width <= 10_000,
              let height = number(fields["height"]), height > 0, height <= 10_000,
              let scale = number(fields["scale"]), scale > 0, scale <= 8
        else { return .failure(.invalidViewport) }
        return .success(.viewport(RemoteViewport(width: width, height: height, scale: scale)))
    }

    private static func batch(_ fields: [String: Any]) -> Result<RemoteInputMessage, RemoteInputDecodeError> {
        guard let time = number(fields["t"]) else { return .failure(.invalidTime) }
        guard let points = fields["points"] as? [[String: Any]], !points.isEmpty,
              points.count <= RemoteTouchIdentifierAllocator.maxActive else { return .failure(.invalidPoints) }
        var messages: [RemoteTouchMessage] = []
        var ids = Set<Int>()
        for point in points {
            var single = point
            single["type"] = "touch"
            single["t"] = time
            guard let data = try? JSONSerialization.data(withJSONObject: single),
                  let text = String(data: data, encoding: .utf8) else { return .failure(.invalidPoints) }
            switch decode(text) {
            case .success(.touch(let message)):
                guard ids.insert(message.pointerId).inserted else { return .failure(.invalidPoints) }
                messages.append(message)
            case .failure(let error): return .failure(error)
            default: return .failure(.invalidPoints)
            }
        }
        return .success(.touches(messages))
    }

    /// 以 UTF-16 單元限制長度，與瀏覽器 String.length 一致，亦限制組合字的負載。
    private static func textCommit(_ fields: [String: Any]) -> Result<RemoteInputMessage, RemoteInputDecodeError> {
        guard let raw = fields["text"] else { return .failure(.missingField("text")) }
        guard let text = raw as? String, !text.isEmpty, text.utf16.count <= maximumTextUTF16Length
        else { return .failure(.invalidText) }
        guard let rawTime = fields["t"] else { return .failure(.missingField("t")) }
        guard let time = number(rawTime) else { return .failure(.invalidTime) }
        return .success(.text(text, time: time))
    }

    /// 按鍵只開放導覽三鍵與 Backspace；時間須為有限 JSON 數字，僅 Backspace 可省略。
    private static func navigationKey(_ fields: [String: Any]) -> Result<RemoteInputMessage, RemoteInputDecodeError> {
        guard let raw = fields["key"] else { return .failure(.missingField("key")) }
        guard let key = raw as? String, ["GoBack", "GoHome", "AppSwitch", "Backspace"].contains(key)
        else { return .failure(.invalidKey) }
        if key == "Backspace", fields["t"] == nil { return .success(.key(.key(key), time: 0)) }
        guard let rawTime = fields["t"] else { return .failure(.missingField("t")) }
        guard let time = number(rawTime) else { return .failure(.invalidTime) }
        return .success(.key(.key(key), time: time))
    }

    private static func pointerId(_ fields: [String: Any]) -> Result<Int, RemoteInputDecodeError> {
        guard let raw = fields["id"] else { return .failure(.missingField("id")) }
        guard let value = number(raw), value.isFinite, value >= Double(Int32.min),
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
