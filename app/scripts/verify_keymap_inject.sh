#!/usr/bin/env bash
# 驗收 3：引擎→sendTouches 活體注入，show_touches 佐證。需模擬器執行中。
#
# 修的是什麼（2026-07-30，D9）：原本這支腳本**永遠回傳 0**。`swift test` 的退出碼從未
# 被讀取，而最後一行是 `adb shell settings put`——測試整組紅掉，腳本照樣 exit 0。
# 它是這批「驗證腳本本身不做驗證」裡最直接的一支：唯一的斷言來源（那個 live test）
# 的成敗被整個丟棄，只留下一張沒有人比對的擷圖。
set -uo pipefail
source "$(dirname "$0")/lib/verify_common.sh"

require_device "${ANDROID_SERIAL:-emulator-5554}"
require_grpc 8554

# show_touches 一定要還原，包括測試失敗中止的路徑——原本的寫法在中途失敗時會把
# guest 永久留在「顯示觸控點」狀態，下一個人得自己發現並手動關掉。
restore_show_touches() { "$ADB" shell settings put system show_touches 0 > /dev/null 2>&1 || true; }
trap restore_show_touches EXIT

"$ADB" shell settings put system show_touches 1
cd "$(dirname "$0")/.." || exit 1

echo "=== 引擎→多指注入活體測試 ==="
MIRAGE_LIVE=1 swift test --filter KeymapInjectLiveTests 2>&1 | tail -4
assert_ok "KeymapInjectLiveTests" "${PIPESTATUS[0]}"

SHOT=/tmp/mirage_keymap_inject.png
"$ADB" exec-out screencap -p > "$SHOT"
# 擷圖是**佐證素材，不是斷言**——沒有任何東西比對它的內容。如實這樣講，不要讓
# 「有一張圖」被當成「驗過了」。真正的判定來自上面那條 assert_ok。
echo "擷圖（人工佐證用，非斷言）：$SHOT"
