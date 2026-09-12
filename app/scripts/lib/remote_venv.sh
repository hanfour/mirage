#!/usr/bin/env bash
# 手機遙控活體腳本的 Python venv：只裝 websockets。
#
# **一律用 Apple 簽署的 /usr/bin/python3 建**，不使用 pyenv 建 venv。
# 活體腳本固定走 127.0.0.1，不受 App 傳入 LAN 連線的防火牆對話框影響。
# 目錄 app/scripts/.venv-remote 已被根目錄 .gitignore:6 的 `.venv*/` 涵蓋。
# 用法：PY=$(bash lib/remote_venv.sh) || exit 1
set -uo pipefail
REMOTE_VENV="${REMOTE_VENV:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.venv-remote}"
SYSTEM_PYTHON=/usr/bin/python3
WEBSOCKETS_SPEC="${WEBSOCKETS_SPEC:-websockets>=15,<16}"

remote_venv_python() {
    local py="${REMOTE_VENV}/bin/python"
    if [ ! -x "$py" ]; then
        [ -x "$SYSTEM_PYTHON" ] || { echo "❌ 找不到系統 python3：${SYSTEM_PYTHON}" >&2; return 1; }
        "$SYSTEM_PYTHON" -m venv "$REMOTE_VENV" >&2 || { echo "❌ 建 venv 失敗：${REMOTE_VENV}" >&2; return 1; }
    fi
    if ! "$py" -c "from websockets.asyncio.client import connect; import websockets; assert 15 <= int(websockets.__version__.split('.')[0]) < 16" > /dev/null 2>&1; then
        "$py" -m pip install --quiet "$WEBSOCKETS_SPEC" >&2 || { echo "❌ pip install websockets 失敗" >&2; return 1; }
    fi
    # 版本要印出來：websockets 13 才有 websockets.asyncio.client，舊版會在連線時才炸。
    "$py" -c "from websockets.asyncio.client import connect; import websockets, sys; assert 15 <= int(websockets.__version__.split('.')[0]) < 16; print('websockets', websockets.__version__, file=sys.stderr)" || return 1
    echo "$py"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    remote_venv_python
fi
