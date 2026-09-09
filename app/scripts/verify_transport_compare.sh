#!/usr/bin/env bash
# D58：在同一個窗口交錯量測多條 transport，輸出可信的中位數對照。
#
# 用法：verify_transport_compare.sh [-p 8556] [-r 3] [-d 20] [-s rgba,swift]
set -uo pipefail

source "$(dirname "$0")/lib/load_sentinel.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"
COMMON_LIB="${SCRIPT_DIR}/lib/verify_common.sh"
LOAD_LIB="${SCRIPT_DIR}/lib/load_sentinel.sh"
source "${COMMON_LIB}"
source "${LOAD_LIB}"
cd "${SCRIPT_DIR}/.." || exit 1

PACKAGE_DIR="${SCRIPT_DIR}/.."
PORT=8556
ROUNDS=3
DURATION=20
SERIES_SPEC="rgba,swift"
LOAD_LIMIT="${LOAD_LIMIT:-12}"
MIN_VALID="${MIN_VALID:-2}"
VENV="${TRANSPORT_COMPARE_VENV:-${SCRIPT_DIR}/../../phase0/harness/.venv-d45/bin/python}"
BASELINE="${SCRIPT_DIR}/../../phase0/harness/fps_baseline.py"
SWIFT_BINARY=""

usage() {
    sed -n '2,5p' "${SCRIPT_PATH}"
}

while getopts "p:r:d:s:h" opt; do
    case "${opt}" in
        p) PORT="${OPTARG}" ;;
        r) ROUNDS="${OPTARG}" ;;
        d) DURATION="${OPTARG}" ;;
        s) SERIES_SPEC="${OPTARG}" ;;
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

IFS=',' read -r -a SERIES <<< "${SERIES_SPEC}"
if [ "${#SERIES[@]}" -eq 0 ]; then
    echo "❌ 至少要指定一個系列：${SERIES_SPEC}" >&2
    exit 2
fi
for series_index_value in "${!SERIES[@]}"; do
    series="${SERIES[${series_index_value}]}"
    case "${series}" in
        rgba|mmap|swift) ;;
        *)
            echo "❌ 不支援的系列：${series}（可用 rgba、mmap、swift）" >&2
            exit 2
            ;;
    esac
    if [ "${series_index_value}" -gt 0 ]; then
        for previous_index in $(seq 0 $((series_index_value - 1))); do
            if [ "${SERIES[${previous_index}]}" = "${series}" ]; then
                echo "❌ 系列不可重複：${series}" >&2
                exit 2
            fi
        done
    fi
done

# D60(a)：參數解析與驗證完成後，量測前才檢查主機磁碟。
disk_preflight "$SCRIPT_DIR" || exit 1

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

for series in "${SERIES[@]}"; do
    if [ "${series}" = "swift" ]; then
        echo "=== 前置：mirage-pull release ==="
        if ! build_warm release 3 "${PACKAGE_DIR}" "mirage-pull"; then
            exit 1
        fi
        if ! SWIFT_BIN_PATH="$(cd "${PACKAGE_DIR}" && swift build -c release --show-bin-path)"; then
            echo "❌ 無法取得 release 執行檔路徑" >&2
            exit 1
        fi
        SWIFT_BINARY="${SWIFT_BIN_PATH}/mirage-pull"
        if [ ! -x "${SWIFT_BINARY}" ]; then
            echo "❌ 找不到 mirage-pull：${SWIFT_BINARY}" >&2
            exit 1
        fi
        echo "✅ mirage-pull：${SWIFT_BINARY}"
        break
    fi
done

SAMPLE_VALID=0
SAMPLE_STATUS="unknown"
SAMPLE_FPS="NA"
SAMPLE_FRAMES="NA"
SAMPLE_ELAPSED="NA"
SAMPLE_DISTINCT="NA"
SAMPLE_REASON="未解析"
SAMPLE_CLIENT="unknown"
SAMPLE_RC=1

run_sample() {
    local transport="$1"
    local json_file err_file parsed parse_rc command_error
    json_file="$(mktemp -t d58_transport_json)"
    err_file="$(mktemp -t d58_transport_err)"

    if [ "${transport}" = "swift" ]; then
        "${SWIFT_BINARY}" --json \
            --endpoint "localhost:${PORT}" --seconds "${DURATION}" \
            --width 900 --height 2000 > "${json_file}" 2> "${err_file}"
    else
        "${VENV}" "${BASELINE}" --json --transport "${transport}" \
            --endpoint "localhost:${PORT}" --seconds "${DURATION}" \
            --width 900 --height 2000 > "${json_file}" 2> "${err_file}"
    fi
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
                      clean(f"JSON 解析失敗：{exc}"), "unknown")))
    raise SystemExit(0)

status = clean(result.get("status"), "unknown")
fps = result.get("fps")
frames = result.get("frames")
elapsed = result.get("elapsed")
distinct = result.get("distinct")
error = result.get("error")
client = clean(result.get("client"), "python")

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
    client,
)))
PY
    )"
    parse_rc=$?
    if [ "${parse_rc}" -ne 0 ]; then
        parsed=$'0\tjson-error\tNA\tNA\tNA\tNA\tvenv Python 無法解析 JSON\tunknown'
    fi
    if [ "${SAMPLE_RC}" -ne 0 ] && [ -s "${err_file}" ]; then
        while IFS= read -r command_error; do
            echo "     ${transport}：${command_error}"
        done < "${err_file}"
    fi
    rm -f "${json_file}" "${err_file}"

    IFS=$'\t' read -r SAMPLE_VALID SAMPLE_STATUS SAMPLE_FPS SAMPLE_FRAMES \
        SAMPLE_ELAPSED SAMPLE_DISTINCT SAMPLE_REASON SAMPLE_CLIENT <<< "${parsed}"
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

printf "\n%-4s %-18s %-12s %-9s %8s %8s %9s %9s %-12s %-12s %-12s\n" \
    "輪次" "順序" "client" "transport" "fps" "frames" "elapsed" "distinct" \
    "status" "量測前負載" "量測後負載"
printf '%s\n' "------------------------------------------------------------------------------------------------"

SERIES_VALUES=()
SERIES_VALID=()
for series in "${SERIES[@]}"; do
    SERIES_VALUES+=("")
    SERIES_VALID+=(0)
done

SERIES_COUNT="${#SERIES[@]}"
for round in $(seq 1 "${ROUNDS}"); do
    echo ""
    echo "=== 第 ${round}/${ROUNDS} 輪：負載門檻（上限 ${LOAD_LIMIT}）==="
    LOAD_BEFORE="$(load_avg_1min)"
    if ! load_gate "${LOAD_LIMIT}"; then
        echo "❌ 第 ${round} 輪量測前負載 ${LOAD_BEFORE} 已超標，中止。"
        exit 1
    fi
    echo "✅ 量測前負載 ${LOAD_BEFORE}（上限 ${LOAD_LIMIT}）"

    start_index=$(( (round - 1) % SERIES_COUNT ))
    order=""
    ROUND_SERIES=()
    ROUND_CLIENT=()
    ROUND_VALID=()
    ROUND_STATUS=()
    ROUND_FPS=()
    ROUND_FRAMES=()
    ROUND_ELAPSED=()
    ROUND_DISTINCT=()

    for offset in $(seq 0 $((SERIES_COUNT - 1))); do
        series_index_value=$(( (start_index + offset) % SERIES_COUNT ))
        series="${SERIES[${series_index_value}]}"
        if [ -n "${order}" ]; then
            order="${order}/${series}"
        else
            order="${series}"
        fi

        run_sample "${series}"
        ROUND_SERIES+=("${series}")
        ROUND_CLIENT+=("${SAMPLE_CLIENT}")
        ROUND_VALID+=("${SAMPLE_VALID}")
        ROUND_STATUS+=("${SAMPLE_STATUS}")
        ROUND_FPS+=("${SAMPLE_FPS}")
        ROUND_FRAMES+=("${SAMPLE_FRAMES}")
        ROUND_ELAPSED+=("${SAMPLE_ELAPSED}")
        ROUND_DISTINCT+=("${SAMPLE_DISTINCT}")
    done

    load_gate "${LOAD_LIMIT}"
    AFTER_GATE_RC=$?
    LOAD_AFTER="$(load_avg_1min)"
    echo "   量測後負載 ${LOAD_AFTER}（本輪 ${LOAD_BEFORE} → ${LOAD_AFTER}）"
    for sample_index in "${!ROUND_SERIES[@]}"; do
        printf "%-4s %-18s %-12s %-9s %8s %8s %9s %9s %-12s %-12s %-12s\n" \
            "${round}" "${order}" "${ROUND_CLIENT[${sample_index}]}" \
            "${ROUND_SERIES[${sample_index}]}" "${ROUND_FPS[${sample_index}]}" \
            "${ROUND_FRAMES[${sample_index}]}" "${ROUND_ELAPSED[${sample_index}]}" \
            "${ROUND_DISTINCT[${sample_index}]}" "${ROUND_STATUS[${sample_index}]}" \
            "${LOAD_BEFORE}" "${LOAD_AFTER}"
    done

    if [ "${AFTER_GATE_RC}" -ne 0 ]; then
        echo "❌ 第 ${round} 輪量測後負載 ${LOAD_AFTER} 已超標，中止。"
        exit 1
    fi

    for sample_index in "${!ROUND_SERIES[@]}"; do
        if [ "${ROUND_VALID[${sample_index}]}" -eq 1 ]; then
            for series_index_value in "${!SERIES[@]}"; do
                if [ "${SERIES[${series_index_value}]}" = "${ROUND_SERIES[${sample_index}]}" ]; then
                    SERIES_VALUES[${series_index_value}]="${SERIES_VALUES[${series_index_value}]} ${ROUND_FPS[${sample_index}]}"
                    SERIES_VALID[${series_index_value}]=$((SERIES_VALID[${series_index_value}] + 1))
                    break
                fi
            done
        fi
    done
done

MEDIANS=()
echo ""
echo "===== 解析結果 ====="
for series_index_value in "${!SERIES[@]}"; do
    median="無資料"
    if [ "${SERIES_VALID[${series_index_value}]}" -gt 0 ]; then
        median="$(median_of "${SERIES_VALUES[${series_index_value}]}")"
    fi
    MEDIANS+=("${median}")
    echo "${SERIES[${series_index_value}]}：中位數 ${median} fps，有效輪數 ${SERIES_VALID[${series_index_value}]}"
done

BASE_SERIES="${SERIES[0]}"
BASE_MEDIAN="${MEDIANS[0]}"
for series_index_value in "${!SERIES[@]}"; do
    series="${SERIES[${series_index_value}]}"
    if [ "${SERIES_VALID[0]}" -gt 0 ] && [ "${SERIES_VALID[${series_index_value}]}" -gt 0 ]; then
        if [ "${series_index_value}" -eq 0 ]; then
            difference="0.00"
        else
            difference="$(difference_of "${BASE_MEDIAN}" "${MEDIANS[${series_index_value}]}")"
        fi
        echo "差值（${series} - ${BASE_SERIES}）：${difference} fps"
    else
        echo "差值（${series} - ${BASE_SERIES}）：無資料"
    fi
done

for series_index_value in "${!SERIES[@]}"; do
    assert_at_least "${SERIES[${series_index_value}]} 有效輪數" \
        "${SERIES_VALID[${series_index_value}]}" "${MIN_VALID}"
done
echo "✅ 所有系列都達到至少 ${MIN_VALID} 個有效樣本；本腳本不判定誰比較快。"
