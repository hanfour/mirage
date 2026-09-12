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
P1-a 迴歸的證據，改列為未量測（**當時記為 pending-unlock，該歸因已推翻，詳見下段更正**）。**未發現 P1-a 迴歸。**

以下三項需要 App 實際合成畫面才有意義：App 合成層 fps（`MIRAGE_FPS_LOG=1`）、
渲染中 CPU 佔用、App 層 `sendTap` e2e 延遲。

> **⚠️ 更正（2026-07-29）**：本段原本把這三項記為 **pending-unlock**，說「本機螢幕鎖定期間
> 無法量測，螢幕解鎖後補測即可」。**那個歸因是錯的。** 真因是 `AVAudioEngine` 丟出的
> Obj-C NSException 在 `@MainActor` 上把 `startLifecycle()` 扯斷，MainActor 自此不再 drain，
> 於是 MTKView 停止繪製（`fps=` 恆為 0）——鏡像顯示自 P1-a 起**從未運作過**，與螢幕鎖定無關。
> 完整證據見 `../docs/specs/2026-07-28-mirror-never-rendered-investigation.md`。
>
> **防護已在樹上**（`Sources/MirageShell/Audio/AudioPlayer.swift:29`），也就是說
> **這三項現在量得了，只是還沒有人回去量**。它們的正確狀態不是「被外部條件擋住」，
> 是「可以驗了但沒人回頭」——見 `2026-07-29-project-review.md` §8 D 節。

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

**已知限制/移交**：GUI 體感未驗（見上方 P1-a 段的更正——阻礙已消失，是沒人回頭驗）；`powerStates` UI 未接線（定義與初始化都在，但全碼庫零消費端）。

> **⚠️ 更正（2026-07-29）**：本行原本還列著「NIO teardown race（今非致命但 NIO 稱未來會升 crash
> ——**待可注入 channel 硬化**）」。**已修（D1／D8）**，而且那個歸因是錯的：問題不是「channel 不可注入」，
> 是 `channel.close()` 全專案零呼叫 ＋ `deinit` 用阻塞式 `syncShutdownGracefully()` 佔死
> cooperative 執行緒。修法是半天不是大重構——而「以為要抽可注入 channel」正是它卡了三個階段
> 沒人動的原因。修正前連跑 5 次 `swift test` 卡死 3 次，修正後 5/5 通過且 0 行 NIO ERROR。
> 見 `2026-07-29-project-review.md` §1。

架構詳見 `../docs/specs/2026-07-24-p1b-lifecycle-design.md`。

# P1-c 鍵位映射

把 P1-a 的「滑鼠即觸控」升級為每遊戲 profile 的鍵位映射——鍵盤/滑鼠 → 多點觸控注入：

- **鍵位映射引擎（`MirageCore/Keymap/`，純引擎）**：tap（技能鍵）、joystick（WASD 移動）、look（滑鼠視角）→ 多指 `TouchFrame` 快照。identifier 靜態分配（joystick=1／taps=2,3…／look=最後）保證多指決定論不衝突。核心 `KeymapEngine` 逐行 100% 覆蓋。
- **每遊戲 profile**：`KeymapProfile`（Codable + schema 驗證，載入 fail-fast）；`ProfileStore` 原子檔案 I/O（temp+rename）。
  位置 `~/Library/Application Support/Mirage/profiles/<gameId>.json`。
  內建**範例** profile `com.example.game` 於首次啟動時複製到該目錄（已存在者不動，
  使用者的編輯永不被覆寫）。

  > **`com.example.game` 是格式範例，不對應任何真實遊戲。** `com.example.*` 是保留給
  > 範例用的網域。Phase-1 的指標遊戲 Pixel Flow（`com.loomgames.pixelflow`）是點擊／
  > 拖曳型，**不需要 keymap profile**——滑鼠直接 tap（無 profile 時的 P1-a 路徑）就是
  > 對的輸入模型，這也正是驗收線「1 款指標遊戲開箱即玩」已經通過的原因。
  > 實測記錄見 `../docs/specs/2026-07-29-d4-builtin-profile-seeding-design.md` §1.3。
  >
  > **因此 `.auto` 自動啟用目前沒有端到端的自動驗證**：`.auto` 要求 profile 的 `gameId`
  > 對得上偵測到的前景 package，而範例是 `com.example.game`，不對應任何真實 App。
  > 這**可以驗，只是沒人回頭驗**（§8 D 節的第三類）——手動放一份以真實 package 命名的
  > profile（例如 `com.google.android.apps.nexuslauncher.json`，模擬器上一定存在的桌面），
  > 用 `.app` bundle + `open` 啟動 Mirage，把該 App 帶到前景，看選單列的
  > 「遊戲：… [keymap ✓]」是否切換。阻礙（`AVAudioEngine` NSException）已於 2026-07-28 修復。
- **多指注入**：`EmulatorClient.sendTouches([TouchSpec])`（一個 `TouchEvent` 帶多 `Touch`）；`sendTap` 為單指特例。
  座標由 `EmulatorClient` 自己用**健康探測回報的 guest 實體螢幕解析度**（`guestDisplay`）換算，呼叫端只傳正規化的 0–1。

  > **⚠️ 更正（2026-07-29）**：本行原本寫「`sendTouches([TouchSpec], width:height:)`……座標用解碼後
  > 實際幀尺寸（對齊 P1-a `renderer.lastFrameSize`）」。**那個簽章已經不存在，而那個座標慣例正是
  > 讓 P1-c 起所有鍵位映射觸點偏到左上一半處的 bug 本體**——串流幀尺寸（540×1200）與 guest 實體
  > 解析度（本機 1080×2400）差兩倍。`width:height:` 兩個參數已刻意拿掉，讓呼叫端沒有機會再傳錯
  > （見 `EmulatorClient+Input.swift:40-48` 的說明）。`renderer.lastFrameSize` 現在只用於算長寬比
  > （`MirrorView.resizeDebounced`），與觸控座標無關。
  >
  > 這一行是本檔最危險的一處過時記載：它座落在最可能被當作寫碼依據的檔案裡，
  > 照著寫等於**重新製造一個剛修好的 bug**。

- **鍵盤直通（D2，2026-07-29）**：keymap profile **沒綁到**的鍵直接送給 guest 鍵盤
  （`EmulatorClient.sendKey`），綁到的維持觸控路徑——使用者可以一邊用搖桿一邊在遊戲
  聊天框打字。換算在 `MirageCore.KeyTranslate`（純函式、逐行單元測試）：特殊鍵用
  macOS 虛擬鍵碼查表（`charactersIgnoringModifiers` 對 Enter 給 `"\r"`、對方向鍵給
  私用區字元，emulator 不認得），可列印字元仍走字元路徑以保持版面感知。
  **帶 ⌘ 的組合一律不直通**（Android 沒有 ⌘；⌘C/⌘V 已有剪貼簿橋接，送了會貼兩次）。
  Esc → Android 返回鍵；主畫面／最近任務在選單列。
  傳輸只用 `KeyboardEvent.key`——實測十個鍵全通，見設計文件 §2。
  活體驗證：`./scripts/verify_keyboard.sh`（儀器是 `getevent`，不是目視）。

  修飾鍵（⇧⌃⌥⌘）走 `KeymapController.handleFlagsChanged`，**只餵引擎、一律不直通**。
  這條旁路是「帶 ⌘ 的組合一律不直通」唯一擋得住 ⌘ 鍵**本身**的地方——`KeyTranslate`
  擋的是字元那半邊。有測試守著（`modifierKeysNeverPassThroughToGuest`）。

  > **殘餘涵蓋面（未被自動化涵蓋，2026-07-29 修訂）**。三項，逐項說明現況：
  >
  > 1. **`MirrorMTKView.keyCode(from:)`（三行 `NSEvent` 取值）、`keyDown`/`keyUp` 覆寫、
  >    `onKey` 閉包接線** — **仍零涵蓋**。業務邏輯已抽進純函式 `KeyTranslate`
  >    （`KeyTranslateTests` 5 條逐行覆蓋），分流邏輯有 `KeymapControllerRoutingTests`
  >    （8 條），`buildKeyEvent` 有 `EmulatorClientTouchTests`——殘餘面因此很薄，但不是零：
  >    三個參數若「標籤對但來源錯」——例如 `hasCommand:` 誤傳
  >    `event.modifierFlags.contains(.option)`、或 `characters:` 誤傳 `event.characters`
  >    （該用 `charactersIgnoringModifiers`）——型別仍吻合、編譯器不會擋、219 條測試也不會紅，
  >    因為它們測的是 `KeyTranslate` 本身，不是這個呼叫端。
  > 2. **`KeymapController.handleFlagsChanged`（NSEvent → 四顆修飾鍵）** — **已涵蓋**
  >    （2026-07-29 補）。`KeymapControllerRoutingTests.modifierKeysNeverPassThroughToGuest`
  >    用 `NSEvent.keyEvent(with: .flagsChanged, …)` 合成真事件（該 factory 在 headless
  >    `swift test` 下實測可用），斷言按住 ⌘/⇧ 期間零 `sendKey`。這條是回歸測試：分流上線後
  >    `handleFlagsChanged` 曾繞經 `route()`，讓引擎不認識的 `Meta`/`Shift`/`Control`/`Alt`
  >    整顆送給 guest。**剩下的接線**——`MirrorMTKView.flagsChanged(with:)` 覆寫 →
  >    `onFlagsChanged` 閉包 → `Coordinator.controller` — 與第 1 項同性質，仍零涵蓋。
  > 3. **`MenuBarController` 的「返回／主畫面／最近任務」→ `onAndroidKey` →
  >    `AppModel.startLifecycle()` 的綁定** — **單元測試仍零涵蓋**（選單項的 `@objc` 動作
  >    需要 GUI）。傳輸那一段已補進活體清單：`KeyboardLiveTests.sequence` 與
  >    `verify_keyboard.sh` 的 `EXPECTED` 於 2026-07-29 加入 `GoHome`/`AppSwitch`
  >    （`KEY_HOME`/`KEY_APPSELECT`）——先前三顆 Android 實體鍵只驗了 `GoBack` 一顆，
  >    另外兩顆是使用者可見功能卻兩邊都沒有。
  >
  > 第 1 項與第 3 項的選單接線屬於 `../docs/specs/2026-07-29-project-review.md` §8 D 節
  > 點名的**第三類：可以驗了，但沒人回頭驗**——不是「待人眼確認」，也不是根本沒做。
  > 阻礙（`AVAudioEngine` 的 NSException 打死 MainActor）已於 2026-07-28 修復，GUI 現在
  > 開得起來、鍵盤事件現在收得到，只是還沒有人回頭用 App 實際按過。驗法：`open` 開 `.app`
  > bundle（不要從 shell 直接跑 executable）→ 在鏡像視窗按幾個鍵、並從選單列點「主畫面」
  > 與「最近任務」→ 同時 `adb -s <serial> shell getevent -l` 觀察是否出現對應的 `KEY_*`
  > 事件（`KEY_A`… / `KEY_HOME` / `KEY_APPSELECT`）。
- **無 profile 退回**：`MirrorView` 在無 active profile 時仍走 P1-a 直接 mouse→tap（不回歸）。
- **App 整合**：`KeymapController`（NSEvent→引擎→注入）、`MouseCapture`（look 游標鎖定）、overlay 提示與陽春編輯器、⌘E 進編輯。
- 活體多指：`ANDROID_SERIAL=emulator-5554 MIRAGE_LIVE=1 swift test --filter MultiTouchLiveTests`（配 `adb shell settings put system show_touches 1`，注入後 show_touches 見 `P: 0/2`）。
- 驗收紀錄：`RESULTS-p1c.md`（authoritative）。

**已知限制/移交**：真實觸點落點精度未驗（換算路徑已修，見上方多指注入的更正）；look 手感、⌘E 即時行為未驗；~~`gameId` 仍硬編碼 `com.example.game`~~（**已於 2026-07-29 移除，D4**：`AppModel.loadKeymap()` 不再用寫死的 `gameId` 載入，profile 完全交給偵測決定，見下方 P1-d 段落）；鍵盤直通的膠水層（`keyCode(from:)`／`keyDown`/`keyUp`／`onKey`／`flagsChanged` 接線）與選單列三顆 Android 實體鍵的接線可以驗了但沒人回頭驗，見上方鍵盤直通說明的殘餘涵蓋面三項。（`MouseCapture` 失焦自動釋放已於 P1-d 修復。）

> **⚠️ 更正（2026-07-29）**：本行原本把「overlay 拖放存檔」列為 **pending-human**，讀起來像
> 「做好了待人眼確認」。**實際是根本沒做**：`Sources/MirageShell/Keymap/OverlayEditorView.swift`
> 全檔 29 行，只有一個「存檔」Button，全 `MirageShell` 零 `DragGesture`——**編輯器不能拖**。
> 這是債務清單 D5（2–3 天），不是驗證工作。
>
> 「pending-human」與「沒做」用同一個詞，是這個專案反覆付過學費的錯誤，見 `2026-07-29-project-review.md` §0。

架構詳見 `../docs/specs/2026-07-24-p1c-keymap-engine-design.md`。

# P1-d 遊戲偵測與 keymap 啟用

讓 P1-c 的休眠 keymap 自動生效：偵測前景遊戲 → 載對應 profile → keymap 接管；無 profile 退 P1-a tap。

- **偵測**：`GameDetector`（App）輪詢 `adb dumpsys activity activities`（~1.5s）→ `ForegroundParser`（**MirageCore 純函式**，逐行 100% 覆蓋）解析前景 package。emulator gRPC 無前景-app RPC，故走 adb。
- **啟用決策**：`ActivationDecider`（**MirageCore 純 reducer**）——偵測 + 已載 profile + 手動覆蓋 → active/inactive；`AdbClient.standard()` 無 adb→靜默不偵測。
- **選單列**：目前遊戲 + 手動「停用 keymap／恢復自動偵測／套用 profile ▸」（掃 `~/Library/Application Support/Mirage/profiles/*.json`）。
- **MouseCapture 修正**（P1-c 交接）：焦點 gating（`hasProfile && !editing && keyWindow`）+ `didResignKeyNotification` 自動釋放，消除游標陷阱。
- 活體：`scripts/verify_keymap_inject.sh`（引擎→注入 show_touches 佐證；擷圖見 P:1/2、座標數學正確）。
- **已知限制**：完整 app-path（KeymapController+NSEvent）與真遊戲手感未驗；`gameId==package`，**真遊戲 profile 內容仍不存在**——只有內建的範例 `com.example.game`。

  > **⚠️ 更正（2026-07-29）**：本行原本接著寫「而它連 bundle 都進不去（`Package.swift` 無
  > `resources:` 宣告，見 D4）」。**D4 已於同日修復**：`Package.swift:32` 補上
  > `resources: [.copy("Resources/profiles")]`，範例 profile 現在會在首次啟動時複製進
  > 使用者目錄（見上方 P1-c「每遊戲 profile」段落）。另外，「真遊戲需要 profile」這個
  > 前提查證後也不成立——Phase-1 指標遊戲 Pixel Flow（`com.loomgames.pixelflow`）是
  > 點擊／拖曳型，不需要 keymap，同見上方 P1-c 段落。

  > **⚠️ 更正（2026-07-29）**：本行原本還列著「`AppModel.profile` 與偵測啟用不同步
  > （overlay 上線前須讓 activation 回寫）」。**已修**：`AppModel.swift:228` 的
  > `case .active(let p): keymap?.reload(p); profile = p` 就是那個回寫。
  > 留著會讓下一個人去修一個已經好了的東西——這比「以為做了其實沒做」更浪費。
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

- **全螢幕**：三種入口——⌃⌘F、視窗綠燈、選單列「遊戲模式（全螢幕）」；由 `NSWindow.didEnterFullScreenNotification`／`didExitFullScreenNotification` 驅動 `AppModel.isFullScreen`（系統告知，不自行推測）。letterbox 由 `MirrorContainerView`（黑底 NSView）+ `ViewportFit`（`MirageCore` 純函式）負責——容器算好 aspect-fit 內容矩形，把 `MirrorMTKView` 佈局進去，黑邊是父 view 的背景色，`MirrorMTKView.bounds` 永遠等於內容矩形，座標數學（`normalized()`／`KeymapController`）零改動。**不綁 Esc**（Esc 在 guest 是返回鍵，搶了會壞遊戲輸入）。全螢幕時隱藏 keymap 唯讀提示 overlay（純視覺噪音），保留 `ConnectionBanner`／`InstallBanner`（斷線是必須知道的異常，安裝是使用者主動觸發的回饋）。串流解析度改用內容矩形寬 + 實際幀長寬比反推高度，上限規則在 `MirageCore/Viewport/StreamSize.swift`（純函式、有單元測試）：寬度上限 1080 **加上總像素預算 1.8 MP**——只限寬守不住成本，9:20 直向在寬度上限下會算到 1080×2400 ≈ 2.6 MP，比 spec §4.3 論證所用的 880×1960（1.7 MP）多 50%；加了像素預算後直向全螢幕為 900×2000，橫向仍由寬度上限主導，小視窗不受影響。**1.8 MP 這個值仍沒有對應的量測點**（§11.2 量到的是 0.65 MP → 30.4 fps、2.59 MP → 22.0 fps，1.8 MP 落在兩者之間）——這是**可以量了但沒人回頭量**，不是被什麼擋住：驗收線 7 原本記的「需解鎖螢幕」歸因已推翻（真因是 `AVAudioEngine` 的 NSException，2026-07-28 已修），量法是 `./scripts/verify_game_fps.sh` 配 `MIRAGE_FPS_LOG`。完整更正見 `StreamSize.swift:17-40`。
- **橫向**：`ImageFormat.rotation` 是 `[Output Only]`，emulator 已把幀轉好；長寬比一律由 `Renderer.lastFrameSize` 驅動的實際解碼幀決定，原本散在 `MirrorMTKView.viewDidMoveToWindow`／`MirrorView.Coordinator.resizeDebounced` 兩處的 `9:20` 硬編碼已移除，橫向遊戲自動支援，無需獨立分支。
- **音訊**：`EmulatorClient.attachAudio()`／`detachAudio()` 與既有 `FramePump` 對稱掛在同一條連線狀態機上（不新增第二條生命週期）——`streamAudio`（48000Hz／stereo／S16／`modeRealTime`，由 `GrpcAudioTransport` 封裝）→ `AudioRingBuffer`（SPSC 無鎖環形緩衝，容量 200ms／19_200 samples，**帶 pre-roll**：`primeThresholdSamples` 預設 9_600＝100ms，`readStereo` 在緩衝深度未蓄到門檻前一律回 0 且不計 underrun，蓄滿後才開始供貨，排乾（`n == 0`）就退回未蓄滿狀態重新蓄水——2026-08-03 由 D32 補上，詳見 `RESULTS-d32.md` §6）→ `AudioPlayer`（`AVAudioEngine` + `AVAudioSourceNode`，render callback 只做一次 `memcpy`／補零，不配置不加鎖不 log）。關視窗即靜音，跟畫面同一條 `PowerState`。選單列「靜音」勾選（`engine.mainMixerNode.outputVolume = 0/1`，macOS 無原生 per-app 音量）。`MIRAGE_AUDIO_LOG=1` 每秒印一行 `[audio] pkt=N sr=48000 ch=2 under=N over=N primes=N depth=Nms` 健康摘要（`primes`＝重新蓄水次數，判讀 pre-roll 健康度唯一的欄位——`under` 低不代表健康，可能是靠反覆蓄水把 underrun 藏起來，見 D44），是唯一能無頭驗證音訊健康的訊號。活體驗證：`scripts/verify_audio.sh`（用 `input keyevent 24` 頂音量 + `am start VIEW` 觸發內建鈴聲發聲，量測 `streamAudio → AudioRingBuffer` 5 秒封包率）——**這是唯一正確的執行方式**：`AudioLiveTests` 額外掛了 `MIRAGE_LIVE_AUDIO=1` 閘門（比照既有 `MIRAGE_LIVE_MMAP` 慣例），只有這支腳本會設定它，避免它跟其他活體測試一起跑進通用的 `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test` 覆蓋率量測指令時，因鈴聲早已播畢而假性紅燈；直接跑 `MIRAGE_LIVE=1 swift test --filter AudioLiveTests`（不帶 `MIRAGE_LIVE_AUDIO=1`）現在會 early return，看似通過但其實什麼都沒驗到。驗收線 6（連續 60 秒 `underruns == 0`）的活體驗證是 `scripts/verify_audio_gui.sh`（真 GUI + 真 `AudioPlayer`，60 秒，六條斷言，詳見下方「已知限制／移交」）。
- **已知限制／移交**：完整未驗清單（真實聽感、letterbox 目視、橫向全螢幕、遊戲模式 chrome 隱藏手感、全螢幕下 keymap/mouse capture 手感、驗收線 7 fps≥55）見 `RESULTS-p1e.md`。**這批全部是「碼在、沒人驗」，不是「被螢幕鎖定擋住」**——見下方那條更正；`overruns`/`underruns` 歸因與緩衝深度呈兩極分佈（多數逼近容量上限、至少一次幾乎全空）的 caveat 亦記錄於該文件。**驗收線 6（連續 60 秒 underruns==0）已於 2026-08-03（D32）由 `scripts/verify_audio_gui.sh` 自動化涵蓋並實測**：判定為「未通過（已大幅改善）」——pre-roll 修正後 underrun 降約 97%，但仍每 1.7 秒排乾一次重新蓄水，殘餘缺陷記為 D44，完整數據見 `RESULTS-d32.md`；驗收線 7 的 pending-human 理由同一批已失效但尚未重驗，另記 D45。**`AudioRingBuffer` 是本專案唯一允許 mutate 的資料結構**（即時執行緒的硬性要求——render callback 不得配置記憶體、不得加鎖、不得 log，破例範圍嚴格限縮在這一個 type 內，對外只暴露不可變的 `AudioChunk`／`AudioStats` 快照）。
- **游標捕捉的對稱性（P1-e fast-follow）**：`MouseCapture` 自 P1-c 就有 `didResignKeyNotification → release()`（游標陷阱的解藥），但一直缺對稱的另一半——焦點回來時沒有人重新捕捉，視窗失焦後（alt-tab、Mission Control、進出全螢幕的過場）捕捉就掉了且不會自動恢復。`AppModel+Focus.swift` 補上 `didBecomeKeyNotification → updateCapture(shouldCapture:)`。判斷條件留在 `AppModel`（`hasProfile && !editing && keyWindow`），`MouseCapture` 維持只做捕捉/釋放的機制角色。
- **覆蓋率量測**：跑 `scripts/coverage.sh`（兩次 `swift test` + `llvm-profdata merge`）。**不要**只跑 `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --enable-code-coverage`——那條指令因 `MIRAGE_LIVE_AUDIO` 閘門不會涵蓋 `GrpcAudioTransport`，只得 ~89%，會被誤判成覆蓋率回歸。實測值會逐次浮動（95.55%／95.72%／95.92% 皆量過），判定看的是有沒有跌破 ~94% 基準，不是有沒有對上某個特定小數。
- ~~**GUI 驗證的實際障礙是「螢幕鎖定」，不是 headless**~~

  > **⚠️ 更正（2026-07-29）**：**這整條是錯的，而且它是本專案代價最高的一次誤診。**
  > 原文說「`CGSSessionScreenIsLocked = true` 時 WindowServer 不合成畫面……螢幕解鎖後
  > 用同樣手法即可一次驗完所有 pending-human 項目」。
  >
  > 真因是 `AVAudioEngine` 的 Obj-C NSException 在 `@MainActor` 上把 `startLifecycle()` 扯斷，
  > MainActor 自此不再 drain——`client.states` 的消費者收不到值、MTKView 停止繪製。
  > `MIRAGE_FPS_LOG` 恆為 0 行不是因為畫面沒被合成，是因為**根本沒有人在畫**。
  > 鏡像顯示自 P1-a 起從未運作過。完整證據見
  > `../docs/specs/2026-07-28-mirror-never-rendered-investigation.md`。
  >
  > 這條歸因讓三個階段的 GUI 驗收被合理地跳過。**防護現在在樹上**
  > （`Sources/MirageShell/Audio/AudioPlayer.swift:29`），上面那份 pending 清單
  > **現在驗得了，只是沒人回去驗**。
- 驗收：`RESULTS-p1e.md`；架構詳見 `../docs/specs/2026-07-26-p1e-fullscreen-audio-design.md`。

# Display Transport：raw RGBA（預設）／MMAP（環境變數 opt-in）

畫面串流走哪條 transport，由連線建立時 `getStatus` 回報的 emulator 版本，加上
`MIRAGE_TRANSPORT` 環境變數共同決定：

- **預設（不設 `MIRAGE_TRANSPORT`）**：一律走 `GrpcStreamTransport`（raw RGBA，protobuf
  payload），不論 emulator 版本為何。
- **`MIRAGE_TRANSPORT=mmap`（opt-in，實驗性）**：需**同時**滿足兩個條件才會啟用
  `FallbackTransport(primary: MmapStreamTransport, secondary: GrpcStreamTransport)`——
  (a) 這個環境變數本身，(b) emulator 版本 ≥37。任一條件不滿足，仍然走 raw RGBA。

## 為什麼預設不是 MMAP

活體驗證發現 `MmapStreamTransport` 拿不到足夠的更新率：**Swift 約 15Hz，而同條件的 Python
client 約 50Hz**（交錯量測基準 Python 400/400 vs Swift 109–110/400）。現有降級機制（只認
「前 3 幀全零」）攔不住這個失敗模式——畫面非全零，會通過探測，使用者看到的是一張嚴重掉幀
卻沒有任何降級或錯誤訊號的畫面。三輪排查未能鎖定根因。完整細節見 `RESULTS-mmap.md`。

> ⚠️ **這裡原本寫的是「凍結」，2026-08-05 的根因調查推翻了那個描述**（結論不變）。
> 「凍結」來自 `MmapStreamLiveTests` 只取 3 幀（約 150ms）的窗口——在 15Hz 下必然全同。
> 這個更正很重要：「凍結」會把人導向「emulator 沒寫」，而實際要查的是「為什麼只有
> 1/3.6 的速率」。見 `RESULTS-mmap.md`「2026-08-05 根因調查」與 D52。

**因此預設收回 raw RGBA，MMAP
需主動選擇加入才會啟用**。

**⚠️ 2026-08-05（D39）重驗：不要再等 emulator 新版了。** 這裡原本寫著「上游 bug
（b/537802959）雖已標記 fixed 但含修正的 build 尚未發布，無法驗證」。實測 37.1.11(stable)／
37.2.1(canary)／37.2.3(dev) 三個版本，Swift 在 3 幀窗口下全部 `distinct=1`，而同一台
emulator、同尺寸、同條件的 **Python(grpcio) 對照全部正常**（`frames=30 distinct=30`）——
**問題與 emulator 版本無關，缺陷在 grpc-swift 這條路徑上**。（那個 `distinct=1` 是窗口
太短造成的，實際更新率約 27.5%，見上方的更正框。）

同一次重驗還推翻了「MMAP 幫不上 fps」：raw RGBA 這條路徑的吞吐天花板在 **270–290 MiB/s**，
而全螢幕 898×1996 要跑滿 60fps 需要 **410 MiB/s**——結構上到不了。同機同內容下
raw **40.0** fps／MMAP **56.7** fps（驗收線 7 的門檻是 55）。所以這條缺陷擋著的是驗收線 7
本身。原本「MMAP 幫不上」的結論是在 540×1200 量的，那個解析度只需要 148 MiB/s，剛好貼著
天花板下緣、本來就在滿速——觀察沒錯，錯的是外推。完整數據與限定條件見 `RESULTS-mmap.md`。

## 版本閘為何不放寬

`MmapVersionGate.allows(...)`（≥37 才允許）是一道**獨立於這條缺陷之外**的安全互鎖：
穩定版 emulator（36.x）收到 MMAP 請求會直接 **SIGSEGV**，把使用者正在跑的整台 VM 弄死
（2/2 確定性重現）。即使 `MIRAGE_TRANSPORT=mmap` 主動選擇加入，版本 <37 一律強制走
raw RGBA——opt-in 不能繞過版本閘，兩者是正交的兩道判斷。

## 三種一次性觀測訊息

連線建立時各印一次（不做每幀日誌）：

```
[transport] mmap enabled (experimental, emulator 37.2.1.0 (37.2.1-15875889))
[transport] mmap unusable, falling back to raw rgba
[transport] raw rgba (default; set MIRAGE_TRANSPORT=mmap to try mmap)
```

第一種：opt-in 且版本 ≥37，選中 MMAP 為主、raw RGBA 為降級後備。第二種：`FallbackTransport`
判定 MMAP 前 3 幀皆全零（或串流提早結束）而實際降級時印出，只印一次。第三種：**新預設**，
未設 `MIRAGE_TRANSPORT` 時的行為（若 opt-in 但版本 <37，訊息改為
`raw rgba (emulator <版本> < 37, mmap unavailable)`）。

## 為什麼 `Frame` 是複製而非映射區的 view

`MmapStreamTransport` 每收到一則通知就把映射區內容**複製**成 `Frame.rgba: Data`，而非直接
用 `Data(bytesNoCopy:)` 指向映射區——emulator 會**原地覆寫**同一塊映射區來寫下一幀，而
`LatestFrameBox` 持有最新幀、`Renderer` 在 vsync 才讀取它。若 `Frame` 直接指向映射區，
渲染器有機會讀到正在被覆寫的記憶體，畫面撕裂。複製是把該幀從持續變動的緩衝區裡快照出來，
成本經量測可忽略（`mmap-copy` 與 `mmap-touch` 只差 0.2 ms/幀），不是可優化掉的浪費。

## 活體驗證：`./scripts/verify_mmap.sh`

需要一個正在跑的 emulator（腳本會自己起動畫供應器——`streamScreenshot` 是變化驅動，
靜止畫面不出幀）。腳本本身已加上 `MIRAGE_TRANSPORT=mmap` 觸發 opt-in 路徑。

**它量的是兩條路徑，不是一條**（D39，2026-08-05 改）：

| 段落 | 是什麼 | 現況 |
|---|---|---|
| Python 對照（`mmap_client_parity.py`） | emulator 的 MMAP 寫入端正不正常 | ✅ **硬斷言**，失敗即中止 |
| Swift 活體（`MmapStreamLiveTests`） | 產品實際會走的路徑正不正常 | ❌ 已知不足（約 15Hz），印退出碼不中止 |

只量 Swift 那條時，紅燈分不出「上游壞了」與「只有我們的 client 壞了」，而這兩者的下一步
完全相反。**Swift 那條目前預期會紅**，這是已知產品缺陷，不是測試腳本或環境問題；對照組
同時是綠的，就是「缺陷在 client 側」的證據。腳本會在 Swift 那條轉綠時明確喊「狀態已改變」。

## 驗收與設計文件

完整驗收線裁決、缺陷排查歷程（含 2026-08-05 根因調查排除的 9 個假設）、覆蓋率變化說明見 `RESULTS-mmap.md`；架構設計見
`../docs/specs/2026-07-27-mmap-stream-transport-design.md`（其 §1 的「實測確認現有 emulator
版本即可繞過」一句已知只對 Python client 成立，對產品 Swift client 不成立，更正說明見
`RESULTS-mmap.md`與`../docs/upstream/2026-07-22-emulator-mmap-macos.md`的「後續更正」小節）。

# App 層 library target（MirageShell）

先前 `MirageApp` 是一個 `executableTarget`，21 檔、1668 行 App 層程式碼（`AppModel`、
`KeymapController`、`AdbClient`、`GameDetector`、`MenuBarController`、`AudioPlayer`……）**無法被
測試 target import**——這筆債跨 P1-c／P1-d／P1-e 三個階段被記錄，每次都以「App 層無法
import，只能靠讀碼＋型別系統＋活體間接佐證」結案。現在打通。

## 三層結構

```
MirageCore   純邏輯 library。禁止 import AppKit／SwiftUI／Metal／AVFoundation，逐行單元測試。
    ↑
MirageShell  App 層 library（新）。24 檔 = 20 檔原封搬入 + MirageApp.swift 拆出的 3 檔
             （MirageScene／AppModel／AppDelegate）+ 新增的 MirageEntry.swift；可被 @testable import。
    ↑
MirageApp    executable。只剩一個檔案：一個轉呼叫的 @main 空殼。
```

## 為什麼要拆成三層，不是兩層

測試 target 只能依賴 library target——SwiftPM 的 `executableTarget` 不能被其他 target
import。但 `@main` 只能掛在 executable 身上，而 `App` 協定的 `static func main()` 一旦寫在
library 裡的型別上，不會被自動呼叫。解法是讓 library side 提供一個 `public` 的轉呼叫函式：

```swift
// MirageShell（library）
public enum MirageEntry {
    public static func main() { MirageScene.main() }   // MirageScene 維持 internal
}
```
```swift
// MirageApp（executable，唯一內容）
import MirageShell

@main
struct Main {
    static func main() { MirageEntry.main() }
}
```

`App` 協定的 extension 自帶 `public static func main()`，所以 `@main` 可以掛在一個純轉呼叫的
空殼上——`MirageScene: App`（原 `MirageApp.swift` 改名）與 `AppDelegate` 都**不需要**變成
`public` 就能被啟動。這個做法先在專案外的最小 spike package 驗證過（`internal struct
SpikeScene: App` 經 `public enum SpikeEntry` 轉呼叫，行程存活 ≥5 秒），詳見
`RESULTS-shell-target.md`「R1 的結論」一節。

## 公開介面只有 `MirageEntry.main()`

`MirageShell` 的全部 `public` 宣告只有一個型別、一個函式：

```
$ grep -rn "\bpublic\b" Sources/MirageShell/
Sources/MirageShell/MirageEntry.swift:6:public enum MirageEntry {
Sources/MirageShell/MirageEntry.swift:8:    public static func main() { MirageScene.main() }
```

**新增 App 層程式碼時不需要、也不應該加 `public`。** `MirageScene`、`AppModel`（及其 4 個
extension）、`AppDelegate`、`KeymapController`、`AdbClient`、`GameDetector`、
`MenuBarController`、`MouseCapture`……全部維持 `internal`；`MirageShellTests` 一律用
`@testable import MirageShell` 觸及它們。若哪天發現需要把某個型別改 `public` 才能測試，先
確認是不是測試寫法的問題（`@testable import` 本來就能看到 internal），而不是預設加
`public`。

## 覆蓋率：`scripts/coverage.sh` 分兩段看

`MirageShell` 成為正式 target 後會出現在 `llvm-cov` 報表裡。跑 `./scripts/coverage.sh` 會看到
**兩段**輸出，不要看合併後的 TOTAL：

- **段 1（`MirageCore`）：判定依據。** 目前基準 87.80%（含 `MmapStreamTransport.swift` opt-in
  路徑 0% 的已知扣分，見 `RESULTS-mmap.md`）。要求是「不因改動而下降」，不是某個絕對數字。
- **段 2（`MirageShell`）：進度指標，不是門檻。** 目前只有 2.62%——這批 App 層程式碼的
  覆蓋率一直是 0，只是重構前它住在 `executableTarget` 裡，結構上被排除在覆蓋率報告之外
  （`RESULTS-p1e.md` 已明載）。**段 2 很低不代表退步，代表這筆債終於看得見了。** 本階段（見
  `RESULTS-shell-target.md`）刻意只開路、不鋪路——只加了 3 個 smoke test 證明
  `@testable import` 真的能觸及 internal 宣告（`MirrorContainerView` letterbox 佈局、
  `AudioPlayer.setMuted`、`InstallState`），實際把 21 個仍是 0% 的檔案補上測試是**另一輪**的
  事。**動手前務必先讀 `RESULTS-shell-target.md`「刻意排除在 smoke test 之外的全域副作用清單」
  一節**——目前列出 **8 項**，`MouseCapture`（游標鎖定）只是其中一項；`AppModel`／
  `MenuBarController`／`ClipboardWatcher` 建構或呼叫起來也會動到開發機的真實剪貼簿、選單列、
  keymap profile 檔案（`AppModel()` 光是建構就會在開發機建一個 profile 目錄）；`AdbClient`／
  `GameDetector` 會對共享模擬器跑真的 `adb` 子行程（含安裝 APK、每 1.5 秒 `dumpsys` 輪詢）；
  `AudioPlayer.start()` 會啟動真實的 CoreAudio 音訊引擎；`AppModel.start()` 會對共享模擬器
  `localhost:8554` 建立真實 gRPC 連線，直接踩進既有的 NIO teardown 架構債（`swift test`
  偶爾卡死的來源之一）。清單的掃法是逃逸路徑分類（子行程/檔案系統/系統單例/網路/UI狀態/
  持久化偏好），不是關鍵字列舉——後者曾經漏掉整個 `Process` 子行程類，細節與掃法見該文件。

若合併後的單一 TOTAL 數字被拿來當證據，本次已重新驗證：那是 **43.59%**，比原設計文件估計的
50–60% 還低——但合併 TOTAL 從來不是判定依據，段 1／段 2 分開看才是，細節見
`RESULTS-shell-target.md`。

## 驗收與設計文件

完整驗收線裁決、R1 spike 驗證方式、公開介面 grep 佐證、覆蓋率兩段數字與更正說明見
`RESULTS-shell-target.md`；架構設計見
`../docs/specs/2026-07-27-app-layer-library-target-design.md`。


## Mac 輸入法（待人工端到端驗收）

無 profile 預設用 Mac 本機組字；有 profile 預設映射，左下「文字輸入」可切換。
文字確定後走剪貼簿＋一次 Paste，`text` 不是中文通道。文字模式 Return 不直送 guest。
面板可調後續提交的候選間隔、暫停、核對不確定結果後恢復、複製保留稿；恢復不重送。
`MIRAGE_TEXT_SETTLE_MS` 可設初值（預設候選250ms），不是安全下限或欄位消費 ACK。

`MIRAGE_IME_DIAGNOSTICS=/全新路徑/trace.jsonl` 開啟不含明文的事件診斷；路徑不能已存在。
`./scripts/verify_host_ime.sh watch --help` 是只讀欄位觀察，`verify --help` 是逐碼位驗收。
完整實體按鍵與 LINE 草稿操作見
[人工清單](../docs/testing/2026-09-11-host-ime-human-checklist.md)，
實作／故障／未驗項見 [Task 5–8 結果](RESULTS-ime-tasks-5-8.md)。
尚不能以離線測試或 Task 4 通道結果宣稱真 Mac IME 問題已驗收修復。

## 模擬器多開（可切換）

多台模擬器各自開機，Mirage 同一時間只接一台；切換時停止舊連線、換端點再啟動連線，
舊模擬器維持開機。M1 16GB 的雙台同時遊玩量測見
[量測結果](RESULTS-multi-instance.md)。目前提供單視窗切換；設計見
[多實例規格](../docs/specs/2026-09-12-multi-instance-design.md)。

- **啟停**：`./scripts/emu.sh -n <名稱> start|stop|status`。名稱就是 AVD 名稱，每台需要
  各自的 AVD（用 `tools/provision` 建立）；同一 AVD 在其他埠執行時，`start` 會拒絕重開。
  預設實例表在 `scripts/lib/emu_instances.sh`：
  `mirage-game:5554:8554 mirage-poc:5556:8556`（名稱:console 埠:gRPC 埠）。
  `MIRAGE_INSTANCES` 可整份覆寫；不帶 `-n` 時選第一台並套用既有的
  `MIRAGE_AVD`／`MIRAGE_PORT`／`MIRAGE_GRPC` 覆寫。
  `status` 列出所有執行中的實例與 gRPC 綁定位址；`stop` 只停指定那台。
- **切換**：選單列 🪞 →「切換模擬器 ▸」，列出探索檔
  `~/Library/Caches/TemporaryItems/avd/running/pid_*.ini` 裡活著的實例，目前那台打勾；
  沒有其他實例時顯示停用項「沒有其他模擬器」。切換期間顯示既有的連線橫幅。
  `MIRAGE_HOST` 保持不變，App 的 `MIRAGE_PORT` 只決定啟動時的 gRPC 埠。
  鍵位 profile 跟著遊戲偵測走。
- **活體驗證**：先由使用者啟動兩台，再執行以下指令（工作目錄為 `app/`）：

  ```bash
  ./scripts/emu.sh -n mirage-game start
  ./scripts/emu.sh -n mirage-poc start
  ./scripts/verify_instance_switch.sh
  ```

  驗證腳本只連接已啟動的兩台，結束後兩台保持執行；開頭用 `require_grpc` 檢查兩個埠，
  缺少監聽時印出對應啟動指令並失敗退出。預設對 5554→5556→5554 依序執行
  `verify_keyboard.sh`（會跑 Swift 活體測試），以 guest `getevent` 判定鍵是否送達，
  每段再確認另一台 `sys.boot_completed` 仍為 1。可用 `MIRAGE_FIRST`／`MIRAGE_SECOND`
  選擇實例；若覆寫 `MIRAGE_INSTANCES`，啟動與驗證須使用同一份表。
  退出碼 0 代表上述三段判定通過；腳本未驅動 GUI 選單，也未驗證同一個 App client 的
  端點切換。選單勾選、畫面切換與按鍵送至新目標仍需人工端到端驗收。
  實例純函式自我測試在 `scripts/lib/emu_selftest.sh`（`ci.sh` 閘門 7）。

## 手機遙控（區域網路）

iPhone Safari 可作為 Mirage 的觸控第二螢幕：Mac 用 VideoToolbox 硬體編碼 H.264，
經 WebSocket 送到手機的 `VideoDecoder`，觸控經既有 `InputQueue` 注入。
見[設計文件](../docs/specs/2026-09-12-lan-remote-control-design.md)。第一版以 iPhone 為目標；
Android Chrome 需要 HTTPS。

- **開啟與配對**：選單列 🪞 →「手機遙控」→「開啟手機遙控」，手機掃描子選單 QR
  或輸入顯示的網址（點網址可複製）。「中斷連線」會作廢 token 並產生新網址；
  「關閉手機遙控」恢復原本幀路徑。開啟／關閉會重連 emulator，中斷手機連線不會。
- **關閉 Mac 視窗**：有手機連線時只隱藏視窗，串流繼續。
- **錯誤**：埠被佔用或硬體編碼器建立失敗時，選單顯示錯誤，不退回軟體編碼。
- **腳本環境變數**：`MIRAGE_REMOTE=1` 啟動即開、`MIRAGE_REMOTE_PORT` 預設 8765、
  `MIRAGE_REMOTE_TOKEN` 為 32 個小寫十六進位字元（不合法時另產生 token）。
  `MIRAGE_REMOTE_PULL_FPS` 預設 30、接受 5–60 的整數；無效值回到 30 並印診斷。
  stdout 印 `[remote] listening port=<n> 已可連線`，不印 token；腳本自行產生並傳入 token。

在 `app/` 執行，兩支遙控腳本僅接受已啟動的 `emulator-5554`／gRPC `8554`（mirage-game），
不啟停模擬器。遊戲須處於持續變動的畫面、Mac 螢幕未鎖定。
腳本透過 `package_app.sh` 與 `gui_session_start` 打包、以 `open -n --env ... --stdout ...` 啟動。
重新打包的 ad-hoc 簽署 App 可能觸發防火牆詢問；腳本固定連 **127.0.0.1**。
手機從 LAN 連入時則需允許 App 的傳入連線。

```bash
# 活體：Swift 編碼器／觸控路徑測試，接著驗 keyframe、幀序與 guest 觸控
./scripts/verify_remote_mirror.sh
./scripts/verify_remote_mirror.sh -P 8770 -w 60 -d 10

# fps：關、開、關、開，每次預設 2 輪、每輪 20 秒
./scripts/verify_remote_fps.sh
./scripts/verify_remote_fps.sh -P 8770 -r 4 -d 20

# 底層 fps 腳本可重複傳入 App 環境變數（本例開啟遙控；viewer 另行連線）
./scripts/verify_fps_fullscreen.sh -s emulator-5554 -p 8554 -E MIRAGE_REMOTE=1 -E MIRAGE_REMOTE_PORT=8770

# 純函式測試（不需要 websockets、App 或模擬器）
python3 -m unittest discover -s scripts/lib -p remote_client_selftest.py
/bin/bash scripts/lib/remote_fps_stats_selftest.sh
```

`remote_venv.sh` 首次執行以 `/usr/bin/python3 -m venv` 建 `scripts/.venv-remote`，安裝
`websockets>=15,<16`；既有 `.venv*/` 忽略規則已涵蓋。Python 程式相容 3.9／3.11 與
websockets 13／15，純函式測試納入 CI 閘門 8；shell 摘要、值域及 viewer 窗口測試納入閘門 7。

活體腳本先確認 Swift 測試真正 passed，再分別用 `getevent_touch.sh` 檢查 Swift 與 GUI 路徑的
`ABS_MT_TRACKING_ID` 按下／放開且無卡住 slot。Python 用戶端須在 60 秒內收到 keyframe，
幀序無缺口、實際送出三則 down/move/up，且 ping 原封 echo。stdout 會列出 App、Swift、
getevent 與 Python 紀錄位置（Swift 的 getevent 副本為該路徑加 `.swift`）。
可依計畫暫將 `touch_messages` 改為只回 down，確認 R3 紅燈後還原、重跑。

fps 對照每臂取得兩次有效摘要，取兩個中位數的較低者，比較 **ON_MEDIAN ≥ OFF_MEDIAN − 3**；
兩臂各需至少 2 個有效輪次。保留四次 log 並印 `OFF_VALUES`／`ON_VALUES` 與值域。
底層的絕對 55 fps 門檻另行解讀，但尺寸未收斂、無有效摘要、異常退出不採計。
開啟臂由 `remote_client.py --loop` 重連；每秒收幀紀錄須涵蓋每個量測窗口（端點容許 2 秒、
內部間隔最多 3 秒，窗口中斷線即失敗），避免 viewer 未工作時得到假對照。
兩臂值域交集大於 3 fps 會警告，請加 `-r 4` 重跑；通過只代表該次抽樣。

靜止畫面也會串流：controller 保留最後一幀，`heartbeatInterval` 預設 250 ms（可透過
`RemoteMirrorConfiguration` 設定）。新 viewer 連線立即取得可用幀的 keyframe，沒有 viewer 時
不取幀、不編碼。1080×2400 靜止畫面約每秒 4 次像素拷貝與硬體編碼，低於正常動態的 30 fps。
重送保留像素並更新編碼時間戳；心跳與間歇後的新幀都不強制 IDR。只有 viewer 初連／明確請求、
編碼 session 重建（尺寸變更）、編碼器的 `MaxKeyFrameInterval=120` 到期才產生 keyframe。
每個 encoder 持有 `CVPixelBufferPool`，同尺寸重用緩衝、尺寸變更重建，每幀一次 vImage 轉換。

PM iPhone 實測 SPS 改寫後 `pending=0`、arrival→output p50/p95 為 5/6 ms，因此正常的
250 ms P-frame 心跳不需 flush。先前 100 ms flush／強制 IDR 政策曾在 22 秒收到 101 幀、
其中 92 張 keyframe，MirageApp 約 70% CPU；fps 對照也出現 guest 幀率下降。
現在 viewer 要連續 2 秒沒有 chunk 才 flush，完成後透過已配對的 `/ws/video` 要求 keyframe；
失敗僅記錄診斷。controller 還沒收到任何一幀時會保留 keyframe 請求，第一幀抵達後送出。
本次修改後的 CPU／guest fps 數字待 PM 重測，不能以程式碼變更視為驗收通過。

拉取率 20／30 fps 對照（`verify_remote_fps.sh` 會將此環境變數傳給開啟臂的 App）：

```bash
MIRAGE_REMOTE_PULL_FPS=20 ./scripts/verify_remote_fps.sh -r 3
MIRAGE_REMOTE_PULL_FPS=30 ./scripts/verify_remote_fps.sh -r 3
```

viewer 的計時器與解碼恢復測試（Node.js 18 以上，已接入閘門 8）：

```bash
node --test scripts/lib/remote_viewer_selftest.cjs
```

**驗證狀態（2026-09-12）**：本次僅執行純函式測試、shell 語法檢查與閘門 4 的兩段 lint。
Swift 編譯、新增的觸控活體測試、兩次 GUI 活體、活體故障注入、fps 對照及完整 CI 由 PM 外部執行；
尚無本次 OFF_VALUES／ON_VALUES 實測數字。階段 E 的 iPhone glass-to-glass 人工量測（門檻 50 ms）亦未做。
