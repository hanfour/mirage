# P1-c 鍵位映射 驗收結果

- **日期**：2026-07-24
- **模擬器**：Android emulator canary **37.2.1**（`@mirage-poc`，headless，原生 **1080×2400**）
- **工具鏈**：Swift 6（語言模式 v5）、grpc-swift 1.27.5、swift-testing
- **執行**：subagent-driven（Task 1–7 implementer + task-review 逐關）＋ controller 親做 Task 8 驗收

## 驗收線逐條裁決（spec §7）

| # | 驗收線 | 實測 | 判定 |
|---|---|---|---|
| 1 | Keymap 單元全綠、覆蓋 ≥80%、release 零警告 | **76/76 綠**；Keymap 引擎覆蓋見下（核心 100%）；`swift build -c release` **0 非-deprecation 警告** | ✅ PASS |
| 2 | 引擎多指：按住 W + 點技能 → TouchFrame 含 id1+id2 兩觸點、座標正確、不衝突（單元） | `simultaneousJoystickAndTapAreTwoStableTouches` 通過——active 觸點 {1,2}，count==2，identifier 不衝突 | ✅ PASS |
| 3 | 活體煙霧：注入「移動+技能」→ show_touches 見兩同時觸點（擷圖） | `MultiTouchLiveTests.injectsTwoSimultaneousTouches` 通過（3.16s，真模擬器）；擷圖 `/tmp/mirage_multitouch.png` show_touches overlay 顯示 **P: 0 / 2**（2 pointers）、**Prs: 1.0**、觸控軌跡 | ✅ PASS |
| 4 | 無 profile 時 MirrorView 仍可直接 mouse→tap（P1-a 不回歸） | `sendMouse` guard `controller?.hasProfile != true` → 送 tap；下游 `renderer?.lastFrameSize ?? guestSize` 映射未改（Task 7 review 逐行確認 P1-a/P1-b 未動）；GUI 體感 pending-human | ✅ 結構 PASS／體感 pending-human |
| 5 | pending-human（解鎖後）：overlay 拖放存檔、look 手感、真遊戲跟手度 | pending-human（GUI，無顯示器） | ⬜ pending-human |

## 覆蓋率（`swift test --enable-code-coverage`，MirageCore/Keymap，逐行）

| 檔 | Line 覆蓋 |
|---|---|
| **KeymapEngine.swift**（核心，spec §7 驗收 2） | **100%**（74 行 0 missed） |
| JoystickMath.swift | 100% |
| NormPoint.swift | 100% |
| KeymapProfile.swift | 100%（region 92.86%） |
| ProfileStore.swift | 79.31%（App-default `standard()` 路徑未測——測試用注入目錄） |
| KeyCode.swift | 純 enum 宣告（無可執行行） |

**說明**：與 P1-b 不同，P1-c 的新增碼是**純引擎**，可完整單元測試——核心 `KeymapEngine` 逐行 **100%**、其餘引擎檔 ~93–100%。唯一略低的 `ProfileStore` 缺口是 App 預設路徑 `standard()`（測試以注入的暫存目錄取代，避免碰使用者家目錄）。新增 Keymap 碼整體 ≈95%+，達標 ≥80%。（`EmulatorClient` 65% region / 84.78% line 為既有 P1-a/P1-b 碼含 gRPC 邊界，非本件範圍。）

## 引擎關鍵發現（Task 4 偏離——已修正並經 opus 終審確認）

計畫的 look 狀態逐字碼有真 bug（單一 `lookActive` flag 於按 joystick 鍵時也被設 true → 幽靈第三觸點污染多指集合、且 mouseMove-only 時 gate 永不開），2/6 測試對逐字碼失敗。implementer 拆成 `lookDown`（僅實際移動且 gate 開時設）+ on-demand `isLookGateOpen` + `releaseLookIfGateClosed` 修正，在資料結構層消除特殊情況；public API 與 identifier 分配不變。opus reviewer 獨立重現兩 bug 並確認修法為正解。補審加 `gatedLookLiftsTouchWhenActivationKeyReleased` 測試釘住 activation-gated 釋放行為。

## 已知限制／移交

- **座標落點精度 pending-human**：Task 7 終審發現 `KeymapController` 原用請求 stream size（非解碼後 `renderer.lastFrameSize`）——鏡像 P1-a CRITICAL 同類 bug；已修（commit c5f9050，`frameSizeProvider` 對齊 `sendMouse`）。模擬器原生 1080×2400 vs 請求 540×1200 確實分歧，故此修正必要；但**真實觸點落點精度**需 GUI/解鎖後人工驗（pending-human）。
- **GUI 體感 pending-human**：overlay 拖放存檔、look 靈敏度手感、⌘E 編輯即時行為、真 WASD→touch 跟手度、編輯模式點擊 hit-testing。
- `MouseCapture` 無視窗失焦（resignKey）自動釋放——alt-tab 離開時游標維持捕捉（已文件化，待補生命週期 hook）。
- `gameId` 目前硬編碼 `com.example.game`（MVP 佔位；P1-d 遊戲偵測時接真值）。

## 判定

- **P1-c GO**：鍵位映射引擎達標——tap/joystick/look 多指快照（核心 100% 覆蓋、id1+id2 不衝突多指經單元 + 活體雙證）、每遊戲 Codable profile + 原子 store、無 profile 退回 P1-a 直接 tap（不回歸）。單元 76/76、release 零警告、活體多指注入通過（show_touches P:0/2 佐證）。
- **移交 P1-d/後續**：座標落點精度活體人工驗；overlay 編輯器拖放/look 手感 pending-human；`MouseCapture` 失焦釋放；`gameId` 遊戲偵測接線。

## 觀察與備註

- identifier 靜態分配（joystick=1／taps=2,3…／look=最後）保證多指決定論——headline 測試證兩觸點 {1,2} 穩定不衝突。
- look 靈敏度 `/1000` 除數為 brief 繼承的佔位縮放，待真實 trackpad/滑鼠 delta 校準。
- 活體注入以請求 540×1200 送，模擬器（原生 1080×2400）縮放後觸點可見（show_touches P:0/2）——證多指 RPC 路徑活體可用。
