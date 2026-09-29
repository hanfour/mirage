#!/usr/bin/env bash
# InstanceManager 驗收腳本的純解析與判斷函式。

il_log_transitions() {
    printf '%s\n' "$1" | awk '
        /^\[launcher\] / && NF == 5 && $4 ~ /^--[[:alnum:]]+-->$/ {
            event = $4
            sub(/^--/, "", event)
            sub(/-->$/, "", event)
            printf "%s\t%s\t%s\t%s\n", $2, $3, event, $5
        }'
}

il_log_has_transition() {
    local text="$1" avd="$2" old="$3" event="$4" new="$5"
    il_log_transitions "$text" | awk -F '\t' \
        -v avd="$avd" -v old="$old" -v event="$event" -v new="$new" \
        '$1 == avd && $2 == old && $3 == event && $4 == new { found = 1 }
         END { exit !found }'
}

il_log_has_destination() {
    local text="$1" avd="$2" state="$3"
    il_log_transitions "$text" | awk -F '\t' \
        -v avd="$avd" -v state="$state" \
        '$1 == avd && $4 == state { found = 1 }
         END { exit !found }'
}

# 要求目的狀態依序出現；中間可有其他轉移。
il_log_states_in_order() {
    local text="$1" avd="$2" expected
    shift 2
    [ "$#" -gt 0 ] || return 1
    expected="$*"
    il_log_transitions "$text" | awk -F '\t' -v avd="$avd" -v expected="$expected" '
        BEGIN { count = split(expected, wanted, " ") }
        $1 == avd && $4 == wanted[matched + 1] { matched++ }
        END { exit matched < count }'
}

il_discovery_line() {
    local text="$1" avd="$2"
    printf '%s\n' "$text" | awk -v avd="$avd" \
        '$1 == "[launcher]" && $2 == avd && $3 ~ /^spawnPid=(none|[0-9]+)$/ \
         && $4 ~ /^discoveryPid=[0-9]+$/ { line = $0 }
         END { if (line != "") print line }'
}

il_discovery_pids() {
    printf '%s\n' "$1" | awk '
        $1 == "[launcher]" && $3 ~ /^spawnPid=(none|[0-9]+)$/ \
         && $4 ~ /^discoveryPid=[0-9]+$/ {
            spawn = $3
            discovered = $4
            sub(/^spawnPid=/, "", spawn)
            sub(/^discoveryPid=/, "", discovered)
            print spawn " " discovered
        }'
}

# 輸出正規化 TSV：AVD、console 埠、pid。格式錯誤時回傳非零。
il_owned_records() {
    python3 -c '
import json
import datetime
import sys

try:
    records = json.loads(sys.argv[1])
except (TypeError, ValueError):
    sys.exit(2)
if not isinstance(records, list):
    sys.exit(2)
rows = []
for record in records:
    if not isinstance(record, dict):
        sys.exit(2)
    avd = record.get("avd")
    port = record.get("consolePort")
    pid = record.get("pid")
    started_at = record.get("startedAt")
    if (not isinstance(avd, str) or not avd or "\t" in avd or "\n" in avd
            or not isinstance(port, int) or isinstance(port, bool)
            or not isinstance(pid, int) or isinstance(pid, bool)
            or not isinstance(started_at, str)):
        sys.exit(2)
    try:
        parsed_at = datetime.datetime.fromisoformat(started_at.replace("Z", "+00:00"))
    except ValueError:
        sys.exit(2)
    if parsed_at.tzinfo is None:
        sys.exit(2)
    rows.append(f"{avd}\t{port}\t{pid}")
sys.stdout.write("\n".join(rows))
' "$1"
}

il_owned_count() {
    local records
    records=$(il_owned_records "$1") || return 1
    printf '%s\n' "$records" | awk 'NF { count++ } END { print count + 0 }'
}

il_owned_has_record() {
    local records
    records=$(il_owned_records "$1") || return 1
    printf '%s\n' "$records" | awk -F '\t' \
        -v avd="$2" -v port="$3" -v pid="$4" \
        '$1 == avd && $2 == port && $3 == pid { found = 1 }
         END { exit !found }'
}

il_owned_has_instance() {
    local records
    records=$(il_owned_records "$1") || return 1
    printf '%s\n' "$records" | awk -F '\t' \
        -v avd="$2" -v port="$3" \
        '$1 == avd && $2 == port { found = 1 }
         END { exit !found }'
}
