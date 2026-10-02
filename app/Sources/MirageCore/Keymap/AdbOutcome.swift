import Foundation

/// adb 執行結果 → 前景 package 的純降級判斷（exitCode 非 0 或無前景 → nil）。
public enum AdbOutcome {
    public static func packageOrNil(exitCode: Int32, stdout: String) -> String? {
        guard exitCode == 0 else { return nil }
        return ForegroundParser.foregroundPackage(fromDumpsys: stdout)
    }

    /// 從 dumpsys activities 的 DisplayRotation 行解析 Surface.ROTATION_* 數值。
    public static func rotationOrNil(stdout: String) -> Int? {
        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let line = rawLine.drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" })
            guard line.hasPrefix("mRotation=") else { continue }
            let value = line.dropFirst("mRotation=".count).prefix { !$0.isWhitespace }
            switch value {
            case "0": return 0
            case "1": return 1
            case "2": return 2
            case "3": return 3
            default: continue
            }
        }
        return nil
    }
}
