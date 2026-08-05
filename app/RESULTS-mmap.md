# Streaming MMAP Transport 驗收結果

- **日期**：2026-07-27
- **模擬器**：Android emulator canary，`localhost:8554`（共享資源，全程未殺／重啟／`loadSnapshot`），
  版本 `37.2.1.0`（`37.2.1-15875889`，`getStatus` 回報）
- **工具鏈**：Swift 6.2.3（swift-testing）、grpc-swift 1.27.5
- **執行**：subagent-driven（Task 1–8 implementer 逐關 + task-review + controller 根因排查）＋
  使用者裁決「預設改回 raw RGBA」＋本 Task 9 重新量測全部 7 條驗收線並寫驗收文件

## 一句話結論

計畫目標是「`streamScreenshot` 走共享記憶體、預設啟用」；基礎建設（Task 1–7）審查全部乾淨，
但 **Task 8 活體驗證揭露 `MmapStreamTransport` 在這台真模擬器上凍結**——收到一次真實寫入後，
映射區不再更新，且現有降級機制攔不住這個失敗模式。使用者裁決：**預設改回 raw RGBA，
MMAP 需 `MIRAGE_TRANSPORT=mmap` 環境變數主動選擇加入**，基礎建設保留供未來重新驗證。

---

## ⚠️ 2026-08-05 重驗（D39）：兩個結論被推翻

本文件下方「沒有含修正的 emulator build 可測」與「MMAP 幫不上 fps」兩節記載的結論，
在 2026-08-05 的重驗中**都被實測推翻**。原文全部保留（推翻的過程本身是證據），
但讀下面任何一節之前先讀這裡。

### 推翻一：凍結與 emulator 版本無關，「等新版」是錯的等待

原本的處置是「等含上游修正的 build 發布後重驗」。實測三個版本，**全部凍結**：

| emulator | channel | build | Swift(grpc-swift) | Python(grpcio) |
|---|---|---|---|---|
| 37.2.1.0 | canary | 15875889 | ❌ `frames=3 distinct=1` | ✅（2026-07-27 記錄） |
| 37.1.11.0 | stable（pin） | 15917651 | ❌ `frames=3 distinct=1` | ✅ `frames=30 distinct=30` |
| 37.2.3.0 | dev（最新） | 15982021 | ❌ `frames=3 distinct=1` | ✅ `frames=30 distinct=30` |

Python 對照是**同一台 emulator、同尺寸 540×1200、同樣把 handle 放 `$TMPDIR`、同樣先
`getStatus` 再 `streamScreenshot`**——唯一的變數是 client 實作。2026-07-27 的對照只在
37.2.1 上做過一次且是手工搭的；本次把它固化成 `phase0/harness/mmap_client_parity.py`，
並接進 `app/scripts/verify_mmap.sh` 當硬斷言。

**這件事其實本文件自己早就預告過**：下方「沒有含修正的 emulator build 可測」一節寫著
「上游修的 0×0 pre-borrow 與本階段觀察到的凍結**不是同一個現象**」。既然如此，等一個
修別的 bug 的 build，本來就沒有理由會解決這個凍結。這個等待前提從寫下的那天起就站不住，
只是沒人回頭質疑它——與 D32／D45 同型（「阻礙已消失／從未成立，但沒人回頭驗」）。

**因此**：`MmapStreamLiveTests` 與各處註解裡「等含修正的 emulator 發布後才應該轉綠」
的敘述全部作廢。要修這個缺陷，該查的是 grpc-swift 這條路徑，不是等上游。根因仍未鎖定
（2026-07-27 那三輪排查推翻的 8 個假設依然有效，本次沒有新增排除項）。

一個取樣上的坑，順帶記下來：重驗時 Python 對照第一次跑出 `frames=5 distinct=1`，看起來
像「Python 也凍結了」。實際是 5 幀在 60Hz 下只跨 **83ms**，而 `animate.py` 供應的畫面
變化率低於 60Hz——窗口內畫面本來就沒變。拉到 30 幀／525ms 後 `distinct=30`。
`MmapStreamLiveTests` 只取 3 幀（約 150ms）有同樣的偽陰性風險，見 D52。

### 推翻二：MMAP 對全螢幕解析度的 fps **有決定性幫助**

`memory` 與 `investigation.md` §11.2 記載「頻寬不是瓶頸，所以 MMAP 幫不上」。該結論是在
**540×1200** 下得出的，而 Phase-1 全螢幕實際跑在 **898×1996**（D45 實測收斂值）。
本次在同一台機器上用 `bench_mmap_vs_rgba.py` 重掃：

| 解析度 | raw RGBA fps | MMAP fps | 差 | raw 的 gRPC 吞吐 |
|---|---|---|---|---|
| 540×1200 | 59.5 | 59.8 | +0.3 | 147 MiB/s |
| **898×1996（全螢幕）** | **40.0** | **56.7** | **+16.7** | **273 MiB/s** |
| 1080×2400 | 29.0 | 58.0 | +29.0 | 287 MiB/s |

形狀很清楚：**raw RGBA 這條路徑的吞吐天花板在 270–290 MiB/s**。540×1200 只用到 147 MiB/s
所以不受限——這正是 §11.2 在那個解析度上看不到頻寬瓶頸的原因，它的觀察沒錯，錯的是把
「在 540×1200 上不是瓶頸」外推成「不是瓶頸」。一過天花板，fps 就隨解析度反比下降；
而 MMAP 在**每一個**解析度都維持 55–60 fps。

**這個模型可以直接對源驗算，而且三個點全中**——若 fps 真的只由「吞吐天花板 ÷ 幀大小」
決定，那用實測吞吐除以幀大小就該還原出實測 fps：

| 解析度 | 每幀 | 實測吞吐 ÷ 每幀 | 實測 fps | 跑滿 60fps 需要 |
|---|---|---|---|---|
| 540×1200 | 2.472 MiB | 147.2 ÷ 2.472 = **59.5** | 59.5 | 148 MiB/s（天花板之下，跑得滿）|
| 898×1996 | 6.837 MiB | 273.1 ÷ 6.837 = **39.9** | 40.0 | **410 MiB/s** |
| 1080×2400 | 9.888 MiB | 287.2 ÷ 9.888 = **29.0** | 29.0 | **593 MiB/s** |

所以更精確的講法不是「898×1996 需要 273 MiB/s」（273 是它**實際達到**的吞吐，不是需求），
而是：**全螢幕要跑滿 60fps 需要 410 MiB/s，而這條路徑最多給到 270–290**——差距是 1.4 倍，
不是差一點。540×1200 需要 148 MiB/s、實測 147.2，剛好貼著天花板下緣過關；這也解釋了為什麼
§11.2 在那個解析度上「降到 1/4 解析度 fps 幾乎不動」——它本來就已經在滿速，降下去自然沒有
更多可拿。**同一份數據換一個解析度就導出相反的結論，這是外推的代價。**

**這讓 MMAP 從「實驗性玩具」變成驗收線 7（fps ≥ 55）的關鍵路徑**：D48 記載全螢幕實測
中位數 43–51、門檻 55，而這裡量到同一條鏈路換成 MMAP 就有 56.7。

**但這組數字必須帶著它的限定讀**，理由與本文件驗收線 7 的但書完全相同：
1. 這是 **Python client（grpcio 直連）**量到的**這條鏈路的能力上限**，不是 `MirageCore`
   實際交付的收益——Swift 路徑目前凍結，一格都拿不到。
2. 內容是 `animate.py` 的人造動畫，不是真遊戲；guest 端的畫面產生速率可能不同。
3. 主機負載 load≈7，非安靜狀態。
4. raw 的 40.0 fps 與 D45 量到的 43–51 不是同一種量法／同一台 AVD／同一種內容，
   數量級相符但不可逐一對應。

換句話說：**這條鏈路在全螢幕上有約 +17 fps 的空間，MMAP 是取得它的已知手段，而我們
目前拿不到它。** 凍結根因從「等上游」變成「擋在驗收線 7 前面的東西」。

---

## 驗收線逐條裁決（spec §8）

| # | 驗收線 | 判定 | 實測 |
|---|---|---|---|
| 1 | `swift test` 全綠，既有 137 個 `@Test` 不回歸 | ✅ PASS | `swift test` → `Test run with 170 tests passed after 0.723 seconds.`（本次重新量測，單次跑完，無需 pkill 重試、無 NIO teardown 卡死）。137 → 170 的完整帳見下方「測試數變動說明」，無回歸 |
| 2 | 新增純函式與 `FallbackTransport` 測試通過；純函式逐行 100% | ✅ PASS | `./scripts/coverage.sh` 本次重新量測：`MmapSupport.swift`（含 `MmapVersionGate`／`MmapBlankProbe`／`DisplayTransportSelector`）**100.00%** line（41/41）；`FallbackTransport.swift` **100.00%** line（91/91）。`MmapBuffer.swift` 94.29%（35 行、2 未覆蓋，屬檔案 I/O 極端錯誤路徑非本驗收線範圍） |
| 3 | `swift build -c release` 零非-deprecation 警告 | ✅ PASS | 完整重建：`Build complete! (11.43s)`；對完整 log `grep -ci warning` 與 `grep -ci deprecat` **皆為 0**——零警告，連 deprecation 警告都沒有 |
| 4 | `coverage.sh` 的 `MirageCore` 段不低於 ~94% 基準 | ❌ **FAIL（如實記錄，屬預期後果，見下）** | 本次重新量測：`TOTAL` line **87.80%**（1238 行、151 未覆蓋），明顯低於 ~94% 基準。**根因非回歸**：`MmapStreamTransport.swift` 本次量到 **0.00%**（107 行全未覆蓋）——因為預設翻轉後該檔案是 opt-in 路徑，`coverage.sh` 沒有設定 `MIRAGE_TRANSPORT=mmap`，`MmapStreamLiveTests` 因三閘門缺一而 early return，一行產品程式碼都沒執行到。詳見下方「覆蓋率下降是預期的」一節 |
| 5 | 活體：`MIRAGE_LIVE_MMAP=1` 下 `MmapStreamTransport` 收到 ≥3 個**非零且互異**的幀 | ❌ **FAIL** | `./scripts/verify_mmap.sh`（本次重新量測，已加 `MIRAGE_TRANSPORT=mmap`）：`[mmap-live] frames=3 distinct=1`；`✘ Test realEmulatorWritesIntoMappedBuffer() failed ... Expectation failed: (Set(digests).count → 1) >= 2`。收到 3 幀、`isValid` 與 `!isBlank` 皆通過（非全零），但 3 幀內容逐位元組相同——**這正是凍結缺陷**，見下方「凍結缺陷」一節的完整交叉驗證 |
| 6 | 活體：跑完後 `/tmp` 無 `mirage_mmap_*` 殘留 | ⚠️ PASS（**檢查本身無驗證意義，見已知限制**） | `verify_mmap.sh` 輸出「殘留檔案數：0 / PASS」。但 `MmapSupport.handlePath` 用的 `NSTemporaryDirectory()` 在 macOS 實際回傳 `$TMPDIR`（`/var/folders/.../T/`），**不是** `/tmp`——這條檢查的 glob 恆對不到 Swift 實際建立的檔案，**恆為 PASS，不論 `close()`/`unlink` 有沒有真的生效**。此為 Task 8 已發現、本次複核仍然成立的既有缺陷，未修腳本（本任務範圍為文件）。**✅ 2026-08-05（D39）已修**：改掃 `$TMPDIR` 與 `/tmp` 兩處，glob 也不排除對照腳本自己建的檔。已故障注入證明會紅（放一個假的 `mirage_mmap_99999_1_540x1200.bin` 進 `$TMPDIR` → `exit 1` 並指出是哪個目錄哪個檔）。**修好之後第一次跑就抓到東西**——抓到的不是產品，是同一次新寫的 `mmap_client_parity.py` 漏了 5 個檔（`buf.close()` 在提早 break 時必然拋 `BufferError`，unlink 掛在它後面永遠不執行，已改成 finally 裡無條件 `os.unlink`）。Swift 那邊實測 0 個殘留，`close()` 的 unlink 一直是好的 |
| 7 | 收益複驗：client CPU/幀降幅 ≥80% | ⚠️ PASS（**範圍受限，非產品路徑證據**） | 引用 Task 8 Step 4 量測：`bench_mmap_vs_rgba.py`（900×2000）client CPU 4.04s→0.43s，**−89%**，達 ≥80% 門檻。**但這是 Python client 用 grpcio 直接發 RPC 量到的「這台主機 MMAP 能力上限」，完全不經過 `MirageCore.MmapStreamTransport`**——第 5 條驗收線已證明後者在活體環境下無法持續拿到新內容，因此 89% 降幅**不能**當作「Swift 產品路徑目前實際交付這個收益」的證據，兩者是不同的問題 |

**裁決摘要**：PASS 5（#1、#2、#3、#6 帶但書、#7 帶但書）／FAIL 2（#4、#5）。**FAIL 的 #5 是本階段最關鍵的發現**：MMAP 之所以預設關閉，正是因為這條驗收線量不過。

---

## 凍結缺陷（Critical，決定本階段最終處置的核心事實）

`MmapStreamTransport` 在 emulator canary 37.2.1.0 上**只完成一次真實寫入，之後映射區凍結**。
Swift client 讀到 3 幀（另有一次拉到 30 幀、跨 480ms、通知以近 60Hz 規律到達）內容逐位元組
完全相同。**同一時刻、同尺寸（540×1200）、同協定的 Python client（grpcio）完全正常**：5 幀
相異、相隔約 15ms、80ms 內到齊。

### 現有降級機制攔不住它

`FallbackTransport`／`MmapBlankProbe` 只認「前 3 幀皆全零」。但凍結的幀**不是全零**——黑色
像素的 RGBA 是 `00 00 00 FF`，不是 `00 00 00 00`，會直接通過探測。淨效果：使用者會看到一張
永遠凍結的畫面，**沒有降級、沒有任何錯誤訊號**，比黑畫面更糟，因為完全無聲無息、不會有人
主動回報。

### 三輪排查推翻的假設（8 個以上）

| 假設 | 排除方法 |
|---|---|
| protobuf 編碼有誤 | 逐欄位手動解碼 wire bytes，Swift 與 Python 送出的請求語意完全等價（format/width/height/channel/handle 五個欄位一一對應） |
| 暖機不足 / 時序競態 | 30 幀跨 480ms、近 60Hz 規律到達仍全同；warm-up 拉到 60 秒仍凍結 |
| 執行緒饑餓 | `GrpcChannelBox` 的 `numberOfThreads` 1→4 無變化 |
| 檔案建立語意 | 把 Python 參考實作改成模仿 Swift 的「mmap 後保留 fd」「加 `O_TRUNC`」「兩者都做」，四種變體全部正常（`phase0/harness/diag_fd_variable.py`） |
| gRPC API 選擇 | 改用便利方法 `streamScreenshot(_:)`（與 Python 同風格）仍凍結 |
| 讀取端快取 | 用 `lsof` 找出實際映射檔路徑後，從行程**外部**直接用 bash `md5`/`xxd` 讀磁碟位元組，仍證實凍結——排除 Swift 端讀取快取 |
| 畫面尺寸 | Python 在同一 540×1200 尺寸下正常 |
| guest 動畫未跑 | `adb exec-out screencap` 連續兩次比對 md5 確認畫面確實在變動，Swift 仍凍結 |

收斂到「emulator 對 grpc-swift 連線與 grpcio 連線行為不同」，**根因未鎖定**——已用完本階段
範圍內合理的診斷手段（交換呼叫風格、繞過 Swift 讀取端、切換前景畫面、拉長 warm-up 與取樣
窗口，結果一致）。完整排查記錄（含逐次實驗的原始輸出）在
`.superpowers/sdd/2026-07-27-mmap-stream-transport/mmap-freeze-investigation.md`
與 `task-8-report.md`（該 sdd 目錄不進版控，關鍵結論摘要於此）。

---

## 沒有含修正的 emulator build 可測

Google 於 2026-07-25 將上游 issue（b/537802959）標記為 fixed，根因是 `streamScreenshot`
開頭用 `request->width() * request->height()` pre-borrow 共享記憶體，該值在請求裝置原生
尺寸時為 0，毒化 cache。但這與本階段觀察到的凍結不是同一個現象——Mirage 從一開始就帶明確
尺寸，理論上不會踩到那個 bug；凍結是三輪排查後仍未定位的**另一個**問題。

查 `repository2-3.xml`，aarch64 可用的 emulator 只有三個：**37.2.1（canary，build 15875889，
就是本階段全程使用的版本）**、37.1.10（beta，更舊）、36.6.11（stable，收到 MMAP 會 SIGSEGV）。
**含修正的 build 尚未發布**，因此「升級後再測」目前不可行——即使願意，也沒有更新的 build
可以驗證凍結是否已隨上游修正一併解決。

---

## 一個必須明白寫出的立論缺陷（協調者的自我更正）

`docs/specs/2026-07-27-mmap-stream-transport-design.md` §1 與
`docs/upstream/2026-07-22-emulator-mmap-macos.md` 都寫著「**實測確認現有 emulator 版本
即可繞過**」。**那個結論只對 Python client 成立，對產品實際的 Swift client 不成立**。

當初的驗證邏輯是：Phase-0 用「不帶 width/height」的請求形狀探測，判定「MMAP 壞了」；
2026-07-27 對照實驗證明「明確帶尺寸即可繞過」，而 Mirage 的 `GrpcStreamTransport` 一直都
帶明確尺寸——據此推論「現有版本就能走 MMAP 串流」。**但這個推論全程只用 Python
（grpcio）驗證過，從未用產品實際會用的 grpc-swift client 驗證**。等到 Task 8 真的用
`MmapStreamTransport`（grpc-swift）連線，才發現同一時刻 Python 正常、Swift 凍結——兩者在
同一個 emulator 版本下行為不對稱。

這是「現在就做 MMAP」這個決策的立論基礎之一，而它建立在一個**未經產品 client 驗證**的
結論上。`docs/upstream/2026-07-22-emulator-mmap-macos.md` 已加「後續更正」小節記錄此事
（保留原文，見該文件），本文件在此正式記錄同一件事，作為本階段方法論教訓：**探測外部 API
的可用性時，必須用產品實際會用的 client/呼叫路徑去驗證；用替代實作（不論多相似）驗證出的
結論，只對那個替代實作成立，不能自動套用到產品本身**。

---

## 最終處置：預設改回 raw RGBA，MMAP 環境變數 opt-in

- `DisplayTransportSelector.choose(emulatorVersion:mmapOptIn:)` 現在需要**兩個條件同時成立**
  才會選 `.mmapWithRawFallback`：`mmapOptIn == true`（`MIRAGE_TRANSPORT=mmap`）**且**
  `MmapVersionGate.allows(...)`（版本 ≥37）。任一條件不滿足一律 `.rawOnly`。
- **版本閘保留為獨立安全互鎖**：與「MMAP 在 37.x 上是否真的可用」無關，36.x 收到 MMAP 請求
  會 SIGSEGV 弄死使用者的 VM，這件事本身與凍結缺陷是兩個獨立問題，opt-in 不能繞過版本閘。
- 三種一次性觀測訊息（`EmulatorClient.makeDisplayTransport()`，連線建立時各印一次）：
  - opt-in 且版本 ≥37 → `[transport] mmap enabled (experimental, emulator <版本>)`
  - opt-in 但版本 <37 → `[transport] raw rgba (emulator <版本> < 37, mmap unavailable)`
  - 未 opt-in（**新預設**）→ `[transport] raw rgba (default; set MIRAGE_TRANSPORT=mmap to try mmap)`
  - 額外一種（`FallbackTransport` 內，僅在 opt-in 且實際降級時印一次）：
    `[transport] mmap unusable, falling back to raw rgba`
- 端到端驗證（`task-default-flip-report.md`）：不設 `MIRAGE_TRANSPORT`、對著真模擬器（37.2.1.0）
  連線，release App 印出 `[transport] raw rgba (default; set MIRAGE_TRANSPORT=mmap to try mmap)`，
  確認新預設行為正確接線。

---

## 覆蓋率下降是預期的

`scripts/coverage.sh` 兩條指令（一般 live 套件 + `AudioLiveTests` 專用）都**沒有**設定
`MIRAGE_TRANSPORT=mmap`，所以 `MmapStreamTransport` 這條 opt-in 路徑一行都不會被執行到。
本次重新量測：`MmapStreamTransport.swift` **0.00%**（107/107 行未覆蓋），把 `MirageCore`
`TOTAL` line coverage 從約 94–96%（P1-e 基準）拉到 **87.80%**。

**這是本次改動的預期後果，不是回歸**：`MmapStreamTransport` 現在是 opt-in 路徑，預設不會被
走到，`coverage.sh` 忠實反映了「預設組態下實際會執行的程式碼」。協調者明確指示不修改
`coverage.sh` 把數字調好看——那會混淆「覆蓋率量測」與「產品缺陷」兩件事，且會讓腳本在已知
會失敗的活體測試（驗收線 5）上意外變紅。**本任務僅如實記錄此現象，未修改任何腳本或程式碼**。

若想量測「假設 MMAP 有被走到會是什麼覆蓋率」，需要額外加 `MIRAGE_TRANSPORT=mmap` 跑第三次
`swift test`——但這樣做會讓 `MmapStreamLiveTests` 因凍結缺陷而**失敗**（非早退），會讓
`coverage.sh` 現有「測試失敗就中止」的邏輯整條腳本失敗，這是遺留給「未來在含修正的 emulator
上重新驗證」時才需要處理的問題，不在本階段範圍。

---

## 測試數變動說明（137 → 170）

Spec 基準（本計畫開工前，commit `6bb30f0`）：**137** 個 `@Test` 全綠。本次重新量測：
**170** 個，全綠，單次跑完（0.723 秒），無回歸。逐任務精確帳（依 `progress.md` 與各
`task-N-report.md` 交叉核對）：

| 階段 | 累計測試數 | 變化 |
|---|---|---|
| 基準（`6bb30f0`） | 137 | — |
| Task 1（`MmapSupport` 純函式）+ Task 2（`MmapBuffer`） | 156 | +19 |
| Task 3（`FallbackTransport`） | 164 | +8 |
| Task 4（`HealthResult` 帶版本） | 164 | +0（純介面改動，無新增測項） |
| Task 5（`MmapStreamTransport` 探測狀態機，含 fix round） | 170 | +6 |
| Task 6（`EmulatorClient` 接線，含 fix round） | 172 | +2 |
| Task 7（刪除 `UnaryMmapTransport`） | 167 | **−5** |
| Task 8（`MmapStreamLiveTests`，三閘門早退） | 168 | +1 |
| 預設翻轉（`DisplayTransportSelectorTests` opt-in 維度） | 170 | +2 |

**另一個需要更正的數字**：Task 9 brief 本身宣稱「Task 7 刪除 `MmapVersionGateTests`
（**−6**）」，但依 `task-7-report.md`（「172 → 167」「-4 MmapVersionGateTests、-1
liveUnaryMmapDeliversFrames」）與 `progress.md` 的精確帳，實際是 **−5**，不是 −6。錯誤源頭
是本 task-9 brief 自己。這是本階段第三個「既有文件數字有誤、被活體/交叉核對抓出來」的案例
（另兩個見下方「兩個要更正的既有錯誤數字」），一併在此更正。

净變化：+19+8+0+6+2−5+1+2 = **+33**，137+33 = **170**，與本次重新量測結果一致。

---

## 兩個要更正的既有錯誤數字

1. **`UnaryMmapTransport` 行數**：先前文件（含本計畫 `docs/plans/2026-07-27-mmap-stream-transport.md`
   與更早的架構債記憶 `nio-teardown-injectable-channel-debt`）稱其為「108 行」，
   **實際是 56 行**——`git show 47aa734~1:Sources/MirageCore/UnaryMmapTransport.swift | wc -l`
   本次複核確認為 56。`docs/specs/2026-07-27-mmap-stream-transport-design.md` §11 亦沿用了
   「108 行」的錯誤說法。`task-7-report.md` 已記錄此更正（minor, deferred），本文件再次確認。
2. **`verify_mmap.sh` 驗收線 6 的殘留檢查恆為 PASS**：見上方裁決表 #6 的說明——
   `NSTemporaryDirectory()` 實際回傳 `$TMPDIR`（`/var/folders/.../T/`），不是 `/tmp`，該檢查
   的 glob 永遠對不到 Swift 實際建立的檔案。這不是本次新發現（Task 8 已記錄），本次複核
   確認問題仍然存在，未修腳本（brief 要求逐字照用；本任務範圍為文件不含程式碼/腳本修改）。
   **✅ 2026-08-05（D39）已修**——從 Task 8 發現到真正修掉隔了 9 天、跨三份文件都記著
   「已知、仍然存在、未修」。這種「記錄得很清楚但沒有人修」的假斷言，成本其實只有五行
   shell；會拖這麼久是因為它每次都被歸到「本任務範圍外」。修法與故障注入見裁決表 #6。

---

## pending-human 清單（spec §9 三項）

spec §9 列出的三項皆需真 GUI session：

1. App 實際跑在 MMAP 路徑下的畫面正確性（無撕裂、無色偏）
2. App 合成層 fps 是否因 client CPU 下降而改善（傳輸層基準不得冒充合成層數字）
3. 換解析度（`setStreamSize`）時的畫面連續性

**本次已依指示用 `ioreg` 確認當下鎖定狀態，如實記錄**：

```
$ ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked
（無輸出，exit 1——鍵值不存在）
$ ioreg -n Root -d1 -a | grep -A1 IOConsoleLocked
	<key>IOConsoleLocked</key>
	<false/>
```

**螢幕目前未鎖定**（`CGSSessionScreenIsLocked` 鍵值不存在——與 `task-default-flip-report.md`
記載的同一台機器、同一種判讀方式一致：該實作者在跑預設翻轉驗證時也是這個狀態，release App
當時確實正常印出 stdout 訊息）。這與 P1-e 系列文件慣用的樣板理由「本機
`CGSSessionScreenIsLocked = true`，螢幕鎖定時 WindowServer 不合成畫面」**不適用於本次**——
不應照抄那份樣板文字。

**但這三項仍然是 pending-human，原因與 P1-e 時不同**：

- 這三項全部預設 MMAP 路徑必須**持續**收到新幀才有意義（撕裂/色偏要有畫面在動才能觀察；
  fps 改善要有持續輸出才能量測；換解析度連續性要新舊解析度都能正常出幀才能比較）。而本階段
  的核心發現是 `MmapStreamTransport` 在這台模擬器上**收到一次寫入後就凍結**——沒有持續的
  幀可供觀察，這三項問題目前**沒有前提成立**，不是「螢幕鎖定擋住了驗證管道」，而是「MMAP
  路徑本身還沒有一個健康到可以被驗證的狀態」。
- 即使螢幕解鎖、App 能正常渲染，這三項的判斷本質仍是**人眼**（有沒有撕裂、色偏是否明顯、
  切換解析度時觀感是否連續）——不是本任務職權範圍內可自動化的量測，需要真人坐在螢幕前
  操作與觀察。
- **結論**：三項維持 pending-human；但把原因從「本機螢幕鎖定」更正為「(a) 螢幕目前未鎖定，
  技術上可以啟動 GUI 驗證，但 (b) MMAP 路徑存在凍結缺陷，沒有持續畫面可供這三項判斷所需的
  觀察，且 (c) 三項判斷本質上需要人眼，非本任務可自動化」。真正要驗這三項，前提是先解決
  凍結缺陷（見下方「未來若要恢復預設 MMAP 的前提」）。

---

## 本階段仍有價值的產出

雖然 MMAP 未能成為預設路徑，以下產出不因此失效，全數保留：

- **`MmapSupport`**（純函式：`byteCount`／`handlePath`／`handleURL`／`isBlank`，逐行 100%
  覆蓋）、**`MmapBlankProbe`**（探測狀態機，含「串流提早結束」路徑）、**`MmapBuffer`**
  （mmap 建立/唯讀映射/快照複製/close 時 unlink）、**`FallbackTransport`**（純組合器，
  100% 覆蓋，四條必測行為齊備）、**`DisplayTransportSelector`**（純決策函式，版本 × opt-in
  兩維度窮舉測試）——全部是完整單元測試涵蓋的純型別/組合器，與 MMAP 是否啟用無關。
- **`HealthResult.healthy(version:)`**：`GrpcHealthProbe.probe()` 現在把已經拿到的
  `EmulatorStatus.version` 帶出來，而非探測後丟棄——**每次連線省下一次 RPC**，且「連上的是
  什麼版本」本來就屬於連線層的知識，這個重構與 MMAP 是否啟用無關，是純粹的品質改善。
  順帶讓版本閘（`MmapVersionGate`）與 opt-in 選路都能無成本使用這個版本字串。
- **`makeMmapTransport` 注入點**：`EmulatorClient` 新增的第四個 DI 工廠，讓「選出來後怎麼
  建構」與「該選哪一種」解耦——即使 MMAP 現在是 opt-in，這個注入點讓將來重新驗證/擴充
  transport 選擇邏輯時不需要再動 `EmulatorClient` 的建構邏輯。
- **`EmulatorClient+Input.swift` 拆分**：把多指觸控/鍵盤注入那段 extension 從
  `EmulatorClient.swift`（曾超過 400 行約束）搬出，純位移不改行為，讓兩個檔案都回到約束內。
- **刪除 56 行的 `UnaryMmapTransport` 舊 workaround**：連同其低覆蓋率的死碼與從未接上
  App 執行期的事實一併退場，改善了 `MirageCore` 覆蓋率分母的長期拖累（在 MMAP 路徑本身
  0% 覆蓋的情況下更為明顯地體現在本次 87.80% 的量測上——若沒刪掉這 56 行更低覆蓋率的舊碼，
  數字只會更難看）。

這些產出未來若要把 MMAP 重新設為預設，可以直接沿用，不需要重做。

---

## 未來若要把預設改回 MMAP 的前提

1. **必須先在含上游修正的 emulator build 上重新做一次活體驗證**，確認凍結問題確實消失——
   不能只憑上游 issue 狀態變成 fixed 就恢復預設（目前 aarch64 沒有含修正的 build 可用，
   見上方「沒有含修正的 emulator build 可測」）。
2. 重新驗證時應同時用 Swift（grpc-swift，產品實際 client）與 Python（grpcio，對照組）在
   **同一活體視窗**內交叉比對，避免重蹈「只用替代實作驗證、结论套用到產品」的立論缺陷
   （見上方「一個必須明白寫出的立論缺陷」）。
3. 驗收線 5 需要重新量到 ≥3 個非零且互異的幀，且建議把探測窗口拉長（例如 30 幀、跨數百
   毫秒）作為更強的信心佐證，而不只是最小的 3 幀。
4. 驗收線 7 的收益複驗屆時應該想辦法讓量測直接經過 `MirageCore.MmapStreamTransport`（例如
   在 Swift 測試裡量 client CPU），而不是繼續依賴獨立的 Python harness——這樣才能真正回答
   「產品路徑本身的收益」而非「主機能力上限」。
5. spec §9 的三項 pending-human 屆時才有前提成立（持續的健康幀流），需要真人在解鎖螢幕前
   實際操作與觀察。

---

## 已知限制

- **撕裂幀（R1，spec §10）**：proto 無同步原語，emulator 端非同步寫入映射區。基準測試約
  1100 幀未觀察到撕裂，但「未觀察到」≠「不會發生」——這條限制與凍結缺陷是獨立的兩件事，
  即使凍結缺陷未來被修好，撕裂仍是尚待觀察的殘留風險，非本階段可證偽或證實。
- **版本閘不放寬**：36.x 收到 MMAP 請求會 SIGSEGV（phase0/RESULTS-0b.md，2/2 確定性重現）。
  上游根因揭露這可能也只是同一個 0×0 pre-borrow 問題，送明確尺寸也許就不會炸——但沒有證據，
  且驗證代價是故意炸掉一台使用者的 VM，維持 ≥37 不放寬。此決策與凍結缺陷的存在與否無關，
  是獨立的安全考量。
- **`coverage.sh` 對 `MmapStreamTransport` 的覆蓋率量測缺口**：見上方「覆蓋率下降是預期的」
  ——這是已知且刻意保留的現況，非待辦。
- **`verify_mmap.sh` 驗收線 6 檢查恆為 PASS、無驗證意義**：見上方裁決表 #6，已記錄未修。
- **凍結缺陷根因未鎖定**：見上方「凍結缺陷」一節，留給未來在含修正 emulator build 上的
  排查作業。
