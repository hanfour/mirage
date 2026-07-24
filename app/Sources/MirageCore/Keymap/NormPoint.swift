import Foundation

/// 正規化座標（0–1，左上原點對齊 guest）。越界由 isValid 暴露，載入期拒絕。
public struct NormPoint: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }

    public var isValid: Bool { (0...1).contains(x) && (0...1).contains(y) }

    /// 換算為 guest 像素（呼叫端傳實際幀尺寸——沿用 P1-a 的實際幀尺寸換算）。
    public func guestPixel(width: Int, height: Int) -> (x: Int, y: Int) {
        (Int((x * Double(width)).rounded()), Int((y * Double(height)).rounded()))
    }
}
