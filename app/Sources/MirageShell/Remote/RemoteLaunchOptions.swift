import MirageCore

/// 啟動時自動開啟遙控的環境變數。**只給活體腳本用**（腳本驅動不了選單），使用者走選單列。
/// 壞值退回預設並記在 `problems`，比照 `EmulatorEndpoint.overrideProblem` 的做法：靜默退回
/// 會讓人盯著錯的埠卻毫無線索。
struct RemoteLaunchOptions: Equatable, Sendable {
    static let enableKey = "MIRAGE_REMOTE"
    static let portKey = "MIRAGE_REMOTE_PORT"
    static let pullFPSKey = "MIRAGE_REMOTE_PULL_FPS"
    static let defaultPullFPS = 30
    static let tokenKey = "MIRAGE_REMOTE_TOKEN"
    private static let portRange = 1...65535

    /// 新幀事件驅動編碼的速率上限，不再是輪詢頻率。
    let pullFPS: Int
    var pullInterval: Duration { .nanoseconds(1_000_000_000 / Int64(pullFPS)) }

    let port: Int
    let token: PairingToken?
    let problems: [String]

    static func parse(_ environment: [String: String]) -> RemoteLaunchOptions? {
        guard environment[enableKey] == "1" else { return nil }
        var problems: [String] = []
        var port = RemoteServerConfiguration.defaultPort
        if let raw = environment[portKey] {
            if let value = Int(raw), portRange.contains(value) {
                port = value
            } else {
                problems.append("\(portKey)=\(raw) 不是 1 到 65535 的整數，改用 \(port)")
            }
        }
        var pullFPS = defaultPullFPS
        if let raw = environment[pullFPSKey] {
            if let value = Int(raw), (5...60).contains(value) {
                pullFPS = value
            } else {
                problems.append("\(pullFPSKey)=\(raw) 不是 5 到 60 的整數，改用 \(defaultPullFPS)")
            }
        }
        var token: PairingToken?
        if let raw = environment[tokenKey] {
            token = PairingToken(value: raw)
            if token == nil { problems.append("\(tokenKey) 不是 32 個小寫十六進位字元，改用亂數 token") }
        }
        return RemoteLaunchOptions(pullFPS: pullFPS, port: port, token: token, problems: problems)
    }
}
