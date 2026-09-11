# Mac IME Task 5–8

Task 8 的真 Mac 輸入法與實體鍵序列需人工操作；合成 AppKit callback 只算單元接線測試。
不以 insertText、osascript、adb input text、UiAutomator 輸入代替人工驗收。

## Task 5 — 本機組字

RED：4 個測試、27 個行為斷言失敗（空實作可編譯）。GREEN：完整 448 tests passed。
證據：`measurements/ime-tasks-5-8/task5-{red,green}.log`。
本機 UTF-16 buffer 保留 NFC/NFD/ZWJ；拒絕切半代理對與未知 guest replacement。
多次 mark 沒有提交出口；insert→unmark 僅一筆，不同組字的同字有不同 UUID。
取消 generation 拒絕舊 token。這些是純狀態證據，尚非真 IME 驗收。
