#!/usr/bin/env bash
# P1 MMAP transport 活體驗證：確認 streamScreenshot + 共享記憶體真的寫入資料。
# 用法：verify_mmap.sh    （需 emulator-5554 正在跑）
#
# **本腳本量兩條路徑，不是一條**（D39，2026-08-05 加入）：
#   Python(grpcio) 對照  → emulator 的 MMAP 寫入端本身正不正常
#   Swift(grpc-swift)    → Mirage 使用的 MMAP 路徑正不正常
# 先前的兩條路徑曾出現不同結果；2026-10-01 重測已接近相同更新率，恢復原因仍未查明。
set -uo pipefail

# D60(a)：在建置、寫日誌及量測之前檢查主機磁碟，失敗直接中止。
source "$(dirname "$0")/lib/load_sentinel.sh"
disk_preflight "$(dirname "$0")" || exit 1
export ANDROID_SERIAL=emulator-5554
# **路徑要在 cd 之前解析成絕對路徑。** 原本是 `cd "$(dirname "$0")/.."` 之後再
# `source "$(dirname "$0")/lib/..."`——`$0` 是相對路徑時，cd 完那個相對路徑就失效了，
# 於是這支腳本只在「從 app/ 目錄呼叫」時才正確。從 repo root 呼叫時兩個 source 都
# 靜默失敗，而 `set -u` 不管函式，缺少的函式要到被呼叫時才炸成 command not found。
# D54 加負載門檻時才踩到：門檻看起來有作動（腳本確實中止了），實際上是
# `load_gate: command not found` 的退出碼 127 讓 `if !` 成立——**一道從未執行過的閘門**。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 1
source "$SCRIPT_DIR/lib/verify_common.sh"
HARNESS="$(cd ../phase0/harness && pwd)"
# animate 要涵蓋「build + Python 對照 + Swift 測試」整段，不只測試本身。
ANIM_SECONDS="${ANIM_SECONDS:-90}"
# **12 不是隨便挑的**（D54）：2026-08-05 的根因調查裡，`swift build -c release` 把
# load 推到 22，緊接著跑的同一份測試量到 1–2；build 快取、load≈9 時量到 75–110。
# 12 落在兩者之間。可用 LOAD_LIMIT 覆寫，但覆寫等於宣告「我知道這批數字不可信」。
LOAD_LIMIT="${LOAD_LIMIT:-12}"

require_grpc 8554

# **量測前的負載門檻（D54）**。這條在 2026-08-05 之前不存在，於是那天所有 MMAP 數字
# 都可能是在量負載而不是量行為——同一份測試在那一天量到 1 到 119。
#
# **超標就中止，不是印個警告繼續**：`load_sentinel.sh` 自己寫的規則是「寧可重測，
# 不要留一筆自己都不相信的數字」。印警告繼續的版本，等於把判讀責任丟給下一個人，
# 而那個人多半只會看最後一行的 ✅。
echo ""
echo "=== 前置：主機負載門檻（上限 ${LOAD_LIMIT}）==="
LOAD_BEFORE=$(load_avg_1min)
if ! load_gate "$LOAD_LIMIT"; then
  echo "❌ 量測前負載 ${LOAD_BEFORE} 已超標，中止。"
  # **這一行不能用反引號**：雙引號裡的反引號是命令替換，第一版寫成
  # 「（`swift build` 剛跑完時…）」，於是每次負載超標時腳本都會真的去跑一次
  # swift build——把一支「因為機器太忙而中止」的路徑，變成再加一份負載。
  # 與閘門 4 擋的全形標點同型：中文說明文字裡混進 shell 語法。
  echo "   等機器安靜下來再跑（swift build 剛跑完時特別容易踩到），"
  echo "   或 LOAD_LIMIT=<更高> 覆寫——但那等於宣告你知道這批數字不可信。"
  exit 1
fi
echo "✅ 量測前負載 ${LOAD_BEFORE}（上限 ${LOAD_LIMIT}）"

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
import importlib.util
import os
import grpc
from google.protobuf import empty_pb2
import emulator_controller_pb2_grpc as ecg
auth_path = os.path.abspath("../../tools/probe/lib/grpc_auth.py")
spec = importlib.util.spec_from_file_location("mirage_probe_grpc_auth", auth_path)
grpc_auth = importlib.util.module_from_spec(spec)
spec.loader.exec_module(grpc_auth)
try:
    metadata = grpc_auth.auth_metadata(8554)
    channel = grpc.intercept_channel(
        grpc.insecure_channel("localhost:8554"), grpc_auth.AuthInterceptor(metadata))
    stub = ecg.EmulatorControllerStub(channel)
    status = stub.getStatus(empty_pb2.Empty(), timeout=5)
    print(f"偵測到 emulator 版本：{status.version}")
    channel.close()
except grpc.RpcError as err:
    print(f"版本偵測失敗：{err.code().name}: {err.details()}")
PYEOF
) || echo "版本偵測失敗（不影響下方測試本身的版本閘，測試會自行再查一次）"

# **先 build 再供應動畫**：測試 target 冷的時候 build 要一分多鐘，而 animate 是計時的。
# build 放在計時器外面，animate 的秒數才真的等於「畫面在動的時間」。
echo ""
echo "=== 前置：預先 build 測試 target（不計入動畫窗口）==="
swift build --build-tests > /dev/null 2>&1
assert_ok "測試 target build" "$?"

# **開跑前先把場地掃乾淨，理由不是整潔而是斷言的正確性**：收尾那條殘留檢查掃的是
# `mirage_mmap_*`，而 `phase0/harness/probe_mmap.py`／`probe_mmap_explicit.py` **也**用
# 這個前綴（`tempfile.mktemp(prefix="mirage_mmap_")`）。有人先手動跑過那兩支、留下殘留，
# 收尾就會紅在別人的垃圾上——一個因為別人而紅的斷言，跟恆綠的假斷言一樣沒有價值。
# 先清再量，收尾抓到的就一定是這次跑出來的。
echo ""
echo "=== 前置：清掉既有的映射檔殘留（收尾那條斷言的基準）==="
PRE=$(find "${TMPDIR:-/tmp}" /tmp -maxdepth 1 -name 'mirage_mmap_*' 2>/dev/null | wc -l | tr -d ' ')
find "${TMPDIR:-/tmp}" /tmp -maxdepth 1 -name 'mirage_mmap_*' -delete 2>/dev/null
echo "   清掉 ${PRE} 個（非本次產生，可能來自 probe_mmap*.py 或上一次中斷的跑次）"

echo ""
echo "=== 前置：動畫供應器（streamScreenshot 是變化驅動，靜止畫面不出幀）==="
( cd "$HARNESS" && "$PY" animate.py --seconds "$ANIM_SECONDS" >/tmp/mirage_anim.log 2>&1 & )
sleep 4

# **這一條是硬斷言**。它一旦轉紅，代表 emulator 的 MMAP 寫入端未觀察到持續更新，
# 或動畫沒有供應成功；後續 Swift 測試就沒有判讀價值，整次量測應該中止。
echo ""
echo "=== 對照組：Python(grpcio) 是否拿得到持續更新的幀 ==="
( cd "$HARNESS" && "$PY" mmap_client_parity.py --width 898 --height 1996 ) 2>&1 | tail -6
PARITY_STATUS=${PIPESTATUS[0]}
assert_ok "Python 對照（emulator 側 MMAP 寫入）" "$PARITY_STATUS"

echo ""
echo "=== 量測：MmapStreamTransport 活體（產品路徑）==="
echo "取樣至少 120 幀、解析度 898x1996，且相異畫面比例須達 80%。"
MIRAGE_TRANSPORT=mmap MIRAGE_LIVE=1 MIRAGE_LIVE_MMAP=1 MIRAGE_MMAP_FRAMES=120 \
  swift test --filter MmapStreamLiveTests 2>&1 \
  | grep -E "\[mmap-live\]|Test run with|✘"
MMAP_STATUS=${PIPESTATUS[0]}
assert_ok "MmapStreamLiveTests（至少 120 幀、80% 相異率）" "$MMAP_STATUS"

# **量測後回檢（D54／D50）**。量測前的門檻擋不住「開始時安靜、擷取途中才飆高」。
# 這裡不猜門檻，只做一件事——把前後兩個負載都印出來，並在明顯上升時明講。
echo ""
echo "=== 收尾：量測期間的負載變化 ==="
LOAD_AFTER=$(load_avg_1min)
echo "   量測前 ${LOAD_BEFORE} → 量測後 ${LOAD_AFTER}"
if awk -v a="$LOAD_BEFORE" -v b="$LOAD_AFTER" 'BEGIN { exit !(b > a * 1.5 && b > 8) }'; then
  echo "⚠️  負載在量測期間明顯上升——**本次的 distinct 數字不可信，請重測**。"
  echo "   （量測前的門檻擋不住這種情況，這就是 D50 的形狀。）"
fi

# 仍需在相同的 emulator、畫面內容和主機負載下比較結果；2026-08-05 曾出現明顯的跨次波動，
# 2026-10-01 的三輪交錯數據列於 app/RESULTS-mmap.md。
echo ""
echo "⚠️  比較不同跑次時，請一併記錄 emulator、畫面內容與主機負載。"

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
# 前面那道「開跑前先清乾淨」是這條斷言成立的前提——沒有它，這個較寬的 glob 會被
# 別人（probe_mmap*.py）留下的殘留誤觸發。
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
