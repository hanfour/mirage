import Foundation

/// 內建範例 profile 的上架。
///
/// **為什麼獨立成一個型別而不是塞進 `ProfileStore`**：seeding 是「把 bundle 的東西
/// 搬到使用者目錄」，與 `ProfileStore` 的「讀寫使用者目錄」是兩件事。塞進
/// `ProfileStore.standard()` 會讓那個工廠方法每次呼叫都做檔案 I/O——隱藏副作用。
public enum BuiltInProfiles {
    public struct SeedOutcome {
        public var copied: [String] = []
        public var failed: [(name: String, error: Error)] = []
    }

    /// 把 `sources` 複製進 `directory`，**已存在者一律不動**。
    /// 分別回報成功複製的名稱與每筆失敗原因；已存在的檔案不列入。
    ///
    /// **永不覆寫是硬性語意，不是最佳化**：使用者用 ⌘E 編輯過的 profile 若被
    /// App 升級覆寫掉，那是不可回復的資料遺失。代價是新版內建 profile 不會自動
    /// 送到舊使用者手上——接受，換來零版本遷移機制與可預測的行為。
    ///
    /// 單一來源失敗（檔案不存在、無讀取權限）只跳過該筆、不中斷其餘：一份壞掉
    /// 不該讓其他份也進不去。呼叫端須逐筆回報失敗原因。
    @discardableResult
    public static func seed(into directory: URL, from sources: [URL]) -> SeedOutcome {
        let fm = FileManager.default
        // 首次啟動時目的目錄不存在，這裡自己建——少了這步整個 seeding 會靜默無效，
        // 而那正是首次啟動這個最重要的情境。
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        var outcome = SeedOutcome()
        for source in sources {
            let name = source.deletingPathExtension().lastPathComponent
            let destination = directory.appendingPathComponent(source.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.copyItem(at: source, to: destination)
                outcome.copied.append(name)
            } catch {
                outcome.failed.append((name: name, error: error))
            }
        }
        return outcome
    }

    /// bundle 內建的 profile 檔案清單。
    ///
    /// **這是本型別唯一不可單元測試的部分**（`Bundle.module` 是建置系統產生的），
    /// 所以刻意獨立成一個函式，讓不可測的面積縮到最小——`seed` 的所有判斷都在
    /// 純函式那邊，用暫存目錄逐條驗過。
    ///
    /// `subdirectory: "profiles"` 對應 `Package.swift` 的 `.copy("Resources/profiles")`：
    /// `.copy` 保持目錄結構，所以查表要帶這一層。若改成 `.process`，目錄會被攤平、
    /// 這裡就要拿掉 subdirectory——兩者要一起改。
    ///
    /// **⚠️ 回傳空陣列不是「找不到 bundle」的行為——找不到 bundle 是 `fatalError`。**
    /// SwiftPM 產生的 `Bundle.module` 存取器（`.build/…/MirageCore.build/DerivedSources/
    /// resource_bundle_accessor.swift:10-13`）長這樣：
    ///
    ///     guard let bundle = preferredBundle ?? Bundle(path: buildPath) else {
    ///         Swift.fatalError("could not load resource bundle: …")
    ///     }
    ///
    /// 兩條候選路徑分別是 `Bundle.main.bundleURL/Mirage_MirageCore.bundle` 與**編譯當下
    /// 寫死的 `.build/` 絕對路徑**。所以在開發機上 `.app` 即使沒帶資源也照跑（默默從
    /// `.build/` 讀），換一台機器或 `swift package clean` 之後就變成**啟動即崩**。
    /// 空陣列只代表「bundle 在、但裡面沒有 json」。詳見債務表 D25。
    public static func bundledSources() -> [URL] {
        Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "profiles") ?? []
    }

    /// 寫死的 starter 版面：搖桿（WASD）＋兩顆點擊鍵＋視角。
    ///
    /// 存在的理由是「編輯器不該因為資源問題而打不開」。bundle 讀不到時（D25 的情境）
    /// 退回這一份，而不是回空陣列——空的 starter 等於空白畫布，那是設計時明確否決的起點。
    public static let fallbackStarterBindings: [Binding] = [
        .joystick(up: .key("w"), down: .key("s"), left: .key("a"), right: .key("d"),
                  center: NormPoint(x: 0.2, y: 0.75), radius: 0.12),
        .tap(key: .key("j"), at: NormPoint(x: 0.85, y: 0.82)),
        .tap(key: .key("k"), at: NormPoint(x: 0.72, y: 0.88)),
        .look(activation: nil, sensitivity: 1.5),
    ]

    /// 從內建 profile 借**版面**（不借 gameId、不借 version）。
    ///
    /// 借 gameId 會讓編輯後的存檔寫回那個佔位檔，正是 D5 §1 描述的死路。
    /// 任一來源解不出來就換下一個；全部失敗才退回 `fallbackStarterBindings`。
    ///
    /// **一定要 `.validated()`（2026-07-30，D5 階段 A 終審 I4）**：`ProfileStore.load`
    /// 有驗、全系統其他地方都靠 `validated()` 保證座標合法——`KeymapEngine.snapshot()`
    /// 的靜止搖桿點與 tap 點刻意不夾取，安全性建立在「profile 必經 validated()」這條
    /// 不變式上。這裡原本只 `decode` 就直接回傳 bindings，是這條路徑上唯一漏掉驗證的缺口。
    public static func starterBindings(from sources: [URL]) -> [Binding] {
        for source in sources {
            guard let data = try? Data(contentsOf: source),
                  let profile = try? JSONDecoder().decode(KeymapProfile.self, from: data).validated(),
                  !profile.bindings.isEmpty
            else { continue }
            return profile.bindings
        }
        print("[profile] ⚠️ 無可用的內建 starter profile，改用 fallback 版面（來源共 \(sources.count) 筆）")
        return fallbackStarterBindings
    }

    /// 產品呼叫端用這個。`Bundle.module` 不可單元測試，所以這裡只做轉呼叫，
    /// 判斷全在上面那個吃 `sources` 的純函式裡。
    public static func starterBindings() -> [Binding] {
        starterBindings(from: bundledSources())
    }
}
