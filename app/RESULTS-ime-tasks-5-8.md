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
