import Darwin
import Testing
@testable import MirageCore

/// D74：真 probe + 預設 sleeper 的整合回歸，不需要模擬器。
/// 自行取得本機未監聽的埠，每次都跑，不依賴開發者的 MIRAGE_PORT。
@Suite(.timeLimit(.minutes(1))) struct EmulatorClientBackoffCrashTests {
    @Test
    func defaultClientSurvivesRepeatedConnectionFailures() async throws {
        let port = try unusedLocalPort()
        // 除 host / port 外全部採預設參數；注入 sleeper 會繞過要測的崩潰路徑。
        let client = EmulatorClient(host: "127.0.0.1", port: port)
        await client.start(box: LatestFrameBox(), width: 540, height: 1200)

        var seen: [ConnState] = []
        for await state in client.states {
            seen.append(state)
            // reconnecting(0) 在第一次 backoff 之前發布，只等它會假綠。
            // 等到第三次失敗，才證明兩次真實 backoff 都已返回；之前不呼叫 stop。
            if state == .reconnecting(attempt: 2) || state == .connected { break }
        }
        await client.stop()

        #expect(seen == [
            .connecting,
            .reconnecting(attempt: 0),
            .reconnecting(attempt: 1),
            .reconnecting(attempt: 2),
        ])
    }

    private func unusedLocalPort() throws -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0, "無法建立取得本機埠的 socket")
        defer { Darwin.close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length)
            }
        }
        try #require(bindResult == 0, "無法 bind 本機臨時埠")
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        try #require(nameResult == 0, "無法讀取本機臨時埠")
        let port = Int(UInt16(bigEndian: address.sin_port))
        try #require(port > 0)
        // 回傳前關閉 socket；與任何先取埠再連線的方式一樣，仍有極短的埠重用窗口。
        return port
    }
}
