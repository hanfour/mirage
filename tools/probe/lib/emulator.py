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

    def send_swipe(self, path: list[tuple[int, int]], step_ms: int) -> None:
        """連續觸點構成的拖曳。頭尾分別是 down 與 up。"""
        if len(path) < 2:
            raise EmulatorError(f"swipe 至少需要 2 個點，實得 {len(path)}")
        for i, (x, y) in enumerate(path):
            self.send_touch(x, y, down=True)
            if i < len(path) - 1:
                time.sleep(step_ms / 1000.0)
        last_x, last_y = path[-1]
        self.send_touch(last_x, last_y, down=False)


@contextlib.contextmanager
def connect(port: int):
    options = [("grpc.max_receive_message_length", _MAX_MESSAGE)]
    with grpc.insecure_channel(f"localhost:{port}", options=options) as channel:
        yield Emulator(pbg.EmulatorControllerStub(channel), port)
