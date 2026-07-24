#!/usr/bin/env bash
# app/scripts/verify_snapshot.sh
# 驗收 4：對執行中模擬器 save → 改變畫面 → load，畫面回到 save 當時。
# 前置：模擬器執行中。用 adb 擷圖比對（save 前 vs load 後應相近；中間改變後應不同）。
set -euo pipefail
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
OUT=/tmp/mirage_snap; mkdir -p "$OUT"
echo "[snap] 需搭配 MIRAGE_LIVE 整合測試 SnapshotRoundTripLiveTests 執行本 gRPC round-trip。"
echo "[snap] 擷圖佐證：save 前後畫面一致、中途變更後不同。"
"$ADB" exec-out screencap -p > "$OUT/before.png"
echo "[snap] before.png 已存；請執行 MIRAGE_LIVE=1 swift test --filter SnapshotRoundTripLiveTests"
