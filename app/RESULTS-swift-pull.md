# Swift 直拉對照組結果

日期：2026-09-03

## 改動

- `app/Package.swift` 新增 `MiragePull`、`mirage-pull`、`MiragePullTests` 三個 target，皆套用既有 `strict` 設定。
- `MiragePull` 使用產品既有的 `GrpcChannelBox` 與 `GrpcStreamTransport`，以外部計時器取消變化驅動的串流，計算每 64 位元組取樣的 64 位元 FNV-1a 指紋，輸出四狀態結果。
- `mirage-pull` 支援 `--endpoint`、`--seconds`、`--width`、`--height`、`--json`，JSON 欄位沿用 `fps_baseline.py` 並加上 `client: "grpc-swift"`。
- `MiragePullTests` 覆蓋狀態與退出碼、整列差異、第一位元組差異、相同畫面、停住串流取消、零幀 static、transport error、JSON 欄位與純文字輸出。
- `verify_transport_compare.sh` 新增 `-s` 系列選擇，預設 `rgba,swift`，支援任意不重複的 `rgba`、`mmap`、`swift` 組合；輪次依系列數輪轉，統計每系列中位數、有效輪數與相對第一系列差值。
- `verify_common.sh` 的 `build_warm` 新增可選 product 參數，保留既有三參數呼叫方式；Swift 系列會在量測前暖機 `mirage-pull` release 建置快取。

## 第二輪修正

- `MiragePull.run` 在建立 `GrpcChannelBox` 後、開始 `measure()` 前，使用同一個 `channel.group` 建立 NIO `ClientBootstrap`，以 5 秒 timeout 做 TCP 連線探測。
- 探測成功後關閉臨時 channel；探測失敗回傳 `UNAVAILABLE: <原因>`、`error` 狀態與退出碼 1，並照常呼叫 `GrpcChannelBox.shutdown()`。
- 新增拒絕連線與可接受 TCP 連線 listener 的 probe 測試，listener 與 event loop group 都在測試結束前以 async API 關閉。
- 探測只能排除「沒有任何程式監聽該埠」。若有人監聽但不是 gRPC 服務，TCP 探測仍會通過，後續 gRPC 串流可能因等待連線就緒而呈現相同的假 `static`；這輪沒有改動 `MirageCore` 的 channel pool 行為。

## 可執行檢查

- `bash -n app/scripts/verify_transport_compare.sh`：通過。
- `bash -n app/scripts/lib/verify_common.sh`：通過。
- `swiftc -parse`：`Package.swift`、library、executable、測試檔皆通過。
- 嵌入的 JSON 解析 Python：repo 沒有 `phase0/harness/.venv-d45/bin/python`，以系統 Python 執行標準函式庫語法與兩種 JSON 輸入行為檢查，baseline 預設 client 為 `python`，Swift JSON client 可解析為 `grpc-swift`，通過。
- `bash app/scripts/verify_transport_compare.sh -s rgba,swift -p 45999`：退出碼 1，在 `require_grpc` 輸出 `❌ gRPC 45999 無回應——模擬器未啟動。`，未進入建置或量測窗口。
- `git diff --check`：通過。

## 尚未驗證

- 依第 6 節要求，沒有執行 `swift build`、`swift test` 或 `bash app/scripts/ci.sh`。PM 需在沙箱外編譯 `mirage-pull`、執行 `MiragePullTests` 與九道 CI 閘門。
- 沒有啟動 emulator，也沒有執行 adb；因此未驗證實際 gRPC 連線失敗 JSON、真實 FPS、真實 channel teardown 與三系列交錯數字。
- 沒有執行 `verify_transport_compare.sh -s rgba,mmap` 的完整量測；其 Python 路徑、負載門檻與有效樣本斷言保留原行為，需由 PM 以 emulator 做改前對照。
- 真實 emulator 數字由 PM 補寫。

## Commit

- `e0ff6ff test: 先加入 Swift 直拉契約測試`
- `c53ad02 feat: 新增 Swift 直拉量測工具`
- `7609244 fix: 補強直拉逾時與輸出測試`
- `39b942a feat: 擴充 transport 交錯驗證系列`
- `2259f17 docs: 完成 Swift 直拉結果報告`

## PM 把關與活體驗證（2026-09-03）

### 把關

- codex 在沙箱裡編不了 Swift（見簡報第 6 節），第一輪盲寫的碼 PM 在沙箱外一次編過（36 秒），`MiragePullTests` 12 條綠；第二輪加探測後 14 條綠。
- `bash app/scripts/ci.sh`：第一輪後八道閘門綠、閘門 8 因 worktree 沒有 venv 而紅（環境，非程式碼；把 main 的 venv 連結進來後 33 條 pytest 綠），第二輪後全部重跑，見下方。
- 獨立審查對 diff 本體沒有發現問題，對探測的修法給了三個要點（重用 group、只排除「沒人聽」、放在 `measure()` 之外），第二輪照此實作。
- 驗收條件 3 第一輪未過（45999 回 `static`、退出碼 2、耗時 2 秒），第二輪通過（`status: error`、`error: UNAVAILABLE: ... Connection refused`、退出碼 1、耗時 1 秒）。
- 順帶：debug 二進位對真實 emulator 只有 4 fps（指紋迴圈與 grpc-swift 未最佳化），量測一律要用 release，`verify_transport_compare.sh` 已如此。

### 活體：`verify_transport_compare.sh -s rgba,swift -p 8556 -r 3 -d 20`

環境同 `app/RESULTS-d58.md`：`mirage-game`、Pixel Flow 0.33.0 在前景、900×2000、`LOAD_LIMIT=12`、release 建置事先暖好（`build_warm` 第 2 次 no-op）。5 秒探測：Swift 直拉 59.34 fps、298 幀 298 種。

| 輪 | 順序 | client | fps | frames | distinct | 負載前 → 後 |
|---|---|---|---|---|---|---|
| 1 | rgba/swift | python | 59.32 | 1187 | 1186 | 6.35 → 8.72 |
| 1 | rgba/swift | grpc-swift | 49.99 | 1000 | 995 | 6.35 → 8.72 |
| 2 | swift/rgba | grpc-swift | 56.61 | 1133 | 1131 | 8.72 → 8.86 |
| 2 | swift/rgba | python | 55.51 | 1111 | 1109 | 8.72 → 8.86 |
| 3 | rgba/swift | python | 57.82 | 1157 | 1157 | 8.86 → 8.47 |
| 3 | rgba/swift | grpc-swift | 56.99 | 1140 | 1138 | 8.86 → 8.47 |

中位數 Python 57.82、grpc-swift 56.61，差 1.21 fps，有效輪數各 3，退出碼 0。第 1 輪 Swift 的 49.99 伴隨負載從 6.35 升到 8.72，第 2、3 輪兩者相當。

### 判定

1. grpc-swift 這條 client 路徑不是驗收線 7 的瓶頸：它單獨拉 raw RGBA 不渲染就過 55，與 Python 相當。連同 `RESULTS-d58.md` 的結論，傳輸與 client 兩段都排除。
2. Mirage 實際量到 43 到 54（D48），損失只剩兩個候選：(a) `MirageShell` 的解碼、Metal 上傳、視窗合成或 `LatestFrameBox` 丟幀；(b) app 自己的 CPU／GPU 負載回頭壓 guest 出幀（D48 在真 GUI 下量到 guest 只有 49 到 57）。直拉工具不渲染，所以 (b) 在這裡不存在。
3. 下一步：在 Mirage 行程內同一窗口計三個數（抵達、上傳、present），與 `verify_fps_fullscreen.sh` 已對齊的 guest fps 並列。抵達接近 guest 而 present 明顯低，損失在渲染；抵達本身就低，是 (b)。
4. D16 記載的「grpc-swift 發請求時 MMAP 更新率遠低於 Python」這個現象與本次無矛盾：那是 MMAP 通知路徑的問題，raw RGBA 路徑上 grpc-swift 正常。
