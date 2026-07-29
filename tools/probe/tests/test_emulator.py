"""lib.emulator 的解析與錯誤包裝邏輯——用假 stub 測，全程不開 socket。

`Emulator.__init__(self, stub, port)` 的 stub 是建構子注入的，這代表
display_size()/screenshot()/send_touch() 可以完全脫離 grpc.insecure_channel()
來測。這點很重要：這個專案有一筆已知的架構債——讓測試建立真 gRPC channel 會
讓測試套件機率性卡死（實測基準：四次跑有兩次卡住）。那筆債只由 connect() 裡
的 grpc.insecure_channel() 觸發，Emulator 這個類別本身完全乾淨，所以這裡刻意
不測 connect()，留給活體驗證。

display_size() 的錯誤處理特別值得測：hw.lcd.* 缺欄位、值不是數字、值 <= 0——
這些錯了會**靜默給出錯誤結論**，不是明顯地壞掉。這個專案才剛因為同類問題
（觸控座標乘錯尺寸）浪費整整一輪，這裡不能再犯。
"""
import grpc
import pytest

import _bootstrap  # noqa: F401  設定 sys.path 讓 emulator_controller_pb2 可 import

import emulator_controller_pb2 as pb
from lib.emulator import Emulator, EmulatorError


class _FakeCode:
    """模擬 grpc.StatusCode：emulator.py 只用得到 .name。"""

    def __init__(self, name: str):
        self.name = name


class _FakeRpcError(grpc.RpcError):
    """emulator.py 用 `except grpc.RpcError as e: ... e.code().name` 接錯誤，
    假錯誤必須是 grpc.RpcError 的子類別、且滿足 .code().name 才騙得過那段
    except 子句與後續組訊息的邏輯。"""

    def __init__(self, code_name: str = "UNAVAILABLE"):
        super().__init__(code_name)
        self._code_name = code_name

    def code(self):
        return _FakeCode(self._code_name)


def _status(entries: dict[str, str]) -> pb.EmulatorStatus:
    """建構真實的 EmulatorStatus protobuf 訊息（不是手寫假物件），
    形狀跟 emulator 實際回傳的一致，比自造 dict-like 物件更貼近真實。"""
    entry_list = pb.EntryList(entry=[pb.Entry(key=k, value=v) for k, v in entries.items()])
    return pb.EmulatorStatus(hardwareConfig=entry_list)


class _FakeStub:
    """只實作 Emulator 會呼叫到的三個 RPC 方法：getStatus/getScreenshot/sendTouch。"""

    def __init__(self, status=None, status_error=None,
                 screenshot=None, screenshot_error=None,
                 touch_error=None):
        self._status = status
        self._status_error = status_error
        self._screenshot = screenshot
        self._screenshot_error = screenshot_error
        self._touch_error = touch_error
        self.touch_calls = []

    def getStatus(self, empty, timeout=None):
        if self._status_error:
            raise self._status_error
        return self._status

    def getScreenshot(self, fmt, timeout=None):
        if self._screenshot_error:
            raise self._screenshot_error
        return self._screenshot

    def sendTouch(self, event, timeout=None):
        if self._touch_error:
            raise self._touch_error
        self.touch_calls.append(event)


def test_display_size_reads_hw_lcd_dimensions():
    stub = _FakeStub(status=_status({"hw.lcd.width": "1080", "hw.lcd.height": "2400"}))
    emu = Emulator(stub, port=8556)
    assert emu.display_size() == (1080, 2400)


def test_display_size_raises_on_missing_field():
    """缺欄位若不擋下來，後面的 int() 會直接炸沒對應到真因的 KeyError。"""
    stub = _FakeStub(status=_status({"hw.lcd.width": "1080"}))  # 缺 height
    emu = Emulator(stub, port=8556)
    with pytest.raises(EmulatorError, match="hw.lcd"):
        emu.display_size()


def test_display_size_raises_on_non_numeric_value():
    stub = _FakeStub(status=_status({"hw.lcd.width": "abc", "hw.lcd.height": "2400"}))
    emu = Emulator(stub, port=8556)
    with pytest.raises(EmulatorError, match="hw.lcd"):
        emu.display_size()


def test_display_size_raises_on_non_positive_value():
    """觸控座標乘錯尺寸的坑，起點常是「有值但不合理」的資料，不是完全缺欄位
    ——兩種都要擋，只查 KeyError 不夠。"""
    stub = _FakeStub(status=_status({"hw.lcd.width": "0", "hw.lcd.height": "2400"}))
    emu = Emulator(stub, port=8556)
    with pytest.raises(EmulatorError, match="不合理"):
        emu.display_size()


def test_display_size_wraps_rpc_error():
    stub = _FakeStub(status_error=_FakeRpcError("UNAVAILABLE"))
    emu = Emulator(stub, port=8556)
    with pytest.raises(EmulatorError, match="UNAVAILABLE"):
        emu.display_size()


def test_screenshot_returns_dimensions_and_bytes():
    status = _status({"hw.lcd.width": "2", "hw.lcd.height": "1"})
    img = pb.Image(format=pb.ImageFormat(format=pb.ImageFormat.RGBA8888, width=2, height=1),
                   image=b"\x00" * (2 * 1 * 4))
    stub = _FakeStub(status=status, screenshot=img)
    emu = Emulator(stub, port=8556)
    assert emu.screenshot() == (2, 1, b"\x00" * 8)


def test_screenshot_wraps_rpc_error_with_streaming_hint():
    """這條提示訊息是刻意的——streamScreenshot 是變化驅動、畫面靜止時不出幀，
    這個坑這個專案已經踩過三次。訊息裡的線索日後 refactor 時不能被順手拿掉。"""
    status = _status({"hw.lcd.width": "1080", "hw.lcd.height": "2400"})
    stub = _FakeStub(status=status, screenshot_error=_FakeRpcError("DEADLINE_EXCEEDED"))
    emu = Emulator(stub, port=8556)
    with pytest.raises(EmulatorError, match="streamScreenshot 是變化驅動"):
        emu.screenshot()


def test_send_touch_forwards_coordinates_and_pressure():
    stub = _FakeStub()
    emu = Emulator(stub, port=8556)
    emu.send_touch(100, 200, down=True)
    assert len(stub.touch_calls) == 1
    touch = stub.touch_calls[0].touches[0]
    assert (touch.x, touch.y, touch.pressure) == (100, 200, 1024)


def test_send_touch_wraps_rpc_error():
    stub = _FakeStub(touch_error=_FakeRpcError("UNAVAILABLE"))
    emu = Emulator(stub, port=8556)
    with pytest.raises(EmulatorError, match="sendTouch"):
        emu.send_touch(1, 1, down=False)


# ---------------------------------------------------------------------------
# down/up 不變式：一旦送出過任何一個 down，就一定要送出 up。
#
# 缺這條不變式時，裝置上會留下一根按著的手指——guest 端後續所有輸入都失準，
# 而且從外面完全看不出來，比原本那個錯誤本身更難查。兩條入口都會殘留：
# 中途 sendTouch RPC 失敗（3 個 down、0 個 up），以及負的 --ms 讓 time.sleep()
# 丟 ValueError（1 個 down、0 個 up）。
# ---------------------------------------------------------------------------

class _ScriptedTouchStub:
    """依呼叫次序決定每次 sendTouch 成功或失敗。

    `codes[i]` 是第 i+1 次 sendTouch 要丟的 gRPC 錯誤碼，None 表示成功；
    序列用完之後一律成功。`failed` 記下實際丟出去的錯誤碼——用來證明「清理用的
    up **有被嘗試**」，即使它自己也失敗了。
    """

    def __init__(self, codes: list[str | None] | None = None):
        self._codes = list(codes or [])
        self.touch_calls = []
        self.failed: list[str] = []

    def sendTouch(self, event, timeout=None):
        i = len(self.touch_calls) + len(self.failed)
        code = self._codes[i] if i < len(self._codes) else None
        if code:
            self.failed.append(code)
            raise _FakeRpcError(code)
        self.touch_calls.append(event)


def _touches(stub) -> list[tuple[int, int, int]]:
    return [(e.touches[0].x, e.touches[0].y, e.touches[0].pressure)
            for e in stub.touch_calls]


def test_swipe_sends_up_when_an_rpc_fails_midway():
    """中途 RPC 失敗（機率遠高於參數錯誤）：錯誤照樣往外拋，但最後一個送出去的
    事件必須是**終點的 up**，不能把觸點留在按下狀態。"""
    stub = _ScriptedTouchStub([None, None, "UNAVAILABLE"])
    emu = Emulator(stub, port=8556)
    with pytest.raises(EmulatorError, match="UNAVAILABLE"):
        emu.send_swipe([(0, 0), (10, 10), (20, 20), (30, 30)], step_ms=0)
    assert _touches(stub)[-1] == (30, 30, 0)          # 終點座標、pressure 0 = up


def test_swipe_sends_up_when_sleep_rejects_negative_step():
    """`probe.py swipe ... -300` 會走到 `time.sleep(-0.15)` 丟 ValueError。
    那不是 RPC 錯誤，所以只接 EmulatorError 的清理是不夠的——這裡確認任何
    例外（含 ValueError、KeyboardInterrupt）都會觸發 up。"""
    stub = _ScriptedTouchStub()
    emu = Emulator(stub, port=8556)
    with pytest.raises(ValueError):
        emu.send_swipe([(1, 2), (9, 9)], step_ms=-150)
    assert _touches(stub) == [(1, 2, 1024), (9, 9, 0)]


def test_swipe_cleanup_up_failure_does_not_mask_the_real_error():
    """清理路徑上的 up 自己再失敗時必須吞掉：使用者要看到的是**原始**失敗原因
    （UNAVAILABLE），不是清理時才發生的 INTERNAL。但清理仍必須被嘗試過。"""
    stub = _ScriptedTouchStub([None, None, "UNAVAILABLE", "INTERNAL"])
    emu = Emulator(stub, port=8556)
    with pytest.raises(EmulatorError, match="UNAVAILABLE"):
        emu.send_swipe([(0, 0), (10, 10), (20, 20)], step_ms=0)
    assert stub.failed == ["UNAVAILABLE", "INTERNAL"]   # 清理的 up 有被送出去


def test_swipe_completes_with_exactly_one_up_at_the_end():
    """正常路徑：N 個點 → N 個 down + 1 個 up，順序不能亂。"""
    stub = _ScriptedTouchStub()
    emu = Emulator(stub, port=8556)
    emu.send_swipe([(0, 0), (5, 5), (10, 10)], step_ms=0)
    assert _touches(stub) == [(0, 0, 1024), (5, 5, 1024), (10, 10, 1024), (10, 10, 0)]


def test_tap_sends_down_then_up():
    """tap 是「只有一個點的 stroke」，走的是同一條保證送出 up 的路徑——
    down/up 的配對關係只存在一處，呼叫端不再自己拼半組。"""
    stub = _ScriptedTouchStub()
    emu = Emulator(stub, port=8556)
    emu.send_tap(7, 11)
    assert _touches(stub) == [(7, 11, 1024), (7, 11, 0)]


def test_tap_does_not_send_a_stray_up_when_the_down_fails():
    """反向的不變式：**沒送出過 down 就不該送 up**。憑空的 up 會取消掉別人
    正在進行中的觸控序列。"""
    stub = _ScriptedTouchStub(["UNAVAILABLE"])
    emu = Emulator(stub, port=8556)
    with pytest.raises(EmulatorError):
        emu.send_tap(7, 11)
    assert stub.touch_calls == []
    assert stub.failed == ["UNAVAILABLE"]


def test_tap_up_failure_on_the_happy_path_still_raises():
    """正常路徑上的 up 失敗必須往外拋——那時觸點就是真的留在裝置上了，
    這是使用者唯一該知道的事，不能被清理邏輯默默吃掉。"""
    stub = _ScriptedTouchStub([None, "UNAVAILABLE"])
    emu = Emulator(stub, port=8556)
    with pytest.raises(EmulatorError, match="UNAVAILABLE"):
        emu.send_tap(7, 11)


def test_swipe_rejects_paths_shorter_than_two_points():
    stub = _ScriptedTouchStub()
    emu = Emulator(stub, port=8556)
    with pytest.raises(EmulatorError, match="2 個點"):
        emu.send_swipe([(1, 1)], step_ms=0)
    assert stub.touch_calls == []


def _pressures(stub) -> list[int]:
    """把 stub 收到的每個 TouchEvent 攤成 pressure 序列（1024=down、0=up）。"""
    return [e.touches[0].pressure for e in stub.touch_calls]


def test_send_tap_holds_before_releasing(monkeypatch):
    """tap 的 down 與 up 之間必須有按壓時間。

    2026-07-28 首次拿這支工具點真遊戲時，Unity 收得到觸控（Play 按鈕出現了按下
    的視覺回饋）卻不認成一次 click，畫面停在原地。零延遲的 tap 是「看起來有送出、
    實際上沒作用」——比完全沒送更難查，因為視覺回饋會讓人以為是座標錯了。

    實測的門檻（見 DEFAULT_TAP_HOLD_MS 的註解）：0ms 與 60ms 都無效、150ms 有效。
    本測試不釘住具體數值，只釘住「down 與 up 之間確實睡了預設的那段時間」——
    數值該由實測決定，不該由測試凍結。
    """
    import lib.emulator as emulator_mod

    slept: list[float] = []
    monkeypatch.setattr(emulator_mod.time, "sleep", slept.append)
    stub = _FakeStub()
    Emulator(stub, port=8556).send_tap(100, 200)

    assert _pressures(stub) == [1024, 0], "必須剛好是一組 down/up"
    assert slept == [emulator_mod.DEFAULT_TAP_HOLD_MS / 1000.0], \
        f"down 與 up 之間應睡 {emulator_mod.DEFAULT_TAP_HOLD_MS}ms，實得 {slept}"


def test_send_tap_still_releases_when_hold_sleep_fails(monkeypatch):
    """按壓時間的 sleep 若失敗，up 仍然要送出。

    hold 的 sleep 發生在 down **之後**——它若拋例外而沒補上 up，裝置上就留著
    一根按著的手指，後續所有輸入都失準且從外面完全看不出來。這是 `_stroke`
    那條不變式（送出 down 就一定送出 up）必須涵蓋的第三條入口。

    用會拋的 sleep 而非負的 hold_ms 來觸發：負值被 `if hold_ms > 0` 擋成
    no-op（那是刻意的——不 hold 比拋例外合理），走不到這條路徑。
    """
    import lib.emulator as emulator_mod

    def boom(_seconds):
        raise KeyboardInterrupt("使用者中斷")

    monkeypatch.setattr(emulator_mod.time, "sleep", boom)
    stub = _FakeStub()
    with pytest.raises(KeyboardInterrupt):
        Emulator(stub, port=8556).send_tap(100, 200, hold_ms=50)

    assert _pressures(stub) == [1024, 0], "失敗路徑上仍須送出 up"


def test_negative_hold_is_a_noop_not_an_error(monkeypatch):
    """負的 hold_ms 不 sleep、也不報錯——就是不按住直接放開。

    這條釘住上一條測試依賴的前提：負值走不到 sleep。若哪天改成對負值拋例外，
    上一條會沉默地失去它要測的路徑。
    """
    import lib.emulator as emulator_mod

    slept: list[float] = []
    monkeypatch.setattr(emulator_mod.time, "sleep", slept.append)
    stub = _FakeStub()
    Emulator(stub, port=8556).send_tap(100, 200, hold_ms=-1)

    assert slept == [], "負的 hold_ms 不該 sleep"
    assert _pressures(stub) == [1024, 0]
