# Streaming MMAP Transport 設計文件

- **日期**：2026-07-27
- **狀態**：待核准
- **前置**：P1-a～P1-e 與 P1-e fast-follow 皆已合併（`main` @ `4e26902`）
- **緣起**：上游 b/537802959 已修，且實測確認**現有 emulator 版本即可繞過**

## 1. 目標

讓 `streamScreenshot` 走共享記憶體（MMAP `ImageTransport`）取代目前的 raw RGBA protobuf
payload，消滅每幀的序列化／反序列化成本。

**為什麼現在做**：Phase-0 曾判定「MMAP 串流在 macOS 壞掉」並據此建了 `UnaryMmapTransport`
workaround。上游回覆揭露根因是 `streamScreenshot` 開頭用 `request->width() * request->height()`
去 pre-borrow 共享記憶體，**請求裝置原生尺寸時該值為 0** 而毒化 cache。而 Mirage 的
`GrpcStreamTransport` **一直都帶明確尺寸**——我們從來不會踩到這個 bug。Phase-0 用了產品
不會送的請求形狀去探測，結論只對探測腳本成立。實測見 `docs/upstream/2026-07-22-emulator-mmap-macos.md`。

### 1.1 已量化的收益（`phase0/harness/bench_mmap_vs_rgba.py`，900×2000，三次）

| 指標 | raw RGBA | MMAP（每幀完整複製） |
|---|---|---|
| client CPU / 幀 | 7.8 / 8.0 / 8.1 ms | **0.68 / 0.71 / 0.74 ms（−91%）** |
| 經 gRPC 的位元組 | 272 / 246 / 222 MiB/s | **0** |
| qemu CPU（10 秒窗口） | 19.9 / 19.6 / 19.0 s | 18.3 / 17.9 / 17.3 s（**−8~9%**） |

60fps 換算，client 每秒省下約 **0.44 個核心**——對筆電上的遊戲模擬器意味著電池、發熱、
以及留給遊戲本身的餘裕。

**明確不成立、不得作為理由**：fps 是**平手**（三次 +4.1 / +0.7 / −1.3，雜訊範圍內）。
第一版基準曾據灌水數字宣稱 fps 提升並可能影響驗收線 7，**該結論已撤回**。

**限制**：client CPU 以 Python client 量測，Swift／grpc-swift 絕對值必然不同；但「消滅
220–272 MiB/s 的 protobuf payload」與「qemu 端 −8~9%」與 client 語言無關。

## 2. 非目標

- **不做零拷貝**。`mmap-copy` 與 `mmap-touch` 只差 0.2 ms/幀；更重要的是**複製是正確性
  所必需**（見 §4.2），不是可以優化掉的浪費。
- **不改 `Frame` 結構**。維持 `Frame.rgba: Data`。
- **不改既有 `GrpcStreamTransport`**。它仍用便利方法 `client.streamScreenshot(_:)`，是既有
  NIO teardown 架構債的一部分——那是獨立的一件事，不夾帶。
- **不放寬版本閘**。36.x 可能也只是同一個 0×0 根因、送明確尺寸就不會炸，但**我們沒有證據**，
  而驗證代價是故意炸掉一台 VM。維持 ≥37。
- **不處理多開**。單實例即可。

## 3. 全域約束（延續既有階段）

- 平台 macOS 14+ Apple Silicon；`swift build -c release` 零非-deprecation 警告
- **MirageCore 不得 import AppKit / SwiftUI / Metal / AVFoundation**（本階段需 `Darwin` 的
  `mmap`/`munmap`/`unlink`，屬系統層非 UI 層，允許）；不 `fatalError`
- `-strict-concurrency=complete`；`.swiftLanguageMode(.v5)`；swift-testing 語法
- 每檔 <400 行、函式 <50 行；不可變優先
- TDD：先寫失敗測試 → 確認失敗 → 最小實作 → 綠 → commit
- Conventional commits，**不得含任何 attribution / Co-Authored-By**
- 既有 137 個 `@Test` 不得回歸
- 活體測試預設 skip；adb 一律 `ANDROID_SERIAL=emulator-5554`

## 4. 架構

```
連線建立（HealthProbe 回報 .healthy(version:)）
    ↓
MmapVersionGate.allows(version)？
    ├─ 否 → GrpcStreamTransport（raw RGBA，現行路徑）
    └─ 是 → FallbackTransport(primary: MmapStreamTransport,
                              secondary: GrpcStreamTransport)
```

### 4.1 版本字串：不新增 RPC

`GrpcHealthProbe.probe()` **已經**在打 `getStatus` 並拿到完整 `EmulatorStatus`（含 `version`），
卻只回傳 `.healthy`／`.failed` 就丟棄。改為讓它帶出來：

```swift
public enum HealthResult: Equatable, Sendable {
    case healthy(version: String)   // 原為 case healthy
    case timedOut
    case failed
}
```

代價：`EmulatorClient.runConnectionLoop` 的 `result == .healthy` 改為 `if case`；
`ScriptedProbe`（測試假件）跟著調。收益：**每次連線少一次 RPC**，且「我們連上的是什麼」
本來就屬於連線層的知識。

`EmulatorClient` 快取該版本字串，供 `ensureChannel()` 決定要建哪種 transport。

### 4.2 MmapStreamTransport

一次掛載的生命週期：

1. 產生**唯一**映射檔路徑：`NSTemporaryDirectory()/mirage_mmap_<pid>_<seq>_<w>x<h>.bin`，
   大小 `w*h*4`
2. `mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0)`
3. 用 **`makeStreamScreenshotCall`**（**不是**便利方法 `client.streamScreenshot(_:)`）掛串流，
   request 為 `ImageFormat{format: .rgba8888, width: w, height: h,
   transport: ImageTransport{channel: .mmap, handle: "file://<path>"}}`
4. 每收到一則通知 → 從映射區 `Data(bytes: ptr, count: size)` 複製出 `Frame` → yield
5. 終止（`onTermination`）→ 顯式 `call.cancel()` → `munmap` → `close(fd)` → **`unlink`**

**為什麼用唯一路徑**：上游根因是 pre-borrow 毒化 cache，而 cache 的 key 看來與 handle 相關
（基準測試中「不帶尺寸」那組與「明確尺寸」那組用不同臨時檔，後者未被前者毒到）。每次掛載
換新路徑就沒有任何殘留狀態的疑慮，也避開舊檔殘留。

**為什麼用 `makeStreamScreenshotCall`**：便利方法丟棄底層 `GRPCAsyncServerStreamingCall`，
無法顯式取消——這是 P1-b 剪貼簿串流實證過、且架構債記錄點名為 crash 元兇的同一個坑。
新程式碼沒有理由重蹈。

**為什麼必須複製（不可零拷貝）**：emulator 會**原地覆寫**同一塊映射區來寫下一幀；而
`LatestFrameBox` 持有最新幀、`Renderer` 在 vsync 才讀取它。若 `Frame.rgba` 直接指向映射區
（`Data(bytesNoCopy:)`），渲染器會讀到正在被覆寫的記憶體 → 撕裂畫面。**複製是把該幀從
持續變動的緩衝區裡快照出來**，這是它存在的理由。此註解必須寫進原始碼，否則未來會有人
把它當成可優化的浪費。

**`UnaryMmapTransport` 退場**：被本 transport 完全取代。刪除該檔；活體測試改指向新
transport；`MmapVersionGate` 保留沿用；`MIRAGE_LIVE_MMAP` 環境變數名稱保留（腳本與文件
不需改動）。順帶修掉它的既有缺陷——它建了映射檔卻**從不 `unlink`**，每次換解析度就在
`/tmp` 留一個 7 MB 檔案。

### 4.3 降級判定：必須在串流路徑上

**不可用 unary 探測**。Phase-0 已證明 unary MMAP 在串流壞掉時**照樣正常**——unary 探測會
得到假陽性，然後給使用者黑畫面。

判定放在 `MmapStreamTransport` 內（只有它知道自己的緩衝區）：**收到的前 3 幀中，若每一幀
的映射區都是全零，則 `finish(throwing: TransportError.mmapUnusable)`**。只要其中任一幀出現
非零位元組，即判定 MMAP 可用、不再檢查後續幀。

全零檢查採**完整掃描**（不取樣）：一次 7.2 MB、最多做 3 次，是一次性成本，換取判定不會因
取樣點恰好落在黑色區域而誤判。判定完成後這條檢查完全不再執行，穩態零開銷。

偏誤方向是刻意的：**寧可誤降級也不要誤啟用**。誤降級只是多花 CPU、畫面完全正確；誤啟用是
黑畫面。且「畫面本來就全黑」時降級也無害——raw RGBA 一樣是黑的。

### 4.4 FallbackTransport

純組合器，本身不碰 gRPC：

```swift
public final class FallbackTransport: DisplayTransport, @unchecked Sendable {
    public init(primary: DisplayTransport, secondary: DisplayTransport)
}
```

`frames(width:height:)` 回傳的串流對消費端**無縫**：切換發生在內部，`FramePump` 看到一條
不中斷的串流。

**關鍵行為（測試必須明確涵蓋）**：只對 `TransportError.mmapUnusable` 降級。primary 若因
模擬器被殺而丟 `.unavailable`，那是**斷線**，必須照常往上傳播交給既有重連迴圈——
**絕不能被誤判成「MMAP 壞了」而永久降級**，否則使用者斷線一次就永遠回不到 MMAP。

**決定的有效範圍是一條 channel**：`dropChannel()` 時 transport 被重建，決定隨之消失，重連
後重新探測 3 幀。這是自癒的，也符合「模擬器可能在重連之間被換掉」的現實。

### 4.5 新增的錯誤型別

`TransportError` 新增一個 case：

```swift
case mmapUnusable(String)   // MMAP 掛載成功但 host 寫入端無作用 → 降級用
```

它與既有的 `.unavailable`（可重連）／`.invalidRequest`（fail fast）語意正交：
`.mmapUnusable` 既不重連也不 fail fast，而是**換一條 transport**。

## 5. 錯誤處理

- **版本取不到／解析失敗** → `MmapVersionGate.allows` 回 false → 走 raw RGBA。不猜。
- **映射檔建立或 `mmap` 失敗** → `finish(throwing: .mmapUnusable)` → 降級。不崩。
- **前 3 幀全零** → `.mmapUnusable` → 降級。
- **串流中斷（`.unavailable`）** → 照常傳播，由既有重連迴圈處理，**不降級**。
- **`unlink` 失敗** → 記錄不拋出（檔案殘留是可容忍的，中斷串流不是）。

## 6. 觀測性

沿用既有 `MIRAGE_FPS_LOG` 風格，新增一行啟動時的一次性訊息：

```
[transport] mmap enabled (emulator 37.2.1.0)
[transport] mmap unusable, falling back to raw rgba
[transport] raw rgba (emulator 36.6.11.0 < 37)
```

三種情形各印一次，讓使用者與未來維護者能一眼看出走的是哪條路。**不做每幀日誌**。

## 7. 測試

| 層 | 對象 | 手段 |
|---|---|---|
| 純函式 | 全零判定、handle 路徑產生 | TDD 單元測，目標逐行 100% |
| 組合器 | `FallbackTransport` | 兩個假 transport（不碰 gRPC，故完全避開 NIO teardown 架構債） |
| 版本閘 | `MmapVersionGate` | 既有測試保留不動 |
| 連線層 | `HealthResult.healthy(version:)` 的接線 | 既有 `ScriptedProbe` 調整後，既有重連測試須全綠 |
| 活體 | `MmapStreamTransport` | `MIRAGE_LIVE_MMAP=1`，驗真的收到**非零且逐幀變動**的幀 |

`FallbackTransport` 的四條必測行為：

1. primary 正常 → 全程不切換，secondary 從未被訂閱
2. primary 丟 `.mmapUnusable` → 無縫接上 secondary，消費端看到連續串流
3. 切換後 → 不再嘗試 primary（同一 instance 內）
4. **primary 丟 `.unavailable` → 不降級，錯誤照常傳播**

## 8. 驗收線

1. `swift test` 全綠，既有 137 個 `@Test` 不回歸
2. 新增純函式與 `FallbackTransport` 測試通過；純函式逐行 100%
3. `swift build -c release` 零非-deprecation 警告
4. `./scripts/coverage.sh` 的 `MirageCore` 段不低於 ~94% 基準
5. 活體：`MIRAGE_LIVE_MMAP=1` 下 `MmapStreamTransport` 收到 ≥3 個**非零且互異**的幀
6. 活體：跑完後 `/tmp` 無 `mirage_mmap_*` 殘留
7. 以 `bench_mmap_vs_rgba.py` 複驗收益仍在量級上成立（client CPU/幀降幅 ≥80%）

## 9. pending-human

需真 GUI session（螢幕解鎖）才能驗，原因見 `RESULTS-p1e.md`：

1. App 實際跑在 MMAP 路徑下的畫面正確性（無撕裂、無色偏）
2. App 合成層 fps 是否因 client CPU 下降而改善（本階段基準只量傳輸層，**不得**互相冒充）
3. 換解析度（`setStreamSize`）時的畫面連續性

## 10. 風險

| # | 風險 | 對策 |
|---|---|---|
| R1 | 撕裂幀——proto 無同步原語，emulator 非同步寫入 | 已知限制，如實記錄。基準約 1100 幀未觀察到，但「沒觀察到」≠「不會發生」。若 pending-human 目視發現撕裂，退路是回 raw RGBA（一行改預設） |
| R2 | 36.x 收到 MMAP 會 SIGSEGV 弄死使用者的 VM | 版本閘 ≥37 當安全互鎖，沒有證據不放寬 |
| R3 | `HealthResult` 改形狀波及既有測試 | 驗收線 1 要求既有 137 個全綠 |
| R4 | 映射檔殘留 `/tmp` | `onTermination` 保證 `unlink`；驗收線 6 明確檢查 |
| R5 | `setStreamSize` 換尺寸時新舊映射並存 | 各自獨立檔案，舊串流終止即釋放；短暫並存可接受 |
| R6 | `Darwin` 的 `mmap` 在 strict-concurrency 下的 Sendable 邊界 | 指標包在 `@unchecked Sendable` 的 final class 內並以 lock 保護，比照既有 `GrpcChannelBox`／`GrpcAudioTransport` 慣例；不得用 `nonisolated(unsafe)` 硬壓 |

## 11. 與既有階段的整合面

- **`EmulatorClient`**：`HealthResult` 解構改動 + `ensureChannel()` 依版本選 transport。
- **既有 `GrpcStreamTransport`**：零改動（成為 fallback 的 secondary）。
- **`Frame`／`LatestFrameBox`／`Renderer`**：零改動。
- **`UnaryMmapTransport`**：刪除（108 行低覆蓋死碼一併退場，順帶改善 MirageCore 覆蓋率分母）。
- **腳本**：`verify_*.sh` 不改；`coverage.sh` 不改。
- **文件**：`app/README.md` 補 transport 選擇邏輯與觀測訊息說明。
