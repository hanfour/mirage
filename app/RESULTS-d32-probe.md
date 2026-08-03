# D32 驗收線 6 探測結果——真 GUI 下的音訊健康量測（零斷言）

> **2026-08-03 審查後追記**：`audio_stats` 的 awk 邏輯審查發現一個問題——缺
> `pkt=`／`under=` 欄位的畸形行原本會被靜默算成 `pkt=0`／`under=0`，污染下一行的
> delta 計算且不留任何痕跡。已修正：畸形行改計入新的 `MALFORMED` 計數並整行跳過，
> 不更新基準；函式也已抽到 `app/scripts/lib/audio_stats.sh` 並附自我測試
> （`app/scripts/lib/audio_stats_selftest.sh`）。**用修正後的 `audio_stats` 重跑
> 下面三次量測留存的原始 log，數字與下表完全一致，且三次皆 `MALFORMED=0`**——這
> 三次實測都沒有出現畸形行，本次修正是補上防護，不是推翻下面的數字。完整修法與
> 驗證見 `.superpowers/sdd/2026-08-03-d32-acceptance-6-automation/task-3-report.md`
> 的追加章節。

- **日期**：2026-08-03
- **腳本**：`app/scripts/verify_audio_gui.sh`（探測版，`set -uo pipefail`，退出碼永遠 0）
- **模擬器**：`emulator-5556`（gRPC `8556`，開機完成，未 `loadSnapshot`、未重啟）
- **發聲來源**：**Pixel Flow**（`com.loomgames.pixelflow`）——三次量測 `SOUND_SECS` 皆等於
  `AUDIO_LINES`（62/62），代表這款遊戲在量測視窗內幾乎連續發聲，**不需要**退回鈴聲方案
  （brief §Step 4 的 `SOUND_SECS=0` 退回路徑未觸發）。
- **量測參數**：預設值，`-d 60`（實際量到 62 行，因 `sleep 6` 拉前景與 `sleep 60` 量測交界
  處有 1–2 秒重疊，非缺陷）。

## 三次量測完整數字

| 次 | AUDIO_LINES | SOUND_SECS | USUM | UMAX | UWINDOWS | FPS_SAMPLES | FPS_AVG | FPS 最低/最高 |
|---|---|---|---|---|---|---|---|---|
| 1 | 62 | 62 | 5481 | 92 | 61 | 64 | 56 | 1 / 60 |
| 2 | 62 | 62 | 5467 | 161 | 61 | 64 | 48 | 2 / 60 |
| 3 | 62 | 62 | 5384 | 92 | 61 | 64 | 49 | 7 / 60 |

三次的 `USUM`（5384–5481）與 `UMAX`（92–161）皆落在同一個量級——符合 Step 5 的預期
（不像 `RESULTS-p1e.md` 記載的 `under=3` 與 `under=426` 那種光譜兩端）。

**附註：第三次量測第一次嘗試得到全 0（`AUDIO_LINES=0 SOUND_SECS=0 USUM=0 UMAX=0
UWINDOWS=0 FPS_SAMPLES=0 FPS_AVG=0`）**，log 檔案完全是空的（0 bytes），`fps_summary`
診斷為「幀也沒進來，問題在串流或連線」。這正是 brief 與 `verify_game_fps.sh:155` 記載的
已知不穩定路徑，重跑一次即恢復正常（上表的「3」即為重跑後的結果）。兩次嘗試皆保留在
`/tmp/d32-probe-3.txt`（全 0，未採用）與 `/tmp/d32-probe-3b.txt`（採用值）供查驗。

## `[audio]` 原始日誌：三次的前 10 行與後 10 行

### 第 1 次

```
[audio] pkt=94 sr=48000 ch=2 under=96 over=0 depth=0ms
[audio] pkt=92 sr=48000 ch=2 under=183 over=0 depth=0ms
[audio] pkt=94 sr=48000 ch=2 under=274 over=0 depth=0ms
[audio] pkt=82 sr=48000 ch=2 under=363 over=0 depth=0ms
[audio] pkt=86 sr=48000 ch=2 under=454 over=0 depth=0ms
[audio] pkt=94 sr=48000 ch=2 under=546 over=0 depth=0ms
[audio] pkt=95 sr=48000 ch=2 under=638 over=0 depth=0ms
[audio] pkt=93 sr=48000 ch=2 under=729 over=0 depth=1ms
[audio] pkt=97 sr=48000 ch=2 under=818 over=0 depth=0ms
[audio] pkt=91 sr=48000 ch=2 under=905 over=0 depth=0ms
...
[audio] pkt=100 sr=48000 ch=2 under=4762 over=0 depth=0ms
[audio] pkt=97 sr=48000 ch=2 under=4852 over=0 depth=0ms
[audio] pkt=99 sr=48000 ch=2 under=4944 over=0 depth=0ms
[audio] pkt=97 sr=48000 ch=2 under=5036 over=0 depth=0ms
[audio] pkt=94 sr=48000 ch=2 under=5125 over=0 depth=0ms
[audio] pkt=97 sr=48000 ch=2 under=5214 over=0 depth=0ms
[audio] pkt=96 sr=48000 ch=2 under=5303 over=0 depth=0ms
[audio] pkt=98 sr=48000 ch=2 under=5395 over=0 depth=0ms
[audio] pkt=99 sr=48000 ch=2 under=5486 over=0 depth=1ms
[audio] pkt=96 sr=48000 ch=2 under=5577 over=0 depth=0ms
```

### 第 2 次

```
[audio] pkt=96 sr=48000 ch=2 under=96 over=0 depth=0ms
[audio] pkt=153 sr=48000 ch=2 under=257 over=0 depth=0ms
[audio] pkt=92 sr=48000 ch=2 under=344 over=0 depth=0ms
[audio] pkt=94 sr=48000 ch=2 under=431 over=0 depth=0ms
[audio] pkt=84 sr=48000 ch=2 under=519 over=0 depth=0ms
[audio] pkt=94 sr=48000 ch=2 under=607 over=0 depth=0ms
[audio] pkt=96 sr=48000 ch=2 under=698 over=0 depth=0ms
[audio] pkt=90 sr=48000 ch=2 under=786 over=0 depth=1ms
[audio] pkt=86 sr=48000 ch=2 under=873 over=0 depth=0ms
[audio] pkt=96 sr=48000 ch=2 under=965 over=0 depth=0ms
...
[audio] pkt=92 sr=48000 ch=2 under=4776 over=0 depth=0ms
[audio] pkt=90 sr=48000 ch=2 under=4863 over=0 depth=0ms
[audio] pkt=92 sr=48000 ch=2 under=4951 over=0 depth=0ms
[audio] pkt=83 sr=48000 ch=2 under=5037 over=0 depth=0ms
[audio] pkt=90 sr=48000 ch=2 under=5125 over=0 depth=0ms
[audio] pkt=84 sr=48000 ch=2 under=5212 over=0 depth=1ms
[audio] pkt=90 sr=48000 ch=2 under=5299 over=0 depth=0ms
[audio] pkt=90 sr=48000 ch=2 under=5386 over=0 depth=0ms
[audio] pkt=90 sr=48000 ch=2 under=5475 over=0 depth=0ms
[audio] pkt=92 sr=48000 ch=2 under=5563 over=0 depth=0ms
```

### 第 3 次（採用值，重跑後）

```
[audio] pkt=93 sr=48000 ch=2 under=91 over=0 depth=0ms
[audio] pkt=97 sr=48000 ch=2 under=183 over=0 depth=0ms
[audio] pkt=93 sr=48000 ch=2 under=270 over=0 depth=0ms
[audio] pkt=91 sr=48000 ch=2 under=357 over=0 depth=0ms
[audio] pkt=97 sr=48000 ch=2 under=448 over=0 depth=0ms
[audio] pkt=97 sr=48000 ch=2 under=540 over=0 depth=0ms
[audio] pkt=94 sr=48000 ch=2 under=631 over=0 depth=0ms
[audio] pkt=96 sr=48000 ch=2 under=722 over=0 depth=0ms
[audio] pkt=96 sr=48000 ch=2 under=813 over=0 depth=0ms
[audio] pkt=98 sr=48000 ch=2 under=905 over=0 depth=0ms
...
[audio] pkt=94 sr=48000 ch=2 under=4690 over=0 depth=0ms
[audio] pkt=93 sr=48000 ch=2 under=4778 over=0 depth=0ms
[audio] pkt=93 sr=48000 ch=2 under=4865 over=0 depth=0ms
[audio] pkt=92 sr=48000 ch=2 under=4952 over=0 depth=0ms
[audio] pkt=93 sr=48000 ch=2 under=5039 over=0 depth=0ms
[audio] pkt=93 sr=48000 ch=2 under=5125 over=0 depth=0ms
[audio] pkt=96 sr=48000 ch=2 under=5214 over=0 depth=0ms
[audio] pkt=94 sr=48000 ch=2 under=5302 over=0 depth=0ms
[audio] pkt=90 sr=48000 ch=2 under=5388 over=0 depth=0ms
[audio] pkt=95 sr=48000 ch=2 under=5475 over=0 depth=0ms
```

## 觀察（供 Task 4 定門檻參考，非本 task 的斷言）

1. **`under` 每秒單調遞增，貫穿整段有聲期間，不是集中在啟動或轉場**。三次量測裡
   `USUM/UWINDOWS ≈ 88–90`——也就是 61 個「連續有聲」的量測窗裡，平均每窗的
   underrun 增量高達 88–90，而 `pkt` 每秒約 82–100（對應約每 10ms 一次的 render
   callback）。換句話說**幾乎每一次 render callback 都伴隨 underrun**，而不是
   「大致健康、偶爾欠位」。這與原始判準假設的「連續有聲時 underrun 應趨近 0，
   只有啟動/靜音轉場才會飆高」不同——三次量測都沒有觀察到「趨近 0」的穩態，
   `depth` 也幾乎全程貼著 `0ms`（偶爾 `1ms`）。這是否代表 playback 品質有實際
   問題（可能有聽感上的斷續）、還是 `AudioRingBuffer` 在這個封包節奏下的正常
   運作模式，需要人耳實聽佐證——**本階段刻意不下結論，留給 Task 4 裁決門檻時
   一併考慮**。
2. **FPS 平均在三次之間有明顯落差**（56.1 / 48.4 / 49.4），且三次都出現過極低的
   單筆取樣（最低 1、2、7），同時串流尺寸在同一次量測裡出現多個值
   （`540x1200 888x1972 900x2000`）——代表量測視窗內發生了解析度變動（例如視窗
   從預設大小被拉到全螢幕），而 fps 對串流解析度敏感（`verify_game_fps.sh` 已
   記載的特性）。三次平均值都還在合理範圍，但**這不是乾淨的穩態量測**，Task 4
   訂 A4 門檻時應把這個變異納入考慮，不要只看單次平均。

## 結論

依這三次量測：

- **A1（`AUDIO_LINES` ≥ 門檻）**：三次皆 62，建議門檻 **≥ 55**（60 秒視窗留啟動/收尾裕度，
  沿用 `verify_game_fps.sh` 對 60 秒視窗的既有慣例）。
- **A2（`SOUND_SECS` ≥ 門檻）**：三次皆 62，與 `AUDIO_LINES` 相等——Pixel Flow 在這個
  關卡幾乎連續發聲。建議門檻 **≥ 55**，與 A1 同值。
- **A3（連續有聲期間 underrun ≤ 門檻）**：`USUM` 三次為 5384–5481、`UMAX` 三次為
  92–161，同量級但數字偏高（見上方觀察 1）。建議門檻 `USUM ≤ 6000` 且 `UMAX ≤ 250`
  （皆略高於三次實測最大值，留安全邊際）——**但這組門檻只保證「不比目前已測到的更差」，
  不代表目前的 under 速率本身是健康的**，是否要收緊需要人耳實聽或進一步調查佐證。
- **A4（`FPS_SAMPLES` > 0 且 `FPS_AVG` ≥ 門檻）**：三次皆有 64 個取樣（> 0），平均
  48–56。建議門檻 `FPS_SAMPLES ≥ 55` 且 `FPS_AVG ≥ 40`——採比三次最低平均（48）更寬鬆
  的下限，因為量測視窗內解析度會變動（見觀察 2），40 是三次數字都能穩定通過、
  又不會因為一次解析度切換就假紅的折衷值；不採用 `RESULTS-p1e.md` 先前提到的
  `≥55`，因為那個數字是在沒有解析度變動的量測條件下訂的，直接套用會讓本探測的
  第 2、3 次落在門檻邊緣甚至以下。

以上為建議值，非本 task 的斷言——`verify_audio_gui.sh` 本身不含任何 `exit 1` 路徑，
退出碼永遠是 0，門檻要由 Task 4 決定並加上斷言後才生效。

---

## 2026-08-03 追記（Task 5）：pre-roll 之後重新量三次、定門檻、加斷言

> 上面整份文件記載的三次量測（`AUDIO_LINES`/`SOUND_SECS` 皆 62、`USUM` 5384–5481）是
> **pre-roll 之前**的探測，已因 Task 4 的產品修正（`AudioRingBuffer` 加 pre-roll）作廢。
> 本節記錄 pre-roll 之後的重新量測、與控制端數字合併算出的門檻，以及加上斷言後的驗證。

### pre-roll 前後對照

| | pre-roll 前（本檔上方三次） | pre-roll 後（控制端兩次） | pre-roll 後（本次三次） |
|---|---|---|---|
| `USUM` | 5481 / 5467 / 5384 | 138 / 170 | 175 / 129 / 150 |
| `UMAX` | 92 / 161 / 92 | 8 / 9 | 8 / 8 / 9 |
| `depth` | 全程 0ms（偶爾 1ms） | 中位 46ms、最大 94ms、最小 0 | 中位 46/46/49.5ms、最大 96/95/94ms、最小皆 0 |
| `PRIMES` | （當時無此指標） | 35 / 36 | 36 / 35 / 34 |
| `FPS_AVG` | 56 / 48 / 49 | 40 / 46 | 45 / 34 / 37 |

`USUM` 降約 97%、`depth` 從全程貼 0ms 變成會積水到 ~94–96ms——pre-roll 確實有效。但
`PRIMES` 落在 34–36（60 秒內平均每 1.7–1.8 秒排乾一次），依 Task 5 brief 的判讀表落在
**「`PRIMES` 大、`USUM` 低」**那一列——**假性健康**：靠反覆蓄水把 underrun 藏起來。
本次三次量測與控制端兩次量測一致地落在同一列，佐證這不是控制端那兩次的偶然。

**這與 2026-08-03 的使用者裁決一致**：驗收線 6 判「未通過（已大幅改善）」，開新債
D44，不修到通過為止。本 task 的斷言因此定位為**回歸偵測**，不是通過判準（見下方
腳本輸出段落）。

### 重新量測時遇到的環境不穩定（比預期嚴重，已排查）

`Step 1` 的第一輪量測連續量到 **3 次全 0**（`AUDIO_LINES=0 ... FPS_AVG=0`，log 檔完全
空白）才在第 4 次嘗試量到數字；`Step 3`（加完斷言後的確認跑）第一次執行也量到全 0，
重跑後才通過。合計本 task 遇到 **4 次**全 0，比 Task 3 記載的「62 次量測中 1 次」高
出許多。

排查手法（**不使用 `screencapture`**——依 `tools/probe` 既有規範，那會拍到使用者桌面，
已在排查途中誤用一次並立即停用）：對卡住的 `MirageApp` 行程用 `sample` 取樣，主執行緒
停在 `NSApplication run` 的事件迴圈裡等事件、**全程只有兩條執行緒**（主執行緒與
`NSEventThread`），代表 `MirageScene.swift` 掛在 `Window` 場景根視圖上的 `.task`
（呼叫 `model.start()`／`startLifecycle()` 那個）從未觸發過——不是產品邏輯錯誤，是
這次啟動 SwiftUI 視窗沒有真正「出現」。這與 `RESULTS-p1e.md`／`live-test-env-gotchas`
記載的舊症狀（headless 不驅動 `.task`）表徵相同。當時 `top -l 2` 量到 load average
27–32、`OrbStack Helper` 瞬間衝到 276% CPU，系統處於重度資源競爭（機器上同時有多個
終端機 session／其他 agent 在跑）。改用 `tell application "Mirage" to activate`
（而非 `gui_session.sh` 現行的 `System Events ... set frontmost`）手動重試後量得到
完整輸出；但隨後改用**完全未修改的** `verify_audio_gui.sh`（原本的 `set frontmost`
寫法）重跑也一樣成功——可見這不是 `gui_session.sh` 啟動手法本身的缺陷，而是當下系統
負載造成的暫時性視窗合成失敗。**`gui_session.sh` 未被本 task 修改**。四次全 0 皆為
此路徑，皆已依 brief 指示重跑排除，未採用其數字。

### 新的三次量測（採用值）

| 次 | AUDIO_LINES | SOUND_SECS | USUM | UMAX | UWINDOWS | PRIMES | MALFORMED | FPS_SAMPLES | FPS_AVG |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 63 | 63 | 175 | 8 | 62 | 36 | 0 | 64 | 45 |
| 2 | 63 | 63 | 129 | 8 | 62 | 35 | 0 | 64 | 34 |
| 3 | 60 | 60 | 150 | 9 | 59 | 34 | 0 | 62 | 37 |

### 五次彙總（本次三次 + 控制端兩次）

| | 控制 1 | 控制 2 | 本次 1 | 本次 2 | 本次 3 | 最小 | 最大 |
|---|---|---|---|---|---|---|---|
| `AUDIO_LINES` | 60 | 61 | 63 | 63 | 60 | 60 | 63 |
| `SOUND_SECS` | 60 | 61 | 63 | 63 | 60 | 60 | 63 |
| `USUM` | 138 | 170 | 175 | 129 | 150 | 129 | 175 |
| `UMAX` | 8 | 9 | 8 | 8 | 9 | 8 | 9 |
| `UWINDOWS` | 59 | 60 | 62 | 62 | 59 | 59 | 62 |
| `PRIMES` | 35 | 36 | 36 | 35 | 34 | 34 | 36 |
| `FPS_AVG` | 40 | 46 | 45 | 34 | 37 | 34 | 46 |
| `MALFORMED` | 0 | 0 | 0 | 0 | 0 | 0 | 0 |

本次三次與控制端兩次數量級一致（`USUM` 129–175、`PRIMES` 34–36、`FPS_AVG` 34–46），
沒有出現 brief 警示的「`PRIMES` 掉到個位數或衝破 80」這種需要先回報的巨大落差，
可以直接依五次合併值定門檻。

### 六個門檻的計算過程

- **A1 `AUDIO_LINES`**：規則＝`DURATION` 的 80%。`DURATION=60`（腳本預設值），
  `60 × 0.8 = 48`。**門檻：`≥ 48`**。
- **A2 `SOUND_SECS`**：規則＝五次最小值再打 8 折。`min(60,61,63,63,60) = 60`，
  `60 × 0.8 = 48`。**門檻：`≥ 48`**（與 A1 同值是巧合——`SOUND_SECS` 最小值剛好等於
  `DURATION`，因為 Pixel Flow 在量測視窗內幾乎連續發聲）。
- **A3 `USUM`**：規則＝五次最大值 × 2，且至少 `UWINDOWS` 的 5%（每 20 秒容許 1 次），
  取兩者較大者。`max(138,170,175,129,150) = 175`，`175 × 2 = 350`；`UWINDOWS` 五次
  落在 59–62，5% ≈ 3，遠小於 350，被 350 那項主導。**門檻：`≤ 350`**。
- **A4 `FPS_AVG`**：規則＝五次最小值再打 8 折，且不高於 55。`min(40,46,45,34,37) = 34`，
  `34 × 0.8 = 27.2`，無條件捨去＝27；`min(27, 55) = 27`。**門檻：`≥ 27`**。
- **A5 `PRIMES`**：規則＝五次最大值 × 2，下限 2。`max(35,36,36,35,34) = 36`，
  `36 × 2 = 72`；72 > 2，被 72 那項主導。**門檻：`≤ 72`**。
- **A6 `MALFORMED`**：固定 **`≤ 0`**（解析可信度門檻，非量測值推導）。

依「`PRIMES` 與 `USUM` 要一起讀」判讀表：五次量測的 `PRIMES`（34–36，非個位數）與
`USUM`（129–175，遠低於 pre-roll 前的 5384–5481 但非趨近 0）落在**「`PRIMES` 大、
`USUM` 低」**那一列——與已裁決的「未通過（已大幅改善）」一致，無新增疑慮，可以
繼續往下加斷言。

### 加上斷言後的驗證

`Step 3`（單次確認全綠，過程中遇到 1 次全 0 需重跑，見上）：

```
✅ A1 音訊日誌行數（App 存活）：61（門檻 48）
✅ A2 有封包的秒數：61（門檻 48）
✅ A3 連續有聲期間的 underrun 增量總和：147（上限 350）
✅ A4 fps 取樣筆數：63（門檻 1）
✅ A4 平均 fps：32（門檻 27）
✅ A5 重新蓄水次數：35（上限 72）
✅ A6 畸形日誌行：0（上限 0）
```

`Step 4`（連跑兩次確認不 flaky，兩次皆 `EXIT=0`，未遇到全 0）：

| | AUDIO_LINES | SOUND_SECS | USUM | FPS_SAMPLES | FPS_AVG | PRIMES | MALFORMED |
|---|---|---|---|---|---|---|---|
| 第 1 次 | 63 | 63 | 132 | 64 | 45 | 36 | 0 |
| 第 2 次 | 62 | 62 | 129 | 64 | 34 | 34 | 0 |

`./scripts/ci.sh`：`EXIT=0`，八道閘門全綠，閘門 4（裸變數緊接全形標點）：

```
=== 閘門 4：shell 腳本裡不得有「裸變數緊接全形標點」 ===
✅ 無裸變數緊接全形標點
```

### 結論

六條斷言已加入 `verify_audio_gui.sh`，門檻由本次三次與控制端兩次共五次實測值決定
（見上方推導），非理論值、非隨意抓數字。`A3`／`A5` 依 brief 的明確指示留了寬裕的
安全邊際（`USUM` 上限 350 是五次實測最大值的 2 倍、`PRIMES` 上限 72 是五次實測最大值
的 2 倍），理由是生產端與消費端音訊時鐘之間沒有 rate adaptation、長時間跑會漂移；
**沒有把 A3 定成 0**，因為那正是 D32 這條債務一開始的形狀。

**這六條斷言是回歸偵測，不是驗收線 6 的通過判準**——腳本判定段落的輸出已明確印出
這個區別（逐字見 `app/scripts/verify_audio_gui.sh` 尾段），任何人單獨執行這支腳本
都能立刻看到「全綠 ≠ 驗收線 6 通過」。驗收線 6 本身已由使用者裁決為「未通過（已
大幅改善）」，殘餘缺陷記為 D44，不在本 task 範圍內修復。

**環境教訓**：本機今天的 GUI 合成不穩定率（4/8 次全 0）遠高於以往，根因是系統負載
（多個並行 session／agent 共用同一台機器），不是 `gui_session.sh` 的啟動手法有缺陷
——已用「完全未修改腳本」重跑驗證過。下次若再遇到偏高的全 0 比率，先看
`top -l 2 -o cpu` 的 load average 與是否有異常吃 CPU 的行程，而不是急著改
`gui_session.sh` 的啟動邏輯。
