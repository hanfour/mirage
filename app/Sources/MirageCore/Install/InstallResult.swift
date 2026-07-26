import Foundation

/// `adb install -r` 輸出解析結果（純值，無 I/O）。App 層決定如何呈現。
public enum InstallResult: Equatable, Sendable {
    case success
    case failure(String)   // 原因（INSTALL_FAILED_… 或原始尾句）

    /// 解析 adb install（stdout+stderr 合流）輸出。
    /// - `Failure [X]` → `.failure(X)`（X 空 → "未知錯誤"）
    /// - 否則含 `Success` → `.success`
    /// - 否則非空且含 "fail" 的尾行 → `.failure(該行)`
    /// - 其他非空 → `.failure(裁修後全文)`；空 → `.failure("未知錯誤")`
    public static func parse(_ output: String) -> InstallResult {
        // 只認 "Failure [" 觸發括號抽取——避開串流進度 "[ 50%]" 誤判。
        if let r = output.range(of: "Failure [") {
            let after = output[r.upperBound...]
            if let close = after.firstIndex(of: "]") {
                let reason = after[..<close].trimmingCharacters(in: .whitespaces)
                return .failure(reason.isEmpty ? "未知錯誤" : reason)
            }
            return .failure("未知錯誤")
        }
        if output.contains("Success") { return .success }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure("未知錯誤") }
        if let line = trimmed.split(separator: "\n").reversed()
            .first(where: { $0.lowercased().contains("fail") }) {
            return .failure(String(line).trimmingCharacters(in: .whitespaces))
        }
        return .failure(trimmed)
    }
}
