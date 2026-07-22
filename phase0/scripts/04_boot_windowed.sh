#!/usr/bin/env bash
# phase0/scripts/04_boot_windowed.sh
# 有視窗模式：Qt 視窗以主機 GPU 全速渲染，供 ScreenCaptureKit 擷取（Phase 0c）。
# 注意：視窗會出現在桌面上；驗證期間請勿關閉。
set -euo pipefail
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
GRPC_PORT="${GRPC_PORT:-8554}"
exec "$SDK/emulator/emulator" @mirage-poc \
  -no-audio -no-boot-anim \
  -gpu host \
  -grpc "$GRPC_PORT"
