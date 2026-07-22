# Phase 0 技術驗證

目的：驗證「headless 官方 emulator + gRPC 串流/輸入」可達 spec §4.2 延遲預算。詳見
`../docs/plans/2026-07-22-phase0-validation.md`。

## 執行順序

1. `scripts/00_install_sdk.sh` — 安裝 SDK 與映像
2. `scripts/01_create_avd.sh` — 建立 mirage-poc AVD
3. `scripts/02_boot_headless.sh` — 啟動（保持前景）
4. `scripts/03_wait_boot.sh` — 等 BOOTED
5. harness 量測（`harness/` 內，先 `source .venv/bin/activate`；首次於新 clone 執行見下方「harness 環境建置」）：
   - `python -m pytest tests/ -v` — 單元測試
   - `python smoke_grpc.py` — 連通
   - `python animate.py --seconds 30` — 另開終端（或背景）執行的持續動畫來源。`streamScreenshot` 為變化驅動，靜止畫面不出幀，量 fps/延遲前必須先跑這支腳本
   - `python stream_bench.py --format rgba --seconds 10`（可加 `--width`/`--height` 縮小解析度，例如 `--width 540 --height 1200`）— 幀率
   - `python input_latency.py` — 注入 RTT
   - `adb shell settings put system show_touches 1 && python e2e_latency.py` — 端到端
6. `cd swift-poc && swift run -c release` — 鏡像視窗體感驗證（**建議使用 Release build**：Debug build 因未優化的逐幀 Metal 上傳路徑，實測 fps 會比 Release 低 15–20 倍，屬建置模式假象，不可用於效能判讀）
7. 數據填入 `RESULTS.md`，做 go/no-go 判定

## Phase 0b 傳輸驗證（備援）

Phase 0 判 gRPC 原始畫格 NO-GO 後的備援驗證。**兩條備援皆判 NO-GO**，判定與完整證據見
[`RESULTS-0b.md`](./RESULTS-0b.md)：

1. `python probe_mmap.py` — MMAP 通道探測（需 `animate.py` 供應動畫）。**⚠️ 警告：於穩定版
   emulator 36.6.11.0 執行本腳本會使 emulator 引擎崩潰**（SIGSEGV/SIGABRT，3/3 確定性重現，
   零幀送達，且無自動復原機制）——執行前務必確認可承受 emulator 需要手動重啟的代價。詳見
   `RESULTS-0b.md`。
2. `python stream_bench.py --format rgba --seconds 8 --transport mmap` — mmap 幀率
   **[SKIPPED]**：MMAP 軌已於步驟 1 判死，依計畫應變條款跳過
3. `python e2e_latency.py --transport mmap` — mmap 端到端（先開 show_touches）**[SKIPPED]**：同上
4. `MIRAGE_TRANSPORT=mmap ./.build/release/MiragePOC` — Swift mmap 終裁 **[SKIPPED]**：同上
5. `python encoded_bench.py --mode fps|e2e` — 編碼路徑對照（WebRTC 等效）；實測同樣
   NO-GO（真實內容變化下僅 0.6fps，e2e 模式於方法論層面直接失敗），詳見 `RESULTS-0b.md`

Phase 1 顯示路徑目前無現成方案通過 60fps 閘門，`RESULTS-0b.md` 列出四個決策選項（fork 補
MMAP 寫入端／回報上游並暫用縮放串流／改用有視窗 emulator + ScreenCaptureKit／接受
42fps），交由決策者裁決。

## harness 環境建置（新 clone 首次執行）

```bash
cd phase0/harness
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
mkdir -p protos gen
cp "$SDK/emulator/lib/emulator_controller.proto" protos/
python -m grpc_tools.protoc -I protos \
  --python_out=gen --grpc_python_out=gen \
  protos/emulator_controller.proto
touch gen/__init__.py
```

`gen/`（protobuf/gRPC stub）為產生物，不進版控（見 `.gitignore`），每次新 clone 都需重跑上述 `protoc` 指令。

## 連線埠

所有 harness/Swift 客戶端一律連線 `localhost:8554`（寫死於程式碼常數，如 `stream_bench.py`/`animate.py` 的 `TARGET`、`EmulatorClient` 的預設 `port`）。`scripts/02_boot_headless.sh` 的 `GRPC_PORT` 環境變數只影響 emulator 啟動時綁定的埠，不會連動更新客戶端；若要改埠，兩邊都要手動改。

## 結果

實測數據與 go/no-go 判定紀錄於 [`RESULTS.md`](./RESULTS.md)。

**結論摘要**：實測過的控制面（headless 啟動、gRPC 輸入注入、串流控制介面）驗證優異；顯示傳輸（gRPC raw-frame streaming）未達 60fps 門檻，判定 **NO-GO**，需啟動備援路線（WebRTC → fork + 共享記憶體）。剪貼簿、生命週期（快照休眠/喚醒）、sendKey 在 Phase 0 未實測，列為 Phase 1 前置驗證項。詳見 `RESULTS.md`。

**Phase 0b 後續**：備援驗證（MMAP 共享記憶體、H.264 編碼串流）兩條路皆判 NO-GO——詳見上方
「Phase 0b 傳輸驗證」與 [`RESULTS-0b.md`](./RESULTS-0b.md)。Phase 1 顯示路徑目前無現成方案
通過閘門，待決策者從 `RESULTS-0b.md` 列出的四個選項中裁決。
