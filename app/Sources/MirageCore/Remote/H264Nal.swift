import Foundation

/// 本專案會碰到的 NAL 型別（H.264 表 7-1 的子集）。
public enum H264NalType: UInt8, Sendable {
    case nonIdrSlice = 1
    case idrSlice = 5
    case sei = 6
    case sps = 7
    case pps = 8
    case accessUnitDelimiter = 9
}

/// Annex-B 位元組層的純函式：起始碼切分、合併、型別判斷。
public enum H264Nal {
    public static let startCode = Data([0, 0, 0, 1])
    private static let typeMask: UInt8 = 0x1f
    private static let forbiddenBit: UInt8 = 0x80

    /// `nal_unit_type`（低五位）。空資料或 forbidden_zero_bit 為 1 都回 nil。
    public static func rawType(of nal: Data) -> UInt8? {
        guard let header = nal.first, header & forbiddenBit == 0 else { return nil }
        return header & typeMask
    }

    public static func type(of nal: Data) -> H264NalType? {
        rawType(of: nal).flatMap(H264NalType.init(rawValue:))
    }

    /// 以 `00 00 01`（三或四位元組起始碼皆可）切分。第一個起始碼之前的位元組與空片段都丟掉。
    public static func split(annexB: Data) -> [Data] {
        let bytes = [UInt8](annexB)
        var boundaries: [(start: Int, end: Int)] = []   // 起始碼在 bytes 裡的 [start, end)
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let start = (i > 0 && bytes[i - 1] == 0) ? i - 1 : i
                boundaries.append((start, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        var nals: [Data] = []
        for (index, boundary) in boundaries.enumerated() {
            let end = index + 1 < boundaries.count ? boundaries[index + 1].start : bytes.count
            if end > boundary.end { nals.append(Data(bytes[boundary.end..<end])) }
        }
        return nals
    }

    public static func join(_ nals: [Data]) -> Data {
        nals.reduce(into: Data()) { out, nal in
            out.append(startCode)
            out.append(nal)
        }
    }
}

/// 一幀的存取單元。`nals` 不含起始碼；keyframe 時前兩個是 SPS、PPS。
public struct H264AccessUnit: Sendable, Equatable {
    public let nals: [Data]
    public let isKeyframe: Bool

    public init(nals: [Data], isKeyframe: Bool) {
        self.nals = nals
        self.isKeyframe = isKeyframe
    }

    public var annexB: Data { H264Nal.join(nals) }
}

/// 把編碼器吐出的一幀 NAL 打包成存取單元，並快取最近的 SPS/PPS（spec 第 4 節：keyframe
/// 訊息必須含 SPS＋PPS＋IDR）。值型別：`pack` 回傳新的 packer，呼叫端持有最新那一份。
public struct H264AccessUnitPacker: Sendable, Equatable {
    public let sps: Data?
    public let pps: Data?

    public init(sps: Data? = nil, pps: Data? = nil) {
        self.sps = sps
        self.pps = pps
    }

    public func pack(_ nals: [Data], rewriteSps: (Data) -> Data?)
        -> (packer: H264AccessUnitPacker, unit: H264AccessUnit?)
    {
        var sps = self.sps
        var pps = self.pps
        var slices: [Data] = []
        var hasVcl = false
        var hasIdr = false
        for nal in nals {
            switch H264Nal.type(of: nal) {
            case .sps?: sps = rewriteSps(nal) ?? nal
            case .pps?: pps = nal
            case .accessUnitDelimiter?: continue
            case .idrSlice?: hasVcl = true; hasIdr = true; slices.append(nal)
            case .nonIdrSlice?: hasVcl = true; slices.append(nal)
            case .sei?, .none: slices.append(nal)
            }
        }
        let next = H264AccessUnitPacker(sps: sps, pps: pps)
        guard hasVcl else { return (next, nil) }
        guard hasIdr else { return (next, H264AccessUnit(nals: slices, isKeyframe: false)) }
        guard let sps, let pps else { return (next, nil) }
        return (next, H264AccessUnit(nals: [sps, pps] + slices, isKeyframe: true))
    }
}
