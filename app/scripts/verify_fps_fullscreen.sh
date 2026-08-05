#!/usr/bin/env bash
# D45：驗收線 7 的重驗——全螢幕串流解析度上限（900×2000）下的 fps。
#
# **與 verify_game_fps.sh 的分工**：那支量「當下視窗尺寸下的 fps」，用途是日常除錯；
# 這支專為驗收線 7，強制全螢幕、斷言串流尺寸真的收斂到上限、並斷言
# MIRAGE_FPS_LOG 中位數 ≥ 55（spec §8 第 7 條，固定值）。
#
# ⚠️ **判準沿革**：本腳本原本規劃用「Mirage / 對照組」的比值取代絕對值 55（見
# docs/specs/2026-08-04-d45-acceptance-7-remeasure-design.md 的原始論證：不經過
# Mirage 的對照組在 540×1200 也只有 30.4 fps，55 結構上達不到）。**2026-08-04
# 實測推翻了這個論證**：對照組實測 57/41/54/59.74，Mirage 側 35~52——55 是「差一點」
# 不是「不可能」。使用者因此裁決**判準保留 ≥55 不改**（見 progress.md、spec §9）。
# 對照組仍照量、仍印在下方「解析結果」（`BASELINE_MEDIAN`／`RATIO_PCT`），當作
# 診斷脈絡（分辨「Mirage 拖慢」vs「模擬器本身這樣」），但**不是驗收判準的一部分**。
#
# **為什麼還留著對照組量測**：不經過 Mirage 的直接消費者在同條件下的 fps 提供了
# 除錯脈絡——沒有它，看到 Mirage 側低於 55 時分不清是 Mirage 額外拖慢，還是這台
# 模擬器在這個畫面下本來就到不了 55。
#
# 用法：
#   ./scripts/verify_fps_fullscreen.sh                       # 預設 5556/8556/Pixel Flow，3 輪各 20 秒
#   ./scripts/verify_fps_fullscreen.sh -r 5 -d 30
#
# 前置：
#   - 模擬器不可帶 -no-window（要真 GUI 合成）
#   - 本機螢幕的**邏輯（非實體）解析度**高度需 ≈ 1052pt 以上，否則全螢幕也到不了
#     900×2000（Task 3 修正時實測釐清，細節見下方全螢幕區塊的長註解）。查邏輯解析度
#     （非 `system_profiler` 印的面板實體像素）：
#       osascript -e 'tell application "Finder" to get bounds of window of desktop'
#     （**不是** `get bounds of desktop`——那個查到的是別的東西，本機實測回傳
#     `473, 14, 537, 78`，明顯不是桌面尺寸；`bounds of window of desktop` 才對，
#     本機驗證回傳 `0, 0, 1680, 1050`，與 Swift `NSScreen.main.frame` 查到的一致）
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
# D45 Task 3 修正：預設 8 訂在「常態負載」的下緣（前一輪實測整場落在 8–18，一度衝到
# 17.95），幾乎每輪都被擋——那是哨兵在扼殺量測，不是在保護量測。真正的失效門檻是
# D32 記載的「load average 20+ 時 MirageScene 的 .task 根本不觸發、連續量到全 0 fps」
# （lib/load_sentinel.sh 開頭那段）。18 貼著這條線的下緣，放行 8–18 的常態波動，
# 仍擋住真正會讓 `.task` 失效的 20+ 區間。
LOAD_LIMIT=18

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

# load_gate 該輪重試次數與間隔。**擋下不等於放棄**——D45 Task 3 修正前的版本把
# `continue` 當「跳過」用，結果 `-r 3` 只吃得到 1 輪（round 預算被攔下的輪次白白吃掉）。
# 6 次、每次間隔 5 秒＝最多多等 30 秒／輪，換取真的把 ROUNDS 用滿；負載尖峰通常是
# 幾秒到十幾秒的瞬間（見前一輪報告：8–18 之間劇烈波動），5 秒間隔足以跨過大部分尖峰。
LOAD_RETRY_MAX=6
LOAD_RETRY_WAIT=5

# 進全螢幕改用 Accessibility API 直接寫 `AXFullScreen` 屬性，取代送 ⌃⌘F 鍵（Task 3
# 修正）——理由與實測見下方進全螢幕區塊的長註解。單次啟動內的收斂輪詢逾時：
FULLSCREEN_POLL_TIMEOUT=10
FULLSCREEN_POLL_INTERVAL=1

# **這台機器這片螢幕的全螢幕天花板量到的是 898（見下方長註解），到不了字面上的 900。**
# 896 卡在「視窗模式天花板 888」與「這片螢幕全螢幕天花板 898」之間：能分辨「有沒有真的
# 進全螢幕」，不強求湊到剛好等於 900 這個在本機結構上到不了的整數。換一片螢幕（邏輯
# 高度 ≳1052pt）量到的數字可能剛好是 900，這條門檻一樣放行，不用跟著改。
#
# ⚠️ **反向風險（複審指出，已記為 D51，見 docs/specs/2026-07-29-project-review.md）**：
# 888／896／898 這三個數字全部綁定在「這片邏輯 1680×1050 螢幕」上量出來的。896 目前
# 卡在兩者中間有安全邊界，但那個邊界只有 10（898−888）這麼窄。換一台視窗模式天花板
# 剛好落在 890–896 附近的機器（例如螢幕更寬、menu bar／dock 佔比不同），這條門檻可能
# 會把「根本沒進全螢幕、只是視窗剛好夠寬」誤判成「已收斂」——方向與本機發現的「全螢幕
# 到不了 900」相反，是這個數值門檻本身可能失準的情境，換機器跑之前應該重新用本檔前置
# 說明那段 osascript 量一次邏輯解析度、核對視窗模式天花板與這個門檻的間距是否還夠。
FULLSCREEN_MIN_WIDTH=896

# AXFullScreen 比鍵送可靠得多，但實測仍偶爾整次啟動都沒吃到（懷疑跟這台共用機器上其他
# Space 切換動畫互相卡到有關，機制未查清）。**擋下不等於放棄**——跟 load_gate 同一個
# 哲學：一次啟動沒收斂就砍掉重開（新視窗、新程序，不是在舊狀態上重試鍵），比在髒樣本上
# 硬量更誠實。3 次關掉重開仍不收斂才真正放棄本輪。
ROUND_RETRY_MAX=3

MIRAGE_VALS=""
BASE_VALS=""
# **獨立於 `ROUNDS` 的訊號**：`ROUNDS` 數的是有幾輪產生了 `[round N]`（有效樣本數），
# `SIZE_OK` 答的是不同的問題——這次執行有沒有踩到「解析度收斂失敗」這個故障模式本身。
# 兩者不能合併：即使最後 `ROUNDS` 湊滿了，若中途有輪次耗盡 `ROUND_RETRY_MAX` 仍未收斂
# 才勉強補回來，那就代表這台機器／這次環境對「進全螢幕」不穩定，即使樣本數字表面正常，
# 這個不穩定本身也是要讓 Task 5 的前置閘門知道的事。複審抓到的 Critical：這裡原本只
# 初始化成 1，卻沒有任何分支寫回 0，變成一個看似有檢查、實際上恆真的死變數。
SIZE_OK=1

for round in $(seq 1 "$ROUNDS"); do
    echo ""
    echo "=== 第 ${round}/${ROUNDS} 輪 ==="

    LOAD_CLEAR=0
    for load_attempt in $(seq 1 "$LOAD_RETRY_MAX"); do
        if load_gate "$LOAD_LIMIT"; then
            LOAD_CLEAR=1
            break
        fi
        echo "   load_gate 攔下（第 ${load_attempt}/${LOAD_RETRY_MAX} 次），等 ${LOAD_RETRY_WAIT} 秒後重試本輪"
        sleep "$LOAD_RETRY_WAIT"
    done
    if [ "$LOAD_CLEAR" -eq 0 ]; then
        echo "   重試 ${LOAD_RETRY_MAX} 次仍被 load_gate 擋下，放棄本輪（如實記錄，不湊數）"
        continue
    fi

    # 進全螢幕。**改用 Accessibility API 直接寫 `AXFullScreen` 屬性，取代送 ⌃⌘F 鍵**
    # （Task 3 修正）。
    #
    # **為什麼換掉鍵送**：⌃⌘F 靠 `System Events` 模擬鍵盤事件，只有 MirageApp 真的是
    # frontmost／key window 時鍵才送得到——`gui_session_start` 的 frontmost 是在
    # `sleep 6` 之後設一次，跟送鍵之間有空檔，這台共用機器上任何搶走 focus 的東西
    # （螢幕保護程式接管、frontmost 被 Chrome／Slack 搶走）都會讓鍵送空，這是連續 4 次
    # 逾時未收斂、前一輪 30 次呼叫大量失敗的根因。`set value of attribute "AXFullScreen"`
    # 直接對視窗的 Accessibility 物件寫值，不經過鍵盤事件佇列、**不需要 frontmost**
    # （實測：其他 App 仍是 frontmost 時設這個屬性一樣生效）。
    #
    # **實測發現本機這片螢幕構造性地到不了字面上的 900x2000**：用 `CGWindowListCopy-
    # WindowInfo` 核對過 MirageApp 視窗進全螢幕後確實佔滿整片螢幕（邏輯座標
    # `{0,0,1680,1050}`，與 `NSScreen.main.frame` 一致），但串流尺寸連續三次全新啟動
    # 都只收斂到同一個數字 `898x1996`（不是隨機抖動的瞬間值，是穩定終態）。回推幾何：
    # `898 = round(content_height_pt × 2 × 888/1972)` 解出 `content_height_pt ≈ 998`，
    # 比螢幕邏輯高度 1050 短少恰好 **52pt**——這正是 SwiftUI 在全螢幕下、對沒有呼叫
    # `.ignoresSafeArea()` 的畫面保留的選單列收回熱區安全區高度
    # （`MirageScene.swift` 的 `ZStack` 沒有這個修飾詞）。這是產品碼行為，修它要動
    # `app/Sources/`，超出本次「不動產品碼」的範圍。
    #
    # `898×1996 ≈ 1.79 MP`，離 `StreamSize.maxPixels`（1.8 MP）僅約 0.4%——量測上視為
    # 已達解析度上限，故收斂判定改成數值門檻 `FULLSCREEN_MIN_WIDTH`（見上方變數定義），
    # 不再要求字面上剛好等於 `900x2000`。判斷收斂看**最新一行** attachStream，不是
    # 「log 裡有沒有出現過」——啟動階段的 resize 序列本身就會短暫經過接近上限的尺寸再
    # 收斂到別的尺寸，只看「出現過」會把這個過渡瞬間誤判成真正收斂。
    #
    # **一次啟動內只送一次 AXFullScreen、poll 一輪**；沒收斂就整個關掉重開（見
    # `ROUND_RETRY_MAX`），不在同一個視窗物件上重送——診斷時懷疑沒收斂常是那次啟動的
    # Space／視窗狀態本身卡住了，重送同一個屬性不會讓它變好，重開才會換到乾淨狀態。
    ROUND_CONVERGED=0
    LATEST_ATTACH=""
    for round_attempt in $(seq 1 "$ROUND_RETRY_MAX"); do
        # 清掉上一次嘗試／上次手動測試留下的視窗尺寸持久化紀錄（SwiftUI 的 `Window(id:)`
        # 用 `NSWindow` frame-autosave 把尺寸寫進這個 domain）。**不清的話這次啟動的
        # 起始視窗狀態取決於上一次怎麼結束**——診斷時實測過 kill 前殘留的視窗尺寸會被
        # 下次啟動原封 restore，讓「收不收斂」變成看上一次臉色，不是獨立事件。
        defaults delete com.mirage.app "NSWindow Frame mirage-mirror" > /dev/null 2>&1 || true

        LOG=$(mktemp -t d45_mirage)
        BUNDLE=$(mktemp -d -t d45_bundle)
        if ! gui_session_start "$LOG" "$BUNDLE" "" \
                "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1"; then
            gui_session_cleanup "$BUNDLE"; rm -f "$LOG"; exit 1
        fi

        osascript -e 'tell application "System Events" to tell process "MirageApp" to set value of attribute "AXFullScreen" of window 1 to true' \
            > /dev/null 2>&1
        for _ in $(seq 1 "$FULLSCREEN_POLL_TIMEOUT"); do
            sleep "$FULLSCREEN_POLL_INTERVAL"
            LATEST_ATTACH=$(grep 'attachStream' "$LOG" | tail -1)
            LATEST_WIDTH=$(printf '%s' "$LATEST_ATTACH" | sed -n 's/.*請求 \([0-9]*\)x.*/\1/p')
            if [ -n "$LATEST_WIDTH" ] && [ "$LATEST_WIDTH" -ge "$FULLSCREEN_MIN_WIDTH" ]; then
                ROUND_CONVERGED=1
                break
            fi
        done
        [ "$ROUND_CONVERGED" -eq 1 ] && break

        echo "   本輪第 ${round_attempt}/${ROUND_RETRY_MAX} 次啟動未收斂到解析度上限" \
             "（最後一次請求 $(printf '%s' "$LATEST_ATTACH" | sed 's/.*請求 //')），關掉重開"
        gui_session_cleanup "$BUNDLE"
        rm -f "$LOG"
    done

    if [ "$ROUND_CONVERGED" -eq 0 ]; then
        echo "   重試 ${ROUND_RETRY_MAX} 次仍未收斂到解析度上限，放棄本輪（如實記錄，不湊數）"
        SIZE_OK=0
        continue
    fi
    echo "✅ 串流尺寸已收斂到解析度上限附近（$(printf '%s' "$LATEST_ATTACH" | sed 's/.*請求 //')，寬度 ≥ ${FULLSCREEN_MIN_WIDTH}）"

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
           # 所以畫面若「前段有動、後段靜止」，分母被低估、診斷用的 RATIO_PCT 反而被
           # 高估——這是系統性偏誤，方向剛好是最不該有的那個。
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

    # D45 全分支最終審查修正（Important #1）：Mirage 的樣本不再綁在對照組的成功與否
    # 上——§9 已把對照組定位成純診斷脈絡，不是驗收判準的一部分（使用者裁決 ≥55
    # 絕對門檻保留不改）。M 有效就無條件計入 MIRAGE_VALS；只有 BASE_VALS 與 ratio
    # 的印出才 gate 在 B 的有效性上。
    #
    # **為什麼原本的寫法是錯的**：B 為空的三個原因——對照組 status=error（工具本身
    # 打嗝）、status=static（畫面靜止，合法但無樣本）、elapsed 超過 DURATION*1.1 的
    # 靜止尾段偵測——全都跟 Mirage 那一側的量測是否有效無關。原寫法會讓一個完全
    # 有效的 Mirage 讀數因為對照組那支 Python 工具的問題而從統計裡消失；而 D49 記載
    # `phase0/harness/` 同目錄 12 支腳本有 11 支已死於 protobuf 版本變動，venv 生態
    # 脆弱，這不是假設性風險。
    if [ -n "$M" ]; then
        MIRAGE_VALS="${MIRAGE_VALS}${M}\n"
    fi
    if [ -n "$M" ] && [ -n "$B" ]; then
        R=$(awk -v m="$M" -v b="$B" 'BEGIN { printf "%d", (b > 0) ? m * 100 / b : 0 }')
        echo "[round ${round}] mirage=${M} baseline=${B} ratio=${R}%"
        BASE_VALS="${BASE_VALS}${B}\n"
    elif [ -n "$M" ]; then
        echo "[round ${round}] mirage=${M} baseline=（無資料，見上方對照組訊息）——本輪僅計入 Mirage 側，不計入 ratio"
    fi
    rm -f "$LOG"
done

# 印中位數。**沒有樣本時印空字串，不印 0**——0 是「量到 0 fps」的合法數字，跟「根本
# 沒有資料」是兩件不同的事，混在一起印會讓人誤讀成真的量到 0。呼叫端需要數字語意時
# 自行用 ${VAR:-0}（例如最終驗收斷言刻意要空字串等同 0，因為那代表完全沒有有效輪次）。
median_of() { printf "%b" "$1" | grep -v '^$' | sort -n | awk '{ v[NR]=$1 } END { if (NR) printf "%d\n", v[int((NR+1)/2)] }'; }

echo ""
echo "===== 解析結果 ====="
MM=$(median_of "$MIRAGE_VALS")
BM=$(median_of "$BASE_VALS")
echo "MIRAGE_MEDIAN=${MM:-無資料}"
echo "BASELINE_MEDIAN=${BM:-無資料（對照組本輪全數失敗／被排除，見上方各輪訊息；不影響驗收線 7 的判定）}"
if [ -n "$MM" ] && [ -n "$BM" ]; then
    echo "RATIO_PCT=$(awk -v m="$MM" -v b="$BM" 'BEGIN { printf "%d", (b > 0) ? m * 100 / b : 0 }')"
else
    echo "RATIO_PCT=無資料（對照組樣本不足以取中位數；ratio 僅為診斷脈絡，不影響驗收線 7 的判定）"
fi
# **ROUNDS 的語意（本次修正後改變）**：現在數的是「有幾輪拿到有效的 Mirage 讀數」，
# 與對照組是否成功無關——這正是下面「前置：有效輪數」該問的問題。修正前這裡數的其實
# 是「Mirage 與對照組同時成功的輪數」，對照組工具打嗝就會讓這個數字被拉低，即使
# Mirage 側的量測完全有效。
echo "ROUNDS=$(printf "%b" "$MIRAGE_VALS" | grep -cv '^$')"
echo "SIZE_OK=${SIZE_OK}"

echo ""
echo "===== 判定 ====="

# 前置：尺寸沒到上限，量的就不是驗收線 7 要的東西。**必須排在最前面**——
# 尺寸不對的話，後面的驗收判定就算綠了也沒有意義。
assert_equals "前置：串流尺寸收斂到上限" "$SIZE_OK" 1
assert_at_least "前置：有效輪數" "$(printf "%b" "$MIRAGE_VALS" | grep -cv '^$')" 2

# 驗收線 7（spec §8 第 7 條）：MIRAGE_FPS_LOG 中位數 ≥ 55。**這個門檻是固定值，不隨
# 量測結果調整**——2026-08-04 的使用者裁決推翻了 D45 原先「對照組也只有 30.4、55
# 結構上達不到」的論證：對照組實測 57/41/54/59.74，Mirage 側 35~52，55 是「差一點」
# 不是「不可能」，判準因此保留 ≥55 不改（見 progress.md、docs/specs/…D45…§9）。
#
# **會紅是正確結果，不是腳本壞了**：截至本次修改，Mirage 側歷次乾淨量測
# （50/52/35、49、43）全部低於 55。這條斷言存在的意義就是把這件事如實說出來，
# 不是被調鬆到通過。
if [ "${MM:-0}" -lt 55 ]; then
    echo ""
    echo "================================================================"
    echo "❌ 驗收線 7 未通過：MIRAGE_MEDIAN=${MM:-0}，門檻 55（spec §8 第 7 條）。"
    echo "   這是如實量測的結果，不是這支腳本的錯誤——上面兩條前置斷言已確認本次"
    echo "   量測有效（尺寸收斂、輪數足夠），紅燈代表 Mirage 側全螢幕 fps 目前"
    echo "   就是低於 55，需要產品碼層面的改善才能轉綠。"
    echo "================================================================"
fi
assert_at_least "驗收線 7：MIRAGE_FPS_LOG 中位數 ≥ 55" "${MM:-0}" 55
