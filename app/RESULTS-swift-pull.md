# Swift 直拉對照組結果

日期：2026-09-03

## 改動

- `app/Package.swift` 新增 `MiragePull`、`mirage-pull`、`MiragePullTests` 三個 target，皆套用既有 `strict` 設定。
- `MiragePull` 使用產品既有的 `GrpcChannelBox` 與 `GrpcStreamTransport`，以外部計時器取消變化驅動的串流，計算每 64 位元組取樣的 64 位元 FNV-1a 指紋，輸出四狀態結果。
- `mirage-pull` 支援 `--endpoint`、`--seconds`、`--width`、`--height`、`--json`，JSON 欄位沿用 `fps_baseline.py` 並加上 `client: "grpc-swift"`。
- `MiragePullTests` 覆蓋狀態與退出碼、整列差異、第一位元組差異、相同畫面、停住串流取消、零幀 static、transport error、JSON 欄位與純文字輸出。
- `verify_transport_compare.sh` 新增 `-s` 系列選擇，預設 `rgba,swift`，支援任意不重複的 `rgba`、`mmap`、`swift` 組合；輪次依系列數輪轉，統計每系列中位數、有效輪數與相對第一系列差值。
- `verify_common.sh` 的 `build_warm` 新增可選 product 參數，保留既有三參數呼叫方式；Swift 系列會在量測前暖機 `mirage-pull` release 建置快取。

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
