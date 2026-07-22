#!/usr/bin/env bash
# phase0/scripts/02_boot_headless.sh
set -euo pipefail
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
GRPC_PORT="${GRPC_PORT:-8554}"
exec "$SDK/emulator/emulator" @mirage-poc \
  -no-window -no-audio -no-boot-anim \
  -gpu host \
  -grpc "$GRPC_PORT"
