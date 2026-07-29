#!/usr/bin/env bash
# 安裝 git hooks。每個 clone 跑一次。
#
# 用 `core.hooksPath` 指向版本控制中的目錄，而不是把檔案複製到 .git/hooks/：
# 複製法會產生兩份、之後永遠不知道哪份是新的——這個 repo 已經因為「同一件事有兩份
# 各自演化的複本」吃過虧（EmulatorEndpoint 的解析先前在 AppModel 與 EmulatorClient
# 各有一份，見 2026-07-29-project-review.md §7）。指過去就只有一份。
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "不在 git repo 裡。"; exit 1
}
HOOKS_DIR="app/scripts/hooks"

if [ ! -d "$REPO_ROOT/$HOOKS_DIR" ]; then
    echo "找不到 $HOOKS_DIR"; exit 1
fi

chmod +x "$REPO_ROOT/$HOOKS_DIR"/* 2>/dev/null
git -C "$REPO_ROOT" config core.hooksPath "$HOOKS_DIR"

echo "已設定 core.hooksPath = $HOOKS_DIR"
echo "已安裝的 hook："
ls -1 "$REPO_ROOT/$HOOKS_DIR"
echo ""
echo "解除：git config --unset core.hooksPath"
