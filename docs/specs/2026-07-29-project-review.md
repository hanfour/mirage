# 全專案回顧：Phase-1 的真實狀態與債務清單

- **日期**：2026-07-29
- **方法**：三個獨立審查（架構健康度、文件與實際的落差、母計畫進度與債務）並行，關鍵宣稱由主控端逐一驗證
- **為什麼需要這份文件**：`grep -rn "TODO\|FIXME\|HACK"` 在所有第一方碼裡回傳 **0 筆**。債務全部寫在散文裡（doc comment 與 RESULTS markdown），任何人 grep 會得出「這個 repo 沒有債」的嚴重錯誤結論。這份文件是那個問題的直接修正。

---

## 0. 最重要的一件事：一個系統性的誤診模式

**這個專案反覆把「功能不存在」記成「pending-human 待人眼驗證」。** 已知四次：

| 項目 | 文件記載 | 實際 |
|---|---|---|
| 鏡像顯示 | 「螢幕鎖定 → pending-unlock」 | 從未運作過，根因是 NSException 打死 MainActor（§6） |
| overlay 編輯器 | 「拖放手感 pending-human」 | 不能拖——全 `MirageShell` 零 `DragGesture` |
| 鍵盤直通 | **任何文件都沒提過** | `sendKey` 全碼庫零呼叫端 |
| 內建 profile | 「佔位，待綁真 package」 | `Package.swift` 無 `resources` 宣告，SPM 看不到那個檔案 |

三次躺在標著「已完成」的 RESULTS 文件裡。**這意味著現有的交付清單不可信**，而它正是排優先序的依據。

> **第 0 步：把所有 `pending-human` / `pending-unlock` 逐項重新分類為
> 「做了沒驗」或「根本沒做」。** ✅ **已執行，結果見 §8（2026-07-29 同日）。**
>
> 兩點修正本節：
> 1. 誤診數字應為**六類**不是四類——多出兩項「已修好但文件還寫著 pending」（§8 C 節）。
> 2. **兩個分類選項不夠。** 實際存在第三類：**「阻礙已消失，但沒人回頭驗」**——
>    所有掛在「螢幕鎖定」下的項目，在 NSException 修好的那一刻就不再被擋住了，
>    但它們在清單上長得跟「被外部條件擋住」一模一樣，於是每一輪都被合理地跳過。
>    這一類橫跨十餘筆，是本次稽核最大的單一收穫（§8 D 節）。

---

## 1. NIO 卡死：既有歸因是錯的（已驗證）

> **狀態更新（2026-07-29 同日）：D1／D8 已修並驗收通過。** 修法與本節推測的方向一致，
> 但根因比「關閉順序」更具體：**顯示串流從來沒有可取消的 call handle**。
> `GrpcStreamTransport` 用便利方法 `client.streamScreenshot(_:)`，它丟棄底層的
> `GRPCAsyncServerStreamingCall`；MMAP 與音訊兩條路徑早就改用 `make*Call` 了，唯獨這條
> **預設開啟**的沒改。於是 `dropChannel()` 永遠帶著一個未解決的 promise 去拆 group。
>
> 兩份獨立 stack sample 顯示：**剛好 8 條**（= 核心數）cooperative 執行緒全部阻塞在
> `dropChannel → channelBox.setter → GrpcChannelBox.deinit → syncShutdownGracefully
> → semaphore_wait_trap`，同一時刻 NIO 的 event loop 執行緒全部閒置在 `kevent`。
> 也就是說 group 不是「關得慢」，是根本沒開始關，而池已被自己佔滿。
>
> | | 修正前 | 修正後 |
> |---|---|---|
> | 5 跑結果 | **3 卡死 / 2 通過** | **5 通過** |
> | `Cannot schedule tasks…` | 通過的兩跑各 3 行、5 行 | **每跑 0 行** |
> | 乾淨跑次 | **0 / 5** | **5 / 5** |
>
> **一個必須寫下來的陷阱**：「0 行 ERROR」單獨拿來當驗收訊號是**瞎的**。
> 那行的語意是「pool 想在已關閉的 loop 上排程」——如果 group 根本沒被關掉，也一樣不會有這行。
> 換句話說它同時相容於「修好了」與「靜默洩漏 NIO 執行緒」。補了
> `ChannelTeardownTests`（opt-in，`MIRAGE_THREAD_AUDIT=1`）直接數行程執行緒，
> 同時斷言「拆除不阻塞呼叫端」與「執行緒真的收斂」，才把這個盲區補起來。
> 實測：12 條 channel 的 `shutdown()` 全部發出耗時 <100ms，執行緒在 50ms 內收斂回基準。

**記憶與 `RESULTS-shell-target.md` 記載**：「測試會建真 channel，需要抽可注入 channel」。

**實際機制**（審查者在套件卡死時抓的 process sample）：

```
8 條 cooperative 執行緒全部停在：
  EmulatorClient.dropChannel()  →  channelBox.setter
    →  EventLoopGroup.syncShutdownGracefully()
      →  _dispatch_semaphore_wait_slow  →  semaphore_wait_trap
```

主控端驗證的兩個前提：

- **`channel.close()` 全專案零呼叫**（唯一的 `.close()` 是 `MmapBuffer` 的 munmap，不相關）
- **`GrpcStreamTransport.swift:34` 的 `deinit { try? group.syncShutdownGracefully() }` 確實存在**，且在 actor 隔離下同步阻塞

**真正的機制**：pool 沒關就把 group 關掉，而且用阻塞式關法、在 cooperative 執行緒上跑。8 核 → 8 條執行緒全被佔死 → 套件永遠不會結束。每次跑得完的 run 也都印 3–4 行
`Cannot schedule tasks on an EventLoop that has already shut down`，那是同一件事的另一個症狀。

**這在產品路徑上一樣會發生**：`AppDelegate.swift:47-52` 用 semaphore 卡住主執行緒、
`AppModel.swift:315` 補 200ms sleep——那就是同一個問題在使用者按 ⌘Q 時的補丁。

**修法**：`channel.close()`（等 future）→ `group.shutdownGracefully(queue:)`（回呼式，不阻塞）。
`dropChannel()` 呼叫它，deinit 只留最後防線。**半天，不動任何公開介面或既有測試。**

> 「以為要抽可注入 channel 這種大重構」正是這件事卡了三個階段沒人動的原因。
> 那個方向不算錯，但它不是最小解，而錯估成本讓它一直排不進來。
>
> **驗收要用直接觀察**：連跑 5 次 `swift test`，斷言「5 次都跑完」且該 ERROR 出現 0 次。
> 目前基準：審查者 7 次跑有 3 次卡死，乾淨跑完的每次也都印那行 ERROR。

---

## 2. 債務清單

優先序欄位是建議，不是承諾。成本是粗估。

| # | 是什麼 | 擋住什麼 | 成本 | 序 |
|---|---|---|---|---|
| ~~**D1**~~ | ~~**NIO 關閉順序 + 阻塞式拆除**（見 §1）~~ | **✅ 已修（2026-07-29）**。`GrpcChannelBox.shutdown()`：先 `channel.close()`、再回呼式 `group.shutdownGracefully(queue:)`，全程不阻塞；`dropChannel()` 顯式呼叫。驗收 5/5 乾淨 | 實際約半天 | — |
| ~~**D2**~~ | ~~**鍵盤直通零實作**~~ | **✅ 已修（2026-07-29）**。`KeymapController` 依 `KeymapEngine.handles(_:)` 分流：profile 沒綁的鍵走 `sendKey` 直通。換算抽成 `MirageCore.KeyTranslate` 純函式；⌘ 組合不直通；Esc→GoBack；主畫面／最近任務走選單列。傳輸路徑由活體實測選定（`key` 十個鍵全通，`.mac` 送不出字母 a——proto3 的 0 是預設值不序列化）。驗證用 `getevent` 當儀器 | 實際約半天 | — |
| ~~**D3**~~ | ~~**8 處活體測試用 `guard/return`**~~ | **✅ 已修（2026-07-29）**。全數改用 `@Test(.enabled(if:))`，env 閘門集中到 `Tests/MirageCoreTests/LiveGate.swift`。未設 env → 如實顯示 skipped 並附原因；設了 env → 照跑（已雙向驗證） | 實際約 1 小時 | — |
| ~~**D4**~~ | ~~**內建 profile 沒進 bundle** + `AppModel.gameId` 寫死~~ | **✅ 已修（2026-07-29）**。`Package.swift` 補 `resources: [.copy("Resources/profiles")]`、資源搬進 target 目錄；`BuiltInProfiles.seed` 首次啟動複製（永不覆寫）；刪掉寫死 `gameId` 的死路徑（其註解「尚未有偵測機制」自 P1-d 起就已過期）。**但記載的「指標遊戲沒有可用 profile」查證後不成立**——Pixel Flow 是點擊／拖曳型，不需要 keymap，見設計文件 §1.3。**`.auto` 端到端仍無自動驗證**（範例 profile 不對應真實 package），已如實記入 §8 D | 實際約半天 | — |
| **D5** | **overlay 編輯器不能拖**（29 行，只有存檔按鈕） | 母計畫交付項；鍵位映射是產品命根子但使用者改不了 | 2–3 天 | **P1** |
| ~~**D6**~~ | ~~**輸入無順序保證**——每個事件各開一個 unstructured Task。兩種資料形態：(a) 觸控 `TouchFrame` **全狀態快照**被晚到的舊快照覆蓋；(b) 鍵盤直通**邊緣事件** down/up 對調＝**永久卡鍵**，且無自癒路徑~~ | **✅ 已修（2026-07-30）**。新增 `MirageCore.InputQueue`：一條 `AsyncStream` ＋ **單一**消費者 Task。順序保證來自「只有一條消費路徑」這個結構，不是序號比對也不是重試——那些都是亂序**發生之後**才補救。佇列由 `AppModel` 持有、**一台 guest 只有一條**：`KeymapController`（直通鍵＋觸控快照）、`MirrorView.Coordinator`（滑鼠 tap）、選單列 Android 實體鍵全走它；每個呼叫端各自一條的話，每條內部有序、彼此之間仍然無序，切換 profile 的瞬間照樣對調，等於沒修。**亂序在修之前已確定性重現**（不是推論）：`["k up", "k down"]`（放開先於按下）、`["touch []", "touch [1]"]`、`maxInFlight=10`。7 條新測試（`InputQueueTests` 4、`KeymapControllerRoutingTests` 2、`MirrorCoordinatorTests` 1）；探針用 `for await` 等待而非輪詢——**刻意不重蹈 D24 的等待預算**，代價是真回歸時要等 `.timeLimit` 的 60 秒。連帶修掉 D21 | 實際約半天 | — |
| ~~**D7**~~ | ~~**`mouseUp` 早退吞掉放開事件**：拖到 letterbox 黑邊或視窗外放開，guest 手指永遠按著~~ | **✅ 已修（2026-07-30）。先重現才修。** **重現**（`MirrorMouseReleaseTests`，把 view 裝進真 NSWindow 後合成滑鼠事件）：界內 `mouseDown` → 界外 `mouseUp`，收到的事件序列是 `[true]`——**放開被整個吞掉**。成因不是「使用者手抖拖出去」這種邊角情況：`mouseDown` 一定落在界內（黑邊屬於 `MirrorContainerView` 的背景，它沒有覆寫滑鼠處理），但 drag 一開始 AppKit 就會把後續的 `mouseDragged`／`mouseUp` **繼續投遞給同一個 view**，即使游標已離開；而黑邊在非同比視窗下**必定存在**（`ViewportFit` 就是為此而生）。**修法是把「拒絕」換成「夾住」，不是加狀態**——原本的 `(0...1).contains` guard 整道拿掉，算術抽成 `NormPoint.fromViewPoint`（純函式，比照 `KeyTranslate` 的既有慣例）並在裡面夾進 0…1。特殊情況因此消失，不必為「按著沒放」多維護一份 in-flight 狀態。夾而不是原樣送出也是刻意的：越界座標會讓畫面有反應但點在錯的地方，比不送更糟，而使用者會以為是遊戲的問題。順帶讓拖曳途中離開界外時觸點停在邊緣（真實觸控螢幕上手指本來就不可能離開螢幕），而不是原地凍結。5 條新測試（`MirrorMouseReleaseTests` 3 ＋ `NormPointTests` 2，後者含既有 nil 路徑的補測）。**與 D6 同族**：兩者都是「guest 端留著一個永遠按著的狀態且無自癒路徑」，D6 修完之後這條的down/up 也才真的成對——順序保證與送達保證缺一不可 | 實際約 1 小時 | — |
| ~~**D8**~~ | ~~**預設 transport 無法取消底層 RPC**~~ | **✅ 已修（2026-07-29，與 D1 同批）**。`GrpcStreamTransport` 改 class 持有真 call、改用 `makeStreamScreenshotCall`；`cancelStream()` 升為 `DisplayTransport` 的**必要**成員（刻意不給 default no-op），三個產品實作與兩個測試假件全數補上 | 實際與 D1 合計約半天 | — |
| ~~**D9**~~ | ~~**驗證腳本本身是假的**：`verify_snapshot.sh` 11 行零斷言；`verify_reconnect.sh:77` 的 `getprop` 缺 `-s`~~ | **✅ 已修（2026-07-30）。系統性掃描後範圍是原記載的三倍半**——D9 記了 2 個問題，實際 **7 個橫跨 5 支腳本**，其中 4 支帶著與 D29 相同的形狀（`swift test` 退出碼未讀），差別是**它們沒有 profdata 那道歪打正著的守門**，所以是真的假綠燈：`verify_keymap_inject.sh`（最後一行是 adb → 測試全紅照樣 exit 0）、`verify_mmap.sh`（退出碼未讀，且 FAIL 分支只 `echo` 後接 `ls`，檔案存在時 `ls` 回 0 → **印著 FAIL 卻 exit 0**）、`verify_audio.sh`（退出碼未讀，`writes >= 75` 這個明確門檻只印在說明裡從沒被檢查）、`verify_snapshot.sh`（連測試都不跑）。缺 `-s` 也不只一處：`verify_snapshot.sh:10` 同樣沒有。**修法：把判斷抽成 `scripts/lib/verify_common.sh`**（`assert_ok`／`assert_at_least`／`require_device`／`require_grpc`）——重複的檢查會漂移，而漂移正是 coverage.sh 在 D29 被修好、這三支卻沒跟上的原因；共用之後只有一份要驗。該工具有自己的 `verify_common_selftest.sh`（**不需模擬器**），並做過突變檢查：把 `assert_ok` 的中止拿掉，自我測試從全綠變成 3 項具名失敗。五支腳本逐一活體驗過會紅：注入必失敗的 live test 後 `verify_snapshot.sh`／`verify_keymap_inject.sh` 皆 `EXIT=1`；注入殘留檔後 `verify_mmap.sh` `EXIT=1`。**`verify_keyboard.sh` 查證後不是 bug**——它的判定來自 `getevent` 獨立量測 guest 端，不依賴 swift test 的自我回報，是這個 repo 裡的正確範本，刻意不動。**過程中自己犯了一次同型錯誤**：一度把 `under == 0` 也做成斷言，實測 under=406 才發現那個門檻在此情境不成立（見 D32）| 實際約 3 小時 | — |
| ~~**D10**~~ | ~~**沒有 CI**~~ | **✅ 已完成（2026-07-29）**。品質閘門 `app/scripts/ci.sh`（三道閘門，每道都注入故障驗證過會紅）＋ `pre-push` hook 強制執行。**Drone／Jenkins 那類需要另外部署 server，本專案不採用**；hook 零基礎設施、今天就生效。已用本地 bare repo 實際驗證：閘門綠 → push 成功；閘門紅 → push 被中止且遠端確實沒收到 | 實際約半天 | — |
| **D11** | **焦點切換不清鍵位狀態**：按住 W 然後 ⌘Tab，keyUp 永不投遞。**2026-07-29 擴大：現在有兩顆東西會卡**——搖桿觸點永遠 down（原記載），**加上** 若按住的是 profile 沒綁的鍵（D2 起走直通），guest 的**鍵盤鍵**也永遠按著。機制本身已經有了：`KeymapController.setEditing(true)` 會把 in-flight 的直通鍵補送 up（2026-07-29 為 ⌘E 加的），**但失焦沒有接上它**——`MouseCapture` 的 `didResignKeyNotification` 觀察者只 `release()` 游標，不碰鍵盤／觸點狀態 | 使用者體感 bug，且卡住的鍵盤鍵不會自己恢復（觸點還有下一幀快照可能蓋掉，鍵盤鍵沒有）。修法已知：失焦時走與 `setEditing(true)` 同一條釋放路徑，觸點側再補一個全放開快照 | 2 小時 | P2 |
| ~~**D12**~~ | ~~**搖桿觸點沒有 clamp**：`center ± radius` 可越界，`validated()` 不檢查~~ | **✅ 已修（2026-07-30，D5 階段 A Task 1）**。夾取放在 `KeymapEngine` 算出觸點的那一行（`NormPoint.clamped`，與 `fromViewPoint` 共用同一份規則）。**刻意不加進 `validated()`**：那是載入期 fail-fast，在那裡拒絕會讓使用者手上**既有的** profile 突然載不進來——而 `applyActivation` 用的是 `try? store.load(...)`，錯誤會被**吞成 nil**，使用者看到的不是「載入失敗」而是「keymap 就是不生效，毫無訊息」。最終審查覆核過這個取捨並認定成立，且指出它比原本寫的理由更強。順帶把 `lookPoint` 那第三份重複的 clamp 也併掉 | 實際約 30 分鐘 | — |
| **D13** | App 層 23 檔約 1300 行接線邏輯、5 條測試；`AppModel()` 光建構就有 8 個全域副作用 | §6 根因、D2、D4 全住在那裡 | 1–2 週 | P2（D1 修完成本降一半） |
| **D14** | **`PowerReducer` / `GrpcSnapshotService` 是死碼**，且 `PowerReducer` 的事件語意（`.snapshotSaved`/`.snapshotLoaded`）與實作相反——實作刻意不存不載快照 | 5 條測試在驗一台不存在的狀態機 | 1 小時 | P2 |
| ~~**D15**~~ | ~~**文件與碼庫不符**（見 §3）~~ | **✅ 已修（2026-07-29）**。§3 十項＋§8 C 三項全數補上更正註記（加註記、不重寫歷史）。含兩處**產品原始碼**註解：`StreamSize.swift`（fps 校準理由，補上 §11.2 的實測並指出它一半對一半錯）、`NormPoint.swift`（座標換算來源，那句話正是觸點偏移的 bug 本體）。連帶查出一個先前被「完全吻合」蓋住的 fps 落差 | 實際約 2 小時 | — |
| **D16** | MMAP transport 凍結未解，`MmapStreamTransport` 0% 覆蓋 | **什麼都沒擋**——§11.2 已證明傳輸不是 fps 瓶頸 | — | **建議封存** |
| **D17** | 環境漂移：canary emulator `37.2.1.0` 為除錯裝上後從未還原 stable | 所有 fps/延遲數字與 Phase-0 不可比 | 1 小時 | P2 |
| **D18** | `emulator-5554`（poc，共享）的 `pointer_location=1` 沒人關 | 小 | 5 分鐘 | P3 |
| **D19** | **`KeyTranslate` 把私用區字元原樣送給 guest**：`specialKeys` 只列了 8 個虛擬鍵碼，其餘鍵一律走 `characters` 路徑。但 macOS 對功能鍵給的 `charactersIgnoringModifiers` 是**私用區字元**——F1=`U+F704`、ForwardDelete=`U+F728`、Home=`U+F729`、End=`U+F72B`、PageUp=`U+F72C`、PageDown=`U+F72D`（以 AppKit 的 `NSF1FunctionKey` 等常數實測列印確認）。它們既非 nil 也非空字串，於是 `guard let characters, !characters.isEmpty` 放行，`.key("\u{F704}")` 被當成 W3C key 送出去。`KeyTranslateTests.swift:37` 的註解寫「沒有字元又不是已知特殊鍵 → nil，**不猜**」——**那句話只涵蓋「沒有字元」的鍵**，「有字元但那字元不是可列印字元」這一整類正好繞過它 | 送出 emulator 必不認得的 key 字串（設計 §2 的實測十個鍵不含任何一個私用區字元，無資料支持它會被翻譯）。後果是靜默無作用而非崩潰，但它讓「不猜」這句註解變成假的：碼確實在猜，只是猜在另一個分支 | 1 小時 | P2 |
| **D20** | **`KeymapEngine.unmappedCount` 會動，但沒人讀——不是「恆為 0」**。它在 `apply(.keyDown)` 裡對「引擎不認識的鍵」累加；D2 之後 `KeymapController.route()` 確實把大部分這類鍵攔去走直通，到不了 `apply`，但**唯一還會餵未綁定鍵進 `apply` 的呼叫端 `handleFlagsChanged`（修飾鍵旁路）本身就是產品路徑**——C1 修復後它直接呼叫 `emit(engine?.apply(.keyDown(code)))`（`KeymapController.swift:120`），而 keymap profile 通常不會綁 Shift/Control/Alt/Meta 這四顆修飾鍵。結果是**使用者在產品路徑上每按一次修飾鍵，這個計數就加一**，這句標題原本說反了 | `KeymapEngineTests.swift:74` 那條斷言驗的是「`apply` 對未映射鍵會累加計數」——這件事是真的，也確實會在產品路徑上發生（見左欄）。斷言測不到的是這個計數**有沒有意義**：全庫沒有任何生產碼讀取 `unmappedCount`（grep 只落在定義與遞增那兩行），它不上報、不觸發任何行為。這仍是本專案要防的「綠燈但沒驗到產品行為」那一類，只是精確地說是**測了一個沒有消費端的旁支指標**，不是「測了一條死路」 | 1 小時（決定：接上真正的消費端，或連同測試一起刪） | P2 |
| ~~**D21**~~ | ~~**注入縫只做了一半**——`InputInjecting` 不含 `sendTap`，`MirrorView.Coordinator` 仍吃具體型別 `EmulatorClient`，模組內並存兩套注入慣例~~ | **✅ 已修（2026-07-30，D6 連帶）**。修 D6 時 tap 必須與其他輸入走**同一條**佇列，這個缺口因此非補不可：`sendTap` 進 `InputInjecting`，`Coordinator` 改吃 `InputQueue`。「無 profile 退回直接 tap」（spec §7 驗收 4，P1-a 不回歸的核心保證）從零涵蓋變成有測試（`MirrorCoordinatorTests`）——**RED 當時該測試量到 `arrivals == []`**，具體展示了這條路徑先前根本觀察不到，不是「應該還好」 | 實際約 1 小時 | — |
| ~~**D22**~~ | ~~**編輯模式擋鍵盤、沒擋滑鼠**：`hasProfile` 是 `engine != nil && !editing`，一進編輯模式就變 false，而 `sendMouse` 正是靠它決定要不要退回直接 tap——編輯模式反而讓滑鼠點擊直接打進 guest~~ | **✅ 已修（2026-07-30，D5 階段 A Task 2）**。根因是兩個語意不同的判斷共用一個述詞：「該不該把滑鼠交給引擎」與「該不該把事件送出去」。拆開——`hasProfile` 改為只表達前者（`engine != nil`），後者由新的 `Coordinator.isEditing` 負責。`AppModel.shouldCapture` 本來就自帶 `&& !editing`，游標捕捉行為不受影響（已查證三個消費端）。順帶補上先前**零涵蓋**的姊妹不變式測試（有 profile 且非編輯時 tap 由引擎接手）——那條是新 guard 的正確性所依賴的東西 | 實際約 1 小時 | — |
| **D23** | **`KeymapController.reload()` 換 profile 時，按住中的 bound 鍵在 guest 端永久卡住觸點**：按住 `w`（綁在搖桿）→ `reload(nil)` → 放開 `w`。舊 engine 連同它的 `pressed={w}` 被整顆丟棄，guest 端留著一個 `down:true` 的搖桿觸點；放開 `w` 這個 keyUp 到達 `route()` 時：不在 `passthroughDown` 裡（原本走的是 engine 分支，不是直通），`engine?.handles` 因新 engine 是 nil 而不成立，最後 `guard down, !editing else { return }` 因為這是 keyUp 直接 return——三段判斷全部跳過，`emit` 一次都不會被呼叫，沒有自癒路徑。**與 D11 不同**：D11 講的是**失焦**（⌘Tab 離開視窗）沒接上既有的釋放機制，且 D11 已知的修法（借用 `setEditing(true)` 對 `passthroughDown` 的釋放路徑）只清直通鍵；這裡的觸發條件是**呼叫 `reload(_:)` 本身**（真實路徑：`AppModel.applyActivation()` 的 `.inactive` 分支，`AppModel.swift:229`，遊戲偵測失去前景遊戲時），卡住的是 engine 內部 `pressed` 集合追蹤的**bound** 鍵，`setEditing` 的機制完全碰不到它——兩者觸發條件與修法都不同，不能互相取代 | 使用者體感 bug，且不會自己恢復：新 engine 從 `pressed={}` 起算，除非後續事件恰好用到同一個觸點 identifier 才會被蓋掉，否則那個觸點對 guest 來說永遠是按著的。修法：`reload()` 換 engine 前，先用舊 engine 目前的 `pressed` 算一次「全放開」快照送出去，或讓 `KeymapEngine` 提供一個等效方法給 `reload()` 呼叫 | 1 小時 | P2 |
| ~~**D24**~~ | ~~**測試用的 `waitUntil` 上限是 2 秒**（`attempts:100 × interval:20ms`），高負載下會逾時，已重現四次；它讓品質閘門本身間歇說謊~~ | **✅ 已修（2026-07-30）**。17 個呼叫點全數改用**沒有等待預算**的閘門：`CountGate`（continuation 精確喚醒，等計數達門檻）與 `StateRecorder.wait(until:)`（等狀態序列滿足述詞）。**刻意不用 `AsyncStream`**（`OrderProbe` 用的那招）——同一個測試會連續等好幾次門檻（`>=1` → `>=2` → `>=3`），而 `AsyncStream` 只支援單一迭代器。逾時改交給掛在 @Suite 上的 `.timeLimit(.minutes(1))`：60 秒不是「更寬鬆的預算」，是「只有真的死掉才踩得到」的量級，不會被日常負載誤觸。順帶把兩個幾乎一模一樣的 recorder actor 合成泛型 `StateRecorder<T>`，並把等待收進持有資料的一方——輪詢別人的內部狀態只是把時序問題推給呼叫端。**驗證**：改完後連跑 10 次完整套件 0 失敗，`ci.sh` 3/3 綠。**過程中自己引入一個新的窄競態並抓到**：`subscribeGate.increment()` 一度放在 `_subscribeCount += 1` **之前**，等待方被放行時計數還沒更新，18 次連跑才複現一次——順序改對後消失。那一次紅是真訊號，不是雜訊 | 實際約 2 小時 | — |
| ~~**D25**~~ | ~~**`.app` 裡找不到資源會硬崩**：全 repo 唯一組 `.app` 的地方只 `cp` executable，不複製 resource bundle；開發機上默默從編譯期寫死的 `.build/` 絕對路徑讀，換機器就啟動即崩~~ | **✅ 已修（2026-07-30）。A/B 實測證明，不是推論。** 新增 `scripts/package_app.sh` 作為**唯一**的 `.app` 組裝入口（`verify_game_fps.sh` 改為呼叫它；`-a` 版本對照選項以第三參數傳遞，未失效），把 `Mirage_MirageCore.bundle` 複製到 `.app` **根目錄**——不是慣例的 `Contents/Resources/`，因為 SwiftPM 產生的存取器查的是 `Bundle.main.bundleURL/Mirage_MirageCore.bundle`，而 `.app` 的 `bundleURL` 就是 `.app` 自己。打包後自檢**不依賴 `.build/`**（只檢查 .app 內部），所以在有 `.build/` 的開發機上也抓得到缺漏——「開發機上測不出來」正是這筆債能存在這麼久的原因。**驗證（把 `.build` 的後備 bundle 藏起來＝模擬換一台機器）**：自帶資源的 .app 正常啟動並印出 `[profile]`；不帶資源的 .app **退出碼 133（SIGTRAP）**，訊息為 `Fatal error: could not load resource bundle: from …/Mirage_MirageCore.bundle or …/.build/…`——與記載一字不差。另發現：拿掉 `Package.swift` 的 `resources` 宣告時**碼根本編不過**（`Bundle.module` 不存在），所以那條回歸路徑已由編譯器擋住 | 實際約 2 小時 | — |
| **D26** | **閘門 3 的假 skip 哨兵只掃單行**。2026-07-30 已把樣式從「只認 env 形式」擴到同時抓 `guard … else { … return }`（`app/scripts/ci.sh` 閘門 3），但跨行的 `guard … else {\n print(…)\n return\n }` 仍抓不到。活的一例：`Tests/MirageCoreTests/MmapStreamLiveTests.swift:31-34`——模擬器版本 < 37 時 print 一行然後 return，該測試回報 passed 但零斷言 | 哨兵漏抓比沒有哨兵更糟，因為綠燈會被當成證據——這正是 D3 與本輪 C1 的共同病理。目前的緩解是把盲區明寫在腳本註解與 `ok` 訊息裡（「無**單行形式**的假 skip」），不假裝全包 | 半天（要 AST 而不是 grep；或先把 `MmapStreamLiveTests` 那條改成不早退） | P2 |
| **D27** | **`BuiltInProfiles.seed` 不回報失敗筆數，呼叫端分不出「全都已存在」與「每一筆都複製失敗」**。`seed` 只回傳成功複製的清單，`catch { continue }` 把權限錯誤之類的失敗整個吞掉。`AppModel.seedBuiltInProfiles()`（`AppModel.swift:103-113`）已能靠 `sources.isEmpty` 分出「資源打包壞了」，但「有來源、每筆都失敗」仍與「全都已存在」印同一句話 | 與 D4 本體同一種病（東西沒到位卻沒有訊號），只是機率低得多——要磁碟滿或 `~/Library/Application Support` 權限異常才會踩到。修法是把回傳型別從 `[String]` 換成帶失敗清單的結構，並讓呼叫端把失敗印出來 | 1 小時 | P2 |
| ~~**D28**~~ | ~~**`MockTransport.subscribeCount` 是沒有同步的跨執行緒讀，且斷言的時序窗口本來就存在**（`connectedRun()` 先發布 `.connected`、之後才 `attachStream()`）~~ | **✅ 已修（2026-07-30，兩半都修完）**。前半：讀取改走鎖（`_subscribeCount` ＋ 加鎖的 computed property，比照同一個 mock 早就寫對的 `cancelCount`）。後半：斷言改成**先等 attach 真的發生再斷言**（`subscribeGate.wait(for: 1)` 之後才 `#expect(subscribeCount == 1)`）——等待保證下限、斷言守上限，時序窗口消失。**這筆債最大的價值是「不要被誤記成 D24」**：它唯一一次紅的指紋是「`reachedConnected` 通過、只有下一行紅」，而 D24 的指紋是 `waitUntil` 自己逾時 | 實際約 30 分鐘 | — |
| ~~**D29**~~ | ~~**`coverage.sh` 從不檢查 `swift test` 的退出碼**~~ | **✅ 已修（2026-07-30），但這筆債的後果原本記錯了，一併更正。** **形式成立**：兩處 `swift test` 的退出碼確實從未被讀取。**後果不成立**——原本（與觸發本次修復的那份審查）寫的是「測試紅了仍會 exit 0」，2026-07-30 實測**推翻**：注入一條必失敗的測試後，SwiftPM 產生 `.profraw` 但**不產生 `default.profdata`**（測試失敗就跳過 merge），於是既有的 `[ ! -f default.profdata ]` 守門照樣 `exit 1`。**沒有假綠燈。** 真正的問題比原記載小一級，但仍值得修：(a) 那道防護是**附帶的、未載明的**——它依賴 「SwiftPM 測試失敗時不 merge」這個沒有任何文件保證的實作細節，哪天改成失敗也 merge，腳本會**靜默**開始對紅測試印綠報告；(b) 失敗訊息把成因寫成「未產生 default.profdata（測試可能失敗）」，要讀的人自己猜。修法：兩處改用 `${PIPESTATUS[0]}` 明確檢查。**刻意不加 `set -e`**——Run 2 是 `swift test … | grep -E`，grep 沒配到就回 1，加了 `-e` 會殺掉一次正常跑次；理由已寫進腳本，免得下一個人「順手補上」。**已注入故障驗過會紅**（`COVERAGE_EXIT=1` ＋ 具名訊息），移除後乾淨跑 `COVERAGE_EXIT=0`，段 1 line 88.95%、段 2 line 10.64%，兩段皆未低於記錄值。過程中另修掉一個自己寫出來的 bug：`$VAR）` 後面接**全形**右括號會被 bash 吃進變數名，`set -u` 當場炸——這在通篇中文的腳本裡會再犯，已在腳本註明「變數後接全形標點一律夾大括號」 | 實際約 30 分鐘 | — |
| ~~**D30**~~ | ~~**啟動流程不是 one-shot，卻掛在 `WindowGroup` 的 `.task`**：`.task` 每個視窗跑一次、`@State model` 整個 App 一份，⌘N 就會對同一個 `AppModel` 重跑整段啟動序列~~ | **✅ 已修（2026-07-30）。先端到端重現，再修。** **重現**（`WindowGroup` 版，實機點選 File ▸ New Mirage Window）：`[app] endpoint=` 印**兩次**、`[profile]` 也印兩次——整段啟動序列確實在同一個 `AppModel` 上重跑。**A/B 對照**：`WindowGroup` 的選單列是 `Apple, Mirage, File, Edit, View, Window, Help`，File 選單內含 `New Mirage Window`；改用 `Window`（單一實例場景）後**連 File 選單都不存在**。修法刻意不是在 `.task` 加旗標——旗標讓「可以有兩個視窗」這個錯誤前提繼續存在、只擋住其中一個後果；Mirage 鏡像一台模擬器本來就只該有一個視窗，換成 `Window` 之後重複啟動在結構上不存在，順帶讓 `NSApp.windows.first` 不再有歧義。**另加一道 actor 層守門**：`EmulatorClient.start()` 原本直接覆寫 `loopTask`（舊 Task 不取消、`running` 仍是 true，兩條連線迴圈同時搶 `attachStream()`），改為已在跑就忽略並**印一行具名警告**——它在重現實驗中確實觸發了，證明守門在真實 App 裡有效；不靜默是刻意的，因為「沒有訊號」正是這筆債藏這麼久的原因。單元測試 `EmulatorClientStartOnceTests`（RED 時 `subscribeCount → 2`）。**「關閉視窗會不會重跑 `.task`」已實測不會**（原本只是推論）：⌘W 關閉（`windowShouldClose` 回 false ＋ `orderOut`）→ `open` 重新啟用 → 選單列「顯示視窗」，三條路徑走完 `[app] endpoint=` 始終只有 1 行、零重複警告 | 實際約 2 小時 | — |
| **D31** | **`SnapshotRoundTripLiveTests` 名不副實，且它驗的是死碼**。該測試**刻意只驗 save**（註解寫明：在運行中的模擬器上 `loadSnapshot` 會使模擬器崩潰，canary 37.2.1，載入 ~2.3GB RAM 快照進 live VM，且與 spec §8 矛盾），所以名字裡的 `RoundTrip` 描述的是一件刻意不做的事。它驗的 `GrpcSnapshotService` 又正好是 D14 記載的死碼 | 看到 `SnapshotRoundTripLiveTests` 綠燈，合理推論是「快照存取來回驗過了」——**兩層都不成立**：只驗了 save，而且驗的服務產品從不呼叫。`verify_snapshot.sh` 的檔頭原本也寫著「save → 改變畫面 → load」，已於 D9 加上更正註記並在輸出裡如實列出涵蓋範圍，但**測試名字本身還沒改** | 30 分鐘 | P2 |
| **D32** | **`verify_audio.sh` 原本印的「under == 0 → 驗收線 6 的必要條件」在該測試情境下不成立**，而驗收線 6 目前**沒有任何自動化涵蓋**。`drainRingAtRealTimeRate`（`AudioLiveTests.swift:14`）每 10ms **無條件**讀 960 樣本、且從 t=0 就開始讀（連線都還沒建立），5 秒 = 500 次讀取，所以 underrun 結構上必然很大（實測 406／407）。那個 drain 存在的目的只是避免緩衝填滿讓 `writes` 卡住（見該檔 line 11-13），不模擬真實播放；測試自己也只斷言 `writes` | **這條差點被我自己做成假紅燈**：D9 修訂時一度把它做成硬性斷言，跑出來才發現不成立（已改成如實報告數字並說明為何不是判準）。真正的代價是驗收線 6（音訊不拖垮鏡像）只能靠 GUI App 下 `MIRAGE_AUDIO_LOG=1` 人工觀察 60 秒——**零自動化**，而設計文件 §197 正是為此承諾「畫面與輸入完全不受影響」（§3 第 3 項記載它就是三階段黑畫面的根因本體）。修法：讓 live 測試接上真正的消費端節奏，或明確承認驗收線 6 無自動涵蓋並記進驗收表 | 半天 | P2 |
| **D33** | **AVD provisioning 完全靠人手，產品沒有一行碼能重現測試環境**。三台 AVD（`mirage-poc`／`mirage-game`／`mirage-bench`）是人手工用 curl 下載映像 + 手寫 `config.ini` 建的，彼此設定還不一致（§4：`poc` 是 `gpu.enabled=no/mode=auto/ram=2G`，另兩台是 `yes/host/4096`）。**這筆先前沒有編號**，只活在 §6 表格下方的一段散文裡——而沒有編號的東西每一輪都會被合理地跳過，正是 §0 記載的誤診模式 | **它讓 Phase-1 唯一通過的驗收線站不住**。「1 款指標遊戲開箱即玩 ✅」目前的實際意思是「有人先幫你把箱子拆好」——換第二個人、換一台機器，沒有任何自動化路徑能到達那個狀態。與 D17（canary emulator 裝上後從未還原 stable）同一族：**環境是手工管理的**，所以所有 fps/延遲數字的可重現性都建立在一個沒人維護的前提上。**兩條出路，選哪條都行，但不能什麼都不做**：(a) 寫一支冪等的 provisioning 腳本；(b) 若 provisioning 明確不在 Phase-1 範圍，就在驗收表上寫明「開箱即玩」的前提是預先備妥的 AVD——不能讓那個 ✅ 裸著，讓讀的人以為它涵蓋了它其實沒涵蓋的東西 | (a) 1–2 天／(b) 10 分鐘 | **P1**（先做 (b)，(a) 看 Phase-1 範圍決定）|
| **D34** | **D5 階段 A 留下的小債（最終全分支審查分流後未修的部分）**。(a) `BuiltInProfiles.fallbackStarterBindings` 與 `Resources/profiles/com.example.game.json` 的 bindings **逐欄位完全相同**，所以 bundle 讀取路徑徹底壞掉時行為上看不出來——沒有任何東西維持兩者同步，也沒有任何訊號會告訴你退回了 fallback；(b) `AppModel.toggleEditing` 的 `.enter` 對「已有 profile」也無條件 `keymap?.reload(p)`，把引擎連同 `pressed` 整顆換掉（**D23 那一族**）；(c) ~~`AppModel.swift:340/362` 與 `AppModel+FullScreen.swift:13` 仍有未經 Optional 轉型保護的 `NSApp` 直接使用~~ → **已修（2026-07-30，階段 B Task 1），但當初對它的風險評估是錯的，一併更正**：原記載說「階段 B 一建立有引擎的 `AppModel` 就會以 signal 5 炸開」——**結構上不成立**。實測＋逐步讀碼確認：這三處在目前的呼叫圖裡**永遠不會**以 nil `NSApp` 被執行到，因為它們全都晚於 `startLifecycle()` 內的 `MenuBarController` 建構，而**那一步本身就會把 `NSApp` 從 nil 撥成非 nil**（建 `NSStatusBar` 狀態項會觸發 `NSApplication` 的惰性初始化）。`wake()` 是 private 且唯一呼叫點是 `MenuBarController` 綁的回呼；`setupFullScreen` 的閉包同理。**對照組**：階段 A 真的崩掉的 `shouldCapture` 走的是 `loadKeymap()`／`toggleEditing()`，**不經過 `startLifecycle()`**——那才是它會崩而這三處不會的原因。保護仍然保留（防禦性、與既有先例一致、呼叫圖日後可能改變），但**刻意不附回歸測試**：曾寫過一條，實測在有無保護時都綠，已刪除——一條自證無鑑別力的測試比沒有測試更糟；(d) 每次 ⌘E（含離開）都呼叫 `starterBindings()`，產品路徑上那是 `Bundle.module.urls` ＋ `Data(contentsOf:)` ＋ JSON decode 跑在 MainActor 上，而只有一個分支用得到；(e) 編輯途中前景遊戲切換時，選單列會短暫顯示新 package 配舊引擎的 active 狀態（離開編輯時自我修正）；(f) `constructsWithInjectedDependencies` 其實沒有驗證 store 注入（刪掉 `self.store = store` 它照樣綠），名字與 docstring 過度承諾 | 沒有一項擋住階段 A 合併——最終審查已逐條分流過。**(a) 與 (c) 是會咬人的兩項**：(a) 屬本 repo 最在意的「東西壞掉卻沒有訊號」那一類；(c) 在階段 B 建立有引擎的 `AppModel` 時會以「整個 test run 收到 signal 5」的形式炸開，而錯誤訊息完全不指向成因（本輪已在 `shouldCapture` 上實測過這個崩法）。(b) 應與 D23 一起處理 | 各 10 分鐘–1 小時 | P2 |

> **關於 `P0`**：這一級是 2026-07-29 為 D6 新增的。原本最高只有 P1，而 D6 在 D2 上線後
> 多了一種「不會自癒」的失效模式（永久卡鍵），與其他 P1 不同級。優先序欄位仍然是建議。

---

## 3. 文件與實際的落差（依誤導程度排序）

> **✅ 全數已補上更正註記（2026-07-29，D15）。** 下面十項逐條處理完畢，另加 §8 C 節的三項。
>
> **做法是加更正註記、不重寫歷史**——本節抱怨的是「更正缺席」，不是「保留了錯誤的歷史」。
> 每則更正都寫明「原本寫什麼、為什麼錯、現在的事實是什麼、證據在哪」，讓讀到舊句子的人
> 當場就看得到反駁，而不是要他們自己去別的檔案交叉比對。
>
> 兩則值得單獨一提：
> - **第 7 項不是單純的「已被推翻」。** `StreamSize.maxPixels` 的註解說「尚未經 fps 實測校準」
>   ——現在有數據了（§11.2），而數據顯示那段理由**一半對一半錯**：0.65 MP 以下縮像素預算
>   幾乎買不到 fps（30.4→32.3，解析度差 4 倍），但 2.59 MP 確實掉到 22.0，上限對防高端仍有用。
>   1.8 MP 這個值本身仍沒有對應量測點。更正寫成這樣，而不是籠統說「已推翻」。
> - **第 10 項（本輪自己犯的錯）連帶查出第二個問題**：撤掉那句「完全吻合」之後，
>   §11.2 的 30.4 fps 與 §12 的 43–56 fps 之間有個**沒人解釋過的落差**——原本被那句話蓋住了。
>   已在文件裡標明，拿 fps 做決策前應先解釋它。

1. **`app/README.md:58`** — 描述已移除的 `sendTouches(_:width:height:)`，並說「座標用解碼後實際幀尺寸」。**那正是讓所有觸點偏移的錯誤慣例。** 座落在最可能被當作寫碼依據的檔案裡——不修的風險不是誤解歷史，是重新寫出剛修好的 bug。
2. **`app/RESULTS-p1d.md:43`** — 「引擎→多指注入活體通過且座標數學正確」的 GO 判定。那條驗的是 harness 直接呼叫並自行傳尺寸，沒有經過 App 層的傳遞路徑。無更正註記。
3. **`docs/specs/2026-07-26-p1e-fullscreen-audio-design.md:197`** — 白紙黑字承諾「音訊不可拖垮鏡像主功能，畫面與輸入完全不受影響」，而它恰好是三階段黑畫面的根因本體。唯一完全沒被回頭修正的設計文件。
4. **`app/RESULTS-p1b.md:48`** — 三份沿用「螢幕鎖定」歸因的 RESULTS 中唯一沒被更正的。
5. **`app/RESULTS-p1e.md`** — 更正只補在一處（line 99–102），line 22 / 47–49 / 168–181 仍原樣斷言舊歸因。其中 line 47–49 自稱「而非憑印象宣稱」——它驗的正是後來被推翻的解釋。
6. **`app/README.md:29–31, 96, 102`** — 頂層 README 對 P1-a／P1-e 都重申「pending-unlock（螢幕解鎖後補測即可）」。
7. **`Sources/MirageCore/Viewport/StreamSize.swift:15–18`** — 產品原始碼註解仍寫「尚未經 fps 實測校準」，且 `maxPixels` 保守取值的理由（縮小像素預算＝保護 fps）已被 §11 推翻。
8. **`Sources/MirageCore/Keymap/NormPoint.swift:11`** — 「呼叫端傳實際幀尺寸——沿用 P1-a 的實際幀尺寸換算」。整條路徑其他六處註解都改了，唯獨這個函式自己沒改，而下一個人讀的就是這一句。
9. **`phase0/README.md:67`** — 仍宣稱純粹 NO-GO，未提「污染主機」的更正（乾淨重測 55.3–57.4fps）。
10. **本輪自己犯的錯**：`2026-07-28-mirror-never-rendered-investigation.md` §5、§6.6 引用「模擬器能以 46–59 fps 串流」佐證「兩條路徑量測終於吻合」，但該數字全庫唯一出處是 recon 文件的一句引用，**無任何表格或原始輸出支撐**；而 §11.1 用同樣方法量到 30.4 fps，對不上。**用了一個沒查證的數字去證明另一個數字。**

---

## 4. 兩處對審查結論的更正

審查建議「掃 AVD 設定，`hw.gpu.enabled=no` 可能一擊解決 60fps」。**主控端驗證後不成立**：

```
mirage-poc:   gpu.enabled=no   mode=auto  ram=2G     cores=4
mirage-game:  gpu.enabled=yes  mode=host  ram=4096   cores=4   ← fps 是在這台量的
mirage-bench: gpu.enabled=yes  mode=host  ram=4096   cores=4
```

recon 文件那句講的是 `poc`。量 fps 用的 `game` 機已是最佳設定，仍只有 29–44fps。這條路走不通。

### 第二處（2026-07-30）：「coverage.sh 會對紅測試回傳成功」不成立

審查指出 `coverage.sh` 沒有 `set -e`、不檢查兩處 `swift test` 的退出碼，並推論「測試失敗但仍產生 profdata 時可能最後回傳成功」。**前半正確，後半實測推翻。**

注入一條必失敗的測試後實測：`swift test --enable-code-coverage` 失敗時只產生 `.profraw`，**不產生 `default.profdata`**（SwiftPM 測試紅就跳過 merge），於是既有的 `[ ! -f default.profdata ]` 守門照樣 `exit 1`。**沒有假綠燈。**

這條仍然值得修，但理由要換掉：那道防護是**附帶且未載明**的，依賴一個沒有文件保證的 SwiftPM 行為；一旦上游改成失敗也 merge，腳本會**靜默**開始說謊。詳見 D29。

> **這一則的方法論價值大於結論本身。** 它是靠「注入故障、看它會不會紅」抓到的——若只是讀碼推論，`set -e` 缺席這個事實會很自然地被推成「所以會回傳成功」，然後這個錯誤結論會以「已修」的姿態進入債務表。§0 講的誤診模式，這次差點在同一輪內重演。

---

## 5. 建議的下一步

> **進度（2026-07-29 同日）**：**第 0 步與下面第 1、2、3 項（D1／D8／D3／D10）皆已完成並驗收**，
> 見 §1、§7、§8。

~~**第 0 步：把所有 `pending-human` 重新分類**（半天）~~ ✅ 已完成，結果見 §8。
最重要的產出不是分類本身，而是發現**分類方式漏了一整類**：十餘筆項目的阻礙早在
2026-07-28 就消失了，卻仍以「pending-unlock」的形式躺在清單上，每一輪都被合理地跳過。

之後：

1. ~~**D1 NIO 關閉順序**（半天）~~ ✅ 已完成。它不是最重要的，它是**乘數**——修完之後每次驗證的成本才是誠實的。D8 同批做掉了（同一個原因）。
2. ~~**D3 假綠燈**（1 小時）~~ ✅ 已完成。
3. ~~**D10 CI**（半天）~~ ✅ 已完成（見 §7）。`app/scripts/ci.sh` 三道閘門都注入故障驗證過會紅，`pre-push` hook 也用本地 bare repo 驗過真的會擋。**不採用需要另外部署 server 的 CI 服務。**
4. **D2 鍵盤直通 + D4 profile 上架**（1 天）——這兩個是「沒有」不是「不夠好」，比三條數字驗收線更致命。
5. **D15 文件更正**（2 小時）——尤其 README:58。
6. **D5 overlay 編輯器真的能拖**（2–3 天）。
7. **把 78ms 那段再分解一層**（1 天）——guest 出幀 vs 編碼 vs 傳輸各佔多少？目前不知道。§12.1 那次分解的價值就是擋掉了「去優化渲染」這個錯方向，對 78ms 要再做一次同樣的事。**在分解之前談「優化傳輸」是在猜**，而這個專案在 MMAP 上已經為「先猜再做」付過全額學費。
8. **冷啟動：先做產品決策**——若允許背景常駐 emulator，使用者感受到的是 4.7s 快照喚醒而非 32.8s 冷啟動（§13.2）。那是產品決策不是工程優化，決定之前不要寫 InstanceManager。

**明確不建議做的**：優化 Metal 渲染路徑（20–28ms 已近下限）、修 MMAP 凍結（傳輸不是瓶頸）、追 Pokémon TCG Pocket 的 SIGSEGV（母計畫 R2 已禁止）。

---

## 6. Phase-1 驗收線現況

| 驗收線 | 狀態 | 瓶頸 | Mirage 佔比 |
|---|---|---|---|
| 1 款指標遊戲開箱即玩 | ✅ | — | — |
| 60fps 穩定 | ❌ 29–44fps | guest 出幀（⚠️ 仍是推論，未直接量到 guest render fps） | 無額外損失 |
| 輸入延遲 < 80ms | ❌ ~110ms | 傳輸佔 ~2/3 | 20–28ms |
| 冷啟動 < 30 秒 | ❌ ~37s | emulator 開機佔 89% | 4.2s |
| 快照喚醒 < 5 秒 | ❌ ~8.9s | 同上 | 4.2s |
| 記憶體閒置 < 4GB | ⬜ **未量** | — | 現行 suspend 不停 qemu，此線在現架構下必然不達標 |

「1 款指標遊戲開箱即玩」通過，但**那台 AVD 是人手工用 curl + 手寫 config.ini 建的**，產品沒有一行碼能重現它。目前「開箱即玩」的意思是「有人先幫你把箱子拆好」。

---

## 7. D10 CI：閘門 + pre-push hook（2026-07-29，已完成）

**為什麼不是 CI 服務**：Drone／Jenkins 那類都要另外部署並維護一台 server，本專案不採用。
GitHub Actions 不需要部署，但需要一個 GitHub remote，而 `git remote -v` 目前是空的。
**`pre-push` hook 是唯一零基礎設施、今天就能真的擋住東西的選項**，因此選它。

（曾經寫過一份 `.drone.yml`，在確認 Drone 不符使用後**刪除**而不是留著。
一份沒人會跑的設定檔留在 repo 裡，下一個人只會以為「這專案有 CI」——
那正是本文件 §3 整節在講的失敗模式。）

**做法上的一個決定**：閘門邏輯全部放在 `app/scripts/ci.sh`，hook 只有一行呼叫它。
那支腳本今天就能在本機跑、能被驗證；邏輯若寫在 hook 或 YAML 裡，就只有等它被觸發
才知道對不對。日後若真的接上 GitHub Actions，也只是換一個 wrapper 呼叫同一支腳本。

### 三道閘門，以及它們各自被證明會紅

一支從未失敗過的驗證腳本不能算驗證過——D9 記著 `verify_snapshot.sh`「11 行零斷言」。
所以每道閘門都注入了對應的故障，確認它真的會紅：

| 閘門 | 注入的故障 | 結果 |
|---|---|---|
| 0：hermetic 前提（目標埠無人監聽） | 用 `nc -l` 佔住該埠 | ❌ 立即中止，退出碼 1 |
| 2：測試連跑 N 次 + NIO ERROR 為 0 | 把 `GrpcChannelBox.shutdown()` 退回 D1 修正前的阻塞式寫法 | ❌ 第 1 跑抓到 2 行 ERROR，第 2、3 跑死鎖被逾時攔下，退出碼 1 |
| 3：不得出現 `guard <env> else { return }` 假 skip | 加一個含該樣式的探針檔 | ❌ 指出檔名行號，退出碼 1 |

乾淨樹上退出碼 0。

**閘門 2 跑不只一次**（預設 3 次）：D1 的死鎖命中率約 60%，單次綠燈有四成機率只是運氣，
而這個 repo 歷來每一份「N tests passed」都是單次的。

**逾時是必要的**：沒有它，D1 那類死鎖會讓 CI 掛到平台的全域逾時才失敗，而在儀表板上
「卡住」跟「還在跑」長得一樣。

### 一個先前沒人驗過的前提

整個測試套件在此之前**從未在「本機沒有模擬器」的條件下跑過**。原因是
`EmulatorEndpoint.resolve`（`MIRAGE_HOST` / `MIRAGE_PORT`，9 條單元測試）雖然早就存在，
卻**只接在 `AppModel` 上**；測試用的 `EmulatorClient()` 預設值仍寫死 `localhost:8554`，
而開發機上剛好一直有 AVD 在跑。CI runner 上不會有。

已把 `EmulatorClient` 的預設端點下沉到 `EmulatorClient.defaultEndpoint`（同一份解析，
`AppModel` 改為共用），於是 `MIRAGE_PORT=<沒人監聽的埠> swift test` 成為確定性的 hermetic 跑法。
**實測：無模擬器條件下連跑 5 次，5/5 通過、每跑 0 行 ERROR。**

順帶一個意外發現：**沒有模擬器時 D1 的死鎖照樣重現**（見上表閘門 2），
也就是說那個 bug 從來不依賴活連線——先前「模擬器剛重開才會中」的觸發配方只是放大因子。

### hook 本身也驗證過會擋

`.drone.yml` 沒被驗證過正是刪掉它的理由，所以 hook 不能重蹈覆轍。
用 `git init --bare` 開一個本地 bare repo 當臨時 remote，實際 push 兩次：

| 情境 | 結果 |
|---|---|
| 閘門全綠 | hook 執行閘門 → 通過 → **push 成功**，遠端收到 branch |
| 閘門紅（塞入假 skip 探針） | hook 執行閘門 → 失敗 → **push 中止**，`git --git-dir` 查遠端**確實沒有那條 branch** |

第二列的最後半句是重點：不是「印了紅字」，是**遠端真的沒收到**。

### 安裝與限制

`./app/scripts/install-hooks.sh`，每個 clone 跑一次。用 `core.hooksPath` 指向版本控制中的
目錄，不複製檔案——複製會產生兩份、之後永遠不知道哪份是新的（本專案已經因為
「同一件事有兩份各自演化的複本」吃過虧，見本節開頭的 `EmulatorEndpoint`）。

擋不住的：只在裝了 hook 的 clone 上生效；`--no-verify` 可繞過（刻意保留，hook 是防手滑
不是防惡意）；保護的是「推出去的東西」而非「commit 進去的東西」。

刻意不做成 `pre-commit`：完整閘門要跑三次測試套件，掛在每次 commit 上會讓人很快開始
習慣性 `--no-verify`，那比沒有 hook 更糟——它教會大家忽略閘門。

### 閘門綠**不**代表什麼

活體測試（`MIRAGE_LIVE` 系列）、覆蓋率（需真模擬器且會觸發 guest 發聲）、
GUI 路徑（⌘Q 拆除、overlay、Metal 渲染）都不在 CI 涵蓋範圍內。

---

## 8. 第 0 步的執行結果：pending 重新分類（2026-07-29）

§0 要求把所有 `pending-human` / `pending-unlock` 逐項重分為「做了沒驗」或「根本沒做」。
以下是執行結果。**每一筆的判定依據都是 grep 呼叫端或檢查 bundle 宣告，不是讀文件。**

方法上有一點值得記下來：只掃 `pending-human` 這類關鍵字是不夠的——`sendKey` 那筆
（任何文件都沒提過，卻是零呼叫端）就抓不到。所以另外做了一路結構性檢查：
「這個功能有沒有呼叫端」「這個資源進得了 bundle 嗎」「這條 stream 有沒有消費端」。
兩筆最嚴重的發現都來自結構性那一路，不是關鍵字那一路。

### A. 根本沒做（功能不存在）

| 項目 | 文件怎麼說 | 實際 | 證據 |
|---|---|---|---|
| ~~鍵盤直通 `sendKey`~~ | ~~**任何文件都沒提過**~~ | ~~公開 API 零呼叫端~~ **✅ 已於 2026-07-29 實作（D2）** | 稽核當時：`Sources/MirageShell/` 與 `Tests/` grep `sendKey` 全零。D2 修復後不再成立——`KeymapController.swift:99`（`route()` 的直通分支經 `sendKeyToGuest`）、`AppModel.swift:246-250`（選單列 `onAndroidKey` 綁定，down 接 up）；同一組 grep 現為 `Sources/MirageShell/` 9 筆、`Tests/` 8 筆 |
| overlay 編輯器拖放 | 「拖放存檔、拖放手感 pending-human」 | 不能拖 | `OverlayEditorView.swift` 全檔 29 行，只有一個「存檔」Button；全 `MirageShell` 零 `DragGesture` |
| 內建 profile 上架 | 「佔位，待綁真 package」 | SPM 看不到那個檔 | 稽核當時：~~`Resources/profiles/com.example.game.json` 在磁碟，但 `Package.swift` 無 `resources:` 宣告、全碼庫零 `Bundle.module`~~。**✅ 已於 2026-07-29 實作（D4）**——資源已搬進 `Sources/MirageCore/Resources/profiles/`，`Package.swift:32` 有 `resources: [.copy("Resources/profiles")]`，`Bundle.module` 有兩個呼叫端（`BuiltInProfiles.swift` 與 `BuiltInProfilesTests.swift`）。（**更正於 2026-07-30**：證據欄前半原本仍用現在式，與後半的「已實作」自我矛盾——隔壁那列的刪除線處理是對的，這列漏了。） |
| 真遊戲 profile 內容 | 「留 Phase 1 三款遊戲」 | 只有 `com.example.game` | ~~`AppModel.swift:59` 硬編碼~~——**該死路徑已於 2026-07-29（D4）整段刪除**，見 `AppModel.swift:118-125` 的更正註解；`MenuBarController.swift:126` 也 fallback 到同一個字串（未變動，YAGNI） |
| `powerStates` UI 接線 | 「未接線」← **誠實** | 定義 + 初始化，零消費端 | `EmulatorClient.swift:63,109` 之外全庫零命中 |
| `isTargeted` 拖曳高亮 | 「刻意 scope 掉的功能缺口」← **誠實** | `.dropDestination` 未帶該參數 | `MirageScene.swift:31` |

**後兩列是這次稽核唯二記載誠實的「沒做」**——它們寫的是「未接線」「刻意缺口」，
不是「pending-human」。差別在於：前者讀起來是「還沒做」，後者讀起來是「做了待驗」。

### B. 做了沒驗（碼在，沒人看過或量過）

| 項目 | 證據 |
|---|---|
| APK 拖放完整鏈 | `MirageScene.swift:31` `.dropDestination` → `AppModel+Install.swift:22` `installAPKs` → `InstallBanner.swift` |
| 焦點恢復重新捕捉 | `AppModel+Focus.swift:22` `didBecomeKey` ＋ `MouseCapture.swift:34` `didResignKey`，兩半都在 |
| keymap overlay 顯示 | `KeymapOverlay.swift` 44 行，有 `ForEach`／`Circle`／`Text` |
| letterbox | `MirrorContainerView.swift:47` `ViewportFit.fit` |
| 全螢幕 | `AppModel+FullScreen.swift:15,21` 兩個通知都接 |
| 音訊播放 | `AppModel+Audio.swift:16,21` `AudioPlayer` ＋ `setAudioSink` |
| 座標落點精度 | 換算來源改為健康探測的 `guestDisplay`（`MirrorView.swift:135` 的說明） |
| look 靈敏度 | `KeymapEngine.swift:61` 的 `/1000` 能跑，但那是佔位除數、未校準 |

### C. 已修好但文件還寫著 pending（D15 類，最會誤導）

> **中欄的行號是 2026-07-29 稽核當時的位置，不是現在的位置。** D15 的更正註記是**就地插入**的，
> 註記本身就把它抱怨的那些句子往下推。2026-07-30 逐一 `sed` 核對的結果：
>
> - `RESULTS-p1d.md:36` — **仍正確**（該行就是「不同步」那條記載本身）。
> - `README.md:77` — **已失效**。在 D4 之前（`818f80f`）它就已經指向另一段文字，
>   所以不是 D4 造成的。原記載現在是 `README.md:173` 的「已知限制」項，更正註記在 `:182-185`。
> - `README.md:29–31, 96, 102` — `:29–31` 仍是那三項未量測項目本身，更正註記在 `:32-40`；
>   `:96` 與 `:102` 在 `818f80f` 就已經是空行（同樣不是 D4 造成的），P1-e 那半的
>   刪除線在 `:210`、更正註記在 `:212-224`。三處都已帶更正註記，所以「仍重申」這個動詞本身也過時了。
>
>   （這兩個範圍在 2026-07-30 也修過一次：原本寫 `:32-35` 與 `:210-213`，指的位置對、
>   但尾端都少算了——引用區塊實際各延伸到 `:40` 與 `:224`。**一節在講「行號會過時」，
>   自己的行號卻量錯**，正好說明這件事沒有靠自覺就能免疫的版本。）
>
> 中欄的舊行號**刻意保留**——它記的是稽核當時看到什麼，改掉會讓這一節變成事後修飾過的紀錄。

| 項目 | 過時的記載（行號為稽核當時） | 實際 |
|---|---|---|
| `AppModel.profile` 與偵測啟用不同步 | `README.md:77`、`RESULTS-p1d.md:36` 仍寫「不同步、overlay 上線前須讓 activation 回寫」 | **已回寫**：`AppModel.swift:228` `case .active(let p): keymap?.reload(p); profile = p` |
| `MouseCapture` 失焦不釋放 | `RESULTS-p1c.md:39` 寫「已文件化，待補生命週期 hook」 | P1-d 已補，`MouseCapture.swift:34` |
| 全部 `pending-unlock`（螢幕鎖定） | `README.md:29–31, 96, 102` 仍重申「螢幕解鎖後補測即可」 | 歸因早已推翻，真因是 `AVAudioEngine` 的 NSException |

### D. 最重要的一項發現：阻礙已經消失，但沒人回頭重試

所有標成「pending-unlock（螢幕鎖定）」的項目——驗收線 1b／5、驗收線 6／7、
P1-e 的七項 GUI pending、`RESULTS-mmap.md` 的三項——**它們的阻礙在 NSException 修好時就沒了**。
防護現在確實在樹上（`AudioPlayer.swift:29` 的 `AVAudioFormat(interleaved: false)` 與其上方
說明「這正是鏡像顯示自 P1-a 起從未運作過的原因」）。

也就是說這批項目的正確分類**既不是「做了沒驗」也不是「根本沒做」，而是第三類：
「可以驗了，但沒人回去驗」**。§0 只給了兩個選項，這是分類本身的盲區。

> **這一類最危險**：它們在清單上長得跟「被外部條件擋住」一模一樣，於是每一輪
> 都被合理地跳過。而擋住它們的那個條件在 2026-07-28 就已經不存在了。

**2026-07-29 同日新增（D2 完成後即刻出現）**。原本只記了一項，**同日稍晚的全分支審查發現
這份清單自己也不完整**——同批新增/改動、同樣零涵蓋的還有兩項。三項如下：

1. **`MirrorMTKView.keyCode(from:)`（三行 `NSEvent` 取值）、`keyDown`/`keyUp` 覆寫、
   `onKey` 閉包接線** — **仍零涵蓋**。業務邏輯已抽進純函式 `MirageCore.KeyTranslate`
   （`KeyTranslateTests` 5 條逐行覆蓋），分流邏輯有 `KeymapControllerRoutingTests`（8 條），
   `buildKeyEvent` 有 `EmulatorClientTouchTests`——殘餘面因此很薄，但不是零：三個參數若
   「標籤對但來源錯」——例如 `hasCommand:` 誤傳 `event.modifierFlags.contains(.option)`、
   或 `characters:` 誤傳 `event.characters`（該用 `charactersIgnoringModifiers`）——型別仍
   吻合、編譯器不會擋、219 條測試也不會紅，因為它們測的是 `KeyTranslate` 本身，不是這個呼叫端。
2. **`KeymapController.handleFlagsChanged`（NSEvent → 四顆修飾鍵）＋ `MirrorView` 的
   `onFlagsChanged` 接線** — **漏記，而且一個 Critical 就住在這裡**。`handleFlagsChanged`
   原本呼叫 `handleKeyDown`/`handleKeyUp`，D2 把那兩個函式改成走 `route()` 分流之後，
   引擎不認識的 `Meta`/`Shift`/`Control`/`Alt` **全部從這條旁路被送給 guest**——直接推翻
   設計 §4.3「修飾鍵維持現狀只餵引擎」與 README「帶 ⌘ 的組合一律不直通」。
   **已於 2026-07-29 修復並補上回歸測試**：`handleFlagsChanged` 改為直接
   `emit(engine?.apply(...))`，測試 `KeymapControllerRoutingTests.modifierKeysNeverPassThroughToGuest`
   用 `NSEvent.keyEvent(with: .flagsChanged, …)` 在 headless 下合成真事件斷言零 `sendKey`
   （該 factory 已實測在 `swift test` 環境可用）。**函式本體現已涵蓋**；剩下的
   `MirrorMTKView.flagsChanged(with:)` 覆寫 → `onFlagsChanged` 閉包接線與第 1 項同性質，仍零涵蓋。
3. **`MenuBarController` 的「返回／主畫面／最近任務」→ `onAndroidKey` →
   `AppModel.startLifecycle()` 的綁定** — **漏記**。`MenuBarController.swift:101-103` 三個
   `@objc` 動作 → `AppModel.swift:246-250` 的閉包 → `client.sendKey`，單元測試零涵蓋
   （選單項要 GUI）。更糟的是**活體清單也不完整**：`verify_keyboard.sh` 的 `EXPECTED`
   原本只有四個鍵，`GoHome`／`AppSwitch` 這兩顆使用者可見功能兩邊都沒有——三顆 Android
   實體鍵只驗了 `GoBack` 一顆。**已於 2026-07-29 補上**：`EXPECTED` 加 `KEY_HOME`／
   `KEY_APPSELECT`，`KeyboardLiveTests.sequence` 同步加 `.key("GoHome")`／`.key("AppSwitch")`。

第 1 項與第 3 項的選單接線屬於**第三類：可以驗了，但沒人回頭驗**——不是「做了待人眼確認」，
也不是根本沒做。阻礙（`AVAudioEngine` 的 NSException 打死 MainActor）已於 2026-07-28 修復，
GUI 現在開得起來、鍵盤事件現在收得到，只是還沒有人回頭用 App 實際按過。驗法：
`open` 開 `.app` bundle（不要從 shell 直接跑 executable）→ 在鏡像視窗按幾個鍵、並從選單列
點「主畫面」與「最近任務」→ 同時 `adb -s <serial> shell getevent -l` 觀察是否出現對應的
`KEY_*` 事件（`KEY_A`… ／`KEY_HOME`／`KEY_APPSELECT`）。詳見 `app/README.md` 鍵盤直通段落。

> **這一筆本身就是 §8 開頭那句方法論的又一次驗證**：「稽核完整性要從逃逸路徑出發」。
> 上面第 2、3 項漏掉的原因與當初漏掉 `sendKey` 一模一樣——列清單的人只列得出自己
> 已經想到的東西。抓到它們的不是關鍵字，是「這批 diff 改了哪些檔、每一檔各有誰在測」。

**D4 新增的一筆（2026-07-29）**：`.auto` 自動啟用的端到端路徑
（seeding → 偵測命中 → `applyActivation` → `keymap?.reload`）**沒有任何自動驗證**。
不是被什麼擋住——是內建的只有 `com.example.game` 這份格式範例，不對應任何真實 App，
所以 `.auto` 永遠不會為它啟用。驗法見 `app/README.md` 的 P1-c 段。
`AppModel` 本身無法 hermetic 測試（債務 D13：光建構就有 8 個全域副作用），
所以這條在 D13 完成前只能手動驗。

**同一批裡一個更具體、可指名的殘留風險**：seed-before-detect 的時序不變式沒有任何
測試守著。`MirageScene.swift:55-57` 的 `.task` 裡三行呼叫——`model.seedBuiltInProfiles()`
→ `model.loadKeymap()` → `model.startDetection()`——依序執行是正確性的一部分：偵測
一旦命中前景 package 就會去讀 profile 目錄。目前這個順序**只靠 `:55`那行的單行程式碼
註解**（「必須在 startDetection 之前：偵測命中就會讀那個目錄」）守著，沒有任何測試
斷言它。若日後有人把 `seedBuiltInProfiles()` 移到 `startDetection()` 之後，會原地
重現 D4 要修的啟動競態，而**全部測試不會有任何一條變紅**——因為 `AppModel`／
`MirageScene` 的接線在 D13 完成前不可測，而 `BuiltInProfiles` 的測試測的是純函式
邏輯、不涉及呼叫順序。這條歸類與上面同屬第三類的相反面：不是「阻礙已消失但沒人
回頭驗」，是「正確性繫在一句註解上，沒有任何機制能在它被移動時發出警告」。

### 對 §0 的一處修正

§0 說「已知四次」誤診。本次逐項稽核後，數字應為**六類**——除了原本四項，
再加上 C 節的兩項「已修好但文件還寫著 pending」。而 D 節指出的第三種分類
（阻礙已消失、但沒人回頭）橫跨十餘筆，是本次稽核最大的單一收穫。
