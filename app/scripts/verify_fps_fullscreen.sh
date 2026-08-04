#!/usr/bin/env bash
# D45：驗收線 7 的重驗——全螢幕串流解析度上限（900×2000）下的 fps。
#
# **與 verify_game_fps.sh 的分工**：那支量「當下視窗尺寸下的 fps」，用途是日常除錯；
# 這支專為驗收線 7，強制全螢幕、斷言串流尺寸真的收斂到上限、並同時量不經過 Mirage 的
# 對照組。判準是比值不是絕對值——完整推導見
# docs/specs/2026-08-04-d45-acceptance-7-remeasure-design.md。
#
# **為什麼要對照組**：不經過 Mirage 的直接消費者在 540×1200 也只有 30.4 fps
# （investigation §11.1），Mirage 側 20–35，兩者一致。絕對 fps 衡量的是這台模擬器產生
# 畫面的能力，不是 Mirage 的效能。
#
# 用法：
#   ./scripts/verify_fps_fullscreen.sh                       # 預設 5556/8556/Pixel Flow，3 輪各 20 秒
#   ./scripts/verify_fps_fullscreen.sh -r 5 -d 30
#
# 前置：
#   - 模擬器不可帶 -no-window（要真 GUI 合成）
#   - 本機螢幕須 2560×1600 以上，否則全螢幕算不到 900×2000
#   - 遊戲必須停在**會持續變化**的畫面（streamScreenshot 是變化驅動的）
#   - phase0/harness/.venv-d45 已建好（見 phase0/harness/README-venv.md）
set -uo pipefail
source "$(dirname "$0")/lib/verify_common.sh"
source "$(dirname "$0")/lib/gui_session.sh"
source "$(dirname "$0")/lib/load_sentinel.sh"

SERIAL="emulator-5556"
GRPC_PORT="8556"
PACKAGE="com.loomgames.pixelflow"
ROUNDS=3
DURATION=20
LOAD_LIMIT=8

while getopts "s:p:g:r:d:l:h" opt; do
  case "$opt" in
    s) SERIAL="$OPTARG" ;;
    p) GRPC_PORT="$OPTARG" ;;
    g) PACKAGE="$OPTARG" ;;
    r) ROUNDS="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    l) LOAD_LIMIT="$OPTARG" ;;
    h) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "用法：$0 [-s serial] [-p port] [-g package] [-r rounds] [-d seconds] [-l load上限]" >&2; exit 2 ;;
  esac
done

for v in ROUNDS DURATION; do
  eval "val=\$${v}"
  case "$val" in ''|*[!0-9]*) echo "❌ -${v} 只接受正整數：實測 '${val}'。" >&2; exit 2 ;; esac
done
[ "$DURATION" -lt 10 ] && { echo "❌ -d 不得低於 10 秒：太短的取樣窗拿不到穩定的中位數。" >&2; exit 2; }

VENV="$(dirname "$0")/../../phase0/harness/.venv-d45/bin/python"
BASELINE="$(dirname "$0")/../../phase0/harness/fps_baseline.py"
[ -x "$VENV" ] || { echo "❌ 找不到 venv：${VENV}（見 phase0/harness/README-venv.md）" >&2; exit 2; }

require_device "$SERIAL"
require_grpc "$GRPC_PORT"

echo ""
echo "=== 啟動遊戲：$PACKAGE ==="
"$ADB" -s "$SERIAL" shell monkey -p "$PACKAGE" -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
sleep 8
FG=$("$ADB" -s "$SERIAL" shell dumpsys activity activities 2>/dev/null \
     | grep topResumedActivity | tr -d '\r' | head -1)
case "$FG" in
  *"$PACKAGE"*) echo "✅ $PACKAGE 在前景" ;;
  *) echo "❌ $PACKAGE 不在前景——沒有畫面來源，量測沒有意義。"; exit 1 ;;
esac

MIRAGE_VALS=""
BASE_VALS=""
SIZE_OK=1

for round in $(seq 1 "$ROUNDS"); do
    echo ""
    echo "=== 第 ${round}/${ROUNDS} 輪 ==="
    if ! load_gate "$LOAD_LIMIT"; then
        echo "   跳過本輪並重試（不把髒樣本算進去）"
        continue
    fi

    LOG=$(mktemp -t d45_mirage)
    BUNDLE=$(mktemp -d -t d45_bundle)
    if ! gui_session_start "$LOG" "$BUNDLE" "" \
            "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1"; then
        gui_session_cleanup "$BUNDLE"; rm -f "$LOG"; exit 1
    fi

    # 進全螢幕。⌃⌘F 是產品的既有快捷鍵（AppModel+FullScreen.swift 綁在選單列）。
    osascript -e 'tell application "System Events" to keystroke "f" using {control down, command down}' \
        > /dev/null 2>&1
    # resizeDebounced 有 300ms 去抖，再加一次 setStreamSize 往返——給它足夠時間收斂。
    sleep 5

    # **斷言串流尺寸真的到上限**。全螢幕若沒進去（或螢幕太小），這裡就會是別的數字，
    # 那樣量到的 fps 不是驗收線 7 要的東西。D32 的失敗正是尺寸沒收斂就開始計時。
    if grep -q 'attachStream.*900x2000' "$LOG"; then
        echo "✅ 串流尺寸已收斂到 900x2000（解析度上限）"
    else
        echo "⚠️ 串流尺寸不是 900x2000，本輪數字不代表解析度上限："
        grep 'attachStream' "$LOG" | sed 's/.*請求 /   請求 /' | sort -u
        SIZE_OK=0
    fi

    BEFORE=$(fps_samples "$LOG")
    sleep "$DURATION"
    M=$(fps_median "$LOG")
    echo "   Mirage 側：中位數 ${M} fps（取樣 $(fps_samples "$LOG") 筆，量測前已有 ${BEFORE} 筆）"

    # **關掉 Mirage 再量對照組**——不並行。兩個 client 同時拉同一條串流，
    # emulator 得做兩份工，量到的是「兩個消費者下的幀率」而非任一方的能力。
    gui_session_cleanup "$BUNDLE"
    sleep 3

    # 對照組是三態的（Task 1 定案）：退出碼 0=measured、2=static（畫面靜止，合法但無
    # 樣本）、1=error（連線或工具失敗）。**必須分流**——把 static 與 error 都當成
    # 「0 fps 的合法樣本」算進中位數，會把「這輪沒量到」偽裝成「這輪很慢」。
    BASE_OUT=$("$VENV" "$BASELINE" --endpoint "localhost:${GRPC_PORT}" \
        --seconds "$DURATION" --width 900 --height 2000 2>/tmp/d45-baseline-err.log)
    BASE_RC=$?
    case "$BASE_RC" in
        0) B=$(printf '%s' "$BASE_OUT" | sed 's/.*fps=\([0-9.]*\).*/\1/')
           # **兩側的 fps 定義不對稱，這裡要抓出會放大它的情況。**
           # Mirage 側：Renderer 只在有幀 present 時才印 `fps=` 行，靜止的秒根本不產生
           # 日誌行 → fps_median 天然排除靜止期。
           # 對照組：fps = frames / elapsed，而 elapsed 是完整壁鐘時間 → 靜止的尾段會
           # 把它拉低。
           # 所以畫面若「前段有動、後段靜止」，分母被低估、比值被高估，7a 反而更容易過
           # ——這是系統性偏誤，方向剛好是最不該有的那個。
           # elapsed 明顯超過 DURATION，就是踩到這個情況的指紋（工具的 RPC timeout 是
           # DURATION+2，正常收工應該貼近 DURATION）。
           BE=$(printf '%s' "$BASE_OUT" | sed 's/.*elapsed=\([0-9.]*\).*/\1/')
           if awk -v e="$BE" -v d="$DURATION" 'BEGIN { exit !(e > d * 1.1) }'; then
               echo "   ⚠️ 對照組 elapsed=${BE}s 明顯超過 ${DURATION}s——畫面可能有靜止尾段，"
               echo "      這一輪的比值會偏高（分母被低估）。本輪不計入。"
               B=""
           else
               echo "   對照組：${B} fps（elapsed=${BE}s）"
           fi ;;
        2) B=""
           echo "   對照組：畫面靜止、整個窗口沒有出幀——本輪不計入" ;;
        *) B=""
           echo "   對照組：失敗（退出碼 ${BASE_RC}）——本輪不計入"
           sed 's/^/     /' /tmp/d45-baseline-err.log ;;
    esac

    if [ -n "$M" ] && [ -n "$B" ]; then
        R=$(awk -v m="$M" -v b="$B" 'BEGIN { printf "%d", (b > 0) ? m * 100 / b : 0 }')
        echo "[round ${round}] mirage=${M} baseline=${B} ratio=${R}%"
        MIRAGE_VALS="${MIRAGE_VALS}${M}\n"
        BASE_VALS="${BASE_VALS}${B}\n"
    fi
    rm -f "$LOG"
done

median_of() { printf "%b" "$1" | grep -v '^$' | sort -n | awk '{ v[NR]=$1 } END { if (NR) printf "%d\n", v[int((NR+1)/2)]; else print 0 }'; }

echo ""
echo "===== 解析結果 ====="
MM=$(median_of "$MIRAGE_VALS")
BM=$(median_of "$BASE_VALS")
echo "MIRAGE_MEDIAN=${MM}"
echo "BASELINE_MEDIAN=${BM}"
echo "RATIO_PCT=$(awk -v m="$MM" -v b="$BM" 'BEGIN { printf "%d", (b > 0) ? m * 100 / b : 0 }')"
echo "ROUNDS=$(printf "%b" "$MIRAGE_VALS" | grep -cv '^$')"
echo "SIZE_OK=${SIZE_OK}"

echo ""
echo "⚠️ 探測版：本腳本目前**沒有任何斷言**，退出碼永遠是 0。"
echo "   門檻要依這份輸出決定後才加（見 docs/plans/2026-08-04-d45-acceptance-7-remeasure.md Task 5）。"
