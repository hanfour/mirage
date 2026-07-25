import Foundation

/// adb 執行結果 → 前景 package 的純降級判斷（exitCode 非 0 或無前景 → nil）。
public enum AdbOutcome {
    public static func packageOrNil(exitCode: Int32, stdout: String) -> String? {
        guard exitCode == 0 else { return nil }
        return ForegroundParser.foregroundPackage(fromDumpsys: stdout)
    }
}
