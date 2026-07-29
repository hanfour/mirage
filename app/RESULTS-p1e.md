# P1-e 全螢幕遊戲模式與音訊 驗收結果

> ## ⚠️ 2026-07-29 全檔更正：本檔多處「螢幕鎖定」歸因是錯的
>
> 更正先前只補在一處（下方 line ~99），其餘各節仍原樣斷言舊歸因。本次補齊。
>
> **真因**：`AVAudioEngine.connect(_:to:format:)` 收到 interleaved format 時丟出的
> `kAudioUnitErr_FormatNotSupported (-10868)` **Obj-C NSException**，在 `@MainActor` 上把
> `startLifecycle()` 扯斷，MainActor 自此不再 drain——MTKView 停止繪製，`fps=` 恆為 0。
> **與螢幕是否鎖定無關**；鏡像顯示自 P1-a 起從未運作過。
> 見 `../docs/specs/2026-07-28-mirror-never-rendered-investigation.md`。
>
> **本檔受影響的段落**：驗收線 7 那列（line ~22）、pending-human 清單標題（line ~47）、
> 以及「GUI pending-human：診斷已收斂到『螢幕鎖定』」整節（line ~168 起）。
>
> **最重要的後果**：防護已在樹上（`Sources/MirageShell/Audio/AudioPlayer.swift:29`），
> 本檔所有列為 pending 的 GUI 項目**現在都驗得了**。它們的正確狀態不是「被外部條件擋住」，
> 是「**可以驗了，但沒人回頭驗**」——這一類在清單上長得跟前者一模一樣，因此每一輪都被
> 合理地跳過。見 `../docs/specs/2026-07-29-project-review.md` §8 D 節。

- **日期**：2026-07-26
- **模擬器**：Android emulator，`emulator-5554`（headless，Android 15／API 35，`wm size` 回報
  `Physical size: 1080x2400`，`ro.product.model=Android SDK built for arm64`）——執行前已確認
  `adb devices` 僅列 `emulator-5554 device`，`ANDROID_SERIAL=emulator-5554` 全程顯式匯出；全程
  未呼叫 `loadSnapshot`、未重啟、未關閉模擬器
- **工具鏈**：Swift 6.2.3（swift-testing）、grpc-swift 1.27.5、swift-atomics 1.3.1
- **執行**：subagent-driven（Task 1–9 implementer 逐關 + task-review）＋本 Task 10 於活體模擬器上
  重新量測全部 7 條驗收線、寫驗收文件與 README

## 驗收線逐條裁決（spec §8）

| # | 驗收線 | 實測 | 判定 |
|---|---|---|---|
| 1 | `swift test` 全綠，既有 101 個 `@Test` 不回歸 | **本次重新量測**（commit `8a1b694` 修正後）：預設 `swift test` → `Test run with 127 tests passed after 0.638 seconds.`；`ANDROID_SERIAL=emulator-5554 MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test` → `Test run with 127 tests passed after 6.581 seconds.`（含 coverage 旗標的同指令 → 5.724 秒，同樣 127/127）——**兩種呼叫方式現在皆全綠**，取代先前記錄的「完整套件可能出現 126/127」（見下方「已知限制」第一項，該問題已修正）。127 = 101 基準 + 本階段新增 26 個（Task 1 ViewportFit +6、Task 4 AudioChunk +7、Task 5 AudioRingBuffer +8、Task 7 EmulatorClient 音訊編排（`EmulatorClientAudioTests`）+4、Task 9 `AudioLiveTests` +1；Task 2/3/6/8 未新增 MirageCore 單元——分別是純接線/App 層/僅活體可驗/App 層）。無回歸 | ✅ PASS |
| 2 | `ViewportFit`、`AudioRingBuffer` 逐行 **100%** 覆蓋 | `xcrun llvm-cov report`（本次重新量測）：`Sources/MirageCore/Viewport/ViewportFit.swift` 行覆蓋 **13/13 → 100.00%**；`Sources/MirageCore/Audio/AudioRingBuffer.swift` 行覆蓋 **55/55 → 100.00%**（region 92.00%，2 個未覆蓋 region 屬條件式分支組合而非行級遺漏，brief 只要求 line 100%，見 Task 5 report 說明）。兩檔在預設與 live 兩種呼叫方式下數字一致，不受下方第 3 項的量測方式變動影響 | ✅ PASS |
| 3 | 整體 MirageCore 覆蓋率不低於現況（~94%，含 live smoke 完整呼叫方式） | **本次重新量測後發現一個新的方法論細節，需誠實記錄**：commit `8a1b694` 讓 `AudioLiveTests` 多掛一道 `MIRAGE_LIVE_AUDIO` 閘門，只有 `verify_audio.sh` 會設定它。結果是單獨執行文件既有指令 `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --enable-code-coverage`（127/127 全綠）時，`AudioLiveTests` 會直接 early return，**不再實際呼叫 `GrpcAudioTransport`**——`llvm-cov report -ignore-filename-regex 'Generated\|Tests\|\.build'` 量到 **TOTAL line 89.25%（region 85.32%、function 91.56%）**，`GrpcAudioTransport.swift` 單獨掉到 **11.69%**（先前約 94.81–98.70%）。**單獨這條指令的數字已低於 ~94% 基準**，不能直接沿用。把它跟 `MIRAGE_LIVE=1 MIRAGE_LIVE_AUDIO=1 swift test --filter AudioLiveTests --enable-code-coverage`（即 `verify_audio.sh` 觸發發聲後的做法，本次也重新量測：`writes=341`）各自的 `.profraw` 用 `xcrun llvm-profdata merge -sparse run1.profraw run2.profraw -o merged.profdata` 合併後再跑 `llvm-cov report`，得到 **TOTAL line 95.92%（region 87.84%、function 94.16%）**，`GrpcAudioTransport.swift` 回到 **98.70%**——高於既有基準。**判定依據採用合併後的數字**，因為這才是專案目前兩個活體測試入口（一般 live 套件 + 音訊專用 `verify_audio.sh`）合起來能達到的完整覆蓋，與 P1-a 建立的「用專案實際測試流程量測」原則一致。**方法論細節見下方「已知限制」第一項**——這代表「量測完整覆蓋率」現在需要兩條指令合併，單一指令不再足夠，未來維護者需知悉 | ✅ PASS |
| 4 | `swift build -c release` 零非-deprecation 警告 | 完整乾淨重建（先 `rm -rf .build/release .build/arm64-apple-macosx/release`）：`Build complete! (146.29s)`；`grep -ci warning` 與 `grep -ci deprecat` 對完整建置 log **皆為 0**——本次是零警告（連 deprecation 警告都沒有），非僅「零非-deprecation 警告」 | ✅ PASS |
| 5 | 活體：audio packet 率 **≥ 30 pkt/s**，格式 48000/stereo/S16 | `./scripts/verify_audio.sh` 本次獨立重跑兩次：第一次 `writes=344 depth=17778 under=3 over=85`，第二次 `writes=344 depth=18752 under=3 over=85`——5 秒視窗內 344 包 ≈ **68.8 pkt/s**，遠超 30 pkt/s 門檻。格式讀碼確認：`GrpcAudioTransport.packets()` 對 `streamAudio` 請求 `samplingRate=48000`、`channels=.stereo`（`AudioStreamFormat.standard` = 48_000/2ch）、`format=.audFmtS16`、`mode=.modeRealTime` | ✅ PASS |
| 6 | 活體：連續 **60 秒** `underruns == 0` | **無法用現有 harness 判定**。Task 9 的活體測試用測試專用背景排空器（`Task.sleep` 節流模擬 `AudioPlayer` render callback，非真正 CoreAudio），視窗僅 **5 秒**、非 60 秒。逐筆核對 task-9/task-10 兩份報告全部「guest 確實在發聲」的 `[audio-live]` 輸出，共 **7 次獨立執行**（完整清單見「Task 9 Step 1 的發聲手段結論」）：`underruns` 範圍 **3–426**，**從未量到 0**——不能拿來宣稱驗收線 6 通過。（其中一筆 `overruns` 量到 **0**，見下方「已知限制」——但 `underruns` 仍非零，不影響本條判定。）真正的 60 秒連續判定需要真 `AudioPlayer`（AVAudioSourceNode render callback）+ 真 GUI session 下用 `MIRAGE_AUDIO_LOG=1` 觀察 | ⬜ pending-human |
| 7 | fps 不回歸（`MIRAGE_FPS_LOG` ≥ 55，全螢幕串流解析度上限下） | 本機顯示器目前 `Display Asleep: Yes`（`ioreg -n IODisplayWrangler` 確認），與 `RESULTS-p1a.md` 記載的同一類本機限制。本次仍實際嘗試：`MIRAGE_FPS_LOG=1 ./.build/release/MirageApp` 背景跑 8 秒後 kill，輸出檔案 **0 行**（無 fps 日誌、無任何輸出）——證實 headless/螢幕關閉下 SwiftUI `WindowGroup` 的 `.task` 未被驅動，`MIRAGE_FPS_LOG` 迴圈從未執行。**不可**拿 transport 層或活體測試的任何數字冒充 App 合成層 fps——本階段沒有任何 fps 數字可回報 | ⬜ pending-human |

## Task 9 Step 1 的發聲手段結論

實際採用手段：`input keyevent 24`（`KEYCODE_VOLUME_UP`）連按 15 次把 `STREAM_MUSIC` 頂到上限（`Max: 15` → `streamVolume:15`）＋ `am start -a android.intent.action.VIEW -d file:///product/media/audio/ringtones/Ring_Synth_04.ogg -t audio/ogg` 叫起內建 `com.android.music/.AudioPreview` 播放。

- brief 原假設的 `/system/media/audio/ringtones/` 在本機映像（`sdk_phone64_arm64`, canary 37.2.1）**不存在**；實際音檔在 `/product/media/audio/ringtones/Ring_Synth_04.ogg`（本任務再次以 `adb shell ls` 確認仍然存在，路徑穩定）。
- `adb shell media volume ...` 二進位在本機映像上不存在（`inaccessible or not found`），`input keyevent 24` 是驗證有效的替代手段。
- **可靠重現，完整彙總已重新逐筆核對（見下表，本次校正）**：把 `task-9-report.md` 與 `task-10-report.md` 裡每一筆「消費者排空修正後、guest 確實在發聲」的 `[audio-live]` 原始輸出逐筆列出（排除兩類不同物理情境：(a) 消費者排空修正**前**的診斷跑次 `writes=17 depth=18686 under=0 over=436`——那是完全沒有消費者的舊程式碼,不代表最終行為；(b) 完整套件跑法下 guest **未**發聲的失敗嘗試（如 `writes=0`/`writes=41`）——那是靜默情境，buffer 沒有真實資料流入,跟「guest 正在發聲」不是同一回事），共得 **7 筆**可稽獨立執行：

  | 來源 | writes | depth（samples／占 19_200 容量%） | under | over |
  |---|---|---|---|---|
  | task-9-report.md（Step 2 第一次） | 344 | 17184／89.50% | 4 | 83 |
  | task-9-report.md（Step 2 第二次） | 345 | 19150／99.74% | 5 | 86 |
  | task-9-report.md（審查回應，閘門驗證） | **450** | **68／0.35%** | **426** | **0** |
  | task-10-report.md（原 Task 10 第一次） | 344 | 17778／92.59% | 3 | 85 |
  | task-10-report.md（原 Task 10 第二次） | 344 | 18752／97.67% | 3 | 85 |
  | task-10-report.md（本輪修法後追加，`verify_audio.sh`） | 345 | 19006／98.99% | 4 | 86 |
  | task-10-report.md（本輪修法後追加，覆蓋率合併實驗） | 341 | 18232／94.96% | 4 | 87 |

  **正確範圍（取代先前版本錯誤的「8 次／3–6／83–86／從未量到 0」彙總）**：`writes` **341–450**；`depth` **0.35%–99.74%**（占容量）；`underruns` **3–426**；`overruns` **0–87**。此發聲手段在這 7 次獨立執行中皆能讓 `writes` 遠超 75 門檻，確認可重複觸發、非一次性僥倖；但 `underruns`/`overruns`/`depth` 三者的實際波動範圍遠比先前版本描述的寬，詳見下方「已知限制」的修正說明。
- **已修正（原「範圍限制」問題）**：本任務原本回報「上述手段在單獨跑 `--filter AudioLiveTests` 時可靠，但放進完整 `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test`（含其他活體測項一起跑）時 `AudioLiveTests` 的 `writes` 會明顯不穩定（曾量到 41、0）」——追查原因是 `Ring_Synth_04.ogg` 播放時長很短、播畢後 `am start VIEW` 對已在前景的 `AudioPreview` 不會使其重新播放，完整套件因其他活體測項排隊消耗時間，輪到 `AudioLiveTests` 的 5 秒取樣窗口時 guest 常已無聲。**此問題已由使用者裁決修法並完成（commit `8a1b694`）**：`AudioLiveTests` 新增獨立閘門，需同時滿足 `MIRAGE_LIVE=1` 與 `MIRAGE_LIVE_AUDIO=1` 才會執行（比照既有 `MIRAGE_LIVE_MMAP` 慣例）；`MIRAGE_LIVE_AUDIO=1` 只由 `scripts/verify_audio.sh` 設定（唯一保證發聲前置條件成立的呼叫端）。本任務重跑驗證：`ANDROID_SERIAL=emulator-5554 MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test` 現在穩定 **127/127 全綠**（`AudioLiveTests` 在此指令下 early return，不再參與斷言，也不再造成紅燈）；**正確的音訊活體執行方式是跑 `./scripts/verify_audio.sh`**，不是 `MIRAGE_LIVE=1 swift test --filter AudioLiveTests`（後者現在會因缺 `MIRAGE_LIVE_AUDIO=1` 而 early return，得到 `Test run with 1 test passed`但實際上什麼都沒驗）。
- **修法的副作用（本次新發現，見驗收線 3 與下方「已知限制」）**：這道閘門讓「一般 live 測試套件」與「音訊活體」變成兩個必須分別觸發的入口——單獨跑文件既有的覆蓋率量測指令不再涵蓋 `GrpcAudioTransport`，需要額外合併 `verify_audio.sh` 的覆蓋率資料才能拿到完整數字。
- **另一項先前未收錄的 Task 9 發現（審查員 Minor，本次補齊）**：計畫（brief）原本給的 `AudioLiveTests.swift` 程式碼**沒有消費者排空 `AudioRingBuffer`**。`AudioRingBuffer` 容量只有 200ms（19_200 samples）天花板，沒有消費者的話幾秒內就會填滿，之後每一包都被計為 `overrun` 而非 `write`——`writes` 會結構性地卡在 ~17–20，跟 guest 是否真的在發聲完全無關（Task 9 實測到這個現象：`writes=17, overruns=436, depth` 貼著容量上限）。Task 9 的修法是在測試裡加一個**測試專用**的背景排空器（`drainRingAtRealTimeRate`，以 48kHz/stereo 的真實節奏——960 samples/10ms——呼叫 `ring.read(into:count:)`，模擬 `AudioPlayer` 的 `AVAudioSourceNode` render callback 角色），**未調整門檻、未調整 `AudioRingBuffer` 容量、未動任何產品程式碼**。這件事目前完整記載於 `AudioLiveTests.swift` 的 doc comment（第 5–13 行），但先前未收進 RESULTS——它是「計畫本身有缺陷、被活體實測抓出來」的具體案例，對未來維護者理解為何測試檔比 brief 原文多一段背景排空邏輯有價值，故在此正式記錄。

## pending-human 清單（spec §9 五項 + 驗收線 6、7）

原因統一：**本機 GUI App headless（螢幕 `Display Asleep: Yes`）不驅動 SwiftUI `WindowGroup` 的 `.task`**，需真 GUI session（有顯示器、螢幕已解鎖）才能驗證。本次已用實際嘗試（8 秒背景跑 App、輸出 0 行）佐證此限制仍然存在，而非憑印象宣稱。

1. 實際聽得到聲音，且無爆音／破音／延遲感（spec §9-1）。
2. 全螢幕 letterbox 目視：置中、黑邊純黑、畫面不變形（spec §9-2）。
3. 橫向遊戲的全螢幕表現（spec §9-3）。
4. 遊戲模式 chrome 隱藏的實際手感——keymap overlay 消失、`ConnectionBanner`／`InstallBanner` 仍可見（spec §9-4）。
5. 全螢幕下 keymap 與 mouse capture 的實際手感（spec §9-5）。
6. 驗收線 6：連續 60 秒 `underruns == 0`（需真 `AudioPlayer` + GUI，見上表）。
7. 驗收線 7：`MIRAGE_FPS_LOG ≥ 55`（需真 GUI 合成，見上表）。

## 覆蓋率細節

`xcrun llvm-cov report ... -ignore-filename-regex 'Generated|Tests|\.build'`（排除 protobuf 產生碼、測試檔、第三方 checkout；方法論同 `RESULTS-p1a.md` 驗收 4）：

**方法論更新（本次修正後量測，取代先前版本）**：commit `8a1b694` 讓 `AudioLiveTests` 掛上 `MIRAGE_LIVE_AUDIO` 閘門後，單一指令不再能同時涵蓋「一般 live 套件」與「`GrpcAudioTransport` 的音訊活體」兩者的程式碼路徑，需分別測量後合併 `.profraw`：

| 呼叫方式 | region | function | line |
|---|---|---|---|
| `swift test --enable-code-coverage`（預設，無 live） | 74.77% | 76.62% | 66.67%（未達 94% 基準） |
| `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --enable-code-coverage`（單獨這條指令，`AudioLiveTests` early return） | 85.32% | 91.56% | **89.25%（未達 ~94% 基準——單獨這條指令不足以判定驗收線 3）** |
| 上一列 + `MIRAGE_LIVE=1 MIRAGE_LIVE_AUDIO=1 swift test --filter AudioLiveTests --enable-code-coverage`（`verify_audio.sh` 觸發發聲後），兩者 `.profraw` 以 `xcrun llvm-profdata merge -sparse` 合併 | **87.84%** | **94.16%** | **95.92%（達標，採此為驗收線 3 判定依據）** |

P1-e 新增檔案的個別數字（合併後的完整量測）：

| 檔 | Line 覆蓋 |
|---|---|
| `Viewport/ViewportFit.swift` | 100.00%（13/13） |
| `Audio/AudioTransport.swift` | 100.00%（27/27） |
| `Audio/AudioRingBuffer.swift` | 100.00%（55/55，region 92.00%） |
| `Audio/GrpcAudioTransport.swift` | 98.70%（77 行，1 未覆蓋——單獨跑「一般 live 套件」指令會因 `MIRAGE_LIVE_AUDIO` 閘門掉到 11.69%，**必須**合併 `verify_audio.sh` 的量測才能反映真實覆蓋，見上表方法論說明；`GrpcAudioTransport` 依 plan 只能活體驗，未寫假 channel 單元測） |
| `EmulatorClient.swift`（含本階段音訊 attach/detach 編排） | 94.74%（285 行，15 未覆蓋，不受本次閘門修法影響——由 `EmulatorClientAudioTests` 等單元測試涵蓋） |

`Sources/MirageApp/`（`MirrorContainerView`、`AudioPlayer`、`AppModel+FullScreen`、`AppModel+Audio`、`MenuBarController` 的全螢幕/靜音項目）**不在此報告中**——`Package.swift` 的 `testTarget` 只依賴 `MirageCore`，App 層結構上被排除在覆蓋率報告之外，與既有 P1-a/P1-c/P1-d/APK 安裝各階段的既有範圍決定一致，非本階段新引入的缺口。

## 已知限制／移交

- **驗收線 6/7 需 GUI，本次已如實列 pending-human**（見上）。
- **overruns/underruns 的歸因是合理推論、非已證明（本次校正：先前版本的彙總範圍有事實錯誤，已修正）**：先前版本宣稱「overruns 落在 83–86、underruns 落在 3–6、underruns 從未量到 0」——這條彙總被一筆同批工作產出的真實資料反駁：`task-9-report.md`「審查回應」記錄的一次獨立執行量到 `writes=450 depth=68 under=426 over=0`，`over=0` 確實被量到過，`under=426` 遠在「3–6」之外。逐筆核對兩份報告的全部 7 次獨立執行（清單見「Task 9 Step 1 的發聲手段結論」）後，正確範圍是 `underruns` **3–426**、`overruns` **0–87**。**這筆資料點不是要被藏起來的例外，反而是支持「harness 排空節奏不穩」假說最直接的證據**：同一份測試程式碼、同一套 `drainRingAtRealTimeRate` 背景排空器，在 6 次執行中呈現「buffer 常態逼近容量、overruns 主導（83–87）、underruns 個位數（3–5）」的體制，卻在這一次執行中呈現完全相反的體制——「buffer 幾乎全空（depth=68／容量 0.35%）、underruns 高達 426、overruns 掉到 0」。同一段程式碼在不同排程條件下量到光譜兩端，正說明 `Task.sleep` 驅動的排空器與 gRPC 送達之間的相對時序（哪一方先跑、跑得多穩）才是決定 under/over 落在哪一端的關鍵變因，而非任何產品邏輯缺陷；真正的 `AVAudioSourceNode` render callback 由 CoreAudio 硬體時脈驅動，不會有這種跨越整個光譜的擺盪。**這個推論仍有機制支撐但非已證明**——沒有人實際量測排空迴圈的 wall-clock 漂移來精確解釋為何某次執行會落在光譜的哪一端；維護者不應把「harness 侷限」這個歸因當作已證實的結論，但這筆極端資料點是目前為止最有力的間接佐證。
- **緩衝深度並非「常態逼近容量上限」，而是兩極分佈（本次校正：先前版本的彙總範圍有事實錯誤，已修正）**：先前版本宣稱「深度常態逼近容量上限」並列出 4 筆全部落在 89.5–99.7% 區間的數字——這條彙總同樣被上述 `depth=68`（容量的 0.35%，幾乎全空）反駁。7 次獨立執行的完整 `depth` 分佈是：6 次落在 **89.50%–99.74%**（逼近容量上限），1 次落在 **0.35%**（幾乎全空）。正確的描述是「多數執行中緩衝逼近容量上限（消費端跟不上、由 `overruns` 顯現），但至少 1 次執行呈現相反的近乎全空狀態（消費端跑贏、由 `underruns` 顯現）」——兩極分佈本身就是 harness 排空節奏不穩定的又一佐證（見上一條）。未來任何人只看 `writes=344` 這類 headline 數字、或只看多數執行的「逼近容量」印象，會漏掉這個兩極分佈，故在此明確記錄兩端數字，不只記錄多數情況。
- ~~**`AudioStats.depthSamples` 可能為負**~~ → **已修（fast-follow）**，見文末「P1-e fast-follow」。
- ~~**`AudioPlayer.start()` 的 catch 分支未 `engine.detach(node)`**~~ → **已於 P1-e 終審修正**（commit `da9a6aa`）：失敗路徑與 `stop()` 皆會 `engine.detach(node)`。本條為文件過期，已校正。
- ~~**`concurrentProducerConsumerKeepsDataIntact` 的提早結束路徑無下限斷言**~~ → **已修（fast-follow）**，見文末。
- **App 層架構債（既有，非本階段引入，但本階段持續往裡面加程式碼）**：`MirageApp` 是 `executableTarget`，唯一測試 target 只依賴 `MirageCore`，**無法 import `MirageApp`**。故 `AudioPlayer`、`MirrorContainerView`、`AppModel+FullScreen`、`AppModel+Audio`、`MenuBarController` 全螢幕/靜音項目——本階段新增的 App 層程式碼——皆無單元測試覆蓋，正確性靠讀碼＋型別系統＋活體佐證，與 P1-c/P1-d 交接時記載的 `KeymapController`/`AdbClient` 同一類缺口。若要讓這些程式碼可測，需把它們抽成可 import 的 library target（後續選項，本階段未做）。
- **完整 live 測試套件中 `AudioLiveTests` 的觸發時序不穩定——已修正**：本任務原本回報 `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test`（全套，非 `--filter`）跑法下，`AudioLiveTests` 的 `writes` 斷言可能因為與其他活體測試併發、鈴聲已播畢而不穩定（曾量到 41、0）。使用者已裁決修法並完成（commit `8a1b694`）：新增 `MIRAGE_LIVE_AUDIO` 閘門（比照既有 `MIRAGE_LIVE_MMAP` 慣例），只有 `verify_audio.sh` 會設定它；`AudioLiveTests` 在通用 `MIRAGE_LIVE` 套件呼叫下改為 early return，不再參與斷言。本任務重新驗證：`MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test`（含／不含 `--enable-code-coverage`）皆穩定 **127/127 全綠**。**正確的音訊活體執行方式是跑 `./scripts/verify_audio.sh`**（會設定 `MIRAGE_LIVE_AUDIO=1` 並先觸發發聲），不是 `MIRAGE_LIVE=1 swift test --filter AudioLiveTests`（後者現在會因缺 `MIRAGE_LIVE_AUDIO=1` 而 early return，得到看似通過但實際什麼都沒驗的 `Test run with 1 test passed`）。
- **修法的副作用——本次新發現，非阻塞但需誠實記錄**：這道閘門解決了紅燈問題，但代價是「一般 live 套件」與「音訊活體」變成兩個必須分別觸發的入口。單獨執行文件既有的覆蓋率量測指令（`MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --enable-code-coverage`）**不再涵蓋 `GrpcAudioTransport`**（該檔 line coverage 從約 94.81–98.70% 掉到 **11.69%**），把 MirageCore TOTAL line coverage 拉到 **89.25%**——**低於 ~94% 基準**。若要拿到符合基準的完整數字（**95.92% line**），現在需要額外執行 `MIRAGE_LIVE=1 MIRAGE_LIVE_AUDIO=1 swift test --filter AudioLiveTests --enable-code-coverage`（觸發發聲後），並用 `xcrun llvm-profdata merge -sparse` 把兩次的 `.profraw` 合併，再對合併後的 `.profdata` 跑 `llvm-cov report`。**這是本階段量測方法論的一項新增步驟，未來任何人只跑單一指令量覆蓋率，會得到一個看起來低於基準、但其實只是漏了音訊活體貢獻的數字**——值得在此明確記錄，避免未來被誤判為真的覆蓋率回歸。

## 判定

- **P1-e GO（可量測部分）**：驗收線 1–5 全數 **PASS**，附真實輸出（測試 127/127（一般套件與 live 套件皆全綠，`MIRAGE_LIVE_AUDIO` 閘門修法後確認）、`ViewportFit`/`AudioRingBuffer` 逐行 100%、MirageCore 合併覆蓋率 95.92%（高於 ~94% 基準，方法論見上）、release 零警告、活體封包率 68.8 pkt/s／48k/stereo/S16 格式確認）。
- **驗收線 6、7 誠實列 pending-human**：現有 harness（測試專用背景排空器、headless App）無法判定，需真 `AudioPlayer` + 真 GUI session；本次已附上實際嘗試的證據（fps 日誌 0 行輸出、underruns 累計 7 次獨立執行範圍 3–426、從未量到 0）而非僅憑印象標註。
  > **⚠️ 2026-07-28 更正**：此處引為證據的「fps 日誌 0 行輸出」，其原因**不是**「需要真 GUI session」。
  > 在真 GUI session、螢幕未鎖、使用者自己的終端機執行的條件下仍是 0 行——鏡像顯示自 P1-a 起
  > 從未運作過（連線成功、幀有進來，但狀態傳不到 UI，且有合成視窗時會 SIGSEGV）。
  > 見 `docs/specs/2026-07-28-mirror-never-rendered-investigation.md`。這條不是 pending-human，是 pending-fix。
- **spec §9 五項 pending-human** 全數列出，皆需真 GUI session。
- **overruns/underruns 歸因與緩衝深度兩極分佈**（含本次校正後的完整範圍與反例資料點）已在「已知限制」明確記錄為 caveat，未包裝成已證實的結論。
- **App 層測試覆蓋缺口**（既有架構債）、**計畫原始活體測試碼缺消費者排空的發現**（本次補齊收錄）、**`AudioLiveTests` 併發時序問題已修正**（commit `8a1b694`）、以及**修法引入的覆蓋率量測新步驟（需合併兩條指令的 `.profraw`）**皆已記錄，供 Phase-1 後續 fast-follow 或架構調整參考。

---

# P1-e fast-follow（2026-07-27）

P1-e 合併後把終審 parked 的殘留項與已知限制逐條收掉，並跑一次完整 e2e。

## 修了什麼

| 項目 | 修法 | 回歸守門 |
|---|---|---|
| `AudioStats.depthSamples` 瞬時可為負 | `stats` 改**先讀 `readIndex` 再讀 `writeIndex`**。兩索引皆單調遞增且 `w >= r` 恆成立，故 `w(t2) - r(t1)` 永不為負——用順序消除特殊情況，**不加** `max(0,)` 分支 | `depthNeverGoesNegativeUnderThreadedContention`（真實 OS 執行緒）。**偵測率實測**：把順序改回錯的寫法 5 次中 4 次紅；修正版連跑 8 次全綠。**cooperative `Task` 版本 0/5 抓不到**——排程粒度遠大於兩個相鄰 atomic load 之間的窗口，那種寫法是什麼都沒驗到的假測試 |
| 視窗焦點恢復時不重新捕捉游標 | 新增 `AppModel+Focus.swift`：`didBecomeKeyNotification` → `mouseCapture.updateCapture(shouldCapture:)`。`MouseCapture` 自 P1-c 就有 `didResignKey → release`，一直缺對稱的另一半，失焦後捕捉掉了不會自動恢復（體感是「look 突然不動了」）。終審點名此缺口在進出全螢幕時更易被踩到 | 無自動測試（App 層不可 import，見既有架構債）。列入 pending-human |
| 串流尺寸上限只限寬 | 加**總像素預算** `maxPixels = 1.8 MP`。原本 9:20 直向在 `maxWidth = 1080` 下算到 1080×2400 ≈ **2.6 MP**，比 spec §4.3 論證所用的 880×1960（≈1.7 MP）多 50%。現在直向全螢幕為 **900×2000 = 1.80 MP**；橫向仍由寬度上限主導（1080×486）；小視窗完全不受影響 | `StreamSizeTests` 7 項（上下限、偶數對齊、退化 aspect、任意長寬比的像素預算不變式） |
| 「未連線就先 suspend」零測試覆蓋 | 補 `suspendBeforeFirstConnectStaysSilentUntilWake` | **決定性**守門：把終審拿掉的 `channelBox != nil` 半條 guard 加回去，測試立刻紅（power 未進 `.suspended` 且 `subscribeCount == 1`——視窗隱藏卻訂閱了音訊） |
| `ViewportFit` 極端比例截斷為 0 無測項 | 補 `extremeRatioTruncatingToZeroStaysInBounds` | 釘住「函式在此輸入下仍不為負、不超界」，避免日後有人在函式內加特例（呼叫端 `MirrorContainerView.layout()` 已有 guard） |
| 併發測試可能偽陽性綠燈 | 加 `collected.count >= 64` 下限斷言 | — |

**順帶**：`StreamSize` 的算術從 `MirrorView.Coordinator`（困在不可測的 executable target）抽到 `MirageCore/Viewport/StreamSize.swift`，讓它真的能被單元測試——App 層架構債往回收了一小塊。

## e2e 實測（2026-07-27，全部親跑，非引用先前數字）

| 項目 | 結果 |
|---|---|
| `swift test`（預設） | **137/137 綠** |
| `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test` | **137/137 綠** |
| `swift build -c release` | **0 警告**（含 deprecation） |
| `./scripts/coverage.sh`（合併兩次執行） | 量了兩次：**95.72%** 與（全部修正後複驗）**95.62%** line。`StreamSize` 100%、`ViewportFit` 100%、`AudioRingBuffer` 100%（line）、`GrpcAudioTransport` 98.70% |
| `./scripts/verify_audio.sh` | 三次：`writes=454 depth=0 under=391 over=0`、`writes=451 depth=0 under=395 over=0`、`writes=339 depth=18806 under=6 over=86` → 68–91 pkt/s，皆遠超 30 門檻 |
| 完整 live 套件的穩定性 | 模擬器穩定時 **10/10** 通過；**剛重開後曾 3 次死鎖 2 次**——已定位並修正，見下節 |
| `./scripts/verify_keymap_inject.sh` | PASS（引擎→多指注入活體） |
| `./scripts/verify_apk_install.sh` | PASS（dumpsys 前景解析未回歸；`adb install -r` → `Success`） |
| `./scripts/verify_snapshot.sh` + `SnapshotRoundTripLiveTests` | PASS |
| `./scripts/verify_reconnect.sh`（殺掉並重開模擬器） | **PASS**——`BOOTED (attempt 1, 4s)`，開機完成後 **1 秒**恢復出幀（門檻 10 秒） |

**覆蓋率數字會浮動**（比照 commit `7956c7c` 為同類問題加過的註記）：本次兩量得 95.72% 與 95.62%、P1-e 當時 95.92%、終審 fix wave 後 95.55%——四者皆 ≥ ~94% 基準。**判定看的是有沒有跌破基準，不是有沒有對上某個特定小數**。浮動來源包括活體測試每次實際走到的分支不同、以及新增/移除敘述行。

## 音訊 harness 兩極分佈：再添一筆極端資料點

本次 `verify_audio.sh` 量到 `writes=454 depth=0 under=391 over=0`——**第二次**落在「消費端跑贏、緩衝近乎全空」那一端（第一次是 P1-e 期間的 `writes=450 depth=68 under=426 over=0`）。加上先前 6 次落在「逼近容量、overruns 主導」那一端，累計 **9 次獨立執行**的範圍是：`writes` **341–454**、`depth` **0%–99.74%**（占容量）、`underruns` **3–426**、`overruns` **0–87**。

這進一步支持既有結論：決定 under/over 落在光譜哪一端的是 `Task.sleep` 驅動的**測試排空器**與 gRPC 送達之間的相對時序，不是任何產品邏輯缺陷。**仍未經計時佐證**（沒有人量排空迴圈的 wall-clock 漂移），這個歸因依舊是有機制支撐的推論而非證明。

## 本次 e2e 撞出的新發現：NIO teardown 架構債有了可重現的觸發條件

跑 `verify_reconnect.sh`（殺掉並重開模擬器）之後**立刻**跑完整 live 套件，測試行程**整個死鎖**——0% CPU、`sample` 顯示 stack 停在 `EmulatorClient.dropChannel` → `GrpcChannelBox`（deinit）→ `semaphore_wait_trap`，也就是阻塞的 `group.syncShutdownGracefully()`。

**Bisect 結果（實測，非推論）**：

| 情境 | 結果 |
|---|---|
| 模擬器穩定 + 帶新測試 | **10/10 通過**（5–8 秒） |
| 模擬器剛重開 + 帶新測試 | **3 次 2 次死鎖**（>100 秒無回應） |
| 模擬器剛重開 + 用 `BISECT_SKIP` 停掉新測試 | **3/3 通過** |
| 模擬器剛重開 + 新測試改用慢探測後 | **4/4 通過** |

**歸因**：新增的 `suspendBeforeFirstConnectStaysSilentUntilWake` 原本用 `ScriptedProbe([.failed])` 造出「尚未連上」的窗口——但探測失敗會走 `dropChannel()`，摧毀一條**真實的** `GrpcChannelBox` 並在 deinit 觸發阻塞式關閉。這條路徑本身是 P1-a/P1-b 的既有程式碼，也是既有已知的 [NIO teardown / 可注入 channel 架構債]；剛重開的模擬器讓它從「偶爾印一行 ERROR」升級成**硬死鎖**。

**修法**（commit `a5e5ebf`）：測試改用 `SlowFirstProbe`（第一次探測延遲 250ms 後回 `.healthy`），取得同樣的窗口而**完全不涉及 channel 拆除**。回歸守門能力不變——把 `channelBox != nil` 半條 guard 加回去仍決定性地紅。

**留給架構債的意義**：這是這筆債第一次有**可重現的觸發條件與硬性症狀**（先前只記錄為「重連時的 race，今非致命」）。抽可注入 channel 之後，應把「模擬器剛重開 + 強制 dropChannel」這個組合納入硬化驗證。

## GUI pending-human：診斷已收斂到「螢幕鎖定」

先前記載為「headless 不驅動 SwiftUI `.task`」，本次取得更精確的證據：

1. 直接從 shell 跑 `./.build/release/MirageApp` → 行程存活但 **0 行輸出**
2. `launchctl asuser 501` → 同樣 **0 行輸出**
3. 包成 `.app` bundle 用 `open` 走 LaunchServices → **成功 check-in**（`lsappinfo` 顯示 `type="Foreground"`、`launch to checkin time: 2.41s`），但仍 **0 行輸出**
4. `ioreg -n Root -d1 -a` → **`CGSSessionScreenIsLocked = true`**

即：`.app` bundle 這條路**確實**能讓 App 進入使用者的 Aqua session（前兩種方式連 check-in 都做不到），真正的阻礙是**螢幕鎖定時 WindowServer 不合成畫面**，`WindowGroup` 的 `.task` 因此不觸發。

**所以先前 7 項 pending-human 全數維持 pending-human，但阻礙是可解的**：螢幕解鎖後，用同樣的 `.app` bundle 手法即可一次驗完。新增第 8 項：進出全螢幕時游標捕捉的恢復行為（本次新修的 `didBecomeKey` 路徑）。

驗收線 7（fps ≥55）仍無數字，因此 **`StreamSize.maxPixels = 1.8 MP` 這個值尚未經 fps 校準**——它是照 spec 自己的論證基礎取的保守值，拿到真實 fps 後應回頭調整。

> **⚠️ 2026-07-29 更正：本節整節的結論是錯的。**
>
> 上面四個觀察（0 行輸出 ×3、`CGSSessionScreenIsLocked = true`）**本身都是真的**，錯的是
> 把最後一個當成前三個的原因。後續在**螢幕未鎖、真 GUI session、使用者自己的終端機**
> 的條件下重跑，仍然是 0 行輸出——所以螢幕鎖定不是那個阻礙。真因是 `AVAudioEngine`
> 的 NSException 打死 MainActor（見本檔開頭的全檔更正）。
>
> **這是一次教科書等級的相關當因果**：`CGSSessionScreenIsLocked = true` 剛好同時成立、
> 剛好能解釋所有症狀、而且剛好是個「不是我們的錯」的解釋——三個條件湊齊，就沒有人
> 再往下查。代價是三個階段的 GUI 驗收被合理地跳過。
>
> 兩點後續：
> 1. **那 8 項現在驗得了**，防護已在樹上（`Sources/MirageShell/Audio/AudioPlayer.swift:29`）。
> 2. **`StreamSize.maxPixels` 現在有數據了**（不是「仍無數字」）：
>    `2026-07-28-mirror-never-rendered-investigation.md` §11.2 量到 0.16 MP→32.3fps、
>    0.65 MP→30.4fps、2.59 MP→22.0fps。結論是**在 0.65 MP 以下縮像素預算幾乎買不到 fps**，
>    但上限對防住高端仍有價值。1.8 MP 這個值本身仍沒有對應量測點。
>    完整說明已寫進 `Sources/MirageCore/Viewport/StreamSize.swift` 的註解。

## 未做，與理由

- **`AppModel` 的通知 observer token 未保存/未 `removeObserver`**：`AppModel` 與行程同生命週期、且閉包皆為 `[weak self]`，沒有洩漏或懸掛後果。要補得在類別本體加 `nonisolated(unsafe)` 儲存屬性（extension 不能有儲存屬性）——**為了一個不存在的問題引入 unsafe 標註是負收益**，故維持現狀。
- **抽 App 層 library target**：這是跨 P1-c/P1-d/P1-e 三個階段反覆出現的同一筆架構債，也是 `AudioPlayer`／`MirrorContainerView`／`AppModel` 全部 extension 無單元測試的根因。但它是**架構重構**而非缺陷修正，會動到十餘個檔案的可見度與 target 邊界，應有自己的設計與審查循環，不適合夾帶在 fast-follow 裡。本次僅把 `StreamSize` 這段純算術先撈出來，作為方向示範。
