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
| ~~**D5**~~ | ~~**overlay 編輯器不能拖**（29 行，只有存檔按鈕）~~ | **✅ 已修（2026-07-30，D5 階段 A＋B）**。查證後發現 D5 記載的「不能拖」是**症狀**——真正擋住使用者的更前面一步：唯一的內建 profile 是佔位 gameId，真實遊戲載不到 profile → `toggleEditing` 的 guard 直接 return → **⌘E 完全沒有反應**。只補拖曳，編輯器仍然打不開。**階段 A**：⌘E 打得開、starter 版面在記憶體、未存檔不落檔；連帶關掉 D12、D22。**階段 B**：底部抽屜（清單＋選取同步）、拖曳移動、半徑與靈敏度、未存變更的離開提示；座標一律對齊 letterbox 內容矩形（不是整個視窗）。**D5 的字面範圍到此完成。** **階段 C（新增／刪除 binding ＋ 按鍵擷取）尚未做**，範圍與已定決策見 `docs/specs/2026-07-30-d5-keymap-editor-design.md` §8。**過程中最有價值的產出不是功能，是 D35**（`#expect` 對兩邊皆 Bool 的比較永遠不會紅）——那是修這個功能時順帶挖出來的 | 實際約 2 天（A＋B） | — |
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
| **D16** | ~~MMAP transport **凍結**未解~~ → **它不是凍結，是更新率只有約 27.5%**（2026-08-05 根因調查更正）。`MmapStreamTransport` 仍 0% 覆蓋 | ~~**什麼都沒擋**——§11.2 已證明傳輸不是 fps 瓶頸~~ → **⚠️ 2026-08-05（D39）實測推翻，本列從「建議封存」升級為 P2**。§11.2 是在 **540×1200** 量的，那個解析度只用到 147 MiB/s，沒到 raw RGBA 約 270–290 MiB/s 的吞吐天花板——它的觀察沒錯，錯的是外推。Phase-1 全螢幕實際跑在 **898×1996**，同一台機器上 raw 40.0 fps／MMAP **56.7** fps；1080×2400 是 29.0／58.0。驗收線 7 的門檻 55、D48 記載的實測是 43–51。**所以這條凍結擋著的是驗收線 7 本身**，不是「什麼都沒擋」。同一次重驗也確定凍結**與 emulator 版本無關**（三版本全凍結、Python 對照全正常），不能再靠等上游解決 | **根因仍未鎖定**，但 2026-08-05 的根因調查把問題重新定義並清掉了一批假設，細節見 `app/RESULTS-mmap.md`「2026-08-05 根因調查」一節。**三件事**：(a)「凍結」是 3 幀窗口（約 150ms）造成的誤判，實際是 Swift 約 15Hz／Python 約 50Hz，交錯量測基準為 **Python 400/400 vs Swift 109–110/400**；(b) 另外 8 個假設已實測排除——HTTP/2 wire 內容等價、flow control／BDP probe、保留 fd、`O_TRUNC`、陳舊 mapping（連每幀重新 mmap 都無效）、sparse hole、inode 重建、debug/release；(c) **已讀 AOSP 原始碼**（`EmulatorService.cpp`，`emu-master-dev`）：`streamScreenshot` 的寫入與通知在同一分支，而 `getScreenshot` 的 MMAP 分支裡 `if (shm->isOpen() && shm->isMapped())` **沒有 else**——條件不成立時 `pixels` 保持未初始化值、函式仍回 OK、client 仍收到通知。但我們抓到的 wire dump 顯示通知裡帶著 `file://` handle（那只在成功路徑回填），**所以嫌疑要往「寫成功了但寫到不是我們讀的那塊」查**。**`SharedMemoryLibrary` 與底層 `SharedMemory` 已補齊**（後者在獨立 repo `platform/hardware/google/aemu`）：`borrow` 沒檢查 `shm->open()` 的回傳值、`assert(shm->size() >= size)` 在 release build 是 no-op，所以「開啟失敗仍進 map → `isMapped()` false → 落進沒有 else 的分支」這條鏈是完整的；**但 `SharedMemory_posix.cpp` 顯示 emulator 用的是 `mmap(..., MAP_SHARED)` 檔案映射，與我們的 client 完全一致**——兩邊映射同一批 physical page，「寫到別處」這個方向被排除；**(c-2) 兩個決定性實驗把環境疑慮清乾淨了**：CPU 競爭不足以解釋（Python 在 6 個競爭行程、load 23.4 下仍 174/400，而 Swift 在 load 6.5 下是 15/400）；**兩個 client 同時對同一台 emulator 時，Python 在 load 28 下拿到 376/400（94%）、Swift 單獨跑在 load 18 下只有 19/400（4.75%）**——guest 畫面產生速率、CPU 競爭、emulator 端寫入三者同時被排除，**根因確定在 grpc-swift 這條 client 路徑上**；**(c-3) 再往下四層，現象縮到最小但根因仍未鎖定**：`Image.seq` 在 wire dump 上是 **1–400 連續、零重複**（emulator 確實為 Swift 寫了 400 次）；在同一個 fd 上 `pread` 與 mmap 比對 400 次**不一致 0 次**且兩者都看不到變化（**不是 mmap 特有的問題**）；同一次跑次的內外對照——**Swift 行程內 0 次變化、外部行程同路徑同 offset 看到 182 次**，而 `fd.ino == path.ino`、size 與 mtime 皆一致，**即「Swift 那個行程對該 vnode 的整個檢視凍結了」**；最小重現（不用 emulator／gRPC，完全照 `MmapBuffer.init` 的順序再讓另一行程寫）**沒有重現**（mmap 168 種／pread 167 種），所以建立方式與 macOS UBC 一致性都正常。**(c-4) 那個實驗做了，結果是決定性的**：Swift 建檔＋持有＋讀、**Python 發請求** → Swift 讀到 **277 種**；Swift 自己發請求 → 0–23 種。**問題跟著 gRPC client 走，不是跟著持有檔案的行程走**，「Swift 行程對 vnode 的檢視凍結」那個描述因此作廢（它只在 grpc-swift 自己發請求時出現）。接著再排除兩個：**HTTP/2 SETTINGS**（讓 Python 模仿 Swift 的 `max_frame_size=16384` 與 8MB window → 106/143/130，正常）、**`MmapStreamTransport` 的 `AsyncThrowingStream` 包裝**（繞過它直接讀 `responseStream` → 23，一樣壞）。**所以是 grpc-swift 發出的請求本身讓 emulator 停止更新映射區。** **(c-5) HEADERS 解開了，wire 層內容全部等價**：Swift 送的是完全正常的 `:method/:path/:authority/:scheme/content-type/te: trailers/user-agent: grpc-swift-nio/1.27.0`，沒有多餘 metadata。唯一的實際差異是 `:authority`（Swift `localhost` vs Python `localhost:8554`），**測了不是原因**（`grpc.default_authority='localhost'` → 194 vs 195）。**所以 protobuf、SETTINGS、HEADERS 三層都等價，差異只可能在時序／TCP 層。** **最重要的未解線索**：在 client 與 emulator 之間插一個純 TCP relay（只轉發 bytes），**Swift 的 distinct 從 16 跳到 92**——proxy 唯一做的事是改變封包切分與時序。**(c-6) 時序層也查完了，三個假設全排除**：`TCP_NODELAY` grpc-swift 有設（原始碼確認）；client 處理成本不是瓶頸（量到 **平均 await=37.5ms vs snapshot=0.7ms**，且逐幀到達時間顯示**簇數=400、簇大小全 1**，不是批次到達）；**8MB target window** 這個唯一還沒測的 wire 差異也無關（調到 64KB／16KB → distinct 全是 1）。**還推翻了我自己的前提**：`await` 可以低到 **15.7ms（≈60Hz，通知速率完全正常）而 distinct 仍是 1**——「通知慢」從來不是問題，問題自始至終是「內容不更新」。**核心矛盾（給下一輪）**：emulator 的 seq 說它做了 400 次成功的 getScreenshot、通知裡帶著 handle（該欄位只在 MMAP 成功路徑回填）、emulator 用 `mmap(MAP_SHARED)` 與 client 同一批 physical page、client 端讀取正常（mmap 與 pread 零不一致）——**但內容從不改變，而同一個檔案改由 Python 發請求就正常**。這六條同時成立且互相排斥。**已超出 client 側能觀測的範圍**。**已回報上游（2026-08-06 提交）**：https://issuetracker.google.com/issues/543078932 —— 內文與完整脈絡見 `docs/upstream/2026-08-06-emulator-mmap-grpc-swift.md`（含 17 項排除清單）；重現腳本留在 `phase0/harness/split_roles_repro.swift`（未附進 issue，但走備案路徑時最快能重現不對稱）。**這條現在等上游回覆，不建議再投入 client 側的假設測試**——17 項都排除了，邊際效益極低。另一條路（自己 build 帶 log 的 emulator，在 `SharedMemoryLibrary::borrow` 與 `getScreenshot` 的 MMAP 分支插 log）保留為備案；(d) **上游 b/537802959 已於 37.2.3 修正，實測對我們無效**——37.2.3 用可靠的 400 幀窗口量到 15–18/400，與 37.2.1 的 13–16/400 無差異。這與本 repo 早就寫下的預測一致（上游修的是 0×0 pre-borrow，Mirage 一直帶明確尺寸、踩不到）。**⚠️ 2026-09-03 決定性對照（D58 工具，mirage-game、真實 Pixel Flow 畫面、900×2000、三輪交錯、負載門檻內）：Python raw RGBA 中位數 58.98、MMAP 59.57，差 0.59 fps。傳輸不是驗收線 7 的瓶頸，MMAP 沒有可量到的增益；D39 那組 raw 40／MMAP 56.7 是在 mirage-poc（GPU 關、2G RAM）用人造動畫量的，換到驗收環境不成立。現象本身（grpc-swift 發請求時更新率遠低於 Python）仍在，但它不再擋任何驗收線。見 `app/RESULTS-d58.md`「PM 把關與活體驗證」 | ~~**P2**~~ → **P3**（2026-09-03 降級：不擋驗收線 7）|
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
| ~~**D29**~~ | ~~**`coverage.sh` 從不檢查 `swift test` 的退出碼**~~ | **✅ 已修（2026-07-30），但這筆債的後果原本記錯了，一併更正。** **形式成立**：兩處 `swift test` 的退出碼確實從未被讀取。**後果不成立**——原本（與觸發本次修復的那份審查）寫的是「測試紅了仍會 exit 0」，2026-07-30 實測**推翻**：注入一條必失敗的測試後，SwiftPM 產生 `.profraw` 但**不產生 `default.profdata`**（測試失敗就跳過 merge），於是既有的 `[ ! -f default.profdata ]` 守門照樣 `exit 1`。**沒有假綠燈。** 真正的問題比原記載小一級，但仍值得修：(a) 那道防護是**附帶的、未載明的**——它依賴 「SwiftPM 測試失敗時不 merge」這個沒有任何文件保證的實作細節，哪天改成失敗也 merge，腳本會**靜默**開始對紅測試印綠報告；(b) 失敗訊息把成因寫成「未產生 default.profdata（測試可能失敗）」，要讀的人自己猜。修法：兩處改用 `${PIPESTATUS[0]}` 明確檢查。**刻意不加 `set -e`**——Run 2 是 `swift test … | grep -E`，grep 沒配到就回 1，加了 `-e` 會殺掉一次正常跑次；理由已寫進腳本，免得下一個人「順手補上」。**已注入故障驗過會紅**（`COVERAGE_EXIT=1` ＋ 具名訊息），移除後乾淨跑 `COVERAGE_EXIT=0`，段 1 line 88.95%、段 2 line 10.64%，兩段皆未低於記錄值。過程中另修掉一個自己寫出來的 bug：`$VAR）` 後面接**全形**右括號會被 bash 吃進變數名，`set -u` 當場炸——這在通篇中文的腳本裡會再犯，已在腳本註明「變數後接全形標點一律夾大括號」。**成本**：實際約 30 分鐘 | — |
| ~~**D30**~~ | ~~**啟動流程不是 one-shot，卻掛在 `WindowGroup` 的 `.task`**：`.task` 每個視窗跑一次、`@State model` 整個 App 一份，⌘N 就會對同一個 `AppModel` 重跑整段啟動序列~~ | **✅ 已修（2026-07-30）。先端到端重現，再修。** **重現**（`WindowGroup` 版，實機點選 File ▸ New Mirage Window）：`[app] endpoint=` 印**兩次**、`[profile]` 也印兩次——整段啟動序列確實在同一個 `AppModel` 上重跑。**A/B 對照**：`WindowGroup` 的選單列是 `Apple, Mirage, File, Edit, View, Window, Help`，File 選單內含 `New Mirage Window`；改用 `Window`（單一實例場景）後**連 File 選單都不存在**。修法刻意不是在 `.task` 加旗標——旗標讓「可以有兩個視窗」這個錯誤前提繼續存在、只擋住其中一個後果；Mirage 鏡像一台模擬器本來就只該有一個視窗，換成 `Window` 之後重複啟動在結構上不存在，順帶讓 `NSApp.windows.first` 不再有歧義。**另加一道 actor 層守門**：`EmulatorClient.start()` 原本直接覆寫 `loopTask`（舊 Task 不取消、`running` 仍是 true，兩條連線迴圈同時搶 `attachStream()`），改為已在跑就忽略並**印一行具名警告**——它在重現實驗中確實觸發了，證明守門在真實 App 裡有效；不靜默是刻意的，因為「沒有訊號」正是這筆債藏這麼久的原因。單元測試 `EmulatorClientStartOnceTests`（RED 時 `subscribeCount → 2`）。**「關閉視窗會不會重跑 `.task`」已實測不會**（原本只是推論）：⌘W 關閉（`windowShouldClose` 回 false ＋ `orderOut`）→ `open` 重新啟用 → 選單列「顯示視窗」，三條路徑走完 `[app] endpoint=` 始終只有 1 行、零重複警告 | 實際約 2 小時 | — |
| **D31** | **`SnapshotRoundTripLiveTests` 名不副實，且它驗的是死碼**。該測試**刻意只驗 save**（註解寫明：在運行中的模擬器上 `loadSnapshot` 會使模擬器崩潰，canary 37.2.1，載入 ~2.3GB RAM 快照進 live VM，且與 spec §8 矛盾），所以名字裡的 `RoundTrip` 描述的是一件刻意不做的事。它驗的 `GrpcSnapshotService` 又正好是 D14 記載的死碼 | 看到 `SnapshotRoundTripLiveTests` 綠燈，合理推論是「快照存取來回驗過了」——**兩層都不成立**：只驗了 save，而且驗的服務產品從不呼叫。`verify_snapshot.sh` 的檔頭原本也寫著「save → 改變畫面 → load」，已於 D9 加上更正註記並在輸出裡如實列出涵蓋範圍，但**測試名字本身還沒改** | 30 分鐘 | P2 |
| ~~**D32**~~ | **`verify_audio.sh` 原本印的「under == 0 → 驗收線 6 的必要條件」在該測試情境下不成立**，而驗收線 6 目前**沒有任何自動化涵蓋**。`drainRingAtRealTimeRate`（`AudioLiveTests.swift:14`）每 10ms **無條件**讀 960 樣本、且從 t=0 就開始讀（連線都還沒建立），5 秒 = 500 次讀取，所以 underrun 結構上必然很大（實測 406／407）。那個 drain 存在的目的只是避免緩衝填滿讓 `writes` 卡住（見該檔 line 11-13），不模擬真實播放；測試自己也只斷言 `writes` | **這條差點被我自己做成假紅燈**：D9 修訂時一度把它做成硬性斷言，跑出來才發現不成立（已改成如實報告數字並說明為何不是判準）。真正的代價是驗收線 6（音訊不拖垮鏡像）只能靠 GUI App 下 `MIRAGE_AUDIO_LOG=1` 人工觀察 60 秒——**零自動化**，而設計文件 §197 正是為此承諾「畫面與輸入完全不受影響」（§3 第 3 項記載它就是三階段黑畫面的根因本體）。修法：讓 live 測試接上真正的消費端節奏，或明確承認驗收線 6 無自動涵蓋並記進驗收表 **✅ 自動化涵蓋已建立（2026-08-03）；驗收線 6 本身判定為未通過。** `app/scripts/verify_audio_gui.sh` 在真 GUI + 真 `AudioPlayer` 下量 60 秒，六條斷言（App 存活／串流活著／連續有聲期間的 underrun 增量／fps／重新蓄水次數／畸形行），四條故障注入皆證明會紅。**真正的發現不是自動化本身**：第一次量出來就揭露驗收線 6 一直是**實質不通過**，而且從來沒有人量過——`under` 每秒增加約 90、`depth` 全程 0ms、`over` 恆為 0，環形緩衝從來沒有積過水。根因是**完全沒有 pre-roll**，已修（`AudioRingBuffer.primeThresholdSamples` 預設 100ms；修法放在緩衝而非播放器，因為 `AudioPlayer` 在 executable target 裡沒有任何單元測試碰得到）。修正後 `USUM` 從 5481 降到約 150（**-97%**）、`depth` 中位 46ms。**但仍判未通過**：`PRIMES`≈35，即 60 秒內排乾 35 次、平均每 1.7 秒一次，每次賠約 100ms 靜音 ≈ 全程 5.8% 在靜音。殘餘缺陷另記為 **D44**。`verify_audio_gui.sh` 的六條斷言因此定位為**回歸偵測**（不要比 2026-08-03 的基準更糟），腳本自己會印出這個區別，**綠燈不等於驗收線 6 通過**。**另外發現三件事**：(1) 人工驗收（headless 不驅動 `.task`）的理由在 2026-07-28 就被推翻了，沒人回頭驗；(2) 驗收線 6 的字面判準（`underruns == 0`）與 spec §5 自相矛盾（靜音期必然欠位），已重新表述並在 spec 加更正註記；(3) `verify_common_selftest.sh` 從 D9 就存在卻從沒被 CI 跑過，已補為閘門 7（現在跑兩支自我測試）。**另記一筆**：驗收線 7（fps ≥ 55）被列為人工驗收的理由與驗收線 6 完全相同、同樣已失效，而 `verify_game_fps.sh` 早就在量 fps，但本次未重驗。 | 半天 | P2 |
| ~~**D33**~~ | **AVD provisioning 完全靠人手，產品沒有一行碼能重現測試環境**。三台 AVD（`mirage-poc`／`mirage-game`／`mirage-bench`）是人手工用 curl 下載映像 + 手寫 `config.ini` 建的，彼此設定還不一致（§4：`poc` 是 `gpu.enabled=no/mode=auto/ram=2G`，另兩台是 `yes/host/4096`）。**這筆先前沒有編號**，只活在 §6 表格下方的一段散文裡——而沒有編號的東西每一輪都會被合理地跳過，正是 §0 記載的誤診模式 | **它讓 Phase-1 唯一通過的驗收線站不住**。「1 款指標遊戲開箱即玩 ✅」目前的實際意思是「有人先幫你把箱子拆好」——換第二個人、換一台機器，沒有任何自動化路徑能到達那個狀態。與 D17（canary emulator 裝上後從未還原 stable）同一族：**環境是手工管理的**，所以所有 fps/延遲數字的可重現性都建立在一個沒人維護的前提上。**兩條出路，選哪條都行，但不能什麼都不做**：(a) 寫一支冪等的 provisioning 腳本；(b) 若 provisioning 明確不在 Phase-1 範圍，就在驗收表上寫明「開箱即玩」的前提是預先備妥的 AVD——不能讓那個 ✅ 裸著，讓讀的人以為它涵蓋了它其實沒涵蓋的東西 | **✅ 已修（(b) 2026-07-30，(a) 2026-07-31）**。(b)：§6 的 ✅ 已標明前提。(a)：`tools/provision/` 可由 manifest 重建 SDK 與兩台 AVD，不依賴 JDK。**天花板沒有變**——Play Store 登入不可自動化，自動化只到「兩台一致的 AVD 可被重建」。三台收成兩台（統一後 `mirage-bench` 與 `mirage-poc` 完全重複），既有的 `mirage-bench` 不動。 | **P1**（先做 (b)，(a) 看 Phase-1 範圍決定）|
| **D34** | **D5 階段 A 留下的小債（最終全分支審查分流後未修的部分）**。(a) `BuiltInProfiles.fallbackStarterBindings` 與 `Resources/profiles/com.example.game.json` 的 bindings **逐欄位完全相同**，所以 bundle 讀取路徑徹底壞掉時行為上看不出來——沒有任何東西維持兩者同步，也沒有任何訊號會告訴你退回了 fallback；(b) `AppModel.toggleEditing` 的 `.enter` 對「已有 profile」也無條件 `keymap?.reload(p)`，把引擎連同 `pressed` 整顆換掉（**D23 那一族**）；(c) ~~`AppModel.swift:340/362` 與 `AppModel+FullScreen.swift:13` 仍有未經 Optional 轉型保護的 `NSApp` 直接使用~~ → **已修（2026-07-30，階段 B Task 1），但當初對它的風險評估是錯的，一併更正**：原記載說「階段 B 一建立有引擎的 `AppModel` 就會以 signal 5 炸開」——**結構上不成立**。實測＋逐步讀碼確認：這三處在目前的呼叫圖裡**永遠不會**以 nil `NSApp` 被執行到，因為它們全都晚於 `startLifecycle()` 內的 `MenuBarController` 建構，而**那一步本身就會把 `NSApp` 從 nil 撥成非 nil**（建 `NSStatusBar` 狀態項會觸發 `NSApplication` 的惰性初始化）。`wake()` 是 private 且唯一呼叫點是 `MenuBarController` 綁的回呼；`setupFullScreen` 的閉包同理。**對照組**：階段 A 真的崩掉的 `shouldCapture` 走的是 `loadKeymap()`／`toggleEditing()`，**不經過 `startLifecycle()`**——那才是它會崩而這三處不會的原因。保護仍然保留（防禦性、與既有先例一致、呼叫圖日後可能改變），但**刻意不附回歸測試**：曾寫過一條，實測在有無保護時都綠，已刪除——一條自證無鑑別力的測試比沒有測試更糟；(d) 每次 ⌘E（含離開）都呼叫 `starterBindings()`，產品路徑上那是 `Bundle.module.urls` ＋ `Data(contentsOf:)` ＋ JSON decode 跑在 MainActor 上，而只有一個分支用得到；(e) 編輯途中前景遊戲切換時，選單列會短暫顯示新 package 配舊引擎的 active 狀態（離開編輯時自我修正）；(f) `constructsWithInjectedDependencies` 其實沒有驗證 store 注入（刪掉 `self.store = store` 它照樣綠），名字與 docstring 過度承諾 | 沒有一項擋住階段 A 合併——最終審查已逐條分流過。**(a) 與 (c) 是會咬人的兩項**：(a) 屬本 repo 最在意的「東西壞掉卻沒有訊號」那一類；(c) 在階段 B 建立有引擎的 `AppModel` 時會以「整個 test run 收到 signal 5」的形式炸開，而錯誤訊息完全不指向成因（本輪已在 `shouldCapture` 上實測過這個崩法）。(b) 應與 D23 一起處理 | 各 10 分鐘–1 小時 | P2 |
| **D35** | **`#expect` 對「兩邊皆 Bool 的頂層二元運算子」永遠不會紅——`#expect(false == true)` 通過**。根因：`app/Package.swift` 仍宣告外部 `swift-testing` 依賴（`Package.resolved` 釘 0.99.0），而 toolchain 自己內建。機制已定位到套件原始碼：`ExpectationChecking+Macro.swift:170` 的泛型 `__checkBinaryOperation` 標了 `@_disfavoredOverload`，而 `:773` 給 `??` 解包用的 `T?` 版**沒標**；`Bool == Bool` 產出的 `Bool` 可隱式提升成 `Bool?`，於是未標記的勝出，流進 `:733` **只檢查非 nil** 的 `__checkValue` → `Optional(false)` 非 nil → 通過。**精確邊界**：失效的是 `boolA == boolB`／`!=`／`?? false`；**不失效**的是 `&&`／`\|\|`（`Bool? && Bool?` 不成立）、非 Bool 的 `==`、`#expect(x)`、`#expect(!x)` | **2026-07-30 實測：52 條斷言橫跨 9 檔從未檢查過任何東西**，其中包含多條專門用來守護不變量的（`isDirty == true`、`hasProfile == true`、`isValid == true`…）。已全數重寫、302 條全綠——**沒有藏著真 bug**，但那是運氣不是保證。**整個 session 每次編譯都在印 `'Suite' is deprecated: … Remove your 'swift-testing' package dependency`，而它被當成雜訊、兩度被記成 deferred minor**——那句警告從頭到尾都在指向這件事。**存量清了，根因沒修**：明天有人再寫一條就又開一個永遠不紅的洞。與 D3（假 skip）／D26（哨兵盲區）同一族 | **2026-07-30 已加 `ci.sh` 閘門 5**（字面 `true`/`false` 形式；已用故障注入證明會紅——注入的 `#expect(x == true)`（`x = false`）**測試本身通過**、閘門抓到並讓 `CI_EXIT=1`，正好又示範一次病灶）。**閘門有盲區**：非字面值的 `Bool == Bool`（如 `#expect(a.isEmpty == b.isEmpty)`）grep 沒有型別資訊、抓不到，全庫現況 0 條命中。**根治＝移除 `Package.swift` 的外部 swift-testing 依賴，需裝 Xcode**（本機 CommandLineTools 不 vend 內建 Testing，`missing required module '_TestingInternals'`）——盲區要等根治才會真正消失。**成本**：閘門已完成／根治看 Xcode | **P2**（降級：復發已有閘門擋） |
| **D36** | **存檔失敗沒有使用者可見的訊息**。`AppModel.saveProfile` 失敗只印一行 console （`[keymap] profile save failed:`）。2026-07-30 的 D5-B fix wave 已讓失敗**不再靜默丟資料**（保持髒、不離開、對話框留著），但使用者看到的仍只是「對話框沒關、存檔鍵還亮著」 | 足以避免資料遺失，不足以說明原因——使用者不知道該怎麼辦（磁碟滿？權限？）。另有一個**待人工驗收**的相關風險：`MirageScene` 的 alert binding 改成 `set: { _ in }` 之後，若 SwiftUI 不會因為 binding 仍為 true 而重新呈現對話框，可能停在「對話框消失但旗標永遠 true」→ 再按 ⌘E 形同無反應且無其他出口（資料仍安全）。已列為 D5-B 人工驗收清單第 1 項 | 1 小時 | P2 |
| **D37** | **`tools/probe/tests/` 的 13 個測試檔從未被跑過**。全部用 pytest，而本機沒裝 pytest（`python3 -m pytest` → `No module named pytest`）、沒有 requirements、沒有入口、不在 `ci.sh` 裡 | 與 D3（假 skip）同一族：**存在但不執行的測試比沒有測試更糟**，因為它讓人以為有涵蓋。13 個檔案涵蓋 coords／gesture／targets／framebuffer 等 probe 的核心邏輯，全都沒有保護 | 改寫成 unittest 併入 `ci.sh` 閘門 6，或加 requirements 並讓閘門裝 pytest。前者與 D33 的選擇一致（零依賴）。**成本**：半天 | P2 |
| **D38** | `mirage-poc.avd/config.ini` 帶字面上未取代的範本佔位符（`avd.id = <build>`、`avd.name = <build>`、`disk.dataPartition.path = <temp>`） | 它照樣能跑，所以不是功能問題；但它是**手工環境的具體證據**，也說明當初的建立程序沒有任何檢查 | `tools/provision/provision.py --apply` 會修正。**成本**：1 分鐘 | P3 |
| ~~**D39**~~ | ~~**MMAP transport 的重驗前提可能已經成立**~~ | **✅ 已重驗（2026-08-05）——結論是「等新版」這個前提從一開始就不成立，且順帶推翻了 D16 的封存建議。** 實測三個 emulator 版本（37.1.11 stable／37.2.1 canary／37.2.3 dev，後者是 manifest 上最新的 build 15982021），`MmapStreamLiveTests` **全部凍結**（`frames=3 distinct=1`）；而同一台 emulator、同尺寸 540×1200、handle 同樣放 `$TMPDIR`、同樣先 `getStatus` 的 **Python(grpcio) 對照全部正常**（`frames=30 distinct=30`，跨約 520ms）。**凍結與 emulator 版本無關**，該查的是 grpc-swift 這條路徑。這件事 `RESULTS-mmap.md` 自己早就預告過（「上游修的 0×0 pre-borrow 與本階段的凍結不是同一個現象」），只是沒人回頭質疑那個等待前提——與 D32／D45 完全同型。**第二個推翻更重要**：「先確認它要解的問題還存在」這條指示照做了，結果是**問題不但存在，還比原本以為的嚴重**——`bench_mmap_vs_rgba.py` 在同一台機器上重掃，raw RGBA 這條路徑的吞吐天花板在 **270–290 MiB/s**，540×1200 只用到 147 MiB/s 所以看不到瓶頸（§11.2 的觀察沒錯，錯的是把它外推成「不是瓶頸」），但**全螢幕 898×1996 上 raw 是 40.0 fps、MMAP 是 56.7 fps**（1080×2400 更懸殊：29.0 vs 58.0）。驗收線 7 的門檻是 55。**限定**：這是 Python client 量到的鏈路能力上限，Swift 路徑凍結、一格都拿不到；內容是 `animate.py` 人造動畫非真遊戲；load≈7。自動化涵蓋：`verify_mmap.sh` 改寫，現在**同時**跑 Python 對照（硬斷言）與 Swift 活體（印退出碼不中止），紅燈第一次能分辨「上游壞了」與「我們的 client 壞了」；順帶修掉驗收線 6 那條恆為 PASS 的假斷言（glob `/tmp` 但 `NSTemporaryDirectory()` 給的是 `$TMPDIR`），兩條新斷言皆已故障注入證明會紅。殘餘缺陷見 **D16**（升級）與 **D52** | 實際約 2 小時 | — |
| **D40** | **`tools/provision` 碰網路與 AVD 寫入的那一層測試 0 覆蓋**：`fetch.download`、`fetch.fetch_text`、`provision._resolve`、`provision._avd_rows` 四者在 `tests/` 裡零直接呼叫（`_resolve` 一律被 mock）。| 這條分支已經發生過兩次「mocked 測試全綠卻藏著 Critical bug」（`zipfile` 不還原權限、Google 原始 zip 不含 `package.xml`），兩次都長在這一層。`download` 的 `.part` 清理、size 檢查、`os.replace` 順序目前沒有任何回歸哨兵 | 用 `http.server` 起一個本機 server 餵已知 bytes，就能離線測 `download`／`fetch_text` 的完整路徑。**成本**：半天 | P2 |
| **D41** | **`image.sysdir.1` 與 pin 的 `install_path` 是兩個各寫各的字串，沒有任何程式或測試把它們綁在一起**，且 `android-35` 散在 4 個檔案 8 處 | 升 android-36 時只改 `versions.py` 沒改 `avdspec.py`，會裝好新映像但 config.ini 指向已不存在的舊路徑，而**工具回報 ✓ exit 0**、`emulator -avd` 以「Cannot find system image」失敗。另有今天就成立的失效：`--sdk-root /opt/sdk` 寫出的 `image.sysdir.1` 是相對路徑，模擬器用它自己的 SDK root 去解 | 讓 `image.sysdir.1` 由 pin 的 `install_path` 導出；API 版本收斂成單一常數。**成本**：2 小時 | P2 |
| ~~**D42**~~ | ~~**`tools/provision` 產出的 AVD 從來沒有人開過機**~~ | **✅ 已修（2026-08-03）**。新增 `app/scripts/verify_provisioned_avd.sh`：產生兩台到暫存 AVD home → 各冷開機一次 → 斷言規格 → 清乾淨。**實測結果**：`mirage-poc` 25–31 秒、`mirage-game` 41 秒到 `sys.boot_completed=1`；兩台的解析度 1080x2400／density 420／abi arm64-v8a／SDK 35／MemTotal 4,015,044 kB 全部相符，**Play Store 套件數 0 vs 1** 證明兩份映像確實掛對。**兩台只差在映像，其餘一字不差**——這正是「跨台 fps 數字可直接比較」的前提，現在是示範不是宣稱。**已用故障注入證明會紅**：把 `config_base.py` 的 `hw.lcd.width` 改成 720，模擬器真的以 720x2400 開起來、斷言抓到、`exit=1`——從 `AvdSpec` 到 guest 實際解析度整條鏈都是活的。順帶在 `verify_common.sh` 補了 `assert_equals`（含三條自我測試，其中「實測為空 → 中止」擋的是 `getprop` 在裝置沒回應時回空字串、把空字串當成相等會讓整組蒐證假綠）。全程用 `ANDROID_AVD_HOME` 指到暫存目錄，`~/.android/avd` 的 mtime 前後未變 | 實際 40 分鐘 | — |
| **D43** | `tools/provision` 最終審查殘留的五個小問題 | 皆不影響正確性：(a) `lib/report.py` 的 `{row.label:<34}` 對不上真實最長 55 字元的 label（`system-images;android-35;google_apis_playstore;arm64-v8a`），欄位對齊全垮；(b) `provision.py` 的漂移訊息會把 Python 的 `None` 漏進使用者可見文字（該處語意其實是「這個 key 應被移除」）；(c) 設計文件 §9 寫 backup 是 `<name>.old-<revision>`，實作是 `.provision-old`；(d) `tools/provision/__init__.py` 是死碼（沒有 `tools/__init__.py`，`tools.provision` 永遠不可匯入）；(e) `kill -9` 留下的孤兒 `.provision-old` 最大 2.31 GB，且**恰好在那個視窗 `install_dir` 不存在，所以下次跑的清理分支不會走到**，會永久留著 | 各自獨立，可分批。**成本**：1 小時 | P3 |
| **D44** | **音訊每 1.7 秒靜音一次**：pre-roll（D32）讓 underrun 降 97%，但實測 `PRIMES`≈35／60 秒——緩衝蓄到約 94ms 後被磨到 0，週而復始，每次重新蓄水賠約 100ms 靜音，全程約 5.8% 在靜音。反推生產端供應量長期約為消費需求的 **94%**（⚠️ **2026-08-07 更正：這個 94% 是錯的，連帶三個候選解法的前提一起作廢。** 它是拿 `writes`（**封包**數）乘上一個假設的包大小（「每包 960 samples」——只寫在 `AudioRingBuffer.init` 的一句註解裡，沒有任何程式或測試強制它）推出來的。為此在 `AudioStats` 加了 `writtenSamples`（累計**樣本**數，直接取單調遞增的 `writeIndex`，免費）並讓每秒日誌印 `supply=`，重量的結果是：**實際平均包大小 68.6 samples，不是 960**；供應約 **6,200 samples/秒**，而 48kHz×2ch 的名目需求是 96,000——**供應率約 6.5%，不是 94%**。`over=0` 全程成立，排除了「送到但被丟棄」。緩衝的實際週期因此是「不供應時以 6,200/s 蓄水約 1.5 秒到 96ms（貼著 9,600 的 pre-roll 門檻）→ 放行 → 需求遠大於供應而瞬間排乾」，與 `primes`≈37／56 秒吻合。**差 15 倍不是 rate adaptation 能救的**，所以原列的三個方向（加大緩衝／低水位滯後／rate adaptation）全部建立在錯誤前提上。**真正待答的是另一個二選一**：(1) guest 本來就幾乎沒有聲音（選單畫面音效稀疏），那 6,200/s 就是實際內容量、系統沒壞，錯的是「連續發聲」這個前置假設與判準；(2) 串流交付的音訊遠少於格式宣稱的量，那是傳輸層缺陷。這正是 `EmulatorClient.swift` 早就記下的盲區（「`pkt=0` 跟 guest 本來就靜音無法區分」）——現在發現它不只影響 `pkt=0`，**任何供應量的解讀都受這個歧義影響**。）：emulator 的音訊時鐘與 Mac CoreAudio 時鐘是兩個獨立時鐘，系統裡**沒有任何 rate adaptation** 對抗漂移。**聽感未經人耳驗證**：修正把「連續細微破音」換成「每 1.7 秒一段 100ms 靜音」，兩者難聽程度量測答不了，「已大幅改善」是量測敘述而非聽感敘述 | 三個方向，未定案：(a) 加大緩衝容量（現 200ms）並提高 pre-roll 門檻——治標，延長週期但仍會排乾；(b) 低水位滯後（跌破門檻某個分數就重置），能減少「排乾瞬間」的硬切但不解決供應不足；(c) 真正的 rate adaptation（消費端偵測水位持續偏低就輕微重採樣放慢）——正解但複雜度高。**決定前應先量清楚 94% 這個數字的來源**：是時鐘漂移、還是 guest 端本來就有丟包／靜音段落，兩者的解法完全不同；同時應做人耳驗證確認靜音迴圈相對於原始破音的聽感優劣 **⚠️ 2026-08-07 追到底了，結論是「每一層都正常」。** 依序排除，每一項都有量測：(a) 供應只差 6% → 錯，是 6.5%，原數字用錯了包大小；(b) guest 沒聲音 → 當時看 `Frames written` 得到 93.6%，但**那個欄位數的是輸出執行緒寫進 HAL 的幀（含靜音），不是音訊內容量**，那個解讀是錯的；(c) 我們丟包 → `over=0` 全程；(d) `modeRealTime` 讓 emulator 丟音訊 → 換 `modeUnspecified` 是 5.9% vs 6.8%，無差別（順帶證實 proto 的 `[Input Only]` 標記屬實）；(e) emulator 沒照要求的格式送 → 實測 48000/stereo/S16，完全照做；(f) grpc-swift 的問題（同 D16）→ **Python client 拿到一模一樣的 6.5%**，與 D16 的指紋（Python 100%／Swift 4%）相反，兩債無關。**決定性實驗**：在 guest 播一段連續滿幅度 440Hz 正弦波，emulator 交付 **100.0%**（每包 2289 bytes）；換回 Pixel Flow 的畫面則是 6.5%（每包 137 bytes）。**所以 emulator 的 `streamAudio` 沒有任何損耗，是那個遊戲畫面本來就只產生約 6.5% 的非靜音內容。** D44 記載的「每 1.7 秒靜音一次」是真的，但成因是內容稀疏，不是時鐘漂移、不是缺 rate adaptation、不是傳輸缺陷。**真正的缺陷在量測**：腳本檔頭把「遊戲必須停在會連續發聲的畫面」列為前置，但 A2 只檢查「有封包的秒數」，而稀疏音效每秒照樣有 92 個封包——那個前置條件從來沒有被驗證過。已補 **A2b 前置閘門**（`SUPPLY_MIN` 預設 90；實測稀疏 6.5%／連續 100%，差 15 倍），與 D56 為 fps 加的逐輪 guest 門檻同一個形狀：上游有一個量決定「這一輪算不算數」，而沒有人在看它。失效方向是紅燈、不可能製造假綠燈，實跑驗證過會擋（A1/A2 綠、A2b 紅）。**驗收線 6 因此要在符合前提的畫面上重量才有結論**——先前所有判定都可能是在不符前提的環境下做的。對照工具：`phase0/harness/audio_client_parity.py`。 | 未估 | P2 |
| ~~**D45**~~ | ~~**驗收線 7（`MIRAGE_FPS_LOG ≥ 55`）需要重驗**。它被列 `pending-human` 的理由與驗收線 6 完全相同（「headless 不驅動 `.task`」），該理由已於 2026-07-28 失效，但只有驗收線 6 被 D32 回頭重驗——驗收線 7 這件事目前只散落記在 `project-review.md` D32 那列的「另記一筆」與 `RESULTS-p1e.md` 的一句「同樣可疑，但本次未重驗」，`RESULTS-p1e.md` 驗收表第 7 列本身**仍原封不動**寫著已被推翻的舊歸因。**這正是 D33 那列自己寫下的教訓：沒有編號的東西每一輪都會被合理地跳過**~~ | **✅ 已修（2026-08-04）**。已重驗：全螢幕解析度上限下（本機收斂到 898×1996，見 `app/RESULTS-d45-probe.md`）四次乾淨的三輪量測 `MIRAGE_FPS_LOG` 中位數為 **49／43／51／43**，全部低於門檻 55，**判定未通過**。原提案「把判準改成相對於對照組的相對值」在執行途中被實測推翻——對照組同條件下可達 41–59.93，一度超過 55，證明 55 是「差一點」而非「結構上不可能」；使用者裁決 `≥ 55` **保留不改**，完整推翻過程見 `docs/specs/2026-08-04-d45-acceptance-7-remeasure-design.md` §9。`app/RESULTS-p1e.md` 第 7 列與 `docs/specs/2026-07-26-p1e-fullscreen-audio-design.md` §8-7 均已同步更新，不再殘留已被推翻的舊歸因。自動化涵蓋於 `app/scripts/verify_fps_fullscreen.sh`。**殘餘效能問題（Mirage 43–51 vs 目標 55）另記為 D48**，不在本次範圍 | 實際約 1 天（Task 1–6） | — |
| **D46** | **pre-roll 對短音效與音訊延遲的影響未評估**。門檻 9600 samples＝100ms，蓄水期**沒有任何逾時或 flush 路徑**：若某次發聲送進來的資料總量少於 100ms（例如一個 60ms 的點擊音效），`readStereo` 會永遠回 0，那段音效不會被播出，留在緩衝裡直到下次發聲把水位補過門檻——屆時使用者會先聽到幾秒前的殘留片段。而且 `under` 不增、`depth` 看起來健康、`pkt=0` 的秒又被 `audio_stats` 排除，**六條斷言對這個情境全部盲**。此外播放一律晚 100ms 起跑 | **嚴重度未知**：guest 端 AudioFlinger 在音效播完後通常還會寫一段靜音才進 standby，若那段靜音也成為封包，水位會被補滿、退化成「只有 +100ms 延遲」而非丟音效。最便宜的實驗：`MIRAGE_AUDIO_LOG=1` 開著，在只有點擊才出聲的畫面點一下，看 `pkt>0` 持續幾行、`primes` 有沒有跳 | 1 小時（先做最便宜的實驗定嚴重度） | P2 |
| **D47** | **`A4 fps 取樣筆數 ≥ 1` 太鬆，抓不到「畫面跑到一半凍住」**。`Renderer.swift` 的 `fps=` 只在有幀真的被 present 時才印，所以畫面在第 5 秒後整個凍住時：`FPS_SAMPLES=5 ≥ 1` 過、`FPS_AVG` 是那 5 行的平均也過、`AUDIO_LINES` 照樣 60（那個 Task 在 MainActor 上沒死）、A2/A3/A5 都是音訊指標不受影響——**六條斷言全綠**。A4 存在的理由正是「音訊拖垮鏡像時這條與 A1 一起紅」，它現在只抓得到「從頭到尾一幀都沒 present」 | 候選修法：改成 `$((DURATION * 8 / 10))`（五次實測 `FPS_SAMPLES` 是 60–64，60 秒下門檻 48 有 22% 裕度）。**但有真實取捨**：`streamScreenshot` 是變化驅動的，畫面靜止的秒本來就不出幀，靜態關卡會少行。**另外**：`FPS_AVG ≥ 27` 是六條裡最容易假紅的（基準 34–46 只有 20% 裕度，本分支自己就有連續四次因主機負載量到 0/5/14/24）。**D45 已定案**：驗收線 7 的 `≥ 55` 保留不改，所以這裡的 A4 `FPS_AVG ≥ 27` 維持絕對值形式即可，不需要為了對齊 D45 而改成相對判準 | 2 小時 | P2 |
| **D48** | **fps 未達驗收線 7**：Mirage 側全螢幕串流解析度上限下的 `MIRAGE_FPS_LOG` 中位數 43–51（**2026-08-06 又量到 31／48／54，中位數 48**），門檻 55。已知上限是 60（60Hz vsync 硬天花板）——~~guest 端（Pixel Flow 的 Unity SurfaceView）用 `dumpsys SurfaceFlinger --timestats` 實測穩定 **59.9 fps**、`droppedFrames=0`（`app/RESULTS-d45-guest-render.md`），所以驗收線 7 等於「**全鏈路（guest→直拉對照組→Mirage）總損失不得超過約 8.3%**」（`(60-55)/60`）。**瓶頸不在 guest render**~~ → **⚠️ 2026-08-06 實測推翻：那個 59.9 是在 load≈3 的 headless 安靜窗口量的；真實負載（真 GUI 全螢幕）下 guest 只有 49.18 fps。** guest 自己就先掉了 18%，「總損失預算 8.3%」這個框架在實際量測條件下不適用。⚠️ **`droppedFrames=0` 不能反駁這件事**——它只表示 SurfaceFlinger 沒丟棄「已提交」的幀，不表示 Unity 送滿了 60；真實負載下 Unity 送得少，`droppedFrames` 照樣是 0。**repo 內任何只引用 `droppedFrames=0` 的推論都要重新檢查。** 另：`docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §11.2 原本「瓶頸在 guest」的推論被 2026-08-04 量測推翻（該文件已加註記），但 2026-08-06 這次等於**部分恢復**了它——在真實負載下 guest 確實是損失的一部分 | 8.3% 的總損失預算非常窄，任何單一環節（guest→直拉對照組的傳輸/編碼、或直拉對照組→Mirage 的 macOS 端解碼/Metal 貼圖上傳/視窗合成）的低效都可能吃光它。瓶頸落在這兩段之間的哪一段、各自的損失多少，D45 沒有拆解——這條線在動 `app/Sources/` 產品碼之前結構上不可能轉綠（例如已知的 `MirageScene.swift` 缺 `.ignoresSafeArea()`，或更根本的渲染/傳輸路徑優化） | 未估。**⚠️ 2026-08-06 實驗做完了，結果推翻本列上面那段歸因的主要部分**（`app/scripts/verify_fps_with_guest.sh -r 3 -d 20`；**該腳本已於 2026-08-06 併入 `verify_fps_fullscreen.sh` 並刪除**——它的整段 timestats 窗口與新的逐輪 `-clear` 互相衝突。完整記錄見 `app/RESULTS-d45-guest-render.md`「2026-08-06 補測」）：**真實負載下 guest 只有 49.18 fps，不是 59.9。**（`totalFrames=11854`、`droppedFrames=0`、`displayOnTime=241.03s`）——**所以「瓶頸不在 guest render」只在安靜窗口成立，在驗收線 7 實際量測的條件下不成立**，本列「已知上限是 60、guest 穩定 59.9、所以驗收線 7 等於全鏈路損失不得超過 8.3%」這個框架**在真實條件下不適用**：guest 自己就先掉了 18%。同一次三輪的 Mirage 中位數是 **31／48／54（總中位數 48）**、直拉對照組 52.17／52.53／49.94——**第 3 輪 Mirage（54）高於同輪對照組（49.94）**，也就是說 Mirage 自己那段（macOS 解碼／Metal／視窗合成）的額外損失遠小於本列原本推估的規模，真正跟著變動的是 guest 產出速率，而它跟著主機負載走。⚠️ **這個比較有已知的不對齊**（guest 窗口 241s 涵蓋三輪＋間隔＋啟動＋一次 65.83s 重編，Mirage 是各輪 20s 窗口的中位數），只支撐「量級相當」，不支撐精確歸因。**✅ 逐輪對齊已於 2026-08-06 隨 D56 完成**（原本這裡誤記成 D57，D57 是建置落進窗口那筆）：`verify_fps_fullscreen.sh` 現在在每一輪的擷取窗口正前方開 timestats、窗口結束就 dump，實測窗口長度 **20.09s／20.11s**（對比舊版的 241.03s 全程平均）。**第一組乾淨的逐輪損失分解**因此拿到了：同一個 20 秒窗口內 guest **56.73** → 直拉對照組 **53.86**（−5.1%）→ Mirage **50**（再 −7.2%）。**歷史**：本實驗前兩次嘗試都沒拿到可信數字——第一次窗口沒對齊（涵蓋了 249 秒的 release build，guest 平均被拉到 34.28 fps）；第二次撞到機器上有其他工作（三個 java 行程吃 356% CPU、load 25–32），`load_gate` 持續擋下。⚠️ **第一次跑順帶暴露一個判準問題，值得記**：我原本用 `droppedFrames == 0` 判定「瓶頸不在 guest」，但那次量到 `fps=34.28` 而 `droppedFrames=0`——**`droppedFrames` 只表示 SurfaceFlinger 沒丟棄「已提交」的幀，不表示 Unity 送滿了 60**。腳本的判定已改成看 fps 是否 ≥55。D45 的結論（59.9 fps + droppedFrames=0）不受影響（59.9 本來就接近 60），但**任何只引用 `droppedFrames=0` 的推論都要重新檢查**）。**⚠️ 2026-08-05（D39）新增一個具體的嫌疑段與一個候選解方**：`bench_mmap_vs_rgba.py` 實測 raw RGBA 這條傳輸路徑的吞吐天花板在 **270–290 MiB/s**，而全螢幕 898×1996 要跑滿 60fps 需要 **410 MiB/s**——**結構上到不了**（模型可對源驗算：實測吞吐÷幀大小＝實測 fps，三個解析度全中，273.1÷6.837=39.9 vs 實測 40.0）。同機同內容下 raw 40.0 fps／MMAP **56.7** fps（1080×2400 是 29.0／58.0）。也就是說「guest→直拉對照組」這一段很可能就是吃掉預算的地方，而 MMAP 是已知能繞過它的手段。**但目前拿不到**：`MmapStreamTransport` 凍結（D16／D39），且那組數字是 Python client 量的鏈路上限、非 Mirage 實際交付。順序建議：先做上面那個 `--timestats` 同步實驗確認損失分佈，若確認落在傳輸段，D16 就從「建議封存」變成 D48 的主線 **⚠️ 2026-08-07：「降解析度換 fps」這條路實測走不通，且方向與模型相反。** D39 建立的模型是 `fps = 吞吐 ÷ 幀大小`（raw RGBA 天花板 270–290 MiB/s），據此推算「降 `maxPixels` 從 1.8 Mpx 到約 1.3 Mpx 就能達 55 fps」。用驗收腳本自己在用的 `fps_baseline.py` 實測四個解析度、兩輪（第二輪順序反過來避免順序效應）：**910k px 20.74／29.82、1,267k 17.80／19.23、1,381k 19.98／20.89、1,792k（現況）23.16／24.23**。**兩輪都是像素愈多 fps 愈高**（1792k > 1381k > 1267k），排序一致——不是雜訊。所以在這個區間 fps **不受傳輸頻寬限制**，降解析度會同時失去解析度**和** fps。⚠️ **這與 D39 的模型衝突，兩者用的是不同工具**：D39 用 `bench_mmap_vs_rgba.py`，而那支工具今天暴露兩個問題——`TARGET` 寫死 `localhost:8554`（沒有旗標，我們的 emulator 在 8556，整組跑出來是 0.0 fps 的無效數據），以及即使連對埠仍只量到 `rgba 0.2 fps`，而同一時刻 `fps_baseline.py` 在同一解析度量到 25.17。**那支工具的數字需要重新檢驗**（D53 已記它不在任何 CI 裡）。⚠️ 本次絕對值（18–30 fps）低於先前的 43–58，因為 emulator 剛重開且遊戲畫面可能不同；但每一輪內的四個點是背靠背量的，**相對比較可信，絕對值不可與先前跑次比**。**結論：`maxPixels` 不是 D48 的槓桿。** 目前已知唯一能跨過門檻的仍是 MMAP（D16，同機實測 raw 40.0 → mmap 56.7），而它卡在上游。 **⚠️⚠️ 同日稍晚更正：上面那段結論是在偏靜止的畫面上量的，錯了。** 使用者把遊戲切到真正持續變化的畫面（連續 6 張 screencap 雜湊全不同）後重跑同樣的兩輪掃描，結果**完全反轉**：**910k px 30.90／30.63、1,267k 26.07／28.30、1,381k 28.16／27.93、1,792k（現況）20.90／21.39**——兩輪吻合得很緊，且**像素愈少 fps 愈高**。`streamScreenshot` 是變化驅動的：畫面不動時 fps 受變化率限制、與頻寬無關，所以先前那組量到的是「畫面多久變一次」而不是「傳輸能送多快」。**所以「降解析度換 fps」這條路是有效的**，先前寫的「走不通、方向相反」作廢。⚠️ 但別直接照這組數字定 `maxPixels`：把兩端代進 `1/fps = a + b×px` 解出**每幀固定成本約 17ms（等於約 59 fps 的天花板）**，要達 55 fps 需要把像素降到約 71k——那是 190×375，不可用。也就是說**單靠降解析度到不了 55**，它能買到的是 21 → 31 fps 這個量級的改善。⚠️ 本次絕對值（21–31）仍低於先前跑次的 43–58，那個固定成本裡包含了今天讓一切都變慢的因素，所以 17ms 這個推估只在本次條件下成立。**真正的教訓**：`verify_fps_fullscreen.sh` 的檔頭把「遊戲必須停在會持續變化的畫面」列為前置，但**只有註解、沒有任何斷言**——與 D44 的音訊前置完全同型，記為 D59。**⚠️ 2026-09-03：「MMAP 候選解方」移除**。D58 工具做的三輪交錯對照量到 Python raw 58.98／MMAP 59.57（見 `app/RESULTS-d58.md`「PM 把關與活體驗證」），傳輸段沒有損失可收。Python 直拉 59 而 Mirage 自己 43 到 54，剩下的損失在 Mirage 行程內部：grpc-swift client 路徑（D16 調查已證明它與 Python 在同一台 emulator 上行為不同、插 TCP relay 改善 6 倍；單一 NIO 執行緒、16 KB HTTP/2 frame 要吞 405 MiB/s）或 macOS 端解碼／Metal／視窗合成。**下一步是「Swift 直拉對照組」**：用 `GrpcChannelBox` + `GrpcStreamTransport` 拉 raw RGBA 不渲染，與 Python 同窗口交錯，一次把兩段切開。**✅ 2026-09-03 同日做完（`mirage-pull`，`app/RESULTS-swift-pull.md`）：grpc-swift 直拉中位數 56.61、Python 同窗口 57.82，client 路徑也排除。** 剩下兩個候選：(a) `MirageShell` 的解碼／Metal 上傳／視窗合成／`LatestFrameBox` 丟幀；(b) app 自己的 CPU／GPU 負載回頭壓 guest 出幀（直拉不渲染所以量不到這項）。**下一步：在 Mirage 行程內同一窗口計「抵達／上傳／present」三個數**，與 `verify_fps_fullscreen.sh` 已逐輪對齊的 guest fps 並列；抵達接近 guest 而 present 低是 (a)，抵達本身就低是 (b)。順帶發現 grpc-swift channel pool 預設等待連線，對沒人聽的埠不會回錯誤，Mirage app 對「模擬器沒開」的判斷不能靠 RPC 錯誤（尚未記債，待確認 `EmulatorClient` 目前怎麼判）。**✅ 2026-09-03 第三段也切開了（`app/RESULTS-frame-counters.md`）**：app 每秒印 `[app] frames arrived= dropped= presented=`，`verify_fps_fullscreen.sh` 逐輪並列。兩次跑次共十輪：**主機安靜時 Mirage 行程內零損失**（guest 59 到 60 的輪次 arrived 60 到 61、presented 60、dropped 0、mirage 59 到 60），**驗收線 7 首次通過**（跑次 1：59／59／60，退出碼 0）。負載下的損失兩種形狀：(b) guest 先掉（36 到 54），Mirage 跟著掉；(a) guest 沒掉但渲染端掉（跑次 2 第 5 輪 guest 58.89、arrived 60、presented 50、dropped 8）。**所以 D48 的本體已從「哪一段慢」變成「對主機負載的耐受度」**：(b) 是 D60，(a) 新記 D64。單格 latest-wins 信箱的拍頻損失沒有出現。 | ~~P2~~ → **P2（重新定義為 D60＋D64）** |
| **D49** | **`phase0/harness/` 的 11 個既有檔案全部 import 不動**：`gen/` 下的產生碼是用 protobuf 7.35.0 產生的，系統 Python 裝的是 4.25.4，一 import 就 `ImportError`/`VersionError`。D45 建了 `.venv-d45` 讓其中新寫的 `fps_baseline.py` 跑得起來（見 `phase0/harness/README-venv.md`），**但其餘 11 個既有檔案仍是死的**：`animate.py`、`bench_mmap_vs_rgba.py`、`diag_fd_variable.py`、`e2e_latency.py`、`encoded_bench.py`、`input_latency.py`、`probe_mmap.py`、`probe_mmap_explicit.py`、`probe_touch_coords.py`、`smoke_grpc.py`、`stream_bench.py`。與 **D37**（`tools/probe/tests` 的 13 個測試檔從未被跑過）同型——存在但不執行的程式碼，讓人以為有涵蓋 | 這些檔案涵蓋 mmap、延遲、觸控座標等量測工具，日後任何重驗（例如 D39 的 MMAP 重驗）撿到其中一支時，會先撞上與本次相同的 import 炸裂，而不是它原本要驗的問題。`.venv-d45` 只鎖了 `fps_baseline.py` 所需的三個套件（`protobuf`/`grpcio`/`numpy`），沒有涵蓋其餘檔案可能還需要的套件（例如 `encoded_bench.py` 的 `av`），未一併驗證過 | 半天（比照 D37 的方向：擴充 `.venv-d45` 的 requirements 並逐檔驗證能跑，或改寫成不依賴 gencode 版本鎖定的形式，視情況併入 CI） | P2 |
| **D50** | **`load_gate` 只在輪次開始前檢查一次主機負載，不涵蓋 20 秒擷取窗口**。D45 補測時有兩個樣本因此被污染：起始負載通過門檻後，負載在擷取期間才飆高，`ROUNDS=2`／`MIRAGE_MEDIAN=6` 與 `MIRAGE_MEDIAN=11`（遠低於任何一次乾淨量測的 35–60 一帶）——`load_gate` 完全沒有機制擋下這種樣本（見 `app/RESULTS-d45-probe.md`「量測阻塞：CPU 負載飆高」一節） | 這兩個樣本本次靠人工比對「35–60 一帶」的既有基準才被識別並排除；若沒人回頭核對，會被當成真實的 Mirage fps 混進中位數，讓驗收線 7 這類 fps 判定失真——負載污染可能把樣本壓到不合理的低值，也可能（視污染模式）製造假象 | 1–2 小時（在擷取迴圈內加週期性負載檢查，或擷取後回溯比對窗口內的負載峰值，超過門檻就整輪作廢重試） | P2 |
| **D51** | **`FULLSCREEN_MIN_WIDTH=896`（`app/scripts/verify_fps_fullscreen.sh`）綁定這台機器的螢幕幾何，沒有債務編號**：888（視窗模式天花板）／896（門檻）／898（這片邏輯 1680×1050 螢幕的全螢幕天花板）三個數字全部只在這台機器量出來，門檻卡在中間、邊界只有 10（898−888）這麼窄。換一台「視窗模式天花板更接近 896」的機器（例如螢幕更寬、menu bar／dock 佔比不同），這條門檻可能把「根本沒進全螢幕、只是視窗剛好夠寬」誤判成「已收斂」 | 這件事在腳本註解與 `RESULTS-d45-probe.md` 都寫得很清楚，**但沒有債務編號**——這個專案自己的教訓是「沒有編號的東西每一輪都會被合理地跳過」（D45 本身就是因此而生）。換機器（CI、另一台開發機、或這台螢幕解析度日後改變）跑這條驗收線之前，應該重新用腳本前置說明那段 `osascript -e 'tell application "Finder" to get bounds of window of desktop'` 量一次邏輯解析度，核對視窗模式天花板與這個門檻的間距是否還夠 | 30 分鐘（重新量測＋視需要調整門檻或加防護） | P3 |
| **D52** | ~~**`MmapStreamLiveTests` 只取 3 幀就判定，窗口約 150ms，有偽陰性風險**~~ → **⚠️ 升級：這不是「風險」，它已經造成了誤判，而且誤判持續了 9 天。** 同日稍晚的根因調查把窗口拉到 400 幀，量到 `distinct=92／102／109／110／119`——**MMAP 從來沒有「凍結」過，它一直在更新，只是慢約 3.6 倍**（Swift 約 15Hz、Python 約 50Hz）。「凍結」這個寫進 D16、`RESULTS-mmap.md`、三處程式碼註解與 memory 的描述，整個來自這條測試的窗口太短。原記載如下——通知以近 60Hz 到達，3 幀只跨約 150ms；而 `streamScreenshot` 是**變化驅動**的，guest 畫面的實際變化率若低於 60Hz（`animate.py` 供應的動畫就是），窗口內畫面本來就可能一模一樣。D39 重驗時 Python 對照用 5 幀跑出 `distinct=1`，看起來像「Python 也凍結了」，拉到 30 幀／525ms 後是 `distinct=30`——同一個坑，只是這次踩在對照組上被抓到 | ~~目前不會誤判，因為 Swift 端的凍結是**確定性**的~~——**這句本身就是被同一個窗口騙出來的**。「三個版本每次都 `distinct=1`」是真的，但那證明的是「150ms 內看不到變化」，不是「沒有變化」。前人「30 幀／480ms 仍全同」同理：在 15Hz 下 480ms 只跨約 7 次更新，全同並不意外。**一條窗口太短的測試不會報錯，它會給你一個看起來很確定的錯誤答案**——而且因為它每次都一致，反而更像真相。同型於 D47（`A4 fps 取樣筆數 ≥ 1` 太鬆），但後果嚴重得多 | 把幀數拉到 30（與 `mmap_client_parity.py` 對齊）或改成「至少 N 幀且至少 T 毫秒」；順帶讓失敗訊息區分「全同」與「根本沒收到足夠的幀」。**同一支測試還有第二個問題，而且更嚴重**：`for try await frame in transport.frames(...)` **沒有任何逾時**——guest 畫面完全靜止時 `streamScreenshot` 一格都不送，測試會無限等下去（D39 的 baseline 那次等了 109 秒才湊滿 3 幀，那還是畫面有在動的情況）。`mmap_client_parity.py` 已經加了 `--timeout`（實測逾時路徑回退出碼 3），Swift 這邊該用 `.timeLimit()` 或在迴圈裡自己計時。**成本**：30 分鐘 | P3 |
| ~~**D53**~~ | **`bench_mmap_vs_rgba.py` 這支決定性的量測工具不在任何 CI／驗證腳本裡**。D39 靠它量出「raw RGBA 吞吐天花板 270–290 MiB/s、全螢幕上 MMAP 值 +16.7 fps」這組推翻 D16 封存建議的數字，但它只是 `phase0/harness/` 底下一支要手工跑的腳本，且與 D49 記載的那 11 支同處一個 venv 依賴脆弱的目錄 | 這組數字直接決定 D16／D48 的優先序。沒有任何東西會在解析度、emulator 版本、或傳輸實作改變時重新量它——下一次有人問「MMAP 到底值不值得修」，會像這次一樣拿 2026-07-28 那組**在錯誤解析度上量的**數字回答 | 併進 `verify_mmap.sh`（它已經有 emulator 與 animate 的前置），或獨立成 `verify_transport_bench.sh`，對「MMAP fps 不得低於 raw fps」這類關係下斷言而非只印表。**成本**：1–2 小時。**✅ 已修（2026-09-03）**：`app/scripts/verify_transport_compare.sh`（交錯、負載門檻、逐輪有效性、中位數，只斷言樣本可信、不判定誰快）＋ `ci.sh` 閘門 8 跑 `phase0/harness/tests`（33 條 pytest，含「生成碼必須來自 `gen/`」這條在 fresh clone 會紅的哨兵）。 | P3 |
| ~~**D54**~~ | **MMAP 這條路徑的量測沒有負載門檻、沒有交錯機制，而它對兩者都極度敏感**。2026-08-05 根因調查中，**同一份 Swift 測試量到 1、2、5、16、75、92、102、103、109、110、119——差 100 倍以上**。兩個變數：(a) **系統負載**——`swift build -c release` 的優化編譯把 load 推到 22，緊接著跑的測試量到 1–2；build 快取、load≈9 時同一份測試量到 75–110；(b) **觀察者干擾**——為了查「emulator 有沒有在寫」而加的外部行程（每 40ms 讀 2.5MB），光是它存在就把 Swift 從 16 打到 1；(c) **還有一個至今不明的變數**——同日稍晚在**同一個 emulator 版本、更低的負載**（6.5–6.7 vs 9.8–10.3）下重測，Swift 從 109／110 掉到 **15／16／13**，差 7 倍。負載更低反而更差，所以不是負載；候選是 emulator 已運行時間（稍早那台開機約 45 分鐘、重測那台剛開機幾分鐘），未驗證 | **這已經產出過一個錯誤結論。** 重度觀察下量到「外部 `read()` 看到 98 次變化、Swift 只看到 5 次」，據此一度判定「emulator 一直在寫、是 Swift 讀不到」——那是儀器污染的產物，低干擾重做時（每 200ms 讀 64KB）外部 31 次／Swift 75 次，差距消失大半。與 **D50**（`load_gate` 不涵蓋擷取窗口）、**D45** §3.3（先後量測會讓某一方落在負載高峰）同族，但這條特別狠：**`verify_mmap.sh` 目前完全沒有負載門檻**，任何人在 build 剛跑完時執行它，拿到的數字都是負載而不是行為 | 給 `verify_mmap.sh` 加 `load_sentinel.sh`（已存在、已有自我測試）的門檻與量測後回檢；把 Python／Swift 對照改成交錯而非先後；任何新增的觀察者都要先量它自己的干擾量再採信它的輸出。**在那之前，不要引用任何單次量到的絕對值**——`RESULTS-mmap.md` 一度把「Swift ≈ 27.5%」寫成穩定基準，幾小時後同條件重測就變成 4%。唯一穩定的是方向：Python 380–400、Swift 遠低於它。**成本**：實際約 1 小時。**✅ 已修（2026-09-03）**：交錯與逐輪負載門檻＋量測後回檢已固化在 `verify_transport_compare.sh`；`verify_mmap.sh` 的門檻 2026-08-05 就有。 | — |
| **D55** | **`verify_mmap.sh` 的兩個 `source` 在從 repo root 呼叫時靜默失敗，於是 D54 新加的負載門檻「看起來有作動、實際上從未執行過」**。腳本開頭是 `cd "$(dirname "$0")/.."`，**之後**才 `source "$(dirname "$0")/lib/..."`——`$0` 是相對路徑時，cd 完那個相對路徑就失效了。從 `app/` 目錄呼叫正常（歷來都這樣跑），從 repo root 呼叫則兩個 source 都失敗 | **這是本 repo「假斷言」家族裡最陰險的一種**：`set -u` 不管函式，缺少的函式要到被呼叫時才炸成 `command not found`（退出碼 127），而 127 讓 `if ! load_gate ...` 這種寫法**照樣成立**——閘門確實中止了腳本，訊息也印了，只是它中止的理由是「函式不存在」而不是「負載超標」。若不是故障注入時順手看了 stderr，這道閘門會以「已驗證會紅」的姿態進 repo。與 D37／D49（存在但不執行的程式碼）同型，但更難發現：那兩者是完全不跑，這個是**跑了但驗的是別的東西** | **已修（2026-08-05）**：路徑在 cd 之前解析成絕對路徑（`SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"`）。已驗：從 repo root 呼叫 0 個 command not found，且 `LOAD_LIMIT=0` 時讀到真實負載 6.35 並以退出碼 1 中止。**已掃過其餘 verify_* 腳本，只有這一支有這個形狀**。**成本**：實際 15 分鐘 | — |
| ~~**D56**~~ | **驗收線 7 的量測變異跨越了門檻本身，所以「單次三輪取中位數」在結構上判定不了它**。2026-08-06 同一顆 build、同一台機器、同一天內量到的 Mirage 中位數是 **56／58**（兩輪跑次）與 **31／48／54**（三輪跑次）——**跨度 31–58，而門檻是 55**。兩次跑次分別會得出「通過」與「未通過」兩個相反的判定。（我在第一次跑次後就對使用者說了「驗收線 7 通過」，確認跑次推翻了它——**推翻一個既有判定的證據門檻應該更高，不是更低**）~~ | 這條線的每一次判定都可能是抽樣運氣。更嚴重的是它讓**任何效能改動都無法驗證**：改了產品碼之後量到 56，分不出是改動有效還是抽到好樣本。D48 想收斂就得先有一把量得準的尺 | **✅ 已修（2026-08-06），並在實跑中證明閘門會擋。** 三件事：**(1) 逐輪 guest 門檻**——`lib/guest_fps.sh` 在**每一輪擷取窗口的正前方**開 timestats、窗口結束就 dump（實測窗口 20.09s／20.11s，對比舊版全程 241.03s），guest 未達 `GUEST_MIN`（預設 55）的輪次判為無效、不計入中位數。**門檻正好等於驗收線 7 不是在調鬆判準**：Mirage 不可能比 guest 快，guest 只有 50 的窗口裡 Mirage ≥55 算術上就不可能，那一輪對這條線沒有鑑別力。⚠️ **它的失效方向是紅燈不是綠燈**（全被擋下就湊不到「有效輪數 ≥ 2」），這是它能存在的前提；而全部輪次被擋時腳本會印出明確警告要人分辨「主機忙」與「Mirage 自己把 emulator 餓死」——後者是真缺陷，這道門檻分不出來，所以它把問題交出去而不是替人做結論。**(2) 回報離散度**：新增 `MIRAGE_VALUES`／`MIRAGE_SPREAD`／`GUEST_VALUES`／`GUEST_REJECTED`，並在值域跨越 55 時明講「這次量測判定不了」。**(3) 預設輪數 3 → 5**（門檻會淘汰掉一部分輪次）。**實跑驗證（`-r 2 -d 20`）**：第 1 輪 guest 56.73 → 有效（Mirage 50）；第 2 輪 guest 50.36 → **判為無效**（Mirage 42）。**沒有這道閘門的話中位數會是 median(50,42)=42，印出一個看起來很篤定的「未通過 42」**，而那個 42 對驗收線 7 毫無鑑別力；現在它誠實地紅在「有效輪數 1 < 2」。順帶拿到**第一組乾淨的逐輪損失分解**：同一窗口 guest 56.73 → 對照組 53.86（−5.1%）→ Mirage 50（再 −7.2%）。解析邏輯抽成純函式並加 `guest_fps_selftest.sh`（7 條，**已做突變檢查**：不做 layer 圈選 → 4 條紅、不要求 SurfaceView → 1 條紅、改回傳 dumpsys 的 `averageFPS` → 1 條紅、拿掉除零保護 → 1 條紅），`ci.sh` 閘門 7 現在跑**四支**自我測試。外來 CPU 診斷（`cpu_delta_report`／`cpu_delta_total`，含 9 條自我測試、6 個突變全紅）從已刪除的 `verify_fps_with_guest.sh` 移入本腳本，**改為只診斷不中止**——真正的防線是逐輪 guest 門檻，它擋的是後果，CPU 診斷給的是成因。**成本**：實際約 2 小時 | — |
| ~~**D57**~~ | ~~**一次成功的 `swift build` 不保證下一次是 no-op，於是建置會落進量測窗口**。2026-08-06 實測：工作樹全程乾淨，連跑兩次相同的 `swift build -c release` → **73.85s（`Compiling SwiftProtobuf …`）然後 0.58s**。根因未鎖定（`SwiftProtobufPlugin` 每次都重跑，疑似讓下游 target 偶發失效）~~ | **影響範圍不只包裝腳本**：`verify_fps_fullscreen.sh` 是**每一輪內**經 `gui_session_start` → `package_app.sh` 建置的，建置就落在該輪 20 秒擷取窗口之前。撞到冷快取的輪次會被 CPU 餓死——2026-08-06 確認跑次的第 1 輪就是這樣量到 **31 fps**（同跑次另兩輪是 48／54）。這是 D50／D54「窗口沒對齊，量到的是別的東西」的第三次同形復發 | **✅ 已修（2026-08-06），兩支腳本都修完，並在實跑中驗證。** 判斷抽進 `verify_common.sh` 的 `build_output_recompiled`／`build_warm`：反覆 `swift build` 直到某次沒有 target 被重編；三次仍在重編就**回紅**（不是「算了繼續」——那會產出一個看起來正常的髒數字）。⚠️ **唯一的難點是必須排除 `Compiling plugin …`**：SwiftPM 每次建置都重跑 build plugin，那兩行在 73.85s 的真重編與 0.58s 的 no-op 輸出裡**都會出現**，拿它當訊號會永遠判定成「還沒暖」。**所以那個判斷刻意抽成純函式**（不跑 swift build 就能測），`verify_common_selftest.sh` 新增 5 條斷言釘住它，**已做突變檢查**：拿掉 plugin 排除 → 1 條紅、改成大小寫不敏感排除 → 1 條紅、永遠回真 → 3 條紅、永遠回假 → 2 條紅，原版全綠。`package_app.sh` 新增 `MIRAGE_SKIP_BUILD=1`（**選擇性關閉，預設行為一字不變**——它是組 .app 的唯一入口 D25，三支 verify_* 都靠它順便建置；跳過是安全的，因為既有的「找不到執行檔／資源 bundle」兩條斷言擋著，已故障注入證明會以退出碼 1 中止且不留半成品）。`verify_fps_fullscreen.sh` 改成輪次前 `build_warm` 一次、之後 `export MIRAGE_SKIP_BUILD=1`。**實跑驗證（`-r 1 -d 10`）當場又復現了本債**：預先建置階段印「第 1 次仍有 target 被重編，再建一次／第 2 次已是 no-op」，而輪次內印「跳過建置」——舊版的話那次重編就會落在擷取窗口正前方。**成本**：實際約 1 小時 | — |
| ~~**D58**~~ | **`bench_mmap_vs_rgba.py` 的 `TARGET` 寫死 `localhost:8554`，沒有旗標可覆寫**，而本專案的 emulator 在 8556。用它跑會得到一整組 `0.0 fps / 0.0 MiB/s` 的數據，外加一行看似合理的判讀「MMAP 未出幀——量測無效」——**紅得像是 MMAP 的問題，實際是連不上**。改連對埠之後仍只量到 `rgba 0.2 fps`，而同一時刻 `fps_baseline.py` 在同一解析度量到 25.17 fps **⚠️ 2026-08-07 同日削弱本列的指控**：「連對埠後仍只量到 rgba 0.2 fps，而同一時刻 `fps_baseline.py` 量到 25.17」這組對照**不成立**——稍後在同一台上背靠背重跑，兩支工具給出一致的結果（bench `rgba 0.6`、baseline `0.24`）。先前那個 100 倍差距更可能是兩次跑之間 guest 出幀狀態不同（Unity 閒置會停止算繪），不是工具缺陷。**寫死 `TARGET = localhost:8554` 仍然是真實缺陷**（連不上會產出整組 0.0 fps 再印「MMAP 未出幀——量測無效」，紅得像是 MMAP 的問題），而且第 144 行呼叫 `animate.py` 時同樣沒傳 `--serial`／`--port`，所以**它的動畫源一直連到 5554、從來沒作用過**——這一項是新發現，比原記載更嚴重：那支工具在非 5554 的機台上，動畫源與資料源都是斷的。但「D39 的數字不可信」這個推論**證據不足**，需要在 guest 確實出幀的環境下重驗才能判定 | **D39 推翻 D16 封存建議的那組數字（raw 40.0／mmap 56.7 fps、吞吐天花板 270–290 MiB/s）全部來自這支工具**，而 2026-08-07 的解析度掃描用 `fps_baseline.py` 得到方向相反的結果（像素愈多 fps 愈高）。兩者至少有一個是錯的，而 D16 的優先序、D48 的候選解法都建立在前者上 | 先把 `TARGET` 改成可由旗標／環境變數指定（並讓連線失敗**明確報錯**而不是產出 0.0 然後印判讀），再用它與 `fps_baseline.py` 在同一時刻、同一解析度做一次對照——兩支工具都量 raw RGBA，數字該落在同一量級。差 100 倍時不能兩個都信。**成本**：1–2 小時。**✅ 已修（2026-09-03）**：bench 加 `--endpoint`／`--serial`／`--no-animate`，連線先探測、失敗以退出碼 1 結束且不印任何 fps；`fps_baseline.py` 加 `--transport mmap`、`distinct`、`stale`（退出碼 3），既有退出碼與純文字輸出不變。對照結果：兩支工具的分歧來自量測條件（poc AVD＋人造動畫 vs game AVD＋真實畫面），不是工具缺陷；見 `app/RESULTS-d58.md`「PM 把關與活體驗證」。 | P2 |
| ~~**D59**~~ | ~~**`verify_fps_fullscreen.sh` 的「畫面必須持續變化」前置只寫在註解裡，沒有任何斷言**。`streamScreenshot` 是變化驅動的——畫面不動時 emulator 根本不出幀，量到的 fps 反映的是「畫面多久變一次」而非傳輸能力，而兩者都會產出一個看起來正常的數字~~ | **這條缺口已經造成一次寫進 repo 的錯誤結論**：2026-08-07 在偏靜止的畫面上掃四個解析度，量到「像素愈多 fps 愈高」，據此判定「降解析度換 fps 走不通」並 commit。使用者把遊戲切到真正會動的畫面後重跑，結果完全反轉（910k px 30.9 fps vs 1792k 20.9 fps）。**本專案第三次踩到同一形狀**——D44 的音訊供應率、D56 的逐輪 guest fps，現在是畫面變化率 | **✅ 已修（2026-08-07）**：量測前抽樣 `CHANGE_SAMPLES`（預設 5）張畫面雜湊，distinct 少於 `CHANGE_MIN_DISTINCT`（預設 4）即中止。用 `exec-out screencap` 而非 `screenrecord`——後者本身會影響 guest 合成負載，而那正是要量的東西。訊息明講「這是環境的紅燈不是產品的紅燈」並給出下一步。失效方向是紅燈，不可能製造假綠燈。已故障注入驗證（門檻拉到 6 → rc=1），現況實測 5/5 張不同、正常放行。**成本**：實際約 30 分鐘 **⚠️ 同日更正：第一版這道閘門用 `screencap` 雜湊，是錯的，已換掉。** 1 秒間隔取樣只能證明畫面「至少每秒變一次」，不能證明它以 20–60Hz 在變。**實測反例**：同一時刻 screencap distinct 4/4（會放行），而 SurfaceFlinger 裡根本找不到遊戲的 layer、串流只有 0.24 fps。而且 `screencap` 每張要數秒，高頻取樣在結構上就辦不到（實測 40 張跑不完 5 分鐘）。**更根本的問題是它重複發明了一個更弱的東西**——本腳本第 353 行早就有逐輪的 guest fps 閘門（D56），我卻另外做了一個訊號更差的複製品。已改用同一個訊號（`lib/guest_fps.sh`，有自我測試與突變檢查）：前置取樣 8 秒問 guest 出了幾幀，門檻 `PREFLIGHT_GUEST_MIN` 預設 20——**刻意低於逐輪的 55**，這裡只擋「根本沒在動」，「動得不夠快」交給逐輪閘門逐輪判定。實跑驗證：在舊閘門會放行的同一個狀態下擋下來（guest 0.22 fps），且該數字與串流實測的 0.24 fps 吻合。 | — |
| **D60** | **guest 出幀率會被兩個主機層面的狀態壓垮，而現有的診斷完全看不到它們**：(a) **磁碟全滿**——2026-08-07 實測從 26 GiB 掉到 **120 MiB**（`ENOSPC`），guest 掉到 3–5 fps、Pixel Flow **ANR**、`animate.py` 注入 120Hz 但連 `PointerLocation` 疊層都只有 3.4 fps；(b) **主機外來 CPU**——清掉磁碟與 ANR、emulator 全新開機、GPU 硬體加速確認正常之後 guest 仍只有 4–5 fps，查出非工作負載 CPU 總和 **248%**（D56 的門檻是 150%） | **這兩個狀態下量到的任何 fps 都是主機的數字，不是產品的數字**，而它們不會有任何錯誤訊息——串流照樣回傳、fps 照樣有值。本輪「像素愈少 fps 愈高」那組反轉結論就是在磁碟從 26 GiB 掉到 120 MiB 的過程中量的：方向可信（兩輪吻合），但絕對值與斜率不能當定案 | 三件可直接做的：(1) **`verify_fps_fullscreen.sh` 已有的兩道閘門要再加一道磁碟檢查**——現有的 `load_gate`（load average）與 D56 的外來 CPU 診斷都看不到磁碟；(2) **emulator 執行期會佔用約 14 GB**（qcow2 overlay），停止時才釋放——`df` 在 emulator 跑著時看起來吃緊是正常的，但真的見底就會出事；(3) **`default_boot` 快照可安全回收**（poc 1.8G＋bench 1.0G，本輪已刪），只影響冷開機時間；⚠️ 具名快照（如 poc 的 `mirage_suspend` 2.3G）不要動。另記一個清理漏網：`verify_*.sh` 的 `gui_session_cleanup` 用 `pkill -x MirageApp`，但從暫存 bundle 啟動的行程曾殘留並吃掉 55% CPU——`pkill -f` 才抓得到。**成本**：半天。**✅ 2026-09-07 回壓量測（`app/RESULTS-backpressure.md`）：Mirage 對 guest 的回壓為零**。同機同畫面交錯三條件各三輪：沒人拉 59.9、grpc-swift 拉不渲染 59.9、Mirage 全螢幕渲染 59.8；qemu 多花約 100 個百分點編碼、MirageApp 自己 42 到 44%，都沒搶到 guest 的 vCPU。「Mirage 少吃 CPU」這條路關掉。**驗收線 7 在使用者同時用機器時的殘餘完全在 emulator 側**，Mirage 能做的只有偵測並告知使用者，這是產品決策 | P2 |
| **D61** | **`tools/provision/provision.py` 不加 `--apply` 也會建立缺少的 AVD**（`_avd_rows`：不存在就建，存在但不符才要旗標）。2026-09-03 只是想「預演」看看狀態，兩台 AVD 就被建出來了。另記同日發現：`~/.android/avd/` 在 2026-08-10 被清空（目錄 mtime），三台 AVD 連同 Pixel Flow 一起消失，**原因不明**，repo 內沒有任何東西會做這件事 | 一支叫「檢查」的指令會寫檔，與 D9 那類「驗證腳本不驗證」是鏡像：這個是「檢查會改狀態」。AVD 消失沒有記錄則表示驗收線 1 的 ✅ 前提可以無聲失效 | 加 `--dry-run` 或把「不存在就建」改成也要 `--apply`（需同步改 `verify_provisioned_avd.sh`）；Pixel Flow 的 APK 已備份到 `~/Library/Android/mirage-apks/`（split APK 兩檔，`adb install-multiple` 重裝） | P3 |
| ~~**D62**~~ | **`phase0/harness/gen/` 被 `phase0/.gitignore` 忽略，且 repo 內沒有重建它的指令**。fresh clone 上 12 支 harness 腳本全部 import 不動（D49 只記了版本不合，沒記「根本沒有檔案」） | 與 D49 同型但更前面一層：D49 是有檔案但版本不合，這條是連檔案都沒有 | **✅ 已修（2026-09-03，隨 D58）**：`README-venv.md` 補 `grpc_tools.protoc` 重建指令、`requirements-d45.txt` 鎖 `grpcio-tools==1.83.0`、`tests/test_generated_proto.py` 在 `gen/` 缺席時會紅（不 skip） | — |
| ~~**D63**~~ | **`verify_fps_fullscreen.sh` 的 `AXFullScreen` 在視窗於 AX 出現前 0.5 秒送出、失敗被 `> /dev/null 2>&1` 吃掉、之後不重送**。實測 `gui_session_start` +7.3 秒回來、視窗 +7.8 秒才在 AX 出現、送成功後 +9.3 秒收斂到 898。2026-09-03 三輪九次啟動全部停在 888×1972，`ROUND_RETRY_MAX` 的關掉重開每次撞同一個時序 | 這條讓 [[live-test-env-gotchas]] 記的「視窗狀態還原，重試即可」變成誤診：重試沒用，因為每次都送在同一個錯誤時刻。與 D55 同型：閘門看起來有作動，實際上是另一個原因 | **✅ 已修（2026-09-03，隨幀計數任務）**：先輪詢 AX 視窗出現（`FULLSCREEN_WINDOW_TIMEOUT`）再送、stderr 印出、每 2 秒讀 `AXFullScreen` 不為 true 就重送（最多 3 次）。修後兩次跑次十次啟動全部收斂 | — |
| **D64** | **渲染端在主機負載下錯過 vsync**：guest 沒掉（58.89）、幀有抵達（60），但 `Renderer.draw` 只 present 了 50、`LatestFrameBox` 覆蓋掉 8（`app/RESULTS-frame-counters.md` 跑次 2 第 5 輪，外來 CPU 183%）。安靜窗口下同一條路徑是 arrived 60／presented 60／dropped 0，所以不是結構性瓶頸，是 `@MainActor` 的 display-link 回呼被搶 | 驗收線 7 在使用者同時用機器時會掉到 49，而這一段是 Mirage 自己能控制的（D60 的 guest 那段不是） | 候選：把 upload＋blit 移出主執行緒（`CVDisplayLink` 或 `MTKView` 的 `isPaused` 加自管執行緒）、或降低 app 主執行緒的其他工作。**先量再動**：用 `MIRAGE_LATENCY_LOG` 與新的三計數在人為負載下（例如 `yes > /dev/null` ×4）重現，確認掉幀發生在 draw 回呼被延後而不是 Metal 本身。**⚠️ 2026-09-07 量了，三個假設在純 CPU 負載下全部不成立**（`app/RESULTS-d64.md`）：0／4／8 個 burner 各五輪，`gap20=0`、`maxgap` 恆 18ms、`in_p95` ≤ 9.3ms、`nodrawable=0`、`dropped=0`，guest 出多少 Mirage 就 present 多少；掉的全是 guest（50 → 34 → 33）。9 月 3 日那一輪 presented 50／dropped 8 用純 CPU 重現不了，當時是使用者在操作機器，嫌疑轉向 GPU 或視窗合成競爭。**本列重新定義：「特定但尚未辨識的負載形態下渲染端錯過 vsync，純 CPU 負載不會」**，優先序降到 P3，等下次自然出現時用已固化的三計數＋draw 時序行抓現場。渲染端在 CPU 負載下沒有東西可修，Mirage 對驗收線 7 剩下的槓桿只有「自己少吃 CPU 以減少對 guest 的回壓」（D60 那段，MirageApp 全螢幕 60fps 約 50% 到 60% CPU，尚未量它對 guest 的影響）。**⚠️ 2026-09-07 同日又抓到兩次現場，三次都是使用者在操作機器時**：(a) `verify_fps_fullscreen.sh` 第 2 輪 guest 59.51、arrived 60、presented 53、dropped 6，同輪 `gap20=0`、`in_p95=9.2ms`、`nodrawable=0`、`noframe=6`，也就是 display link 準時、上傳快、drawable 有，但 60 幀抵達的**節奏不均勻**（有的 vsync 收兩幀覆蓋一幀、有的收零幀），這是抵達抖動不是渲染慢；(b) 回壓量測 `app` 三輪 guest 59.7 到 59.9 但 `mirage_fps` 47／48／50。**候選解法：`LatestFrameBox` 改深度 2 的小佇列**，抵達抖動時 vsync 仍有上一幀可畫，代價最多 16.7ms 延遲。回壓量測（`app/RESULTS-backpressure.md`）證明「少吃 CPU」那條路沒東西可省，所以 D64 的這個形狀現在是 Mirage 側對驗收線 7 唯一還能動的東西。**✅ 解法已實作（2026-09-07，`app/RESULTS-d64-queue.md`）但提案未驗證**：`FrameSink` 協定＋`FrameQueue`（深度 N 的 FIFO）＋`MIRAGE_FRAME_QUEUE=2` 開關，預設關閉零行為變化；`verify_fps_fullscreen.sh -A` 同顆 build 交錯 latest／queue2，含 `lat_p50`／`lat_p95`。A/B 機制全部驗證通過，但活體那次是螢幕分享（外來 CPU 244%）把 guest 壓到 14 到 21，六輪全判無效、兩個 sink 都 `dropped=0`，抖動根本沒出現。**D64 的觸發條件比「使用者在用機器」更窄**：三次現場外來 CPU 分別 183%／91%／0 到 34%，guest 都在 59 以上；純 CPU burner 重現不了、螢幕分享太重。**缺可靠的重現手段**。下次既有模式量到 guest ≥ 55 但 `dropped` ≥ 5 的輪次，立刻同條件跑 `-A`。 | ~~P2~~ → ~~P3~~ → **P2**（解法已實作，待重現條件驗證） |
| ~~**D65**~~ | **螢幕鎖定時 GUI 活體會無聲失敗，訊息與 D63 一模一樣**（「視窗 N 秒內未在 AX 出現」、`fps=` 行數 0）。app 照收幀（`[conn] 幀 #360`），但 SwiftUI 不建視窗、`Renderer.draw` 一次沒跑。2026-09-04 深夜三組實驗全部零輪，追了四層（activate、清 defaults、A/B 舊二進位、CG 視窗層）才發現是 `CGSSessionScreenIsLocked=True` | 與 D63 同一個症狀、不同根因，而現有前置沒有任何一條會說「螢幕鎖定」。深夜或遠端跑活體必踩 | `gui_session_start` 前置加一行 `ioreg -n Root -d1 -a` 讀 `IOConsoleUsers[].CGSSessionScreenIsLocked`，鎖定就紅並明講。**成本**：30 分鐘。**✅ 已修（2026-09-07，D65 同日第二次咬人後）**：純函式 `gui_screen_lock_state` 吃 plist 文字印 locked／unlocked／unknown（沒有該 key 判 unknown 不誤擋，解鎖後 macOS 會把 key 整個拿掉），四條自我測試、故障注入會紅，`gui_session_start` 鎖定時直接回 1 並印「螢幕已鎖定」 | — |
| ~~**D66**~~ | **macOS 的 BSD `seq 1 0` 印 `1 0`**（起點大於終點會倒數），`for _ in $(seq 1 "$N")` 在 `N=0` 時跑兩次。`verify_fps_under_load.sh -n 0` 對照組因此啟動了兩個 burner，前置量到外來 CPU 241% 然後被門檻連擋六次 | 與 D55 同型：對照組「看起來有跑」，實際跑的是別的條件。同一輪還抓到 bash 3.2 對空陣列 `"${ARR[@]}"` 在 `set -u` 下炸（4.4 才修，macOS 內建就是 3.2），PM 的 Homebrew bash 5.3 撞不到、審查 agent 才抓到 | **✅ 已修（2026-09-04）**：`[ "$N" -gt 0 ] && for`；空陣列展開前判 `${#ARR[@]}`；用 `/bin/bash` 實跑兩條空陣列路徑驗過。**紀律**：把關 bash 腳本一律用 `/bin/bash` 跑一次 | — |

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

**明確不建議做的**：優化 Metal 渲染路徑（20–28ms 已近下限）、~~修 MMAP 凍結（傳輸不是瓶頸）~~、追 Pokémon TCG Pocket 的 SIGSEGV（母計畫 R2 已禁止）。

> ⚠️ **2026-08-05（D39）：「修 MMAP 凍結」這一項已從不建議清單移除。** 它當初被列進來的
> 依據是 §11.2「傳輸不是瓶頸」，而那個結論是在 **540×1200** 量的。全螢幕實際跑在
> 898×1996：raw RGBA 這條路徑的吞吐天花板是 270–290 MiB/s，而該解析度要跑滿 60fps
> 需要 **410 MiB/s**——結構上到不了。實測 raw 40.0 fps／MMAP 56.7 fps（驗收線 7 門檻 55）。
> 詳見 D16（已從「建議封存」升級 P2）與 `app/RESULTS-mmap.md`。
>
> **但第 7 項的告誡仍然完全成立、而且更該讀一次**：「在分解之前談『優化傳輸』是在猜」。
> D39 量到的是「這條鏈路換掉傳輸方式有 +16.7 fps 的空間」，**不是**「Mirage 的損失都在
> 傳輸段」——後者仍未分解。差別在於現在有一個帶數字的候選，不是猜測；但要動手之前，
> 第 7 項那個分解還是得先做。

---

## 6. Phase-1 驗收線現況

| 驗收線 | 狀態 | 瓶頸 | Mirage 佔比 |
|---|---|---|---|
| 1 款指標遊戲開箱即玩 | ⚠️ **✅（有前提）** | **前提：新機器先跑 `tools/provision/provision.py`（無旗標即可），再人工登入 Play Store 或 sideload APK** | — |
| 60fps 穩定 | ⚠️ **✅（有條件，2026-09-03）**：主機安靜時（外來 CPU 29%）三有效輪 59／59／60，退出碼 0，首次通過；主機忙時（外來 CPU 183%）49／59／60 跨越門檻、判定不了。舊記載：❌ **31–58fps（2026-08-06 重量，取代原記載的 29–44）**；驗收線 7 的門檻是 55，未通過 | **三段都有損失，不是單一瓶頸**——同一個 20 秒窗口逐輪對齊量到：guest **56.73** → 直拉對照組 **53.86**（−5.1%）→ Mirage **50**（再 −7.2%）。⚠️ 原記載「guest 出幀」與「仍是推論」兩句都要更正，見下方註記。**2026-09-03（D58 工具）：傳輸段排除**：同一台 game AVD、真實畫面、900×2000 上 Python raw 58.98／MMAP 59.57，兩者都到 vsync 天花板；Mirage 的損失在自己行程內（grpc-swift 或渲染），下一步「Swift 直拉對照組」切開這兩段。**同日第二段也切開了**：grpc-swift 直拉不渲染 56.61（`app/RESULTS-swift-pull.md`），client 路徑排除；剩渲染段與「app 負載回壓 guest」兩個候選。**2026-09-03 三段全部切開**：安靜窗口 Mirage 行程內零損失（arrived 60／presented 60／dropped 0）；負載下 guest 先掉（D60）或渲染端掉（D64）。**2026-09-07 回壓量測後定案**：Mirage 對 guest 零回壓（三條件 59.8 到 59.9），使用者同時用機器時的殘餘全在 emulator 側（D60），Mirage 側唯一還能動的是 D64 的抵達抖動（深度 2 佇列） | **不是「無額外損失」**：乾淨輪次裡 Mirage 自己那段掉 7.2%。但它也不是主因——第 3 輪曾量到 Mirage(54) > 同輪對照組(49.94) |
| 輸入延遲 < 80ms | ❌ ~110ms | 傳輸佔 ~2/3 | 20–28ms |
| 冷啟動 < 30 秒 | ❌ ~37s | emulator 開機佔 89% | 4.2s |
| 快照喚醒 < 5 秒 | ❌ ~8.9s | 同上 | 4.2s |
| 記憶體閒置 < 4GB | ✅ **通過（2026-08-07 首次量到，兩輪 1.55 GB／1.96 GB，門檻 4 GB）** | 量法是「有無 Mirage 的系統記憶體差值」（`active + wired + compressed`），不依賴任何單一行程指標。⚠️ **會這樣量是因為行程指標給不出單一答案**：RSS 合計 1.13 GB、footprint 的 dirty 5,313 MB、`phys_footprint` 9.3 GB，差 9 倍；而 9.3 GB 與系統整體矛盾（整台機器 `active+wired+compressed` 才 6.70 GB），它把整塊 guest RAM 映射算進去而那些頁面多半沒常駐。系統差值與 RSS 法同量級，兩個獨立方法互相印證 | ~~現行 suspend 不停 qemu，此線在現架構下必然不達標~~ → **實測推翻**。那句是推論，而 AVD 設定 4GB guest RAM 不等於主機付出 4GB——頁面是惰性配置的 |

**「60fps 穩定」那一列的三個更正（2026-08-04 起陸續量到，2026-08-06 定案）**：

1. **數字從 29–44 換成 31–58。** 全螢幕解析度上限（本機收斂到 898×1996）下的實測，
   詳見 D45／D48。門檻 55 未通過。

2. **「瓶頸在 guest 出幀」這句要分條件講，不能裸著讀。** D45 在 headless、load≈3 的
   安靜窗口量到 guest 穩定 **59.9 fps**，據此推翻了它；但 D48 在**驗收線 7 實際的量測
   條件**（真 GUI 全螢幕、load 8–15）下量到 guest 只有 **49.18 fps**——guest 自己就先
   掉了 18%。**兩個結論都對，差別在條件**：安靜窗口下瓶頸不在 guest，真實負載下 guest
   是損失的一部分。原記載「仍是推論，未直接量到」已不成立——現在兩種條件都直接量過了
   （`dumpsys SurfaceFlinger --timestats`，工具本身的 `averageFPS` 偏高約 3%，已在 AOSP
   原始碼層級確認機制並改用 `totalFrames ÷ displayOnTime`）。

3. ⚠️ **`droppedFrames=0` 不能當作「guest 沒問題」的證據。** 它只表示 SurfaceFlinger
   沒有丟棄**已提交**的幀，不表示 Unity 送滿了 60——實測有過 `fps=34.28` 而
   `droppedFrames=0` 的窗口。**repo 內任何只引用這個欄位的推論都要重新檢查。**

**另外，這條線的量測本身在 2026-08-06 之前判定不了它**（D56）：同一顆 build、同一天
量到 56／58（中位數 56，通過）與 31／48／54（中位數 48，未通過），**跨度 31–58 而門檻
是 55**。現已補上逐輪 guest 門檻——guest 未達 55 的輪次判為無效輪，因為那個窗口裡
Mirage ≥55 在算術上就不可能，該輪對這條線沒有鑑別力。

**「1 款指標遊戲開箱即玩」的 ✅ 有前提，不能裸著讀**（D33）。它成立的條件是：這台機器上已經有人手工備妥 `~/Library/Android/sdk`（emulator 37.2.1 canary、platform-tools、兩份 android-35 system image）與三台 AVD。產品**沒有一行碼**能重現那個狀態。換一個人、換一台機器，沒有任何自動化路徑能到達那個 ✅。

2026-07-30 實地查證，補三件比原記載更精確的事實：

1. **`avdmanager` / `sdkmanager` 在 PATH 裡但完全跑不起來——這台機器沒有 Java runtime**（`Unable to locate a Java Runtime`）。也就是說官方文件上「建 AVD 的標準方法」在此環境下**不可用**，這正是當初改用 curl + 手寫 `config.ini` 的原因。任何 provisioning 腳本要嘛先裝 JDK，要嘛沿用 curl + 寫檔的路線。
2. **三台的不一致確認屬實，且比原記載多一項**：`mirage-poc` 除了 `gpu.enabled=no / mode=auto / ram=2G`，還有 `hw.keyboard=no`；另兩台是 `yes / host / 4096 / yes`。RAM 2G vs 4G 是實質差異——**跑在 poc 上與跑在 bench 上的 fps 數字不可直接比較**。
3. **兩份 system image 的來源不一致**：`default/arm64-v8a` 帶 `package.xml`（來自官方 repository zip），`google_apis_playstore/arm64-v8a` **沒有 `package.xml`**（手工組裝，來源與版本無從追溯）。

**另有一段是腳本永遠補不上的**：`mirage-game` 用的是 playstore image，要在上面裝遊戲需要登入 Google 帳號——那一步不可自動化。所以「開箱即玩」可自動化的邊界最多到「**兩台一致的 AVD 可被重建**」，遊戲本身得靠 sideload APK（`verify_apk_install.sh` 已涵蓋）或人工登入。這條邊界必須寫在這裡，否則寫了 provisioning 腳本之後這個 ✅ 仍然是半裸的。

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
