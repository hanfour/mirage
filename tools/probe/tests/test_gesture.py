"""lib.gesture.swipe_plan：swipe 時長 → 觸點數／每點間隔。

**為什麼這條重要**：這兩行公式原本直接寫在 `cmd_swipe` 裡，單元測試碰不到，
而負的 `--ms` 正好從這裡穿過去：

    ms=-300 → steps=max(2, -15)=2 → step_ms=-150 → time.sleep(-0.15) → ValueError

使用者拿到的是 `error: sleep length must be non-negative`——一句跟模擬器、跟
swipe 都無關的訊息，零線索；而且那時 down 已經送出去、up 永遠不會送。
觸點殘留由 `Emulator._stroke` 的不變式擋（見 tests/test_emulator.py），
**輸入合法性由這裡擋**，兩層各司其職。
"""
import pytest

from lib.gesture import MIN_STEPS, swipe_plan


def test_default_300ms_matches_the_documented_behaviour():
    """設計文件 §3 的預設值是 300ms；20ms 一點 → 15 點。這個數字同時決定了
    lerp_path 的 steps，改動它會連帶改變座標內插，所以釘住。"""
    assert swipe_plan(300) == (15, 20)


def test_short_swipes_still_get_at_least_two_points():
    """只送起點與終點以下的點數，guest 會當成瞬移，多數遊戲的拖曳手勢不會被
    辨識——而且 lerp_path 對 steps<2 會直接 raise。"""
    steps, step_ms = swipe_plan(10)
    assert steps == MIN_STEPS
    assert step_ms == 5


@pytest.mark.parametrize("bad_ms", [0, -1, -300])
def test_rejects_non_positive_duration_with_a_message_about_swipe(bad_ms):
    """錯誤訊息必須指向使用者實際打的東西（swipe 的時長），而不是
    `sleep length must be non-negative`。"""
    with pytest.raises(ValueError, match="swipe 時長"):
        swipe_plan(bad_ms)


def test_rejects_non_positive_step_interval():
    """ms_per_step 是可調參數，0 會讓 max(MIN_STEPS, ms // 0) 直接 ZeroDivisionError
    ——那同樣是會穿過 main() 變成 traceback 的例外。"""
    with pytest.raises(ValueError, match="每點間隔"):
        swipe_plan(300, ms_per_step=0)


@pytest.mark.parametrize("duration", [1, 19, 20, 21, 300, 1000, 5000])
def test_step_ms_is_never_negative(duration):
    """釘住這條性質本身：任何合法時長算出來的 step_ms 都不能是負的，
    因為它會直接餵進 time.sleep()。"""
    steps, step_ms = swipe_plan(duration)
    assert steps >= MIN_STEPS
    assert step_ms >= 0


@pytest.mark.parametrize("duration", [40, 100, 300, 1000])
def test_total_sleep_stays_within_the_requested_duration(duration):
    """(steps-1) 段間隔加起來不該超過使用者要求的時長——超過的話 swipe 會比
    指定的慢，量 fps 或做手勢時序時會得到偏掉的結論。"""
    steps, step_ms = swipe_plan(duration)
    assert (steps - 1) * step_ms <= duration
