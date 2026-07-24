# P1-d 遊戲偵測與 keymap 啟用 設計文件

## 1. 目標

把 P1-c 的「休眠預設」鍵位映射升級為**自動生效**：偵測前景執行的遊戲（package）→ 載入對應 profile → 讓 keymap 引擎接管輸入；無對應 profile 時退回 P1-a 直接 mouse→tap。並吸收 P1-c 交接的兩個 fast-follow：MouseCapture 游標陷阱修復、app 層輸入路徑（NSEvent→引擎→注入）端到端活體驗證。

**非目標（留後續階段）**：三款指標遊戲實玩、60fps/延遲量測、APK 安裝、全螢幕模式、音訊、真實遊戲的 profile 內容調校（本件用既有 `com.example.game` 佔位 profile + 可注入的偵測序列驗證邏輯）。

## 2. 全域約束（延續 P1-a/b/c）

- 平台 macOS 14+ Apple Silicon；`swift build -c release` 零非-deprecation 警告。
- **MirageCore 不得 import AppKit/SwiftUI/Metal**，不 `fatalError`；錯誤回傳/記錄，App 層決定呈現。
- 所有 target 開 `-strict-concurrency=complete`；`.swiftLanguageMode(.v5)`。
- 測試語法用 swift-testing（`@Suite struct`/`@Test func`/`#expect`）；每檔 <400 行、函式 <50 行；純邏輯與 UI 膠水嚴格分離；不可變優先。
- TDD：先寫失敗測試→確認失敗→最小實作→綠→commit。Conventional commits、無 attribution。
- MirageCore 覆蓋 ≥80%；既有測試（P1-a/b/c，合併後 79 個）不回歸。
- 活體測試預設 skip、環境變數開啟（`MIRAGE_LIVE`）；adb 指令一律以 `ANDROID_SERIAL=emulator-5554` 鎖定模擬器（避開實體手機干擾，見專案記憶）。
- **零 proto 遷移**：偵測走 adb（host 工具），非 gRPC——實測 emulator gRPC 無前景-app RPC（僅 `getDisplayConfigurations`/`getDisplayMode`/`getStatus`）。

## 3. 檔案結構

```
app/Sources/MirageCore/Keymap/
├── ForegroundParser.swift        # 純函式：dumpsys 輸出 → 前景 package（可單元測試）
└── ActivationDecider.swift       # 純 reducer：偵測+已載 profile+手動鎖定 → 啟用決策（可單元測試）
app/Sources/MirageApp/Detect/
├── GameDetector.swift            # @MainActor：adb dumpsys 輪詢 + 解析 + 變動回呼
└── AdbClient.swift               # adb 子行程薄封裝（逾時、ANDROID_SERIAL、錯誤降級）
app/Sources/MirageApp/
├── MirageApp.swift               # 修改：AppModel 接 GameDetector→(載 profile)→ActivationDecider→套用
└── Keymap/
    ├── KeymapController.swift     # 修改：reload(profile:) 已存在（P1-c），確認 reload(nil) deactivate 語意
    └── MouseCapture.swift         # 修改：window-key gating + resignKey release
app/Sources/MirageApp/Lifecycle/
└── MenuBarController.swift        # 修改：顯示目前遊戲 + 手動強制/停用 profile
app/Tests/MirageCoreTests/
├── ForegroundParserTests.swift    # 純解析單元
└── ActivationDeciderTests.swift   # 啟用決策：偵測+profile 有無+手動鎖定 序列 → 正確決策
app/scripts/
└── verify_keymap_inject.sh        # 活體 harness（Core KeymapEngine→sendTouches→show_touches；見 §4.7 限制）
app/RESULTS-p1d.md                 # 驗收
```

**測試 target 說明**：所有可單元測試的決策邏輯（`ForegroundParser`、`ActivationDecider`）皆為 **MirageCore 純型別**，於既有 `MirageCoreTests` 測——**不新建 MirageApp 測試 target**（App 層 `GameDetector`/`AdbClient`/選單列/MouseCapture 為薄膠水，正確性靠 Core 決策覆蓋 + 活體 + pending-human）。

## 4. 元件設計

### 4.1 ForegroundParser（MirageCore，純函式）

```
enum ForegroundParser {
    /// 從 `adb shell dumpsys activity activities` 輸出解析前景 package。
    /// 取 topResumedActivity/ResumedActivity 行的 `pkg/.Activity`，回 package（"com.x.game"）。
    /// 無法解析或無前景 → nil。
    static func foregroundPackage(fromDumpsys output: String) -> String?
}
```

- 純字串解析、無副作用、無 AppKit/adb 依賴 → MirageCore、可窮舉單元測試（正常、系統 UI、多行、空、格式變異）。
- 系統 package（launcher `com.android.launcher3`、`NotificationShade` 等）照常回傳其 package——由上層「無 profile → 退 tap」自然處理，parser 不特判。

### 4.2 AdbClient（MirageApp，adb 子行程薄封裝）

```
struct AdbClient {                     // 非 @MainActor；純執行
    init(adbPath: URL, serial: String) // serial = "emulator-5554"
    func dumpsysActivities() async -> String?   // 逾時（~2s）；失敗/逾時 → nil（降級，不擲錯）
}
```

- 用 `Process` 執行 `adb -s <serial> shell dumpsys activity activities`；`ANDROID_SDK_ROOT` 推導 adb 路徑。
- 逾時與非零退出 → 回 nil（偵測層降級，見 §5）。

### 4.3 GameDetector（MirageApp，@MainActor）

```
@MainActor final class GameDetector {
    init(adb: AdbClient, interval: Duration = .milliseconds(1500),
         onChange: @escaping (String?) -> Void)  // package 變動時回呼（nil = 無前景/adb 失敗）
    func start(); func stop()
}
```

- Timer 輪詢（仿 P1-b `ClipboardWatcher`）：每 tick `await adb.dumpsysActivities()` → `ForegroundParser.foregroundPackage` → 與上次比較，**變動才** `onChange`。
- adb 連續失敗 → 回報 nil 一次（去抖），不狂洗。

### 4.4 ActivationDecider（MirageCore，純 reducer）+ 啟用協調（AppModel）

**純決策（Core，可窮舉測試）**——把「該不該啟用、用哪個 profile」與 I/O 分離：

```
enum ManualOverride: Equatable { case auto, force(KeymapProfile), disabled }
enum Activation: Equatable { case active(KeymapProfile), inactive }

enum ActivationDecider {
    /// detected：偵測到的前景 package（nil=無/adb 失敗）；
    /// loadedProfile：App 已對 detected 做 ProfileStore.load 的結果（nil=無/失敗）；
    /// override：手動鎖定狀態。純函式，無 I/O。
    static func decide(detected: String?, loadedProfile: KeymapProfile?,
                       override: ManualOverride) -> Activation
}
```

決策語意：`.force(p)` → `.active(p)`（手動優先，無視偵測）；`.disabled` → `.inactive`；`.auto` → `loadedProfile.map { .active($0) } ?? .inactive`。

**啟用協調（AppModel，薄膠水）**：`GameDetector.onChange(package)` →（有值才）`ProfileStore.standard().load(gameId: package)`（I/O，失敗回 nil）→ `ActivationDecider.decide(...)` → `.active(p)`：`keymap.reload(p)`；`.inactive`：`keymap.reload(nil)`（→ `hasProfile==false` → MirrorView 退 P1-a tap）→ 更新選單列。靜默無彈窗。
手動覆蓋（§4.5 選單列）改 `ManualOverride`，自動偵測期間 decider 讓其優先，直到「恢復自動」清為 `.auto`。

### 4.5 選單列覆蓋（MenuBarController 擴充）

- 新增區塊：「目前遊戲：`<package>`　[✓ profile / ✗ 無 profile]」。
- 「套用 profile ▸」子選單（列出 `ProfileStore` 內可用 gameId）供手動強制；「停用 keymap」項。
- 手動選擇設「手動鎖定」；「恢復自動偵測」項清除。

### 4.6 MouseCapture 修正（P1-c fast-follow）

- `capture()` 前置條件收緊：**僅在** app 視窗為 key（frontmost）**且** 當前 profile 含 look binding **且** 非編輯模式時才 `CGAssociateMouseAndMouseCursorPosition(0)`+`NSCursor.hide()`。
- 監聽 `NSWindow.didResignKeyNotification`（或 `windowDidResignKey`）→ `release()`；`didBecomeKey` 時若條件成立才重捕捉。
- 消除 P1-c 的「profile active 時 alt-tab 游標鎖死」。

### 4.7 App-path 活體驗（P1-c fast-follow，誠實範圍）

**限制**：`KeymapController` 位於 MirageApp **executable** target（不可 `import`），故 harness 無法建它；`NSEvent→KeyCode` 抽取在 `MirrorMTKView`（AppKit/GUI）。因此「完整 app-path 端到端」無法 headless 驗——這是 P1-c 已知的休眠→啟用轉換風險，本件誠實切分而非假裝驗到：

- **harness 能驗（Core 注入鏈）**：`verify_keymap_inject.sh` + `MIRAGE_LIVE`-gated 測試——建 `KeymapEngine`（Core）+ 真 `EmulatorClient`，餵合成 `InputEvent` 序列（keyDown W → mouseMove → keyDown 技能）→ 取 `TouchFrame` → `sendTouches` → `show_touches` 擷圖佐證引擎→注入。此為 P1-c `MultiTouchLiveTests` 的延伸（多了 joystick/look/連續事件的引擎驅動），增量有限但補上「引擎狀態序列→多指注入」的活體證。
- **pending-human（App glue）**：`KeymapController`（hasProfile gating/編輯暫停/frameSizeProvider）與 `MirrorMTKView` 的 `NSEvent→KeyCode` 抽取，需真 GUI session——列 pending-human。**若要 headless 驗 `KeymapController`，須先把它抽到可 import 的 library target（本件範圍外，記為後續選項）。**

## 5. 錯誤處理

- adb 不可用/逾時/非零退出 → `AdbClient` 回 nil → `GameDetector` 回報 nil（偵測降級）→ 啟用協調視為「無前景」→ keymap 維持（若手動鎖定）或退 tap；**不崩、不狂洗 log**。
- `ForegroundParser` 無法解析 → nil（保守）。
- `ProfileStore.load` 失敗（無檔/損壞/schema）→ 視為無 profile → 退 tap（P1-a 不回歸），錯誤記錄不彈窗。
- MouseCapture 條件不成立 → 不捕捉（安全預設）；deinit/resignKey 一律還原游標。

## 6. 測試

- `ForegroundParserTests`（MirageCore 純單元）：正常前景、launcher/系統 UI、多 activity 行、空輸出、格式變異、無 ResumedActivity → nil。
- `ActivationDeciderTests`（MirageCore 純單元）：`.auto`+有 profile→active；`.auto`+無→inactive；`.force(p)`→active(p)（無視偵測/loadedProfile）；`.disabled`→inactive；偵測序列（game→launcher→game）驅動的決策正確。
- `AdbClient`：逾時/失敗 → nil（可注入假 runner 測降級；真 adb 走活體）——若薄到不值一測則活體覆蓋。
- App-path harness（活體）：合成 InputEvent→引擎→sendTouches→show_touches 佐證（§4.7 Core 範圍）。
- pending-human：真 GUI NSEvent 抽取、`KeymapController`/MouseCapture GUI 行為、真遊戲偵測→套用手感。

## 7. 驗收線

| # | 驗收線 | 量測 |
|---|---|---|
| 1 | ForegroundParser + 啟用邏輯單元全綠、MirageCore 覆蓋 ≥80%、release 零警告、既有 79 不回歸 | 單元 |
| 2 | 活體：模擬器前景切換（launcher ↔ 有 profile 的 package）→ GameDetector 回報正確 package、啟用協調正確 active/deactivate | 活體（adb 實測 + 注入假 package 或既有 app）|
| 3 | App-path harness：合成 InputEvent → sendTouches → show_touches 見對應觸點（controller→引擎→注入活體證） | 活體 harness + 擷圖 |
| 4 | MouseCapture：非 key window 時不捕捉游標；resignKey 還原（無 alt-tab 鎖死） | 結構 + pending-human GUI |
| 5 | 無 profile / adb 失敗 → 退回 P1-a 直接 tap（不回歸、不崩） | 單元 + 活體 |
| 6 | pending-human：真 GUI NSEvent 抽取、真遊戲偵測→套用→實玩手感 | pending-human |

## 8. 與 P1-a/b/c 整合面 + 風險

- 改 `MirageApp.swift`（AppModel 接 GameDetector）、`MenuBarController`（接 P1-b 選單列，新增區塊）、`MouseCapture`（P1-c）、`KeymapController`（確認 `reload(nil)` deactivate 語意）——皆 App 層，與 P1-b 生命週期/剪貼簿、P1-c 引擎不同區域，additive 為主。
- MirageCore 僅新增 `ForegroundParser`（純），不動既有。
- **風險**：偵測輪詢（1.5s adb 子行程）耗用——用去抖 + 逾時界定，量測其 CPU；若有感再調 interval 或改事件式。
- **風險**：`gameId == package` 假設——P1-c 佔位 profile gameId 為 `com.example.game`（非真 package）；本件驗證用「注入假 package 序列」或臨時對某真在跑的 package 建 profile 來端到端驗；真遊戲 profile 內容留後續。
- **休眠→啟用轉換**：本件正是讓 P1-c 由休眠轉 active，故 app 層 keymap 路徑首度被真正驅動——§4.7 harness + pending-human GUI 為其驗證。
