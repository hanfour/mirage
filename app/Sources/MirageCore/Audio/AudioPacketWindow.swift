/// 一次監測窗口：累計 ring 計數與本窗口的原始 payload bytes 直方圖。
/// 每個桶是「bytes:包數」，依 bytes 排序；空窗口明確印 {}。
/// 接收後尚未送到 ring 的包會歸到下一窗口，與 pkt/smp 的寫入邊界一致。
public struct AudioPacketWindow: Sendable {
    public let stats: AudioStats
    public let byteCounts: [Int: Int]

    public var logFields: String {
        let bins = byteCounts.keys.sorted().map { "\($0):\(byteCounts[$0]!)" }
        let packets = byteCounts.values.reduce(0, +)
        let bytes = byteCounts.reduce(0) { $0 + $1.key * $1.value }
        return "rxpkt=\(packets) rxbytes=\(bytes) pkt_bytes={\(bins.joined(separator: ","))}"
    }
}
