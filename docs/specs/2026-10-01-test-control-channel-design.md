# 測試控制通道：不經過真實游標操作 Mirage

- 日期：2026-10-01
- 分支：`feat/test-control`

## 問題

實機驗證與部分 `verify_*.sh` 用 CGEvent 送到 HID 層（`lib/cgkey.js`、`lib/cgclick.js`、scratchpad 的合成工具），會移動使用者的游標、把 Mirage 拉到前景。驗證期間使用者不能用電腦，兩邊會搶操作。

直接送給行程（`CGEvent.postToPid`）已實測不可行：游標沒動，但事件的 `windowNumber` 是 0，雙指拖曳等依視窗編號過濾的路徑全部收不到，Android 沒有任何觸控。

## 目標

Mirage 內建一個只在測試時開啟的控制通道，測試工具透過它把滑鼠、捲動、鍵盤事件送進鏡像視窗：

- 不移動真實游標，不改變前景 app，Mirage 在背景時也能操作。
- 事件走與真實輸入相同的處理路徑（事件佇列 → local monitor → `sendEvent` → responder），驗證結果才代表真實行為。

## 開啟條件與安全

- 只有環境變數 `MIRAGE_TEST_CONTROL=<socket 路徑>` 存在時才開啟。沒有這個變數時不建立任何 socket、不載入任何相關狀態。
- 只用 Unix domain socket，不開網路埠。建立時權限 0600。路徑已存在且不是 socket 時拒絕啟動通道並記 NSLog，不刪除該檔案；是殘留的 socket 才刪掉重建。
- 開啟時 NSLog 一行 `[test-control] 已開啟：<路徑>`，方便從 log 確認。
- App 結束時關閉並刪除 socket。
- `make_release.sh` 產生的 .dmg 不需要額外處理（環境變數由啟動方帶入，一般使用者從 Finder 開不會帶）。

## 協定

一行一個 JSON 請求，一行一個 JSON 回應（UTF-8，`\n` 分隔），同一連線可連續送多個請求。請求依序處理，回應在事件已排進 Mirage 的事件佇列之後才送出。

回應格式：`{"ok": true, ...}` 或 `{"ok": false, "error": "<原因>"}`。未知的 `cmd`、欄位缺漏、值超出範圍都回 `ok: false`，不能讓 app 崩潰。

座標一律是鏡像視窗內容區的座標，原點在左上，單位為點（`"unit": "pt"`，預設）或 0 到 1 的比例（`"unit": "norm"`）。

| cmd | 欄位 | 動作 |
| --- | --- | --- |
| `state` | | 回傳 `pid`、`windowNumber`、視窗 frame（螢幕座標）、內容區大小、是否全螢幕、標題列是否顯示、連線狀態、標題列按鈕的 frame（內容區座標，含 `home`／`recents`） |
| `mouse` | `action`（`down`／`drag`／`up`／`click`）、`x`、`y`、`unit` | 合成左鍵事件。`click` 是 down 加 up |
| `drag` | `from`、`to`（各為 `{x, y}`）、`steps`、`interval_ms`、`unit` | down、`steps` 次 drag、up |
| `scroll` | `x`、`y`、`dx`、`dy`（每步點數）、`steps`、`interval_ms`、`unit`、`momentum`（選填，放開後再送幾個 momentum 事件） | 觸控板手勢：began、`steps` 次 changed、ended，事件帶 `hasPreciseScrollingDeltas` 與 phase |
| `key` | `keyCode`、`modifiers`（`cmd`／`shift`／`option`／`control` 陣列）、`action`（`press`／`down`／`up`） | 合成鍵盤事件，⌘ 快捷鍵要能觸發 SwiftUI `.keyboardShortcut` 與選單的 key equivalent |
| `titlebar` | `visible`（bool） | 直接呼叫標題列顯示／隱藏的邏輯（見下方「hover 的限制」） |
| `fullscreen` | `on`（bool） | 進入或離開全螢幕，回應在動畫結束後送出 |

### 事件合成的要求

- 用 `NSApp.postEvent(_:atStart: false)` 排進事件佇列，不可直接呼叫 `window.sendEvent`。雙指拖曳靠 `NSEvent.addLocalMonitorForEvents` 收捲動事件，local monitor 只看得到從事件佇列取出的事件，直接 `sendEvent` 會繞過它。
- 事件的 `windowNumber` 必須是鏡像視窗，`locationInWindow` 必須對應請求的座標。滑鼠與鍵盤用 `NSEvent.mouseEvent(...)`／`NSEvent.keyEvent(...)` 建立；捲動事件沒有 NSEvent 建構函式，用 CGEvent 設定 phase（field 99）、momentum phase（field 123）、`scrollWheelEventIsContinuous`、位置與視窗欄位後轉成 `NSEvent(cgEvent:)`，轉完要確認 `windowNumber`、`phase`、`hasPreciseScrollingDeltas` 正確，不正確就回 `ok: false` 並說明，不能靜默送出錯的事件。
- Mirage 不在前景時鍵盤事件也要送達鏡像視窗的 responder。`keyWindow` 在 app 不在前景時可能是 nil，實作要處理這種情況，且不得因此呼叫 `NSApp.activate` 或改變前景 app。

### hover 的限制

標題列 hover 靠 `NSTrackingArea` 的 mouseEntered／mouseExited，這兩個事件由 window server 依真實游標位置產生，合成事件無法觸發。`titlebar` 指令因此直接呼叫顯示／隱藏邏輯，驗證的是「顯示後按鈕可按、隱藏後上緣點擊送進 Android」，hover 偵測本身仍需人工確認。

## 客戶端

- `app/scripts/lib/mirage_ctl.py`：可 import 的函式加上命令列介面（`python3 mirage_ctl.py <socket> state`、`... scroll --x 0.5 --y 0.6 --dy -10 --steps 25 --unit norm` 等），只用 Python 標準函式庫。
- `app/scripts/lib/mirage_ctl_selftest.py`：用假的 Unix socket server 驗證請求編碼、回應解析、`ok: false` 時以非 0 退出碼結束並印出 error。接進 `ci.sh` 閘門 8。

## 驗收腳本

新增 `app/scripts/verify_test_control.sh`，需要模擬器，流程：

1. 記下真實游標位置與前景 app。
2. 帶 `MIRAGE_TEST_CONTROL` 啟動 Mirage（經 `gui_session.sh`），等連線完成，再把前景切回啟動前的 app，讓 Mirage 在背景。
3. 用 `mirage_ctl.py` 依序：`state` 確認視窗與按鈕 frame；⌘1 → guest 前景是 launcher；開設定後 ⌘2 → 最近任務；`titlebar visible=true` 後點主畫面按鈕；`scroll` 雙指上滑 → guest `getevent`（`/dev/input/event1`）看到一次 `ABS_MT_TRACKING_ID` 按下與放開、`ABS_MT_POSITION_Y` 遞減，且 app 抽屜打開；`mouse click` 點一個 app 圖示 → 該 app 到前景。
4. 結束時斷言：真實游標位置沒變、前景 app 沒變、guest 沒有殘留按著的手指。
5. 不帶 `MIRAGE_TEST_CONTROL` 再啟動一次，斷言 socket 不存在。

## 不在這次範圍

- 既有 `verify_*.sh` 改用控制通道：`verify_first_run.sh`、`verify_avd_settings.sh`、`verify_input_latency.sh`、`verify_instance_lifecycle.sh`、`verify_screenshot_volume.sh`、`verify_release.sh` 之後逐支遷移。`verify_input_latency.sh` 量的是 HID 到畫面的延遲，可能要保留真實輸入。
- 全螢幕驗證（`gui_session.sh` 的 AXFullScreen）維持原樣。
- 文字輸入（IME）路徑。

## 驗收

| 項目 | 方式 | 負責 |
| --- | --- | --- |
| 協定解析、錯誤處理、座標換算 | Swift 單元測試：合法與不合法請求、`norm`／`pt` 換算、未知 cmd 回 `ok: false` | codex |
| Python 客戶端 | `mirage_ctl_selftest.py`，接進閘門 8 | codex |
| 事件確實走真實路徑 | `verify_test_control.sh` 全部通過，Mirage 在背景 | PM |
| 不干擾使用者 | 同一支腳本的游標與前景斷言；PM 跑的時候使用者照常用電腦 | PM |
| 未開啟時沒有通道 | 同一支腳本第 5 步 | PM |
