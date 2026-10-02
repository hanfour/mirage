# 設定頁「降低卡頓」開關，預設開啟兩幀佇列

2026-10-02

## 背景

D64：遊戲畫面忙碌時，emulator 送來的幀抵達時間不均勻，同一個螢幕刷新（16.7 ms）內偶爾收到兩幀。Mirage 現在的幀接收端 `LatestFrameBox` 只留最新一幀，前一幀被覆蓋，下一個刷新又沒有新幀可畫，畫面一跳一停。兩幀佇列 `FrameQueue(depth: 2)` 已實作，只能用環境變數 `MIRAGE_FRAME_QUEUE=2` 開啟。

2026-10-02 用 Brotato 實測（同一局遊戲、波與波之間切換，丟幀率＝dropped ÷ arrived）：

| 接收端 | 丟幀率（不截圖段） | 丟幀率（截圖段） | 抵達→上屏延遲 p50／p95（不截圖段、load 8–9） |
| --- | --- | --- | --- |
| latest（現況） | 0.6–10.1% | 4.7–12.3% | 13–14／15 ms |
| queue2 | 0–0.3% | 0–3.9% | 26–32／28–34 ms |

佇列換來幾乎不掉幀，代價是多約一幀（13–19 ms）的顯示延遲。使用者決定：設定頁加開關，預設開。

## 行為

### 決定接收端的順序

1. 環境變數 `MIRAGE_FRAME_QUEUE` 有設且是整數：
   - `0` 或 `1`：`LatestFrameBox`
   - `≥ 2`：`FrameQueue(depth: N)`
2. 環境變數有設但不是整數（含空字串）：忽略它，照第 3 步決定，並印一行說明（`[app] MIRAGE_FRAME_QUEUE=<值> 不是整數，改用設定`）。這是行為變更：原本空字串與非整數都直接當 latest。
3. 沒有環境變數：讀使用者設定 `smoothFrames`。`true` → `FrameQueue(depth: 2)`，`false` → `LatestFrameBox`。

`smoothFrames` 從未設定過時視為 `true`（預設開）。

啟動 log 照舊印 `[app] frame sink=<label>`，後面加上來源：`（設定）` 或 `（MIRAGE_FRAME_QUEUE）`。例：`[app] frame sink=queue depth=2（設定）`。

### 生效時機

接收端在 `AppModel` 建構時決定，`Renderer` 與 `EmulatorClient` 都拿同一個物件，執行中不替換。開關改了之後**重新開啟 Mirage 才生效**，設定頁要寫明。

## 儲存

沿用 `LaunchPreferences`（UserDefaults，測試用獨立 suite）：

- key：`mirage.display.smoothFrames`
- `var smoothFrames: Bool`：讀時 `defaults.object(forKey:) == nil` 回 `true`，否則 `bool(forKey:)`
- 測試要涵蓋：未設定回 true、設 false 後回 false、再設 true 回 true。

## 純函式

`FrameSinkFactory`（MirageCore）改成：

```swift
public enum FrameSinkSource: Equatable { case setting, environment }
public static func make(environment: [String: String], smoothFrames: Bool)
    -> (sink: any FrameSink, source: FrameSinkSource, warning: String?)
```

保留 `label(for:)`。舊的 `make(from:)` 移除，呼叫端只有 `AppModel`。

`FrameSinkFactoryTests` 改寫成一張表，至少涵蓋：

| environment | smoothFrames | 期望 |
| --- | --- | --- |
| 無 | true | queue depth=2，source=setting，warning nil |
| 無 | false | latest，source=setting |
| `"0"` | true | latest，source=environment |
| `"1"` | true | latest，source=environment |
| `"2"` | false | queue depth=2，source=environment |
| `"3"` | false | queue depth=3，source=environment |
| `""` | true | queue depth=2，source=setting，warning 非 nil |
| `"abc"` | false | latest，source=setting，warning 非 nil |

型別判斷先算成 Bool 再 `#expect`（見既有測試寫法），不要寫 `#expect(x == true)`。

## 設定頁

`SettingsWindow` 在「AVD 設定」之前新增一個 Section「畫面」：

- `Toggle("降低卡頓", isOn: …)`，綁 `LaunchPreferences.smoothFrames`。
- 說明文字（`.font(.caption)`、次要顏色）：「遊戲畫面忙碌時減少跳幀，畫面會多約一幀（約 15 ms）延遲。重新開啟 Mirage 後生效。」
- 若本次啟動的接收端來自環境變數，另加一行：「目前由 MIRAGE_FRAME_QUEUE 環境變數決定，這個開關暫時不影響。」

開關怎麼接到 `LaunchPreferences`：照 `SettingsWindow` 既有 Section 與 controller 的模式，挑最少改動的方式。`AppModel` 已持有 `launchPreferences`。

## 驗證腳本

`scripts/verify_fps_fullscreen.sh`：

- `-A` 交錯量測的 latest 那一臂目前不設 `MIRAGE_FRAME_QUEUE`。預設改開之後，它會變成 queue2，兩臂一樣。改成明確傳 `MIRAGE_FRAME_QUEUE=1`。
- 沒有 `-q`、沒有 `-A` 的一般量測：不傳 `MIRAGE_FRAME_QUEUE`，量的是產品預設（現在是 queue2）。在輸出的說明或 log 檢查處註明這件事。
- 檢查 log 的 `[app] frame sink=` 行的地方，配合新的來源後綴調整解析（後綴不影響判斷 latest／queue）。

## 文件

- `docs/specs/2026-07-29-project-review.md` 的 D64 列：補上 2026-10-02 的重現條件（Brotato 第 4 波以後）與上表數字，狀態改為「已處理：設定頁開關，預設開」。
- `app/RESULTS-d64-queue.md` 末尾加一節「2026-10-02 Brotato 實測」，內容同上表，註明量測限制：每臂 2–3 波；第二局主機有外來負載（load 8–17）；延遲數字約有 ±5 ms 的不確定。

## 不做

- 執行中即時切換接收端。
- 佇列深度可調（固定 2）。
- 手機遙控那條路徑的佇列（`BroadcastFrameSink` 的 secondary 維持 `LatestFrameBox`）。

## 驗收

1. 單元測試：上面兩組（`LaunchPreferences`、`FrameSinkFactory`）通過；ci.sh 全綠。
2. 實機（PM 做）：
   - 不設環境變數、全新的 UserDefaults suite 或刪掉 key 後啟動，log 為 `frame sink=queue depth=2（設定）`。
   - 設定頁關掉開關、重開 Mirage，log 為 `frame sink=latest（設定）`。
   - `MIRAGE_FRAME_QUEUE=1` 啟動，log 為 `frame sink=latest（MIRAGE_FRAME_QUEUE）`，設定頁顯示環境變數那行說明。
   - 測試後把使用者的設定還原為開。
