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

> **下一輪的第 0 步**：把所有 `pending-human` / `pending-unlock` 逐項重新分類為
> 「做了沒驗」或「根本沒做」。半天。在確定清單是真的之前，任何優先序都是在按錯的地圖走路。

---

## 1. NIO 卡死：既有歸因是錯的（已驗證）

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
| **D1** | **NIO 關閉順序 + 阻塞式拆除**（見 §1） | 測試套件機率性卡死（實測 7 跑 3 卡）→ 歷來每次「N tests passed」都有相當機率只是運氣；擋住 CI 與所有 App 層測試；⌘Q 路徑靠 sleep 掩護 | 半天 | **P0** |
| **D2** | **鍵盤直通零實作**——`sendKey` 無呼叫端，無 profile 時按鍵直接丟棄 | 母計畫 Phase-1 交付項；使用者在視窗裡打字 guest 收不到 | 半天 | **P0** |
| **D3** | **8 處活體測試用 `guard/return`** 而非 skip → 未設 env 時報 passed 但零斷言 | 綠燈是假的。分佈於 `MmapStreamLive`/`KeymapInjectLive`/`SnapshotRoundTripLive`/`AudioLive`/`EmulatorClientReconnect`(×2)/`ClipboardBridge`/`EmulatorClientTouch` | 1 小時 | **P0**（最便宜） |
| **D4** | **內建 profile 沒進 bundle** + `AppModel.gameId` 寫死 `com.example.game` | `.auto` 自動啟用端到端不可能通；指標遊戲沒有可用 profile | 半天 | **P1** |
| **D5** | **overlay 編輯器不能拖**（29 行，只有存檔按鈕） | 母計畫交付項；鍵位映射是產品命根子但使用者改不了 | 2–3 天 | **P1** |
| **D6** | **輸入無順序保證**——每個事件各開一個 unstructured Task，而 `TouchFrame` 是全狀態快照，晚到的舊快照會覆蓋新狀態 | 快速連點/連按產生幽靈觸點或吃掉動作，症狀是「遊戲沒反應」——又一個看起來像遊戲問題的靜默錯誤 | 半天–1 天 | **P1** |
| **D7** | **`mouseUp` 早退吞掉放開事件**（`MirrorView.swift:35-52`）：拖到 letterbox 黑邊或視窗外放開，guest 手指永遠按著 | 同上，且黑邊在非同比視窗下必定存在 | 1 小時 | **P1** |
| **D8** | **預設 transport 無法取消底層 RPC**——`GrpcStreamTransport` 用便利方法丟棄 call handle。同樣的修法已套用在 clipboard、audio、MMAP 三處，唯獨預設開啟的 raw RGBA 沒有 | 孤兒 RPC 的未解決 promise 正是 D1 的燃料 | 1–2 小時 | **P1**（與 D1 同批做） |
| **D9** | **驗證腳本本身是假的**：`verify_snapshot.sh` 11 行零斷言（只存 PNG + 印字）；`verify_reconnect.sh:77` 的 `getprop` 缺 `-s`（會打到實體手機） | 驗收訊號不可信 | 半天 | **P1** |
| **D10** | **沒有 CI** | 所有品質閘門靠人手動跑；與 D1 疊加＝從未機械驗證過綠燈 | 半天 | **P1**（**必須在 D1 之後**——在 50% 機率紅的套件上架 CI 只會教會大家忽略紅燈） |
| **D11** | **焦點切換不清鍵位狀態**：按住 W 然後 ⌘Tab，keyUp 永不投遞，搖桿觸點永遠 down | 使用者體感 bug | 2 小時 | P2 |
| **D12** | **搖桿觸點沒有 clamp**：`center ± radius` 可越界，`validated()` 不檢查。同一換算在 Python 端會 raise，Swift 端靜默送出 | ⌘E 把搖桿拉到邊緣就注入越界座標 | 1 小時 | P2 |
| **D13** | App 層 23 檔約 1300 行接線邏輯、5 條測試；`AppModel()` 光建構就有 8 個全域副作用 | §6 根因、D2、D4 全住在那裡 | 1–2 週 | P2（D1 修完成本降一半） |
| **D14** | **`PowerReducer` / `GrpcSnapshotService` 是死碼**，且 `PowerReducer` 的事件語意（`.snapshotSaved`/`.snapshotLoaded`）與實作相反——實作刻意不存不載快照 | 5 條測試在驗一台不存在的狀態機 | 1 小時 | P2 |
| **D15** | **文件與碼庫不符**（見 §3） | 誤導下一個人重寫剛修好的 bug | 2 小時 | **P1** |
| **D16** | MMAP transport 凍結未解，`MmapStreamTransport` 0% 覆蓋 | **什麼都沒擋**——§11.2 已證明傳輸不是 fps 瓶頸 | — | **建議封存** |
| **D17** | 環境漂移：canary emulator `37.2.1.0` 為除錯裝上後從未還原 stable | 所有 fps/延遲數字與 Phase-0 不可比 | 1 小時 | P2 |
| **D18** | `emulator-5554`（poc，共享）的 `pointer_location=1` 沒人關 | 小 | 5 分鐘 | P3 |

---

## 3. 文件與實際的落差（依誤導程度排序）

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

**第 0 步：把所有 `pending-human` 重新分類**（半天）。理由見 §0。

之後：

1. **D1 NIO 關閉順序**（半天）——它不是最重要的，它是**乘數**。7 跑 3 卡＝每次驗證成本翻倍，而下面幾乎每件事都要動 `EmulatorClient`。順帶把 D8 一起做（同一批、同一個原因）。
2. **D3 假綠燈**（1 小時）——最便宜的一筆，且直接消滅「測試通過」這個訊號的雜訊。
3. **D10 CI**（半天，必須在 D1 之後）。
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
