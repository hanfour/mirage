# P1-e 全螢幕遊戲模式與音訊 設計文件

- **日期**：2026-07-26
- **狀態**：待核准
- **前置**：P1-a 顯示殼、P1-b 生命週期、P1-c 鍵位映射、P1-d 遊戲偵測、APK 拖放安裝（皆已合併）

## 1. 目標

補齊母計畫 Phase-1「鏡像視窗：Metal 渲染、縮放、**全螢幕遊戲模式**、**音訊**」尚缺的兩項：

1. **全螢幕遊戲模式**：macOS 原生全螢幕（⌃⌘F／綠燈），畫面 aspect-fit 置中、黑邊乾淨、不變形；全螢幕時隱藏 keymap 提示 overlay。
2. **音訊輸出**：guest 音訊經 `streamAudio` → CoreAudio 播放到 Mac 喇叭，與畫面共用同一條電源生命週期（關視窗即靜音）。

**非目標**（本階段明確不做）：

- **麥克風輸入**（`injectAudio`，Mac mic → guest）。母計畫 §5 只把「音訊隨畫面走」列入 P1；語音聊天留待後續。
- **A/V 同步**。`AudioPacket` 雖帶 timestamp，emulator 未提供對齊機制；手遊玩家對音畫同步容忍度遠高於影片。緩衝深度壓在 ~100ms 即可。
- **等化器／空間音訊／音量曲線／per-game 音訊設定**。
- **無邊框覆蓋式全螢幕**。原生全螢幕是本專案「Mac 原生質感」差異化的一部分（母計畫 §2.4）；不做第二種模式，不加設定項。
- **模糊背景／自訂黑邊視覺**。黑邊就是純黑。

## 2. 全域約束（延續 P1-a/b/c/d + APK 安裝）

- 平台 macOS 14+ Apple Silicon；`swift build -c release` 零非-deprecation 警告。
- **MirageCore 不得 import AppKit/SwiftUI/Metal/AVFoundation**；不 `fatalError`；錯誤回傳/記錄，App 層決定呈現。
- 所有 target 開 `-strict-concurrency=complete`；`.swiftLanguageMode(.v5)`。
- 測試語法用 swift-testing；每檔 <400 行、函式 <50 行；純函式與 UI 膠水嚴格分離。
- **不可變優先**——本階段有一個明文破例，見 §4.5。
- TDD：先寫失敗測試 → 確認失敗 → 最小實作 → 綠 → commit。Conventional commits、無 attribution。
- MirageCore 覆蓋 ≥80%；既有測試（合併後 101 個 `@Test`）不回歸。
- 活體測試預設 skip、`MIRAGE_LIVE` 開啟；adb 一律 `ANDROID_SERIAL=emulator-5554`（避開實體手機）。
- **零 proto 遷移**：`streamAudio` / `AudioFormat` / `AudioPacket` 已存在於 `Sources/MirageCore/Generated/emulator_controller.{pb,grpc}.swift`，不需重新產生。

## 3. 檔案結構

新增：

```
Sources/MirageCore/Viewport/ViewportFit.swift          純函式：幀 aspect-fit 進 bounds
Sources/MirageCore/Audio/AudioTransport.swift          協定 + AudioChunk / AudioStreamFormat 值型別
Sources/MirageCore/Audio/AudioRingBuffer.swift         SPSC 無鎖環形緩衝（唯一可變破例）
Sources/MirageCore/Audio/GrpcAudioTransport.swift      streamAudio 封裝
Sources/MirageApp/MirrorContainerView.swift            黑底容器，負責 letterbox layout
Sources/MirageApp/Audio/AudioPlayer.swift              AVAudioEngine + AVAudioSourceNode
Tests/MirageCoreTests/ViewportFitTests.swift
Tests/MirageCoreTests/AudioRingBufferTests.swift
Tests/MirageCoreTests/AudioChunkTests.swift            S16 → Float32 轉換
Tests/MirageCoreTests/AudioTransportTests.swift        假 transport 注入
Tests/MirageCoreTests/AudioLiveTests.swift             活體（MIRAGE_LIVE）
app/scripts/verify_audio.sh                            活體驗證腳本
```

修改：

```
Package.swift                       + swift-atomics（exact 1.3.1，已在 Package.resolved）
Sources/MirageApp/MirrorView.swift  NSViewRepresentable 改回傳容器；resizeDebounced 改用內容矩形
Sources/MirageApp/MirageApp.swift   isFullScreen 狀態、overlay 隱藏、選單列接線
Sources/MirageCore/EmulatorClient.swift          attachAudio / detachAudio（對稱於 FramePump）
Sources/MirageApp/Lifecycle/MenuBarController.swift  「進入遊戲模式」「靜音」項目
app/README.md                       P1-e 章節
```

## 4. 元件設計

### 4.1 ViewportFit（MirageCore，純函式）

**問題**：目前的呈現層沒有「fit」的概念。它是「視窗鎖 `contentAspectRatio` + `CAMetalLayer` 拉伸填滿 view bounds」——等於把長寬比問題外包給 window manager。**macOS 原生全螢幕會忽略 `contentAspectRatio`**（視窗即整片螢幕），這個外包當場破產：畫面被拉成 16:10、而且 `MirrorMTKView.normalized()` 用 `bounds` 換算觸控座標，一旦有黑邊就整組歪掉。

```swift
public struct FitRect: Equatable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int   // backing pixel
}

public enum ViewportFit {
    /// 把 frame 的長寬比 aspect-fit 進 bounds，回傳置中的內容矩形。
    /// frame 或 bounds 任一維度 <= 0 → 回傳 .zero（呼叫端據此不佈局，不崩）。
    public static func fit(frame: (w: Int, h: Int), in bounds: (w: Int, h: Int)) -> FitRect
}
```

保證的性質（測試要明確斷言）：

- **aspect 相同 → 黑邊為 0**，退化成滿版。這條性質就是「視窗模式零回歸」的形式化保證。
- 內容矩形永不超出 bounds；置中偏移為 `(bounds - content) / 2`。
- 直向、橫向、正方、極端比例走同一條路徑，**無 if 分支處理方向**。

### 4.2 MirrorContainerView（App，letterbox 佈局）

**取捨說明**（這是本設計最重要的一個決定）：直覺解法是寫 Metal render pass，把 texture 畫到置中的 quad。那需要新增 shader，並且 `normalized()` 得處理黑邊偏移、`KeymapController` 的座標路徑跟著動——為了加一個功能污染三條既有路徑。

改用更笨、更清晰的做法：

```
MirrorContainerView (黑底 NSView)         ← 本階段唯一新增的 view
   └── MirrorMTKView (程式碼完全不動)      ← frame = ViewportFit.fit(...) 的內容矩形
         └── CAMetalLayer 照舊拉伸填滿它
```

容器在 `layout()` 時算一次 `fit`，把子 view 的 frame 設成內容矩形。由此：

- **黑邊是父 view 的背景色**（`wantsLayer` + 黑 `backgroundColor`），不是渲染出來的 → 零 Metal 改動、零 shader。
- **`MirrorMTKView.bounds` 永遠等於內容矩形** → `normalized()`、`KeymapController`、`Renderer` 的座標數學**一行都不用改**，零回歸風險。
- **黑邊上的點擊**被 AppKit hit-test 天然擋在容器上，傳不到 MTKView——不是加 `if` 擋掉，是幾何上不會發生。
- **橫向遊戲**：`ImageFormat.rotation` 是 `[Output Only]` 且「the image **will be rotated** based upon the coarse grained orientation of the device」——emulator 已把幀轉好，回來的就是橫幀。容器一律以**實際幀長寬比**驅動，橫向自動支援。
- **視窗模式**：`contentAspectRatio` 仍鎖著，黑邊寬度自然為 0 → **同一份程式碼，沒有「全螢幕模式」分支**。

容器需要知道目前幀尺寸：由 `Renderer.lastFrameSize`（已存在）供給；幀尺寸變化時觸發 `needsLayout = true`。

**順手清除的技術債**：`9:20`／`w * 20 / 9` 目前硬編碼在 `MirrorMTKView.viewDidMoveToWindow`、`MirrorView.Coordinator.resizeDebounced` 兩處（另有 `defaultGuestSize` 常數 540×1200 三處）。全部改由實際幀長寬比驅動；`defaultGuestSize` 保留為「尚未收到第一幀」的初始值。

### 4.3 串流解析度（MirrorView.Coordinator）

`resizeDebounced` 改用**內容矩形寬**（而非視窗寬）+ 實際幀長寬比反推高度。全螢幕時內容矩形寬 = 螢幕高 × aspect，會自動請求更高解析度。

**必須設上限**：4K 螢幕上直向遊戲會算出約 880×1960，再大就有掉 fps 風險（風險 R4）。定義常數 `maxStreamWidth = 1080`，超過即 clamp。上限值可調，調整依據是 `MIRAGE_FPS_LOG` 的實測。

### 4.4 AudioTransport / AudioChunk（MirageCore，協定與值型別）

對齊既有 `DisplayTransport` 的注入風格：

```swift
public struct AudioStreamFormat: Equatable, Sendable {
    public let samplingRate: Int      // 48000
    public let channels: Int          // 2（stereo）
    // 取樣格式固定 S16（proto AudioFormat.SampleFormat.audFmtS16），不參數化
}

public struct AudioChunk: Sendable {
    public let samples: [Float]       // interleaved Float32，已由 S16 轉換完成
}

public protocol AudioTransport: Sendable {
    func packets(format: AudioStreamFormat) -> AsyncThrowingStream<AudioChunk, Error>
}
```

**格式決策**：request `samplingRate = 48000`、`channels = stereo`、`format = audFmtS16`、`mode = modeRealTime`。proto 註明 samplingRate 上限 48kHz、Android 裝置典型即 48k，固定格式 → **不需要重採樣**。

**S16 → Float32 轉換在生產者端做完**，不進即時執行緒。轉換為純函式，獨立可測：端點值 `-32768`/`32767`、奇數 byte 數（防禦性截斷，不崩）、空 `Data`。

### 4.5 AudioRingBuffer（MirageCore，唯一可變破例）

```swift
public final class AudioRingBuffer: @unchecked Sendable {
    public init(capacitySamples: Int)          // 容量上限 ~200ms @48k stereo = 19200
    public func write(_ samples: [Float])      // 生產者執行緒；滿 → 丟新、overruns += 1
    public func read(into: UnsafeMutablePointer<Float>, count: Int) -> Int
                                               // 即時執行緒；不足 → 回實際數、underruns += 1
    public var stats: AudioStats { get }        // 不可變快照
}

public struct AudioStats: Equatable, Sendable {
    public let underruns: Int, overruns: Int, depthSamples: Int
}
```

**明文破例**：這是本專案唯一允許 mutate 的資料結構，直接違反全域約束的「不可變優先」。理由是即時音訊的硬性要求——render callback **不得配置記憶體、不得加鎖、不得 log**，每包造新陣列會在即時執行緒觸發配置，結果是週期性爆音。破例範圍嚴格限縮在這一個 type 內：內部是預先配置的 `UnsafeMutableBufferPointer<Float>` + `ManagedAtomic<Int>` 讀寫索引（SPSC），對外只暴露不可變的 `AudioChunk` 與 `AudioStats` 快照。

**溢位／欠位策略**：

- 緩衝滿 → **丟掉新進封包**、`overruns += 1`。丟新不丟舊，SPSC 的讀寫索引不變式才乾淨（丟舊需要生產者移動讀索引，會破壞單一擁有者假設）。穩態下生產與消費都是 48k 不會持續溢位，只有瞬時卡頓才觸發。
- 緩衝空 → render callback 由呼叫端補靜音、`underruns += 1`，**絕不阻塞**。

**容量與穩態深度是兩回事**：容量 200ms 是溢位前的天花板；穩態深度目標 ~100ms（§1 非目標所述），由生產端自然節奏決定，不另設節流。深度持續逼近容量代表消費端出問題，會由 `overruns` 顯現。

**依賴**：`swift-atomics` 已存在於 `Package.resolved`（1.3.1，grpc-swift 的傳遞依賴），只是未宣告成可 import 的 product。加 `.package(url:, exact: "1.3.1")` + `.product(name: "Atomics", package: "swift-atomics")`，**不引入新的網路依賴**。

### 4.6 AudioPlayer（App，CoreAudio 接線）

`AVAudioEngine` + `AVAudioSourceNode`，格式 `AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)`——interleaved 讓 render block 只需一次 `memcpy`。

render block 的唯一工作：`ringBuffer.read(into:count:)`，回傳數不足時把餘下 frame 補 0。不配置、不加鎖、不 log。

靜音：`engine.mainMixerNode.outputVolume = 0/1`。macOS 沒有原生 per-app 音量，不給靜音等於玩家只能把整台 Mac 靜音——選單列一個勾選項，3 行程式碼。

### 4.7 生命週期接線（EmulatorClient）

與既有 `FramePump` **完全對稱**，掛在同一條連線狀態機上，**不新增第二條生命週期**：

| 事件 | 畫面（既有） | 音訊（新增） |
|---|---|---|
| → `.connected` | `attachStream()` | `attachAudio()` |
| 斷線 / `.stopRequested` | `pump.detach()` | `detachAudio()` |
| 重連成功 | 重新 attach | 重新 attach |
| 休眠（關視窗） | 停止拉幀 | `detachAudio()`（關窗即靜音） |
| 喚醒 | 恢復拉幀 | `attachAudio()` |

`EmulatorClient.init` 新增 `makeAudioTransport: @Sendable (GrpcChannelBox) -> AudioTransport` 參數，預設為 `GrpcAudioTransport(channel:)`——與既有 `makeTransport` / `makeHealthProbe` 同一套注入慣例，讓 §7 的接線測試能塞假件。

`detachAudio()` **必須顯式 `call.cancel()`**——proto 白紙黑字：「The stream may block indefinitely if the emulator ceases to produce audio」，永遠不能指望它自己結束。這也直接關聯到已知的 NIO teardown 技術債（見 `RESULTS-p1b.md`）；不顯式取消就是再挖一個同樣的坑。

## 5. 錯誤處理

- **`ViewportFit` 退化輸入**（幀或 bounds 任一維度 ≤ 0）→ 回 `.zero`，容器不佈局子 view，不崩。
- **`AudioTransport` 串流錯誤** → 走既有 `TransportError` 分類（`unavailable` 可重連 / `invalidRequest` fail fast），交由既有連線狀態機處理，音訊不自行重連。
- **AVAudioEngine 啟動失敗**（無輸出裝置、沙盒權限）→ 記錄並降級為「無音訊」，**畫面與輸入完全不受影響**。音訊不可拖垮鏡像主功能。

  > **⚠️ 更正（2026-07-29）：這條設計承諾在實作上沒有兌現，而它恰好是三個階段黑畫面的根因本體。**
  >
  > 本節只設想了「`engine.start()` 丟 Swift `Error`」這一種失敗，用 `do/catch` 包住。但實際
  > 打死系統的是 `engine.connect(_:to:format:)` 在收到 interleaved format 時丟的
  > `kAudioUnitErr_FormatNotSupported (-10868)` **Obj-C NSException**——`do/catch` 攔不到它。
  > 那個例外在 `@MainActor` 上把 `startLifecycle()` 的執行整個扯斷，MainActor 自此不再 drain：
  > `client.states` 的消費者永遠收不到值（橫幅卡在「未連線」）、MTKView 停止繪製
  > （`fps=` 恆為 0）。**音訊確確實實拖垮了鏡像主功能**，而且拖垮的方式正是本節宣稱不會發生的那種。
  >
  > 修法在 `MirageShell/Audio/AudioPlayer.swift:29`：格式硬性指定 `interleaved: false`
  > （不是偏好，是 `engine.connect` 的硬性要求），從源頭讓那個 NSException 不會被丟出來。
  > 完整證據見 `2026-07-28-mirror-never-rendered-investigation.md`。
  >
  > **設計教訓**：「降級為無音訊」的容錯只擋得住你**預期的那種失敗**。這裡預期的是 Swift
  > 錯誤，實際來的是 Obj-C 例外——而 Swift 的 `do/catch` 對後者完全無效。寫「不可拖垮主功能」
  > 時要問的不是「我有沒有 catch」，是「有哪些失敗形態根本不走 catch」。
- **`streamAudio` 無封包 ≠ 斷線**。遊戲靜音時本來就沒有封包，絕不可拿它當健康訊號（健康探測仍由既有 `HealthProbe` 負責）。
- **緩衝欠位/溢位**不是錯誤，是要被計數與觀測的正常現象。

## 6. 觀測性

`MIRAGE_AUDIO_LOG=1` → 每秒印一行：

```
[audio] pkt=42 sr=48000 ch=2 under=0 over=0 depth=96ms
```

這是本階段**唯一能無頭驗證音訊健康的訊號**，`verify_audio.sh` 的斷言就建立在它之上。格式沿用既有 `MIRAGE_FPS_LOG` 的風格（單行、可 grep）。

## 7. 測試

| 層 | 對象 | 手段 |
|---|---|---|
| 純函式 | `ViewportFit`、`AudioRingBuffer`、S16→Float32 | TDD 單元測，目標**逐行 100%** |
| 接線 | `EmulatorClient` 的 attach/detach 編排 | 注入假 `AudioTransport`（對齊既有 `makeTransport` 注入慣例）：斷線卸載、重連重掛、休眠靜音、`stop()` 後不再有封包 |
| gRPC 實作 | `GrpcAudioTransport` | **只能活體驗**（同 `GrpcStreamTransport` 既有處境），不寫假 channel 單元測 |
| 活體 | 真模擬器 | `MIRAGE_LIVE=1 swift test --filter AudioLiveTests`、`scripts/verify_audio.sh` |
| GUI | 全螢幕視覺、聽感 | **pending-human**（見 §9） |

`ViewportFit` 測試須窮舉會咬人的邊界：直向、橫向、正方、極端比例、bounds 為 0、幀為 0，以及「aspect 相同 → 黑邊為 0」這條保證視窗模式零回歸的性質。

`AudioRingBuffer` 測試須涵蓋：環繞寫、跨界讀、部分讀、欠位補靜音與計數、溢位丟新與計數、SPSC 併發壓力（生產與消費各一 task 跑固定樣本數，斷言無資料損毀）。

**活體驗證的已知難題**（不假裝已解決）：guest 不發聲就沒有封包。腳本策略是**先印 packet 率**；若為 0，再用 `adb shell` 觸發 AOSP 內建鈴聲/通知音發聲。這條路能否跑通**必須由 plan 的第一個音訊活體任務先行確認**，若走不通則改用替代發聲手段（例如 sideload 一顆會發聲的 APK），並把結論寫進 `RESULTS-p1e.md`。

## 8. 驗收線

可量測（必須有輸出佐證）：

1. `swift test` 全綠，既有 101 個 `@Test` 不回歸。
2. `ViewportFit`、`AudioRingBuffer` 逐行 **100%** 覆蓋。
3. 整體 MirageCore 覆蓋率不低於現況（~94%，含 live smoke 的完整呼叫方式）。
4. `swift build -c release` 零非-deprecation 警告。
5. 活體：audio packet 率 **≥ 30 pkt/s**（proto 稱 20–30ms 一包），格式 48000 / stereo / S16。
6. 活體：連續 60 秒 `underruns == 0`。

   > **⚠️ 更正（2026-08-03，D32）：這條字面判準與本文件 §5 自相矛盾，結構上不可能成立。**
   >
   > §5 寫著「`streamAudio` 無封包 ≠ 斷線。遊戲靜音時本來就沒有封包」與「緩衝欠位/
   > 溢位不是錯誤，是要被計數與觀測的正常現象」。而 `AudioPlayer` 的 render callback
   > 每 ~10ms 要一次資料（`AudioPlayer.swift:35`），guest 只要有一刻不發聲，
   > `readStereo` 就走 `underrunCount.wrappingIncrement`（`AudioRingBuffer.swift:100`）。
   > 所以 `== 0` 在任何含靜音期的 60 秒裡不可能成立。
   >
   > 這與 D32 原本記載的「drain 情境下不成立」是**不同的第二個原因**：前者出在測試
   > harness 的假消費端，後者在真 `AudioPlayer` 下一樣存在。把 harness 換成真的並
   > 不會讓這條判準變得可達。
   >
   > **新表述**：只統計「本秒與前一秒皆有封包」的 underrun 增量，並與「App 存活」
   > 「串流活著」「畫面 fps」三條一起判。自動化涵蓋在 `app/scripts/verify_audio_gui.sh`，
   > 完整推導見 `docs/specs/2026-08-03-d32-acceptance-6-automation-design.md`。
7. fps 不回歸：`MIRAGE_FPS_LOG` 在全螢幕串流解析度上限下 **≥ 55**。

## 9. pending-human（本機 GUI App headless 不驅動 `.task`，無法自動驗）

1. 實際聽得到聲音，且無爆音／破音／延遲感。
2. 全螢幕 letterbox 目視：置中、黑邊純黑、畫面不變形。
3. 橫向遊戲的全螢幕表現。
4. 遊戲模式 chrome 隱藏的實際手感（keymap overlay 消失、連線/安裝 banner 仍可見）。
5. 全螢幕下 keymap 與 mouse capture 的實際手感。

## 10. 與既有階段的整合面 + 風險

**整合面**：

- **P1-a 顯示**：`Renderer` 程式碼不動；`MirrorMTKView` 程式碼不動。只有 `MirrorView.makeNSView` 改回傳容器、`resizeDebounced` 改算法。
- **P1-b 生命週期**：音訊掛在既有 `PowerState`／連線狀態機上，不新增狀態。
- **P1-c/P1-d 鍵位**：座標路徑零改動（因 `MirrorMTKView.bounds` == 內容矩形）；`shouldCapture` 判斷式不改（全螢幕下 `NSApp.keyWindow != nil` 本來就成立）。
- **APK 安裝**：`InstallBanner` 在全螢幕保留顯示。

**風險**：

| # | 風險 | 對策 |
|---|---|---|
| R1 | `streamAudio` 可能無限阻塞（proto 明載） | 卸載顯式 `cancel()`；**不可**把「無封包」當斷線訊號 |
| R2 | render thread 即時約束 | 無鎖 + 預配置 + 不 log；違反即週期性爆音 |
| R3 | `DeliveryMode` 對 `streamAudio` 是否生效未知（proto 標 `[Input Only]`） | 不論生效與否都安全——自家 ring buffer 的 overrun 丟包已守住延遲上限 |
| R4 | 全螢幕請求高解析度 → 掉 fps | `maxStreamWidth` 上限常數 + 既有 `MIRAGE_FPS_LOG` 佐證 |
| R5 | 全螢幕與音訊都需真 GUI 才能驗 | 比照 P1-a~d 慣例，pending-human 誠實列出，不灌水 |
| R6 | 顯式宣告 swift-atomics 擾動版本解析 | `exact: "1.3.1"`，對齊現有 `Package.resolved` |

## 11. 互動決策（已定案）

| 事項 | 決定 | 理由 |
|---|---|---|
| 音訊方向 | 只做輸出 | 母計畫 §5 只把「音訊隨畫面走」列 P1；玩家聽得到聲音即 100% 價值 |
| 全螢幕形式 | macOS 原生（⌃⌘F／綠燈／獨立 Space） | Mac 原生質感是本專案差異化；無邊框式是 BlueStacks 那種「Windows 移植感」 |
| **不搶 Esc** | 不綁定 | Esc 在 guest 是返回鍵，搶了直接壞遊戲輸入 |
| 全螢幕隱藏 | KeymapOverlay 提示標記 | 遊戲中為純視覺噪音 |
| 全螢幕保留 | ConnectionBanner、InstallBanner | 斷線是必須知道的異常；安裝是使用者主動觸發的回饋 |
| 休眠音訊 | 關窗即靜音，跟畫面走 | 共用 `PowerState` 一條狀態線，不新增獨立開關 |
| 靜音勾選 | 做（唯一破 YAGNI 的小項） | macOS 無原生 per-app 音量，不給靜音等於得靜音整台 Mac |
| spec/plan 拆分 | 一份 spec、一份 plan，內部分兩段 | 合計 ~10 個任務，與前幾階段同規模；兩者共用同一個驗收情境與 RESULTS |
| 全螢幕狀態來源 | `NSWindow.didEnterFullScreenNotification` | 由系統告知，不自行推測 |
