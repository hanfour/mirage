"""sendTouch 注入 RTT：量 gRPC 單次呼叫往返時間（對應預算表「gRPC 輸入注入 < 3ms」）。"""
import sys
import time

sys.path.insert(0, "gen")

import grpc
import emulator_controller_pb2 as ec
import emulator_controller_pb2_grpc as ecg
from lib.stats import percentile

TARGET = "localhost:8554"
N_TAPS = 200
TAP_X, TAP_Y = 540, 1200  # pixel_7 螢幕中央附近


def send_tap(stub, x: int, y: int, down: bool) -> None:
    touch = ec.Touch(x=x, y=y, identifier=0, pressure=1024 if down else 0)
    stub.sendTouch(ec.TouchEvent(touches=[touch]), timeout=2)


def main() -> int:
    stub = ecg.EmulatorControllerStub(grpc.insecure_channel(TARGET))
    rtts_ms: list[float] = []
    for _ in range(N_TAPS):
        t0 = time.monotonic()
        send_tap(stub, TAP_X, TAP_Y, down=True)
        rtts_ms.append((time.monotonic() - t0) * 1000)
        send_tap(stub, TAP_X, TAP_Y, down=False)
        time.sleep(0.02)
    print(f"n={len(rtts_ms)} p50={percentile(rtts_ms, 50):.2f}ms "
          f"p95={percentile(rtts_ms, 95):.2f}ms max={max(rtts_ms):.2f}ms")
    return 0


if __name__ == "__main__":
    sys.exit(main())
