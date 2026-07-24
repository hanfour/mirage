# Mirage App（P1-a）

產品殼與顯示管線。建置：`cd app && swift build -c release`。
執行：先啟動模擬器（`phase0/scripts/02_boot_headless.sh` + `03_wait_boot.sh`），
再 `./.build/release/MirageApp`。

- `MIRAGE_FPS_LOG=1`：每秒印 `[app] fps=N`（量測用）
- unary-mmap 傳輸：`MirageCore` 已實作且有版本閘（僅 canary emulator ≥37；穩定版會被拒絕），
  但**尚未接入 App 執行期**（`MirageApp` 沒有任何讀取 `MIRAGE_TRANSPORT` 的程式碼），延後至
  P1-b 接線。目前唯一能跑到這條路徑的是測試路徑：`MIRAGE_LIVE_MMAP=1 swift test`。
- 測試：`swift test`；活體整合：`MIRAGE_LIVE=1 swift test --filter LiveSmokeTests`
  （`MIRAGE_LIVE_MMAP=1` 另外開啟 unary-mmap 活體路徑；兩者皆需要一個正在跑的 emulator，
  且是量測完整測試覆蓋率時的必要呼叫方式——只跑預設 `swift test` 會因活體測試提早
  return 而漏掉大段覆蓋率，細節見 `RESULTS-p1a.md` 驗收 4 節）
- 驗收紀錄：`RESULTS-p1a.md`；重連驗證：`scripts/verify_reconnect.sh`

架構詳見 `../docs/specs/2026-07-23-p1a-display-shell-design.md`。

## 目前驗收狀態

headless／transport 層可量測的驗收線皆為 **PASS**：重連（殺模擬器→重啟→1 秒內恢復出幀，
遠低於 10 秒門檻）、測試全綠（28/28）、覆蓋率 94.89%（line，含 live smoke）、release 零警告、
transport 層 540p fps 56.3–60.0（≥55 門檻）。

先前版本記錄的 e2e「真實回歸／未過」判定已於 commit ea2ca09 撤回並校正：量測工具
`e2e_latency.py` 是純 Python harness，**不經過 P1-a 的程式碼**，因此那組數字不能當作
P1-a 迴歸的證據，已改列 pending-unlock（詳見下段）。**未發現 P1-a 迴歸。**

以下三項需要 App 實際合成畫面才有意義，本機螢幕鎖定期間無法量測，皆為
**pending-unlock**（螢幕解鎖後補測即可，不需改動任何測試腳本或產品碼）：
App 合成層 fps（`MIRAGE_FPS_LOG=1`）、渲染中 CPU 佔用、App 層 `sendTap` e2e 延遲。

完整逐條數字、判定與校正說明以 `RESULTS-p1a.md` 為準（authoritative）。

# P1-b 生命週期

把 P1-a 的「能連能重連」升級為可信生命週期：

- **健康探測重連**：斷線期 banner 誠實顯示 `reconnecting(n)`、attempt 真實遞增（修 P1-a 終審假連線缺口）。重連迴圈非遞迴（消除 async frame 堆積）。
- **休眠／喚醒（暫停/恢復拉幀）**：關閉視窗→停止 app 端拉幀（省串流/渲染 CPU，**qemu 仍在跑**，spec §8）；選單列/重開→恢復拉幀。
  - ⚠️ **快照「還原」已 descope**：活體實測 `loadSnapshot` 會使運行中的模擬器崩潰（canary 37.2.1），且與「qemu 仍在跑」矛盾（load 會 rewind 丟狀態）。`wake()` 因此只恢復拉幀、不 load 快照。`save-on-suspend` 保留為磁碟檢查點。詳見 `RESULTS-p1b.md` 發現 1。
- **選單列常駐（🪞）**：連線狀態、喚醒、顯示視窗、退出（Cmd+Q 乾淨 teardown）。（power 狀態 UI 尚未接線）
- **雙向剪貼簿（純文字，防回音）**：host↔guest 經 `ClipboardBridge` 去重切斷回音迴圈。
- 快照 stub 產生：`scripts/gen_snapshot_stub.sh`（需 grpc-swift 1.27.5 checkout build plugin）。
- 活體：`MIRAGE_LIVE=1 swift test --filter "ClipboardLiveTests|SnapshotRoundTripLiveTests|LiveSmokeTests"`（需運行中的 emulator）。
- 驗收紀錄：`RESULTS-p1b.md`（authoritative）。

**已知限制/移交**：NIO teardown race（重連時，今非致命但 NIO 稱未來會升 crash——待可注入 channel 硬化）；GUI 體感 pending-human（需真 GUI session）；`powerStates` UI 未接線。

架構詳見 `../docs/specs/2026-07-24-p1b-lifecycle-design.md`。
