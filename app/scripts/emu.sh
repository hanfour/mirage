#!/usr/bin/env bash
# 模擬器的單一入口：start（冪等）／stop／status。
#
# **存在的理由**：量測用的 emulator 一直是人工啟動的，沒有任何腳本負責它，
# 於是每次的旗標與埠號都靠人記得。今天實測過幾個會咬人的點：
#   - 不指定 `-grpc` 會拿到隨機埠（實測 54098），Mirage 與所有 verify_* 都連不上。
#   - 沒有 `-no-snapshot-save`，每次關閉會寫約 3.8G 的快照，磁碟很快見底。
#   - 用快照開機會帶著上次的狀態，量測結果不可比（音訊崩潰態會被一起帶進來）。
#   - 只給 `-grpc` 會綁在 `[::]`、不驗證，整個區域網路都能操作模擬器（D73）。
#     加 `-grpc-use-token` 後改綁 127.0.0.1 並要求 token；Mirage 與 tools/probe
#     會自己從探索檔讀 token，phase0/harness 的舊腳本則連不上（見該目錄 README）。
#
# ⚠️ 埠號刻意用 5554／8554：`app/scripts/` 底下多數 verify_* 預設這組。
# `tools/probe/lib/targets.py` 的 `game` 用的是 5556／8556，兩套慣例並存，
# 用 probe 時要自己覆寫。
set -uo pipefail
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
EMULATOR="$SDK/emulator/emulator"
ADB="$SDK/platform-tools/adb"
AVD="${MIRAGE_AVD:-mirage-game}"
PORT="${MIRAGE_PORT:-5554}"
GRPC="${MIRAGE_GRPC:-8554}"
SERIAL="emulator-${PORT}"

booted() { [ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; }
running() { pgrep -f "qemu-system.*${AVD}" >/dev/null 2>&1 || pgrep -f qemu-system >/dev/null 2>&1; }
# gRPC 綁在哪個位址：`*` 表示對整個區域網路開放（沒用 -grpc-use-token 啟動的舊實例）。
grpc_bind() { lsof -nP -iTCP:"$GRPC" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $9}'; }
warn_if_open() {
  case "$(grpc_bind)" in
    \*:*) echo "⚠️ gRPC 綁在 $(grpc_bind)，對區域網路開放且沒有驗證。請 stop 後重新 start。" >&2 ;;
  esac
}

case "${1:-start}" in
  start)
    if running && booted; then echo "✅ 已在執行且開機完成（${SERIAL}，gRPC ${GRPC}）"; warn_if_open; exit 0; fi
    if running; then echo "⏳ 已在執行，等待開機完成…"; else
      echo "▶︎ 啟動 ${AVD}（port ${PORT}／gRPC ${GRPC}，冷開機、離開不存快照）"
      nohup "$EMULATOR" -avd "$AVD" -no-snapshot -port "$PORT" -grpc "$GRPC" -grpc-use-token \
        < /dev/null > "${TMPDIR:-/tmp}/mirage-emu.log" 2>&1 &
      sleep 8
    fi
    for _ in $(seq 1 60); do booted && { echo "✅ 開機完成（${SERIAL}）"; exit 0; }; sleep 3; done
    echo "❌ 90 秒內未開機完成，log：${TMPDIR:-/tmp}/mirage-emu.log" >&2; exit 1
    ;;
  stop)
    running || { echo "已經沒有在執行"; exit 0; }
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1
    for _ in $(seq 1 30); do running || { echo "✅ 已停止（未寫快照）"; exit 0; }; sleep 2; done
    echo "⚠️ 30 秒內沒停下來。**不要用 kill -9**（會留孤兒行程），再等或手動關視窗。" >&2; exit 1
    ;;
  status)
    if ! running; then echo "未執行"; exit 1; fi
    booted && st="開機完成" || st="開機中"
    printf '執行中：%s（%s）\n' "$SERIAL" "$st"
    printf '  gRPC 綁定：%s\n' "$(grpc_bind)"; warn_if_open
    printf '  磁碟可用：%s\n' "$(df -h / | tail -1 | awk '{print $4}')"
    printf '  前景：%s\n' "$("$ADB" -s "$SERIAL" shell dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity | grep -oE '[a-z][a-z.]+/[A-Za-z.]+' | head -1)"
    ;;
  *) echo "用法：$0 [start|stop|status]" >&2; exit 2 ;;
esac
