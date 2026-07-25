import Foundation

/// 從 `adb shell dumpsys activity activities` 輸出解析前景 package。
/// 取第一個含 "ResumedActivity" 的行內 `<pkg>/<activity>` token 的 package 段。
public enum ForegroundParser {
    public static func foregroundPackage(fromDumpsys output: String) -> String? {
        for rawLine in output.split(separator: "\n") {
            guard rawLine.contains("ResumedActivity") else { continue }
            if let pkg = package(inLine: String(rawLine)) { return pkg }
        }
        return nil
    }

    /// 從一行抽 `pkg/.activity` 的 package：以空白/大括號切 token，取第一個含 "/" 且 "/" 前含 "." 的。
    private static func package(inLine line: String) -> String? {
        for token in line.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "}" }) {
            guard let slash = token.firstIndex(of: "/") else { continue }
            let pkg = String(token[token.startIndex..<slash])
            if pkg.contains("."), !pkg.hasPrefix("/") { return pkg }
        }
        return nil
    }
}
