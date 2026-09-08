# 驗收線 4：第五輪交付

日期：2026-09-08。狀態：**驗收線 4 判定通過**。兩次跑次各三輪全有效，
產品喚醒（`power suspended-->waking` 至其後第一幀）六輪落在 0.023 到 0.047 秒，門檻 5 秒。
關視窗會讓 app 退出的缺陷已修復。⌘Q 在休眠再喚醒之後仍然無效，記為 D69 未結案。

## 根因證據

PM 在沙箱外確認第一輪 debug、release 建置皆通過，並回傳 PID 95445 的活體紀錄：

```text
[wake-diag] assign-selected-after window=... number=12838 identifier=mirage-mirror mirror=true key=true visible=true delegate=AppLifecycle lifecycle=true
[wake-diag] windowShouldClose return=false action=suspend window=... number=12838 identifier=mirage-mirror mirror=true key=true visible=true delegate=AppLifecycle lifecycle=true
[wake-diag] terminate-window window=... number=12838 identifier=mirage-mirror mirror=true key=false visible=false delegate=AppLifecycle lifecycle=true
[wake-diag] terminate-window window=... number=4294967296 identifier=nil mirror=false key=false visible=true delegate=nil lifecycle=false
[conn] connected --stopRequested--> disconnected
```

同一鏡像視窗的 delegate 指派成功且關窗時仍存在，候選 2 在這次重現中排除。
`windowShouldClose` 回傳 false 並隱藏視窗後仍退出，支持候選 1 的退出政策方向。
`respondsToLastWindowPolicy=true` 不能證明舊政策回傳 true，也不能歸因為 AppKit 預設值。
本輪不需要 LLDB；以明確政策實作與回呼紀錄繼續驗證。

## 修法與診斷

`AppDelegate.applicationShouldTerminateAfterLastWindowClosed` 明確回傳 false。
回呼本身記錄 `event=lastWindowPolicy receiver=MirageShell.AppDelegate return=false`，
同一行的 `appDelegate` 透過 Objective-C `object_getClass` 取得 NSApp.delegate
執行期完整類別名稱，可與 receiver 比較。
PM 已確認 `appDelegate=SwiftUI.AppDelegate`，`NSApplicationDelegateAdaptor` 在中間包了一層，
我們實作的回呼有被轉發到。這也解釋修正前 `respondsToLastWindowPolicy` 已是 true。
這個值是新實作的回傳值，沒有量到舊實作的回傳值。

每筆 `[wake-diag]` 只有一行，前綴後全部是固定順序的 `key=value`：

```text
event appDelegate respondsToLastWindowPolicy isActive mainMenuNil mainMenuItems activationPolicy receiver return action windowCount window windowClass number identifier mirror key visible delegate lifecycle contentView controller level styleMask width height excludedFromWindowsMenu
```

不存在的物件或值印 `nil`，旗標印 `true` 或 `false`。值中的空白、等號及特殊字元
採百分比編碼，解析時先依空白切欄位，再以第一個等號切 key/value，最後 decode 值。
`event` 不夾帶其他欄位，所有事件共用相同欄位集合。
所有診斷與 power log 僅在 `MIRAGE_CONN_LOG=1` 輸出。

PM 已確認第二個視窗是 `windowClass=NSStatusBarWindow`、`level=25`、
`width=39 height=0`，是選單列項目本身，不是遺留視窗。
視窗 visible 不等於它會列入最後視窗政策的判斷。

`applicationWillTerminate` 的 `audioPlayer?.stop()`、detached shutdown、semaphore 等待
保持既有行為。純狀態 `LifecyclePolicy` 管理隱藏後下一次顯示才恢復，避免重複喚醒；
`EmulatorClient.suspend()`／`wake()` 的語意沒有修改。
鏡像 delegate 指派方式維持現狀，這次證據沒有支持變更它。

## PM 執行

先在沙箱外建置、跑測試與 CI，再確認 emulator 已在運作、螢幕解鎖、MirageApp 已正常退出。
量測期間不要操作其他 Mirage 視窗，System Events 需有輔助使用權限。

```bash
cd /Users/hanfourhuang/Projects/mirage/.worktrees/acceptance-4-wake/app
swift build
swift build -c release
/bin/bash scripts/ci.sh
/bin/bash scripts/verify_wake.sh -r 3 -p 8556
```

埠號請沿用 PM 有效設定。腳本不啟動或重啟 emulator、不載入快照。
打包在量測之外；不用 `gui_session_start`，保留其原有 `sleep 6`。
沿用 `verify_common.sh` 的建置及連線檢查、`gui_session.sh` 的鎖定檢查與清理，
以及 `cpu_delta_total` 與 `input_latency_cpu_gate` 的外來 CPU 計算及門檻。

每輪流程：app 未執行 → `open -a` → 第一幀 → 確認 fps 與 delegate 指派紀錄 →
確認前景後送 ⌘W → 等待 suspended → 至少三秒 fps 行數不變且原 PID 持續存在 →
選單列「顯示視窗」→ 新的第一幀 → 選單列「退出 Mirage」→ 原 PID 消失且有退出清理紀錄。
選單退出逾時或缺紀錄也會使該輪無效。失敗輪的 finally 也先走同一選單退出，再由共用函式清理。
PM 對照確認休眠再喚醒後的 ⌘Q 按鍵路徑失效，但選單退出正常，因此退出斷言改驗選單路徑。
這項工具修正不代表產品的 ⌘Q 缺陷已修復。

計時採外部 Python `time.monotonic()`，每 20ms 輪詢 log：

| 欄位 | 起點至終點 | 用途 |
| --- | --- | --- |
| `startup_s` | 呼叫 `open -a` 前至首次觀察到第一幀 | 啟動，包含命令派送與主機負載影響 |
| `wake_s` | 首次觀察到新 `[conn] power suspended-->waking` 至其後新 `[conn] 幀 #1` | 產品喚醒，作為判定依據 |
| `wake_applescript_s` | 呼叫選單 AppleScript 前至同一筆新第一幀 | 舊定義，僅供參考 |

原始碼 `wake()` 先輸出 `suspended-->waking`，因此固定用此轉移，不改用較晚的 active。
喚醒只搜尋送出操作前 log 長度之後的內容，第一幀必須位於新轉移之後。
不是第一個 fps 窗口，也不是實際 present 時間。這是 log 的外部觀察間隔，
輪詢、輸出緩衝與作業系統排程仍會影響精度，不能視為內部精確時間戳。
兩筆同次輪詢出現時 `wake_s=0`、`wake_same_poll=True`，表示無法在該輪詢解析度內區分，並非零延遲。
啟動及喚醒各逾時 10 秒，喚醒逾時包含 AppleScript 派送；缺少轉移或後續新幀皆判無效。
舊 #1、#10、#100 不可充當新第一幀。
CPU 採同一整輪窗口，從啟動前至退出後，floor 10 與 floor 0 共用快照及實際經過秒數；
依既有工具限制，只計兩份快照都存在的 PID，不宣稱能捕捉中途建立又退出的外來行程。

每輪一行包含上述三種秒數、`wake_same_poll`、`quit`、`foreign_cpu_floor10`、`foreign_cpu_floor0`。
summary 分別保留 `wake`、`wake_applescript`、`startup` 的中位數與最小、最大值。
無效輪印 NA 並附原因，繼續下一輪；預設三輪且要求三個有效輪，不以忽略失敗輪補成綠燈。
有效輪的喚醒中位數必須嚴格小於 5 秒，CPU floor 10 必須嚴格小於 50%。
偶數筆中位數取中間兩筆平均。慢於 5 秒的單輪仍參與中位數，不淘汰以美化結果。
`Logs:` 目錄保存每輪 app log、錯誤、原始秒數、有效 JSONL 與打包紀錄。

政策轉送、第二個視窗身分、關窗續存與選單退出已由 PM 確認，接下來重跑三輪以量測產品喚醒區間。

## 已執行驗證

`/bin/bash app/scripts/lib/wake_selftest.sh` 退出碼 0，9 項 Python 測試通過。
五項注入使用正式輪詢與判斷函式，由獨立子行程執行，逐項確認退出碼 1 與具名原因：

| 斷言 | 注入 | 實際結果 |
| --- | --- | --- |
| 1 原 PID 存活 | 真實子行程先退出，再檢查休眠窗口 | exit=1，關視窗退出了，A 沒修好 |
| 2 fps 停止 | 假時鐘第 1 秒新增 fps 行 | exit=1，suspend 沒生效 |
| 3 新第一幀 | 只提供舊 #1 與 #10，假時鐘走完 10 秒 | exit=1，沒有新的第一幀 |
| 4 中位數 <5 | 輸入 4、5、6 秒 | exit=1，中位數必須低於 5 秒 |
| 5 CPU <50 | 輸入 floor 10 =50 | exit=1，CPU 必須低於 50% |

另外測到延後第 2 秒退出、完整三秒安靜窗口、沒有 fps 基準、新幀辨識、
49% 與 4.99 秒邊界、偶數中位數、NaN 及有效輪數不足。
shell 實際使用的 CPU gate 也確認 49 通過、50 回傳非零。
這些是工具層故障注入，沒有故障注入 GUI，也不代替 AppKit 活體驗證。

新增 `LifecyclePolicyTests` 涵蓋最後視窗不退出，以及顯示、隱藏、重複顯示、重複隱藏的恢復狀態。
既有 Swift 測試未修改。NSWindow 隱藏、代理轉送及實際 suspend 已有 PM 活體證據；選單列喚醒也已有第四輪 PM 活體證據；
音訊停止仍待活體確認，純狀態測試不宣稱涵蓋它們。

第二輪本機 `swift build --build-tests` 退出碼 1，manifest 階段出現
`sandbox-exec: sandbox_apply: Operation not permitted`，未進入本版原始碼編譯。
`/bin/bash scripts/ci.sh` 閘門 0 通過，閘門 1 因同一錯誤中止；閘門 2 至 8 未跑。
閘門 7 已接入 wake 自我測試。PM 實跑 `app/scripts/ci.sh` 退出碼 0，九道閘門全綠，
閘門 7 現在跑八支自我測試（verify_common／audio_stats／load_sentinel／guest_fps／gui_session／backpressure／input_latency／wake）。
第三輪 bash 語法與 `git diff --check` 通過。不把第一輪 PM 的建置結果套用到新修改。

## 第三輪修正與 PM 編譯修正確認

J：原本要求 `unlocked`，但未鎖定機器可能沒有 `CGSSessionScreenIsLocked` key，
因此回傳 `unknown`。PM 三輪都被誤判無效，有效輪數 0/3，沒有量到延遲。
現在與 `gui_session_start` 一致，只有 `locked` 判無效，`unlocked` 與 `unknown` 繼續。
新增自我測試執行正式 `verify_wake.sh`，沿用真正的鎖定解析與 summary，
替換 GUI、建置及量測相依項。`unlocked` 與缺 key 的 `unknown` 各進入三次模擬量測，
退出碼皆為 0；注入 `locked` 後三輪皆印 `INVALID screen=locked`，
量測呼叫次數為 0，summary 因有效輪數不足回傳 1。模擬秒數不是活體量測結果。

K：`gui_session_cleanup ''` 是有意只清行程，保留 bundle 給下一輪。
已於呼叫處補註解；最後 EXIT trap 以 `$BUNDLE` 清除打包目錄。

已檢查並保留 PM 在工作樹中的兩項編譯修正：

1. `AppLifecycle.swift` 的寬高改用 `String(format: "%.0f", ...)`，修正 `String(CGFloat)` 編譯錯誤。
2. `LifecyclePolicyTests.swift` 先呼叫 mutating `consumeResume()`，再以 `#expect(resumed)`
   或 `#expect(!resumed)` 斷言，避開巨集把值捕捉進不可變 `$0` 閉包的編譯錯誤。
   PM 留下的註解已保留，沒有改成此 repo 無法可靠報錯的 `#expect(x == true)`。

PM 已編譯並實跑修正版；第三輪本機未重新執行 Swift 建置或完整 CI，沒有執行 GUI。

## 活體數字與判定

以下為 PM 第五輪回報的既有三輪，腳本 rc=0，`quit=clean` 三輪皆通過，floor 10 皆為 0%。

| 路徑與定義 | 逐輪秒數 | 中位數 | 最小至最大 |
| --- | --- | --- | --- |
| 舊喚醒，AppleScript 至第一幀，僅供參考 | 2.290／2.271／2.248 | 2.271 | 2.248 至 2.290 |
| app 未執行時啟動，open 至第一幀 | 1.188／0.467／0.439 | 0.467 | 0.439 至 1.188 |
| 新產品喚醒，power 轉移至第一幀（跑次 A） | 0.042 / 0.025 / 0.023 | 0.025 | 通過 |
| 新產品喚醒，power 轉移至第一幀（跑次 B） | 0.045 / 0.023 / 0.047 | 0.045 | 通過 |
| AppleScript 選單互動（參考，非產品） | 2.18 到 2.23 | 2.19 | 不判 |
| open 到第一幀（安靜機器） | 0.375 到 1.038 | 0.39 到 0.41 | 參考 |

PM 送 ⌘W 後觀察到：

```text
event=windowShouldClose return=false action=suspend key=true mirror=true delegate=MirageShell.AppLifecycle lifecycle=true
[conn] power active-->suspending
[conn] power suspending-->suspended
```

app 持續存活，沒有 terminate，也沒有 stopRequested。關視窗退出 app 的缺陷已修復。
政策回呼轉送及第二個視窗為選單列項目也已確認。
### PM 實跑結果與判定

兩次獨立跑次，各三輪、全部有效、退出乾淨（`quit=clean`），`rc=0`：

| 跑次 | wake_s 三輪 | wake 中位數 | startup_s 中位數 | 外來 CPU floor10 |
| --- | --- | --- | --- | --- |
| A | 0.042 / 0.025 / 0.023 | 0.025 | 0.407 | 29 / 47 / 46% |
| B | 0.045 / 0.023 / 0.047 | 0.045 | 0.382 | 30 / 0 / 0% |

六輪合計 0.023 到 0.047 秒，門檻 5 秒。**驗收線 4 通過**，幅度超過 100 倍。

`wake_same_poll` 六輪皆為 False，代表 power 轉移與第一幀出現在不同次輪詢，
20ms 的輪詢粒度沒有把兩個標記壓成同一點。但量到的值本身只有一到兩個輪詢間隔，
所以這把尺支持的結論是「遠低於門檻」，不足以宣稱毫秒等級的精確度。

`wake_applescript_s` 六輪 2.18 到 2.23 秒，與 PM 單獨量到的 AppleScript 純成本
（視窗已顯示時點同一組選單，`wake()` 因 `guard suspended` 不做事，三次 2.15 / 2.10 / 2.07 秒）
一致。舊定義的 2.27 秒裡約 92% 是量測工具的固定開銷，不是產品延遲。

### 啟動那一段對主機負載極度敏感

安靜機器（外來 CPU floor10 為 0 到 47%）量到 0.375 到 1.038 秒。
但在外來 CPU 約 120%（`ANECompilerService` 佔 100%）的條件下，用同樣的方法
（`open -a` 後輪詢 `[conn] 幀 #1`）量到 3.70 / 4.18 / 5.75 秒，差約 5 倍，
而 5.75 秒已經超過 5 秒門檻。緩衝不是原因：有無 `NSUnbufferedIO=YES`
在安靜機器上都是 0.70 到 1.10 秒。

這一段目前不是驗收線 4 的判定依據（判定的是喚醒），但它是使用者關掉 app 之後
重新開啟時會經歷的路徑，負載敏感度要記著。
⌘Q 另列為產品缺陷 D69，不能以選單退出通過代替驗證。
沒有執行 LLDB 或 GUI，沒有 commit。

## 第四輪 L 修正與 M 量測條件

PM 實跑五組對照，結果如下；這是修正前的證據，不是本版的驗證結果。

| 對照 | 結果 |
| --- | --- |
| 只按 ⌘Q，沒休眠過 | 已退出，willTerminate=1、stopRequested=1 |
| ⌘W 休眠 → 選單「顯示視窗」喚醒 → ⌘Q | 仍存活，willTerminate=0 |
| 同上，喚醒後先按 Esc 再 ⌘Q | 仍存活 |
| 同上，喚醒後等 8 秒再 ⌘Q | 仍存活 |
| 同上，改用選單列「退出 Mirage」 | 已退出，willTerminate=1 |

同次跑次有一筆 `power suspending-->suspended`、一筆 wake 轉移，喚醒後視窗數為 1。
送 ⌘Q 前 `command_key` 的前景驗證成功。Esc 與等待都無效，不能歸因為選單卡住；
未休眠的 ⌘Q 與選單退出正常，也不能歸因為最後視窗政策使 app 無法退出。

`AppLifecycle.wake` 現在於 `makeKeyAndOrderFront` 後呼叫
`NSApp.activate(ignoringOtherApps: true)`，包含單純顯示與休眠恢復兩條路徑。
既有 `wake`、新增的 `wake-before-activate`、`wake-after-activate` 與
`didBecomeActive` 事件都帶 `isActive`、`mainMenuNil`、`mainMenuItems`、
`activationPolicy`。policy 記 raw value：0 為 regular、1 為 accessory、2 為 prohibited。
啟用呼叫後的同步紀錄不保證啟用已完成，因此另觀察 `didBecomeActive` 通知。
第四輪曾嘗試此最小修法；第五輪 PM 已確認 `NSApp.activate(ignoringOtherApps: true)` 無效。D69 維持未結案，本輪不再追查。

M：PM 回報前三輪外來 CPU 為 208 到 250%，全被 CPU 閘門擋下。
PM 查到 Chrome 為 97 + 50.8 + 34.6，合計約 182%，iTerm 約 66%；
當時使用者正在操作瀏覽器，屬於外部環境負載，不是量測工具自身造成。
這些行程數字是 PM 的排查觀察，不視為與每輪快照完全相同的加總。
CPU 閘門照設計運作，第四輪當時沒有三個有效樣本；第五輪 PM 回報已取得上表三輪。本輪不修改 CPU 計算方式或門檻。

第四輪非 GUI 驗證：wake 自我測試 9 項通過，五項故障注入、三種鎖定狀態與
shell CPU 邊界皆通過。沒有執行 GUI，沒有 commit。

第四輪 `swift build --build-tests` 退出碼 1，manifest 階段仍出現
`sandbox-exec: sandbox_apply: Operation not permitted`，尚未編譯本版 Swift 原始碼。
未執行完整 CI；`git diff --check` 通過。

## 第五輪 N、O、P

N：PM 在視窗已顯示、`wake()` 因 `guard suspended` 不做事的條件下，
點同一組選單測得 AppleScript 純成本 2.15／2.10／2.07 秒，範圍 2.07 至 2.15 秒。
相較舊喚醒中位數 2.271 秒，約 92% 是工具操作成本。PM 推估產品約 0.15 至 0.20 秒，
但這不是逐輪配對量測，不把相減估值填入產品結果。第五輪改量上述 power 至第一幀，
同時保留 AppleScript 至第一幀供比較，5 秒喚醒中位數門檻只套用產品區間。

O：`startup_s` 對主機負載敏感。安靜條件下 floor 10 為 0%，三輪為 0.439 至 1.188 秒；
PM 較早在外來 CPU 約 120%、`ANECompilerService` 約 100% 時，以同樣的
`open -a` 後輪詢第一幀方式測得 3.70／4.18／5.75 秒，約差 5 倍，5.75 秒已超過 5 秒門檻。
高負載組是條件對照，不混入通過 CPU 閘門的樣本，也不能宣稱所有負載下啟動都小於 5 秒。
PM 在安靜機器比較有無 `NSUnbufferedIO=YES`，兩者都是 0.70 至 1.10 秒，
不支持把這次差異歸因於輸出緩衝。報告啟動秒數必須連同主機負載條件解讀；
整輪 CPU 平均值也不等於啟動瞬間的負載。

P：PM 確認休眠再喚醒後 ⌘Q 仍無效，activate 嘗試未修復。
喚醒後 `isActive=true`、`mainMenuNil=false`、`mainMenuItems=5`、`activationPolicy=0`，
AX 層 `frontmost=true`、選單列數 2；唯一異常是 `windowCount` 從 2 變成 3，
目前未證實因果。這組 app 視窗計數與第四輪對照中的可見視窗數 1 分開記錄。
選單列「退出 Mirage」正常，五組對照保留於上表及 D69 債務列。D69 未結案，不再往下追。

第五輪非 GUI 驗證：11 項 Python 自我測試通過，涵蓋派送成本排除、舊 log 排除、
轉移前幀排除、同次輪詢與缺少轉移；既有故障注入、鎖定狀態及 CPU 邊界皆通過。
沒有執行 GUI、Swift 建置或完整 CI，沒有 commit。

## D69 結案：⌘Q 沒有壞，壞的是量測方式（2026-09-08 深夜）

先前記載「休眠再喚醒後 ⌘Q 失效、選單退出正常」，並據此把驗收線 4 的退出路徑改用
狀態列選單，腳本自己註明「通過不代表 ⌘Q 已修復」。**那個判定是量測假象。**

失效的是 System Events 的 `keystroke`，不是 ⌘Q。同一個 app 實例、同一個失效狀態下：

| 送鍵方式 | 結果 |
| --- | --- |
| System Events `keystroke "q" using command down` | 行程存活（兩輪皆然） |
| CGEvent（`lib/cgkey.js`，keyCode 12 + command） | 一秒內退出（兩輪皆然） |

另有一輪只送 CGEvent、沒有先送 System Events，一樣有效，排除「前一次按鍵先喚醒了什麼」。

### 定位過程的三個分辨點

1. **同一狀態下用滑鼠點「Quit Mirage」1 秒內退出**，`applicationWillTerminate` 有跑。
   選單動作與整條 teardown 都是好的。
2. **⌘H 同樣失效**，所以不是 Quit 專屬。
3. **⌘W 仍然有效**（`event=windowShouldClose` 次數增加），所以按鍵進得到 app、
   主選單也收得到鍵等價，只有應用選單（Mirage 選單）那幾項不作用。

三個點合起來把範圍縮到「送鍵方式」，而不是產品的任何一層。

先前的五組對照全部用 System Events 送鍵，因此每一組都落在同一個假象裡。
這與 `cgclick.js` 的存在理由同型（System Events 的 `click at` 在某些視窗狀態下完全無效），
只是先前沒有人把那條教訓套到按鍵上。

### 順帶排除的兩個假設

- **`AppModel.wake()` 取 `NSApp.windows.first` 可能不是鏡像視窗**：實測喚醒後
  `windows.first` 仍是鏡像視窗（`mirror=true lifecycle=true`），
  `makeKeyAndOrderFront` 之後 `key=true visible=true`。
- **`windowCount` 從 2 變成 3 是異常**：那是狀態列選單開啟時的暫時視窗，
  下一次 `windowShouldClose` 已回到 2，良性。

### 改動

`lib/cgkey.js` 與 `lib/cgkey_selftest.js`（全程 mock、不送真實事件，兩項突變檢查證明會紅），
由 `wake_selftest.sh` 在 ci.sh 閘門 7 執行。`wake_probe.py` 的退出路徑改回 ⌘Q，
**驗收線 4 因此才真正驗到使用者會走的那條路**；選單路徑保留給 finally 的清理。

實跑證據：兩次獨立的 VALID 輪次皆 `quit=clean`，wake_s 0.023 與 0.024。

⚠️ **沒有取得 3/3 全綠的跑次**。guest 要有變化畫面才會出幀（D59），而唯一的動態內容是
Unity 遊戲，它讓 emulator 吃掉約 110% CPU，`foreign CPU < 50%` 這道閘門把 emulator
算成外來負載，六輪只有一輪過閘門。這是環境限制不是產品紅燈，
但也代表這條驗收線在 guest 跑遊戲時很難取得有效輪次，與 D67 同一個形狀。
