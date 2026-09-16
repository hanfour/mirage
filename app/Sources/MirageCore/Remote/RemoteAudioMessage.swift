import Foundation

/// `/ws/audio` 一則二進位訊息（spec 第 4 節）：8 bytes 送出時間、4 bytes 序號、
/// 4 bytes 取樣率、1 byte 聲道數、S16 little-endian 交錯樣本。
///
/// 取樣率與聲道寫進每一則而不是握手一次：emulator 的音訊格式在重連後可能不同，
/// 每則自帶格式就不需要「格式變更」這個額外的訊息型別。
/// 時間是 Mac 的 monotonic 奈秒，手機端只拿來算相對值，不與自己的時鐘相減。
public struct RemoteAudioMessage: Sendable, Equatable {
    public static let headerSize = 17

    public let sentAtNanoseconds: UInt64
    public let sequence: UInt32
    public let samplingRate: UInt32
    public let channels: UInt8
    public let samples: Data

    public init(sentAtNanoseconds: UInt64, sequence: UInt32, samplingRate: UInt32,
                channels: UInt8, samples: Data) {
        self.sentAtNanoseconds = sentAtNanoseconds
        self.sequence = sequence
        self.samplingRate = samplingRate
        self.channels = channels
        self.samples = samples
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + samples.count)
        out.append(contentsOf: Self.bigEndianBytes(sentAtNanoseconds, count: 8))
        out.append(contentsOf: Self.bigEndianBytes(UInt64(sequence), count: 4))
        out.append(contentsOf: Self.bigEndianBytes(UInt64(samplingRate), count: 4))
        out.append(channels)
        out.append(samples)
        return out
    }

    public static func decode(_ data: Data) -> RemoteAudioMessage? {
        let bytes = [UInt8](data) // 複製成 0 起始的陣列，避免 Data slice 的 startIndex 陷阱。
        guard bytes.count > headerSize else { return nil }
        let channels = bytes[16]
        guard channels == 1 || channels == 2 else { return nil }
        let samplingRate = bytes[12..<16].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (8_000...48_000).contains(samplingRate) else { return nil }
        let payloadCount = bytes.count - headerSize
        guard payloadCount > 0, payloadCount % (2 * Int(channels)) == 0 else { return nil }
        let time = bytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let sequence = bytes[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return RemoteAudioMessage(sentAtNanoseconds: time, sequence: sequence,
                                  samplingRate: samplingRate, channels: channels,
                                  samples: Data(bytes[headerSize...]))
    }

    private static func bigEndianBytes(_ value: UInt64, count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> UInt64(8 * (count - 1 - $0))) }
    }
}
