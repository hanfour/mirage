import Foundation

/// 內建範例 profile 的上架。
///
/// **為什麼獨立成一個型別而不是塞進 `ProfileStore`**：seeding 是「把 bundle 的東西
/// 搬到使用者目錄」，與 `ProfileStore` 的「讀寫使用者目錄」是兩件事。塞進
/// `ProfileStore.standard()` 會讓那個工廠方法每次呼叫都做檔案 I/O——隱藏副作用。
public enum BuiltInProfiles {
    /// 把 `sources` 複製進 `directory`，**已存在者一律不動**。
    /// 回傳實際複製了哪些（檔名去掉 `.json`）；空陣列代表全都已存在。
    ///
    /// **永不覆寫是硬性語意，不是最佳化**：使用者用 ⌘E 編輯過的 profile 若被
    /// App 升級覆寫掉，那是不可回復的資料遺失。代價是新版內建 profile 不會自動
    /// 送到舊使用者手上——接受，換來零版本遷移機制與可預測的行為。
    ///
    /// 單一來源失敗（檔案不存在、無讀取權限）只跳過該筆、不中斷其餘：一份壞掉
    /// 不該讓其他份也進不去。回傳值只列成功的，呼叫端可據此如實回報。
    @discardableResult
    public static func seed(into directory: URL, from sources: [URL]) -> [String] {
        let fm = FileManager.default
        // 首次啟動時目的目錄不存在，這裡自己建——少了這步整個 seeding 會靜默無效，
        // 而那正是首次啟動這個最重要的情境。
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var copied: [String] = []
        for source in sources {
            let name = source.deletingPathExtension().lastPathComponent
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.copyItem(at: source, to: destination)
                copied.append(name)
            } catch {
                continue        // 見上：單筆失敗不影響其餘
            }
        }
        return copied
    }
}
