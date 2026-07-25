#!/usr/bin/env bash
# 驗收 3：引擎→sendTouches 活體注入，show_touches 佐證。需模擬器執行中。
set -uo pipefail
export ANDROID_SERIAL=emulator-5554
ADB="$HOME/Library/Android/sdk/platform-tools/adb"
"$ADB" shell settings put system show_touches 1
cd "$(dirname "$0")/.."
MIRAGE_LIVE=1 swift test --filter KeymapInjectLiveTests 2>&1 | tail -4
"$ADB" exec-out screencap -p > /tmp/mirage_keymap_inject.png && echo "擷圖 /tmp/mirage_keymap_inject.png"
"$ADB" shell settings put system show_touches 0
