#!/usr/bin/env bash
# gui_session.sh 的幀計數解析自我測試。
# 不需要模擬器、不需要 adb，故障時能直接驗證解析是否真的會失敗。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/gui_session.sh"
FAILURES=0

check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "✅ $desc"
    else
        echo "❌ ${desc}：得到 ${got}，期待 ${want}"
        FAILURES=$((FAILURES + 1))
    fi
}

SAVED_ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT-}"
SAVED_ANDROID_HOME="${ANDROID_HOME-}"
SAVED_ANDROID_AVD_HOME="${ANDROID_AVD_HOME-}"
unset ANDROID_SDK_ROOT ANDROID_HOME ANDROID_AVD_HOME
check "Android 開發環境預設值" "$(gui_session_android_environment)" \
      "ANDROID_SDK_ROOT=$HOME/Library/Android/sdk
ANDROID_AVD_HOME=$HOME/.android/avd"
ANDROID_HOME=/android-home
check "ANDROID_HOME 作為 SDK 退回值" "$(gui_session_sdk_root)" /android-home
ANDROID_SDK_ROOT=/sdk-root
check "ANDROID_SDK_ROOT 優先於 ANDROID_HOME" "$(gui_session_sdk_root)" /sdk-root
ANDROID_AVD_HOME=/custom/avds
check "ANDROID_AVD_HOME 覆寫預設值" "$(gui_session_avd_home)" /custom/avds
if [ -n "$SAVED_ANDROID_SDK_ROOT" ]; then export ANDROID_SDK_ROOT="$SAVED_ANDROID_SDK_ROOT"; else unset ANDROID_SDK_ROOT; fi
if [ -n "$SAVED_ANDROID_HOME" ]; then export ANDROID_HOME="$SAVED_ANDROID_HOME"; else unset ANDROID_HOME; fi
if [ -n "$SAVED_ANDROID_AVD_HOME" ]; then export ANDROID_AVD_HOME="$SAVED_ANDROID_AVD_HOME"; else unset ANDROID_AVD_HOME; fi

WORK=$(mktemp -d -t frame_counter_selftest)
trap 'rm -rf "$WORK"' EXIT

printf '%s\n' \
    '[app] fps=61' \
    '[app] frames arrived=12 dropped=2 presented=10' \
    '[app] draw calls=60 gap20=1 maxgap=21ms in_p95=3.4ms nodrawable=0 noframe=2' \
    '[app] lat p50=12.3ms p95=18.9ms n=57' \
    '[app] fps=59' \
    '[app] frames arrived=14 dropped=3 presented=11' \
    '[app] draw calls=59 gap20=2 maxgap=41ms in_p95=4.5ms nodrawable=1 noframe=3' \
    '[app] lat p50=13.3ms p95=19.9ms n=58' \
    '[app] fps=57' \
    '[app] frames arrived=16 dropped=4 presented=12' \
    '[app] draw calls=58 gap20=3 maxgap=61ms in_p95=5.6ms nodrawable=2 noframe=4' \
    '[app] lat p50=14.3ms p95=20.9ms n=59' \
    '[app] fps=55' \
    '[app] frames arrived=18 dropped=5 presented=13' \
    '[app] draw calls=57 gap20=4 maxgap=81ms in_p95=6.7ms nodrawable=3 noframe=5' \
    '[app] lat p50=15.3ms p95=21.9ms n=60' \
    > "$WORK/mixed.log"

echo "=== frames_median ==="
check "frames_samples 計數" \
      "$(frames_samples "$WORK/mixed.log")" 4
check "fps 與 frames 樣本一對一" \
      "$(fps_samples "$WORK/mixed.log")" "$(frames_samples "$WORK/mixed.log")"
check "arrived 中位數" \
      "$(frames_median "$WORK/mixed.log" arrived)" 14
check "dropped 中位數" \
      "$(frames_median "$WORK/mixed.log" dropped)" 3
check "presented 中位數" \
      "$(frames_median "$WORK/mixed.log" presented)" 11
check "跳過前一筆後的 arrived 中位數" \
      "$(frames_median "$WORK/mixed.log" arrived 1)" 16
check "跳過前一筆後的 dropped 中位數" \
      "$(frames_median "$WORK/mixed.log" dropped 1)" 4
check "跳過前一筆後的 presented 中位數" \
      "$(frames_median "$WORK/mixed.log" presented 1)" 12
check "跳過全部樣本回 0" \
      "$(frames_median "$WORK/mixed.log" arrived 4)" 0

echo ""
echo "=== tagged_median draw ==="
check "draw calls 中位數" \
      "$(tagged_median "$WORK/mixed.log" draw calls)" 58
check "draw gap20 中位數" \
      "$(tagged_median "$WORK/mixed.log" draw gap20)" 2
check "draw maxgap 解析 ms 後綴" \
      "$(tagged_median "$WORK/mixed.log" draw maxgap)" 41
check "draw in_p95 解析小數與 ms 後綴" \
      "$(tagged_median "$WORK/mixed.log" draw in_p95)" 4.5
check "draw nodrawable 中位數" \
      "$(tagged_median "$WORK/mixed.log" draw nodrawable)" 1
check "draw noframe 中位數" \
      "$(tagged_median "$WORK/mixed.log" draw noframe)" 3
check "draw 跳過前一行的 maxgap 中位數" \
      "$(tagged_median "$WORK/mixed.log" draw maxgap 1)" 61
check "draw 跳過前一行的 in_p95 中位數" \
      "$(tagged_median "$WORK/mixed.log" draw in_p95 1)" 5.6

echo ""
echo "=== latency_median ==="
check "latency p50 中位數" \
      "$(latency_median "$WORK/mixed.log" p50)" 13.3
check "latency p95 中位數" \
      "$(latency_median "$WORK/mixed.log" p95)" 19.9
check "latency 跳過前一行的 p95 中位數" \
      "$(latency_median "$WORK/mixed.log" p95 1)" 20.9
check "未知 latency 欄位回 0" \
      "$(latency_median "$WORK/mixed.log" p90)" 0

DRAW_SAMPLES=$(grep -c '^\[app\] draw ' "$WORK/mixed.log" 2>/dev/null || true)
check "fps／frames／draw 樣本一對一" \
      "$(fps_samples "$WORK/mixed.log")/$(frames_samples "$WORK/mixed.log")/${DRAW_SAMPLES}" 4/4/4

: > "$WORK/empty.log"
check "沒有幀樣本回 0" \
      "$(frames_median "$WORK/empty.log" arrived)" 0
check "沒有幀樣本時筆數為 0" \
      "$(frames_samples "$WORK/empty.log")" 0

echo ""
echo "=== fps_median 相容性 ==="
check "混入 frames 行不污染 fps_median" \
      "$(fps_median "$WORK/mixed.log")" 57

echo ""
echo "=== gui_screen_lock_state（D65；假資料照 ioreg 的一 key 一行格式）==="
LOCKED_PLIST=$(printf '%s\n' '<dict>' '<key>IOConsoleUsers</key>' '<array>' '<dict>' '<key>kCGSSessionUserNameKey</key>' '<string>u</string>' '<key>CGSSessionScreenIsLocked</key>' '<true/>' '</dict>' '</array>' '</dict>')
UNLOCKED_PLIST=$(printf '%s\n' '<dict>' '<key>CGSSessionScreenIsLocked</key>' '<false/>' '</dict>')
NOKEY_PLIST=$(printf '%s\n' '<dict>' '<key>kCGSSessionOnConsoleKey</key>' '<true/>' '</dict>')
check "鎖定的 plist 判 locked" "$(gui_screen_lock_state "$LOCKED_PLIST")" locked
check "未鎖定的 plist 判 unlocked" "$(gui_screen_lock_state "$UNLOCKED_PLIST")" unlocked
check "沒有該 key 判 unknown（不誤擋）" "$(gui_screen_lock_state "$NOKEY_PLIST")" unknown
check "空字串判 unknown" "$(gui_screen_lock_state "")" unknown

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "${FAILURES} 項失敗"
exit 1
