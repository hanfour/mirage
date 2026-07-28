"""讓 lib/ 與 phase0/harness/gen/ 可以被 import。

⚠️ 刻意接受的暫時耦合：phase0/harness 實質上已經是本專案的 gRPC 工具箱，
`phase0` 只是歷史名稱。它哪天搬家，這個檔案要跟著改。
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_HARNESS = os.path.abspath(os.path.join(_HERE, "..", "..", "phase0", "harness"))

# ⚠️ 踩坑記錄（活體驗證時發現）：phase0/harness 底下也有一個 `lib` package
# （空的 __init__.py，見 phase0/harness/lib/__init__.py）。直接跑
# `python probe.py` 時，Python 會把腳本所在目錄（_HERE）自動放進
# sys.path[0]，導致下面迴圈裡「if path not in sys.path 才 insert」這條
# 判斷式把 _HERE 跳過、只把 gen/ 和 _HARNESS insert(0, ...) 到它前面，
# 最終順序變成 [_HARNESS, gen, _HERE, ...] —— `from lib import adb` 因此
# 解析到 phase0/harness/lib（沒有 adb.py）而不是 tools/probe/lib，整支
# CLI 直接掛掉。pytest 測不出這個問題，因為測試檔案直接 import lib.targets，
# 從不經過這支 _bootstrap.py。
# 修法：不管 _HERE 是否已經在 sys.path 裡，一律先移除再塞回最前面，確保
# tools/probe/lib 的優先權高於 phase0/harness/lib。
for path in (_HARNESS, os.path.join(_HARNESS, "gen"), _HERE):
    if path in sys.path:
        sys.path.remove(path)
    sys.path.insert(0, path)
