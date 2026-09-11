#!/usr/bin/env bash
# Observation/comparison only. All IME input must come from the human keyboard.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "${SCRIPT_DIR}/lib/host_ime_acceptance.py" "$@"
