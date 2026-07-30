#!/usr/bin/env bash
# P1 MMAP transport 活體驗證：確認 streamScreenshot + 共享記憶體真的寫入資料。
# 用法：verify_mmap.sh    （需 emulator-5554 正在跑）
set -uo pipefail
export ANDROID_SERIAL=emulator-5554
HARNESS="$(cd "$(dirname "$0")/../../phase0/harness" && pwd)"

echo "=== 前置：模擬器是否在跑 ==="
nc -z localhost 8554 && echo "gRPC 8554 ALIVE" || { echo "模擬器未啟動"; exit 1; }

echo ""
echo "=== 前置：具備 grpc+protobuf 的 python ==="
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

echo ""
echo "=== 前置：偵測 emulator 版本（決定下方活體測試會不會被版本閘擋下）==="
( cd "$HARNESS" && "$PY" - <<'PYEOF'
import sys
sys.path.insert(0, "gen")
import grpc
from google.protobuf import empty_pb2
import emulator_controller_pb2_grpc as ecg
try:
    stub = ecg.EmulatorControllerStub(grpc.insecure_channel("localhost:8554"))
    status = stub.getStatus(empty_pb2.Empty(), timeout=5)
    print(f"偵測到 emulator 版本：{status.version}")
except grpc.RpcError as err:
    print(f"版本偵測失敗：{err.code().name}: {err.details()}")
PYEOF
) || echo "版本偵測失敗（不影響下方測試本身的版本閘，測試會自行再查一次）"

echo ""
echo "=== 前置：動畫供應器（streamScreenshot 是變化驅動，靜止畫面不出幀）==="
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
MMAP_STATUS=${PIPESTATUS[0]}

# **這一條刻意不 `assert_ok`，而且理由要寫下來。** MMAP 在 emulator 37.2.1.0 上已知會凍結
# （上游 b/537802959，見 D16），所以這條測試現在必定紅。把它做成硬性閘門會產生一支永遠
# 紅的腳本，而「永遠紅的燈」訓練人去無視紅燈——那正是 D24 的病理。折衷是：**明確印出
# 退出碼**（不再像原本那樣整個丟棄），但不因它中止；下面那條獨立的檢查才是本腳本的斷言。
if [ "$MMAP_STATUS" -eq 0 ]; then
  echo "✅ MmapStreamLiveTests 通過（退出碼 0）——若上游修正已發布，D16 可以重驗了"
else
  echo "⚠️  MmapStreamLiveTests 失敗（退出碼 ${MMAP_STATUS}）：這是**已知且預期**的結果"
  echo "   （emulator 37.2.1.0 凍結，上游 b/537802959 尚未有可用修正版，見 D16）。"
  echo "   刻意不讓它中止本腳本——但它不再是靜默丟棄，退出碼現在看得見。"
fi

echo ""
echo "=== 驗收線 6：/tmp 不得有映射檔殘留 ==="
# 這條與上面的凍結無關，**是本腳本真正的斷言**。原本它 `echo "FAIL：…"` 之後接 `ls`，
# 而 `ls` 在檔案存在時回傳 0——於是印著 FAIL 的那次跑，腳本照樣 exit 0（D9）。
LEFT=$(ls /tmp/mirage_mmap_* 2>/dev/null | wc -l | tr -d ' ')
echo "殘留檔案數：$LEFT"
if [ "$LEFT" != "0" ]; then
  echo "❌ FAIL：close() 的 unlink 沒生效"
  ls /tmp/mirage_mmap_*
  exit 1
fi
echo "✅ PASS：無殘留映射檔"
