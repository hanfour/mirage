# 驗收線 2：輸入延遲分段量測，只判 Mirage 可控的三段

- 日期：2026-09-07
- 狀態：任務簡報（交 codex 實作，PM 把關）
- 分支：`acceptance-2-input-latency`
- 相關：母計畫 §7 驗收線 2（輸入延遲 < 80ms）、`docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §12、D60、D64

## 1. 背景

驗收線 2 上一次的記載是「約 110 到 119ms，不通過」，其中「送出觸控到幀抵達」78.1ms 佔三分之二，結論是「瓶頸在 emulator 到 Mirage 之間，不在渲染」。

2026-09-07 的探測推翻了那個數字的量測方式，三個問題各自足以讓結論失效：

1. 偵測器在噪音底附近判定。舊工具用 60×60 區域平均、門檻 8.0，而 `show_touches` 圓點在這台機器上只讓區域平均動 2 到 7.6，噪音底 0.56。
2. `misses=9/50`（18%）被排除在統計外，逾時樣本的真實延遲只會更長，所以 p50 與 p95 都是樂觀值。
3. `show_touches` 是漸入動畫。同一批樣本只改門檻，「ack 到幀產生」從 38.3ms 變成 206.3ms：

   | 門檻（差異像素數） | 50 | 200 | 500 | 1000 |
   | --- | --- | --- | --- | --- |
   | ack 到幀產生 p50 | 38.3ms | 45.0ms | 104.2ms | 206.3ms |

   換 `pointer_location` 一樣敏感（54.8 到 266.9ms），改用遊戲分頁切換則 16 次有 7 到 15 次抓不到。

修好偵測器（差異像素數判準、單調序號游標）後在 Pixel Flow 主選單量到（Python 直連，n=40，misses=0）：

| 段落 | p50 | p95 |
| --- | --- | --- |
| 送出到 ack（gRPC 注入往返） | 1.8ms | 8.6ms |
| ack 到幀產生（guest 反應與合成） | 95.4ms | 154.7ms |
| 幀產生到抵達（擷取、編碼、傳輸） | 11.8ms | 19.3ms |
| 合計 | 110.3ms | 170.1ms |

佔了 86% 的「ack 到幀產生」目前沒有可信的尺可量，所有現成的視覺回饋都是漸入的。

## 2. 已定的產品決策

驗收線 2 只判 Mirage 可控的三段，判到 present 為止：

1. 輸入注入段：使用者事件進入 `InputQueue` 到 `sendTouch` 回來。
2. 傳輸段：emulator 產生幀到幀抵達 Mirage。
3. 渲染段：幀抵達到 present。

guest 反應段歸 emulator 側，與 D60 同一個處理方式：Mirage 只能偵測告知，不列入判定。present 到 Mac 上屏那 8 到 17ms 從此不計入合計，另記為已知未量項（實測需要高速攝影機，這台機器做不到）。

## 3. 目標（一句話）

讓上述三段各自有可重複的量測與硬斷言，並在真實條件下判定三段合計是否低於 80ms。

## 4. 可用的關鍵事實（已實測，不要重新推導）

- `Android_Emulation_Control_Image` 有 `timestampUs` 欄位，是 emulator 估計此幀產生的時刻，單位微秒。它與主機的 Unix 時鐘可比：`抵達時刻 - timestampUs` 在 200 幀窗口上 min 8.5ms、p50 12.8ms、p95 18.9ms、max 31.2ms，全正值，`seq` 連續無斷。
- `Image.seq` 是單調遞增的幀序號，可用來偵測丟幀。
- 串流影像是由上而下排列。proto 註解寫 "from left to right and bottom up"，與實際不符，照註解做上下翻轉會取樣到鏡射位置。
- `streamScreenshot` 在 540×1200、Pixel Flow 主選單上約 42 fps，`timestampUs` 相鄰間隔 p50 19.8ms、p95 37.2ms、max 81.5ms。幀產生的節奏本身在抖。
- 輸入路徑：`MirrorView.mouseDown` 到 `InputQueue.tap(nx:ny:down:)` 到 `EmulatorClient.sendTap`，所以用 `osascript` 點 Mirage 視窗就是真實路徑。

## 5. 範圍

### A. `MirageCore`：幀帶上傳輸段的耗時

- `Frame` 加 `public let transitMs: Double?`，預設 nil，不參與 `Equatable`（理由與 `receivedAt` 相同，既有測試比對幀內容不該因此失敗）。
- 在 `GrpcStreamTransport.frames` 建構 `Frame` 時計算：`Date().timeIntervalSince1970 * 1000 - Double(img.timestampUs) / 1000`。
- 這個減法只在這裡做一次。`receivedAt` 是 `ContinuousClock`（單調），`timestampUs` 是 Unix 牆鐘，兩個時鐘不能在下游被再次相減。doc comment 要寫明這一點。
- `MmapStreamTransport` 沒有這個欄位可用，傳 nil。log 要能分辨「這條路徑量不到」與「量到 0」。
- 牆鐘可能被校時跳動。`transitMs` 為負值時視為無效樣本，計數但不進統計。

### B. `MirageShell`：`MIRAGE_LATENCY_LOG` 多印傳輸段

- `Renderer.recordLatency` 既有的 `[app] lat p50=..ms p95=..ms n=..` 一個字都不改（`verify_fps_fullscreen.sh` 的 `latency_median` 在解析它）。
- 同一秒窗口背靠背多印一行：`[app] transit p50=..ms p95=..ms n=.. invalid=.. unavailable=..`。`invalid` 是負值樣本數，`unavailable` 是 `transitMs` 為 nil 的樣本數。
- 統計沿用 `LatencyWindow`。

### C. `MirageCore`：輸入注入段的量測

- `InputQueue` 的 `Command` 各 case 帶一個 `ContinuousClock.Instant`，在 `yield` 前取得。消費者 `await injector.send*` 回來後記錄耗時。
- 由 `MIRAGE_INPUT_LATENCY=1` 開啟，未開時不記錄、不印、行為與現在完全相同。
- 每秒印一行 `[app] inject p50=..ms p95=..ms n=..`。沒有樣本的那一秒不印，不要印 0。
- 這一段量的是「事件進入佇列到 RPC 回來」，包含佇列排隊與 actor 跳躍。`MirrorView` 的 AppKit 事件處理不在內，doc comment 要寫明。

### D. `app/scripts/verify_input_latency.sh`

比照 `verify_fps_fullscreen.sh` 的結構，沿用 `verify_common.sh`、`gui_session.sh` 的既有共用函式（`build_warm`、`load_gate`、`gui_session_start`、`gui_session_fullscreen`、`tagged_median`、`latency_median`），不要各寫一份。

- 進全螢幕，與驗收線 7 同條件，讓三段的數字可以和既有 fps 結果並排讀。
- 每輪 20 秒，輪次前建置一次（`MIRAGE_SKIP_BUILD=1`）。預設三輪，`-r` 可調。
- 量測窗口內用 `osascript` 每 500ms 對 Mirage 視窗送一次點擊，座標固定在畫面上不會改變遊戲狀態的位置（主選單背景，不要打到 Play 或底部分頁）。每輪約 40 次。
- 逐輪印一行：`[round N] inject_p50= transit_p50= render_p50= sum_p50= inject_n= transit_n= invalid= unavailable=`。
- 摘要印中位數與跨度：`INJECT_MEDIAN=`、`TRANSIT_MEDIAN=`、`RENDER_MEDIAN=`、`SUM_MEDIAN=`、`SUM_RANGE=`。
- 硬斷言（任一條不成立就退出碼非 0 並明講哪一條）：
  1. 每輪 `inject_n` 至少 30，否則點擊沒送到，這一輪無效。
  2. 每輪 `transit_n` 至少 600（20 秒、30fps 以上），否則沒在收幀。
  3. `invalid` 必須為 0。出現負值代表時鐘假設不成立，整份數字作廢。
  4. `unavailable` 必須為 0。出現代表跑在 MMAP 路徑上，這條路徑量不到傳輸段。
  5. 前置負載閘門，非工作負載 CPU 總和低於 50%。
  6. `SUM_MEDIAN` 低於 80 才算通過，否則判定未通過並印出是哪一段佔最多。
- 每條斷言都要故障注入證明會紅，做法與 `verify_transport_compare.sh` 一致。

### E. `phase0/harness/e2e_latency.py`：修到可用，但不用於判定

現況是壞的：`TARGET` 寫死 `localhost:8554`、座標寫死、判準抓不到訊號、`misses` 被靜默排除。它是 repo 裡唯一的輸入延遲工具，留著不修會被引用。

- 檔頭寫明：這支量的是 emulator 側，對偵測門檻敏感，不用於驗收線 2 的判定。
- 參數化 target、串流尺寸、觸控座標、樣本數、門檻。
- 判準改成差異像素數（區域內任一通道差異大於 30 的像素數），並在輸出印門檻敏感度：同一批樣本用門檻 ×0.25 與 ×4 各算一次 p50，兩者差距超過 20% 就在輸出標示「這個數字由門檻決定，不可引用」。
- 輸出四段：送出到 ack、ack 到幀產生（用 `timestampUs`）、幀產生到抵達、合計。`misses` 一律印出，且不得從 p50 與 p95 的計算中悄悄消失，輸出要標明統計不含 misses。
- 掃描抵達幀時用單調遞增的序號當游標。用 `len(deque)` 當游標在 `maxlen` 填滿後長度恆為上限，游標不再前進，偵測從此永遠落空且不報錯。這個錯誤在探測時實際發生過，40 次裡 21 次被誤記成 miss。
- 影像不要做上下翻轉（見第 4 節）。

### F. 測試

- `Frame` 的 `transitMs` 不參與 `Equatable`：兩幀內容相同、`transitMs` 不同，`==` 為 true。
- 既有 `LatestFrameBoxTests`、`FramePumpTests`、`FrameQueueTests`、`EmulatorClientReconnectTests` 一個字都不改，必須照常通過。
- `InputQueue` 的順序保證（D6）不能被改動破壞：既有測試照常通過，另加一條驗證開啟量測後順序不變。
- 負值 `transitMs` 被計入 `invalid` 而不進統計的純函式測試。
- `verify_common_selftest.sh` 或對應的自我測試加上新輸出行的解析案例（`[app] transit ...`、`[app] inject ...`）。
- `ci.sh` 閘門 7 的自我測試清單要涵蓋新增的解析函式。

### G. `app/RESULTS-input-latency.md`

只寫量到的與看到的。至少包含：探測結果與舊數字的差異、三段的逐輪數字與中位數跨度、故障注入的每一條證據（指令與紅的輸出）、判定通過與否、以及未量項（guest 反應段、present 到上屏）。

## 6. 禁區

- `[app] fps=` 與 `[app] frames` 必須背靠背、一對一，不能在中間插入新行。`verify_fps_fullscreen.sh` 以 `fps_samples` 的數量當作跳過數。
- `[app] lat` 的既有格式不動。
- `recordLatency`、`LatestFrameBox`、`FrameQueue`、`FramePump` 的行為不動。
- 三個環境變數預設全關，關閉時行為與現在逐位元組相同。
- 不要改 `verify_fps_fullscreen.sh` 的既有判定與退出碼。
- 不要動系統的 protobuf 環境，harness 一律用 `phase0/harness/.venv-d45/bin/python`。
- guest 的 `show_touches`、`pointer_location` 若在量測中開啟，結束時必須關回去。

## 7. 已知會踩的坑

- `swift build` 不是冪等的，成功一次不保證下次 no-op。輪次前建置一次，不要讓建置落進量測窗口。
- macOS 的螢幕自動鎖定會讓超過 5 分鐘的活體量測中途作廢。`gui_session_start` 已有前置檢查。
- zsh 沒有 `PIPESTATUS[0]`，腳本內用 bash 3.2 驗證。
- 裸變數緊接全形標點（`$rc，`）在 `set -u` 下會炸成未綁定變數，`ci.sh` 閘門 4 會擋。
- `#expect` 拿 Bool 跟 `true`／`false` 比永遠不紅，`ci.sh` 閘門 5 會擋。
- 同條件重跑之間的變異可達 20ms，n=20 不足以判定。每個條件至少 40 個樣本、至少三輪。

## 8. 驗收條件

1. `app/scripts/ci.sh` 九道閘門全綠。
2. `verify_input_latency.sh` 六條斷言各自故障注入證明會紅。
3. 三輪活體量測完成，逐輪數字與中位數跨度寫進 `app/RESULTS-input-latency.md`。
4. 三個環境變數關閉時，`verify_fps_fullscreen.sh` 的輸出與判定與合併前相同。
5. 報告只寫量到的與看到的。自稱做了什麼不算證據。
