# Mac IME Task 5–8

Task 8 的真 Mac 輸入法與實體鍵序列需人工操作；合成 AppKit callback 只算單元接線測試。
不以 insertText、osascript、adb input text、UiAutomator 輸入代替人工驗收。

## Task 5 — 本機組字

RED：4 個測試、27 個行為斷言失敗（空實作可編譯）。GREEN：完整 448 tests passed。
證據：`measurements/ime-tasks-5-8/task5-{red,green}.log`。
本機 UTF-16 buffer 保留 NFC/NFD/ZWJ；拒絕切半代理對與未知 guest replacement。
多次 mark 沒有提交出口；insert→unmark 僅一筆，不同組字的同字有不同 UUID。
取消 generation 拒絕舊 token。這些是純狀態證據，尚非真 IME 驗收。

## Task 6 — AppKit 路由與操作入口

RED：舊 MirrorMTKView 有 2 tests／3 issues：interpret 次數 0、guest 收到組字鍵、
key-up 在字元切換後由 a 變 b。GREEN：完整 454 tests passed。
`task6-red.log` 與 `task6-green.log` 保存實際輸出。

NSTextInputClient 接本機狀態及共享 queue；真正 view 入口的合成事件測試確認：
一次 interpret、組字 Return/Escape/flags 零 guest 鍵、舊 key-up 使用原鍵碼、
中文＋ZWJ＋é 只一組四鍵 Paste、設定 0 拒收且保留字串。這不是實體鍵／真 IME 驗收。
無 profile 預設文字模式；有 profile 預設映射，可明確切文字模式並釋放／暫停整份映射與游標捕捉。
模式／失焦／session 取消本機組字；未知 replacement 有提示且不猜 guest 編輯。
左下「文字輸入」可調候選間隔、暫停、核對後恢復、分筆複製保留文字。
恢復沒有重送出口；複製前先暫停 watcher 寫入。一般提交只顯示欄位未驗證。

計畫具體化：文字模式 Return 一律不直送 guest（包括未組字時），需用畫面送出鈕。
這保守擋住 insertText 清掉 marked 後同一 Return 再被當 Send 的風險。
Cmd-V 明確走同一提交路；其他 Cmd 快捷鍵仍留 AppKit，不新增 guest Meta。

## Task 7 — 本機浮層與候選座標

RED：2 tests／6 issues，範圍／尺寸／焦點及 anchor 的空實作失敗。
GREEN：完整 457 tests passed（`task7-green.log`）。
真 NSWindow 測試直接呼叫產品 firstRect，並在移窗／縮放後逆轉換回 glyph。
負座標視窗與 ZWJ UTF-16 insertion range 亦通過；負座標測試不等於有副螢幕實景。
浮層是鏡像 view 的本機子 view，不參與 guest framebuffer，也不接收點擊或 first responder。

另開可見測試視窗，在本機 2× 螢幕移動 (97,53) points、鏡像內容由 300×500
縮為 250×420；移窗兩軸偏差與縮放後反轉換偏差都是 0 point。
`geometry-window/geometry.json` 保存 rect／scale／誤差，`window.png` 是實際視窗擷取，
已看圖確認 A🙂中文 的浮層與「中」選取高亮可見。此圖的 preedit 是**合成 component fixture**，
不是 Mac 輸入法產生，`humanIMEVerified:false`。

**不能下的結論：**尚不能宣稱系統候選窗在實際 IME、全螢幕、1× 或副螢幕均準確。
錨點是最後一次內容內點擊；沒有 Android caret API，guest 自己移 caret 不會精確追蹤。
實作完成、已有設備的 AppKit 幾何驗證通過；系統候選窗相鄰／可見驗收轉交 Task 8 人工半部。

## Task 8 — 自動化半部；人工半部未完成

完成診斷收集、只讀欄位觀察／精確比對、五種隔離故障及人工操作清單。
沒有開遊戲／LINE 做新輸入；沒有用合成 callback 冒充實體鍵。
人工清單：`../docs/testing/2026-09-11-host-ime-human-checklist.md`。

### 診斷與精確欄位

`MIRAGE_IME_DIAGNOSTICS=/全新路徑/trace.jsonl` opt-in：保存事件／composition／commit ID、
interpret 路由、queue phase、實際交易政策、結果與 candidate rect。普通 guest key 的 dispatch
亦有紀錄，可抓候選 Enter／組字鍵外漏。文字只記 SHA-256 與 UTF-16 長度，不記明文；
檔案 0600、O_EXCL 拒絕覆寫，寫入失敗在面板顯示。這些事件不能鑑定是否真的由人按鍵。

`./scripts/verify_host_ime.sh watch ...` 只向既有 driver 發 `action:observe`，不清理／取得焦點／
輸入／發送。保存觀察開始與完成時間、精確欄位、裁切圖；失敗樣本為 INVALID，不能當空值。
`verify` 必須同時有：人工操作聲明、正確且聚焦的 fresh 欄位、marked 期間原文不變、
單次 interpret、input-client 來源（Cmd-V 不能代替）、預期提交的精確 hash／次數／順序、
一次 Paste dispatch、submittedUnverified 排程結束後的新觀察、最終精確碼位，以及原稿精確還原。
純 ASCII／Unicode 控制案另標 kind，不取代中文 IME 驗收。no-send 仍需人確認。

RED：最初一律 PASS 的驗收器被負對照打紅，保存在 `task8-red.log`。
GREEN：5 個 Python tests（包含多個負 fixture 與 CLI 子案例）通過，`task8-python-green.log`。
涵蓋 clipboard 對但欄位錯、preedit 外漏、NFC/NFD、重複／缺提交、Enter、失焦／stale、
缺診斷／雙 interpret、原稿被清空、政策不符、觀察時間重疊、以貼上代替 IME。
CLI 對錯欄位 exit 1；缺證據 exit 2；舊 FAIL 再執行拒絕覆寫，原 bytes 不變。
報告保存 expected／observed scalars、case／trace／snapshot hashes 及實際 dispatch 起點間距。
`policyChangedToHideFailure:false` 表示本工具從未改政策，不是替人工行為背書。

### 故障驗證與實際共用 UI

`HostIMEAcceptanceTests` 從 MirrorMTKView 入口以**合成事件＋隔離 transport** 驗證，
並擷取產品共用 `TextInputDetails` 的可見 NSWindow。不是活體 LINE／Mac IME 操作。

| 注入 | outcome | 失敗後／手動恢復後的 down 呼叫數 |
|---|---|---|
| 回讀不符 | failedBeforePaste(readbackTimeout) | 0 / 0 |
| 斷線 | failedBeforePaste(transport) | 0 / 0 |
| v-down timeout | indeterminateAfterDispatch(transport) | 2 / 2 |
| v-down 時失焦 | indeterminateAfterDispatch(staleSession) | 2 / 2 |
| v-down 時外部 clipboard | indeterminateAfterDispatch(clipboardConflict) | 2 / 2 |

2 是 Control-down 與 v-down 的**呼叫**，不能當 guest 已接受的證明。
五案均保留「保留é」、暫停後续，第二次輸入不新增 down；未知結果未勾核對無法恢復，
勾選後也不重送。另驗 late unmark 零提交、整份 keymap 暫停、診斷不覆寫與精確 hash。

第一批 `failures/` 截圖發現設定欄顯示預設 250，而測試實際注入 1 ms；交易 trace／
result 的 1 ms 是正確的。新增 `settingsDisplayActualQueuePolicy`：注入 137，舊 UI 顯示250，
如預期 RED（`task8-policy-display-red.log`）。改成從 queue 的實際政策初始化，顯示已套用值。
沒有改交易政策或延長等待來掩蓋失敗。修正後新目錄 `failures-policy-display-fixed/` 保存五案
trace／result／status.png，原資料保留；看圖確認 timeout 顯示「不確定」，mismatch 顯示「未送」，
新圖已標示實際 1 ms。**1 ms 只是假 transport 測試值，不是產品／活體認證。**

### 邊界與計畫具體化

- 文字模式中的 Return 不直送 guest；使用者若要發送，須點畫面送出鈕，本輪不測發送。
- mouse-down 也立即失效舊文字 session；已 dispatch 會保守未知。modifier flags 交 IME，
  不送映射引擎；keyDown 不因此被 handleEvent 第二次。
- 系統字元檢視器在失焦後的 callback 若屬已取消 session，保留文字並明示未送，不能靜默丟字。
  真系統選字器／注音／拼音與焦點互動仍由人工清單驗證；不能從合成事件推定可行。
- 全螢幕／副螢幕的真候選窗、六組實體輸入 corpus、真 IME 中間插入／替換、20 筆 burst、
  遊戲映射與 Unity 實際數字回歸仍待人工。Task 4 位置 PASS 不替代這些項目。

完整 Swift suite：**462 tests passed**（`task8-green.log`）。

最終 `ci.sh`：預設 **3 次完整 suite 全綠**、0 NIO ERROR、所有既有閘門通過；
新增 host IME 驗收器 5 tests、harness 50、probe 107 亦通過。
完整輸出保存在 `measurements/ime-tasks-5-8/task8-ci.log`。
本次沒有把任何真 IME／實體鍵／LINE 新輸入案例列 PASS。
