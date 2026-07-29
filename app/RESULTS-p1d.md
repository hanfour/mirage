# P1-d 遊戲偵測與 keymap 啟用 驗收結果

- **日期**：2026-07-25
- **模擬器**：Android emulator canary **37.2.1**（`@mirage-poc`，headless，原生 1080×2400）
- **工具鏈**：Swift 6（語言模式 v5）、grpc-swift 1.27.5、swift-testing
- **執行**：subagent-driven（Task 1–7 implementer + task-review 逐關）＋ controller 親做 Task 8 驗收

## 驗收線逐條裁決（spec §7）

| # | 驗收線 | 實測 | 判定 |
|---|---|---|---|
| 1 | ForegroundParser+ActivationDecider 單元全綠、覆蓋 ≥80%、release 零警告、既有不回歸 | **92/92 綠**；P1-d 純 Core 覆蓋見下（皆 100% line）；`swift build -c release` **0 非-deprecation 警告**；79→92 無回歸 | ✅ PASS |
| 2 | 活體：前景切換→GameDetector 回報正確 package、啟用正確 active/deactivate | 偵測機制 live：`adb dumpsys activity activities` → `topResumedActivity=…com.android.launcher3/…` → `ForegroundParser` 解析 `com.android.launcher3`（已測格式）；`ActivationDecider` 4 單元；launcher 前景→無對應 profile→deactivate→退 P1-a tap（正確）。GameDetector→AppModel→activation 全鏈為 App 層，結構驗 + GUI pending-human | ✅ 機制+邏輯 PASS／full-app pending-human |
| 3 | harness：合成 InputEvent→sendTouches→show_touches 見觸點 | `KeymapInjectLiveTests.engineDrivenMultiTouchInjects` 通過（3.27s，引擎→sendTouches→真模擬器）；擷圖 `/tmp/mirage_keymap_inject.png` show_touches：**P: 1/2**（2 pointers）、**X:135 Y:696**（＝joystick-up 數學正確：0.25×540、(0.7−0.12)×1200）、**Prs:1.0** | ✅ PASS |
| 4 | MouseCapture：非 key window 不捕捉、resignKey 還原 | `updateCapture(shouldCapture:)` gating（`hasProfile && !editing && keyWindow!=nil`）+ `didResignKeyNotification`→release（結構）；游標行為 GUI pending-human | ✅ 結構 PASS／pending-human |
| 5 | 無 profile / adb 失敗 → 退 P1-a tap（不回歸不崩） | `ActivationDecider` `.auto`+nil→inactive 單元；`AdbClient.standard()` nil→靜默不偵測；`AdbOutcome` exitCode≠0→nil（降級）單元；launcher 前景→退 tap（活體印證） | ✅ PASS |
| 6 | pending-human：真 GUI NSEvent 抽取、KeymapController GUI、真遊戲手感 | GUI（無顯示器） | ⬜ pending-human |

## 覆蓋率（`swift test --enable-code-coverage`，P1-d 新增 MirageCore/Keymap，逐行）

| 檔 | Line 覆蓋 |
|---|---|
| ForegroundParser.swift | 100%（region 94.44%，1 region） |
| ActivationDecider.swift | 100% |
| AdbOutcome.swift | 100% |

P1-d 的可測邏輯（dumpsys 解析、啟用決策、adb 降級）皆 MirageCore 純型別、逐行 100%——**不新建 App 測試 target**（GameDetector/AdbClient/選單列/MouseCapture 為薄膠水，正確性靠上述 Core 決策覆蓋 + 活體 + pending-human）。

## 座標正確性佐證（§7 #3 附帶）

活體注入以請求 540×1200 送，模擬器原生 1080×2400。show_touches 顯示 joystick-up 觸點落在 **X:135 Y:696**，正是 `center(0.25,0.7)` 向上位移 `radius 0.12` 的 guest 像素（0.25×540=135、(0.7−0.12)×1200=696）——證引擎→`guestPixel`→`sendTouches` 座標鏈正確（呼應 P1-c 的 `renderer.lastFrameSize` coord-fix）。

## 已知限制／移交

- **完整 app-path pending-human**：`KeymapController`（在不可 import 的 executable target）與 `MirrorMTKView` 的 `NSEvent→KeyCode` 抽取需真 GUI session——harness 只驗到 Core 引擎→注入鏈（§4.7 誠實切分）。若要 headless 驗 `KeymapController`，須先把它抽成 library target（後續選項）。
- **`AppModel.profile` 與偵測驅動啟用不同步**（Task 7 發現）：Task 5 `applyActivation()` 只 `keymap?.reload(p)`，未回寫 `AppModel.profile`——故 overlay 編輯器（⌘E 用 `profile`）與 look-only gating 讀到的是 P1-c 啟動期的值，非偵測後的 active profile。App 層 coherence 缺口，建議 P1-d fast-follow 或 overlay 上線前修（讓 activation 回寫 `profile`）。

  > **✅ 已修（更正於 2026-07-29）**：`AppModel.swift:201` 的
  > `case .active(let p): keymap?.reload(p); profile = p` 就是那個回寫。本條已解決，
  > 留著會讓下一個人去修一個已經好了的東西。（另：原文寫「pending-human 領域」——
  > 這是**缺陷**不是待驗項，用詞本身就是 §0 記載的那個誤用。）
- **MouseCapture 未做 look-only gating 與 didBecomeKey 自動重捕捉**（依 brief sanctioned fallback）——gating 已收緊到「有 profile+非編輯+key window」，消除主要游標陷阱；look-only 精修與 refocus 重捕捉列 follow-up。
- **`gameId == package` 假設**：內建 profile gameId 為 `com.example.game`（非真 package）；真遊戲 profile 內容與實玩手感留後續（Phase 1「3 款指標遊戲」）。
- **偵測輪詢**：1.5s adb 子行程 + 每次 disk load（1.5s 可忽略）；若 interval 縮或 store 變慢再評估。

## 判定

- **P1-d GO**：遊戲偵測機制（adb dumpsys→ForegroundParser）活體通過、啟用決策（ActivationDecider）100% 覆蓋、無 profile/adb 失敗退 P1-a tap（不回歸不崩）、引擎→多指注入活體通過、MouseCapture 焦點 gating 消游標陷阱。單元 92/92、release 零警告。

> **⚠️ 更正（2026-07-29）**：本條 GO 判定原本包含「**且座標數學正確**」。**那句話不成立，
> 而且它掩護了一個真實的 bug 達兩個階段。**
>
> 那條活體驗的是 harness **直接呼叫 `sendTouches` 並自行傳入尺寸**，沒有經過 App 層的
> 傳遞路徑。App 層（`KeymapController`）當時傳的是**串流幀尺寸**而非 guest 實體解析度，
> 兩者在本機差兩倍——所以 P1-c 起所有鍵位映射的觸點都落在目標的左上一半處。
> 「座標數學正確」講的是換算函式本身，不是實際落點；把它寫進 GO 判定，讀起來像後者。
>
> 已修：`sendTouches` 拿掉 `width:height:` 參數，改由 `EmulatorClient` 用健康探測回報的
> `guestDisplay` 換算，呼叫端沒有機會再傳錯。**但真實落點精度至今仍未經人眼驗證。**
- **移交 fast-follow/後續**：AppModel.profile 回寫（overlay 上線前）；完整 app-path 與真遊戲手感 pending-human（需 GUI session）；look-only gating 精修；真遊戲 profile 內容（Phase 1 三款遊戲）。

## 觀察與備註

- emulator gRPC 無前景-app RPC（僅 getDisplayConfigurations/getDisplayMode/getStatus）——偵測走 adb 是唯一自動路徑，已探明。
- launcher（`com.android.launcher3`）為前景時無對應 profile→自動退 P1-a tap，符「無 profile 不回歸」語意。
