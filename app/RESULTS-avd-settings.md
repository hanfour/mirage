# 設定頁（CPU、記憶體、解析度）驗收結果

驗證腳本：`app/scripts/verify_avd_settings.sh [--rounds N] [--keep]`

## 結論

設定頁可以改 CPU 核心數、記憶體、解析度，寫入 AVD 的 `config.ini`，模擬器由 app 管理且在跑時自動重新啟動，guest 內確認生效。不是由 Mirage 建立的 AVD（開發機上 `provision.py` 建的那台）唯讀。2026-09-30 兩輪共 38 項全數通過。

## 實測

| 情境 | 判準 | 兩輪結果 |
|---|---|---|
| V1 暫存 AVD 套用 2 核、3072 MB、720×1600 | 自動重新啟動並再次 `running`；`config.ini` 為新值；guest `wm size` 720x1600、processor 2、MemTotal 3047312 kB | 通過 |
| V2 開發機 AVD | 判定唯讀、沒有寫入；`config.ini` sha1 `1ecd83d4…` 全程不變 | 通過 |

## 驗證中找到並修正的缺陷

- 首次啟動精靈的空間檢查只替 AVD 預留 2 GiB，emulator 首次開機實際要求資料分割區 × 1.2（預設 8 GiB 時為 9830.40 MB）。可用空間介於兩者之間時，精靈會通過、下載 2.2 GB，開機時才失敗。已改為依 `sdk-spec.json` 的 `disk.dataPartition.size` 計算。
- 模擬器因空間不足結束時，啟動器原本當成異常結束自動重開一次，畫面只顯示「模擬器異常結束」。現在從 emulator log 認出 `Not enough space to create userdata partition`，直接顯示「磁碟空間不足：需要 X GB，可用 Y GB」，不重開。實機驗證中實際觸發過一次（可用 5386 MB、需要 7373 MB），行為符合預期。

## 驗證腳本本身的兩個修正

- 測試用 AVD 的資料分割區設 2 GiB 會被 emulator 改回 6 GiB（`config.ini` 開機後變成 6442450944，需求 7372.80 MB = 6144 MiB × 1.2），推斷是 Play 映像的最小值。測試值改為 6 GiB。
- launcher 的 `running` 由 gRPC `booted` 判定，重新啟動後 adb 要再過幾秒才連上。立刻查 guest 會得到 `device offline`／`not found`。查詢前改為先等 adb 回報 `sys.boot_completed=1`，實測等待 0 到 2 秒。

## 未完成

- 設定視窗本身的畫面操作（Picker、按鈕文字切換）沒有自動化畫面驗證；套用路徑由只供測試的 `MIRAGE_SETTINGS_AUTOAPPLY` 走與按鈕相同的 `SettingsController.apply()`。
- 外部實例（`emu.sh` 開的）套用後「下次啟動生效」的畫面說明只有單元測試。
