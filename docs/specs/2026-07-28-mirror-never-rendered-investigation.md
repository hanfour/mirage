# 調查記錄：鏡像顯示從未運作，且原因被記錯

- **日期**：2026-07-28
- **狀態**：**根因已確立並修正**（見 §6）。§1–§5 保留當時的偵察過程原文，因為推翻假設的順序本身就是這次的教訓
- **影響**：Mirage 的核心功能（把模擬器畫面顯示出來）自 P1-a 起從未真正運作過

## 0. 一句話

`MIRAGE_FPS_LOG` 的 `fps=` 在這個專案的歷史上**從來沒有非零過**。`RESULTS-p1a.md` 把它歸因於「螢幕鎖定」並標記 `pending-unlock`，P1-e 沿用同一個歸因。**那個歸因是錯的**——今天在螢幕未鎖、使用者從自己的互動式終端機執行的條件下重現，仍然是 0，且視窗全黑、橫幅顯示紅字「未連線」。

## 1. 為什麼拖到現在才發現

App 層唯一的可觀測訊號就是 `fps=`，而它同時被三件事影響：

1. 有沒有連上
2. 連上後有沒有拉到幀
3. 拿到幀後有沒有畫出來

三者都沒發生時，「0 行輸出」分不出是哪一段斷掉。P1-a 挑了一個合理的解釋（螢幕鎖定會讓 `CVDisplayLink` 不觸發，這本身是真的）並誠實標成 pending，但**那個解釋沒有被獨立驗證過**——而它剛好能解釋觀察到的現象，於是三個階段都沿用了它。

今天新增 `MIRAGE_CONN_LOG=1`（commit `bc0d169`）把這三段拆開，第一次執行就看到了真相。

## 2. 已確立的事實

```
[app] endpoint=localhost:8558
[conn] UI 狀態消費者已啟動
[conn] connecting <--connectRequested  yield=enqueued(remaining: 9223372036854775807)
[conn] ensureChannel=true probe=healthy(version: "37.2.1.0 (37.2.1-15875889)")
[transport] raw rgba (default; set MIRAGE_TRANSPORT=mmap to try mmap)
[conn] connected <--connectSucceeded  yield=enqueued(remaining: 9223372036854775807)
[conn] attachStream 掛上，請求 540x1200
[conn] streamScreenshot 已送出，等第一幀…
[conn] 幀 #1 540x1200 bytes=2592000
[conn] 幀 #2 540x1200 bytes=2592000
```

| # | 事實 | 證據 |
|---|---|---|
| 1 | **連線是成功的** | 健康探測回報 `healthy`、狀態機到達 `connected`、`lsof` 顯示 TCP `[::1]:8558 ESTABLISHED` |
| 2 | **幀確實有進來，且內容正確** | `540x1200 bytes=2592000`＝`540×1200×4`，與 `Frame.isValid` 的要求一致；持續執行 3 分鐘可收到 360+ 幀 |
| 3 | **狀態永遠傳不到 UI** | `stateCont.yield()` 回報 `enqueued(remaining: Int.max)`（值確實進了無上限緩衝區），消費者停在 `for await` 且未結束，但**一個值都沒收到**。故 `connState` 停在初始的 `.disconnected` → 橫幅紅字「未連線」 |
| 4 | **有真實合成視窗時會 SIGSEGV** | 使用者環境：收到幀 #1、#2 之後 `segmentation fault`。無合成視窗的環境（背景執行）不崩，幀持續累積 → **崩潰在渲染路徑，不在網路路徑** |

## 3. 已測試並推翻的假設

| # | 假設 | 推翻方式 |
|---|---|---|
| 1 | 螢幕鎖定導致 `CVDisplayLink` 不觸發 | 螢幕未鎖、使用者自己的終端機執行，症狀相同 |
| 2 | 是 `configurable-endpoint` 分支改壞的 | `main` 版二進位（`/tmp/mirage-main`）同樣 0 取樣 |
| 3 | GUI app 被當成 background-only 所以不驅動 | 使用者從互動式終端機執行，症狀相同 |
| 4 | `AppModel` 與連線迴圈是不同的 `EmulatorClient` 實例 | `ObjectIdentifier` 兩邊一致（`0x…f61e0`） |
| 5 | 主 actor 被餓死，消費者的恢復排不上 | 改成 `Task.detached` 後症狀不變 |
| 6 | Swift concurrency 協作執行緒池卡住 | 探針證明健康：`activeProcessorCount=8`、detached 任務執行、MainActor 任務執行、5 秒逐秒心跳全數印出 |

另外排除：`client.states` 只有**一個**消費者（`AppModel.swift`，已 grep 全碼庫確認）；`stateCont.finish()` 全碼庫**無任何呼叫**；`states` 是 `nonisolated let` + `AsyncStream.makeStream`（預設 `.unbounded`）的標準寫法。

## 4. 下一輪的起點

**先寫一個會紅的測試。** `MirageShell` 於 `670369b` 之後可被 `@testable import`——「`EmulatorClient` 的 `states` 送不到消費者」這件事**應該能在單元測試裡重現，不需要 GUI、不需要模擬器**。這會是那筆跨三階段的架構債第一次真正兌現。

注意 [[nio-teardown-injectable-channel-debt]] 記載的判準：**任何讓 `EmulatorClient` 走到 `ensureChannel()` 建真 channel 的單元測試，都會加載 NIO 卡死那筆債**。所以測試要能在不建真 channel 的前提下驅動狀態轉換——若做不到，那本身就是「可注入 channel」該優先做的又一個理由。

**SIGSEGV 另案處理。** 它只在有合成視窗時發生（需要使用者環境），但已知它發生在幀送達之後、位於渲染路徑。P1-a 當時就存在，故嫌疑落在 `b2c0a5d` 當時就有的碼（`texture.replace` / `blit.copy` / `cb.present`），**不是** P1-e 新增的 `onFrameSize`。lldb 下不易重現（與 [[nio-teardown-injectable-channel-debt]] 記載的 Heisenbug 特性一致）。

**文件已更正**：`app/RESULTS-p1a.md`、`app/RESULTS-p1e.md` 的 `pending-unlock` 歸因已加註指向本文件。

## 5. 對 Phase-1 的影響

`docs/specs/2026-07-28-phase1-game-recon.md` 那一輪把驗收線縮成 1 款、並確認了「點擊型遊戲跑得起來、模擬器能以 46–59 fps 串流」。那些結論仍然成立——它們量的是**模擬器與環境**，用的是 Python harness，不經過 Mirage。

但**「Mirage 顯示遊戲時 60fps」這條驗收線目前無法量**，因為 Mirage 顯示不出東西。修好本文件的問題是 Phase-1 的前置。

---

## 6. 根因（已確立、已修正）

**`AudioPlayer.start()` 用 interleaved 格式呼叫 `AVAudioEngine.connect(_:to:format:)`，
AVAudioEngine 的節點連接只接受 deinterleaved，於是丟出 NSException，在 `@MainActor`
上把 App 的啟動流程整個扯斷——MainActor 自此不再 drain 任何工作。**

```
AVAudioEngine.connect(node, to: mixer, format: <48kHz, 2ch, Float32, interleaved>)
  → AUInterfaceBaseV3::SetFormat → NSOSStatusErrorDomain Code=-10868
                                   (kAudioUnitErr_FormatNotSupported)
  → NSException 'com.apple.coreaudio.avfaudio'
```

### 6.1 一個根因如何同時造出 §2 的四個「事實」

| §2 的事實 | 其實是什麼 |
|---|---|
| 3. 狀態永遠傳不到 UI | 消費者 `Task {}` 建立在 `AppModel.start()`（`@MainActor`）內，**繼承 MainActor 隔離**。`stateCont.yield()` 確實把值放進了無上限緩衝區（故回報 `enqueued`），但要喚醒消費者必須把它的 continuation 排進 MainActor——而 MainActor 已經死了。`for await` 因此永遠掛著、也永遠不結束，與觀察完全吻合 |
| 4. 有真實合成視窗時 SIGSEGV | 同一條路徑的下游。修正後以真實合成視窗（`.app` bundle + `open`）連續執行 60 秒、期間持續操作 guest 使畫面變化，**未再重現** |
| `fps=` 恆為 0 | `Renderer.draw` 由 MTKView 的 display link 在**主執行緒**呼叫，MainActor 一死就不再被呼叫。修正前 `draw` 只跑 1–2 次就停 |
| 連線與收幀正常 | `EmulatorClient` 是獨立 actor、`FramePump` 跑在 cooperative pool，兩者都不經過 MainActor，所以完全不受影響——這正是「連線好好的、幀一直進來、畫面卻是黑的」這個矛盾組合的來源 |

### 6.2 為什麼 `do/catch` 沒接住

`AudioPlayer.start()` 的註解寫著「啟動失敗一律降級為無音訊——音訊絕不可拖垮鏡像主功能」。
那個意圖是對的，實作有兩個洞：

1. `do/catch` 只包住 `engine.start()`，沒有包 `engine.connect()`
2. 就算包了也沒用——**NSException 是 Obj-C 例外，Swift 的 `catch` 只接 `Error`**

例外從 Swift 的 async frame unwind 出去，把那一段執行流程整個拆掉，卻沒有終止程序：
主執行緒回到 run loop 繼續等事件（`sample` 抓到的堆疊乾淨得像 idle），而 MainActor
的 job queue 從此再也沒有被 drain 過。**沒有 crash、沒有錯誤訊息、沒有任何日誌**——
這是它能潛伏三個階段的原因。

### 6.3 定位它的關鍵一步

`MIRAGE_CONN_LOG`（`bc0d169`）拆開了「連上／拉幀／畫出」，但三段都停在同一個症狀上。
真正切開僵局的是**兩個心跳探針並排**：

```swift
Task { @MainActor in ... }   // 只跳 1 次就停
Task.detached { ... }        // 持續跳滿
```

MainActor 死、其他一切正常——這個對比立刻把嫌疑範圍從「網路／並發／渲染」縮到
「主執行緒上某一段同步程式碼沒有返回」，接著在 `startLifecycle()` 逐步加 log 就落到
`startAudio()`，再逐行落到 `engine.connect`。

**假設 #3（background-only）當初推翻得不嚴謹**：用「換一個互動式終端機執行」來推翻，
但 activation policy 取決於有沒有 `.app` bundle／`Info.plist`，跟終端機互不互動無關。
本輪補做了正確的驗證——打包成 bundle 後 `policy` 確實從 `2`(.prohibited) 變成 `0`(.regular)，
**而症狀完全不變**，這才真正排除了它。

**最終切開真相的是對照組**：一支最小 SwiftUI app（同樣 non-bundled、同樣從非互動 shell
執行）心跳跳滿 15 次。環境、bundle、headless 三個嫌疑一次全部出局，剩下的只能是 Mirage
自己的程式碼。

### 6.4 修正

- `AudioPlayer.start()` 改用 `interleaved: false`
- `AudioRingBuffer.readStereo(left:right:frames:)`：新增拆交錯的讀取。環形緩衝存的仍是
  guest 送來的交錯樣本（`AudioChunk` 的合約不變），拆交錯發生在即時執行緒上，
  維持零配置零鎖；只讀完整 frame，落單的半個 frame 留在緩衝裡等下一輪
- 迴歸測試：`AudioRingBufferTests` 5 條（拆交錯／部分讀／半 frame／空讀／環繞）、
  `ShellSmokeTests.audioPlayerStartReturnsWithoutTrapping`。後者的價值不在斷言而在
  「`start()` 能返回」——格式若被改回 interleaved，NSException 會讓整個測試程序 abort

### 6.5 驗證

| 項目 | 修正前 | 修正後 |
|---|---|---|
| MainActor 心跳 | 跳 1 次即停 | 持續 |
| `[ui] 收到狀態` | 一次都沒有 | `connecting` → `connected` 皆送達 |
| `Renderer.draw` | 跑 1–2 次即停 | 持續 |
| `MIRAGE_FPS_LOG` | 恆為 0 行 | 非零（專案史上第一次） |
| 音訊 render block | 從未被呼叫 | 持續被拉（`under` 遞增；`pkt=0` 是 guest 本身靜音） |
| 60 秒前景執行 | SIGSEGV | 存活，無崩潰跡象 |
| 測試套件 | — | 188 passed |

### 6.6 fps 實測：驗收線已達標，但量它有兩個陷阱

修好後第一次量到 `fps=1–2`，本文件曾據此寫下「瓶頸換成串流頻寬」。**那個結論是錯的**，
而且錯法跟 §0 的「螢幕鎖定」一模一樣——挑了一個能解釋現象的假設就當成結論。
補上控制變因後的實測：

| build | 串流尺寸 | guest 畫面 | fps |
|---|---|---|---|
| debug | 540×1200 | **靜止** | 1–2 |
| debug | 540×1200 | 持續變化 | 13 |
| **release** | **540×1200** | **持續變化** | **43–56** |
| release | 888×1972 | 持續變化 | 15–25 |

**Phase-1 的 60fps 驗收線在 release + 540×1200 下已經達到 43–56 fps**，與
`2026-07-28-phase1-game-recon.md` 用 Python harness 量到的 46–59 fps 完全吻合——
兩條路徑的量測終於對得上了。

**使用者實測複驗**（§7 的黑畫面修好之後，release build、真實桌面、約 5 分鐘連續運行）：
穩態 **45–55 fps**、峰值 **60**，畫面正常顯示。序列中數次掉到個位數，都對應 guest 畫面
靜止的區間——那是 `streamScreenshot` 變化驅動的正常表現，不是掉幀。

量這個數字有兩個會讓人得到錯誤結論的陷阱：

1. **guest 畫面必須持續變化。** `streamScreenshot` 是變化驅動的，靜止桌布本來就不送幀。
   對著靜止畫面量到的 `fps=1–2` 量的是「畫面沒在動」，不是任何瓶頸。
2. **必須用 release build。** debug 比 release 慢 3–4 倍（13 vs 50），拿 debug 的數字
   推論架構瓶頸會得到完全錯誤的圖像。

解析度的影響在 **launcher 上**近似線性：面積 ×2.7（540×1200 → 888×1972）對應 fps ÷2.5。

> ⚠️ **這個結論在真實遊戲上不成立**，見 §11。上面這組數字量的是 launcher，
> 它的 guest 端畫面產生很快，所以瓶頸落在傳輸；換成 Unity 遊戲之後瓶頸就換人了。
> 別把 launcher 的量測外推到遊戲。

---

## 7. 第二個 bug：`fps` 有數字但畫面全黑

音訊那個修好後暴露出來的**獨立**缺陷。症狀特徵很好認：**`fps=` 一路 40–60，畫面卻全黑，
且橫幅正常顯示已連線**。

### 7.1 根因

```swift
guard let texture,
      let drawable = view.currentDrawable,
      drawable.texture.width == texture.width,      // ← 要求完全相等
      drawable.texture.height == texture.height,
```

`draw(in:)` 用 `blit.copy` 整塊搬運，blit 要求來源與目的尺寸**完全相等**，不等就整幀跳過。
而這兩個尺寸來自兩條獨立演化的路徑：

- `texture` 尺寸 ← 解碼幀（emulator 送什麼就是什麼）
- `drawable` 尺寸 ← 視窗。`MTKView.autoResizeDrawable` **預設為 `true`**，每次 layout
  都把 `drawableSize` 拉回 `bounds × contentScale`，覆蓋掉 `upload()` 依幀尺寸設的值

於是「畫面出不出得來」被押在「`resizeDebounced` 請求的串流尺寸有沒有剛好等於視窗的
backing 尺寸」上。而 `StreamSize` 的上限 clamp、偶數對齊、`ViewportFit` 的 letterbox 捨入、
debounce 的 300ms 空窗——任一個都會讓它不等。**收斂是巧合，不是設計。**

`fps=` 照樣有數字，因為 `upload()`（fps 的計數點）在那道 guard **之前**。實測診斷：

```
texture=540x1200 drawable=918x1976 drawableSize=(540.0,1200.0) autoResize=true 相符=false
```

注意 `drawableSize` 已被設成 540×1200 而 `drawable.texture` 仍是 918×1976——
`drawableSize` 的變更要下一幀才生效，這是另一個會製造不等的來源。

### 7.2 修正

`view.autoResizeDrawable = false`。讓兩條尺寸路徑合而為一：**drawable 的尺寸權威是解碼幀，
不是視窗**。顯示端的縮放交給 CAMetalLayer 免費完成（長寬比已由 `MirrorContainerView`
的 letterbox 保證與幀一致，不會變形）。

這消除的是特殊情況本身，不是再加一層條件判斷——`resizeDebounced` 的角色也因此回歸正常：
它是「為了畫質與頻寬請求合適的串流解析度」，不再是「為了讓 blit 能跑而必須精確匹配」。

迴歸測試：`ShellSmokeTests.drawableSizeFollowsFrameNotViewBounds`——送一幀 540×1200
進去，然後改變 view 的 frame 並觸發 layout，斷言 `drawableSize` 不被拉走。
修正前該斷言實得 `(2036, 4866)`。

### 7.3 這兩個 bug 為什麼會一起被誤診

音訊那個把 MainActor 打死後，`Renderer.draw` 根本不再被呼叫，本 bug 完全被遮蔽。
而兩者的表面症狀都是「畫面是黑的」。先修好前者、`fps=` 開始有數字之後，
後者才第一次露出它自己的特徵（**有 fps 但畫面黑**）。

同一份調查記錄裡連續兩次「一個症狀、多個根因」，值得記住的判準是：
**`fps=` 量的是 `upload()`，不是 `present()`。它證明幀有進來並上傳到 texture，
不證明任何一個像素被畫到螢幕上。** 要證明後者只有一個辦法——看畫面。

### 7.4 §7.2 的修法不完整，真正的修法是取樣繪製

`autoResizeDrawable = false` 只是把 drawable 綁到幀尺寸，**仍然依賴「綁定能精確成立」**。
而幀尺寸根本不受我們控制：proto 的縮放合約是 can-be-less，實測請求 `562x1248` 會回
`561x1248`（**奇數**）。症狀重演——30 秒收到 1080 幀、`fps=` 一行都沒有、畫面全黑。

真正的修法是**消除「尺寸必須相等」這個要求本身**：`blit.copy` 換成 render pass 取樣繪製
（`MirrorShaders` 的全螢幕三角形 + linear sampler，`MirrorBlitter` 負責編碼）。來源與目的
尺寸從此無關，縮放由 GPU 取樣器免費完成，長寬比仍由 `MirrorContainerView` 的 letterbox
保證。`drawableSize` 因此交回 MTKView 自己管（`autoResizeDrawable` 回到預設）。

**教訓**：§7.2 那一版是「把兩條路徑綁在一起」，本質上還是在賭一個外部變數的值。
消除特殊情況跟「讓特殊情況剛好不發生」是兩回事。

## 8. `fps=` 指標本身是錯的（已修）

計數點原本在 `upload()` 裡，位於 `draw()` 的早退 guard **之前**。所以「幀進得來但一個
像素都沒畫上螢幕」時，`fps=` 照樣是漂亮的兩位數——**這個落差先後兩次讓「畫面全黑」被
誤判成已修好**（第一次是 §7 的 blit 尺寸，第二次是 §7.4 的奇數尺寸）。

已改為在 `present(drawable)` 之後計數，且只在「這一輪確實取到新幀」時計——重畫同一張不是
畫面更新，否則量出來的會恆等於螢幕更新率，看起來永遠達標。

**修正前後的數字不可比較**。Pixel Flow @ 540x1200 的實測：舊指標（upload）26.9–37.7 fps，
新指標（present）在同樣條件下 17.9 fps；而在**真實合成視窗**下（`.app` bundle + 前景 +
小視窗）是 **29–44 fps**。三個數字的差異全部來自量測條件，不是效能波動：

| 量測條件 | present fps |
|---|---|
| bare executable（視窗未真正合成，`currentDrawable` 常為 nil） | 17.9 平均 |
| `.app` bundle + 前景 + 小視窗（串流 540x1200） | **29–44** |
| `.app` bundle + 前景 + 大視窗（串流 887x1972） | 15–20 |

`app/scripts/verify_game_fps.sh` 目前用 bare executable，因此它報的數字**偏低且不可信**；
要它可信必須改成 `.app` bundle 啟動（本輪已驗證這條路可行）。**這一項尚未修。**

## 9. 測試套件本身是 flaky 的（既有問題，非本輪引入）

追 §7.4 的迴歸測試時發現：完整 `swift test` 會機率性停擺——26–30 條 async 測試 started
之後永遠不 complete，主執行緒閒置在 run loop。

**基準實測**：把本輪**所有**改動 stash 掉、回到 `6056dbd` 連跑四次 → **2 次卡住、2 次通過**。
所以這與本輪的改動無關，而且意味著**先前每一次「189 tests passed」都有約一半機率只是運氣**，
包括本文件 §6.5 引用的那一次。

嫌疑指向 `nio-teardown-injectable-channel-debt` 那筆既有的債——完整套件 log 裡的
`Cannot schedule tasks on an EventLoop that has already shut down` 是同一條線索。
新增的 Metal 迴歸測試被執行時觸發機率明顯升高，故先以 `MIRAGE_LIVE_METAL=1` gate 起來；
**那是權宜，不是根治**。根治要處理那筆 NIO 債（可注入 channel）。

## 10. 觸控座標用錯了尺寸（已修，commit `0cae17e`）

顯示修好之後第一次真正「用滑鼠玩」，症狀是**點擊不準**——十字線有出現（注入是通的），
但落在目標位置的**左上一半處**。

**根因**：`sendTouch` 的座標系是 guest 的**實體螢幕**（proto 明載 "physical location on
the screen"，本機 1080×2400），而 App 層拿**串流幀尺寸**（540×1200）換算。

實測（`phase0/harness/probe_touch_coords.py`）：送 `Touch(270, 600)`，`pointer_location`
疊層的十字線精確落在 **(270, 599)**。若座標系是串流影像，該落在 (540, 1200)。

> 第一版探測用 `getevent` 讀 raw 值，沒有換算該裝置的 ABS 範圍（max=32767），
> 把 raw 8191 誤讀成「滿值」而得出**相反**的結論；而且重跑兩次都抓不到事件，
> 才發現第一次那筆很可能是先前 swipe 的殘留。改用「疊層 + 抓幀讀十字線」才拿到可信結果。

同一個錯誤也在 keymap 路徑：`sendTouches(_:width:height:)` 的唯一呼叫端
`KeymapController` 傳的一樣是幀尺寸，所以 **P1-c 起所有鍵位映射觸點都是偏的**。
記憶中那句「引擎→多指注入活體通過」驗的是 harness 直接呼叫並自行傳尺寸，
沒有經過 App 層這段傳遞。

**修法是消除傳錯的可能，不是改對那個數字**：`sendTap(x:y:)` → `sendTap(nx:ny:)`、
`sendTouches(_:width:height:)` → `sendTouches(_:)`，換算收進 `EmulatorClient`（唯一
知道 guest 實體解析度的地方，由健康探測順手帶出）。拿掉參數後編譯器擋住每一個舊呼叫點，
`KeymapController` 的 `guestSize`/`frameSizeProvider` 整套佈線因此消失。

**活體驗證**：使用者實測點擊位置正確，Pixel Flow 可正常操作。

## 11. fps 的瓶頸不在 Mirage（實測定位）

Phase-1「1 款指標遊戲開箱即玩」走通後的第一次體感回報：**會頓、fps 20–35**。

### 11.1 對照組證明瓶頸不在 Mirage

用 Python harness 直接量**同一條串流**（不經過 Mirage）：

```
fps=30.4  p50=28.8ms  p95=78.2ms  avg_frame=2.47MiB  throughput=75MiB/s  (540x1200)
```

Mirage 側是 20–35 fps。**兩者一致 → Mirage 的顯示路徑沒有額外損失**。
而 `p95=78.2ms` 對比 `p50=28.8ms` 就是「頓」的來源：長尾幀要等 78ms（瞬間 12.8 fps）。

### 11.2 也不是頻寬瓶頸

同機同內容掃描解析度：

| 解析度 | fps | p50 | p95 | 每幀 | 吞吐 |
|---|---|---|---|---|---|
| 270×600 | 32.3 | 22.0ms | 72.0ms | 0.62 MiB | 20 MiB/s |
| 540×1200 | 30.4 | 28.8ms | 78.2ms | 2.47 MiB | 75 MiB/s |
| 1080×2400 | 22.0 | 37.2ms | 101.7ms | 9.89 MiB | 218 MiB/s |

**解析度降到 1/4，fps 只從 30.4 升到 32.3。** 頻寬瓶頸不會長這樣（那會近似線性）。
只有到 1080×2400（218 MiB/s）傳輸才開始成為限制。

**推論**：瓶頸在 guest 端的畫面產生速率（Unity 遊戲在 ARM 模擬器上的 render fps），
不在我們的傳輸或渲染。**這也意味著 MMAP transport 幫不上這個忙**——它省的是傳輸成本，
而傳輸不是瓶頸。

> ⚠️ 這條推論**尚未直接量到 guest 端的 render fps**。試過 `dumpsys SurfaceFlinger
> --latency`（這版 Android 拿不到資料）與 `getevent`（時序不可靠）。要坐實它，
> 下一輪需要一個能直接讀 guest render 速率的方法。**在那之前這是推論，不是結論。**

### 11.3 量 fps 的三個陷阱（踩滿了才記下來）

1. **guest 畫面必須持續變化**——`streamScreenshot` 是變化驅動的。本輪拿 launcher 當
   對照組量到 12.7 fps，那量的是「swipe 之間的靜止期」，不是效能。
2. **必須用 release build**——debug 慢 3–4 倍。
3. **必須量 `present` 不是 `upload`**——見 §8。

以及一個機器層面的：**`verify_game_fps.sh` 預設的 5558 是 AOSP bench 機，沒有 Google
帳號，Pixel Flow 在上面進不了遊戲**（卡在載入畫面）。能玩的是 5556（Play Store 已登入）。
量 fps 用 5558 沒問題，但任何「能不能玩」的驗證都必須用 5556。

## 12. 輸入延遲實測（驗收線 2）：不通過，而且量到的是下界

2026-07-29，用 `phase0/harness/e2e_latency.py`（開 `show_touches`、送 tap、以
`streamScreenshot` 監看該區域亮度變化）在 `emulator-5556` 上量：

```
n=41  misses=9  p50=78.1ms  p95=235.1ms
```

腳本註明此值不含 Mac 上屏，對照 80ms 上限時加 8–17ms：

| 指標 | 實測 | +17ms 上屏 | 驗收線 80ms |
|---|---|---|---|
| p50 | 78.1ms | **95.1ms** | ❌ |
| p95 | 235.1ms | **252.1ms** | ❌ |

### 這個數字是**下界**，不是實際體感

量測路徑是 **gRPC 直連**（Python client 送 tap、Python client 收幀），
**完全不經過 Mirage**。真實使用時還要加上 Mirage 這一段：幀解碼 → 上傳 texture
→ present。所以實際的 input-to-photon 只會比 95ms 更高。

**要量「經過 Mirage 的完整 e2e」需要在 `Renderer` 埋點**（記錄幀從 `LatestFrameBox`
取出到 `present` 的時間），目前沒有這個能力。

### 與 Phase-0 的落差，以及未控制的變因

`phase0/RESULTS.md` 記錄的是 p50 51.1/56.8ms、p95 65.2/65.7ms（同樣不含上屏），
明顯優於本次。但**不能直接判定為退步**，以下變因都沒有控制：

- **不同機器**：Phase-0 量的是 `emulator-5554`（AOSP）；本次是 `emulator-5556`
  （Play Store 映像、4GB RAM）。本次嘗試在 5554 上做對照量測，但那台畫面靜止、
  `streamScreenshot` 不出幀（change-driven），量不到。
- **本次那台當天跑過 Pixel Flow**，可能有背景負載。
- Phase-0 自己就有一筆更正記錄：那批數字量於「受污染主機」（見
  `phase0/RESULTS-rebaseline.md`）。

### misses 的偏差（Phase-0 已指出，此處同樣成立）

`misses=9`（50 次中 9 次逾時未偵測到畫面變化）**被排除在 p50/p95 的計算之外**。
那 9 次的真實延遲只會更長（甚至無限），所以回報的 p95=235ms 仍是樂觀值。

### 結論

**驗收線 2（輸入延遲 < 80ms）目前不通過**，而且量到的 95.1ms 是不含 Mirage 的下界。
下一步該做的是在 `Renderer` 埋點量完整路徑——在那之前，我們不知道 Mirage 這一段
貢獻了多少，也就不知道該優化哪裡。

### 12.1 延遲分解（2026-07-29 補量）

新增 `MIRAGE_LATENCY_LOG=1` 之後，Mirage 這一段終於量得到。完整鏈路的分解：

| 段落 | p50 | p95 | 佔比 | 量法 |
|---|---|---|---|---|
| 送出觸控 → 幀抵達 Mirage | 78.1ms | 235.1ms | **~2/3** | `phase0/harness/e2e_latency.py`（gRPC 直連） |
| **幀抵達 → present** | **20–28ms** | **31–48ms** | ~1/5 | `MIRAGE_LATENCY_LOG=1`（本次新增） |
| present → Mac 上屏 | 8–17ms | — | ~1/8 | `phase0/RESULTS.md` 的既有估計，未實測 |
| **合計** | **~110–119ms** | — | | 驗收線 **80ms** ❌ |

**這個分解就是做這件事的目的**：先前只知道「超過 80ms」，不知道該優化哪裡。
現在知道了——**瓶頸在 emulator 到 Mirage 之間那 78ms，不在 Mirage 的渲染**。

Mirage 自己的 20–28ms 裡包含幀解碼（`Data` → texture upload）與等下一次 vsync
（60Hz 下最多 16.7ms），所以**這一段已經接近它的下限**，再優化空間有限。

**優化方向因此明確**：要壓延遲得動傳輸與 emulator 端的幀產生，動渲染沒有用。
這也和 §11 的結論一致（fps 的瓶頸同樣不在 Mirage）。

> ⚠️ 兩段量測**不是同一次觀測**：78.1ms 那筆是 Python client 自己收幀，
> 20–28ms 那筆是 Mirage 收幀，兩者在不同時間、不同 client 下量的。相加得到的
> 110–119ms 是合理的估計，**不是一次端到端的實測**。要拿到真正的單次 e2e，
> 得在同一條路徑上同時打兩個時間戳（送 tap 的時刻與 present 的時刻），
> 那需要讓量測端能觸發 Mirage 的輸入——目前沒有這條路。
