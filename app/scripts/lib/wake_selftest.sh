#!/bin/bash
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 "$HERE/wake_selftest.py" || exit 1
source "$HERE/input_latency.sh"
input_latency_cpu_gate 49 || exit 1
if input_latency_cpu_gate 50; then
    echo 'FAIL: shell CPU gate accepted 50%'; exit 1
fi
echo 'PASS: shell CPU gate rejects 50%'
