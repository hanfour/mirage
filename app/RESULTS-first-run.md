# 首次啟動精靈驗收結果

規格：`docs/specs/2026-09-29-first-run-setup-design.md`
驗證腳本：`app/scripts/verify_first_run.sh [--rounds N] [--real-download] [--keep]`（判準見規格 §6）

## 結論

沒有 Android SDK 的環境打開 Mirage 會出現精靈，同意授權後從 Google 下載 emulator、platform-tools、Play 映像並建立 `mirage-game` AVD，完成後自動開機到 `running`；再次開啟不出現精靈。2026-09-29 真下載一次（S2）加上本機假套件共 10 輪，全數通過。

## 實測

| 情境 | 輪數 | 結果 |
|---|---|---|
| S1 本機假套件（安裝、755 權限、版本紀錄、AVD 設定檔） | 3 | 通過 |
| S2 真下載 2.2 GB，裝到暫存目錄後開機 | 1 | 通過 |
| S3 第二次啟動不出現精靈（接在 S2 之後時另判 150 秒內 `running`） | 3（其中 1 輪接在 S2 之後） | 通過 |
| S4 可用空間 1 GB 時不開始下載 | 3 | 通過 |

S2 各項完成時間（從精靈開始算）：

| 項目 | 完成於 |
|---|---|
| Android Emulator（395 MB） | 17 秒 |
| Android Platform Tools（16 MB） | 17 秒 |
| android-35 Google Play 映像（1.79 GB） | 88 秒 |
| mirage-game AVD | 88 秒 |

下載速度取決於網路，這個數字只代表當天這台機器的環境。

## 驗證中找到並修正的缺陷

- 測試 target 加了 `resources` 之後，SwiftPM 替它產生自己的 `Bundle.module`，蓋掉測試原本透過 `@testable import MirageCore` 拿到的 bundle，既有的內建 profile 測試因此找不到資源。改為用 `#filePath` 讀 fixture，測試 target 不宣告資源。
- `PackageInstaller` 的解壓原本在 async 函式裡同步輪詢 ditto，解 1.8 GB 映像時佔住一條並行執行緒，取消要等解壓結束才生效。改為 `terminationHandler` 加 continuation，取消時終止 ditto。突變驗證：拿掉終止，取消測試在 3.2 秒失敗。
- 精靈原本在 `AppModel.start()` 裡等待結束，下載期間選單列與視窗關閉規則（`startLifecycle`）都還沒建立，精靈後面也有一個全黑的鏡像視窗。改為顯示精靈後立即返回，成功後才建立啟動器；精靈期間鏡像視窗隱藏。突變驗證：改回等待，測試在 2.15 秒失敗。

## 開發環境

- app 的 SDK 與 AVD 預設在 `~/Library/Application Support/Mirage/sdk`、`…/Mirage/avd`。開發機從 Finder 開 Mirage 會看到精靈，這是預期行為。
- 經由 `lib/gui_session.sh` 啟動的驗證腳本會帶 `ANDROID_SDK_ROOT`／`ANDROID_AVD_HOME` 指向既有的 `~/Library/Android/sdk` 與 `~/.android/avd`，行為不變。直接啟動 app 的 `verify_reconnect.sh` 與 `lib/wake_probe.py` 也已補上。
- `emu.sh` 開的外部模擬器在跑時，app 不檢查 SDK、不顯示精靈。

## 未完成

- 斷點續傳：下載失敗的那一項從頭重下。
- 版本不符的已安裝套件只記警告，不升級。
- 精靈畫面本身（說明頁的授權勾選、進度列）沒有自動化的畫面驗證，只有按鈕啟用規則（`SetupGate`）的單元測試與 log 判準；需要人工看一次。
