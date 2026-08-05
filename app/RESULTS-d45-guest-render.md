# D45：坐實 guest render fps（7a 對照組分母的前提檢驗）

- **日期**：2026-08-04
- **模擬器**：`emulator-5556`（gRPC `8556`），emulator `37.2.1.0`（system image
  `google/sdk_gphone64_arm64/emu64a:15/AE3A.240806.036/12592187:user/release-keys`），
  AVD 名稱 `mirage-game`
- **遊戲**：Pixel Flow `com.loomgames.pixelflow`（`versionName=0.30.3`
  `versionCode=173`），已跑超過一小時，畫面在關卡選擇/地圖畫面（**不是遊玩中**，見下方限制 4）
- **主機負載**：`load averages: 2.91 3.39 3.76`（量測期間；**遠低於** `RESULTS-d45-probe.md`
  記載的 7a 對照組量測條件 load 8–18，見下方限制 5）
- **本 task 不需要 GUI**：三個候選方法皆為 `adb dumpsys` 或讀 proto 定義。Mac 螢幕
  在量測期間鎖定（螢幕保護執行中）——依指示未嘗試解鎖，也未執行任何需要 GUI 合成的
  量測。

> ⚠️ **殘餘價值說明**：本檔標題沿用「7a 對照組分母的前提檢驗」，但 7a/7b 那組相對
> 判準已於 design doc §9 整段作廢（使用者裁決 `≥ 55` 保留不改）。本檔仍有獨立價值：
> **guest render 是不是瓶頸**這個問題本身值得回答，且過程中發現並修正了量測工具
> `dumpsys SurfaceFlinger --timestats` 一個欄位的系統性偏差——這個修正對任何未來
> 用同一工具量 fps 的人都有用，不只是為了 7a。

> ⚠️ **讀下面內容前，先看這五條限制**（皆有獨立小節詳述）：
> 1. **Step 4 的 A/B 是 headless `streamScreenshot` 客戶端，不是真正的 Mirage.app
>    GUI**——沒有涵蓋 macOS 端解碼/Metal/視窗合成。
> 2. **A/B 只跑了一輪**（每臂 20 秒），沒有多輪取中位數。
> 3. **`dumpsys` 直接印出的 `averageFPS`（61.78–61.85）是量測工具本身的系統性偏差**，
>    真值約 **59.9 fps**——已在 AOSP 原始碼層級確認機制，見 Step 2。本檔所有「guest
>    fps」的說法均指修正後的數字，不是 dumpsys 原始輸出。
> 4. **量測畫面是選單/關卡選擇地圖，不是遊玩中**——「guest 不是瓶頸」目前只在選單
>    畫面成立，投資 §11 原始問題（「會頓、fps 20–35」）記載的是遊玩時的體感。
> 5. **A/B 在主機 load≈3 的安靜窗口下做**，而 7a 對照組的量測條件是 load 8–18
>    （`RESULTS-d45-probe.md`）——兩者不可比，本檔**沒有**驗證 guest 在高負載下
>    是否掉幀。

## 摘要結論（含修正）

**方法二（`dumpsys SurfaceFlinger --timestats`）可用，坐實成功——但工具回報的
`averageFPS` 欄位本身有系統性偏差，已修正。**

- guest 端（Pixel Flow 的 Unity SurfaceView）修正後的 render fps 約 **59.9 fps**
  （59.86–59.92，三個獨立窗口），緊貼 60Hz vsync 天花板，三個窗口
  `droppedFrames` 皆為 **0**。
- A/B（headless、load≈3、單輪）：guest 在有無 `streamScreenshot` 客戶端下都維持
  vsync 鎖定、零掉幀——但**這個指標在安靜窗口下已經頂到天花板**，能觀察到的只是
  「有沒有掉幀」，觀察不到「有沒有些微額外負擔」（見限制 5、Step 4「已知限制」）。
- **`docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §11.2 的推論
  被本次量測推翻**：那條推論的內容是「瓶頸在 guest 端的畫面產生速率」。本次直接
  量到的是相反的事——guest 在安靜窗口、選單畫面下沒有掉幀、緊貼 vsync。已在該
  文件用獨立 commit 加註 ⚠️ 指回本檔；§11.2「不是頻寬瓶頸」那半段（解析度掃描
  證據）不受影響，仍然成立，要推翻的只有「所以瓶頸在 guest」那半句。
  **⚠️ 2026-08-05（D39）更正上面這句的後半**：解析度掃描的**數據**確實不受影響，
  但「不是頻寬瓶頸」這個**結論**只在 §11.2 涵蓋的三個解析度上成立。補上全螢幕
  898×1996（本檔量測用的就是這個尺寸）之後，raw RGBA 在那裡撞到 270–290 MiB/s 的
  吞吐天花板：實測 raw 40.0 fps／MMAP 56.7 fps。也就是說本檔「損失在 guest 之後的
  鏈路」這個結論不但成立，還多了一個帶數字的候選段落。見 `app/RESULTS-mmap.md`。
- **這不等於「已經知道瓶頸在哪」**：本檔只排除了一個節點（guest render，且僅在
  安靜窗口／選單畫面下）。guest→直拉對照組、直拉對照組→Mirage 之間的實際損失
  成因，以及 guest 在高負載/遊玩中是否維持這個表現，都還沒有拆解——見下方
  「對『為什麼只有 49』的說明」與「下一步」。

方法一不可用（量到空的系統 UI 幀）。方法三依規則跳過（方法二已成功，不需要再試）。

---

## Step 1：方法一 —— `dumpsys gfxinfo framestats`

```bash
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
"$ADB" -s emulator-5556 shell dumpsys gfxinfo com.loomgames.pixelflow framestats \
  > /tmp/d45-gfxinfo.txt 2>&1
grep -c "PROFILEDATA" /tmp/d45-gfxinfo.txt
```

實際輸出關鍵片段：

```
** Graphics info for pid 4246 [com.loomgames.pixelflow] **

Stats since: 5642009465814ns
Total frames rendered: 0
...
	com.loomgames.pixelflow/com.scopely.unity.ScopelyUnityActivity/android.view.ViewRootImpl@b1db90 (visibility=0)
View hierarchy:

  com.loomgames.pixelflow/com.scopely.unity.ScopelyUnityActivity/android.view.ViewRootImpl@b1db90
  10 views, 12.58 kB of render nodes

Total ViewRootImpl   : 1
```

`grep -c "PROFILEDATA"` → **0**。

**判定：不可用。** 完全命中 brief 預先寫下的風險：`gfxinfo` 量的是 App 的
`ViewRootImpl`（一個只有 10 views 的空殼——Android 標準 View 階層，menu/系統 UI
殘留），`Total frames rendered` 恆為 0。Unity 自己用 `SurfaceView` 直接畫到
BLAST buffer，繞過了這條 `ViewRootImpl` 的繪製路徑，`gfxinfo` 完全看不到它。
往方法二。

## Step 2：方法二 —— `dumpsys SurfaceFlinger --timestats`

```bash
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
"$ADB" -s emulator-5556 shell dumpsys SurfaceFlinger --timestats -clear
"$ADB" -s emulator-5556 shell dumpsys SurfaceFlinger --timestats -enable
sleep 20
"$ADB" -s emulator-5556 shell dumpsys SurfaceFlinger --timestats -dump > /tmp/d45-timestats.txt
"$ADB" -s emulator-5556 shell dumpsys SurfaceFlinger --timestats -disable
```

實際輸出關鍵片段（第一次試跑，無客戶端連線）：

```
statsStart = 1785831622
statsEnd = 1785831650
totalFrames = 1689
displayOnTime = 28156 ms
...
displayRefreshRate = 60 fps
renderRate = 60 fps
uid = 10208
layerName = SurfaceView[com.loomgames.pixelflow/com.scopely.unity.ScopelyUnityActivity](BLAST)#128
packageName =
gameMode = Unsupported
totalFrames = 1687
droppedFrames = 0
lateAcquireFrames = 0
badDesiredPresentFrames = 0
...
SetFrameRate vote for this layer:
frameRate = 60.00
frameRateCompatibility = Default
seamlessness = ShouldBeSeamless
averageFPS = 61.849
present2present histogram is as below:
... 12ms=1 13ms=4 14ms=48 15ms=275 16ms=766 17ms=520 18ms=68 19ms=5 ...（20ms 以上全為 0）
```

**判定：可用**（layer 識別正確；數字本身有系統性偏差，見下方修正）。`layerName`
同時含 `SurfaceView` 與 `pixelflow`，且該 layer 自己的 `totalFrames`、
`droppedFrames`、`averageFPS`、`present2present` histogram 一應俱全——這是 Pixel
Flow 自己那個 Unity SurfaceView layer 的實際出幀統計，不是系統 UI 或全域聚合值。

### 數字修正：`averageFPS = 61.849` 是量測工具的系統性偏差，真值約 59.9

原報告曾用「拿 histogram 手算加權平均，結果與 dumpsys 印出的 `averageFPS` 吻合」
當作「這個數字等於 Pixel Flow 真實出幀速率」的證據。**這是套套邏輯**：`dumpsys`
自己就是用「`1000 / histogram 加權平均間隔`」算出 `averageFPS` 的，拿同一份
histogram 手算同一條公式，吻合是必然的——這只驗證了「這個欄位是這樣算出來的」，
不驗證「這個數字對不對」。

**真正的交叉檢驗，是拿另一個獨立來源比對**：每個 dump 都同時印出
`totalFrames`（該 layer 實際出幀數）與 `displayOnTime`（本次量測窗口的實際
時長，毫秒），兩者相除是另一條完全不依賴 histogram 分桶的 fps 算法：

| 窗口 | layer totalFrames | 窗口長度（`displayOnTime`） | `totalFrames÷窗口` | dumpsys `averageFPS` | 差 |
|---|---|---|---|---|---|
| 首試（無客戶端） | 1687 | 28.156s | **59.92** | 61.849 | +1.93（+3.2%） |
| A2（無客戶端） | 1201 | 20.042s | **59.92** | 61.780 | +1.86（+3.1%） |
| B（有客戶端） | 1211 | 20.230s | **59.86** | 61.811 | +1.95（+3.3%） |

**三個獨立窗口，`averageFPS` 都系統性地偏高約 3%，換算成平均幀間隔一律
偏低約 0.50–0.53ms**（`histogram 加權平均間隔 − 1000/(totalFrames÷窗口)`）。
三次幾乎相同的偏差量，是量化/捨去誤差的典型指紋，不是隨機雜訊。

**機制（已查證 AOSP 原始碼，非猜測）**：抓了 `android.googlesource.com/platform/
frameworks/native`（`refs/heads/main`）目前的原始碼，兩個檔案：

`services/surfaceflinger/TimeStats/TimeStats.cpp` 裡，present2present 的原始
奈秒差值在丟進 histogram 之前，先被這個 helper 轉成整數毫秒：

```cpp
static int32_t toMs(nsecs_t nanos) {
    int64_t millis =
            std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::nanoseconds(nanos))
                    .count();
    millis = std::clamp(millis, int64_t(INT32_MIN), int64_t(INT32_MAX));
    return static_cast<int32_t>(millis);
}
static int32_t msBetween(nsecs_t start, nsecs_t end) { return toMs(end - start); }
```

`std::chrono::duration_cast` 在兩個整數計數的 duration 型別之間轉換是**向零捨去**
（正值即無條件捨去到整數毫秒）——例如真實間隔 16.72ms 會被存成 16，捨去的
0.72ms 直接消失，不會進到後面任何計算。均勻分布下，這個捨去的期望損失正是
**0.5ms**，與我們三個窗口實測的 0.50–0.53ms 完全吻合。

再往下，`services/surfaceflinger/TimeStats/timestatsproto/TimeStatsHelper.cpp`
的 `Histogram::averageTime()` 直接拿這些已經被捨去的整數桶值做加權平均：

```cpp
float TimeStatsHelper::Histogram::averageTime() const {
    int64_t ret = 0;
    int64_t count = 0;
    for (const auto& ele : hist) {
        count += ele.second;
        ret += ele.first * ele.second;
    }
    return static_cast<float>(ret) / count;
}
```

`layerName`/`averageFPS` 那段文字輸出的產生處確認了公式：

```cpp
const float averageTime = iter->second.averageTime();
const float averageFPS = averageTime < 1.0f ? 0.0f : 1000.0f / averageTime;
StringAppendF(&result, "averageFPS = %.3f\n", averageFPS);
```

**兩段機制疊在一起**：原始間隔先被無條件捨去到整數毫秒（平均少 0.5ms），
`averageTime()` 再對這些已捨去的值取加權平均、`averageFPS = 1000/averageTime`
——平均間隔偏低 0.5ms/16.5ms≈3%，換算成 fps 就是系統性偏高約 3%，與實測完全
對得上。

**查證範圍的誠實說明**：抓到的是 AOSP **master（目前最新）**分支的原始碼，沒有
去比對這台模擬器 system image（`AE3A.240806.036`／Android 15）實際跑的確切
版本——這件事本身沒有查證。但 (a) `toMs`/`msBetween` 這個模式在這個檔案裡是
長期穩定的既有寫法，(b) `dumpsys` 實際輸出的欄位名稱與 histogram 分桶結構
（`layerName`／`totalFrames`／`droppedFrames`／`averageFPS`／present2present
histogram 分桶到 20ms 以下每 1ms 一格、以上漸疏）與這份原始碼逐項對得上，
(c) 三個獨立窗口的偏差量高度一致（0.50/0.50/0.53ms），是這個機制的典型指紋。
機制層面的確認可信度高，只是沒有做到「逐字元核對這台機器實際跑的版本」這個
更嚴格的標準。

**下文所有「guest fps」皆指修正後的數字（totalFrames÷窗口），不是 dumpsys
直接印出的 `averageFPS`。**

### 可用性論證：改用 `droppedFrames` 與 histogram 集中度，而非「數字吻合」

`present2present` 量的是**已經被 present 到顯示器的相鄰幀時間差**，這個量法
被 60Hz vsync 從下面截斷——guest 產得比 vsync 快也只會看到 present 卡在
vsync 節奏，量不到「guest 真正能衝多快」的上限。它能給的是**guest ≥ 約 60**
這個下界，不是精確的「guest 出幀速率」。

對本 task 的問題（guest 是不是低於驗收線 55 的瓶頸）而言，這個下界已經足夠：

- 首試窗口：`droppedFrames = 0`，1687 幀全部落在 12–19ms 桶，**沒有一幀落到
  20ms（約 1.2 個 vsync 週期）以上**——guest 幾乎每個 vsync 都準時交幀。
- A2／B 窗口：`droppedFrames` 同樣為 **0**，但 histogram 尾端不是全零（見
  Step 4，各有約 3% 的幀落在 20ms 以上）——見下方 Step 4 的完整數字，不在這裡
  過度延伸首試窗口的「零尾端」結論。

方法二已給出可用（雖需修正）的數字，依 brief「試到第一個給得出可用數字的為止」
的規則，**方法三（emulator gRPC 是否暴露統計）跳過，未嘗試**。

## Step 3：方法三 —— 跳過（依停止規則）

未執行。方法二已可用，依 brief 明文的停止規則不需要再試。若未來方法二失效
（例如換一支不用 BLAST SurfaceView 的遊戲），可以回頭檢查
`phase0/harness/gen/emulator_controller_pb2_grpc.py` 裡有沒有幀率/統計相關的
RPC——這件事本次沒有查證過。

## Step 4：A/B 對照 —— 已完成，但改用 headless 方式，且在安靜負載窗口下

### 範圍調整說明

Brief 原定的 A/B 是「Mirage 沒有跑」vs「Mirage 跑著並全螢幕拉串流」，但本 task
的環境限制是 Mac 螢幕鎖定中且明確禁止任何需要 GUI 的操作，無法啟動 Mirage.app
本身。

改採**headless** 方式驗證同一個因果機制：spec §5.1 疑慮的核心不是「Mirage.app
這個 macOS 程式存在」，而是「**`streamScreenshot` 這個 RPC 本身的存在與否，
會不會讓 guest 端多做工**」。`phase0/harness/fps_baseline.py`
（7a 對照組本身用的同一支腳本）就是一個乾淨的 `streamScreenshot` 客戶端，用它
在背景拉取，剛好能單獨隔離出這個變數——不含 Mirage 的 macOS 端解碼/Metal/
視窗合成，但完整覆蓋 guest 端會不會因為「有沒有人在拉串流」而變慢這個問題。
成本低（沿用既有腳本、`.venv-d45` 已建好），值得做。

**注意**：`phase0/harness/` 下需要 `import emulator_controller_pb2` 的腳本，在
系統 Python（protobuf 4.25.4）下會 `ImportError`（gencode 是用 protobuf 7.35.0
產生的）。改用既有的 `phase0/harness/.venv-d45`（`README-venv.md` 記載的解法），
不動系統環境。

### 量測設計

交錯量測，前後緊接（同一段時間窗口內，減少畫面內容/環境雜訊的漂移）：

1. **State A2**（無串流客戶端）：`-clear` → `-enable` → `sleep 20` → `-dump` → `-disable`
2. **State B**（`fps_baseline.py` 拉取 900×2000，20 秒）：`-clear` → `-enable`
   → 前景跑 `fps_baseline.py --seconds 20 --width 900 --height 2000` →
   （其跑完後立刻）`-dump` → `-disable`

量測前後都用 `adb exec-out screencap` 間隔 2 秒比對 MD5，確認畫面持續變化
（非靜止畫面，避免量到假 0）。

### 完整原始輸出

**State A2**（`/tmp/d45-timestats-A2.txt`，本機暫存，未進 repo）：

```
statsStart = 1785831877
statsEnd = 1785831897
totalFrames = 1202
displayOnTime = 20042 ms

displayRefreshRate = 60 fps
renderRate = 60 fps
uid = 10208
layerName = SurfaceView[com.loomgames.pixelflow/com.scopely.unity.ScopelyUnityActivity](BLAST)#128
packageName =
gameMode = Unsupported
totalFrames = 1201
droppedFrames = 0
lateAcquireFrames = 0
badDesiredPresentFrames = 0
...
SetFrameRate vote for this layer:
frameRate = 60.00
frameRateCompatibility = Default
seamlessness = ShouldBeSeamless
averageFPS = 61.780
present2present histogram is as below:
... 9ms=1 11ms=1 12ms=20 13ms=69 14ms=111 15ms=146 16ms=379 17ms=233 18ms=109 19ms=94 20ms=32 21ms=6 ...（22ms 以上全為 0）
```

**State B**（`/tmp/d45-timestats-B.txt`，本機暫存，未進 repo）：

```
statsStart = 1785831908
statsEnd = 1785831928
totalFrames = 1213
displayOnTime = 20230 ms

displayRefreshRate = 60 fps
renderRate = 60 fps
uid = 10208
layerName = SurfaceView[com.loomgames.pixelflow/com.scopely.unity.ScopelyUnityActivity](BLAST)#128
packageName =
gameMode = Unsupported
totalFrames = 1211
droppedFrames = 0
lateAcquireFrames = 0
badDesiredPresentFrames = 0
...
SetFrameRate vote for this layer:
frameRate = 60.00
frameRateCompatibility = Default
seamlessness = ShouldBeSeamless
averageFPS = 61.811
present2present histogram is as below:
... 3ms=1 8ms=1 9ms=1 10ms=2 11ms=2 12ms=14 13ms=47 14ms=76 15ms=170 16ms=465 17ms=253 18ms=95 19ms=48 20ms=27 21ms=4 22ms=1 26ms=2 36ms=1 40ms=1 ...
```

客戶端自己收到的原始輸出（`fps_baseline.py --json`）：

```json
{"status": "measured", "error": null, "fps": 59.93350517569912, "frames": 1199, "elapsed": 20.005504374974407, "width": 900, "height": 2000}
```

### 結果（修正後）

| 狀態 | 視窗（`displayOnTime`） | layer totalFrames | `droppedFrames` | 修正 fps（`totalFrames÷視窗`） | ≥20ms 幀數（占比） |
|---|---|---|---|---|---|
| A2（無客戶端） | 20.042s | 1201 | **0** | 59.92 | 38（3.16%） |
| B（`fps_baseline.py` 拉流） | 20.230s | 1211 | **0** | 59.86 | 36（2.97%） |

客戶端自己收到 `fps=59.93 frames=1199 elapsed=20.01s status=measured`——與 guest
端修正後的 59.86 幾乎一致（1199/1211 = 99.0% 的幀被客戶端收到）。

### 結論（降級後，符合指標本身的侷限）

**在主機 load≈3 的安靜窗口下，有無 `streamScreenshot` 客戶端，guest 均維持
vsync 鎖定、零掉幀**（`droppedFrames` 兩臂皆 0，≥20ms 尾端占比相近，
3.16% vs 2.97%）。

這**不是**「兩者完全沒有差異」的統計顯著性證明——`present2present`／
`droppedFrames` 這兩個指標在安靜窗口下已經頂到 vsync 天花板（見 Step 2 的
下界說明），streamScreenshot 就算真的讓 guest 多做了一點工，只要沒有嚴重到
壓垮 vsync 造成掉幀，這個量法本來就量不出來。能負責任地說的是：**在這個
負載條件下，streamScreenshot 客戶端的存在沒有讓 guest 掉出 vsync 節奏**，
不是「絕對沒有任何負擔」。

可用的雜訊估計：兩個「無客戶端」窗口（首試 59.92、A2 59.92）幾乎完全一致
（差 0.008fps），而唯一的「有客戶端」窗口（B 59.86）比兩者低約 0.06fps
（≈0.1%）。這個差距同一量級也出現在 histogram 尾端占比（3.16% vs 2.97%，
方向相反），不構成一致的方向性訊號，仍在「無顯著差異」的合理解讀範圍內，
但樣本數（n=1 vs n=2）太小，不足以排除微小效應。

**這推翻了 spec §5.1「streamScreenshot 本身會嚴重拖慢 guest 到掉幀」的最壞
情境**，但**沒有**排除「有微小、量不到掉幀程度的額外負擔」這個較弱的版本。
7a 對照組的分母，在這個負載條件下，沒有觀察到因為「Mirage 沒有跑」而被
人為墊高的證據。

### 已知限制

- **這不是字面上的「Mirage.app 跑著」**：headless 客戶端沒有 macOS 端的解碼、
  Metal 貼圖上傳、視窗合成這幾段——那些成本完全沒有被本次 A/B 觸及。
- **只做了一輪**（各 20 秒），沒有重複驗證取多次中位數。
- **在主機 load≈3 的安靜窗口下做**，而 7a 對照組（`RESULTS-d45-probe.md`）
  的量測條件是 load 8–18。本次 A/B 完全沒有觸及「主機 CPU 競爭讓 guest
  錯過 vsync」這條路徑會發作的區間——B 臂拿到的 59.86／客戶端 59.93，比
  `RESULTS-d45-probe.md` 記載的**每一輪**對照組數字都高（那批最高 57.73，
  是在 load 8–18 下量的）。**這代表 A/B 系統性地避開了問題最可能發作的
  負載區間**，見下方「下一步」。

---

## 對「為什麼 fps 只有 49」的說明

這批量測（連同 `app/RESULTS-d45-probe.md` 記錄的 Task 3 數字）讓完整鏈路的三個
節點都有數字了：

| 節點 | fps | 量測方式 | 量測條件 |
|---|---|---|---|
| guest render（本 task，修正後） | ≈59.9（59.86–59.92，穩定，n=3） | `SurfaceFlinger --timestats` | load≈3，選單畫面 |
| 直拉對照組（`RESULTS-d45-probe.md` + 本 task） | **39.29–59.93**（n=23，見下方「數字來源總表」） | `fps_baseline.py` | load ≥8，逐輪負載未逐一記錄 |
| Mirage 全鏈路（`RESULTS-d45-probe.md`） | 原始輪次 **35–60**（n=15）／每次三輪中位數 **35–52**（n=7） | `verify_fps_fullscreen.sh` | load 8–32（不含被排除的污染樣本） |

> ⚠️ **這一節在複審中兩次被抓到數字對不上來源**（第一次是無出處的「47–59fps」，
> 第二次是查無出處的「44.02」，且核對過程中發現本節其餘幾個數字——「9 個獨立
> 輪次 84–103%」、「35/38–60/43/49/52」——也因為 `RESULTS-d45-probe.md` 在本
> task 進行期間被 Task 5 追加了兩批新量測而**過時**，一併重新核對修正。下面
> 每一個數字都能在「數字來源總表」查到精確的檔案:行號。

**guest render 修正後約 59.9fps，緊貼 60Hz vsync 天花板，在本次量測的負載/畫面
條件下沒有觀察到掉幀**——這排除了「guest render 在安靜窗口/選單畫面下是瓶頸」
這個假設。

**但這不能直接解釋「為什麼是 49」**，原因是**負載條件對不上**：

- 本 task 量到「guest→直拉幾乎無損」（1199/1211=99%），是在 load≈3 這個安靜
  窗口下量到的。同一個窗口下客戶端自己收到 59.93 fps，與 guest 的 59.86 幾乎
  一致——**在這個負載下，沒有損失需要解釋**。
- 但 `RESULTS-d45-probe.md` 記載的直拉對照組原始輪次值低至 **39.29**（見數字
  來源總表），是在 load 8 以上（Task 3／Task 5 兩批量測期間主機負載持續在
  8–18、一度到 32）量到的，明顯低於 guest 的 59.9 天花板。
- **本 task 沒有在這種負載下量過 guest**——所以「這些低值是不是因為 guest
  本身在高負載下也開始掉幀」這個問題，**本 task 沒有回答**。可能性有兩種，
  本檔都沒有證據可以排除任一種：
  1. guest 在高負載下依然穩如 59.9，損失全部發生在傳輸/編碼通道或量測方法
     本身（原本的推測方向）；
  2. guest 本身也會被主機 CPU 競爭拖慢、錯過 vsync（如果這樣，`droppedFrames`
     在那個負載下應該不會是 0）——**這是本次 A/B 因為避開高負載區間而完全
     沒有檢驗到的可能性**。

再往下，「直拉對照組」到「Mirage 全鏈路」的比值——**15 個獨立輪次**（不是先前
誤植的 9 個，`RESULTS-d45-probe.md` 累積了四批量測：探測版 3 輪、Task 3 修正後
6 輪、Task 5 補測 6 輪），排序後為 82/84/85/86/89/90/91/93/96/97/103/103/103/
111/118%，**範圍 82–118%，中位數 93%**（來源見數字來源總表）。

⚠️ **這個範圍不能整段當成「Mirage 消費管線的損失」——15 筆裡有 5 筆
（103/103/103/111/**118**）超過 100%，字面上代表「Mirage 比它的上游對照組還
快」，這物理上不可能（Mirage 是對照組的下游消費者），是敘事矛盾。**

機制：`app/scripts/verify_fps_fullscreen.sh:221-234` 顯示 `mirage=` 與
`baseline=` **不是同時量到的**，是先量 Mirage（`sleep "$DURATION"` 後讀
`fps_median`）、**關掉 Mirage**（`gui_session_cleanup`）、`sleep 3`、才開始
量對照組——腳本自己的註解寫明原因：「關掉 Mirage 再量對照組——不並行。兩個
client 同時拉同一條串流，emulator 得做兩份工，量到的是『兩個消費者下的幀率』
而非任一方的能力」。這是刻意的設計（避免兩個 client 搶同一條串流），但代價是
兩側的量測窗口在時間上**先後錯開**，中間隔著「關閉＋3 秒」的空檔。

這台機器的負載在量測期間劇烈波動（`RESULTS-d45-probe.md` 記載實測 8→32），
兩個先後窗口撞上不同瞬時負載是完全可能的：**若 Mirage 那個窗口撞上低負載、
baseline 那個窗口撞上高負載，baseline 會被壓低，ratio 就會 >100%**——不代表
Mirage 真的比上游快，只代表兩個窗口彼此不可比。反過來，若 Mirage 窗口撞上
高負載、baseline 撞上低負載，ratio 會被壓得更低，同一個機制也會讓 <100% 的
數字失真（只是方向相反、字面上看不出矛盾，不會被立刻發現）。

**因此**：82–118% 這整個範圍本身就摻雜了「先後量測撞上不同瞬時負載」這種
量測雜訊，不能整段拿來當「Mirage 消費管線損失」的證據——那個敘事只在兩側
負載條件相近的樣本上站得住。**中位數 93% 是相對可用的估計**（多數樣本落在
85–103% 附近，離群的 118%／82% 各自只有一筆），但它仍然建立在「先後量測、
非同時」這個前提上，不是嚴格意義的「同一瞬間的損失率」。這個結論不受本次
guest render 修正影響（沒有用到有偏差的 `averageFPS` 欄位），是另一個獨立的
量測方法限制。

（`RESULTS-d45-probe.md:172`／`:363` 各自提過一句「含兩次 >100%…屬正常量測
雜訊」，但只斷言結論、沒說機制——上面這段補的就是那個一直沒寫出來的機制。）

**59.9 對驗收線 55 的餘裕該怎麼看**：以量到的 59.9 為基準，55 只低了 8.9%
（`(59.9-55)/55`）；以 vsync 理論天花板 60 為基準，驗收線 7 的「55」相當於
「**全鏈路（guest→直拉→Mirage）總損失不得超過約 8.3%**」（`(60-55)/60`）。
不是「guest 遠高於門檻、有很多餘裕」，而是「guest 本身已經頂到鏈路能給的
上限（vsync），55 這個門檻對整條鏈路的容錯空間本來就很窄」。

**總結**：guest render 已排除是「安靜窗口/選單畫面」下的瓶頸，但**只排除了這一
個節點、在這一種條件下**。guest 在高負載/遊玩中的表現、以及「直拉對照組」到
「Mirage 全鏈路」這段損失各自的成因，都還沒有拆解——這是後續效能債務該去的
方向，也是下面「下一步」建議的實驗要回答的問題。

### 數字來源總表

上面表格與敘述用到的每一個統計數字（範圍、中位數、n），都是從下面這份原始
資料重算出來的，不是手動挑選或憑印象轉述。**這份總表本身就是覆核用的**——
懷疑上面任何一個數字，回這裡查對應的檔案:行號即可。

**15 組獨立輪次（`mirage=`／`baseline=`／`ratio=` 三聯值，含比值計算的完整分母）**：

| 批次 | 輪 | mirage | baseline | ratio | 來源 |
|---|---|---|---|---|---|
| 探測版 | 1 | 52 | 57.09 | 91% | `RESULTS-d45-probe.md:31` |
| 探測版 | 2 | 35 | 41.19 | 84% | `RESULTS-d45-probe.md:32` |
| 探測版 | 3 | 49 | 54.93 | 89% | `RESULTS-d45-probe.md:33` |
| Task 3 run1 | 1 | 49 | 54.23 | 90% | `RESULTS-d45-probe.md:157` |
| Task 3 run1 | 2 | 60 | 57.73 | 103% | `RESULTS-d45-probe.md:158` |
| Task 3 run1 | 3 | 39 | 40.02 | 97% | `RESULTS-d45-probe.md:159` |
| Task 3 run2 | 1 | 38 | 44.43 | 85% | `RESULTS-d45-probe.md:165` |
| Task 3 run2 | 2 | 43 | 45.78 | 93% | `RESULTS-d45-probe.md:166` |
| Task 3 run2 | 3 | 43 | 41.69 | 103% | `RESULTS-d45-probe.md:167` |
| Task 5 run3 | 1 | 57 | 48.08 | 118% | `RESULTS-d45-probe.md:339` |
| Task 5 run3 | 2 | 45 | 52.30 | 86% | `RESULTS-d45-probe.md:340` |
| Task 5 run3 | 3 | 51 | 49.18 | 103% | `RESULTS-d45-probe.md:341` |
| Task 5 run4 | 1 | 38 | 39.29 | 96% | `RESULTS-d45-probe.md:347` |
| Task 5 run4 | 2 | 44 | 39.32 | 111% | `RESULTS-d45-probe.md:348` |
| Task 5 run4 | 3 | 43 | 52.40 | 82% | `RESULTS-d45-probe.md:349` |

由這 15 列直接算出：`mirage` 範圍 35–60（n=15）；`baseline` 範圍 39.29–57.73
（n=15）；`ratio` 排序後 82/84/85/86/89/90/91/93/96/97/103/103/103/111/118，
範圍 82–118%、中位數 93%（第 8 個值，n=15）。

⚠️ **`ratio` 這欄不是同一瞬間的比值**——每一列的 `mirage=` 與 `baseline=` 是
先後量測、不是同時（見上方「再往下」段落對 `verify_fps_fullscreen.sh:221-234`
的說明）。>100% 的 5 筆（103/103/103/111/118）就是這個時間差撞上這台機器
負載波動的直接證據，不代表 Mirage 真的比上游快。

**每次三輪（或單輪）的中位數／代表值——7 次獨立量測**（`RESULTS-d45-probe.md`
的彙總表格，不是原始輪次）：52（`:21`）／35（`:22`）／49（`:23`，探測版三次，
各僅 1 輪）；49（`:150`）／43（`:151`，Task 3 兩次三輪中位數）；51（`:334`）／
43（`:335`，Task 5 兩次三輪中位數）。範圍 **35–52**（n=7），對應 probe.md 自己
「結論」段（`:361`）的「四次 49/43/51/43…連同…52/35/49…合計共 7 次獨立樣本」。

**Mirage 側被排除、不計入任何統計的樣本**（如實記錄為何不用，不是遺漏）：
`MIRAGE_MEDIAN=0`（螢幕鎖定，`:178`／`:191`）、`MIRAGE_MEDIAN=6`／`11`（CPU 負載
飆高污染，`:317`／`:319`）——這些數字**沒有**出現在上面任何一個範圍或中位數裡。

> ⚠️ **全分支最終審查發現的第三類、未被上面兩類涵蓋的落差**：design doc §9
> 表格「驗證跑次」列的配對是 `mirage=50`／`baseline=59.74`（見下段）。`59.74`
> 已被納入下面 baseline 的 n=23，但配對的 `mirage=50` **沒有**出現在上面 n=7
> 的清單裡，也不在本段「被排除的樣本」清單裡——核對後判定這是**遺漏，不是
> 刻意排除**：它不像上面兩類（螢幕鎖定、CPU 負載污染）有明確記載的失效理由，
> 而且它成對的 baseline 值反而被正常採計，兩側處理不一致，找不到任何「這次
> 不算正式三輪流程」之類的排除依據。`50` 落在已記載的 **35–52** 範圍內（併入
> 後 n=7→n=8，中位數仍是 49：35/43/43/49/49/50/51/52 排序後中間兩位平均
> (49+49)/2=49），**不影響任何既有結論**，故本次不回頭改動 `probe.md`／
> `project-review.md` 等處既有的「n=7」／「35–52」措辭，僅在此註明來源與
> 這個不一致，供日後查核。

**直拉對照組（baseline）的額外樣本**——screen-lock 被排除的那批，Mirage 側雖然
無效（=0），但 `RESULTS-d45-probe.md` 明確記載「對照組不需要畫面合成（純
gRPC + 解碼），因此不受影響、數字照常健康」（`:187`），所以這 6 個 baseline
值仍是合法的直拉對照組樣本：44.82／51.78／53.19（`:178`）、
52.26／51.07／52.57（`:179`）。

**`RESULTS-d45-probe.md` 之外的 2 筆**：`59.74`——`docs/specs/2026-08-04-
d45-acceptance-7-remeasure-design.md:333`（design doc §9 表格「驗證跑次」，
早於 probe.md 存在，是促成使用者裁決 `≥55` 保留不改的原始證據之一）；
`59.93`——本檔 Step 4「State B」的 `fps_baseline.py --json` 輸出（本 task
自己量到的，非 probe.md）。

由 15 筆（39.29–57.73）＋這 6 筆（44.82–53.19，皆落在前者範圍內）＋這 2 筆
外部值（59.74、59.93）合併，得到摘要表格所寫的**直拉對照組總範圍
39.29–59.93（n=23）**。

---

## 下一步：決定性實驗（本次未做，螢幕仍鎖定）

審查建議、本檔認同：**在螢幕不鎖定時，於 `verify_fps_fullscreen.sh` 的一輪
量測進行中同步抓 `dumpsys SurfaceFlinger --timestats`**，直接比對「真正的
Mirage GUI 全螢幕跑著、主機在 7a 那種 load 8–18 的真實負載下」guest 有沒有
掉幀。

這比補跑多輪 headless A/B 更有價值——它正好打在本次 A/B 完全沒有觸及的區間
（限制 5）：如果那個條件下 `droppedFrames` 仍是 0，guest render 不是瓶頸這個
結論才算真正在問題會發作的條件下驗證過；如果不是 0，就直接找到了「49」這個
數字的部分成因，而不是繼續往下游猜。

具體做法：
1. 確認螢幕不鎖定、且能維持喚醒（`caffeinate` 或人在旁邊）。
2. 啟動 `dumpsys SurfaceFlinger --timestats -enable`。
3. 立刻接著跑 `app/scripts/verify_fps_fullscreen.sh -r 1 -d 20`（或更長），
   讓真正的 Mirage.app 全螢幕跑著、產生本機的真實負載（含 build/打包/視窗
   合成的 CPU 成本）。
4. 跑完立刻 `-dump`、`-disable`，比對 guest 端的 `droppedFrames`／修正後 fps
   與本檔 A2/B 兩臂的數字。

**不在本次執行**——螢幕鎖定中，依指示不解鎖、不做任何需要 GUI 的操作。

---

## 環境確認記錄

量測前後皆以 `adb exec-out screencap -p` 間隔 2 秒取樣、比對 MD5，確認畫面
持續變化：

```
MD5 (/tmp/d45-s1.png) = 773ace60f4c838a6cd9ca61c9caf5808
MD5 (/tmp/d45-s2.png) = b75a0ad7ef430760258d50d4dfb5f2aa
...
MD5 (/tmp/d45-s5.png) = bd52610bf445a46ba4c8e673066dee13
MD5 (/tmp/d45-s6.png) = 10f417dffbfb023c11a31ac98ff42cee
```

`mCurrentFocus` 全程確認為 `com.loomgames.pixelflow/com.scopely.unity.ScopelyUnityActivity`。

**首試窗口 `displayOnTime=28.156s` 為何比腳本裡的 `sleep 20` 多了約 8 秒**：
首試的 `-enable` 與後續 `sleep 20`／`-dump` 分屬兩次獨立的工具呼叫，中間有
真實的（模型產生下一步指令的）wall-clock 延遲，這段延遲被算進了 SurfaceFlinger
自己記錄的 `displayOnTime` 裡。A2、B 兩臂刻意把整個「`-clear`→`-enable`→
`sleep`→`-dump`→`-disable`」序列包進單一 bash 呼叫，`displayOnTime` 只比
`sleep 20` 多了 42–230ms（純 adb 程序啟動開銷），印證了這個解釋。**不影響任何
數字的可信度**——所有 fps 都是用該次實際量到的 `totalFrames` 除以該次實際的
`displayOnTime`，不是假設的 20 秒，已經把這個差異算進去了。
