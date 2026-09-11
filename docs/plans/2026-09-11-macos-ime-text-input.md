# macOS IME 與 guest 文字提交 實作計畫

**狀態：已核准執行 Task 1–4；Task 1–3 完成，Task 4 進行中；Task 5–8 本輪不做。**

**Goal:** 使用 Mac 注音／拼音在 Mirage 裡組字、選字，確定文字經剪貼簿＋一次貼上進入 LINE
草稿；組字按鍵不漏到 guest，連續提交有可調節流、可見失敗狀態且不自動重送。

**Architecture:** Core 純狀態描述組字、提交與節流；checked gRPC transport 執行剪貼簿與
W3C 貼上 chord；同一 InputQueue 與剪貼簿協調器統一序列化。Shell 接 NSTextInputClient、
輸入模式、失敗復原入口及本機 marked overlay。先補實際文字位置語意，再接 UI。

**Tech Stack:** 專案既有 Swift toolchain／v5 語言模式、strict concurrency、swift-testing、
grpc-swift、AppKit／SwiftUI；診斷沿用 Python／adb，產品主路不新增 adb 依賴。

**依據：**
- [已核准設計與 §10 實測回填](../specs/2026-09-11-macos-ime-text-input-design.md)
- [RESULTS-text-channels.md](../../app/RESULTS-text-channels.md)
- repo 的 D2／D5 實作計畫格式與 `app/scripts/ci.sh` 現行檢查。

## Global Constraints

- 主路固定 `setClipboard → readback → Control down/v down/v up/Control up`；
  `KeyboardEvent.text` **不作為中文提交或自動 fallback**。Android Paste 的 adb 結果不直接
  轉成 runtime 路徑，也不把 Android 279 當 evdev。原生長按貼上仍是未驗成的退路。
- clipboard 回讀只證明 clipboard 值；RPC OK 只證明請求返回。兩者都不是欄位消費 ACK。
  結果型別、UI、log、測試不得把它們命名為 `inserted/verified/successfullyTyped`。
- 必須有消費等待或節流；本階段沒有可靠消費 ACK，採**可調節流**，不偽造 ACK。
  100／250 ms 只是在一組配置下通過的樣本，不能硬寫成通用安全下限。
- timeout、斷線、外部 clipboard 衝突或使用者回報錯字時，不自動重試／重播 Paste；
  保留字串與狀態。任何已可能送出的 commit 都屬結果不確定，不能當「未送出」重排。
- 同字串測試只驗次數／去重，**異字、有序編號序列**才驗 clipboard 消費競態。
- 精確文字／clipboard 比對使用 Unicode scalar 值序列（或 UTF-8 bytes），不只用 Swift
  `String ==` 的 canonical equivalence；NFC é 與 NFD e＋附加符號被改寫時必須能抓到。
- 純邏輯留 Core，AppKit 接線留 Shell；文字、tap/key 與 clipboard 同步不能各建一條互不
  協調的 Task 佇列。actor 在 await 處會重入，不能以「放進 actor」代替順序測試。
- 每個 task 都先寫失敗測試、實際看見預期失敗，再實作。新 API 若先造成編譯紅，補最小
  型別後還要見到目標行為斷言紅，不能把「找不到型別」當成完整的 red 證據。
- 每個 task 結束前跑 **`(cd app && swift test)`**，全綠才作該 task 的 commit。
  下列 filter 用於開發期 red/green，不能取代 task 結尾的完整測試。
- 真機測試集中 `LiveGate`、使用 `@Test(.enabled(if: ...))`；前置不足明記 blocked/invalid，
  不得 `guard ... else { return }` 回報空的 pass。live 被 skipped 不等於驗收完成。
- 全部 task 完成後跑 **`(cd app && ./scripts/ci.sh)`**，保留預設連跑次數與既有閘門，
  全部通過才交付。CI 綠燈不取代 LINE 活體證據。
- 測試只用可清理的欄位／授權草稿，保留原內容，不按 Send；選字 Enter 必須驗不誤送。
  之前位置測試遭拒是**未驗證紀錄**，不是可行證據。本次只排進計畫，不現在重試執行。

## 共同的提交合約與節流政策

這是 Task 1–3 的實作合約，不是已存在的 API。

- `TextCommit`：唯一 ID、完整字串、focus/session generation、建立時間；不同 ID 即使字串相同
  也要各提交一次。重複 ID 不再 dispatch，不能按字串去重。
- 狀態：`queued → preparingClipboard → dispatchingPaste → settling → submittedUnverified`。
  `submittedUnverified` 表示依政策完成本次排程，**不表示欄位已插入**。
- 失敗至少分 `failedBeforePaste`、`indeterminateAfterDispatch`、`cancelledBeforeDispatch`、
  `rejectedPolicy/queueLimit`；帶可恢復字串與 commit ID，不把未知當空字串或 success。
- `TextSubmissionPolicy` 注入 `settleDelay`、RPC／回讀 deadline、排隊期限與容量限制。
  Shell 解析 `MIRAGE_TEXT_SETTLE_MS`，提供可調整值及暫停文字提交入口；不散落 magic sleep。
  初始工程候選可為 **250 ms**，必須標成待 Task 4／8 驗收的政策值，不是實測保證。
  100 ms 作對照；0 ms 只留在離線負對照假件／既有失敗 fixture，不作產品可用配置。
- 配置必須是可表示的有限正整數 duration；缺值使用明示候選，負數、0、非數字、溢位等
  非法值須明確拒絕並保留待送文字，不能偷偷退成 0 或悄悄換另一個值。參數有效不等於安全。
- 每筆交易快照自己的政策。`settleUntil` 以 monotonic clock 計算，**從最後合成 key-up 的
  checked RPC 返回後**起算；其間不得寫下一筆 clipboard、還原舊 clipboard，或讓 watcher
  偷跑。縮短設定只影響後續交易，不截短正在進行的保留期。
- 配置改變、版本／目標改變，先前測試不自動移植成認證。驗收報告保存配置與實際起點間距。

| 失敗／變更時點 | 必須看見的行為 |
|---|---|
| Paste 前回讀不符、超時或 session 已失效 | Paste 次數 0；停止該筆，保留文字與原因 |
| 開始送 chord 後錯誤、timeout／session 改變 | 補釋放合成鍵；結果標 unknown，暫停後續文字與 clipboard 覆寫，不 replay |
| settle 中外部 clipboard 變更 | 標不確定並暫停，保留最新外部內容；不以恢復舊值蓋掉它 |
| 佇列滿／等待超時 | 拒收或停止未開始的 commit，保留本機草稿；不得靜默丟棄或改貼最後一筆 |
| RPC 都 OK，但活體欄位比對失敗 | 該配置驗收 FAIL，停止放行功能；不得單純加大 sleep 後把舊失敗抹掉 |
| runtime 無欄位回讀但使用者發現錯字 | 提供「暫停文字提交／保留與複製草稿」；不宣稱會自動偵測或自動修正所有靜默錯字 |

正常 settle 到期可以依政策送下一筆，但仍未驗證欄位內容。遇到已知錯誤的 pause 與這個正常
未驗證狀態分開；手動恢復只放行**未 dispatch** 的待送資料，已未知的 commit 不自動重送。

## Task 切分與依賴

| Task | 交付 | 依賴 | 結束時的關鍵證據 |
|---|---|---|---|
| 1 | 政策／結果狀態與可控制的消費假件 | — | 改 delay 真的改 dispatch 邊界；RPC OK 不變 verified |
| 2 | checked 剪貼簿＋一次 Paste executor | 1 | 命令順序、錯誤分類、鍵釋放、零自動重送 |
| 3 | InputQueue／clipboard 協調與 session 取消 | 1–2 | 異字延遲消費＋watcher 競態可重現且被阻擋 |
| 4 | Swift 真路徑的插入／選取與節流驗收 | 1–3 | 普通 EditText、LINE 既有前後綴都正確；待驗項不能 skip 過關 |
| 5 | 本機組字純狀態 | 1 | UTF-16 與 finalize exactly-once，組字中 guest 事件數 0 |
| 6 | NSTextInputClient／模式／錯誤 UI 接線 | 3–5 | 真 view 路由、Return/Escape、key-up 所有權與失焦處理 |
| 7 | marked overlay／候選位置 | 5–6 | 真 AppKit 座標與可見候選窗匹配；不寫 guest 像素 |
| 8 | 真 Mac IME→LINE、故障驗收、CI | 1–7 | 真 IME＋精確欄位＋失敗路徑證據，最後完整 ci.sh 通過 |

**最高風險為 Task 3**：RPC 返回、consumer 消費、clipboard echo、watcher 與焦點變更不是同一
時點；最容易做出「全部 RPC 綠燈，卻貼錯最後一筆」的版本。Task 4 是先於 UI 的放行門檻，
Task 8 才是使用者回報是否真正修好的驗收。

---

### Task 1：政策、提交狀態與消費假件

**Files（擬議）:** Create `MirageCore/Input/TextSubmissionPolicy.swift`、`TextCommitState.swift`；
Test `MirageCoreTests/TextSubmissionPolicyTests.swift`、`TextCommitStateTests.swift`、
測試輔助 `DeferredPasteConsumer.swift`。路徑均在 `app/Sources/` 或 `app/Tests/` 對應模組。

**Interfaces:** 產出 policy、commit/result 型別與純轉移。Clock／sleeper 注入，測試不等牆鐘。
假件須區分「RPC 已回覆」和「Paste 實際讀 clipboard」；後者可手動推進，讀的是**消費當下的值**，
不能在 sendPaste 時先複製文字到 fake，否則把真實競態藏起來。

- [x] **Step 1 — RED：** 寫非法配置、不同 delay、policy 快照、重複 ID／相同文字不同 ID、
  timeout 狀態測試。加入兩筆異字 A/B：RPC 都立即 OK、回讀都正確，延後消費時不應得到 B/B。
  先讓無等待的簡單版本得到 B/B，確認失敗具有鑑別力；同字測試不能取代這條。
- [x] **Step 2 — 確認紅：** `(cd app && swift test --filter 'TextSubmissionPolicyTests|TextCommitStateTests')`。
  保存斷言差異，不以外部 SDK／權限錯誤當預期 red。
- [x] **Step 3 — GREEN：** 實作型別、純狀態／clock 合約；250 只集中於具名候選 policy，
  任意正值可注入。結果不提供假的 verified case；明確定義 before/after dispatch 的界線。
- [x] **Step 4 — 驗成立：** 虛擬時鐘到 deadline 前一刻 B 不能開始；到期才可；改成另一個值
  邊界同步改變。RPC／readback 事件無法直接跨過 settling。超時保留原文字／ID。
- [x] **Step 5 — 全測與提交：** `(cd app && swift test)`；全綠後 commit policy/state/tests。

### Task 2：checked transport 與單筆 Paste executor

**Files:** Create `MirageCore/Input/TextCommitTransport.swift`、`TextCommitExecutor.swift`；
Modify `EmulatorClient+Input.swift`，將 checked clipboard 操作放小型 extension；
Test `TextCommitExecutorTests.swift`／`TextCommitEventTests.swift`。

**Interfaces:** checked `set/readClipboard`、checked W3C key send，明確丟出失敗；不復用會吞掉
錯誤的 `try?` wrapper。Executor 接收 policy、clock、session-valid predicate，產出狀態／結果。

- [x] **Step 1 — RED：** fake 記錄完整順序。回讀錯值不得送 chord；每個 RPC 分別失敗／timeout
  必須有正確結果，dispatch 後未知不得變成可自動重試。驗 Unicode 整串只設 clipboard.text，
  沒有 KeyboardEvent.text、沒有每個中文字各造鍵事件。測不同 ID 的相同字串送兩次。
- [x] **Step 2 — 確認紅：** `(cd app && swift test --filter 'TextCommitExecutorTests|TextCommitEventTests')`；
  例如原來吞錯會誤繼續 Paste、原來無 checked 結果無法區分 timeout，必須看見對應斷言紅。
- [x] **Step 3 — GREEN：** 實作 set→有限回讀→再次檢查 session→四個合成鍵→settle。
  Paste 發出後的 cancellation 仍進未知分支，不能當沒送出；盡力釋放合成 v／Control。
- [x] **Step 4 — 驗成立：** 每案對照有序 trace、Paste 次數與 key-up：準備失敗 0 次，
  dispatch 後錯誤至多 1 次，釋放不是再次按下。移除錯誤傳播或加入 auto-retry，測試要紅。
- [x] **Step 5 — 全測與提交：** `(cd app && swift test)`；全綠後 commit checked executor。

### Task 3：共享佇列、clipboard 同步、失焦與保留期（最高風險）

**Files:** Modify `InputQueue.swift`、`InputInjecting.swift`、`ClipboardBridge.swift`、
`MirageShell/AppModel.swift` 的 clipboard 接線、`ClipboardWatcher.swift`；
Create `MirageCore/Input/TextClipboardCoordinator.swift`；
Test `TextCommitQueueTests.swift`、`TextClipboardCoordinatorTests.swift` 及既有 queue/bridge 測試。

**Interfaces:** `queue.commitText` 有結果／狀態通知；一個 consumer 管理文字交易與一般輸入。
所有 host→guest clipboard 寫入進同一協調邊界，禁止保留 AppModel 另開 Task 的旁路。

- [x] **Step 1 — RED：** 先接 Task 1 的延遲消費假件，讓 clipboard／RPC 全 OK 卻讀到 B/B。
  測 A settling 時 watcher 要寫 C、一般同步要還原舊值、切 focus 到 B、兩筆同值 echo、
  delayed echo、外部複製與佇列超限。把目前非同步 watcher 旁路保留時測試必須失敗。
- [x] **Step 2 — 確認紅：** `(cd app && swift test --filter 'TextCommitQueueTests|TextClipboardCoordinatorTests')`；
  至少觀察異字錯貼與 watcher 提前覆寫兩種行為紅，不只驗「呼叫順序看起來對」。
- [x] **Step 3 — GREEN：** 將 clipboard 所有權保留到 settle 結束，所有後續寫入／restore／
  watcher 都等待同一 gate。去重按 commit ID；own echo 不寫 Mac clipboard。
  proto 只有 clipboard 文字、沒有來源 ID：對同值外部複製的歧義要保存限制，不捏造可辨識來源。
- [x] **Step 4 — 取消與失敗：** generation 更新在 MainActor 輸入事件當下立即可見，不能排在
  長交易後才失效。Paste 前取消可停送；Paste 後／settle 中失焦則保守標未知，不因取消 sleep
  就解除 clipboard 保護。未知狀態暫停後續文字／clipboard，仍能在原隊列執行鍵／觸點釋放；
  不能等待使用者對話框而把 consumer 永久鎖住。RPC 與排隊都有有限期限。
- [x] **Step 5 — 驗成立：** 確定性時鐘＋消費 trace 得到 A/B，而非 B/B；watcher 在 gate 前
  寫入次數 0；失焦不在新欄位送舊 commit；外部新值不被舊 restore 蓋掉；重複 ID 不重播。
  fake 故意把真正消費延到 policy 之後時仍能產生 mismatch，證明節流不是全能 ACK；
  不能把 fake 改成一定在 250 ms 內消費來製造通用正確性的錯覺。
- [x] **Step 6 — 全測與提交：** `(cd app && swift test)`，包含既有 D6／D11／D23、clipboard 回歸；
  全綠後 commit。此時只表示協調合約成立，尚不能宣布 LINE 完成。

### Task 4：補齊中間插入／選取替換，驗 Swift 真提交路徑（UI 前置門檻）

**Files:** Create `MirageCoreTests/TextCommitLiveTests.swift`、`TextFieldEvidenceTests.swift`；
Modify `LiveGate.swift`、`text_channel_probe.py`／新增 `verify_text_commit.sh` 與欄位證據解析器；
新增 RESULTS 節與 measurements。Swift live 測試須呼叫 Task 2–3 的真 executor／queue，
Python／adb 只作清理、定位及觀察，不讓另一套 Python paste 代替被驗的 Swift 實作。

- [ ] **Step 1 — RED：** 先寫精確比對測試／錯誤 fixture：錯成結尾追加、整欄替換、丟掉前後綴、
  沒有 focus、stale/null XML、NFC/NFD 被互換、clipboard 等於期望但欄位不同，都必須 FAIL。以 clipboard 相符
  作 pass 的最小版本要真的紅；缺現場資料記 blocked，不偽造功能已失敗或已可行。
- [ ] **Step 2 — 確認紅：** `(cd app && swift test --filter TextFieldEvidenceTests)`，並測診斷腳本
  對錯欄位／錯內容退出非零。新增 live gate 關閉時顯示 skip；開啟但缺前置時 `#require` 失敗。
- [ ] **Step 3 — 建立前置：** 普通原生 EditText 先做、LINE 草稿後做；確認版本、IME、目標
  field、focus、原內容備份。每案獨立清理／種下已知 ASCII seed 並讀回，不先清掉使用者真草稿。
  新鮮 UI dump、已知 placeholder、精確碼位與欄位裁切圖沿用上一輪加固規則。
- [ ] **Step 4 — 中間插入實測（尚未驗過）：** 獨立設 `LEFTRIGHT`，把 caret 放在 LEFT 後，
  以真 Swift 主路提交 `中文🙂`；最終**必須恰為 `LEFT中文🙂RIGHT`**，不可接受結尾追加。
  保存定位手勢／按鍵、caret 可見證據與前後欄位；操作回覆不是 caret 位置證明。
- [ ] **Step 5 — 選取替換實測（尚未驗過）：** 獨立設 `LEFToldRIGHT`，只選 old，再提交
  `中文🙂`；最終也必須恰為 `LEFT中文🙂RIGHT`。先以可見選取範圍或 sentinel→guest Copy→
  clipboard 變成 old 證明選取；不能把原來 clipboard 已是 old 當 Copy 成功。
  這是驗 guest 選取後的 Paste，**不等於支援 NSTextInputClient 任意 guest replacementRange**。
- [ ] **Step 6 — 固定政策驗收：** 兩個目標皆跑六種既有字串、20 筆同字／異字 burst，
  100／250 ms 與最終選定配置分列。每個準備交付的配置至少三輪獨立重設，記實際起點間隔；
  輪數是回歸抽樣，不是安全下限證明。遇到內容不符保留失敗並停止放行該配置，不默改 sleep。
- [ ] **Step 7 — 驗成立：** 中間插入、選取替換在**兩個目標**都有精確欄位證據，Swift 路徑
  的 burst 不漏、不重、不亂序；未發送訊息、還原原草稿。權限／登入／可讀性不足是 blocked，
  task 不勾完成，也不靠 Task 5–7 的 UI 工作掩蓋前置缺口。
- [ ] **Step 8 — 全測與提交：** live 以 `MIRAGE_LIVE=1 MIRAGE_LIVE_TEXT=1` 明確啟用，
  腳本指定 serial、port、package、field、settle 值並保存紀錄；之後跑 `(cd app && swift test)`。
  所需 live 證據與完整測試皆通過才 commit 本 task 的驗收成果。

### Task 5：本機組字純狀態與 finalize

**Files:** Create `MirageCore/Input/CompositionState.swift`、`TextInputSession.swift`；
Test `CompositionStateTests.swift`／`TextInputSessionTests.swift`。

- [ ] **Step 1 — RED：** setMarkedText 多次變更不產生 commit；候選替換、UTF-16 selection、
  emoji 代理對、NFD／ZWJ、NSNotFound 與越界 replacement；insert→unmark 只一次 finalize，
  不同組字的相同文字兩次 finalize；取消／失焦後殘留 unmark 不提交。
- [ ] **Step 2 — 確認紅：** `(cd app && swift test --filter 'CompositionStateTests|TextInputSessionTests')`。
  讓以 String.count 當 UTF-16 長度、每次 marked 都送、unmark 重送的版本分別紅。
- [ ] **Step 3 — GREEN：** 本機 buffer 只代表尚未提交的組字，commit 一次快照到 Task 3。
  不模擬未知的 LINE document；超出本機範圍的 replacement 保留草稿並明示不支援，
  不猜成 guest Delete、全部取代或追加。
- [ ] **Step 4 — 驗成立：** 組字過程 sink 事件 0，確定事件與 commit ID 數量完全吻合；
  cancel generation 讓遲來回呼無效，字串碼位未被拆散／正規化。
- [ ] **Step 5 — 全測與提交：** `(cd app && swift test)`，全綠後 commit 組字 model。

### Task 6：NSTextInputClient、模式與錯誤／調整入口

**Files:** Modify `MirrorView.swift`、`KeymapController.swift`、`AppModel.swift`／選單；
Create Shell `TextInput/` client adapter 與提交狀態呈現；
Test `MirrorTextInputRoutingTests.swift`、`TextInputModeTests.swift`、`TextSubmissionStatusTests.swift`。

- [ ] **Step 1 — RED：** 在真 MirrorMTKView 的事件入口測 interpret 只呼叫一次，IME 吃的
  down/up 不送 guest；有 marked 的 Return 不能再送 Enter，Escape 不變 GoBack。
  覆蓋 flagsChanged、key-up 使用 down 時的所有權與鍵值、失焦／profile 切換，
  no-profile 的 LINE 預設文字模式、有 profile 時明確切換文字模式才暫停整份映射。
  timeout UI 不得顯示成功、關掉提示不能默默重試；非法配置保留文字而不啟動 Paste。
- [ ] **Step 2 — 確認紅：** `(cd app && swift test --filter 'MirrorTextInputRoutingTests|TextInputModeTests|TextSubmissionStatusTests')`。
  舊的直接 KeyTranslate 路由應違反「組字中零 guest 按鍵」；不只測 Core reducer。
- [ ] **Step 3 — GREEN：** 實作 NSTextInputClient 所需回呼、接 Task 5／3；不要同時呼叫
  interpretKeyEvents 與另一遍 handleEvent。配置解析值真正注入 queue policy，
  UI 的調整／暫停／複製未送草稿有效。已 dispatch 不確定的文字與未 dispatch 草稿分開，
  手動恢復不重播未知交易；不把 raw error 或每筆未驗證狀態做成干擾性的成功／失敗彈窗。
- [ ] **Step 4 — 驗成立：** 從 view 入口到 fake transport 的有序 trace 正確，候選用鍵不漏送，
  mode 切換先釋放舊鍵／觸點，調設定真的改下一筆等待時間；去掉 interpret 或所有權記錄時紅。
- [ ] **Step 5 — 全測與提交：** `(cd app && swift test)`，包含 keyboard/keymap/clipboard/focus
  回歸；全綠後 commit 本機 IME 接線與狀態入口。

### Task 7：marked overlay 與候選窗座標

**Files:** Create `MirageCore/Input/CompositionAnchor.swift`、Shell `MarkedTextOverlay.swift`；
Modify `MirrorContainerView.swift`／client firstRect；Test `CompositionAnchorTests.swift`、
`TextInputGeometryTests.swift`。

- [ ] **Step 1 — RED：** 點位與黑邊、1×／2×、副螢幕負座標、全螢幕／resize／移窗後的 screen
  rect；firstRect 不回固定 (0,0)，actualRange 對應本機 UTF-16 範圍；overlay 不搶焦點／觸控。
  將 Android pixels 或 backing pixels 當 AppKit points 的版本必須失敗。
- [ ] **Step 2 — 確認紅：** `(cd app && swift test --filter 'CompositionAnchorTests|TextInputGeometryTests')`。
  必須有真 NSView/window convert 接線測試，不只驗純乘除算術。
- [ ] **Step 3 — GREEN：** 以最後鏡像內容點位作近似錨點，無點位用內容內預設位置；
  本機 overlay 畫 marked／selection，firstRect 從實際 glyph 經 view→window→screen 轉換。
  幾何變更 invalidateCharacterCoordinates；不寫入 guest 畫面、不宣稱拿到 Android caret。
- [ ] **Step 4 — 驗成立：** 對照 Mac 截圖中浮層與系統候選窗，移窗／縮放後仍相鄰且可見；
  guest 截圖沒有本機 marked 字。沒有副螢幕設備時該實景項標未驗，不能把純函式當實機證據。
- [ ] **Step 5 — 全測與提交：** `(cd app && swift test)`；幾何與已具備環境的可視驗收通過後
  commit，剩餘環境限制明記給 Task 8，不能隱藏。

### Task 8：真 Mac IME→LINE、失敗行為、文件與最終 CI

**Files:** Create `verify_host_ime.sh`／證據解析測試 `HostIMEAcceptanceTests.swift`；
擴充 opt-in Shell/GUI 測試，更新 app README、設計狀態、RESULTS 與 measurements。

- [ ] **Step 1 — RED：** 先做驗收器失敗 fixture：clipboard 正確但欄位錯、同值掩蓋異字錯序、
  組字鍵漏入、commit 兩次、候選選字 Enter 變送出、原草稿被清空、只有 RPC OK 沒欄位證據，
  均應回 FAIL／invalid。拿舊版缺 IME 的真 view 作基準或撤掉 interpret 的隔離變體，
  必須能被測到；不在真聊天裡注入會發送訊息的負對照。
- [ ] **Step 2 — 確認紅：** `(cd app && swift test --filter HostIMEAcceptanceTests)`；
  驗收腳本對以上 fixture 非零退出，不能用沒有記錄／沒有測試直接成功。
- [ ] **Step 3 — 真 IME 正向：** 使用 Apple 注音與拼音的實際實體鍵序列，先普通 EditText、
  再 LINE 授權草稿。組字／候選更改期間 guest 原文不變；確定後整串恰好一次。
  LINE 的選字 Enter 先用已確認 Enter 不直接發送的草稿測試配置，並驗 guest Enter 事件數為 0；
  無此條件就列為 blocked，不拿真訊息測失敗。
  保存 Mac marked/candidate、guest 碼位與欄位裁切圖、commit ID／route／policy 診斷，
  不用直接呼叫 insertText、adb input text 或 UiAutomator.setText 冒充 Mac IME。
- [ ] **Step 4 — 位置與 burst 回歸：** 重跑 Task 4 中間插入與選取替換，這次文字從真 IME
  確定進 Task 3；確認前後綴保留。六種字串、異字 20 筆、同字計次、Mac 中英切換、
  Android IME 配置分列；採用的 settle 值與實際間距必須保存，值變了便不沿用舊驗收章。
- [ ] **Step 5 — 已知失敗：** 在隔離測試 transport 注入回讀錯誤／Paste timeout／斷線，
  從真 UI 確認字串保留、狀態非成功、後續文字暫停、無自動重送。另驗失焦、外部 clipboard、
  調整配置與使用者「暫停」入口。普通／LINE 欄位出現靜默 mismatch 就停止該配置驗收，
  不以 RPC 全綠覆蓋；不宣稱 runtime 能偵測所有內容錯誤。
- [ ] **Step 6 — 知道真的成立：** LINE 實際碼位／順序與草稿位置正確，組字鍵未漏、Enter
  未發送、原草稿／測試前 clipboard 已清理還原；遊戲 keymap 與 Unity 既有數字案例不回歸。
  讀不到欄位可用 sentinel→guest Copy 的獨立證據，不可直接讀原提交 clipboard；
  無法觀察的案例如實 blocked／人工驗證，不得用一張候選窗照片代表端到端成功。
- [ ] **Step 7 — task 完整測試：** `(cd app && swift test)` 全綠，完成 RESULTS（含失敗／
  配置／未驗清單），不把 Task 4 或任一 live blocked 項藏在測試 skip 裡。
- [ ] **Step 8 — 全部交付閘門：** `(cd app && ./scripts/ci.sh)`，依現行腳本確認離線端點、
  build-tests、預設三次完整 suite、NIO 與 fake-skip 等檢查全過。保留失敗 log，不降低
  CI_RUNS 或刪測試換綠燈。全部 task 所需證據成立後，才作最終提交／交付說明。

## 完成紀錄格式

每個 task 的紀錄至少包含：red 的具體失敗、green 的實際結果、完整 `swift test` 結果、
live 證據位置（或明確未驗原因）、實際 policy 與提交範圍。只有單元測試的 task 不冒稱
目標 app 已驗；有 live 驗收的 task 不拿 CI／模擬器 RPC 狀態代替內容證據。

執行紀錄見 `app/RESULTS-ime-tasks-1-4.md`。使用者已核准本輪依序實作至 Task 4，
Task 5–8 不在本輪範圍；Task 4 的實際欄位結果仍是放行門檻。
