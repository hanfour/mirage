#!/usr/bin/env bash
# P1 MMAP transport 活體驗證：確認 streamScreenshot + 共享記憶體真的寫入資料。
# 用法：verify_mmap.sh    （需 emulator-5554 正在跑）
#
# **本腳本量兩條路徑，不是一條**（D39，2026-08-05 改）：
#   Python(grpcio) 對照  → emulator 的 MMAP 寫入端本身正不正常
#   Swift(grpc-swift)    → 產品實際會走的那條路徑正不正常
# 只量 Swift 那條時，紅燈分不出「上游壞了」與「只有我們的 client 壞了」，
# 而這兩者的下一步完全相反。D39 之前這個對照是手工搭的，只做過一次。
set -uo pipefail
export ANDROID_SERIAL=emulator-5554
cd "$(dirname "$0")/.." || exit 1
source "$(dirname "$0")/lib/verify_common.sh"
HARNESS="$(cd ../phase0/harness && pwd)"
# animate 要涵蓋「build + Python 對照 + Swift 測試」整段，不只測試本身。
ANIM_SECONDS="${ANIM_SECONDS:-90}"

require_grpc 8554

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

# **先 build 再供應動畫**：測試 target 冷的時候 build 要一分多鐘，而 animate 是計時的。
# D39 第一次跑就踩到——animate 40 秒早就結束，測試才開始等幀，於是等了 109 秒才湊滿
# 3 幀。build 放在計時器外面，animate 的秒數才真的等於「畫面在動的時間」。
echo ""
echo "=== 前置：預先 build 測試 target（不計入動畫窗口）==="
swift build --build-tests > /dev/null 2>&1
assert_ok "測試 target build" "$?"

echo ""
echo "=== 前置：動畫供應器（streamScreenshot 是變化驅動，靜止畫面不出幀）==="
( cd "$HARNESS" && "$PY" animate.py --seconds "$ANIM_SECONDS" >/tmp/mirage_anim.log 2>&1 & )
sleep 4

# **這一條是硬斷言，Swift 那條不是**——因為它現在是綠的。它一旦轉紅，代表 emulator
# 的 MMAP 寫入端壞了（或動畫沒供應成功），那時 Swift 的紅燈就沒有判讀價值，整次量測
# 都不可信，應該中止而不是繼續往下印。
echo ""
echo "=== 對照組：Python(grpcio) 是否拿得到持續更新的幀 ==="
( cd "$HARNESS" && "$PY" mmap_client_parity.py --width 540 --height 1200 ) 2>&1 | tail -6
PARITY_STATUS=${PIPESTATUS[0]}
assert_ok "Python 對照（emulator 側 MMAP 寫入）" "$PARITY_STATUS"

echo ""
echo "=== 量測：MmapStreamTransport 活體（產品路徑）==="
echo "MMAP 預設關閉（見 DisplayTransportSelector 裁決），本測試需 MIRAGE_TRANSPORT=mmap"
echo "才會實際執行。**已知現況（D39，2026-08-05 重驗）**：37.1.11 / 37.2.1 / 37.2.3"
echo "三個 emulator 版本上皆凍結，而同條件的 Python 對照三次皆正常——缺陷在 client 側，"
echo "與 emulator 版本無關（原本「等含修正的 build 發布」那個等待前提已被推翻）。"
MIRAGE_TRANSPORT=mmap MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 swift test --filter MmapStreamLiveTests 2>&1 \
  | grep -E "\[mmap-live\]|Test run with|✘"
MMAP_STATUS=${PIPESTATUS[0]}

# **這一條刻意不 `assert_ok`，而且理由要寫下來。** MMAP 的凍結是已知的產品缺陷，
# 把它做成硬性閘門會產生一支永遠紅的腳本，而「永遠紅的燈」訓練人去無視紅燈——那正是
# D24 的病理。折衷是：**明確印出退出碼**，但不因它中止；上面的 Python 對照與下面的
# 殘留檢查才是本腳本會中止的斷言。
if [ "$MMAP_STATUS" -eq 0 ]; then
  echo "🎉 MmapStreamLiveTests 通過（退出碼 0）——**狀態已改變**。"
  echo "   Swift 路徑現在拿得到持續更新的幀了。請重新評估 DisplayTransportSelector"
  echo "   的預設，並更新 app/RESULTS-mmap.md 的裁決（D16／D39）。"
else
  echo "⚠️  MmapStreamLiveTests 失敗（退出碼 ${MMAP_STATUS}）：這是**已知且預期**的結果。"
  echo "   對照組同時是綠的 → 缺陷在 grpc-swift 這條路徑上，不在 emulator。"
  echo "   刻意不讓它中止本腳本——但它不再是靜默丟棄，退出碼現在看得見。"
fi

echo ""
echo "=== 驗收線 6：跑完不得有映射檔殘留（close() 的 unlink 有沒有生效）==="
# **這條檢查原本恆為 PASS，是假斷言**（D39 修）：它 glob 的是 `/tmp/mirage_mmap_*`，
# 但 `MmapSupport.handlePath` 拿的是 `NSTemporaryDirectory()`，在 macOS 上實際回傳
# `$TMPDIR`（`/var/folders/.../T/`）——glob 恆對不到 Swift 真正建立的檔案，不論
# `close()`/`unlink` 有沒有生效都會 PASS。兩個目錄都掃，是因為 `NSTemporaryDirectory()`
# 在 `$TMPDIR` 未設時會退回 `/tmp`，而 swift test 的環境不保證兩者一致。
#
# glob 刻意用 `mirage_mmap_*` **不排除對照腳本的 `mirage_mmap_parity_*`**。一度想排除，
# 因為那是對照組的檔案不是產品的——但那等於自己開一道後門，而後門後面真的有東西：
# `mmap_client_parity.py` 第一版就漏了 5 個檔（`buf.close()` 在提早 break 時必然拋
# BufferError，unlink 掛在它後面就永遠不會執行）。兩邊都該清乾淨，一條斷言管兩邊。
LEFT=0
for dir in "${TMPDIR:-/tmp}" /tmp; do
  n=$(find "$dir" -maxdepth 1 -name 'mirage_mmap_*' 2>/dev/null | wc -l | tr -d ' ')
  echo "   ${dir} → ${n} 個"
  LEFT=$((LEFT + n))
done
if [ "$LEFT" != "0" ]; then
  echo "❌ FAIL：unlink 沒生效，殘留 ${LEFT} 個映射檔"
  find "${TMPDIR:-/tmp}" /tmp -maxdepth 1 -name 'mirage_mmap_*' 2>/dev/null
  exit 1
fi
echo "✅ PASS：無殘留映射檔（已掃 \$TMPDIR 與 /tmp，含對照腳本自己建的）"
