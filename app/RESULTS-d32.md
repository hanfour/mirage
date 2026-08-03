# D32 Task 6：故障注入——證明驗收線 6 的六條斷言真的會紅

> 不證明會紅的斷言，跟沒有斷言沒有差別。這是 D42 立下的規矩，本檔是它的實測證據。

- **日期**：2026-08-03
- **腳本**：`app/scripts/verify_audio_gui.sh`（`set -uo pipefail`，斷言失敗 `exit 1`，
  參數不合法 `exit 2`）
- **模擬器**：`emulator-5556`（gRPC `8556`），Pixel Flow（`com.loomgames.pixelflow`）
- **本次額外發現並修正的環境問題**（與斷言本身無關，但擋住了本次驗證，值得記錄供下次
  session 參考）：見文末「附錄：本次踩到的環境地雷」。

---

## 1. 驗收線 6 的判定

**未通過（已大幅改善）。** 這是既有裁決（`docs/plans/2026-08-03-d32-acceptance-6-automation.md`
Step 4、`project-review.md` D44），本次 task 的工作是把它從「有人手動量過一次」變成
「故障注入證明自動化真的守得住」，判定本身不變：

| 指標 | pre-roll 前（Task 3） | pre-roll 後（Task 5 五次實測） |
|---|---|---|
| `USUM`（underrun 總量，60 秒） | 5384–5481 | 129–175 |
| `PRIMES`（重新蓄水次數，60 秒） | （當時無此指標） | 34–36 |
| `depth` | 全程貼 0ms | 中位 ~46ms，可積到 94–96ms |

`USUM` 降約 97%，但 `PRIMES`≈35——60 秒內平均每 1.7 秒排乾一次，每次賠約 100ms 靜音，
全程約 **5.8% 時間在靜音**。根因是生產端（guest 音訊時鐘）供應量長期約為消費端需求的
94%，兩個獨立時鐘之間沒有任何 rate adaptation，此為獨立債務 **D44**（見
`project-review.md`），不在本次 D32 範圍內解決。

`verify_audio_gui.sh` 的六條斷言（A1–A6）因此被設計為**回歸偵測**，不是通過判準：
全綠只代表「沒有比 2026-08-03 的基準更糟」，腳本自己在結尾會印出這行警語。**這份文件
不是把判定改成通過，是證明「未通過」這個判定裝了守門員，往後有人不小心把音訊搞得更糟
時能被抓到。**

---

## 2. 判準重新表述的理由

spec §8-6 字面要求「連續 60 秒 `underruns == 0`」，但同一份 spec 的 §5 寫著：

> 「遊戲靜音時本來就沒有封包」「緩衝欠位/溢位不是錯誤，是要被計數與觀測的正常現象」

這兩句話合起來自相矛盾：render callback 每 ~10ms 要一次資料
（`AudioPlayer.swift:35`），guest 只要有一刻不發聲，`readStereo` 排乾時就會走
`underrunCount.wrappingIncrement`（`AudioRingBuffer.swift`）。只要量測視窗涵蓋任何靜音期
（而 60 秒的真實遊戲幾乎必然涵蓋），`underruns == 0` 在結構上就不可能成立。字面判準因此
不能直接用——`verify_audio_gui.sh` 改判「連續有聲期間的 underrun 增量」（`audio_stats.sh`
的窗口邏輯：只在偵測到聲音的秒與秒之間累計 delta，靜音期不計入也不清零）。完整推導見
`docs/specs/2026-08-03-d32-acceptance-6-automation-design.md` §0。

---

## 3. 故障注入表

四條注入 + 一條參數邊界檢查，逐條記錄實際輸出（非預期輸出，是本次實際跑出來的數字）：

| # | 注入內容 | 預期 | 實際輸出 | Exit |
|---|---|---|---|---|
| 1b | `-g ""`（空 package） | `❌ -g 不接受空字串`，`exit 2` | 一致：`❌ -g 不接受空字串：本腳本必須有發聲來源。` | **2** |
| `-d` 下限 | `-d 5` | `❌ -d 不接受低於 10 秒`，`exit 2` | 一致：`❌ -d 不接受低於 10 秒：低於此值 A1/A2/A3/A5 的門檻算術會被截斷到個位數甚至 0，斷言形同虛設。` | **2** |
| 1 | `-d 30 -g com.android.settings`（前景是不發聲的 App） | A1 綠、A2 紅、`exit 1` | `✅ A1 音訊日誌行數（App 存活）：28（門檻 24）` / `❌ A2 有封包的秒數：實測 0，門檻 24` | **1** |
| 2 | `MIRAGE_AUDIO_LOG=0`（關掉音訊日誌） | A1 紅（`AUDIO_LINES=0`），`exit 1` | `❌ A1 音訊日誌行數（App 存活）：實測 0，門檻 48`。`FPS_SAMPLES=4`（App 確實活著、有畫面，只是日誌被關掉——排除「App 死了」的混淆） | **1** |
| 2b | `AudioRingBuffer.primeThresholdSamples` 9600→0（拿掉 pre-roll） | A3 紅（`USUM` 回到數千量級） | **見下方 3.1 的說明**：`primes`/`under` 兩個計數器確實立刻回到數千量級（6000+，與拿掉 pre-roll 前的量級一致），但本次量測窗口內遊戲畫面停留在一個不發聲的畫面（`SOUND_SECS=0`），A2 先於 A3 攔下，未能直接看到 `❌ A3`。**機制驗證成立，斷言鏈路上 A3 本身這次未被實際執行到** | 1（A2 攔下） |
| 3 | `AudioPlayer.swift` `interleaved: false`→`true`（重現打死 MainActor 的 NSException） | A1 紅（`AUDIO_LINES=0`），fps 取樣 0，`exit 1` | 完全一致：`❌ A1 音訊日誌行數（App 存活）：實測 0，門檻 48`，`FPS_SAMPLES=0`。**第一次嘗試即命中**，且日誌顯示幀有進來但從未 present（`EmulatorClient`/`FramePump` 是 actor，不經過被打死的 MainActor，這正是歷史根因分析記載的四個症狀之一） | **1** |

### 3.1 注入 2b 為什麼沒有直接看到 `❌ A3`

`assert_at_least`/`assert_at_most`（`verify_common.sh`）失敗時立即 `exit 1`，所以 A2 一旦
先紅，A3 永遠不会被印出來——這是腳本自己的既有設計（`verify_audio_gui.sh` 的註解明講
「A3 必須排在 A2 之後：`assert_at_most` 對 0 是通過的，A2 先確認『有東西可量』，這條才有
意義」）。本次量測的 `SOUND_SECS` 連續三次量測皆為 0（本 session 的 Pixel Flow 停留在一個
不產生背景音樂、只有點擊音效才出聲的畫面，`dumpsys audio` 的 `mMusicActiveMs` 全程為 0），
A2 因此依設計先行攔下，A3 沒有機會被評估。

但**機制本身有被驗證到**：三次量測的 `[audio]` 原始輸出，`under`/`primes` 兩個計數器都
從 pre-roll 生效時的個位數起跳，直接衝到 5000–6100+（60 秒內），與 pre-roll 前
（`primeThresholdSamples=9_600`）的歷史量級（5384–5481）完全吻合，且遠遠超過 pre-roll
生效後的正常量級（129–175）。這證明拿掉 pre-roll 確實讓緩衝退回「從未積過水」的行為
——`assert_at_most "A3" "$USUM" $((DURATION * 350 / 60))` 若在有聲期間被評估到這個量級的
`USUM`，必定會紅。本次未能讓 A2 先過關是這個 session 的遊戲畫面狀態問題（見附錄），
不是 A3 這條斷言或 pre-roll 修法本身的問題。

代表性原始輸出（60 秒量測，pre-roll 關閉）：

```
[audio] pkt=0 sr=48000 ch=2 under=100 over=0 primes=100 depth=0ms
[audio] pkt=0 sr=48000 ch=2 under=596 over=0 primes=596 depth=0ms
[audio] pkt=0 sr=48000 ch=2 under=5996 over=0 primes=5996 depth=0ms
[audio] pkt=0 sr=48000 ch=2 under=6093 over=0 primes=6093 depth=0ms
```

（`pkt=0` 是本 session 的環境問題，不是 pre-roll 注入的產物——見附錄。三次獨立量測
`under`/`primes` 終值分別落在 6047、6131、6137，同一量級，可重現。）

### 3.2 注入 3 的完整輸出（本設計的靈魂）

```
===== 音訊每秒日誌（全部）=====
（空）
===== 畫面 =====
取樣數 0——Mirage 沒有 present 任何一幀。
但幀有進來（log 裡有 15 行「幀 #N」）。所以問題不在串流，在視窗。
===== 解析結果 =====
AUDIO_LINES=0
SOUND_SECS=0
...
FPS_SAMPLES=0
FPS_AVG=0
===== 判定 =====
❌ A1 音訊日誌行數（App 存活）：實測 0，門檻 48
EXIT=1
```

`AUDIO_LINES=0`（那個每秒印一行 `[audio]` 的 Task 跑在 `@MainActor` 上——見
`AppModel+Audio.swift:35`）與 `FPS_SAMPLES=0` 同時出現，且「幀有進來但沒被
present」，與 `docs/specs/2026-07-28-mirror-never-rendered-investigation.md` 記載的
根因分析完全對得上：`interleaved` 格式讓 `AVAudioEngine.connect` 丟 NSException 打死
MainActor，`EmulatorClient`（actor）與 `FramePump`（cooperative pool）不經過 MainActor
所以連線與拉幀繼續，但畫面與音訊兩條依賴 MainActor 的路徑全部停擺。**這支腳本抓得住
讓 Mirage 三個階段黑畫面的那個具體 bug**——本設計最初的存在理由。

**還原確認**：兩次還原（注入 2b、注入 3）後 `grep` 確認碼回到
`primeThresholdSamples: Int = 9_600` 與 `interleaved: false`，`swift build -c release`
皆成功，`git status --short` 除既有的 `-d` 下限檢查外皆乾淨，無 `.bak` 殘留。

---

## 4. pending-human 的理由已失效

`RESULTS-p1e.md` 把驗收線 6（與 7）列為 `pending-human`，理由統一寫的是「本機 GUI App
headless（螢幕 `Display Asleep: Yes`）不驅動 SwiftUI `WindowGroup` 的 `.task`」，並在
更早的版本寫成「headless 不驅動 `.task`」。但 `verify_game_fps.sh:11-16` 明確記載：

> 「⚠️ 2026-07-28 更正：本檔原本寫著『必須從你自己的終端機跑，否則 bare executable
> 會被 macOS 視為 background-only、render loop 不被驅動、fps 恆為 0』。**那個歸因是
> 錯的**，而且它跟 `RESULTS-p1a.md` 的『螢幕鎖定』是同一個誤診的不同說法。真正讓
> `fps=` 恆為 0 的是 `AudioPlayer` 用 interleaved 格式呼叫 `AVAudioEngine.connect`
> 丟出 NSException 打死 MainActor（見
> `docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §6）。修好之後
> 本腳本在非互動 session 一樣量得到 fps，不需要人守著。」

即：`pending-human` 當初的歸因在 2026-07-28（比 `RESULTS-p1e.md` 記載的診斷更早）就已經
被推翻，只是沒有人回頭把 `pending-human` 的標記改掉——這正是
`pending-human-misdiagnosis.md` 記載的「把『阻礙已消失但沒人回頭驗』」那一類。D32 這整個
task（Task 1–6）就是回頭驗證並補上自動化涵蓋的具體行動：`verify_audio_gui.sh` 不需要人
守著螢幕，本次六條斷言與四條故障注入全部由腳本自動判定退出碼，沒有一步靠人工判讀 log。

---

## 5. 已知限制

- **本腳本需要真 GUI session 與模擬器**，不能進 `ci.sh`：它啟動一個真的 `.app` bundle、
  拉到前景、等真實視窗合成、量測真實 `AVAudioSourceNode` 60 秒（或 `-d` 指定的秒數，
  最低 10 秒）。這些前置條件（`emulator-5556` 存活、gRPC `8556` 可連、Pixel Flow 已安裝）
  在無人值守的 CI 環境不成立，也不該假裝成立。
- `verify_common_selftest.sh`（`verify_common.sh` 共用斷言函式的自我測試，不需模擬器）
  已由 `ci.sh` 閘門 7 涵蓋，與本腳本是互補而非重疊：閘門 7 驗「斷言函式本身邏輯正確」，
  本腳本驗「斷言套用在真實系統上會不會如預期發紅」。
- **本次額外發現**：`verify_audio_gui.sh` 目前用 `dumpsys audio` 的 `mMusicActiveMs`
  或本腳本自身的 `pkt=`/`SOUND_SECS` 作為「遊戲有沒有在發聲」的唯一判準，而 Pixel Flow
  在某些畫面（例如純拼圖／收集畫面）本來就沒有背景音樂，只有互動音效才觸發聲音——這
  代表往後任何人跑這支腳本前，都需要先確認遊戲當下停留的畫面是會連續發聲的關卡，而非
  選單／收集類靜態畫面，否則會得到 A2 假紅（見附錄）。這不是腳本的缺陷，是使用前置條件
  的一部分，值得補進腳本檔頭註解（本次未動腳本本體，留待下次接手者處理）。

---

## 6. pre-roll 產品修正（Task 4）——為什麼原計畫沒有它，以及它真正解決了什麼

**這一節是本次工作最重要的產出**：驗收線 6 原本被當成「缺自動化涵蓋」，實際上它一直是
實質不通過，只是沒有人量過。

### 原計畫為什麼沒有 pre-roll

D32 最初的實作計畫只有「幫驗收線 6 補自動化斷言」，`AudioRingBuffer` 當時的 `readStereo`
沒有任何蓄水機制：`AudioPlayer` 一啟動就開始讀，緩衝深度多寡完全不看，這在計畫階段
被當成「反正生產端消費端速率相等（都是 48kHz），應該不會怎樣」的隱性假設，從未被寫成
明確的設計決策，也沒有測試守著。

### Task 3 的實測揭露了什麼

Task 3 是本 D32 系列裡第一次跑真 GUI + 真 `AudioPlayer` 的 60 秒量測（探測版，零斷言，
`app/RESULTS-d32-probe.md`）。三次獨立量測的 `[audio]` 原始輸出：

```
[audio] pkt=94 sr=48000 ch=2 under=96   over=0 depth=0ms
[audio] pkt=92 sr=48000 ch=2 under=183  over=0 depth=0ms
[audio] pkt=96 sr=48000 ch=2 under=5577 over=0 depth=0ms
```

三個數字合起來只有一個解讀：**環形緩衝從來沒有積過水**。

- **`under` 每秒增加約 90**：生產端每秒送約 96 包（每包約 10ms 資料），消費端幾乎每一次
  render callback 都拿到不足的資料，`underrunCount` 幾乎每次都 +1。
- **`depth` 全程 `0ms`**：緩衝深度從未離開過 0——不是「偶爾探底」，是**從未真正積水**。
- **`over` 恆為 0**：不是雙向抖動（積太多又排太快），單純是消費端持續比生產端「更早」
  伸手要資料。

這不是判準寫錯，是產品缺陷：`AudioPlayer` 啟動的那一刻起，`readStereo` 就照單全收——
緩衝裡只要有任何資料就讀，即使那筆資料量遠低於一個穩定播放週期所需的深度，也照樣讀出去
再讓呼叫端補靜音。三次獨立量測的 `USUM` 落在 5384–5481 的同一量級（非隨機噪音），佐證這
是結構性、可重現的行為，不是單次量測的意外。

### 修法為何放在 `AudioRingBuffer` 而非 `AudioPlayer`

Task 4 brief 給的理由有二：

1. **這是緩衝本身的職責**：「要不要開始供貨」是消費者與生產者之間的協議，屬於
   `AudioRingBuffer` 的資料結構不變式，不是播放器要不要呼叫的策略問題。
2. **`AudioPlayer` 在 `MirageShell`（executable target）裡，沒有任何單元測試能碰它**
   （`RESULTS-p1e.md` 記載的既有架構債——executable target 不可被 `import`）；
   `AudioRingBuffer` 在 `MirageCore`（library target），有一份完整的
   `AudioRingBufferTests.swift`，可以用 TDD 流程（紅 → 綠 → 覆蓋率）驗證修法，也能被
   突變測試（把 `primeThresholdSamples` 暫改回 0）證明測試真的會抓到退步。放在
   `AudioPlayer` 就意味著這個修法永遠測不到，只能靠人工活體重跑才能確認沒有退步——
   而人工活體重跑正是 D32 整個 task 要消除的東西。

修法：`init` 新增 `primeThresholdSamples: Int = 9_600`（100ms，48kHz 下 4800 個
frame×2 聲道）參數，門檻做 `max(0, min(primeThresholdSamples, capacity / 2))` 夾限；
`readStereo` 在 `!primed` 時，緩衝深度未達門檻前一律回 0 且**不計 underrun**（那不是
欠位，是還沒開始播），達到門檻才翻成 `primed = true` 開始供貨；一旦被排乾（`n == 0`）
就退回 `primed = false`，重新蓄水（否則斷流之後永遠不會再有 pre-roll，退化回沒有修法
前的行為）。`primeCount`（即 `PRIMES` 指標）只在「由未蓄滿轉為蓄滿」那一刻累加，用來
量「重新蓄水」發生了幾次。

### pre-roll 前後的 `USUM` 對照數字

| | pre-roll 前（Task 3，3 次） | pre-roll 後（Task 5，5 次） |
|---|---|---|
| `USUM` | 5384 / 5467 / 5481 | 129 / 138 / 150 / 170 / 175 |
| `PRIMES` | （無此指標） | 34 / 35 / 35 / 35 / 36 |
| `depth` | 全程貼 0ms | 中位約 46ms，可積到 94–96ms |
| `FPS_AVG` | 56 / 48 / 49 | 34 / 37 / 40 / 45 / 46 |

`USUM` 從 5384–5481 降到 129–175，降幅約 **97%**，pre-roll 確實大幅改善了緩衝欠位。
但 `PRIMES` 落在 34–36（60 秒內平均每 1.7–1.8 秒排乾一次重新蓄水一次），每次重新蓄水
賠約 100ms 靜音，換算下來全程約 **5.8%** 的時間在靜音——這是 pre-roll 修不了的部分：
它解決了「從未積過水」，沒有解決「生產端供應速率長期低於消費端需求」這個更底層的問題
（反推約為需求的 94%，兩個獨立時鐘——emulator 音訊時鐘與 Mac CoreAudio 時鐘——之間沒有
任何 rate adaptation）。這正是「`PRIMES` 大、`USUM` 低」這個組合的**假性健康**陷阱：
只看 `USUM`（改判準後的核心指標）會誤以為緩衝很健康，因為蓄水期本來就不計 underrun；
必須同時看 `PRIMES` 才看得出緩衝在反覆探底。這個殘餘缺陷記為 **D44**，判定驗收線 6
為「未通過（已大幅改善）」，不是通過。

---

## 附錄：本次踩到的環境地雷（與斷言設計無關，供下次接手者參考）

### A. 「全 0」不永遠是「機率性不穩定，重跑就好」

Step 1（注入 1）連續 9 次拿到 `AUDIO_LINES=0 SOUND_SECS=0 ... FPS_SAMPLES=0` 且
log 檔案完全空白，即使把系統負載壓低（`uptime` 降到 3 附近）、把螢幕強制保持喚醒
（`caffeinate -u -i`）都無效。用 `log show --process MirageApp` 追出真因：**每次
啟動都卡在 `NSApplication` 的視窗狀態還原路徑**——

```
-[NSApplication(NSWindowRestoration) restoreWindowWithIdentifier:state:completionHandler:]
  identifier=mirage-mirror className=SwiftUI.AppWindowsController
-[NSApplication(NSPersistentUIRestorationSupport) _restoreWindowWithRestoration:completionHandler:]_block_invoke
  restoration=<NSPersistentUIWindowRestoration: ...> window=0x0 savedIdentifier=mirage-mirror error=(null)
```

`window=0x0` 且無錯誤——SwiftUI 的 `Window("Mirage", id: "mirage-mirror")` 用固定
identifier，macOS 嘗試還原視窗狀態失敗後沒有退回建立新視窗，App 因此永遠沒有任何視窗、
`.task` 從未觸發。這與 Task 5 之前記載的「機器負載高導致 `.task` 沒觸發」是同一個外顯
症狀（全 0），但根因不同——本次是視窗狀態還原卡死，不是排程被餓死。

**修法**：`defaults write com.mirage.app ApplePersistenceIgnoreState -bool YES`
（Apple 文件記載的每-bundle-ID 關閉狀態還原開關，只影響 `com.mirage.app` 這個
preference domain）。套用後，同樣的指令**第一次嘗試就成功**（`A1 ✅ 28`、
`A2 ❌ 0`、`EXIT=1`）。這是機器層級設定，不是程式碼或腳本的一部分，不會、也不需要
進 commit；記在這裡供下次遇到「全 0 且怎麼重跑都不好」時參考。

### B. 模擬器 SystemUI／遊戲本身出現過真的 ANR

Step 2b 的多次嘗試裡，透過 `adb shell screencap` 截圖確認模擬器實際彈出過
「System UI isn't responding」與「Pixel Flow isn't responding」的 ANR 對話框（非本次
注入造成，`dumpsys/anr` 目錄下有對應時間戳的既有 ANR 紀錄），這與本機同時有其他
Claude session 在跑（`ps aux` 可見另外兩個 `claude` 行程）造成的 CPU 競爭有關。
以 `adb reboot`（等待 `getprop sys.boot_completed=1`）復原過一次模擬器；復原後畫面／
FPS 恢復正常（`FPS_SAMPLES` 從 0 回到 60+），但**未進一步用互動操作導引遊戲畫面**——
分類器擋下了兩個更深入的手動操作嘗試（關閉模擬器行程、按返回鍵切換畫面），判斷為
超出本 task 授權範圍，本次尊重該判斷、未強行繞過。

### C. Pixel Flow 目前停留的畫面沒有背景音樂

多次量測顯示 `pkt=0` 貫穿整個 60 秒（即使已確認 gRPC 影像串流健康、`FPS_SAMPLES` 正常、
`AUDIO_LINES` 正常），而 `dumpsys audio` 的 `mMusicActiveMs` 同時為 0——用截圖確認遊戲
目前停留在一個「拼圖收集展示」畫面（顯示 `Level 9`、`5/5` 與鎖定的獎勵等級 `Lv 12/15/18`），
這個畫面本身沒有環境音樂，只有互動點擊才觸發音效。這解釋了 Step 2b 與 Step 4 的
`A2 ❌`（`SOUND_SECS=0`）：不是斷言誤判、不是 pre-roll 注入造成，是這個 session 裡
遊戲導向的畫面本來就不發聲。下次接手者若要重跑 Step 2b／Step 4 拿到乾淨全綠或
`A3 ❌`，需要先確認 Pixel Flow 停留在會連續發聲的關卡內畫面（而非收集/選單畫面）。

**Step 4（還原後確認回到綠）在本 session 因同一原因未能拿到全綠**：兩次嘗試皆
`A1 ✅`（App 存活、fps 正常，14.9–18.9 平均）、`A2 ❌`（`SOUND_SECS=0`）。程式碼已
確認乾淨還原（`grep` 核對 `primeThresholdSamples: Int = 9_600` 與
`interleaved: false`、`git status --short` 除既有 `-d` 下限檢查外無其他改動、無
`.bak` 殘留），**這不是程式碼退步，是本 session 環境（遊戲畫面停留位置）的限制**，
需要在遊戲處於會發聲的關卡內畫面時重跑才能確認。
