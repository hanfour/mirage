"""launch 的輪詢／逾時／前綴比對邏輯，與 cmd_launch 的 I/O 接線分離。

這條路徑（尤其是逾時分支）是 `launch` 指令存在的核心價值：task-4 brief 明白
要求逾時訊息要印出「目前前景是什麼」，那是判斷問題所在的線索。但這段邏輯原本
整段寫死在 cmd_launch 裡，靠真裝置跑 30 秒才會走到逾時分支——2026-07-28 那輪
的活體驗證案例（`com.nonexistent.app`）甚至沒能命中它，是 `adb.run()` 提早
丟出 AdbError 才「僥倖」用非零退出碼矇混過去的，逾時分支本身完全零覆蓋。

把控制流（何時呼叫 check_fn、比對前綴、判斷逾時、算 elapsed）抽成不碰真裝置
的純函式，讓假時鐘可以瞬間跑完「30 秒沒等到前景」這種案例，而不必真的等 30 秒
或養一個永遠啟動不了 activity 的情境。`check_fn`／`clock_fn`／`sleep_fn` 都是
注入點，做法比照 `lib/emulator.py` 的 `Emulator(stub, port)` 建構子注入。
"""
import time
from typing import Callable


def poll_until_foreground(
    check_fn: Callable[[], str | None],
    match_prefix: str,
    timeout_s: float = 30.0,
    clock_fn: Callable[[], float] = time.monotonic,
    sleep_fn: Callable[[float], None] = time.sleep,
) -> tuple[bool, str | None, float]:
    """輪詢 check_fn() 直到回傳值以 ``match_prefix + "/"`` 開頭，或逾時。

    回傳 (ok, fg, elapsed)：

    - 命中時 ok=True，fg 是命中的前景字串，elapsed 是輪詢花費的秒數。
    - 逾時時 ok=False，fg 是逾時當下再查一次 check_fn() 的結果——可能是
      None（查不到前景），呼叫端要能分辨「查到但不對」與「查不到」印出不同
      訊息，不能對 None 呼叫 .startswith() 之類的方法炸掉。

    比對必須帶 ``"/"`` 邊界：``match_prefix="com.foo"`` 不能被
    ``"com.foobar/Activity"`` 誤判命中——這是套件名前綴比對的老問題，只用
    startswith(match_prefix) 會抓到不相干的鄰居套件。
    """
    start = clock_fn()
    deadline = start + timeout_s
    prefix = match_prefix + "/"
    while clock_fn() < deadline:
        fg = check_fn()
        if fg and fg.startswith(prefix):
            return True, fg, clock_fn() - start
        sleep_fn(1.0)
    return False, check_fn(), clock_fn() - start
