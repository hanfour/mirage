"""lib.launch.poll_until_foreground 的輪詢／逾時／前綴比對邏輯——用假時鐘測，
全程不碰真裝置，「30 秒沒等到前景」這種案例瞬間跑完。

這條路徑是 launch 指令存在的核心價值：逾時訊息要印出「目前前景是什麼」，那是
判斷問題所在的線索（task-4 brief）。2026-07-28 的活體驗證從沒真正命中過這條
分支——連 `com.nonexistent.app` 那個案例都是被 adb.run() 提早拋出的 AdbError
矇混過去，逾時分支本身完全零覆蓋。這裡把它釘住。
"""
import pytest

from lib.launch import poll_until_foreground


class _FakeClock:
    """假時鐘：sleep() 直接推進內部計時，不真的等待。"""

    def __init__(self, start: float = 0.0):
        self._now = start

    def now(self) -> float:
        return self._now

    def sleep(self, seconds: float) -> None:
        self._now += seconds


class _ScriptedCheck:
    """依序回傳預先寫好的前景字串；序列用完後重複回傳最後一個值。"""

    def __init__(self, values: list[str | None]):
        self._values = list(values)
        self._i = 0

    def __call__(self) -> str | None:
        v = self._values[min(self._i, len(self._values) - 1)]
        self._i += 1
        return v


class _RecordingMismatch:
    """每次回傳不同、但都不符合比對前綴的前景字串，並記下呼叫次數。
    用來確認逾時分支回傳的是「最後一次看到的值」，而不是寫死的初始值。"""

    def __init__(self):
        self.calls = 0

    def __call__(self) -> str:
        self.calls += 1
        return f"com.other.app{self.calls}/MainActivity"


def test_matches_on_first_check():
    """第一次就命中：ok=True，elapsed 是 0（時鐘還沒被推進過）。"""
    clock = _FakeClock()
    ok, fg, elapsed = poll_until_foreground(
        lambda: "com.target/MainActivity", "com.target",
        clock_fn=clock.now, sleep_fn=clock.sleep)
    assert (ok, fg, elapsed) == (True, "com.target/MainActivity", 0.0)


def test_matches_after_several_misses():
    """前幾次不匹配、之後命中：ok=True，elapsed 反映實際等待的輪詢次數
    （兩次不匹配各 sleep 1 秒後，第三次才命中 → elapsed == 2.0）。"""
    check = _ScriptedCheck(["com.other/Activity", "com.other/Activity",
                             "com.target/MainActivity"])
    clock = _FakeClock()
    ok, fg, elapsed = poll_until_foreground(
        check, "com.target", clock_fn=clock.now, sleep_fn=clock.sleep)
    assert (ok, fg) == (True, "com.target/MainActivity")
    assert elapsed == pytest.approx(2.0)


def test_timeout_returns_last_seen_foreground():
    """一路都不匹配直到逾時：ok=False，且回傳的 fg 是最後一次看到的值——
    不是某個寫死的預設，也不是第一次看到的值。這正是 brief 要求的「目前前景
    是什麼」那條線索，逾時訊息全靠這個回傳值。"""
    check = _RecordingMismatch()
    clock = _FakeClock()
    ok, fg, elapsed = poll_until_foreground(
        check, "com.target", clock_fn=clock.now, sleep_fn=clock.sleep)
    assert ok is False
    assert fg == f"com.other.app{check.calls}/MainActivity"
    assert elapsed == pytest.approx(30.0)


def test_timeout_with_no_foreground_ever_does_not_crash():
    """check_fn 全程回傳 None（adb 查不到前景時的真實回傳值）直到逾時：
    ok=False、fg=None，且不能因為對 None 呼叫 .startswith() 之類的方法而炸掉。
    `fg and fg.startswith(...)` 的短路是擋住這個的關鍵，這裡把它釘住。"""
    clock = _FakeClock()
    ok, fg, elapsed = poll_until_foreground(
        lambda: None, "com.target", clock_fn=clock.now, sleep_fn=clock.sleep)
    assert (ok, fg) == (False, None)
    assert elapsed == pytest.approx(30.0)


def test_prefix_match_requires_slash_boundary():
    """`com.foo` 不該被 `com.foobar/Activity` 誤判命中——沒有 "/" 邊界的話，
    單純 str.startswith(match_prefix) 會抓到套件名前綴相同的不相干鄰居套件。
    這裡用一個永遠只回傳「前綴相同但沒有 / 邊界」字串的 check_fn，確認它
    始終落在逾時分支，而不是被誤判命中。"""
    clock = _FakeClock()
    ok, fg, elapsed = poll_until_foreground(
        lambda: "com.foobar/Activity", "com.foo",
        clock_fn=clock.now, sleep_fn=clock.sleep)
    assert ok is False
    assert fg == "com.foobar/Activity"
    assert elapsed == pytest.approx(30.0)
