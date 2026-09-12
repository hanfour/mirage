import Foundation

/// `/ws/video` 一則二進位訊息（spec 第 4 節）：8 bytes 送出時間、4 bytes 序號、1 byte keyframe、Annex-B。
/// 時間是 Mac 的 monotonic 奈秒，手機端只拿來算相對值，不與自己的時鐘相減。
public struct RemoteVideoMessage: Sendable, Equatable {
    public static let headerSize = 13
    private static let keyframeFlag: UInt8 = 1
    private static let threeByteStartCode = Data([0, 0, 1])

    public let sentAtNanoseconds: UInt64
    public let sequence: UInt32
    public let isKeyframe: Bool
    public let accessUnit: Data

    public init(sentAtNanoseconds: UInt64, sequence: UInt32, isKeyframe: Bool, accessUnit: Data) {
        self.sentAtNanoseconds = sentAtNanoseconds
        self.sequence = sequence
        self.isKeyframe = isKeyframe
        self.accessUnit = accessUnit
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + accessUnit.count)
        out.append(contentsOf: Self.bigEndianBytes(sentAtNanoseconds, count: 8))
        out.append(contentsOf: Self.bigEndianBytes(UInt64(sequence), count: 4))
        out.append(isKeyframe ? Self.keyframeFlag : 0)
        out.append(accessUnit)
        return out
    }

    public static func decode(_ data: Data) -> RemoteVideoMessage? {
        let bytes = [UInt8](data)   // 複製成 0 起始的陣列，避免 Data slice 的 startIndex 陷阱
        guard bytes.count > headerSize else { return nil }
        let flag = bytes[12]
        guard flag <= keyframeFlag else { return nil }
        let payload = Data(bytes[headerSize...])
        guard payload.starts(with: H264Nal.startCode) || payload.starts(with: threeByteStartCode) else { return nil }
        let time = bytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let sequence = bytes[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return RemoteVideoMessage(sentAtNanoseconds: time, sequence: sequence,
                                  isKeyframe: flag == keyframeFlag, accessUnit: payload)
    }

    private static func bigEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64(8 * (count - 1 - $0))) }
    }
}
