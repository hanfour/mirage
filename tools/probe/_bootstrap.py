"""讓 lib/ 與 phase0/harness/gen/ 可以被 import。

⚠️ 刻意接受的暫時耦合：phase0/harness/gen 實質上已經是本專案的 gRPC pb2
生成碼所在地，`phase0` 只是歷史名稱。它哪天搬家，這個檔案要跟著改。
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_HARNESS = os.path.abspath(os.path.join(_HERE, "..", "..", "phase0", "harness"))
_GEN = os.path.join(_HARNESS, "gen")

# ⚠️ 踩坑記錄（活體驗證時發現，2026-07-28 review 又發現第一版修法治標未治
# 本）：只需要 `_GEN`（pb2 生成碼所在地），絕對不要把 `_HARNESS` 本身塞進
# sys.path。
#
# 原因一（bug 的直接成因）：phase0/harness 底下也有一個 `lib` package
# （空的 __init__.py，見 phase0/harness/lib/__init__.py），跟 tools/probe
# 底下的 `lib` package 同名。只要 `_HARNESS` 出現在 sys.path 上，
# `from lib import adb` 就有可能解析到 phase0/harness/lib（沒有 adb.py）
# 而不是 tools/probe/lib，整支 CLI 直接掛掉——而且 pytest 測不出來，因為
# 測試檔案直接 `from lib.targets import ...`，從不經過這支 _bootstrap.py，
# 只有真的執行 `python probe.py` 才會炸。第一版修法只是「反轉優先權」讓
# tools/probe 贏，兩個同名 package 仍然疊在 sys.path 上；日後任何人只要
# 沿用同一種寫法重用 harness 的其他模組，這顆雷會用一模一樣的方式再炸一次。
#
# 原因二（確認過 _HARNESS 本來就不需要）：gen/ 底下的 pb2 模組彼此用同層
# import（`emulator_controller_pb2_grpc.py` 內部是
# `import emulator_controller_pb2`，找的是 gen/ 目錄本身，不是
# phase0/harness），沒有任何一處 import 會爬到 phase0/harness 這一層；
# 設計文件 §7 也只提到需要 `phase0/harness/gen/`。實測過：sys.path 只放
# `_GEN`（不放 `_HARNESS`），`import emulator_controller_pb2` 與
# `import emulator_controller_pb2_grpc` 都正常。
#
# 所以正確修法不是「反轉優先權」，是「消除碰撞」：根本不把 _HARNESS 放進
# sys.path，只放 _GEN。之後若真的要 import phase0/harness 底下 gen/ 以外
# 的東西（例如 lib/stats.py），請用完整模組路徑或另外處理命名衝突，不要
# 再把整個 _HARNESS 目錄塞進 sys.path。
for path in (_GEN, _HERE):
    if path in sys.path:
        sys.path.remove(path)
    sys.path.insert(0, path)
