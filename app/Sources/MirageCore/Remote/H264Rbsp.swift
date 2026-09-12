import Foundation

/// SPS 解析與改寫共用的錯誤。改寫失敗時呼叫端（`H264AccessUnitPacker`）保留原 SPS，
/// 手機仍能解碼，只是回到未改寫的 170 ms 延遲；不拋到編碼迴圈外。
public enum H264SpsError: Error, Equatable {
    case notSps
    case truncated
    case oversizedExpGolomb
    case invalidEmulationPrevention
    case invalidField(String)
    case invalidTrailingBits
}

/// RBSP 位元組層：emulation prevention（7.4.1）與 Exp-Golomb（9.1）的純函式。
public enum H264Rbsp {
    private static let preventionByte: UInt8 = 3

    /// `00 00 03` → `00 00`。`03` 之後必須還有一個位元組且 ≤ 3，否則這不是 prevention byte。
    public static func unescape(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for (i, b) in bytes.enumerated() {
            if zeros == 2, b == preventionByte {
                guard i + 1 < bytes.count, bytes[i + 1] <= preventionByte else {
                    throw H264SpsError.invalidEmulationPrevention
                }
                zeros = 0
                continue
            }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return Data(out)
    }

    /// `00 00` 後接 `00`…`03` 時插入 `03`。
    public static func escape(_ data: Data) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 64)
        var zeros = 0
        for b in data {
            if zeros == 2, b <= preventionByte {
                out.append(preventionByte)
                zeros = 0
            }
            out.append(b)
            zeros = b == 0 ? zeros + 1 : 0
        }
        return Data(out)
    }

    public static func bits(of data: Data) -> [Bool] {
        data.flatMap { byte in (0..<8).map { (byte >> (7 - $0)) & 1 == 1 } }
    }

    /// Exp-Golomb 無號：`value + 1` 的二進位，前面補「位元數 − 1」個 0。
    public static func ueBits(_ value: UInt32) -> [Bool] {
        // UInt32.max 的 codeNum + 1 需要第 33 位，避免公開 API 溢位。
        let code = UInt64(value) + 1
        let width = UInt64.bitWidth - code.leadingZeroBitCount
        let zeros = Array(repeating: false, count: width - 1)
        let digits = (0..<width).map { (code >> UInt32(width - 1 - $0)) & 1 == 1 }
        return zeros + digits
    }

    /// `rbsp_trailing_bits`：一個 1 之後補 0 到位元組邊界。
    public static func finishRbsp(_ bits: [Bool]) -> Data {
        var all = bits + [true]
        while all.count % 8 != 0 { all.append(false) }
        var out = Data(capacity: all.count / 8)
        for start in stride(from: 0, to: all.count, by: 8) {
            let byte = all[start..<start + 8].reduce(UInt8(0)) { ($0 << 1) | ($1 ? 1 : 0) }
            out.append(byte)
        }
        return out
    }
}

/// MSB-first 位元讀取器。值型別，`mutating` 只推進自己的游標，沒有共享狀態。
public struct H264BitReader {
    public let bits: [Bool]
    public private(set) var position: Int = 0
    private static let maxLeadingZeros = 31

    public init(bits: [Bool]) {
        self.bits = bits
    }

    public mutating func u(_ width: Int) throws -> UInt32 {
        precondition((0...32).contains(width), "u() 的寬度必須在 0…32")
        guard position + width <= bits.count else { throw H264SpsError.truncated }
        var value: UInt32 = 0
        for i in 0..<width where bits[position + i] { value |= 1 << UInt32(width - 1 - i) }
        position += width
        return value
    }

    public mutating func flag() throws -> Bool {
        try u(1) == 1
    }

    public mutating func ue() throws -> UInt32 {
        var zeros = 0
        while try u(1) == 0 {
            zeros += 1
            if zeros > Self.maxLeadingZeros { throw H264SpsError.oversizedExpGolomb }
        }
        let suffix = try u(zeros)
        return (1 << UInt32(zeros)) - 1 + suffix
    }

    public mutating func se() throws -> Int32 {
        let code = try ue()
        let magnitude = Int32((code + 1) / 2)
        return code & 1 == 1 ? magnitude : -magnitude
    }
}
