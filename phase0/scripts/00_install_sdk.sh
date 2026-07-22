#!/usr/bin/env bash
# phase0/scripts/00_install_sdk.sh
# 冪等：已有 Android Studio 的 SDK 就直接沿用，缺什麼裝什麼。
set -euo pipefail

SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
SDKMANAGER="$SDK/cmdline-tools/latest/bin/sdkmanager"
IMAGE="system-images;android-35;default;arm64-v8a"

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "錯誤：本專案僅支援 Apple Silicon（偵測到 $(uname -m)）" >&2
  exit 1
fi

if [[ ! -x "$SDKMANAGER" ]]; then
  echo "找不到 sdkmanager：$SDKMANAGER" >&2
  echo "請至 https://developer.android.com/studio#command-line-tools-only 下載 macOS zip，" >&2
  echo "解壓後將 zip 內的 cmdline-tools/ 放到 $SDK/cmdline-tools/latest/" >&2
  exit 1
fi

yes | "$SDKMANAGER" --licenses > /dev/null || true
"$SDKMANAGER" "platform-tools" "emulator" "$IMAGE"

"$SDK/emulator/emulator" -version | head -1
"$SDK/platform-tools/adb" --version | head -1
echo "OK: SDK ready at $SDK"
