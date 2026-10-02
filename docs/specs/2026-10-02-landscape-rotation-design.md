# 橫向遊戲：鏡像畫面跟著 Android 顯示方向轉

2026-10-02

## 問題

Brotato 這類橫向遊戲啟動後，Android 把顯示方向切成橫向（`dumpsys` 的 `mRotation=1`，解析度 2400×1080），但 Mirage 的鏡像視窗仍是直向，畫面順時針轉了 90 度躺著。

成因：

- emulator 的 `streamScreenshot`／MMAP 送來的永遠是面板方向（直向 1080×2400）的影像。guest 轉向時，內容在直向影像裡轉 90 度畫。
- 影像 `format.rotation` 回報的是 emulator 虛擬裝置（skin）的方向，guest 轉向時仍是 `PORTRAIT`，不能拿來判斷。
- Mirage 直接畫出面板影像，所以內容躺著。

觸控目前在躺著的畫面上是對的（點躺著的畫面某處，遊戲裡就是那個位置），問題只在無法正常遊玩。

## 目標

guest 顯示方向不是 0 時，Mirage 的鏡像視窗、全螢幕、截圖、鍵位映射、手把、觸控板拖曳都以「轉正後」的方向呈現與操作，和直向遊戲的體驗一致。

不做：

- 不旋轉 emulator 虛擬裝置（`setPhysicalModel` 的 ROTATION）。
- 手機遙控畫面維持現狀（面板方向，橫向遊戲在手機上躺著，觸控仍正確）。見「手機遙控」一節。

## 座標約定

整個 Mirage 內所有正規化座標（`NormPoint`、`TouchSpec.point`、`sendTap(nx:ny:)`、鍵位 profile、編輯器、測試控制通道的 `mouse` 座標）一律是「轉正後的顯示座標」：左上 (0,0)、右下 (1,1)，即使用者在視窗上看到的方向。

換成面板座標只在一個地方做：`EmulatorClient.sendTap` 與 `EmulatorClient.sendTouches` 在呼叫 `guestPixel` 之前。

旋轉值沿用 Android `Surface.ROTATION_*`：0、1、2、3 分別是 0°、90°、180°、270°。轉正座標 (ux, uy) 換成面板座標 (px, py)：

| rotation | px | py |
| --- | --- | --- |
| 0 | ux | uy |
| 1 | 1 − uy | ux |
| 2 | 1 − ux | 1 − uy |
| 3 | uy | 1 − ux |

rotation 1 這列由 2026-10-02 Brotato 實機截圖對照得出：轉正畫面左上的血條在面板影像的右上、轉正右上的 Skip 鈕在面板影像的右下。rotation 3 與 2 依對稱推得，需要實機驗證（見驗收）。

guest 實體解析度 `guestDisplay` 維持面板方向（1080×2400），`guestPixel` 的換算不變。

現有鍵位 profile 都在直向遊戲上建立，rotation 0 時換算是恆等，不受影響。

## 偵測

`AdbClient.foregroundResult` 已經每 1.5 秒跑一次 `dumpsys activity activities`，輸出裡有顯示方向。從同一份輸出解析，不新增 adb 呼叫。

`mRotation=` 在實際輸出裡出現 22 次：21 次是各視窗設定裡的 `mRotation=ROTATION_90`、`mRotation=ROTATION_0`、`mRotation=undefined`（嵌在 `winConfig={…}` 中間），只有 1 次是顯示方向，位在 `DisplayRotation` 區段、整行以它開頭：

```
  DisplayRotation
    mCurrentAppOrientation=SCREEN_ORIENTATION_LANDSCAPE
    mLastOrientation=0
    mRotation=1 mDeferredRotationPauseCount=0
```

- 純函式放 `AdbOutcome`（MirageCore，可測）：`rotationOrNil(stdout:) -> Int?`。只認「去掉前導空白後以 `mRotation=` 開頭、緊接一位數字 0–3」的行；取第一個符合的行。其他情況（找不到、`ROTATION_90`、`undefined`、數字超出範圍）回 nil。直接找第一個 `mRotation=` 子字串會拿到 `ROTATION_90` 而回 nil，是錯的。
- `ForegroundResult.success` 帶出 rotation（nil 代表這輪沒讀到，沿用上次值，不當成 0）。
- `GameDetector` 新增 `onRotationChange: (Int) -> Void`，只在值改變時呼叫；與 package 的 `onChange` 分開，不改變 package 變更的既有行為與測試。
- 延遲：轉向後最多 1.5 秒（退避時 10 秒）才會跟上，這段期間畫面維持舊方向。可接受；遊戲通常只在啟動時轉一次。

AppModel 收到新 rotation 後：

1. 寫入 `EmulatorClient`（新的 `setDisplayRotation(_:)`），之後的觸控換算用新值。
2. 寫入 Renderer（繪製時的旋轉參數）。
3. 重新計算視窗長寬比、串流請求尺寸。
4. 清除進行中的觸控（送 up），避免手指在轉向前後落在不同位置。沿用既有的釋放路徑（失焦時釋放所有按鍵／觸點的那條）。

## 繪製

`MirrorShaders` 的 fragment 依 rotation 換算取樣座標：輸出像素的轉正 uv 用上表換成面板 uv 再取樣。rotation 以 `setFragmentBytes` 傳入（一個 `UInt32`），不新增 pipeline。

`MirrorContainerView` 的 letterbox 與 `applyWindowAspect` 改用「轉正後的幀尺寸」：rotation 為 1 或 3 時，寬高互換。新增一個純函式（MirageCore，可測）：`DisplayRotation.upright(size:rotation:)`。

## 視窗

rotation 從直向變橫向（或反過來）時，視窗內容區寬高互換，保持視窗頂邊中點不動，超出螢幕可見範圍時往內移。全螢幕中不調整視窗（沿用 `applyWindowAspect` 的既有判斷），只改 letterbox。

最小尺寸：直向寬 ≥ 270；橫向時改為高 ≥ 270（即短邊 ≥ 270）。

## 串流請求尺寸

視窗需求 `updateWindowStreamDemand(width:height:)` 收到的是轉正後的像素尺寸；rotation 為 1 或 3 時，送進 `StreamDemands` 前寬高互換成面板方向。`StreamSize.aspect` 的 frame 參數同樣用面板方向的幀尺寸，不需改。

## 截圖（⌘S）

存檔影像要轉正：rotation 不為 0 時，在寫檔前把影像依 rotation 轉回正向。

## 手機遙控

viewer 顯示的仍是面板影像，送來的觸控座標是面板座標。為了維持現狀（觸控正確），`RemoteMirrorController` 的 `onTouches` 在進 `InputQueue` 前，把面板座標換成轉正座標（上表的反函數），讓 `EmulatorClient` 換回面板時是恆等。反函數放 `DisplayRotation`，與正函數一起測「來回等於原值」。

手機上轉正顯示是另一項工作，不在本規格。

## 測試控制通道

`state` 增加 `rotation`（目前 Mirage 套用的值）。

## 單元測試

- `DisplayRotation`：四個 rotation 的換算表逐列驗證（含四個角）；正反函數來回等於原值；`upright(size:)` 在 1、3 互換。
- `AdbOutcome.rotationOrNil`：讀真實輸出全文 `Tests/MirageCoreTests/Fixtures/rotation/activities-brotato-rot1.txt`（Brotato 執行中，期望 1）與 `activities-home-rot0.txt`（桌面，期望 0），用 `#filePath` 定位，不要加進 Package.swift 的 resources；另加三個小字串：只有 `winConfig` 裡的 `mRotation=ROTATION_90`（期望 nil）、沒有任何 `mRotation`（nil）、`    mRotation=7 mDeferred…`（nil）。
- `GameDetector`：rotation 改變才呼叫 `onRotationChange`；rotation nil 不呼叫；package 未變但 rotation 改變仍呼叫。
- `EmulatorClient.buildTouchEvent` 或新的純換算：rotation 1 時轉正 (0,0) 送出的像素是面板 (1079, 0) 附近（依 `guestPixel` 既有的四捨五入／夾住規則）。

## 驗收

自動（新腳本 `scripts/verify_rotation.sh`，用測試控制通道，不搶游標）：

1. 開 Brotato（`am start` 其 launcher activity），等 `state.rotation == 1`（最多 10 秒）。
2. 視窗內容區寬 > 高。
3. 用 `mirage_ctl.py mouse` 點轉正座標的四個點（0.1,0.1）、（0.9,0.1）、（0.1,0.9）、（0.9,0.9），`getevent -lt /dev/input/event1` 讀到的 `ABS_MT_POSITION_X/Y` 依上表落在對應的面板像素 ±3%。
4. 截圖（⌘S 走測試通道）存出的 PNG 寬 > 高。
5. `wm user-rotation lock 3` 強制 rotation 3（若 Brotato 允許），重做第 3 步；若 guest 不肯轉到 3，記錄為未驗並說明。結束後 `wm user-rotation free`。
6. 回桌面或開 Pixel Flow（直向），等 `state.rotation == 0`，視窗變回直向，再點一次四角驗證恆等。

兩輪全過才算通過。ci.sh 全綠。

人工：使用者在 Brotato 實際玩一局，確認畫面方向、觸控、拖曳搖桿正常。

## 影響範圍

| 項目 | rotation 0（所有現有直向遊戲） | rotation 1／3 |
| --- | --- | --- |
| 觸控換算 | 恆等，行為不變 | 轉正後換算 |
| 鍵位 profile | 不變 | 在轉正畫面上編輯與套用 |
| 手機遙控 | 不變 | 維持躺著（現狀） |
| 視窗預設尺寸、autosave | 不變 | 寬高互換 |
