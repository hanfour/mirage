# 首次啟動精靈：app 內下載 SDK 並建立 AVD

- 日期：2026-09-29
- 狀態：設計已確認，待拆實作任務
- 前置：`2026-09-29-instance-manager-design.md`（app 自己啟動模擬器，已合併）
- 對應計畫：`2026-07-22-mirage-project-plan.md` §5「首次啟動自動下載映像並建立實例」

## 1. 目標

一台沒有 Android SDK 的 Mac，從 Finder 打開 Mirage，照畫面按下去就能開到 Android 桌面，不需要終端機、Python 或 Android Studio。

完成後的判準：在一個全新的 HOME（沒有 SDK、沒有 AVD）啟動 Mirage，精靈出現；按下開始並完成後，模擬器自動開機到 `running`；再次啟動 Mirage 不出現精靈。

## 2. 範圍

要做：

1. 版本鎖定與 AVD 設定移到一份 JSON，`provision.py` 與 app 共用。
2. app 的 SDK 與 AVD 位置改為 Mirage 自己的目錄，環境變數可覆寫。
3. app 啟動時檢查 SDK 與 AVD，缺少就顯示精靈，不啟動模擬器。
4. 精靈：說明與授權同意、空間檢查、逐項下載與安裝、進度、取消、失敗重試。
5. 完成後交給啟動器開機。
6. 開發環境的驗證腳本行為不變。

不做：

- 斷點續傳。失敗的那一項重新下載。
- `mirage-poc`（開發量測用的 AVD）。精靈只建 `mirage-game`。
- Google 帳號登入。使用者在 Android 裡自己登入 Play 商店。
- 升級已安裝的 SDK。版本不符時只報告，不覆蓋（與 `provision.py` 不帶 `--upgrade` 時相同）。

## 3. 現況

| 項目 | 現況 |
|---|---|
| 建 SDK 與 AVD | 只有 `tools/provision/provision.py`（Python，需要終端機）。一般使用者的 `/usr/bin/python3` 是空殼，執行會跳出安裝開發者工具的對話框 |
| 版本鎖定 | `tools/provision/lib/versions.py` 的 `PINS`，下載網址在執行時從 Google 的 manifest 解析 |
| AVD 設定 | `tools/provision/lib/config_base.py` 的 `BASE` 加上 `avdspec.py` 的 8 個 overlay 欄位 |
| 已安裝紀錄 | SDK 根目錄的 `.mirage-provision.json`，`{install_path: revision}` |
| SDK 位置 | app（`SdkLocator`）與 `provision.py`（`sdkpaths.sdk_root`）都是 `ANDROID_SDK_ROOT` → `ANDROID_HOME` → `~/Library/Android/sdk` |
| AVD 位置 | `ANDROID_AVD_HOME` → `~/.android/avd` |
| 缺 SDK 或 AVD 時 | 啟動器進 `failed(emulatorNotFound)` 或 `failed(avdNotFound)`，畫面提示執行 `provision.py` |

實測大小（macOS ARM）：

| 套件 | zip | 解壓後 |
|---|---|---|
| emulator 37.1.11 | 395 MB | 1.1 GB |
| platform-tools 37.0.1 | 16 MB | 37 MB |
| system-images android-35 google_apis_playstore arm64-v8a rev 9 | 1.79 GB | 2.1 GB |

## 4. 設計

### 4.1 單一來源：`sdk-spec.json`

新增 `app/Sources/MirageCore/Resources/sdk-spec.json`，內容：

```json
{
  "androidTarget": "android-35",
  "packages": [
    { "manifestKey": "repo", "path": "emulator", "channel": "stable",
      "revision": "37.1.11", "sha1": "…", "size": 394555844,
      "installPath": "emulator", "url": "https://dl.google.com/android/repository/…zip" }
  ],
  "avds": [
    { "name": "mirage-game", "imageManifest": "sysimg_playstore", "playstore": true,
      "tagId": "google_apis_playstore", "tagDisplay": "Google Play" }
  ],
  "configBase": { "abi.type": "arm64-v8a", "…": "…" }
}
```

- `packages` 是現有 `PINS` 的 4 項，多一個 `url` 欄位（完整下載網址）。網址的值由實作時執行一次 `provision.py` 的 manifest 解析取得後寫入。
- `avds` 包含現有的兩台，`configBase` 是現有的 `BASE`。
- `provision.py` 的 `versions.PINS`、`avdspec.SPECS`、`config_base.BASE` 改成讀這份 JSON。`provision.py` 仍然抓 manifest 並比對 sha1 與 size，另外檢查 manifest 解出的網址等於 JSON 的 `url`，不一致就中止，訊息與現有的 pin 漂移相同。
- app 的精靈只安裝 `mirage-game` 需要的三項：emulator、platform-tools、playstore 映像。

`provision.py` 既有的 95 條測試必須全數通過（CI 閘門 6）。

### 4.2 位置

新增 `MirageCore/Lifecycle/MiragePaths.swift`（純函式，環境與家目錄以參數傳入）：

| 目錄 | 優先序 |
|---|---|
| SDK 根目錄 | `ANDROID_SDK_ROOT` → `ANDROID_HOME` → `~/Library/Application Support/Mirage/sdk` |
| AVD 目錄 | `ANDROID_AVD_HOME` → `~/Library/Application Support/Mirage/avd` |
| 下載暫存 | `~/Library/Caches/Mirage/downloads` |

- 空字串視為未設定（與 `sdkpaths._first_non_empty` 相同）。
- `SdkLocator` 的預設退回值改成 `MiragePaths` 的 SDK 根目錄。`LaunchCheck` 的 AVD 目錄改用 `MiragePaths`。
- 啟動器啟動模擬器時，在子行程環境裡設 `ANDROID_SDK_ROOT` 與 `ANDROID_AVD_HOME` 為解析後的值。emulator 靠 `ANDROID_AVD_HOME` 找 AVD，不設的話會去 `~/.android/avd`。`LaunchPlan` 增加 `environment` 欄位。
- `provision.py` 與 `app/scripts/lib/verify_common.sh` 的預設值不改，仍是 `~/Library/Android/sdk` 與 `~/.android/avd`。它們是開發工具，服務的是開發機上的既有環境。`sdkpaths.py` 裡「必須與 AdbClient.swift 一致」的註解改寫為：app 刻意使用自己的目錄，開發環境由 `gui_session.sh` 以環境變數對齊。

### 4.3 開發環境相容

`app/scripts/lib/gui_session.sh` 啟動 app 時，加上
`--env ANDROID_SDK_ROOT=<verify_common 的 SDK 路徑> --env ANDROID_AVD_HOME=<~/.android/avd 或既有覆寫>`。
所有經由 `gui_session.sh` 啟動 app 的驗證腳本因此沿用開發機現有的 SDK 與 AVD，行為不變。實作時要列出所有「不經過 `gui_session.sh` 而直接 `open` Mirage.app」的腳本，逐一補上同樣的環境變數。

在開發機上從 Finder 直接開 Mirage 會看到精靈，這是預期行為。

### 4.4 何時顯示精靈

新增 `MirageCore/Setup/SetupCheck.swift`（純函式，檔案存在與紀錄讀取以參數注入）。輸入 `sdk-spec.json`、SDK 根目錄、AVD 目錄，輸出缺少的項目清單：

- 每個套件：目錄不存在 → 缺少。目錄存在時用與 `fetch.installed_revision` 相同的規則讀版本（`package.xml` 優先，其次 `.mirage-provision.json`）：版本相符 → 已安裝；版本不符或讀不出來 → 視為已安裝但記一行警告，不重新下載（避免覆蓋使用者用其他工具裝的東西）。
- AVD：`<avd 目錄>/mirage-game.ini` 或 `<avd 目錄>/mirage-game.avd/config.ini` 不存在 → 缺少。

`AppModel.prepareInstanceLauncher()` 在建立啟動器之前呼叫 `SetupCheck`。清單不是空的就顯示精靈，不呼叫 `ensureRunning`。有 `MIRAGE_HOST`／`MIRAGE_PORT` 覆寫時不檢查、不顯示精靈（與啟動器相同）。

### 4.5 精靈畫面

一個獨立視窗（`MirageShell/Setup/SetupWindow.swift`），三個階段：

1. 說明
   - 文字：Mirage 需要下載 Android 模擬器與系統映像，列出缺少的項目與合計下載大小。
   - 需要的可用空間與目前可用空間（見 §4.6）。不足時「開始」不可按，並顯示還差多少。
   - Android SDK 授權條款連結（`https://developer.android.com/studio/terms`）與「我同意」勾選框。未勾選時「開始」不可按。
   - 「結束 Mirage」按鈕。
2. 安裝中
   - 每一項一列：名稱、狀態（等待中、下載中 x／y MB、驗證中、解壓縮中、完成、失敗）。
   - 「取消」：停止目前的下載、刪掉暫存檔，回到說明階段。已完成的項目保留。
3. 結果
   - 成功：顯示「完成」，1 秒後關閉精靈並交給啟動器（`ensureRunning`），接著出現既有的「啟動模擬器中…」提示。
   - 失敗：顯示失敗的項目與原因，按鈕「重試」（從未完成的項目繼續）與「結束 Mirage」。

精靈顯示期間，主視窗的 `ConnectionBanner` 不顯示任何提示（啟動器尚未建立，「未連線」會誤導）。

「開始」能不能按寫成純函式 `SetupGate.canStart(agreed:required:available:)`，由單元測試涵蓋；畫面只讀它的結果。

### 4.6 空間檢查

需要空間 = 缺少套件的 zip 大小總和 × 3.2 + 2 GB（AVD 首次開機的 userdata）。

- 3.2 沿用 `fetch.ensure_space` 的實測倍率（emulator 解壓後 3.12 倍）。
- 三項全缺時約 9 GB。
- 可用空間讀下載暫存目錄所在磁碟區（`URLResourceKey.volumeAvailableCapacityForImportantUsageKey`）。
- 每一項開始下載前再檢查一次該項的 zip × 3.2，不足就失敗並說明，不開始下載。

### 4.7 單一項目的安裝流程

新增 `MirageCore/Setup/PackageInstaller.swift`，每項依序：

1. 下載到 `<下載暫存>/<zip 檔名>.part`（`URLSession` download task，回報進度）。已存在的 `.part` 刪掉重來。
2. 驗證大小等於 `size`、sha1 等於 `sha1`。不符就刪檔並失敗，訊息寫出預期與實際值。
3. 以 `/usr/bin/ditto -x -k <zip> <暫存目錄>` 解壓。暫存目錄建在安裝位置的上層目錄內（同一磁碟區，才能 rename）。
4. 暫存目錄最上層必須恰好一個目錄，否則失敗（與 `fetch.extract_into` 相同）。
5. 安裝位置已存在時先改名為 `<安裝位置>.mirage-old`，把解出的目錄 rename 到安裝位置，成功後刪除 `.mirage-old`；失敗時還原。
6. 更新 `.mirage-provision.json`（讀取、加入這一項、整份寫回，暫存檔加 rename）。
7. 刪除 zip。

`ditto` 會保留檔案權限。`provision.py` 第一次真下載時，Python 的解壓丟掉了 `adb` 的執行權限，因此 §6 的測試必須用帶 755 權限的真 zip 驗證這一點。

### 4.8 建立 AVD

新增 `MirageCore/Setup/AvdWriter.swift`：

- `config.ini`：`configBase` 疊上 overlay 8 個欄位（`avd.id`、`avd.name`、`image.sysdir.1`、`PlayStore.enabled`、`tag.id`、`tag.ids`、`tag.display`、`tag.displaynames`），key 排序後以 `key = value` 輸出。`image.sysdir.1` 是 SDK 根目錄的絕對路徑加映像的 `installPath` 再加 `/`。
- 指標檔 `<avd 目錄>/mirage-game.ini`：`key=value` 無空格，內容與 `config_ini.render_pointer_ini` 相同。
- 兩個檔都用暫存檔加 rename 寫入。`mirage-game.avd/` 目錄不存在時建立。
- 與 Python 的一致性以測試鎖住：同一份 JSON 與同一個 SDK 路徑，Swift 產出的兩個檔案與 `config_ini.render_config`／`render_pointer_ini` 的輸出逐字相同（見 §6）。

### 4.9 流程控制

新增 `MirageShell/Setup/SetupController.swift`：依序安裝缺少的套件，最後建立 AVD；對外提供階段與每項狀態給畫面；取消與重試。全部完成後重新執行 `SetupCheck`，清單為空才算成功，再交給 `prepareInstanceLauncher` 繼續。

每次狀態改變印一行 `[setup] <項目> <狀態>`，完成時印 `[setup] done`，驗證腳本以此判斷。

## 5. 相容性

- 開發機上的驗證腳本：經由 §4.3 的環境變數沿用既有 SDK 與 AVD。
- 已經在跑的外部模擬器（`emu.sh` 開的）：`SetupCheck` 在 `prepareInstanceLauncher` 裡、目標實例已在跑時不檢查、直接視為外部實例，避免開發機因為 Mirage 目錄沒有 SDK 而跳出精靈。
- `provision.py`：改讀 JSON 後，行為與輸出不變，95 條測試照跑。
- `LaunchCheck` 的 `emulatorNotFound`／`avdNotFound` 仍保留（例如使用者刪了 SDK 目錄），提示文字改成「重新開啟 Mirage 以執行設定」。

## 6. 測試

單元測試（不需要網路與模擬器）：

- `MiragePaths`：三個目錄的優先序、空字串視為未設定。
- `sdk-spec.json` 解析：欄位齊全、缺欄位時報錯。另加一條：Swift 讀出的 4 個套件與 Python `versions.PINS` 相同（Python 端測試讀 JSON 後比對；Swift 端測試比對 revision 與 sha1 的固定值）。
- `SetupCheck`：全缺、全有、只缺 AVD、版本不符（記警告、不列入缺少）、`package.xml` 優先於紀錄檔。
- 空間計算：全缺約 9 GB 的算式、部分已裝時只算缺少的項目。
- `SetupGate.canStart`：未同意、空間不足、兩者都滿足三種情況。
- `AvdWriter`：與 Python 輸出逐字相同。做法是在 `tools/provision/tests/` 產生 golden 檔（用固定的 SDK 路徑 `/tmp/mirage-sdk` 與 AVD 路徑 `/tmp/mirage-avd`），放進 `app/Tests/MirageCoreTests/Fixtures/`，Swift 測試讀它比對。Python 端另有一條測試確認 golden 檔與目前的 `render_config` 輸出相同，避免 golden 過期。
- `PackageInstaller`：測試內用 SwiftNIO（專案已依賴）起一個本機 HTTP server，提供一個由 `/usr/bin/zip` 從帶 755 權限檔案做出的小 zip：
  - 下載、驗證、解壓、就位、紀錄、刪 zip 全流程成功，解出的檔案保有 755 權限。
  - sha1 不符 → 失敗、沒有留下 `.part`、安裝位置不變。
  - zip 最上層有兩個項目 → 失敗、安裝位置不變。
  - 安裝位置已存在舊目錄且解壓失敗 → 舊目錄還原。
- `SetupController`：注入假的 installer，驗證順序（三個套件後才寫 AVD）、取消後回到說明階段且已完成項目保留、重試只做未完成的項目。

實機驗證，新增 `app/scripts/verify_first_run.sh`：

| 情境 | 做法 | 判準 |
|---|---|---|
| S1 本機假套件 | 以測試用的 `sdk-spec.json`（環境變數 `MIRAGE_SDK_SPEC_FILE` 覆寫，只供測試）指向本機 HTTP server 上的小 zip，暫存 HOME | 精靈出現、log 依序出現各項完成與 `[setup] done`、`SetupCheck` 再跑為空 |
| S2 真下載 | 不覆寫 spec，暫存目錄當 `ANDROID_SDK_ROOT`／`ANDROID_AVD_HOME`，真的從 Google 下載 2.2 GB | `[setup] done` 後 150 秒內啟動器進 `running` |
| S3 第二次啟動 | 接在 S2 之後重開 app | 不出現精靈，直接進 `running` |
| S4 空間不足 | 以測試用環境變數把可用空間假裝成 1 GB | 「開始」不可按，log 印出需要與可用空間 |

S2 只由 PM 手動執行一次（磁碟需約 9 GB，本機可用 13 GB），驗證後刪除暫存目錄。S1、S3、S4 每個至少跑兩次。

腳本以只供測試用的環境變數 `MIRAGE_SETUP_AUTOSTART=1` 讓精靈跳過說明階段直接開始，不用 CGEvent 點畫面（按鈕位置會隨版面改變）。說明階段的按鈕啟用規則由 `SetupGate` 的單元測試涵蓋。S4 不設 autostart，判準看 log 裡 `[setup] gate` 那一行（`canStart=false required=… available=…`）。

## 7. 實作任務

依序做，每項完成都要過 `ci.sh`：

1. `sdk-spec.json` 與 `provision.py` 改讀它（含 `url` 欄位與 manifest 比對、golden 檔產生與 Python 端測試）。
2. `MiragePaths`、`SdkLocator`／`LaunchCheck`／`LaunchPlan` 改用它、啟動器對子行程設環境變數、`gui_session.sh` 與其他直接 `open` 的腳本補環境變數。
3. `SetupCheck`、空間計算、`AvdWriter` 與單元測試（含 golden 比對）。
4. `PackageInstaller` 與本機 HTTP server 測試。
5. `SetupController`、精靈視窗、接進 `prepareInstanceLauncher`。
6. `verify_first_run.sh`，S1、S3、S4 各跑兩次，S2 跑一次，結果寫進 `app/RESULTS-first-run.md`。
