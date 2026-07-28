"""swipe 的「時長 → 觸點數／每點間隔」換算。純邏輯、無 I/O。

原本這兩行公式直接寫在 `cmd_swipe` 裡，單元測試碰不到——而負的 `--ms` 正好
從這裡穿過去：`ms=-300 → steps=2 → step_ms=-150 → time.sleep(-0.15)` 丟出
`ValueError: sleep length must be non-negative`。使用者拿到的是一句跟模擬器、
跟 swipe 都無關的訊息，零線索；而且那時 down 已經送出去了。

觸點殘留由 `Emulator._stroke` 的不變式擋（一旦送出 down 就一定送出 up），
**輸入合法性由這裡擋**——兩層各司其職：這裡讓錯誤訊息說人話，那裡確保就算
有人繞過這裡，裝置也不會留著一根按下去的手指。
"""

MIN_STEPS = 2
DEFAULT_MS_PER_STEP = 20


def swipe_plan(duration_ms: int, ms_per_step: int = DEFAULT_MS_PER_STEP) -> tuple[int, int]:
    """回傳 (steps, step_ms)：整段 swipe 要送幾個觸點、每兩點之間睡多久。

    至少 `MIN_STEPS` 個點——只送起點與終點，guest 會當成瞬移，多數遊戲的拖曳
    手勢不會被辨識（見 `coords.lerp_path`）。
    """
    if duration_ms <= 0:
        raise ValueError(f"swipe 時長須為正的毫秒數，實得 {duration_ms}")
    if ms_per_step <= 0:
        raise ValueError(f"每點間隔須為正的毫秒數，實得 {ms_per_step}")
    steps = max(MIN_STEPS, duration_ms // ms_per_step)
    return steps, duration_ms // steps
