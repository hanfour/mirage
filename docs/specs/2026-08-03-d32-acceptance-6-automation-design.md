# D32：驗收線 6 的自動化涵蓋 — 設計

- 日期：2026-08-03
- 對應債務：`docs/specs/2026-07-29-project-review.md` D32（P2）
- 對應驗收線：`docs/specs/2026-07-26-p1e-fullscreen-audio-design.md` §8 第 6 條

## 0. 這份文件解決什麼

P1-e 驗收線 6「活體：連續 60 秒 `underruns == 0`」目前**零自動化涵蓋**，在
`RESULTS-p1e.md` 被列為 pending-human。本文件把它變成一支會紅的腳本。

過程中確認了兩件推翻既有記載的事實，它們決定了整個方案的形狀：

**事實一：pending-human 的理由已經不成立。**
`RESULTS-p1e.md` 給的理由是「本機 GUI App headless 不驅動 SwiftUI `WindowGroup` 的
`.task`」。但 `verify_game_fps.sh:11-16` 記載這個歸因在 2026-07-28 被推翻——真因是
`AudioPlayer` 用 interleaved 格式呼叫 `AVAudioEngine.connect` 丟出 NSException 打死
MainActor（見 `2026-07-28-mirror-never-rendered-investigation.md`），修好之後
「本腳本在非互動 session 一樣量得到 fps，不需要人守著」。

也就是說，**擋住驗收線 6 的那道牆在 2026-07-28 就被拆了，只是沒有人回頭驗**。
`verify_game_fps.sh` 已經示範了完整手法（`package_app.sh` 打包 → `open -a` →
`osascript` 拉前景 → grep 每秒日誌），而 `MIRAGE_AUDIO_LOG` 的輸出格式
（`AppModel+Audio.swift:41`）刻意沿用 `MIRAGE_FPS_LOG` 的單行可 grep 風格，同一套
harness 直接能用。

**事實二：驗收線 6 的字面判準與 spec 自己的設計矛盾。**
§8-6 寫「連續 60 秒 `underruns == 0`」，但同一份 spec 的 §5 寫著：

> `streamAudio` 無封包 ≠ 斷線。遊戲靜音時本來就沒有封包
>
> 緩衝欠位/溢位不是錯誤，是要被計數與觀測的正常現象

`AudioPlayer` 的 `AVAudioSourceNode` render callback 每 ~10ms 就要一次資料
（`AudioPlayer.swift:35-51`），guest 只要有一刻不發聲，`readStereo` 就走
`underrunCount.wrappingIncrement`（`AudioRingBuffer.readStereo`——引用函式名而非行號，
因為 pre-roll 修法已把它往下推過一次，見下方「2026-08-03 追記」）。所以 `== 0` 在
任何含靜音期的 60 秒裡**結構上不可能**。

這與 D32 已記載的「drain 情境下不成立」是**不同的第二個原因**：前者是測試 harness
的假消費端造成的，後者在真 `AudioPlayer` 下一樣存在。只把 harness 換成真的，判準仍
然不會通過。判準本身必須重新表述。

D32 已經差點被做成假紅燈一次（D9 修訂時一度把 `under == 0` 做成硬性斷言，跑出來才
發現不成立）。本設計的每一個門檻都必須先實測再定。

## 1. 決策

| # | 決策 | 理由 |
|---|---|---|
| 1 | 走**真 GUI 自動化量測**，不走「承認無涵蓋」也不走「改 live 測試」 | 改 live 測試仍是 `Task.sleep` 假消費端，`RESULTS-p1e.md` 已記載它會在 `under=3` 與 `under=426` 兩端擺盪，量到的數字不可信；「承認無涵蓋」的前提（headless 阻礙）已被推翻 |
| 2 | 判準 = **音訊健康 + 畫面同時存活**，一次 60 秒同時量 | `MIRAGE_AUDIO_LOG` 的每秒迴圈跑在 MainActor 上（`AppModel+Audio.swift:35`），MainActor 被打死就是 0 行——這份日誌的存在本身就在守「音訊不拖垮鏡像」。多設一個 `MIRAGE_FPS_LOG=1` 是同一個行程、同一份 log，零額外成本 |
| 3 | 發聲來源用 **Pixel Flow 遊戲**（`com.loomgames.pixelflow`，`mirage-game` AVD） | 遊戲同時給聲音與畫面變化，不需要人造動畫注入器（`verify_game_fps.sh -n` 的理由）；而且這就是驗收線本意的情境：玩遊戲時音訊不拖垮鏡像。若探測發現它不持續發聲，退回鈴聲方案並記錄 |
| 4 | **探測先行**：先跑零斷言量測拿真實數字，再定門檻 | D32 本身就是「先定門檻再實測」踩出來的坑 |

## 2. 判準的量測邏輯

從 `MIRAGE_AUDIO_LOG=1` 每秒一行解析：

```
[audio] pkt=42 sr=48000 ch=2 under=0 over=0 depth=96ms
```

四條斷言（門檻值待 §5 探測後填入）：

| # | 斷言 | 量什麼 | 為什麼需要它 |
|---|---|---|---|
| A1 | `[audio]` 行數 ≥ 門檻 | App 活到最後 | 這行的 Task 跑在 MainActor 上。**MainActor 被打死就是 0 行**——P1-e 那個 NSException 的直接守門 |
| A2 | `pkt>0` 的秒數 ≥ 門檻 | 串流真的活著 | 排除「App 活著但音訊根本沒進來」的假綠燈 |
| A3 | 連續有聲期間 `under` 增量 ≤ 門檻 | 核心判準 | 見下 |
| A4 | `fps=` 樣本數 > 0 且平均 ≥ 門檻 | 畫面沒被拖垮 | 「音訊不拖垮鏡像」的直接證據 |

### 「連續有聲期間」的定義

`under` 是累積值。逐行相減得該秒增量 ΔU，**只統計「本秒 `pkt>0` 且前一秒也
`pkt>0`」的那些 ΔU**。

這一刀同時砍掉兩個結構上不可能的區間：

- **啟動期**：App 一啟動 `AudioPlayer` 就在 render，而連線還沒建立，前幾秒必然狂
  underrun。這正是 D32 在 drain 情境記載的「從 t=0 就開始讀」在真 `AudioPlayer` 下
  的等價物——換成真消費端並不會讓這個問題消失。
- **靜音期與它的過渡秒**：spec §5 明說靜音時沒有封包是正常的。靜音期本身 `pkt=0`
  被排除；緊接其後的第一個有聲秒，其 ΔU 包含靜音期末尾的欠位，靠「前一秒也有聲」
  這個條件一併排除。

用「前一秒也有聲」取代「固定丟掉前 N 秒的 warm-up」是刻意的：後者要選一個魔術數
字，前者自適應，消除特殊情況。

這樣量出來的 ΔU 才回答了驗收線 6 真正想問的：**串流穩定供應時，消費端有沒有欠位。**

### 為什麼 A3 的門檻不寫死成 0

即使排除了啟動期與靜音期，生產端（emulator 的音訊時鐘）與消費端（Mac 的 CoreAudio
時鐘）是兩個獨立時鐘，長時間會漂移，而系統裡沒有任何 rate adaptation 機制。60 秒內
漂移掉 200ms 的緩衝天花板只需要 0.33% 的時鐘偏差。門檻必須由 §5 的探測結果決定，
不能從理論推導。

## 3. 檔案結構

| 檔案 | 動作 |
|---|---|
| `app/scripts/verify_audio_gui.sh` | **新增**。驗 playback 層／驗收線 6 |
| `app/scripts/lib/gui_session.sh` | **新增**。抽出「打包 → `open -a` → `osascript` 拉前景 → cleanup」與 fps 解析 |
| `app/scripts/verify_game_fps.sh` | 改用 `gui_session.sh`；重跑一次確認同樣量得到 |
| `app/scripts/lib/verify_common.sh` | 加 `assert_at_most`（現有只有 `assert_at_least`） |
| `app/scripts/lib/verify_common_selftest.sh` | 補 `assert_at_most` 的測試，含突變檢查 |
| `app/scripts/ci.sh` | 加閘門 7 執行 selftest |

### 命名：為什麼是 `_gui` 而不是 `_60s`

既有 `verify_audio.sh` 驗的是 transport 層（封包率／驗收線 5，5 秒視窗，假消費端）。
新腳本驗的是 playback 層（消費端健康／驗收線 6）。兩者最關鍵的差別不是時長，是
**新腳本需要真 GUI session 與真 `AudioPlayer`**——那也是使用者在跑之前最需要知道的
前置條件。

### 為什麼要抽 `gui_session.sh`

不是潔癖。新腳本的 A4 就是 fps 斷言，不抽就要複製一份 awk 解析與「取樣數 0 時怎麼
分辨是視窗問題還是串流問題」的診斷邏輯。D9 的教訓寫得很明白：

> 重複的檢查會漂移，而漂移正是 `coverage.sh` 在 D29 被修好、這三支卻沒跟上的原因

`package_app.sh`（D25）已經為「怎麼組 .app」抽過一次，這次是「怎麼啟動 GUI session
並收 log」。

### 為什麼要加閘門 7

`ci.sh` 現有六道閘門**沒有一道跑 `verify_common_selftest.sh`**。那支自我測試不需要
模擬器，卻從沒被 CI 執行過——跟 D37（`tools/probe/tests` 的 13 個檔從未被跑過）是同
一個形狀。本次要往 `verify_common.sh` 加 `assert_at_most`，新斷言若沒人跑就是不受保
護的。成本 3 行。

## 4. 腳本行為

```
verify_audio_gui.sh [-s serial] [-p grpc_port] [-g package] [-d seconds]
```

預設值比照 `verify_game_fps.sh`（`emulator-5558` / `8558` /
`com.loomgames.pixelflow`），`-d` 預設 60。gRPC port 由 emulator 啟動時的 `-grpc`
參數決定，不從 serial 推導，所以一律用 `-p` 明確指定。

流程：

1. 前置：`require_adb`、`require_device`、`require_grpc`（皆已存在於 `verify_common.sh`）
2. 啟動遊戲：`monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1`，確認它進入
   前景。**前景確認失敗一律中止**（`exit 1`），不像 `verify_game_fps.sh` 只發警告——
   那支腳本沒有遊戲仍能量到 launcher 的 fps，這支沒有發聲源則後面每一條斷言都失去
   意義，繼續跑只會產生一個看起來像產品缺陷、其實是環境沒備好的紅燈
3. 媒體音量頂到最大：`input keyevent 24` × 15（沿用 `verify_audio.sh` 已驗證的手法；
   `adb shell media volume` 在本機映像上不存在）
4. `gui_session.sh` 打包並啟動 Mirage，環境變數 `MIRAGE_PORT`／`MIRAGE_AUDIO_LOG=1`／
   `MIRAGE_FPS_LOG=1`／`MIRAGE_CONN_LOG=1`
5. 量測 `-d` 秒
6. 解析 log，依 §2 的邏輯計算，套用 A1–A4 斷言
7. cleanup：`pkill -x MirageApp`、移除暫存 bundle

**不注入動畫**：遊戲進行中畫面本來就在變化，而注入器會真的去點畫面，可能叫出暫停
選單或退出關卡（`verify_game_fps.sh:32-36` 記載的同一個理由）。

## 5. 執行順序

分兩階段，順序不可調換：

**階段一：探測（零斷言）**
建好 harness，跑一次 60 秒，把 `[audio]` 每一行與 fps 摘要原樣輸出。這一輪**不做任何
斷言**，目的只是拿到真實數字：Pixel Flow 是否持續發聲、連續有聲期間的 ΔU 分佈、
depth 落在哪、fps 多少。若 Pixel Flow 不發聲，此時退回鈴聲方案並記錄。

**階段二：定門檻、加斷言、故障注入**
依階段一的數字填入 A1–A4 的門檻，然後證明它會紅。

## 6. 故障注入

比照 D42 的做法——不證明會紅的斷言，跟沒有斷言沒有差別。

| # | 注入 | 預期 |
|---|---|---|
| 1 | 不啟動遊戲（無發聲來源） | A2 紅：`pkt>0` 的秒數為 0 |
| 2 | 不設 `MIRAGE_AUDIO_LOG` | A1 紅：0 行 |
| 3 | 把 `AudioPlayer.swift:30` 的 `interleaved: false` 改回 `true` | A1 與 A4 同時紅：NSException 打死 MainActor，audio log 0 行且 fps 0 |

第 3 條是本設計的靈魂：它把「這支腳本能抓到什麼」從宣稱變成證明，而且抓的正是讓
Mirage 三個階段黑畫面的那個具體回歸。改完立刻 revert，不留在樹上。

## 7. 文件更新

- **spec `§8-6`**：加更正註記（沿用 §5 既有的「⚠️ 更正（2026-07-29）」慣例），記下字
  面判準與 §5 自相矛盾，以及新的表述
- **`RESULTS-p1e.md`**：驗收線 6 依實測改判並附真實數字；pending-human 清單移除第 6
  項；**一併修正該文件把 headless 當阻礙的記載**——那個歸因已被 2026-07-28 的調查推翻
- **`project-review.md`**：D32 標記已修

## 8. 不在本次範圍

- **驗收線 7（`MIRAGE_FPS_LOG ≥ 55`）**：它被列 pending-human 的理由與驗收線 6 完全
  相同，同樣已經失效，而且 `verify_game_fps.sh` 早就在量 fps 了。但那是另一筆帳，本
  次只在 `project-review.md` 記一句，不順手做掉。
- **rate adaptation**：若 §5 探測顯示時鐘漂移確實造成穩態 underrun，那是產品層的設計
  問題，不在一支驗證腳本的職責範圍內。本次只如實量測並記錄，需要時另開債務。

## 2026-08-03 追記（實作後）

本文件寫成時（§0–§8）還是「四條斷言／A1–A4／無 pre-roll／無判定」的版本。實作過程中
發生的事，指過去的人若只看到這裡會完全不知道，補記於此——`verify_audio_gui.sh` 的結尾
橫幅與 spec §8-6 的更正註記都把讀者指向本文件當作「完整推導」，不能讓它停在實作前。

**pre-roll 是實測逼出來的產品修正，不是本文件原本的設計。** Task 3 用本文件描述的
harness 跑第一次真 GUI + 真 `AudioPlayer` 量測時，量到 `under` 每秒穩定增加約 90、
`depth` 全程貼 0ms、`over` 恆為 0——環形緩衝從來沒有積過水。根因是 `AudioRingBuffer`
原本沒有任何蓄水機制，`readStereo` 從建構起就照單全收。修法（`primeThresholdSamples`
預設 9_600＝100ms）加在 `AudioRingBuffer` 而非 `AudioPlayer`，理由與本文件 §3 抽
`gui_session.sh`／§7 選 library target 測試的邏輯一致：`AudioPlayer` 在 executable
target 裡沒有任何單元測試碰得到，`AudioRingBuffer` 有。完整推導見 `app/RESULTS-d32.md` §6。

**斷言從四條變六條**：本文件 §2 只設計了 A1–A4。實作後新增：

- **A5**（`PRIMES`，重新蓄水次數上限）——沒有這條，A3 可以靠反覆蓄水作弊：蓄水期
  `under` 不增、`depth` 看似健康、`pkt>0` 所以窗口不排除，一個每 2 秒就重新蓄水一次、
  每次賠 100ms 靜音的緩衝，只看 A3 會顯示為「很健康」。
- **A6**（`MALFORMED`，畸形日誌行數，固定 `≤ 0`）——解析可信度門檻，不是品質門檻：
  缺 `pkt=`／`under=` 欄位的畸形行會讓 delta 跨越遺失的取樣點，該紅。

六條門檻的完整推導（五次實測值的比例換算）見 `app/RESULTS-d32-probe.md` §「六個門檻的
計算過程」。

**最終判定：未通過（已大幅改善）**，不是本文件原本設想的「通過／不通過」二選一，而是
兩者之間的第三種結果——pre-roll 讓 `USUM` 降約 97%（5481 → 約 150），但 `PRIMES`≈35
（60 秒內平均每 1.7 秒排乾一次重新蓄水，每次賠約 100ms 靜音，全程約 5.8% 時間在靜音）。
`verify_audio_gui.sh` 的六條斷言因此定位為**回歸偵測**（不要比 2026-08-03 的基準更糟），
不是驗收線 6 本身的通過判準——腳本自己在結尾會印出這個區別。

**殘餘缺陷記為 D44**：生產端（emulator 音訊時鐘）供應量長期約為消費端需求的 94%，
兩個獨立時鐘之間沒有任何 rate adaptation。三個候選方向（加大緩衝／低水位滯後／真正的
rate adaptation）均未定案，見 `project-review.md` D44。
