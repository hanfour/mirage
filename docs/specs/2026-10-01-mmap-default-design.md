# 畫面改走共享記憶體（MMAP）為預設

- 日期：2026-10-01
- 分支：`feat/mmap-default`

## 背景

Mirage 預設用 gRPC `streamScreenshot` 收 raw RGBA，每幀 7 MB 經 TCP 傳輸並由 protobuf 解碼。MMAP transport 早已實作（`MmapStreamTransport`、`FallbackTransport`、`DisplayTransportSelector`），但因為 grpc-swift 發的請求曾經拿不到持續更新的畫面，預設關閉，要 `MIRAGE_TRANSPORT=mmap` 才開。

2026-10-01 重測（emulator 37.1.11、macOS 26.6.2、898×1996、Pixel Flow 遊戲畫面，三輪交錯，`mirage-pull` 直拉）：

| | raw RGBA | MMAP |
| --- | --- | --- |
| fps | 59.3–60.0 | 59.6–59.9 |
| 30 秒內不同畫面數 | 1779–1800 | 1789–1797 |
| 接收端 CPU | 34.7–36.4% | 12.6–13.1% |
| qemu CPU | 216–232% | 173–186% |

grpc-swift 的 MMAP 已正常，每路 60 fps 串流省約 65 個百分點 CPU。何時、為何恢復不確定，所以預設改用 MMAP 的同時，要能偵測舊問題的症狀並自動退回 raw。

## 1. 預設改為 MMAP

- `DisplayTransportSelector.choose`：emulator 版本 ≥ 37 時預設 `.mmapWithRawFallback`；版本 < 37 或未知時維持 `.rawOnly`（36.x 收到 MMAP 請求會 SIGSEGV，`MmapVersionGate` 不動）。
- 環境變數改成：`MIRAGE_TRANSPORT=raw` 強制 raw（退回與 A/B 用）；`MIRAGE_TRANSPORT=mmap` 保留，效果等同預設；未設定即預設。其他值當成未設定，並 print 一次警告。
- 啟動時的 `[transport]` 訊息改為反映新預設，例如 `[transport] mmap（預設，emulator 37.1.11；MIRAGE_TRANSPORT=raw 可改回）`。
- `MmapStreamTransport` 與 `MmapSupport` 註解裡「實驗性、預設關閉」的說明改為現況，並註明 2026-10-01 的重測數字與「恢復原因不明」。

## 2. 偵測「有通知但內容不變」並退回 raw

舊問題的症狀：emulator 持續送通知（`Image.seq` 連續），但映射區內容從不改變。既有的退回只檢查前 3 幀是否全零，攔不到這個症狀，畫面會停格。

判斷方式：

- emulator 只在 guest 有新畫面時才送通知（沒有新畫面時 `getScreenshot` 回 `FAILED_PRECONDITION`，`streamScreenshot` 直接略過），所以「連續收到通知但內容完全相同」本身就可疑。
- 但遊戲也可能每幀重畫出一模一樣的畫面，只看內容相同會誤判。因此疑似停格時再做一次確認：用 unary `getScreenshot`（raw RGBA，同尺寸）取一張，與映射區目前內容比對。兩者不同才判定 MMAP 失效；相同代表畫面本來就沒變，重設計數繼續用 MMAP。

規則：

- 每幀計算映射區快照的指紋（取樣式雜湊即可，比照 `MiragePull.fingerprint` 的步距取樣，不做完整掃描）。
- 連續 120 次通知（60 fps 約 2 秒）指紋相同 → 做一次 raw 比對。
- raw 與 MMAP 內容不同 → 丟 `TransportError.mmapUnusable`，由 `FallbackTransport` 退回 raw，並 print 一次 `[transport] mmap 內容停止更新（連續 N 次通知相同、raw 比對不同），改用 raw rgba`。
- raw 與 MMAP 相同 → 計數歸零，30 秒內不再做第二次比對（避免靜止重畫的遊戲每 2 秒多一次 7 MB 請求）。
- raw 比對本身失敗（RPC 錯誤）→ 不判定失效，計數歸零，記一行 log。
- 「連續相同計數」「是否該比對」「比對結果怎麼處理」寫成純型別，可單元測試；gRPC 與 mmap 讀取留在外層。
- 退回的有效範圍維持既有設計：一個 channel 一次，重連後重新選擇。

## 3. 量測工具與驗證腳本修正

- `phase0/harness/mmap_client_parity.py`：請求要帶 `authorization: Bearer <grpc.token>`。2026-09-11 emulator 改 token 驗證後這支工具一直回 UNAUTHENTICATED。沿用 `tools/probe/lib/grpc_auth.py` 的 `discover_token`，不要另寫一份。
- `app/scripts/verify_mmap.sh`：跟著上面修好後要能在實機跑過。
- `MmapStreamLiveTests`：取樣窗口從 3 幀改為至少 120 幀，判準從「distinct > 1」改為「distinct 至少為 frames 的 80%」，解析度改為 898×1996。3 幀窗口曾造成「凍結」的誤判（見測試檔註解），這次一併修掉。
- `mirage-pull`：新增 `--transport rgba|mmap`（預設 rgba，維持既有量測的可比性），輸出的 `transport=` 欄位依實際使用的 transport 填寫。
- `app/RESULTS-mmap.md` 開頭加一段 2026-10-01 的重測結果，說明預設已改為 MMAP。

## 不在這次範圍

- MMAP 在全螢幕 Mirage 內的 fps 與 CPU 驗收（由 PM 以 `verify_fps_fullscreen.sh` 的 `-E MIRAGE_TRANSPORT=raw` A/B 進行）。
- 多開時每台模擬器各自一份映射檔的檔名衝突：`handlePath` 已含 pid 與序號，本次不改。

## 驗收

| 項目 | 方式 | 負責 |
| --- | --- | --- |
| 選擇器真值表 | 單元測試：版本（36、37、未知）× 環境變數（未設、raw、mmap、其他值） | codex |
| 停格偵測 | 單元測試：119 次相同不觸發、120 次觸發比對、比對不同丟錯、比對相同歸零且 30 秒內不再比對、比對失敗不判定失效、中途內容改變計數歸零 | codex |
| 退回路徑 | 單元測試：串流中途丟 `mmapUnusable` 時 `FallbackTransport` 改用 raw 且之後的 `frames()` 直接走 raw | codex |
| 對照工具與腳本 | `mmap_client_parity.py`、`verify_mmap.sh` 實機通過；`MmapStreamLiveTests` 在實機以新判準通過 | PM |
| 產品實際走 MMAP | Mirage 啟動 log 出現新的 `[transport] mmap` 訊息；MirageApp CPU 與 `MIRAGE_TRANSPORT=raw` 對照 | PM |
| 全螢幕 fps | `verify_fps_fullscreen.sh` 預設與 `-E MIRAGE_TRANSPORT=raw` 交錯 | PM（需使用者空出電腦） |
