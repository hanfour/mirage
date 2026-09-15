import Darwin
import Foundation

/// UDP connect 只選路，不呼叫 send；不能據此判斷網際網路或對端是否可達。
enum HostAddressProbe {
    static func current(interfaces: [HostAddress], probe: (String) -> String?) -> [HostAddress] {
        merged(interfaces: interfaces, defaultRoute: probe("1.1.1.1"),
               tailscaleRoute: probe("100.100.100.100"))
    }

    /// getifaddrs 的介面名稱優先；探測補上的位址統一標為 route。
    static func merged(interfaces: [HostAddress], defaultRoute: String?,
                       tailscaleRoute: String?) -> [HostAddress] {
        var addresses = interfaces
        if let ip = defaultRoute, isUsable(ip) {
            addresses.append(HostAddress(interface: "route", ip: ip))
        }
        if let ip = tailscaleRoute, isTailscale(ip) {
            addresses.append(HostAddress(interface: "route", ip: ip))
        }
        var seen = Set<String>()
        return HostAddresses.ordered(addresses.filter { seen.insert($0.ip).inserted })
    }

    static func needsLocalNetworkHint(_ ips: [String]) -> Bool {
        !ips.contains { ip in
            guard let bytes = octets(ip) else { return false }
            return bytes[0] == 10 || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && (16...31).contains(bytes[1])) || isTailscale(ip)
        }
    }

    static func isTailscale(_ ip: String) -> Bool {
        guard let bytes = octets(ip) else { return false }
        return bytes[0] == 100 && (64...127).contains(bytes[1])
    }

    private static func octets(_ ip: String) -> [UInt8]? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        let bytes = parts.compactMap { UInt8($0) }
        return bytes.count == 4 ? bytes : nil
    }

    private static func isUsable(_ ip: String) -> Bool {
        guard let bytes = octets(ip) else { return false }
        return bytes[0] != 0 && bytes[0] != 127 && bytes[0] < 224
    }

    static func localAddress(to destination: String) -> String? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var peer = sockaddr_in()
        peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_port = UInt16(53).bigEndian
        guard destination.withCString({ inet_pton(AF_INET, $0, &peer.sin_addr) }) == 1 else { return nil }
        let connected = withUnsafePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0, local.sin_family == sa_family_t(AF_INET) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let ip = String(cString: buffer)
        return isUsable(ip) ? ip : nil
    }
}
