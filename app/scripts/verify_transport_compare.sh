#!/usr/bin/env bash
# D58：在同一個窗口交錯量測 raw RGBA 與 MMAP，輸出可信的中位數對照。
#
# 用法：verify_transport_compare.sh [-p 8556] [-r 3] [-d 20]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"
COMMON_LIB="${SCRIPT_DIR}/lib/verify_common.sh"
LOAD_LIB="${SCRIPT_DIR}/lib/load_sentinel.sh"
source "${COMMON_LIB}"
source "${LOAD_LIB}"
cd "${SCRIPT_DIR}/.." || exit 1

PORT=8556
ROUNDS=3
DURATION=20
LOAD_LIMIT="${LOAD_LIMIT:-12}"
MIN_VALID="${MIN_VALID:-2}"
VENV="${TRANSPORT_COMPARE_VENV:-${SCRIPT_DIR}/../../phase0/harness/.venv-d45/bin/python}"
BASELINE="${SCRIPT_DIR}/../../phase0/harness/fps_baseline.py"

usage() {
    sed -n '2,7p' "${SCRIPT_PATH}"
}

while getopts "p:r:d:h" opt; do
    case "${opt}" in
        p) PORT="${OPTARG}" ;;
        r) ROUNDS="${OPTARG}" ;;
        d) DURATION="${OPTARG}" ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

validate_positive_int() {
    local label="$1" value="$2"
    case "${value}" in
        ''|*[!0-9]*)
            echo "❌ ${label} 必須是正整數：${value}" >&2
            return 1
            ;;
    esac
    if [ "${value}" -le 0 ]; then
        echo "❌ ${label} 必須大於 0：${value}" >&2
        return 1
    fi
    return 0
}

validate_positive_int "port" "${PORT}" || exit 2
validate_positive_int "rounds" "${ROUNDS}" || exit 2
validate_positive_int "seconds" "${DURATION}" || exit 2
validate_positive_int "MIN_VALID" "${MIN_VALID}" || exit 2
if [ "${PORT}" -gt 65535 ]; then
    echo "❌ port 超出範圍：${PORT}" >&2
    exit 2
fi

echo "=== 前置：gRPC ==="
require_grpc "${PORT}"

echo "=== 前置：venv python ==="
if [ ! -x "${VENV}" ]; then
    echo "❌ 找不到 venv python：${VENV}" >&2
    echo "請先建立環境：" >&2
    echo "  cd phase0/harness" >&2
    echo "  python3 -m venv .venv-d45" >&2
    echo "  ./.venv-d45/bin/pip install --quiet 'protobuf>=7.35,<8' grpcio numpy pytest" >&2
    exit 1
fi
if [ ! -f "${BASELINE}" ]; then
    echo "❌ 找不到 fps_baseline.py：${BASELINE}" >&2
    exit 1
fi
echo "✅ venv python：${VENV}"

SAMPLE_VALID=0
SAMPLE_STATUS="unknown"
SAMPLE_FPS="NA"
SAMPLE_FRAMES="NA"
SAMPLE_ELAPSED="NA"
SAMPLE_DISTINCT="NA"
SAMPLE_REASON="未解析"
SAMPLE_RC=1

run_sample() {
    local transport="$1"
    local json_file err_file parsed parse_rc
    json_file="$(mktemp -t d58_transport_json)"
    err_file="$(mktemp -t d58_transport_err)"

    "${VENV}" "${BASELINE}" --json --transport "${transport}" \
        --endpoint "localhost:${PORT}" --seconds "${DURATION}" \
        --width 900 --height 2000 > "${json_file}" 2> "${err_file}"
    SAMPLE_RC=$?

    parsed="$("${VENV}" - "${json_file}" "${DURATION}" <<'PY'
import json
import sys

path = sys.argv[1]
duration = float(sys.argv[2])

def clean(value, default="NA"):
    if value is None:
        return default
    return str(value).replace("\t", " ").replace("\n", " ")

try:
    with open(path, encoding="utf-8") as stream:
        result = json.load(stream)
except Exception as exc:
    print("\t".join(("0", "json-error", "NA", "NA", "NA", "NA",
                      clean(f"JSON 解析失敗：{exc}"))))
    raise SystemExit(0)

status = clean(result.get("status"), "unknown")
fps = result.get("fps")
frames = result.get("frames")
elapsed = result.get("elapsed")
distinct = result.get("distinct")
error = result.get("error")

try:
    elapsed_value = float(elapsed)
except (TypeError, ValueError):
    elapsed_value = None

valid = status == "measured" and elapsed_value is not None \
    and elapsed_value <= duration * 1.1
if valid:
    reason = "有效"
elif status != "measured":
    reason = f"status={status}"
    if error:
        reason += f" error={clean(error)}"
elif elapsed_value is None:
    reason = "elapsed 不是數字"
else:
    reason = f"elapsed={elapsed_value:.3f} 超過上限 {duration * 1.1:.3f}"

try:
    fps_text = f"{float(fps):.2f}"
except (TypeError, ValueError):
    fps_text = clean(fps)
try:
    elapsed_text = f"{float(elapsed):.3f}"
except (TypeError, ValueError):
    elapsed_text = clean(elapsed)

print("\t".join((
    "1" if valid else "0",
    status,
    fps_text,
    clean(frames),
    elapsed_text,
    clean(distinct),
    clean(reason),
)))
PY
    )"
    parse_rc=$?
    if [ "${parse_rc}" -ne 0 ]; then
        parsed="0\tjson-error\tNA\tNA\tNA\tNA\tvenv Python 無法解析 JSON"
    fi
    if [ "${SAMPLE_RC}" -ne 0 ] && [ -s "${err_file}" ]; then
        while IFS= read -r error_line; do
            echo "     ${transport}：${error_line}"
        done < "${err_file}"
    fi
    rm -f "${json_file}" "${err_file}"

    IFS=$'\t' read -r SAMPLE_VALID SAMPLE_STATUS SAMPLE_FPS SAMPLE_FRAMES \
        SAMPLE_ELAPSED SAMPLE_DISTINCT SAMPLE_REASON <<< "${parsed}"
    if [ "${SAMPLE_VALID}" -ne 1 ]; then
        echo "   ${transport} 無效：${SAMPLE_REASON}（退出碼 ${SAMPLE_RC}）"
    fi
}

median_of() {
    local values="$1"
    "${VENV}" - "${values}" <<'PY'
import statistics
import sys

values = [float(value) for value in sys.argv[1].split() if value]
print(f"{statistics.median(values):.2f}")
PY
}

difference_of() {
    "${VENV}" - "$1" "$2" <<'PY'
import sys

print(f"{float(sys.argv[2]) - float(sys.argv[1]):.2f}")
PY
}

printf "\n%-4s %-8s %-9s %8s %8s %9s %9s %-12s %-12s %-12s\n" \
    "輪次" "順序" "transport" "fps" "frames" "elapsed" "distinct" \
    "status" "量測前負載" "量測後負載"
printf '%s\n' "--------------------------------------------------------------------------------"

RGBA_VALUES=""
MMAP_VALUES=""
RGBA_VALID=0
MMAP_VALID=0

for round in $(seq 1 "${ROUNDS}"); do
    echo ""
    echo "=== 第 ${round}/${ROUNDS} 輪：負載門檻（上限 ${LOAD_LIMIT}）==="
    LOAD_BEFORE="$(load_avg_1min)"
    if ! load_gate "${LOAD_LIMIT}"; then
        echo "❌ 第 ${round} 輪量測前負載 ${LOAD_BEFORE} 已超標，中止。"
        exit 1
    fi
    echo "✅ 量測前負載 ${LOAD_BEFORE}（上限 ${LOAD_LIMIT}）"

    if [ $((round % 2)) -eq 1 ]; then
        FIRST_TRANSPORT="rgba"
        SECOND_TRANSPORT="mmap"
    else
        FIRST_TRANSPORT="mmap"
        SECOND_TRANSPORT="rgba"
    fi

    run_sample "${FIRST_TRANSPORT}"
    FIRST_VALID="${SAMPLE_VALID}"
    FIRST_STATUS="${SAMPLE_STATUS}"
    FIRST_FPS="${SAMPLE_FPS}"
    FIRST_FRAMES="${SAMPLE_FRAMES}"
    FIRST_ELAPSED="${SAMPLE_ELAPSED}"
    FIRST_DISTINCT="${SAMPLE_DISTINCT}"

    run_sample "${SECOND_TRANSPORT}"
    SECOND_VALID="${SAMPLE_VALID}"
    SECOND_STATUS="${SAMPLE_STATUS}"
    SECOND_FPS="${SAMPLE_FPS}"
    SECOND_FRAMES="${SAMPLE_FRAMES}"
    SECOND_ELAPSED="${SAMPLE_ELAPSED}"
    SECOND_DISTINCT="${SAMPLE_DISTINCT}"

    load_gate "${LOAD_LIMIT}"
    AFTER_GATE_RC=$?
    LOAD_AFTER="$(load_avg_1min)"
    echo "   量測後負載 ${LOAD_AFTER}（本輪 ${LOAD_BEFORE} → ${LOAD_AFTER}）"
    printf "%-4s %-8s %-9s %8s %8s %9s %9s %-12s %-12s %-12s\n" \
        "${round}" "${FIRST_TRANSPORT}/${SECOND_TRANSPORT}" "${FIRST_TRANSPORT}" \
        "${FIRST_FPS}" "${FIRST_FRAMES}" "${FIRST_ELAPSED}" "${FIRST_DISTINCT}" \
        "${FIRST_STATUS}" "${LOAD_BEFORE}" "${LOAD_AFTER}"
    printf "%-4s %-8s %-9s %8s %8s %9s %9s %-12s %-12s %-12s\n" \
        "${round}" "${FIRST_TRANSPORT}/${SECOND_TRANSPORT}" "${SECOND_TRANSPORT}" \
        "${SECOND_FPS}" "${SECOND_FRAMES}" "${SECOND_ELAPSED}" "${SECOND_DISTINCT}" \
        "${SECOND_STATUS}" "${LOAD_BEFORE}" "${LOAD_AFTER}"

    if [ "${AFTER_GATE_RC}" -ne 0 ]; then
        echo "❌ 第 ${round} 輪量測後負載 ${LOAD_AFTER} 已超標，中止。"
        exit 1
    fi

    if [ "${FIRST_VALID}" -eq 1 ]; then
        if [ "${FIRST_TRANSPORT}" = "rgba" ]; then
            RGBA_VALUES="${RGBA_VALUES} ${FIRST_FPS}"
            RGBA_VALID=$((RGBA_VALID + 1))
        else
            MMAP_VALUES="${MMAP_VALUES} ${FIRST_FPS}"
            MMAP_VALID=$((MMAP_VALID + 1))
        fi
    fi
    if [ "${SECOND_VALID}" -eq 1 ]; then
        if [ "${SECOND_TRANSPORT}" = "rgba" ]; then
            RGBA_VALUES="${RGBA_VALUES} ${SECOND_FPS}"
            RGBA_VALID=$((RGBA_VALID + 1))
        else
            MMAP_VALUES="${MMAP_VALUES} ${SECOND_FPS}"
            MMAP_VALID=$((MMAP_VALID + 1))
        fi
    fi
done

RGBA_MEDIAN="無資料"
MMAP_MEDIAN="無資料"
if [ "${RGBA_VALID}" -gt 0 ]; then
    RGBA_MEDIAN="$(median_of "${RGBA_VALUES}")"
fi
if [ "${MMAP_VALID}" -gt 0 ]; then
    MMAP_MEDIAN="$(median_of "${MMAP_VALUES}")"
fi

echo ""
echo "===== 解析結果 ====="
echo "rgba：中位數 ${RGBA_MEDIAN} fps，有效輪數 ${RGBA_VALID}"
echo "mmap：中位數 ${MMAP_MEDIAN} fps，有效輪數 ${MMAP_VALID}"
if [ "${RGBA_VALID}" -gt 0 ] && [ "${MMAP_VALID}" -gt 0 ]; then
    echo "差值（mmap - rgba）：$(difference_of "${RGBA_MEDIAN}" "${MMAP_MEDIAN}") fps"
else
    echo "差值（mmap - rgba）：無資料"
fi

assert_at_least "rgba 有效輪數" "${RGBA_VALID}" "${MIN_VALID}"
assert_at_least "mmap 有效輪數" "${MMAP_VALID}" "${MIN_VALID}"
echo "✅ 兩種 transport 都達到至少 ${MIN_VALID} 個有效樣本；本腳本不判定誰比較快。"
