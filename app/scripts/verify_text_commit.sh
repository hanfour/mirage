#!/usr/bin/env bash
# 真 Swift InputQueue/executor 的文字驗收；adb 只作 setup/位置/欄位觀察。
# 用法：bash app/scripts/verify_text_commit.sh <serial> <grpc-port> <package> <field-id> <output-dir> [empty-hint]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
export MIRAGE_TEXT_SERIAL="${1:?serial}"
export MIRAGE_PORT="${2:?grpc port}"
export MIRAGE_TEXT_TARGET_PACKAGE="${3:?package}"
export MIRAGE_TEXT_TARGET_FIELD="${4:?field id}"
export MIRAGE_TEXT_EVIDENCE_DIR="${5:?output dir}"
export MIRAGE_TEXT_EMPTY_HINT="${6:-}"
export MIRAGE_LIVE=1 MIRAGE_LIVE_TEXT=1
export MIRAGE_TEXT_POLICIES="${MIRAGE_TEXT_POLICIES:-100,250}"
export MIRAGE_TEXT_ROUNDS="${MIRAGE_TEXT_ROUNDS:-3}"
if [ -d "$MIRAGE_TEXT_EVIDENCE_DIR" ] && [ -n "$(ls -A "$MIRAGE_TEXT_EVIDENCE_DIR")" ]; then
    echo "拒絕覆寫既有驗收目錄：${MIRAGE_TEXT_EVIDENCE_DIR}；請使用新的 run 目錄。" >&2
    exit 2
fi
mkdir -p "$MIRAGE_TEXT_EVIDENCE_DIR"
cd "$REPO_ROOT/app"
swift test --skip-build --filter TextCommitLiveTests 2>&1 | tee "$MIRAGE_TEXT_EVIDENCE_DIR/swift-live.log"
