#!/bin/bash
cd "$(dirname "$0")/.." || exit 1
./emu.sh stop
echo ""
echo "完成後可以關閉這個視窗。"
