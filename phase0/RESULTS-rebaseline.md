# 乾淨主機重測基線（2026-07-23）——污染事件與翻案紀錄

## 事件

2026-07-23 發現主機存在 **16 個孤兒 zsh 行程**（前次 Claude Code session 殘留、ppid=1、
已連續空轉 5 天 9 小時、各吃 ~40% CPU、合計 ~6.4 核），為 Phase 0 / 0b 全程
host load 32–134 異常的主因。清除後 load 回落至 ~10–18（殘餘大戶為使用者的
ccusage statusline，~146%）。

**受影響**：Phase 0 / 0b 的所有量化數字（fps、延遲）。
**不受影響**：行為性/確定性結論——MMAP 於穩定版 36.6.11.0 崩潰（3/3）、canary
37.2.1.0 寫入端 no-op（lsof 證明）、串流 change-driven 特性、注入 RTT（~1ms，
本就未受影響）。上游 bug 報告（docs/upstream/）維持有效。

## 乾淨主機重測（headless、canary 37.2.1.0、animate.py 動畫源、load 10–18）

| 量測項 | 污染期數字 | 乾淨重測 | 60fps/80ms 閘門 |
|---|---|---|---|
| gRPC RGBA native 1080×2400 | 29–30fps | **55.3fps**（p50 17.3ms, p95 25.9ms, 546MiB/s） | ❌（差 ~5fps） |
| gRPC RGBA 540×1200 | ~42fps 平台 | **57.2fps**（p50 16.8ms） | ❌（邊緣） |
| gRPC RGBA 720×1600 | ~42fps 平台 | **57.4fps**（p50 16.7ms） | ❌（邊緣） |
| e2e p50（+17ms） | 68–74ms | **57.7ms**（40.7+17） | ✅（<80；理想 <50 未達） |
| e2e p95（+17ms） | 82–83ms ❌ | **71.3ms**（54.3+17） | ✅（首次進界） |
| screenrecord H.264 720×1600 | 0.6fps | **52.4fps**（629 幀/12s, 11.5MB） | ❌（邊緣） |
| Swift Release fps native | ~29fps | **24.8fps avg（12–32）** | ❌（客戶端瓶頸，見下） |
| Swift Release fps 540×1200 | — | **46.6fps avg（典型 48–54）** | 邊緣（未優化 POC） |

註記：
- e2e 重測 misses=14/50 偏高（污染期 8/2），成因未查（快幀率下基線動態改變？），
  依既有方法論註記，p95 可能低估——判讀保守。
- 55–57fps 的殘餘缺口疑似仍受剩餘負載（statusline ~146%）與 guest 60Hz vsync
  對齊影響；真正 idle 主機可能貼到 60。「差 5fps」與「差 30fps」是本質不同的工程問題。
- 環境：emulator 為 canary 37.2.1.0（Phase 0 原基線為穩定版 36.6.11.0），版本
  與負載雙重變因，嚴格歸因需穩定版重測——但「gRPC 路線量級可用」的結論不依賴此。

## 對既有判定的影響

1. **Phase 0 的 NO-GO（顯示路徑）**：量化基礎已翻——乾淨主機上 gRPC 距 60fps
   閘門僅差 3–5fps，且 e2e p95 進界。「架構性不可行」降級為「邊緣差距，需優化
   或小幅放寬」。
2. **0b 的「編碼軌不可用」**：翻案——52.4fps，同為邊緣差距。
3. **0b 的 MMAP 結論**：維持（行為性）。
4. **RESULTS-0b 的四選項決策menu**：前提（「兩備援皆死、gRPC 30fps」）已失效，
   決策需以本檔數字重開。
5. 使用者 2026-07-22 的體感「有點卡」同樣量於污染期，需乾淨主機重驗。

## 方法論教訓（追加）

**量測前必查 host load 的紀律有效抓到了異常（各報告皆有記錄），但當時把 32–77
的 load 當成「使用者環境常態」接受了——錯。負載異常持續存在時，應先追查負載
來源再量測，而不是帶著註記硬量。** 5 天前的殭屍行程一直在，Phase 0 開工前查一次
`ps aux | sort -rk3` 就能省掉兩個 phase 的誤判。

## Swift 客戶端瓶頸解析（2026-07-23 補測，load 6–17）

同一乾淨主機、同一條 gRPC 流：Python 收幀 55fps（只計數）、Swift POC 25fps（native）。
污染期兩者同被壓到 ~29，掩蓋了客戶端差異，Phase 0 誤把 POC 的客戶端成本歸給伺服器。
POC 目前每幀在主執行緒做兩次 10MB 拷貝 + 貼圖上傳（gRPC Data → Frame.rgba → texture.replace，
且收幀 Task 繼承 MainActor）；縮放至 540p（2.5MB/幀）即回到 46.6fps 均值。

**優化 backlog（Phase 1 顯示管線，全屬常規工程）**：收幀移出主執行緒、單次拷貝
staging（MTLBuffer）、掉幀策略（drop-late）、視窗尺寸串流（產品常態）、全螢幕才拉原生。

**客觀體感代理結論**：傳輸容量 55–57fps（≈guest 60Hz vsync 極限）、e2e p50+17=57.7ms/
p95+17=71.3ms 全進 80ms 界內——2026-07-22 的「有點卡」主因為主機污染 + POC 未優化，
gRPC 顯示路徑架構成立（選項 A）。

## unary-MMAP 路徑發現（2026-07-23 補測，canary 37.2.1.0）

原始碼追蹤（AOSP emu-master-dev）+ 隔離實驗：
- **unary `getScreenshot` + MMAP 在 macOS 上是好的**：payload=0、伺服器回 MMAP 通道、
  客戶端檔案收到真像素。串流版才是壞的（borrow 後逐幀寫入路徑缺失）。
- 輪詢吞吐實測：**52.5 次/s（serial）、p50 15.3ms、p95 35.8ms**、內容新鮮度 48/52
  distinct（animate 動畫源；量測時 load 15-32）。
- 意涵：**第三條不 fork 的顯示路徑**——unary-MMAP 輪詢=零拷貝資料面+今天可用。
  限制：僅 canary（穩定版 36.6.11.0 對任何 MMAP 請求都會崩潰）；輪詢非變化驅動
  （閒置畫面仍耗擷取成本，可用自適應頻率緩解）。
- 上游草稿已依此強化（stream-vs-unary 隔離 + 原始碼分析 + 修法建議）並修正 lsof
  過強表述。修復定位：`streamScreenshot` 逐幀寫入需比照 unary 的
  `isOpen()/isMapped()` 守衛與 shm 寫入；`SharedMemoryLibrary::borrow` 錯誤處理
  為 assert-only（release build 靜默）。

**顯示路徑總結（全部實測於乾淨主機）**：
| 路徑 | 數字 | 特性 |
|---|---|---|
| gRPC stream RGBA（主選） | 55-57fps | 變化驅動、每幀 10MiB 序列化 |
| unary-MMAP 輪詢（canary 限定） | ~52/s, p50 15.3ms | 零拷貝、需輪詢 |
| 編碼 H.264 | 52.4fps | 頻寬最省、有編解碼延遲 |
