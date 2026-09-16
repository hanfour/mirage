# 區域網路手機遙控：設計

- 日期：2026-09-12
- 狀態：A 到 D 已完成，E 部分完成（2026-09-14）
- 協定來源：`chore/remote-hardening` 的 `a9b28a5`（含 `client-stats` 與 keyframe 節流）；實測依 `app/RESULTS-remote-control.md` 第 1 到 8 節。
- 使用情境：手機放在 Mac 旁邊，當 Mirage 的觸控第二螢幕。Mac 上的 Mirage 視窗照常運作。
- 延遲預算：手機畫面落後 Mac 畫面 50ms 上下。

## 1. 已確認的事實

以下包含 spike 與正式實作在 iPhone（iOS 18.7、Safari 26.6.1）上的實測；延遲與 fps 列為 spike 數字，正式實作結果見第 8 節：

| 項目 | 結果 |
|---|---|
| `VideoDecoder` 在 `http://` 上是否可用 | 可用，`isSecureContext=false` 也開放。iPhone 不需要 HTTPS |
| H.264 baseline／high 解碼支援 | 都支援，硬體解碼 |
| 未改寫 SPS 時的解碼延遲 | 抵達到畫出 p50/p95 172/180 ms，解碼器囤 10 幀 |
| 改寫 SPS 注入 `max_num_reorder_frames=0` 後 | p50/p95 4/5 ms，囤 0 幀，解碼 60.8 fps，本地丟幀 0 |
| WebSocket 往返（經 Tailscale） | 24 到 27 ms |
| iOS Safari pointerId | 可為負數，實測 `-10102172`；伺服器接受完整 signed Int32 範圍 |
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
                                              │                     │ NotifyingFrameSink 通知後限速 takeLatest()
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
| `NotifyingFrameSink.swift` | 包住編碼用 box，新幀抵達時通知 controller，合併未消費通知 |
| `Remote/PairingToken.swift` | 一次性 token 產生（`randomSource` 注入）與常數時間比對 |
| `Remote/RemoteTouchMessage.swift` | 解碼觸控、導覽鍵、文字、ping 與 client-stats；驗證 JSON 欄位並夾取座標 |
| `Remote/RemoteTouchIdentifierAllocator.swift` | 手機 pointerId → 64 到 79 的配置與釋放，最多 10 指，超過拒絕 |
| `Remote/H264Nal.swift` | Annex-B 起始碼切分、存取單元打包、NAL 型別判斷 |
| `Remote/H264SpsRewriter.swift` | SPS 解析與 VUI bitstream_restriction 注入（`max_num_reorder_frames=0`、`max_dec_frame_buffering=max(1, num_ref_frames)`），含 emulation prevention 往返；冪等 |
| `Remote/RemoteSessionState.swift` | 單一手機連線的 reducer：等待配對 → 已連線 → 已斷線，比照 `ConnectionStateMachine` |
| `Remote/RemoteServer.swift` | NIOHTTP1＋NIOWebSocket：`GET /?t=<token>` 回 viewer 頁、`/ws/video`、`/ws/input` 升級時驗 token；只接受一組 video＋input 配對 |
| `Remote/RemoteServerCore.swift`、`Remote/RemoteServer+Connections.swift` | 配對、識別碼配置、輸入轉發、影像與統計送出、WebSocket 分片組裝及 keyframe 節流 |
| `Remote/RemoteLatencyWindow.swift` | 一秒窗口的 age／encode／send 百分位、transit 與新幀／心跳計數 |
| `Remote/RemoteVideoMessage.swift`、`Remote/RemoteVideoQueue.swift` | 13-byte 影像標頭與 GOP 背壓佇列 |
| `Resources/remote/viewer.html`、`Resources/remote/viewer-input.js` | 手機解碼顯示、觸控與文字輸入、重連及統計，隨 `Mirage_MirageCore.bundle` 打包 |

`Package.swift` 已宣告 `swift-nio` exact `2.101.3`，`MirageCore` 使用 `NIOCore`、`NIOPosix`、`NIOHTTP1`、`NIOWebSocket`。

### MirageShell（系統框架，活體驗證）

| 檔案 | 職責 |
|---|---|
| `Remote/RemoteMirrorController.swift` | 新幀事件驅動編碼、依拉取率上限合併通知、250 ms 心跳、封包與統計送出；觸控與按鍵交給 `InputQueue` |
| `Remote/RemoteVideoEncoder.swift` | 硬體 `VTCompressionSession`，RGBA → BGRA pixel buffer → Annex-B；尺寸變更重建並附新 SPS/PPS，PTS 使用幀時間 |
| `Remote/RGBAPixelBuffer.swift` | 使用 pixel buffer pool，將 RGBA 轉成 BGRA |
| `Remote/RemoteLaunchOptions.swift` | 解析腳本用啟動環境變數，錯值記錄後使用預設 |
| `Remote/HostAddresses.swift` | 列出配對網址可用的主機位址 |
| `Remote/QRCodeImage.swift` | 將配對網址轉成 QR 圖片 |
| `Lifecycle/RemoteMenu.swift` | 手機遙控選單、網址與 QR、連線品質及中斷操作 |
| `AppModel+Remote.swift` | 建立 sink、啟停 controller、配對輪替、文字提交及斷線後的 suspend |
| `Lifecycle/AppLifecycle.swift` | `windowShouldClose` 依 `hasActiveRemoteViewer` 決定是否 suspend |
| `Lifecycle/MenuBarController.swift` | 整合手機遙控子選單 |

編碼設定分為必要四項與可選五項。必要四項為建立 session 時要求硬體編碼器、`RealTime=true`、`AllowFrameReordering=false`、`ProfileLevel=H264_Baseline_AutoLevel`，任一失敗即中止，不退回軟體編碼。可選五項為 `MaxFrameDelayCount=0`、`PrioritizeEncodingSpeedOverQuality=true`、`MaxKeyFrameInterval=120`、`AverageBitRate=12000000`、`ExpectedFrameRate=30`；失敗只記錄在 `skippedProperties`。實測硬體不支援 `MaxFrameDelayCount`，回傳 `-12900`，不影響啟用。session 準備或編碼本身失敗仍回報錯誤。

啟動環境變數供腳本與 A/B 驗證使用：`MIRAGE_REMOTE=1` 自動開啟，`MIRAGE_REMOTE_PORT` 接受 1 到 65535（預設 8765），`MIRAGE_REMOTE_TOKEN` 接受 32 個小寫十六進位字元（未設或無效則隨機產生），`MIRAGE_REMOTE_PULL_FPS` 接受 5 到 60（預設 30）。拉取率是事件驅動編碼的上限，不是固定輪詢頻率。

## 4. 協定

### `/ws/video`

影像方向為 Mac → 手機，每則二進位訊息是一個存取單元，標頭共 13 bytes：

| 位移 | 長度 | 內容 |
|---|---|---|
| 0 | 8 | Mac monotonic 送出時間，UInt64 奈秒，big-endian |
| 8 | 4 | UInt32 幀序號，big-endian |
| 12 | 1 | 0 為一般幀，1 為 keyframe（含 SPS＋PPS＋IDR） |
| 13 | 其餘 | Annex-B 位元組 |

驗證要求總長度大於 13、旗標只能是 0 或 1、payload 以三或四 byte Annex-B 起始碼開始；viewer 另拒絕送出時間為 0。Mac 時間不可直接與手機 `performance.now()` 相減。此訊息型別未另訂 payload 大小上限。新連線要求 IDR，從帶 SPS/PPS 的 keyframe 開始送，不先單獨送參數集。手機從 SPS 算 codec 字串，不另送 config。影像佇列預設最多 3 幀，背壓時清掉佇列並丟到下一個 IDR、累計丟幀，不單獨跳過中間的 P-frame 後接續同一 GOP。

`stats` 方向為 Mac → 手機，JSON 文字格式為 `{"type":"stats","intervalMs":1000,"age":{"p50":6,"p95":15,"count":30},"encode":{"p50":7,"p95":9,"count":30},"send":{"p50":0.03,"p95":0.05,"count":30},"transitMs":10,"newFrames":30,"heartbeatFrames":0,"inputRPCsPerSecond":42,"inputCoalesced":82}`（數字僅示意）。每秒送一個窗口；`age`、`encode`、`send` 為毫秒百分位及樣本數，無有效樣本時省略，`transitMs` 同樣可省略；`intervalMs` 是實際窗口長度。`age` 與 transit 只計新幀，encode／send 只計成功產生存取單元的回呼，`send` 量至交給 server，非網路單程延遲。`inputRPCsPerSecond` 為實際 `sendTouches` 呼叫次數除以窗口秒數，`inputCoalesced` 為窗口內合併掉的 move 批次數。viewer 解析 JSON 並只採用 `type:"stats"`；沒有另設欄位數值上限。統計不進影像佇列，慢連線只保留最新一份。

`keyframe` 方向為手機 → Mac，是內容恰為 `keyframe` 的 8-byte 文字 frame，不是 JSON。只接受未分片的完整 frame（`fin=true`），其餘文字忽略。只有已配對的 video channel 可請求；距上次接受請求不足 500 ms 時忽略並增加 `keyframeRequestsThrottled`，剛好 500 ms 可接受，被拒請求不延後時間窗。viewer 在等待 IDR 時用 `keyframeRequested` 避免重複送出；此去重與伺服器的時間節流不同。

### `/ws/input`

以下訊息均由手機 → Mac，以 JSON 文字傳送；只有 `ping` 有 Mac → 手機 echo。整則文字含分片合計最多 65536 bytes，最後一片才解碼 UTF-8；拒絕 binary、非法分片與無效 UTF-8 並關閉該連線。JSON 必須為物件且 `type` 為字串，數字欄位不接受布林或數字字串；訊息欄位驗證失敗則整則丟棄、計數，每秒最多一行 log。

`touches` 是主要多點快照格式：`{"type":"touches","t":1234.5,"points":[{"id":-10102172,"phase":"down","x":0.49,"y":0.75},{"id":8,"phase":"move","x":0.65,"y":0.75}]}`。`t` 必填且為有限毫秒數；`points` 每則 1 到 10 點、id 不重複，每點遵守下列單點驗證。任一點格式或配置失敗，整批丟棄且不改識別碼狀態；合法批次一次交給 `onTouches`。viewer 每個 rAF 送有變化的手指，同一 id 的 down／up／cancel 依序分幀保留，背景以 16 ms timeout 兜底，up／cancel 成功送出才移除。消費端以約 16 ms 窗口將連續且識別碼集合相同的純 move 批次合併為最新一則，不跨越 down／up／cancel 或其他輸入。

`touch` 為單點相容格式：`{"type":"touch","phase":"down","t":1234.5,"id":-10102172,"x":0.49,"y":0.75}`，也接受舊格式 `type:"down|move|up|cancel"`。phase 只能為 `down`、`move`、`up`、`cancel`；id 必須為 signed Int32 整數（-2147483648 到 2147483647）。x、y 必須為有限數，伺服器夾到 0 到 1，原點在畫面內容區左上，不含 letterbox。單點 `t` 缺少或非有限數字時使用 0，與批次必填不同。識別碼配置到 64 到 79，但同時最多 10 指；未配置 id 只能以 down 開始，up／cancel 強制 `down:false` 並釋放。

`key` 格式為 `{"type":"key","key":"GoHome","t":1234.5}`，導覽三鍵白名單為 `GoBack`、`GoHome`、`AppSwitch`；實作另接受文字刪除用的 `Backspace`，其他 key 拒絕。`t` 必須為有限數字，只有 `Backspace` 可省略（預設 0）。一則訊息經 `InputQueue.key` 送 down 再 up，不提供任意按鍵或重複次數控制；大小受共同文字上限限制。

`text` 格式為 `{"type":"text","text":"Mirage remote 中文🙂 hello","t":1234.5}`。text 必須是非空字串，最多 4096 個 UTF-16 單元，與瀏覽器 `String.length` 一致；t 必填且為有限數字。經 `TextInputPresentation.enqueue`（`origin: "remote"`）使用與 Mac IME 相同的剪貼簿＋Paste 交易與互斥。

`ping` 格式為 `{"type":"ping","t":1234.5}`。伺服器只檢查 type，不驗證 t 或其他欄位，將原始文字完整 echo；viewer 每秒送出並用回傳 t 計算 RTT。沒有額外欄位上限，仍受 65536-byte 共同限制；這與 WebSocket 控制 frame 的 ping／pong 不同。

`client-stats` 格式為 `{"type":"client-stats","rtt":50,"dropped":0,"decodeFps":30}`。rtt 為毫秒，decodeFps 為每秒解碼數，兩者必填、有限且非負，無額外數值上限；dropped 必須是 0 到 9007199254740991 的整數，為頁面累計序號缺口加本地丟幀。三欄均拒絕布林、字串及負值，不要求 t。viewer 在取得有效 RTT 後每秒回報，供 Mac 選單顯示連線品質；伺服器不 echo，input 關閉時清掉最新值。

### `/ws/audio`

音訊方向為 Mac → 手機，每則二進位訊息是一批交錯樣本，標頭共 17 bytes：

| 位移 | 長度 | 內容 |
|---|---|---|
| 0 | 8 | Mac monotonic 送出時間，UInt64 奈秒，big-endian |
| 8 | 4 | UInt32 批次序號，big-endian |
| 12 | 4 | UInt32 取樣率，big-endian |
| 16 | 1 | 聲道數，只接受 1 或 2 |
| 17 | 其餘 | S16 little-endian 交錯樣本 |

取樣率與聲道寫進每一則而不是握手一次，是因為 emulator 的音訊格式在重連後可能不同，
而手機端要據此設定 `AudioContext`；每則自帶格式就不需要「格式變更」這個額外訊息型別。
內容用 S16 而不是 Float32：位元組少一半（48kHz 立體聲為 192 kB/s），瀏覽器端轉 Float32
是一個乘法。**不編碼成 AAC 或 Opus**：省下的頻寬換來編解碼延遲與一套 codec 協商，
而同一個 Wi-Fi 下 192 kB/s 不是瓶頸（影像本身就比這個大）。

驗證要求總長度大於 17、聲道為 1 或 2、取樣率介於 8000 與 48000、payload 長度為
`2 × 聲道數` 的整數倍且不為零；不符者整則丟棄並計數。guest 沒有出聲時 emulator 本來就
不送封包，所以靜音不佔頻寬，不另做靜音偵測。

音訊佇列預設最多 10 則（約 120 ms）。背壓時**丟最舊的**並累計 `audioDropped`：
音訊落後比丟一小段更難聽，且與影像不同，音訊沒有「等下一個 keyframe」這種恢復點。

`/ws/audio` 與 `/ws/input` 一樣必須依附已配對的 video session，不能單獨配對。

手機端以 `AudioWorklet` 播放，worklet 內是一個固定容量的環形緩衝，主執行緒把收到的
樣本寫進去。**蓄水門檻 100 ms**，與 Mac 端 `AudioRingBuffer` 相同理由：生產與消費速率
相等時穩態深度會是 0，每次 render 都補靜音。`AudioContext` 必須由使用者手勢啟動，
頁面本來就要點一下才開始，接在同一個手勢上。

頁面右上提供 🔊／🔇 切換，`?audio=0` 連 socket 都不開。統計列加一欄音訊緩衝深度與丟棄數。

### 手機頁面

以 `VideoDecoder`、`optimizeForLatency:true` 解碼，output 回呼 `drawImage` 後立刻 `close()`。設定 `touch-action:none`、`user-select:none`、`-webkit-touch-callout:none`、`overscroll-behavior:none`，攔截 `gesturestart`／`gesturechange`，可用時請求 screen wake lock；不用 iPhone 不支援的 Fullscreen API。

底部提供返回、主畫面、最近任務三鍵，`?nav=0` 隱藏導覽列；⌨︎ 開啟 iOS 文字輸入，Return 提交整串，空輸入框的 Backspace 送刪除按鍵，鍵盤彈出時依 `visualViewport` 縮畫面。統計顯示 fps、解碼佇列、抵達到畫出 p50/p95、RTT、丟幀與 Mac 分段延遲；點擊疊層可收合並存 localStorage，收合後仍顯示錯誤。`?stats=0` 隱藏統計，錯誤仍可見。

任一 socket 斷線或錯誤時，關閉舊配對並按 1／2／4 秒退避，自動重連最多三次；退避只計前景時間，video 握手成功才開 input，input 就緒且已畫出影像才視為健康。回前景時若任一 socket 未開啟或重試已用完，重置次數並立即重連。解碼錯誤會關閉舊解碼器、重建並請求 IDR；連續第三次錯誤即停止，須重新整理頁面，成功 output 會清除連續錯誤計數。連續 2 秒沒有影像 chunk 才 flush 解碼器並請求 keyframe；正常 250 ms 心跳不會觸發 flush。

## 5. 配對與安全

- 伺服器預設關閉，由選單列開啟。開啟時產生 128-bit 隨機 token，選單顯示 `http://<主機位址>:<埠>/?t=<token>` 與 QR。
- token 只在 `GET /` 與兩條 WebSocket 升級時驗證，同一時間只接受一組 video＋input 配對；重複 video 或 input 連線回 409。input 必須依附已建立的 video，否則回 409；video 關閉時 input 一併關閉、撤銷輸入資格並放開所有手指。關閉功能或中斷連線時 token 作廢，重新開啟產生新的。
- 監聽所有介面（使用者實際用 Tailscale 連，只綁 Wi-Fi 介面會擋掉這條路），安全性靠 token 而不是綁定位址。埠預設 8765，可設。
- 不做 HTTPS。理由見第 1 節。
- 輸入訊息由 `RemoteTouchMessageDecoder.decode` 驗證，規則與上限見第 4 節；不合法整則丟棄並計數。配對網址與 token 不印進 stdout，只由選單提供。

## 6. 生命週期

- 手機連著時關 Mac 視窗：不 suspend，畫面繼續串流（第 3 節的 guard）。
- 沒有手機連著：與現況相同。
- 手機斷線：沒有 video 時編碼器不拉取；若 Mac 視窗仍隱藏，走關視窗相同的 suspend 路徑。token 保留到使用者關閉功能或主動中斷，同一個網址可以重連。
- 編碼由新幀通知驅動，限速期間合併通知並只取最新幀；靜止畫面每 250 ms 重編最後一幀作心跳 P-frame，更新 PTS 避免重複或倒退。沒有快取幀時仍須等第一幀。心跳與間歇新幀不強制 IDR；IDR 只在 viewer 連上、明確請求、session 重建、GOP 到期四種情況產生。
- 串流尺寸隨 Mac 視窗變動：`EmulatorClient` 只有一組 `streamSize`，手機與 Mac 共用同一份幀。尺寸變更時重建編碼 session、下一則訊息帶新的 SPS/PPS，手機端 `configure` 一次。既有 300 ms 的 resize debounce 已足夠，不另加。

## 7. 錯誤處理

| 情況 | 行為 |
|---|---|
| 埠被佔用 | 選單顯示錯誤與埠號，功能維持關閉 |
| `VTCompressionSession` 建立失敗 | 選單顯示錯誤碼，功能關閉；不退回軟體編碼 |
| `MaxFrameDelayCount` 硬體不支援 | 回傳 `-12900`，只記入 `skippedProperties`；其他可選屬性失敗也只記錄 |
| 解碼器連續錯誤 | 前兩次關閉並重建解碼器、請求 IDR，第三次停止並提示重新整理；成功 output 清零 |
| 手機斷線 | 1／2／4 秒退避自動重連三次，只計前景時間；用完提示重新整理 |
| 手機回前景 | 任一 socket 未開啟或重試用完時，重置重試次數並立即重連 |
| 手機解碼器 `configure` 失敗 | 頁面顯示 codec 字串與錯誤，不重試 |
| token 錯誤 | HTTP 403，不透露是否有進行中的連線 |
| 觸控訊息格式錯誤 | 丟棄、計數、每秒最多印一行 log |
| 手機端 `decodeQueueSize` 超過 8 或 pending 超過 120 | reset 解碼器，丟到下一個 keyframe，計數 |

## 8. 驗證

- 單元測試：第 3 節 MirageCore 的每個檔案。`H264SpsRewriter` 用真實 SPS 當素材（VideoToolbox 產出的 baseline `27420032ab40220096f2e8`、high `27640032ac568044012de5d0`），驗改寫後欄位不變、冪等、含 emulation prevention byte 的往返。
- `RemoteServer` 用 `127.0.0.1:0` 起真實 socket 測配對、拒絕第二連線、訊息格式，不需模擬器。
- 活體：`app/scripts/verify_remote_mirror.sh` 先執行 `RemoteVideoEncoderLiveTests` 與 `RemoteInputLiveTests`，要求 passed 而非 skipped，再用 Python WebSocket 用戶端檢查 R1 到 R7。

| 項目 | 判定 |
|---|---|
| R1 | 60 秒內收到 keyframe |
| R2 | 幀序連續，`SEQ_GAPS == 0` |
| R3 | down／move／up 後 guest getevent 出現 `ABS_MT_TRACKING_ID`，且沒有 slot 卡在 down；使用負數 pointerId |
| R4 | `GoHome` 後前景為 HOME resolver 指定的 launcher |
| R5 | `AppSwitch` 在 guest evdev 出現 `KEY_APPSELECT` DOWN 與 UP，不以前景 activity 是否改變判定 |
| R6 | 遠端文字提交後，以設定搜尋欄位的新鮮 UI dump 精確回讀相等；測試字串為 `Mirage remote 中文🙂 hello` |
| R7 | 3 秒雙指縮放，兩 slot 均按下及放開、RPC ≤70/s、transit p50 <50 ms、後續 tap 在 500 ms 內到達；tap 時差使用同一 guest 時鐘 |

延遲驗證以各窗口 age p50／p95 的中位數判定，要求 p50 <12 ms、p95 <25 ms。結果文件記錄事件驅動、上限 60 時 age p50 約 6 ms，預設上限維持 30；本機分段 encode p50 約 7 ms、send 約 0.03 ms、transit 約 10 ms。iPhone 經 Tailscale 抵達到畫出 p50/p95 為 5/6 ms，首輪 RTT 47 到 57 ms，後續為 47 到 75 ms，不能代替同一 Wi-Fi 或 glass-to-glass 量測。

R1 到 R3 實測第一個 keyframe 0 秒，10 秒收到 280 幀、幀序缺口 0，其中 3 個 keyframe，觸控按放成立。R4 到 R6 通過。R7 實測 RPC 每秒 42 到 44、每秒合併 82 批、pinch 期間 transit 10.7 ms、兩 slot 放開，後續 tap 在 500 ms 內到達。

驗收線 7 的遙控開關對照使用 `verify_remote_fps.sh`，`GUEST_MIN=45`、每臂 3 輪×2 pass。Mirage 中位數關 46、開 46，符合「開 ≥ 關 − 3 fps」，但兩臂均未達絕對門檻 55 fps。

結果文件第 8 節的本機路徑對照（2026-09-14）使用 `verify_fps_fullscreen.sh`，兩版本各跑一次：

| 版本 | Mirage 逐輪 fps | 中位數 | guest fps |
|---|---|---|---|
| `9d72bdf`，遙控程式碼加入前 | 52、54、54、54、55 | 54 | 55.2 到 56.8 |
| `8e1438f`，遙控全部合併、功能關閉 | 51、52、53、54 | 52 | 51.8 到 57.9 |

差 2 fps，沒有證據顯示遙控程式碼拖慢本機路徑。兩版本均未達 55；同一天同一 build 曾量到 31 到 58，且外來 CPU 狀態不同（floor 0：對照版 84%、現版 33%），不能據此宣稱絕對門檻通過。

人工 glass-to-glass 驗收需第三台裝置同框拍 Mac 與手機畫面，目標 50 ms，並記錄網路路徑；目前未量。

## 9. 分階段交付

| 階段 | 內容 | 驗證與完成狀態 |
|---|---|---|
| A | NIO 宣告、幀扇出、H.264 打包與 SPS 改寫、token、輸入解碼、識別碼配置、配對狀態 | 2026-09-12 完成；單元測試、ci.sh |
| B | `RemoteServer`、手機頁面 | 2026-09-12 完成；loopback 整合測試 |
| C | `RemoteVideoEncoder` | 2026-09-12 完成；硬體活體測試驗 SPS VUI 與每幀一個存取單元 |
| D | controller、`AppModel+Remote`、選單、生命週期 guard | 2026-09-12 完成；活體與 fps 對照；R7 追加驗證於 2026-09-13 完成，本機版本對照於 2026-09-14 完成 |
| E | 人工驗收與延遲量測 | 部分完成：iPhone 實測畫面、點擊、滑動、雙指縮放、導覽鍵、打字、切背景後回前景重連；未完成：同一 Wi-Fi 延遲與 glass-to-glass |

## 10. 不做的事

- Android：需要 HTTPS，憑證發放與安裝在第一版之外。
- 手機獨立解析度：需要第二條 `streamScreenshot`，CPU 成本翻倍，與第 2 節第 3 點衝突。
- 多支手機同時連線。
- 鍵位映射套用到手機觸控：手機本身是觸控裝置，直接注入。

## 11. 風險

- 編碼器拉幀與 RGBA → `CVPixelBuffer` 拷貝每幀約 10 MB，30 fps 約 300 MB/s，對 Mirage 的 fps 影響未量，第 8 節的對照是驗收條件。
- 手機端 `VideoDecoder` 在 `http://` 上開放是 WebKit 的行為，未來版本可能改成要求 secure context；屆時要補 HTTPS。
- `-no-window`、Tailscale 中繼、Wi-Fi 干擾都會改變延遲，第 8 節的人工量測要記錄網路路徑。
