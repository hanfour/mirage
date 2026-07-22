# Phase 0 技術驗證

目的：驗證「headless 官方 emulator + gRPC 串流/輸入」可達 spec §4.2 延遲預算。詳見
`../docs/plans/2026-07-22-phase0-validation.md`。

## 執行順序

1. `scripts/00_install_sdk.sh` — 安裝 SDK 與映像
2. `scripts/01_create_avd.sh` — 建立 mirage-poc AVD
3. `scripts/02_boot_headless.sh` — 啟動（保持前景）
4. `scripts/03_wait_boot.sh` — 等 BOOTED
5. harness 量測（`harness/` 內，先 `source .venv/bin/activate`）：
   - `python -m pytest tests/ -v` — 單元測試
   - `python smoke_grpc.py` — 連通
   - `python stream_bench.py --format rgba --seconds 10` — 幀率（另開終端跑動畫，見計畫 Task 4 Step 6；`streamScreenshot` 為變化驅動，靜止畫面不出幀，動畫來源須為持續高頻注入，不可用間歇性 `adb shell input` 指令）
   - `python input_latency.py` — 注入 RTT
   - `adb shell settings put system show_touches 1 && python e2e_latency.py` — 端到端
6. `cd swift-poc && swift run -c release` — 鏡像視窗體感驗證（**建議使用 Release build**：Debug build 因未優化的逐幀 Metal 上傳路徑，實測 fps 會比 Release 低 15–20 倍，屬建置模式假象，不可用於效能判讀）
7. 數據填入 `RESULTS.md`，做 go/no-go 判定

## 結果

實測數據與 go/no-go 判定紀錄於 [`RESULTS.md`](./RESULTS.md)。

**結論摘要**：控制面（headless 啟動、gRPC 輸入注入、剪貼簿、生命週期）驗證優異；顯示傳輸（gRPC raw-frame streaming）未達 60fps 門檻，判定 **NO-GO**，需啟動備援路線（WebRTC → fork + 共享記憶體），詳見 `RESULTS.md`。
