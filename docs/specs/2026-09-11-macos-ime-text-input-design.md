# macOS 輸入法：本機組字與 guest 文字提交設計

- 日期：2026-09-11
- 狀態：**Task 1–7 與 Task 8 自動化半部已實作；Swift 通道／位置有 Task 4 證據，真 Mac IME 與系統候選窗仍待人工**
- 觸發：LINE 訊息框在 Mac 中文輸入法下打不出字；切成英文，反而可由 Android IME 組中文。
- 相關：D2 鍵盤直通設計、D6 單一 InputQueue、D11／D23 失焦釋放、P1-b 剪貼簿橋接。

## 1. 要修的使用者行為與目前證據

使用者在 Mirage 裡點 LINE 訊息框，直接用 Mac 注音／拼音組字、挑選候選字，確認後完整文字
只進入 guest 一次。組字中的字母、注音、選字用空白／方向／Enter／Escape，不應變成 Android
的按鍵、返回動作或 LINE 的發送動作。英文、標點、刪除和遊戲鍵位操作不能因此壞掉。

初稿時 `MirrorMTKView` 直接在 `keyDown/keyUp` 呼叫 `KeyTranslate`，再經 `KeymapController`
送出 W3C key；沒有 `NSTextInputClient`、本機組字儲存或 `interpretKeyEvents`。
這足以確認**本機 IME 接線缺失**，但使用者描述的各層吞鍵順序與 LINE 的實際接收能力，
仍要用事件追蹤與欄位證據確認，不能把原因假設寫成已量到的事實。

初稿只新增設計文件；以下保留設計脈絡。實作進度見 `../../app/RESULTS-ime-tasks-5-8.md`。
2026-09-11 的通道實測與設計修正見 §10，不把通道測試當成 Mac IME 端到端已完成。

## 2. 文字要走哪條路

### 2.1 現有 KeyboardEvent 的欄位與限制

依本 repo 的 `phase0/harness/protos/emulator_controller.proto`（KeyboardEvent）與 Swift 產生碼：

| 欄位 | 可用內容／語意 | 本案用途 |
|---|---|---|
| `codeType` | Usb、Evdev、XKB、Win、Mac | 實體鍵碼的命名空間，不是文字編碼 |
| `eventType` | keydown、keyup、keypress | 編輯鍵／按鍵事件；不是組字階段 |
| `keyCode` | int32，依 codeType 轉 evdev | 不作中文字串通道；D2 已遇到 Mac `a` 鍵碼 0 的預設值問題 |
| `key` | W3C key，例如 Enter、Backspace、ArrowLeft，或可翻譯字元 | 保留控制鍵與既有遊戲鍵位路徑 |
| `text` | UTF-8 字串，逐字嘗試轉成 evdev keypress | **不是 Android InputConnection.commitText**；不能假設任意 Unicode 可插入 |

`keyCode/key/text` 不是 proto `oneof`，呼叫端必須自行保證只選一種。proto 欄位註解與
產生碼的 RPC 註解對多欄位優先序並不一致，本案不依賴任何一種優先序。
`text` 註解明示任意 UTF 字元可能被忽略，大量文字亦可能壓滿鍵盤緩衝；「UTF-8 可序列化」
不等於「中文字會到欄位」。D2 驗過 ASCII 與控制鍵的 evdev，**沒有驗過任意中文整串提交**。
D2 當年的「text 適合大量文字」描述不作為本案依據。

**決定：中文、混合字串、emoji 的首選是 guest 剪貼簿＋一次貼上動作，不用 text 猜運氣。**
`text` 保留為前置能力探測的對照組，不先做成自動首選再失敗重試。純 ASCII 在經驗證的
相容模式下才可退回逐鍵輸入；不能用逐字拆中文／emoji 偽裝 Unicode 支援。

### 2.2 提交交易：整串剪貼簿＋Paste

Mac 的一次確定提交形成 `TextCommit(id, text, focusGeneration)`，進現有 **同一條 InputQueue**，
不在 `insertText` 裡另開一個與 tap/key 並行的 Task。預計新增 `InputInjecting` 的可回報錯誤
文字操作及 `InputQueue.commitText`；現有 `sendKey`、`setGuestClipboard` 的 `try?` 不能拿來
判斷文字交易成功。

一筆交易的順序：

1. 確認已連線、仍是該文字輸入 session；舊 session 的待送文字取消並保留本機未送草稿。
2. 取得剪貼簿交易所有權，經 **gRPC setClipboard(ClipData.text)** 寫入完整提交字串。
   不先寫 `NSPasteboard.general`，也不靠 0.5 秒 watcher 輪詢把它搬過去。
3. 在有限逾時內讀回 guest clipboard，必須與預期字串一致。這只證明 clipboard 正確，
   **不是欄位已收到**。不一致就停在貼上之前，顯示失敗，不能繼續送 Paste。
4. 貼上之前再次檢查 focusGeneration／連線 session，失效就不送 Paste。
   在同一 queue 交易裡送 `Control down → v down → v up → Control up` 的 W3C key，
   經既有 sendKey transport。這是程式建立的 guest chord，不走目前只餵引擎的
   `handleFlagsChanged`。任何錯誤路徑都盡力補釋放合成的 v／Control。
5. 只記為 `submitted`（請求已交付），不記「文字已插入成功」。後續交易不能插進此交易的
   clipboard 寫入與貼上中間。保留最近提交的可恢復本機文字，不在錯誤後無聲丟掉。

`Control+v` 是設計首選，**尚待 stable 37.1.11 與 LINE 能力探測通過**；不能因為 W3C
Control/v 可送達就宣稱 LINE 一定接受貼上。剪貼簿回讀與 sendKey 回覆也沒有「目標 app 已讀取
clipboard」的 ACK：序列化只保證 Mirage 的請求順序，不等於 Android 欄位處理已完成。
因此不能在 chord RPC 一返回就立即還原 clipboard。相鄰 commit 的 settle 間隔須在前置探測
量定（初始候選 100／250 ms，未驗證），快速連續提交必須專項驗過；固定延遲不是正確性證明。
若無法在 LINE 穩定取得逐次精確結果，本方案的自動提交不得判通過，改評估具備消費 ACK 的
guest IME／InputConnection bridge，不能只繼續加 sleep 就說修好了。

### 2.3 必須與既有剪貼簿同步協調

現行 `AppModel.applyHostClipboard` 另開 Task，guest→host echo 會寫 Mac clipboard；
`ClipboardBridge` 又以文字相同去重。直接呼叫 setGuestClipboard 會造成三種問題：
IME 文字污染 Mac clipboard、watcher 覆蓋尚待貼上的內容、連續兩次相同字串被吃掉。

設計新增剪貼簿協調器（由 AppModel 持有、Core 保留純狀態）：

- 所有 host→guest clipboard 寫入與文字交易共享序列化邊界，舊 watcher Task 不得旁路穿插。
- 本機 IME 交易不修改 Mac clipboard；追蹤交易自己送出的 guest echo，避免回寫 Mac。
  暫緩一般 clipboard 同步到貼上交易結束；記錄內容／來源／session，不能只靠 lastValue。
- **提交去重按 commit ID，不按字串**。連續確認兩次「你好」要貼兩次；clipboard 內容未變
  也仍要產生第二次 Paste。
- 本版暫時保留最後提交字串在 guest clipboard，不立即還原，以免 app 延後讀取而貼到舊值。
  這是明確副作用；要保留 guest 舊 clipboard 需有可靠消費 ACK，不能偷偷用定時還原。
- 真正外部 clipboard 變更若與交易衝突，交易狀態標為未知／中止，保留最新外部內容與本機草稿，
  不以「恢復舊值」蓋掉使用者新複製的資料。第一版不宣稱無法辨識的同值外部複製可完美區分。

### 2.4 送不進去時的退路

| 狀況 | 退路 | 不可做的事 |
|---|---|---|
| set/getClipboard 明確失敗，尚未送 Paste | 保留未送文字，顯示「未能提交」與重試／複製文字入口 | 不吞錯後清掉本機文字 |
| clipboard 正確，但目標不接受 Control+v | 能力探測評估 Android `KEYCODE_PASTE`；若該目標驗過才選為它的貼上策略。否則保留字串，讓使用者在 guest 長按選「貼上」 | 不在 RPC OK 後自動再貼一次 |
| Paste 已送，逾時或欄位結果未知 | 顯示「提交結果未確認」，由使用者核對後決定是否重試 | 不自動重播，避免重複文字 |
| Unity 數字／ASCII 欄位不接受整串貼上 | 明示相容模式：經驗證的逐字 W3C keypress＋節流；0.8 秒只作該 Unity 欄位的起始參考值 | 不把 Unicode 分成 UTF-8 bytes／UTF-16 單元，亦不聲稱 ASCII fallback 能送中文 |
| 目標禁用貼上、Unicode 無可靠通道 | 保留可複製文字，標此欄位尚不支援；guest IME bridge 作後續獨立方案 | 不用 adb input text 中文碰運氣，不默默改回 Android 組字 |

能力探測可用 `adb -s <serial> shell input keyevent KEYCODE_PASTE` 分離貼上鍵問題。
它是 Android keycode 279，**不能直接塞進 KeyboardEvent.keyCode 當 Evdev**；本案不預設
W3C `Paste` 或 Linux 對照一定有效。若要納入 runtime fallback，必須另列其可用 transport、
裝置 serial、失敗處理與實測證據；第一版保守退到 guest 既有長按貼上，不新增隱藏 adb 依賴。

## 3. guest_text_input.sh 的四個坑怎麼落到設計裡

已逐項讀過 `app/scripts/lib/guest_text_input.sh`，那支是 Unity 生日欄位的 ASCII 自動化經驗：

1. **Unity 軟鍵盤可能全黑，focus/IME 仍正常**：以目標欄位焦點、輸入狀態與實際欄位文字
   交叉確認；不因黑鍵盤去改 `hw.keyboard=yes` 的 provision 設定。
2. **整串 ASCII 可能被 Unity 的自動格式化錯位**：整串 clipboard paste 必須獨立驗證。
   「01011990」逐字 0.8 秒的成功，不能外推成 LINE、中文、paste 都需要或都適用 0.8 秒。
   相容節流只加在驗明需要的目標；不拖慢所有 LINE 中文輸入。
3. **Escape／Back 可能離開整個 app**：組字取消完全留在 Mac，不送 KEYCODE_ESCAPE、
   GoBack 或 Back 去收鍵盤。沒有 marked text 時仍可保留既有明確 Android 返回操作。
4. **命令返回不是成功證據**：RPC／adb 退出碼只作路徑診斷，驗收一定看最終欄位精確內容。

不直接重用該腳本的「點座標、先刪四十次、再逐字注入」作產品實作：那會破壞使用者原有草稿
與選取範圍。文字提交只取代 guest 自己目前選取的內容，不自動清空欄位。

## 4. AppKit 接線、組字狀態與按鍵所有權

### 4.1 輸入模式及 keymap 相容

畫面串流沒有「guest 正在編輯哪個欄位」的可靠訊號，不用 OCR 猜焦點或只憑中文輸入法已選中
就停掉遊戲鍵位。設計分為：

- **文字輸入**：無作用中 keymap（例如 LINE）預設此模式；所有文字按鍵交給 Mac IME。
- **鍵位操作**：有遊戲 profile 時沿用既有映射與按住語意；提供可見的「文字輸入」切換，
  用於遊戲聊天。進文字模式時暫停整份映射，不能只放行沒綁的字母，否則一句話仍會少字。
- 鍵位編輯模式不向 guest 送文字。切模式、換 package/profile、失焦、休眠／斷線時，
  先釋放舊模式已送的鍵與觸點，再取消本機組字並增加 focusGeneration。

### 4.2 keyDown/keyUp 的分流

文字模式的 `keyDown` 只走一次 `interpretKeyEvents([event])`，由 AppKit 回呼
`setMarkedText`、`insertText` 或 `doCommand(by:)`；不另外把同一 NSEvent 送 KeyTranslate，
也不再同時呼叫第二遍 inputContext.handleEvent。候選字視窗由系統 IME 管理。

- 每次事件記錄是否起始時有 marked text、是否已觸發 commit／cancel／command，避免同一個
  Return 既選字又變成 guest Enter。**有組字時的 Return 只能確認文字，不能順便發送訊息。**
- 以實體 virtualKey 記錄 down 的所有者（IME、guest 控制鍵、keymap）。IME 吃掉的 down，
  對應 up 也吃掉；guest 的 up 用 down 時儲存的 key，避免切輸入法後字元改變造成卡鍵。
- marked text 存在時，方向鍵、空白、數字選字、退格與 Escape 優先交 IME；
  `cancelOperation` 只取消本機組字。文字模式的 flagsChanged 不旁路餵遊戲映射。
- 無組字時的 `deleteBackward`、移動、Tab、Enter 等以明確 command 對應既有控制鍵，
  一次 command 只送一組 keypress；尚未支援的 selector 不猜成一般字元或控制碼。
- ⌘ 快捷鍵保留 AppKit／選單處理，不直接送 guest Meta。`paste:` 若由 Mirage 接手，
  讀 host clipboard 後使用同一文字交易；與既有 watcher 的「同步」區分，不重複貼。
  現行 repo 沒有因為設了剪貼簿同步就自動具備完善的 ⌘C／⌘V 編輯語意。

### 4.3 NSTextInputClient 的本機資料模型

`MirageCore` 放不可變 CompositionState／事件歸屬與 transaction 狀態；
`MirageShell` 的 MirrorMTKView 負責 AppKit 協定與繪圖。state 只代表**尚未提交的本機組字**，
不假裝握有 LINE 全部文件、選取範圍或 guest caret。

| 方法 | 設計行為 |
|---|---|
| `setMarkedText(_:selectedRange:replacementRange:)` | 接受 String／NSAttributedString，更新本機 attributed buffer、選取與組字 ID；不產生 guest key/text/paste |
| `hasMarkedText`／`markedRange`／`selectedRange` | 按本機 buffer 回答；無 marked 時 markedRange 為 NSNotFound，空本機文件的 selection 為 (0,0) |
| `insertText(_:replacementRange:)` | 套用可解析的本機 replacement，一次 finalize 完整確定字串，入 queue 一筆 commit，清掉 marked；純英文直接 insertText 也走這條，不另送原始字母 |
| `unmarkText()` | 正常確定時將仍存在的 marked 內容 finalize 一次；若 insertText 已完成則 no-op。取消／失焦先標 cancel 狀態，再 discardMarkedText，防止取消回呼被當成提交 |
| `attributedSubstring(forProposedRange:actualRange:)` | 只提供本機 buffer 有效交集，精確回 actualRange；未知 guest 文件範圍回 nil，不編造周邊文字 |
| `validAttributesForMarkedText` | 列出浮層真正支持的字型、底線、前景／背景與 selected clause 類屬性 |
| `firstRect`／`characterIndex(for:)` | 使用下節本機浮層的 glyph 與螢幕座標；浮層外無已知文字索引時回 NSNotFound |
| `doCommand(by:)` | 按 4.2 區分本機組字與 guest 編輯命令，避免雙重注入 |

所有 NSRange 以 **UTF-16 code units** 處理，不能拿 Swift String.count 當 NSRange 長度；
測試含代理對 emoji、組合附加符號與 ZWJ。`selectedRange` 在 setMarkedText 裡相對於新字串。
NSNotFound 表示使用當前本機 selection／marked range，不把它當大索引做算術。
本機範圍內的候選替換可做；指向已送 guest 文字的 reconversion／replacementRange 暫不支援，
拒絕並保留可恢復文字，不能擅自送 Delete 或把替換誤做追加。

一次組字只由 finalize 產生一個 commit ID。`insertText → unmarkText` 不重送；
另一個組字即使文字完全相同也不是重複。實際 IME 回呼序列要在活體測試記錄並鎖回測試，
不能只以人造 insertText 回呼就宣稱整套輸入法能用。

## 5. marked text 與候選字視窗放哪裡

**要畫 marked text，但只畫 Mac 本機浮層，不畫入 guest，也不改 Metal 畫面像素。**
浮層是 MirrorContainerView 裡不搶 first responder、不攔滑鼠的輕量 AppKit text overlay，
顯示帶底線的組字與選取區，僅組字時出現；不另做可編輯 NSTextView 搶走協定回呼。
確認／取消即移除。guest 的 LINE 欄位只在確定提交後才改變，避免雙重顯示與半句被送出。

目前沒有 Android caret rectangle 通道。第一版使用**最後一次有效點擊鏡像內容的位置**作
近似錨點，並且文字預覽與候選窗跟著同一錨點；不聲稱能跟隨 guest 真正游標。
沒有錨點（例如只用 Tab 聚焦）時固定在鏡像內容底部內縮位置。欄位移動或軟鍵盤重排可能使
近似位置與真正 caret 不同，使用者再次點欄位可更新；完整 caret 同步屬另案。

座標流程（全部為 AppKit points）：

1. 滑鼠點位先換到 MirrorMTKView.bounds，儲存相對**實際鏡像內容**的正規化錨點，
   不含黑邊。視窗縮放／全螢幕後，用新的 mirror.frame 還原到容器座標。
2. 用 AppKit text layout 計算 marked range／本機 selection 的 glyph rect；不支援範圍
   回合法的本機 caret rect 並設定對應 actualRange，不能一律 NSZeroRect。
3. `view.convert(rect, to: nil)` 換到 window base，再 `window.convertToScreen(rect)`
   回覆 firstRect。不能把 backing pixels、Android pixels 或右上／左上原點混進去。
4. 浮層在可見內容內調整位置，必要時放錨點上方；螢幕邊緣依 window 所在螢幕的 visibleFrame
   處理，允許副螢幕負座標，不硬夾到全域 (0,0)。IME 自己決定候選窗如何避邊。
5. 視窗移動、resize、全螢幕、螢幕／scale 改變、浮層文字選取或錨點更新時呼叫
   `inputContext.invalidateCharacterCoordinates()`。改變的是座標，不觸發再次提交。

## 6. 預計改動邊界

| 區域 | 責任 |
|---|---|
| MirrorView／新增本機 composition client 與 overlay | NSTextInputClient、事件分流、marked rendering、錨點與 firstRect |
| KeymapController／AppModel／模式入口 | 文字模式、既有鍵位釋放、focusGeneration、clipboard 交易協調 |
| MirageCore 的純 state／InputQueue／InputInjecting | 組字 finalize、命令順序、可回報結果的 commitText、session 失效取消 |
| EmulatorClient 的輸入／clipboard API | checked set/getClipboard、合成貼上 chord、取消與錯誤分類 |
| ClipboardBridge／Watcher 接線 | 暫緩／來源辨識／避免 IME echo 污染 host clipboard |
| Tests 與 opt-in verify_host_ime 流程 | 本機 state、接線、順序、真 IME、LINE 精確欄位證據 |

不新增 proto 欄位、不把整串文字塞成 `.key("你好")`，不重構音訊／畫面傳輸。
不自動安裝或切換 Android IME，不改 AVD 的 hw.keyboard 設定。

## 7. 驗證：怎樣才算真的修好

### 7.1 先驗 guest 提交通道，不急著把 UI 做完

固定 stable 37.1.11、AVD、Android IME 與 app 版本，記錄 serial 與實際 package，
準備可讀回內容的普通 EditText 測試頁，再到 LINE 草稿框對照。每個案例先以獨立方法清空或
設定已知前後綴並確認 focus，不能拿「上一個注入命令沒報錯」當焦點成立。

同一測試字串依次比較 `KeyboardEvent.text`、clipboard＋Control+v、clipboard＋Android
Paste、手動長按貼上；這是**分開清理欄位的能力探測**，不是在使用者同一草稿上連續重試。
資料至少含 `Mirage IME 中文測試 42！`、同字串重複兩次、`你好🙂`、`é`、emoji ZWJ。
分別記錄：RPC／adb 結果、guest clipboard 回讀、焦點、最終欄位字串／截圖。
text 的 ASCII 成功與中文失敗要分列；ASCII 成功不能升格為 Unicode 路徑通過。

通道必須支持「既有前後綴中間插入」、「替換 guest 選取文字」、「快速連續 20 筆不同／相同
commit 不漏不重不亂序」。找出短間隔下 clipboard 讀取競態；若 LINE 無法穩定通過，就
退回 2.4 的明示退路／重新評估通道，**不宣稱 NSTextInputClient 做完便已解決回報**。

### 7.2 離線與 AppKit 接線測試

- 純 state：多次 setMarkedText 不產生 guest 事件，UTF-16 selection/replacement 正確，
  insert/unmark 只 finalize 一次；取消、失焦、換 profile／session 不把殘留字送到新欄位。
- 實際 MirrorMTKView 接線：事件交 interpretKeyEvents，按鍵 up 所有權正確；有 marked 的
  Return／Escape 不漏成 Enter／GoBack。只測 Core reducer 而未測 view 接線不夠。
- InputQueue fake：tap down/up → 一整筆 text transaction → 下一個 tap/command 順序固定；
  模擬 clipboard 失敗、錯內容、Paste timeout、失焦及並發 watcher，驗沒有多貼一次、
  沒有遺留 Control down、相同文字的不同 commit ID 都會送。
- 幾何：1×／2×、黑邊、負座標副螢幕、縮放／全螢幕與視窗移動，firstRect 與浮層相同錨點。
- keymap／鍵盤／焦點／clipboard 既有測試保留，依 repo 的 `app/scripts/ci.sh` 跑必要檢查。
  對去掉 interpret、漏送組字鍵、去掉 clipboard 交易排序三種故障注入，對應測試必須失敗。

### 7.3 LINE 真實驗收是必要條件

使用已登入且經使用者允許的測試對話**草稿框**，記錄 LINE package/version 與設定。
只在草稿裡驗文字，不按「發送」；若要驗完成輸入後 Enter 的實際發送行為，需另外指定
經授權的測試收件者。本案「選字用 Enter 不送出訊息」本身必須驗證。

| 操作 | Mac 端應看到 | guest／LINE 應看到 |
|---|---|---|
| 選 Mac 注音或拼音，逐鍵組「中文測試」但不確認 | 本機 marked text 與真正系統候選窗 | 原草稿完全不變；注音／拼音字母未漏入 |
| 用空白、方向／數字換候選，再 Enter 確認 | 候選消失；一次確定提交 | 精確出現所選文字一次，不多字母、不追加換行、不發送 |
| 組字時 Backspace、Escape | 本機刪除／取消組字 | 原草稿不變，LINE 仍在原畫面，不返回桌面 |
| 連續提交「你好」兩次，再混合英文／數字／標點／emoji | 每筆正常組字／提交 | `你好你好` 與後續字串完全一致，不被 bridge 同值去重 |
| 切 Mac 英文／中文，Android IME 也分中／英配置 | Mac 中文時由 Mac 組字 | 各配置的確定字串都一致，不再依賴 Android 二次組字 |
| 帶已存在的草稿、中間游標、guest 選取文字再輸入 | 本機只表示目前組字 | 前後綴保留，正確插入／替換，不先清空整個欄位 |
| 組字時移動／縮放／全螢幕／換螢幕 | 候選窗跟著浮層近似錨點，未跑到螢幕原點 | 不因重新佈局多提交一次 |
| 組字時失焦、換 app、休眠再回來 | 組字結束，沒有候選窗殘留 | 新欄位沒有幽靈文字、舊按鍵沒有卡住 |

必須透過**真正 Mac 輸入法與實體鍵序列**驗至少 Apple 注音與拼音；優先讓使用者人工鍵入並
收診斷事件，也可在選定輸入法後重播實體 keycode。直接 `insertText("中文")`、osascript
注入現成 Unicode、adb input text、UiAutomator.setText 都繞過 IME，不能取代這一步。

欄位確認採以下證據鏈：

1. Mac 視窗截圖／短錄影顯示 marked 與候選窗；commit 前的 guest `adb exec-out screencap -p`
   顯示草稿未變，區分 Mac overlay 和 Android 實際文字。
2. commit 後讀目標 editable node 的 text 與 focused/package（UIAutomator 可讀時），
   **逐字比對期望值、順序、次數**，並保存 guest 畫面。RPC OK／getevent 只能作輔助診斷。
3. 若 LINE 控件不暴露文字，保存清晰欄位截圖，另用 guest 的選取／複製做讀回：暫停 bridge，
   先把 guest clipboard 改成不相同的 sentinel，再在已確認的測試欄位執行全選／複製，
   getClipboard 必須等於實際完整草稿。**直接讀仍留著剛送字串的 clipboard 是循環證明**。
   如該控件也不允許複製，只能人工逐字核對，結果標人工驗證，不偽裝自動精確通過。
4. 診斷日誌串起 physical event ID、composition ID、commit ID、route 與 RPC 結果；
   預設只記長度／狀態，不把真實 LINE 聊天內容寫入 log。驗收使用已知測試字串，截圖限定測試區。

Unity 另跑生日數字欄位「01011990」的既有錯位案例，確認焦點與黑鍵盤不被誤判；
它通過也不能替代 LINE Unicode 驗收。LINE 未完成實際欄位驗證時，狀態只能是
「本機接線／通道測試通過，LINE 待驗」，不能報「已修好」。

## 8. 分階段交付與目前未驗證事項

1. 設計經使用者審閱後，先做 7.1 的通道能力探測，尤其 LINE 的 Unicode paste 與連續 commit。
2. 確定通道後實作本機 IME client、近似錨點／浮層、queue 與 clipboard 交易，補離線測試。
3. 跑實際 Mac IME→Mirage→LINE 的整條鏈，保存前後證據；再驗 Unity 與 keymap 回歸。
4. 依結果寫 RESULTS，明確分列支援配置、人工驗證、未支援欄位與未確立項目，再評估提交。

尚未驗證：LINE 實際貼上能力與節流需求、不同 IME 的 finalize 回呼順序、候選窗實際位置、
clipboard echo／外部變更競態。這些不是用單元測試綠燈就能消掉的事項。

## 9. 依據

本地：`MirrorView.swift`、`MirrorContainerView.swift`、`KeyTranslate.swift`、
`EmulatorClient+Input.swift`、`InputQueue.swift`、`AppModel` 的 clipboard 接線、`ClipboardBridge`、
`guest_text_input.sh`、`docs/specs/2026-07-29-d2-keyboard-passthrough-design.md`；
協定以本 repo 的 proto／產生碼與已安裝 SDK 的 `NSTextInputClient.h`／`NSTextInputContext.h` 核對。

- [Apple：NSTextInputClient](https://developer.apple.com/documentation/appkit/nstextinputclient)
- [Apple：interpretKeyEvents](https://developer.apple.com/documentation/appkit/nsresponder/interpretkeyevents(_:))
- [Apple：firstRect 的座標介面](https://developer.apple.com/documentation/appkit/nstextinputclient/firstrect(forcharacterrange:actualrange:))
- [Android emulator controller proto（上游參照）](https://android.googlesource.com/platform/tools/base/+/285ce4c92366c4b0b1152cc7ccd1f2d862320d7e/emulator/proto/emulator_controller.proto)
- [Android KeyEvent：KEYCODE_PASTE](https://developer.android.com/reference/android/view/KeyEvent#KEYCODE_PASTE)

上游文件與本地生成註解提供語意，並不等於已驗證本機 pin 版本或 LINE 支援；活體結果必須另記。


## 10. 2026-09-11 通道驗證回填

詳見 [RESULTS-text-channels.md](../../app/RESULTS-text-channels.md) 與其原始資料。
普通原生 EditText 先測，再到 LINE 26.14.0 草稿對照；未發送訊息、未實作 Mac IME UI。

- 單次 clipboard＋Control+v、clipboard＋Android KEYCODE_PASTE 都精確送達六種測試字串，
  包含中文、重複內容、emoji、NFC/NFD 重音及 ZWJ。text 路徑六案皆不完整。
- 20 筆不同字串、額外間隔 0 ms 的 Control+v 在兩個目標都出錯，儘管每次 clipboard
  回讀正確、RPC 都 OK；欄位大量重複最後一筆。**這否證「RPC 回來就可覆寫下一筆」**。
- 100／250 ms 的同字與異字 burst 本輪通過，只能作後續固定配置的測試起點，不是通用 ACK
  或安全下限。§2.2 的消費等待／節流必須落實；單次主路候選保留，無節流版本不採用。
- adb Android Paste 在本輪三種額外間隔通過，但本身有較長往返成本，尚無等速比較，
  也未決定 runtime 是否引入 adb。UI 原生長按 Paste 選單未取得，手動退路仍未驗成。
- 中間插入／選取替換的執行請求遭拒，未跑；完整 §7.1 不標全綠。
  逾時不自動重送、最終要讀欄位而非 clipboard 的兩條規則均保持。


## 11. Task 5–8 實作回填（人工驗收尚未放行）

NSTextInputClient、本機 UTF-16 組字、共享 clipboard Paste、可調政策／暫停／保留稿 UI 與
marked 浮層已接入。文字模式 Return 一律不直送 Android；Cmd-V 可走同一交易，但不能
用它取代 IME 驗收。候選錨點仍是點擊近似值，不是 Android caret API。

Task 7 在實際 2× NSWindow 移動／縮放的 glyph 座標偏差為 0 point，只有本機浮層圖，
**未驗真正系統候選窗**。Task 8 五種故障以合成 view 事件與隔離 transport 驗證，
真 Apple 注音／拼音／字元檢視器及 LINE 端到端仍 pending-human。
精確欄位工具不輸入、拒絕 clipboard 假通過及覆寫舊 FAIL；完整人工操作清單見
`../testing/2026-09-11-host-ime-human-checklist.md`。
