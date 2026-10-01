# 手把支援

- 日期：2026-10-01
- 分支：`feat/gamepad`

## 範圍與限制

Mac 上接的手把（Xbox、PlayStation、Switch Pro 等 GameController 框架支援的）透過鍵位映射轉成 Android 觸控，做法與 BlueStacks 相同。

Android 看不到「真的手把」：emulator gRPC 沒有手把輸入，在 guest 建虛擬手把裝置要 root，Google Play 映像不能 root。原生支援手把的遊戲因此也只能走鍵位映射。

使用者沒有實體手把。所有「手把狀態 → 觸控」的邏輯寫成純型別並單元測試；端到端用測試控制通道送模擬的手把狀態驗證。唯一驗不到的是讀取實體手把的 GameController 薄層，結果文件要明寫「未以實體手把驗證」。

使用者已定的三個決策：

1. 左搖桿控制 profile 的 joystick 綁定、右搖桿控制 look 綁定，類比力道對應觸點偏移量。
2. 按鍵在鍵位編輯器裡按手把綁定，同一個點擊點可以同時有鍵盤鍵與手把鍵。
3. 沒有 profile 時提供基本操作（返回、主畫面、最近任務、捲動）。

## 1. 資料模型

- 新增 `GamepadButton`（MirageCore/Keymap）：`a`、`b`、`x`、`y`、`leftShoulder`、`rightShoulder`、`leftTrigger`、`rightTrigger`、`dpadUp`、`dpadDown`、`dpadLeft`、`dpadRight`、`leftThumbstickButton`、`rightThumbstickButton`、`menu`、`options`。不含 Home 鍵（macOS 會攔給系統）。
- `Binding.tap` 加上選填的手把鍵：`case tap(key: KeyCode, at: NormPoint, gamepad: GamepadButton? = nil)`（若 enum associated value 不能帶預設值，就用其他不破壞既有呼叫端的寫法，並說明）。
- 舊的 profile JSON（沒有 gamepad 欄位）必須能照常讀取。測試要直接讀 repo 裡現有的 `Resources/profiles/*.json` 與使用者存檔格式的範例。
- joystick 與 look 綁定的資料不變：搖桿自動對應，不需要另外設定。

## 2. 手把輸入轉觸控

新增純型別處理「手把狀態快照」：

- `GamepadSnapshot`：按下中的按鍵集合、左右搖桿 (x, y)（-1 到 1，y 向上為正）、左右扳機（0 到 1，超過 0.5 視為按下）。
- 每次快照與前一次比較，產生事件：按鍵按下／放開、搖桿位置變化。

接到 `KeymapEngine`：

- 按鍵：與 tap 綁定的 `gamepad` 相符時，行為與鍵盤鍵相同（按下即觸點按下，放開即放開）。同一點的鍵盤鍵與手把鍵同時按住時只算一根手指，兩者都放開才放開。
- 左搖桿 → joystick 綁定：死區 0.15。死區外觸點在 `center + (x, -y) × radius`（螢幕 y 向下，要轉換）；回到死區內放開觸點。與鍵盤 WASD 同時操作時以搖桿為準，搖桿回到死區後才恢復鍵盤。
- 右搖桿 → look 綁定：死區 0.15。偏移時以固定頻率（60 Hz）產生視角位移，速度與偏移量成正比，最大值用 look 的 `sensitivity` 換算到「滿偏約每秒轉過半個螢幕寬」。look 綁定的 `activation` 鍵對搖桿不適用（搖桿推了就是要轉視角）。回到死區時停止並放開觸點，行為與滑鼠視角放開一致。
- 60 Hz 的計時放在外層（Shell），純型別只接受「經過 dt 秒」的輸入，測試不依賴真實時間。

## 3. 沒有 profile 時的基本操作

目前遊戲沒有 profile（或 profile 為空）時：

| 手把 | 動作 |
| --- | --- |
| B | 返回（`GoBack`） |
| menu（≡、Start） | 主畫面（`GoHome`） |
| options（⧉、Select） | 最近任務（`AppSwitch`） |
| 十字鍵上下、左搖桿上下 | 捲動：在畫面中央做一次單指拖曳，比照觸控板雙指滑動的實作（`TouchpadDragMachine` 與 `onMouse` 路徑），按住持續捲動 |
| 其他 | 不作用 |

有 profile 時以 profile 為準，上表不作用。

## 4. 鍵位編輯器：新增、刪除、改鍵

（原規劃的編輯器階段 C，按鍵擷取是綁定手把鍵的前提。）

- 抽屜加「新增點擊鍵」：在畫面中央新增一個 tap，立即進入改鍵等待。
- 選中綁定時可「刪除」。
- 選中 tap 時可「改鍵」：進入等待狀態，抽屜顯示「按下鍵盤鍵或手把鍵…（Esc 取消）」。下一個鍵盤鍵設為 `key`，下一個手把鍵設為 `gamepad`；兩種都可以各設一次，另有「清除手把鍵」。
- 抽屜列表顯示手把鍵（例如「● 點擊　J　Ⓐ」）。
- 擷取鍵盤鍵與現有編輯模式的按鍵處理不能衝突（編輯模式下 ⌘ 快捷鍵照常）。
- 刪除與新增不改變其他綁定在陣列中的順序（`KeymapEngine` 依順序分配觸控 id）。
- 擷取狀態寫成純型別（`EditorSession` 的延伸），可單元測試。

## 5. 讀取實體手把（Shell 薄層）

- 用 GameController 框架：監聽 `GCControllerDidConnect`／`DidDisconnect`，以 `GCController.current`（最近使用的那支）為準。
- 讀 `extendedGamepad`，每次值改變時組成 `GamepadSnapshot` 交給第 2 節的邏輯。
- 只在 Mirage 是前景 app 時作用（`shouldMonitorBackgroundEvents` 維持 false）。失去前景或手把斷線時放開所有手把造成的觸點。
- 選單列狀態顯示「手把：已連接（名稱）／未連接」。

## 6. 測試控制通道

`MIRAGE_TEST_CONTROL` 新增 `gamepad` 指令：送一份 `GamepadSnapshot`（`buttons` 陣列、`leftStick`、`rightStick`、`leftTrigger`、`rightTrigger`），走與實體手把相同的入口（第 5 節組好快照之後的那一步）。`mirage_ctl.py` 加對應子指令。

## 驗收

| 項目 | 方式 | 負責 |
| --- | --- | --- |
| 舊 profile 相容 | 單元測試：讀現有 JSON、存檔再讀回不變 | codex |
| 快照差異 → 事件 | 單元測試：按下、放開、扳機門檻、搖桿死區 | codex |
| 按鍵綁定 | 單元測試：手把鍵觸發 tap；鍵盤與手把同按只一根手指 | codex |
| 左搖桿 | 單元測試：半偏移落在半徑一半、y 方向轉換、回死區放開、與 WASD 的優先順序 | codex |
| 右搖桿 | 單元測試：以注入的 dt 產生位移、滿偏速度、回死區放開 | codex |
| 無 profile 基本操作 | 單元測試：B／menu／options 對應的 Android 鍵、十字鍵捲動產生按下→移動→放開 | codex |
| 編輯器擷取 | 單元測試：新增、刪除不影響順序、改鍵（鍵盤、手把、Esc 取消、清除手把鍵） | codex |
| 端到端 | 測試控制通道送手把快照：無 profile 時 B 返回、menu 回主畫面、十字鍵捲動（guest `getevent` 與前景 activity）；有 profile 時 A 觸發綁定點、左搖桿拖動 joystick 觸點 | PM |
| 實體手把 | 無法驗證，結果文件註明 | — |
