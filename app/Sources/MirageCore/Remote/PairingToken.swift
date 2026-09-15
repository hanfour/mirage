import Foundation

/// 手機配對用的持久 token（spec 第 5 節）。
///
/// 128-bit 亂數、32 個小寫十六進位字元，放在網址 `?t=` 上。伺服器只在 `GET /` 與兩條
/// WebSocket 升級時比對；比對是常數時間，不讓回應時間洩漏前綴長度。
/// 亂數來源可注入（`randomBytes`），讓測試能給固定位元組而不必 mock `SystemRandomNumberGenerator`。
public struct PairingToken: Sendable, Equatable {
    public static let byteCount = 16
    private static let hexLength = byteCount * 2
    private static let hexDigits = Set("0123456789abcdef")

    public let value: String

    /// 只接受 32 個小寫十六進位字元。大寫、長度不對、非十六進位都回 nil。
    public init?(value: String) {
        guard value.count == Self.hexLength, value.allSatisfy({ Self.hexDigits.contains($0) }) else {
            return nil
        }
        self.value = value
    }

    private init(bytes: [UInt8]) {
        value = bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func generate(randomBytes: (Int) -> [UInt8] = systemRandomBytes) -> PairingToken {
        let bytes = randomBytes(byteCount)
        precondition(bytes.count == byteCount, "randomBytes 必須回傳 \(byteCount) 個位元組")
        return PairingToken(bytes: bytes)
    }

    /// 純決策：有效舊值沿用；缺值、壞值或明確輪替才採用呼叫端提供的新值。
    public static func selected(existing: String?, rotate: Bool, replacement: PairingToken) -> PairingToken {
        if !rotate, let existing, let token = PairingToken(value: existing) { return token }
        return replacement
    }

    public static func systemRandomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    /// 常數時間比對：長度不同直接 false，長度相同時把全部位元組 XOR 後 OR 起來，
    /// 不在第一個不同的位元組提早返回。
    public func matches(_ candidate: String?) -> Bool {
        guard let candidate else { return false }
        let expected = Array(value.utf8)
        let actual = Array(candidate.utf8)
        guard expected.count == actual.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(expected, actual) { difference |= a ^ b }
        return difference == 0
    }
}
