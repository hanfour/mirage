#!/usr/bin/env bash
# 在同一台 emulator、同一份畫面上交錯量測 guest 的 none／pull／app 回壓。
#
# 用法：verify_guest_backpressure.sh [-p 8556] [-s emulator-5556] [-r 3] [-d 20] [-c none,pull,app]
set -uo pipefail

# 所有 source 路徑先解析成絕對路徑，再切換工作目錄（D55）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "$0")"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/verify_common.sh"
source "${SCRIPT_DIR}/lib/gui_session.sh"
source "${SCRIPT_DIR}/lib/load_sentinel.sh"
source "${SCRIPT_DIR}/lib/guest_fps.sh"
source "${SCRIPT_DIR}/lib/backpressure.sh"
cd "${PACKAGE_DIR}" || exit 1

SERIAL="emulator-5556"
GRPC_PORT="8556"
ROUNDS=3
DURATION=20
CONDITION_SPEC="none,pull,app"
PACKAGE="${MIRAGE_GAME_PACKAGE:-com.loomgames.pixelflow}"
LOAD_LIMIT="${LOAD_LIMIT:-18}"
MIN_VALID="${MIN_VALID:-2}"
FOREIGN_MAX="${FOREIGN_MAX:-60}"
ROUND_RETRY_MAX="${ROUND_RETRY_MAX:-3}"
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-20}"
CONDITION_GAP="${CONDITION_GAP:-5}"
PREFLIGHT_SECONDS="${PREFLIGHT_SECONDS:-8}"
PREFLIGHT_GUEST_MIN="${PREFLIGHT_GUEST_MIN:-20}"

usage() {
    sed -n '2,6p' "${SCRIPT_PATH}"
}

while getopts "p:s:r:d:c:h" opt; do
    case "${opt}" in
        p) GRPC_PORT="${OPTARG}" ;;
        s) SERIAL="${OPTARG}" ;;
        r) ROUNDS="${OPTARG}" ;;
        d) DURATION="${OPTARG}" ;;
        c) CONDITION_SPEC="${OPTARG}" ;;
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

validate_nonnegative_int() {
    local label="$1" value="$2"
    case "${value}" in
        ''|*[!0-9]*)
            echo "❌ ${label} 必須是非負整數：${value}" >&2
            return 1
            ;;
    esac
    return 0
}

validate_number() {
    local label="$1" value="$2"
    if ! awk -v value="${value}" \
        'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/) }'; then
        echo "❌ ${label} 必須是非負數字：${value}" >&2
        return 1
    fi
    return 0
}

validate_positive_int "port" "${GRPC_PORT}" || exit 2
validate_positive_int "rounds" "${ROUNDS}" || exit 2
validate_positive_int "seconds" "${DURATION}" || exit 2
validate_positive_int "MIN_VALID" "${MIN_VALID}" || exit 2
validate_positive_int "ROUND_RETRY_MAX" "${ROUND_RETRY_MAX}" || exit 2
validate_nonnegative_int "COOLDOWN_SECONDS" "${COOLDOWN_SECONDS}" || exit 2
validate_nonnegative_int "CONDITION_GAP" "${CONDITION_GAP}" || exit 2
validate_number "LOAD_LIMIT" "${LOAD_LIMIT}" || exit 2
validate_number "FOREIGN_MAX" "${FOREIGN_MAX}" || exit 2
if [ "${GRPC_PORT}" -gt 65535 ]; then
    echo "❌ port 超出範圍：${GRPC_PORT}" >&2
    exit 2
fi

IFS=',' read -r -a CONDITIONS <<< "${CONDITION_SPEC}"
CONDITION_COUNT=${#CONDITIONS[@]}
if [ "${CONDITION_COUNT}" -eq 0 ] || [ -z "${CONDITIONS[0]}" ]; then
    echo "❌ 至少要指定一個條件：${CONDITION_SPEC}" >&2
    exit 2
fi
for ((condition_index = 0; condition_index < CONDITION_COUNT; condition_index++)); do
    condition="${CONDITIONS[condition_index]}"
    case "${condition}" in
        none|pull|app) ;;
        *)
            echo "❌ 不支援的條件：${condition}（可用 none、pull、app）" >&2
            exit 2
            ;;
    esac
    if [ "${condition_index}" -gt 0 ]; then
        previous_index=0
        while [ "${previous_index}" -lt "${condition_index}" ]; do
            if [ "${CONDITIONS[previous_index]}" = "${condition}" ]; then
                echo "❌ 條件不可重複：${condition}" >&2
                exit 2
            fi
            previous_index=$((previous_index + 1))
        done
    fi
done

echo "=== 前置：gRPC ==="
require_grpc "${GRPC_PORT}"
echo "=== 前置：裝置 ${SERIAL} ==="
require_device "${SERIAL}"

echo ""
echo "=== 前置：guest 出幀率（取樣 ${PREFLIGHT_SECONDS} 秒）==="
guest_window_start "${SERIAL}"
sleep "${PREFLIGHT_SECONDS}"
PREFLIGHT_RAW=$(guest_window_end "${SERIAL}" "${PACKAGE}") || PREFLIGHT_RAW=""
PREFLIGHT_FPS=$(printf '%s' "${PREFLIGHT_RAW}" | cut -d' ' -f1)
echo "   guest ${PREFLIGHT_FPS:-（找不到 layer）} fps"
if [ -z "${PREFLIGHT_FPS}" ] || ! awk -v g="${PREFLIGHT_FPS}" \
    -v t="${PREFLIGHT_GUEST_MIN}" 'BEGIN { exit !(g >= t) }'; then
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
assert_at_least "前置：guest 出幀率" "${PREFLIGHT_FPS%%.*}" "${PREFLIGHT_GUEST_MIN}"

echo ""
echo "=== 前置：release 建置快取 ==="
if ! build_warm release 3 "${PACKAGE_DIR}" "mirage-pull"; then
    exit 1
fi
if ! build_warm release 3 "${PACKAGE_DIR}" "MirageApp"; then
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
export MIRAGE_SKIP_BUILD=1

# 前置工作完成後先讓建置餘熱退掉，再確認主機負載已回到量測門檻內。
echo ""
echo "=== 前置：冷卻（${COOLDOWN_SECONDS} 秒）==="
sleep "${COOLDOWN_SECONDS}"
if ! load_gate "${LOAD_LIMIT}"; then
    echo "❌ 冷卻後 load_gate 未通過，中止量測。"
    exit 1
fi
echo "✅ 冷卻後 load_gate 通過"

NONE_GUEST_VALS=""
NONE_QEMU_VALS=""
NONE_CLIENT_VALS=""
NONE_FOREIGN_VALS=""
PULL_GUEST_VALS=""
PULL_QEMU_VALS=""
PULL_CLIENT_VALS=""
PULL_FOREIGN_VALS=""
APP_GUEST_VALS=""
APP_QEMU_VALS=""
APP_CLIENT_VALS=""
APP_FOREIGN_VALS=""

condition_values() {
    local condition="$1" metric="$2"
    case "${condition}:${metric}" in
        none:guest) printf '%s' "${NONE_GUEST_VALS}" ;;
        none:qemu) printf '%s' "${NONE_QEMU_VALS}" ;;
        none:client) printf '%s' "${NONE_CLIENT_VALS}" ;;
        none:foreign) printf '%s' "${NONE_FOREIGN_VALS}" ;;
        pull:guest) printf '%s' "${PULL_GUEST_VALS}" ;;
        pull:qemu) printf '%s' "${PULL_QEMU_VALS}" ;;
        pull:client) printf '%s' "${PULL_CLIENT_VALS}" ;;
        pull:foreign) printf '%s' "${PULL_FOREIGN_VALS}" ;;
        app:guest) printf '%s' "${APP_GUEST_VALS}" ;;
        app:qemu) printf '%s' "${APP_QEMU_VALS}" ;;
        app:client) printf '%s' "${APP_CLIENT_VALS}" ;;
        app:foreign) printf '%s' "${APP_FOREIGN_VALS}" ;;
    esac
}

append_condition_sample() {
    local condition="$1" guest="$2" qemu="$3" client="$4" foreign="$5"
    case "${condition}" in
        none)
            NONE_GUEST_VALS="${NONE_GUEST_VALS}${guest}\n"
            NONE_QEMU_VALS="${NONE_QEMU_VALS}${qemu}\n"
            NONE_CLIENT_VALS="${NONE_CLIENT_VALS}${client}\n"
            NONE_FOREIGN_VALS="${NONE_FOREIGN_VALS}${foreign}\n"
            ;;
        pull)
            PULL_GUEST_VALS="${PULL_GUEST_VALS}${guest}\n"
            PULL_QEMU_VALS="${PULL_QEMU_VALS}${qemu}\n"
            PULL_CLIENT_VALS="${PULL_CLIENT_VALS}${client}\n"
            PULL_FOREIGN_VALS="${PULL_FOREIGN_VALS}${foreign}\n"
            ;;
        app)
            APP_GUEST_VALS="${APP_GUEST_VALS}${guest}\n"
            APP_QEMU_VALS="${APP_QEMU_VALS}${qemu}\n"
            APP_CLIENT_VALS="${APP_CLIENT_VALS}${client}\n"
            APP_FOREIGN_VALS="${APP_FOREIGN_VALS}${foreign}\n"
            ;;
    esac
}

ACTIVE_CLIENT_PID=""
ACTIVE_CLIENT_LOG=""
ACTIVE_BUNDLE=""
ACTIVE_LOG=""

cleanup_active() {
    local client_pid="${ACTIVE_CLIENT_PID}"
    local client_log="${ACTIVE_CLIENT_LOG}"
    local bundle="${ACTIVE_BUNDLE}"
    local log="${ACTIVE_LOG}"
    ACTIVE_CLIENT_PID=""
    ACTIVE_CLIENT_LOG=""
    ACTIVE_BUNDLE=""
    ACTIVE_LOG=""
    if [ -n "${client_pid}" ]; then
        kill "${client_pid}" 2>/dev/null || true
        wait "${client_pid}" 2>/dev/null || true
    fi
    if [ -n "${bundle}" ]; then
        gui_session_cleanup "${bundle}"
    fi
    [ -n "${client_log}" ] && rm -f "${client_log}"
    [ -n "${log}" ] && rm -f "${log}"
}

trap 'cleanup_active; exit 130' INT TERM
trap cleanup_active EXIT

run_condition() {
    local round="$1" condition="$2"
    local guest_raw="" guest_fps="" frames="" guest_label="NA" frames_label="NA"
    local cpu_report foreign_report qemu_cpu client_cpu foreign_cpu
    local client_pattern measured_processes invalid_reason mirage_fps=""
    local client_seconds app_converged app_attempt client_alive=1

    cleanup_active
    guest_window_start "${SERIAL}"

    case "${condition}" in
        none)
            measured_processes="qemu-system|WindowServer"
            client_pattern=""
            client_cpu="0"
            ;;
        pull)
            measured_processes="qemu-system|mirage-pull|WindowServer"
            client_pattern="mirage-pull"
            client_seconds=$((DURATION + 30))
            ACTIVE_CLIENT_LOG="$(mktemp -t backpressure_pull)"
            "${SWIFT_BINARY}" --endpoint "localhost:${GRPC_PORT}" \
                --seconds "${client_seconds}" --width 898 --height 1996 \
                > "${ACTIVE_CLIENT_LOG}" 2>&1 &
            ACTIVE_CLIENT_PID=$!
            sleep 3
            if ! kill -0 "${ACTIVE_CLIENT_PID}" 2>/dev/null; then
                echo "❌ pull client 未能維持到 ready："
                sed 's/^/   /' "${ACTIVE_CLIENT_LOG}"
                cleanup_active
                return 1
            fi
            ;;
        app)
            measured_processes="qemu-system|MirageApp|WindowServer"
            client_pattern="MirageApp"
            app_converged=0
            for ((app_attempt = 1; app_attempt <= ROUND_RETRY_MAX; app_attempt++)); do
                ACTIVE_LOG="$(mktemp -t backpressure_mirage)"
                ACTIVE_BUNDLE="$(mktemp -d -t backpressure_bundle)"
                if ! gui_session_start "${ACTIVE_LOG}" "${ACTIVE_BUNDLE}" "" \
                        "MIRAGE_PORT=${GRPC_PORT}" "MIRAGE_FPS_LOG=1" "MIRAGE_CONN_LOG=1"; then
                    echo "   本輪第 ${app_attempt}/${ROUND_RETRY_MAX} 次啟動未收斂，關掉重開"
                    cleanup_active
                    continue
                fi
                if gui_session_fullscreen "${ACTIVE_LOG}" "${ACTIVE_BUNDLE}" \
                        "${FULLSCREEN_MIN_WIDTH:-896}"; then
                    app_converged=1
                    break
                fi
                echo "   本輪第 ${app_attempt}/${ROUND_RETRY_MAX} 次啟動未收斂，關掉重開"
                cleanup_active
            done
            if [ "${app_converged}" -eq 0 ]; then
                echo "[round ${round} cond=${condition}] guest=NA frames=NA host_cpu_qemu=NA host_cpu_client=NA host_cpu_foreign=NA mirage_fps=0"
                echo "   ❌ 樣本無效：app 重試 ${ROUND_RETRY_MAX} 次仍未收斂，不計入中位數。"
                return 0
            fi
            ;;
    esac

    # client ready 後重新清零，窗口不包含啟動與收斂期。
    guest_window_start "${SERIAL}"
    SNAP_A=$(cpu_snapshot)
    sleep "${DURATION}"
    SNAP_B=$(cpu_snapshot)
    case "${condition}" in
        pull)
            if ! kill -0 "${ACTIVE_CLIENT_PID}" 2>/dev/null; then
                client_alive=0
            fi
            ;;
        app)
            if ! pgrep -x "MirageApp" > /dev/null 2>&1; then
                client_alive=0
            fi
            ;;
    esac
    guest_raw=$(guest_window_end "${SERIAL}" "${PACKAGE}") || guest_raw=""

    cpu_report=$(cpu_delta_report "${SNAP_A}" "${SNAP_B}" "${DURATION}" "")
    qemu_cpu=$(backpressure_cpu_total "${cpu_report}" 'qemu-system')
    if [ "${condition}" != "none" ]; then
        if [ "${client_alive}" -eq 1 ]; then
            client_cpu=$(backpressure_cpu_total "${cpu_report}" "${client_pattern}")
        else
            client_cpu="NA"
        fi
    fi
    foreign_report=$(cpu_delta_report "${SNAP_A}" "${SNAP_B}" "${DURATION}" \
        "${measured_processes}")
    foreign_cpu=$(backpressure_cpu_total "${foreign_report}" '.*')

    if [ -n "${guest_raw}" ]; then
        guest_fps=$(printf '%s' "${guest_raw}" | cut -d' ' -f1)
        frames=$(printf '%s' "${guest_raw}" | cut -d' ' -f2)
        guest_label="${guest_fps}"
        frames_label="${frames}"
    fi
    if [ "${condition}" = "app" ]; then
        mirage_fps=$(fps_median "${ACTIVE_LOG}")
    fi
    cleanup_active

    if [ "${client_alive}" -eq 0 ]; then
        invalid_reason="client"
    else
        invalid_reason=$(backpressure_invalid_reason "${guest_fps}" "${foreign_cpu}" \
            "${FOREIGN_MAX}")
    fi
    if [ "${condition}" = "app" ]; then
        echo "[round ${round} cond=${condition}] guest=${guest_label} frames=${frames_label} host_cpu_qemu=${qemu_cpu} host_cpu_client=${client_cpu} host_cpu_foreign=${foreign_cpu} mirage_fps=${mirage_fps}"
    else
        echo "[round ${round} cond=${condition}] guest=${guest_label} frames=${frames_label} host_cpu_qemu=${qemu_cpu} host_cpu_client=${client_cpu} host_cpu_foreign=${foreign_cpu}"
    fi

    case "${invalid_reason}" in
        guest)
            echo "   ❌ 樣本無效：guest 量不到（找不到 ${PACKAGE} 的 layer），不計入中位數。"
            ;;
        foreign)
            echo "   ❌ 樣本無效：foreign=${foreign_cpu}% 超過 FOREIGN_MAX=${FOREIGN_MAX}%，不計入中位數。"
            ;;
        client)
            if [ "${condition}" = "pull" ]; then
                echo "   ❌ 樣本無效：pull client 在量測窗口內提前結束，不計入中位數。"
            else
                echo "   ❌ 樣本無效：MirageApp 在量測窗口內提前結束，不計入中位數。"
            fi
            ;;
        *)
            append_condition_sample "${condition}" "${guest_fps}" "${qemu_cpu}" \
                "${client_cpu}" "${foreign_cpu}"
            ;;
    esac
}

for ((round = 1; round <= ROUNDS; round++)); do
    if ! load_gate "${LOAD_LIMIT}"; then
        echo "   第 ${round}/${ROUNDS} 輪先被 load_gate 擋下，跳過本輪。"
        continue
    fi

    ROUND_ORDER="$(rotate_conditions "${round}" "${CONDITION_SPEC}")"
    echo ""
    echo "=== 第 ${round}/${ROUNDS} 輪（順序：${ROUND_ORDER}）==="
    IFS=',' read -r -a ROUND_CONDITIONS <<< "${ROUND_ORDER}"
    ROUND_COUNT=${#ROUND_CONDITIONS[@]}
    if [ "${ROUND_COUNT}" -gt 0 ]; then
        for ((condition_index = 0; condition_index < ROUND_COUNT; condition_index++)); do
            run_condition "${round}" "${ROUND_CONDITIONS[condition_index]}" || exit 1
            if [ "${condition_index}" -lt "$((ROUND_COUNT - 1))" ] || \
                    [ "${round}" -lt "${ROUNDS}" ]; then
                echo "   條件間隔 ${CONDITION_GAP} 秒，等待上一個 client 拆除完成"
                sleep "${CONDITION_GAP}"
            fi
        done
    fi
done

echo ""
echo "===== 回壓摘要 ====="
for ((condition_index = 0; condition_index < CONDITION_COUNT; condition_index++)); do
    condition="${CONDITIONS[condition_index]}"
    guest_values="$(condition_values "${condition}" guest)"
    qemu_values="$(condition_values "${condition}" qemu)"
    valid_rounds=$(backpressure_count "${guest_values}")
    guest_median=$(backpressure_median "${guest_values}")
    qemu_median=$(backpressure_median "${qemu_values}")
    echo "${condition}: guest_median=${guest_median:-無資料} valid_rounds=${valid_rounds} host_cpu_qemu_median=${qemu_median:-無資料}"
done

NONE_VALUES="$(condition_values none guest)"
PULL_VALUES="$(condition_values pull guest)"
APP_VALUES="$(condition_values app guest)"
echo "DELTA_NONE_PULL=$(median_delta "${NONE_VALUES}" "${PULL_VALUES}")"
echo "DELTA_PULL_APP=$(median_delta "${PULL_VALUES}" "${APP_VALUES}")"
echo "DELTA_NONE_APP=$(median_delta "${NONE_VALUES}" "${APP_VALUES}")"

VALIDATION_FAILURES=0
for ((condition_index = 0; condition_index < CONDITION_COUNT; condition_index++)); do
    condition="${CONDITIONS[condition_index]}"
    valid_rounds=$(backpressure_count "$(condition_values "${condition}" guest)")
    if [ "${valid_rounds}" -lt "${MIN_VALID}" ]; then
        echo "❌ ${condition} 有效樣本不足：${valid_rounds}，門檻 ${MIN_VALID}。"
        VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
    else
        echo "✅ ${condition} 有效樣本：${valid_rounds}（門檻 ${MIN_VALID}）"
    fi
done

if [ "${VALIDATION_FAILURES}" -ne 0 ]; then
    exit 1
fi
exit 0
