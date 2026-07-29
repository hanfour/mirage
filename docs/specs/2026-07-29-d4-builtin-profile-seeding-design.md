# D4 內建 profile 上架與死路徑清除 設計

- **日期**：2026-07-29
- **債務編號**：D4（`2026-07-29-project-review.md` §2，P1）
- **狀態**：設計待實作

## 1. 問題

D4 記載兩件事：「內建 profile 沒進 bundle」＋「`AppModel.gameId` 寫死 `com.example.game`」，
擋住的是「`.auto` 自動啟用端到端不可能通；指標遊戲沒有可用 profile」。

逐項查證後，**其中一項不成立，另一項比記載的更具體**。

### 1.1 內建 profile 確實進不了 bundle（成立）

`app/Resources/profiles/com.example.game.json` 存在於磁碟，但：

- `app/Package.swift` 的 MirageCore target **無 `resources:` 宣告**
- 全碼庫**零 `Bundle.module`**
- SPM 的資源必須位於 target 目錄之下，而 `app/Resources/` 在 `Sources/MirageCore/` **之外**

所以那個檔案對建置系統而言不存在，永遠到不了使用者的
`~/Library/Application Support/Mirage/profiles/`。

### 1.2 寫死的 `gameId` 是**過期的死路徑**（比記載更具體）

`AppModel.swift:57-59` 的註解寫「目前哪個 game 在跑（gameId）**尚未有偵測機制**，先寫死」。
**那句話已經過期**：P1-d 加了 `GameDetector` → `ForegroundParser` → `currentPackage`，
而 `applyActivation()`（`AppModel.swift:194`）用的正是 `currentPackage`。

於是 `loadKeymap()`（`:99`）那次以寫死 id 進行的載入，是一條與偵測並存、且語意錯誤的路徑：
它會在啟動時載入 `com.example.game` 的 profile，不管使用者實際在玩什麼。

> **本節（§1.2）的三個行號是 D4 動手前（`818f80f`）的位置，不是現在的位置。** 那條死路徑
> 已於 2026-07-30 整段刪除，`AppModel.swift:57-59` 現在是 `start()` 的開頭。對應的現況：
> `applyActivation()` 在 `AppModel.swift:220`、`loadKeymap()` 在 `:126`（只建
> `KeymapController(profile: nil)`，不再讀 store），刪除的理由寫在 `:118-125` 的更正註解。

### 1.3 「指標遊戲沒有可用 profile」——**這一項不成立**

Phase-1 的指標遊戲是 **Pixel Flow**（`com.loomgames.pixelflow`，recon 判定唯一可遊玩的一款）。
2026-07-29 在 `game` AVD（`emulator-5556`）上實際啟動並玩到關卡盤面，觀察到：

- 它是**關卡制方塊拼圖**：關卡地圖 → 進關 → 盤面放置方塊
- 操作**全部是點擊與拖曳**——沒有移動、沒有瞄準、沒有同時多鍵
- **拖曳是滑鼠手勢，不是 keymap 能表達的東西**

而「無 profile → `MirrorView.Coordinator.sendMouse` 走 P1-a 直接 tap」這條路徑本來就通，
**這正是驗收線「1 款指標遊戲開箱即玩」已經是 ✅ 的原因**。

**結論：為 Pixel Flow 做一份 keymap profile 是在解一個不存在的問題**，硬套 WASD 版面反而有害。
D4 剩下的真問題只有 1.1 與 1.2。

> **調查過程中一個差點犯的錯，記下來**：關卡地圖上連兩次 gRPC tap 沒反應，
> 改用 `adb shell input tap` 同座標立刻進關——我一度要下結論「gRPC 觸控注入對這款遊戲無效」。
> 但那兩次 gRPC tap 與 adb tap 之間隔了數十秒，**時間是混淆因子**。
> 改做同狀態 A/B（在一個靜止的 modal 上先送 gRPC tap）後，gRPC **正常生效**。
> 先前的失敗成因未確立（很可能是地圖畫面仍在結算），**不寫成結論**。
> 這正是本專案一再犯的相關當因果——差別只在這次先做了對照。

## 2. 設計決定

| # | 決定 | 理由 |
|---|---|---|
| D-1 | **只修機制，不做遊戲內容** | 見 §1.3。Pixel Flow 不需要 profile |
| D-2 | 資源放 **MirageCore**（`Bundle.module`），不是 App bundle | `ProfileStore` 在 Core、測試也在 Core，`Bundle.module` 兩邊都拿得到 |
| D-3 | seeding 策略：**不存在才複製，永不覆寫** | 使用者的編輯永遠不會被吃掉。代價是 App 升級帶來的新版內建 profile 不會覆蓋舊使用者的副本——接受，換來零版本遷移機制與可預測行為 |
| D-4 | seeding 寫成**可測的純函式**，不塞進 `ProfileStore.standard()` | 工廠方法裡做檔案 I/O 是隱藏副作用，且每次呼叫都會跑 |
| D-5 | 範例 profile 的 `gameId` 維持 `com.example.game` | `com.example.*` 是保留給範例的網域，它自我說明「這不是真實遊戲」。但必須在文件與檔案旁寫明 |
| D-6 | 刪掉 `AppModel` 的寫死 `gameId` 與那次啟動載入 | 見 §1.2。偵測是唯一的真實來源 |

## 3. 架構

### 3.1 新增：`MirageCore/Keymap/BuiltInProfiles.swift`

```
public enum BuiltInProfiles {
    /// 把來源檔案複製進 store 目錄，**已存在者不動**。
    /// 回傳實際複製了哪些 gameId（空陣列＝全都已存在）。
    @discardableResult
    public static func seed(into directory: URL, from sources: [URL]) -> [String]

    /// bundle 內建的 profile 檔案清單。唯一碰 Bundle.module 的地方。
    public static func bundledSources() -> [URL]
}
```

`seed(into:from:)` 的兩個參數都是呼叫端給的 URL，所以可以用暫存目錄逐條單元測試：
已存在不覆寫、來源不存在、目的目錄不存在、來源不是合法 JSON。

`bundledSources()` 是唯一不可單元測試的一行（`Bundle.module` 查表），刻意獨立成一個函式，
讓不可測的面積縮到最小。

### 3.2 資源搬遷

`app/Resources/profiles/` → `app/Sources/MirageCore/Resources/profiles/`
（SPM 要求資源位於 target 目錄之下），`Package.swift` 的 MirageCore target 加：

```swift
resources: [.copy("Resources/profiles")]
```

用 `.copy` 而非 `.process`：profile 是 JSON，不需要任何編譯期處理，`.copy` 保持目錄結構原樣。

### 3.3 `AppModel` 的兩處改動

**（a）啟動時 seeding**：在 `loadKeymap()` 之前呼叫一次
`BuiltInProfiles.seed(into: <store 目錄>, from: BuiltInProfiles.bundledSources())`。
複製了什麼要 `print` 一行——沒有這行，「內建 profile 有沒有到位」又會變成只能靠翻檔案系統才知道的事。

**（b）刪掉死路徑**：`static let gameId` 與 `loadKeymap()` 裡那次 `load(gameId: Self.gameId)`。

`loadKeymap()` **不能整段刪**——它同時負責建立 `KeymapController` 與更新游標捕捉。
改成建立不帶 profile 的 controller，由偵測（`applyActivation` → `keymap?.reload(p)`）填入。

### 3.4 一個要講明的行為改變

拿掉寫死載入後，**在沒有 adb 的環境下使用者將完全不會有 profile**
（`AdbClient.standard()` 無 adb 時靜默不偵測，`currentPackage` 恆為 nil）。

先前那條路徑會載入 `com.example.game`——但那本來就是錯的：它不管使用者在玩什麼都載入同一份。

逃生出口是既有的選單列「套用 profile ▸」手動覆寫（`MenuBarController.menuNeedsUpdate` 掃描
store 目錄）。**這是刻意的取捨**：寧可沒有 profile，也不要載入一個與當前遊戲無關的 profile。

順帶：`MenuBarController.availableGameIds()`（`:122`）的
`ids.isEmpty ? ["com.example.game"] : ids` 在 seeding 之後永遠走不到 fallback 分支
（目錄至少有範例那一份）。無害，不動它，但值得知道。

## 4. 驗收的誠實切分

**這一輪不會讓 `.auto` 端到端變成可自動驗證的，而且原因不是懶。**

`.auto` 要求 profile 的 `gameId` **對得上偵測到的前景 package**。範例 profile 是
`com.example.game`，不對應任何真實 App——**所以 seeding 修好之後，`.auto` 仍然永遠不會為它啟用**。
要端到端驗 `.auto`，需要一份以真實 package 命名的 profile，而那屬於遊戲內容（D-1 已排除）。

| 層 | 驗什麼 | 怎麼驗 |
|---|---|---|
| `BuiltInProfiles.seed` | 已存在不覆寫、來源缺失、目錄不存在、複製後內容相同 | 暫存目錄，MirageCore 純單元 |
| bundle → 檔案系統 | `bundledSources()` 真的找得到檔案；種下去的檔案能被 `ProfileStore.load` 讀回 | 單元測試——**但見下方的未驗證假設** |
| App 層接線 | `applyActivation` → `keymap?.reload` | **不可自動驗**，見下 |

### 4.1 一個未驗證的假設，實作時要先擋掉

本設計假設 **`Bundle.module` 在 `MirageCoreTests` 執行時找得到資源**（SwiftPM 會為測試
一併複製 target 的資源 bundle）。**我沒有驗證過這件事**——它是「照理應該可行」，
而這個 repo 剛為一批「照理應該可行」的宣稱付過學費。

**實作計畫的第一個 task 必須先驗這件事**：搬資源、改 `Package.swift`、寫一條只斷言
「`Bundle.module` 找得到那個檔案」的測試，跑通了才往下做。若不可行（例如測試 target
拿不到 MirageCore 的資源 bundle），**停下來回報**，不要繞路（例如改用絕對路徑、
或把資源複製進測試 target）——繞路會讓「產品能不能拿到資源」這件事繼續沒被驗證，
而那正是 D4 本身的成因。

**App 層接線屬 `2026-07-29-project-review.md` §8 D 節的第三類「可以驗了但沒人回頭驗」**
（阻礙 `AVAudioEngine` NSException 已於 2026-07-28 修復）。具體驗法：

1. 手動放一份以真實 package 命名的 profile 進 `~/Library/Application Support/Mirage/profiles/`
   （例如 `com.google.android.apps.nexuslauncher.json`，那是模擬器上一定存在的桌面）
2. 用 `.app` bundle + `open` 啟動 Mirage（**不要**從 shell 直接跑 executable）
3. 把該 App 帶到前景，看選單列的「遊戲：… [keymap ✓]」是否切換

**不得**把 D4 標成「`.auto` 端到端已驗」。

> **⚠️ 補記（2026-07-30）：上面第 2 步在有 `.build/` 的開發機上，結構上無法證明資源已進 bundle。**
>
> SwiftPM 產生的 `Bundle.module` 存取器（`app/.build/arm64-apple-macosx/debug/
> MirageCore.build/DerivedSources/resource_bundle_accessor.swift:5-13`）依序試兩條路徑：
> `Bundle.main.bundleURL/Mirage_MirageCore.bundle`，然後是**編譯當下寫死的
> `.build/…/Mirage_MirageCore.bundle` 絕對路徑**；兩條都不中才 `Swift.fatalError`。
>
> 而全 repo 唯一組裝 `.app` 的地方（`app/scripts/verify_game_fps.sh:81-82`）**只
> `cp` executable，不複製 resource bundle**。所以在這台機器上 `.app` 照跑、profile 照樣
> 種得下去——**但那是從 `.build/` 讀的**，不是從 `.app` 裡讀的。換一台機器、或
> `swift package clean` 之後，同一個 `.app` 會**啟動即崩**（fatalError，不是空陣列）。
>
> **一個測不出目標缺陷的驗證步驟，正是本專案要根治的那種東西。** 這一步能驗
> 「seeding 接線對不對」，**不能**驗「資源打包對不對」。後者目前只有
> `BuiltInProfilesTests.bundleContainsSampleProfile` 在守（測試 bundle，不是 `.app`），
> 而 `.app` 的打包路徑無人守——已記入 `2026-07-29-project-review.md` 債務表 **D25**。
> 這裡不修打包流程：這個 repo 目前沒有發佈流程，補一個是另一輪的事。

## 5. 不做什麼（YAGNI）

- **不做版本遷移**：`KeymapProfile.version` 存在，但拿它做「內建版較新就提示／覆寫」需要遷移邏輯與 UI，而目前連一份真實遊戲的 profile 都還沒有。過度設計。
- **不為 Pixel Flow 做 profile**：見 §1.3。
- **不動 `MenuBarController` 的 fallback**：它變成走不到的分支，但無害。
- ~~**不改 `ProfileStore`**：seeding 是新責任，放新型別，不往既有型別上疊。~~

  > **⚠️ 更正（2026-07-30）：這一條在實作時被有意識地推翻了，設計文件先前沒跟上。**
  > 實作在 `ProfileStore` 上新增了 `public static func standardDirectory()`
  > （`ProfileStore.swift:19-22`；計畫 Task 3 明列），所以「不改 `ProfileStore`」現在
  > 對碼庫做了一個不成立的宣稱。
  >
  > **為什麼推翻是對的**：原本這條要防的是「把 seeding 的責任疊到 `ProfileStore` 上」
  > ——那個顧慮仍然成立，`seed()` 到今天還是住在 `BuiltInProfiles`，`ProfileStore`
  > 一行 seeding 邏輯都沒有。但 `standardDirectory()` 不是新責任，它是**把既有知識
  > 暴露出來**：`ProfileStore.standard()` 本來就知道「Mirage/profiles 在哪」，只是把它
  > 埋在函式體裡。seeding 的目的地必須與 `ProfileStore` 讀取的目錄**是同一個**，若不
  > 暴露就得讓呼叫端自己再拼一次 `"Mirage/profiles"`——那才是真正的架構問題（兩份
  > 同樣的知識遲早漂移，這個 repo 剛因為 `EmulatorEndpoint` 的解析有兩份而吃過虧）。
  >
  > **暴露既有知識 ≠ 疊加新責任。** 抽 `standardDirectory()` 之後
  > `MenuBarController.availableGameIds()`（`MenuBarController.swift:123`）也改用它，
  > 路徑複本從三份降到一份。YAGNI 防的是「還用不到的東西」，不是「已經有兩個呼叫端
  > 的東西」。

## 6. 驗收

1. `swift test` 全綠，`BuiltInProfiles` 逐行覆蓋。
2. 建置後 `Bundle.module` 找得到範例 profile（單元測試斷言，不是靠翻檔案系統）。
3. 全新環境（清空 store 目錄）跑一次 App 後，`~/Library/Application Support/Mirage/profiles/com.example.game.json` 存在且內容與 bundle 內相同。
4. 使用者修改過的 profile 在第二次啟動後**未被覆寫**。
5. `app/scripts/ci.sh` 三道閘門全過。
6. 全碼庫零 `AppModel.gameId` 殘留。
