"""gRPC 操作。畫面與輸入都走這條——也就是 Mirage 產品走的同一條路徑。"""
import contextlib
import time

import grpc

import emulator_controller_pb2 as pb
import emulator_controller_pb2_grpc as pbg
from google.protobuf import empty_pb2

# 1080x2400 RGBA = 10.4 MB，遠超 gRPC 預設的 4 MB 上限。
_MAX_MESSAGE = 64 * 1024 * 1024


class EmulatorError(RuntimeError):
    pass


class Emulator:
    def __init__(self, stub, port: int):
        self._stub = stub
        self._port = port

    def display_size(self) -> tuple[int, int]:
        """guest 實體螢幕解析度，與 EmulatorClient 取的是同一個來源（hw.lcd.*）。"""
        try:
            status = self._stub.getStatus(empty_pb2.Empty(), timeout=10)
        except grpc.RpcError as e:
            raise EmulatorError(f"grpc localhost:{self._port} unreachable ({e.code().name})") from None
        cfg = {e.key: e.value for e in status.hardwareConfig.entry}
        try:
            w, h = int(cfg["hw.lcd.width"]), int(cfg["hw.lcd.height"])
        except (KeyError, ValueError):
            raise EmulatorError("getStatus 沒有可用的 hw.lcd.width/height") from None
        if w <= 0 or h <= 0:
            raise EmulatorError(f"hw.lcd 尺寸不合理：{w}x{h}")
        return w, h

    def screenshot(self) -> tuple[int, int, bytes]:
        w, h = self.display_size()
        fmt = pb.ImageFormat(format=pb.ImageFormat.RGBA8888, width=w, height=h)
        try:
            img = self._stub.getScreenshot(fmt, timeout=15)
        except grpc.RpcError as e:
            raise EmulatorError(
                f"connected but no frame in 15s — streamScreenshot 是變化驅動的，"
                f"畫面靜止時不出幀（{e.code().name}）") from None
        return img.format.width, img.format.height, img.image

    def send_touch(self, x: int, y: int, down: bool) -> None:
        touch = pb.Touch(x=x, y=y, identifier=0, pressure=1024 if down else 0)
        try:
            self._stub.sendTouch(pb.TouchEvent(touches=[touch]), timeout=10)
        except grpc.RpcError as e:
            raise EmulatorError(f"sendTouch 失敗：{e.code().name}") from None

    def send_tap(self, x: int, y: int) -> None:
        """單點點擊。就是只有一個點的 stroke——down/up 的配對關係只存在一處。"""
        self._stroke([(x, y)])

    def send_swipe(self, path: list[tuple[int, int]], step_ms: int) -> None:
        """連續觸點構成的拖曳。頭尾分別是 down 與 up。"""
        if len(path) < 2:
            raise EmulatorError(f"swipe 至少需要 2 個點，實得 {len(path)}")
        self._stroke(path, step_ms)

    def _stroke(self, path: list[tuple[int, int]], step_ms: int = 0) -> None:
        """沿 path 送出一連串 down，結束時送出 up。

        **不變式：一旦送出過任何一個 down，就一定會送出 up。**

        缺這條不變式時有兩條入口會在裝置上留下一根按著的手指：中途任一
        `sendTouch` RPC 失敗（3 個 down、0 個 up），以及負的 `step_ms` 讓
        `time.sleep()` 丟 ValueError（1 個 down、0 個 up）。殘留的觸點會讓
        guest 端後續所有輸入都失準，而且從外面完全看不出來——比原本的錯誤
        本身更難查。所以擋在這裡，而不是在每個呼叫端加 if：呼叫端會漏，
        `cmd_tap` 當初就漏了。

        失敗路徑上的 up 是 best-effort：它自己再失敗時必須**吞掉**，否則會
        蓋掉真正的失敗原因。正常路徑上的 up 失敗則照常往外拋——那時它就是
        使用者唯一該知道的事。
        """
        last = path[-1]
        down_sent = False
        try:
            for i, (x, y) in enumerate(path):
                self.send_touch(x, y, down=True)
                down_sent = True
                if i < len(path) - 1:
                    time.sleep(step_ms / 1000.0)
        except BaseException:
            if down_sent:
                with contextlib.suppress(EmulatorError):
                    self.send_touch(last[0], last[1], down=False)
            raise
        self.send_touch(last[0], last[1], down=False)


@contextlib.contextmanager
def connect(port: int):
    options = [("grpc.max_receive_message_length", _MAX_MESSAGE)]
    with grpc.insecure_channel(f"localhost:{port}", options=options) as channel:
        yield Emulator(pbg.EmulatorControllerStub(channel), port)
