#!/usr/bin/env bash
# phase0/scripts/01_create_avd.sh
set -euo pipefail
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
AVDMANAGER="$SDK/cmdline-tools/latest/bin/avdmanager"
NAME="mirage-poc"

if "$AVDMANAGER" list avd | grep -q "Name: $NAME"; then
  echo "OK: AVD $NAME 已存在"
  exit 0
fi
echo no | "$AVDMANAGER" create avd \
  -n "$NAME" \
  -k "system-images;android-35;default;arm64-v8a" \
  -d pixel_7
echo "OK: AVD $NAME created"
