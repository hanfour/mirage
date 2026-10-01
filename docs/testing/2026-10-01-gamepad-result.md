# 手把支援實作結果

- 規格：`docs/specs/2026-10-01-gamepad-design.md`
- 狀態：Codex 程式與單元測試已完成；PM 實機驗收待執行。

## 自動化覆蓋

- 舊版內建 profile 與使用者存檔 JSON 的讀取、儲存、再讀取相容性。
- 快照差異、扳機門檻、tap 按住狀態、雙搖桿死區/優先序、右搖桿時間位移。
- 無 profile 的 Android 系統鍵與持續拖曳捲動。
- 編輯器新增、刪除、鍵盤/手把擷取、取消與清除手把鍵。
- 測試控制通道 `gamepad` 快照格式與 Python CLI。

Swift 測試受本次工作環境限制，未執行 `swift build` 或 `swift test`。Python selftest 已執行，4 項通過。PM 的測試控制通道端到端項目尚未執行。

## 實體控制器

未以實體手把驗證。GameController 連線、按鍵/搖桿讀值與前景狀態薄層未有硬體驗收；所有快照到觸控的判斷都由純型別與測試控制通道覆蓋。
