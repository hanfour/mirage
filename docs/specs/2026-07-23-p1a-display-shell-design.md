# P1-a 顯示管線與產品骨架 — 設計文件

- **日期**：2026-07-23
- **狀態**：已核准（brainstorming 流程）
- **上游文件**：`2026-07-22-mirage-project-plan.md` §7 Phase 1；數據依據 `phase0/RESULTS-rebaseline.md`
- **Phase 1 拆解全景**（已核准）：**P1-a 顯示管線與骨架（本件）** → P1-b 生命週期與系統整合 ∥ P1-c 鍵位映射引擎 → P1-d 指標遊戲驗收。各子專案獨立走 spec→plan→執行。

## 1. 目標

把 POC 升級為產品級顯示管線與 App 骨架：**540p 視窗穩定 60fps、斷線自動重連、
模組化可測試**。這是 Phase 1 其餘三塊的基座。

**非目標（YAGNI，明確不做）**：鍵位映射（P1-c）、快照/生命週期管理與剪貼簿/APK/
音訊（P1-b）、遊戲庫 UI（P2）、多開（P2）、120fps（P3）。

## 2. 背景約束（來自實測）

- 傳輸主選 gRPC 縮放串流：乾淨主機 540p 57fps、native 55fps（≈guest 60Hz vsync 極限）。
- POC 的 25fps 瓶頸在客戶端：收幀 Task 繼承 MainActor + 每幀兩次 10MB 拷貝。
- unary-MMAP（canary 限定）實測 52.5 次/s 零拷貝可用；穩定版 emulator 碰 MMAP 即崩——
  **任何 MMAP 程式碼路徑必須先檢查 emulator 版本**。
- 斷線＝實際踩過的產品級需求（模擬器重啟後 POC 凍結）。

## 3. 專案結構

```
app/                          # 新頂層 SwiftPM package（日後包 .app bundle）
├── Package.swift             # 依賴：grpc-swift 1.x（沿用 1.27.5 釘版）、swift-collections?（僅必要時）
├── Sources/
│   ├── MirageCore/           # 無 UI 依賴、全單元可測
│   │   ├── Transport/
│   │   │   ├── DisplayTransport.swift      # protocol
│   │   │   ├── GrpcStreamTransport.swift   # 主選實作
│   │   │   └── UnaryMmapTransport.swift    # 實驗旗標（canary 檢查前置）
│   │   ├── EmulatorClient.swift            # 連線/重連狀態機、輸入注入、健康檢查
│   │   ├── FramePump.swift                 # actor：最新幀信箱
│   │   └── Generated/                      # proto stubs（自 POC 遷移）
│   └── MirageApp/            # SwiftUI 殼
│       ├── MirageApp.swift                 # @main、App scene
│       ├── MirrorView.swift                # NSViewRepresentable 包 MTKView
│       ├── Renderer.swift                  # vsync 拉取 + MTLBuffer staging + blit
│       └── ConnectionBanner.swift          # 連線狀態 UI
└── Tests/MirageCoreTests/    # 重連狀態機、FramePump 語意、尺寸換算、mock transport
phase0/                       # 原封保留（量測 harness 與歷史紀錄）
```

檔案紀律：每檔 <400 行；MirageCore 不 import AppKit/SwiftUI/Metal。

## 4. 核心設計

### 4.1 FramePump（actor 信箱 + vsync 拉取）

```
DisplayTransport ──(背景 task 消費)──> FramePump(actor)
                                        └── mailbox: Frame?（單格，新幀覆蓋舊幀）
MTKView draw(每 vsync) ──takeLatest()──> 上傳 MTLBuffer → blit → present
```

- **drop-late 天生免費**：信箱只有一格，消費不及的幀自然被覆蓋，永遠畫最新。
- 拷貝鏈收斂為一次：transport 產出的 `Frame.rgba`（Data）→ `MTLBuffer` staging
  （`replaceRegion` 或 `makeBuffer(bytesNoCopy:)` 視對齊）→ blit 到 drawable。
- 收幀完全脫離 MainActor；渲染側只做拉取與上傳。

### 4.2 DisplayTransport protocol

```swift
protocol DisplayTransport: Sendable {
    func frames(width: Int, height: Int) -> AsyncThrowingStream<Frame, Error>
}
```

- `GrpcStreamTransport`：streamScreenshot 縮放請求（視窗實際 pixel 尺寸）。
- `UnaryMmapTransport`：`MIRAGE_TRANSPORT=unary-mmap` 旗標啟用；啟用前查
  `getStatus` 版本 ≥37.x，否則拒絕啟用並記 log（穩定版防崩鐵則）。
- 視窗 resize：debounce 300ms 後以新尺寸重開串流（透過 FramePump 換 source）。
- 全螢幕：切原生解析度。

### 4.3 EmulatorClient 連線狀態機

```
disconnected ──connect()──> connecting ──ok──> connected
     ^                          │fail                │stream斷/health fail
     └────────── backoff(0.5s→8s cap, jitter) ── reconnecting
```

- 健康檢查：串流中斷時以 getStatus 探測；模擬器行程消失→持續退避重試。
- 重連成功自動重掛串流與輸入通道；UI 收到狀態變化（AsyncStream<ConnectionState>）。
- 輸入注入（sendTouch/座標換算）自 POC 遷移，介面不變。

## 5. 錯誤處理

- Transport 層：gRPC 錯誤分類（UNAVAILABLE→重連；INVALID_ARGUMENT→fail fast 記 log）。
- FramePump：尺寸不符幀直接丟棄並計數（暴露 metrics counter，不靜默）。
- Renderer：drawable 取得失敗跳幀不崩；連續 N 次失敗上報狀態。
- 全域：MirageCore 不 fatalError；App 層決定呈現。

## 6. 測試策略

- **單元（MirageCoreTests，TDD）**：重連狀態機（含退避時序、假時鐘注入）、FramePump
  覆蓋語意（塞 3 幀取 1 得最新）、尺寸/座標換算、版本檢查邏輯（UnaryMmap 拒啟用）。
  Mock transport 注入，不碰網路。
- **整合（沿用 phase0 harness）**：animate.py 動畫源 + 真模擬器量 fps；殺模擬器重啟
  驗重連；e2e 落點迴歸。
- 覆蓋率目標：MirageCore ≥80%。

## 7. 驗收標準（P1-a 出貨線）

1. 540p 視窗 **穩定 60fps**（Release、乾淨主機 load<核心數、animate 動畫源、
   量測 30s p5 幀率 ≥55）。
2. `pkill qemu` 後模擬器重啟，App **10 秒內自動恢復畫面**，全程不崩潰。
3. e2e 輸入落點與延遲不回歸（p50 ≤ Phase 0 重測基線 +10%）。
4. MirageCore 單元測試全綠、覆蓋率 ≥80%；`swift build -c release` 零警告。
5. CPU：540p 60fps 下 App Release 佔用記錄在案（目標 <50% 單核當量，超標記錄原因）。

## 8. 風險與備註

- MTKView vsync 拉取模式下 CVDisplayLink/draw 迴圈與 SwiftUI 整合的細節（`isPaused`/
  `enableSetNeedsDisplay` 組合）需在計畫中定死，避免隱性 30fps 上限。
- grpc-swift 1.x 的 AsyncStream 取消語意（重開串流時舊 call 的 cancel）要測。
- 60fps 驗收依賴乾淨主機——量測紀律沿用（load 檢查、animate 源、Release build）。
- unary-MMAP 為實驗旗標非驗收項；其 canary 版本檢查是安全鐵則（穩定版會崩）。
