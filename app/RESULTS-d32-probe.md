# D32 驗收線 6 探測結果——真 GUI 下的音訊健康量測（零斷言）

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
