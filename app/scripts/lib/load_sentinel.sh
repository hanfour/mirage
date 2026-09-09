#!/usr/bin/env bash
# 量測前後的環境哨兵。用法：source "$(dirname "$0")/lib/load_sentinel.sh"
#
# **存在的理由是 D32 踩過的坑**：這台開發機是共用的，load average 20+ 時
# `MirageScene` 的 `.task` 根本不觸發、視窗從未建立，連續四次量到全 0 fps，
# 當時誤以為是程式問題查了很久（見 app/RESULTS-d32.md 附錄）。
#
# D45 的量測是比值（Mirage vs 對照組），負載尖峰會讓分子分母不對等地失真，
# 所以規則是**寧可重測，不要留一筆自己都不相信的數字**。

# 當下 1 分鐘 load average。macOS 的 uptime 格式：
#   ... load averages: 2.51 3.02 3.41
load_avg_1min() {
    uptime | sed 's/.*load averages*: *//' | awk '{ print $1 }'
}

# load average 超過上限 → 印警告、回傳 1。否則回傳 0。
#
# **只回傳碼、不 exit**：呼叫端才知道該重測還是中止。量測腳本通常要重測，
# 但一次性的診斷指令可能只想知道環境髒不髒。
load_gate() {
    local limit="$1" la
    la=$(load_avg_1min)
    if awk -v a="$la" -v l="$limit" 'BEGIN { exit !(a > l) }'; then
        echo "⚠️ load average ${la} 超過上限 ${limit}——本次樣本不可信，建議重測。" >&2
        return 1
    fi
    return 0
}

# === 外來 CPU 的硬閘門（D67）===
#
# **「非工作負載 CPU 總和 <50%」在 `verify_fps_fullscreen.sh` 裡從來不是閘門。**
# 那個數字算出來之後只印，沒有進過任何比較，所以 50% 一直只是人工判讀紀律，
# 而驗收線 7 的每一個 fps 數字都是在這個尺度下判讀的。
#
# **同時那把尺會漏報**：`cpu_delta_report` 的預設 floor 是 10，低於 10% 的行程整個不計。
# 2026-09-08 實測同一時刻 floor 10 是 322 到 351%、floor 0 是 366 到 385%，
# 差距來自 50 個小行程；另一次量到差 100 個百分點。所以兩個 floor 都要印出來，
# 讓「這個窗口夠安靜」的判斷不會偏樂觀。
#
# **判定仍只用 floor 10**：門檻 50 是在 floor 10 下校準的（安靜窗口的 floor 10 是 29%），
# 換成 floor 0 需要重新校準而目前沒有那組資料。floor 0 印出來是給人看差距用的。
#
# ⚠️ 這裡刻意不重用 `input_latency.sh` 的 `input_latency_cpu_gate`：那支的輸出格式被
# `input_latency_selftest.sh` 逐字鎖住（`foreign_cpu_floor10=0% foreign_cpu_floor0=54%`），
# 動它的風險大於這幾行的重複。

# 同一組快照算出兩個 floor 的總和，印成「<floor10> <floor0>」。
foreign_cpu_totals() {
    local a="$1" b="$2" seconds="$3" skip="$4"
    printf '%s %s\n' \
        "$(cpu_delta_total "$a" "$b" "$seconds" "$skip" 10)" \
        "$(cpu_delta_total "$a" "$b" "$seconds" "$skip" 0)"
}

# floor 10 的總和超過上限 → 印警告、回傳 1。非數字也算不通過：拿不到讀數時
# 放行等於預設「機器很安靜」，而那正是這道閘門要擋的樂觀。
foreign_cpu_gate() {
    local value="$1" limit="$2"
    if ! awk -v v="$value" 'BEGIN { exit !(v ~ /^[0-9]+([.][0-9]+)?$/) }'; then
        echo "⚠️ 外來 CPU 讀數不是數字（得到「${value}」）——當作不通過。" >&2
        return 1
    fi
    if awk -v v="$value" -v l="$limit" 'BEGIN { exit !(v >= l) }'; then
        echo "⚠️ 非工作負載 CPU 總和 ${value}% 未低於 ${limit}%——本次量測不可信。" >&2
        return 1
    fi
    return 0
}

# === 擷取窗口內的負載（D50）===
#
# **`load_gate` 只在輪次開始前檢查一次，擋不住「起跑時安靜、跑到一半才飆高」。**
# D45 補測時有兩個樣本就是這樣被污染的：起始負載過關，負載在 20 秒擷取窗口中間才上來，
# 量到 `MIRAGE_MEDIAN=6` 與 `11`，而任何一次乾淨量測都落在 35 到 60 一帶。
# 那兩筆是靠人工比對既有基準才被識別並排除的；沒人回頭核對就會混進中位數。
#
# 修法是把擷取窗口的 `sleep` 換成會取樣的版本，回報窗口內的 load average 峰值，
# 讓呼叫端能在事後判定整輪要不要作廢。**刻意不在窗口中途中止**：中止會讓擷取窗口
# 長度不一致，而窗口長度本身就是 fps 中位數的分母。

# 睡滿 duration 秒，期間每 interval 秒取樣一次 load average，把峰值印到 stdout。
# 用法：peak=$(load_watch_sleep <duration> [interval，預設 2])
#
# 窗口長度必須精準：interval 除不盡 duration 時，最後一段只睡剩下的秒數，
# 總時長仍等於 duration。取樣本身不算在裡面（`uptime` 是毫秒等級）。
load_watch_sleep() {
    local duration="$1" interval="${2:-2}" peak la elapsed=0 chunk
    peak=$(load_avg_1min)
    while [ "$elapsed" -lt "$duration" ]; do
        chunk=$((duration - elapsed))
        [ "$chunk" -gt "$interval" ] && chunk="$interval"
        sleep "$chunk"
        elapsed=$((elapsed + chunk))
        la=$(load_avg_1min)
        peak=$(awk -v a="$la" -v p="$peak" 'BEGIN { print (a > p) ? a : p }')
    done
    printf '%s\n' "$peak"
}

# 窗口峰值超過上限 → 印警告、回傳 1。與 load_gate 同一個方向：紅燈是「這筆不可信」。
load_peak_gate() {
    local peak="$1" limit="$2"
    if awk -v a="$peak" -v l="$limit" 'BEGIN { exit !(a > l) }'; then
        echo "⚠️ 擷取窗口內 load average 峰值 ${peak} 超過上限 ${limit}——本輪樣本不可信。" >&2
        return 1
    fi
    return 0
}

# === 外來 CPU 佔用（D56 變異來源 (b)）===
#
# **`load_gate` 看的 load average 是 1 分鐘平均，看不出「是誰在吃」。** 量測被污染時
# 需要的是「除了被量的東西以外，還有什麼在燒 CPU」——三個 java 行程吃 356% 與
# 終端機自己畫輸出吃 70%，兩者的 load average 可能一樣，但結論完全不同。
#
# ⚠️ **不要用 `ps` 的 `%cpu` 欄位。** 在 macOS 上它是行程生命期的衰減平均，不是當下
# 用量——實測 iTerm2 報 **90.7%**，而它的 `etime` 是 **7 天**。拿它當門檻會永久卡住。
# 真實的瞬時用量要自己算：取兩次 `cputime`，相除以間隔。
#
# ⚠️ **也不要用 `ps aux` 取欄位**：`STARTED` 是一或兩個 token（`5:12AM` vs `Wed08AM`），
# COMMAND 的欄號會跟著移位。實測踩過，印出 `61% 1384:40.74`——那是 TIME 欄不是行程名。
# `ps -Ao pid=,cputime=,comm=` 是固定欄位，沒有這個問題。

# 取一次 CPU 時間快照。
cpu_snapshot() { ps -Ao pid=,cputime=,comm=; }

# 從兩次快照算出各行程的瞬時 CPU%，印成「<pct> <comm>」由高到低。
# 用法：cpu_delta_report "<快照A>" "<快照B>" <間隔秒> <要排除的行程 regex>
# 第五參數是單一行程的最低百分比，預設 10；傳 0 可加總所有正值。
#
# **純函式（吃字串、不碰系統），所以自我測試釘得住 cputime 的格式解析**——那是這段
# 唯一會錯的地方：macOS 的 cputime 可能是 `MM:SS.ss`、`HH:MM:SS` 或 `DD-HH:MM:SS`。
cpu_delta_report() {
    awk -v gap="$3" -v skip="$4" -v floor="${5:-10}" '
        function secs(t,   n, p, d, k) {
            d = 0
            k = index(t, "-")
            if (k > 0) { d = substr(t, 1, k - 1) + 0; t = substr(t, k + 1) }
            n = split(t, p, ":")
            if (n == 3) { return d * 86400 + p[1] * 3600 + p[2] * 60 + p[3] }
            if (n == 2) { return d * 86400 + p[1] * 60 + p[2] }
            return d * 86400 + t + 0
        }
        NR == FNR { prev[$1] = secs($2); next }
        {
            if (!($1 in prev)) { next }
            pct = (secs($2) - prev[$1]) / gap * 100
            if (pct <= floor) { next }
            cmd = ""
            for (i = 3; i <= NF; i++) { cmd = cmd (i > 3 ? " " : "") $i }
            if (skip != "" && cmd ~ skip) { next }
            printf "%.1f %s\n", pct, cmd
        }
    ' <(printf '%s\n' "$1") <(printf '%s\n' "$2") | sort -nr
}

# 同上，但只印總和（整數百分比）。沒有任何行程超標時印 0。
cpu_delta_total() {
    cpu_delta_report "$@" | awk '{ s += $1 } END { printf "%d\n", s }'
}
