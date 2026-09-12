import Foundation

/// VideoToolbox 的 `CMBlockBuffer` 是 AVCC 格式：每個 NAL 前面是 big-endian 長度前綴
/// （長度由 format description 的 `nalUnitHeaderLength` 決定，實測 4）。手機端要的是
/// Annex-B，所以先切成不含前綴的 NAL 清單，交給 `H264AccessUnitPacker` 加起始碼。
enum H264AvccSplitter {
    /// 長度前綴指到緩衝區外時停止，回傳到此為止完整的 NAL。不拋錯：半截 NAL 對手機端
    /// 沒有用，丟掉比送出去更好。長度 0 不是 NAL，同樣視為結束。
    static func split(_ avcc: Data, headerLength: Int) -> [Data] {
        precondition((1...4).contains(headerLength), "AVCC 長度前綴只有 1 到 4 位元組")
        let bytes = [UInt8](avcc)
        var nals: [Data] = []
        var index = 0
        while index + headerLength <= bytes.count {
            let length = bytes[index..<index + headerLength].reduce(0) { ($0 << 8) | Int($1) }
            let start = index + headerLength
            guard length > 0, start + length <= bytes.count else { break }
            nals.append(Data(bytes[start..<start + length]))
            index = start + length
        }
        return nals
    }
}
