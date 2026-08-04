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
