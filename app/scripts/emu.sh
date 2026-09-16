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
# -n 指定表格中的實例；未指定時選第一台並套用 MIRAGE_AVD／PORT／GRPC。
# 所有實例共用啟停邏輯，running 一律依 console 埠判斷，status 列出全部。
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/emu_instances.sh"
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
EMULATOR="$SDK/emulator/emulator"
ADB="$SDK/platform-tools/adb"

NAME=""
HEADLESS="${MIRAGE_HEADLESS:-0}"
COMMAND=""
usage() { echo "用法：$0 [-H] [-n <實例名稱>] [start|stop|status]（MIRAGE_HEADLESS=1 亦可無視窗啟動）" >&2; }
while [ "$#" -gt 0 ]; do
    case "$1" in
      -H) HEADLESS=1; shift ;;
      -n)
        NAME="${2:-}"
        case "$NAME" in
          ''|-*) echo "❌ -n 後面要接實例名稱" >&2; exit 2 ;;
        esac
        shift 2
        ;;
      start|stop|status)
        if [ -n "$COMMAND" ]; then usage; exit 2; fi
        COMMAND="$1"; shift ;;
      *) usage; exit 2 ;;
    esac
done
if [ -n "$NAME" ] && [ "${MIRAGE_AVD+x}${MIRAGE_PORT+x}${MIRAGE_GRPC+x}" != "" ]; then
    echo "⚠️ 已指定 -n，忽略 MIRAGE_AVD／MIRAGE_PORT／MIRAGE_GRPC 環境變數覆寫。" >&2
fi
TABLE="${MIRAGE_INSTANCES:-$EMU_DEFAULT_INSTANCES}"
DEFAULT_TRIPLET=$(emu_select_triplet "" "$TABLE") || exit 2
read -r DEFAULT_NAME DEFAULT_PORT DEFAULT_GRPC <<< "$DEFAULT_TRIPLET"
TRIPLET=$(emu_select_triplet "$NAME" "$TABLE" "${MIRAGE_AVD:-}" "${MIRAGE_PORT:-}" "${MIRAGE_GRPC:-}") || exit 2
NAME="${NAME:-$DEFAULT_NAME}"
read -r AVD PORT GRPC <<< "$TRIPLET"
SERIAL="emulator-${PORT}"
# 第一台保留原有 log 與 stop 訊息（含其 MIRAGE_* 覆寫）；其他實例附上 serial。
LOG="${TMPDIR:-/tmp}/mirage-emu-${PORT}.log"
STOPPED="✅ 已停止（${SERIAL}，未寫快照）"
NOT_RUNNING="已經沒有在執行（${SERIAL}）"
if [ "$NAME" = "$DEFAULT_NAME" ]; then
    LOG="${TMPDIR:-/tmp}/mirage-emu.log"
    STOPPED="✅ 已停止（未寫快照）"
    NOT_RUNNING="已經沒有在執行"
fi

# 接線測試可注入行程清單；有設但為空也代表空清單，不回頭查真實行程。
ps_lines() {
  if [ "${MIRAGE_EMU_PS_LINES+x}" = x ]; then
    printf '%s\n' "$MIRAGE_EMU_PS_LINES"
  else
    pgrep -fl qemu-system 2>/dev/null
  fi
}
booted_on() { [ "$("$ADB" -s "$1" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; }
booted() { booted_on "$SERIAL"; }
running() { emu_is_running "$(ps_lines)" "$PORT"; }
# gRPC 綁在哪個位址：`*` 表示對整個區域網路開放（沒用 -grpc-use-token 啟動的舊實例）。
grpc_bind() { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $9}'; }
warn_if_open() {
  case "$(grpc_bind "$1")" in
    \*:*) echo "⚠️ gRPC 綁在 $(grpc_bind "$1")，對區域網路開放且沒有驗證。請 stop 後重新 start。" >&2 ;;
  esac
}
foreground_on() {
  "$ADB" -s "$1" shell dumpsys activity activities 2>/dev/null | grep -m1 topResumedActivity | grep -oE '[a-z][a-z.]+/[A-Za-z.]+' | head -1
}

configure_guest_keyboard() {
  local current
  current=$("$ADB" -s "$SERIAL" shell settings get secure show_ime_with_hard_keyboard 2>/dev/null | tr -d '\r') || {
    echo "⚠️ 無法讀取 guest 軟體鍵盤設定（${SERIAL}），不影響開機成功；可稍後重跑 start" >&2; return 1;
  }
  if emu_should_disable_soft_keyboard "$current"; then
    "$ADB" -s "$SERIAL" shell settings put secure show_ime_with_hard_keyboard 0 >/dev/null 2>&1 || {
      echo "⚠️ 無法停用 guest 軟體鍵盤（${SERIAL}），不影響開機成功；可稍後重跑 start" >&2; return 1;
    }
    echo "✅ guest show_ime_with_hard_keyboard：${current:-空值} → 0（有實體鍵盤時不顯示軟體鍵盤）"
  fi
}

case "${COMMAND:-start}" in
  start)
    if [ "$HEADLESS" = 1 ] && emu_running_instances "$(ps_lines)" | awk -v p="$PORT" '
        $3 == p && $5 == "windowed" { found = 1 } END { exit !found }'; then
      echo "已在執行（有視窗）；要換成 headless 請 stop 後重開"
      exit 0
    fi
    if running && booted; then echo "✅ 已在執行且開機完成（${SERIAL}，gRPC ${GRPC}）"; warn_if_open "$GRPC"; configure_guest_keyboard || true; exit 0; fi
    if running; then echo "⏳ 已在執行，等待開機完成…"; else
      if other=$(emu_avd_conflict "$(ps_lines)" "$AVD" "$PORT"); then
        echo "❌ AVD ${AVD} 已在 console 埠 ${other} 上執行。同一個 AVD 不能開第二台——每台要各自一個 AVD（規格 §3.1），用 tools/provision 加一台再以 -n 指定。" >&2
        exit 1
      fi
      echo "▶︎ 啟動 ${AVD}（port ${PORT}／gRPC ${GRPC}，冷開機、離開不存快照）"
      EMULATOR_ARGS=(-avd "$AVD" -no-snapshot -port "$PORT" -grpc "$GRPC" -grpc-use-token)
      if [ "$HEADLESS" = 1 ]; then EMULATOR_ARGS+=(-no-window); fi
      # 量測用的額外旗標（例如 D44 在試的 `-audio none`）。以空白分隔，不做引號解析。
      if [ -n "${MIRAGE_EMU_EXTRA_ARGS:-}" ]; then
        read -ra extra <<< "$MIRAGE_EMU_EXTRA_ARGS"
        EMULATOR_ARGS+=("${extra[@]}")
        echo "額外旗標：${MIRAGE_EMU_EXTRA_ARGS}"
      fi
      nohup "$EMULATOR" "${EMULATOR_ARGS[@]}" \
        < /dev/null > "$LOG" 2>&1 &
      sleep 8
    fi
    for _ in $(seq 1 60); do booted && { echo "✅ 開機完成（${SERIAL}）"; configure_guest_keyboard || true; exit 0; }; sleep 3; done
    echo "❌ 90 秒內未開機完成，log：${LOG}" >&2; exit 1
    ;;
  stop)
    running || { echo "$NOT_RUNNING"; exit 0; }
    "$ADB" -s "$SERIAL" emu kill >/dev/null 2>&1
    for _ in $(seq 1 30); do running || { echo "$STOPPED"; exit 0; }; sleep 2; done
    echo "⚠️ 30 秒內沒停下來。**不要用 kill -9**（會留孤兒行程），再等或手動關視窗。" >&2; exit 1
    ;;
  status)
    LINES=$(emu_running_instances "$(ps_lines)")
    if [ -z "$LINES" ]; then echo "未執行"; exit 1; fi
    # adb 會吃 stdin，不能讓它讀走清單剩下的行；read 專用 fd 3，查詢的 stdin 接 /dev/null。
    while read -r pid avd port grpc window <&3; do
      serial="emulator-${port}"
      if booted_on "$serial"; then st="開機完成"; else st="開機中"; fi
      printf '執行中：%s（%s，AVD %s，pid %s）\n' "$serial" "$st" "$avd" "$pid"
      if [ "$window" = headless ]; then echo "  視窗：headless"; else echo "  視窗：有"; fi
      if [ "$grpc" = "?" ]; then
        printf '  gRPC：未指定 -grpc，隨機埠，Mirage 連不上\n'
      else
        printf '  gRPC %s 綁定：%s\n' "$grpc" "$(grpc_bind "$grpc")"; warn_if_open "$grpc"
      fi
      printf '  前景：%s\n' "$(foreground_on "$serial")"
    done 3<<< "$LINES" < /dev/null
    printf '磁碟可用：%s\n' "$(df -h / | tail -1 | awk '{print $4}')"
    ;;
  *) usage; exit 2 ;;
esac
