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

## APK 拖放安裝

把 sideload 一顆 APK 的手動 adb 指令變成拖放：

- **拖放**：把一個或多個 `.apk` 檔拖到 App 視窗，逐個依序 `adb install -r` 安裝（非併發，一批跑完才輪下一個）；非 `.apk` 檔會被過濾掉，不觸發安裝。
- **回饋**：底部 `InstallBanner`——安裝中顯示進度（n/total）；每個結果各自一顆膠囊（成功／失敗附原因），約 **4 秒後自動消失**（用 generation 令牌避免舊 dismiss 誤清剛拖入的新批次）。
- **解析**：`InstallResult.parse` 把 `adb install` 的原始輸出（`Success` / `Failure [REASON]` / adb 執行失敗）轉成型別化結果，純函式、9 個單元窮舉格式（含 progress-bracket 不誤判為 failure）。
- **adb 不可用**：偵測不到 `adb` 時每個檔案直接標記失敗，不嘗試安裝、不崩潰。
- **活體驗證**：`scripts/verify_apk_install.sh`（需 `ANDROID_SERIAL=emulator-5554` 指向的模擬器正在跑）——先印 `dumpsys` 前景解析（佐證 P1-d 偵測未回歸），再對一個第三方 APK 跑真實 `adb install -r` 並印原始輸出。
- **與遊戲安裝的關係**：本功能只做「sideload 機制」——把任意 `.apk` 裝進模擬器。**真遊戲要能跑，使用者仍需自行安裝 GApps**（母計畫 R1 範圍，非本功能負責）；APK 拖放安裝不含 Play 商店、不含 GApps 佈署。
- 驗收：`RESULTS-apk-install.md`；架構詳見 `../docs/specs/2026-07-25-apk-install-design.md`。

# P1-e 全螢幕與音訊

補齊母計畫 Phase-1「鏡像視窗」尚缺的兩項：macOS 原生全螢幕遊戲模式、guest 音訊輸出到 Mac 喇叭。

- **全螢幕**：三種入口——⌃⌘F、視窗綠燈、選單列「遊戲模式（全螢幕）」；由 `NSWindow.didEnterFullScreenNotification`／`didExitFullScreenNotification` 驅動 `AppModel.isFullScreen`（系統告知，不自行推測）。letterbox 由 `MirrorContainerView`（黑底 NSView）+ `ViewportFit`（`MirageCore` 純函式）負責——容器算好 aspect-fit 內容矩形，把 `MirrorMTKView` 佈局進去，黑邊是父 view 的背景色，`MirrorMTKView.bounds` 永遠等於內容矩形，座標數學（`normalized()`／`KeymapController`）零改動。**不綁 Esc**（Esc 在 guest 是返回鍵，搶了會壞遊戲輸入）。全螢幕時隱藏 keymap 唯讀提示 overlay（純視覺噪音），保留 `ConnectionBanner`／`InstallBanner`（斷線是必須知道的異常，安裝是使用者主動觸發的回饋）。串流解析度改用內容矩形寬 + 實際幀長寬比反推高度，上限規則在 `MirageCore/Viewport/StreamSize.swift`（純函式、有單元測試）：寬度上限 1080 **加上總像素預算 1.8 MP**——只限寬守不住成本，9:20 直向在寬度上限下會算到 1080×2400 ≈ 2.6 MP，比 spec §4.3 論證所用的 880×1960（1.7 MP）多 50%；加了像素預算後直向全螢幕為 900×2000，橫向仍由寬度上限主導，小視窗不受影響。**該預算尚未經 fps 實測校準**（驗收線 7 仍 pending-human）。
- **橫向**：`ImageFormat.rotation` 是 `[Output Only]`，emulator 已把幀轉好；長寬比一律由 `Renderer.lastFrameSize` 驅動的實際解碼幀決定，原本散在 `MirrorMTKView.viewDidMoveToWindow`／`MirrorView.Coordinator.resizeDebounced` 兩處的 `9:20` 硬編碼已移除，橫向遊戲自動支援，無需獨立分支。
- **音訊**：`EmulatorClient.attachAudio()`／`detachAudio()` 與既有 `FramePump` 對稱掛在同一條連線狀態機上（不新增第二條生命週期）——`streamAudio`（48000Hz／stereo／S16／`modeRealTime`，由 `GrpcAudioTransport` 封裝）→ `AudioRingBuffer`（SPSC 無鎖環形緩衝，容量 200ms／19_200 samples）→ `AudioPlayer`（`AVAudioEngine` + `AVAudioSourceNode`，render callback 只做一次 `memcpy`／補零，不配置不加鎖不 log）。關視窗即靜音，跟畫面同一條 `PowerState`。選單列「靜音」勾選（`engine.mainMixerNode.outputVolume = 0/1`，macOS 無原生 per-app 音量）。`MIRAGE_AUDIO_LOG=1` 每秒印一行 `[audio] pkt=N sr=48000 ch=2 under=N over=N depth=Nms` 健康摘要，是唯一能無頭驗證音訊健康的訊號。活體驗證：`scripts/verify_audio.sh`（用 `input keyevent 24` 頂音量 + `am start VIEW` 觸發內建鈴聲發聲，量測 `streamAudio → AudioRingBuffer` 5 秒封包率）——**這是唯一正確的執行方式**：`AudioLiveTests` 額外掛了 `MIRAGE_LIVE_AUDIO=1` 閘門（比照既有 `MIRAGE_LIVE_MMAP` 慣例），只有這支腳本會設定它，避免它跟其他活體測試一起跑進通用的 `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test` 覆蓋率量測指令時，因鈴聲早已播畢而假性紅燈；直接跑 `MIRAGE_LIVE=1 swift test --filter AudioLiveTests`（不帶 `MIRAGE_LIVE_AUDIO=1`）現在會 early return，看似通過但其實什麼都沒驗到。
- **已知限制／移交**：完整 pending-human 清單（真實聽感、letterbox 目視、橫向全螢幕、遊戲模式 chrome 隱藏手感、全螢幕下 keymap/mouse capture 手感、驗收線 6 連續 60 秒 underruns==0、驗收線 7 fps≥55）見 `RESULTS-p1e.md`；`overruns`/`underruns` 歸因與緩衝深度呈兩極分佈（多數逼近容量上限、至少一次幾乎全空）的 caveat 亦記錄於該文件。**`AudioRingBuffer` 是本專案唯一允許 mutate 的資料結構**（即時執行緒的硬性要求——render callback 不得配置記憶體、不得加鎖、不得 log，破例範圍嚴格限縮在這一個 type 內，對外只暴露不可變的 `AudioChunk`／`AudioStats` 快照）。
- **游標捕捉的對稱性（P1-e fast-follow）**：`MouseCapture` 自 P1-c 就有 `didResignKeyNotification → release()`（游標陷阱的解藥），但一直缺對稱的另一半——焦點回來時沒有人重新捕捉，視窗失焦後（alt-tab、Mission Control、進出全螢幕的過場）捕捉就掉了且不會自動恢復。`AppModel+Focus.swift` 補上 `didBecomeKeyNotification → updateCapture(shouldCapture:)`。判斷條件留在 `AppModel`（`hasProfile && !editing && keyWindow`），`MouseCapture` 維持只做捕捉/釋放的機制角色。
- **覆蓋率量測**：跑 `scripts/coverage.sh`（兩次 `swift test` + `llvm-profdata merge`）。**不要**只跑 `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --enable-code-coverage`——那條指令因 `MIRAGE_LIVE_AUDIO` 閘門不會涵蓋 `GrpcAudioTransport`，只得 ~89%，會被誤判成覆蓋率回歸。實測值會逐次浮動（95.55%／95.72%／95.92% 皆量過），判定看的是有沒有跌破 ~94% 基準，不是有沒有對上某個特定小數。
- **GUI 驗證的實際障礙是「螢幕鎖定」，不是 headless**：`.app` bundle + `open` 能讓 App 進入使用者的 Aqua session（`lsappinfo` 可見 `type="Foreground"` check-in），但 `CGSSessionScreenIsLocked = true` 時 WindowServer 不合成畫面，`WindowGroup` 的 `.task` 不觸發，`MIRAGE_FPS_LOG`／`MIRAGE_AUDIO_LOG` 皆 0 行輸出。**螢幕解鎖後**用同樣手法即可一次驗完所有 pending-human 項目。
- 驗收：`RESULTS-p1e.md`；架構詳見 `../docs/specs/2026-07-26-p1e-fullscreen-audio-design.md`。
