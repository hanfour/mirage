import MirageCore

/// 單一 APK 的安裝結果項（名稱取自檔名，供 banner 呈現）。
struct InstallItem: Equatable, Sendable {
    let name: String
    let result: InstallResult
}

/// 安裝流程 UI 狀態。adb install 無逐步進度，只有 installing→finished 的批次狀態。
enum InstallState: Equatable, Sendable {
    case idle
    case installing(done: Int, total: Int)
    case finished([InstallItem])
}
