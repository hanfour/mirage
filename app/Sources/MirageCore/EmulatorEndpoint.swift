import Foundation

/// 模擬器 gRPC 端點的解析結果。純值型別、無 I/O，故可完整單元測試。
///
/// 存在的理由：連線目標先前寫死在 `EmulatorClient` 的預設參數上（`localhost:8554`）。
/// 一旦要同時面對多台模擬器——量測用的實例、使用者自己的實例、日後由 Mirage 自己
/// 建立的實例——寫死的 port 就不成立了。
public struct EmulatorEndpoint: Sendable, Equatable {
    public let host: String
    public let port: Int

    /// 非 `nil` 表示環境變數存在但無效，**已退回預設值**。
    ///
    /// 這個欄位不是裝飾。靜默退回會讓使用者連上**另一台**模擬器卻毫無訊號——正是
    /// MMAP 階段付過學費的失敗模式（`RESULTS-mmap.md`：降級無訊號 = 使用者盯著錯誤
    /// 畫面卻不知道）。呼叫端有義務把它顯示出來。
    public let overrideProblem: String?

    public init(host: String, port: Int, overrideProblem: String? = nil) {
        self.host = host
        self.port = port
        self.overrideProblem = overrideProblem
    }

    public static let `default` = EmulatorEndpoint(host: "localhost", port: 8554)

    static let hostKey = "MIRAGE_HOST"
    static let portKey = "MIRAGE_PORT"

    /// 從環境解析。任一覆寫無效即退回該欄位的預設值，並在 `overrideProblem` 說明原因。
    ///
    /// 兩個覆寫**各自獨立**判定：一個壞掉不影響另一個生效，但兩個原因都會被回報——
    /// 只報第一個會讓使用者修完再撞第二個。
    public static func resolve(environment: [String: String]) -> EmulatorEndpoint {
        var problems: [String] = []

        let host: String
        switch environment[hostKey] {
        case nil:
            host = `default`.host
        case let raw? where raw.trimmingCharacters(in: .whitespaces).isEmpty:
            problems.append("\(hostKey) 是空白，退回 \(`default`.host)")
            host = `default`.host
        case let raw?:
            host = raw
        }

        let port: Int
        switch environment[portKey] {
        case nil:
            port = `default`.port
        case let raw? where isValidPort(raw):
            port = Int(raw)!
        case let raw?:
            problems.append("\(portKey)=\(raw) 不是 1–65535 的整數，退回 \(`default`.port)")
            port = `default`.port
        }

        return EmulatorEndpoint(host: host, port: port,
                                overrideProblem: problems.isEmpty ? nil
                                                                  : problems.joined(separator: "；"))
    }

    private static func isValidPort(_ raw: String) -> Bool {
        guard let n = Int(raw) else { return false }
        return (1...65535).contains(n)
    }
}
