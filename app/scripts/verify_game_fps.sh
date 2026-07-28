#!/usr/bin/env bash
# app/scripts/verify_game_fps.sh
#
# Phase-1 驗收線 1：量 Mirage 顯示真實遊戲時的 fps。
#
# 為什麼需要「動畫來源」：`streamScreenshot` 是**變化驅動**的——畫面靜止時完全不出幀
# （phase0/RESULTS.md「Change-driven stream 特性」）。多數手遊在沒人操作時畫面是靜止的，
# 所以直接開著遊戲量會得到 0 fps，那不是效能問題。本腳本開 `pointer_location` 疊層並
# 持續注入滑動，保證每一幀都有像素變化。
#
# 為什麼要你從自己的終端機跑：Mirage 是 GUI app。從非互動 session 啟動的 bare executable
# 會被 macOS 視為 background-only，視窗存在但 render loop 不被驅動，fps 恆為 0
# （見 `docs/specs/2026-07-28-phase1-game-recon.md`）。**這個腳本必須在你的終端機執行。**
#
# 用法：
#   ./scripts/verify_game_fps.sh                        # 預設 5558 / 8558，量 30 秒
#   ./scripts/verify_game_fps.sh -s emulator-5558 -p 8558 -g com.loomgames.pixelflow -d 60
set -uo pipefail

SERIAL="emulator-5558"
GRPC_PORT="8558"
PACKAGE="com.loomgames.pixelflow"
DURATION=30

while getopts "s:p:g:d:h" opt; do
  case "$opt" in
    s) SERIAL="$OPTARG" ;;
    p) GRPC_PORT="$OPTARG" ;;
    g) PACKAGE="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "用法：$0 [-s serial] [-p grpc_port] [-g package] [-d seconds]" >&2; exit 2 ;;
  esac
done

# adb 常不在 PATH 上；用與 AdbClient.standard() 相同的推導順序。
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
ADB="$SDK/platform-tools/adb"
[ -x "$ADB" ] || { echo "找不到可執行的 adb：$ADB" >&2; exit 1; }

APP="$(cd "$(dirname "$0")/.." && pwd)/.build/release/MirageApp"
[ -x "$APP" ] || { echo "找不到 ${APP}——請先跑 swift build -c release" >&2; exit 1; }

"$ADB" -s "$SERIAL" get-state >/dev/null 2>&1 \
  || { echo "裝置 $SERIAL 不在線上（adb devices 看看）" >&2; exit 1; }

LOG=$(mktemp -t mirage_game_fps)
ANIM_PID=""
ORIG_POINTER=$("$ADB" -s "$SERIAL" shell settings get system pointer_location 2>/dev/null | tr -d '\r')

cleanup() {
  [ -n "$ANIM_PID" ] && kill "$ANIM_PID" 2>/dev/null
  pkill -x MirageApp 2>/dev/null
  # 還原：疊層是為了量測而開的，不還原會一直留在使用者的裝置上。
  case "$ORIG_POINTER" in
    ""|null) "$ADB" -s "$SERIAL" shell settings put system pointer_location 0 >/dev/null 2>&1 ;;
    *)       "$ADB" -s "$SERIAL" shell settings put system pointer_location "$ORIG_POINTER" >/dev/null 2>&1 ;;
  esac
}
trap cleanup EXIT INT TERM

echo "[fps] 啟動 $PACKAGE 於 $SERIAL"
"$ADB" -s "$SERIAL" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 8

FG=$("$ADB" -s "$SERIAL" shell dumpsys activity activities 2>/dev/null \
     | grep topResumedActivity | tr -d '\r' | head -1)
echo "[fps] 前景：${FG:-（查不到）}"
case "$FG" in
  *"$PACKAGE"*) ;;
  *) echo "[fps] 警告：$PACKAGE 不在前景，量到的不是它的 fps" >&2 ;;
esac

echo "[fps] 開啟 pointer_location 疊層並持續注入滑動（保證畫面變化）"
"$ADB" -s "$SERIAL" shell settings put system pointer_location 1 >/dev/null 2>&1
( while :; do "$ADB" -s "$SERIAL" shell input swipe 400 900 700 1500 250 >/dev/null 2>&1; done ) &
ANIM_PID=$!

echo "[fps] 啟動 Mirage → localhost:${GRPC_PORT}，量測 ${DURATION}s"
MIRAGE_PORT="$GRPC_PORT" MIRAGE_FPS_LOG=1 "$APP" > "$LOG" 2>&1 &
sleep "$DURATION"

# grep -c 沒命中時**已經會印出 0**、同時回傳 1。寫成 `|| echo 0` 會再補一個 0，
# 讓 SAMPLES 變成兩行、後面的 -eq 直接爆掉——而那正是沒量到幀時必然走到的路徑。
SAMPLES=$(grep -c 'fps=' "$LOG" 2>/dev/null || true)
echo ""
echo "===== 結果 ====="
grep 'fps=' "$LOG" | tail -20
echo ""
if [ "$SAMPLES" -eq 0 ]; then
  echo "取樣數 0——Mirage 沒有畫任何一幀。前兩行輸出："
  head -2 "$LOG"
  echo ""
  echo "最常見原因：這個腳本不是從互動式終端機跑的（GUI app 變成 background-only，"
  echo "render loop 不被驅動）。請在你自己的終端機視窗執行。log：$LOG"
  exit 1
fi
grep 'fps=' "$LOG" | sed 's/.*fps=//' | awk -v n="$SAMPLES" '
  { s += $1; if (min == "" || $1 < min) min = $1; if ($1 > max) max = $1 }
  END { printf "取樣 %d 筆　平均 %.1f fps　最低 %d　最高 %d\n", n, s/n, min, max }'
echo "驗收線：60fps 穩定（母計畫 §7 Phase-1）"
echo "log：$LOG"
