# 區域網路手機遙控：設計

- 日期：2026-09-12
- 狀態：設計待核可
- 使用情境：手機放在 Mac 旁邊，當 Mirage 的觸控第二螢幕。Mac 上的 Mirage 視窗照常運作。
- 延遲預算：手機畫面落後 Mac 畫面 50ms 上下。

## 1. 已確認的事實

以下由拋棄式 spike（Python relay＋ffmpeg VideoToolbox＋手機瀏覽器頁面，不進 repo）在 iPhone（iOS 18.7、Safari 26.6.1）上實測：

| 項目 | 結果 |
|---|---|
| `VideoDecoder` 在 `http://` 上是否可用 | 可用，`isSecureContext=false` 也開放。iPhone 不需要 HTTPS |
| H.264 baseline／high 解碼支援 | 都支援，硬體解碼 |
| 未改寫 SPS 時的解碼延遲 | 抵達到畫出 p50/p95 172/180 ms，解碼器囤 10 幀 |
| 改寫 SPS 注入 `max_num_reorder_frames=0` 後 | p50/p95 4/5 ms，囤 0 幀，解碼 60.8 fps，本地丟幀 0 |
| WebSocket 往返（經 Tailscale） | 24 到 27 ms |
| 觸控回傳 | 多點 pointer 事件經 WebSocket 回傳並 echo，0 個未送 |
| Mac 端硬體編碼 | 1080×2400@60 H.264，60 fps、零丟幀 |

Android Chrome 的 WebCodecs 只在 HTTPS 下開放。本設計第一版只支援 iPhone，Android 列在不做的事。

其他排除的傳輸方式：MSE 的解碼延遲約 240 ms；HLS 以秒計；WebRTC 沒有純 Swift 的 DTLS／SRTP 實作，只能引入 libwebrtc。

## 2. 架構

```
模擬器 ──gRPC streamScreenshot──▶ EmulatorClient ──▶ FramePump
                                                        │ put()
                                              BroadcastFrameSink
                                              ┌─────────┴─────────┐
                                        LatestFrameBox        LatestFrameBox
                                        （Renderer 用）        （編碼器用）
                                              │                     │ takeLatest() 依自己的節奏
                                          Mac 視窗            RemoteVideoEncoder（VideoToolbox）
                                                                    │ Annex-B NAL
                                                              RemoteServer（NIO HTTP＋WebSocket）
                                                                    │ WebSocket 二進位
                                                              手機瀏覽器 viewer.html（WebCodecs → canvas）
                                                                    │ WebSocket JSON（觸控）
                                                              RemoteTouchMessage → InputQueue → EmulatorClient.sendTouches
```

三個設計決定：

1. 編碼器接在 `FrameSink` 這一層。新增 `BroadcastFrameSink`，`put()` 扇出到 Renderer 的 box 與編碼器的 box，`takeLatest()`／`stats()` 代理給 Renderer 的 box。`FramePump`、`LatestFrameBox`、`Renderer`、`EmulatorClient` 一行不改；遙控關閉時 `AppModel` 用原本的 box，行為零改變。`Frame.rgba` 是 `Data`，扇出不多一次像素拷貝。
2. 遠端觸控走既有的 `InputQueue`，不直接呼叫 `EmulatorClient.sendTouch`。`sendTouch` 是獨立的 unary gRPC 呼叫，兩個並發 Task 各自送會在網路上超車，D6 記錄過那種「沒有自癒路徑的卡鍵」。手機的手指用保留的識別碼區段 64 到 79，與 Mac 端的 `sendTap`（0）和 keymap 觸點（1 起）不重疊；模擬器的並發觸控上限是 10。
3. 編碼一律用 VideoToolbox 硬體編碼。主機 CPU 是這台機器的瓶頸（`app/RESULTS-multi-instance.md`），軟體編碼會把 Mirage 自己的 fps 拉下來。

## 3. 元件

### MirageCore（純函式為主，逐行單元測試）

| 檔案 | 職責 |
|---|---|
| `BroadcastFrameSink.swift` | 幀扇出 decorator |
| `Remote/PairingToken.swift` | 一次性 token 產生（`randomSource` 注入）與常數時間比對 |
| `Remote/RemoteTouchMessage.swift` | 手機 JSON 觸控訊息 → `[TouchSpec]`，含 `NormPoint` 夾取與識別碼換算；抬起時強制 `down:false` |
| `Remote/RemoteTouchIdentifierAllocator.swift` | 手機 pointerId → 64 到 79 的配置與釋放，超過 16 指拒絕 |
| `Remote/H264Nal.swift` | Annex-B 起始碼切分、存取單元打包、NAL 型別判斷 |
| `Remote/H264SpsRewriter.swift` | SPS 解析與 VUI bitstream_restriction 注入（`max_num_reorder_frames=0`、`max_dec_frame_buffering=max(1, num_ref_frames)`），含 emulation prevention 往返；冪等 |
| `Remote/RemoteSessionState.swift` | 單一手機連線的 reducer：等待配對 → 已連線 → 已斷線，比照 `ConnectionStateMachine` |
| `Remote/RemoteServer.swift` | NIOHTTP1＋NIOWebSocket：`GET /?t=<token>` 回 viewer 頁、`/ws/video`、`/ws/input` 升級時驗 token；只接受一條配對連線 |
| `Resources/remote/viewer.html` | 手機頁面，隨 `Mirage_MirageCore.bundle` 打包 |

`Package.swift` 要補 `.package(url: swift-nio, exact: "2.101.3")`（已在 `Package.resolved` 解析圖裡，不引入新版本），`MirageCore` target 加 `NIOPosix`、`NIOHTTP1`、`NIOWebSocket`。目前沒有這行，`import NIOWebSocket` 編不過。

### MirageShell（系統框架，活體驗證）

| 檔案 | 職責 |
|---|---|
| `Remote/RemoteVideoEncoder.swift` | `VTCompressionSession` 封裝：`Frame`（RGBA）→ `CVPixelBuffer` → Annex-B；尺寸變更時銷毀重建並重送 SPS/PPS；PTS 用 `Frame.receivedAt` |
| `Remote/RemoteMirrorController.swift` | 拉取迴圈（預設 30 fps，可設到 60）、餵編碼器、封包送 `RemoteServer`、收到的觸控轉 `inputQueue.touches(_:)` |
| `AppModel+Remote.swift` | 依設定建 `BroadcastFrameSink`、啟停 server 與 controller、提供連線網址與配對狀態 |
| `Lifecycle/AppLifecycle.swift`（修改） | `windowShouldClose` 加 `hasActiveRemoteViewer` guard，有手機連著時關 Mac 視窗不 suspend；預設閉包 `{ false }`，功能關閉時行為不變 |
| `Lifecycle/MenuBarController.swift`（修改） | 「手機遙控」子選單：開啟／關閉、顯示連線網址與 QR、中斷連線 |

編碼器的低延遲設定：`RealTime=true`、`AllowFrameReordering=false`、`MaxFrameDelayCount=0`、`PrioritizeEncodingSpeedOverQuality=true`、`ProfileLevel` baseline、`MaxKeyFrameInterval` 120、位元率預設 12 Mbps。

## 4. 協定

WebSocket `/ws/video`，每則二進位訊息一個存取單元：

| 位移 | 長度 | 內容 |
|---|---|---|
| 0 | 8 | 送出時間，`monotonic` 奈秒，big-endian |
| 8 | 4 | 幀序號 |
| 12 | 1 | 1 表示 keyframe（該則含 SPS＋PPS＋IDR） |
| 13 | 其餘 | Annex-B 位元組 |

新連線先送最近的 SPS/PPS，從下一個 IDR 才開始送。手機端從 SPS 算 codec 字串，不由伺服器另外送 config 訊息。伺服器背壓（送出佇列超過 3 幀）時丟掉整個 GOP 到下一個 IDR，不丟單一 P 幀，並計數。

WebSocket `/ws/input`，JSON 文字訊息：

```json
{"t": 1234.5, "id": 7, "type": "down|move|up|cancel", "x": 0.49, "y": 0.75}
{"type": "ping", "t": 1234.5}
```

`x`、`y` 是 0 到 1，相對於畫面內容區（不含 letterbox），左上原點；手機端算好再送。伺服器對 `ping` 原封 echo，供手機量往返。

手機端頁面：`VideoDecoder({codec, optimizeForLatency: true})`，output 回呼 `drawImage` 後立刻 `close()`；CSS `touch-action: none`、`user-select: none`、`-webkit-touch-callout: none`、`overscroll-behavior: none`，攔 `gesturestart`／`gesturechange`；`navigator.wakeLock.request("screen")`。不用 Fullscreen API（iPhone 沒有）。角落顯示解碼 fps、`decodeQueueSize`、抵達到畫出 p50/p95、往返、丟幀，可用 `?stats=0` 關掉。

## 5. 配對與安全

- 伺服器預設關閉，由選單列開啟。開啟時產生 128-bit 隨機 token，選單顯示 `http://<主機位址>:<埠>/?t=<token>` 與 QR。
- token 只在 `GET /` 與兩條 WebSocket 升級時驗證，同一時間只接受一條配對連線；第二個連線回 409。關閉功能或中斷連線時 token 作廢，重新開啟產生新的。
- 監聽所有介面（使用者實際用 Tailscale 連，只綁 Wi-Fi 介面會擋掉這條路），安全性靠 token 而不是綁定位址。埠預設 8765，可設。
- 不做 HTTPS。理由見第 1 節。
- 觸控訊息在 `RemoteTouchMessage.decode` 驗證：型別、識別碼範圍、座標範圍，任一不合法整則丟棄並計數，不拋例外。

## 6. 生命週期

- 手機連著時關 Mac 視窗：不 suspend，畫面繼續串流（第 3 節的 guard）。
- 沒有手機連著：與現況相同。
- 手機斷線：編碼器停止拉取，token 保留到使用者關閉功能，同一個網址可以重連。
- 串流尺寸隨 Mac 視窗變動：`EmulatorClient` 只有一組 `streamSize`，手機與 Mac 共用同一份幀。尺寸變更時重建編碼 session、下一則訊息帶新的 SPS/PPS，手機端 `configure` 一次。既有 300 ms 的 resize debounce 已足夠，不另加。

## 7. 錯誤處理

| 情況 | 行為 |
|---|---|
| 埠被佔用 | 選單顯示錯誤與埠號，功能維持關閉 |
| `VTCompressionSession` 建立失敗 | 選單顯示錯誤碼，功能關閉；不退回軟體編碼 |
| 手機解碼器 `configure` 失敗 | 頁面顯示 codec 字串與錯誤，不重試 |
| token 錯誤 | HTTP 403，不透露是否有進行中的連線 |
| 觸控訊息格式錯誤 | 丟棄、計數、每秒最多印一行 log |
| 手機端 `decodeQueueSize` 超過 8 | 丟到下一個 keyframe，計數 |

## 8. 驗證

- 單元測試：第 3 節 MirageCore 的每個檔案。`H264SpsRewriter` 用真實 SPS 當素材（VideoToolbox 產出的 baseline `27420032ab40220096f2e8`、high `27640032ac568044012de5d0`），驗改寫後欄位不變、冪等、含 emulation prevention byte 的往返。
- `RemoteServer` 用 `127.0.0.1:0` 起真實 socket 測配對、拒絕第二連線、訊息格式，不需模擬器。
- 活體：`scripts/verify_remote_mirror.sh`（`MIRAGE_LIVE=1 MIRAGE_LIVE_REMOTE=1`）：啟動 app、開遙控、用 Python WebSocket 用戶端連上，斷言 60 秒內收到 keyframe、幀序連續、送一組 down/move/up 後 guest 的 `getevent` 出現 `ABS_MT_TRACKING_ID`（用 `lib/getevent_touch.sh`）。
- 驗收線 7 不劣化：`verify_fps_fullscreen.sh` 在遙控開與關各跑兩次，開的時候中位數不低於關的時候 3 fps 以上。
- 人工：iPhone 開網址，量 glass-to-glass（第三台裝置同框拍 Mac 與手機畫面）。門檻 50 ms，敏感度往兩側試。

## 9. 分階段交付

| 階段 | 內容 | 驗證方式 |
|---|---|---|
| A | `Package.swift` NIO 宣告、`BroadcastFrameSink`、`H264Nal`、`H264SpsRewriter`、`PairingToken`、`RemoteTouchMessage`、識別碼配置、`RemoteSessionState` | 單元測試，ci.sh |
| B | `RemoteServer`、`viewer.html` | loopback 整合測試 |
| C | `RemoteVideoEncoder` | 活體測試：餵合成幀，斷言輸出 SPS 已含 VUI、每幀一個存取單元 |
| D | `RemoteMirrorController`、`AppModel+Remote`、選單、生命週期 guard | `verify_remote_mirror.sh`、fps 對照 |
| E | 人工驗收與 glass-to-glass 量測 | 使用者 |

每階段一個分支，合併前過 ci.sh、code-reviewer 審查、全分支 diff。

## 10. 不做的事

- Android：需要 HTTPS，憑證發放與安裝在第一版之外。
- 手機獨立解析度：需要第二條 `streamScreenshot`，CPU 成本翻倍，與第 2 節第 3 點衝突。
- 音訊串流。
- 多支手機同時連線。
- 鍵位映射套用到手機觸控：手機本身是觸控裝置，直接注入。

## 11. 風險

- 編碼器拉幀與 RGBA → `CVPixelBuffer` 拷貝每幀約 10 MB，30 fps 約 300 MB/s，對 Mirage 的 fps 影響未量，第 8 節的對照是驗收條件。
- 手機端 `VideoDecoder` 在 `http://` 上開放是 WebKit 的行為，未來版本可能改成要求 secure context；屆時要補 HTTPS。
- `-no-window`、Tailscale 中繼、Wi-Fi 干擾都會改變延遲，第 8 節的人工量測要記錄網路路徑。
