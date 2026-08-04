# D45：坐實 guest render fps（7a 對照組分母的前提檢驗）

- **日期**：2026-08-04
- **模擬器**：`emulator-5556`（gRPC `8556`），emulator `37.2.1.0`（system image
  `google/sdk_gphone64_arm64/emu64a:15/AE3A.240806.036/12592187:user/release-keys`），
  AVD 名稱 `mirage-game`
- **遊戲**：Pixel Flow `com.loomgames.pixelflow`（`versionName=0.30.3`
  `versionCode=173`），已跑超過一小時，畫面在關卡選擇/地圖畫面
- **主機負載**：`load averages: 2.91 3.39 3.76`（量測期間，遠低於既有文件記載的
  `load_gate` 門檻）
- **本 task 不需要 GUI**：三個候選方法皆為 `adb dumpsys` 或讀 proto 定義。Mac 螢幕
  在量測期間鎖定（螢幕保護執行中）——依指示未嘗試解鎖，也未執行任何需要 GUI 合成的
  量測。

## 摘要結論

**方法二（`dumpsys SurfaceFlinger --timestats`）可用，坐實成功。**

- guest 端（Pixel Flow 的 Unity SurfaceView）render fps 穩定在 **≈61.8 fps**，
  無論有沒有 `streamScreenshot` 客戶端在拉取，數字幾乎不變（61.780 vs
  61.811，差 0.05%）。
- 這推翻了 spec §5.1 的疑慮：**`streamScreenshot` 本身不會讓 guest 額外做工、
  拖慢它的畫面產生速率**。7a 對照組的分母（「Mirage 沒有跑」時量到的 fps）
  量的仍是同一個 guest render 能力，前提成立。
- `investigation.md` §11.2 的「推論」现在有了直接量測支持，可以升格：guest 的
  出幀速率本身很健康、遠高於驗收線的 55；47–59fps 這個範圍的落差不是 guest
  render 造成的，發生在它之後的傳輸/消費鏈路上（見下方「對『為什麼只有 49』的
  說明」，這部分本 task 未完全拆解）。

方法一不可用（量到空的系統 UI 幀）。方法三依規則跳過（方法二已成功，不需要再試）。
Step 4 的 A/B 對照**已完成**，但用 headless 的方式（見下方說明），不是字面上的
「Mirage GUI 全螢幕跑著」。

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
... 12ms=1 13ms=4 14ms=48 15ms=275 16ms=766 17ms=520 18ms=68 19ms=5 ...
```

**判定：可用。** `layerName` 同時含 `SurfaceView` 與 `pixelflow`，且該 layer
自己的 `totalFrames`、`droppedFrames`、`averageFPS`、`present2present`
histogram 一應俱全——這是 Pixel Flow 自己那個 Unity SurfaceView layer 的實際
出幀統計，不是系統 UI 或全域聚合值。

**驗算 `averageFPS` 的真實意義**：用 `present2present histogram` 手算加權平均
間隔，核對它是否真的等於「這個 layer 的平均出幀速率」而不是別的東西：

```python
buckets = {12:1, 13:4, 14:48, 15:275, 16:766, 17:520, 18:68, 19:5}
total = sum(buckets.values())          # 1687，與 totalFrames 完全吻合
weighted = sum(k*v for k,v in buckets.items())  # 27276
mean_ms = weighted/total               # 16.168ms
fps = 1000/mean_ms                     # 61.849
```

手算結果 **61.849**，與 `dumpsys` 直接印出的 `averageFPS = 61.849` 完全吻合
（誤差 < 0.001）。這證實 `averageFPS` 就是「該 layer 的 present-to-present
平均間隔」換算出來的 fps，直接對應 Pixel Flow 的出幀速率——滿足 brief 的可用性
判準。

⚠️ **一個值得記錄的異常，但不影響下面的相對比較**：`averageFPS ≈ 61.8` 略高於
`displayRefreshRate = 60 fps` 的理論上限。這台模擬器用 `-gpu host`，present
時間戳記在虛擬化環境下可能有量化/抖動誤差（histogram 的 bucket 顆粒度在
20ms 以下是 1ms 一格），導致平均值略微超過 60。這個系統性偏差在下面 A、B
兩次量測中應該同樣存在（同一套機制、同一套量測窗口長度），所以不影響**相對**
比較的有效性，但**不建議把 61.8 這個絕對數字當成「guest 真的能跑贏 60Hz
面板」的證據**。

方法二已給出可用數字，依 brief「試到第一個給得出可用數字的為止」的規則，
**方法三（emulator gRPC 是否暴露統計）跳過，未嘗試**。

## Step 3：方法三 —— 跳過（依停止規則）

未執行。方法二已可用，依 brief 明文的停止規則不需要再試。若未來方法二失效
（例如換一支不用 BLAST SurfaceView 的遊戲），可以回頭檢查
`phase0/harness/gen/emulator_controller_pb2_grpc.py` 裡有沒有幀率/統計相關的
RPC——這件事本次沒有查證過。

## Step 4：A/B 對照 —— 已完成，但改用 headless 方式

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

### 結果

| 狀態 | 視窗 | layer totalFrames | averageFPS | 備註 |
|---|---|---|---|---|
| A2（無客戶端） | 20.042s | 1201 | **61.780** | |
| B（`fps_baseline.py` 拉流） | 20.230s | 1211 | **61.811** | 客戶端自己收到 `fps=59.93 frames=1199 status=measured` |

原始輸出（State B，`fps_baseline.py --json`）：

```json
{"status": "measured", "error": null, "fps": 59.93350517569912, "frames": 1199, "elapsed": 20.005504374974407, "width": 900, "height": 2000}
```

### 結論

**guest render fps 在有無 `streamScreenshot` 客戶端下幾乎相同**（61.780 vs
61.811，差 0.031 fps，即 0.05%——遠小於任何一次量測本身的 histogram 顆粒度）。

**這推翻了 spec §5.1 的疑慮**：`streamScreenshot` 這個 RPC 的存在，不會讓 guest
端的畫面產生速率變慢。7a 對照組「Mirage 沒有跑」時量到的 fps，量的就是同一個
guest render 能力，不是一個因為少了額外負擔而被人為墊高的乾淨基準——**分母是
乾淨的，7a 站得住**。

### 已知限制

- **這不是字面上的「Mirage.app 跑著」**：headless 客戶端沒有 macOS 端的解碼、
  Metal 貼圖上傳、視窗合成這幾段——那些成本完全沒有被本次 A/B 觸及。如果未來
  要驗證「Mirage.app 本身（而不只是它送出的 RPC 請求）是否會透過某種方式回頭
  拖慢 guest」（例如透過某種回饋路徑），需要在螢幕未鎖定的環境下重跑一次
  真正的 GUI 全螢幕 A/B。
- **只做了一輪**（各 20 秒），沒有重複驗證取多次中位數。兩個狀態的差距
  （0.05%）遠小於這類量測正常的 round-to-round 波動（`RESULTS-d45-probe.md`
  記載同一次呼叫內三輪就有 38–60 fps 的散布），信心已經足夠支持「無顯著影響」
  這個結論，但嚴格說不是統計顯著性檢定。
- **61.8fps 略高於 60fps 理論上限**（見 Step 2 的異常記錄）——這是系統性偏差，
  同時出現在 A、B 兩次，不影響相對比較，但不代表 guest 真的能跑贏面板刷新率。

---

## 對「為什麼 fps 只有 49」的說明

這批量測（連同 `app/RESULTS-d45-probe.md` 記錄的 Task 3 數字）讓完整鏈路的三個
節點都有數字了：

| 節點 | fps | 量測方式 |
|---|---|---|
| guest render（本 task） | **≈61.8**（61.78–61.85，穩定） | `SurfaceFlinger --timestats` |
| 對照組／`streamScreenshot` 直拉（Task 3 + 本 task） | 41 / 54 / 57 / 59.74 / **59.93** | `fps_baseline.py` |
| Mirage 全鏈路（Task 3） | 35 / 43 / 49 / 52 | `verify_fps_fullscreen.sh` |

**guest render 本身很健康、遠高於驗收線的 55**，而且本 task 證明它不受
`streamScreenshot` 有沒有客戶端影響——**guest render 不是瓶頸**。

但落差發生在它之後：guest 的 61.8 到「直拉對照組」的 41–59.93 之間，已經有
一段損失，而且**波動很大**（41 到 59.93 有 46% 的擺幅）。由於本 task 已經證明
這段損失不是因為「guest 因為有人在拉串流而變慢」，這個波動的來源必然在
**傳輸/編碼通道本身**（`streamScreenshot` 的 RPC 開銷、序列化、或量測當下的
主機環境雜訊），或是量測方法自身的雜訊——本 task 沒有進一步拆解。

再往下，「直拉對照組」到「Mirage 全鏈路」還有一段（比值 83–103%，多數落在
85–97%），這段損失落在 Mirage 自己的消費管線（解碼、Metal 貼圖上傳、視窗
present）——這與 investigation §11.1 原本的結論方向一致，本 task 沒有新增
證據推翻它。

**總結**：guest render 端已經坐實不是問題所在。真正拖慢到 49 這個數字的兩段
損失（guest→直拉對照組、直拉對照組→Mirage）各自的成因，本 task 都還沒有拆解
到底——這是後續效能債務該去的方向，而不是回頭懷疑 guest 端的畫面產生能力。

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
