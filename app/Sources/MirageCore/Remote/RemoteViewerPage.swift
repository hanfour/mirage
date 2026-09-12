import Foundation

/// 手機頁面的讀取器。這是手機遙控唯一碰 `Bundle.module` 的地方，比照
/// `BuiltInProfiles.bundledSources()`：`.copy("Resources/remote")` 保留目錄層，所以查表帶
/// `subdirectory: "remote"`。找不到 bundle 是 SwiftPM 產生的 accessor 直接 `fatalError`
/// （見 `BuiltInProfiles.swift:55-66` 與債務 D25），回 nil 只代表 bundle 在、檔案缺。
public enum RemoteViewerPage {
    static let resourceName = "viewer"
    static let resourceExtension = "html"
    static let subdirectory = "remote"

    public static func bundled() -> Data? {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: resourceExtension,
                                          subdirectory: subdirectory)
        else { return nil }
        return try? Data(contentsOf: url)
    }
}
