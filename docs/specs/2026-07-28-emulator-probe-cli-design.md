# 設計：emulator probe CLI（開發期驗證工具）

- **日期**：2026-07-28
- **狀態**：設計已核准，待實作計畫
- **定位**：**內部開發工具，不是產品的一部分**。母計畫 §1 明確寫「開發者用途不是本專案的目標」——本工具服務的是我們自己的驗證流程，不會出現在使用者手上。

## 1. 為什麼需要它

2026-07-28 這一輪修好了四個擋在 Phase-1 前面的 bug（見
`2026-07-28-mirror-never-rendered-investigation.md`）。四個之中有三個是這樣被發現的：
**寫完程式碼、請使用者親自跑一次、他回報「畫面是黑的」／「點擊不準」／「遊戲進不去」。**

每一次來回都要人在場。而其中兩個問題（黑畫面、座標偏移）**只要能自動抓一張畫面看一眼
就能立刻判定**。工具化這件事，等於把驗證迴圈從「等人回報」變成「當場確認」。

同一輪還暴露了幾個具體的操作陷阱，每一個都造成實際的錯誤結論。它們構成本工具的硬性約束
（§4），因為註解攔不住，只有「工具做不到」才攔得住。

## 2. 範圍

### 做

一支 CLI，提供操作模擬器與取得畫面的最小原語，讓 Claude session 能自行完成
「開遊戲 → 操作 → 看畫面 → 判斷」的迴圈。判斷交給 vision，工具只負責取得可判斷的素材。

### 不做

- **高階驗收劇本**（`verify-playable <pkg>` 之類）。「畫面對不對」終究要 vision 判斷，
  包成劇本只會綁死流程，而流程每次都不一樣。
- **fps 量測**。`app/scripts/verify_game_fps.sh` 已經負責這件事，不重複。
- **MCP server**。CLI 能做的事一樣多，且零設定、使用者自己也能直接跑來重現問題。
- **會玩遊戲的 agent**。那是獨立的子專案，見 §8。

## 3. 介面

```
probe.py --target {game|bench|poc} <command> [args]
```

### Target（顯式必填，無預設值）

| name | device | gRPC | 用途 |
|---|---|---|---|
| `game` | `emulator-5556` | 8556 | Play Store 已登入 — **唯一能實際玩遊戲的機器** |
| `bench` | `emulator-5558` | 8558 | AOSP、無 Google 帳號 — 只能量效能，遊戲會卡在載入畫面 |
| `poc` | `emulator-5554` | 8554 | 共享實例，**不得殺／重啟** |

### Commands

| 指令 | 行為 |
|---|---|
| `launch <pkg>` | 啟動並輪詢至前景確認，逾時 **30 秒**（Pixel Flow 在 `game` 上實測載入需數分鐘，但那是 splash 之後的事——本指令只確認 activity 到前景，不等遊戲載完）；逾時則印出當下前景是什麼 |
| `fg` | 印目前前景 activity |
| `tap <nx> <ny>` | normalized 座標（0–1，左上原點） |
| `swipe <nx1> <ny1> <nx2> <ny2> [ms]` | 同上，`ms` 預設 300 |
| `shot <out.png> [--via grpc\|adb]` | 抓畫面，預設 `grpc` |
| `compare <prefix>` | 同時抓兩條路徑 → `<prefix>-grpc.png` / `<prefix>-adb.png` |
| `overlay {on\|off\|restore}` | 見下方說明 |

**`shot` 的解析度**：兩條路徑一律抓 **guest 實體解析度**（由 `getStatus` 的 `hw.lcd.*` 取得，
與 `EmulatorClient` 同一個來源）。**刻意不提供 `--width/--height`**——縮放後的畫面拿來判讀
座標會再製造一次 §10 那種尺寸混淆，而判讀畫面內容本來就該用原尺寸。

**`overlay` 三個動作的差異**（必須明確，否則會像本輪一樣忘記還原）：

- `on` — 開啟疊層，**並把開啟前的原值寫入狀態檔**（`~/.mirage-probe/<target>-overlay`）
- `off` — 直接關閉（設為 0），不管原值是什麼
- `restore` — 讀狀態檔還原成 `on` 之前的值；沒有狀態檔就是 no-op

`on` 與 `restore` 配對使用。`off` 只在「就是要它關掉」時用。

座標一律 normalized，與 `EmulatorClient.sendTap(nx:ny:)` 同一套語意——工具與產品不會養出
兩種座標習慣。（那正是 §10 那個 bug 的溫床。）

### `compare` 為何值得獨立成一個指令

它不是便利包裝，而是把一個**不直觀、容易漏掉的診斷動作**固化下來。這一輪三個關鍵突破都
來自兩條路徑的對照：

- guest 端是純藍 splash（adb），而我一直盯著 Mirage 看 → 才知道遊戲卡在 guest
- `overlay on` 之後抓圖讀得到十字線 → 才找到驗證觸控座標的方法
- Python harness 量到 30.4 fps vs Mirage 側 20–35 → 才排除 Mirage 是效能瓶頸

> ⚠️ **2026-07-28 實測推翻的前提（本節原文已更正）。**
>
> 本節原本把「`adb screencap` **不含** `pointer_location` 疊層、gRPC **含**」
> 列為 `compare` 存在的理由之一，並要求「輸出必須明講含／不含 overlay」。
> **那個前提是錯的**，而工具照著它在輸出上蓋了一個從來沒被觀察過的斷言。
>
> 在 `bench` 上以**同一條路徑切換疊層**實測（`overlay off` → 抓圖 →
> `overlay on` → 抓圖，逐列比對）：
>
> | 路徑 | 切換疊層後出現差異的列 |
> |---|---|
> | `adb exec-out screencap` | row 136–167 |
> | gRPC `getScreenshot` | row 136–167 |
>
> **兩條路徑都含疊層**，位置還一模一樣。畫面靜止時，兩條路徑真正的差異只有一個：
> gRPC 幀在頂端中央 **row 34–101 有一個黑色圓形**（螢幕挖孔遮罩），adb 那張沒有。
>
> 所以 `compare` 仍然值得獨立成一個指令，只是價值不在它原本宣稱的地方。修正後的
> 做法是：**工具不再印任何關於內容差異的信念，改成當場比一次再報告**——尺寸是否
> 相同、有沒有像素差異、差在哪些列。標籤只描述**路徑**
> （`grpc: getScreenshot` / `adb: exec-out screencap`），不描述內容。
>
> 為了讓「比一次」成立，adb 那條改抓 **raw framebuffer**（`exec-out screencap`，
> **不帶 `-p`**）而不是裝置自己編的 PNG：兩條路徑一律得到 RGBA、一律用同一支
> encoder 寫檔，像素差異才是唯一的變因。（否則要比對就得自己寫一支 PNG 解碼器，
> 而寫半套只會製造新的錯誤結論。）代價是 raw 要搬 10.4 MB、`exec-out` 實測 5.3–6.2 秒（三次量測），
> 裝置自編的 PNG 約 1 秒——**刻意接受**：`shot` 預設走 gRPC（約 0.6 秒），adb 這條
> 是 gRPC 出問題時的備援與 `compare` 的對照組，不是熱路徑。
>
> ⚠️ 兩張圖**不是同時抓的**（前後相隔數秒），畫面在動時內容本來就會不同，輸出會
> 註明這件事。這不是理論顧慮：實測時 `overlay on` 之後立刻跑 `compare`，疊層剛好
> 在兩次抓取之間才畫上去，row 136–167 就多出一段看起來像「路徑差異」的假差異。

## 4. 硬性約束（全部來自本輪的實際失誤）

1. **永不呼叫 `screencapture`**，只從 adb / gRPC 取畫面。
   `screencapture -R` 抓的是螢幕區域而非視窗內容，Mirage 不在最上層時會拍到使用者桌面上
   的任何東西——本輪誤拍兩張（一份簡報、一段私人對話）。把它變成「工具做不到」。
2. **`--target` 無預設值。** 本輪照 `verify_game_fps.sh` 的預設用了 `bench`，測了整輪
   「能不能玩」才發現那台沒有 Google 帳號、遊戲根本進不去。
3. **不提供 `getevent`。** 本輪用它讀觸控座標時沒換算裝置的 ABS 範圍（max=32767），
   把 raw 8191 誤讀成滿值而得出**完全相反**的結論；重跑兩次還都抓不到事件，才發現第一次
   那筆是先前 swipe 的殘留。要驗座標請用 `overlay on` + `shot` 讀十字線——那條路徑本輪
   驗證過是準的（送 `Touch(270,600)`，十字線落在 `(270,599)`）。
4. **`overlay on` 必須先記錄原值**，`overlay restore` 還原。本輪開了兩台機器的疊層，
   全靠自己記得關。

## 5. 輸出格式

給 Claude 讀，所以簡短、路徑明確、不用 ASCII 表格：

```
$ probe.py --target game launch com.loomgames.pixelflow
launched, foreground=com.loomgames.pixelflow/com.scopely.unity.ScopelyUnityActivity (3.2s)

$ probe.py --target bench compare /tmp/x
grpc: getScreenshot → /tmp/x-grpc.png  1080x2400  16559 bytes
adb: exec-out screencap → /tmp/x-adb.png  1080x2400  15543 bytes
diff: 68/2400 列有像素差異，落在 row 34–101
note: 兩張圖非同時抓取（前後相隔 6.1s 內），畫面在動時內容本來就會不同
```

標籤描述的是**取得畫面的路徑**，不是畫面內容有什麼差別——內容差異由 `diff` 那行報告，
而那行是當場量出來的。理由見 §3 那段實測更正。

## 6. 錯誤處理

三種失敗必須能分辨——本輪三種都遇到過，而且一開始分不出來：

| 情況 | 訊息 |
|---|---|
| 裝置不在線 | `device emulator-5556 offline (adb devices 看看)` |
| gRPC 連不上 | `grpc localhost:8556 unreachable` |
| 連上但抓不到幀 | `connected but no frame in 5s — streamScreenshot 是變化驅動的，畫面靜止時不出幀` |

最後一條的提示文字是刻意的：change-driven 這個坑本輪踩了三次
（量到 1–2 fps、launcher 12.7 fps、`animate.py` 那筆 3.3 fps 的失敗量測）。

## 7. 位置與依賴

`tools/probe/probe.py`。不放 `app/scripts/`（那裡是 shell 驗收腳本），也不放 `phase0/`
（那是歷史性的技術驗證）。

gRPC 需要 pb2 生成碼，`phase0/harness/gen/` 已有，`phase0/harness/.venv` 也已備妥 grpc
套件——**重用，不重新生成**，透過 `_bootstrap.py` 設定 `sys.path`。

> ⚠️ 這是刻意接受的暫時耦合。`phase0/harness` 實質上已經是本專案的 gRPC 工具箱，
> `phase0` 只是歷史名稱。它哪天搬家，`_bootstrap.py` 要跟著改。

### 測試

工具本身以實際使用驗證，但兩塊純邏輯要有單元測試，因為它們錯了會靜默給出錯誤結論：

- **target 解析**：name → (device, port)。錯了會像本輪一樣測錯機器。
- **normalized 座標 → 像素換算**：錯了會像 §10 那個 bug 一樣，點擊靜默偏移。

## 8. 與「會玩遊戲的 agent」的關係

使用者提出希望有能玩遊戲的 agent，動機是**讓 fps 與順暢度的量測建立在真實負載上**——
目前量到的數字用的是 `adb shell input swipe` 反覆滑動，那是人造負載，且量的是主選單而非
關卡內。這個動機成立。

那是獨立的子專案，且**依賴本工具**（任何會玩遊戲的 agent，底下都是這幾個原語）。

**先做本工具的關鍵理由不是「循序漸進」，而是它能回答「B 值不值得做」**：

本工具完成後即可把遊戲帶進關卡內、抓幀、量 fps。若關卡內的 fps 與主選單相當
（都在 30 上下），則瓶頸已確定在 guest 端、與怎麼玩無關，**B 對「量 fps」這個目的就不必做**。
反之若關卡內明顯更差，B 才有明確的靶。現在我們不知道是哪一種。

至於「訓練 agent 玩遊戲」作為目標本身（而非為了量 fps），完全可以立項，
但它該用自己的理由立項，不該掛在 fps 量測底下。

## 9. 驗收

1. 能在 `game` 上啟動 Pixel Flow 並確認前景
2. `compare` 能報出兩條路徑的**實測**差異（而不是宣稱差異）：畫面靜止時只差
   **row 34–101**——gRPC 幀有螢幕挖孔的黑色圓形遮罩，adb 那張沒有
3. `tap` 送出的座標，在 `overlay on` 下用 `shot` 讀到的十字線位置與送出值相符
4. 三種錯誤情況各自給出可分辨的訊息
5. target 解析與座標換算兩塊有單元測試

> ⚠️ **第 2 條已於 2026-07-28 更正。** 原文是「`compare` 產出的兩張圖能看出
> overlay 的有無差異」，而當初拿來當證據的是**檔案大小差 19.2%**（疊層全關時
> grpc 132 KB vs adb 162 KB）。那不是內容差異，是**編碼器差異**——一邊是我們自己
> 的 `png.encode_rgba`、另一邊是裝置上的 PNG 編碼器，差異連正負號都不固定。
> 兩條路徑其實**都含**疊層（見 §3 的實測表）。現在兩條路徑共用同一支 encoder，
> 檔案大小才可比，而驗收改以逐列比對的結果為準。
