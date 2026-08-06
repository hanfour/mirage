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
#
# **純函式（吃字串、不碰系統），所以自我測試釘得住 cputime 的格式解析**——那是這段
# 唯一會錯的地方：macOS 的 cputime 可能是 `MM:SS.ss`、`HH:MM:SS` 或 `DD-HH:MM:SS`。
cpu_delta_report() {
    awk -v gap="$3" -v skip="$4" '
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
            if (pct <= 10) { next }
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
