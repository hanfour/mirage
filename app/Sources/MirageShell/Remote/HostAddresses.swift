import Darwin
import Foundation

struct HostAddress: Equatable, Sendable {
    let interface: String
    let ip: String
}

/// 主機的 IPv4 位址，供選單顯示連線網址（spec 第 5 節：伺服器綁所有介面，網址要給使用者
/// 實際會走的那個位址——Wi-Fi 或 Tailscale）。
enum HostAddresses {
    /// `getifaddrs`：IPv4、介面 UP、非 loopback。排序交給 `ordered`。
    static func current() -> [HostAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [HostAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let addr = entry.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            out.append(HostAddress(interface: String(cString: entry.pointee.ifa_name), ip: String(cString: buffer)))
        }
        return ordered(out)
    }

    /// en*（Wi-Fi／有線）→ utun*（Tailscale）→ 其他（bridge、vmnet）。穩定排序，同類保持原順序。
    static func ordered(_ list: [HostAddress]) -> [HostAddress] {
        func rank(_ name: String) -> Int {
            if name.hasPrefix("en") { return 0 }
            if name.hasPrefix("utun") { return 1 }
            return 2
        }
        return list.enumerated()
            .sorted { (rank($0.element.interface), $0.offset) < (rank($1.element.interface), $1.offset) }
            .map(\.element)
    }
}
