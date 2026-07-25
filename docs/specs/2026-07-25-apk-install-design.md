# APK 拖放安裝 設計文件

## 1. 目標

把 .apk（單/多）拖到鏡像視窗 → 非同步 `adb install -r` → 「安裝中…」狀態 → 成功/失敗回饋。提供 sideload APK 到模擬器的核心能力（母計畫 Phase-1「拖放安裝 APK」；也是「3 款指標遊戲開箱即玩」的前置之一）。

**非目標**：已安裝 app 清單/啟動/移除（Phase-2 遊戲庫）；真遊戲取得與 GApps/Play 依賴（外部，見母計畫 R1）；APK 逐步安裝進度（adb install 無此訊號，只有 installing→done/failed）。

## 2. 全域約束（延續 P1-a/b/c/d）

- 平台 macOS 14+ Apple Silicon；`swift build -c release` 零非-deprecation 警告。
- **MirageCore 不得 import AppKit/SwiftUI/Metal**；不 `fatalError`；錯誤回傳/記錄，App 層決定呈現。
- 所有 target 開 `-strict-concurrency=complete`；`.swiftLanguageMode(.v5)`。
- 測試語法用 swift-testing；每檔 <400 行、函式 <50 行；純解析與 UI 膠水嚴格分離；不可變優先。
- TDD：先寫失敗測試→確認失敗→最小實作→綠→commit。Conventional commits、無 attribution。
- MirageCore 覆蓋 ≥80%；既有測試（合併後 92）不回歸。
- 活體測試預設 skip、`MIRAGE_LIVE` 開啟；adb 一律 `ANDROID_SERIAL=emulator-5554`（避開實體手機）。
- **零 proto 遷移**：安裝走 adb（host 工具），非 gRPC。

## 3. 檔案結構

```
app/Sources/MirageCore/Install/
└── InstallResult.swift          # 純：enum + parse(adb install 輸出)（可單元測試）
app/Sources/MirageApp/Detect/
└── AdbClient.swift              # 修改：抽私有 run(args:timeout:); +install(apkURL:)
app/Sources/MirageApp/Install/
└── InstallBanner.swift          # 安裝中/結果 banner（SwiftUI）
app/Sources/MirageApp/
├── MirrorView.swift             # 修改：.onDrop(.fileURL) 濾 .apk → AppModel.installAPKs
└── MirageApp.swift              # 修改：AppModel installState + installAPKs；body 疊 InstallBanner
app/Tests/MirageCoreTests/
└── InstallResultTests.swift      # 純解析單元
app/scripts/
└── verify_apk_install.sh         # 活體：實際裝一個小 APK → 結果
app/RESULTS-apk-install.md         # 驗收
```

## 4. 元件設計

### 4.1 InstallResult（MirageCore，純解析）

```
public enum InstallResult: Equatable, Sendable {
    case success
    case failure(String)   // 原因（INSTALL_FAILED_… 或原始尾句）

    /// 解析 `adb install -r` 輸出：
    /// - 含 "Success" → .success（涵蓋 "Performing Streamed Install\nSuccess"）
    /// - "Failure [INSTALL_FAILED_X: …]" / "adb: failed to install …: Failure [X]" → .failure(X)
    /// - 其他非空 → .failure(裁修後尾句)；空 → .failure("未知錯誤")
    public static func parse(_ output: String) -> InstallResult
}
```

- 純字串、無副作用、無 AppKit/adb → MirageCore、可窮舉單元測試（success/streamed-success/各 Failure 原因/adb-error 前綴/空/未知）。
- 解析規則：先判 `Success`（整體含即成功）；否則抓第一個 `[...]` 括號內容為原因，無括號則取含 "Failure"/"failed" 的行裁修，皆無則 `.failure("未知錯誤")`。

### 4.2 AdbClient 重構 + install（App）

抽出共用私有執行器（DRY），既有偵測行為不變：

```
struct AdbClient: Sendable {
    // 既有：adbPath/serial/standard()
    // 新增私有：跑 adb，並發排空 pipe（沿用 P1-d OutcomeBox.drainAndFinish），逾時→nil。
    private func run(_ args: [String], timeout: Duration) async -> (exit: Int32, stdout: String)?

    // 既有改呼叫 run（行為不變，回歸驗）：
    func dumpsysForegroundPackage(timeout: Duration = .seconds(2)) async -> String?
    //   = run(["-s", serial, "shell", "dumpsys", "activity", "activities"], timeout:)
    //     → AdbOutcome.packageOrNil(exitCode:stdout:)

    // 新增：
    func install(apkURL: URL, timeout: Duration = .seconds(120)) async -> InstallResult
    //   run(["-s", serial, "install", "-r", apkURL.path], timeout:)
    //     → 有結果：InstallResult.parse(stdout)；run 回 nil（adb 執行失敗/逾時）：.failure("adb 執行失敗或逾時")
}
```

- install timeout 較長（大 APK 可達數十秒）；沿用 `run` 的並發排空避免大輸出死鎖。
- `run` 回 nil（adb 無法啟動/逾時砍）→ install 降級為 `.failure`；dumpsys 降級為 nil（同 P1-d）。

### 4.3 拖放（MirrorView）

- SwiftUI `.onDrop(of: [.fileURL], isTargeted: $dropTargeted)`（or `[UTType.fileURL]`）於鏡像視圖。
- drop handler：`loadItem`/`loadObject` 取 `URL`，濾 `pathExtension.lowercased() == "apk"`；集齊後 `Task { await model.installAPKs(urls) }`。非 .apk 忽略（或回饋「僅支援 .apk」）。
- `isTargeted` 可做拖曳高亮（pending-human 體感）。

### 4.4 安裝狀態 + 回饋（AppModel + InstallBanner）

```
// AppModel 增補：
enum InstallState: Equatable { case idle; case installing(done: Int, total: Int); case finished([Item]) }
struct Item: Equatable { let name: String; let result: InstallResult }
var installState: InstallState = .idle

func installAPKs(_ urls: [URL]) async {
    guard let adb = AdbClient.standard() else { installState = .finished([...adb 不可用]); return }
    var items: [Item] = []
    for (i, url) in urls.enumerated() {
        installState = .installing(done: i, total: urls.count)
        let r = await adb.install(apkURL: url)
        items.append(Item(name: url.lastPathComponent, result: r))
    }
    installState = .finished(items)
    // 數秒後回 idle（Task.sleep）
}
```

- `InstallBanner`（SwiftUI，疊在鏡像上，`allowsHitTesting(false)`）：
  - `.installing(done,total)`：spinner +「安裝中… (\(done+1)/\(total))」。
  - `.finished(items)`：逐項「✓ <name> 安裝成功 / ✗ <name>: <原因>」，~4s 後 `installState=.idle` 自動消失。

## 5. 錯誤處理

- 非 .apk 拖入 → 忽略（不進 install；可選 banner「僅支援 .apk」）。
- `AdbClient.standard()` nil（無 adb）→ `.finished` 記「adb 不可用」，不崩。
- install 逾時/非零/adb 執行失敗 → `InstallResult.failure(原因)`（降級，不崩）。
- 安裝失敗不影響鏡像/輸入/偵測（各自獨立）。

## 6. 測試

- `InstallResultTests`（MirageCore 純）：`Success`、`Performing Streamed Install\nSuccess`、`Failure [INSTALL_FAILED_ALREADY_EXISTS]`、`adb: failed to install x.apk: Failure [INSTALL_FAILED_INVALID_APK: ...]`、空→未知、未知格式→failure(尾句)。
- `AdbClient` 重構回歸：既有偵測活體（dumpsys→package）不變；`run` 抽出後 `dumpsysForegroundPackage` 行為等價（既有 92 綠 + P1-d 偵測活體不回歸）。
- 活體 `verify_apk_install.sh`：對模擬器裝一個小測試 APK（或既有系統可重裝的 APK）→ 印 InstallResult。
- pending-human：拖放 UI 手感、拖曳高亮、大 APK banner 體感。

## 7. 驗收線

| # | 驗收線 | 量測 |
|---|---|---|
| 1 | InstallResult 單元全綠、MirageCore 覆蓋 ≥80%、release 零警告、既有 92 不回歸 | 單元 |
| 2 | AdbClient `run` 重構後 P1-d 偵測不回歸（dumpsys→package 活體仍正確） | 活體 |
| 3 | 活體：拖/指定一個 .apk → `adb install -r` → InstallResult 正確（成功或明確失敗原因） | 活體（verify_apk_install.sh）|
| 4 | 拖非 .apk / adb 不可用 → 不崩、明確回饋 | 單元 + 結構 |
| 5 | pending-human：拖放 UI、拖曳高亮、大 APK 安裝體感 | pending-human |

## 8. 與 P1-a/b/c/d 整合面 + 風險

- `AdbClient`（P1-d）重構抽 `run`——**dumpsys 行為必須等價**（P1-d 偵測依賴），重構後回歸驗（活體 + 既有測試）。
- `MirrorView`（P1-a/c）加 `.onDrop`——additive，不動 P1-a 滑鼠映射/P1-c 輸入路由/keymap。
- `MirageApp.body` 疊 `InstallBanner`——與 P1-c overlay/P1-b 選單列不同層，additive。
- MirageCore 僅加 `InstallResult` 純型別。
- **風險**：`adb install` 對 GApps 依賴的真遊戲（原神等）仍需使用者自裝 GApps（母計畫 R1）——本件只做 sideload 機制，不代散布；驗收用可自由 sideload 的測試 APK。
- **風險**：install timeout 120s 對超大 APK 可能不足——可調；`run` 的並發排空確保大輸出不死鎖（吸取 P1-d 終審教訓）。
