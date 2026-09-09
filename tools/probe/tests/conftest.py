"""讓 `tools/probe/tests/` 能被 pytest 收集。

這些測試 import `lib.*` 與 `_bootstrap`，兩者都在 `tools/probe/` 底下，
而 pytest 不會自動把它放進 `sys.path`，於是 11 個測試檔全部在收集階段就 ImportError。

D37 原本記載的阻礙是「本機沒裝 pytest」，那一條已經失效：閘門 8 用的
`phase0/harness/.venv-d45` 裡就有 pytest。剩下的只有這個路徑問題。
作法比照 `phase0/harness/tests/conftest.py`。
"""
import sys
from pathlib import Path

PROBE_DIR = str(Path(__file__).resolve().parents[1])
if PROBE_DIR not in sys.path:
    sys.path.insert(0, PROBE_DIR)
