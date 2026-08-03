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
# ⚠️ 2026-07-28 更正：本檔原本寫著「必須從你自己的終端機跑，否則 bare executable 會被
# macOS 視為 background-only、render loop 不被驅動、fps 恆為 0」。**那個歸因是錯的**，
# 而且它跟 RESULTS-p1a.md 的「螢幕鎖定」是同一個誤診的不同說法。真正讓 `fps=` 恆為 0 的是
# `AudioPlayer` 用 interleaved 格式呼叫 `AVAudioEngine.connect` 丟出 NSException 打死
# MainActor（見 `docs/specs/2026-07-28-mirror-never-rendered-investigation.md` §6）。
# 修好之後本腳本在非互動 session 一樣量得到 fps，不需要人守著。
#
# 為什麼要印串流尺寸：fps 對串流解析度敏感（launcher 上 540x1200 約 50fps、888x1972
# 約 20fps）。⚠️ 但「面積與 fps 成反比」這個推論**只在 launcher 上成立**——在真實遊戲
# 上實測降到 1/4 解析度，fps 只從 30.4 升到 32.3，瓶頸不在傳輸（見調查記錄 §11）。
# 無論如何，**沒有附上尺寸的 fps 數字無法解讀**。而串流尺寸由視窗大小經
# `resizeDebounced` 決定，會隨視窗變動。本腳本因此固定開
# `MIRAGE_CONN_LOG=1` 並把實際請求的尺寸印進結果。
#
# 用法：
#   ./scripts/verify_game_fps.sh                        # 預設 5558 / 8558，量 30 秒
#   ./scripts/verify_game_fps.sh -s emulator-5558 -p 8558 -g com.loomgames.pixelflow -d 60
#   ./scripts/verify_game_fps.sh -s emulator-5554 -p 8554 -g ""   # 不開 App，只量 launcher
#   ./scripts/verify_game_fps.sh -a /path/to/other/MirageApp      # 指定二進位（做版本對照用）
#   ./scripts/verify_game_fps.sh -n -g "" -s emulator-5556 -p 8556 # 不注入，量遊戲自己的畫面
#
# `-n`（不注入動畫）：關掉疊層與滑動注入器。**量關卡內的 fps 必須用它**——遊戲進行中
# 畫面本來就不停變化，不需要人造動畫源；而注入器會真的去點畫面，可能退出關卡或叫出
# 暫停選單，量到的變成「關卡內＋機器人亂點」。注入器存在的理由只是對付靜止的主選單／
# launcher，那是它唯一該用的場合。搭配 `-g ""`（不重新啟動 App）就能量當下已經在跑的
# 畫面，不會把遊戲重啟回主選單。
set -uo pipefail

source "$(dirname "$0")/lib/gui_session.sh"

SERIAL="emulator-5558"
GRPC_PORT="8558"
PACKAGE="com.loomgames.pixelflow"
DURATION=30

APP_OVERRIDE=""
INJECT=1

while getopts "s:p:g:d:a:nh" opt; do
  case "$opt" in
    s) SERIAL="$OPTARG" ;;
    p) GRPC_PORT="$OPTARG" ;;
    g) PACKAGE="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    a) APP_OVERRIDE="$OPTARG" ;;
    n) INJECT=0 ;;
    h) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "用法：$0 [-s serial] [-p grpc_port] [-g package] [-d seconds] [-a app_path] [-n]" >&2; exit 2 ;;
  esac
done

# adb 常不在 PATH 上；用與 AdbClient.standard() 相同的推導順序。
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
ADB="$SDK/platform-tools/adb"
[ -x "$ADB" ] || { echo "找不到可執行的 adb：$ADB" >&2; exit 1; }


"$ADB" -s "$SERIAL" get-state >/dev/null 2>&1 \
  || { echo "裝置 $SERIAL 不在線上（adb devices 看看）" >&2; exit 1; }

LOG=$(mktemp -t mirage_game_fps)
ANIM_PID=""

# **必須以 .app bundle 啟動，不能直接跑 bare executable。**
# 直接跑 bare executable 時 macOS 不一定會把視窗合成上螢幕，MTKView 的
# currentDrawable 因此為 nil、Renderer 早退，present 一次都不發生——而幀其實
# 都正常進來了。症狀是「取樣數 0」但 log 裡 `幀 #N` 一路在跑。2026-07-28 實測
# 這是**不穩定**的：同樣的指令有時量得到、有時完全量不到，所以不是「偏低」
# 而是「不可信」。包成 bundle 之後 activation policy 才是 .regular。
# 打包交給 `scripts/package_app.sh`（D25）。原本這裡自己 `cp` executable 就當成 .app，
# **不複製 resource bundle**——在有 `.build/` 的開發機上照跑（`Bundle.module` 默默從編譯
# 當下寫死的絕對路徑讀），換一台機器或 `swift package clean` 之後就是啟動即崩。
# 已用 A/B 實測確認：藏掉 `.build` 的後備路徑後，自帶資源的 .app 正常啟動，
# 不帶資源的 .app 退出碼 133（fatalError: could not load resource bundle）。
#
# 順帶讓「怎麼組 .app」只有一份定義——這裡與 D30 除錯時各組一份的重複，正是漂移的起點。
BUNDLE=$(mktemp -d -t mirage_fps_bundle)
ORIG_POINTER=$("$ADB" -s "$SERIAL" shell settings get system pointer_location 2>/dev/null | tr -d '\r')

cleanup() {
  [ -n "$ANIM_PID" ] && kill "$ANIM_PID" 2>/dev/null
  gui_session_cleanup "${BUNDLE:-}"
  # 還原：疊層是為了量測而開的，不還原會一直留在使用者的裝置上。
  case "$ORIG_POINTER" in
    ""|null) "$ADB" -s "$SERIAL" shell settings put system pointer_location 0 >/dev/null 2>&1 ;;
    *)       "$ADB" -s "$SERIAL" shell settings put system pointer_location "$ORIG_POINTER" >/dev/null 2>&1 ;;
  esac
}
trap cleanup EXIT INT TERM

echo "[fps] 二進位：${APP_OVERRIDE:-（預設 .build/release/MirageApp）}"
if [ -n "$PACKAGE" ]; then
  echo "[fps] 啟動 $PACKAGE 於 $SERIAL"
  "$ADB" -s "$SERIAL" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 8
else
  echo "[fps] 未指定套件——量當前前景（對照組用）"
fi

FG=$("$ADB" -s "$SERIAL" shell dumpsys activity activities 2>/dev/null \
     | grep topResumedActivity | tr -d '\r' | head -1)
echo "[fps] 前景：${FG:-（查不到）}"
if [ -n "$PACKAGE" ]; then
  case "$FG" in
    *"$PACKAGE"*) ;;
    *) echo "[fps] 警告：$PACKAGE 不在前景，量到的不是它的 fps" >&2 ;;
  esac
fi

if [ "$INJECT" -eq 1 ]; then
  echo "[fps] 開啟 pointer_location 疊層並持續注入滑動（保證畫面變化）"
  "$ADB" -s "$SERIAL" shell settings put system pointer_location 1 >/dev/null 2>&1
  ( while :; do "$ADB" -s "$SERIAL" shell input swipe 400 900 700 1500 250 >/dev/null 2>&1; done ) &
  ANIM_PID=$!
else
  echo "[fps] -n：不注入動畫，量畫面自己的變化率（關卡內請用這個）"
fi

echo "[fps] 啟動 Mirage（.app bundle）→ localhost:${GRPC_PORT}，量測 ${DURATION}s"
if ! gui_session_start "$LOG" "$BUNDLE" "$APP_OVERRIDE" \
        "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1"; then
    exit 1
fi
sleep "$DURATION"

echo ""
echo "===== 結果 ====="
grep 'fps=' "$LOG" | tail -20
echo ""
if ! fps_summary "$LOG"; then
    exit 1
fi
if [ "$INJECT" -eq 1 ]; then
  echo "動畫來源：注入（疊層＋持續滑動）——這是人造負載，不代表真實遊玩"
else
  echo "動畫來源：無注入，畫面自己的變化率"
fi
echo "驗收線：60fps 穩定（母計畫 §7 Phase-1）"
echo "log：$LOG"
