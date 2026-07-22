# Phase 0b 顯示傳輸備援驗證結果（日期：2026-07-22）

環境：與 Phase 0 相同——MacBook Air (M1, 16GB RAM) / macOS 26.3.1 / 映像 android-35 default
arm64。Host load 於量測期間全程落在 **32–77**（`task-1-report.md` 記錄 32.63–51.93；
`final-fix-report.md` 記錄 76–77；`task-5-report.md` 各次量測前後記錄 42.18–61.61，但該
報告自我審查段落另有「42–115」的敘述性說法，與其自身逐字引用的 `uptime` 數字不符——此為
**task-5-report 內部不一致**，本檔案採各次量測**逐字引用**的 `uptime` 輸出為準，「32–77」
為全程（Phase 0 + Phase 0b）觀測到的最寬區間，全數據標記 **contaminated 風險**，非乾淨基準
環境下的量測。

**環境 drift（必記）**：Task 1、Task 5 的量測均在穩定版 emulator **36.6.11.0** 上完成。
MMAP 深度診斷（主 session，Task 1 完成後）後段換裝 **canary 37.2.1.0**（本 session 以
`sdkmanager --channel=3` 安裝，**未還原**）——canary 版的診斷結果與穩定版**不可直接互換
比較**，兩者分開列示於下方對照表與判定中。

前情：Phase 0 判 gRPC 原始畫格 NO-GO（native ~29-30fps，e2e p95+17ms 邊緣超標 ~82ms）。本
驗證依計畫比較 MMAP 共享記憶體與 H.264 編碼串流兩條備援傳輸。

## 對照表（不含上屏；e2e 為 p50+17ms 換算）

| 傳輸 | fps（native, 持續動畫） | e2e p50+17ms | e2e p95+17ms | 客戶端 CPU | 備註 |
|---|---|---|---|---|---|
| gRPC 原始畫格（Phase 0 基線） | ~29-30fps ❌ | 68-74ms ✅ | ~82ms ❌ | Release ~15% | 每幀約 10MiB 序列化 |
| **MMAP 共享記憶體**（穩定版 36.6.11.0） | 無法量測 ❌ — 請求即崩潰（SIGSEGV exit139 ×2、SIGABRT exit134 ×1，file:///與shm名稱皆試，3/3 確定性重現，零幀送達） | 無法量測 | 無法量測 | N/A | Task 2-4 SKIPPED（依計畫應變條款，軌判死） |
| **MMAP 共享記憶體**（canary 37.2.1.0，主session深度診斷） | 無法量測 ❌ — 不崩潰、通知流動（payload=0、尺寸正確）但 host 寫入端靜默 no-op，像素恆零（三種 handle 變體、lsof 證實 qemu 從未開啟 handle） | 無法量測 | 無法量測 | N/A | 環境 drift；非正式任務步驟，屬事後診斷 |
| **MMAP 共享記憶體**（Swift Release，終裁） | 未執行 | — | — | 未執行 | 依賴 Python 軌先過關才會執行；Task 2-4 SKIPPED 故未達此步 |
| 編碼 H.264（screenrecord+PyAV，WebRTC 等效） | 0.6fps ❌（真實內容變化對照實驗；`fps=311.2` 為 PyAV 解碼批次假象，已識破且不採信） | 無法量測 ❌ — baseline 收集在 70 秒捕捉視窗內湊不齊 10 幀，`StopIteration`→crash | 無法量測 | 未量測 | 原生解析度 `--output-format=h264` 輸出恆 0 bytes；`--size 720x1600` 為授權最小修正後才有輸出 |

閘門：fps ≥60 穩定；e2e p50+17 < 80ms（上限）/ 50ms（理想）。

## MMAP 探測結論（Task 1 + 主 session 深度診斷）

- **payload_bytes**：
  - 穩定版 36.6.11.0：無法判定——`streamScreenshot`（MMAP transport）RPC 發出後 emulator
    引擎於同一時間窗內崩潰（`qemu-system-aarch64-headless` corpse / SIGSEGV exit139 /
    SIGABRT exit134），零幀送達，3/3 確定性重現（含 2/2 SIGSEGV 於 `file:///` 長路徑
    handle、1 次 SIGABRT 於 `/mirage_frames` POSIX shm 名稱 handle）
  - canary 37.2.1.0：**payload_bytes = 0**（通知確有流動，`reported = 1080x2400` 正確，
    與探測時的已知 guest 解析度一致）——資料在協定層面確實走 mmap 通道而非 gRPC payload
- **emulator 是否自建/接受既有檔案**：canary 版**形式上接受**——長路徑 `file:///`、短路徑
  `file:///tmp/mirage_f.bin`、POSIX shm 名稱 `mirage_shm` 三種 handle 變體皆未被拒絕
  （無 `INVALID_ARGUMENT`（推論：通知既已流動，該請求不可能被拒）），但**決定性反證**：串流進行中執行 `lsof -p <qemu_pid>` 顯示
  qemu **從未開啟**任一 handle 對應的檔案、亦無任何 PSXSHM 物件——形式接受、實際從未寫入。
  穩定版則因請求即崩潰，連「形式接受」都無法驗證。
- **tearing 觀察**：N/A——canary 版三種 handle 變體下 mmap 內容恆為全零（md5 恆同，
  `21c998afc567...` = 全零 10,368,000 bytes，等於 1080×2400×4 RGBA 幀大小；inode 假說已
  否決，即每幀重新開檔但 inode 不變、內容仍全零），無真實像素可供觀察 tearing；穩定版零
  幀送達，同樣無法觀察。

## 判定

- [ ] **MMAP 為 Phase 1 顯示路徑**：條件——fps ≥60 且 e2e 達標 → **未達成**：穩定版請求即
      崩潰（不 fork 前提下不可用）；canary 版通知面已通但 host 寫入端靜默 no-op，兩者皆
      無法產生一幀真實像素資料。
- [ ] **編碼路徑為 Phase 1 顯示路徑**：條件——MMAP 不可用/不達標且 H.264 達標 →
      **未達成**：MMAP 確已不可用（滿足前提），但 H.264 路徑本身亦不達標——真實內容變化
      對照實驗量到僅 0.6fps，e2e 模式在方法論層面直接失敗（70 秒捕捉視窗內湊不齊 10 幀
      baseline）。
- [x] **兩者皆不達標** → 啟動計畫外備援，Phase 1 顯示路徑延後，**回報決策者裁決**（見下方
      「Phase 1 顯示路徑決策選項」，本檔案僅列出選項、不代為選擇）。

## Phase 1 顯示路徑決策選項（列出，不代為選擇）

1. **fork + 補 MMAP host 寫入端**：成本已重估為「小 patch」等級——canary 版通知面
   （notification path）已通，僅缺 host 端把 guest 畫面實際寫入 client 提供的 handle 這一
   步；patch 可回饋上游，符合 GPL 開源義務策略。風險：需自行維護 fork 直到上游合併。
2. **回報上游並追蹤**：精準 bug 報告素材已備（見下方附錄：macOS `ImageTransport.MMAP`
   寫入端 no-op / 穩定版 36.x 直接 SIGSEGV）。等待上游修復期間，用 gRPC 縮放串流
   （~42fps，Phase 0 量測值）出 MVP。風險：上游回應時程不可控。
3. **架構調整**：改用有視窗（non-headless）emulator + macOS ScreenCaptureKit 做 60fps
   視窗擷取。優點：不需 fork emulator 原始碼。風險：放棄現有 headless 架構假設，
   ScreenCaptureKit 路徑本 phase 未驗證，需自行驗證延遲與穩定性。
4. **接受 42fps**：直接以 gRPC 縮放串流（720p/540p，~42fps 平台，Phase 0 量測值）作為
   Phase 1 顯示路徑出 MVP。優點：零額外開發成本、架構不變。風險：已知體感「有點卡」
   （Phase 0 人工驗收於 ~29fps 時的定性結論，42fps 下預期改善但仍低於 60fps 目標）。

## 觀察與備註

### MMAP 兩版本行為對比是本次驗證最重要的發現
穩定版與 canary 版呈現兩種截然不同、但同樣致命的失敗模式：穩定版是「協定層面就讓 host
崩潰」（更嚴重、更危險——會直接終止整個 emulator 行程），canary 版是「協定層面看似成功
但實際上是個空殼」（通知準時抵達、尺寸正確回報，唯獨從未真的寫入一個位元組的畫面資料）。
這個對比本身就是精準的上游 bug 報告素材（見附錄），也是「fork 成本被重估為小 patch」判斷
的直接依據——canary 版證明協定/通知層已經work，缺的只是 host 端那一小段「開 handle、
memcpy 畫面進去」的實作。

### 編碼路徑：假象識破與方法論教訓
`--mode fps` 首次量測印出 `fps=311.2`，數字看似驚人達標，但深入追查（bytes 抵達時序 vs.
PyAV 解幀時序的交叉比對）確認這是 FFmpeg/PyAV 對無容器索引的 raw H.264 Annex-B stream 做
`avformat_find_stream_info` 探測時的批次吐幀假象——真實幀全部擠壓在串流結束前的幾十毫秒內
一次噴出，量到的是「解碼器 batching」而非「編碼路徑真實吞吐」。真實吞吐透過對照實驗
（Settings 清單真實捲動內容變化 + `screenrecord --time-limit 12`）量得 **0.6fps**，確認
編碼路徑在 headless emulator + AOSP default 映像上不可用，非量測假象或方法論疏漏。

### Host load 全程偏高，數據需標記 contaminated
本次驗證全程（Phase 0 延續至 Phase 0b）host load average 落在 32–77 之間，多次遠超過內部
「~30 為乾淨基準」的指引門檻。已知會被 host load 影響的量測（fps 絕對值、e2e 延遲）本身
在 Task 1（MMAP 崩潰）與 Task 5（編碼路徑不可用）中都是**結構性、非負載相關**的失敗——
MMAP 崩潰行為在低負載時間點（探測時 33–40）與高負載時間點一致重現；編碼路徑的 batching
假象與真實 0.6fps 也在不同負載區間重現。因此「host load 偏高」削弱的是本檔案任何殘存
fps/延遲**數值**的精確度，但不影響「MMAP 軌死、編碼軌死」這個**質性判定**的可信度。

### 環境 drift 的後續影響
Canary 37.2.1.0 是本 session 為了排查 MMAP 崩潰根因而臨時安裝的，**未還原**回穩定版
36.6.11.0。這代表：(a) 若之後在同一台機器上重跑 Phase 0 或 Phase 0b 的任何腳本，
emulator 版本已經與本檔案「Phase 0 基線」「Task 1/5」量測時不同，重跑前務必先確認/還原
版本，否則數字不可比較；(b) canary 版的行為（不崩潰但寫入端 no-op）尚未經過 Task 1 那種
2-3 次獨立重現驗證的嚴謹程度（僅一輪深度診斷),嚴格說屬於「初步但證據鏈完整」而非「像
穩定版崩潰那樣的高信心確定性重現」。

### `probe_mmap.py` 執行風險（README 已加註警告）
`probe_mmap.py` 在穩定版 emulator 36.6.11.0 上執行會直接觸發 emulator 引擎 SIGSEGV/SIGABRT
崩潰（3/3 確定性重現），且崩潰後 emulator 行程消失、無自動復原機制。任何人在穩定版環境下
重新執行此腳本前，必須先接受「emulator 需要手動重啟」的代價；`phase0/README.md` 已在
Phase 0b 一節加註此警告。

---

## 附錄：上游 bug 報告素材

供回報 Android Emulator 專案（或內部 issue tracker）使用，證據鏈全部可溯源至
`task-1-report.md`、`mmap-canary-diagnostic.md`。

**標題（建議）**：`ImageTransport.MMAP` on macOS: stable channel crashes the engine on
first request; canary delivers empty notifications but never writes the client handle

**版本**：
- 穩定版：emulator 36.6.11.0（36.6.11-15507667），映像 android-35 default arm64
- Canary（後續診斷用）：emulator 37.2.1.0，透過 `sdkmanager --channel=3` 安裝
- Host：macOS 26.3.1，Apple Silicon (M1)

**穩定版重現步驟**：
1. 啟動 headless emulator（`-gpu host -grpc 8554`），確認 gRPC 可連通、`hw.lcd.width/height
   = 1080/2400`
2. 背景執行動畫來源（持續 `sendTouch` 或等效內容變化）
3. 以 `streamScreenshot` 呼叫 `ImageFormat.transport = MMAP`，`handle` 分別嘗試：
   - `file:///` + 絕對路徑（長路徑）
   - POSIX shm 名稱（如 `/mirage_frames`）
4. 觀察結果：RPC 於數秒至數十秒內回傳 `UNAVAILABLE: Stream removed (Socket closed)`；
   `qemu-system-aarch64-headless` 行程同時消失；macOS 統一日誌 (`log show`) 於同一秒顯示
   `kernel: qemu-system-aarch64-headless[pid] Corpse allowed`
5. 確定性：3/3（2× `file:///` 長路徑 → exit 139 SIGSEGV；1× shm 名稱 → exit 134 SIGABRT）

**Canary 重現步驟與證據**：
1. 同上啟動流程，改用 37.2.1.0
2. 同一 `streamScreenshot` + MMAP 呼叫**不再崩潰**，`Image` 訊息正常抵達，
   `image` 欄位長度為 0（`payload_bytes=0`），`format.width/height` 正確回報 1080×2400
3. 讀取 handle 對應檔案內容：全為零位元組，`md5sum` 在動畫持續注入下跨多幀恆為同一值
   （`21c998afc567...`），檔案大小固定為 10,368,000 bytes（= 1080×2400×4）
4. 排除 inode 誤判假說：每幀重新以相同路徑開檔，`stat` 確認 inode 不變，內容仍全零
5. 換用短路徑 `file:///tmp/mirage_f.bin`、POSIX shm 名稱 `mirage_shm` 重試：同樣全零，或
   shm 物件根本查無（未被建立）
6. **決定性證據**：串流進行期間執行 `lsof -p <qemu_pid>`，輸出中**不含**任一 handle
   對應的檔案描述符或 PSXSHM 物件——證明 host 端從未開啟該 handle，寫入邏輯是靜默 no-op
   （並非權限問題、並非非同步延遲寫入）

**結論陳述（供上游 issue 直接引用）**：macOS 平台的 `ImageTransport.MMAP`——(a) 於穩定版
36.6.11.0 上，任何 `streamScreenshot` MMAP 請求會使 host 引擎行程崩潰（SIGSEGV/SIGABRT），
與 handle 格式（長路徑 file URI / POSIX shm 名稱）無關；(b) 於 canary 37.2.1.0 上崩潰已
修復，通知路徑（frame 尺寸/計數）運作正常，但 host 端從未實際開啟或寫入 client 提供的
handle——payload 恆為 0 位元組，功能等同未實作。
