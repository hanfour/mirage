#!/usr/bin/env bash
# gui_session_quit_gracefully 的參數與 PID 自我測試，不啟動 GUI app。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/gui_session.sh"
FAILURES=0

check_failure() {
    local description="$1"
    shift
    if "$@"; then
        echo "❌ ${description}：預期失敗，實際成功"
        FAILURES=$((FAILURES + 1))
    else
        echo "✅ ${description}"
    fi
}

sleep 30 &
SLEEP_PID=$!
kill "${SLEEP_PID}" 2>/dev/null || true
wait "${SLEEP_PID}" 2>/dev/null || true

check_failure "不存在的 PID 回非零" gui_session_quit_gracefully "${SLEEP_PID}"
check_failure "非數字 PID 回非零" gui_session_quit_gracefully not-a-pid

# CI 沒有可安全結束的測試 GUI app；NSRunningApplication 的實際結束流程留給實機驗證。
if [ "${FAILURES}" -eq 0 ]; then
    echo "GUI app 正常結束流程略過，需由實機驗證"
    exit 0
fi
echo "${FAILURES} 項失敗"
exit 1
