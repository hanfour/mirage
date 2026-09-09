#!/usr/bin/env bash
# load_sentinel.sh 與 gui_session.sh 的 fps_median 的自我測試。
# **不需要模擬器、不需要 adb**——比照 verify_common_selftest.sh 的既有結構。
#
# 用法：./scripts/lib/load_sentinel_selftest.sh（退出碼 0 = 全部通過）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/load_sentinel.sh"
source "$HERE/gui_session.sh"
FAILURES=0

check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "✅ $desc"
    else
        # 變數一律用 ${} 包起來——`$desc：`（裸變數緊接全形字元）會被 bash 當成變數名的
        # 一部分，`set -u` 當場報「未綁定的變數」。ci.sh 閘門 4 擋的就是這個。
        echo "❌ ${desc}：得到 ${got}，期待 ${want}"
        FAILURES=$((FAILURES + 1))
    fi
}

WORK=$(mktemp -d -t d45_selftest)
trap 'rm -rf "$WORK"' EXIT

echo "=== fps_median ==="

# 奇數筆：正中間那筆。刻意亂序，驗證它有排序。
printf '[fps] fps=30\n[fps] fps=10\n[fps] fps=20\n' > "$WORK/odd.log"
check "奇數筆取正中間"        "$(fps_median "$WORK/odd.log")"  20

# 偶數筆：取中間兩筆的下位，不內插。10/20/30/40 → 20（不是 25）。
printf '[fps] fps=40\n[fps] fps=10\n[fps] fps=30\n[fps] fps=20\n' > "$WORK/even.log"
check "偶數筆取下位不內插"    "$(fps_median "$WORK/even.log")" 20

# **這是 fps_median 存在的理由**：一次 load 尖峰量到的 0 會把平均拖歪，中位數不受影響。
# 平均 = (60+58+0+59+61)/5 = 47.6 → 47；中位數 = 59。
printf '[fps] fps=60\n[fps] fps=58\n[fps] fps=0\n[fps] fps=59\n[fps] fps=61\n' > "$WORK/spike.log"
check "離群的 0 不影響中位數"  "$(fps_median "$WORK/spike.log")" 59
check "同一份資料的平均被拖歪"  "$(fps_average "$WORK/spike.log")" 47

# 單筆與空檔案的邊界。
printf '[fps] fps=42\n' > "$WORK/one.log"
check "單筆"                  "$(fps_median "$WORK/one.log")"   42
: > "$WORK/empty.log"
check "空檔案回 0"            "$(fps_median "$WORK/empty.log")"  0

echo ""
echo "=== load_gate ==="

# load_gate 用實際的 load average，測不了固定值；改測它的判定邏輯：
# 上限給一個絕不可能超過的值 → 必過；給 0 → 必不過（load average 不會是負的）。
( load_gate 100000 > /dev/null 2>&1 ); check "上限極高 → 回 0（通過）" "$?" 0
( load_gate 0      > /dev/null 2>&1 ); check "上限為 0 → 回 1（擋下）" "$?" 1

# load_avg_1min 必須印出一個可被 awk 當數字比較的東西。
LA=$(load_avg_1min)
check "load_avg_1min 印出數字" \
      "$(awk -v v="$LA" 'BEGIN { print (v + 0 == v && v >= 0) ? "yes" : "no" }')" "yes"

echo ""
echo "=== cpu_delta（D56）==="

# 兩次快照，間隔 10 秒。**這組測試釘住的是 cputime 的格式解析**——macOS 上它可能是
# `MM:SS.ss`、`HH:MM:SS`、甚至 `DD-HH:MM:SS`，而解錯的後果是靜默的：算出來的百分比
# 只是「不太對」，不會有任何錯誤訊息。
#
# ⚠️ **高位欄位必須在兩次快照之間跨過進位邊界，否則這些測試驗不到任何東西。**
# 第一版寫成 `1:00:00` → `1:00:02`：把 HH:MM:SS 誤解成 MM:SS 時，兩邊同樣少算 3600 秒，
# **差值完全一樣**，解析壞掉的實作照樣通過（突變檢查當場證明：改壞了還是全綠）。
# 這正是「結構上不可能失敗的測試」。改成跨過整點／跨過午夜之後，誤解會讓差值變成負數
# 而被門檻濾掉，測試才真的紅。
SNAP_A='  101 10:00.00 /usr/bin/busy
  102 0:59:58 /Applications/iTerm.app/Contents/MacOS/iTerm2
  103 00:10.00 /usr/bin/idle
  104 0-23:59:58 /usr/bin/ancient
  105 00:05.00 /usr/local/bin/qemu-system-aarch64'
# busy 多 5 秒 → 50%；iTerm2 跨整點多 5 秒 → 50%；idle 多 0.5 秒 → 5%（低於門檻，濾掉）
# ancient 跨午夜多 5 秒 → 50%；qemu 多 9 秒 → 90%（但被 skip 濾掉）
SNAP_B='  101 10:05.00 /usr/bin/busy
  102 1:00:03 /Applications/iTerm.app/Contents/MacOS/iTerm2
  103 00:10.50 /usr/bin/idle
  104 1-00:00:03 /usr/bin/ancient
  105 00:14.00 /usr/local/bin/qemu-system-aarch64'

check "cpu_delta_report：MM:SS.ss 解析（5 秒/10 秒 = 50%）" \
      "$(cpu_delta_report "$SNAP_A" "$SNAP_B" 10 "qemu-system" | grep busy)" \
      "50.0 /usr/bin/busy"
# HH:MM:SS 若被當成 MM:SS 解析，1:00:00 會變成 60 秒而不是 3600 秒——差值仍是 2 秒，
# 所以這條要能紅，關鍵在下面的總和：解析錯會讓 ancient 那筆整個歪掉。
check "cpu_delta_report：HH:MM:SS 跨整點（5 秒/10 秒 = 50%）" \
      "$(cpu_delta_report "$SNAP_A" "$SNAP_B" 10 "qemu-system" | grep iTerm2 | cut -d' ' -f1)" \
      "50.0"
check "cpu_delta_report：DD-HH:MM:SS 跨午夜（5 秒/10 秒 = 50%）" \
      "$(cpu_delta_report "$SNAP_A" "$SNAP_B" 10 "qemu-system" | grep ancient | cut -d' ' -f1)" \
      "50.0"
# 低於 10% 的雜訊不該入列——不然每次跑都會印出一整頁系統背景行程。
check "cpu_delta_report：5% 的行程被門檻濾掉" \
      "$(cpu_delta_report "$SNAP_A" "$SNAP_B" 10 "qemu-system" | grep -c idle)" \
      "0"
# 被量的東西（qemu／MirageApp／WindowServer）不算污染，必須排除。
check "cpu_delta_report：skip regex 濾掉被量的行程" \
      "$(cpu_delta_report "$SNAP_A" "$SNAP_B" 10 "qemu-system" | grep -c qemu)" \
      "0"
check "cpu_delta_total：50+50+50 = 150" \
      "$(cpu_delta_total "$SNAP_A" "$SNAP_B" 10 "qemu-system")" "150"
# skip 為空字串時 qemu 的 90% 要算進來。
check "cpu_delta_total：skip 為空 → 含 qemu 共 240" \
      "$(cpu_delta_total "$SNAP_A" "$SNAP_B" 10 "")" "240"
# 新出現的行程（第一次快照裡沒有）不能被當成「用了全部 CPU 時間」。
check "cpu_delta_report：只在第二次快照出現的行程不列入" \
      "$(cpu_delta_report "$SNAP_A" "$SNAP_B$(printf '\n  999 99:00.00 /usr/bin/newcomer')" 10 "" | grep -c newcomer)" \
      "0"
check "cpu_delta_total：完全沒有超標行程 → 0" \
      "$(cpu_delta_total "$SNAP_A" "$SNAP_A" 10 "")" "0"

# === D67：外來 CPU 的硬閘門 ===
#
# 用既有的假快照：busy 50%、iTerm2 50%、ancient 50%、idle 5%（低於 floor 10 會被濾掉）、
# qemu 90%（被 skip 濾掉）。所以 floor 10 是 150、floor 0 是 155。
# **這 5 個百分點的差就是 D67 說的漏報**，只是在假資料上只有一個小行程。
check "foreign_cpu_totals：同時給 floor 10 與 floor 0" \
      "$(foreign_cpu_totals "$SNAP_A" "$SNAP_B" 10 "qemu-system")" "150 155"

if foreign_cpu_gate 150 50 2>/dev/null; then
    check "foreign_cpu_gate：150 超過上限 50 應回傳 1" "0" "1"
else
    check "foreign_cpu_gate：150 超過上限 50 應回傳 1" "1" "1"
fi
if foreign_cpu_gate 29 50 2>/dev/null; then
    check "foreign_cpu_gate：29 低於上限 50 應回傳 0" "0" "0"
else
    check "foreign_cpu_gate：29 低於上限 50 應回傳 0" "1" "0"
fi
# 門檻不含等號：剛好 50 不算通過。既有的 input_latency_cpu_gate 也是這個方向。
if foreign_cpu_gate 50 50 2>/dev/null; then
    check "foreign_cpu_gate：剛好等於上限應回傳 1" "0" "1"
else
    check "foreign_cpu_gate：剛好等於上限應回傳 1" "1" "1"
fi
# 拿不到讀數時放行等於預設「機器很安靜」，那正是這道閘門要擋的樂觀。
for bad in "" "n/a" "12abc"; do
    if foreign_cpu_gate "$bad" 50 2>/dev/null; then
        check "foreign_cpu_gate：非數字「${bad}」應回傳 1" "0" "1"
    else
        check "foreign_cpu_gate：非數字「${bad}」應回傳 1" "1" "1"
    fi
done

# === D60(a)：磁碟空間純函式 ===
( disk_gate 5119 5120 2>/dev/null ); check "disk_gate：低於門檻" "$?" 1
( disk_gate 5121 5120 2>/dev/null ); check "disk_gate：高於門檻" "$?" 0
( disk_gate 5120 5120 2>/dev/null ); check "disk_gate：等於門檻" "$?" 0
for bad in "" "n/a" "-1"; do
    ( disk_gate "$bad" 5120 2>/dev/null ); check "disk_gate：無效讀數「${bad}」" "$?" 1
    ( disk_gate 6000 "$bad" 2>/dev/null ); check "disk_gate：無效門檻「${bad}」" "$?" 1
done

# === D50：擷取窗口內的負載取樣 ===
#
# 用假的 load_avg_1min 序列取代真實讀數，這樣測的是「取樣與取峰值的邏輯」，
# 不是這台機器當下有多忙。窗口長度也一併驗，因為它是 fps 中位數的分母。
# 計數器放檔案而不是變數：`load_watch_sleep` 用 `$(load_avg_1min)` 取值，那是子行程，
# 變數的遞增回不到父行程，每次都會拿到同一筆。第一版就是這樣寫的，三條測試同時紅。
FAKE_DIR=$(mktemp -d -t load_sentinel_selftest)
trap 'rm -rf "$FAKE_DIR"' EXIT
FAKE_LOADS=""
fake_loads_reset() {
    FAKE_LOADS="$1"
    printf '0\n' > "$FAKE_DIR/index"
}
load_avg_1min() {
    local i
    i=$(( $(cat "$FAKE_DIR/index") + 1 ))
    printf '%s\n' "$i" > "$FAKE_DIR/index"
    printf '%s\n' "$FAKE_LOADS" | sed -n "${i}p"
}

fake_loads_reset "$(printf '1.0\n2.0\n30.0\n3.0\n')"
check "load_watch_sleep：回報窗口內的峰值而不是最後一筆" \
      "$(load_watch_sleep 3 1)" "30.0"

# 起跑安靜、中途飆高，正是 D50 記載的那兩個被污染的樣本的形狀。
fake_loads_reset "$(printf '2.0\n2.1\n40.0\n2.2\n')"
PEAK=$(load_watch_sleep 3 1)
check "load_watch_sleep：起跑安靜中途飆高也抓得到" "$PEAK" "40.0"
if load_peak_gate "$PEAK" 18 2>/dev/null; then
    check "load_peak_gate：峰值 40 超過上限 18 應回傳 1" "0" "1"
else
    check "load_peak_gate：峰值 40 超過上限 18 應回傳 1" "1" "1"
fi

fake_loads_reset "$(printf '5.0\n6.0\n7.0\n')"
PEAK=$(load_watch_sleep 2 1)
if load_peak_gate "$PEAK" 18 2>/dev/null; then
    check "load_peak_gate：峰值 7 未超過上限 18 應回傳 0" "0" "0"
else
    check "load_peak_gate：峰值 7 未超過上限 18 應回傳 0" "1" "0"
fi

# 窗口長度必須精準：interval 除不盡 duration 時不可以超睡。
fake_loads_reset "$(printf '1.0\n1.0\n1.0\n1.0\n1.0\n')"
START=$(date +%s)
load_watch_sleep 5 2 > /dev/null
ELAPSED=$(( $(date +%s) - START ))
if [ "$ELAPSED" -ge 5 ] && [ "$ELAPSED" -le 6 ]; then
    check "load_watch_sleep：duration 5、interval 2 睡滿 5 秒不超睡" "ok" "ok"
else
    check "load_watch_sleep：duration 5、interval 2 睡滿 5 秒不超睡" "${ELAPSED}s" "5s"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "全部通過"
    exit 0
fi
echo "$FAILURES 項失敗"
exit 1
