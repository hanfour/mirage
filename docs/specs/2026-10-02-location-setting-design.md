# 設定模擬器位置

- 日期：2026-10-02
- 分支：`feat/location`

## 目標

讓使用者在 Mirage 設定模擬器的 GPS 位置，供依賴位置的 app（地圖、天氣、外送等）使用。功能對齊 Android Studio 模擬器 Extended controls 的 Location：設一個固定座標。

不做：路線播放、持續移動、搖桿／十字鍵控制行走、任何為特定遊戲設計的移動功能。

## 已確認的介面

emulator gRPC `setGps(GpsState)`。2026-10-02 實測：送出 `latitude=25.0339, longitude=121.5645, altitude=10, satellites=12, passiveUpdate=false` 後，guest 的 `dumpsys location` 中 gps 與 fused 的 last location 都是該座標。emulator 重開後位置回到預設，所以要在每次連上時重新套用。

## 1. 設定與保存

- 設定頁（⌘,）新增「位置」區塊，對所有模擬器都可用（與 AVD 設定不同，這是執行期設定，開發機 AVD 也可以用）。
- 開關「使用自訂位置」，預設關。關閉時 Mirage 不呼叫 `setGps`（模擬器維持自己的預設）。
- 緯度、經度兩個輸入欄（十進位度數）；驗證：緯度 -90 到 90、經度 -180 到 180，格式錯誤時顯示錯誤並不套用。高度固定 10 公尺、衛星數 12。
- 常用地點：可把目前座標存成一筆（名稱＋座標），從清單選一筆直接套用，可刪除。
- 「套用」按鈕：立即送 `setGps`，成功顯示「已套用」，失敗顯示原因。
- 保存在 `~/Library/Application Support/Mirage/location.json`（開關、目前座標、常用地點），寫入時用原子寫入；讀取失敗或格式錯誤時視為未設定，並在設定頁顯示一次錯誤，不要讓 app 崩潰。

## 2. 連線時套用

- 每次連上 emulator（首次連線、重連、切換實例）後，若開關開著就送一次 `setGps`。
- 送出失敗記一行 log，不重試迴圈，不影響其他連線流程。
- 選單列狀態加一行「位置：自訂（名稱或座標）」或「位置：模擬器預設」。

## 3. 測試控制通道

`state` 回應加上 `location`：`{"enabled": Bool, "latitude": Double?, "longitude": Double?}`，供驗證腳本確認。

## 驗收

| 項目 | 方式 | 負責 |
| --- | --- | --- |
| 座標驗證 | 單元測試：邊界值、超出範圍、非數字 | codex |
| 保存 | 單元測試：寫入再讀回相同；檔案損毀時回到未設定且回報錯誤 | codex |
| 連線時套用 | 單元測試：開關開／關時是否呼叫（注入的 setGps） | codex |
| 實機 | 設定台北 101 座標並套用 → guest `dumpsys location` 的 gps last location 相符；重開 Mirage 與模擬器後自動恢復同一座標；關閉開關後重開不再套用 | PM |
