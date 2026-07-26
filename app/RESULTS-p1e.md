# P1-e 全螢幕遊戲模式與音訊 驗收結果

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
| 6 | 活體：連續 **60 秒** `underruns == 0` | **無法用現有 harness 判定**。Task 9 的活體測試用測試專用背景排空器（`Task.sleep` 節流模擬 `AudioPlayer` render callback，非真正 CoreAudio），視窗僅 **5 秒**、非 60 秒。累計獨立重跑 `under=3、3`（原 Task 10）、`under=4、4`（本次修法後追加驗證）、Task 9 先前 4 次 `4–6`——**共 8 次獨立執行，`underruns` 全部非零**（範圍 3–6），不能拿來宣稱驗收線 6 通過。真正的 60 秒連續判定需要真 `AudioPlayer`（AVAudioSourceNode render callback）+ 真 GUI session 下用 `MIRAGE_AUDIO_LOG=1` 觀察 | ⬜ pending-human |
| 7 | fps 不回歸（`MIRAGE_FPS_LOG` ≥ 55，全螢幕串流解析度上限下） | 本機顯示器目前 `Display Asleep: Yes`（`ioreg -n IODisplayWrangler` 確認），與 `RESULTS-p1a.md` 記載的同一類本機限制。本次仍實際嘗試：`MIRAGE_FPS_LOG=1 ./.build/release/MirageApp` 背景跑 8 秒後 kill，輸出檔案 **0 行**（無 fps 日誌、無任何輸出）——證實 headless/螢幕關閉下 SwiftUI `WindowGroup` 的 `.task` 未被驅動，`MIRAGE_FPS_LOG` 迴圈從未執行。**不可**拿 transport 層或活體測試的任何數字冒充 App 合成層 fps——本階段沒有任何 fps 數字可回報 | ⬜ pending-human |

## Task 9 Step 1 的發聲手段結論

實際採用手段：`input keyevent 24`（`KEYCODE_VOLUME_UP`）連按 15 次把 `STREAM_MUSIC` 頂到上限（`Max: 15` → `streamVolume:15`）＋ `am start -a android.intent.action.VIEW -d file:///product/media/audio/ringtones/Ring_Synth_04.ogg -t audio/ogg` 叫起內建 `com.android.music/.AudioPreview` 播放。

- brief 原假設的 `/system/media/audio/ringtones/` 在本機映像（`sdk_phone64_arm64`, canary 37.2.1）**不存在**；實際音檔在 `/product/media/audio/ringtones/Ring_Synth_04.ogg`（本任務再次以 `adb shell ls` 確認仍然存在，路徑穩定）。
- `adb shell media volume ...` 二進位在本機映像上不存在（`inaccessible or not found`），`input keyevent 24` 是驗證有效的替代手段。
- **可靠重現**：本任務原本獨立重跑 `verify_audio.sh` 兩次（writes 344、344），本輪修法驗證後再獨立量測兩次（`./scripts/verify_audio.sh` 本體一次得 `writes=345`；為覆蓋率合併實驗手動重現同一流程一次得 `writes=341`）——累計 4 次 + Task 9 的 4 次，共 8 次獨立執行，`writes` 341–345，與 Task 9 記錄一致，確認此發聲手段可重複觸發、非一次性僥倖。
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
- **overruns 的歸因是合理推論、非已證明**：累計 8 次獨立活體執行（Task 9 之前 4 次 + 原 Task 10 2 次 + 本次修法後追加 2 次）`overruns` 落在 83–87、`underruns` 落在 3–6，**從未量到 0**。判斷是 harness 侷限——測試專用背景排空器用 `Task.sleep` 節流（非真正 CoreAudio 硬體時脈驅動），加上 `AudioRingBuffer.write()` 整包丟棄的溢位語意，一旦飽和就持續飽和；產品路徑由 CoreAudio render callback 驅動，理論上沒有這個失效模式。**這個推論有機制支撐，但沒有人實際量測排空迴圈的 wall-clock 漂移來證明它**——維護者不應把它當作已證實的結論。
- **緩衝深度常態逼近容量上限（重要 caveat，明列於此，不只在原始碼註解）**：8 次獨立量測中的 4 次記錄了具體 `depth`：`17778`／`18752`（原 Task 10）、`19006`／`18232`（本次修法後追加，即容量 19_200 samples 的 **98.99%／94.96%**），全部落在 Task 9 記錄的 89.5–99.7% 區間內。深度長期貼近容量上限是消費端跟不上的訊號，由 `overruns` 顯現（見上）；未來任何人只看 `writes=344` 這類 headline 數字會漏掉這件事，故在此明確記錄。
- **`AudioStats.depthSamples` 可能為負**：由 `writeIndex`/`readIndex` 兩次獨立 atomic load 相減得出，兩次讀取之間可能被寫入，瞬時可能為負。`MIRAGE_AUDIO_LOG=1` 印出的 `depth=Nms`（`AppModel+Audio.swift` 的 `depthMs = s.depthSamples * 1000 / (48_000 * 2)`）偶爾會因此出現負值，屬觀測用途下可接受的既有設計，非本次改動引入。
- **`AudioPlayer.start()` 的 catch 分支未 `engine.detach(node)`**：`engine.start()` 失敗時只把 `self.node = nil`，先前 `attach(node)` 未撤銷。目前這個分支不可達（`engine.start()` 在正常開發機上不會失敗），但若未來重試 `start()` 邏輯會留下半掛載的 node。
- **`AudioRingBufferTests.concurrentProducerConsumerKeepsDataIntact` 的提早結束路徑無下限斷言**：`overruns > 0 → break` 提早結束時對 `collected.count` 沒有下限要求，理論上可以在幾乎沒驗到任何資料時仍然綠燈（連跑 15+ 次未觀察到此現象，屬理論風險而非已重現的問題）。
- **App 層架構債（既有，非本階段引入，但本階段持續往裡面加程式碼）**：`MirageApp` 是 `executableTarget`，唯一測試 target 只依賴 `MirageCore`，**無法 import `MirageApp`**。故 `AudioPlayer`、`MirrorContainerView`、`AppModel+FullScreen`、`AppModel+Audio`、`MenuBarController` 全螢幕/靜音項目——本階段新增的 App 層程式碼——皆無單元測試覆蓋，正確性靠讀碼＋型別系統＋活體佐證，與 P1-c/P1-d 交接時記載的 `KeymapController`/`AdbClient` 同一類缺口。若要讓這些程式碼可測，需把它們抽成可 import 的 library target（後續選項，本階段未做）。
- **完整 live 測試套件中 `AudioLiveTests` 的觸發時序不穩定——已修正**：本任務原本回報 `MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test`（全套，非 `--filter`）跑法下，`AudioLiveTests` 的 `writes` 斷言可能因為與其他活體測試併發、鈴聲已播畢而不穩定（曾量到 41、0）。使用者已裁決修法並完成（commit `8a1b694`）：新增 `MIRAGE_LIVE_AUDIO` 閘門（比照既有 `MIRAGE_LIVE_MMAP` 慣例），只有 `verify_audio.sh` 會設定它；`AudioLiveTests` 在通用 `MIRAGE_LIVE` 套件呼叫下改為 early return，不再參與斷言。本任務重新驗證：`MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test`（含／不含 `--enable-code-coverage`）皆穩定 **127/127 全綠**。**正確的音訊活體執行方式是跑 `./scripts/verify_audio.sh`**（會設定 `MIRAGE_LIVE_AUDIO=1` 並先觸發發聲），不是 `MIRAGE_LIVE=1 swift test --filter AudioLiveTests`（後者現在會因缺 `MIRAGE_LIVE_AUDIO=1` 而 early return，得到看似通過但實際什麼都沒驗的 `Test run with 1 test passed`）。
- **修法的副作用——本次新發現，非阻塞但需誠實記錄**：這道閘門解決了紅燈問題，但代價是「一般 live 套件」與「音訊活體」變成兩個必須分別觸發的入口。單獨執行文件既有的覆蓋率量測指令（`MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --enable-code-coverage`）**不再涵蓋 `GrpcAudioTransport`**（該檔 line coverage 從約 94.81–98.70% 掉到 **11.69%**），把 MirageCore TOTAL line coverage 拉到 **89.25%**——**低於 ~94% 基準**。若要拿到符合基準的完整數字（**95.92% line**），現在需要額外執行 `MIRAGE_LIVE=1 MIRAGE_LIVE_AUDIO=1 swift test --filter AudioLiveTests --enable-code-coverage`（觸發發聲後），並用 `xcrun llvm-profdata merge -sparse` 把兩次的 `.profraw` 合併，再對合併後的 `.profdata` 跑 `llvm-cov report`。**這是本階段量測方法論的一項新增步驟，未來任何人只跑單一指令量覆蓋率，會得到一個看起來低於基準、但其實只是漏了音訊活體貢獻的數字**——值得在此明確記錄，避免未來被誤判為真的覆蓋率回歸。

## 判定

- **P1-e GO（可量測部分）**：驗收線 1–5 全數 **PASS**，附真實輸出（測試 127/127（一般套件與 live 套件皆全綠，`MIRAGE_LIVE_AUDIO` 閘門修法後確認）、`ViewportFit`/`AudioRingBuffer` 逐行 100%、MirageCore 合併覆蓋率 95.92%（高於 ~94% 基準，方法論見上）、release 零警告、活體封包率 68.8 pkt/s／48k/stereo/S16 格式確認）。
- **驗收線 6、7 誠實列 pending-human**：現有 harness（測試專用背景排空器、headless App）無法判定，需真 `AudioPlayer` + 真 GUI session；本次已附上實際嘗試的證據（fps 日誌 0 行輸出、underruns 累計 8 次獨立執行皆非零）而非僅憑印象標註。
- **spec §9 五項 pending-human** 全數列出，皆需真 GUI session。
- **overruns 歸因與緩衝深度逼近上限**已在「已知限制」明確記錄為 caveat，未包裝成已證實的結論。
- **App 層測試覆蓋缺口**（既有架構債）、**計畫原始活體測試碼缺消費者排空的發現**（本次補齊收錄）、**`AudioLiveTests` 併發時序問題已修正**（commit `8a1b694`）、以及**修法引入的覆蓋率量測新步驟（需合併兩條指令的 `.profraw`）**皆已記錄，供 Phase-1 後續 fast-follow 或架構調整參考。
