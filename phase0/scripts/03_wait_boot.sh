#!/usr/bin/env bash
# phase0/scripts/03_wait_boot.sh
set -euo pipefail
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
"$ADB" wait-for-device
until [[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
  sleep 1
done
echo BOOTED
