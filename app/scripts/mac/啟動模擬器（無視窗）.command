#!/bin/bash
# Finder 點兩下即可執行。會開一個 Terminal 視窗顯示進度，開完可以直接關掉。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
./emu.sh -H start
echo ""
echo "完成後可以關閉這個視窗。"
