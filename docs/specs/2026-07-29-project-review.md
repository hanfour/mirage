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
`AppModel.swift:274` 補 200ms sleep——那就是同一個問題在使用者按 ⌘Q 時的補丁。

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
| **D4** | **內建 profile 沒進 bundle** + `AppModel.gameId` 寫死 `com.example.game` | `.auto` 自動啟用端到端不可能通；指標遊戲沒有可用 profile | 半天 | **P1** |
| **D5** | **overlay 編輯器不能拖**（29 行，只有存檔按鈕） | 母計畫交付項；鍵位映射是產品命根子但使用者改不了 | 2–3 天 | **P1** |
| **D6** | **輸入無順序保證**——每個事件各開一個 unstructured Task。**2026-07-29 擴大：現在有兩種資料形態**。(a) 觸控走 `TouchFrame` **全狀態快照**，晚到的舊快照覆蓋新狀態；(b) 鍵盤直通（D2）走**邊緣事件**——`KeymapController.route()` 對每個 keyDown/keyUp 各開一個 Task，路上沒有任何一層保證順序（MainActor 排隊 → `EmulatorClient` actor → 兩個各自獨立的 unary RPC，HTTP/2 跨 stream 不保證到達順序） | (a) 快速連點/連按產生幽靈觸點或吃掉動作，症狀是「遊戲沒反應」——又一個看起來像遊戲問題的靜默錯誤。(b) **比 (a) 嚴重一級**：down 與 up 對調就是**永久卡鍵**。快照有自癒機制（下一幀會蓋掉錯的狀態），邊緣事件沒有——那顆鍵從此一直按著，而且影響的是整個 guest 鍵盤輸入，不只當下那款遊戲 | 半天–1 天 | **P0** |
| **D7** | **`mouseUp` 早退吞掉放開事件**（`MirrorView.swift:35-52`）：拖到 letterbox 黑邊或視窗外放開，guest 手指永遠按著 | 同上，且黑邊在非同比視窗下必定存在 | 1 小時 | **P1** |
| ~~**D8**~~ | ~~**預設 transport 無法取消底層 RPC**~~ | **✅ 已修（2026-07-29，與 D1 同批）**。`GrpcStreamTransport` 改 class 持有真 call、改用 `makeStreamScreenshotCall`；`cancelStream()` 升為 `DisplayTransport` 的**必要**成員（刻意不給 default no-op），三個產品實作與兩個測試假件全數補上 | 實際與 D1 合計約半天 | — |
| **D9** | **驗證腳本本身是假的**：`verify_snapshot.sh` 11 行零斷言（只存 PNG + 印字）；`verify_reconnect.sh:77` 的 `getprop` 缺 `-s`（會打到實體手機） | 驗收訊號不可信 | 半天 | **P1** |
| ~~**D10**~~ | ~~**沒有 CI**~~ | **✅ 已完成（2026-07-29）**。品質閘門 `app/scripts/ci.sh`（三道閘門，每道都注入故障驗證過會紅）＋ `pre-push` hook 強制執行。**Drone／Jenkins 那類需要另外部署 server，本專案不採用**；hook 零基礎設施、今天就生效。已用本地 bare repo 實際驗證：閘門綠 → push 成功；閘門紅 → push 被中止且遠端確實沒收到 | 實際約半天 | — |
| **D11** | **焦點切換不清鍵位狀態**：按住 W 然後 ⌘Tab，keyUp 永不投遞。**2026-07-29 擴大：現在有兩顆東西會卡**——搖桿觸點永遠 down（原記載），**加上** 若按住的是 profile 沒綁的鍵（D2 起走直通），guest 的**鍵盤鍵**也永遠按著。機制本身已經有了：`KeymapController.setEditing(true)` 會把 in-flight 的直通鍵補送 up（2026-07-29 為 ⌘E 加的），**但失焦沒有接上它**——`MouseCapture` 的 `didResignKeyNotification` 觀察者只 `release()` 游標，不碰鍵盤／觸點狀態 | 使用者體感 bug，且卡住的鍵盤鍵不會自己恢復（觸點還有下一幀快照可能蓋掉，鍵盤鍵沒有）。修法已知：失焦時走與 `setEditing(true)` 同一條釋放路徑，觸點側再補一個全放開快照 | 2 小時 | P2 |
| **D12** | **搖桿觸點沒有 clamp**：`center ± radius` 可越界，`validated()` 不檢查。同一換算在 Python 端會 raise，Swift 端靜默送出 | ⌘E 把搖桿拉到邊緣就注入越界座標 | 1 小時 | P2 |
| **D13** | App 層 23 檔約 1300 行接線邏輯、5 條測試；`AppModel()` 光建構就有 8 個全域副作用 | §6 根因、D2、D4 全住在那裡 | 1–2 週 | P2（D1 修完成本降一半） |
| **D14** | **`PowerReducer` / `GrpcSnapshotService` 是死碼**，且 `PowerReducer` 的事件語意（`.snapshotSaved`/`.snapshotLoaded`）與實作相反——實作刻意不存不載快照 | 5 條測試在驗一台不存在的狀態機 | 1 小時 | P2 |
| ~~**D15**~~ | ~~**文件與碼庫不符**（見 §3）~~ | **✅ 已修（2026-07-29）**。§3 十項＋§8 C 三項全數補上更正註記（加註記、不重寫歷史）。含兩處**產品原始碼**註解：`StreamSize.swift`（fps 校準理由，補上 §11.2 的實測並指出它一半對一半錯）、`NormPoint.swift`（座標換算來源，那句話正是觸點偏移的 bug 本體）。連帶查出一個先前被「完全吻合」蓋住的 fps 落差 | 實際約 2 小時 | — |
| **D16** | MMAP transport 凍結未解，`MmapStreamTransport` 0% 覆蓋 | **什麼都沒擋**——§11.2 已證明傳輸不是 fps 瓶頸 | — | **建議封存** |
| **D17** | 環境漂移：canary emulator `37.2.1.0` 為除錯裝上後從未還原 stable | 所有 fps/延遲數字與 Phase-0 不可比 | 1 小時 | P2 |
| **D18** | `emulator-5554`（poc，共享）的 `pointer_location=1` 沒人關 | 小 | 5 分鐘 | P3 |
| **D19** | **`KeyTranslate` 把私用區字元原樣送給 guest**：`specialKeys` 只列了 8 個虛擬鍵碼，其餘鍵一律走 `characters` 路徑。但 macOS 對功能鍵給的 `charactersIgnoringModifiers` 是**私用區字元**——F1=`U+F704`、ForwardDelete=`U+F728`、Home=`U+F729`、End=`U+F72B`、PageUp=`U+F72C`、PageDown=`U+F72D`（以 AppKit 的 `NSF1FunctionKey` 等常數實測列印確認）。它們既非 nil 也非空字串，於是 `guard let characters, !characters.isEmpty` 放行，`.key("\u{F704}")` 被當成 W3C key 送出去。`KeyTranslateTests.swift:37` 的註解寫「沒有字元又不是已知特殊鍵 → nil，**不猜**」——**那句話只涵蓋「沒有字元」的鍵**，「有字元但那字元不是可列印字元」這一整類正好繞過它 | 送出 emulator 必不認得的 key 字串（設計 §2 的實測十個鍵不含任何一個私用區字元，無資料支持它會被翻譯）。後果是靜默無作用而非崩潰，但它讓「不猜」這句註解變成假的：碼確實在猜，只是猜在另一個分支 | 1 小時 | P2 |
| **D20** | **`KeymapEngine.unmappedCount` 在產品路徑上恆為 0**。它在 `apply(.keyDown)` 裡對「引擎不認識的鍵」累加，但 D2 之後那些鍵在 `KeymapController.route()` 就被攔去走直通，根本到不了 `apply`。唯一還會餵未綁定鍵進 `apply` 的呼叫端是 `handleFlagsChanged`（修飾鍵），而它不看這個計數 | `KeymapEngineTests` 那條斷言測的是 App 永不執行的路徑——不是錯的測試，是**測了一條死路**。這正是本專案要防的「綠燈但沒驗到產品行為」那一類 | 1 小時（決定：接上真正的消費端，或連同測試一起刪） | P2 |
| **D21** | **注入縫只做了一半**。`InputInjecting` 只涵蓋 `sendTouches`/`sendKey`，**`sendTap` 不在裡面**；於是 `MirrorView.Coordinator` 仍吃具體型別 `EmulatorClient`（actor），滑鼠→tap 這條路徑無法在不建真 gRPC channel 的情況下觀察，仍然只能靠讀碼驗證。同一個模組因此並存兩套注入慣例：`KeymapController` 吃協定、`Coordinator` 吃具體型別 | 「無 profile 退回直接 tap」（spec §7 驗收 4）是 P1-a 不回歸的核心保證，而它零自動化涵蓋。也讓下一個人不知道該照哪一套寫 | 1 小時 | P2 |
| **D22** | **編輯模式擋鍵盤、沒擋滑鼠**。`KeymapController.hasProfile` 是 `engine != nil && !editing`，所以一進編輯模式它就變 false；而 `MirrorView.Coordinator.sendMouse` 的 `guard controller?.hasProfile != true else { return }` 正是靠這個值決定要不要退回直接 tap——**編輯模式反而讓滑鼠點擊直接打進 guest**。「編輯時不干擾 guest」這個意圖被滑鼠那半邊整個繞過 | 使用者在 ⌘E 編輯器裡拖曳鍵位（D5 做完之後）等於在 guest 螢幕上亂點。兩個布林值目前共用一個述詞，語意其實不同：「該不該把滑鼠交給引擎」與「該不該送出去」 | 1 小時 | P2 |

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

## 4. 一處對審查結論的更正

審查建議「掃 AVD 設定，`hw.gpu.enabled=no` 可能一擊解決 60fps」。**主控端驗證後不成立**：

```
mirage-poc:   gpu.enabled=no   mode=auto  ram=2G     cores=4
mirage-game:  gpu.enabled=yes  mode=host  ram=4096   cores=4   ← fps 是在這台量的
mirage-bench: gpu.enabled=yes  mode=host  ram=4096   cores=4
```

recon 文件那句講的是 `poc`。量 fps 用的 `game` 機已是最佳設定，仍只有 29–44fps。這條路走不通。

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
| ~~鍵盤直通 `sendKey`~~ | ~~**任何文件都沒提過**~~ | ~~公開 API 零呼叫端~~ **✅ 已於 2026-07-29 實作（D2）** | 稽核當時：`Sources/MirageShell/` 與 `Tests/` grep `sendKey` 全零。D2 修復後不再成立——`KeymapController.swift:99`（`route()` 的直通分支經 `sendKeyToGuest`）、`AppModel.swift:221-222`（選單列 `onAndroidKey` 綁定，down 接 up）；同一組 grep 現為 `Sources/MirageShell/` 9 筆、`Tests/` 8 筆 |
| overlay 編輯器拖放 | 「拖放存檔、拖放手感 pending-human」 | 不能拖 | `OverlayEditorView.swift` 全檔 29 行，只有一個「存檔」Button；全 `MirageShell` 零 `DragGesture` |
| 內建 profile 上架 | 「佔位，待綁真 package」 | SPM 看不到那個檔 | `Resources/profiles/com.example.game.json` 在磁碟，但 `Package.swift` 無 `resources:` 宣告、全碼庫零 `Bundle.module` |
| 真遊戲 profile 內容 | 「留 Phase 1 三款遊戲」 | 只有 `com.example.game` | `AppModel.swift:59` 硬編碼；`MenuBarController.swift:105` 也 fallback 到同一個字串 |
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

| 項目 | 過時的記載 | 實際 |
|---|---|---|
| `AppModel.profile` 與偵測啟用不同步 | `README.md:77`、`RESULTS-p1d.md:36` 仍寫「不同步、overlay 上線前須讓 activation 回寫」 | **已回寫**：`AppModel.swift:201` `case .active(let p): keymap?.reload(p); profile = p` |
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
   `AppModel.startLifecycle()` 的綁定** — **漏記**。`MenuBarController.swift:100-102` 三個
   `@objc` 動作 → `AppModel.swift:219-222` 的閉包 → `client.sendKey`，單元測試零涵蓋
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

### 對 §0 的一處修正

§0 說「已知四次」誤診。本次逐項稽核後，數字應為**六類**——除了原本四項，
再加上 C 節的兩項「已修好但文件還寫著 pending」。而 D 節指出的第三種分類
（阻礙已消失、但沒人回頭）橫跨十餘筆，是本次稽核最大的單一收穫。
