# APK 拖放安裝 驗收結果

- **日期**：2026-07-25
- **模擬器**：Android emulator，`emulator-5554`（headless，Android 15／API 35，`wm size` 回報 1080×2400，`ro.product.model=Android SDK built for arm64`）——**執行前已確認只有這台裝置掛載**（`adb devices` 僅列 `emulator-5554 device`，無實體手機干擾），`ANDROID_SERIAL=emulator-5554` 全程顯式匯出
- **工具鏈**：Swift 6（語言模式 v5）、grpc-swift 1.27.5、swift-testing
- **執行**：subagent-driven（Task 1–4 implementer 逐關）＋本 Task 5 於活體模擬器上直接跑腳本、量測覆蓋率、寫驗收文件

## 驗收線逐條裁決（spec §7）

| # | 驗收線 | 實測 | 判定 |
|---|---|---|---|
| 1 | InstallResult 單元全綠、覆蓋 ≥80%、release 零警告、既有 92 不回歸 | `swift test --filter InstallResultTests` **9/9 綠**；`llvm-cov report`（本次重新量測）`InstallResult.swift` line coverage **95.00%**（20 行，1 行未執行；region 93.75%、function 100%）；`swift build -c release 2>&1 \| grep -E 'warning\|error' \| grep -v deprecat` **零輸出（零警告）**；`swift test` 全量 **101/101 綠**（92 基準 + Task 1 新增 9）| ✅ PASS |
| 2 | AdbClient run 重構後 P1-d 偵測不回歸 | 既有測試面：101/101 含 `ForegroundParserTests`/`ActivationDeciderTests`/`AdbOutcomeTests` 全綠。**活體面**（本次重新對活體模擬器執行 `verify_apk_install.sh`）：`dumpsys activity activities` 解析出 `topResumedActivity=ActivityRecord{39cc710 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t16}`——與 P1-d `RESULTS-p1d.md` 驗收 2 同一格式、同一 launcher package，證 Task 2 的 `run(args:timeout:mergeStderr:)` 抽出未改變 `dumpsysForegroundPackage` 的 argv/輸出路徑 | ✅ PASS |
| 3 | 拖/指定 .apk → adb install -r → InstallResult 正確 | **機制活體**（本次真實執行，見下「活體輸出」節）：對真實下載的 APK 執行 `adb -s emulator-5554 install -r <apk>`，原始輸出 `Performing Streamed Install` / `Success`——即 `InstallResult.parse` 會吃到的確切輸入格式，對照 Task 1 `streamedSuccess()` 單元（同輸入 → `.success`）。**解析面**：Task 1 9 個單元窮舉 plain success／streamed success／failure 有無 bracket／adb 錯誤前綴／空字串／未知格式／progress bracket 誤判防呆，皆綠。**完整 app-path（拖放→dropDestination→installAPKs→banner）** 需真 GUI session，見下方 pending-human | ✅ 機制+解析 PASS／full-app pending-human |
| 4 | 拖非 .apk / adb 不可用 → 不崩、明確回饋 | 結構驗證（讀碼確認，非本次新跑測試）：`.dropDestination` 先 `urls.filter { pathExtension == "apk" }`，過濾後為空即 `return false`（不觸發 `installAPKs`，也不崩）；`AppModel.installAPKs` 對 `AdbClient.standard()==nil` 逐一 URL 映射為 `.failure("adb 不可用")` 後直接 `finish`，不進入 `.installing` 狀態、不崩潰、`InstallBanner` 會呈現明確失敗文字。此路徑無獨立單元測試（SwiftUI glue，非 TDD 範圍，Task 3/4 已載明），正確性靠讀碼＋型別系統（無 force-unwrap／`fatalError`）佐證 | ✅ 結構 PASS／無獨立單元 |
| 5 | pending-human：拖放 UI、拖曳高亮、大 APK 體感、完整 app-path | 見下「已知限制／移交」 | ⬜ pending-human |

## 活體輸出（本次於執行中的 emulator-5554 實測，逐字擷取）

### 第一次執行：`./scripts/verify_apk_install.sh`（新模擬器，尚無第三方 app）

```
=== 驗收 2：dumpsys 前景解析（P1-d 不回歸）===
      topResumedActivity=ActivityRecord{39cc710 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t16}

=== 驗收 3：adb install -r 機制（InstallResult.parse 的輸入）===
無可用 APK——請給路徑：verify_apk_install.sh /path/to/app.apk
```
（exit 1——如實記錄。手動確認 `adb -s emulator-5554 shell pm list packages -3` 當下**確實輸出空白**，非腳本 bug。）

### 補測：下載一個真實 APK 再跑（未捏造輸出）

由於這台模擬器是全新的、無任何第三方 app 可供重裝，為了不捏造機制活體，改為下載官方 F-Droid client 安裝檔（`https://f-droid.org/F-Droid.apk`，官方穩定下載連結，非 fixture）到本機暫存，再直接指定路徑重跑：

```
=== 驗收 2：dumpsys 前景解析（P1-d 不回歸）===
      topResumedActivity=ActivityRecord{39cc710 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t16}

=== 驗收 3：adb install -r 機制（InstallResult.parse 的輸入）===
--- adb install -r 原始輸出 ---
Performing Streamed Install
Success
--- 結束（Success → .success；Failure [X] → .failure(X)）---
```

事後以 `adb -s emulator-5554 shell pm list packages -3` 確認 `package:org.fdroid.fdroid` 已真實安裝（非空回報）。

### 第三次執行：不帶參數，驗證腳本的「自動抓現有第三方 app 重裝」分支

安裝 F-Droid 後，第三方套件已非空，重跑一次無參數版本，驗證腳本 Step 1 沒測到的另一條路徑（`pm list packages -3` → `pm path` → `adb pull` → 重裝）：

```
=== 驗收 2：dumpsys 前景解析（P1-d 不回歸）===
      topResumedActivity=ActivityRecord{39cc710 u0 com.android.launcher3/.uioverrides.QuickstepLauncher t16}

=== 驗收 3：adb install -r 機制（InstallResult.parse 的輸入）===
抓到可重裝 APK：org.fdroid.fdroid
--- adb install -r 原始輸出 ---
Performing Streamed Install
Success
--- 結束（Success → .success；Failure [X] → .failure(X)）---
```

三次執行的 `ResumedActivity` 行完全一致（`com.android.launcher3/.uioverrides.QuickstepLauncher`）——因為過程中沒有切換前景 app，這正是預期行為，佐證 dumpsys 解析路徑穩定、無回歸。全程未呼叫 `loadSnapshot` 或任何可能使模擬器崩潰的操作（僅 `dumpsys`/`pm list`/`pm path`/`pull`/`install -r`）。

## 建置與單元（本次重新量測）

```
$ swift build -c release 2>&1 | grep -E 'warning|error' | grep -v deprecat || echo "零警告"
零警告

$ swift test --filter InstallResultTests
✔ Test run with 9 tests passed after 0.001 seconds.

$ swift test
✔ Test run with 101 tests passed after 0.543 seconds.
```

`swift test` 輸出中出現數行 `ERROR: Cannot schedule tasks on an EventLoop that has already shut down.`——這是既有、已文件化的 SwiftNIO teardown race 背景雜訊（見專案記憶 `nio-teardown-injectable-channel-debt.md` 與 Task 2/3/4 report 已記載），非本次改動引入，所有測試仍標記 `passed`。

### 覆蓋率（`llvm-cov report`，本次針對 `InstallResultTests` 量測）

| 檔 | Line 覆蓋 |
|---|---|
| InstallResult.swift | 95.00%（20 行，1 行未執行；region 93.75%、function 100%） |

## 已知限制／移交

- **完整 app-path pending-human**：拖放 `.apk` 到視窗 → `.dropDestination` → `AppModel.installAPKs` → `InstallBanner` 呈現，這條鏈需要真 GUI session（有顯示器、能實際拖檔案）才能端到端驗證；本機目前只能驗證「機制」（adb install -r 原始輸出）+ 「解析」（InstallResult.parse 單元）兩端，中間的 SwiftUI 拖放接線靠讀碼＋型別系統佐證，非活體跑過。
- **拖放 UI 手感 pending-human**：實際拖曳一個或多個 `.apk` 到視窗時的游標回饋、視窗是否正確接受 drop，需真 GUI session。
- **`isTargeted` 拖曳高亮 pending-human**：Task 4 明確 scope 掉——拖曳懸停時視窗無視覺提示（僅 drop 後才有 `InstallBanner` 回饋），此為刻意的功能缺口而非 bug，留待後續體感打磨。
- **大 APK banner 體感 pending-human**：`InstallBanner` 的 `.installing(done:total:)` 進度顯示與大檔案（例如百 MB 等級遊戲 APK）安裝耗時下的實際觀感，需真裝置＋真大檔測試；本次驗證用的 F-Droid.apk（12.4 MB）安裝很快，未觸及大檔案的體感問題。
- **`adb 不可用` / 拖非 `.apk` 的不崩驗證**：本次僅讀碼確認邏輯正確（無 force-unwrap、無 fatalError、guard 提前 return），未新增獨立單元測試，也未活體模擬「adb 真的不可用」或「真的拖一個非 apk 檔案」的情境——如需更高信心，可在後續補一個新增单元測試覆蓋 `installAPKs` 的 adb-nil 分支（目前 `AppModel` 本身無獨立測試檔，與 Task 3 report 記載的既有缺口一致）。

## 判定

- **APK 拖放安裝 GO（機制+解析層）**：`InstallResult.parse` 單元 9/9 全綠、覆蓋 95%（超過 ≥80% 門檻）；release build 零警告；既有 101/101 測試不回歸；`AdbClient` 重構後 dumpsys 前景解析活體驗證與 P1-d 一致、無回歸；`adb install -r` 機制以真實下載的 APK 活體驗證兩次（直接指定路徑 + 自動偵測既有第三方 app 兩條分支皆跑過），兩次皆得到真實 `Success`，未捏造任何輸出。
- **移交 pending-human**：完整 app-path（拖放手勢→banner 呈現）、`isTargeted` 拖曳高亮、大 APK 體感，皆需真 GUI session 才能驗證，本次未跑；`adb 不可用`/非 `.apk` 拖放的不崩性靠讀碼佐證、未活體模擬。
