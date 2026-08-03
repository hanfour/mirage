# D32 Task 6：故障注入——證明驗收線 6 的斷言會紅

> 不證明會紅的斷言，跟沒有斷言沒有差別。這是 D42 立下的規矩，本檔是它的實測證據。

- **日期**：2026-08-03（原始故障注入會期）／2026-08-03 二次會期（審查修正：離線
  fixture 補證、`-d` 型別守門、文件用語訂正）
- **腳本**：`app/scripts/verify_audio_gui.sh`（`set -uo pipefail`，斷言失敗 `exit 1`，
  參數不合法 `exit 2`）
- **模擬器**：`emulator-5556`（gRPC `8556`），Pixel Flow（`com.loomgames.pixelflow`）
- **本次額外發現並修正的環境問題**（與斷言本身無關，但擋住了本次驗證，值得記錄供下次
  session 參考）：見文末「附錄：本次踩到的環境地雷」。

**涵蓋範圍的誠實表述（2026-08-03 審查後訂正，取代原本「六條斷言真的會紅」的標題宣稱）**：
`assert_*` 失敗會立即 `exit 1`，所以每次跑腳本只有排在最前面被評估到的那條斷言會真正
被「執行到」。本次故障注入實際端到端跑出來、被腳本評估到的只有 **A1／A2**（多次以不同
方向命中：A1 紅／綠、A2 紅）。**A3／A5** 從未被腳本實際評估到（每次都被排在它們之前的
A2 攔下），但本次新增的離線 fixture（`app/scripts/lib/audio_stats_selftest.sh` 案例
G／H，見 §3.1）**用真實發生過的完整 60 秒日誌**證明了「若評估到，會紅」：斷言邏輯本身
沒有僥倖過關的空間，只是這次的環境條件（遊戲畫面停在不發聲的收集畫面）沒讓 A2 先過關。
**A4** 完全未驗——沒有離線 fixture 涵蓋 `gui_session.sh` 的 fps 解析，本次唯一相關數據
（附錄 C 的 `FPS_AVG` 14–24）也低於門檻，但因 A2 先攔下同樣沒被腳本實際評估到。**A6**
的斷言邏輯（`assert_at_most` 對畸形行計數）已由既有的案例 C／D（`MALFORMED:1`）與
`verify_common_selftest.sh` 的突變測試涵蓋，非本次新增。

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

### A1–A6 實測值對門檻（Task 5 加完斷言後的確認跑，`app/RESULTS-d32-probe.md` §「加上斷言
後的驗證」逐字引用）

| # | 描述 | 判準 | 門檻（`DURATION=60`） | 實測值 |
|---|---|---|---|---|
| A1 | 音訊日誌行數（App 存活） | `assert_at_least` | ≥ 48 | 61 |
| A2 | 有封包的秒數 | `assert_at_least` | ≥ 48 | 61 |
| A3 | 連續有聲期間 underrun 增量總和 | `assert_at_most` | ≤ 350 | 147 |
| A4 | fps 取樣筆數 | `assert_at_least` | ≥ 1 | 63 |
| A4 | 平均 fps | `assert_at_least` | ≥ 27 | 32 |
| A5 | 重新蓄水次數 | `assert_at_most` | ≤ 72 | 35 |
| A6 | 畸形日誌行 | `assert_at_most` | ≤ 0 | 0 |

門檻推導（五次實測值的比例換算）見 `app/RESULTS-d32-probe.md` §「六個門檻的計算過程」，
不在此重複。

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

四條注入 + 兩條參數邊界檢查（共六列，逐條記錄實際輸出，非預期輸出，是本次實際跑出來的
數字）；另有 2026-08-03 二次會期（審查修正）新增的第三條參數邊界檢查（`-d` 非整數輸入）：

| # | 注入內容 | 預期 | 實際輸出 | Exit |
|---|---|---|---|---|
| 1b | `-g ""`（空 package） | `❌ -g 不接受空字串`，`exit 2` | 一致：`❌ -g 不接受空字串：本腳本必須有發聲來源。` | **2** |
| `-d` 下限 | `-d 5` | `❌ -d 不接受低於 10 秒`，`exit 2` | 一致：`❌ -d 不接受低於 10 秒：低於此值 A3/A5 的門檻算術會被整數除法截到 0 或 1，斷言形同虛設。`（訊息文字於二次會期同步更新，見 Minor-7：原本的推導與 `DURATION=10` 自相矛盾） | **2** |
| `-d` 型別（二次會期新增，Important-4） | `-d abc`（非整數） | `❌ -d 只接受正整數秒數`，`exit 2` | 一致：`❌ -d 只接受正整數秒數：實測 'abc'。`（另驗證 `-d -3`、`-d ""` 同樣 `exit 2`；`-d 30` 等合法整數不受影響，正常進入前景檢查） | **2** |
| 1 | `-d 30 -g com.android.settings`（前景是不發聲的 App） | A1 綠、A2 紅、`exit 1` | `✅ A1 音訊日誌行數（App 存活）：28（門檻 24）` / `❌ A2 有封包的秒數：實測 0，門檻 24` | **1** |
| 2 | `MIRAGE_AUDIO_LOG=0`（關掉音訊日誌） | A1 紅（`AUDIO_LINES=0`），`exit 1` | `❌ A1 音訊日誌行數（App 存活）：實測 0，門檻 48`。`FPS_SAMPLES=4`（App 確實活著、有畫面，只是日誌被關掉——排除「App 死了」的混淆） | **1** |
| 2b | `AudioRingBuffer.primeThresholdSamples` 9600→0（拿掉 pre-roll） | A3 紅（`USUM` 回到數千量級） | **見下方 3.1 的訂正說明**：本次量測窗口內遊戲畫面停留在一個不發聲的畫面（`pkt` 全程為 0，`SOUND_SECS=0`），A2 先於 A3 攔下，`❌ A3` 從未被評估到。原始輸出的 `under`/`primes` 兩個計數器逐行相等（都到 6093）——**這是「全程無資料」的指紋，不是「拿掉 pre-roll」的指紋**，不能當作 A3 會紅的證據；真正會被這份日誌命中的是 A5（`PRIMES=6093` 遠超上限 72），同樣因 A2 攔下而未被評估到。A3 真的會紅的證據改由離線 fixture 提供（§3.1） | 1（A2 攔下） |
| 3 | `AudioPlayer.swift` `interleaved: false`→`true`（重現打死 MainActor 的 NSException） | A1 紅（`AUDIO_LINES=0`），fps 取樣 0，`exit 1` | 完全一致：`❌ A1 音訊日誌行數（App 存活）：實測 0，門檻 48`，`FPS_SAMPLES=0`。**第一次嘗試即命中**，且日誌顯示幀有進來但從未 present（`EmulatorClient`/`FramePump` 是 actor，不經過被打死的 MainActor，這正是歷史根因分析記載的四個症狀之一） | **1** |

### 3.1 注入 2b 為什麼沒有直接看到 `❌ A3`，以及原始版本的推論錯在哪

`assert_at_least`/`assert_at_most`（`verify_common.sh`）失敗時立即 `exit 1`，所以 A2 一旦
先紅，A3 永遠不會被印出來——這是腳本自己的既有設計（`verify_audio_gui.sh` 的註解明講
「A3 必須排在 A2 之後：`assert_at_most` 對 0 是通過的，A2 先確認『有東西可量』，這條才有
意義」）。本次量測的 `SOUND_SECS` 連續三次量測皆為 0（本 session 的 Pixel Flow 停留在一個
不產生背景音樂、只有點擊音效才出聲的畫面，`dumpsys audio` 的 `mMusicActiveMs` 全程為 0），
A2 因此依設計先行攔下，A3 沒有機會被評估。

**⚠️ 2026-08-03 審查訂正**：本節原本引用下方這份 `pkt=0` 的日誌，宣稱「機制驗證成立」，
推論方向是錯的。逐一拆解：

**（a）`pkt=0` 的行對 `USUM` 貢獻是零。** `audio_stats`（`app/scripts/lib/audio_stats.sh`）
的 `usum` 只在「本秒 `pkt>0` 且前一秒也 `pkt>0`」時累加。這次量測全程 `pkt=0`，解析出來是
`SOUND_SECS=0`、`UWINDOWS=0`、**`USUM=0`**。而 `assert_at_most` 對 0 是**通過**的——
把這份日誌餵進 A3，印出來的會是**綠燈**，不是紅燈。

**（b）`under == primes` 逐行相等（100/100、596/596、6093/6093）是「沒有資料」的指紋，
不是「拿掉 pre-roll」的指紋。** 讀 `AudioRingBuffer.readStereo` 的推導：門檻 0 且緩衝
全空時，每次 render callback 會 `guard (w-r) >= 0` 通過 → `primed=true`、`primeCount+=1`；
接著 `n=0` → `guard n > 0` 失敗 → `primed=false`、`underrunCount+=1`。**每次 callback 兩個
計數器各加一**，所以恆等。若真有資料流入（如 §6 的 Task 3 真實日誌），`primed` 翻 true
後會維持住，`primes` 幾乎不動而 `under` 持續爬，兩者大幅發散——那才是 pre-roll 前的形狀
（見下方案例 G 的對照）。

**（c）真正會被這份日誌命中的其實是 A5，原本的文件完全沒提。** `audio_stats` 對
`primes=` 不做 `pkt>0` 過濾，取最後一行累積值 → `PRIMES=6093`，而 A5 上限是 72——超標
85 倍。只是 A2 先攔下、A5 又排在 A3 之後，同樣沒被腳本評估到。

**修正後的證明鏈**（不需要模擬器，離線可重現，永遠活在 `ci.sh` 閘門 7 裡）：

1. `verify_common_selftest.sh` 已證明 `assert_at_most` 超標會 `exit 1`（含突變檢查）。
2. `audio_stats_selftest.sh`（2026-08-03 二次會期新增案例 G／H）用**真實發生過的完整
   60 秒日誌**（非手造）證明：
   - 案例 G（`fixtures/audio_preroll_before_real.log`，即 Task 3 pre-roll 前三次真實
     量測之一，逐字存檔）：`USUM=5481` 遠超 A3 門檻 350——**這是 A3 真的會紅的證據**。
   - 案例 H（`fixtures/audio_injection_2b_silent_screen.log`，即本次注入 2b 那份
     `pkt=0` 日誌，逐字存檔）：`USUM=0`（若誤當 A3 證據會是綠燈）但 `PRIMES=6093`
     遠超 A5 門檻 72——**把「為什麼這份日誌不能當 A3 的證據、但可以當 A5 的證據」
     永久釘在測試裡**，不再只活在這段文字說明中。
3. 兩者組合：A3 對真實的 pre-roll-前資料會紅（案例 G），A5 對這次注入 2b 的資料會紅
   （案例 H）。

⚠️ **這證明的是「斷言邏輯會紅」，不是「端到端注入會紅」**：本次故障注入本身，因為
Pixel Flow 該時刻停在無背景音樂的畫面，A2 先攔下，A3／A5 從未被 `verify_audio_gui.sh`
實際執行到——如實標為未驗證，不宣稱已端到端驗證。

代表性原始輸出（60 秒量測，pre-roll 關閉，摘自 `fixtures/audio_injection_2b_silent_screen.log`
首尾各兩行）：

```
[audio] pkt=0 sr=48000 ch=2 under=100 over=0 primes=100 depth=0ms
[audio] pkt=0 sr=48000 ch=2 under=198 over=0 primes=198 depth=0ms
...
[audio] pkt=0 sr=48000 ch=2 under=5996 over=0 primes=5996 depth=0ms
[audio] pkt=0 sr=48000 ch=2 under=6093 over=0 primes=6093 depth=0ms
```

（`pkt=0` 是本 session 的環境問題，不是 pre-roll 注入的產物——見附錄 C。六次獨立量測
`under`/`primes` 終值分別落在 5851、6047、6056、6093、6131、6137，同一量級，可重現；
完整 63 行日誌逐字存於 `app/scripts/lib/fixtures/audio_injection_2b_silent_screen.log`。）

### 3.2 注入 3 的完整輸出（本設計的靈魂）

**2026-08-03 審查訂正**：以下為 `/tmp/d32-step3.log` 逐字引用（原本這裡的版本刪掉了
粗體、冒號與後三行說明，以「完整輸出」為名卻不是逐字——已改回原樣）：

```
===== 音訊每秒日誌（全部）=====

===== 畫面 =====
取樣數 0——Mirage 沒有 present 任何一幀。

但幀有進來（log 裡有 15 行「幀 #N」）。**所以問題不在串流，在視窗**：
視窗沒有被合成上螢幕，MTKView 的 currentDrawable 為 nil，Renderer 早退。
檢查：Mirage 視窗有沒有真的出現在螢幕上、有沒有被其他視窗完全遮住、
螢幕是否鎖定。這條路徑實測是不穩定的，重跑一次往往就好。
log：/var/folders/fs/cw9m80hj6n59wx62tb60tcn00000gn/T/mirage_audio_gui.ZZ5Xc6bUSh

===== 解析結果 =====
AUDIO_LINES=0
SOUND_SECS=0
USUM=0
UMAX=0
UWINDOWS=0
MALFORMED=0
PRIMES=0
FPS_SAMPLES=0
FPS_AVG=0

===== 判定 =====
❌ A1 音訊日誌行數（App 存活）：實測 0，門檻 48
```

（`EXIT=1` 由外層 `echo "EXIT=$RC"` 印出，不在腳本本身的輸出裡，故不列入上面的逐字引用；
實測退出碼確為 1。）

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
守著螢幕，每一步的判定都由腳本的 `exit` code 決定，沒有一步靠人工判讀 log。**但這不等於
六條斷言本次都被實際評估到**——`assert_*` 失敗即中止的設計，讓每次跑只有排最前面的
斷言真正被評估（見文首「涵蓋範圍的誠實表述」與 §3 表）；A3／A5 這次是靠離線 fixture
補上「斷言邏輯會紅」的證明，不是靠這支腳本本身端到端跑出來的。

---

## 5. 已知限制

- **本腳本需要真 GUI session 與模擬器**，不能進 `ci.sh`：它啟動一個真的 `.app` bundle、
  拉到前景、等真實視窗合成、量測真實 `AVAudioSourceNode` 60 秒（或 `-d` 指定的秒數，
  最低 10 秒）。這些前置條件（`emulator-5556` 存活、gRPC `8556` 可連、Pixel Flow 已安裝）
  在無人值守的 CI 環境不成立，也不該假裝成立。
- `verify_common_selftest.sh`（`verify_common.sh` 共用斷言函式的自我測試）與
  `audio_stats_selftest.sh`（`audio_stats.sh` 解析邏輯的自我測試，2026-08-03 二次會期
  新增案例 G／H，用真實日誌證明 A3／A5 對的資料形狀會紅）皆不需模擬器，已由 `ci.sh`
  閘門 7 涵蓋，與本腳本是互補而非重疊：閘門 7 驗「斷言／解析邏輯本身正確」，本腳本驗
  「斷言套用在真實系統上會不會如預期發紅」——本次故障注入會期只端到端驗到了 A1／A2，
  A3／A5 這半靠閘門 7 補齊，見 §3.1。
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
`app/RESULTS-d32-probe.md`）。以下三行摘自**第 1 次量測**的第 1、2、60 秒（`[audio]`
逐秒輸出的頭兩行與最後一行，2026-08-03 審查訂正：原文誤標為「三次獨立量測」，實際是
同一次量測的三個時間點；三次量測完整數字見 `app/RESULTS-d32-probe.md` 表格，皆同量級）：

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

### 6.1 Task 4 審查 Important-1 的裁決：「低水位帶讓 pre-roll 形同虛設」假說已被數據推翻

Task 4 審查時留下一個當時裁決「留給實測裁決」的 Important：`AudioRingBuffer` 的重置
條件是 `n == 0`（緩衝被排到完全空）而非低水位滯後（跌破門檻某個分數就提早重置）。
假說是：在 `2 <= (w-r) < 2*frames` 這個帶裡，`readStereo` 會持續**部分讀**——每次都
不足一個 frame、都計一次 underrun、`depth` 被掏回接近 0——但因為 `n` 從未真正等於 0，
`primed` 不會翻回 `false`，緩衝停在這個帶裡打轉，pre-roll 形同虛設。這個假說當時只能
靠讀碼證明路徑存在，定不了它在實測中佔多大比例，故留到 Task 5 拿到真實數字後回頭裁決
（見 `.superpowers/sdd/2026-08-03-d32-acceptance-6-automation/progress.md` Task 4 條目）。

**Task 5 的實測數字已經回答了它。** 用五次量測的中位數 `USUM`≈150、`PRIMES`≈35 反推：

- 平均每個「重新蓄水週期」對應的 underrun 增量 ≈ `150 / 35` ≈ **4.3 次**。
- 其中恰好 **1 次**是 `n == 0` 觸發的真正重置（`PRIMES` 定義就是這個事件的計數）。
- 其餘約 **3 次**是部分讀——真的發生了，但每個週期只發生 3 次，不是「持續」發生。
- 一次 render callback 對應約 10ms，3 次部分讀 ≈ **30ms**；一個週期（60 秒 / 35 ≈
  1.7 秒＝1700ms）裡，低水位帶只被穿過約 30ms，占週期時間約 **1.8%**（約 2%）。

換句話說：緩衝**確實**會短暫進入低水位帶，但只是排乾前的過渡瞬間，不是卡在裡面打轉。
**「持續部分讀讓 pre-roll 形同虛設」這個假說被數據推翻**：如果緩衝真的卡在低水位帶
反覆部分讀而不觸發重置，指紋會是 `PRIMES` 很小（很少真正排乾到 0）而 `USUM` 仍停留在
千位數量級（部分讀持續計 underrun）——那正是 `audio_stats_selftest.sh` 案例 G
（pre-roll 前的真實日誌：`USUM=5481`、`PRIMES=0`，因為當時 pre-roll 尚不存在）的形狀，
不是 Task 5 實測到的「`PRIMES`≈35、`USUM`≈150」這個形狀。實測呈現的是**乾淨的排乾—
重新蓄水循環**，不是卡在低水位帶。

這個結論先前只存在於審查意見裡，`progress.md` 仍把它記為「仍開著，留給實測裁決」——
本節把裁決寫下來，避免下一輪把它當成未解決的開放問題。

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

**Step 4（還原後確認回到綠）在本 session 因同一原因未能拿到全綠**：四次嘗試
（`/tmp/d32-step4.log`、`d32-step4-retry.log`、`d32-step4-retry2.log`、
`d32-step4-retry3.log`，皆已用 `primes=0` 起始值確認是還原後、非注入狀態下的量測）
皆 `A1 ✅`（App 存活，`AUDIO_LINES` 60–63）、`A2 ❌`（`SOUND_SECS=0`）。

**⚠️ 2026-08-03 審查訂正**：原本這裡寫「fps 正常，14.9–18.9 平均」是錯的。A4 的 fps
門檻是 **27**（`verify_audio_gui.sh`，且不隨 `DURATION` 縮放），而四次的 `FPS_AVG`
實測分別是 **0、5、14、24**（`fps_average`／`gui_session.sh` 回傳整數，無條件捨去）
——**全數低於門檻 27**，也全數低於 Task 5 的基準 34–46（`app/RESULTS-d32-probe.md`）。
就算 A2 這次過關，**A4 一樣會紅**。fps 掉到基準的零到七成，跟聲音／pre-roll 無關，
原因未查明，疑與本機 CPU 競爭有關——本 session 同時有其他 Claude session 在跑
（`ps aux` 可見另外兩個 `claude` 行程），qemu CPU 一度衝到 260%（見附錄 B）。

程式碼已確認乾淨還原（`grep` 核對 `primeThresholdSamples: Int = 9_600` 與
`interleaved: false`、`git status --short` 除既有的 `-d` 檢查外無其他改動、無 `.bak`
殘留）。結論降級為：**A1 已確認回綠**（四次還原後的量測 `AUDIO_LINES` 皆遠高於門檻，
且注入 3 翻紅的正是 A1——見下方「注入 3 的控制組」）；**A2–A6 的回綠基準本 session 未
取得**，需要在遊戲處於會發聲的關卡內畫面時重跑才能確認，不宣稱「不是程式碼退步」這種
需要全綠才站得住的結論。

**注入 3 的控制組其實是成立的**（原報告未明講，這裡補上）：注入 3 讓 A1 翻紅的機制是
`interleaved: true` 讓 `AVAudioEngine.connect` 丟 NSException 打死 MainActor，那個每秒
印 `[audio]` 的 Task 跑在 MainActor 上，所以 `AUDIO_LINES=0`。還原（`interleaved: false`）
之後，上面四次獨立的 Step 4 量測 `AUDIO_LINES` 全部回到 60–63（門檻 48 之上），**A1 正是
注入 3 翻紅的那一條，也正是還原後穩定回綠的那一條**——這是比「兩次都沒拿到全綠」更有力
的證據：它直接證明注入 3 的紅燈來自注入本身，不是腳本壞了或環境問題，因為同一批還原後
的量測裡，A1（受注入 3 直接影響的斷言）每次都乾淨回綠，只有 A2（受遊戲畫面狀態影響、
與注入 3 無關的斷言）持續紅。
