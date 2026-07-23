# Mirage App（P1-a）

產品殼與顯示管線。建置：`cd app && swift build -c release`。
執行：先啟動模擬器（`phase0/scripts/02_boot_headless.sh` + `03_wait_boot.sh`），
再 `./.build/release/MirageApp`。

- `MIRAGE_FPS_LOG=1`：每秒印 `[app] fps=N`（量測用）
- `MIRAGE_TRANSPORT=unary-mmap`：實驗傳輸（僅 canary emulator ≥37；穩定版會被版本閘拒絕）
- 測試：`swift test`；活體整合：`MIRAGE_LIVE=1 swift test --filter LiveSmokeTests`
  （`MIRAGE_LIVE_MMAP=1` 另外開啟 unary-mmap 活體路徑；兩者皆需要一個正在跑的 emulator，
  且是量測完整測試覆蓋率時的必要呼叫方式——只跑預設 `swift test` 會因活體測試提早
  return 而漏掉大段覆蓋率，細節見 `RESULTS-p1a.md` 驗收 4 節）
- 驗收紀錄：`RESULTS-p1a.md`；重連驗證：`scripts/verify_reconnect.sh`

架構詳見 `../docs/specs/2026-07-23-p1a-display-shell-design.md`。

## 目前驗收狀態

P1-a 五條驗收線目前為 **PARTIAL PASS**（3/5 可測項中 2 過 1 未過，另 2 項因本機螢幕鎖定
無法量測）。**尚未達到可完整出貨的狀態**——e2e 迴歸有實測到的真實回歸（未過），且
App 合成 fps／渲染中 CPU 兩項待螢幕解鎖後補測。完整逐條數字與判定見 `RESULTS-p1a.md`。
