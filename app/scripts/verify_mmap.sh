#!/usr/bin/env bash
# P1 MMAP transport 活體驗證：確認 streamScreenshot + 共享記憶體真的寫入資料。
# 用法：verify_mmap.sh    （需 emulator-5554 正在跑）
set -uo pipefail
export ANDROID_SERIAL=emulator-5554
HARNESS="$(cd "$(dirname "$0")/../../phase0/harness" && pwd)"

echo "=== 前置：模擬器是否在跑 ==="
nc -z localhost 8554 && echo "gRPC 8554 ALIVE" || { echo "模擬器未啟動"; exit 1; }

echo ""
echo "=== 前置：動畫供應器（streamScreenshot 是變化驅動，靜止畫面不出幀）==="
PY=""
for cand in "$HARNESS/.venv/bin/python" "$(command -v python3)"; do
  [ -x "$cand" ] && "$cand" -c "import grpc, google.protobuf" 2>/dev/null && { PY="$cand"; break; }
done
if [ -z "$PY" ]; then
  echo "找不到具備 grpc+protobuf 的 python。請先建立環境："
  echo "  python3 -m venv $HARNESS/.venv && $HARNESS/.venv/bin/pip install -r $HARNESS/requirements.txt"
  echo "（系統 python 的 protobuf 版本過舊，會讓 animate.py 匯入失敗）"
  exit 1
fi
( cd "$HARNESS" && "$PY" animate.py --seconds 40 >/tmp/mirage_anim.log 2>&1 & )
sleep 4

echo ""
echo "=== 量測：MmapStreamTransport 活體 ==="
echo "注意：MMAP 現在預設關閉（見 DisplayTransportSelector 裁決），本測試需 MIRAGE_TRANSPORT=mmap"
echo "才會實際執行；在 emulator 37.2.1.0 上已知會失敗（凍結，上游 b/537802959 尚未有可用修正版），"
echo "這是預期中的已知缺陷，等含修正的 emulator 發布後才應該轉綠。"
cd "$(dirname "$0")/.." || exit 1
MIRAGE_TRANSPORT=mmap MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --filter MmapStreamLiveTests 2>&1 \
  | grep -E "\[mmap-live\]|Test run with|✘"

echo ""
echo "=== 驗收線 6：/tmp 不得有映射檔殘留 ==="
LEFT=$(ls /tmp/mirage_mmap_* 2>/dev/null | wc -l | tr -d ' ')
echo "殘留檔案數：$LEFT"
[ "$LEFT" = "0" ] && echo "PASS" || { echo "FAIL：close() 的 unlink 沒生效"; ls /tmp/mirage_mmap_*; }
