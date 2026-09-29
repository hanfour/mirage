import Foundation

/// 手機頁面的讀取器。比照
/// `BuiltInProfiles.bundledSources()`：`.copy("Resources/remote")` 保留目錄層，所以查表帶
/// `subdirectory: "remote"`。找不到 bundle 是 SwiftPM 產生的 accessor 直接 `fatalError`
/// （見 `BuiltInProfiles.swift:55-66` 與債務 D25），回 nil 只代表 bundle 在、檔案缺。
public enum RemoteViewerPage {
    static let resourceName = "viewer"
    static let resourceExtension = "html"
    static let subdirectory = "remote"

    /// 標記與檔名的對應表。**順序就是頁面上的順序**：`viewer-input` 會用到
    /// `viewer-audio` 匯出的東西，所以 audio 的標記在 HTML 裡排在前面。
    /// 新增資源時只改這張表；漏掉替換的話 `RemoteViewerPageTests` 會紅
    /// （它斷言成品裡不得殘留任何 `MIRAGE_VIEWER_` 標記，不是只檢查已知的那幾個）。
    static let inlinedScripts = [("/* MIRAGE_VIEWER_AUDIO */", "viewer-audio"),
                                 ("/* MIRAGE_VIEWER_INPUT */", "viewer-input")]

    public static func bundled() -> Data? {
        guard let url = MirageResources.bundle.url(forResource: resourceName, withExtension: resourceExtension,
                                                   subdirectory: subdirectory),
              var html = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        for (marker, name) in inlinedScripts {
            guard let scriptURL = MirageResources.bundle.url(forResource: name, withExtension: "js", subdirectory: subdirectory),
                  let script = try? String(contentsOf: scriptURL, encoding: .utf8) else { return nil }
            html = html.replacingOccurrences(of: marker, with: script)
        }
        return html.data(using: .utf8)
    }
}
