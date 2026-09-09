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
#   ./scripts/verify_fps_fullscreen.sh -q 2                  # 啟用深度 2 幀佇列
#   ./scripts/verify_fps_fullscreen.sh -A                   # latest 與 queue2 交錯量測
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
source "$(dirname "$0")/lib/guest_fps.sh"

SERIAL="emulator-5556"
GRPC_PORT="8556"
PACKAGE="com.loomgames.pixelflow"
# D56：預設從 3 提到 5。guest 門檻會淘汰掉一部分輪次（那些輪次的 emulator 本來就
# 沒產出足夠的幀，量到的 Mirage 數字對驗收線 7 沒有鑑別力），所以要多備幾輪才湊得到
# 「前置：有效輪數 ≥ 2」。輪次內不再建置（D57）之後，每輪約 45 秒，5 輪仍在可接受範圍。
ROUNDS=5
DURATION=20
# D45 Task 3 修正：預設 8 訂在「常態負載」的下緣（前一輪實測整場落在 8–18，一度衝到
# 17.95），幾乎每輪都被擋——那是哨兵在扼殺量測，不是在保護量測。真正的失效門檻是
# D32 記載的「load average 20+ 時 MirageScene 的 .task 根本不觸發、連續量到全 0 fps」
# （lib/load_sentinel.sh 開頭那段）。18 貼著這條線的下緣，放行 8–18 的常態波動，
# 仍擋住真正會讓 `.task` 失效的 20+ 區間。
LOAD_LIMIT=18

QUEUE_DEPTH=""
AB_MODE=0

while getopts "s:p:g:r:d:l:hq:A" opt; do
  case "$opt" in
    s) SERIAL="$OPTARG" ;;
    p) GRPC_PORT="$OPTARG" ;;
    g) PACKAGE="$OPTARG" ;;
    r) ROUNDS="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    l) LOAD_LIMIT="$OPTARG" ;;
    q) QUEUE_DEPTH="$OPTARG" ;;
    A) AB_MODE=1 ;;
    h) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "用法：$0 [-s serial] [-p port] [-g package] [-r rounds] [-d seconds] [-l load上限] [-q depth] [-A]" >&2; exit 2 ;;
  esac
done

for v in ROUNDS DURATION; do
  eval "val=\$${v}"
  case "$val" in ''|*[!0-9]*) echo "❌ -${v} 只接受正整數：實測 '${val}'。" >&2; exit 2 ;; esac
done
[ "$DURATION" -lt 10 ] && { echo "❌ -d 不得低於 10 秒：太短的取樣窗拿不到穩定的中位數。" >&2; exit 2; }

if [ -n "$QUEUE_DEPTH" ]; then
  case "$QUEUE_DEPTH" in
    ''|*[!0-9]*) echo "❌ -q 只接受整數深度：實測 '${QUEUE_DEPTH}'。" >&2; exit 2 ;;
  esac
  [ "$QUEUE_DEPTH" -ge 2 ] || { echo "❌ -q 深度不得低於 2：1 應維持 latest-wins。" >&2; exit 2; }
fi
[ "$AB_MODE" -eq 0 ] || [ -z "$QUEUE_DEPTH" ] || {
  echo "❌ -A 已固定比較 latest 與 queue2，不可同時指定 -q。" >&2
  exit 2
}

VENV="$(dirname "$0")/../../phase0/harness/.venv-d45/bin/python"
BASELINE="$(dirname "$0")/../../phase0/harness/fps_baseline.py"
[ -x "$VENV" ] || { echo "❌ 找不到 venv：${VENV}（見 phase0/harness/README-venv.md）" >&2; exit 2; }

require_device "$SERIAL"
require_grpc "$GRPC_PORT"

# === 前置：guest 真的在出幀嗎（D59）===
#
# **檔頭把「遊戲必須停在會持續變化的畫面」列為前置條件，但在此之前沒有任何斷言檢查它。**
# `streamScreenshot` 是變化驅動的——guest 不出幀時 emulator 根本不送畫面，量到的 fps
# 反映的是「畫面多久變一次」而非傳輸能力，而兩者都會產出一個看起來正常的數字。
#
# 2026-08-07 這條缺口造成了一次**寫進 repo 的錯誤結論**：在偏靜止的畫面上掃四個解析度，
# 量到「像素愈多 fps 愈高」，據此判定「降解析度換 fps 走不通」並 commit。切到真正會動的
# 畫面後重跑完全反轉（910k px 30.9 fps vs 1792k 20.9 fps）。
#
# ⚠️ **第一版這道閘門用 `screencap` 雜湊，是錯的，已換掉。** 1 秒間隔取樣只能證明畫面
# 「至少每秒變一次」，不能證明它以 20–60Hz 在變。實測反例：同一時刻 distinct 4/4 通過，
# 而 SurfaceFlinger 裡根本找不到遊戲的 layer（guest 完全沒出幀），串流只有 0.24 fps。
# 而且 `screencap` 每張要數秒，高頻取樣在結構上就辦不到。
#
# 改用與逐輪閘門**同一個訊號**（`lib/guest_fps.sh`，有自我測試與突變檢查）：直接問
# guest 出了幾幀。這比 screencap 強，也不重複發明——第一版等於做了一個比既有閘門更弱的
# 複製品。這裡只是把同樣的判準提前，讓不合格的環境**快速失敗**，而不是跑完整輪才發現。
PREFLIGHT_SECONDS="${PREFLIGHT_SECONDS:-8}"
PREFLIGHT_GUEST_MIN="${PREFLIGHT_GUEST_MIN:-20}"
echo ""
echo "=== 前置：guest 出幀率（取樣 ${PREFLIGHT_SECONDS} 秒）==="
guest_window_start "$SERIAL"
sleep "$PREFLIGHT_SECONDS"
PREFLIGHT_RAW=$(guest_window_end "$SERIAL" "$PACKAGE") || PREFLIGHT_RAW=""
PREFLIGHT_FPS=$(printf '%s' "$PREFLIGHT_RAW" | cut -d' ' -f1)
echo "   guest ${PREFLIGHT_FPS:-（找不到 layer）} fps"
if [ -z "$PREFLIGHT_FPS" ] || ! awk -v g="$PREFLIGHT_FPS" -v t="$PREFLIGHT_GUEST_MIN" 'BEGIN { exit !(g >= t) }'; then
    echo "================================================================"
    echo "❌ 前置未滿足：guest ${PREFLIGHT_FPS:-（找不到 layer）} fps，門檻 ${PREFLIGHT_GUEST_MIN}。"
    echo "   **這不是產品的紅燈，是環境的紅燈。** guest 沒在出幀時，streamScreenshot"
    echo "   不會送畫面，量到的 fps 反映的是畫面多久變一次，不是傳輸能力。"
    echo "   找不到 layer 通常代表遊戲雖在前景但已停止算繪（Unity 閒置會暫停算繪）。"
    echo "   下一步：把遊戲切到會**持續變化**的畫面（遊玩中，不是選單／收集畫面）再跑。"
    echo "   門檻刻意低於逐輪的 GUEST_MIN=${GUEST_MIN:-55}——這裡只擋「根本沒在動」，"
    echo "   「動得不夠快」交給逐輪閘門逐輪判定。"
    echo "   要在明知 guest 沒出幀的情況下硬跑：PREFLIGHT_GUEST_MIN=0 $0 $*"
    echo "================================================================"
fi
assert_at_least "前置：guest 出幀率" "${PREFLIGHT_FPS%%.*}" "$PREFLIGHT_GUEST_MIN"

# === 主機外來 CPU（D56 變異來源 (b)）===
#
# **只診斷、不擋。** 真正的防線是每輪的 guest 門檻——它擋的是「後果」（emulator 沒
# 產出足夠的幀），這裡給的是「成因」，讓紅燈的人知道要去關掉什麼。原本這段在
# `verify_fps_with_guest.sh` 裡是會中止的，但那支腳本已併入本檔（它的整段 timestats
# 窗口與本檔逐輪的 `-clear` 互相衝突），而有了逐輪 guest 門檻之後，事前一刀切地中止
# 整個跑次既多餘又更擾人：機器只是暫時忙的話，被影響的輪次自己會被判為無效。
BUSY_GAP="${BUSY_GAP:-5}"
# qemu（emulator 本體）、MirageApp、WindowServer（全螢幕合成）就是被量的東西，不算污染。
MEASURED_PROCS="qemu-system|MirageApp|WindowServer"
echo ""
echo "=== 主機外來 CPU（取樣 ${BUSY_GAP} 秒）==="
SNAP_A=$(cpu_snapshot)
sleep "$BUSY_GAP"
SNAP_B=$(cpu_snapshot)
FOREIGN_TOTAL=$(cpu_delta_total "$SNAP_A" "$SNAP_B" "$BUSY_GAP" "$MEASURED_PROCS")
echo "   非工作負載 CPU 總和：${FOREIGN_TOTAL}%（qemu／MirageApp／WindowServer 已排除）"
cpu_delta_report "$SNAP_A" "$SNAP_B" "$BUSY_GAP" "$MEASURED_PROCS" \
    | head -3 | awk '{ c = ""; for (i = 2; i <= NF; i++) { c = c (i > 2 ? " " : "") $i }; printf "     %5.1f%%  %s\n", $1, c }'

# === 建置一次，在所有輪次之外（D57）===
#
# **原本每一輪都在窗口內建置。** `gui_session_start` → `package_app.sh` →
# `swift build -c release`，而那就發生在該輪 20 秒擷取窗口的正前方。平常它是 0.5 秒
# 的 no-op 所以沒人注意，但 2026-08-06 實測到 `swift build` **不是冪等的**：工作樹
# 全程乾淨，連跑兩次相同指令是 73.85s 然後 0.58s。撞到那 73 秒的輪次會被 CPU 餓死
# ——實測量到 **31 fps**，而同一次跑次的另兩輪是 48／54。
#
# 修法是把建置整個移出輪次：這裡建到真的 no-op 為止（`build_warm` 的判斷有自我測試
# 釘著，見 verify_common_selftest.sh），之後每輪的 `package_app.sh` 只做複製與自檢。
# 這樣輪次之間的耗時也一致，`load_gate` 擋的才是真的環境負載，不是我們自己製造的。
echo ""
echo "=== 預先建置 release（一次，在所有輪次之外）==="
if ! build_warm release 3 "$(dirname "$0")/.."; then
    exit 1
fi
# 之後每輪的 package_app.sh 只複製，不建置。
export MIRAGE_SKIP_BUILD=1

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
# 修正）——理由與實測見下方進全螢幕區塊的長註解。單次啟動內的收斂輪詢參數由
# `gui_session_fullscreen` 讀取；預設值維持原本的 10 秒／1 秒。
# gui_session_start 實測在 +7.3 秒回來，視窗在 +7.8 秒才出現在 AX，成功設定後約
# +9.3 秒收斂。因此先以 0.5 秒間隔等待視窗，再開始全螢幕設定與尺寸輪詢。
# 這些參數同樣在共用函式內以 `${VAR:-預設}` 讀取，讓兩支腳本共用同一組預設。

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
# 門檻以第三參數傳給 `gui_session_fullscreen`；呼叫端用 `${FULLSCREEN_MIN_WIDTH:-896}`。

# AXFullScreen 比鍵送可靠得多，但實測仍偶爾整次啟動都沒吃到（懷疑跟這台共用機器上其他
# Space 切換動畫互相卡到有關，機制未查清）。**擋下不等於放棄**——跟 load_gate 同一個
# 哲學：一次啟動沒收斂就砍掉重開（新視窗、新程序，不是在舊狀態上重試鍵），比在髒樣本上
# 硬量更誠實。3 次關掉重開仍不收斂才真正放棄本輪。
# 允許負載包裝腳本依環境調高重試次數；直接執行時維持原本的 3 次。
ROUND_RETRY_MAX="${ROUND_RETRY_MAX:-3}"

MIRAGE_VALS=""
BASE_VALS=""
ARRIVED_VALS=""
DROPPED_VALS=""
PRESENTED_VALS=""
GAP20_VALS=""
MAXGAP_VALS=""
IN_P95_VALS=""
NODRAWABLE_VALS=""
# **獨立於 `ROUNDS` 的訊號**：`ROUNDS` 數的是有幾輪產生了 `[round N]`（有效樣本數），
# `SIZE_OK` 答的是不同的問題——這次執行有沒有踩到「解析度收斂失敗」這個故障模式本身。
# 兩者不能合併：即使最後 `ROUNDS` 湊滿了，若中途有輪次耗盡 `ROUND_RETRY_MAX` 仍未收斂
# 才勉強補回來，那就代表這台機器／這次環境對「進全螢幕」不穩定，即使樣本數字表面正常，
# 這個不穩定本身也是要讓 Task 5 的前置閘門知道的事。複審抓到的 Critical：這裡原本只
# 初始化成 1，卻沒有任何分支寫回 0，變成一個看似有檢查、實際上恆真的死變數。
SIZE_OK=1

# === guest 門檻（D56）===
#
# **為什麼門檻正好等於驗收線 7 的 55，而這不是「調鬆判準」**：Mirage 不可能比 guest
# 產出的還快。某一輪 guest 只有 49 fps 時，Mirage ≥ 55 在那個窗口裡**算術上就不可能**
# ——那一輪既不能證明 Mirage 慢、也不能證明它快，對驗收線 7 沒有任何鑑別力。把它算進
# 中位數不是「保守」，是拿環境雜訊稀釋判定：同一顆 build、同一天量到 56／58（通過）
# 與 31／48／54（未通過），差別就在 guest（實測 49.18 vs 安靜窗口的 59.9）。
#
# ⚠️ **這個門檻的失效方向是紅燈，不是綠燈**，這是它能存在的前提：guest 全部不達標時
# 有效輪數會湊不到 2，前置斷言直接紅。它不可能把一次失敗變成通過。
#
# ⚠️ **但有一個它不該吸收掉的情況：Mirage 自己把 emulator 餓死。** 那時 guest 也會掉，
# 而那是真的產品缺陷、不是環境問題。所以全部輪次都被這道門檻淘汰時，下方會印出明確
# 警告要求人去分辨，而不是安靜地報「環境不佳」。
GUEST_MIN="${GUEST_MIN:-55}"
GUEST_VALS=""
GUEST_REJECTED=0
# D50：擷取窗口內負載飆高而判為無效的輪次數。
WINDOW_LOAD_REJECTED=0

ab_median_of() {
    printf "%b" "$1" | grep -v '^$' | sort -n \
        | awk '{ v[NR]=$1 } END { if (NR) printf "%d\n", v[int((NR+1)/2)] }'
}

ab_median_one_decimal_of() {
    printf "%b" "$1" | grep -v '^$' | sort -n \
        | awk '{ v[NR]=$1 } END { if (NR) printf "%.1f\n", v[int((NR+1)/2)] }'
}

ab_count_of() {
    printf "%b" "$1" | grep -cv '^$'
}

AB_LATEST_VALS=""
AB_QUEUE_VALS=""
AB_LATEST_DROPPED=""
AB_QUEUE_DROPPED=""
AB_LATEST_LAT_P95=""
AB_QUEUE_LAT_P95=""
AB_GUEST_VALS=""
AB_GUEST_REJECTED=0
AB_WINDOW_LOAD_REJECTED=0

ab_print_result() {
    local round="$1" sink="$2"
    if [ -n "$AB_M" ] && [ -n "$AB_B" ]; then
        echo "[round ${round} sink=${sink}] guest=${AB_G} arrived=${AB_A} presented=${AB_P} dropped=${AB_D} mirage=${AB_M} baseline=${AB_B} ratio=${AB_R}% lat_p50=${AB_LAT_P50} lat_p95=${AB_LAT_P95}"
    elif [ -n "$AB_M" ]; then
        echo "[round ${round} sink=${sink}] guest=${AB_G} arrived=${AB_A} presented=${AB_P} dropped=${AB_D} mirage=${AB_M} baseline=（無資料，見上方對照組訊息），本輪僅計入 Mirage 側，不計入 ratio lat_p50=${AB_LAT_P50} lat_p95=${AB_LAT_P95}"
    else
        echo "[round ${round} sink=${sink}] guest=${AB_G:-（未量到）} arrived=${AB_A:-（無資料）} presented=${AB_P:-（無資料）} dropped=${AB_D:-（無資料）} mirage=（無資料） baseline=（無資料） ratio=（無資料） lat_p50=${AB_LAT_P50:-（無資料）} lat_p95=${AB_LAT_P95:-（無資料）}"
    fi
    if [ -n "$AB_M" ]; then
        echo "[round ${round} sink=${sink} draw] gap20=${AB_GAP20} maxgap=${AB_MAXGAP}ms in_p95=${AB_IN_P95}ms nodrawable=${AB_NODRAWABLE} noframe=${AB_NOFRAME}"
    fi
}

run_ab_sink() {
    local round="$1" sink="$2"
    local log="" bundle="" round_converged=0 latest_attach=""
    local round_attempt sink_line before lat_before
    local m a d p gap20 maxgap in_p95 nodrawable noframe
    local g="" gf gd gw b="" be="" base_out base_rc r

    AB_VALID=0
    AB_G=""
    AB_M=""
    AB_A=""
    AB_D=""
    AB_P=""
    AB_GAP20=""
    AB_MAXGAP=""
    AB_IN_P95=""
    AB_NODRAWABLE=""
    AB_NOFRAME=""
    AB_B=""
    AB_R=""
    AB_LAT_P50=""
    AB_LAT_P95=""

    for round_attempt in $(seq 1 "$ROUND_RETRY_MAX"); do
        defaults delete com.mirage.app "NSWindow Frame mirage-mirror" > /dev/null 2>&1 || true

        log=$(mktemp -t d64_mirage)
        bundle=$(mktemp -d -t d64_bundle)
        if [ "$sink" = "queue2" ]; then
            if ! gui_session_start "$log" "$bundle" "" \
                    "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1" \
                    "MIRAGE_FRAME_QUEUE=2" "MIRAGE_LATENCY_LOG=1"; then
                gui_session_cleanup "$bundle"; rm -f "$log"; exit 1
            fi
        else
            if ! gui_session_start "$log" "$bundle" "" \
                    "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1" \
                    "MIRAGE_LATENCY_LOG=1"; then
                gui_session_cleanup "$bundle"; rm -f "$log"; exit 1
            fi
        fi

        if gui_session_fullscreen "$log" "$bundle" "${FULLSCREEN_MIN_WIDTH:-896}"; then
            round_converged=1
            break
        fi

        if [ "$WINDOW_FOUND" -eq 1 ]; then
            echo "   [sink=${sink}] 第 ${round_attempt}/${ROUND_RETRY_MAX} 次啟動未收斂到解析度上限" \
                 "（最後一次請求 $(printf '%s' "$LATEST_ATTACH" | sed 's/.*請求 //')），關掉重開"
        fi
    done

    if [ "$round_converged" -eq 0 ]; then
        # 與非 A/B 迴圈一致：踩到收斂失敗就讓前置斷言紅，不能因為其他輪次湊到樣本而被吃掉。
        SIZE_OK=0
        echo "   [sink=${sink}] 重試 ${ROUND_RETRY_MAX} 次仍未收斂到解析度上限，放棄本次量測"
        ab_print_result "$round" "$sink"
        return 0
    fi
    echo "✅ [sink=${sink}] 串流尺寸已收斂到解析度上限附近（$(printf '%s' "$LATEST_ATTACH" | sed 's/.*請求 //')，寬度 ≥ ${FULLSCREEN_MIN_WIDTH:-896}）"

    sink_line=$(grep '^\[app\] frame sink=' "$log" | tail -1)
    if [ -n "$sink_line" ]; then
        echo "   $sink_line"
    else
        echo "   ⚠️ [sink=${sink}] log 找不到 [app] frame sink= 行"
    fi

    before=$(fps_samples "$log")
    lat_before=$(grep -c '^\[app\] lat ' "$log" 2>/dev/null || true)
    guest_window_start "$SERIAL"
    # D50：A/B 這條路徑的擷取窗口與主路徑同型，同樣需要窗口內的負載保護。
    window_peak=$(load_watch_sleep "$DURATION" 2)
    g_raw=$(guest_window_end "$SERIAL" "$PACKAGE") || g_raw=""
    m=$(fps_median "$log")
    a=$(frames_median "$log" arrived "$before")
    d=$(frames_median "$log" dropped "$before")
    p=$(frames_median "$log" presented "$before")
    gap20=$(tagged_median "$log" draw gap20 "$before")
    maxgap=$(tagged_median "$log" draw maxgap "$before")
    in_p95=$(tagged_median "$log" draw in_p95 "$before")
    nodrawable=$(tagged_median "$log" draw nodrawable "$before")
    noframe=$(tagged_median "$log" draw noframe "$before")
    AB_LAT_P50=$(latency_median "$log" p50 "$lat_before")
    AB_LAT_P95=$(latency_median "$log" p95 "$lat_before")

    if [ -n "$g_raw" ]; then
        g=$(printf '%s' "$g_raw" | cut -d' ' -f1)
        gf=$(printf '%s' "$g_raw" | cut -d' ' -f2)
        gd=$(printf '%s' "$g_raw" | cut -d' ' -f3)
        gw=$(printf '%s' "$g_raw" | cut -d' ' -f4)
        echo "   [sink=${sink}] guest 側：${g} fps（${gf} 幀 ÷ $(awk -v w="$gw" 'BEGIN { printf "%.2f", w / 1000 }')s，droppedFrames=${gd}）"
    else
        echo "   [sink=${sink}] guest 側：量不到"
    fi

    AB_G="$g"
    AB_M="$m"
    AB_A="$a"
    AB_D="$d"
    AB_P="$p"
    AB_GAP20="$gap20"
    AB_MAXGAP="$maxgap"
    AB_IN_P95="$in_p95"
    AB_NODRAWABLE="$nodrawable"
    AB_NOFRAME="$noframe"

    gui_session_cleanup "$bundle"
    sleep 3

    # D50：先判窗口負載。負載污染會同時壓低 guest 與 Mirage 兩側，
    # 先判 guest 會把成因記成「guest 未達門檻」，掩蓋掉真正的原因。
    if ! load_peak_gate "$window_peak" "$LOAD_LIMIT"; then
        AB_WINDOW_LOAD_REJECTED=$((AB_WINDOW_LOAD_REJECTED + 1))
        echo "   ❌ [sink=${sink}] 本輪判為無效：擷取窗口內 load average 峰值 ${window_peak} 超過 ${LOAD_LIMIT}"
        # 收尾照既有的 guest 拒絕路徑：呼叫端不看回傳值，所以要自己清 log 並印出結果，
        # 否則這一輪在輸出裡憑空消失，而殘檔會留下來。
        rm -f "$log"
        ab_print_result "$round" "$sink"
        return 0
    fi

    if [ -z "$g" ] || ! awk -v g="$g" -v t="$GUEST_MIN" 'BEGIN { exit !(g >= t) }'; then
        AB_GUEST_REJECTED=$((AB_GUEST_REJECTED + 1))
        [ -n "$g" ] && AB_GUEST_VALS="${AB_GUEST_VALS}${g}\n"
        rm -f "$log"
        ab_print_result "$round" "$sink"
        return 0
    fi
    AB_GUEST_VALS="${AB_GUEST_VALS}${g}\n"

    base_out=$("$VENV" "$BASELINE" --endpoint "localhost:${GRPC_PORT}" \
        --seconds "$DURATION" --width 900 --height 2000 2>/tmp/d64-baseline-err.log)
    base_rc=$?
    case "$base_rc" in
        0) b=$(printf '%s' "$base_out" | sed 's/.*fps=\([0-9.]*\).*/\1/')
           be=$(printf '%s' "$base_out" | sed 's/.*elapsed=\([0-9.]*\).*/\1/')
           if awk -v e="$be" -v d="$DURATION" 'BEGIN { exit !(e > d * 1.1) }'; then
               echo "   [sink=${sink}] 對照組 elapsed=${be}s 明顯超過 ${DURATION}s，本輪不計入 ratio"
               b=""
           else
               echo "   [sink=${sink}] 對照組：${b} fps（elapsed=${be}s）"
           fi ;;
        2) b=""
           echo "   [sink=${sink}] 對照組：畫面靜止、整個窗口沒有出幀" ;;
        *) b=""
           echo "   [sink=${sink}] 對照組：失敗（退出碼 ${base_rc}）"
           sed 's/^/     /' /tmp/d64-baseline-err.log ;;
    esac

    AB_VALID=1
    AB_B="$b"
    if [ -n "$m" ] && [ -n "$b" ]; then
        r=$(awk -v m="$m" -v b="$b" 'BEGIN { printf "%d", (b > 0) ? m * 100 / b : 0 }')
        AB_R="$r"
    fi

    if [ -n "$m" ]; then
        if [ "$sink" = "queue2" ]; then
            AB_QUEUE_VALS="${AB_QUEUE_VALS}${m}\n"
            AB_QUEUE_DROPPED="${AB_QUEUE_DROPPED}${d}\n"
            AB_QUEUE_LAT_P95="${AB_QUEUE_LAT_P95}${AB_LAT_P95}\n"
        else
            AB_LATEST_VALS="${AB_LATEST_VALS}${m}\n"
            AB_LATEST_DROPPED="${AB_LATEST_DROPPED}${d}\n"
            AB_LATEST_LAT_P95="${AB_LATEST_LAT_P95}${AB_LAT_P95}\n"
        fi
    fi

    rm -f "$log"
    ab_print_result "$round" "$sink"
}

run_ab_mode() {
    local round first_sink second_sink
    local latest_median queue_median latest_dropped queue_dropped
    local latest_lat_p95 queue_lat_p95 queue_rounds

    for round in $(seq 1 "$ROUNDS"); do
        echo ""
        echo "=== 第 ${round}/${ROUNDS} 輪 A/B ==="

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

        if [ $((round % 2)) -eq 1 ]; then
            first_sink="latest"
            second_sink="queue2"
        else
            first_sink="queue2"
            second_sink="latest"
        fi
        run_ab_sink "$round" "$first_sink"
        run_ab_sink "$round" "$second_sink"
    done

    latest_median=$(ab_median_of "$AB_LATEST_VALS")
    queue_median=$(ab_median_of "$AB_QUEUE_VALS")
    latest_dropped=$(ab_median_of "$AB_LATEST_DROPPED")
    queue_dropped=$(ab_median_of "$AB_QUEUE_DROPPED")
    latest_lat_p95=$(ab_median_one_decimal_of "$AB_LATEST_LAT_P95")
    queue_lat_p95=$(ab_median_one_decimal_of "$AB_QUEUE_LAT_P95")
    queue_rounds=$(ab_count_of "$AB_QUEUE_VALS")

    echo ""
    echo "===== A/B 解析結果 ====="
    echo "SINK_LATEST_VALUES=$(printf '%b' "$AB_LATEST_VALS" | grep -v '^$' | sort -n | tr '\n' ' ' | sed 's/ $//')"
    echo "SINK_QUEUE_VALUES=$(printf '%b' "$AB_QUEUE_VALS" | grep -v '^$' | sort -n | tr '\n' ' ' | sed 's/ $//')"
    echo "SINK_LATEST_MEDIAN=${latest_median:-無資料}"
    echo "SINK_QUEUE_MEDIAN=${queue_median:-無資料}"
    echo "DROPPED_LATEST=${latest_dropped:-無資料}"
    echo "DROPPED_QUEUE=${queue_dropped:-無資料}"
    echo "LAT_P95_LATEST=${latest_lat_p95:-無資料}"
    echo "LAT_P95_QUEUE=${queue_lat_p95:-無資料}"
    echo "GUEST_VALUES=$(printf '%b' "$AB_GUEST_VALS" | grep -v '^$' | sort -n | tr '\n' ' ' | sed 's/ $//')"
    echo "GUEST_REJECTED=${AB_GUEST_REJECTED}"
    echo "WINDOW_LOAD_REJECTED=${AB_WINDOW_LOAD_REJECTED}"
    echo "SIZE_OK=${SIZE_OK}"

    echo ""
    echo "===== A/B 判定 ====="
    assert_equals "前置：串流尺寸收斂到上限" "$SIZE_OK" 1
    assert_at_least "前置：queue2 有效輪數" "$queue_rounds" 2

    if [ -n "$queue_median" ] \
            && [ "$(printf '%b' "$AB_QUEUE_VALS" | grep -v '^$' | sort -n | head -1)" -lt 55 ] \
            && [ "$(printf '%b' "$AB_QUEUE_VALS" | grep -v '^$' | sort -n | tail -1)" -ge 55 ]; then
        echo "⚠️ queue2 量測值域跨越門檻 55：這次量測判定不穩定。"
    fi
    assert_at_least "驗收線 7：sink=queue2 的 MIRAGE_FPS_LOG 中位數 ≥ 55" "${queue_median:-0}" 55
}

if [ "$AB_MODE" -eq 1 ]; then
    run_ab_mode
    exit 0
fi

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
    # 每次啟動先等 AX 視窗出現再設定全螢幕。尺寸輪詢期間每隔一段時間讀取
    # `AXFullScreen`，必要時在同一個視窗物件上重送，仍未收斂才走 `ROUND_RETRY_MAX` 的
    # 關掉重開路徑。
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
        if [ -n "$QUEUE_DEPTH" ]; then
            if ! gui_session_start "$LOG" "$BUNDLE" "" \
                    "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1" \
                    "MIRAGE_FRAME_QUEUE=$QUEUE_DEPTH" "MIRAGE_LATENCY_LOG=1"; then
                gui_session_cleanup "$BUNDLE"; rm -f "$LOG"; exit 1
            fi
        else
            if ! gui_session_start "$LOG" "$BUNDLE" "" \
                    "MIRAGE_PORT=$GRPC_PORT" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1"; then
                gui_session_cleanup "$BUNDLE"; rm -f "$LOG"; exit 1
            fi
        fi

        if gui_session_fullscreen "$LOG" "$BUNDLE" "${FULLSCREEN_MIN_WIDTH:-896}"; then
            ROUND_CONVERGED=1
            break
        fi

        if [ "$WINDOW_FOUND" -eq 1 ]; then
            echo "   本輪第 ${round_attempt}/${ROUND_RETRY_MAX} 次啟動未收斂到解析度上限" \
                 "（最後一次請求 $(printf '%s' "$LATEST_ATTACH" | sed 's/.*請求 //')），關掉重開"
        fi
    done

    if [ "$ROUND_CONVERGED" -eq 0 ]; then
        echo "   重試 ${ROUND_RETRY_MAX} 次仍未收斂到解析度上限，放棄本輪（如實記錄，不湊數）"
        SIZE_OK=0
        continue
    fi
    echo "✅ 串流尺寸已收斂到解析度上限附近（$(printf '%s' "$LATEST_ATTACH" | sed 's/.*請求 //')，寬度 ≥ ${FULLSCREEN_MIN_WIDTH:-896}）"
    if [ -n "$QUEUE_DEPTH" ]; then
        SINK_LINE=$(grep '^\[app\] frame sink=' "$LOG" | tail -1)
        if [ -n "$SINK_LINE" ]; then
            echo "   $SINK_LINE"
        else
            echo "   ⚠️ log 找不到 [app] frame sink= 行"
        fi
    fi

    # **guest 的量測窗口必須與這裡的擷取窗口是同一段**（D56／D48 限制）。前一版把
    # timestats 開在整個跑次外層，量到的 241 秒窗口涵蓋三輪＋輪次間隔＋App 啟動＋
    # 一次 65.83 秒的重編——那個平均值不能與任何單輪的 Mirage 數字比較。
    BEFORE=$(fps_samples "$LOG")
    guest_window_start "$SERIAL"
    # D50：擷取窗口內每 2 秒取樣一次 load average，回報峰值。
    # `load_gate` 只在輪次開始前檢查一次，擋不住「起跑安靜、跑到一半才飆高」——
    # D45 補測有兩個樣本就是這樣被污染的（量到 6 與 11，乾淨量測是 35 到 60 一帶），
    # 當時是靠人工比對既有基準才被識別的。
    WINDOW_PEAK=$(load_watch_sleep "$DURATION" 2)
    GUEST_RAW=$(guest_window_end "$SERIAL" "$PACKAGE") || GUEST_RAW=""
    # `mirage=M` 的取樣母體含全螢幕收斂期。既有 `fps_median` 沒有跳過參數，這是既有
    # 行為，本任務不動判定；`arrived`、`dropped`、`presented` 只含量測窗口。
    # 兩者不是同一個窗口，逐輪不能直接相減。
    M=$(fps_median "$LOG")
    A=$(frames_median "$LOG" arrived "$BEFORE")
    D=$(frames_median "$LOG" dropped "$BEFORE")
    P=$(frames_median "$LOG" presented "$BEFORE")
    GAP20=$(tagged_median "$LOG" draw gap20 "$BEFORE")
    MAXGAP=$(tagged_median "$LOG" draw maxgap "$BEFORE")
    IN_P95=$(tagged_median "$LOG" draw in_p95 "$BEFORE")
    NODRAWABLE=$(tagged_median "$LOG" draw nodrawable "$BEFORE")
    NOFRAME=$(tagged_median "$LOG" draw noframe "$BEFORE")
    echo "   Mirage 側：中位數 ${M} fps（取樣 $(fps_samples "$LOG") 筆，量測前已有 ${BEFORE} 筆）"
    echo "   幀計數窗口：arrived=${A} presented=${P} dropped=${D}（跳過量測前 ${BEFORE} 筆）"
    echo "   draw 時序：gap20=${GAP20} maxgap=${MAXGAP}ms in_p95=${IN_P95}ms nodrawable=${NODRAWABLE} noframe=${NOFRAME}"

    G=""
    if [ -z "$GUEST_RAW" ]; then
        echo "   guest 側：量不到——找不到 ${PACKAGE} 的 SurfaceView layer（遊戲可能不在前景，"
        echo "            或整個窗口沒有出幀）"
    else
        G=$(printf '%s' "$GUEST_RAW" | cut -d' ' -f1)
        GF=$(printf '%s' "$GUEST_RAW" | cut -d' ' -f2)
        GD=$(printf '%s' "$GUEST_RAW" | cut -d' ' -f3)
        GW=$(printf '%s' "$GUEST_RAW" | cut -d' ' -f4)
        # **不印 dumpsys 自己的 averageFPS**，它系統性偏高約 3%（AOSP 的
        # duration_cast<milliseconds> 無條件捨去，見 lib/guest_fps.sh 的長註解）。
        echo "   guest 側：${G} fps（${GF} 幀 ÷ $(awk -v w="$GW" 'BEGIN { printf "%.2f", w / 1000 }')s，droppedFrames=${GD}）"
        # ⚠️ droppedFrames=0 **不能**用來反駁「guest 是瓶頸」：它只表示 SurfaceFlinger
        # 沒丟棄「已提交」的幀，不表示 Unity 送滿了 60。實測有過 fps=34.28 而
        # droppedFrames=0 的窗口。判準一律看 fps，不看 droppedFrames。
    fi

    # **關掉 Mirage 再量對照組**——不並行。兩個 client 同時拉同一條串流，
    # emulator 得做兩份工，量到的是「兩個消費者下的幀率」而非任一方的能力。
    gui_session_cleanup "$BUNDLE"
    sleep 3

    # === 本輪有效性：擷取窗口內的負載（D50）===
    #
    # 刻意放在 guest 判定之前：負載污染會同時壓低 guest 與 Mirage 兩側，
    # 先判 guest 會把成因記成「guest 未達門檻」，掩蓋掉真正的原因。
    if ! load_peak_gate "$WINDOW_PEAK" "$LOAD_LIMIT"; then
        WINDOW_LOAD_REJECTED=$((WINDOW_LOAD_REJECTED + 1))
        echo "   ❌ 本輪判為無效：擷取窗口內 load average 峰值 ${WINDOW_PEAK} 超過 ${LOAD_LIMIT}——"
        echo "      起跑時的 load_gate 過了，負載是在窗口中間才上來的。這一輪量到的是"
        echo "      主機的數字不是產品的數字，不計入中位數（如實記錄，不湊數）。"
        rm -f "$LOG"
        continue
    fi

    # === 本輪有效性：guest 有沒有產出足以讓驗收線 7 成立的幀（D56）===
    if [ -z "$G" ] || ! awk -v g="$G" -v t="$GUEST_MIN" 'BEGIN { exit !(g >= t) }'; then
        GUEST_REJECTED=$((GUEST_REJECTED + 1))
        echo "   ❌ 本輪判為無效：guest ${G:-（量不到）} fps 未達 ${GUEST_MIN}——"
        echo "      這個窗口裡 Mirage 要達到 ${GUEST_MIN} 在算術上就不可能，本輪對驗收線 7"
        echo "      沒有鑑別力，不計入中位數（如實記錄，不湊數）。"
        [ -n "$G" ] && GUEST_VALS="${GUEST_VALS}${G}\n"
        rm -f "$LOG"
        continue
    fi
    GUEST_VALS="${GUEST_VALS}${G}\n"

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
        ARRIVED_VALS="${ARRIVED_VALS}${A}\n"
        DROPPED_VALS="${DROPPED_VALS}${D}\n"
        PRESENTED_VALS="${PRESENTED_VALS}${P}\n"
        GAP20_VALS="${GAP20_VALS}${GAP20}\n"
        MAXGAP_VALS="${MAXGAP_VALS}${MAXGAP}\n"
        IN_P95_VALS="${IN_P95_VALS}${IN_P95}\n"
        NODRAWABLE_VALS="${NODRAWABLE_VALS}${NODRAWABLE}\n"
    fi
    if [ -n "$M" ] && [ -n "$B" ]; then
        R=$(awk -v m="$M" -v b="$B" 'BEGIN { printf "%d", (b > 0) ? m * 100 / b : 0 }')
        echo "[round ${round}] guest=${G} arrived=${A} presented=${P} dropped=${D} mirage=${M} baseline=${B} ratio=${R}%"
        BASE_VALS="${BASE_VALS}${B}\n"
    elif [ -n "$M" ]; then
        echo "[round ${round}] guest=${G} arrived=${A} presented=${P} dropped=${D} mirage=${M} baseline=（無資料，見上方對照組訊息）——本輪僅計入 Mirage 側，不計入 ratio"
    fi
    if [ -n "$M" ]; then
        echo "[round ${round} draw] gap20=${GAP20} maxgap=${MAXGAP}ms in_p95=${IN_P95}ms nodrawable=${NODRAWABLE} noframe=${NOFRAME}"
    fi
    rm -f "$LOG"
done

# 印中位數。**沒有樣本時印空字串，不印 0**——0 是「量到 0 fps」的合法數字，跟「根本
# 沒有資料」是兩件不同的事，混在一起印會讓人誤讀成真的量到 0。呼叫端需要數字語意時
# 自行用 ${VAR:-0}（例如最終驗收斷言刻意要空字串等同 0，因為那代表完全沒有有效輪次）。
median_of() { printf "%b" "$1" | grep -v '^$' | sort -n | awk '{ v[NR]=$1 } END { if (NR) printf "%d\n", v[int((NR+1)/2)] }'; }

median_one_decimal_of() { printf "%b" "$1" | grep -v '^$' | sort -n | awk '{ v[NR]=$1 } END { if (NR) printf "%.1f\n", v[int((NR+1)/2)] }'; }

list_of()   { printf "%b" "$1" | grep -v '^$' | sort -n | tr '\n' ' ' | sed 's/ $//'; }
count_of()  { printf "%b" "$1" | grep -cv '^$'; }
min_of()    { printf "%b" "$1" | grep -v '^$' | sort -n | head -1; }
max_of()    { printf "%b" "$1" | grep -v '^$' | sort -n | tail -1; }

echo ""
echo "===== 解析結果 ====="
MM=$(median_of "$MIRAGE_VALS")
BM=$(median_of "$BASE_VALS")
AM=$(median_of "$ARRIVED_VALS")
DM=$(median_of "$DROPPED_VALS")
PM=$(median_of "$PRESENTED_VALS")
GAP20M=$(median_of "$GAP20_VALS")
MAXGAPM=$(median_of "$MAXGAP_VALS")
IN_P95M=$(median_one_decimal_of "$IN_P95_VALS")
NODRAWABLEM=$(median_of "$NODRAWABLE_VALS")
# === 離散度（D56）===
#
# **只印中位數會把判定的不確定性藏起來。** 2026-08-06 同一顆 build、同一天量到
# 56／58（中位數 56，通過）與 31／48／54（中位數 48，未通過）——兩次跑次得出相反的
# 判定，而兩個中位數各自看起來都很篤定。值域必須跟中位數一起印。
echo "MIRAGE_VALUES=$(list_of "$MIRAGE_VALS")"
if [ -n "$MM" ]; then
    echo "MIRAGE_SPREAD=$(min_of "$MIRAGE_VALS")–$(max_of "$MIRAGE_VALS")（$(count_of "$MIRAGE_VALS") 個有效輪次）"
fi
echo "GUEST_VALUES=$(list_of "$GUEST_VALS")"
echo "GUEST_REJECTED=${GUEST_REJECTED}（guest 未達 ${GUEST_MIN} 而判為無效的輪次數）"
echo "WINDOW_LOAD_REJECTED=${WINDOW_LOAD_REJECTED}（擷取窗口內 load 峰值超過 ${LOAD_LIMIT} 而判為無效的輪次數）"
echo "MIRAGE_MEDIAN=${MM:-無資料}"
echo "ARRIVED_MEDIAN=${AM}"
echo "DROPPED_MEDIAN=${DM}"
echo "PRESENTED_MEDIAN=${PM}"
echo "GAP20_MEDIAN=${GAP20M}"
echo "MAXGAP_MEDIAN=${MAXGAPM}"
echo "IN_P95_MEDIAN=${IN_P95M}"
echo "NODRAWABLE_MEDIAN=${NODRAWABLEM}"
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

# **全部輪次都被 guest 門檻淘汰時，不可以安靜地當成「環境不佳」。**（D56）
# guest 掉幀有兩種成因，而它們的結論完全相反：
#   - 主機被別的東西佔滿 → 環境問題，換個時間重跑
#   - Mirage 自己把 emulator 餓死 → 真的產品缺陷，重跑幾次都一樣
# 這道門檻分不出這兩者，所以它必須把問題交出去，而不是替人做結論。
if [ "$(count_of "$MIRAGE_VALS")" -eq 0 ] && [ "$GUEST_REJECTED" -gt 0 ]; then
    echo ""
    echo "================================================================"
    echo "⚠️  ${GUEST_REJECTED} 個輪次全部因為 guest 未達 ${GUEST_MIN} 而判為無效。"
    echo "   guest 實測：$(list_of "$GUEST_VALS")"
    echo "   **這不必然是環境問題。** 兩種成因結論相反，這道門檻分不出來："
    echo "     (a) 主機被別的東西佔滿 → 換個安靜的時間重跑即可"
    echo "     (b) Mirage 自己把 emulator 餓死 → 是產品缺陷，重跑幾次都一樣"
    echo "   分辨方法：不開 Mirage、只跑對照組時 guest 是多少？兩者接近就是 (a)，"
    echo "   開了 Mirage 才掉就是 (b)。（D45 在 headless、load≈3 下量到的是 59.9。）"
    echo "   本次跑次開始時的非工作負載 CPU 總和是 ${FOREIGN_TOTAL}%——偏高就先往 (a) 查。"
    echo "================================================================"
fi

assert_at_least "前置：有效輪數" "$(count_of "$MIRAGE_VALS")" 2

# **值域跨越門檻時，這次量測判定不了驗收線 7。**（D56）
# 一半輪次在 55 以上、一半在以下，中位數落在哪邊是抽樣運氣，不是產品狀態。
# 這種情況印綠或印紅都是在假裝確定，正確的輸出是「這把尺這次沒量準」。
if [ -n "$MM" ] && [ "$(min_of "$MIRAGE_VALS")" -lt 55 ] && [ "$(max_of "$MIRAGE_VALS")" -ge 55 ]; then
    echo ""
    echo "================================================================"
    echo "⚠️  量測值域 $(min_of "$MIRAGE_VALS")–$(max_of "$MIRAGE_VALS") **跨越了門檻 55**，這次量測判定不了驗收線 7。"
    echo "   實測值：$(list_of "$MIRAGE_VALS")"
    echo "   中位數 ${MM} 落在哪一邊是抽樣運氣，不是產品狀態——2026-08-06 同一顆 build"
    echo "   同一天量到 56／58（通過）與 31／48／54（未通過）就是這個現象（D56）。"
    echo "   下一步：機器安靜下來後加輪數重跑（-r 9），或先處理仍在污染量測的變異來源。"
    echo "   **下方的判定行仍會照中位數給出結果，但它的可信度就是這一段所說的。**"
    echo "================================================================"
fi

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
