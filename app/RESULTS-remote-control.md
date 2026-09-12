# 區域網路手機遙控：實作結果（2026-09-12）

設計：`docs/specs/2026-09-12-lan-remote-control-design.md`。實作分兩個分支合併：MirageCore 端（純函式、NIO 伺服器、手機頁面）與 MirageShell 端（VideoToolbox 編碼器、controller、選單、生命週期）。

## 1. 端到端

| 項目 | 結果 |
|---|---|
| iPhone（iOS 18.7、Safari 26.6.1）經 Tailscale 開 `?t=` 網址 | 畫面即模擬器鏡像；WS 往返 47 到 57 ms |
| 手機端抵達到畫出 p50/p95 | 5/6 ms（與 spike 相同） |
| `verify_remote_mirror.sh`（Python 用戶端，127.0.0.1） | 第一個 keyframe 0 秒；10 秒收 280 幀、幀序缺口 0；觸控經 `/ws/input` → `InputQueue` → 模擬器，guest getevent 看到按下與放開各 1 次 |
| 驗收線 7 對照（`verify_remote_fps.sh`，`GUEST_MIN=45`、每臂 3 輪×2 pass） | Mirage 中位數：關 46、開 46；guest：關 48.5 到 54.2、開 46.6 到 51.3。判定「開 ≥ 關 − 3」通過 |

對照時這台機器連遙控關閉都只有 46 到 50（平常 55 到 58），是當天的主機狀態，兩臂在同一狀態下交錯量。

## 2. 實作中被實測推翻的三件事

1. 硬體 H.264 編碼器不支援 `MaxFrameDelayCount`，設定回 `-12900`。改成必要屬性（硬體、`RealTime`、`AllowFrameReordering=false`、profile）失敗才中止，可選屬性失敗只記錄在 `skippedProperties`。活體測試斷言這台機器會跳過 `MaxFrameDelayCount`。
2. 畫面靜止時手機黑畫面：`LatestFrameBox` 只在畫面變化時有幀，controller 沒東西可編，連第一張 keyframe 都送不出。加 250 ms 心跳重編最後一幀，viewer 連上時立刻送 keyframe。
3. 心跳幀第一版一律送 IDR（22 秒收 101 幀其中 92 幀 keyframe），Mac 端約 70% CPU，回壓到 guest（對照時 guest 從 51 到 53 掉到 47 到 50，一個 pass 有兩輪 32）。改成心跳與間歇新幀都是 P-frame，IDR 只在 viewer 連上、明確請求、session 重建、GOP 到期四種情況；像素緩衝改用 pool。改完 280 幀只有 3 個 keyframe，對照通過。

## 3. 其他在實作中定案的細節

- `/ws/input` 必須依附 `/ws/video`（否則 409）；video 斷線時 input 一併關閉並放開所有手指。第一版兩條各自獨立，拿到 token 的第二台裝置可以不看畫面就注入觸控。
- NIO typed 升級被拒絕時不重送 request head（`NIOTypedHTTPServerUpgraderStateMachine.swift:181-183`），403／409 要由 `shouldUpgrade` 記下、HTTP 路徑不等 head 直接回。
- 手機連著時關 Mac 視窗不 suspend；手機斷線後若視窗仍隱藏，補走與關視窗相同的 suspend 路徑。
- 配對網址與 token 不印進 stdout，只從選單列取得（QR 或複製）。
- viewer 閒置 2 秒才 flush 解碼器並請求 keyframe；心跳每 250 ms 到就不會觸發。
- `MIRAGE_REMOTE=1`、`MIRAGE_REMOTE_PORT`、`MIRAGE_REMOTE_TOKEN`、`MIRAGE_REMOTE_PULL_FPS`（5 到 60，預設 30）供腳本與 A/B 用。

## 4. 未做與已知限制

- Android：WebCodecs 需要 HTTPS，未做。
- glass-to-glass 延遲未量（要第三台裝置同框拍）。手機端內部 5 ms、往返約 50 ms（Tailscale）；Wi-Fi 直連未量。
- macOS 防火牆對每次重新打包的 ad-hoc 簽署 app 都會問一次「允許傳入連線」，不按允許就只有本機能連。腳本一律連 127.0.0.1。
- 驗收線 7 的絕對值 55 這天沒達到（遙控關閉時也只有 46），對照只證明開關差距在容許範圍內。

## 5. 2026-09-12 追加：導覽鍵、文字輸入、疊層收合

iPhone 實測回報畫面、點擊、滑動、雙指縮放都正常，但回主畫面、切換 app、打字做不到，統計疊層一直在。原因與處理：

- Android 手勢導覽要從螢幕邊緣滑，iOS 自己先攔走邊緣手勢（底邊回 iOS 主畫面、頂邊控制中心），網頁收不到。手機頁面底部加「返回／主畫面／最近任務」三顆鍵，經 `/ws/input` 的 `{"type":"key"}` 訊息走 Mac 端既有的 `InputQueue.key` 路徑（down 再 up）。`?nav=0` 可隱藏。
- 文字：頁面加「⌨︎」鍵叫出 iOS 鍵盤，Return 把整串以 `{"type":"text"}` 送出，接到既有的文字提交路徑（`TextInputPresentation.enqueue`，`origin: "remote"`，與 Mac IME 共用剪貼簿＋Paste 交易與互斥）；上限 4096 個 UTF-16 單元；輸入框為空時 Backspace 送按鍵事件；鍵盤彈出時用 `visualViewport` 縮畫面。
- 統計疊層點一下收合，狀態存 localStorage；收合時錯誤仍顯示；`?stats=0` 維持完全不顯示。

`verify_remote_mirror.sh` 加三段：R4 送 `GoHome` 後前景是 launcher；R5 送 `AppSwitch` 後 getevent 出現 `KEY_APPSELECT` DOWN／UP（Pixel 的最近任務由 launcher activity 自己畫，前景不會變，第一版用前景判是錯的）；R6 送 `Mirage remote 中文🙂 hello` 到設定搜尋欄位（`com.google.android.settings.intelligence/.modules.search.SearchActivity`）後 uiautomator 回讀逐碼位相等。六段全過。

## 6. 2026-09-12 追加：延遲分段、事件驅動編碼、iOS 實測修正

- Mac 端分段延遲（本機 Python 用戶端，10 秒）：transit 10、age p50 8（p95 16 到 21）、encode p50 7、send 0.03 ms；手機端解碼到畫出 5 ms。手機疊層每秒顯示這些數字（`{"type":"stats"}` 文字訊息，不進影像佇列）。
- 拉幀改成事件驅動（`NotifyingFrameSink`，幀一到就編，以拉取率上限限速合併），age p50 從 8 到 10 降到約 6（上限 60 時）；p95 有約 15 ms 的地板（幀抵達、拷貝、轉 BGRA 到交給編碼器的固定成本）。預設上限維持 30。`verify_remote_mirror.sh` 用各窗 p50／p95 的中位數判（p50 < 12、p95 < 25），逐窗判會被單一窗口的尖峰打紅（同一 build 三次 p95 最大值 21／18／27.6）。
- 使用者感覺慢的是點擊到畫面，且手機不在同一個 Wi-Fi（Tailscale 經公網直連，單程 39 ms，WS RTT 47 到 75 ms）；這段佔整條路徑的大半。同一 Wi-Fi 的數字尚未量。
- iOS Safari 的 pointerId 可為負數（實測 `-10102172`），第一版驗證只收非負整數，所有觸控被丟（`invalidPointerId` 累計 188），症狀是「點擊無效」。改為接受 Int32 全範圍，活體改用負數 id 送。
- 手機頁面：斷線自動重連（1／2／4 秒三次）、解碼錯誤重建解碼器、切到背景回前景時主動重連（iOS 切背景會斷 WebSocket）、退避只算前景時間。

## 7. 2026-09-13 追加：雙指縮放時所有輸入排隊

iPhone 雙指縮放圖片時疊層顯示 `transit 326.7 ms`（平常 10）、`frames/s new=5`，使用者描述縮放期間所有後續操作都排在後面才執行。機制：手機端每根手指每個 `pointermove` 各送一則訊息，雙指每秒 120 到 240 則，Mac 端每則一次 `sendTouches` gRPC，模擬器逐一消化、與畫面串流共用同一條 HTTP/2 連線。

處理：手機端每個畫面週期把所有手指打包成一則 `touches` 快照（同一幀內的 down／up 邊緣保留、背景時 `setTimeout` 兜底）；Mac 端一次 `sendTouches` 送多點；`InputQueue` 消費端把「識別碼集合相同的連續純 move 批次」合併成最新一則（keymap 的全狀態快照與本機滑鼠不受影響，邊緣事件不合併）。統計多 `inputRPCsPerSecond` 與 `inputCoalesced`。

活體 R7（Python 用戶端模擬雙指 120 Hz 縮放 3 秒）：RPC 每秒 42 到 44、合併 82 批／秒、pinch 期間 transit 10.7 ms、兩 slot 最後都放開、縮放結束後的 tap 在 guest 時鐘上 500 ms 內到達。第一版的 tap 判定把 guest 的 getevent 時間戳與主機 `monotonic` 相減，兩個時鐘不可比，已改成同一時鐘的差。
