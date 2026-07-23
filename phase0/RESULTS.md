# Phase 0 實測結果（日期：2026-07-22）

環境：MacBook Air (M1, 16GB RAM, 無風扇) / macOS 26.3.1 / emulator 36.6.11.0 / 映像 android-35 default arm64

| 量測項 | 預算（spec §4.2/§7） | 實測 | 判定 |
|---|---|---|---|
| 串流 fps（RGBA 原生，Swift 原生客戶端 Release build） | ≥ 60fps 穩定 | native 1080×2400 ≈ 29fps avg（20–34fps 區間） | ❌ |
| 串流 fps（RGBA 原生，Python 客戶端，持續內容變化下） | （對照用） | native 30.6fps (p50 28.4ms) / 720p 42.7fps / 540p 42.0fps（~42fps 平台，降解析度無法突破） | ❌ |
| 串流每幀大小/吞吐 | （紀錄用） | native RGBA 9.888 MiB/幀；PNG 格式僅 1fps，不可用 | — |
| sendTouch 注入 RTT p50 / p95 | < 3ms | p50=1.04ms, p95=2.37ms (n=200) | ✅ |
| E2E input-to-photon p50（+17ms 上屏） | < 50ms 目標 / < 80ms 上限 | run1: 51.1+17=68.1ms；run2: 56.8+17=73.8ms | ✅（<80ms）／❌（<50ms 理想未達） |
| E2E p95（+17ms） | < 80ms | run1: 65.2+17=82.2ms；run2: 65.7+17=82.7ms | ❌（邊緣超標約 3ms） |
| Swift 視窗體感（定性） | 「跟手」 | 人工驗收（2026-07-22）：「有點卡」——與量測一致（~29fps + e2e p50 68-74ms 的預期體感）；點擊/拖曳功能正常。座標映射先前經 code review 靜態追蹤分析驗證〔task-9 review〕 | ❌（確認 NO-GO 判定） |

## 判定

- [ ] **GO**：延遲 < 80ms 且 60fps 穩定 → 進 Phase 1
- [x] **NO-GO**：不達標 → 啟動備援 (a) WebRTC（參考官方 container scripts）；
      (a) 再不達標 → (b) fork + 共享記憶體；備援驗證限時 2 週（spec §7）

**NO-GO for gRPC raw-frame streaming as the display path**（幀率 29–42fps 遠低於 60fps 門檻；e2e p95 邊緣超標）→ 依計畫啟動備援 (a) WebRTC 通道驗證（官方 android-emulator-container-scripts 有現成實作可參考），限時 2 週；若再不達標 → 備援 (b) fork + 共享記憶體。

> **後續（2026-07-22）**：備援驗證已完成——兩條備援路線皆不達標，詳見 `RESULTS-0b.md`。
>
> **重大更正（2026-07-23）**：本檔全部 fps/延遲數字量測於受污染主機（詳見 `RESULTS-rebaseline.md`）——乾淨重測 gRPC native 55.3fps、e2e p95 進界，NO-GO 的量化基礎已翻案。

**重要澄清**：實測過的控制面（headless 啟動、gRPC 輸入注入 1.04ms、串流控制介面）驗證成功且表現優異——判 NO-GO 的只有「顯示傳輸」這一段；備援只需替換畫面通道，其餘架構不變。剪貼簿、生命週期（快照休眠/喚醒）、sendKey（spec §7 列出 sendTouch/sendKey，本次僅實測 sendTouch）在 Phase 0 未實測，列為 Phase 1 前置驗證項。

### 各分項細判

- **串流 fps**：無論 Python 或 Swift 原生客戶端，在「持續內容變化」的真實條件下，native 解析度皆卡在 ~29–31fps，降解析度最高也只到 ~42fps 平台（720p/540p），未達 60fps 門檻。此為終局瓶頸，直接觸發 NO-GO。
- **sendTouch RTT**：p50=1.04ms／p95=2.37ms，均低於 <3ms 預算（餘裕 65%/21%）。控制面注入路徑驗證優異。
- **E2E input-to-photon**：p50+17ms 兩次量測（68.1ms／73.8ms）皆落在 <80ms 的 Go 區間內，但都未達 <50ms 理想目標；p95+17ms 兩次量測（82.2ms／82.7ms）皆**超出** 80ms 上限（超標約 2.2–2.7ms，邊緣性超標，非災難性）。p50 過關但 p95 未過關，且兩者皆與「串流 fps 過低」同源——低幀率下等待下一幀所需的時間直接推高 p95。

## 觀察與備註

### Debug vs. Release build 教訓
Swift POC 的預設 `swift run`（Debug build）在原生解析度下僅 ~1–2fps，比 Release build（~29fps avg）低 15–20 倍。這是 Debug 建置模式下 ARC / 邊界檢查 / `MTLTexture.replace` 上傳路徑未優化造成的假象，不是架構瓶頸（Debug client CPU ~104% 單核打滿；Release client CPU 僅 ~15% 卻產出更多幀）。**任何效能判讀都必須以 Release build（`swift run -c release` 或 `swift build -c release`）為準**，本文件的 Swift fps 數字（~29fps avg）即取自 Release build。README 的執行指南已相應標註。

### Change-driven stream 特性
`streamScreenshot` 是變化驅動（change-driven）的：靜止畫面完全不出幀（Task 6 量測到，閒置畫面 2 秒僅收到連線瞬間的 1 幀，其後無新幀）。這意味著任何 fps/延遲量測都**必須搭配持續的動畫來源**（例如 ~120Hz 連續 `sendTouch` 拖曳）才能量到管線真實吞吐；用單次或間歇性的 `adb shell input swipe`（指令間有數百毫秒內容死區）量到的是「畫面變化率」而非「管線吞吐」，會嚴重低估 fps。

### 兩次 scaled diagnostic 方法論差異
Task 4 對降解析度做了兩次獨立診斷，數字差異很大（v2: native 30.6 / 720p 42.7 / 540p 42.0fps；v1 修正版: 23.5 / 0.8 / 13.6 / 12.0fps），原因不是矛盾而是動畫來源品質不同：
- v2 用 gRPC `sendTouch` ~120Hz 連續注入圓形拖曳，保證每次 move 都觸發重繪 → 量到的是持續變化下的真實管線吞吐，**判讀管線能力以此為準**。
- v1 修正版用 `adb shell input swipe` 迴圈，指令啟動本身有數百毫秒空窗 → 量到的是「內容變化率」下界，非管線能力；其中 720p 的 0.8fps 更是單次多秒 stall 造成的量測假象（緊接在高吞吐原生解析度串流被拆除後的過渡期爭用）。
- 兩者共同確認：`ImageFormat` 的 `width`/`height` 縮放請求被精確執行（觀察到的 byte 數與 `w*h*4` 完全吻合，零誤差），排除了「縮放沒生效」的可能。
- **方法論教訓**：任何未來的 fps/吞吐量測，動畫來源必須是高頻連續注入（而非間歇性 shell 指令），否則量到的是內容變化率而非管線能力，會嚴重誤導判讀。

### misses 未計入百分位可能低估 p95（方法論註記）
Task 6 的 e2e 量測中，`misses`（超時未偵測到畫面變化的樣本，run1: 8/50、run2: 2/50）被排除於 p50/p95 百分位計算之外（brief 原始設計）。這代表目前回報的 p95 只反映「有偵測到變化」的樣本分布，未把逾時樣本（理論上延遲更長甚至無限）計入——實際的完整分布 p95 很可能比回報值更高。已知的 p95 邊緣超標（+2.2~2.7ms）若計入 misses，超標幅度可能更大，這點在對備援方案的緊迫性判讀上應保守看待。

### 穩定性事件
原生解析度 RGBA 長時間串流曾致 guest `system_server` 崩潰重啟（~54 秒中斷），在 Task 4 降解析度診斷期間觀察到（透過 `adb shell service list` 缺少 `window`/`input` 服務、`system_server` elapsed time 僅 54s 確認）。約 50 秒後系統自行恢復。傾向產品端應避免長時間原生解析度串流，或至少需要偵測與復原機制。

### 硬體脈絡
本機為 Apple Silicon 地板機型（M1 無風扇），較新晶片（M3/M4）數字預期會更好，但目前差距（29fps → 60fps 門檻需要 2 倍提升）不太可能單靠換硬體弭平——這是架構/協議層的瓶頸（per-frame 序列化/擷取成本，非網路頻寬；qemu CPU 在各次量測中均未飽和），而非單純算力不足。

### CPU/頻寬佐證
**更正（原版本此處有誤）**：早期草稿曾寫「loopback 吞吐 43–80 MiB/s 遠高於 593 MiB/s」，這句話數學上不成立（43–80 < 593），且把「達成的傳輸量」誤標成「頻寬上限」——予以更正。43–80 MiB/s 的來源：Task 4 v1（`adb input swipe` 動畫源）低幀率兩次量測（8.1fps／4.4fps，皆為原生 9.888MiB/幀）換算出的**實際傳輸量**（8.1×9.888≈80MiB/s；4.4×9.888≈43MiB/s），不是管線頻寬能力的量測值——那兩次的幀率本身遠低於 60fps，換算出的吞吐自然也遠低於 60fps×9.888MiB/幀≈593MiB/s 的需求下限，兩者不可比、更談不上「遠高於」。

「非網路瓶頸」的結論改以下列兩點誠實佐證支撐：(a) 降解析度使單幀資料量縮小近 4 倍（1080×2400 的 9.888MiB → 540×1200 的 2.472MiB），若瓶頸是頻寬，fps 應隨資料量減少而大幅上升，但 v2（持續 sendTouch 動畫源）實測 fps 只從 native 30.6 微幅拉到 ~42 便撞頂（42fps 平台，見上節「兩次 scaled diagnostic 方法論差異」），漲幅與資料量縮減幅度不成比例；(b) qemu CPU 佔用在各解析度量測中均維持中等水準，未見到單一核心或全機飽和的證據。兩點合力指向瓶頸落在 per-frame 的擷取/序列化路徑本身，而非傳輸層頻寬或運算力總量——但此推論仍非窮盡排除，若 Phase 1 採用相近架構，建議進一步用專門的頻寬/CPU profiling 工具驗證。
