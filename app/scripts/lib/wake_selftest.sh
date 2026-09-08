#!/bin/bash
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 "$HERE/wake_selftest.py" || exit 1
# D69：⌘Q 的退出路徑改走 CGEvent（見 cgkey.js 檔頭），這支自我測試鎖住它的參數驗證
# 與「down 和 up 都要帶修飾鍵」這條，全程用 mock、不送出任何真實事件。
if osascript -l JavaScript "$HERE/cgkey_selftest.js" "$HERE/cgkey.js" > /dev/null 2>&1; then
    echo 'PASS: cgkey.js 自我測試通過'
else
    echo 'FAIL: cgkey.js 自我測試失敗（重跑 osascript -l JavaScript lib/cgkey_selftest.js lib/cgkey.js 看細節）'
    exit 1
fi
source "$HERE/input_latency.sh"
input_latency_cpu_gate 49 || exit 1
if input_latency_cpu_gate 50; then
    echo 'FAIL: shell CPU gate accepted 50%'; exit 1
fi
echo 'PASS: shell CPU gate rejects 50%'
