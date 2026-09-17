# 啟動流程與鏡像視窗脫鉤設計

背景模式啟動時完全不建立鏡像視窗。一般模式的行為不變。

## 1. 已確認的事實

以下都在 2026-09-17 於本機實測。

- 背景模式（`f92d002`）啟動時，鏡像視窗仍在畫面上停留 318 到 472 ms（修改前 557 到 571 ms），
  以 20 ms 取樣 `CGWindowListCopyWindowInfo` 量到，每個版本量兩次以上。
- 這段期間 Mirage 視窗排在所有一般視窗的第 2 層，只被 iPhone 鏡像輸出蓋住，
  切成 `accessory` 並不會讓它落到其他 app 後面。
- 原因：`MirageScene` 用 SwiftUI `Window` 場景，SwiftUI 在啟動時建立並顯示視窗，
  之後才執行 `.task`。整段啟動流程（`start` → `startLifecycle` → `seedBuiltInProfiles`
  → `loadKeymap` → `startDetection`）都在這個 `.task` 裡，所以在 `.task` 內做任何隱藏都來不及。
- `.defaultLaunchBehavior(.suppressed)` 需要 macOS 15，本專案最低支援 14；而且視窗被抑制時
  `.task` 不會執行，要叫出視窗必須從某個存在的 view 取得 `openWindow`，背景模式下沒有這樣的 view。
- 依賴「那一個視窗」的程式碼：`AppModel.startLifecycle()` 讓出一輪 run loop 後以
  `NSApp.windows.first` 設定 `AppLifecycle` 委派；`AppModel.wake()` 以 `NSApp.windows.first`
  顯示視窗；`verify_fps_fullscreen.sh` 刪除 UserDefaults 的 `NSWindow Frame mirage-mirror`；
  `gui_session.sh` 以 AX 設定 `window 1` 的 `AXFullScreen`。
- `AppModel` 共 1,237 行、10 個檔案，連線、遙控、音訊、語音辨識與選單列、視窗的程式碼交錯在一起。

## 2. 不做的事

- 把 `AppModel` 拆成與 UI 無關的核心（`MirageEngine`）與 GUI 兩層。這是第二階段，
  等 MCP 端口（`mirage-mcp` 執行檔）開始做時再做，屆時有第二個使用端可以驗證介面切得對不對。
  本文件第 6 節先列出成員歸屬，不搬動程式碼。
- 改用純 AppKit、拿掉 SwiftUI App。主選單（⌘Q、編輯選單、全螢幕）要全部自建，文字輸入的回歸風險最高。
- 修改鏡像畫面的內容（`MirrorView`、疊層、`.alert`）。只搬位置，不改內容。

## 3. 結構

```
MirageEntry.main()
  └─ MirageScene (SwiftUI App)
       ├─ Settings { EmptyView() } + 移除「設定…」選單項目   ← 只用來讓 SwiftUI 提供主選單
       └─ @NSApplicationDelegateAdaptor AppDelegate
            ├─ let model = AppModel()
            ├─ applicationWillFinishLaunching：背景模式切 accessory（既有）
            └─ applicationDidFinishLaunching：Task { await model.launch() }

AppModel
  ├─ launch()：原 .task 內容，順序不變
  └─ let windowController = MirrorWindowController(model 的弱參照)

MirrorWindowController
  ├─ window() → NSWindow   第一次呼叫才建立，之後都回傳同一個
  └─ show()                 經 AppLifecycle.wake(showing:) 顯示

MirrorRootView (SwiftUI)    原 Window { } 內的 ZStack、兩個 .alert、.frame
```

## 4. 啟動順序

| 步驟 | 一般模式 | 背景模式 |
| --- | --- | --- |
| applicationWillFinishLaunching | 不動 | `setActivationPolicy(.accessory)` |
| launch() 開頭 | `windowController.show()` | 不建立視窗 |
| start() | 連線 | 先開遙控再連線（既有） |
| startLifecycle() | 建立 `AppLifecycle`、選單列 | 同左 |
| startLifecycle() 之後 | 不動 | 遙控成功：`lifecycle.didHideWindow()` 進休眠；失敗：`windowController.show()` |
| seedBuiltInProfiles、loadKeymap、startDetection | 同原順序 | 同原順序 |

背景模式的休眠或叫回視窗放在 `startLifecycle()` 之後，因為兩者都要用到 `AppLifecycle`。
一般模式在 `launch()` 開頭就顯示視窗，與現在「啟動時看得到視窗」一致。`AppLifecycle` 在
`startLifecycle()` 才建立，所以視窗建立時若 `lifecycle` 還是 nil，委派要在 `startLifecycle()`
建立 `AppLifecycle` 之後補設；`MirrorWindowController` 提供 `attach(delegate:)` 處理這件事。

移除的程式碼：

- `startLifecycle()` 內「讓出一輪 run loop，找 `NSApp.windows.first` 設委派」整段。
- `hideWindowEarlyForBackgroundMode()` 與 `MirageScene` 的呼叫點。
- `applyBackgroundModeAfterStart` 內的 `window?.orderOut(nil)`（沒有視窗可藏）。

## 5. MirrorWindowController

建立視窗時設定：

| 屬性 | 值 | 理由 |
| --- | --- | --- |
| `styleMask` | titled、closable、miniaturizable、resizable | 與 SwiftUI `Window` 預設相同 |
| `title` | `Mirage` | AX 與腳本以此辨識 |
| `contentView` | `NSHostingView(rootView: MirrorRootView(model:))` | 畫面內容不變 |
| `contentMinSize` | 270×600 | 原 `.frame(minWidth:minHeight:)` |
| `setFrameAutosaveName` | `mirage-mirror` | UserDefaults key 不變，`verify_fps_fullscreen.sh` 不用改 |
| `collectionBehavior` | 加入 `.fullScreenPrimary` | SwiftUI 原本自動加；少了它無法全螢幕，`gui_session.sh` 的 AXFullScreen 會失敗 |
| `isReleasedWhenClosed` | false | 關視窗是隱藏（`windowShouldClose` 回傳 false），物件要留著 |
| `delegate` | `AppLifecycle` | 既有的關視窗→休眠路徑 |

單一視窗的保證（D30）改由 `MirrorWindowController` 負責：只有 `window()` 會建立 `NSWindow`，
且只建立一次。`Settings` 場景沒有 ⌘N，不會產生第二個鏡像視窗。

改用 `windowController` 取得視窗的地方：`AppModel.wake()`、`applyBackgroundModeAfterStart`、
`AppDelegate.applicationWillTerminate` 的診斷輸出。`NSApp.keyWindow` 的用法（全螢幕切換、
`shouldCapture`）不需要改，因為鏡像視窗仍是唯一會成為 key 的一般視窗。

## 6. 第二階段的成員歸屬（本階段不搬動）

| 歸核心（不 import AppKit／SwiftUI） | 歸 GUI |
| --- | --- |
| `client`、`box`、`activeSink`、`connState`、`currentEndpoint` | `menuBar`、`lifecycle`、`windowController` |
| `inputQueue`、`textInput` 的提交流程 | `mouseCapture`、`isFullScreen`、`frameSize`、焦點追蹤 |
| `remote` 與遙控啟停、token | `remoteMenuState`、QR 與選單呈現 |
| `audioRing`、音訊扇出、供應監測 | `audioPlayer`（CoreAudio 播放）、靜音 |
| 語音辨識、段落切分 | `speechText` 字幕 |
| 多開切換、遊戲偵測、profile 載入 | keymap 編輯器、`editorSession`、存檔提示 |
| APK 安裝 | `installState` 橫幅、剪貼簿與 `NSPasteboard` |

核心以狀態值提供給 GUI 讀取，不直接呼叫 `menuBar`。

## 7. 驗證

單元測試（先寫）：

- `MirrorWindowController.window()` 呼叫兩次回傳同一個物件，第一次呼叫前沒有建立任何視窗。
- 建立的視窗有 `.fullScreenPrimary`、autosave 名稱為 `mirage-mirror`、`isReleasedWhenClosed` 為 false。
- `attach(delegate:)` 在視窗建立前後呼叫都會讓最終的 `window.delegate` 是傳入的物件。

實機驗證，以 20 ms 取樣工具量測，修改前後各兩次：

| 情境 | 通過條件 |
| --- | --- |
| 背景模式啟動 | 12 秒內 `onscreenWindows` 每一筆都是 0，`policy=accessory` |
| 一般模式啟動 | 視窗出現後持續顯示，`policy=regular` |
| 背景模式點「顯示視窗」 | `policy=regular`、frontmost、1 個視窗 |
| 接著按紅色按鈕 | `policy=accessory`、0 個視窗 |
| 接著手機端腳本連線 | 收到 keyframe、`SEQ_GAPS=0`、`emulatorConnected=true` |
| 背景模式且 8765 埠被佔用 | 視窗出現、`policy=regular` |
| 一般模式按 ⌘E | 進入編輯模式 |
| 一般模式以 CGEvent 送按鍵 | guest 收到字元（用 `lib/cgkey.js`，不用 System Events） |
| 全螢幕 | `gui_session.sh` 設定 AXFullScreen 後讀回 true |

另外跑 `verify_remote_mirror.sh` 與 `ci.sh`。

## 8. 風險

- `NSHostingView` 與 SwiftUI `Window` 的鍵盤事件傳遞可能不同：`MirrorMTKView` 要成為
  first responder，⌘E 的隱藏按鈕要能觸發。第 7 節的 ⌘E 與 CGEvent 按鍵兩項要實機驗證，不能只靠單元測試。
- SwiftUI App 只剩 `Settings` 場景時，主選單項目可能與現在不同（視窗選單、全螢幕項目）。
  實作後比對修改前後 `NSApp.mainMenu` 的項目標題。
- 視窗位置：舊的 SwiftUI 視窗與新的 AppKit 視窗使用同一個 autosave 名稱，但儲存格式若不相容，
  第一次啟動會回到預設位置。這只影響一次，不需要處理。
