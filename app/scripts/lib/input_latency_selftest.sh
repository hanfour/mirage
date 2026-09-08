#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/input_latency.sh"
source "$HERE/load_sentinel.sh"
WORK=$(mktemp -d -t input_latency_selftest)
trap 'rm -rf "$WORK"' EXIT

fixture() {
    local fault="$1" i=4 t=40 invalid=0 unavailable=0 p=12
    case "$fault" in
        inject) i=1 ;;
        transit) t=29 ;;
        invalid) invalid=1 ;;
        unavailable) unavailable=1 ;;
        sum) p=80 ;;
    esac
    for ((n=0;n<20;n++)); do
        printf '[app] inject p50=2.0ms p95=8.0ms n=%s\n' "$i"
        printf '[app] lat p50=15.0ms p95=25.0ms n=40\n'
        printf '[app] transit p50=%s.0ms p95=90.0ms n=%s invalid=%s unavailable=%s\n' "$p" "$t" "$invalid" "$unavailable"
    done
}

run_case() {
    local fault="$1" cpu=10
    [ "$fault" != cpu ] || cpu=50
    input_latency_cpu_gate "$cpu" || return 1
    fixture "$fault" > "$WORK/fixture.log"
    input_latency_round "$WORK/fixture.log" 1 || return 1
    printf '%s %s %s %s\n' "$INJECT" "$TRANSIT" "$RENDER" "$SUM" > "$WORK/rows"
    input_latency_summary "$WORK/rows"
}

if [ "${1:-}" = --fault ]; then
    case "${2:-}" in inject|transit|invalid|unavailable|cpu|sum) run_case "$2"; exit $? ;; *) exit 2 ;; esac
fi

failures=0
osascript -l JavaScript "$HERE/cgclick_selftest.js" "$HERE/cgclick.js" || failures=$((failures+1))
# 無效參數在載入 CoreGraphics 前即退出，這裡不會送出事件。
for args in '' '1 2 3' 'abc 2 3 0' '1 2 1.5 0' '1 2 3 -1'; do
    if osascript -l JavaScript "$HERE/cgclick.js" $args > "$WORK/cgclick-invalid.log" 2>&1; then
        failures=$((failures+1))
    fi
    grep -q 'Error:' "$WORK/cgclick-invalid.log" || failures=$((failures+1))
done
# 在子 shell 取代負載與時間來源，不讀實機負載，也不真的等待。
load_tests() (
    local calls=0 sleeps=0 succeed=1 slept=0 SECONDS=0
    load_gate() { calls=$((calls+1)); [ "$1" = 18 ] && [ "$calls" -ge "$succeed" ]; }
    sleep() { sleeps=$((sleeps+1)); slept=$((slept+$1)); SECONDS=$((SECONDS+$1)); }
    input_latency_load_retry 18 6 5 || return 1
    [ "$calls:$sleeps" = '1:0' ] || return 1
    calls=0; sleeps=0; succeed=3
    input_latency_load_retry 18 6 5 > "$WORK/retry.log" || return 1
    [ "$calls:$sleeps" = '3:2' ] || return 1
    grep -q 'load_gate 攔下（第 2/6 次），等 5 秒後重試本輪' "$WORK/retry.log" || return 1
    calls=0; sleeps=0; succeed=6
    input_latency_load_retry 18 6 5 || return 1
    [ "$calls:$sleeps" = '6:5' ] || return 1
    calls=0; sleeps=0; succeed=99
    : > "$WORK/rounds.txt"
    : > "$WORK/rejected.txt"
    input_latency_collect 1 "$WORK" input_latency_load_retry 18 6 5
    [ "$calls:$sleeps" = '6:6' ] || return 1
    grep -q '重試 6 次仍被 load_gate 擋下，放棄本輪（如實記錄，不湊數）' "$WORK/rejected.txt" || return 1
    if input_latency_finish "$WORK" 1 > "$WORK/load-finish.log"; then return 1; fi
    grep -q 'VALID_ROUNDS=0 REQUIRED_ROUNDS=1' "$WORK/load-finish.log" || return 1
    if grep -q 'PASS:' "$WORK/load-finish.log"; then return 1; fi
    calls=0; sleeps=0; succeed=1; SECONDS=0
    input_latency_wait_load 18 60 5 > "$WORK/warm.log" || return 1
    [ "$calls:$sleeps" = '1:0' ] || return 1
    calls=0; sleeps=0; succeed=3; SECONDS=0
    input_latency_wait_load 18 60 5 > "$WORK/warm.log" || return 1
    grep -q '已等 10 秒' "$WORK/warm.log" || return 1
    calls=0; sleeps=0; slept=0; succeed=99; SECONDS=0
    if input_latency_wait_load 18 12 5 > "$WORK/warm.log"; then return 1; fi
    [ "$calls:$sleeps:$slept" = '4:3:12' ] || return 1
    grep -q '等待逾時，已等 12 秒（上限 12 秒）' "$WORK/warm.log"
)
load_tests || failures=$((failures+1))
run_case clean || failures=$((failures+1))
for fault in inject transit invalid unavailable cpu sum; do
    /bin/bash "$0" --fault "$fault" > "$WORK/$fault.log" 2>&1
    rc=$?
    printf 'FAULT %s rc=%s\n' "$fault" "$rc"
    cat "$WORK/$fault.log"
    [ "$rc" -ne 0 ] || failures=$((failures+1))
done
fixture clean > "$WORK/fixture.log"
[ "$(tagged_median "$WORK/fixture.log" transit p50)" = 12 ] || failures=$((failures+1))
[ "$(tagged_median "$WORK/fixture.log" inject p95)" = 8 ] || failures=$((failures+1))
[ "$(input_latency_counts "$WORK/fixture.log" inject)" = '80 0 0' ] || failures=$((failures+1))
printf '%s\n' '[app] inject p50=99ms p95=100ms n=1' '[app] inject p50=3ms p95=5ms n=2' > "$WORK/skip.log"
[ "$(tagged_median "$WORK/skip.log" inject p50 1)" = 3 ] || failures=$((failures+1))
printf '%s\n' '[app] transit p50=NA p95=NA n=0 invalid=0 unavailable=40' > "$WORK/na.log"
[ "$(input_latency_counts "$WORK/na.log" transit)" = '0 0 40' ] || failures=$((failures+1))
printf '%s\n' '[app] inject p50=1ms p95=2ms n=40' >> "$WORK/na.log"
if input_latency_round "$WORK/na.log" 1 > "$WORK/na.out"; then failures=$((failures+1)); fi
grep -q 'MMAP cannot measure transit' "$WORK/na.out" || failures=$((failures+1))
printf '%s\n' '[app] transit p50=12ms p95=20ms n=600' > "$WORK/bad.log"
if input_latency_counts "$WORK/bad.log" transit; then failures=$((failures+1)); fi
if input_latency_counts /dev/null inject; then failures=$((failures+1)); fi
printf '%s\n' '1 10 20 31' '3 30 40 73' '2 20 30 52' > "$WORK/three.rows"
summary=$(input_latency_summary "$WORK/three.rows") || failures=$((failures+1))
for expected in INJECT_MEDIAN=2.0 TRANSIT_MEDIAN=20.0 RENDER_MEDIAN=30.0 SUM_MEDIAN=52.0 SUM_RANGE=31.0..73.0; do
    printf '%s\n' "$summary" | grep -qx "$expected" || failures=$((failures+1))
done
printf '%s\n' '60 10 10 80' > "$WORK/eighty.rows"
if input_latency_summary "$WORK/eighty.rows" > "$WORK/eighty.out"; then failures=$((failures+1)); fi
grep -q 'largest segment=inject' "$WORK/eighty.out" || failures=$((failures+1))
# 六個各低於 10% 的行程仍須計入 floor 0 的額外資訊。
a=''; b=''
for ((n=1;n<=6;n++)); do
    a="${a}${n} 00:00.00 foreign${n}
"
    b="${b}${n} 00:00.45 foreign${n}
"
done
[ "$(cpu_delta_total "$a" "$b" 5 'qemu-system|MirageApp|WindowServer' 0)" = 54 ] || failures=$((failures+1))
cpu_output=$(input_latency_cpu_window "$a" "$b" 5 1) || failures=$((failures+1))
echo "$cpu_output"
[[ "$cpu_output" == *'foreign_cpu_floor10=0% foreign_cpu_floor0=54%'* ]] || failures=$((failures+1))
# 第一輪有效、第二輪無效、第三輪仍執行，保留兩輪數字但全跑必須紅燈。
: > "$WORK/rounds.txt"
: > "$WORK/rejected.txt"
for round in 1 2 3; do
    fault=clean
    [ "$round" -ne 2 ] || fault=invalid
    fixture "$fault" > "$WORK/round-$round.log"
    input_latency_collect "$round" "$WORK" input_latency_round "$WORK/round-$round.log" "$round"
done
[ "$(wc -l < "$WORK/rounds.txt" | tr -d ' ')" = 2 ] || failures=$((failures+1))
grep -q '\[round 3\] inject_p50=' "$WORK/result-3.log" || failures=$((failures+1))
if input_latency_finish "$WORK" 3 > "$WORK/finish.log"; then failures=$((failures+1)); fi
cat "$WORK/finish.log"
grep -q 'invalid=20' "$WORK/finish.log" || failures=$((failures+1))
grep -q 'insufficient valid rounds' "$WORK/finish.log" || failures=$((failures+1))
if grep -q 'PASS:' "$WORK/finish.log"; then failures=$((failures+1)); fi
input_latency_finish "$WORK" 2 > /dev/null || failures=$((failures+1))
: > "$WORK/rounds.txt"
if input_latency_finish "$WORK" 3 > "$WORK/empty-finish.log"; then failures=$((failures+1)); fi
grep -q 'insufficient valid rounds' "$WORK/empty-finish.log" || failures=$((failures+1))
echo "input_latency selftest failures=${failures}"
[ "$failures" -eq 0 ]
