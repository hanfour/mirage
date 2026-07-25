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

# P1-c 鍵位映射

把 P1-a 的「滑鼠即觸控」升級為每遊戲 profile 的鍵位映射——鍵盤/滑鼠 → 多點觸控注入：

- **鍵位映射引擎（`MirageCore/Keymap/`，純引擎）**：tap（技能鍵）、joystick（WASD 移動）、look（滑鼠視角）→ 多指 `TouchFrame` 快照。identifier 靜態分配（joystick=1／taps=2,3…／look=最後）保證多指決定論不衝突。核心 `KeymapEngine` 逐行 100% 覆蓋。
- **每遊戲 profile**：`KeymapProfile`（Codable + schema 驗證，載入 fail-fast）；`ProfileStore` 原子檔案 I/O（temp+rename）。位置 `~/Library/Application Support/Mirage/profiles/<gameId>.json`；內建指標 `com.example.game`。
- **多指注入**：`EmulatorClient.sendTouches([TouchSpec], width:height:)`（一個 `TouchEvent` 帶多 `Touch`）、`sendKey`；`sendTap` 為單指特例。座標用解碼後實際幀尺寸（對齊 P1-a `renderer.lastFrameSize`）。
- **無 profile 退回**：`MirrorView` 在無 active profile 時仍走 P1-a 直接 mouse→tap（不回歸）。
- **App 整合**：`KeymapController`（NSEvent→引擎→注入）、`MouseCapture`（look 游標鎖定）、overlay 提示與陽春編輯器、⌘E 進編輯。
- 活體多指：`ANDROID_SERIAL=emulator-5554 MIRAGE_LIVE=1 swift test --filter MultiTouchLiveTests`（配 `adb shell settings put system show_touches 1`，注入後 show_touches 見 `P: 0/2`）。
- 驗收紀錄：`RESULTS-p1c.md`（authoritative）。

**已知限制/移交**：真實觸點落點精度 pending-human（GUI/解鎖）；overlay 拖放存檔、look 手感、⌘E 即時行為 pending-human；`gameId` 硬編碼待遊戲偵測（P1-d）。（`MouseCapture` 失焦自動釋放已於 P1-d 修復。）

架構詳見 `../docs/specs/2026-07-24-p1c-keymap-engine-design.md`。

# P1-d 遊戲偵測與 keymap 啟用

讓 P1-c 的休眠 keymap 自動生效：偵測前景遊戲 → 載對應 profile → keymap 接管；無 profile 退 P1-a tap。

- **偵測**：`GameDetector`（App）輪詢 `adb dumpsys activity activities`（~1.5s）→ `ForegroundParser`（**MirageCore 純函式**，逐行 100% 覆蓋）解析前景 package。emulator gRPC 無前景-app RPC，故走 adb。
- **啟用決策**：`ActivationDecider`（**MirageCore 純 reducer**）——偵測 + 已載 profile + 手動覆蓋 → active/inactive；`AdbClient.standard()` 無 adb→靜默不偵測。
- **選單列**：目前遊戲 + 手動「停用 keymap／恢復自動偵測／套用 profile ▸」（掃 `~/Library/Application Support/Mirage/profiles/*.json`）。
- **MouseCapture 修正**（P1-c 交接）：焦點 gating（`hasProfile && !editing && keyWindow`）+ `didResignKeyNotification` 自動釋放，消除游標陷阱。
- 活體：`scripts/verify_keymap_inject.sh`（引擎→注入 show_touches 佐證；擷圖見 P:1/2、座標數學正確）。
- **已知限制**：完整 app-path（KeymapController+NSEvent）與真遊戲手感 pending-human；`AppModel.profile` 與偵測啟用不同步（overlay 上線前須讓 activation 回寫）；`gameId==package`（真遊戲 profile 內容留 Phase 1 三款遊戲）。
- 驗收：`RESULTS-p1d.md`；架構詳見 `../docs/specs/2026-07-24-p1d-game-detection-design.md`。
